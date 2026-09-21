// SPDX-License-Identifier: Apache-2.0
//! work/msgaudit — 消息存档
//!
//! 对应 `_ref/wechat/work/msgaudit/`。Go 参考实现仅在 Linux + cgo + `msgaudit`
//! 编译标签下挂载 WeWorkFinanceSdk C 库，提供拉取加密聊天记录 / 媒体 / 解密
//! 等能力；Zig 端不引入 cgo 依赖，因此只落地 HTTP 形态的元数据查询接口：
//!
//! - `GetRoomInfo` — 获取会话信息（群聊基础信息）
//!   (`POST /cgi-bin/msgaudit/groupchat/get`)
//! - `GetAgreeInfo` — 查询是否需要拉取"同意存档"状态
//!   (`POST /cgi-bin/msgaudit/check_single_agree`)
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

/// 获取会话信息（群聊基础信息）。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/msgaudit/groupchat/get?access_token=...`。
pub const getRoomInfoURL = "https://qyapi.weixin.qq.com/cgi-bin/msgaudit/groupchat/get";

/// 查询是否需要拉取"同意存档"状态。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/msgaudit/check_single_agree?access_token=...`。
pub const getAgreeInfoURL = "https://qyapi.weixin.qq.com/cgi-bin/msgaudit/check_single_agree";

// ─────────────────────────────────────────────────────────────────────────────
// 请求 / 响应结构
// ─────────────────────────────────────────────────────────────────────────────

/// `GetRoomInfo` 响应。对应企业微信 `POST /cgi-bin/msgaudit/groupchat/get`，
/// 请求体为 `{"roomid":"..."}`。
pub const RoomInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 群名称。
    roomname: []const u8 = "",
    /// 群主 userid。
    creator: []const u8 = "",
    /// 群创建时间（Unix 秒）。
    room_create_time: i64 = 0,
    /// 群公告。
    notice: []const u8 = "",
    /// 群成员列表。
    members: []RoomMember = &.{},
};

/// `RoomInfoResponse.members` 中的成员条目。
pub const RoomMember = struct {
    memberid: []const u8 = "",
};

/// `GetAgreeInfo` 请求体。
///
/// `info` 是 `[]AgreeInfoEntry` 列表。
pub const AgreeInfoRequest = struct {
    info: []const AgreeInfoEntry = &.{},
};

/// `AgreeInfoRequest.info` 列表中的元素。
///
/// 注意：企业微信官方文档中该字段的拼写就是 `exteranalopenid`
/// （"external" 的误拼，微信侧历史遗留），请求与响应均使用此拼写，
/// 调用方不要"修正"为 externalopenid。
pub const AgreeInfoEntry = struct {
    /// 企业成员 userid。
    userid: []const u8 = "",
    /// 外部联系人 openid（注意是微信官方拼写 `exteranalopenid`）。
    exteranalopenid: []const u8 = "",
};

/// `GetAgreeInfo` 响应中的单条记录。
pub const AgreeInfo = struct {
    /// 状态变更时间（Unix 秒）。
    status_change_time: i64 = 0,
    userid: []const u8 = "",
    /// 外部联系人 openid（注意是微信官方拼写 `exteranalopenid`）。
    exteranalopenid: []const u8 = "",
    /// "Agree"（已同意）/ "Disagree"（不同意）。
    agree_status: []const u8 = "",
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

    /// 获取会话信息（群聊基础信息）。
    ///
    /// 对应企业微信 `POST /cgi-bin/msgaudit/groupchat/get`，
    /// 请求体为 `{"roomid":"..."}`，`roomid` 为待查询的群 id。
    pub fn getRoomInfo(self: *Self, roomid: []const u8) !std.json.Parsed(RoomInfoResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getRoomInfoURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeRoomIdJson(self.allocator, roomid);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(RoomInfoResponse, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 查询是否需要拉取"同意存档"状态。
    ///
    /// 对应企业微信 `POST /cgi-bin/msgaudit/check_single_agree`。
    /// 请求条目必须同时携带 `userid` 与 `exteranalopenid`
    /// （注意是微信官方拼写，见 `AgreeInfoEntry`）。
    pub fn getAgreeInfo(self: *Self, req: AgreeInfoRequest) !std.json.Parsed(AgreeInfoResponse) {
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

        var parsed = std.json.parseFromSlice(AgreeInfoResponse, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：手写 JSON 序列化
// ─────────────────────────────────────────────────────────────────────────────

/// `roomid` 编码为 `{"roomid":"rid1"}`。
fn encodeRoomIdJson(allocator: std.mem.Allocator, roomid: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"roomid\":\"");
    try appendJsonString(allocator, &buf, roomid);
    try buf.appendSlice(allocator, "\"}");
    return buf.toOwnedSlice(allocator);
}

/// `AgreeInfoRequest` 编码为 `{"info":[{"userid":"u1","exteranalopenid":"o1"},...]}`。
/// 注意 key 使用微信官方拼写 `exteranalopenid`。
fn encodeAgreeInfoJson(allocator: std.mem.Allocator, info: []const AgreeInfoEntry) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"info\":[");
    for (info, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"userid\":\"");
        try appendJsonString(allocator, &buf, entry.userid);
        try buf.appendSlice(allocator, "\",\"exteranalopenid\":\"");
        try appendJsonString(allocator, &buf, entry.exteranalopenid);
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
            else => {
                if (c < 0x20) {
                    // 其余 <0x20 控制字符必须转义为 \u00XX，否则生成非法 JSON。
                    const digits = "0123456789ABCDEF";
                    try buf.appendSlice(allocator, "\\u00");
                    try buf.append(allocator, digits[c >> 4]);
                    try buf.append(allocator, digits[c & 0x0f]);
                } else {
                    try buf.append(allocator, c);
                }
            },
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

test "RoomInfoResponse 默认值" {
    const r = RoomInfoResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
    try std.testing.expectEqualStrings("", r.roomname);
    try std.testing.expectEqual(@as(usize, 0), r.members.len);
}

test "RoomMember 默认值" {
    const m = RoomMember{};
    try std.testing.expectEqualStrings("", m.memberid);
}

test "AgreeInfoRequest 默认值" {
    const r = AgreeInfoRequest{};
    try std.testing.expectEqual(@as(usize, 0), r.info.len);
}

test "AgreeInfoEntry 默认值（含 exteranalopenid）" {
    const e = AgreeInfoEntry{};
    try std.testing.expectEqualStrings("", e.userid);
    try std.testing.expectEqualStrings("", e.exteranalopenid);
}

test "AgreeInfo 默认值" {
    const a = AgreeInfo{};
    try std.testing.expectEqual(@as(i64, 0), a.status_change_time);
    try std.testing.expectEqualStrings("", a.agree_status);
}

test "AgreeInfoResponse 默认值" {
    const r = AgreeInfoResponse{};
    try std.testing.expectEqual(@as(usize, 0), r.agreeinfo.len);
}

test "encodeRoomIdJson 生成正确 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeRoomIdJson(alloc, "r\"1");
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"roomid\":\"r\\\"1\"}", body);
}

