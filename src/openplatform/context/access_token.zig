// SPDX-License-Identifier: Apache-2.0
//! openplatform/context/access_token — component / authorizer token 获取与缓存
//!
//! 对应 `_ref/wechat/openplatform/context/accessToken.go`：
//! - `getComponentAccessToken` — 用 `component_verify_ticket` 换取
//!   `component_access_token`，缓存 key `openplatform_component_access_token_{app_id}`；
//! - `getAuthrAccessToken` / `refreshAuthrAccessToken` — 按 `authorizer_appid`
//!   缓存 / 刷新被授权方的 `authorizer_access_token`，对照 Go 端
//!   `GetAuthrAccessTokenContext` / `RefreshAuthrTokenContext`。

const std = @import("std");
const Context = @import("mod.zig").Context;
const cache_mod = @import("../../cache/mod.zig");
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Error = error{
    VerifyTicketRequired,
    CacheUnavailable,
    AuthorizerAppidRequired,
    RefreshTokenRequired,
} || util_error.WechatError || cache_mod.CacheError || std.mem.Allocator.Error;

/// component token 接口 URL。
const componentAccessTokenURL = "https://api.weixin.qq.com/cgi-bin/component/api_component_token";

/// 刷新 authorizer token 接口 URL（`{s}` 为 component_access_token）。
const refreshAuthrTokenURL = "https://api.weixin.qq.com/cgi-bin/component/api_authorizer_token?component_access_token={s}";

const TokenResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    component_access_token: []const u8 = "",
    expires_in: i64 = 0,
};

/// 被授权方（公众号 / 小程序）的接口调用凭据。
///
/// 对照 Go 端 `AuthrAccessToken`：刷新接口会同时返回新的
/// `authorizer_access_token` 与 `authorizer_refresh_token`（后者可能轮换，
/// 调用方 / 缓存必须回存新值）。
pub const AuthrAccessToken = struct {
    /// 被授权方 AppID（`authorizer_appid`）。
    appid: []const u8 = "",
    /// 新的 authorizer_access_token（`authorizer_access_token`）。
    access_token: []u8,
    /// 有效期（秒，`expires_in`）。
    expires_in: i64 = 0,
    /// 新的 authorizer_refresh_token（`authorizer_refresh_token`）。
    refresh_token: []u8,

    /// 释放 `access_token` / `refresh_token` 两个持有切片。
    pub fn deinit(self: *AuthrAccessToken, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
    }
};

/// 统一的 POST JSON 出口：注入 transport 时走临时 client（测试），
/// 否则走线程局部默认 client（生产）。
fn postJSON(
    ctx: *Context,
    allocator: std.mem.Allocator,
    uri: []const u8,
    payload: []const u8,
) Error![]u8 {
    if (ctx.transport) |t| {
        const tctx = ctx.transport_ctx orelse
            @panic("Context.transport 已设置但 transport_ctx 为空：请同时传入两者");
        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        client.setTransport(t, tctx);
        return client.postJSON(uri, payload) catch return util_error.WechatError.NetworkError;
    }
    const client = util_http.getDefaultClient(allocator);
    return client.postJSON(uri, payload) catch return util_error.WechatError.NetworkError;
}

/// 获取 component_access_token。
///
/// 1. 以 `openplatform_component_access_token_{app_id}` 为 key 查缓存；
/// 2. 未命中时持 `ctx.token_mutex` 锁内双检，仍 miss 则调用
///    `api_component_token` 回源并回写缓存（TTL 7000 秒，预留 200 秒缓冲）。
///
/// 返回的 token 由调用方负责 `allocator.free`。
pub fn getComponentAccessToken(
    ctx: *Context,
    allocator: std.mem.Allocator,
    verify_ticket: []const u8,
) Error![]u8 {
    if (verify_ticket.len == 0) return error.VerifyTicketRequired;
    const cache_inst = ctx.config.cache orelse return error.CacheUnavailable;

    // verify_ticket 可能借用自缓存 get（Memcache/Redis 后端下一次 get 即失效），
    // 锁内双检会再触发 cache get，这里先复制为自有切片。
    const ticket_owned = try allocator.dupe(u8, verify_ticket);
    defer allocator.free(ticket_owned);

    const cache_key = try std.fmt.allocPrint(
        allocator,
        "openplatform_component_access_token_{s}",
        .{ctx.config.app_id},
    );
    defer allocator.free(cache_key);

    if (try cache_inst.get(cache_key)) |cached| {
        return allocator.dupe(u8, cached);
    }

    ctx.token_mutex.lock();
    defer ctx.token_mutex.unlock();
    return getComponentAccessTokenLocked(ctx, allocator, ticket_owned, cache_key);
}

