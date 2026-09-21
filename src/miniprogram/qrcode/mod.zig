// SPDX-License-Identifier: Apache-2.0
//! miniprogram/qrcode — 小程序码（无数量限制）
//!
//! 对应 `_ref/wechat/miniprogram/qrcode/qrcode.go`：
//! `wxa/getwxacodeunlimit` 获取小程序码（永久有效，数量暂无限制）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

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
    pub fn getUnlimited(
        self: *Self,
        scene: []const u8,
        page: ?[]const u8,
        width: u32,
    ) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/getwxacodeunlimit?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body_json = try encodeGetUnlimitedBody(self.allocator, scene, page, width);
        defer self.allocator.free(body_json);

        const resp = blk: {
            if (self.transport) |t| {
                var client = util_http.HttpClient.init(self.allocator);
                defer client.deinit();
                client.setTransport(t, self.transport_ctx);
                break :blk try client.postJSON(uri, body_json);
            }
            const client = util_http.getDefaultClient(self.allocator);
            break :blk try client.postJSON(uri, body_json);
        };

        // 二进制端点失败时微信返回 JSON 错误体；可识别为错误响应时抛 ApiError，
        // 正常图片字节原样返回（等价 Go util.HandleFileResponse）。
        const checked = util_error.handleFileResponse(resp, "GetUnlimited") catch |err| {
            self.allocator.free(resp);
            return err;
        };
        return @constCast(checked);
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
