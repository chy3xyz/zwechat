// SPDX-License-Identifier: Apache-2.0
//! miniprogram/operation — 小程序运维中心
//!
//! 对应 `_ref/wechat/miniprogram/operation/operation.go`：域名配置、性能数据、
//! 访问来源、客户端版本、实时日志、用户反馈、JS 错误、分阶段发布。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const GetDomainInfoRequest = struct {
    action: []const u8 = "",
};

pub const GetDomainInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    requestdomain: []const []const u8 = &.{},
    wsrequestdomain: []const []const u8 = &.{},
    uploaddomain: []const []const u8 = &.{},
    downloaddomain: []const []const u8 = &.{},
    udpdomain: []const []const u8 = &.{},
    bizdomain: []const []const u8 = &.{},
};

pub const GetPerformanceRequest = struct {
    cost_time_type: i64 = 0,
    default_start_time: i64 = 0,
    default_end_time: i64 = 0,
    device: []const u8 = "",
    is_download_code: []const u8 = "",
    scene: []const u8 = "",
    networktype: []const u8 = "",
};

pub const GetPerformanceResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    default_time_data: []const u8 = "",
    compare_time_data: []const u8 = "",
};

pub const GetSceneListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    scene: []const Scene = &.{},
};

pub const Scene = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const GetVersionListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    cvlist: []const ClientVersion = &.{},
};

pub const ClientVersion = struct {
    type: i64 = 0,
    client_version_list: []const []const u8 = &.{},
};

pub const RealTimeLogSearchRequest = struct {
    date: []const u8 = "",
    begin_time: i64 = 0,
    end_time: i64 = 0,
    start: i64 = 0,
    limit: i64 = 0,
    level: i64 = 0,
    trace_id: []const u8 = "",
    url: []const u8 = "",
    id: []const u8 = "",
    filter_msg: []const u8 = "",
};

pub const RealTimeLogSearchResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    data: RealTimeLogSearchData = .{},
};

pub const RealTimeLogSearchData = struct {
    list: []const RealTimeLogSearchDataList = &.{},
    total: i64 = 0,
};

pub const RealTimeLogSearchDataList = struct {
    level: i64 = 0,
    libraryVersion: []const u8 = "",
    clientVersion: []const u8 = "",
    id: []const u8 = "",
    timestamp: i64 = 0,
    platform: i64 = 0,
    url: []const u8 = "",
    traceid: []const u8 = "",
    filterMsg: []const u8 = "",
    msg: []const RealTimeLogSearchDataListMsg = &.{},
};

pub const RealTimeLogSearchDataListMsg = struct {
    time: i64 = 0,
    level: i64 = 0,
    msg: []const []const u8 = &.{},
};

pub const GetFeedbackListRequest = struct {
    page: i64 = 0,
    num: i64 = 0,
    type: i64 = 0,
};

pub const GetFeedbackListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total_num: i64 = 0,
    list: []const Feedback = &.{},
};

pub const Feedback = struct {
    record_id: i64 = 0,
    create_time: i64 = 0,
    content: []const u8 = "",
    phone: []const u8 = "",
    openid: []const u8 = "",
    nickname: []const u8 = "",
    head_url: []const u8 = "",
    type: i64 = 0,
    mediaIds: []const []const u8 = &.{},
    systemInfo: []const u8 = "",
};

pub const GetJsErrDetailRequest = struct {
    startTime: []const u8 = "",
    endTime: []const u8 = "",
    errorMsgMd5: []const u8 = "",
    errorStackMd5: []const u8 = "",
    appVersion: []const u8 = "",
    sdkVersion: []const u8 = "",
    osName: []const u8 = "",
    clientVersion: []const u8 = "",
    openid: []const u8 = "",
    offset: i64 = 0,
    limit: i64 = 0,
    desc: []const u8 = "",
};

pub const GetJsErrDetailResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    totalCount: i64 = 0,
    openid: []const u8 = "",
    data: []const JsErrDetailData = &.{},
};

pub const JsErrDetailData = struct {
    Count: []const u8 = "",
    sdkVersion: []const u8 = "",
    ClientVersion: []const u8 = "",
    errorStackMd5: []const u8 = "",
    TimeStamp: []const u8 = "",
    appVersion: []const u8 = "",
    errorMsgMd5: []const u8 = "",
    errorMsg: []const u8 = "",
    errorStack: []const u8 = "",
    Ds: []const u8 = "",
    OsName: []const u8 = "",
    openId: []const u8 = "",
    pluginversion: []const u8 = "",
    appId: []const u8 = "",
    DeviceModel: []const u8 = "",
    source: []const u8 = "",
    route: []const u8 = "",
    Uin: []const u8 = "",
    nickname: []const u8 = "",
};

pub const GetJsErrListRequest = struct {
    appVersion: []const u8 = "",
    errType: []const u8 = "",
    startTime: []const u8 = "",
    endTime: []const u8 = "",
    keyword: []const u8 = "",
    openid: []const u8 = "",
    orderby: []const u8 = "",
    desc: []const u8 = "",
    offset: i64 = 0,
    limit: i64 = 0,
};