/// `getComponentAccessToken` 的锁内实现：调用方必须已持有 `ctx.token_mutex`。
/// 先锁内双检缓存，仍 miss 才回源 + 回写。
fn getComponentAccessTokenLocked(
    ctx: *Context,
    allocator: std.mem.Allocator,
    verify_ticket: []const u8,
    cache_key: []const u8,
) Error![]u8 {
    const cache_inst = ctx.config.cache orelse return error.CacheUnavailable;

    // 锁内双检：等待锁期间其他线程可能已回源并回写。
    if (try cache_inst.get(cache_key)) |cached| {
        return allocator.dupe(u8, cached);
    }

    const client_body = try std.fmt.allocPrint(
        allocator,
        "{{\"component_appid\":\"{s}\",\"component_appsecret\":\"{s}\",\"component_verify_ticket\":\"{s}\"}}",
        .{ ctx.config.app_id, ctx.config.app_secret, verify_ticket },
    );
    defer allocator.free(client_body);

    const resp = try postJSON(ctx, allocator, componentAccessTokenURL, client_body);
    defer allocator.free(resp);

    var parsed = std.json.parseFromSlice(TokenResponse, allocator, resp, .{ .ignore_unknown_fields = true }) catch {
        return util_error.WechatError.DecodeError;
    };
    defer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    if (parsed.value.component_access_token.len == 0) return util_error.WechatError.ApiError;

    const token = try allocator.dupe(u8, parsed.value.component_access_token);
    errdefer allocator.free(token);
    try cache_inst.set(cache_key, token, 7000);
    return token;
}

test "component token helper 需要 verify_ticket" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    const result = getComponentAccessToken(&ctx, std.testing.allocator, "");
    try std.testing.expectError(error.VerifyTicketRequired, result);
}

// ──────────────────────────────────────────────────────────────────────────────
// authorizer_access_token 获取与刷新（对照 Go `GetAuthrAccessToken` / `RefreshAuthrToken`）
// ──────────────────────────────────────────────────────────────────────────────

/// 刷新接口的响应体（字段名与微信接口一致）。
const AuthrTokenResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    authorizer_appid: []const u8 = "",
    authorizer_access_token: []const u8 = "",
    expires_in: i64 = 0,
    authorizer_refresh_token: []const u8 = "",
};

/// authorizer_access_token 缓存 key（对照 Go `authorizer_access_token_{appid}`）。
fn authrTokenKey(allocator: std.mem.Allocator, appid: []const u8) Error![]u8 {
    return std.fmt.allocPrint(allocator, "authorizer_access_token_{s}", .{appid});
}

/// authorizer_refresh_token 缓存 key（对照 Go `authorizer_refresh_token_{appid}`）。
fn authrRefreshKey(allocator: std.mem.Allocator, appid: []const u8) Error![]u8 {
    return std.fmt.allocPrint(allocator, "authorizer_refresh_token_{s}", .{appid});
}

/// 获取被授权方的 authorizer_access_token。
///
/// 1. 缓存命中直接返回；
/// 2. 未命中时持 `ctx.token_mutex` 锁内双检，仍 miss 则读
///    `authorizer_refresh_token_{appid}` 缓存并调 `refreshAuthrAccessToken` 回源。
///
/// 持锁跨 HTTP 是刻意的：authorizer 刷新会轮换 refresh_token，
/// 并发刷新互相覆盖会丢失凭据（见 `Context.token_mutex` 注释）。
///
/// 返回的 token 由调用方负责 `allocator.free`。
pub fn getAuthrAccessToken(
    ctx: *Context,
    allocator: std.mem.Allocator,
    authorizer_appid: []const u8,
) Error![]u8 {
    if (authorizer_appid.len == 0) return error.AuthorizerAppidRequired;
    const cache_inst = ctx.config.cache orelse return error.CacheUnavailable;

    const key = try authrTokenKey(allocator, authorizer_appid);
    defer allocator.free(key);

    if (try cache_inst.get(key)) |cached| {
        if (cached.len > 0) return allocator.dupe(u8, cached);
    }

    ctx.token_mutex.lock();
    defer ctx.token_mutex.unlock();

    // 锁内双检：等待锁期间其他线程可能已回源并回写。
    if (try cache_inst.get(key)) |cached| {
        if (cached.len > 0) return allocator.dupe(u8, cached);
    }

    const rkey = try authrRefreshKey(allocator, authorizer_appid);
    defer allocator.free(rkey);

    // cache.get 返回借用切片（Memcache/Redis 后端下一次 get 会 free 并覆盖
    // last_value），而 refreshAuthrAccessTokenLocked 内部还会 get component
    // token —— 必须立即 dupe，否则 refresh 切片悬垂（UAF）。
    const refresh_borrowed = (try cache_inst.get(rkey)) orelse return error.RefreshTokenRequired;
    const refresh = try allocator.dupe(u8, refresh_borrowed);
    defer allocator.free(refresh);

    var token = try refreshAuthrAccessTokenLocked(ctx, allocator, "", authorizer_appid, refresh);
    defer token.deinit(allocator);
    return allocator.dupe(u8, token.access_token);
}

