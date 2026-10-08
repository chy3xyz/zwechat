// SPDX-License-Identifier: Apache-2.0
//! openplatform/account — 开放平台账号管理
//!
//! 对应 `_ref/wechat/openplatform/account/account.go`：在 Go SDK 中是 TODO
//! 骨架。本 Zig 版补齐四条与上游微信开放平台后端对齐的真实接口：
//! - `POST /cgi-bin/open/create` — 创建开放平台账号并绑定公众号 / 小程序；
//! - `POST /cgi-bin/open/get`   — 查询已绑定的开放平台账号；
//! - `POST /cgi-bin/open/bind`   — 将公众号 / 小程序绑定到开放平台账号；
//! - `POST /cgi-bin/open/unbind` — 解绑。
//!
//! 重要：这四个接口都以**被授权方**身份调用，query 参数必须是
//! `access_token={authorizer_access_token}`（`12_` 前缀，按
//! `authorizer_appid` 通过 `Context.getAuthrAccessToken` 获取）；
//! **不能**用 `component_access_token`（参数名也不是
//! `component_access_token`），否则线上必失败。

const std = @import("std");

const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_json = @import("../../util/json.zig");

/// 微信开放平台（第三方平台）账号管理。
///
/// 字段说明：
/// - `ctx` — 复用上层 `OpenPlatform.ctx`，避免重复持有 config。
/// - `allocator` — 所有响应 / URL 切片的分配器；调用方传入的 allocator 需长期存活。
pub const Account = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP；
    /// 与 `officialaccount/menu` 等模块的惯例一致，生产环境保持 `null`）。
    transport: ?util_http.HttpClient.Transport = null,
    /// `transport` 被调用时透传的不透明上下文。
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    /// 创建账号实例。调用方负责保证 `ctx` 与 `allocator` 在 `Account` 生命周期内有效。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// `CreateOpenAccount` — 创建开放平台账号并绑定公众号 / 小程序。
    ///
    /// 接口：`POST https://api.weixin.qq.com/cgi-bin/open/create?access_token={s}`
    /// 请求体：`{"appid":"<appID>"}`
    /// 成功响应：`{"errcode":0,"errmsg":"ok","open_appid":"<open_appid>"}`
    ///
    /// `app_id` — 待绑定的公众号 / 小程序 AppID。
    /// `authorizer_access_token` — 被授权方的 authorizer_access_token
    /// （经 `Context.getAuthrAccessToken(authorizer_appid)` 获取）。
    /// 返回：开放平台账号的 `open_appid`（由调用方负责 `allocator.free`）。
    pub fn createOpenAccount(
        self: *Self,
        app_id: []const u8,
        authorizer_access_token: []const u8,
    ) ![]u8 {
        const body_json = try util_json.stringFieldObject(self.allocator, "appid", app_id);
        defer self.allocator.free(body_json);

        const uri = try self.allocator.print(
            "{s}?access_token={s}",
            .{ createOpenAccountURL, authorizer_access_token },
        );
        defer self.allocator.free(uri);

        const body = try self.postJSON(uri, body_json);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(OpenAccountResponse, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.open_appid);
    }

    /// `GetOpenAccount` — 查询公众号 / 小程序所绑定的开放平台账号。
    ///
    /// 接口：`POST https://api.weixin.qq.com/cgi-bin/open/get?access_token={s}`
    /// 请求体：`{"appid":"<appID>"}`
    /// 成功响应：`{"errcode":0,"errmsg":"ok","open_appid":"<open_appid>"}`
    ///
    /// `app_id` — 待查询的公众号 / 小程序 AppID。
    /// `authorizer_access_token` — 被授权方的 authorizer_access_token。
    /// 返回：开放平台账号的 `open_appid`（由调用方负责 `allocator.free`）。
    pub fn getOpenAccount(
        self: *Self,
        app_id: []const u8,
        authorizer_access_token: []const u8,
    ) ![]u8 {
        const body_json = try util_json.stringFieldObject(self.allocator, "appid", app_id);
        defer self.allocator.free(body_json);

        const uri = try self.allocator.print(
            "{s}?access_token={s}",
            .{ getOpenAccountURL, authorizer_access_token },
        );
        defer self.allocator.free(uri);

        const body = try self.postJSON(uri, body_json);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(OpenAccountResponse, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.open_appid);
    }

    /// 将公众号 / 小程序绑定到开放平台账号。
    ///
    /// 接口：`POST https://api.weixin.qq.com/cgi-bin/open/bind?access_token={s}`
    /// 请求体：`{"appid":"<appID>","open_appid":"<open_appid>"}`
    ///
    /// `authorizer_access_token` — 被授权方的 authorizer_access_token
    /// （不能用 component_access_token）。
    pub fn bind(
        self: *Self,
        app_id: []const u8,
        open_app_id: []const u8,
        authorizer_access_token: []const u8,
    ) !void {
        const uri = try self.allocator.print(
            "https://api.weixin.qq.com/cgi-bin/open/bind?access_token={s}",
            .{authorizer_access_token},
        );
        defer self.allocator.free(uri);

        const body_json = try util_json.stringFieldsObject(self.allocator, &.{
            .{ .name = "appid", .value = app_id },
            .{ .name = "open_appid", .value = open_app_id },
        });
        defer self.allocator.free(body_json);

        const resp = try self.postJSON(uri, body_json);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CommonResponse, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    }

    /// 将公众号 / 小程序从开放平台账号解绑。
    ///
    /// 接口：`POST https://api.weixin.qq.com/cgi-bin/open/unbind?access_token={s}`
    /// 请求体 / token 语义同 `bind`。
    pub fn unbind(
        self: *Self,
        app_id: []const u8,
        open_app_id: []const u8,
        authorizer_access_token: []const u8,
    ) !void {
        const uri = try self.allocator.print(
            "https://api.weixin.qq.com/cgi-bin/open/unbind?access_token={s}",
            .{authorizer_access_token},
        );
        defer self.allocator.free(uri);

        const body_json = try util_json.stringFieldsObject(self.allocator, &.{
            .{ .name = "appid", .value = app_id },
            .{ .name = "open_appid", .value = open_app_id },
        });
        defer self.allocator.free(body_json);

        const resp = try self.postJSON(uri, body_json);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CommonResponse, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    }

    /// 统一的 POST JSON 出口：注入 transport 时走临时 client（测试），
    /// 否则走线程局部默认 client（生产）。
    fn postJSON(self: *Self, uri: []const u8, payload: []const u8) (util_error.WechatError || std.mem.Allocator.Error)![]u8 {
        if (self.transport) |t| {
            const tctx = self.transport_ctx orelse
                @panic("Account.transport 已设置但 transport_ctx 为空：请同时传入两者");
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, tctx);
            return client.postJSON(uri, payload) catch return util_error.WechatError.NetworkError;
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, payload) catch return util_error.WechatError.NetworkError;
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 常量与响应结构
// ──────────────────────────────────────────────────────────────────────────────