pub const GetJsErrListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    totalCount: i64 = 0,
    openid: []const u8 = "",
    data: []const JsErrListData = &.{},
};

pub const JsErrListData = struct {
    errorMsgMd5: []const u8 = "",
    errorMsg: []const u8 = "",
    uv: i64 = 0,
    pv: i64 = 0,
    errorStackMd5: []const u8 = "",
    errorStack: []const u8 = "",
    pvPercent: []const u8 = "",
    uvPercent: []const u8 = "",
};

pub const GetGrayReleasePlanResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    gray_release_plan: GrayReleasePlanDetail = .{},
};

pub const GrayReleasePlanDetail = struct {
    status: i64 = 0,
    create_timestamp: i64 = 0,
    gray_percentage: i64 = 0,
    support_experiencer_first: bool = false,
    support_debuger_first: bool = false,
};

/// 小程序运维中心模块。
pub const Operation = struct {
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

    /// 查询域名配置。
    pub fn getDomainInfo(self: *Self, req: GetDomainInfoRequest) !std.json.Parsed(GetDomainInfoResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"action\":\"{s}\"}}", .{req.action});
        defer self.allocator.free(body);
        return self.postParsed("wxa/getwxadevinfo", body, GetDomainInfoResponse);
    }

    /// 获取性能数据。
    pub fn getPerformance(self: *Self, req: GetPerformanceRequest) !std.json.Parsed(GetPerformanceResponse) {
        const body = try jsonStringifyPerformance(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("wxaapi/log/get_performance", body, GetPerformanceResponse);
    }

    /// 获取访问来源。
    pub fn getSceneList(self: *Self) !std.json.Parsed(GetSceneListResponse) {
        return self.getParsed("wxaapi/log/get_scene", GetSceneListResponse);
    }

    /// 获取客户端版本。
    pub fn getVersionList(self: *Self) !std.json.Parsed(GetVersionListResponse) {
        return self.getParsed("wxaapi/log/get_client_version", GetVersionListResponse);
    }

    /// 查询实时日志。
    pub fn realTimeLogSearch(self: *Self, req: RealTimeLogSearchRequest) !std.json.Parsed(RealTimeLogSearchResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        var uri: std.ArrayListUnmanaged(u8) = .empty;
        defer uri.deinit(self.allocator);
        try uri.print(self.allocator, "https://api.weixin.qq.com/wxaapi/userlog/userlog_search?access_token={s}&date={s}&begintime={d}&endtime={d}", .{ access_token, req.date, req.begin_time, req.end_time });
        if (req.start > 0) try uri.print(self.allocator, "&start={d}", .{req.start});
        if (req.limit > 0) try uri.print(self.allocator, "&limit={d}", .{req.limit});
        if (req.trace_id.len > 0) try uri.print(self.allocator, "&traceId={s}", .{req.trace_id});
        if (req.url.len > 0) try uri.print(self.allocator, "&url={s}", .{req.url});
        if (req.id.len > 0) try uri.print(self.allocator, "&id={s}", .{req.id});
        if (req.filter_msg.len > 0) try uri.print(self.allocator, "&filterMsg={s}", .{req.filter_msg});
        if (req.level > 0) try uri.print(self.allocator, "&level={d}", .{req.level});

        return self.getParsedUri(uri.items, RealTimeLogSearchResponse);
    }

    /// 获取用户反馈列表。
    pub fn getFeedbackList(self: *Self, req: GetFeedbackListRequest) !std.json.Parsed(GetFeedbackListResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        var uri: std.ArrayListUnmanaged(u8) = .empty;
        defer uri.deinit(self.allocator);
        try uri.print(self.allocator, "https://api.weixin.qq.com/wxaapi/feedback/list?access_token={s}&page={d}&num={d}", .{ access_token, req.page, req.num });
        if (req.type > 0) try uri.print(self.allocator, "&type={d}", .{req.type});

        return self.getParsedUri(uri.items, GetFeedbackListResponse);
    }

    /// 查询 js 错误详情。
    pub fn getJsErrDetail(self: *Self, req: GetJsErrDetailRequest) !std.json.Parsed(GetJsErrDetailResponse) {
        const body = try jsonStringifyJsErrDetail(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("wxaapi/log/jserr_detail", body, GetJsErrDetailResponse);
    }

    /// 查询错误列表。
    pub fn getJsErrList(self: *Self, req: GetJsErrListRequest) !std.json.Parsed(GetJsErrListResponse) {
        const body = try jsonStringifyJsErrList(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("wxaapi/log/jserr_list", body, GetJsErrListResponse);
    }

    /// 获取分阶段发布详情。
    pub fn getGrayReleasePlan(self: *Self) !std.json.Parsed(GetGrayReleasePlanResponse) {
        return self.getParsed("wxa/getgrayreleaseplan", GetGrayReleasePlanResponse);
    }

    fn postParsed(self: *Self, endpoint: []const u8, body: []const u8, comptime T: type) !std.json.Parsed(T) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(self.allocator, "https://api.weixin.qq.com/{s}?access_token={s}", .{ endpoint, access_token });
        defer self.allocator.free(uri);

        const resp = try self.postJSON(uri, body);
        defer self.allocator.free(resp);
        return parseCommon(self.allocator, resp, T);
    }

    fn getParsed(self: *Self, endpoint: []const u8, comptime T: type) !std.json.Parsed(T) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(self.allocator, "https://api.weixin.qq.com/{s}?access_token={s}", .{ endpoint, access_token });
        defer self.allocator.free(uri);
        return self.getParsedUri(uri, T);
    }

    fn getParsedUri(self: *Self, uri: []const u8, comptime T: type) !std.json.Parsed(T) {
        const resp = try self.httpGet(uri);
        defer self.allocator.free(resp);
        return parseCommon(self.allocator, resp, T);
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

    /// GET；注入 transport 时使用之，否则走线程默认 client。
    fn httpGet(self: *Self, uri: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.get(uri);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.get(uri);
    }
};

fn parseCommon(allocator: std.mem.Allocator, resp: []const u8, comptime T: type) !std.json.Parsed(T) {
    var parsed = std.json.parseFromSlice(T, allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        return util_error.WechatError.DecodeError;
    };
    errdefer parsed.deinit();
    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    return parsed;
}

fn jsonStringifyPerformance(allocator: std.mem.Allocator, req: GetPerformanceRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("cost_time_type");
    try s.write(req.cost_time_type);
    try s.objectField("default_start_time");
    try s.write(req.default_start_time);
    try s.objectField("default_end_time");
    try s.write(req.default_end_time);
    try s.objectField("device");
    try s.write(req.device);
    try s.objectField("is_download_code");
    try s.write(req.is_download_code);
    try s.objectField("scene");
    try s.write(req.scene);
    try s.objectField("networktype");
    try s.write(req.networktype);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyJsErrDetail(allocator: std.mem.Allocator, req: GetJsErrDetailRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "startTime", .value = req.startTime },
        .{ .name = "endTime", .value = req.endTime },
        .{ .name = "errorMsgMd5", .value = req.errorMsgMd5 },
        .{ .name = "errorStackMd5", .value = req.errorStackMd5 },
        .{ .name = "appVersion", .value = req.appVersion },
        .{ .name = "sdkVersion", .value = req.sdkVersion },
        .{ .name = "osName", .value = req.osName },
        .{ .name = "clientVersion", .value = req.clientVersion },
        .{ .name = "openid", .value = req.openid },
        .{ .name = "desc", .value = req.desc },
    };
    for (fields) |f| {
        try s.objectField(f.name);
        try s.write(f.value);
    }
    try s.objectField("offset");
    try s.write(req.offset);
    try s.objectField("limit");
    try s.write(req.limit);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyJsErrList(allocator: std.mem.Allocator, req: GetJsErrListRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "appVersion", .value = req.appVersion },
        .{ .name = "errType", .value = req.errType },
        .{ .name = "startTime", .value = req.startTime },
        .{ .name = "endTime", .value = req.endTime },
        .{ .name = "keyword", .value = req.keyword },
        .{ .name = "openid", .value = req.openid },
        .{ .name = "orderby", .value = req.orderby },
        .{ .name = "desc", .value = req.desc },
    };
    for (fields) |f| {
        try s.objectField(f.name);
        try s.write(f.value);
    }
    try s.objectField("offset");
    try s.write(req.offset);
    try s.objectField("limit");
    try s.write(req.limit);
    try s.endObject();
    return out.toOwnedSlice();
}

