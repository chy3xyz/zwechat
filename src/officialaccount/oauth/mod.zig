// SPDX-License-Identifier: Apache-2.0
//! officialaccount/oauth — 网页授权
//!
//! 对应 `_ref/wechat/officialaccount/oauth/oauth.go`：构建跳转 URL、code 换 token、刷新 token、获取用户信息。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_uri = @import("../../util/uri.zig");

pub const Oauth = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 构造网页授权跳转 URL（scope: snsapi_base / snsapi_userinfo）。
    ///
    /// `redirect_uri` 与 `state` 由本方法按 Go `url.QueryEscape` 语义做 percent-encode
    /// （Go 参考 `oauth.go` 的 `GetRedirectURL` 对 `redirect_uri` 调用了 `url.QueryEscape`；
    /// `state` 在 Go 里是裸插值，此处按仓库「用户可控参数一律转义」纪律一并转义），
    /// 调用方直接传入原始值即可。`scope` 为固定枚举（snsapi_base / snsapi_userinfo），不转义。
    /// 返回的 URL 由 `self.allocator` 分配，调用方负责 `free`。
    pub fn getRedirectURL(self: *Self, redirect_uri: []const u8, scope: []const u8, state: []const u8) ![]u8 {
        const escaped_uri = try util_uri.queryEscape(self.allocator, redirect_uri);
        defer self.allocator.free(escaped_uri);
        const escaped_state = try util_uri.queryEscape(self.allocator, state);
        defer self.allocator.free(escaped_state);
        return self.allocator.print(
            "https://open.weixin.qq.com/connect/oauth2/authorize?appid={s}&redirect_uri={s}&response_type=code&scope={s}&state={s}#wechat_redirect",
            .{ self.ctx.config.app_id, escaped_uri, scope, escaped_state },
        );
    }

    /// code → user access_token（含 openid / refresh_token）。
    /// 返回的 `std.json.Parsed(ResAccessToken)` 由调用方持有并负责 `deinit`，
    /// 避免内部切片（openid/unionid 等）在返回前被释放导致 use-after-free。
    pub fn getUserAccessToken(self: *Self, code: []const u8) !std.json.Parsed(ResAccessToken) {
        // `code` 来自回调 query，属用户可控参数，按 Go `url.QueryEscape` 语义转义
        //（Go 参考此处是裸插值，本仓库按统一纪律收紧）。
        const escaped_code = try util_uri.queryEscape(self.allocator, code);
        defer self.allocator.free(escaped_code);
        const uri = try self.allocator.print(
            "https://api.weixin.qq.com/sns/oauth2/access_token?appid={s}&secret={s}&code={s}&grant_type=authorization_code",
            .{ self.ctx.config.app_id, self.ctx.config.app_secret, escaped_code },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResAccessToken, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };

        if (parsed.value.errcode != 0) {
            parsed.deinit();
            return util_error.WechatError.ApiError;
        }
        return parsed;
    }

    /// 刷新 user access_token。
    /// 返回的 `std.json.Parsed(ResAccessToken)` 由调用方持有并负责 `deinit`。
    pub fn refreshAccessToken(self: *Self, refresh_token: []const u8) !std.json.Parsed(ResAccessToken) {
        // `refresh_token` 由调用方传入，转义后拼入 query（Go 参考为裸插值）。
        const escaped_token = try util_uri.queryEscape(self.allocator, refresh_token);
        defer self.allocator.free(escaped_token);
        const uri = try self.allocator.print(
            "https://api.weixin.qq.com/sns/oauth2/refresh_token?appid={s}&grant_type=refresh_token&refresh_token={s}",
            .{ self.ctx.config.app_id, escaped_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResAccessToken, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 校验 user access_token 是否有效。
    pub fn checkAccessToken(self: *Self, access_token: []const u8, open_id: []const u8) !bool {
        const escaped_open_id = try util_uri.queryEscape(self.allocator, open_id);
        defer self.allocator.free(escaped_open_id);
        const uri = try self.allocator.print(
            "https://api.weixin.qq.com/sns/auth?access_token={s}&openid={s}",
            .{ access_token, escaped_open_id },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(CommonError, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        return parsed.value.errcode == 0;
    }

    /// 获取用户基本信息（需 scope=snsapi_userinfo）。
    /// 返回的 `std.json.Parsed(UserInfo)` 由调用方持有并负责 `deinit`，
    /// 避免内部切片（nickname/headimgurl/unionid 等）在返回前被释放导致 use-after-free。
    pub fn getUserInfo(self: *Self, access_token: []const u8, open_id: []const u8, lang: []const u8) !std.json.Parsed(UserInfo) {
        const language = if (lang.len == 0) "zh_CN" else lang;
        // `open_id` 为用户可控参数，转义后拼入 query；`lang` 是固定语言枚举，不转义。
        const escaped_open_id = try util_uri.queryEscape(self.allocator, open_id);
        defer self.allocator.free(escaped_open_id);
        const uri = try self.allocator.print(
            "https://api.weixin.qq.com/sns/userinfo?access_token={s}&openid={s}&lang={s}",
            .{ access_token, escaped_open_id, language },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(UserInfo, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };

        if (parsed.value.errcode != 0) {
            parsed.deinit();
            return util_error.WechatError.ApiError;
        }
        return parsed;
    }
};

pub const CommonError = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const ResAccessToken = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    access_token: []const u8 = "",
    expires_in: i64 = 0,
    refresh_token: []const u8 = "",
    openid: []const u8 = "",
    scope: []const u8 = "",
    unionid: []const u8 = "",
    is_snapshotuser: i64 = 0,
};

pub const UserInfo = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    openid: []const u8 = "",
    nickname: []const u8 = "",
    sex: i64 = 0,
    province: []const u8 = "",
    city: []const u8 = "",
    country: []const u8 = "",
    headimgurl: []const u8 = "",
    privilege: []const []const u8 = &.{},
    unionid: []const u8 = "",
};

test "Oauth.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-oa", .app_secret = "sec" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const o = Oauth.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-oa", o.ctx.config.app_id);
}

test "ResAccessToken 默认值" {
    const r = ResAccessToken{};
    try std.testing.expectEqualStrings("", r.access_token);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}

// ──────────────────────────────────────────────────────────────────────────────
// query 转义守护（回归：用户可控参数裸插值进 URL query）
// ──────────────────────────────────────────────────────────────────────────────

/// 记录请求 URI 的 transport（Oauth 无注入 transport，需挂到默认客户端上）。
const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uris: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator, response: []const u8) RecordingTransport {
        return .{ .allocator = allocator, .response = response };
    }

    fn deinit(self: *RecordingTransport) void {
        for (self.uris.items) |u| self.allocator.free(u);
        self.uris.deinit(self.allocator);
    }

    fn dispatch(
        ctx_ptr: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = method;
        _ = payload;
        _ = content_type;
        const self: *RecordingTransport = @ptrCast(@alignCast(ctx_ptr));
        try self.uris.append(self.allocator, try self.allocator.dupe(u8, uri));
        return allocator.dupe(u8, self.response);
    }
};

