// SPDX-License-Identifier: Apache-2.0
//! miniprogram/subscribe — 订阅消息
//!
//! 对应 `_ref/wechat/miniprogram/subscribe/subscribe.go`：发送订阅消息、模板列表、
//! 类目、统一服务消息等。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 订阅消息请求。
pub const Message = struct {
    touser: []const u8,
    template_id: []const u8,
    page: []const u8 = "",
    data: []const DataEntry = &.{},
    miniprogram_state: []const u8 = "",
    lang: []const u8 = "",
};

/// 模板内容键值对。
pub const DataEntry = struct {
    key: []const u8,
    value: []const u8,
    color: []const u8 = "",
};

/// 模板项。
pub const TemplateItem = struct {
    pri_tmpl_id: []const u8 = "",
    title: []const u8 = "",
    content: []const u8 = "",
    example: []const u8 = "",
    type: i64 = 0,
    keyword_enum_value_list: []const KeywordEnumValue = &.{},
};

pub const KeywordEnumValue = struct {
    enum_value_list: []const []const u8 = &.{},
    keyword_code: []const u8 = "",
};

/// 模板列表。
pub const TemplateList = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    data: []const TemplateItem = &.{},
};

/// 类目。
pub const Category = struct {
    id: i64 = 0,
    name: []const u8 = "",
};

/// 订阅消息模块。
pub const Subscribe = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 发送订阅消息。
    pub fn send(self: *Self, msg: Message) !void {
        const body = try jsonStringifyMessage(self.allocator, msg);
        defer self.allocator.free(body);
        try self.postCommon("https://api.weixin.qq.com/cgi-bin/message/subscribe/send", body, "Send");
    }

    /// 发送订阅消息并返回 msgid。
    pub fn sendGetMsgId(self: *Self, msg: Message) !i64 {
        const body = try jsonStringifyMessage(self.allocator, msg);
        defer self.allocator.free(body);

        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/message/subscribe/send?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            msgid: i64 = 0,
        }, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value.msgid;
    }

    /// 获取当前帐号下的个人模板列表。
    pub fn listTemplates(self: *Self) !std.json.Parsed(TemplateList) {
        return self.getParsed("https://api.weixin.qq.com/wxaapi/newtmpl/gettemplate", TemplateList);
    }

    /// 获取类目。
    pub fn getCategory(self: *Self) !std.json.Parsed(struct {
        errcode: i64 = 0,
        errmsg: []const u8 = "",
        data: []const Category = &.{},
    }) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxaapi/newtmpl/getcategory?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.get(uri);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            data: []const Category = &.{},
        }, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    fn postCommon(self: *Self, url: []const u8, body: []const u8, api_name: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ url, access_token });
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, api_name)) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    fn getParsed(self: *Self, comptime T: type, url: []const u8) !std.json.Parsed(T) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ url, access_token });
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.get(uri);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(T, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

fn jsonStringifyMessage(allocator: std.mem.Allocator, msg: Message) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("touser");
    try s.write(msg.touser);
    try s.objectField("template_id");
    try s.write(msg.template_id);
    if (msg.page.len > 0) {
        try s.objectField("page");
        try s.write(msg.page);
    }
    try s.objectField("data");
    try s.beginObject();
    for (msg.data) |entry| {
        try s.objectField(entry.key);
        try s.beginObject();
        try s.objectField("value");
        try s.write(entry.value);
        if (entry.color.len > 0) {
            try s.objectField("color");
            try s.write(entry.color);
        }
        try s.endObject();
    }
    try s.endObject();
    if (msg.miniprogram_state.len > 0) {
        try s.objectField("miniprogram_state");
        try s.write(msg.miniprogram_state);
    }
    if (msg.lang.len > 0) {
        try s.objectField("lang");
        try s.write(msg.lang);
    }
    try s.endObject();
    return out.toOwnedSlice();
}

test "Subscribe.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-sub" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const s = Subscribe.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-sub", s.ctx.config.app_id);
}

test "Message 序列化包含 touser 与 data" {
    const allocator = std.testing.allocator;
    const body = try jsonStringifyMessage(allocator, .{
        .touser = "openid-1",
        .template_id = "tmpl-1",
        .data = &.{.{ .key = "thing1", .value = "hello" }},
    });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"touser\":\"openid-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thing1\"") != null);
}
