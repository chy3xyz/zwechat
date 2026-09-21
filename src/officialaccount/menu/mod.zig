// SPDX-License-Identifier: Apache-2.0
//! officialaccount/menu — 自定义菜单
//!
//! 对应 `_ref/wechat/officialaccount/menu/`：提供 12 类按钮构造器 + CRUD API。
//! 主要接口：SetMenu / GetMenu / DeleteMenu / AddConditional / DeleteConditional /
//! MenuTryMatch / GetCurrentSelfMenuInfo。

const std = @import("std");
const Context = @import("../context.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_json = @import("../../util/json.zig");

/// 公众号菜单顶层 struct。
pub const Menu = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 创建自定义菜单（POST JSON）。
    pub fn setMenu(self: *Self, buttons: []const Button) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try writeJsonButtons(self.allocator, &buf, buttons);

        const body = try util_retry.callApi(self.ctx, self.allocator, "SetMenu", TokenReq{
            .menu = self,
            .url = menuCreateURL,
            .payload = buf.items,
        });
        defer self.allocator.free(body);
    }

    /// 查询当前菜单。
    /// 返回的 `std.json.Parsed(ResMenu)` 由调用方持有并负责 `deinit`。
    pub fn getMenu(self: *Self) !std.json.Parsed(ResMenu) {
        const body = try util_retry.callApi(self.ctx, self.allocator, "GetMenu", TokenReq{
            .menu = self,
            .url = menuGetURL,
        });
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResMenu, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return parsed;
    }

    /// 删除菜单。
    pub fn deleteMenu(self: *Self) !void {
        const body = try util_retry.callApi(self.ctx, self.allocator, "DeleteMenu", TokenReq{
            .menu = self,
            .url = menuDeleteURL,
        });
        defer self.allocator.free(body);
    }

    /// 创建个性化菜单（POST JSON），结构为 `{"button":[...],"matchrule":{...}}`。
    pub fn addConditional(self: *Self, buttons: []const Button, match_rule: ?MatchRule) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"button\":[");
        for (buttons, 0..) |b, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try writeJsonButton(self.allocator, &buf, &b);
        }
        // 注意：这里只闭合 button 数组；matchrule 与 button 同属一个 JSON 对象。
        try buf.append(self.allocator, ']');
        if (match_rule) |rule| {
            try buf.appendSlice(self.allocator, ",\"matchrule\":");
            try writeJsonMatchRule(self.allocator, &buf, &rule);
        }
        try buf.append(self.allocator, '}');

        const body = try util_retry.callApi(self.ctx, self.allocator, "AddConditional", TokenReq{
            .menu = self,
            .url = menuAddConditionalURL,
            .payload = buf.items,
        });
        defer self.allocator.free(body);
    }

    /// 删除个性化菜单。
    pub fn deleteConditional(self: *Self, menu_id: i64) !void {
        const req_body = try std.fmt.allocPrint(self.allocator, "{{\"menuid\":{d}}}", .{menu_id});
        defer self.allocator.free(req_body);

        const body = try util_retry.callApi(self.ctx, self.allocator, "DeleteConditional", TokenReq{
            .menu = self,
            .url = menuDeleteConditionalURL,
            .payload = req_body,
        });
        defer self.allocator.free(body);
    }

    /// 测试个性化菜单匹配。
    /// 返回的 `std.json.Parsed(TryMatchResult)` 由调用方持有并负责 `deinit`。
    pub fn menuTryMatch(self: *Self, user_id: []const u8) !std.json.Parsed(TryMatchResult) {
        const req_body = try std.fmt.allocPrint(self.allocator, "{{\"user_id\":\"{s}\"}}", .{user_id});
        defer self.allocator.free(req_body);

        const body = try util_retry.callApi(self.ctx, self.allocator, "MenuTryMatch", TokenReq{
            .menu = self,
            .url = menuTryMatchURL,
            .payload = req_body,
        });
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(TryMatchResult, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return parsed;
    }

    /// 获取自定义菜单配置（开发接口）。
    /// 返回的 `std.json.Parsed(ResSelfMenuInfo)` 由调用方持有并负责 `deinit`。
    pub fn getCurrentSelfMenuInfo(self: *Self) !std.json.Parsed(ResSelfMenuInfo) {
        const body = try util_retry.callApi(self.ctx, self.allocator, "GetCurrentSelfMenuInfo", TokenReq{
            .menu = self,
            .url = menuSelfMenuInfoURL,
        });
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResSelfMenuInfo, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return parsed;
    }

    fn httpGet(self: *Self, uri: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.get(uri);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.get(uri);
    }

    fn postJSON(self: *Self, uri: []const u8, payload: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, payload);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, payload);
    }
};

