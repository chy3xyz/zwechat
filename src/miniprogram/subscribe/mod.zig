// SPDX-License-Identifier: Apache-2.0
//! miniprogram/subscribe — 订阅消息
//!
//! 对应 `_ref/wechat/miniprogram/subscribe/subscribe.go`：发送订阅消息、模板列表、
//! 类目、统一服务消息等。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const credential = @import("../../credential/mod.zig");
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

/// 统一服务消息数据项（对照 Go `DataItem`）。
pub const UniformDataItem = struct {
    value: []const u8,
    color: []const u8 = "",
};

/// 统一服务消息 data 键值对（Go 侧为 map，Zig 用有序 entry 切片）。
pub const UniformDataEntry = struct {
    key: []const u8,
    item: UniformDataItem,
};

/// 小程序模板消息部分（对照 Go `UniformMessage.WeappTemplateMsg`）。
pub const WeappTemplateMsg = struct {
    template_id: []const u8 = "",
    page: []const u8 = "",
    form_id: []const u8 = "",
    data: []const UniformDataEntry = &.{},
    emphasis_keyword: []const u8 = "",
};

/// 公众号模板消息内嵌小程序跳转（对照 Go `UniformMessage.MpTemplateMsg.Miniprogram`）。
pub const MpMiniprogram = struct {
    appid: []const u8 = "",
    pagepath: []const u8 = "",
};

/// 公众号模板消息部分（对照 Go `UniformMessage.MpTemplateMsg`）。
pub const MpTemplateMsg = struct {
    appid: []const u8 = "",
    template_id: []const u8 = "",
    url: []const u8 = "",
    miniprogram: MpMiniprogram = .{},
    data: []const UniformDataEntry = &.{},
};

/// 统一服务消息（对照 Go `UniformMessage`，
/// `POST /cgi-bin/message/wxopen/template/uniform_send`）。
pub const UniformMessage = struct {
    touser: []const u8,
    weapp_template_msg: WeappTemplateMsg = .{},
    mp_template_msg: MpTemplateMsg = .{},
};

/// 订阅消息模块。
pub const Subscribe = struct {
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

        const resp = try self.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            msgid: i64 = 0,
        }, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value.msgid;
    }

    /// 发送统一服务消息（`uniform_send`，对照 Go `UniformSend`）。
    ///
    /// 小程序模板消息与公众号模板消息可同时下发，按 `UniformMessage`
    /// 各字段组装 JSON；errcode 非 0 返回 `WechatError.ApiError`。
    pub fn uniformSend(self: *Self, msg: UniformMessage) !void {
        const body = try jsonStringifyUniformMessage(self.allocator, msg);
        defer self.allocator.free(body);

        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/message/wxopen/template/uniform_send?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const resp = try self.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "UniformSend")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
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

        const resp = try self.httpGet(uri);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            data: []const Category = &.{},
        }, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
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

        const resp = try self.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, api_name)) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    fn getParsed(self: *Self, url: []const u8, comptime T: type) !std.json.Parsed(T) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ url, access_token });
        defer self.allocator.free(uri);

        const resp = try self.httpGet(uri);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(T, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// POST JSON；注入 transport 时使用之，否则走线程默认 client。
    fn postJSON(self: *Self, uri: []const u8, body: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, body);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body);
    }

    /// GET；注入 transport 时使用之，否则走线程默认 client。
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
};

/// 序列化统一服务消息 data：`{"key":{"value":"...","color":"..."}}`。
/// 字符串字段统一走 `std.json.Stringify` 转义。
fn writeUniformData(s: *std.json.Stringify, data: []const UniformDataEntry) !void {
    try s.beginObject();
    for (data) |entry| {
        try s.objectField(entry.key);
        try s.beginObject();
        try s.objectField("value");
        try s.write(entry.item.value);
        if (entry.item.color.len > 0) {
            try s.objectField("color");
            try s.write(entry.item.color);
        }
        try s.endObject();
    }
    try s.endObject();
}

/// 构造 `uniform_send` 的 JSON 请求体（字段名与 Go `UniformMessage` 一致）。
fn jsonStringifyUniformMessage(allocator: std.mem.Allocator, msg: UniformMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("touser");
    try s.write(msg.touser);

    try s.objectField("weapp_template_msg");
    try s.beginObject();
    try s.objectField("template_id");
    try s.write(msg.weapp_template_msg.template_id);
    try s.objectField("page");
    try s.write(msg.weapp_template_msg.page);
    try s.objectField("form_id");
    try s.write(msg.weapp_template_msg.form_id);
    try s.objectField("data");
    try writeUniformData(&s, msg.weapp_template_msg.data);
    try s.objectField("emphasis_keyword");
    try s.write(msg.weapp_template_msg.emphasis_keyword);
    try s.endObject();

    try s.objectField("mp_template_msg");
    try s.beginObject();
    try s.objectField("appid");
    try s.write(msg.mp_template_msg.appid);
    try s.objectField("template_id");
    try s.write(msg.mp_template_msg.template_id);
    try s.objectField("url");
    try s.write(msg.mp_template_msg.url);
    try s.objectField("miniprogram");
    try s.beginObject();
    try s.objectField("appid");
    try s.write(msg.mp_template_msg.miniprogram.appid);
    try s.objectField("pagepath");
    try s.write(msg.mp_template_msg.miniprogram.pagepath);
    try s.endObject();
    try s.objectField("data");
    try writeUniformData(&s, msg.mp_template_msg.data);
    try s.endObject();

    try s.endObject();
    return out.toOwnedSlice();
}

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

