//! openplatform/miniprogram — 代小程序实现业务（骨架）
//!
//! 对应 `_ref/wechat/openplatform/miniprogram/`：在 Go SDK 中聚合
//! `miniprogram.MiniProgram`（小程序业务）并把 `access_token` 句柄替换为
//! `DefaultAuthrAccessToken`（从开放平台的角度拿"被授权方"的 token）。
//!
//! 当前 Zig 骨架仅持有 `app_id` 与 `openContext`，便于上层在
//! `OpenPlatform.getMiniProgram(...)` 之后按需 `getContext()` 取回 ctx；
//! 子模块（basic / component / urllink / rtc / membercard 等）的实现
//! 在后续 pass 中以 `GetXxx()` 懒加载入口的形式补齐。

const std = @import("std");

const Context = @import("../context/mod.zig").Context;

/// 代小程序业务入口（骨架）。
///
/// 设计说明：
/// - 字段名 `app_id` 与 Go 端 `MiniProgram.AppID` 一致（小写转 snake_case）。
/// - `open_context` 复用上层 `OpenPlatform.ctx`（与 Go 嵌入语义等价）。
/// - 当前未持有 `*miniprogram.MiniProgram` 字段——避免在未实现子模块时
///   强引用尚未落地的业务类型。后续 pass 在引入 `minigame/minigame` 业务
///   层后补齐。
pub const OpenMiniProgram = struct {
    /// 被代运营的小程序 AppID。
    app_id: []const u8,
    /// 复用上层开放平台 ctx。
    open_context: *Context,

    const Self = @This();

    /// 构造代小程序实例。
    pub fn init(open_context: *Context, app_id: []const u8) Self {
        return .{ .app_id = app_id, .open_context = open_context };
    }

    /// 暴露内部 ctx 指针（与 Go 端 `GetContext` 语义一致），方便子模块读取配置 / token。
    pub fn getContext(self: *Self) *Context {
        return self.open_context;
    }
};

test "OpenMiniProgram.init 持有 app_id 与 ctx" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op-mp" } };
    var omp = OpenMiniProgram.init(&ctx, "wx-mp-authorized");

    try std.testing.expectEqualStrings("wx-mp-authorized", omp.app_id);
    try std.testing.expectEqual(@intFromPtr(&ctx), @intFromPtr(omp.open_context));
    try std.testing.expectEqual(@intFromPtr(&ctx), @intFromPtr(omp.getContext()));
}

test "OpenMiniProgram 默认 app_id 兼容空字符串" {
    var ctx: Context = .{ .config = .{} };
    const omp = OpenMiniProgram.init(&ctx, "");
    try std.testing.expectEqualStrings("", omp.app_id);
}
