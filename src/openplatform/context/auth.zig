// SPDX-License-Identifier: Apache-2.0
//! openplatform/context/auth — 第三方平台「首次授权链路」
//!
//! 对应 `_ref/wechat/openplatform/context/accessToken.go` 中除 token 获取/刷新外的
//! 授权接口：
//! - `getPreCode` — 获取预授权码 `pre_auth_code`（Go `GetPreCode`）；
//! - `queryAuthCode` — 用授权码换取 authorizer 凭据并回写双缓存
//!   （Go `QueryAuthCode`，本仓库按任务要求补上缓存回写）；
//! - `getAuthrInfo` — 获取授权方帐号基本信息（Go `GetAuthrInfo`）；
//! - `getComponentLoginPage` / `getBindComponentURL` / `getBindComponentURLV2` —
//!   构造授权链接（纯本地字符串拼接，无额外 HTTP，内部先取 pre_auth_code）。
//!
//! component_access_token 一律走「仅读缓存」语义（Go `GetComponentAccessTokenContext`）：
//! 调用方需先用 `getComponentAccessToken`（带 verify_ticket）回源换取并落缓存。

const std = @import("std");
const Context = @import("mod.zig").Context;
const cache_mod = @import("../../cache/mod.zig");
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const access_token = @import("access_token.zig");

pub const Error = access_token.Error || error{ AuthorizationCodeRequired, WriteFailed };

/// 获取预授权码接口 URL（`{s}` 为 component_access_token）。
const getPreCodeURL = "https://api.weixin.qq.com/cgi-bin/component/api_create_preauthcode?component_access_token={s}";

/// 授权码换 authorizer 凭据接口 URL（`{s}` 为 component_access_token）。
const queryAuthURL = "https://api.weixin.qq.com/cgi-bin/component/api_query_auth?component_access_token={s}";

/// 获取授权方信息接口 URL（`{s}` 为 component_access_token）。
const getComponentInfoURL = "https://api.weixin.qq.com/cgi-bin/component/api_get_authorizer_info?component_access_token={s}";

/// 第三方平台扫码授权链接（Go `componentLoginURL`）。
const componentLoginURL = "https://mp.weixin.qq.com/cgi-bin/componentloginpage?component_appid={s}&pre_auth_code={s}&redirect_uri={s}&auth_type={d}&biz_appid={s}";

/// 链接跳转授权链接（移动端，Go `bindComponentURL`）。
const bindComponentURL = "https://mp.weixin.qq.com/safe/bindcomponent?action=bindcomponent&auth_type={d}&no_scan=1&component_appid={s}&pre_auth_code={s}&redirect_uri={s}&biz_appid={s}#wechat_redirect";

/// 新版链接跳转授权链接（移动端，Go `bindComponentURLV2`）。
const bindComponentURLV2 = "https://open.weixin.qq.com/wxaopen/safe/bindcomponent?action=bindcomponent&auth_type={d}&no_scan=1&component_appid={s}&pre_auth_code={s}&redirect_uri={s}&biz_appid={s}#wechat_redirect";

/// 微信返回接口中各种「类型/权限 id」的包装（Go `ID`）。
pub const ID = struct {
    id: i64 = 0,
};

/// 授权的接口内容（Go `AuthFuncInfo`）。
pub const AuthFuncInfo = struct {
    funcscope_category: ID = .{},
};

/// 授权的基本信息（Go `AuthBaseInfo`，字段为自有切片，见 `deinit`）。
pub const AuthBaseInfo = struct {
    /// 授权方 AppID（`authorizer_appid`）。
    appid: []u8,
    /// 授权方接口调用凭据（`authorizer_access_token`）。
    access_token: []u8,
    /// 凭据有效期（秒，`expires_in`）。
    expires_in: i64 = 0,
    /// 授权方刷新凭据（`authorizer_refresh_token`）。
    refresh_token: []u8,
    /// 授权的功能集（`func_info`）。
    func_info: []AuthFuncInfo,

    /// 释放全部持有切片（`func_info` 元素只含标量，无需逐个释放）。
    pub fn deinit(self: *AuthBaseInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.appid);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
        allocator.free(self.func_info);
    }
};

