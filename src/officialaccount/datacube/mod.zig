// SPDX-License-Identifier: Apache-2.0
//! officialaccount/datacube — 数据统计
//!
//! 提供公众号用户、消息、接口、图文、分享传播及流量主广告等维度的统计接口。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 广告位类型（对照 publisher.go `AdSlot`），用于 `getPublisherAdPosGeneral` 的 `ad_slot` 参数。
pub const AdSlot = struct {
    /// 公众号底部广告
    pub const biz_bottom = "SLOT_ID_BIZ_BOTTOM";
    /// 公众号文中广告
    pub const biz_mid_context = "SLOT_ID_BIZ_MID_CONTEXT";
    /// 公众号视频后贴
    pub const biz_video_end = "SLOT_ID_BIZ_VIDEO_END";
    /// 公众号互选广告
    pub const biz_sponsor = "SLOT_ID_BIZ_SPONSOR";
    /// 公众号返佣商品
    pub const biz_cps = "SLOT_ID_BIZ_CPS";
    /// 小程序 banner
    pub const weapp_banner = "SLOT_ID_WEAPP_BANNER";
    /// 小程序激励视频
    pub const weapp_reward_video = "SLOT_ID_WEAPP_REWARD_VIDEO";
    /// 小程序插屏广告
    pub const weapp_interstitial = "SLOT_ID_WEAPP_INTERSTITIAL";
    /// 小程序视频广告
    pub const weapp_video_feeds = "SLOT_ID_WEAPP_VIDEO_FEEDS";
    /// 小程序视频前贴
    pub const weapp_video_begin = "SLOT_ID_WEAPP_VIDEO_BEGIN";
    /// 小程序格子广告
    pub const weapp_box = "SLOT_ID_WEAPP_BOX";
};

