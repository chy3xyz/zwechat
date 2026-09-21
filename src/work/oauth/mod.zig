// SPDX-License-Identifier: Apache-2.0
//! work/oauth — 企业微信网页授权
//!
//! 对应 `_ref/wechat/work/oauth/oauth.go`：构造跳转 URL、code 换 userid、
//! 获取访问用户身份 / 敏感信息、二次验证相关接口。
//!
//! 主要接口：
//! - `getRedirectURL`         ：构造 snsapi_base 跳转 URL。
//! - `getRedirectPrivateURL`  ：构造 snsapi_privateinfo 跳转 URL（带 agentid）。
//! - `getQrContentTargetURL`  ：构造独立窗口登录二维码 URL。
//! - `userInfoToId`           ：根据 code 拿 userid（对应 Go 的 `UserFromCode`）。
//! - `getUserInfo`            ：访问用户身份 / 登录身份。
//! - `getUserDetail`          ：访问用户敏感信息（POST JSON）。
//! - `getTfaInfo` / `tfaSucc` ：二次验证流程。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_uri = @import("../../util/uri.zig");
const util_json = @import("../../util/json.zig");
const credential = @import("../../credential/mod.zig");

// ──────────────────────────────────────────────────────────────────────────────
// URL 模板常量（与 `_ref/wechat/work/oauth/oauth.go` 一一对应）
// ──────────────────────────────────────────────────────────────────────────────

/// 企业微信内跳转地址（snsapi_base）。
pub const oauthTargetURL =
    "https://open.weixin.qq.com/connect/oauth2/authorize" ++
    "?appid={s}&redirect_uri={s}&response_type=code&scope=snsapi_base" ++
    "&state=STATE#wechat_redirect";

/// 企业微信内跳转地址（snsapi_privateinfo，携带 agentid 用于获取成员详情）。
pub const oauthTargetPrivateURL =
    "https://open.weixin.qq.com/connect/oauth2/authorize" ++
    "?appid={s}&redirect_uri={s}&response_type=code&scope=snsapi_privateinfo" ++
    "&agentid={s}&state=STATE#wechat_redirect";

/// `/cgi-bin/user/getuserinfo` 接口：根据 code 拿 userid（老接口，行为类似公众号 oauth）。
pub const oauthUserInfoURL =
    "https://qyapi.weixin.qq.com/cgi-bin/user/getuserinfo?access_token={s}&code={s}";

/// 独立窗口登录二维码 URL。
pub const oauthQrContentTargetURL =
    "https://open.work.weixin.qq.com/wwopen/sso/qrConnect?appid={s}&agentid={s}" ++
    "&redirect_uri={s}&state={s}";

/// `/cgi-bin/auth/getuserinfo` 接口：获取访问用户身份 / 登录身份。
pub const getUserInfoURL =
    "https://qyapi.weixin.qq.com/cgi-bin/auth/getuserinfo?access_token={s}&code={s}";

/// `/cgi-bin/auth/getuserdetail` 接口：获取访问用户敏感信息（POST JSON）。
pub const getUserDetailURL =
    "https://qyapi.weixin.qq.com/cgi-bin/auth/getuserdetail?access_token={s}";

/// `/cgi-bin/auth/get_tfa_info` 接口：获取用户二次验证信息（POST JSON）。
pub const getTfaInfoURL =
    "https://qyapi.weixin.qq.com/cgi-bin/auth/get_tfa_info?access_token={s}";

/// `/cgi-bin/user/tfa_succ` 接口：使用二次验证（POST JSON）。
pub const tfaSuccURL =
    "https://qyapi.weixin.qq.com/cgi-bin/user/tfa_succ?access_token={s}";

// ──────────────────────────────────────────────────────────────────────────────
// 内部辅助
// ──────────────────────────────────────────────────────────────────────────────

/// 按 Go `url.QueryEscape` 语义做 percent-encode（实现收敛到 `util.uri.queryEscape`）：
/// 保留 `[0-9A-Za-z-_.~]`，空格转 `+`，其余字节转 `%XX`（大写 hex）。
const queryEscape = util_uri.queryEscape;

// ──────────────────────────────────────────────────────────────────────────────
// 请求 / 响应结构
// ──────────────────────────────────────────────────────────────────────────────