/// 授权账号的基础配置（Go `AuthorizerBasicConfig`）。
pub const AuthorizerBasicConfig = struct {
    isPhoneConfigured: bool = false,
    isEmailConfigured: bool = false,
};

/// 授权账号小程序配置的类目信息（Go `CategoriesInfo`）。
pub const CategoriesInfo = struct {
    first: []const u8 = "",
    second: []const u8 = "",
};

/// 授权账号为小程序时的网络配置（Go `MiniProgramInfo.Network`）。
pub const MiniProgramNetwork = struct {
    RequestDomain: []const []const u8 = &.{},
    WsRequestDomain: []const []const u8 = &.{},
    UploadDomain: []const []const u8 = &.{},
    DownloadDomain: []const []const u8 = &.{},
    BizDomain: []const []const u8 = &.{},
    UDPDomain: []const []const u8 = &.{},
};

/// 授权账号小程序配置（授权账号为小程序时存在，Go `MiniProgramInfo`）。
pub const MiniProgramInfo = struct {
    network: MiniProgramNetwork = .{},
    categories: []const CategoriesInfo = &.{},
};

/// 授权账号的开放能力信息（Go `AuthorizerInfo.BusinessInfo`，值是 "0"/"1" 字符串）。
pub const BusinessInfo = struct {
    open_store: []const u8 = "",
    open_scan: []const u8 = "",
    open_pay: []const u8 = "",
    open_card: []const u8 = "",
    open_shake: []const u8 = "",
};

/// 授权方详细信息（Go `AuthorizerInfo`）。
///
/// 所有字符串切片借用自所属 `std.json.Parsed` 的所有权域，调用方只需
/// `parsed.deinit()`，无需（也不能）逐个 free。
pub const AuthorizerInfo = struct {
    nick_name: []const u8 = "",
    head_img: []const u8 = "",
    service_type_info: ID = .{},
    verify_type_info: ID = .{},
    user_name: []const u8 = "",
    principal_name: []const u8 = "",
    business_info: BusinessInfo = .{},
    alias: []const u8 = "",
    qrcode_url: []const u8 = "",
    /// 注意：微信 JSON key 是大写开头的 `MiniProgramInfo`（Go 结构标签如此）。
    @"MiniProgramInfo": ?MiniProgramInfo = null,
    register_type: i64 = 0,
    account_status: i64 = 0,
    basic_config: ?AuthorizerBasicConfig = null,
};

/// `getAuthrInfo` 的响应体（`authorization_info` 复用 `AuthBaseInfo` 的借用形态：
/// 无自有切片，字符串借用自 `Parsed` 所有权域）。
pub const AuthrInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    authorizer_info: AuthorizerInfo = .{},
    authorization_info: AuthrAuthInfo = .{},
};

/// `getAuthrInfo` 响应中的授权信息（Go `AuthBaseInfo`，此处 token 字段恒为空：
/// 该接口不返回凭据，凭据走 `queryAuthCode` / `refreshAuthrAccessToken`）。
pub const AuthrAuthInfo = struct {
    authorizer_appid: []const u8 = "",
    func_info: []const AuthFuncInfo = &.{},
};

/// queryAuthCode 的原始响应体（字段名与微信接口逐字一致）。
const QueryAuthResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    authorization_info: QueryAuthInfo = .{},
};

const QueryAuthInfo = struct {
    authorizer_appid: []const u8 = "",
    authorizer_access_token: []const u8 = "",
    expires_in: i64 = 0,
    authorizer_refresh_token: []const u8 = "",
    func_info: []const AuthFuncInfo = &.{},
};

const PreCodeResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    pre_auth_code: []const u8 = "",
};

/// 统一的 POST JSON 出口（与 access_token.zig 的私有 postJSON 同惯例）。
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

