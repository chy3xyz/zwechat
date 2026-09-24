// SPDX-License-Identifier: Apache-2.0
//! util/sync — 进程内同步原语
//!
//! **已迁移到 `std.Io.Mutex`**（此前这里是手写 CAS 自旋锁；旧注释「`std.Io.Mutex`
//! 依赖 Io 运行时不便嵌入数据结构」是错的）：`std.Io.Mutex` 是 `extern struct`，
//! 可以静态初始化（`.init`）并直接内嵌为任意结构体的字段，不需要构造期传入任何
//! Io 运行时。它内部走 `Io.futexWait` / `Io.futexWake`
//! （Linux `futex(2)` / macOS `__ulock_wait2` / Windows `RtlWaitOnAddress`），
//! 用 `std.Io.Threaded.global_single_threaded.io()` 也是**真阻塞**，
//! 不会像自旋锁那样在临界区较长时空转烧 CPU（更不会把整个时间片耗在等待者身上）。
//!
//! 迁移后的惯用写法（结构体持锁 + 可注入 Io）：
//!
//! ```zig
//! io: std.Io = std.Io.Threaded.global_single_threaded.io(),
//! mutex: std.Io.Mutex = .init,
//! // 临界区：
//! self.mutex.lockUncancelable(self.io);
//! defer self.mutex.unlock(self.io);
//! ```
//!
//! 用 `lockUncancelable`（而不是 `lock`）是刻意的：这里全是同步代码，没有
//! cancelation point，`lockUncancelable` 返回 `void`、不需要 `try`。
//!
//! 本文件保留的 `SpinMutex` 只是**兼容层**（名字沿用历史，内部不再是自旋锁）：
//! 给尚未迁移到 `std.Io.Mutex` 的引用提供零参数 `lock()` / `unlock()` / `tryLock()`。
//! 新代码请直接用 `std.Io.Mutex`。

const std = @import("std");

/// 默认 `Io` 句柄：`global_single_threaded` 的 futex 路径不依赖实例状态
/// （`Io.Threaded` 的 `futexWaitUncancelable` / `futexWake` 直接下发系统调用，
/// 不使用 `userdata`），因此可以安全地在任意线程上用于跨线程的锁等待与唤醒。
pub const defaultIo: std.Io = std.Io.Threaded.global_single_threaded.io();

/// 兼容层（**已弃用**）：零参数 `lock()` / `unlock()` 的历史签名，内部已改为
/// `std.Io.Mutex` 的**真阻塞**实现（不再是 CAS 自旋）。
///
/// 之所以不直接删成 `pub const SpinMutex = std.Io.Mutex;`：那样 `lock()` 就不再是
/// 零参数，尚未迁移的调用点会编译失败。保留本包装类型让它们既继续编译，
/// 又顺便从「空转自旋」升级为「真阻塞」。
///
/// 新代码请直接使用 `std.Io.Mutex`（结构体内加 `io: std.Io` 字段 +
/// `mutex: std.Io.Mutex = .init`，临界区写 `lockUncancelable(io)` / `unlock(io)`）。
pub const SpinMutex = struct {
    /// futex 等待 / 唤醒所用的 Io 句柄，可注入（默认 `defaultIo`）。
    io: std.Io = defaultIo,
    /// 真正的互斥量。`std.Io.Mutex` 非递归：同一线程重复 `lock` 会死锁。
    mutex: std.Io.Mutex = .init,

    /// 获取锁，阻塞直到成功（futex 等待，不空转）。
    pub fn lock(self: *SpinMutex) void {
        self.mutex.lockUncancelable(self.io);
    }

    /// 释放锁。锁必须已被当前线程持有。
    pub fn unlock(self: *SpinMutex) void {
        self.mutex.unlock(self.io);
    }

    /// 尝试获取锁，不阻塞。返回 `true` 表示获取成功。
    pub fn tryLock(self: *SpinMutex) bool {
        return self.mutex.tryLock();
    }
};

test "SpinMutex 兼容层：lock/unlock/tryLock 状态迁移" {
    var m: SpinMutex = .{};
    try std.testing.expect(m.tryLock());
    // 非递归：已持有时再 tryLock 必须失败（新实现同样是不可重入锁）。
    try std.testing.expect(!m.tryLock());
    m.unlock();
    m.lock();
    m.unlock();

    // `io` 可注入。
    var injected: SpinMutex = .{ .io = defaultIo };
    injected.lock();
    injected.unlock();
}

test "std.Io.Mutex：持锁期间同线程再取锁会阻塞（用 tryLock 断言，不写死锁测试）" {
    // 迁移语义取证：`lockUncancelable` 之后锁已归本线程所有，`tryLock` 必须返回
    // false（等价于「同线程再 `lock` 会阻塞」的安全断言）。这里刻意不写
    // 「同线程 lock 两次」的真死锁测试。
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(defaultIo);
    try std.testing.expect(!mutex.tryLock());
    mutex.unlock(defaultIo);

    try std.testing.expect(mutex.tryLock());
    mutex.unlock(defaultIo);
}

test "std.Io.Mutex：跨线程真阻塞（持锁者未释放时等待者进不去临界区）" {
    const Ctx = struct {
        mutex: std.Io.Mutex = .init,
        /// 等待者已比持锁者先就绪（准备调用 lock）。
        waiter_ready: std.atomic.Value(bool) = .init(false),
        /// 等待者已成功进入临界区。
        acquired: std.atomic.Value(bool) = .init(false),

        fn waiter(self: *@This()) void {
            self.waiter_ready.store(true, .release);
            self.mutex.lockUncancelable(defaultIo);
            self.acquired.store(true, .release);
            self.mutex.unlock(defaultIo);
        }
    };

    var ctx: Ctx = .{};

    ctx.mutex.lockUncancelable(defaultIo);
    const t = try std.Thread.spawn(.{}, Ctx.waiter, .{&ctx});

    while (!ctx.waiter_ready.load(.acquire)) std.atomic.spinLoopHint();
    // 持锁者仍持锁：等待者只能停在 futex 等待里，不可能进入临界区。
    std.Io.sleep(defaultIo, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    try std.testing.expect(!ctx.acquired.load(.acquire));

    // 释放后等待者必须拿到锁（由互斥量保证，不依赖调度时序）。
    ctx.mutex.unlock(defaultIo);
    t.join();

    try std.testing.expect(ctx.acquired.load(.acquire));
    // 释放后可再次获取，说明锁状态已正确回到 unlocked。
    try std.testing.expect(ctx.mutex.tryLock());
    ctx.mutex.unlock(defaultIo);
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
