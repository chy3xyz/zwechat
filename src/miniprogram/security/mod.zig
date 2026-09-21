// SPDX-License-Identifier: Apache-2.0
//! miniprogram/security — 微信小程序内容安全审核 (`security.msgSecCheck` / `imgSecCheck`)

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

pub const Security = struct {
    ctx: *Context,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    pub fn init(ctx: *Context) Security {
        return .{ .ctx = ctx };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Security, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 检查一段文本是否含有违法违规内容 (`security.msgSecCheck` v2)。
    ///
    /// 返回微信原始响应体，调用方负责 `allocator.free`；
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次，
    /// 其他非 0 errcode 直接返回 `WechatError.ApiError`。
    pub fn msgSecCheck(
        self: Security,
        allocator: std.mem.Allocator,
        openid: []const u8,
        content: []const u8,
        scene: u8, // 1: 资料，2: 评论，3: 论坛，4: 社交日志
    ) ![]u8 {
        const body = try encodeMsgSecCheckBody(allocator, openid, content, scene);
        defer allocator.free(body);

        const Sender = struct {
            security: Security,
            body: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const url = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/wxa/msg_sec_check?access_token={s}",
                    .{token},
                );
                defer a.free(url);
                return c.security.postJSON(a, url, c.body);
            }
        };

        return util_retry.callApi(self.ctx, allocator, "MsgSecCheck", Sender{
            .security = self,
            .body = body,
        });
    }

    /// 异步校验图片 / 音频是否含有违法违规内容（`media_check_async` v2，
    /// 对照 Go `MediaCheckAsync`）。
    ///
    /// `media_url` 为待检测的图片 / 音频地址；`media_type` 1:音频 2:图片；
    /// `openid` 为用户的 openid（用户需在近两小时访问过小程序）；
    /// `scene` 场景枚举值（1 资料；2 评论；3 论坛；4 社交日志）。
    ///
    /// 返回微信分配的 trace_id，调用方负责 `allocator.free`；
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次。
    pub fn mediaCheckAsync(
        self: Security,
        allocator: std.mem.Allocator,
        media_url: []const u8,
        media_type: u8,
        openid: []const u8,
        scene: u8,
    ) ![]u8 {
        const body = try encodeMediaCheckAsyncBody(allocator, media_url, media_type, openid, scene);
        defer allocator.free(body);

        const Sender = struct {
            security: Security,
            body: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const url = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/wxa/media_check_async?access_token={s}",
                    .{token},
                );
                defer a.free(url);
                return c.security.postJSON(a, url, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, allocator, "MediaCheckAsync", Sender{
            .security = self,
            .body = body,
        });
        defer allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            trace_id: []const u8 = "",
        }, allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) {
            return util_error.WechatError.ApiError;
        }
        return allocator.dupe(u8, parsed.value.trace_id);
    }

    fn postJSON(self: Security, allocator: std.mem.Allocator, uri: []const u8, payload: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, payload);
        }
        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        return client.postJSON(uri, payload);
    }
};

/// 构造 `msg_sec_check` 的 JSON 请求体（字符串字段统一走
/// `std.json.Stringify` 转义，避免 openid/content 中的引号破坏 JSON）。
fn encodeMsgSecCheckBody(allocator: std.mem.Allocator, openid: []const u8, content: []const u8, scene: u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("openid");
    try s.write(openid);
    try s.objectField("scene");
    try s.write(scene);
    try s.objectField("version");
    try s.write(@as(u8, 2));
    try s.objectField("content");
    try s.write(content);
    try s.endObject();
    return out.toOwnedSlice();
}

/// 构造 `media_check_async` 的 JSON 请求体（v2 固定带 `version: 2`，
/// 字符串字段统一走 `std.json.Stringify` 转义）。
fn encodeMediaCheckAsyncBody(
    allocator: std.mem.Allocator,
    media_url: []const u8,
    media_type: u8,
    openid: []const u8,
    scene: u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("media_url");
    try s.write(media_url);
    try s.objectField("media_type");
    try s.write(media_type);
    try s.objectField("openid");
    try s.write(openid);
    try s.objectField("scene");
    try s.write(scene);
    try s.objectField("version");
    try s.write(@as(u8, 2));
    try s.endObject();
    return out.toOwnedSlice();
}