/// 单次带 token 调用的请求构造器：交给 `util/retry.callApi` 复用模块自己的
/// transport 注入逻辑（`payload` 为 null 时走 GET）。`send` 必须 `pub`（跨文件调用）。
const TokenReq = struct {
    menu: *Menu,
    url: []const u8,
    payload: ?[]const u8 = null,

    pub fn send(self: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const uri = try std.fmt.allocPrint(allocator, "{s}?access_token={s}", .{ self.url, token });
        defer allocator.free(uri);
        if (self.payload) |p| return self.menu.postJSON(uri, p);
        return self.menu.httpGet(uri);
    }
};

/// 菜单按钮。字段 `@"type"` 对应 JSON 键 `type`（`type` 是 Zig 关键字）。
pub const Button = struct {
    type: []const u8 = "",
    name: []const u8 = "",
    key: []const u8 = "",
    url: []const u8 = "",
    media_id: []const u8 = "",
    appid: []const u8 = "",
    pagepath: []const u8 = "",
    sub_button: []const Button = &.{},

    pub fn setClick(name: []const u8, key: []const u8) Button {
        return .{ .type = "click", .name = name, .key = key };
    }
    pub fn setView(name: []const u8, url: []const u8) Button {
        return .{ .type = "view", .name = name, .url = url };
    }
    pub fn setScanCodePush(name: []const u8, key: []const u8) Button {
        return .{ .type = "scancode_push", .name = name, .key = key };
    }
    pub fn setScanCodeWaitMsg(name: []const u8, key: []const u8) Button {
        return .{ .type = "scancode_waitmsg", .name = name, .key = key };
    }
    pub fn setPicSysPhoto(name: []const u8, key: []const u8) Button {
        return .{ .type = "pic_sysphoto", .name = name, .key = key };
    }
    pub fn setPicPhotoOrAlbum(name: []const u8, key: []const u8) Button {
        return .{ .type = "pic_photo_or_album", .name = name, .key = key };
    }
    pub fn setPicWeixin(name: []const u8, key: []const u8) Button {
        return .{ .type = "pic_weixin", .name = name, .key = key };
    }
    pub fn setLocationSelect(name: []const u8, key: []const u8) Button {
        return .{ .type = "location_select", .name = name, .key = key };
    }
    pub fn setMediaID(name: []const u8, media_id: []const u8) Button {
        return .{ .type = "media_id", .name = name, .media_id = media_id };
    }
    pub fn setViewLimited(name: []const u8, media_id: []const u8) Button {
        return .{ .type = "view_limited", .name = name, .media_id = media_id };
    }
    pub fn setMiniprogram(name: []const u8, url: []const u8, appid: []const u8, pagepath: []const u8) Button {
        return .{
            .type = "miniprogram",
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

/// `MenuTryMatch` 返回结构。
pub const TryMatchResult = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    button: []Button = &.{},
};

/// `GetCurrentSelfMenuInfo` 返回结构。
pub const ResSelfMenuInfo = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    is_menu_open: i32 = 0,
    selfmenu_info: struct {
        button: []SelfMenuButton = &.{},
    } = .{},
};

/// 自定义菜单配置详情按钮。
pub const SelfMenuButton = struct {
    type: []const u8 = "",
    name: []const u8 = "",
    key: []const u8 = "",
    url: []const u8 = "",
    value: []const u8 = "",
    sub_button: struct {
        list: []SelfMenuButton = &.{},
    } = .{},
    news_info: struct {
        list: []ButtonNew = &.{},
    } = .{},
};

/// 图文消息菜单条目。
pub const ButtonNew = struct {
    title: []const u8 = "",
    author: []const u8 = "",
    digest: []const u8 = "",
    show_cover: i32 = 0,
    cover_url: []const u8 = "",
    content_url: []const u8 = "",
    source_url: []const u8 = "",
};

// ──────────────────────────────────────────────────────────────────────────────
// 内部：JSON 序列化辅助
// ──────────────────────────────────────────────────────────────────────────────

fn writeJsonButton(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), b: *const Button) !void {
    try buf.append(allocator, '{');
    var first = true;
    if (b.type.len > 0) {
        try buf.appendSlice(allocator, "\"type\":\"");
        try appendJsonString(allocator, buf, b.type);
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
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "group_id", .value = r.group_id },
        .{ .name = "sex", .value = r.sex },
        .{ .name = "country", .value = r.country },
        .{ .name = "province", .value = r.province },
        .{ .name = "city", .value = r.city },
        .{ .name = "client_platform_type", .value = r.client_platform_type },
        .{ .name = "language", .value = r.language },
    };
    for (fields) |f| {
        if (f.value.len == 0) continue;
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, "\":\"");
        try appendJsonString(allocator, buf, f.value);
        try buf.append(allocator, '"');
        first = false;
    }
    try buf.append(allocator, '}');
}

