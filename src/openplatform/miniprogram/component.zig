// SPDX-License-Identifier: Apache-2.0
//! openplatform/miniprogram/component — 快速注册小程序
//!
//! 对应 `_ref/wechat/openplatform/miniprogram/component/component.go`：
//! 第三方平台代法人快速注册小程序（FastRegisterWeapp），
//! 以及查询注册任务状态（action=search）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const access_token = @import("../context/access_token.zig");

pub const Error = access_token.Error || error{WriteFailed};

/// 快速注册小程序接口 URL（`{s}` 为 component_access_token）。
const fastRegisterWeappURL = "https://api.weixin.qq.com/cgi-bin/component/fastregisterweapp?action={s}&component_access_token={s}";

/// 快速注册小程序参数（Go `RegisterMiniProgramParam`，字段与微信接口逐字一致）。
pub const RegisterMiniProgramParam = struct {
    /// 企业名。
    name: []const u8,
    /// 企业代码。
    code: []const u8,
    /// 企业代码类型：1 统一社会信用代码（18 位）2 组织机构代码（9 位）3 营业执照注册号（15 位）。
    code_type: []const u8,
    /// 法人微信号。
    legal_persona_wechat: []const u8,
    /// 法人姓名（绑定银行卡）。
    legal_persona_name: []const u8,
    /// 第三方联系电话（方便法人与第三方联系）。
    component_phone: []const u8,
};

/// 查询注册任务状态参数（Go `GetRegistrationStatusParam`）。
pub const RegistrationStatusParam = struct {
    /// 企业名。
    name: []const u8,
    /// 法人微信号。
    legal_persona_wechat: []const u8,
    /// 法人姓名（绑定银行卡）。
    legal_persona_name: []const u8,
};

/// fastregisterweapp 的原始响应体（只有 errcode/errmsg 有效载荷）。
const CommonResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

