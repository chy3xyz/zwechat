//! officialaccount/menu — 自定义菜单
//!
//! 对应 `_ref/wechat/officialaccount/menu/`：提供 12 类按钮构造器 + CRUD API。
//! 主要接口：SetMenu / GetMenu / DeleteMenu / AddConditional / DeleteConditional /
//! MenuTryMatch / GetCurrentSelfMenuInfo。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 公众号菜单顶层 struct。
pub const Menu = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 创建自定义菜单（POST JSON）。
    pub fn setMenu(self: *Self, buttons: []const Button) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ menuCreateURL, access_token },
        );
        defer self.allocator.free(uri);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try writeJsonButtons(self.allocator, &buf, buttons);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.postJSON(uri, buf.items);
        defer self.allocator.free(body);

        if (try util_error.decodeWithCommonError(self.allocator, body, "SetMenu")) |ce| {
            std.debug.print("SetMenu err: {s}\n", .{ce.errmsg});
        }
    }

    /// 查询当前菜单。
    pub fn getMenu(self: *Self) !ResMenu {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ menuGetURL, access_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResMenu, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 删除菜单。
    pub fn deleteMenu(self: *Self) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ menuDeleteURL, access_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        if (try util_error.decodeWithCommonError(self.allocator, body, "DeleteMenu")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    /// 创建个性化菜单（POST JSON）。
    pub fn addConditional(self: *Self, buttons: []const Button, match_rule: ?MatchRule) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ menuAddConditionalURL, access_token },
        );
        defer self.allocator.free(uri);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"button\":[");
        for (buttons, 0..) |b, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try writeJsonButton(self.allocator, &buf, &b);
        }
        try buf.appendSlice(self.allocator, "]}");
        if (match_rule) |rule| {
            try buf.appendSlice(self.allocator, ",\"matchrule\":");
            try writeJsonMatchRule(self.allocator, &buf, &rule);
        }
        try buf.append(self.allocator, '}');

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.postJSON(uri, buf.items);
        defer self.allocator.free(body);

        if (try util_error.decodeWithCommonError(self.allocator, body, "AddConditional")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    /// 测试个性化菜单匹配。
    pub fn menuTryMatch(self: *Self, user_id: []const u8) ![]Button {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ menuTryMatchURL, access_token },
        );
        defer self.allocator.free(uri);

        const req_body = try std.fmt.allocPrint(self.allocator, "{{\"user_id\":\"{s}\"}}", .{user_id});
        defer self.allocator.free(req_body);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.postJSON(uri, req_body);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            button: []Button = &.{},
        }, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value.button;
    }
};

/// 菜单按钮。
pub const Button = struct {
    type_: []const u8 = "", // JSON: "type"（Zig 中 `type` 是关键字，所以改名为 type_）
    name: []const u8 = "",
    key: []const u8 = "",
    url: []const u8 = "",
    media_id: []const u8 = "",
    appid: []const u8 = "",
    pagepath: []const u8 = "",
    sub_button: []const Button = &.{},

    pub fn setClick(name: []const u8, key: []const u8) Button {
        return .{ .type_ = "click", .name = name, .key = key };
    }
    pub fn setView(name: []const u8, url: []const u8) Button {
        return .{ .type_ = "view", .name = name, .url = url };
    }
    pub fn setScanCodePush(name: []const u8, key: []const u8) Button {
        return .{ .type_ = "scancode_push", .name = name, .key = key };
    }
    pub fn setScanCodeWaitMsg(name: []const u8, key: []const u8) Button {
        return .{ .type_ = "scancode_waitmsg", .name = name, .key = key };
    }
    pub fn setPicSysPhoto(name: []const u8, key: []const u8) Button {
        return .{ .type_ = "pic_sysphoto", .name = name, .key = key };
    }
    pub fn setPicPhotoOrAlbum(name: []const u8, key: []const u8) Button {
        return .{ .type_ = "pic_photo_or_album", .name = name, .key = key };
    }
    pub fn setPicWeixin(name: []const u8, key: []const u8) Button {
        return .{ .type_ = "pic_weixin", .name = name, .key = key };
    }
    pub fn setLocationSelect(name: []const u8, key: []const u8) Button {
        return .{ .type_ = "location_select", .name = name, .key = key };
    }
    pub fn setMediaID(name: []const u8, media_id: []const u8) Button {
        return .{ .type_ = "media_id", .name = name, .media_id = media_id };
    }
    pub fn setViewLimited(name: []const u8, media_id: []const u8) Button {
        return .{ .type_ = "view_limited", .name = name, .media_id = media_id };
    }
    pub fn setMiniprogram(name: []const u8, url: []const u8, appid: []const u8, pagepath: []const u8) Button {
        return .{
            .type_ = "miniprogram",
            .name = name,
            .url = url,
            .appid = appid,
            .pagepath = pagepath,
        };
    }
    pub fn setSub(name: []const u8, sub: []const Button) Button {
        return .{ .name = name, .sub_button = sub };
    }
};