pub const DataCube = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 获取用户增减数据（begin_date / end_date 格式：YYYY-MM-DD）。
    pub fn getUserSummary(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getusersummary", begin_date, end_date);
    }

    pub fn getUserCumulate(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getusercumulate", begin_date, end_date);
    }

    pub fn getArticleSummary(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getarticlesummary", begin_date, end_date);
    }

    pub fn getInterfaceSummary(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getinterfacesummary", begin_date, end_date);
    }

    /// 获取接口分析分时数据（`getinterfacesummaryhour`）。
    pub fn getInterfaceSummaryHour(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getinterfacesummaryhour", begin_date, end_date);
    }

    // ── 图文阅读 / 分享转发（对照 datacube/broadcast.go）──

    /// 获取图文群发总数据（`getarticletotal`）。
    pub fn getArticleTotal(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getarticletotal", begin_date, end_date);
    }

    /// 获取图文统计数据（`getuserread`）。
    pub fn getUserRead(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getuserread", begin_date, end_date);
    }

    /// 获取图文统计分时数据（`getuserreadhour`）。
    pub fn getUserReadHour(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getuserreadhour", begin_date, end_date);
    }

    /// 获取图文分享转发数据（`getusershare`）。
    pub fn getUserShare(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getusershare", begin_date, end_date);
    }

    /// 获取图文分享转发分时数据（`getusersharehour`）。
    pub fn getUserShareHour(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getusersharehour", begin_date, end_date);
    }

    // ── 消息发送分布（对照 datacube/message.go）──

    /// 获取消息发送概况数据（`getupstreammsg`）。
    pub fn getUpstreamMsg(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getupstreammsg", begin_date, end_date);
    }

    /// 获取消息发送分时数据（`getupstreammsghour`）。
    pub fn getUpstreamMsgHour(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getupstreammsghour", begin_date, end_date);
    }

    /// 获取消息发送周数据（`getupstreammsgweek`）。
    pub fn getUpstreamMsgWeek(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getupstreammsgweek", begin_date, end_date);
    }

    /// 获取消息发送月数据（`getupstreammsgmonth`）。
    pub fn getUpstreamMsgMonth(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getupstreammsgmonth", begin_date, end_date);
    }

    /// 获取消息发送分布数据（`getupstreammsgdist`）。
    pub fn getUpstreamMsgDist(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getupstreammsgdist", begin_date, end_date);
    }

    /// 获取消息发送分布周数据（`getupstreammsgdistweek`）。
    pub fn getUpstreamMsgDistWeek(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getupstreammsgdistweek", begin_date, end_date);
    }

    /// 获取消息发送分布月数据（`getupstreammsgdistmonth`）。
    pub fn getUpstreamMsgDistMonth(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getupstreammsgdistmonth", begin_date, end_date);
    }

    // ── 流量主广告数据（对照 datacube/publisher.go）──

    /// 获取公众号分广告位数据（`action=publisher_adpos_general`）。
    ///
    /// `ad_slot` 传空串表示不按广告位过滤；否则取 `AdSlot` 常量之一。
    /// 返回原始 JSON（含 `list` / `summary` / `base_resp`），调用方负责 `free`。
    pub fn getPublisherAdPosGeneral(
        self: *Self,
        start_date: []const u8,
        end_date: []const u8,
        page: i64,
        page_size: i64,
        ad_slot: []const u8,
    ) ![]u8 {
        return self.fetchPublisher("publisher_adpos_general", start_date, end_date, page, page_size, ad_slot);
    }

    /// 获取公众号返佣商品数据（`action=publisher_cps_general`）。
    pub fn getPublisherCpsGeneral(
        self: *Self,
        start_date: []const u8,
        end_date: []const u8,
        page: i64,
        page_size: i64,
    ) ![]u8 {
        return self.fetchPublisher("publisher_cps_general", start_date, end_date, page, page_size, "");
    }

    /// 获取公众号结算收入数据及结算主体信息（`action=publisher_settlement`）。
    pub fn getPublisherSettlement(
        self: *Self,
        start_date: []const u8,
        end_date: []const u8,
        page: i64,
        page_size: i64,
    ) ![]u8 {
        return self.fetchPublisher("publisher_settlement", start_date, end_date, page, page_size, "");
    }

    /// 拉取流量主统计数据（GET，对照 publisher.go `fetchData`）。
    ///
    /// 查询参数顺序对齐 Go `url.Values.Encode()` 的字母序：
    /// `access_token` / `action` / `ad_slot` / `end_date` / `page` / `page_size` / `start_date`。
    /// 先按 errcode 检查错误响应，再按 `base_resp.ret` 检查业务错误。
    fn fetchPublisher(
        self: *Self,
        action: []const u8,
        start_date: []const u8,
        end_date: []const u8,
        page: i64,
        page_size: i64,
        ad_slot: []const u8,
    ) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        var uri_buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer uri_buf.deinit(self.allocator);
        try uri_buf.appendSlice(self.allocator, "https://api.weixin.qq.com/publisher/stat?access_token=");
        try uri_buf.appendSlice(self.allocator, access_token);
        try uri_buf.appendSlice(self.allocator, "&action=");
        try uri_buf.appendSlice(self.allocator, action);
        if (ad_slot.len > 0) {
            try uri_buf.appendSlice(self.allocator, "&ad_slot=");
            try uri_buf.appendSlice(self.allocator, ad_slot);
        }
        try uri_buf.appendSlice(self.allocator, "&end_date=");
        try uri_buf.appendSlice(self.allocator, end_date);
        var num_buf: [24]u8 = undefined;
        try uri_buf.appendSlice(self.allocator, "&page=");
        try uri_buf.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{page}) catch unreachable);
        try uri_buf.appendSlice(self.allocator, "&page_size=");
        try uri_buf.appendSlice(self.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{page_size}) catch unreachable);
        try uri_buf.appendSlice(self.allocator, "&start_date=");
        try uri_buf.appendSlice(self.allocator, start_date);
        const uri = try uri_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.get(uri);

        if (try util_error.decodeWithCommonError(self.allocator, resp, action)) |ce| {
            defer ce.deinit();
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }

        var parsed = std.json.parseFromSlice(struct {
            base_resp: struct {
                ret: i64 = 0,
                err_msg: []const u8 = "",
            } = .{},
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            self.allocator.free(resp);
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.base_resp.ret != 0) {
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    fn fetchJson(self: *Self, endpoint: []const u8, begin_date: []const u8, end_date: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/datacube/{s}?access_token={s}",
            .{ endpoint, access_token },
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"begin_date\":\"{s}\",\"end_date\":\"{s}\"}}",
            .{ begin_date, end_date },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, endpoint)) |ce| {
            defer ce.deinit();
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }
};