/// 把 `rec` 挂到线程默认 HTTP 客户端上（调用方负责在结束时 `releaseTransport`）。
fn installTransport(allocator: std.mem.Allocator, rec: *RecordingTransport) void {
    const client = util_http.getDefaultClient(allocator);
    client.setTransport(RecordingTransport.dispatch, @ptrCast(rec));
}

/// 直接销毁线程局部客户端：不用别的 allocator 再取一次指针（避免宽容语义依赖）。
fn releaseTransport() void {
    util_http.deinitDefaultClient();
}

fn makeOauth(ctx: *Context, allocator: std.mem.Allocator) Oauth {
    ctx.* = .{
        .config = .{ .app_id = "wx-oa", .app_secret = "sec" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    return Oauth.init(ctx, allocator);
}

test "getRedirectURL 按 Go 语义转义 redirect_uri（与 _ref/wechat oauth.go:37 对齐）" {
    const allocator = std.testing.allocator;
    var ctx: Context = undefined;
    var o = makeOauth(&ctx, allocator);

    const url = try o.getRedirectURL("https://cb.example.com/oauth/cb?a=1&b=2", "snsapi_base", "STATE123");
    defer allocator.free(url);
    // 逐字节等于 Go：fmt.Sprintf(redirectOauthURL, AppID, url.QueryEscape(redirectURI), scope, state)
    try std.testing.expectEqualStrings(
        "https://open.weixin.qq.com/connect/oauth2/authorize?appid=wx-oa&redirect_uri=https%3A%2F%2Fcb.example.com%2Foauth%2Fcb%3Fa%3D1%26b%3D2&response_type=code&scope=snsapi_base&state=STATE123#wechat_redirect",
        url,
    );
}

test "getRedirectURL 转义 state 中的 & / = （防止参数被截断）" {
    const allocator = std.testing.allocator;
    var ctx: Context = undefined;
    var o = makeOauth(&ctx, allocator);

    const url = try o.getRedirectURL("https://cb.example.com/cb", "snsapi_userinfo", "a&b=c");
    defer allocator.free(url);
    try std.testing.expect(std.mem.find(u8, url, "&state=a%26b%3Dc#wechat_redirect") != null);
    try std.testing.expect(std.mem.find(u8, url, "&state=a&b=c") == null);
}

test "getUserAccessToken / checkAccessToken / getUserInfo / refreshAccessToken URI：纯字母数字输入与改造前逐字节一致" {
    const allocator = std.testing.allocator;
    var rec = RecordingTransport.init(
        allocator,
        "{\"access_token\":\"at1\",\"refresh_token\":\"rt1\",\"openid\":\"OPENID1\"}",
    );
    defer rec.deinit();
    installTransport(allocator, &rec);
    defer releaseTransport();

    var ctx: Context = undefined;
    var o = makeOauth(&ctx, allocator);

    {
        var parsed = try o.getUserAccessToken("CODE1");
        defer parsed.deinit();
    }
    {
        var parsed = try o.refreshAccessToken("REFRESH1");
        defer parsed.deinit();
    }
    _ = try o.checkAccessToken("AT1", "OPENID1");
    {
        var parsed = try o.getUserInfo("AT1", "OPENID1", "");
        defer parsed.deinit();
    }

    try std.testing.expectEqual(@as(usize, 4), rec.uris.items.len);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/sns/oauth2/access_token?appid=wx-oa&secret=sec&code=CODE1&grant_type=authorization_code",
        rec.uris.items[0],
    );
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/sns/oauth2/refresh_token?appid=wx-oa&grant_type=refresh_token&refresh_token=REFRESH1",
        rec.uris.items[1],
    );
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/sns/auth?access_token=AT1&openid=OPENID1",
        rec.uris.items[2],
    );
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/sns/userinfo?access_token=AT1&openid=OPENID1&lang=zh_CN",
        rec.uris.items[3],
    );
}

test "getUserAccessToken / checkAccessToken 转义 code / openid 中的 & 与 = （回归：裸插值截断参数）" {
    const allocator = std.testing.allocator;
    var rec = RecordingTransport.init(allocator, "{\"errcode\":0}");
    defer rec.deinit();
    installTransport(allocator, &rec);
    defer releaseTransport();

    var ctx: Context = undefined;
    var o = makeOauth(&ctx, allocator);

    _ = try o.checkAccessToken("AT1", "o&id=x");
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/sns/auth?access_token=AT1&openid=o%26id%3Dx",
        rec.uris.items[0],
    );
}
