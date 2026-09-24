// SPDX-License-Identifier: Apache-2.0
//! util/default_io — 本仓**自己的**进程级 `Io` 单例
//!
//! 全仓所有「默认 `Io`」（结构体字段默认值，以及 `getCurrTS()` / `randomStr()`
//! 一类无 `Io` 参数的兼容入口）都指向本文件的实例，而不是
//! `std.Io.Threaded.global_single_threaded`。
//!
//! ## 为什么不用 `std.Io.Threaded.global_single_threaded`
//!
//! 那个单例**不是线程安全的** —— `std/Io/Threaded.zig` 的注释明写
//! "This instance does not support concurrency or cancelation"。偏偏
//! `lib/compiler/test_runner.zig` 把它当成**测试进程与 build runner 之间协议
//! I/O 的载体**（`runner_threaded_io`，配合 `--listen=-` 收发
//! `std.zig.Server` 消息）；`std.Options.debug_io` 的默认值也是同一个对象
//! （`std/std.zig`：`debug_threaded_io` 缺省即 `Io.Threaded.global_single_threaded`）。
//!
//! 而本仓大量默认路径过去正是从这个单例取 `Io`，部分用例还在派生线程
//! （mock server / 并发 token 测试）里拿它做 IO —— 库代码与 runner 的协议 stdio
//! 共用一个非线程安全实例，是随时可能踩坏内部状态的隐患。
//!
//! 本文件提供**同一进程内的第二个** `Io.Threaded` 实例：库代码只用它，runner
//! 的协议 stdio 继续用自己的，两条路径不再共享可变状态。
//!
//! ### 它不治那行 `failed command`（实测结论，勿再误判）
//!
//! 仓库曾怀疑 `zig build test` 每次打印的那行
//! `failed command: .../test --cache-dir=... --seed=... --listen=-` 正是该共享所致，
//! 并把本文件当成修复。**A/B 实测否定了该假设**：把库代码对 `global_single_threaded`
//! 的引用全部换成本文件后，那行依旧每次都出现（改前 4/4 次、改后 6/6 次，
//! 另有 3/3 稳定性复跑），而同一份汇总始终是 `N/N tests passed` + `test success`、
//! 退出码 0。
//!
//! 真正的原因（读工具链源码确认）：`lib/compiler/Maker.zig:2699` 只要某一步**产生了
//! 任何 stderr** 就调用 `printErrorMessages`，**完全不看该步成功与否**；而
//! `printErrorMessages` 在 verbose 上下文里无条件打印 `failed command:`（同文件
//! 3198 行）。本仓有多个用例会走 `std.log.warn` 路径（redis / memcache 的超时与
//! 连接池用例），测试运行器又把测试输出整体写往 stderr —— 于是这条"失败报告"
//! 必然出现；没有任何 stderr 输出的 `zig build live-probe-test` 步骤则不出现。
//! 也就是说，该行与「用哪个 `Io` 实例」无关，属工具链的展示口径问题。
//! 详见 `docs/OPEN_ITEMS.md` 第 13 条。
//!
//! ## 何时可以改回全局单例
//!
//! 本文件只是绕开共享，并没有修 std 本身。等上游把 test runner 的协议 stdio
//! 换成一个不与其他用途共享的实例（或 `global_single_threaded` 本身变成线程
//! 安全的）之后，即可删除本文件，把各处的默认值换回
//! `std.Io.Threaded.global_single_threaded.io()`。
//!
//! ## 用法
//!
//! 一句 `default_io.io()` 同时覆盖两种位置：
//!
//! ```zig
//! io: std.Io = default_io.io(),   // 结构体字段默认值：编译期求值
//! const ts = util_time.getCurrTSWithIo(default_io.io());   // 运行期
//! ```
//!
//! 前者可行是因为 [`io()`] 用 `@inComptime()` 分流：编译期直接返回句柄，
//! 运行期才走懒初始化。宿主仍可用 `.io = <自己的 Io>` 注入 —— 字段类型与语义
//! 都没变，变的只是默认值从 std 的全局单例换成了本仓的进程级实例。

const std = @import("std");

const Threaded = std.Io.Threaded;

