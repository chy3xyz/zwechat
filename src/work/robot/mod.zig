// SPDX-License-Identifier: Apache-2.0
//! work/robot — 群机器人 webhook 推送
//!
//! 对应 `_ref/wechat/work/robot/`：通过群机器人 `webhook_url` 推送
//! 文本 / Markdown 消息。**不需要** access_token，调用方需要先在
//! 企业微信群中添加机器人并取得 webhook key。
//!
//! 当前落地：
//! - `sendText`（文本消息，可附带 @ 成员列表）
//! - `sendMarkdown`（Markdown 消息）

const std = @import("std");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_json = @import("../../util/json.zig");
const util_uri = @import("../../util/uri.zig");

// ─────────────────────────────────────────────────────────────────────────────
// query 转义
// ─────────────────────────────────────────────────────────────────────────────

/// 按 Go `url.QueryEscape` 语义转义 query 参数值（收敛到 `util.uri.queryEscape`）。
const queryEscape = util_uri.queryEscape;

/// 组装 `webhook/send?key={escaped_key}` 的 URI。
fn webhookURI(allocator: std.mem.Allocator, webhook_key: []const u8) ![]u8 {
    const escaped = try queryEscape(allocator, webhook_key);
    defer allocator.free(escaped);
    return allocator.print("{s}?key={s}", .{ webhookSendURL, escaped });
}

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 群机器人 webhook 发送接口。
/// 调用方在 `webhook_key` 处传入机器人的 key（通常 `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...`）。
pub const webhookSendURL = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send";

// ─────────────────────────────────────────────────────────────────────────────
// 响应 / 数据结构
// ─────────────────────────────────────────────────────────────────────────────

/// 通用响应（机器人接口）。
pub const WebhookSendResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

/// 文本消息请求体。
pub const TextMessage = struct {
    /// 文本内容，最长 2048 字节（utf8）。
    content: []const u8 = "",
    /// 通过 userid @ 指定成员。
    mentioned_list: [][]const u8 = &.{},
    /// 通过手机号 @ 指定成员。
    mentioned_mobile_list: [][]const u8 = &.{},
};

/// Markdown 消息请求体。
pub const MarkdownMessage = struct {
    /// Markdown 内容，最长 4096 字节（utf8）。
    content: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 群机器人子模块。
///
/// 机器人推送**不依赖** `Context`（无需 access_token），
/// 只需要 `webhook_key` 与 allocator。
pub const Robot = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 直接用 allocator 构造实例。
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// 发送文本消息。
    ///
    /// `webhook_key` 形如 `abc123-def456-...`（机器人配置中可见的 key 段）。
    pub fn sendText(
        self: *Self,
        webhook_key: []const u8,
        msg: TextMessage,
    ) !std.json.Parsed(WebhookSendResponse) {
        const uri = try webhookURI(self.allocator, webhook_key);
        defer self.allocator.free(uri);

        const body = try encodeTextMessage(self.allocator, msg);
        defer self.allocator.free(body);

        return self.postAndDecode(uri, body);
    }

    /// 发送 Markdown 消息。
    pub fn sendMarkdown(
        self: *Self,
        webhook_key: []const u8,
        msg: MarkdownMessage,
    ) !std.json.Parsed(WebhookSendResponse) {
        const uri = try webhookURI(self.allocator, webhook_key);
        defer self.allocator.free(uri);

        const body = try encodeMarkdownMessage(self.allocator, msg);
        defer self.allocator.free(body);

        return self.postAndDecode(uri, body);
    }

    // -------------------------------------------------------------------------

    fn postAndDecode(self: *Self, uri: []const u8, body: []const u8) !std.json.Parsed(WebhookSendResponse) {
        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(WebhookSendResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：手写 JSON 序列化
// ─────────────────────────────────────────────────────────────────────────────

fn encodeTextMessage(allocator: std.mem.Allocator, msg: TextMessage) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"msgtype\":\"text\",\"text\":{");
    try buf.appendSlice(allocator, "\"content\":\"");
    try appendJsonString(allocator, &buf, msg.content);
    try buf.append(allocator, '"');
    if (msg.mentioned_list.len > 0) {
        try buf.appendSlice(allocator, ",\"mentioned_list\":[");
        for (msg.mentioned_list, 0..) |u, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try appendJsonString(allocator, &buf, u);
            try buf.append(allocator, '"');
        }
        try buf.append(allocator, ']');
    }
    if (msg.mentioned_mobile_list.len > 0) {
        try buf.appendSlice(allocator, ",\"mentioned_mobile_list\":[");
        for (msg.mentioned_mobile_list, 0..) |u, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try appendJsonString(allocator, &buf, u);
            try buf.append(allocator, '"');
        }
        try buf.append(allocator, ']');
    }
    try buf.appendSlice(allocator, "}}");
    return buf.toOwnedSlice(allocator);
}