/// 读取缓存中的 component_access_token（不发起网络请求）。
///
/// 对照 Go 端 `GetComponentAccessTokenContext`（仅读缓存）；缓存未命中返回
/// `error.VerifyTicketRequired`，调用方应带 `verify_ticket` 调
/// `getComponentAccessToken` 回源后再试。
pub fn getCachedComponentAccessToken(ctx: *Context, allocator: std.mem.Allocator) Error![]u8 {
    const cache_inst = ctx.config.cache orelse return error.CacheUnavailable;
    const cache_key = try std.fmt.allocPrint(
        allocator,
        "openplatform_component_access_token_{s}",
        .{ctx.config.app_id},
    );
    defer allocator.free(cache_key);
    const cached = (try cache_inst.get(cache_key)) orelse return error.VerifyTicketRequired;
    if (cached.len == 0) return error.VerifyTicketRequired;
    return allocator.dupe(u8, cached);
}

/// 用 authorizer_refresh_token 刷新被授权方凭据，并把新 token 回写缓存。
///
/// 流程（对照 Go `RefreshAuthrTokenContext`）：
/// 1. 取 component_access_token：`verify_ticket` 非空时允许缓存未命中并回源换取；
///    为空时仅读缓存（Go 端语义）；
/// 2. `POST /cgi-bin/component/api_authorizer_token?component_access_token={s}`；
/// 3. 新 access_token 按 TTL `credential.tokenTTL(expires_in)` 缓存，
///    新 refresh_token 缓存 10 年（两者都可能轮换，必须回存）。
///
/// 整个「取 component token → 刷新 → 双写缓存」链路在 `ctx.token_mutex` 内串行执行
/// （锁内不做双检：本函数语义即为强制刷新），防止并发轮换互相覆盖丢失凭据。
pub fn refreshAuthrAccessToken(
    ctx: *Context,
    allocator: std.mem.Allocator,
    verify_ticket: []const u8,
    authorizer_appid: []const u8,
    authorizer_refresh_token: []const u8,
) Error!AuthrAccessToken {
    if (authorizer_appid.len == 0) return error.AuthorizerAppidRequired;
    if (authorizer_refresh_token.len == 0) return error.RefreshTokenRequired;
    if (ctx.config.cache == null) return error.CacheUnavailable;

    // 两个参数都可能借用自缓存 get（Memcache/Redis 后端后续 get 会使其悬垂），
    // 锁内还会多次触达缓存，这里先复制为自有切片。
    const ticket_owned = try allocator.dupe(u8, verify_ticket);
    defer allocator.free(ticket_owned);
    const rt_owned = try allocator.dupe(u8, authorizer_refresh_token);
    defer allocator.free(rt_owned);

    ctx.token_mutex.lock();
    defer ctx.token_mutex.unlock();
    return refreshAuthrAccessTokenLocked(ctx, allocator, ticket_owned, authorizer_appid, rt_owned);
}

