// SPDX-License-Identifier: Apache-2.0
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

/// `GetChatInfo` 响应：顶层为 errcode/errmsg，群字段包在 `chat_info` 内
/// （对齐企业微信 `GET /cgi-bin/appchat/get` 的真实返回结构）。
pub const ChatInfo = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    chat_info: ChatInfoInner = .{},
};

/// `ChatInfo.chat_info` 内层结构。注意 key 是 `chatid`（不是 `chat_id`）。
pub const ChatInfoInner = struct {
    chatid: []const u8 = "",
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

/// `CreateChat` 响应。微信返回的 key 是 `chatid`（不是 `chat_id`）。
pub const CreateChatResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    chatid: []const u8 = "",
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
    pub fn createChat(self: *Self, req: CreateChatRequest) !std.json.Parsed(CreateChatResponse) {
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

        var parsed = std.json.parseFromSlice(CreateChatResponse, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 获取群信息。
    ///
    /// 对应 `/cgi-bin/appchat/get`。
    pub fn getChatInfo(self: *Self, chat_id: []const u8) !std.json.Parsed(ChatInfo) {
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

        var parsed = std.json.parseFromSlice(ChatInfo, self.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 修改群信息。
    ///
    /// 对应 `/cgi-bin/appchat/update`。
    pub fn updateChat(self: *Self, req: UpdateChatRequest) !std.json.Parsed(CommonResponse) {
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

        var parsed = std.json.parseFromSlice(CommonResponse, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
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
    try buf.appendSlice(allocator, "]}");
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

test "ChatInfo 默认值（chat_info 内层包装）" {
    const c = ChatInfo{};
    try std.testing.expectEqualStrings("", c.chat_info.chatid);
    try std.testing.expectEqualStrings("", c.chat_info.name);
    try std.testing.expectEqualStrings("", c.chat_info.owner);
    try std.testing.expectEqual(@as(usize, 0), c.chat_info.userlist.len);
}

test "CreateChatResponse 默认值（chatid）" {
    const r = CreateChatResponse{};
    try std.testing.expectEqualStrings("", r.chatid);
}

// ── Mock transport 测试 ──────────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = @import("../../credential/mod.zig").AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .corp_id = "ww-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "getChatInfo 解析 chat_info 包装结构" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/appchat/get?access_token=token-abc&chatid=g-1", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"chat_info\":{\"chatid\":\"g-1\",\"name\":\"研发群\",\"owner\":\"zhangsan\",\"userlist\":[\"zhangsan\",\"lisi\"]}}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var ac = AppChat.init(&ctx, allocator);
    var parsed = try ac.getChatInfo("g-1");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("g-1", parsed.value.chat_info.chatid);
    try std.testing.expectEqualStrings("研发群", parsed.value.chat_info.name);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.chat_info.owner);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.chat_info.userlist.len);
    try std.testing.expectEqualStrings("lisi", parsed.value.chat_info.userlist[1]);
}

test "createChat 解析 chatid 字段" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/appchat/create?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"chatid\":\"g-new\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var ac = AppChat.init(&ctx, allocator);
    var userlist = [_][]const u8{"zhangsan"};
    var parsed = try ac.createChat(.{
        .chat_id = "g-new",
        .name = "群",
        .owner = "zhangsan",
        .userlist = &userlist,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("g-new", parsed.value.chatid);
}
