//! work/context — 企业微信调用上下文
//!
//! 对应 `_ref/wechat/work/context/context.go` 的 `Context`：
//! 持有 `Config` 与 `AccessTokenHandle`，作为企业微信全部子模块
//! （externalcontact / invoice / addresslist / appchat / robot / oauth / jsapi 等）
//! 的运行时入口。
//!
//! 行为上模拟 Go 的 interface embedding——所有 get 操作直接转发给 handle。
//!
//! 与官方账号 `Context` 的差异：
//! - 多了一个可选的 `js_ticket_handle` 字段（用于 JS-SDK 签名）；
//! - 业务字段中包含企业微信特有的 `corp_id` / `corp_secret` / `agent_id` 等。

const std = @import("std");
const Config = @import("../config.zig").Config;
const credential = @import("../../credential/mod.zig");

/// 企业微信调用上下文。
///
/// 同时持有企业微信配置、`AccessTokenHandle` 与可选的 `JsTicketHandle`，
/// 是企业微信所有子模块共享的运行时状态。
pub const Context = struct {
    /// 企业微信配置（不可变引用，调用方持有原 slice 的所有权）。
    config: Config,
    /// access_token 获取句柄（vtable 形式，可热替换为自定义实现）。
    access_token_handle: credential.AccessTokenHandle,
    /// jsapi_ticket 获取句柄（vtable 形式，可选）。
    ///
    /// 留空时由 `Work.getJsTicket` 懒加载一份 `DefaultJsTicket`（cache key prefix
    /// 固定为 `CacheKeyWorkPrefix`）；通常只有 jsapi 子模块需要关心。
    js_ticket_handle: ?credential.JsTicketHandle = null,

    /// 获取 access_token，委托给 `access_token_handle.getAccessToken`。
    ///
    /// `allocator` 由底层 handle 用于分配返回的 token 切片；
    /// 所有权仍归调用方（handle 负责分配，调用方负责 `allocator.free`）。
    ///
    /// 错误集与 `access_token_handle.getAccessToken` 完全一致。
    pub fn getAccessToken(
        self: *Context,
        allocator: std.mem.Allocator,
    ) @TypeOf(self.access_token_handle.getAccessToken(allocator)) {
        return self.access_token_handle.getAccessToken(allocator);
    }

    /// 获取 jsapi_ticket，委托给 `js_ticket_handle.getTicket`。
    ///
    /// 当 `js_ticket_handle == null` 时返回 `error.JsTicketHandleNotSet`，
    /// 由上层 `Work.getJsTicket` 在调用此方法前决定是否懒加载。
    pub fn getJsTicket(
        self: *Context,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) ![]u8 {
        const handle = self.js_ticket_handle orelse return error.JsTicketHandleNotSet;
        return handle.getTicket(allocator, access_token);
    }
};

test "Context 默认配置字段可见" {
    const ctx = Context{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    try std.testing.expectEqualStrings("", ctx.config.corp_id);
    try std.testing.expectEqualStrings("", ctx.config.corp_secret);
    try std.testing.expectEqualStrings("", ctx.config.agent_id);
    try std.testing.expect(ctx.config.cache == null);
    // 默认未设置 js_ticket_handle。
    try std.testing.expect(ctx.js_ticket_handle == null);
    // getAccessToken / getJsTicket 的存在性在 mod.zig 的 @hasDecl 测试中保证。
}

test "Context 暴露自定义配置" {
    const ctx = Context{
        .config = .{
            .corp_id = "ww-ctx-test",
            .corp_secret = "ctx-secret",
            .agent_id = "1000003",
            .token = "ctx-token",
            .encoding_aes_key = "ctx-aes",
        },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    try std.testing.expectEqualStrings("ww-ctx-test", ctx.config.corp_id);
    try std.testing.expectEqualStrings("ctx-secret", ctx.config.corp_secret);
    try std.testing.expectEqualStrings("1000003", ctx.config.agent_id);
    try std.testing.expectEqualStrings("ctx-token", ctx.config.token);
    try std.testing.expectEqualStrings("ctx-aes", ctx.config.encoding_aes_key);
}

test "Context 暴露自定义 js_ticket_handle" {
    const ctx = Context{
        .config = .{ .corp_id = "ww-js" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
        .js_ticket_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    try std.testing.expect(ctx.js_ticket_handle != null);
}

test "Context.getJsTicket handle 为空时返回 JsTicketHandleNotSet" {
    var ctx = Context{
        .config = .{ .corp_id = "ww-no-ticket" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
        // js_ticket_handle 留空
    };
    const result = ctx.getJsTicket(std.testing.allocator, "any_ak");
    try std.testing.expectError(error.JsTicketHandleNotSet, result);
}