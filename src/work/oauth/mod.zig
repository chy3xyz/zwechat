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

/// 按 Go `url.QueryEscape` 语义做 percent-encode：
/// 保留 `[0-9A-Za-z-_.~]`，空格转 `+`，其余字节转 `%XX`（大写 hex）。
fn queryEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try buf.append(allocator, c),
            ' ' => try buf.append(allocator, '+'),
            else => {
                try buf.append(allocator, '%');
                try buf.append(allocator, hex[c >> 4]);
                try buf.append(allocator, hex[c & 0x0f]);
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}

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

    const Self = @This();

    /// `ctx` 由调用方保证生命周期长于本实例；`allocator` 用于拼装 URL 与解析响应。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
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
    /// 返回的 `std.json.Parsed(ResUserInfo)` 由调用方持有并负责 `deinit`。
    pub fn userInfoToId(self: *Self, code: []const u8) !std.json.Parsed(ResUserInfo) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            oauthUserInfoURL,
            .{ access_token, code },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResUserInfo, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 获取访问用户身份 / 登录身份。对应 Go 的 `GetUserInfo`。
    /// 返回的 `std.json.Parsed(GetUserInfoResponse)` 由调用方持有并负责 `deinit`。
    pub fn getUserInfo(self: *Self, code: []const u8) !std.json.Parsed(GetUserInfoResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            getUserInfoURL,
            .{ access_token, code },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(GetUserInfoResponse, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 获取访问用户敏感信息（POST JSON）。对应 Go 的 `GetUserDetail`。
    ///
    /// 调用方只需传入 `user_ticket`；请求体由本方法拼接。
    /// 返回的 `std.json.Parsed(GetUserDetailResponse)` 由调用方持有并负责 `deinit`。
    pub fn getUserDetail(self: *Self, user_ticket: []const u8) !std.json.Parsed(GetUserDetailResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            getUserDetailURL,
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"user_ticket\":\"{s}\"}}",
            .{user_ticket},
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetUserDetailResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 获取用户二次验证信息（POST JSON）。
    /// 返回的 `std.json.Parsed(GetTfaInfoResponse)` 由调用方持有并负责 `deinit`。
    pub fn getTfaInfo(self: *Self, code: []const u8) !std.json.Parsed(GetTfaInfoResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            getTfaInfoURL,
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"code\":\"{s}\"}}",
            .{code},
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetTfaInfoResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 使用二次验证（POST JSON）。
    pub fn tfaSucc(self: *Self, user_id: []const u8, tfa_code: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            tfaSuccURL,
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"userid\":\"{s}\",\"tfa_code\":\"{s}\"}}",
            .{ user_id, tfa_code },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "TfaSucc")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
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
