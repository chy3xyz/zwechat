// SPDX-License-Identifier: Apache-2.0
//! officialaccount/datacube — 数据统计
//!
//! 提供公众号用户、消息、接口、图文、分享传播及流量主广告等维度的统计接口。
//!
//! token 注入 / errcode 检查 / token 失效自愈（40001 等 → 作废缓存 → 只重试一次）
//! 交给 `util/retry.callApi` 统一处理。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

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
    /// errcode 由 `callApi` 检查；`base_resp.ret` 在此处检查。
    fn fetchPublisher(
        self: *Self,
        action: []const u8,
        start_date: []const u8,
        end_date: []const u8,
        page: i64,
        page_size: i64,
        ad_slot: []const u8,
    ) ![]u8 {
        const Req = struct {
            action: []const u8,
            start_date: []const u8,
            end_date: []const u8,
            page: i64,
            page_size: i64,
            ad_slot: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                var uri_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer uri_buf.deinit(a);
                try uri_buf.appendSlice(a, "https://api.weixin.qq.com/publisher/stat?access_token=");
                try uri_buf.appendSlice(a, token);
                try uri_buf.appendSlice(a, "&action=");
                try uri_buf.appendSlice(a, c.action);
                if (c.ad_slot.len > 0) {
                    try uri_buf.appendSlice(a, "&ad_slot=");
                    try uri_buf.appendSlice(a, c.ad_slot);
                }
                try uri_buf.appendSlice(a, "&end_date=");
                try uri_buf.appendSlice(a, c.end_date);
                var num_buf: [24]u8 = undefined;
                try uri_buf.appendSlice(a, "&page=");
                try uri_buf.appendSlice(a, std.fmt.bufPrint(&num_buf, "{d}", .{c.page}) catch unreachable);
                try uri_buf.appendSlice(a, "&page_size=");
                try uri_buf.appendSlice(a, std.fmt.bufPrint(&num_buf, "{d}", .{c.page_size}) catch unreachable);
                try uri_buf.appendSlice(a, "&start_date=");
                try uri_buf.appendSlice(a, c.start_date);
                const uri = try uri_buf.toOwnedSlice(a);
                defer a.free(uri);

                const client = util_http.getDefaultClient(a);
                return client.get(uri);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, action, Req{
            .action = action,
            .start_date = start_date,
            .end_date = end_date,
            .page = page,
            .page_size = page_size,
            .ad_slot = ad_slot,
        });

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
        const Req = struct {
            endpoint: []const u8,
            begin_date: []const u8,
            end_date: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/datacube/{s}?access_token={s}",
                    .{ c.endpoint, token },
                );
                defer a.free(uri);

                const body = try std.fmt.allocPrint(
                    a,
                    "{{\"begin_date\":\"{s}\",\"end_date\":\"{s}\"}}",
                    .{ c.begin_date, c.end_date },
                );
                defer a.free(body);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, body);
            }
        };

        // errcode 由 callApi 检查；成功（含 `errcode == 0`）时返回原始响应体。
        return util_retry.callApi(self.ctx, self.allocator, endpoint, Req{
            .endpoint = endpoint,
            .begin_date = begin_date,
            .end_date = end_date,
        });
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
    /// 当前（缓存中的）token；`invalidate` 后换成 `refreshed`。
    token: []const u8,
    /// 作废后换发的新 token（模拟微信换发）；`null` 表示作废后仍返回同一 token。
    refreshed: ?[]const u8 = null,
    /// `invalidate` 被调用的次数。
    invalidates: usize = 0,

    fn getAccessToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const state: *const TestTokenState = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, state.token);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const state: *TestTokenState = @ptrCast(@alignCast(ptr));
        state.invalidates += 1;
        if (state.refreshed) |t| {
            state.token = t;
            state.refreshed = null;
        }
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getAccessToken,
        .invalidate = invalidate,
    };
};

fn makeFakeTokenHandle(state: *TestTokenState) credential.AccessTokenHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &TestTokenState.vtable,
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
    // 不依赖「用别的 allocator 再取一次指针」的宽容语义：直接销毁线程局部实例，
    // 注入的 transport 随实例一起消失（下次 getDefaultClient 会重新初始化）。
    util_http.deinitDefaultClient();
}

/// 用 `MockTransport` 路由表替代 capture（按 URI 命中不同响应，见失效重试测试）。
fn setupMockClient(alloc: std.mem.Allocator, mt: *util_http.MockTransport) void {
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(mt));
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

test "DataCube token 失效自愈：40001 → 作废缓存 → 新 token 重试成功" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/datacube/getusersummary?access_token=old-ak", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential, access_token is invalid or not latest\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/datacube/getusersummary?access_token=new-ak", .{
        .body = "{\"list\":[{\"ref_date\":\"2024-01-01\"}]}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(allocator, &state, &ctx);

    const resp = try dc.getUserSummary("2024-01-01", "2024-01-07");
    defer allocator.free(resp);

    try std.testing.expectEqualStrings("{\"list\":[{\"ref_date\":\"2024-01-01\"}]}", resp);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[0], "access_token=old-ak") != null);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-ak") != null);
}

test "DataCube 非 token 类 errcode（45009）直接 ApiError：不作废、只请求一次" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/datacube/getusercumulate?access_token=old-ak", .{
        .body = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(allocator, &state, &ctx);

    try std.testing.expectError(
        util_error.WechatError.ApiError,
        dc.getUserCumulate("2024-01-01", "2024-01-07"),
    );
    try std.testing.expectEqual(@as(usize, 0), state.invalidates);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}

test "DataCube.getPublisherAdPosGeneral 走 token 失效自愈（GET 查询串带新 token）" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute(
        "https://api.weixin.qq.com/publisher/stat?access_token=old-ak&action=publisher_adpos_general&ad_slot=SLOT_ID_BIZ_BOTTOM&end_date=2024-01-31&page=1&page_size=10&start_date=2024-01-01",
        .{ .body = "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}" },
    );
    try mt.addRoute(
        "https://api.weixin.qq.com/publisher/stat?access_token=new-ak&action=publisher_adpos_general&ad_slot=SLOT_ID_BIZ_BOTTOM&end_date=2024-01-31&page=1&page_size=10&start_date=2024-01-01",
        .{ .body = "{\"base_resp\":{\"ret\":0,\"err_msg\":\"ok\"},\"total_num\":1}" },
    );
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx: Context = undefined;
    var dc = makeDc(allocator, &state, &ctx);

    const resp = try dc.getPublisherAdPosGeneral("2024-01-01", "2024-01-31", 1, 10, AdSlot.biz_bottom);
    defer allocator.free(resp);

    try std.testing.expectEqualStrings("{\"base_resp\":{\"ret\":0,\"err_msg\":\"ok\"},\"total_num\":1}", resp);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-ak") != null);
}