/// 按 Go `url.QueryEscape` 规则转义 query 参数：
/// 仅保留 `[A-Za-z0-9-_.~]`，空格转 `+`，其余 `%XX`。
///
/// 注意不能用 `std.Uri.Component.formatQuery`——它的 `isQueryChar` 允许
/// `&`/`=`/`?`/`/`/`:` 原样通过，与 Go 语义不符。
fn escapeQuery(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.writer.writeByte(c);
        } else if (c == ' ') {
            try out.writer.writeByte('+');
        } else {
            try out.writer.print("%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice();
}

/// 读取缓存中的 component_access_token（不发起网络请求）。
///
/// 缓存未命中返回 `error.VerifyTicketRequired`，调用方应先带 `verify_ticket`
/// 调 `Context.getComponentAccessToken` 回源。
fn requireComponentToken(ctx: *Context, allocator: std.mem.Allocator) Error![]u8 {
    return access_token.getCachedComponentAccessToken(ctx, allocator);
}

/// 获取预授权码 `pre_auth_code`（Go `GetPreCodeContext`）。
///
/// URL：`POST /cgi-bin/component/api_create_preauthcode?component_access_token={s}`，
/// body `{"component_appid": ...}`。返回的字符串由调用方负责 `allocator.free`。
pub fn getPreCode(ctx: *Context, allocator: std.mem.Allocator) Error![]u8 {
    const component_token = try requireComponentToken(ctx, allocator);
    defer allocator.free(component_token);

    const uri = try std.fmt.allocPrint(allocator, getPreCodeURL, .{component_token});
    defer allocator.free(uri);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("component_appid");
    try s.write(ctx.config.app_id);
    try s.endObject();
    const body = try out.toOwnedSlice();
    defer allocator.free(body);

    const resp = try postJSON(ctx, allocator, uri, body);
    defer allocator.free(resp);

    var parsed = std.json.parseFromSlice(PreCodeResponse, allocator, resp, .{ .ignore_unknown_fields = true }) catch {
        return util_error.WechatError.DecodeError;
    };
    defer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    if (parsed.value.pre_auth_code.len == 0) return util_error.WechatError.ApiError;

    return allocator.dupe(u8, parsed.value.pre_auth_code);
}

/// 用授权码换取授权方的接口调用凭据和授权信息（Go `QueryAuthCodeContext`）。
///
/// URL：`POST /cgi-bin/component/api_query_auth?component_access_token={s}`，
/// body `{"component_appid","authorization_code"}`。
///
/// 成功后按 `authorizer_appid` 回写两个缓存 key（与 `getAuthrAccessToken` 约定一致）：
/// - `authorizer_access_token_{appid}` — TTL `credential.tokenTTL(expires_in)`；
/// - `authorizer_refresh_token_{appid}` — 10 年。
///
/// 回写在 `ctx.token_mutex` 内串行执行（与 token 链路一致，防止并发覆盖轮换凭据）。
/// 返回结构体由 `AuthBaseInfo.deinit` 释放。
pub fn queryAuthCode(
    ctx: *Context,
    allocator: std.mem.Allocator,
    authorization_code: []const u8,
) Error!AuthBaseInfo {
    if (authorization_code.len == 0) return error.AuthorizationCodeRequired;
    const cache_inst = ctx.config.cache orelse return error.CacheUnavailable;

    const component_token = try requireComponentToken(ctx, allocator);
    defer allocator.free(component_token);

    const uri = try std.fmt.allocPrint(allocator, queryAuthURL, .{component_token});
    defer allocator.free(uri);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("component_appid");
    try s.write(ctx.config.app_id);
    try s.objectField("authorization_code");
    try s.write(authorization_code);
    try s.endObject();
    const body = try out.toOwnedSlice();
    defer allocator.free(body);

    const resp = try postJSON(ctx, allocator, uri, body);
    defer allocator.free(resp);

    var parsed = std.json.parseFromSlice(QueryAuthResponse, allocator, resp, .{ .ignore_unknown_fields = true }) catch {
        return util_error.WechatError.DecodeError;
    };
    defer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;

    const info = parsed.value.authorization_info;
    if (info.authorizer_access_token.len == 0) return util_error.WechatError.ApiError;

    var result = blk: {
        const appid = try allocator.dupe(u8, info.authorizer_appid);
        errdefer allocator.free(appid);
        const access_token_s = try allocator.dupe(u8, info.authorizer_access_token);
        errdefer allocator.free(access_token_s);
        const refresh_token_s = try allocator.dupe(u8, info.authorizer_refresh_token);
        errdefer allocator.free(refresh_token_s);
        const func_info = try allocator.dupe(AuthFuncInfo, info.func_info);
        break :blk AuthBaseInfo{
            .appid = appid,
            .access_token = access_token_s,
            .expires_in = info.expires_in,
            .refresh_token = refresh_token_s,
            .func_info = func_info,
        };
    };
    errdefer result.deinit(allocator);

    // 回写双缓存（token 链路约定：锁内串行，防止并发覆盖轮换凭据）。
    ctx.token_mutex.lock();
    defer ctx.token_mutex.unlock();

    const akey = try std.fmt.allocPrint(allocator, "authorizer_access_token_{s}", .{result.appid});
    defer allocator.free(akey);
    try cache_inst.set(akey, result.access_token, credential.tokenTTL(result.expires_in));

    const rkey = try std.fmt.allocPrint(allocator, "authorizer_refresh_token_{s}", .{result.appid});
    defer allocator.free(rkey);
    try cache_inst.set(rkey, result.refresh_token, 10 * 365 * 24 * 60 * 60);

    return result;
}

/// 获取授权方的帐号基本信息（Go `GetAuthrInfoContext`）。
///
/// URL：`POST /cgi-bin/component/api_get_authorizer_info?component_access_token={s}`，
/// body `{"component_appid","authorizer_appid"}`。
///
/// 返回 `std.json.Parsed(AuthrInfoResponse)`：`.value` 内全部切片借用其所有权域，
/// 调用方读完之后 `deinit` 即可。
pub fn getAuthrInfo(
    ctx: *Context,
    allocator: std.mem.Allocator,
    authorizer_appid: []const u8,
) Error!std.json.Parsed(AuthrInfoResponse) {
    if (authorizer_appid.len == 0) return error.AuthorizerAppidRequired;

    const component_token = try requireComponentToken(ctx, allocator);
    defer allocator.free(component_token);

    const uri = try std.fmt.allocPrint(allocator, getComponentInfoURL, .{component_token});
    defer allocator.free(uri);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("component_appid");
    try s.write(ctx.config.app_id);
    try s.objectField("authorizer_appid");
    try s.write(authorizer_appid);
    try s.endObject();
    const body = try out.toOwnedSlice();
    defer allocator.free(body);

    const resp = try postJSON(ctx, allocator, uri, body);
    defer allocator.free(resp);

    var parsed = std.json.parseFromSlice(AuthrInfoResponse, allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        return util_error.WechatError.DecodeError;
    };
    errdefer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;

    return parsed;
}

/// 构造第三方平台扫码授权链接（Go `GetComponentLoginPageContext`）。
///
/// 内部先调 `getPreCode` 取预授权码，再纯本地拼链接：
/// `https://mp.weixin.qq.com/cgi-bin/componentloginpage?component_appid=...&pre_auth_code=...&redirect_uri=...&auth_type=...&biz_appid=...`
///
/// `redirect_uri` 会按 URI query 规则转义；返回的链接由调用方 `allocator.free`。
pub fn getComponentLoginPage(
    ctx: *Context,
    allocator: std.mem.Allocator,
    redirect_uri: []const u8,
    auth_type: i64,
    biz_app_id: []const u8,
) Error![]u8 {
    const code = try getPreCode(ctx, allocator);
    defer allocator.free(code);

    const escaped = try escapeQuery(allocator, redirect_uri);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator, componentLoginURL, .{
        ctx.config.app_id,
        code,
        escaped,
        auth_type,
        biz_app_id,
    });
}

