// SPDX-License-Identifier: Apache-2.0
//! miniprogram/analysis — 小程序数据分析
//!
//! 对应 `_ref/wechat/miniprogram/analysis/analysis.go`：留存 / 数据概况 / 访问趋势 /
//! 用户画像 / 访问分布 / 页面访问 / 性能数据。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const RetainItem = struct {
    key: i64 = 0,
    value: i64 = 0,
};

pub const ResAnalysisRetain = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    ref_date: []const u8 = "",
    visit_uv_new: []const RetainItem = &.{},
    visit_uv: []const RetainItem = &.{},
};

pub const ResAnalysisDailySummary = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    list: []const DailySummaryItem = &.{},
};

pub const DailySummaryItem = struct {
    ref_date: []const u8 = "",
    visit_total: i64 = 0,
    share_pv: i64 = 0,
    share_uv: i64 = 0,
};

pub const ResAnalysisVisitTrend = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    list: []const VisitTrendItem = &.{},
};

pub const VisitTrendItem = struct {
    ref_date: []const u8 = "",
    session_cnt: i64 = 0,
    visit_pv: i64 = 0,
    visit_uv: i64 = 0,
    visit_uv_new: i64 = 0,
    stay_time_uv: f64 = 0,
    stay_time_session: f64 = 0,
    visit_depth: f64 = 0,
};

pub const UserPortraitItem = struct {
    id: i64 = 0,
    name: []const u8 = "",
    value: i64 = 0,
};

pub const UserPortrait = struct {
    index: i64 = 0,
    province: []const UserPortraitItem = &.{},
    city: []const UserPortraitItem = &.{},
    genders: []const UserPortraitItem = &.{},
    platforms: []const UserPortraitItem = &.{},
    devices: []const UserPortraitItem = &.{},
    ages: []const UserPortraitItem = &.{},
};

pub const ResAnalysisUserPortrait = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    ref_date: []const u8 = "",
    visit_uv_new: UserPortrait = .{},
    visit_uv: UserPortrait = .{},
};

pub const VisitDistributionIndexItem = struct {
    key: i64 = 0,
    value: i64 = 0,
    access_source_visit_uv: i64 = 0,
};

pub const VisitDistributionIndex = struct {
    index: []const u8 = "",
    item_list: []const VisitDistributionIndexItem = &.{},
};

pub const ResAnalysisVisitDistribution = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    ref_date: []const u8 = "",
    list: []const VisitDistributionIndex = &.{},
};

pub const VisitPageItem = struct {
    page_path: []const u8 = "",
    page_visit_pv: i64 = 0,
    page_visit_uv: i64 = 0,
    page_staytime_pv: f64 = 0,
    entrypage_pv: i64 = 0,
    exitpage_pv: i64 = 0,
    page_share_pv: i64 = 0,
    page_share_uv: i64 = 0,
};

pub const ResAnalysisVisitPage = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    ref_date: []const u8 = "",
    list: []const VisitPageItem = &.{},
};

pub const GetPerformanceDataRequest = struct {
    module: []const u8 = "",
    time: PerformanceDataTime = .{},
    params: []const PerformanceDataParams = &.{},
};

pub const PerformanceDataTime = struct {
    begin_timestamp: i64 = 0,
    end_timestamp: i64 = 0,
};

pub const PerformanceDataParams = struct {
    field: []const u8 = "",
    value: []const u8 = "",
};

pub const GetPerformanceDataResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    body: PerformanceDataBody = .{},
};

pub const PerformanceDataBody = struct {
    tables: []const PerformanceDataTable = &.{},
    count: i64 = 0,
};

pub const PerformanceDataTable = struct {
    id: []const u8 = "",
    lines: []const PerformanceDataTableLine = &.{},
    zh: []const u8 = "",
};

pub const PerformanceDataTableLine = struct {
    fields: []const PerformanceDataTableLineField = &.{},
};

pub const PerformanceDataTableLineField = struct {
    refdate: []const u8 = "",
    value: []const u8 = "",
};

/// 小程序数据分析模块。
pub const Analysis = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    pub fn getAnalysisDailyRetain(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisRetain) {
        return self.fetchDateRange("getweanalysisappiddailyretaininfo", ResAnalysisRetain, begin_date, end_date);
    }
    pub fn getAnalysisMonthlyRetain(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisRetain) {
        return self.fetchDateRange("getweanalysisappidmonthlyretaininfo", ResAnalysisRetain, begin_date, end_date);
    }
    pub fn getAnalysisWeeklyRetain(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisRetain) {
        return self.fetchDateRange("getweanalysisappidweeklyretaininfo", ResAnalysisRetain, begin_date, end_date);
    }
    pub fn getAnalysisDailySummary(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisDailySummary) {
        return self.fetchDateRange("getweanalysisappiddailysummarytrend", ResAnalysisDailySummary, begin_date, end_date);
    }
    pub fn getAnalysisDailyVisitTrend(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisVisitTrend) {
        return self.fetchDateRange("getweanalysisappiddailyvisittrend", ResAnalysisVisitTrend, begin_date, end_date);
    }
    pub fn getAnalysisMonthlyVisitTrend(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisVisitTrend) {
        return self.fetchDateRange("getweanalysisappidmonthlyvisittrend", ResAnalysisVisitTrend, begin_date, end_date);
    }
    pub fn getAnalysisWeeklyVisitTrend(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisVisitTrend) {
        return self.fetchDateRange("getweanalysisappidweeklyvisittrend", ResAnalysisVisitTrend, begin_date, end_date);
    }
    pub fn getAnalysisUserPortrait(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisUserPortrait) {
        return self.fetchDateRange("getweanalysisappiduserportrait", ResAnalysisUserPortrait, begin_date, end_date);
    }
    pub fn getAnalysisVisitDistribution(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisVisitDistribution) {
        return self.fetchDateRange("getweanalysisappidvisitdistribution", ResAnalysisVisitDistribution, begin_date, end_date);
    }
    pub fn getAnalysisVisitPage(self: *Self, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(ResAnalysisVisitPage) {
        return self.fetchDateRange("getweanalysisappidvisitpage", ResAnalysisVisitPage, begin_date, end_date);
    }

    /// 获取小程序性能数据。
    pub fn getPerformanceData(self: *Self, req: GetPerformanceDataRequest) !std.json.Parsed(GetPerformanceDataResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/business/performance/boot?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try jsonStringifyPerformance(self.allocator, req);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetPerformanceDataResponse, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    fn fetchDateRange(self: *Self, comptime T: type, endpoint: []const u8, begin_date: []const u8, end_date: []const u8) !std.json.Parsed(T) {
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
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(T, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

fn jsonStringifyPerformance(allocator: std.mem.Allocator, req: GetPerformanceDataRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("module");
    try s.write(req.module);
    try s.objectField("time");
    try s.beginObject();
    try s.objectField("begin_timestamp");
    try s.write(req.time.begin_timestamp);
    try s.objectField("end_timestamp");
    try s.write(req.time.end_timestamp);
    try s.endObject();
    try s.objectField("params");
    try s.beginArray();
    for (req.params) |p| {
        try s.beginObject();
        try s.objectField("field");
        try s.write(p.field);
        try s.objectField("value");
        try s.write(p.value);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

test "Analysis.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-an" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const a = Analysis.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-an", a.ctx.config.app_id);
}

test "ResAnalysisRetain 默认值" {
    const r = ResAnalysisRetain{};
    try std.testing.expectEqualStrings("", r.ref_date);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}