/// `refreshAuthrAccessToken` 的锁内实现：调用方必须已持有 `ctx.token_mutex`。
fn refreshAuthrAccessTokenLocked(
    ctx: *Context,
    allocator: std.mem.Allocator,
    verify_ticket: []const u8,
    authorizer_appid: []const u8,
    authorizer_refresh_token: []const u8,
) Error!AuthrAccessToken {
    const cache_inst = ctx.config.cache orelse return error.CacheUnavailable;

    const component_token = if (verify_ticket.len > 0) blk: {
        const cache_key = try std.fmt.allocPrint(
            allocator,
            "openplatform_component_access_token_{s}",
            .{ctx.config.app_id},
        );
        defer allocator.free(cache_key);
        break :blk try getComponentAccessTokenLocked(ctx, allocator, verify_ticket, cache_key);
    } else try getCachedComponentAccessToken(ctx, allocator);
    defer allocator.free(component_token);

    const uri = try std.fmt.allocPrint(allocator, refreshAuthrTokenURL, .{component_token});
    defer allocator.free(uri);

    const body_json = try std.fmt.allocPrint(
        allocator,
        "{{\"component_appid\":\"{s}\",\"authorizer_appid\":\"{s}\",\"authorizer_refresh_token\":\"{s}\"}}",
        .{ ctx.config.app_id, authorizer_appid, authorizer_refresh_token },
    );
    defer allocator.free(body_json);

    const resp = try postJSON(ctx, allocator, uri, body_json);
    defer allocator.free(resp);

    var parsed = std.json.parseFromSlice(AuthrTokenResponse, allocator, resp, .{ .ignore_unknown_fields = true }) catch {
        return util_error.WechatError.DecodeError;
    };
    defer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    if (parsed.value.authorizer_access_token.len == 0) return util_error.WechatError.ApiError;

    // 两个 dupe 都放进块作用域：任一失败只触发本块内已注册 errdefer（释放先成功者），
    // 不会与构造完成后注册的 token.deinit 叠加 —— 避免 OOM 路径泄漏或 double free。
    var token = blk: {
        const access_token = try allocator.dupe(u8, parsed.value.authorizer_access_token);
        errdefer allocator.free(access_token);
        const refresh_token = try allocator.dupe(u8, parsed.value.authorizer_refresh_token);
        break :blk AuthrAccessToken{
            .appid = authorizer_appid,
            .access_token = access_token,
            .expires_in = parsed.value.expires_in,
            .refresh_token = refresh_token,
        };
    };
    errdefer token.deinit(allocator);

    const key = try authrTokenKey(allocator, authorizer_appid);
    defer allocator.free(key);
    try cache_inst.set(key, token.access_token, credential.tokenTTL(token.expires_in));

    const rkey = try authrRefreshKey(allocator, authorizer_appid);
    defer allocator.free(rkey);
    try cache_inst.set(rkey, token.refresh_token, 10 * 365 * 24 * 60 * 60);

    return token;
}

test "getAuthrAccessToken 需要 authorizer_appid" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    const result = getAuthrAccessToken(&ctx, std.testing.allocator, "");
    try std.testing.expectError(error.AuthorizerAppidRequired, result);
}

test "getAuthrAccessToken 无 cache 返回 CacheUnavailable" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    const result = getAuthrAccessToken(&ctx, std.testing.allocator, "wx-authr-1");
    try std.testing.expectError(error.CacheUnavailable, result);
}

test "getAuthrAccessToken 无 refresh token 缓存返回 RefreshTokenRequired" {
    const memory = try @import("../../cache/memory.zig").Memory.create(std.testing.allocator);
    defer {
        memory.deinit();
        std.testing.allocator.destroy(memory);
    }
    var ctx: Context = .{ .config = .{ .app_id = "wx-op", .cache = memory.asCache() } };
    const result = getAuthrAccessToken(&ctx, std.testing.allocator, "wx-authr-1");
    try std.testing.expectError(error.RefreshTokenRequired, result);
}

test "refreshAuthrAccessToken mock：解析响应并写入双缓存" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/component/api_component_token",
        .{ .body = "{\"component_access_token\":\"comp-tok\",\"expires_in\":7200}" },
    );
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/component/api_authorizer_token?component_access_token=comp-tok",
        .{ .body = "{\"authorizer_appid\":\"wx-authr-1\",\"authorizer_access_token\":\"12_authr_tok\",\"expires_in\":7200,\"authorizer_refresh_token\":\"refreshed_rt\"}" },
    );

    var ctx: Context = .{
        .config = .{ .app_id = "wx-op", .app_secret = "sec", .cache = memory.asCache() },
        .transport = util_http.MockTransport.dispatch,
        .transport_ctx = @ptrCast(&mock),
    };

    var token = try refreshAuthrAccessToken(&ctx, allocator, "ticket", "wx-authr-1", "old_rt");
    defer token.deinit(allocator);
    try std.testing.expectEqualStrings("12_authr_tok", token.access_token);
    try std.testing.expectEqualStrings("refreshed_rt", token.refresh_token);
    try std.testing.expectEqual(@as(i64, 7200), token.expires_in);

    // 双缓存均已回存（cache.get 返回的是 cache 持有的借用切片，无需 free）。
    const cache_inst = ctx.config.cache.?;
    const akey = try authrTokenKey(allocator, "wx-authr-1");
    defer allocator.free(akey);
    const cached_tok = (try cache_inst.get(akey)).?;
    try std.testing.expectEqualStrings("12_authr_tok", cached_tok);

    const rkey = try authrRefreshKey(allocator, "wx-authr-1");
    defer allocator.free(rkey);
    const cached_rt = (try cache_inst.get(rkey)).?;
    try std.testing.expectEqualStrings("refreshed_rt", cached_rt);
}