/// 快速注册小程序业务入口（Go `component.Component`）。
pub const Component = struct {
    ctx: *Context,

    const Self = @This();

    /// 构造入口（与 Go 端 `component.NewComponent(opContext)` 对齐）。
    pub fn init(ctx: *Context) Self {
        return .{ .ctx = ctx };
    }

    /// 统一的 POST JSON 出口（与 openplatform/context 惯例一致）。
    fn postJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        uri: []const u8,
        payload: []const u8,
    ) Error![]u8 {
        const ctx = self.ctx;
        if (ctx.transport) |t| {
            const tctx = ctx.transport_ctx orelse
                @panic("Context.transport 已设置但 transport_ctx 为空：请同时传入两者");
            var client = util_http.HttpClient.init(allocator);
            defer client.deinit();
            client.setTransport(t, tctx);
            return client.postJSON(uri, payload) catch return util_error.WechatError.NetworkError;
        }
        const client = util_http.getDefaultClient(allocator);
        return client.postJSON(uri, payload) catch return util_error.WechatError.NetworkError;
    }

    /// 取 component_access_token（仅读缓存，与 Go `GetComponentAccessToken` 语义一致）。
    fn requireComponentToken(self: *Self, allocator: std.mem.Allocator) Error![]u8 {
        return access_token.getCachedComponentAccessToken(self.ctx, allocator);
    }

    /// 快速创建小程序（Go `RegisterMiniProgram`，`action=create`）。
    ///
    /// URL：`POST /cgi-bin/component/fastregisterweapp?action=create&component_access_token={s}`。
    /// 响应 `errcode != 0` 抛 `WechatError.ApiError`。
    pub fn registerMiniProgram(
        self: *Self,
        allocator: std.mem.Allocator,
        param: RegisterMiniProgramParam,
    ) Error!void {
        const component_token = try self.requireComponentToken(allocator);
        defer allocator.free(component_token);

        const uri = try std.fmt.allocPrint(allocator, fastRegisterWeappURL, .{ "create", component_token });
        defer allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("name");
        try s.write(param.name);
        try s.objectField("code");
        try s.write(param.code);
        try s.objectField("code_type");
        try s.write(param.code_type);
        try s.objectField("legal_persona_wechat");
        try s.write(param.legal_persona_wechat);
        try s.objectField("legal_persona_name");
        try s.write(param.legal_persona_name);
        try s.objectField("component_phone");
        try s.write(param.component_phone);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer allocator.free(body);

        const resp = try self.postJSON(allocator, uri, body);
        defer allocator.free(resp);

        var parsed = std.json.parseFromSlice(CommonResponse, allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    }

    /// 查询小程序注册任务状态（Go `GetRegistrationStatus`，`action=search`）。
    ///
    /// URL：`POST /cgi-bin/component/fastregisterweapp?action=search&component_access_token={s}`。
    /// 响应 `errcode != 0` 抛 `WechatError.ApiError`。
    pub fn getRegistrationStatus(
        self: *Self,
        allocator: std.mem.Allocator,
        param: RegistrationStatusParam,
    ) Error!void {
        const component_token = try self.requireComponentToken(allocator);
        defer allocator.free(component_token);

        const uri = try std.fmt.allocPrint(allocator, fastRegisterWeappURL, .{ "search", component_token });
        defer allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("name");
        try s.write(param.name);
        try s.objectField("legal_persona_wechat");
        try s.write(param.legal_persona_wechat);
        try s.objectField("legal_persona_name");
        try s.write(param.legal_persona_name);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer allocator.free(body);

        const resp = try self.postJSON(allocator, uri, body);
        defer allocator.free(resp);

        var parsed = std.json.parseFromSlice(CommonResponse, allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────────────────────────────────────

/// 记录 method / uri / payload 的测试 transport。
const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uris: std.ArrayList([]u8) = .empty,
    payloads: std.ArrayList([]u8) = .empty,
    methods: std.ArrayList(std.http.Method) = .empty,

    fn init(allocator: std.mem.Allocator, response: []const u8) RecordingTransport {
        return .{ .allocator = allocator, .response = response };
    }

    fn deinit(self: *RecordingTransport) void {
        for (self.uris.items) |u| self.allocator.free(u);
        for (self.payloads.items) |p| self.allocator.free(p);
        self.uris.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        self.methods.deinit(self.allocator);
    }

    fn dispatch(
        ctx_ptr: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = content_type;
        const self: *RecordingTransport = @ptrCast(@alignCast(ctx_ptr));
        try self.uris.append(self.allocator, try self.allocator.dupe(u8, uri));
        try self.payloads.append(self.allocator, try self.allocator.dupe(u8, payload));
        try self.methods.append(self.allocator, method);
        return allocator.dupe(u8, self.response);
    }
};

/// 构造带内存 cache + 预置 component token 的测试 Context。
fn testCtx(allocator: std.mem.Allocator, memory: *@import("../../cache/memory.zig").Memory) !Context {
    const ckey = try std.fmt.allocPrint(allocator, "openplatform_component_access_token_{s}", .{"wx-op"});
    defer allocator.free(ckey);
    try memory.asCache().set(ckey, "comp-tok", 7000);
    return .{ .config = .{ .app_id = "wx-op", .app_secret = "sec", .cache = memory.asCache() } };
}

test "registerMiniProgram mock：POST action=create 正确 URL/body" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var comp = Component.init(&ctx);
    try comp.registerMiniProgram(allocator, .{
        .name = "企业\"名",
        .code = "91330100MA27X0XX0Q",
        .code_type = "1",
        .legal_persona_wechat = "legal_wx",
        .legal_persona_name = "张三",
        .component_phone = "13800000000",
    });

    try std.testing.expectEqual(@as(usize, 1), rec.uris.items.len);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/component/fastregisterweapp?action=create&component_access_token=comp-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqual(std.http.Method.POST, rec.methods.items[0]);
    // 企业名中的引号必须被 JSON 转义（裸插值会产出非法 JSON）。
    try std.testing.expectEqualStrings(
        "{\"name\":\"企业\\\"名\",\"code\":\"91330100MA27X0XX0Q\",\"code_type\":\"1\",\"legal_persona_wechat\":\"legal_wx\",\"legal_persona_name\":\"张三\",\"component_phone\":\"13800000000\"}",
        rec.payloads.items[0],
    );
}

test "getRegistrationStatus mock：POST action=search 正确 URL/body" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var comp = Component.init(&ctx);
    try comp.getRegistrationStatus(allocator, .{
        .name = "某企业",
        .legal_persona_wechat = "legal_wx",
        .legal_persona_name = "张三",
    });

    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/component/fastregisterweapp?action=search&component_access_token=comp-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqualStrings(
        "{\"name\":\"某企业\",\"legal_persona_wechat\":\"legal_wx\",\"legal_persona_name\":\"张三\"}",
        rec.payloads.items[0],
    );
}

test "registerMiniProgram errcode 非 0 抛 ApiError" {
    const allocator = std.testing.allocator;

    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":89249,\"errmsg\":\"该企​业已注册\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var comp = Component.init(&ctx);
    const result = comp.registerMiniProgram(allocator, .{
        .name = "某企业",
        .code = "code",
        .code_type = "1",
        .legal_persona_wechat = "wx",
        .legal_persona_name = "张三",
        .component_phone = "138",
    });
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "registerMiniProgram component token 缓存未命中返回 VerifyTicketRequired" {
    const allocator = std.testing.allocator;
    const memory = try @import("../../cache/memory.zig").Memory.create(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }
    var ctx: Context = .{ .config = .{ .app_id = "wx-op", .cache = memory.asCache() } };
    var comp = Component.init(&ctx);
    const result = comp.registerMiniProgram(allocator, .{
        .name = "n",
        .code = "c",
        .code_type = "1",
        .legal_persona_wechat = "w",
        .legal_persona_name = "p",
        .component_phone = "138",
    });
    try std.testing.expectError(error.VerifyTicketRequired, result);
}
