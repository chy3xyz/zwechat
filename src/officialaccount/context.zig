//! officialaccount/context — 公众号调用上下文
//!
//! 对应 `_ref/wechat/officialaccount/context/context.go` 的 `Context`：
//! 持有 `Config` 与 `AccessTokenHandle`，作为公众号 API 的运行时入口。
//! 行为上模拟 Go 的 interface embedding——所有 get 操作直接转发给 handle。

const std = @import("std");
const Config = @import("config.zig").Config;
const credential = @import("../credential/mod.zig");

/// 公众号调用上下文。
///
/// 同时持有公众号配置与 `AccessTokenHandle`，是公众号所有子模块
/// （菜单、素材、用户等）共享的运行时状态。
pub const Context = struct {
    /// 公众号配置（不可变引用，调用方持有原 slice 的所有权）。
    config: Config,
    /// access_token 获取句柄（vtable 形式，可热替换为自定义实现）。
    access_token_handle: credential.AccessTokenHandle,

    /// 获取 access_token，委托给 `access_token_handle.getAccessToken`。
    ///
    /// `allocator` 由底层 handle 用于分配返回的 token 切片；
    /// 所有权仍归调用方（handle 负责分配，调用方负责 `allocator.free`）。
    ///
    /// 错误集与 `access_token_handle.getAccessToken` 完全一致。
    pub fn getAccessToken(self: *Context, allocator: std.mem.Allocator) @TypeOf(self.access_token_handle.getAccessToken(allocator)) {
        return self.access_token_handle.getAccessToken(allocator);
    }
};

test "Context 默认配置字段可见" {
    const ctx = Context{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    try std.testing.expectEqualStrings("", ctx.config.app_id);
    try std.testing.expectEqualStrings("", ctx.config.app_secret);
    try std.testing.expectEqualStrings("", ctx.config.token);
    try std.testing.expectEqualStrings("", ctx.config.encoding_aes_key);
    try std.testing.expect(ctx.config.cache == null);
    try std.testing.expect(!ctx.config.use_stable_ak);
    // getAccessToken 的存在性 / 签名在 mod.zig 的 @hasDecl 测试中保证。
}

test "Context 暴露自定义配置" {
    const ctx = Context{
        .config = .{
            .app_id = "wx-ctx-test",
            .app_secret = "ctx-secret",
            .token = "ctx-token",
            .encoding_aes_key = "ctx-aes",
            .use_stable_ak = true,
        },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    try std.testing.expectEqualStrings("wx-ctx-test", ctx.config.app_id);
    try std.testing.expectEqualStrings("ctx-secret", ctx.config.app_secret);
    try std.testing.expectEqualStrings("ctx-token", ctx.config.token);
    try std.testing.expectEqualStrings("ctx-aes", ctx.config.encoding_aes_key);
    try std.testing.expect(ctx.config.use_stable_ak);
}
