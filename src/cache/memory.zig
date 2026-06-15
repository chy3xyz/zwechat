//! cache/memory — 内存缓存实现
//!
//! 对应 `_ref/wechat/cache/memory.go`：进程内线程安全的 KV 缓存，支持过期时间（TTL）。
//! - 键、值字符串由本结构持有，插入时复制、由 `Memory.deinit` / `delete` / 覆盖写时释放。
//! - 互斥使用一个原子自旋锁实现（Zig 0.17-dev 已移除 `std.Thread.Mutex`，新 `std.Io.Mutex`
//!   依赖 Io 运行时不便嵌入数据结构；这里采用最精简的 CAS 自旋锁以保持零依赖）。
//! - TTL 以纳秒存储（`expire_at_ns: i64`）；`get` / `isExist` 命中过期键时延迟删除。

const std = @import("std");
const Cache = @import("mod.zig").Cache;
const CacheError = @import("mod.zig").CacheError;

/// 内存缓存条目。值是 dup 出的所有权内存，由 `Memory` 释放。
/// 键由 `HashMap` 自身管理（同样 dup），不重复保存。
const Entry = struct {
    value: []const u8,
    /// 纳秒时间戳（`Io.Clock.now(.awake, io).nanoseconds`）。
    /// 0 表示永不过期。
    expire_at_ns: i64,
};

/// 最简 CAS 自旋锁。Zig 0.17-dev 不再提供 `std.Thread.Mutex`，
/// 这里用 `std.atomic.Value(u8)` 手工实现 5 行版本，足以覆盖缓存场景。
const SpinMutex = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    const UNLOCKED: u8 = 0;
    const LOCKED: u8 = 1;

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(UNLOCKED, .release);
    }
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
    /// 进程内线程安全互斥。
    mutex: SpinMutex,

    /// 分配一个新的 `Memory` 缓存。
    ///
    /// 调用方须在使用完毕后依次调用 `deinit()` 与 `allocator.destroy(self)`。
    pub fn create(allocator: std.mem.Allocator) !*Memory {
        const self = try allocator.create(Memory);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .data = std.HashMap([]const u8, Entry, std.hash_map.StringContext, 80).init(allocator),
            .mutex = .{},
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
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_key = self.allocator.dupe(u8, key) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_key);

        const owned_val = self.allocator.dupe(u8, val) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_val);

        const expire_at_ns: i64 = if (ttl_seconds <= 0)
            0
        else
            nowNanoseconds() +| (ttl_seconds * std.time.ns_per_s);

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
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();
        defer self.mutex.unlock();

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

    /// 当前单调时钟纳秒时间戳。统一通过 `std.Io.Clock.now(.awake, ...)` 取得，
    /// 与上游 Go 版 `time.Now()` 在单调递增语义上保持一致。
    fn nowNanoseconds() i64 {
        const ts = std.Io.Clock.now(.awake, std.Options.debug_io);
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
    try std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromMilliseconds(1200), .awake);

    // 过期后读 / 存在性检查都应返回 null / false，并触发惰性删除。
    const after = try c.get("ephemeral");
    try std.testing.expect(after == null);
    try std.testing.expect(!(try c.isExist("ephemeral")));
    try std.testing.expectEqual(@as(usize, 0), mem.data.count());
}

test "memory delete 与 deinit 不泄漏" {
    // 使用 DebugAllocator 风格的 testing.allocator 在内存泄漏 / 双重释放时会失败。
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