// ── 可注入 transport 测试 ────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 记录 method / uri / payload 并返回预设响应的 transport。
const CapturingTransport = struct {
    method: std.http.Method = .GET,
    uri: []const u8 = "",
    payload: []const u8 = "",
    response: []const u8 = "",

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = content_type;
        const self: *CapturingTransport = @ptrCast(@alignCast(ctx));
        self.method = method;
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }

    fn deinit(self: *CapturingTransport, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.payload);
    }
};

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "listTemplates GET 模板列表并解析（回归：泛型 T 参数错位）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"data\":[{\"pri_tmpl_id\":\"tmpl-1\",\"title\":\"下单提醒\",\"content\":\"thing1\",\"example\":\"例\",\"type\":2}]}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var s = Subscribe.init(&ctx, allocator);
    s.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try s.listTemplates();
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxaapi/newtmpl/gettemplate?access_token=token-abc", tt.uri);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.data.len);
    try std.testing.expectEqualStrings("tmpl-1", parsed.value.data[0].pri_tmpl_id);
    try std.testing.expectEqualStrings("下单提醒", parsed.value.data[0].title);
}

test "sendGetMsgId POST 订阅消息并解析 msgid" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"msgid\":12345}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var s = Subscribe.init(&ctx, allocator);
    s.setTransport(CapturingTransport.dispatch, &tt);

    const msgid = try s.sendGetMsgId(.{
        .touser = "openid-1",
        .template_id = "tmpl-1",
        .data = &.{.{ .key = "thing1", .value = "hello" }},
    });
    try std.testing.expectEqual(@as(i64, 12345), msgid);

    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/message/subscribe/send?access_token=token-abc", tt.uri);
    try std.testing.expect(std.mem.indexOf(u8, tt.payload, "\"touser\":\"openid-1\"") != null);
}

test "uniformSend POST 统一服务消息且 body 字段与 Go 对齐" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var s = Subscribe.init(&ctx, allocator);
    s.setTransport(CapturingTransport.dispatch, &tt);

    try s.uniformSend(.{
        .touser = "openid-1",
        .weapp_template_msg = .{
            .template_id = "tmpl-weapp",
            .page = "pages/index",
            .form_id = "form-1",
            .data = &.{
                .{ .key = "keyword1", .item = .{ .value = "值\"1", .color = "#173177" } },
            },
            .emphasis_keyword = "keyword1.DATA",
        },
        .mp_template_msg = .{
            .appid = "wx-mp",
            .template_id = "tmpl-mp",
            .url = "https://example.com",
            .miniprogram = .{ .appid = "wx-mp", .pagepath = "pages/index" },
            .data = &.{.{ .key = "first", .item = .{ .value = "您好" } }},
        },
    });

    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/message/wxopen/template/uniform_send?access_token=token-abc", tt.uri);

    // body 必须是合法 JSON，且关键字段与 Go UniformMessage 的 json tag 一致。
    var parsed = try std.json.parseFromSlice(struct {
        touser: []const u8,
        weapp_template_msg: struct {
            template_id: []const u8,
            page: []const u8,
            form_id: []const u8,
            data: std.json.Value,
            emphasis_keyword: []const u8,
        },
        mp_template_msg: struct {
            appid: []const u8,
            template_id: []const u8,
            url: []const u8,
            miniprogram: struct {
                appid: []const u8,
                pagepath: []const u8,
            },
            data: std.json.Value,
        },
    }, allocator, tt.payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("openid-1", parsed.value.touser);
    try std.testing.expectEqualStrings("tmpl-weapp", parsed.value.weapp_template_msg.template_id);
    try std.testing.expectEqualStrings("form-1", parsed.value.weapp_template_msg.form_id);
    try std.testing.expectEqualStrings("keyword1.DATA", parsed.value.weapp_template_msg.emphasis_keyword);
    try std.testing.expectEqualStrings("tmpl-mp", parsed.value.mp_template_msg.template_id);
    try std.testing.expectEqualStrings("pages/index", parsed.value.mp_template_msg.miniprogram.pagepath);
    // 嵌套 data 中的 value 含引号时必须已被转义（Stringify 保证）。
    try std.testing.expect(std.mem.indexOf(u8, tt.payload, "值\\\"1") != null);
}

test "uniformSend errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"errcode\":40037,\"errmsg\":\"invalid template_id\"}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var s = Subscribe.init(&ctx, allocator);
    s.setTransport(CapturingTransport.dispatch, &tt);

    const result = s.uniformSend(.{ .touser = "openid-1" });
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}