/// `getuserinfo`（`/cgi-bin/user/getuserinfo`）响应（对应 Go 的 `ResUserInfo`）。
///
/// 字段名沿用 Go 的大小写：`UserId` / `DeviceId` / `OpenID` —— JSON 解码时
/// `std.json` 默认大小写敏感，因此必须严格匹配微信接口返回的字段。
pub const ResUserInfo = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 企业成员时返回。
    UserId: []const u8 = "",
    DeviceId: []const u8 = "",
    /// 非企业成员授权时返回。
    OpenID: []const u8 = "",
    external_userid: []const u8 = "",
};

/// `auth/getuserinfo` 响应（对应 Go 的 `GetUserInfoResponse`）。
pub const GetUserInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userid: []const u8 = "",
    user_ticket: []const u8 = "",
    openid: []const u8 = "",
    external_userid: []const u8 = "",
};

/// `auth/getuserdetail` 请求体。
pub const GetUserDetailRequest = struct {
    user_ticket: []const u8 = "",
};

/// `auth/getuserdetail` 响应。
pub const GetUserDetailResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userid: []const u8 = "",
    gender: []const u8 = "",
    avatar: []const u8 = "",
    qr_code: []const u8 = "",
    mobile: []const u8 = "",
    email: []const u8 = "",
    biz_mail: []const u8 = "",
    address: []const u8 = "",
};

/// `auth/get_tfa_info` 请求体。
pub const GetTfaInfoRequest = struct {
    code: []const u8 = "",
};

/// `auth/get_tfa_info` 响应。
pub const GetTfaInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userid: []const u8 = "",
    tfa_code: []const u8 = "",
};

// ──────────────────────────────────────────────────────────────────────────────
// Oauth struct
// ──────────────────────────────────────────────────────────────────────────────