test "DataCube.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-dc" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const dc = DataCube.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-dc", dc.ctx.config.app_id);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：假 AccessTokenHandle + capture transport。
// ─────────────────────────────────────────────────────────────────────────────

const credential = @import("../../credential/mod.zig");

const TestTokenState = struct {
    token: []const u8,
};

fn testGetAccessToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const state: *const TestTokenState = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, state.token);
}

const test_token_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = testGetAccessToken,
};

fn makeFakeTokenHandle(state: *TestTokenState) credential.AccessTokenHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &test_token_vtable,
    };
}

const TestCapture = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uri: []u8 = &.{},
    payload: []u8 = &.{},

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = method;
        _ = content_type;
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }
};

fn setupTestClient(alloc: std.mem.Allocator, cap: *TestCapture) void {
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(TestCapture.dispatch, @ptrCast(cap));
}

fn releaseTestClient() void {
    const client = util_http.getDefaultClient(std.heap.page_allocator);
    client.setTransport(null, null);
    util_http.deinitDefaultClient();
}

fn makeDc(alloc: std.mem.Allocator, state: *TestTokenState, ctx: *Context) DataCube {
    ctx.* = .{ .config = .{}, .access_token_handle = makeFakeTokenHandle(state) };
    return DataCube.init(ctx, alloc);
}

fn expectDateBody(payload: []const u8, begin: []const u8, end: []const u8) !void {
    const expected = try std.fmt.allocPrint(std.heap.page_allocator, "{{\"begin_date\":\"{s}\",\"end_date\":\"{s}\"}}", .{ begin, end });
    defer std.heap.page_allocator.free(expected);
    try std.testing.expectEqualStrings(expected, payload);
}

test "DataCube 图文统计系列（getArticleTotal/getUserRead/getUserShare）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"list\":[{\"ref_date\":\"2024-01-01\"}]}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(alloc, &state, &ctx);

    const cases = [_]struct {
        call: *const fn (*DataCube, []const u8, []const u8) anyerror![]u8,
        endpoint: []const u8,
    }{
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUserRead(b, e);
            }
        }.f, .endpoint = "getuserread" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUserReadHour(b, e);
            }
        }.f, .endpoint = "getuserreadhour" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUserShare(b, e);
            }
        }.f, .endpoint = "getusershare" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUserShareHour(b, e);
            }
        }.f, .endpoint = "getusersharehour" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getArticleTotal(b, e);
            }
        }.f, .endpoint = "getarticletotal" },
    };

    for (cases) |case| {
        const resp = try case.call(&dc, "2024-01-01", "2024-01-07");
        defer alloc.free(resp);
        const expected_uri = try std.fmt.allocPrint(alloc, "https://api.weixin.qq.com/datacube/{s}?access_token=stub-ak", .{case.endpoint});
        try std.testing.expectEqualStrings(expected_uri, cap.uri);
        try expectDateBody(cap.payload, "2024-01-01", "2024-01-07");
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"list\"") != null);
    }
}

test "DataCube 消息发送分布七端点" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"list\":[]}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(alloc, &state, &ctx);

    const cases = [_]struct {
        call: *const fn (*DataCube, []const u8, []const u8) anyerror![]u8,
        endpoint: []const u8,
    }{
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUpstreamMsg(b, e);
            }
        }.f, .endpoint = "getupstreammsg" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUpstreamMsgHour(b, e);
            }
        }.f, .endpoint = "getupstreammsghour" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUpstreamMsgWeek(b, e);
            }
        }.f, .endpoint = "getupstreammsgweek" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUpstreamMsgMonth(b, e);
            }
        }.f, .endpoint = "getupstreammsgmonth" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUpstreamMsgDist(b, e);
            }
        }.f, .endpoint = "getupstreammsgdist" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUpstreamMsgDistWeek(b, e);
            }
        }.f, .endpoint = "getupstreammsgdistweek" },
        .{ .call = struct {
            fn f(d: *DataCube, b: []const u8, e: []const u8) anyerror![]u8 {
                return d.getUpstreamMsgDistMonth(b, e);
            }
        }.f, .endpoint = "getupstreammsgdistmonth" },
    };

    for (cases) |case| {
        const resp = try case.call(&dc, "2024-02-01", "2024-02-07");
        defer alloc.free(resp);
        const expected_uri = try std.fmt.allocPrint(alloc, "https://api.weixin.qq.com/datacube/{s}?access_token=stub-ak", .{case.endpoint});
        try std.testing.expectEqualStrings(expected_uri, cap.uri);
        try expectDateBody(cap.payload, "2024-02-01", "2024-02-07");
    }
}

