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
    /// 返回的 URL 由 `redirect_uri` 直接拼接而成；调用方应在传入前自行
    /// URL 编码（或用 `std.Uri.percentEncodeBackwardsCompatible`），与 Go 行为对齐。
    pub fn getRedirectURL(self: *Self, redirect_uri: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            oauthTargetURL,
            .{ self.ctx.config.corp_id, redirect_uri },
        );
    }

    /// 构造网页授权跳转 URL（snsapi_privateinfo）。
    pub fn getRedirectPrivateURL(self: *Self, redirect_uri: []const u8, agent_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            oauthTargetPrivateURL,
            .{ self.ctx.config.corp_id, redirect_uri, agent_id },
        );
    }

    /// 构造独立窗口登录二维码 URL。
    ///
    /// `state` 通常由调用方生成（Go 版使用 `util.RandomStr(16)`）。
    pub fn getQrContentTargetURL(self: *Self, redirect_uri: []const u8, state: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            oauthQrContentTargetURL,
            .{ self.ctx.config.corp_id, self.ctx.config.agent_id, redirect_uri, state },
        );
    }

    /// 根据 code 获取用户身份 / userid。对应 Go 的 `UserFromCode`。
    ///
    /// 命中 `UserId` 字段时为企业成员；只有 `OpenID` 时为非企业成员。
    /// 调用方负责 `deinit` 返回值的字符串字段吗？——返回的是切片视图（来自 JSON 解析
    /// 的内存），生命周期与 `ResUserInfo` 绑定；不要单独 free 字段，统一走 `parsed.deinit()`。
    /// 此处我们直接返回 `ResUserInfo` 值给调用方，所有权仍归内部解析缓冲；
    /// 调用方若需要长期持有字段，请自行 `dupe`。
    pub fn userInfoToId(self: *Self, code: []const u8) !ResUserInfo {
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

        var parsed = std.json.parseFromSlice(ResUserInfo, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 获取访问用户身份 / 登录身份。对应 Go 的 `GetUserInfo`。
    pub fn getUserInfo(self: *Self, code: []const u8) !GetUserInfoResponse {
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

        var parsed = std.json.parseFromSlice(GetUserInfoResponse, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 获取访问用户敏感信息（POST JSON）。对应 Go 的 `GetUserDetail`。
    ///
    /// 调用方只需传入 `user_ticket`；请求体由本方法拼接。
    pub fn getUserDetail(self: *Self, user_ticket: []const u8) !GetUserDetailResponse {
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

        var parsed = std.json.parseFromSlice(GetUserDetailResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 获取用户二次验证信息（POST JSON）。
    pub fn getTfaInfo(self: *Self, code: []const u8) !GetTfaInfoResponse {
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

        var parsed = std.json.parseFromSlice(GetTfaInfoResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
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

        if (try util_error.decodeWithCommonError(self.allocator, resp, "TfaSucc")) |_| {
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

test "Oauth.getRedirectURL 拼接 corp_id 和 redirect_uri" {
    var ctx: Context = .{
        .config = .{ .corp_id = "wwabc123" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fba_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    var o = Oauth.init(&ctx, fba.allocator());
    const url = try o.getRedirectURL("https://example.com/cb");
    try std.testing.expect(std.mem.indexOf(u8, url, "wwabc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "https://example.com/cb") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=snsapi_base") != null);
}

test "Oauth.getRedirectPrivateURL 包含 agentid" {
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