test "encodeAgreeInfoJson 生成正确 JSON（exteranalopenid 拼写）" {
    const alloc = std.testing.allocator;
    const body = try encodeAgreeInfoJson(alloc, &.{
        .{ .userid = "u1", .exteranalopenid = "o1" },
    });
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"info\":[{\"userid\":\"u1\",\"exteranalopenid\":\"o1\"}]}", body);
}

test "appendJsonString 转义控制字符为 \\u00XX" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try appendJsonString(alloc, &buf, "a\x01b\x1fc");
    try std.testing.expectEqualStrings("a\\u0001b\\u001Fc", buf.items);
}

// ── Mock transport 测试 ──────────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = @import("../../credential/mod.zig").AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 捕获 uri / method / payload 的 transport，用于断言请求契约。
const Capture = struct {
    uri: []u8 = &.{},
    method: std.http.Method = .GET,
    payload: []u8 = &.{},
    response: []const u8,

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = content_type;
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.uri = try allocator.dupe(u8, uri);
        self.method = method;
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }

    fn deinit(self: *Capture, allocator: std.mem.Allocator) void {
        if (self.uri.len > 0) allocator.free(self.uri);
        if (self.payload.len > 0) allocator.free(self.payload);
        self.* = .{ .response = "" };
    }
};

fn makeCtx() Context {
    return .{
        .config = .{ .corp_id = "ww-audit" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "getRoomInfo 请求与响应契约" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"roomname\":\"研发群\",\"creator\":\"zhangsan\",\"room_create_time\":1594190854,\"notice\":\"公告\",\"members\":[{\"memberid\":\"zhangsan\"},{\"memberid\":\"lisi\"}]}" };

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(Capture.dispatch, @ptrCast(&cap));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
        cap.deinit(allocator);
    }

    var ctx = makeCtx();
    var m = MsgAudit.init(&ctx, allocator);
    var parsed = try m.getRoomInfo("ROOM_ID_1");
    defer parsed.deinit();

    // 请求契约：POST + 正确端点 + {"roomid":"..."}。
    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/msgaudit/groupchat/get?access_token=token-abc", cap.uri);
    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings("{\"roomid\":\"ROOM_ID_1\"}", cap.payload);

    // 响应解析。
    try std.testing.expectEqualStrings("研发群", parsed.value.roomname);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.creator);
    try std.testing.expectEqual(@as(i64, 1594190854), parsed.value.room_create_time);
    try std.testing.expectEqualStrings("公告", parsed.value.notice);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.members.len);
    try std.testing.expectEqualStrings("lisi", parsed.value.members[1].memberid);
}

test "getAgreeInfo 请求与响应契约" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"agreeinfo\":[{\"status_change_time\":1594190854,\"userid\":\"zhangsan\",\"exteranalopenid\":\"o-1\",\"agree_status\":\"Agree\"}]}" };

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(Capture.dispatch, @ptrCast(&cap));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
        cap.deinit(allocator);
    }

    var ctx = makeCtx();
    var m = MsgAudit.init(&ctx, allocator);
    var parsed = try m.getAgreeInfo(.{
        .info = &.{.{ .userid = "zhangsan", .exteranalopenid = "o-1" }},
    });
    defer parsed.deinit();

    // 请求契约：POST + 正确端点 + 同时携带 userid / exteranalopenid。
    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/msgaudit/check_single_agree?access_token=token-abc", cap.uri);
    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings("{\"info\":[{\"userid\":\"zhangsan\",\"exteranalopenid\":\"o-1\"}]}", cap.payload);

    // 响应解析。
    try std.testing.expectEqual(@as(usize, 1), parsed.value.agreeinfo.len);
    const info = parsed.value.agreeinfo[0];
    try std.testing.expectEqual(@as(i64, 1594190854), info.status_change_time);
    try std.testing.expectEqualStrings("zhangsan", info.userid);
    try std.testing.expectEqualStrings("o-1", info.exteranalopenid);
    try std.testing.expectEqualStrings("Agree", info.agree_status);
}
