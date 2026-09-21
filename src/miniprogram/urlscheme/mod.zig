// SPDX-License-Identifier: Apache-2.0
//! miniprogram/urlscheme — 小程序 URL Scheme
//!
//! 对应 `_ref/wechat/miniprogram/urlscheme/`：
//! `wxa/generatescheme` 生成 URL Scheme、`wxa/queryscheme` 查询 Scheme 码。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// `wxa/generatescheme` 响应。
pub const GenerateResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    openlink: []const u8 = "",
};

/// `wxa/queryscheme` 请求（对照 Go `QueryScheme`）。
pub const QuerySchemeRequest = struct {
    /// 小程序 scheme 码。
    scheme: []const u8,
    /// 查询类型：0:查询 scheme 信息；1:查询 pv 等访问数据。
    query_type: i64 = 0,
};

/// scheme 配置（对照 Go `SchemeInfo`）。
pub const SchemeInfo = struct {
    /// 小程序 appid。
    appid: []const u8 = "",
    /// 小程序页面路径。
    path: []const u8 = "",
    /// 小程序页面 query。
    query: []const u8 = "",
    /// 创建时间，Unix 时间戳。
    create_time: i64 = 0,
    /// 到期失效时间，Unix 时间戳，0 表示永久生效。
    expire_time: i64 = 0,
    /// 要打开的小程序版本（release / trial / develop）。
    env_version: []const u8 = "",
};

/// quota 配置（对照 Go `QuotaInfo`）。
pub const QuotaInfo = struct {
    remain_visit_quota: i64 = 0,
};

/// `wxa/queryscheme` 响应（对照 Go `ResQueryScheme`）。
pub const QuerySchemeResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    scheme_info: SchemeInfo = .{},
    /// 访问该链接的 openid，没有用户访问过则为空字符串。
    visit_openid: []const u8 = "",
    quota_info: QuotaInfo = .{},
};

/// URL Scheme 模块。
pub const URLScheme = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 生成 URL Scheme。
    ///
    /// `jump_wxa_json` 为 `jump_wxa` 对象的 JSON 字符串，例如：
    /// `{"path":"pages/index","query":"a=1"}`。
    /// 返回的 `std.json.Parsed(GenerateResponse)` 由调用方持有并负责 `deinit`。
    pub fn generate(self: *Self, jump_wxa_json: []const u8) !std.json.Parsed(GenerateResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/generatescheme?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jump_wxa\":{s}}}",
            .{jump_wxa_json},
        );
        defer self.allocator.free(body_json);

        const resp = try self.postJSON(uri, body_json);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GenerateResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 查询小程序 scheme 码（`wxa/queryscheme`，对照 Go `QuerySchemeWithRes`）。
    ///
    /// 返回的 `std.json.Parsed(QuerySchemeResponse)` 由调用方持有并负责 `deinit`。
    pub fn queryScheme(self: *Self, req: QuerySchemeRequest) !std.json.Parsed(QuerySchemeResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/queryscheme?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try encodeQuerySchemeBody(self.allocator, req);
        defer self.allocator.free(body);

        const resp = try self.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(QuerySchemeResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// POST JSON；注入 transport 时使用之，否则走线程默认 client。
    fn postJSON(self: *Self, uri: []const u8, body: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, body);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body);
    }
};

/// 构造 `wxa/queryscheme` 的 JSON 请求体（scheme 字段经 Stringify 转义）。
fn encodeQuerySchemeBody(allocator: std.mem.Allocator, req: QuerySchemeRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("scheme");
    try s.write(req.scheme);
    try s.objectField("query_type");
    try s.write(req.query_type);
    try s.endObject();
    return out.toOwnedSlice();
}

test "URLScheme.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-link" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const u = URLScheme.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-link", u.ctx.config.app_id);
}

// —— 可注入 transport 测试 ——

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 记录 method / uri / payload 并返回预设响应的 transport。
const CapturingTransport = struct {
    method: std.http.Method = .GET,
    uri: []const u8 = "",
    payload: []const u8 = "",
    response: []const u8 = "",

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = content_type;
        const self: *CapturingTransport = @ptrCast(@alignCast(ctx));
        self.method = method;
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }

    fn deinit(self: *CapturingTransport, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.payload);
    }
};

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-link" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "queryScheme POST 请求并解析 scheme_info / quota_info" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"scheme_info\":{\"appid\":\"wx-link\",\"path\":\"pages/index\",\"query\":\"a=1\",\"create_time\":1629121902,\"expire_time\":0,\"env_version\":\"release\"},\"visit_openid\":\"oVISITOR\",\"quota_info\":{\"remain_visit_quota\":4999}}",
    };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var u = URLScheme.init(&ctx, allocator);
    u.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try u.queryScheme(.{ .scheme = "weixin://dl/business/?t=T_1", .query_type = 0 });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/queryscheme?access_token=token-abc", tt.uri);
    try std.testing.expectEqualStrings("{\"scheme\":\"weixin://dl/business/?t=T_1\",\"query_type\":0}", tt.payload);

    try std.testing.expectEqualStrings("wx-link", parsed.value.scheme_info.appid);
    try std.testing.expectEqualStrings("pages/index", parsed.value.scheme_info.path);
    try std.testing.expectEqualStrings("a=1", parsed.value.scheme_info.query);
    try std.testing.expectEqual(@as(i64, 1629121902), parsed.value.scheme_info.create_time);
    try std.testing.expectEqualStrings("release", parsed.value.scheme_info.env_version);
    try std.testing.expectEqualStrings("oVISITOR", parsed.value.visit_openid);
    try std.testing.expectEqual(@as(i64, 4999), parsed.value.quota_info.remain_visit_quota);
}

test "queryScheme errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"errcode\":40013,\"errmsg\":\"invalid appid\"}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var u = URLScheme.init(&ctx, allocator);
    u.setTransport(CapturingTransport.dispatch, &tt);

    const result = u.queryScheme(.{ .scheme = "weixin://dl/business/?t=BAD" });
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "generate POST 请求并解析 openlink" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"openlink\":\"weixin://dl/business/?t=abc\"}",
    };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var u = URLScheme.init(&ctx, allocator);
    u.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try u.generate("{\"path\":\"pages/index\"}");
    defer parsed.deinit();
    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/generatescheme?access_token=token-abc", tt.uri);
    try std.testing.expectEqualStrings("{\"jump_wxa\":{\"path\":\"pages/index\"}}", tt.payload);
    try std.testing.expectEqualStrings("weixin://dl/business/?t=abc", parsed.value.openlink);
}