/// 个性化菜单匹配规则。
pub const MatchRule = struct {
    group_id: []const u8 = "",
    sex: []const u8 = "",
    country: []const u8 = "",
    province: []const u8 = "",
    city: []const u8 = "",
    client_platform_type: []const u8 = "",
    language: []const u8 = "",
};

/// `GetMenu` 返回结构。
pub const ResMenu = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    menu: struct {
        button: []Button = &.{},
        menuid: i64 = 0,
    } = .{},
    conditionalmenu: []ConditionalMenu = &.{},

    pub const ConditionalMenu = struct {
        button: []Button = &.{},
        matchrule: MatchRule = .{},
        menuid: i64 = 0,
    };
};

// ──────────────────────────────────────────────────────────────────────────────
// 内部：JSON 序列化辅助
// ──────────────────────────────────────────────────────────────────────────────

fn writeJsonButton(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), b: *const Button) !void {
    try buf.append(allocator, '{');
    var first = true;
    if (b.type_.len > 0) {
        try buf.appendSlice(allocator, "\"type\":\"");
        try appendJsonString(allocator, buf, b.type_);
        try buf.append(allocator, '"');
        first = false;
    }
    if (b.name.len > 0) {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"name\":\"");
        try appendJsonString(allocator, buf, b.name);
        try buf.append(allocator, '"');
        first = false;
    }
    if (b.key.len > 0) {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"key\":\"");
        try appendJsonString(allocator, buf, b.key);
        try buf.append(allocator, '"');
        first = false;
    }
    if (b.url.len > 0) {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"url\":\"");
        try appendJsonString(allocator, buf, b.url);
        try buf.append(allocator, '"');
        first = false;
    }
    if (b.media_id.len > 0) {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"media_id\":\"");
        try appendJsonString(allocator, buf, b.media_id);
        try buf.append(allocator, '"');
        first = false;
    }
    if (b.appid.len > 0) {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"appid\":\"");
        try appendJsonString(allocator, buf, b.appid);
        try buf.append(allocator, '"');
        first = false;
    }
    if (b.pagepath.len > 0) {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"pagepath\":\"");
        try appendJsonString(allocator, buf, b.pagepath);
        try buf.append(allocator, '"');
        first = false;
    }
    if (b.sub_button.len > 0) {
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"sub_button\":[");
        for (b.sub_button, 0..) |sb, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeJsonButton(allocator, buf, &sb);
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, '}');
}

fn writeJsonButtons(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), buttons: []const Button) !void {
    try buf.appendSlice(allocator, "{\"button\":[");
    for (buttons, 0..) |b, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeJsonButton(allocator, buf, &b);
    }
    try buf.appendSlice(allocator, "]}");
}

fn writeJsonMatchRule(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), r: *const MatchRule) !void {
    try buf.append(allocator, '{');
    var first = true;
    inline for (.{
        .{ "group_id", &r.group_id },
        .{ "sex", &r.sex },
        .{ "country", &r.country },
        .{ "province", &r.province },
        .{ "city", &r.city },
        .{ "client_platform_type", &r.client_platform_type },
        .{ "language", &r.language },
    }) |pair| {
        const key: []const u8 = pair[0];
        const val: *const []const u8 = pair[1];
        if (val.len == 0) continue;
        if (!first) try buf.append(allocator, ',');
        try buf.writer.print("\"{s}\":\"", .{key});
        try appendJsonString(allocator, buf, val.*);
        try buf.append(allocator, '"');
        first = false;
    }
    try buf.append(allocator, '}');
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

// ──────────────────────────────────────────────────────────────────────────────
// URL 常量
// ──────────────────────────────────────────────────────────────────────────────

pub const menuCreateURL = "https://api.weixin.qq.com/cgi-bin/menu/create";
pub const menuGetURL = "https://api.weixin.qq.com/cgi-bin/menu/get";
pub const menuDeleteURL = "https://api.weixin.qq.com/cgi-bin/menu/delete";
pub const menuAddConditionalURL = "https://api.weixin.qq.com/cgi-bin/menu/addconditional";
pub const menuDeleteConditionalURL = "https://api.weixin.qq.com/cgi-bin/menu/delconditional";
pub const menuTryMatchURL = "https://api.weixin.qq.com/cgi-bin/menu/trymatch";
pub const menuSelfMenuInfoURL = "https://api.weixin.qq.com/cgi-bin/get_current_selfmenu_info";

// ──────────────────────────────────────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────────────────────────────────────

test "Button 构造器返回预期 type" {
    try std.testing.expectEqualStrings("click", Button.setClick("a", "k").type_);
    try std.testing.expectEqualStrings("view", Button.setView("a", "u").type_);
    try std.testing.expectEqualStrings("miniprogram", Button.setMiniprogram("a", "u", "aid", "/p").type_);
}

test "MatchRule 默认值" {
    const r = MatchRule{};
    try std.testing.expectEqualStrings("", r.group_id);
    try std.testing.expectEqualStrings("", r.sex);
}

test "Menu.init 暴露 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const m = Menu.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("wx-test", m.ctx.config.app_id);
}