/// 构造链接跳转授权链接（移动端，Go `GetBindComponentURLContext`）。
///
/// 链接形如
/// `https://mp.weixin.qq.com/safe/bindcomponent?action=bindcomponent&auth_type=...&no_scan=1&component_appid=...&pre_auth_code=...&redirect_uri=...&biz_appid=...#wechat_redirect`。
pub fn getBindComponentURL(
    ctx: *Context,
    allocator: std.mem.Allocator,
    redirect_uri: []const u8,
    auth_type: i64,
    biz_app_id: []const u8,
) Error![]u8 {
    const code = try getPreCode(ctx, allocator);
    defer allocator.free(code);

    const escaped = try escapeQuery(allocator, redirect_uri);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator, bindComponentURL, .{
        auth_type,
        ctx.config.app_id,
        code,
        escaped,
        biz_app_id,
    });
}

/// 构造新版链接跳转授权链接（移动端，Go `GetBindComponentURLV2Context`）。
///
/// 与 `getBindComponentURL` 相同，但 host 为
/// `https://open.weixin.qq.com/wxaopen/safe/bindcomponent`。
pub fn getBindComponentURLV2(
    ctx: *Context,
    allocator: std.mem.Allocator,
    redirect_uri: []const u8,
    auth_type: i64,
    biz_app_id: []const u8,
) Error![]u8 {
    const code = try getPreCode(ctx, allocator);
    defer allocator.free(code);

    const escaped = try escapeQuery(allocator, redirect_uri);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator, bindComponentURLV2, .{
        auth_type,
        ctx.config.app_id,
        code,
        escaped,
        biz_app_id,
    });
}