fn encodeMarkdownMessage(allocator: std.mem.Allocator, msg: MarkdownMessage) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"msgtype\":\"markdown\",\"markdown\":{\"content\":\"");
    try appendJsonString(allocator, &buf, msg.content);
    try buf.appendSlice(allocator, "\"}}");
    return buf.toOwnedSlice(allocator);
}

/// JSON 字符串转义（实现收敛到 `util.json.appendEscapedString`；
/// 同时把 `\b`/`\f` 由 `\u0008`/`\u000c` 改为与 Go / `std.json` 一致的短转义）。
const appendJsonString = util_json.appendEscapedString;

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

test "Robot.init 持有 allocator" {
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const r = Robot.init(fba.allocator());
    // allocator 是 std.mem.Allocator（值类型），逐字段按指针比较
    try std.testing.expect(r.allocator.ptr == fba.allocator().ptr);
    try std.testing.expect(r.allocator.vtable == fba.allocator().vtable);
}

test "TextMessage 默认值" {
    const m = TextMessage{};
    try std.testing.expectEqualStrings("", m.content);
    try std.testing.expectEqual(@as(usize, 0), m.mentioned_list.len);
    try std.testing.expectEqual(@as(usize, 0), m.mentioned_mobile_list.len);
}

test "MarkdownMessage 默认值" {
    const m = MarkdownMessage{};
    try std.testing.expectEqualStrings("", m.content);
}

test "encodeTextMessage 生成合法 JSON" {
    const alloc = std.testing.allocator;
    var users = [_][]const u8{ "user1", "user2" };
    const body = try encodeTextMessage(alloc, .{
        .content = "hello \"world\"\n",
        .mentioned_list = &users,
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"msgtype\":\"text\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\\\"world\\\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\\n") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"mentioned_list\":[\"user1\",\"user2\"]") != null);
}

test "encodeMarkdownMessage 生成合法 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeMarkdownMessage(alloc, .{ .content = "# title" });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"msgtype\":\"markdown\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"markdown\":{\"content\":\"# title\"}") != null);
}

test "encodeTextMessage 转义控制字符生成合法 JSON" {
    const alloc = std.testing.allocator;
    var users = [_][]const u8{"u\x01"};
    const body = try encodeTextMessage(alloc, .{
        .content = "a\x07\x0bb",
        .mentioned_list = &users,
    });
    defer alloc.free(body);

    // <0x20 控制字符必须被转义，不能原样写入。
    try std.testing.expect(std.mem.find(u8, body, "\\u0007") != null);
    try std.testing.expect(std.mem.find(u8, body, "\\u000b") != null);
    try std.testing.expect(std.mem.find(u8, body, "\\u0001") != null);
    try std.testing.expect(std.mem.find(u8, body, "\x07") == null);

    // 输出可被 std.json 解析回原文。
    const Decoded = struct {
        msgtype: []const u8,
        text: struct {
            content: []const u8,
            mentioned_list: []const []const u8,
        },
    };
    var parsed = try std.json.parseFromSlice(Decoded, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\x07\x0bb", parsed.value.text.content);
    try std.testing.expectEqualStrings("u\x01", parsed.value.text.mentioned_list[0]);
}

// ─────────────────────────────────────────────────────────────────────────────
// query 转义守护（回归：用户可控参数裸插值进 URL query）
// ─────────────────────────────────────────────────────────────────────────────

test "webhookURI 正常输入与改造前逐字节一致、特殊字符 key 被转义" {
    const allocator = std.testing.allocator;

    const plain = try webhookURI(allocator, "693a91f6-7f3e-4bc4-97a0-0ec2sifa5aaa");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=693a91f6-7f3e-4bc4-97a0-0ec2sifa5aaa",
        plain,
    );

    const escaped = try webhookURI(allocator, "k&ey=1");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k%26ey%3D1",
        escaped,
    );
}

test "sendText / sendMarkdown 用转义后的 key 发请求" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k%26ey%3D1", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var r = Robot.init(allocator);
    {
        var parsed = try r.sendText("k&ey=1", .{ .content = "hi" });
        defer parsed.deinit();
    }
    {
        var parsed = try r.sendMarkdown("k&ey=1", .{ .content = "# hi" });
        defer parsed.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k%26ey%3D1",
        mt.history.items[0],
    );
}
