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
    /// 响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn checkText(self: *Self, openid: []const u8, text: []const u8, scene: u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/msg_sec_check?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try encodeCheckTextBody(self.allocator, openid, text, scene);
        defer self.allocator.free(body);

        const resp = try self.postJSON(uri, body);
        errdefer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            // errdefer 负责释放 resp。
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) {
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    /// 检测图片内容（`media` 为图片文件绝对路径）。
    pub fn checkImage(self: *Self, media: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/img_sec_check?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const fields = [_]util_http.MultipartField{
            .{
                .is_file = true,
                .field_name = "media",
                .filename = "media",
                .value = "",
                .file_path = media,
            },
        };
        const resp = try client.postMultipart(uri, &fields);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "ContentCheckImage")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
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
