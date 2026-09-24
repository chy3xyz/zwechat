// SPDX-License-Identifier: Apache-2.0
//! cache/memory — 内存缓存实现
//!
//! 对应 `_ref/wechat/cache/memory.go`：进程内线程安全的 KV 缓存，支持过期时间（TTL）。
//! - 键、值字符串由本结构持有，插入时复制、由 `Memory.deinit` / `delete` / 覆盖写时释放。
//! - 互斥使用 `std.Io.Mutex`：真阻塞的 futex 锁（Linux `futex(2)` / macOS
//!   `__ulock_wait2`），可静态初始化并直接内嵌为字段，零依赖且不空转烧 CPU。
//!   `io` 字段驱动 futex 等待 / 唤醒，默认本仓进程级单例 `default_io.io()`，
//!   可用 `Memory.createWithIo` 注入宿主运行时的 `Io`。
//! - TTL 以纳秒存储（`expire_at_ns: i64`）；`get` / `isExist` 命中过期键时延迟删除。

const std = @import("std");
const default_io = @import("../util/default_io.zig");
const Cache = @import("mod.zig").Cache;
const CacheError = @import("mod.zig").CacheError;

/// 内存缓存条目。值是 dup 出的所有权内存，由 `Memory` 释放。
/// 键由 `HashMap` 自身管理（同样 dup），不重复保存。
const Entry = struct {
    value: []const u8,
    /// 纳秒时间戳（`ttlClock()` 的读数）。0 表示永不过期。
    expire_at_ns: i64,
};

/// 内存缓存。对应 Go 版的 `Memory`（`_ref/wechat/cache/memory.go`）。
///
/// 内部数据存放在堆上，通过 `create(allocator)` 构造；调用方负责：
/// 1. `deinit()` 释放所有键值与表项；
/// 2. `allocator.destroy(self)` 回收结构自身。
pub const Memory = struct {
    /// 持有本结构与所有键值字符串的分配器。
    allocator: std.mem.Allocator,
    /// 键 → 条目 的哈希表。键 / 值的所有权由 `Memory` 管理。
    data: std.HashMap([]const u8, Entry, std.hash_map.StringContext, 80),
    /// futex 等待 / 唤醒所用的 `Io` 句柄（默认 `default_io.io()`，其 futex 路径
    /// 不依赖实例状态，跨线程使用安全）。
    io: std.Io = default_io.io(),
    /// 进程内线程安全互斥（真阻塞的 futex 锁）。
    mutex: std.Io.Mutex = .init,

    /// 分配一个新的 `Memory` 缓存（互斥量使用默认 `Io`）。
    ///
    /// 调用方须在使用完毕后依次调用 `deinit()` 与 `allocator.destroy(self)`。
    pub fn create(allocator: std.mem.Allocator) !*Memory {
        return createWithIo(allocator, default_io.io());
    }

    /// 分配一个新的 `Memory` 缓存，并注入驱动互斥量的 `Io` 句柄。
    ///
    /// 临界区全是纯内存操作（哈希表读 / 写），`io` 只影响 futex 等待与唤醒的实现；
    /// 需要与宿主运行时共用同一个 `Io` 时用本构造。
    pub fn createWithIo(allocator: std.mem.Allocator, io: std.Io) !*Memory {
        const self = try allocator.create(Memory);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .data = std.HashMap([]const u8, Entry, std.hash_map.StringContext, 80).init(allocator),
            .io = io,
        };
        return self;
    }

    /// 释放 `Memory` 持有的所有键值字符串与表项。
    ///
    /// **不会**释放 `Memory` 结构本身；调用方仍需 `allocator.destroy(self)`。
    /// 释放后请勿再使用 `asCache()` 得到的句柄。
    pub fn deinit(self: *Memory) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.data.deinit();
        self.* = undefined;
    }

    /// 返回绑定到本实例的 vtable 句柄。
    ///
    /// 返回值按值拷贝，使用时需保证 `self` 仍然存活。
    pub fn asCache(self: *Memory) Cache {
        return .{
            .ctx = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    // ---------------- vtable 实现 ----------------

    const vtable: Cache.VTable = .{
        .get = getImpl,
        .set = setImpl,
        .isExist = isExistImpl,
        .delete = deleteImpl,
        .deinit = deinitImpl,
    };

    fn getImpl(ctx: *anyopaque, key: []const u8) CacheError!?[]const u8 {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const gop = self.data.getEntry(key) orelse return null;

        if (isExpired(gop.value_ptr.expire_at_ns)) {
            // 先用 fetchRemove 安全地拆下条目，再释放键值内存；
            // 这样可以避免 `free` 后再让 HashMap 比较已释放字节导致的 UB。
            if (self.data.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.value);
            }
            return null;
        }
        return gop.value_ptr.value;
    }

    fn setImpl(ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const owned_key = self.allocator.dupe(u8, key) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_key);

        const owned_val = self.allocator.dupe(u8, val) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_val);

        const expire_at_ns: i64 = if (ttl_seconds <= 0)
            0
        else
            // 乘法用饱和版本：ttl_seconds 来自外部（如微信响应里的 expires_in），
            // 极大值（如 i64 max）在 Debug 下会让普通 `*` 触发整数溢出 panic。
            // 饱和到 maxInt(i64) 后实际效果等价于永不过期。
            nowNanoseconds() +| (ttl_seconds *| std.time.ns_per_s);

        // 覆盖写：先释放旧键值，再插入新条目。
        if (self.data.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.value);
        }

        try self.data.put(owned_key, .{
            .value = owned_val,
            .expire_at_ns = expire_at_ns,
        });
    }

    fn isExistImpl(ctx: *anyopaque, key: []const u8) CacheError!bool {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const gop = self.data.getEntry(key) orelse return false;
        if (isExpired(gop.value_ptr.expire_at_ns)) {
            // 与 `getImpl` 同样的懒删路径：先 fetchRemove 再释放内存。
            if (self.data.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.value);
            }
            return false;
        }
        return true;
    }

    fn deleteImpl(ctx: *anyopaque, key: []const u8) CacheError!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.data.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.value);
        }
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    // ---------------- 内部辅助 ----------------

    fn isExpired(expire_at_ns: i64) bool {
        if (expire_at_ns == 0) return false;
        return nowNanoseconds() >= expire_at_ns;
    }

    /// TTL 判定链（写入过期时刻 + 过期比较）统一使用的时钟源。
    ///
    /// 刻意选 `Clock.boot`（Linux `CLOCK_BOOTTIME` / macOS `CLOCK_MONOTONIC_RAW`）：
    /// 它**计入**系统休眠时间，而 `awake` 排除休眠。缓存 TTL 表达的是「这份凭据在
    /// 网络世界里还剩多久过期」，必须随墙钟推进 —— 若用 `awake`，笔记本合盖 /
    /// 容器冻结数小时再唤醒后 `expire_at_ns` 没有前进，缓存里会留着微信侧**早已
    /// 失效**的 access_token（白吃一次 40001，靠自愈重试补回来）。
    ///
    /// 反例（不要照搬到这里）：纯耗时测量（如测试里量 `elapsed_ms`、连接池等待
    /// 退避）要的恰恰是「进程实际被调度运行了多久」，那里继续用 `awake`。
    fn ttlClock() std.Io.Clock {
        return .boot;
    }

    /// TTL 时钟的当前纳秒读数（来源见 `ttlClock`）。
    fn nowNanoseconds() i64 {
        const ts = std.Io.Clock.now(ttlClock(), default_io.io());
        // 纳秒值远低于 i64 上限；截断到 i64 方便序列化与比较。
        return @intCast(ts.nanoseconds);
    }
};