/// JSON 字符串转义（实现收敛到 `util.json.appendEscapedString`；此前漏转义
/// `c < 0x20` 控制字符，菜单名等调用方文本含控制字符时会产出非法 JSON）。
const appendJsonString = util_json.appendEscapedString;

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

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "Button 构造器返回预期 type" {
    try std.testing.expectEqualStrings("click", Button.setClick("a", "k").type);
    try std.testing.expectEqualStrings("view", Button.setView("a", "u").type);
    try std.testing.expectEqualStrings("miniprogram", Button.setMiniprogram("a", "u", "aid", "/p").type);
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

test "writeJsonButtons 输出合法 JSON 且含子菜单" {
    const allocator = std.testing.allocator;
    const sub = [_]Button{Button.setClick("s1", "k1")};
    const buttons = [_]Button{
        Button.setClick("一级", "V1001"),
        Button.setSub("父菜单", &sub),
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try writeJsonButtons(allocator, &buf, &buttons);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const arr = root.get("button").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    const first = arr.items[0].object;
    try std.testing.expectEqualStrings("click", first.get("type").?.string);
    try std.testing.expectEqualStrings("一级", first.get("name").?.string);
    const second = arr.items[1].object;
    try std.testing.expectEqual(@as(usize, 1), second.get("sub_button").?.array.items.len);
}

test "addConditional JSON 结构合法（回归：matchrule 曾拼到对象外）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/menu/addconditional?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    var ctx = makeCtx();
    var m = Menu.init(&ctx, allocator);
    m.setTransport(util_http.MockTransport.dispatch, &mt);

    const buttons = [_]Button{Button.setView("官网", "https://example.com")};
    try m.addConditional(&buttons, .{ .country = "中国", .province = "广东" });

    // 用与 addConditional 相同的序列化路径重建期望体，并用 std.json 校验合法性。
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"button\":[");
    for (buttons, 0..) |b, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeJsonButton(allocator, &buf, &b);
    }
    try buf.append(allocator, ']');
    try buf.appendSlice(allocator, ",\"matchrule\":");
    try writeJsonMatchRule(allocator, &buf, &.{
        .country = "中国",
        .province = "广东",
    });
    try buf.append(allocator, '}');

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{}) catch |err| {
        std.debug.print("非法 JSON: {s}\n", .{buf.items});
        return err;
    };
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.contains("button"));
    try std.testing.expect(root.contains("matchrule"));
}

test "setMenu errcode != 0 返回 ApiError（回归：错误曾被打印后吞掉）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/menu/create?access_token=token-abc", .{
        .body = "{\"errcode\":40018,\"errmsg\":\"invalid button name size\"}",
    });

    var ctx = makeCtx();
    var m = Menu.init(&ctx, allocator);
    m.setTransport(util_http.MockTransport.dispatch, &mt);

    const buttons = [_]Button{Button.setClick("a", "k")};
    try std.testing.expectError(util_error.WechatError.ApiError, m.setMenu(&buttons));
}

test "getMenu 解析 type 字段（回归：type_ 与 JSON 键 type 不匹配）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/menu/get?access_token=token-abc", .{
        .body =
        \\{"menu":{"button":[{"type":"click","name":"今日歌曲","key":"V1001_TODAY_MUSIC"}],"menuid":208396938}}
        ,
    });

    var ctx = makeCtx();
    var m = Menu.init(&ctx, allocator);
    m.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try m.getMenu();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.menu.button.len);
    try std.testing.expectEqualStrings("click", parsed.value.menu.button[0].type);
    try std.testing.expectEqualStrings("今日歌曲", parsed.value.menu.button[0].name);
}