/// `POST /cgi-bin/open/create` 接口 URL（不含 query，调用时拼 `?access_token=`）。
pub const createOpenAccountURL = "https://api.weixin.qq.com/cgi-bin/open/create";

/// `POST /cgi-bin/open/get` 接口 URL（不含 query，调用时拼 `?access_token=`）。
pub const getOpenAccountURL = "https://api.weixin.qq.com/cgi-bin/open/get";

/// 开放平台账号管理接口的通用响应。
///
/// 所有字段都有默认值：成功时会有 `open_appid`，失败时仅 `errcode` / `errmsg` 非零。
const OpenAccountResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    open_appid: []const u8 = "",
};

/// 绑定 / 解绑等无业务返回的通用响应。
const CommonResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

// ──────────────────────────────────────────────────────────────────────────────
// 内联测试
// ──────────────────────────────────────────────────────────────────────────────

test "Account.init 持有 ctx 与 allocator" {
    // 断言只依赖 `ctx` 指针与 `Allocator.vtable` 的同一性——**不比较**
    // `Allocator.ptr`：无状态分配器（如 `std.heap.page_allocator`）下该字段是
    // `undefined`，比较属 UB，在 release 下会随机失败。
    var fba_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const allocator = fba.allocator();

    var ctx: Context = .{ .config = .{ .app_id = "wx-acc-test" } };
    const a = Account.init(&ctx, allocator);
    try std.testing.expect(a.ctx == &ctx);
    try std.testing.expectEqualStrings("wx-acc-test", a.ctx.config.app_id);
    try std.testing.expect(a.allocator.vtable == allocator.vtable);
}

test "OpenAccountResponse 默认值" {
    const r = OpenAccountResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
    try std.testing.expectEqualStrings("", r.open_appid);
}

test "createOpenAccountURL / getOpenAccountURL 指向正确主机" {
    try std.testing.expect(std.mem.find(u8, createOpenAccountURL, "api.weixin.qq.com") != null);
    try std.testing.expect(std.mem.find(u8, createOpenAccountURL, "/cgi-bin/open/create") != null);
    try std.testing.expect(std.mem.find(u8, getOpenAccountURL, "api.weixin.qq.com") != null);
    try std.testing.expect(std.mem.find(u8, getOpenAccountURL, "/cgi-bin/open/get") != null);
}

test "createOpenAccount 请求 URL 带 access_token= 参数并解析 open_appid" {
    const allocator = std.testing.allocator;

    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/open/create?access_token=12_authr_tok",
        .{ .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"open_appid\":\"wx-open-1\"}" },
    );

    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mock));

    const open_appid = try a.createOpenAccount("wx-target", "12_authr_tok");
    defer allocator.free(open_appid);
    try std.testing.expectEqualStrings("wx-open-1", open_appid);

    // 参数名必须是 access_token=，不是 component_access_token=。
    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);
    const uri = mock.history.items[0];
    try std.testing.expect(std.mem.find(u8, uri, "access_token=12_authr_tok") != null);
    try std.testing.expect(std.mem.find(u8, uri, "component_access_token=") == null);
}

