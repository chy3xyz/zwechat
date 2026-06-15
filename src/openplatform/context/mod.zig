//! openplatform/context — 开放平台（第三方平台）调用上下文
//!
//! 对应 `_ref/wechat/openplatform/context/context.go` 的 `Context`：
//! 在 Go 中仅嵌入 `*config.Config`，并在其 `accessToken.go` 内挂载一组
//! 与 component 平台有关的 token / preauthcode / authorizer 接口。
//!
//! Zig 版把 token 状态直接放到 Context 内（`access_token: ?[]const u8`），
//! 与上游 Go 端 `GetComponentAccessToken` 行为对齐：先返回缓存值，
//! 未命中时由调用方在收到 `SetComponentAccessToken` 后回填。

const std = @import("std");

const Config = @import("../config.zig").Config;

/// 开放平台（第三方平台）调用上下文。
///
/// 设计要点：
/// - 持有不可变 `Config`（调用方持有原 slice 的所有权）。
/// - `access_token` 字段是"component_access_token"，用于开放平台内部接口
///   （`/cgi-bin/component/*`），与"authorizer_access_token"（被授权方的 token）
///   不是一回事。后者由 `openplatform/miniprogram` 或 `openplatform/officialaccount`
///   模块单独管理。
/// - `setAccessToken` / `getAccessToken` 是最小可用的存取接口，调用方负责
///   在拉取新 token 后调用 `setAccessToken` 回填。
pub const Context = struct {
    /// 开放平台配置（不可变引用）。
    config: Config,
    /// 当前的 component_access_token（`null` 表示尚未获取）。
    access_token: ?[]const u8 = null,

    /// 写入新的 component_access_token。
    ///
    /// 注：本骨架仅做赋值语义；Go 版还会把 token 写进 `cache.Cache`（TTL = expires_in - 1500），
    /// 后续 pass 在引入完整 SetComponentAccessToken 流程时再补齐。
    pub fn setAccessToken(self: *Context, token: []const u8) void {
        self.access_token = token;
    }

    /// 取出当前缓存的 component_access_token。
    ///
    /// 返回 `null` 表示尚未获取过 token。调用方拿到 `null` 后应通过
    /// `SetComponentAccessToken`（后续 pass 实现）从微信服务端拉取并回填。
    pub fn getAccessToken(self: *const Context) ?[]const u8 {
        return self.access_token;
    }

    /// 获取或刷新 component_access_token。
    ///
    /// `verify_ticket` 是微信第三方平台推送的「票据」，每次换取 token 时必填。
    /// 结果会写入 `config.cache`；命中缓存时直接返回。
    pub fn getComponentAccessToken(
        self: *Context,
        allocator: std.mem.Allocator,
        verify_ticket: []const u8,
    ) ![]u8 {
        return @import("access_token.zig").getComponentAccessToken(self, allocator, verify_ticket);
    }
};

test "Context 默认值" {
    const ctx = Context{ .config = .{} };
    try std.testing.expectEqualStrings("", ctx.config.app_id);
    try std.testing.expectEqualStrings("", ctx.config.app_secret);
    try std.testing.expect(ctx.access_token == null);
}

test "Context 自定义配置 + token 存取" {
    var ctx = Context{
        .config = .{
            .app_id = "wx-op-ctx",
            .app_secret = "ctx-secret",
            .token = "ctx-token",
        },
        .access_token = null,
    };
    try std.testing.expectEqualStrings("wx-op-ctx", ctx.config.app_id);
    try std.testing.expect(ctx.getAccessToken() == null);

    ctx.setAccessToken("comp-ak-xyz");
    try std.testing.expect(ctx.getAccessToken() != null);
    try std.testing.expectEqualStrings("comp-ak-xyz", ctx.getAccessToken().?);

    // 覆写语义
    ctx.setAccessToken("comp-ak-rotated");
    try std.testing.expectEqualStrings("comp-ak-rotated", ctx.getAccessToken().?);
}

test "Context.getComponentAccessToken 需要 cache" {
    var ctx = Context{
        .config = .{ .app_id = "wx-op", .app_secret = "s" },
    };
    const result = ctx.getComponentAccessToken(std.testing.allocator, "ticket");
    try std.testing.expectError(error.CacheUnavailable, result);
}
