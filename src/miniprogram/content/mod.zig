// SPDX-License-Identifier: Apache-2.0
//! miniprogram/content — 内容安全（旧接口）
//!
//! 对应 `_ref/wechat/miniprogram/content/content.go`：`msg_sec_check` / `img_sec_check`。
//! 注意：微信已推荐使用 `security.MsgSecCheck` / `security.ImgSecCheck`（返回值更丰富），
//! 本模块保留旧接口以对齐上游参考实现。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 内容安全模块（旧接口）。
pub const Content = struct {
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

    /// 检测文字内容 (`msg_sec_check` v2)。
    ///
    /// `openid` / `scene` 为必填参数（对齐 security.msgSecCheck）：
    /// `scene` 取值 1: 资料，2: 评论，3: 论坛，4: 社交日志。
    ///
    /// 返回微信原始响应体，调用方负责 `allocator.free`；
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次，
    /// 其他非 0 errcode 返回 `WechatError.ApiError`。
    pub fn checkText(self: *Self, openid: []const u8, text: []const u8, scene: u8) ![]u8 {
        const body = try encodeCheckTextBody(self.allocator, openid, text, scene);
        defer self.allocator.free(body);

        const Sender = struct {
            content: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/msg_sec_check?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                return c.content.postJSON(uri, c.body);
            }
        };

        return util_retry.callApi(self.ctx, self.allocator, "ContentCheckText", Sender{
            .content = self,
            .body = body,
        });
    }

    /// 检测图片内容（`media` 为图片文件绝对路径）。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次。
    pub fn checkImage(self: *Self, media: []const u8) !void {
        const Sender = struct {
            content: *Self,
            media: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/img_sec_check?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);

                const client = util_http.getDefaultClient(c.content.allocator);
                const fields = [_]util_http.MultipartField{
                    .{
                        .is_file = true,
                        .field_name = "media",
                        .filename = "media",
                        .value = "",
                        .file_path = c.media,
                    },
                };
                return client.postMultipart(uri, &fields);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "ContentCheckImage", Sender{
            .content = self,
            .media = media,
        });
        self.allocator.free(resp);
    }
};

/// 构造 `msg_sec_check` 的 JSON 请求体（字符串字段统一走 `std.json.Stringify`
/// 转义，避免 openid/content 中的引号破坏 JSON）。
fn encodeCheckTextBody(allocator: std.mem.Allocator, openid: []const u8, text: []const u8, scene: u8) ![]u8 {
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
    try s.write(text);
    try s.endObject();
    return out.toOwnedSlice();
}

test "Content.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ct" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const c = Content.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ct", c.ctx.config.app_id);
}

test "encodeCheckTextBody 特殊字符转义为合法 JSON" {
    const allocator = std.testing.allocator;
    const body = try encodeCheckTextBody(allocator, "o\"pen\\id", "内容\n\"quoted\"", 2);
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

test "checkText body 含 openid/scene/version:2 且成功返回" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx: Context = .{
        .config = .{ .app_id = "wx-ct" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var c = Content.init(&ctx, allocator);
    c.setTransport(Capture.dispatch, &cap);

    const resp = try c.checkText("oABC", "hello \"world\" \\ 检查", 2);
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
    try std.testing.expectEqual(@as(u8, 2), parsed.value.scene);
    try std.testing.expectEqual(@as(u8, 2), parsed.value.version);
    try std.testing.expectEqualStrings("hello \"world\" \\ 检查", parsed.value.content);
}

test "checkText errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":87014,\"errmsg\":\"risky content\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx: Context = .{
        .config = .{ .app_id = "wx-ct" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var c = Content.init(&ctx, allocator);
    c.setTransport(Capture.dispatch, &cap);

    const result = c.checkText("oABC", "违规内容", 3);
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "checkText token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/wxa/msg_sec_check?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-ct" },
        .access_token_handle = stub.asHandle(),
    };
    var c = Content.init(&ctx, allocator);
    c.setTransport(util_http.MockTransport.dispatch, &mt);

    const resp = try c.checkText("oABC", "hello", 2);
    defer allocator.free(resp);
    try std.testing.expectEqualStrings("{\"errcode\":0,\"errmsg\":\"ok\"}", resp);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
