//! work/msgaudit — 消息存档
//!
//! 对应 `_ref/wechat/work/msgaudit/`。Go 参考实现仅在 Linux + cgo + `msgaudit`
//! 编译标签下挂载 WeWorkFinanceSdk C 库，提供拉取加密聊天记录 / 媒体 / 解密
//! 等能力；Zig 端不引入 cgo 依赖，因此只落地 HTTP 形态的元数据查询接口：
//!
//! - `GetRoomInfo` — 拉取群聊基础信息
//!   (`POST /cgi-bin/msgaudit/groupchat/get_room_info`)
//! - `GetAgreeInfo` — 拉取成员"同意存档"状态
//!   (`POST /cgi-bin/msgaudit/get_agree_info`)
//!
//! 解密 / 拉取原始聊天内容依赖 C SDK，目前**未实现**；后续如需接入，可在此
//! 模块内新增 `decodeChatData` 之类的桥接方法。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 拉取群聊基础信息。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/msgaudit/groupchat/get_room_info?access_token=...`。
pub const getRoomInfoURL =
    "https://qyapi.weixin.qq.com/cgi-bin/msgaudit/groupchat/get_room_info";

/// 拉取成员的"同意存档"状态。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/msgaudit/get_agree_info?access_token=...`。
pub const getAgreeInfoURL = "https://qyapi.weixin.qq.com/cgi-bin/msgaudit/get_agree_info";

// ─────────────────────────────────────────────────────────────────────────────
// 请求 / 响应结构
// ─────────────────────────────────────────────────────────────────────────────

/// `GetRoomInfo` 请求体。
pub const RoomInfoRequest = struct {
    /// 待查询的群 id 列表（最多 1000 个）。
    room_list: []const []const u8 = &.{},
};

/// `GetRoomInfo` 响应中的单条群聊信息。
pub const RoomInfo = struct {
    /// 群 id。
    roomid: []const u8 = "",
    /// 群主 userid。
    creator: []const u8 = "",
    /// 群名称。
    name: []const u8 = "",
};

/// `GetRoomInfo` 响应。
pub const RoomInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    room_list: []RoomInfo = &.{},
};

/// `GetAgreeInfo` 请求体。
///
/// `info` 是 `[]AgreeInfoEntry` 列表；上限 100 个。Go 参考用结构体数组，
/// Zig 端保持一致。
pub const AgreeInfoRequest = struct {
    info: []const AgreeInfoEntry = &.{},
};

/// `AgreeInfoRequest.info` 列表中的元素。
pub const AgreeInfoEntry = struct {
    /// 企业成员 userid（外部企业为 external_userid）。
    userid: []const u8 = "",
};

/// `GetAgreeInfo` 响应中的单条记录。
pub const AgreeInfo = struct {
    userid: []const u8 = "",
    /// 0=未同意，1=同意。
    status: i64 = 0,
    /// 同意时间（Unix 秒）。
    agree_time: i64 = 0,
    /// 同意的外部联系人 openid。
    open_userid: []const u8 = "",
};

/// `GetAgreeInfo` 响应。
pub const AgreeInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    agreeinfo: []AgreeInfo = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 消息存档子模块。
pub const MsgAudit = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 拉取群聊基础信息。
    ///
    /// 对应 WeWork `/cgi-bin/msgaudit/groupchat/get_room_info` 接口。
    pub fn getRoomInfo(self: *Self, req: RoomInfoRequest) !RoomInfoResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getRoomInfoURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeRoomListJson(self.allocator, req.room_list);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(RoomInfoResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 拉取成员的"同意存档"状态。
    ///
    /// 对应 WeWork `/cgi-bin/msgaudit/get_agree_info` 接口。
    pub fn getAgreeInfo(self: *Self, req: AgreeInfoRequest) !AgreeInfoResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getAgreeInfoURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeAgreeInfoJson(self.allocator, req.info);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(AgreeInfoResponse, self.allocator, resp, .{}) catch {
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

/// `RoomInfoRequest` 编码为 `{"room_list":["rid1","rid2"]}`。
fn encodeRoomListJson(allocator: std.mem.Allocator, room_list: []const []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"room_list\":[");
    for (room_list, 0..) |rid, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try appendJsonString(allocator, &buf, rid);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// `AgreeInfoRequest` 编码为 `{"info":[{"userid":"u1"},{"userid":"u2"}]}`。
fn encodeAgreeInfoJson(allocator: std.mem.Allocator, info: []const AgreeInfoEntry) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"info\":[");
    for (info, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"userid\":\"");
        try appendJsonString(allocator, &buf, entry.userid);
        try buf.appendSlice(allocator, "\"}");
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

test "MsgAudit.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-audit" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const m = MsgAudit.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-audit", m.ctx.config.corp_id);
}

test "RoomInfoRequest 默认值" {
    const r = RoomInfoRequest{};
    try std.testing.expectEqual(@as(usize, 0), r.room_list.len);
}

test "RoomInfo 默认值" {
    const r = RoomInfo{};
    try std.testing.expectEqualStrings("", r.roomid);
    try std.testing.expectEqualStrings("", r.creator);
}

test "RoomInfoResponse 默认值" {
    const r = RoomInfoResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
    try std.testing.expectEqual(@as(usize, 0), r.room_list.len);
}

test "AgreeInfoRequest 默认值" {
    const r = AgreeInfoRequest{};
    try std.testing.expectEqual(@as(usize, 0), r.info.len);
}

test "AgreeInfoEntry 默认值" {
    const e = AgreeInfoEntry{};
    try std.testing.expectEqualStrings("", e.userid);
}

test "AgreeInfo 默认值" {
    const a = AgreeInfo{};
    try std.testing.expectEqual(@as(i64, 0), a.status);
    try std.testing.expectEqual(@as(i64, 0), a.agree_time);
}

test "AgreeInfoResponse 默认值" {
    const r = AgreeInfoResponse{};
    try std.testing.expectEqual(@as(usize, 0), r.agreeinfo.len);
}

test "encodeRoomListJson 生成正确 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeRoomListJson(alloc, &.{ "r1", "r\"2" });
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"room_list\":[\"r1\",\"r\\\"2\"]}", body);
}

test "encodeAgreeInfoJson 生成正确 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeAgreeInfoJson(alloc, &.{
        .{ .userid = "u1" },
        .{ .userid = "u2" },
    });
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"info\":[{\"userid\":\"u1\"},{\"userid\":\"u2\"}]}", body);
}
