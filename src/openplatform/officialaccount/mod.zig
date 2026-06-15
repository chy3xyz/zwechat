//! openplatform/officialaccount — 代公众号实现业务（骨架）
//!
//! 对应 `_ref/wechat/openplatform/officialaccount/`：在 Go SDK 中聚合
//! `officialaccount.OfficialAccount`（公众号业务）并把 `access_token` 句柄
//! 替换为 `DefaultAuthrAccessToken`，使得所有公众号子模块（js / oauth 等）
//! 在"代公众号"语境下也能正常工作。
//!
//! 当前 Zig 骨架仅持有 `app_id` 与 `openContext`，便于上层在
//! `OpenPlatform.getOfficialAccount(...)` 之后按需 `getContext()` 取回 ctx；
//! 子模块（oauth / js）的实现以 `GetXxx()` 懒加载入口的形式在后续 pass 补齐。

const std = @import("std");

const Context = @import("../context/mod.zig").Context;

/// 代公众号业务入口（骨架）。
///
/// 设计说明：
/// - `app_id` — 被代运营的公众号 AppID（非开放平台第三方平台 AppID）。
/// - `open_context` — 复用上层 `OpenPlatform.ctx`（与 Go 嵌入语义等价）。
pub const OpenOfficialAccount = struct {
    /// 被代运营的公众号 AppID。
    app_id: []const u8,
    /// 复用上层开放平台 ctx。
    open_context: *Context,

    const Self = @This();

    /// 构造代公众号实例。
    pub fn init(open_context: *Context, app_id: []const u8) Self {
        return .{ .app_id = app_id, .open_context = open_context };
    }

    /// 暴露内部 ctx 指针（与 Go 端 `GetContext` 语义一致），方便子模块读取配置 / token。
    pub fn getContext(self: *Self) *Context {
        return self.open_context;
    }
};

test "OpenOfficialAccount.init 持有 app_id 与 ctx" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op-oa" } };
    var ooa = OpenOfficialAccount.init(&ctx, "wx-oa-authorized");

    try std.testing.expectEqualStrings("wx-oa-authorized", ooa.app_id);
    try std.testing.expectEqual(@intFromPtr(&ctx), @intFromPtr(ooa.open_context));
    try std.testing.expectEqual(@intFromPtr(&ctx), @intFromPtr(ooa.getContext()));
}

test "OpenOfficialAccount 默认 app_id 兼容空字符串" {
    var ctx: Context = .{ .config = .{} };
    const ooa = OpenOfficialAccount.init(&ctx, "");
    try std.testing.expectEqualStrings("", ooa.app_id);
}