/// 进程级实例本体。
///
/// 编译期即以 `init_single_threaded` 形态存在 —— 也就是说，**在首次运行期调用
/// [`io()`] 之前**它已经完全可用（零分配、不安装信号处理器，与历史上的
/// `global_single_threaded` 默认行为一致），只是还没有线程池。
///
/// 生命周期 = 进程生命周期，**永不 deinit**（与 std 的全局单例同构）。
var instance: Threaded = .init_single_threaded;

/// 编译期即可求值的 `Io` 句柄：`std.Io` 就是 `{ userdata, vtable }`，
/// `userdata` 是上面那个全局实例的地址，二者都是常量。
///
/// 与 [`io()`] 运行期返回的句柄**是同一实例、同一 vtable**（升级前后都成立）。
const handle: std.Io = instance.io();

/// 懒初始化状态机（`pending` → `initializing` → `ready`）。
///
/// 用裸原子 + 自旋而不是 `std.Io.Mutex`：后者需要一个可用的 `Io` 才能等待 /
/// 唤醒，而这里的目标恰恰是造出第一个 `Io`，属鸡生蛋。本工具链也没有
/// `std.once` / `std.Thread.Once` 可用（`std/` 下无 `once.zig`，`std.Thread`
/// 只导出 spawn/yield 一组 API，没有 once）。冷路径一次性，自旋可接受。
const pending: u8 = 0;
const initializing: u8 = 1;
const ready: u8 = 2;
var state: std.atomic.Value(u8) = .init(pending);

/// 取进程级 `Io` 句柄。
///
/// * **运行期**：首次调用把 `instance` 就地升级为完整 `Threaded`
///   （`std.heap.page_allocator`：进程生命周期，避免与 `std.testing.allocator`
///   的泄漏检测纠缠），此后每次只做一次原子读。
/// * **编译期**（结构体字段默认值必须在 comptime 求值）：直接返回 `handle`，
///   跳过状态机 —— 懒初始化是运行期概念，编译期既无并发也无需分配。
pub fn io() std.Io {
    if (!@inComptime()) ensureInit();
    return handle;
}

/// 运行期的懒初始化分派（`@inComptime()` 为真时本函数根本不会被分析）。
fn ensureInit() void {
    switch (state.load(.acquire)) {
        ready => {},
        initializing => waitReady(),
        pending => initOnce(),
        else => unreachable,
    }
}

/// 兜底自旋：另一个线程正在初始化，等它置位 `ready`。
fn waitReady() void {
    while (state.load(.acquire) != ready) std.atomic.spinLoopHint();
}

fn initOnce() void {
    if (state.cmpxchgStrong(pending, initializing, .acquire, .monotonic) != null) {
        // 竞争失败：另一个线程已经在初始化（或已完成），等它。
        waitReady();
        return;
    }
    instance = Threaded.init(std.heap.page_allocator, .{});
    state.store(ready, .release);
}

test "default_io：结构体字段默认值位置可编译期求值，且与 io() 同实例同 vtable" {
    const Holder = struct { io: std.Io = io() };
    const holder: Holder = .{};
    try std.testing.expect(holder.io.userdata != null);
    try std.testing.expectEqual(handle.userdata, holder.io.userdata);
    try std.testing.expectEqual(handle.userdata, io().userdata);
    try std.testing.expectEqual(handle.vtable, io().vtable);
}

test "default_io：io() 的实例真的能用（实时钟读数 + OS 随机熵源）" {
    const inst = io();
    const ts = std.Io.Clock.now(.real, inst);
    // 2020-01-01 之后的墙钟时间；只证明时钟路径可用，不做精确断言。
    try std.testing.expect(ts.toSeconds() > 1_577_836_800);
    var bytes: [16]u8 = undefined;
    inst.random(&bytes);
}

test "default_io：多线程并发取用返回同一个实例" {
    const N = 4;
    var handles: [N]std.Io = undefined;
    var threads: [N]std.Thread = undefined;
    const Runner = struct {
        fn run(out: *std.Io) void {
            out.* = io();
        }
    };
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Runner.run, .{&handles[i]});
    }
    for (threads) |t| t.join();
    for (handles) |h| {
        try std.testing.expectEqual(handle.userdata, h.userdata);
    }
}