// ──────────────────────────────────────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────────────────────────────────────

/// 记录 method / uri / payload 的测试 transport（util.MockTransport 只记录 uri，
/// 这里需要同时断言 body 与请求方法）。
const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uris: std.ArrayList([]u8) = .empty,
    payloads: std.ArrayList([]u8) = .empty,
    methods: std.ArrayList(std.http.Method) = .empty,

    fn init(allocator: std.mem.Allocator, response: []const u8) RecordingTransport {
        return .{ .allocator = allocator, .response = response };
    }

    fn deinit(self: *RecordingTransport) void {
        for (self.uris.items) |u| self.allocator.free(u);
        for (self.payloads.items) |p| self.allocator.free(p);
        self.uris.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        self.methods.deinit(self.allocator);
    }

    fn dispatch(
        ctx_ptr: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = content_type;
        const self: *RecordingTransport = @ptrCast(@alignCast(ctx_ptr));
        try self.uris.append(self.allocator, try self.allocator.dupe(u8, uri));
        try self.payloads.append(self.allocator, try self.allocator.dupe(u8, payload));
        try self.methods.append(self.allocator, method);
        return allocator.dupe(u8, self.response);
    }
};

/// 构造带内存 cache + 预置 component token 的测试 Context。
fn testCtx(allocator: std.mem.Allocator, memory: *@import("../../cache/memory.zig").Memory) !Context {
    const ckey = try std.fmt.allocPrint(allocator, "openplatform_component_access_token_{s}", .{"wx-op"});
    defer allocator.free(ckey);
    try memory.asCache().set(ckey, "comp-tok", 7000);
    return .{ .config = .{ .app_id = "wx-op", .app_secret = "sec", .cache = memory.asCache() } };
}

test "getPreCode mock：POST 正确 URL/body 并解析 pre_auth_code" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"pre_auth_code\":\"pre-auth-123\",\"expires_in\":600}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    const code = try getPreCode(&ctx, allocator);
    defer allocator.free(code);
    try std.testing.expectEqualStrings("pre-auth-123", code);

    try std.testing.expectEqual(@as(usize, 1), rec.uris.items.len);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/component/api_create_preauthcode?component_access_token=comp-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqual(std.http.Method.POST, rec.methods.items[0]);
    try std.testing.expectEqualStrings("{\"component_appid\":\"wx-op\"}", rec.payloads.items[0]);
}

test "getPreCode component token 缓存未命中返回 VerifyTicketRequired" {
    const allocator = std.testing.allocator;
    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }
    var ctx: Context = .{ .config = .{ .app_id = "wx-op", .cache = memory.asCache() } };
    const result = getPreCode(&ctx, allocator);
    try std.testing.expectError(error.VerifyTicketRequired, result);
}

test "queryAuthCode 需要 authorization_code" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    const result = queryAuthCode(&ctx, std.testing.allocator, "");
    try std.testing.expectError(error.AuthorizationCodeRequired, result);
}