test "getAuthrAccessToken 缓存命中不发第二次请求" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/component/api_component_token",
        .{ .body = "{\"component_access_token\":\"comp-tok\",\"expires_in\":7200}" },
    );
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/component/api_authorizer_token?component_access_token=comp-tok",
        .{ .body = "{\"authorizer_access_token\":\"12_authr_tok\",\"expires_in\":7200,\"authorizer_refresh_token\":\"refreshed_rt\"}" },
    );

    var ctx: Context = .{
        .config = .{ .app_id = "wx-op", .app_secret = "sec", .cache = memory.asCache() },
        .transport = util_http.MockTransport.dispatch,
        .transport_ctx = @ptrCast(&mock),
    };

    // 预置 refresh token（首次授权由 QueryAuthCode 写入缓存）与 component token
    // （verify_ticket 传空时仅读缓存，走 Go `GetComponentAccessTokenContext` 语义）。
    const rkey = try authrRefreshKey(allocator, "wx-authr-1");
    defer allocator.free(rkey);
    try memory.asCache().set(rkey, "old_rt", 10 * 365 * 24 * 60 * 60);
    const ckey = try std.fmt.allocPrint(allocator, "openplatform_component_access_token_{s}", .{"wx-op"});
    defer allocator.free(ckey);
    try memory.asCache().set(ckey, "comp-tok", 7000);

    // 第一次：authorizer token 缓存未命中，走刷新流程（仅 authorizer token 1 次请求）。
    const tok1 = try getAuthrAccessToken(&ctx, allocator, "wx-authr-1");
    defer allocator.free(tok1);
    try std.testing.expectEqualStrings("12_authr_tok", tok1);
    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);

    // 第二次：authorizer token 缓存命中，不发请求。
    const tok2 = try getAuthrAccessToken(&ctx, allocator, "wx-authr-1");
    defer allocator.free(tok2);
    try std.testing.expectEqualStrings("12_authr_tok", tok2);
    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);
}

test "getAuthrAccessToken 未命中经 refresh 正常获取（refresh 借用切片已复制）" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/component/api_authorizer_token?component_access_token=comp-tok",
        .{ .body = "{\"authorizer_access_token\":\"fresh_tok\",\"expires_in\":7200,\"authorizer_refresh_token\":\"rotated_rt\"}" },
    );

    var ctx: Context = .{
        .config = .{ .app_id = "wx-op", .app_secret = "sec", .cache = memory.asCache() },
        .transport = util_http.MockTransport.dispatch,
        .transport_ctx = @ptrCast(&mock),
    };

    // 预置 component token（verify_ticket 为空仅读缓存）与 refresh token。
    const ckey = try std.fmt.allocPrint(allocator, "openplatform_component_access_token_{s}", .{"wx-op"});
    defer allocator.free(ckey);
    try memory.asCache().set(ckey, "comp-tok", 7000);
    const rkey = try authrRefreshKey(allocator, "wx-authr-9");
    defer allocator.free(rkey);
    try memory.asCache().set(rkey, "old_rt", 10 * 365 * 24 * 60 * 60);

    // refresh token 借用自缓存 get：内部必须 dupe 后再触发后续 cache get
    // （取 component token），否则后端为 Memcache/Redis 时切片会悬垂。
    const tok = try getAuthrAccessToken(&ctx, allocator, "wx-authr-9");
    defer allocator.free(tok);
    try std.testing.expectEqualStrings("fresh_tok", tok);

    // 轮换后的 refresh_token 已回存。
    const cached_rt = (try memory.asCache().get(rkey)).?;
    try std.testing.expectEqualStrings("rotated_rt", cached_rt);
}
