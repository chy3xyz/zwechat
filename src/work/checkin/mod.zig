//! work/checkin — 打卡
//!
//! 对应 `_ref/wechat/work/checkin/`：实现"打卡"应用相关的查询与写入接口。
//! 当前落地两个最常用入口：
//!
//! - `getCheckinData` — 拉取打卡记录数据
//!   (`POST /cgi-bin/checkin/getcheckindata`)
//! - `getCheckinOption` — 拉取员工打卡规则
//!   (`POST /cgi-bin/checkin/getcheckinoption`)
//!
//! 对应 Go 参考中的 `GetCheckinData` 与 `GetOption`；后续如需扩展
//! `GetCorpOption`（企业级规则）/ `GetScheduleList`（排班）/ `AddRecord`（补卡）
//! 等，可在此文件追加 `pub fn`，结构与现有方法一致。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 拉取打卡记录数据。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/checkin/getcheckindata?access_token=...`。
pub const getCheckinDataURL = "https://qyapi.weixin.qq.com/cgi-bin/checkin/getcheckindata";

/// 拉取员工打卡规则。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/checkin/getcheckinoption?access_token=...`。
pub const getCheckinOptionURL = "https://qyapi.weixin.qq.com/cgi-bin/checkin/getcheckinoption";

// ─────────────────────────────────────────────────────────────────────────────
// 请求 / 响应结构
// ─────────────────────────────────────────────────────────────────────────────

/// `getCheckinData` 请求体。
///
/// `start_time` / `end_time` 是 Unix 秒级时间戳；`userid_list` 限定成员范围
/// （为空时按企业全员处理）；`opencheckindatatype` 控制数据类型（1=上下班打卡，
/// 2=外出打卡 等，详见企业微信文档）。
pub const CheckinDataRequest = struct {
    opencheckindatatype: i64 = 1,
    starttime: i64 = 0,
    endtime: i64 = 0,
    useridlist: []const []const u8 = &.{},
};

/// `getCheckinData` 响应中的单条打卡记录。
pub const CheckinDataItem = struct {
    userid: []const u8 = "",
    groupname: []const u8 = "",
    checkin_type: []const u8 = "",
    exception_type: []const u8 = "",
    checkin_time: i64 = 0,
    location_title: []const u8 = "",
    location_detail: []const u8 = "",
    wifiname: []const u8 = "",
    notes: []const u8 = "",
    wifimac: []const u8 = "",
    mediaids: []const []const u8 = &.{},
    sch_checkin_time: i64 = 0,
    groupid: i64 = 0,
    schedule_id: i64 = 0,
    timeline_id: i64 = 0,
    lat: i64 = 0,
    lng: i64 = 0,
    deviceid: []const u8 = "",
};

/// `getCheckinData` 响应。
pub const CheckinDataResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    checkindata: []CheckinDataItem = &.{},
};

/// `getCheckinOption` 请求体。
pub const CheckinOptionRequest = struct {
    /// 查询时间点（Unix 秒级时间戳）。
    datetime: i64 = 0,
    useridlist: []const []const u8 = &.{},
};

/// `getCheckinOption` 响应中的单条规则。
pub const OptionInfo = struct {
    userid: []const u8 = "",
    group: OptionGroup = .{},
};

/// 打卡规则详情（与 Go `OptionGroup` 对齐）。
pub const OptionGroup = struct {
    grouptype: i64 = 0,
    groupid: i64 = 0,
    groupname: []const u8 = "",
    checkindate: []CheckinDate = &.{},
    spe_workdays: []SpeDay = &.{},
    spe_offdays: []SpeDay = &.{},
    sync_holidays: bool = false,
    need_photo: bool = false,
    wifimac_infos: []WifiMacInfo = &.{},
    loc_infos: []LocInfo = &.{},
    allow_checkin_offworkday: bool = false,
    allow_apply_offworkday: bool = false,
    buka_restriction: i64 = 0,
    span_day_time: i64 = 0,
    standard_work_duration: i64 = 0,
    offwork_interval_time: i64 = 0,
    checkin_method_type: i64 = 0,
};

pub const CheckinDate = struct {
    workdays: []const i64 = &.{},
    checkintime: []CheckinTime = &.{},
    flex_time: i64 = 0,
    noneed_offwork: bool = false,
    limit_aheadtime: i64 = 0,
    flex_on_duty_time: i64 = 0,
    flex_off_duty_time: i64 = 0,
};

pub const CheckinTime = struct {
    work_sec: i64 = 0,
    off_work_sec: i64 = 0,
    remind_work_sec: i64 = 0,
    remind_off_work_sec: i64 = 0,
};