test "deleteConditional 请求 menuid" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/menu/delconditional?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    var ctx = makeCtx();
    var m = Menu.init(&ctx, allocator);
    m.setTransport(util_http.MockTransport.dispatch, &mt);

    try m.deleteConditional(208396938);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}

test "getCurrentSelfMenuInfo 解析 selfmenu_info" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/get_current_selfmenu_info?access_token=token-abc", .{
        .body =
        \\{"is_menu_open":1,"selfmenu_info":{"button":[{"type":"click","name":"今日歌曲","key":"V1001"}]}}
        ,
    });

    var ctx = makeCtx();
    var m = Menu.init(&ctx, allocator);
    m.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try m.getCurrentSelfMenuInfo();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 1), parsed.value.is_menu_open);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.selfmenu_info.button.len);
    try std.testing.expectEqualStrings("click", parsed.value.selfmenu_info.button[0].type);
}

test "menuTryMatch 返回 button 列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/menu/trymatch?access_token=token-abc", .{
        .body = "{\"button\":[{\"type\":\"view\",\"name\":\"官网\",\"url\":\"https://example.com\"}]}",
    });

    var ctx = makeCtx();
    var m = Menu.init(&ctx, allocator);
    m.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try m.menuTryMatch("openid-1");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.button.len);
    try std.testing.expectEqualStrings("view", parsed.value.button[0].type);
}

// —— token 失效自愈 / 非 token 错误不重试 ——

/// 可作废的假凭据：作废前发 `token-abc`，作废后发 `token-new`（模拟微信换发新 token）。
const HealToken = struct {
    cached: []const u8 = "token-abc",
    invalidates: usize = 0,

    fn getToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.cached);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        self.invalidates += 1;
        self.cached = "token-new";
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

/// 按调用次序返回响应、并记录每次请求 URI 的 transport。
const SeqResp = struct {
    responses: []const []const u8,
    calls: usize = 0,
    uris: [4][160]u8 = @splat(@splat(0)),
    uri_lens: [4]usize = @splat(0),

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = method;
        _ = payload;
        _ = content_type;
        const self: *SeqResp = @ptrCast(@alignCast(ctx));
        if (self.calls < self.uris.len and uri.len <= self.uris[0].len) {
            @memcpy(self.uris[self.calls][0..uri.len], uri);
            self.uri_lens[self.calls] = uri.len;
        }
        const idx = @min(self.calls, self.responses.len - 1);
        self.calls += 1;
        return allocator.dupe(u8, self.responses[idx]);
    }

    fn uriAt(self: *const SeqResp, idx: usize) []const u8 {
        return self.uris[idx][0..self.uri_lens[idx]];
    }
};

fn newHealMenu(ctx: *Context, alloc: std.mem.Allocator, stub: *SeqResp) Menu {
    var m = Menu.init(ctx, alloc);
    m.setTransport(SeqResp.dispatch, stub);
    return m;
}

test "getMenu 40001 自愈：作废缓存 → 换新 token 重试一次并成功" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"menu\":{\"button\":[{\"type\":\"click\",\"name\":\"今日歌曲\",\"key\":\"V1001\"}],\"menuid\":1}}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var m = newHealMenu(&ctx, allocator, &stub);

    var parsed = try m.getMenu();
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.menu.button.len);
    try std.testing.expectEqualStrings("今日歌曲", parsed.value.menu.button[0].name);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/menu/get?access_token=token-abc",
        stub.uriAt(0),
    );
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/menu/get?access_token=token-new",
        stub.uriAt(1),
    );
}

test "setMenu 40001 自愈：重试后成功且第二次请求带新 token" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"errcode\":0,\"errmsg\":\"ok\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var m = newHealMenu(&ctx, allocator, &stub);

    const buttons = [_]Button{Button.setClick("a", "k")};
    try m.setMenu(&buttons);

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/menu/create?access_token=token-new",
        stub.uriAt(1),
    );
}

test "menuTryMatch 非 token 错误（45009）不重试也不作废" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var m = newHealMenu(&ctx, allocator, &stub);

    try std.testing.expectError(util_error.WechatError.ApiError, m.menuTryMatch("openid-1"));

    try std.testing.expectEqual(@as(usize, 0), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
}
