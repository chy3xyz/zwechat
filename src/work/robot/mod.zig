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
    ) !WebhookSendResponse {
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?key={s}",
            .{ webhookSendURL, webhook_key },
        );
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
    ) !WebhookSendResponse {
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?key={s}",
            .{ webhookSendURL, webhook_key },
        );
        defer self.allocator.free(uri);

        const body = try encodeMarkdownMessage(self.allocator, msg);
        defer self.allocator.free(body);

        return self.postAndDecode(uri, body);
    }

    // -------------------------------------------------------------------------

    fn postAndDecode(self: *Self, uri: []const u8, body: []const u8) !WebhookSendResponse {
        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(WebhookSendResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：手写 JSON 序列化
// ─────────────────────────────────────────────────────────────────────────────

fn encodeTextMessage(allocator: std.mem.Allocator, msg: TextMessage) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"msgtype\":\"markdown\",\"markdown\":{\"content\":\"");
    try appendJsonString(allocator, &buf, msg.content);
    try buf.appendSlice(allocator, "\"}}");
    return buf.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

test "Robot.init 持有 allocator" {
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const r = Robot.init(fba.allocator());
    // allocator 是 std.mem.Allocator（值类型），通过 vtable 指针比较即可
    try std.testing.expectEqual(@intFromPtr(fba.allocator().vtable), @intFromPtr(r.allocator.vtable));
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
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"mentioned_list\":[\"user1\",\"user2\"]") != null);
}

test "encodeMarkdownMessage 生成合法 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeMarkdownMessage(alloc, .{ .content = "# title" });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"markdown\":{\"content\":\"# title\"}") != null);
}