pub const Oauth = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 capture transport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    /// `ctx` 由调用方保证生命周期长于本实例；`allocator` 用于拼装 URL 与解析响应。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    fn postJSON(self: *Self, allocator: std.mem.Allocator, uri: []const u8, payload: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, payload);
        }
        return util_http.getDefaultClient(allocator).postJSON(uri, payload);
    }

    /// 构造网页授权跳转 URL（snsapi_base）。
    ///
    /// `redirect_uri` 会按 Go 参考的 `url.QueryEscape` 语义做 percent-encode
    /// （保留 `[0-9A-Za-z-_.~]`，空格转 `+`，其余转 `%XX` 大写 hex），
    /// 调用方直接传入原始回调地址即可。
    /// 返回的 URL 由 `self.allocator` 分配，调用方负责 `free`。
    pub fn getRedirectURL(self: *Self, redirect_uri: []const u8) ![]u8 {
        const escaped = try queryEscape(self.allocator, redirect_uri);
        defer self.allocator.free(escaped);
        return std.fmt.allocPrint(
            self.allocator,
            oauthTargetURL,
            .{ self.ctx.config.corp_id, escaped },
        );
    }

    /// 构造网页授权跳转 URL（snsapi_privateinfo）。
    ///
    /// `redirect_uri` 的编码行为与 `getRedirectURL` 一致；
    /// 返回的 URL 同样由调用方负责 `free`。
    pub fn getRedirectPrivateURL(self: *Self, redirect_uri: []const u8, agent_id: []const u8) ![]u8 {
        const escaped = try queryEscape(self.allocator, redirect_uri);
        defer self.allocator.free(escaped);
        return std.fmt.allocPrint(
            self.allocator,
            oauthTargetPrivateURL,
            .{ self.ctx.config.corp_id, escaped, agent_id },
        );
    }

    /// 构造独立窗口登录二维码 URL。
    ///
    /// `state` 通常由调用方生成（Go 版使用 `util.RandomStr(16)`）；
    /// `redirect_uri` 的编码行为与 `getRedirectURL` 一致；
    /// 返回的 URL 同样由调用方负责 `free`。
    pub fn getQrContentTargetURL(self: *Self, redirect_uri: []const u8, state: []const u8) ![]u8 {
        const escaped = try queryEscape(self.allocator, redirect_uri);
        defer self.allocator.free(escaped);
        return std.fmt.allocPrint(
            self.allocator,
            oauthQrContentTargetURL,
            .{ self.ctx.config.corp_id, self.ctx.config.agent_id, escaped, state },
        );
    }

    /// 根据 code 获取用户身份 / userid。对应 Go 的 `UserFromCode`。
    ///
    /// 命中 `UserId` 字段时为企业成员；只有 `OpenID` 时为非企业成员。
    /// 走 `util/retry.callApi`：token 失效（40001 等）时自动作废缓存并重试一次。
    /// 返回的 `std.json.Parsed(ResUserInfo)` 由调用方持有并负责 `deinit`。
    pub fn userInfoToId(self: *Self, code: []const u8) !std.json.Parsed(ResUserInfo) {
        const Sender = struct {
            self: *Self,
            code: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    oauthUserInfoURL,
                    .{ token, c.code },
                );
                defer allocator.free(uri);
                return util_http.getDefaultClient(c.self.allocator).get(uri);
            }
        };

        const body = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "UserInfoToId",
            Sender{ .self = self, .code = code },
        );
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResUserInfo, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        return parsed;
    }

    /// 获取访问用户身份 / 登录身份。对应 Go 的 `GetUserInfo`。
    /// 走 `util/retry.callApi`：token 失效时自动作废缓存并重试一次。
    /// 返回的 `std.json.Parsed(GetUserInfoResponse)` 由调用方持有并负责 `deinit`。
    pub fn getUserInfo(self: *Self, code: []const u8) !std.json.Parsed(GetUserInfoResponse) {
        const Sender = struct {
            self: *Self,
            code: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    getUserInfoURL,
                    .{ token, c.code },
                );
                defer allocator.free(uri);
                return util_http.getDefaultClient(c.self.allocator).get(uri);
            }
        };

        const body = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "GetUserInfo",
            Sender{ .self = self, .code = code },
        );
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(GetUserInfoResponse, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        return parsed;
    }

    /// 获取访问用户敏感信息（POST JSON）。对应 Go 的 `GetUserDetail`。
    ///
    /// 调用方只需传入 `user_ticket`；请求体由本方法拼接。
    /// 走 `util/retry.callApi`：token 失效时自动作废缓存并重试一次。
    /// 返回的 `std.json.Parsed(GetUserDetailResponse)` 由调用方持有并负责 `deinit`。
    pub fn getUserDetail(self: *Self, user_ticket: []const u8) !std.json.Parsed(GetUserDetailResponse) {
        // user_ticket 由调用方提供，走 JSON 转义（原先 allocPrint 裸插值）。
        const body = try util_json.stringFieldObject(self.allocator, "user_ticket", user_ticket);
        defer self.allocator.free(body);

        const Sender = struct {
            self: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    getUserDetailURL,
                    .{token},
                );
                defer allocator.free(uri);
                return c.self.postJSON(allocator, uri, c.body);
            }
        };

        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "GetUserDetail",
            Sender{ .self = self, .body = body },
        );
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetUserDetailResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        return parsed;
    }

    /// 获取用户二次验证信息（POST JSON）。
    /// 走 `util/retry.callApi`：token 失效时自动作废缓存并重试一次。
    /// 返回的 `std.json.Parsed(GetTfaInfoResponse)` 由调用方持有并负责 `deinit`。
    pub fn getTfaInfo(self: *Self, code: []const u8) !std.json.Parsed(GetTfaInfoResponse) {
        // code 来自调用方，走 JSON 转义（原先 allocPrint 裸插值）。
        const body = try util_json.stringFieldObject(self.allocator, "code", code);
        defer self.allocator.free(body);

        const Sender = struct {
            self: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    getTfaInfoURL,
                    .{token},
                );
                defer allocator.free(uri);
                return c.self.postJSON(allocator, uri, c.body);
            }
        };

        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "GetTfaInfo",
            Sender{ .self = self, .body = body },
        );
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetTfaInfoResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        return parsed;
    }

    /// 使用二次验证（POST JSON）。
    /// 走 `util/retry.callApi`：token 失效时自动作废缓存并重试一次。
    pub fn tfaSucc(self: *Self, user_id: []const u8, tfa_code: []const u8) !void {
        // userid / tfa_code 均来自调用方，走 std.json.Stringify 转义
        //（原先 allocPrint 裸插值，含 `"`/控制字符即产出非法 JSON）。
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        try jw.beginObject();
        try jw.objectField("userid");
        try jw.write(user_id);
        try jw.objectField("tfa_code");
        try jw.write(tfa_code);
        try jw.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const Sender = struct {
            self: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    tfaSuccURL,
                    .{token},
                );
                defer allocator.free(uri);
                return c.self.postJSON(allocator, uri, c.body);
            }
        };

        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "TfaSucc",
            Sender{ .self = self, .body = body },
        );
        defer self.allocator.free(resp);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 内联测试
// ──────────────────────────────────────────────────────────────────────────────

test "Oauth.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-oauth", .agent_id = "1000001" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fba_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const o = Oauth.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-oauth", o.ctx.config.corp_id);
    try std.testing.expectEqualStrings("1000001", o.ctx.config.agent_id);
}