test "Security.init 构造实例" {
    var ctx: Context = .{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const sec = Security.init(&ctx);
    try std.testing.expectEqual(&ctx, sec.ctx);
}

test "encodeMsgSecCheckBody 特殊字符转义为合法 JSON" {
    const allocator = std.testing.allocator;
    const body = try encodeMsgSecCheckBody(allocator, "o\"pen\\id", "内容\n\"quoted\"", 2);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(struct {
        openid: []const u8,
        scene: u8,
        version: u8,
        content: []const u8,
    }, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("o\"pen\\id", parsed.value.openid);
    try std.testing.expectEqual(@as(u8, 2), parsed.value.scene);
    try std.testing.expectEqual(@as(u8, 2), parsed.value.version);
    try std.testing.expectEqualStrings("内容\n\"quoted\"", parsed.value.content);
}

// —— mock 测试 ——

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 捕获请求 payload 并返回预设响应的 transport，用于请求体断言。
const Capture = struct {
    response: []const u8,
    payload: []u8 = &.{},

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = content_type;
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (self.payload.len > 0) allocator.free(self.payload);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }
};

test "msgSecCheck body 为合法 JSON 且成功返回响应" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx: Context = .{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var sec = Security.init(&ctx);
    sec.setTransport(Capture.dispatch, &cap);

    const resp = try sec.msgSecCheck(allocator, "oABC", "hello \"world\" \\ 检查", 2);
    defer allocator.free(resp);
    try std.testing.expectEqualStrings("{\"errcode\":0,\"errmsg\":\"ok\"}", resp);

    var parsed = try std.json.parseFromSlice(struct {
        openid: []const u8,
        scene: u8,
        version: u8,
        content: []const u8,
    }, allocator, cap.payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("oABC", parsed.value.openid);
    try std.testing.expectEqualStrings("hello \"world\" \\ 检查", parsed.value.content);
}

test "msgSecCheck errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":87014,\"errmsg\":\"risky content\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx: Context = .{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var sec = Security.init(&ctx);
    sec.setTransport(Capture.dispatch, &cap);

    const result = sec.msgSecCheck(allocator, "oABC", "违规内容", 3);
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "mediaCheckAsync body 为合法 JSON 且返回 trace_id" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"trace_id\":\"trace_abc_123\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx: Context = .{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var sec = Security.init(&ctx);
    sec.setTransport(Capture.dispatch, &cap);

    const trace_id = try sec.mediaCheckAsync(allocator, "https://img.example/a\"b.png", 2, "oABC", 3);
    defer allocator.free(trace_id);
    try std.testing.expectEqualStrings("trace_abc_123", trace_id);

    // 断言请求体：URL 中的引号被正确转义，version 固定为 2。
    var parsed = try std.json.parseFromSlice(struct {
        media_url: []const u8,
        media_type: u8,
        openid: []const u8,
        scene: u8,
        version: u8,
    }, allocator, cap.payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://img.example/a\"b.png", parsed.value.media_url);
    try std.testing.expectEqual(@as(u8, 2), parsed.value.media_type);
    try std.testing.expectEqualStrings("oABC", parsed.value.openid);
    try std.testing.expectEqual(@as(u8, 3), parsed.value.scene);
    try std.testing.expectEqual(@as(u8, 2), parsed.value.version);
}

test "mediaCheckAsync errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":87014,\"errmsg\":\"risky media\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx: Context = .{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var sec = Security.init(&ctx);
    sec.setTransport(Capture.dispatch, &cap);

    const result = sec.mediaCheckAsync(allocator, "https://img.example/x.png", 2, "oABC", 2);
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "msgSecCheck token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/msg_sec_check?access_token=token-abc", .{
        .body = "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/wxa/msg_sec_check?access_token=token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{},
        .access_token_handle = stub.asHandle(),
    };
    var sec = Security.init(&ctx);
    sec.setTransport(util_http.MockTransport.dispatch, &mt);

    const resp = try sec.msgSecCheck(allocator, "oABC", "hello", 2);
    defer allocator.free(resp);
    try std.testing.expectEqualStrings("{\"errcode\":0,\"errmsg\":\"ok\"}", resp);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