pub const SpeDay = struct {
    timestamp: i64 = 0,
    notes: []const u8 = "",
};

pub const WifiMacInfo = struct {
    wifiname: []const u8 = "",
    wifimac: []const u8 = "",
};

pub const LocInfo = struct {
    lat: i64 = 0,
    lng: i64 = 0,
    loc_title: []const u8 = "",
    loc_detail: []const u8 = "",
    distance: i64 = 0,
};

/// `getCheckinOption` 响应。
pub const CheckinOptionResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    info: []OptionInfo = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 打卡子模块。
pub const Checkin = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 拉取打卡记录数据。
    ///
    /// 对应 `_ref/wechat/work/checkin/record.go` 的 `GetCheckinData`。
    pub fn getCheckinData(self: *Self, req: CheckinDataRequest) !CheckinDataResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getCheckinDataURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeCheckinDataJson(self.allocator, req);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CheckinDataResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 拉取员工打卡规则。
    ///
    /// 对应 `_ref/wechat/work/checkin/record.go` 的 `GetOption`。
    pub fn getCheckinOption(self: *Self, req: CheckinOptionRequest) !CheckinOptionResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getCheckinOptionURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeCheckinOptionJson(self.allocator, req);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CheckinOptionResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：手写 JSON 序列化
// ─────────────────────────────────────────────────────────────────────────────

/// `CheckinDataRequest` 编码为 `{"opencheckindatatype":N,"starttime":N,"endtime":N,"useridlist":["a","b"]}`。
fn encodeCheckinDataJson(allocator: std.mem.Allocator, req: CheckinDataRequest) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(
        allocator,
        "{{\"opencheckindatatype\":{d},\"starttime\":{d},\"endtime\":{d},\"useridlist\":[",
        .{ req.opencheckindatatype, req.starttime, req.endtime },
    );
    for (req.useridlist, 0..) |uid, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try appendJsonString(allocator, &buf, uid);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// `CheckinOptionRequest` 编码为 `{"datetime":N,"useridlist":["a","b"]}`。
fn encodeCheckinOptionJson(allocator: std.mem.Allocator, req: CheckinOptionRequest) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{{\"datetime\":{d},\"useridlist\":[", .{req.datetime});
    for (req.useridlist, 0..) |uid, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try appendJsonString(allocator, &buf, uid);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

test "Checkin.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-ci" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const c = Checkin.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-ci", c.ctx.config.corp_id);
}

test "CheckinDataRequest 默认值" {
    const r = CheckinDataRequest{};
    try std.testing.expectEqual(@as(i64, 1), r.opencheckindatatype);
    try std.testing.expectEqual(@as(i64, 0), r.starttime);
    try std.testing.expectEqual(@as(usize, 0), r.useridlist.len);
}

test "CheckinDataItem 默认值" {
    const i = CheckinDataItem{};
    try std.testing.expectEqualStrings("", i.userid);
    try std.testing.expectEqual(@as(i64, 0), i.checkin_time);
}

test "CheckinDataResponse 默认值" {
    const r = CheckinDataResponse{};
    try std.testing.expectEqual(@as(usize, 0), r.checkindata.len);
}

test "CheckinOptionRequest 默认值" {
    const r = CheckinOptionRequest{};
    try std.testing.expectEqual(@as(i64, 0), r.datetime);
}

test "OptionInfo 默认值" {
    const o = OptionInfo{};
    try std.testing.expectEqualStrings("", o.userid);
}

test "OptionGroup 默认值" {
    const g = OptionGroup{};
    try std.testing.expectEqualStrings("", g.groupname);
    try std.testing.expectEqual(@as(usize, 0), g.checkindate.len);
}

test "CheckinOptionResponse 默认值" {
    const r = CheckinOptionResponse{};
    try std.testing.expectEqual(@as(usize, 0), r.info.len);
}

test "encodeCheckinDataJson 生成正确 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeCheckinDataJson(alloc, .{
        .opencheckindatatype = 3,
        .starttime = 1700000000,
        .endtime = 1700086400,
        .useridlist = &.{ "u1", "u\"2" },
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"opencheckindatatype\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"starttime\":1700000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"endtime\":1700086400") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"u\\\"2\"") != null);
}

test "encodeCheckinOptionJson 生成正确 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeCheckinOptionJson(alloc, .{
        .datetime = 1700000000,
        .useridlist = &.{"u1"},
    });
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"datetime\":1700000000,\"useridlist\":[\"u1\"]}", body);
}