test "getOpenAccount 请求 URL 带 access_token= 参数" {
    const allocator = std.testing.allocator;

    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/open/get?access_token=12_authr_tok",
        .{ .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"open_appid\":\"wx-open-1\"}" },
    );

    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mock));

    const open_appid = try a.getOpenAccount("wx-target", "12_authr_tok");
    defer allocator.free(open_appid);
    try std.testing.expectEqualStrings("wx-open-1", open_appid);

    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);
    const uri = mock.history.items[0];
    try std.testing.expect(std.mem.find(u8, uri, "access_token=12_authr_tok") != null);
    try std.testing.expect(std.mem.find(u8, uri, "component_access_token=") == null);
}

/// 记录请求体的测试 transport：`util_http.MockTransport` 只记录 URI、不记录
/// payload，无法断言**实际发出**的请求体（模式同 `openplatform/miniprogram/component.zig`）。
const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    payloads: std.ArrayList([]u8) = .empty,

    fn deinit(self: *RecordingTransport) void {
        for (self.payloads.items) |p| self.allocator.free(p);
        self.payloads.deinit(self.allocator);
    }

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = content_type;
        const self: *RecordingTransport = @ptrCast(@alignCast(ctx));
        try self.payloads.append(self.allocator, try self.allocator.dupe(u8, payload));
        return allocator.dupe(u8, self.response);
    }
};

test "createOpenAccount：app_id 含引号时请求体仍是合法 JSON 且值原样回传" {
    const allocator = std.testing.allocator;

    var rec = RecordingTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"open_appid\":\"wx-open-1\"}",
    };
    defer rec.deinit();

    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, allocator);
    a.setTransport(RecordingTransport.dispatch, @ptrCast(&rec));

    // app_id 来自调用方，故意含 `"`：裸 allocPrint 插值会拼出非法 JSON。
    const app_id = "wx\"trick";
    const open_appid = try a.createOpenAccount(app_id, "12_tok");
    defer allocator.free(open_appid);
    try std.testing.expectEqualStrings("wx-open-1", open_appid);

    try std.testing.expectEqual(@as(usize, 1), rec.payloads.items.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, rec.payloads.items[0], .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(app_id, obj.get("appid").?.string);
}

test "getOpenAccount：app_id 含引号时请求体仍是合法 JSON 且值原样回传" {
    const allocator = std.testing.allocator;

    var rec = RecordingTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"open_appid\":\"wx-open-2\"}",
    };
    defer rec.deinit();

    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, allocator);
    a.setTransport(RecordingTransport.dispatch, @ptrCast(&rec));

    const app_id = "wx\"trick";
    const open_appid = try a.getOpenAccount(app_id, "12_tok");
    defer allocator.free(open_appid);
    try std.testing.expectEqualStrings("wx-open-2", open_appid);

    try std.testing.expectEqual(@as(usize, 1), rec.payloads.items.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, rec.payloads.items[0], .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(app_id, obj.get("appid").?.string);
}

test "bind 请求 URL 带 access_token= 参数（authorizer token）" {
    const allocator = std.testing.allocator;

    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/open/bind?access_token=12_authr_tok",
        .{ .body = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    );

    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mock));

    try a.bind("wx-target", "wx-open-1", "12_authr_tok");

    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);
    const uri = mock.history.items[0];
    try std.testing.expect(std.mem.find(u8, uri, "access_token=12_authr_tok") != null);
    try std.testing.expect(std.mem.find(u8, uri, "component_access_token=") == null);
}

test "unbind 请求 URL 带 access_token= 参数（authorizer token）" {
    const allocator = std.testing.allocator;

    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/open/unbind?access_token=12_authr_tok",
        .{ .body = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    );

    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mock));

    try a.unbind("wx-target", "wx-open-1", "12_authr_tok");

    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);
    const uri = mock.history.items[0];
    try std.testing.expect(std.mem.find(u8, uri, "access_token=12_authr_tok") != null);
    try std.testing.expect(std.mem.find(u8, uri, "component_access_token=") == null);
}

test "bind / unbind errcode 非零返回 ApiError" {
    const allocator = std.testing.allocator;

    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/open/bind?access_token=12_t",
        .{ .body = "{\"errcode\":40013,\"errmsg\":\"invalid appid\"}" },
    );
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/open/unbind?access_token=12_t",
        .{ .body = "{\"errcode\":40013,\"errmsg\":\"invalid appid\"}" },
    );

    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mock));

    try std.testing.expectError(util_error.WechatError.ApiError, a.bind("wx-t", "wx-o", "12_t"));
    try std.testing.expectError(util_error.WechatError.ApiError, a.unbind("wx-t", "wx-o", "12_t"));
}
