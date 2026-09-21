// SPDX-License-Identifier: Apache-2.0
//! util/sync — 进程内同步原语
//!
//! Zig 0.17-dev 已移除 `std.Thread.Mutex`（新的 `std.Io.Mutex` 依赖 Io 运行时不便嵌入
//! 数据结构），这里提供基于 `std.atomic.Value(u8)` 的极简 CAS 自旋锁，供
//! `cache.Memory` 与 `credential` 各令牌获取器共用，替代原先散落在 5 个文件里的
//! 重复实现。
//!
//! 适用场景：临界区极短（哈希表查询 / 一次赋值）的缓存类数据结构。
//! 不适合临界区含网络 I/O 或长时间计算的场景（那种应使用基于 Io 运行时的互斥）。

const std = @import("std");

/// 最简 CAS 自旋锁。
///
/// 非递归：同一线程对已持有的锁再次 `lock` 会死锁，调用方需自行保证。
pub const SpinMutex = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    const UNLOCKED: u8 = 0;
    const LOCKED: u8 = 1;

    /// 获取锁，自旋直到成功。获取顺序为 `.acquire`，与 `unlock` 的 `.release` 配对。
    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    /// 释放锁。锁必须已被当前线程持有。
    pub fn unlock(self: *SpinMutex) void {
        self.state.store(UNLOCKED, .release);
    }

    /// 尝试获取锁，不阻塞。返回 `true` 表示获取成功。
    pub fn tryLock(self: *SpinMutex) bool {
        return self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }
};

test "SpinMutex lock/unlock 状态迁移" {
    var m: SpinMutex = .{};
    try std.testing.expect(m.tryLock());
    try std.testing.expect(!m.tryLock());
    m.unlock();
    m.lock();
    m.unlock();
}

test "SpinMutex 多线程互斥：并发自增不丢更新" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        mutex: SpinMutex = .{},
        counter: usize = 0,
    };
    var ctx: Ctx = .{};

    const Worker = struct {
        fn run(c: *Ctx) void {
            var i: usize = 0;
            while (i < 50000) : (i += 1) {
                c.mutex.lock();
                c.counter += 1;
                c.mutex.unlock();
            }
        }
    };

    const threads = try allocator.alloc(std.Thread, 4);
    defer allocator.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&ctx});
    for (threads) |t| t.join();

    // 若互斥失效，自增会相互覆盖，总数必然小于 4 * 50000。
    try std.testing.expectEqual(@as(usize, 4 * 50000), ctx.counter);
}