// ============================================================================
// 单元测试
// ============================================================================

test "memory 基本 set/get 往返" {
    const allocator = std.testing.allocator;
    const mem = try Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    const c = mem.asCache();
    try c.set("name", "alice", 60);

    const got = try c.get("name");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("alice", got.?);
}

test "memory overwrite：后写者赢" {
    const allocator = std.testing.allocator;
    const mem = try Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    const c = mem.asCache();
    try c.set("k", "v1", 60);
    try c.set("k", "v2", 60);

    const got = try c.get("k");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v2", got.?);
    try std.testing.expectEqual(@as(usize, 1), mem.data.count());
}

test "memory TTL 到期后惰性删除" {
    const allocator = std.testing.allocator;
    const mem = try Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    const c = mem.asCache();
    // 1 秒 TTL，等待 1.2 秒确保过期。
    try c.set("ephemeral", "value", 1);

    // 立即读取应当命中。
    try std.testing.expect((try c.get("ephemeral")) != null);
    try std.testing.expect(try c.isExist("ephemeral"));

    // 睡眠到过期之后（Zig 0.17-dev：`std.Thread.sleep` 已移除，改用 `std.Io.sleep`）。
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1200), .awake);

    // 过期后读 / 存在性检查都应返回 null / false，并触发惰性删除。
    const after = try c.get("ephemeral");
    try std.testing.expect(after == null);
    try std.testing.expect(!(try c.isExist("ephemeral")));
    try std.testing.expectEqual(@as(usize, 0), mem.data.count());
}

