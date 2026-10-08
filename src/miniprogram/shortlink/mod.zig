// SPDX-License-Identifier: Apache-2.0
//! miniprogram/shortlink — 小程序 Short Link 短链接
//!
//! 对应 `_ref/wechat/miniprogram/shortlink/shortlink.go`：
//! `wxa/genwxashortlink` 生成短期/永久 Short Link。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 小程序 Short Link 模块。
pub const ShortLink = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 生成永久 Short Link（返回的 link 由调用方负责 `allocator.free`）。
    pub fn generateShortLinkPermanent(self: *Self, page_url: []const u8, page_title: []const u8) ![]u8 {
        return self.generate(page_url, page_title, true);
    }

    /// 生成临时 Short Link（返回的 link 由调用方负责 `allocator.free`）。
    pub fn generateShortLinkTemp(self: *Self, page_url: []const u8, page_title: []const u8) ![]u8 {
        return self.generate(page_url, page_title, null);
    }

    fn generate(self: *Self, page_url: []const u8, page_title: []const u8, is_permanent: ?bool) ![]u8 {
        // 用 std.json.Stringify 序列化请求体，正确处理 page_url/page_title 中的特殊字符；
        // `is_permanent` 为 null 时（临时链接）不序列化该字段。
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("page_url");
        try s.write(page_url);
        try s.objectField("page_title");
        try s.write(page_title);
        if (is_permanent) |p| {
            try s.objectField("is_permanent");
            try s.write(p);
        }
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const Sender = struct {
            sl: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try allocator.print(
                    "https://api.weixin.qq.com/wxa/genwxashortlink?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.sl.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "GenerateShortLink", Sender{
            .sl = self,
            .body = body,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            link: []const u8 = "",
        }, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.link);
    }
};

test "ShortLink.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-sl" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const sl = ShortLink.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-sl", sl.ctx.config.app_id);
}

test "shortlink 请求体省略 is_permanent（临时链接语义）" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("page_url");
    try s.write("pages/index?x=\"1\"");
    try s.objectField("page_title");
    try s.write("首页");
    try s.endObject();
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    // 临时链接不携带 is_permanent 字段，且特殊字符被正确转义。
    try std.testing.expect(std.mem.find(u8, body, "is_permanent") == null);
    try std.testing.expect(std.mem.find(u8, body, "\\\"1\\\"") != null);
}

// ── 可注入 transport 测试 ────────────────────────────────────────────────

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 记录 method / uri / payload 的 transport（generate 走线程默认 client）。
const CapturingTransport = struct {
    method: std.http.Method = .GET,
    uri: []u8 = &.{},
    payload: []u8 = &.{},
    response: []const u8 = "",

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = content_type;
        const self: *CapturingTransport = @ptrCast(@alignCast(ctx));
        self.method = method;
        if (self.uri.len > 0) allocator.free(self.uri);
        if (self.payload.len > 0) allocator.free(self.payload);
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }

    fn deinit(self: *CapturingTransport, allocator: std.mem.Allocator) void {
        if (self.uri.len > 0) allocator.free(self.uri);
        if (self.payload.len > 0) allocator.free(self.payload);
    }
};

test "generateShortLinkTemp POST 临时短链：URL/body 省略 is_permanent 且解析 link" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"link\":\"https://wxa.run/tmp1\"}" };
    defer tt.deinit(allocator);

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(CapturingTransport.dispatch, @ptrCast(&tt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx: Context = .{
        .config = .{ .app_id = "wx-sl" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var sl = ShortLink.init(&ctx, allocator);

    const link = try sl.generateShortLinkTemp("pages/index", "首页");
    defer allocator.free(link);

    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/genwxashortlink?access_token=token-abc", tt.uri);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"page_url\":\"pages/index\"") != null);
    try std.testing.expect(std.mem.find(u8, tt.payload, "is_permanent") == null);
    try std.testing.expectEqualStrings("https://wxa.run/tmp1", link);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "generateShortLinkPermanent token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/wxa/genwxashortlink?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":40014,\"errmsg\":\"invalid access_token\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"link\":\"https://wxa.run/abc\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-sl" },
        .access_token_handle = stub.asHandle(),
    };
    var sl = ShortLink.init(&ctx, allocator);

    const link = try sl.generateShortLinkPermanent("pages/index", "首页");
    defer allocator.free(link);
    try std.testing.expectEqualStrings("https://wxa.run/abc", link);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