test "DataCube.getInterfaceSummaryHour 请求与解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"list\":[{\"ref_date\":\"2024-01-01\",\"ref_hour\":0}]}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(alloc, &state, &ctx);

    const resp = try dc.getInterfaceSummaryHour("2024-01-01", "2024-01-01");
    defer alloc.free(resp);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/datacube/getinterfacesummaryhour?access_token=stub-ak",
        cap.uri,
    );
    try expectDateBody(cap.payload, "2024-01-01", "2024-01-01");
    try std.testing.expect(std.mem.indexOf(u8, resp, "ref_hour") != null);
}

test "DataCube errcode 非 0 返回 ApiError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(alloc, &state, &ctx);

    try std.testing.expectError(util_error.WechatError.ApiError, dc.getUserShare("2024-01-01", "2024-01-07"));
    try std.testing.expectError(util_error.WechatError.ApiError, dc.getUpstreamMsgDist("2024-01-01", "2024-01-07"));
    try std.testing.expectError(util_error.WechatError.ApiError, dc.getInterfaceSummaryHour("2024-01-01", "2024-01-07"));
}

test "DataCube.getPublisherAdPosGeneral GET 参数顺序与 base_resp 检查" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"base_resp\":{\"ret\":0,\"err_msg\":\"ok\"},\"list\":[{\"slot_id\":1}],\"total_num\":1}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(alloc, &state, &ctx);

    const resp = try dc.getPublisherAdPosGeneral("2024-01-01", "2024-01-31", 1, 10, AdSlot.biz_bottom);
    defer alloc.free(resp);
    // 参数顺序对齐 Go url.Values.Encode() 字母序。
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/publisher/stat?access_token=stub-ak&action=publisher_adpos_general&ad_slot=SLOT_ID_BIZ_BOTTOM&end_date=2024-01-31&page=1&page_size=10&start_date=2024-01-01",
        cap.uri,
    );
    try std.testing.expectEqualStrings("", cap.payload);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"total_num\":1") != null);

    // base_resp.ret != 0 → ApiError。
    cap.response = "{\"base_resp\":{\"ret\":1001,\"err_msg\":\"invalid date\"}}";
    try std.testing.expectError(util_error.WechatError.ApiError, dc.getPublisherAdPosGeneral("2024-01-01", "2024-01-31", 1, 10, AdSlot.biz_bottom));

    // 不带 ad_slot 时不出现该参数。
    cap.response = "{\"base_resp\":{\"ret\":0,\"err_msg\":\"ok\"}}";
    const resp2 = try dc.getPublisherCpsGeneral("2024-01-01", "2024-01-31", 0, 20);
    defer alloc.free(resp2);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/publisher/stat?access_token=stub-ak&action=publisher_cps_general&end_date=2024-01-31&page=0&page_size=20&start_date=2024-01-01",
        cap.uri,
    );
}

test "DataCube.getPublisherSettlement 结算数据" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"base_resp\":{\"ret\":0,\"err_msg\":\"ok\"},\"settlement_list\":[{\"date\":\"2024-01\",\"sett_no\":\"NO1\"}]}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(alloc, &state, &ctx);

    const resp = try dc.getPublisherSettlement("2024-01-01", "2024-01-31", 1, 5);
    defer alloc.free(resp);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/publisher/stat?access_token=stub-ak&action=publisher_settlement&end_date=2024-01-31&page=1&page_size=5&start_date=2024-01-01",
        cap.uri,
    );
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"sett_no\":\"NO1\"") != null);
}