test "URL 模板常量值正确" {
    try std.testing.expect(std.mem.indexOf(u8, oauthTargetURL, "snsapi_base") != null);
    try std.testing.expect(std.mem.indexOf(u8, oauthTargetPrivateURL, "snsapi_privateinfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, oauthUserInfoURL, "user/getuserinfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, oauthQrContentTargetURL, "wwopen/sso/qrConnect") != null);
    try std.testing.expect(std.mem.indexOf(u8, getUserInfoURL, "auth/getuserinfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, getUserDetailURL, "auth/getuserdetail") != null);
    try std.testing.expect(std.mem.indexOf(u8, getTfaInfoURL, "auth/get_tfa_info") != null);
    try std.testing.expect(std.mem.indexOf(u8, tfaSuccURL, "user/tfa_succ") != null);
}

test "Oauth.getRedirectURL 拼接 corp_id 并对 redirect_uri 做 QueryEscape" {
    var ctx: Context = .{
        .config = .{ .corp_id = "wwabc123" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fba_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    var o = Oauth.init(&ctx, fba.allocator());
    const url = try o.getRedirectURL("https://example.com/cb?a=1&b=2");
    try std.testing.expect(std.mem.indexOf(u8, url, "wwabc123") != null);
    // 与 Go url.QueryEscape("https://example.com/cb?a=1&b=2") 的结果一致。
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=https%3A%2F%2Fexample.com%2Fcb%3Fa%3D1%26b%3D2") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=snsapi_base") != null);
}

test "Oauth.getRedirectPrivateURL 包含 agentid 且编码 redirect_uri" {
    var ctx: Context = .{
        .config = .{ .corp_id = "wwxyz", .agent_id = "42" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fba_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    var o = Oauth.init(&ctx, fba.allocator());
    const url = try o.getRedirectPrivateURL("https://example.com/cb", "42");
    try std.testing.expect(std.mem.indexOf(u8, url, "wwxyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=snsapi_privateinfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "agentid=42") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=https%3A%2F%2Fexample.com%2Fcb") != null);
}

test "Oauth.getQrContentTargetURL 编码 redirect_uri 并携带 state" {
    var ctx: Context = .{
        .config = .{ .corp_id = "wwqr", .agent_id = "1000009" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fba_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    var o = Oauth.init(&ctx, fba.allocator());
    const url = try o.getQrContentTargetURL("https://example.com/qr cb", "state123");
    try std.testing.expect(std.mem.indexOf(u8, url, "appid=wwqr") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "agentid=1000009") != null);
    // 空格转 '+'（Go QueryEscape 语义）。
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=https%3A%2F%2Fexample.com%2Fqr+cb") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=state123") != null);
}

test "queryEscape 符合 Go QueryEscape 语义" {
    const alloc = std.testing.allocator;
    // 保留字符不编码。
    const plain = try queryEscape(alloc, "AZaz09-_.~");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("AZaz09-_.~", plain);
    // 空格转 '+'，其余转大写 hex。
    const esc = try queryEscape(alloc, "a b&c=中");
    defer alloc.free(esc);
    try std.testing.expectEqualStrings("a+b%26c%3D%E4%B8%AD", esc);
}

test "ResUserInfo 默认值（字段大小写与 Go 一致）" {
    const r = ResUserInfo{};
    try std.testing.expectEqualStrings("", r.UserId);
    try std.testing.expectEqualStrings("", r.DeviceId);
    try std.testing.expectEqualStrings("", r.OpenID);
    try std.testing.expectEqualStrings("", r.external_userid);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}

test "GetUserDetailResponse 默认值" {
    const r = GetUserDetailResponse{};
    try std.testing.expectEqualStrings("", r.userid);
    try std.testing.expectEqualStrings("", r.mobile);
    try std.testing.expectEqualStrings("", r.email);
}

test "GetUserInfoResponse 默认值" {
    const r = GetUserInfoResponse{};
    try std.testing.expectEqualStrings("", r.user_ticket);
    try std.testing.expectEqualStrings("", r.openid);
}

// ──────────────────────────────────────────────────────────────────────────────
// token 失效自愈（mock transport）
// ──────────────────────────────────────────────────────────────────────────────

/// 可自愈的假 token handle：`invalidate` 后把 `idx` 推进到下一个 token。
const HealState = struct {
    invalidates: usize = 0,
    idx: usize = 0,
    tokens: []const []const u8 = &.{ "old-token", "new-token" },

    fn getToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const st: *HealState = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, st.tokens[st.idx]);
    }

    fn invalidate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const st: *HealState = @ptrCast(@alignCast(ctx));
        st.invalidates += 1;
        if (st.idx + 1 < st.tokens.len) st.idx += 1;
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

fn makeHealCtx(state: *HealState) Context {
    return .{
        .config = .{ .corp_id = "ww-oauth-heal" },
        .access_token_handle = .{ .ptr = @ptrCast(state), .vtable = &HealState.vtable },
    };
}

/// 记录 payload 并返回固定响应的 transport。
const Capture = struct {
    payload: []u8 = &.{},
    fn dispatch(ctx: *anyopaque, a: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = content_type;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.payload = try a.dupe(u8, payload);
        return a.dupe(u8, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    }
};

test "getUserDetail 转义 user_ticket 中的引号与控制字符（回归：allocPrint 裸插值）" {
    const allocator = std.testing.allocator;
    var cap = Capture{};
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var o = Oauth.init(&ctx, allocator);
    o.setTransport(Capture.dispatch, &cap);

    var parsed = try o.getUserDetail("tk\"A\x01");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("{\"user_ticket\":\"tk\\\"A\\u0001\"}", cap.payload);
    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, cap.payload, .{});
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("tk\"A\x01", reparsed.value.object.get("user_ticket").?.string);
}

test "getTfaInfo 转义 code 中的引号与反斜杠（回归：allocPrint 裸插值）" {
    const allocator = std.testing.allocator;
    var cap = Capture{};
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var o = Oauth.init(&ctx, allocator);
    o.setTransport(Capture.dispatch, &cap);

    var parsed = try o.getTfaInfo("a\\\"b");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("{\"code\":\"a\\\\\\\"b\"}", cap.payload);
    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, cap.payload, .{});
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("a\\\"b", reparsed.value.object.get("code").?.string);
}

test "tfaSucc 转义 userid / tfa_code 中的控制字符（回归：allocPrint 裸插值）" {
    const allocator = std.testing.allocator;
    var cap = Capture{};
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var o = Oauth.init(&ctx, allocator);
    o.setTransport(Capture.dispatch, &cap);

    try o.tfaSucc("u\x1f1", "0\"0");

    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, cap.payload, .{});
    defer reparsed.deinit();
    const obj = reparsed.value.object;
    try std.testing.expectEqualStrings("u\x1f1", obj.get("userid").?.string);
    try std.testing.expectEqualStrings("0\"0", obj.get("tfa_code").?.string);
}