test "Operation.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-op" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const o = Operation.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-op", o.ctx.config.app_id);
}

test "GetDomainInfoResponse 默认值" {
    const r = GetDomainInfoResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}

// ── 可注入 transport 测试 ────────────────────────────────────────────────

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
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "getDomainInfo POST 域名配置并解析（回归：泛型 T 参数错位）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"requestdomain\":[\"https://a.com\"],\"wsrequestdomain\":[\"wss://b.com\"],\"uploaddomain\":[],\"downloaddomain\":[],\"udpdomain\":[],\"bizdomain\":[]}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var o = Operation.init(&ctx, allocator);
    o.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try o.getDomainInfo(.{ .action = "get" });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/getwxadevinfo?access_token=token-abc", tt.uri);
    try std.testing.expectEqualStrings("{\"action\":\"get\"}", tt.payload);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.requestdomain.len);
    try std.testing.expectEqualStrings("https://a.com", parsed.value.requestdomain[0]);
}

test "getSceneList GET 访问来源并解析（回归：getParsed 泛型 T 参数错位）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"scene\":[{\"name\":\"扫码\",\"value\":\"1001\"}]}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var o = Operation.init(&ctx, allocator);
    o.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try o.getSceneList();
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxaapi/log/get_scene?access_token=token-abc", tt.uri);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.scene.len);
    try std.testing.expectEqualStrings("扫码", parsed.value.scene[0].name);
}
