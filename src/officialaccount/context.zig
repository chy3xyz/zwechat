// SPDX-License-Identifier: Apache-2.0
//! officialaccount/context — 公众号调用上下文
//!
//! 对应 `_ref/wechat/officialaccount/context/context.go` 的 `Context`：
//! 持有 `Config` 与 `AccessTokenHandle`，作为公众号 API 的运行时入口。
//! 行为上模拟 Go 的 interface embedding——所有 get 操作直接转发给 handle。
//!
//! 业务模块不应自己写「token 失效重试」，而是把发送逻辑包成一个 `sender`
//! 交给 `util/retry.callApi`——它负责「识别 40001 → 作废缓存 → 取新 token →
//! **只重试一次**」（见本文件末尾测试的完整用法）。

const std = @import("std");
const Config = @import("config.zig").Config;
const credential = @import("../credential/mod.zig");
const retry = @import("../util/retry.zig");

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

    /// 作废缓存的 access_token，使下一次 `getAccessToken` 必须回源。
    ///
    /// 转发给 `access_token_handle.invalidateAccessToken`；注入的 handle 未提供
    /// `invalidate` 钩子时返回 `error.InvalidateNotSupported`。
    /// 业务模块通常不直接调用，而是走 `util/retry.callApi` 的失效恢复链路。
    pub fn invalidateAccessToken(self: *Context, allocator: std.mem.Allocator) anyerror!void {
        return self.access_token_handle.invalidateAccessToken(allocator);
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

/// 假凭据 handle：缓存一个 token，支持作废（用于验证 Context 转发与 retry 链路）。
const StubToken = struct {
    cached: ?[]const u8 = "token_v1",
    fetches: usize = 0,
    invalidates: usize = 0,

    fn getAccessToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *StubToken = @ptrCast(@alignCast(ptr));
        if (self.cached) |token| return allocator.dupe(u8, token);
        self.fetches += 1;
        // 首次回源发 token_v2（v1 代表「已被作废的旧 token」）。
        self.cached = if (self.fetches == 1) "token_v2" else "token_v3";
        return allocator.dupe(u8, self.cached.?);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *StubToken = @ptrCast(@alignCast(ptr));
        self.invalidates += 1;
        self.cached = null;
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getAccessToken,
        .invalidate = invalidate,
    };
};

test "Context.invalidateAccessToken 转发到 handle，且未实现时返回 InvalidateNotSupported" {
    const allocator = std.testing.allocator;

    var stub = StubToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-ctx-invalidate" },
        .access_token_handle = .{ .ptr = @ptrCast(&stub), .vtable = &StubToken.vtable },
    };

    try ctx.invalidateAccessToken(allocator);
    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expect(stub.cached == null);

    // 只实现 getAccessToken 的旧式 handle：作废请求明确报「不支持」，不静默成功。
    const legacy_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getAccessToken };
    var legacy_ctx = Context{
        .config = .{ .app_id = "wx-ctx-legacy" },
        .access_token_handle = .{ .ptr = @ptrCast(&stub), .vtable = &legacy_vtable },
    };
    try std.testing.expectError(error.InvalidateNotSupported, legacy_ctx.invalidateAccessToken(allocator));
}

/// retry 链路里 sender 的共享状态：记录收到的 token（token 由 callApi 释放，必须复制）。
const SenderState = struct {
    calls: usize = 0,
    token_buf: [2][16]u8 = @splat(@splat(0)),
    token_len: [2]usize = .{ 0, 0 },

    fn tokenAt(self: *const SenderState, idx: usize) []const u8 {
        return self.token_buf[idx][0..self.token_len[idx]];
    }
};

/// 记录型 sender：第一次返回 `first_response`，之后返回 `ok_response`。
/// 真正的业务模块在这里复用自己模块的发送逻辑（含 transport 注入）。
const RecordingSender = struct {
    state: *SenderState,
    first_response: []const u8,
    ok_response: []const u8,

    pub fn send(self: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const st = self.state;
        if (st.calls < st.token_buf.len and token.len <= st.token_buf[0].len) {
            std.mem.copyForwards(u8, st.token_buf[st.calls][0..token.len], token);
            st.token_len[st.calls] = token.len;
        }
        const first = st.calls == 0;
        st.calls += 1;
        return allocator.dupe(u8, if (first) self.first_response else self.ok_response);
    }
};

test "Context + util/retry.callApi: 40001 → 作废 handle → 换新 token 重试成功" {
    const allocator = std.testing.allocator;

    const token_invalid_body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}";
    const ok_body = "{\"errcode\":0,\"errmsg\":\"ok\"}";

    var stub = StubToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-ctx-retry" },
        .access_token_handle = .{ .ptr = @ptrCast(&stub), .vtable = &StubToken.vtable },
    };

    var state = SenderState{};
    const body = try retry.callApi(&ctx, allocator, "GetThing", RecordingSender{
        .state = &state,
        .first_response = token_invalid_body,
        .ok_response = ok_body,
    });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(ok_body, body);
    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expectEqualStrings("token_v1", state.tokenAt(0));
    try std.testing.expectEqualStrings("token_v2", state.tokenAt(1));
}

test "Context + util/retry.callApi: 真实 DefaultAccessToken + Memory 缓存端到端（作废后真回源取新 token）" {
    const allocator = std.testing.allocator;
    const cache_mod = @import("../cache/mod.zig");
    const DefaultAccessToken = @import("../credential/default_access_token.zig").DefaultAccessToken;

    const token_invalid_body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}";
    const ok_body = "{\"errcode\":0,\"errmsg\":\"ok\"}";

    const mem = try cache_mod.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    // 假 fetcher：第一次回源给 oa_token_a，第二次给 oa_token_b（模拟微信换发新 token）。
    const FetchState = struct {
        calls: usize = 0,

        fn fetch(ptr: *anyopaque, alloc: std.mem.Allocator, url: []const u8) credential.CredentialError![]u8 {
            _ = url;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return alloc.dupe(u8, if (self.calls == 1)
                "{\"access_token\":\"oa_token_a\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}"
            else
                "{\"access_token\":\"oa_token_b\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}");
        }
    };
    var fetch_state = FetchState{};

    var token_provider = DefaultAccessToken.initWithFetcher(
        "wx-e2e",
        "secret",
        credential.CacheKeyOfficialAccountPrefix,
        mem.asCache(),
        FetchState.fetch,
        @ptrCast(&fetch_state),
    );
    var ctx = Context{
        .config = .{ .app_id = "wx-e2e" },
        .access_token_handle = token_provider.asHandle(),
    };

    var state = SenderState{};
    const body = try retry.callApi(&ctx, allocator, "GetThing", RecordingSender{
        .state = &state,
        .first_response = token_invalid_body,
        .ok_response = ok_body,
    });
    defer allocator.free(body);

    // 端到端：第一次用缓存里的 oa_token_a 失败 → 真作废缓存 → 真回源拿到 oa_token_b。
    try std.testing.expectEqualStrings(ok_body, body);
    try std.testing.expectEqual(@as(usize, 2), fetch_state.calls);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expectEqualStrings("oa_token_a", state.tokenAt(0));
    try std.testing.expectEqualStrings("oa_token_b", state.tokenAt(1));

    // 缓存 key 命名与真实实现一致，且被重试链路回写成新 token。
    const key = credential.CacheKeyOfficialAccountPrefix ++ "_access_token_wx-e2e";
    const cached = (try mem.asCache().get(key)).?;
    try std.testing.expectEqualStrings("oa_token_b", cached);
}
