//! work/appchat — 应用群（群信息 / 推送）
//!
//! 对应 `_ref/wechat/work/appchat/`：企业微信应用群相关接口。
//! 当前落地 `CreateChat`（创建群）/ `GetChatInfo`（查群详情）/ `UpdateChat`（改群信息）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 创建群。
pub const appchatCreateURL = "https://qyapi.weixin.qq.com/cgi-bin/appchat/create";

/// 获取群信息。
pub const appchatGetURL = "https://qyapi.weixin.qq.com/cgi-bin/appchat/get";

/// 修改群信息。
pub const appchatUpdateURL = "https://qyapi.weixin.qq.com/cgi-bin/appchat/update";

/// 推送群消息。
pub const appchatSendURL = "https://qyapi.weixin.qq.com/cgi-bin/appchat/send";

// ─────────────────────────────────────────────────────────────────────────────
// 响应 / 数据结构
// ─────────────────────────────────────────────────────────────────────────────

/// 群聊详情。
pub const ChatInfo = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    chat_id: []const u8 = "",
    name: []const u8 = "",
    owner: []const u8 = "",
    userlist: [][]const u8 = &.{},
};

/// `CreateChat` 请求体。
pub const CreateChatRequest = struct {
    chat_id: []const u8 = "",
    name: []const u8 = "",
    owner: []const u8 = "",
    userlist: [][]const u8 = &.{},
};

/// `CreateChat` 响应。
pub const CreateChatResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    chat_id: []const u8 = "",
};

/// `UpdateChat` 请求体。
pub const UpdateChatRequest = struct {
    chat_id: []const u8 = "",
    name: []const u8 = "",
    owner: []const u8 = "",
    add_user_list: [][]const u8 = &.{},
    del_user_list: [][]const u8 = &.{},
};

/// `UpdateChat` 响应。
pub const CommonResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 应用群子模块聚合。
pub const AppChat = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 创建群聊。
    ///
    /// 对应 `_ref/wechat/work/appchat/appchat.go` 之外的「创建群」接口
    /// （`/cgi-bin/appchat/create`），是群推送流程的前置步骤。
    pub fn createChat(self: *Self, req: CreateChatRequest) !CreateChatResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ appchatCreateURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeCreateChatRequest(self.allocator, req);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CreateChatResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 获取群信息。
    ///
    /// 对应 `/cgi-bin/appchat/get`。
    pub fn getChatInfo(self: *Self, chat_id: []const u8) !ChatInfo {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}&chatid={s}",
            .{ appchatGetURL, access_token, chat_id },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ChatInfo, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 修改群信息。
    ///
    /// 对应 `/cgi-bin/appchat/update`。
    pub fn updateChat(self: *Self, req: UpdateChatRequest) !CommonResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ appchatUpdateURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeUpdateChatRequest(self.allocator, req);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CommonResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助
// ─────────────────────────────────────────────────────────────────────────────

/// 手写序列化 `CreateChatRequest`，避免引入 `std.json` 的反射栈。
fn encodeCreateChatRequest(allocator: std.mem.Allocator, req: CreateChatRequest) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"chatid\":\"");
    try appendJsonString(allocator, &buf, req.chat_id);
    try buf.appendSlice(allocator, "\",\"name\":\"");
    try appendJsonString(allocator, &buf, req.name);
    try buf.appendSlice(allocator, "\",\"owner\":\"");
    try appendJsonString(allocator, &buf, req.owner);
    try buf.appendSlice(allocator, "\",\"userlist\":[");
    for (req.userlist, 0..) |u, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try appendJsonString(allocator, &buf, u);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn encodeUpdateChatRequest(allocator: std.mem.Allocator, req: UpdateChatRequest) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"chatid\":\"");
    try appendJsonString(allocator, &buf, req.chat_id);
    try buf.appendSlice(allocator, "\",\"name\":\"");
    try appendJsonString(allocator, &buf, req.name);
    try buf.appendSlice(allocator, "\",\"owner\":\"");
    try appendJsonString(allocator, &buf, req.owner);
    try buf.appendSlice(allocator, "\",\"add_user_list\":[");
    for (req.add_user_list, 0..) |u, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try appendJsonString(allocator, &buf, u);
        try buf.append(allocator, '"');
    }
    try buf.appendSlice(allocator, "],\"del_user_list\":[");
    for (req.del_user_list, 0..) |u, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try appendJsonString(allocator, &buf, u);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, "]}");
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

test "AppChat.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-appchat" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const ac = AppChat.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-appchat", ac.ctx.config.corp_id);
}

test "CreateChatRequest 默认值" {
    const r = CreateChatRequest{};
    try std.testing.expectEqualStrings("", r.chat_id);
    try std.testing.expectEqualStrings("", r.name);
    try std.testing.expectEqual(@as(usize, 0), r.userlist.len);
}

test "UpdateChatRequest 默认值" {
    const r = UpdateChatRequest{};
    try std.testing.expectEqualStrings("", r.chat_id);
    try std.testing.expectEqual(@as(usize, 0), r.add_user_list.len);
    try std.testing.expectEqual(@as(usize, 0), r.del_user_list.len);
}

test "ChatInfo 默认值" {
    const c = ChatInfo{};
    try std.testing.expectEqualStrings("", c.chat_id);
    try std.testing.expectEqualStrings("", c.name);
    try std.testing.expectEqualStrings("", c.owner);
    try std.testing.expectEqual(@as(usize, 0), c.userlist.len);
}