test "queryAuthCode mock：解析授权信息并回写双缓存" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(
        allocator,
        "{\"authorization_info\":{\"authorizer_appid\":\"wx-authr-1\",\"authorizer_access_token\":\"qa_tok\",\"expires_in\":7200,\"authorizer_refresh_token\":\"qa_rt\",\"func_info\":[{\"funcscope_category\":{\"id\":1}},{\"funcscope_category\":{\"id\":17}}]}}",
    );
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var info = try queryAuthCode(&ctx, allocator, "auth_code_abc");
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings("wx-authr-1", info.appid);
    try std.testing.expectEqualStrings("qa_tok", info.access_token);
    try std.testing.expectEqualStrings("qa_rt", info.refresh_token);
    try std.testing.expectEqual(@as(i64, 7200), info.expires_in);
    try std.testing.expectEqual(@as(usize, 2), info.func_info.len);
    try std.testing.expectEqual(@as(i64, 1), info.func_info[0].funcscope_category.id);
    try std.testing.expectEqual(@as(i64, 17), info.func_info[1].funcscope_category.id);

    // 请求 URL / body 断言。
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/component/api_query_auth?component_access_token=comp-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqual(std.http.Method.POST, rec.methods.items[0]);
    try std.testing.expectEqualStrings(
        "{\"component_appid\":\"wx-op\",\"authorization_code\":\"auth_code_abc\"}",
        rec.payloads.items[0],
    );

    // 双缓存回写：access token 与 refresh token 均可被 getAuthrAccessToken 链路直接消费。
    const cache_inst = ctx.config.cache.?;
    const akey = try std.fmt.allocPrint(allocator, "authorizer_access_token_{s}", .{"wx-authr-1"});
    defer allocator.free(akey);
    try std.testing.expectEqualStrings("qa_tok", (try cache_inst.get(akey)).?);

    const rkey = try std.fmt.allocPrint(allocator, "authorizer_refresh_token_{s}", .{"wx-authr-1"});
    defer allocator.free(rkey);
    try std.testing.expectEqualStrings("qa_rt", (try cache_inst.get(rkey)).?);
}

test "queryAuthCode errcode 非 0 抛 ApiError" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":40013,\"errmsg\":\"invalid appid\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    const result = queryAuthCode(&ctx, allocator, "bad_code");
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "queryAuthCode 全链路：queryAuthCode 回写后 getAuthrAccessToken 缓存命中零请求" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(
        allocator,
        "{\"authorization_info\":{\"authorizer_appid\":\"wx-authr-1\",\"authorizer_access_token\":\"qa_tok\",\"expires_in\":7200,\"authorizer_refresh_token\":\"qa_rt\",\"func_info\":[]}}",
    );
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var info = try queryAuthCode(&ctx, allocator, "auth_code_abc");
    info.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), rec.uris.items.len);

    // 首次授权链路闭环：queryAuthCode 已回写缓存，getAuthrAccessToken 直接命中。
    const tok = try @import("access_token.zig").getAuthrAccessToken(&ctx, allocator, "wx-authr-1");
    defer allocator.free(tok);
    try std.testing.expectEqualStrings("qa_tok", tok);
    try std.testing.expectEqual(@as(usize, 1), rec.uris.items.len);
}

