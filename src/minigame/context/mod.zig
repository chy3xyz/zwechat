// SPDX-License-Identifier: Apache-2.0
//! minigame/context — 微信小游戏调用上下文
//!
//! 对应 `_ref/wechat/minigame/`：上游 Go 侧仅有 README；本 Zig 落地
//! 按"小游戏业务 = 小程序业务的子集"思路，对齐 `miniprogram/context.Context` 形态：
//! 持有 `Config` + `AccessTokenHandle`，提供 `getAccessToken` 透传。
//!
//! 上层在 `MiniGame.init` 时把已构造好的 `AccessTokenHandle` 注入即可；
//! 子模块（消息推送、用户信息、客服等）在后续 pass 中按需 `getContext()` 取回。

const std = @import("std");

const Config = @import("../config.zig").Config;
const credential = @import("../../credential/mod.zig");

/// 微信小游戏调用上下文。
///
/// 与 `miniprogram.Context` 形态一致：持有 `Config` 与 `AccessTokenHandle`，
/// 是小游戏所有子模块共享的运行时状态。
pub const Context = struct {
    /// 小游戏配置（不可变引用）。
    config: Config,
    /// access_token 获取句柄（vtable 形式，可热替换为自定义实现）。
    access_token_handle: credential.AccessTokenHandle,

    /// 获取 access_token，委托给 `access_token_handle.getAccessToken`。
    ///
    /// 错误集合与 `access_token_handle.getAccessToken` 完全一致。
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
    try std.testing.expect(ctx.config.cache == null);
}

test "Context 自定义配置" {
    const ctx = Context{
        .config = .{
            .app_id = "wx-mg-ctx",
            .app_secret = "mg-ctx-secret",
        },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    try std.testing.expectEqualStrings("wx-mg-ctx", ctx.config.app_id);
    try std.testing.expectEqualStrings("mg-ctx-secret", ctx.config.app_secret);
}

// ──────────────────────────────────────────────────────────────────────────────
// getAccessToken 透传（此前零调用）
// ──────────────────────────────────────────────────────────────────────────────

/// 固定响应的 fetcher 桩（不经网络）。
fn stubMinigameFetcher(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) credential.CredentialError![]u8 {
    return allocator.dupe(u8, "{\"access_token\":\"minigame_tok\",\"expires_in\":7200}");
}

/// 直接失败的 fetcher 桩，用于验证错误透传。
fn failingMinigameFetcher(_: *anyopaque, _: std.mem.Allocator, _: []const u8) credential.CredentialError![]u8 {
    return credential.CredentialError.HttpError;
}

test "Context.getAccessToken 透传到 access_token_handle 并返回 token（真实 DefaultAccessToken + 桩 fetcher）" {
    const allocator = std.testing.allocator;
    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var dat = credential.DefaultAccessToken.initWithFetcher(
        "wx-mg",
        "secret",
        credential.CacheKeyMiniProgramPrefix,
        memory.asCache(),
        stubMinigameFetcher,
        undefined,
    );

    var ctx = Context{
        .config = .{ .app_id = "wx-mg", .cache = memory.asCache() },
        .access_token_handle = dat.asHandle(),
    };

    const tok = try ctx.getAccessToken(allocator);
    defer allocator.free(tok);
    try std.testing.expectEqualStrings("minigame_tok", tok);

    // 二级调用命中 DefaultAccessToken 的缓存（同一 handle，不再回源）。
    const tok2 = try ctx.getAccessToken(allocator);
    defer allocator.free(tok2);
    try std.testing.expectEqualStrings("minigame_tok", tok2);
}

test "Context.getAccessToken 透传 handle 的错误" {
    const allocator = std.testing.allocator;
    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var dat = credential.DefaultAccessToken.initWithFetcher(
        "wx-mg-fail",
        "secret",
        credential.CacheKeyMiniProgramPrefix,
        memory.asCache(),
        failingMinigameFetcher,
        undefined,
    );

    var ctx = Context{
        .config = .{ .app_id = "wx-mg-fail", .cache = memory.asCache() },
        .access_token_handle = dat.asHandle(),
    };

    try std.testing.expectError(credential.CredentialError.HttpError, ctx.getAccessToken(allocator));
}
