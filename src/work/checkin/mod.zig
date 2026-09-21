// SPDX-License-Identifier: Apache-2.0
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
const util_retry = @import("../../util/retry.zig");
const util_json = @import("../../util/json.zig");
const credential = @import("../../credential/mod.zig");

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
    /// 走 `util/retry.callApi`：token 失效（40001 等）时自动作废缓存、取新 token 重试一次。
    /// 返回的 `std.json.Parsed(CheckinDataResponse)` 由调用方持有并负责 `deinit`。
    pub fn getCheckinData(self: *Self, req: CheckinDataRequest) !std.json.Parsed(CheckinDataResponse) {
        const body = try encodeCheckinDataJson(self.allocator, req);
        defer self.allocator.free(body);

        const Sender = struct {
            self: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}",
                    .{ getCheckinDataURL, token },
                );
                defer allocator.free(uri);
                return util_http.getDefaultClient(c.self.allocator).postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "GetCheckinData",
            Sender{ .self = self, .body = body },
        );
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CheckinDataResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        return parsed;
    }

    /// 拉取员工打卡规则。
    ///
    /// 对应 `_ref/wechat/work/checkin/record.go` 的 `GetOption`。
    /// 与 `getCheckinData` 一样走 `util/retry.callApi` 的失效自愈链路。
    /// 返回的 `std.json.Parsed(CheckinOptionResponse)` 由调用方持有并负责 `deinit`。
    pub fn getCheckinOption(self: *Self, req: CheckinOptionRequest) !std.json.Parsed(CheckinOptionResponse) {
        const body = try encodeCheckinOptionJson(self.allocator, req);
        defer self.allocator.free(body);

        const Sender = struct {
            self: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}",
                    .{ getCheckinOptionURL, token },
                );
                defer allocator.free(uri);
                return util_http.getDefaultClient(c.self.allocator).postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "GetCheckinOption",
            Sender{ .self = self, .body = body },
        );
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CheckinOptionResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        return parsed;
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

/// JSON 字符串转义（实现收敛到 `util.json.appendEscapedString`；此前漏转义
/// `c < 0x20` 控制字符）。
const appendJsonString = util_json.appendEscapedString;

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

// ─────────────────────────────────────────────────────────────────────────────
// Mock access_token 句柄（测试用）
// ─────────────────────────────────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 可自愈的假 token handle：`invalidate` 后把 `idx` 推进到下一个 token。
/// `tokens` 按调用次序给出，模拟微信换发新 token。
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

fn makeCtx() Context {
    return .{
        .config = .{ .corp_id = "ww-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

fn makeHealCtx(state: *HealState) Context {
    return .{
        .config = .{ .corp_id = "ww-heal" },
        .access_token_handle = .{ .ptr = @ptrCast(state), .vtable = &HealState.vtable },
    };
}

test "getCheckinOption 解析含 note_can_use_local_pic/schedulelist/open_sp_checkin 的真实响应" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/checkin/getcheckinoption?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"info\":[{\"userid\":\"zhangsan\",\"group\":{\"grouptype\":1,\"groupid\":100,\"groupname\":\"研发组\",\"note_can_use_local_pic\":true,\"open_sp_checkin\":true,\"schedulelist\":[{\"schedule_id\":1,\"schedule_name\":\"早班\"}],\"checkindate\":[{\"workdays\":[1,2,3,4,5],\"checkintime\":[{\"work_sec\":32400,\"off_work_sec\":61200}]}]}}]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var c = Checkin.init(&ctx, allocator);
    var parsed = try c.getCheckinOption(.{
        .datetime = 1700000000,
        .useridlist = &.{"zhangsan"},
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.info.len);
    const g = parsed.value.info[0].group;
    try std.testing.expectEqualStrings("研发组", g.groupname);
    try std.testing.expectEqual(@as(i64, 100), g.groupid);
    try std.testing.expectEqual(@as(usize, 1), g.checkindate.len);
    try std.testing.expectEqual(@as(usize, 5), g.checkindate[0].workdays.len);
    try std.testing.expectEqual(@as(i64, 32400), g.checkindate[0].checkintime[0].work_sec);
    // note_can_use_local_pic / schedulelist / open_sp_checkin 是结构体未建模的字段，
    // 解析不报错即说明 ignore_unknown_fields 生效。
}

test "getCheckinData token 失效自愈：40001 → 作废缓存 → 新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/checkin/getcheckindata?access_token=old-token", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential, access_token is invalid or not latest\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/checkin/getcheckindata?access_token=new-token", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"checkindata\":[{\"userid\":\"zhangsan\",\"checkin_time\":1700000000}]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var c = Checkin.init(&ctx, allocator);
    var parsed = try c.getCheckinData(.{ .useridlist = &.{"zhangsan"} });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("zhangsan", parsed.value.checkindata[0].userid);
    // 作废恰好一次，且第二次请求确实换上了新 token。
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[0], "access_token=old-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-token") != null);
}

test "getCheckinOption 非 token 类 errcode（60011）直接 ApiError，不重试也不作废" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/checkin/getcheckinoption?access_token=old-token", .{
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
    var c = Checkin.init(&ctx, allocator);

    try std.testing.expectError(error.ApiError, c.getCheckinOption(.{ .datetime = 1700000000 }));

    try std.testing.expectEqual(@as(usize, 0), state.invalidates);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}