test "userInfoToId token 失效自愈：40001 → 作废缓存 → 新 token 重试成功（GET 路径）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/user/getuserinfo?access_token=old-token&code=CODE1", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/user/getuserinfo?access_token=new-token&code=CODE1", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"UserId\":\"zhangsan\",\"DeviceId\":\"dev1\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var o = Oauth.init(&ctx, allocator);
    var parsed = try o.userInfoToId("CODE1");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("zhangsan", parsed.value.UserId);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[0], "access_token=old-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-token") != null);
}

test "getUserDetail token 失效自愈：42001 → 作废缓存 → 新 token 重试成功（POST 路径）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/auth/getuserdetail?access_token=old-token", .{
        .body = "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/auth/getuserdetail?access_token=new-token", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"userid\":\"zhangsan\",\"mobile\":\"15000000000\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var o = Oauth.init(&ctx, allocator);
    var parsed = try o.getUserDetail("ticket_1");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("15000000000", parsed.value.mobile);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-token") != null);
}

test "tfaSucc token 失效自愈：40014 → 重试后成功且返回 void（无响应体泄漏）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/user/tfa_succ?access_token=old-token", .{
        .body = "{\"errcode\":40014,\"errmsg\":\"invalid access_token\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/user/tfa_succ?access_token=new-token", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var o = Oauth.init(&ctx, allocator);
    try o.tfaSucc("zhangsan", "123456");

    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-token") != null);
}

test "getUserInfo 非 token 类 errcode（60011）直接 ApiError，不重试也不作废" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/auth/getuserinfo?access_token=old-token&code=CODE1", .{
        .body = "{\"errcode\":60011,\"errmsg\":\"no privilege to access the data\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var o = Oauth.init(&ctx, allocator);

    try std.testing.expectError(error.ApiError, o.getUserInfo("CODE1"));

    try std.testing.expectEqual(@as(usize, 0), state.invalidates);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}
