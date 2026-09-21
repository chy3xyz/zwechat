// SPDX-License-Identifier: Apache-2.0
//! miniprogram/qrcode — 小程序码（无数量限制）
//!
//! 对应 `_ref/wechat/miniprogram/qrcode/qrcode.go`：
//! `wxa/getwxacodeunlimit` 获取小程序码（永久有效，数量暂无限制）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 小程序码模块。
pub const QRCode = struct {
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

    /// 获取小程序码（无数量限制）。
    ///
    /// - `scene`：最大 32 个可见字符，必填。
    /// - `page`：默认首页；可传 `null`。
    /// - `width`：二维码宽度，默认 430。
    ///
    /// 返回图片二进制切片，调用方负责 `allocator.free`。
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次；其余非 0
    /// errcode（微信在二进制端点上以 JSON 错误体回包）抛 `WechatError.ApiError`。
    pub fn getUnlimited(
        self: *Self,
        scene: []const u8,
        page: ?[]const u8,
        width: u32,
    ) ![]u8 {
        const body_json = try encodeGetUnlimitedBody(self.allocator, scene, page, width);
        defer self.allocator.free(body_json);

        const Sender = struct {
            qr: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/getwxacodeunlimit?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                if (c.qr.transport) |t| {
                    var client = util_http.HttpClient.init(c.qr.allocator);
                    defer client.deinit();
                    client.setTransport(t, c.qr.transport_ctx);
                    return client.postJSON(uri, c.body);
                }
                const client = util_http.getDefaultClient(c.qr.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        // 二进制端点失败时微信返回 JSON 错误体；`callApi` 的 errcode 检查与
        // `handleFileResponse` 等价（非 JSON 响应视为成功，原样返回图片字节）。
        return util_retry.callApi(self.ctx, self.allocator, "GetUnlimited", Sender{
            .qr = self,
            .body = body_json,
        });
    }
};

/// 构造 `getwxacodeunlimit` 的 JSON 请求体（字符串字段统一走
/// `std.json.Stringify` 转义；`page` 为 `null` 时省略该字段）。
fn encodeGetUnlimitedBody(allocator: std.mem.Allocator, scene: []const u8, page: ?[]const u8, width: u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("scene");
    try s.write(scene);
    if (page) |p| {
        try s.objectField("page");
        try s.write(p);
    }
    try s.objectField("width");
    try s.write(width);
    try s.endObject();
    return out.toOwnedSlice();
}

test "QRCode.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-qr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const q = QRCode.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-qr", q.ctx.config.app_id);
}

test "encodeGetUnlimitedBody 有 page 时为合法 JSON" {
    const allocator = std.testing.allocator;
    const body = try encodeGetUnlimitedBody(allocator, "a=1&b=\"2\"", "pages/index?x=1", 430);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(struct {
        scene: []const u8,
        page: []const u8,
        width: u32,
    }, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a=1&b=\"2\"", parsed.value.scene);
    try std.testing.expectEqualStrings("pages/index?x=1", parsed.value.page);
    try std.testing.expectEqual(@as(u32, 430), parsed.value.width);
}

test "encodeGetUnlimitedBody 无 page 时省略该字段" {
    const allocator = std.testing.allocator;
    const body = try encodeGetUnlimitedBody(allocator, "scene-1", null, 200);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(struct {
        scene: []const u8,
        width: u32,
    }, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("scene-1", parsed.value.scene);
    try std.testing.expectEqual(@as(u32, 200), parsed.value.width);
    try std.testing.expect(std.mem.indexOf(u8, body, "page") == null);
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

test "getUnlimited 请求体为合法 JSON 并返回图片字节" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "\xff\xd8\xff\xe0" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx: Context = .{
        .config = .{ .app_id = "wx-qr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var q = QRCode.init(&ctx, allocator);
    q.setTransport(Capture.dispatch, &cap);

    const img = try q.getUnlimited("s\"c\\ene", "pages/index", 430);
    defer allocator.free(img);
    try std.testing.expectEqualSlices(u8, "\xff\xd8\xff\xe0", img);

    // body 必须是合法 JSON 且字符串字段已转义。
    var parsed = try std.json.parseFromSlice(struct {
        scene: []const u8,
        page: []const u8,
        width: u32,
    }, allocator, cap.payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s\"c\\ene", parsed.value.scene);
    try std.testing.expectEqualStrings("pages/index", parsed.value.page);
    try std.testing.expectEqual(@as(u32, 430), parsed.value.width);
}

test "getUnlimited 返回 JSON 错误体时抛 ApiError" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx: Context = .{
        .config = .{ .app_id = "wx-qr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var q = QRCode.init(&ctx, allocator);
    q.setTransport(Capture.dispatch, &cap);

    const result = q.getUnlimited("scene-1", "pages/index", 430);
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "getUnlimited token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/wxa/getwxacodeunlimit?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    // 第二次成功：二进制端点上返回图片字节（非 JSON → 视为成功）。
    try mt.addRoute(base ++ "token-new", .{ .body = "\xff\xd8\xff\xe0" });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-qr" },
        .access_token_handle = stub.asHandle(),
    };
    var q = QRCode.init(&ctx, allocator);
    q.setTransport(util_http.MockTransport.dispatch, &mt);

    const img = try q.getUnlimited("scene-1", "pages/index", 430);
    defer allocator.free(img);
    try std.testing.expectEqualSlices(u8, "\xff\xd8\xff\xe0", img);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
