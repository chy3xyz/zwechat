//! zwechat — CLI 示例入口
//!
//! 当前阶段仅打印版本号并演示如何构造顶层 Wechat 实例。
//! 后续阶段将加入真实的业务命令（公众号消息推送、支付下单等）。

const std = @import("std");
const zwechat = @import("root.zig");

pub fn main() void {
    std.debug.print("zwechat v{s}\n", .{zwechat.version});
    std.debug.print("cache          : {s}\n", .{@typeName(zwechat.cache)});
    std.debug.print("credential     : {s}\n", .{@typeName(zwechat.credential)});
    std.debug.print("util           : {s}\n", .{@typeName(zwechat.util)});
    std.debug.print("officialaccount: {s}\n", .{@typeName(zwechat.officialaccount)});
}