test "memory delete 与 deinit 不泄漏" { // 使用 DebugAllocator 风格的 testing.allocator 在内存泄漏 / 双重释放时会失败。
    const allocator = std.testing.allocator;
    const mem = try Memory.create(allocator);
    const c = mem.asCache();

    try c.set("a", "1", 60);
    try c.set("b", "2", 60);
    try c.set("c", "3", 60);

    try c.delete("b");
    try std.testing.expectEqual(@as(usize, 2), mem.data.count());
    try std.testing.expect(try c.isExist("a"));
    try std.testing.expect(!try c.isExist("b"));
    try std.testing.expect(try c.isExist("c"));

    mem.deinit();
    allocator.destroy(mem);
}

test "memory 超大 TTL 不触发整数溢出 panic" {
    // 回归：ttl_seconds 来自外部输入（如微信响应的 expires_in），极大值
    // （i64 max）在 Debug 模式下会让 `ttl_seconds * ns_per_s` 溢出 panic。
    // 修复后饱和到 maxInt(i64)，实际效果等价于永不过期。
    const allocator = std.testing.allocator;
    const mem = try Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    const c = mem.asCache();
    try c.set("huge_ttl", "v", std.math.maxInt(i64));

    const got = try c.get("huge_ttl");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    try std.testing.expect(try c.isExist("huge_ttl"));
}

test "memory 互斥已迁移为 std.Io.Mutex：持锁期间同线程 tryLock 返回 false" {
    // 取证：锁字段的类型与语义都是 `std.Io.Mutex`（`tryLock` 无参数、
    // `lockUncancelable` 需要 `io`）。用 tryLock 断言替代「同线程 lock 两次」的
    // 死锁测试。
    const allocator = std.testing.allocator;
    const mem = try Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    mem.mutex.lockUncancelable(mem.io);
    try std.testing.expect(!mem.mutex.tryLock());
    mem.mutex.unlock(mem.io);

    try std.testing.expect(mem.mutex.tryLock());
    mem.mutex.unlock(mem.io);
}

test "memory createWithIo：注入的 Io 驱动互斥量，多线程并发写表不丢条目" {
    // 迁移语义取证：并发 insert 走同一个哈希表，互斥一旦失效就会出现
    // 条目覆盖 / 表结构损坏（HashMap 非线程安全，损坏时 count 必然对不上）。
    const allocator = std.testing.allocator;
    const mem = try Memory.createWithIo(allocator, default_io.io());
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    const THREADS = 4;
    const PER_THREAD = 200;

    const Worker = struct {
        fn run(m: *Memory, tid: usize) !void {
            var i: usize = 0;
            while (i < PER_THREAD) : (i += 1) {
                var key_buf: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buf, "concurrent_{d}_{d}", .{ tid, i });
                try m.asCache().set(key, "v", 60);
            }
        }
    };

    const threads = try allocator.alloc(std.Thread, THREADS);
    defer allocator.free(threads);
    for (threads, 0..) |*t, tid| t.* = try std.Thread.spawn(.{}, Worker.run, .{ mem, tid });
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, THREADS * PER_THREAD), mem.data.count());
    // 抽查每线程的首尾键都在。
    try std.testing.expect(try mem.asCache().isExist("concurrent_0_0"));
    try std.testing.expect(try mem.asCache().isExist("concurrent_3_199"));
}

test "memory TTL 取时来源为 Clock.boot（计入休眠）" {
    // TTL 必须计入系统休眠：`awake` 时钟在休眠期间不前进，用它会让
    // 「合盖 8 小时后唤醒」的进程继续复用早已失效的 access_token。
    // 这里断言取时封装确实走 boot 时钟，且写入的 expire_at_ns 由它算出。
    try std.testing.expectEqual(std.Io.Clock.boot, Memory.ttlClock());

    // 取时封装就是 boot 时钟的读数（同一时刻前后夹逼）。
    const before: i64 = @intCast(std.Io.Clock.now(Memory.ttlClock(), std.testing.io).nanoseconds);
    const got = Memory.nowNanoseconds();
    const after: i64 = @intCast(std.Io.Clock.now(Memory.ttlClock(), std.testing.io).nanoseconds);
    try std.testing.expect(got >= before and got <= after);

    const allocator = std.testing.allocator;
    const mem = try Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    const ttl_seconds: i64 = 60;
    try mem.asCache().set("k", "v", ttl_seconds);
    const expire_at_ns = mem.data.get("k").?.expire_at_ns;
    const expected = before + ttl_seconds * std.time.ns_per_s;
    // 写入与这里的取时之间只隔了几条指令，容差给到 1 秒足够宽松；
    // 若写入侧换了别的时钟源（例如 awake），两者在这台机器上会差出休眠时长。
    try std.testing.expect(@abs(expire_at_ns - expected) < std.time.ns_per_s);
    try std.testing.expect(@abs(expire_at_ns - (after + ttl_seconds * std.time.ns_per_s)) < std.time.ns_per_s);
}