test "getAuthrInfo mock：解析授权方信息（含 MiniProgramInfo 与嵌套字段）" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(
        allocator,
        "{\"authorizer_info\":{\"nick_name\":\"授权方昵称\",\"head_img\":\"http://img\",\"service_type_info\":{\"id\":2},\"verify_type_info\":{\"id\":0},\"user_name\":\"gh_xxx\",\"principal_name\":\"主体\",\"business_info\":{\"open_store\":\"0\",\"open_scan\":\"1\",\"open_pay\":\"1\",\"open_card\":\"0\",\"open_shake\":\"0\"},\"alias\":\"alias_x\",\"qrcode_url\":\"http://qr\",\"MiniProgramInfo\":{\"network\":{\"RequestDomain\":[\"https://a.com\"],\"WsRequestDomain\":[],\"UploadDomain\":[],\"DownloadDomain\":[],\"BizDomain\":[],\"UDPDomain\":[]},\"categories\":[{\"first\":\"类目一\",\"second\":\"类目二\"}]},\"register_type\":0,\"account_status\":1,\"basic_config\":{\"isPhoneConfigured\":true,\"isEmailConfigured\":false}},\"authorization_info\":{\"authorizer_appid\":\"wx-authr-1\",\"func_info\":[{\"funcscope_category\":{\"id\":1}}]}}",
    );
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var parsed = try getAuthrInfo(&ctx, allocator, "wx-authr-1");
    defer parsed.deinit();

    const info = parsed.value.authorizer_info;
    try std.testing.expectEqualStrings("授权方昵称", info.nick_name);
    try std.testing.expectEqualStrings("http://img", info.head_img);
    try std.testing.expectEqual(@as(i64, 2), info.service_type_info.id);
    try std.testing.expectEqual(@as(i64, 0), info.verify_type_info.id);
    try std.testing.expectEqualStrings("gh_xxx", info.user_name);
    try std.testing.expectEqualStrings("主体", info.principal_name);
    try std.testing.expectEqualStrings("1", info.business_info.open_scan);
    try std.testing.expectEqualStrings("alias_x", info.alias);
    try std.testing.expectEqualStrings("http://qr", info.qrcode_url);
    try std.testing.expectEqual(@as(i64, 1), info.account_status);
    try std.testing.expect(info.basic_config != null);
    try std.testing.expect(info.basic_config.?.isPhoneConfigured);
    try std.testing.expect(!info.basic_config.?.isEmailConfigured);

    // 小程序信息子树（JSON key 为大写开头的 MiniProgramInfo）。
    try std.testing.expect(info.@"MiniProgramInfo" != null);
    const mp = info.@"MiniProgramInfo".?;
    try std.testing.expectEqual(@as(usize, 1), mp.network.RequestDomain.len);
    try std.testing.expectEqualStrings("https://a.com", mp.network.RequestDomain[0]);
    try std.testing.expectEqual(@as(usize, 1), mp.categories.len);
    try std.testing.expectEqualStrings("类目一", mp.categories[0].first);
    try std.testing.expectEqualStrings("类目二", mp.categories[0].second);

    // authorization_info 子树（该接口不返回凭据）。
    try std.testing.expectEqualStrings("wx-authr-1", parsed.value.authorization_info.authorizer_appid);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.authorization_info.func_info.len);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.authorization_info.func_info[0].funcscope_category.id);

    // 请求 URL / body 断言。
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/component/api_get_authorizer_info?component_access_token=comp-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqualStrings(
        "{\"component_appid\":\"wx-op\",\"authorizer_appid\":\"wx-authr-1\"}",
        rec.payloads.items[0],
    );
}

test "getAuthrInfo 需要 authorizer_appid" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    const result = getAuthrInfo(&ctx, std.testing.allocator, "");
    try std.testing.expectError(error.AuthorizerAppidRequired, result);
}

test "getComponentLoginPage 构造扫码授权链接并转义 redirect_uri" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"pre_auth_code\":\"pre-auth-9\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    const url = try getComponentLoginPage(&ctx, allocator, "https://cb.example.com/op/cb?a=1&b=2", 3, "wx-biz-1");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://mp.weixin.qq.com/cgi-bin/componentloginpage?component_appid=wx-op&pre_auth_code=pre-auth-9&redirect_uri=https%3A%2F%2Fcb.example.com%2Fop%2Fcb%3Fa%3D1%26b%3D2&auth_type=3&biz_appid=wx-biz-1",
        url,
    );
}

test "getBindComponentURL / V2 构造链接跳转授权链接" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"pre_auth_code\":\"pre-auth-7\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    const url_v1 = try getBindComponentURL(&ctx, allocator, "https://cb.example.com/cb", 1, "");
    defer allocator.free(url_v1);
    try std.testing.expectEqualStrings(
        "https://mp.weixin.qq.com/safe/bindcomponent?action=bindcomponent&auth_type=1&no_scan=1&component_appid=wx-op&pre_auth_code=pre-auth-7&redirect_uri=https%3A%2F%2Fcb.example.com%2Fcb&biz_appid=#wechat_redirect",
        url_v1,
    );

    const url_v2 = try getBindComponentURLV2(&ctx, allocator, "https://cb.example.com/cb", 2, "wx-biz-2");
    defer allocator.free(url_v2);
    try std.testing.expectEqualStrings(
        "https://open.weixin.qq.com/wxaopen/safe/bindcomponent?action=bindcomponent&auth_type=2&no_scan=1&component_appid=wx-op&pre_auth_code=pre-auth-7&redirect_uri=https%3A%2F%2Fcb.example.com%2Fcb&biz_appid=wx-biz-2#wechat_redirect",
        url_v2,
    );

    // 两个链接各触发一次 getPreCode（本测试中 pre_auth_code 不缓存）。
    try std.testing.expectEqual(@as(usize, 2), rec.uris.items.len);
}
