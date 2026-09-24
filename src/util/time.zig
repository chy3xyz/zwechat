// SPDX-License-Identifier: Apache-2.0
//! util/time — 时间工具
//!
//! 对应 `_ref/wechat/util/time.go`：提供 `GetCurrTS`（当前 Unix 秒）。
//! 微信服务端要求 timestamp 是秒级 Unix 时间戳，故只暴露取秒函数。
//!
//! `getCurrTSWithIo(io)` 是推荐入口（宿主注入 `Io`）；`getCurrTS()` 保留为
//! 等价的默认实现，行为与历史版本一致。

const std = @import("std");

/// 返回当前 Unix 秒（等价于 Go 的 `time.Now().Unix()`）。
///
/// **deprecated**：库代码应当接受 `Io` 参数，而不是自行访问全局单例
/// （见 `std/Io/Threaded.zig` 中 `global_single_threaded` 的说明）。请改用
/// [`getCurrTSWithIo`]；本函数保留为等价的默认实现，行为不变。
pub fn getCurrTS() i64 {
    return getCurrTSWithIo(std.Io.Threaded.global_single_threaded.io());
}

/// 返回当前 Unix 秒，由调用方注入驱动时钟的 `Io`。
///
/// 在 Zig 0.17-dev 里 `std.time.timestamp()` 已被移除，改走 `std.Io.Clock.now(.real, ...)`。
pub fn getCurrTSWithIo(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toSeconds();
}

test "getCurrTS 返回正整数" {
    try std.testing.expect(getCurrTS() > 0);
}

test "getCurrTSWithIo 与 Io.Clock.now 偏差不超过 2 秒" {
    const io = std.testing.io;
    const a = getCurrTSWithIo(io);
    const b = std.Io.Clock.now(.real, io).toSeconds();
    const diff = if (a > b) a - b else b - a;
    try std.testing.expect(diff <= 2);
}

test "getCurrTS 与 getCurrTSWithIo 走同一条取时路径" {
    // 旧函数委托到 `global_single_threaded`，与注入同一实例的结果应完全一致
    // （同一秒内调用；跨秒只会差 1）。
    const io = std.Io.Threaded.global_single_threaded.io();
    const diff = getCurrTS() - getCurrTSWithIo(io);
    try std.testing.expect(diff >= -1 and diff <= 1);
}
