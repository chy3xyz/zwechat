//! util/time — 时间工具
//!
//! 对应 `_ref/wechat/util/time.go`：仅提供 `GetCurrTS`（当前 Unix 秒）。
//! 微信服务端要求 timestamp 是秒级 Unix 时间戳，故只暴露一个简单函数。

const std = @import("std");

/// 返回当前 Unix 秒（等价于 Go 的 `time.Now().Unix()`）。
///
/// 在 Zig 0.17-dev 里 `std.time.timestamp()` 已被移除，改走 `std.Io.Clock.now(.real, ...)`。
pub fn getCurrTS() i64 {
    return std.Io.Clock.now(.real, std.Options.debug_io).toSeconds();
}

test "getCurrTS 返回正整数" {
    try std.testing.expect(getCurrTS() > 0);
}

test "getCurrTS 与 Io.Clock.now 偏差不超过 2 秒" {
    const a = getCurrTS();
    const b = std.Io.Clock.now(.real, std.Options.debug_io).toSeconds();
    const diff = if (a > b) a - b else b - a;
    try std.testing.expect(diff <= 2);
}