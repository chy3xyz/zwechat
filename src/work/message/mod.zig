// SPDX-License-Identifier: Apache-2.0
//! work/message — 应用消息推送
//!
//! 对应 `_ref/wechat/work/message/`：实现企业微信"发送应用消息"接口
//! (`/cgi-bin/message/send`)，支持文本 / 图片 / 语音 / 视频 / 文件 / 图文 /
//! 文本卡片 / markdown / 小程序 / 菜单 等多种 `msgtype`。
//!
//! 当前落地 `SendText` 和 `SendImage` 两个最常用入口；其他类型（voice /
//! video / file / news / mpnews / markdown / miniprogram_notice 等）扩展时
//! 只需参照现有 `SendTextRequest` / `SendImageRequest` 形状新增一个 `msgtype`
//! 子结构，并复用 `Send` 即可。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 发送应用消息接口。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token={access_token}`。
pub const sendURL = "https://qyapi.weixin.qq.com/cgi-bin/message/send";

// ─────────────────────────────────────────────────────────────────────────────
// 请求 / 响应结构
// ─────────────────────────────────────────────────────────────────────────────

/// 发送应用消息的公共参数（对应 Go 的 `SendRequestCommon`）。
///
/// Go 版通过 `*SendRequestCommon` 嵌入到 `SendTextRequest` 等具体请求中；
/// Zig 没有继承，这里用"扁平化"实现：每个具体请求类型都直接持有这些字段。
/// 默认值均按企业微信文档的"不传 = 关闭"约定。
pub const SendRequestCommon = struct {
    /// 指定接收消息的成员，成员 ID 列表（多个用 `|` 分隔，最多 1000 个）；
    /// 特殊值 `"@all"` 表示向企业应用的全部成员发送。
    to_user: []const u8 = "",
    /// 指定接收消息的部门，部门 ID 列表（多个用 `|` 分隔，最多 100 个）；
    /// `to_user = "@all"` 时本参数被忽略。
    to_party: []const u8 = "",
    /// 指定接收消息的标签，标签 ID 列表（多个用 `|` 分隔，最多 100 个）；
    /// `to_user = "@all"` 时本参数被忽略。
    to_tag: []const u8 = "",
    /// 群聊 id，指定后向该群发送消息（应用消息群）。
    /// 企业微信约定：`chat_id` 与 `to_user` / `to_party` / `to_tag` 互斥，
    /// 指定本字段后三者均不生效。
    chat_id: []const u8 = "",
    /// 消息类型，由具体 `SendText` / `SendImage` 等函数负责设置。
    msg_type: []const u8 = "",
    /// 企业应用的 id，整型。
    agent_id: []const u8 = "",
    /// 是否是保密消息：`0` 表示可对外分享，`1` 表示不能分享且内容显示水印。
    safe: i64 = 0,
    /// 是否开启 id 转译：`0` 表示否，`1` 表示是。默认 0，仅第三方应用需要。
    enable_id_trans: i64 = 0,
    /// 是否开启重复消息检查：`0` 表示否，`1` 表示是。
    enable_duplicate_check: i64 = 0,
    /// 重复消息检查的时间间隔（秒），默认 1800，最大不超过 4 小时。
    duplicate_check_interval: i64 = 0,
};

/// 发送文本消息请求。
///
/// 公共字段来自 `SendRequestCommon`；`text.content` 为消息正文（utf8，最长 2048 字节）。
pub const SendTextRequest = struct {
    common: SendRequestCommon = .{},
    /// 文本内容（最长 2048 字节，超过将截断）。
    content: []const u8 = "",
};

/// 发送图片消息请求。
///
/// 图片素材需要先调用 `/cgi-bin/media/upload` 获取 `media_id`。
pub const SendImageRequest = struct {
    common: SendRequestCommon = .{},
    /// 图片媒体文件 id。
    media_id: []const u8 = "",
};

/// 发送 Markdown 消息请求。
///
/// Markdown 内容是纯文本（最长 2048 字节），与企业微信智能机器人
/// 的 markdown 卡片互通。无需 `media_id` — 直接传内容即可。
pub const SendMarkdownRequest = struct {
    common: SendRequestCommon = .{},
    /// Markdown 内容（最长 2048 字节）。
    content: []const u8 = "",
};

/// `SendText` / `SendImage` / `SendMarkdown` 等共用的返回结构。
///
/// 除了 `errcode` / `errmsg`（在微信侧 errcode=0 表示成功），还会带回
/// 部分用户维度的回执信息以及本次消息的 `msgid`。
pub const SendResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 不合法的 userid，不区分大小写，统一转为小写。
    invalid_user: []const u8 = "",
    /// 不合法的 partyid。
    invalid_party: []const u8 = "",
    /// 不合法的标签 id。
    invalid_tag: []const u8 = "",
    /// 没有基础接口许可（包含已过期）的 userid。
    unlicensed_user: []const u8 = "",
    /// 消息 id。
    msgid: []const u8 = "",
    /// 仅第三方应用返回。
    response_code: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 应用消息子模块。
pub const Message = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 发送文本消息。
    ///
    /// 对应 `_ref/wechat/work/message/message.go` 的 `SendText`。
    /// 本方法会强制把 `msg_type` 置为 `"text"`。
    pub fn sendText(self: *Self, req: SendTextRequest) !std.json.Parsed(SendResponse) {
        var copy = req;
        copy.common.msg_type = "text";
        return self.send(SendTextRequest, copy);
    }

    /// 发送图片消息。
    ///
    /// 对应 `_ref/wechat/work/message/message.go` 的 `SendImage`。
    /// 本方法会强制把 `msg_type` 置为 `"image"`。
    pub fn sendImage(self: *Self, req: SendImageRequest) !std.json.Parsed(SendResponse) {
        var copy = req;
        copy.common.msg_type = "image";
        return self.send(SendImageRequest, copy);
    }

    /// 发送 Markdown 消息。
    ///
    /// 对应 WeCom API `msgtype: "markdown"`。本方法会强制把 `msg_type`
    /// 置为 `"markdown"`。内容直接传掉 fields 中的 `markdown.content`。
    pub fn sendMarkdown(self: *Self, req: SendMarkdownRequest) !std.json.Parsed(SendResponse) {
        var copy = req;
        copy.common.msg_type = "markdown";
        return self.send(SendMarkdownRequest, copy);
    }

    // -------------------------------------------------------------------------
    // 内部通用发送逻辑（对照 Go 的 `Send`）
    // -------------------------------------------------------------------------

    /// 把任意"已设置好 `msg_type`"的请求 JSON 化后调用 `/cgi-bin/message/send`。
    ///
    /// `T` 必须是 `SendTextRequest` / `SendImageRequest` / `SendMarkdownRequest`
    /// 之一；调用方应通过 `sendText` / `sendImage` / `sendMarkdown` 等包装方法间接调用。
    ///
    /// 取 token / 拼 URI / 发请求 / errcode 检查（含 token 失效后作废缓存并重试一次）
    /// 统一走 `util/retry.callApi`，`Req.send` 只负责「用给定 token 发一次请求」。
    fn send(self: *Self, comptime T: type, req: T) !std.json.Parsed(SendResponse) {
        const Req = struct {
            req: T,

            /// 用 `token` 拼出完整 URI 并 POST 请求体，返回响应体（所有权交给调用方）。
            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}",
                    .{ sendURL, token },
                );
                defer allocator.free(uri);

                const body = try serializeRequest(allocator, c.req);
                defer allocator.free(body);

                const client = util_http.getDefaultClient(allocator);
                return client.postJSON(uri, body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "MessageSend", Req{ .req = req });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(SendResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
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

/// 把 `SendTextRequest` / `SendImageRequest` 序列化为微信要求的 JSON 字符串。
///
/// 之所以手写而不直接用 `std.json.stringify`，是因为 Go 版用了"扁平"形式：
/// `SendRequestCommon` 字段直接展开到顶层，但文本/图片的子结构（`text` / `image`）
/// 是嵌套对象。手写可以避免无关字段（"msgtype" vs "msg_type"）被序列化。
fn serializeRequest(allocator: std.mem.Allocator, req: anytype) ![]u8 {
    const T = @TypeOf(req);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const c = req.common;

    try buf.append(allocator, '{');
    // 公共字段
    const common_fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "touser", .value = c.to_user },
        .{ .name = "toparty", .value = c.to_party },
        .{ .name = "totag", .value = c.to_tag },
        .{ .name = "chatid", .value = c.chat_id },
        .{ .name = "msgtype", .value = c.msg_type },
        .{ .name = "agentid", .value = c.agent_id },
    };
    for (common_fields) |f| {
        if (f.value.len != 0) {
            try buf.print(allocator, "\"{s}\":\"", .{f.name});
            try appendJsonString(allocator, &buf, f.value);
            try buf.append(allocator, '"');
            try buf.append(allocator, ',');
        }
    }
    if (c.safe != 0) try buf.print(allocator, "\"safe\":{d},", .{c.safe});
    if (c.enable_id_trans != 0) try buf.print(allocator, "\"enable_id_trans\":{d},", .{c.enable_id_trans});
    if (c.enable_duplicate_check != 0) try buf.print(allocator, "\"enable_duplicate_check\":{d},", .{c.enable_duplicate_check});
    if (c.duplicate_check_interval != 0) try buf.print(allocator, "\"duplicate_check_interval\":{d},", .{c.duplicate_check_interval});

    // 子结构：text 或 image
    switch (T) {
        SendTextRequest => {
            if (req.content.len == 0) {
                return error.InvalidArgument;
            }
            try buf.appendSlice(allocator, "\"text\":{\"content\":\"");
            try appendJsonString(allocator, &buf, req.content);
            try buf.appendSlice(allocator, "\"}}");
        },
        SendImageRequest => {
            if (req.media_id.len == 0) {
                return error.InvalidArgument;
            }
            try buf.appendSlice(allocator, "\"image\":{\"media_id\":\"");
            try appendJsonString(allocator, &buf, req.media_id);
            try buf.appendSlice(allocator, "\"}}");
        },
        SendMarkdownRequest => {
            if (req.content.len == 0) {
                return error.InvalidArgument;
            }
            try buf.appendSlice(allocator, "\"markdown\":{\"content\":\"");
            try appendJsonString(allocator, &buf, req.content);
            try buf.appendSlice(allocator, "\"}}");
        },
        else => @compileError("serializeRequest 不支持的请求类型"),
    }
    return buf.toOwnedSlice(allocator);
}

/// JSON 字符串转义（实现收敛到 `util.json.appendEscapedString`；此前漏转义
/// `c < 0x20` 控制字符，消息正文含控制字符时会产出非法 JSON）。
const appendJsonString = util_json.appendEscapedString;

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

test "Message.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const m = Message.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-msg", m.ctx.config.corp_id);
}

test "SendRequestCommon 默认值" {
    const c = SendRequestCommon{};
    try std.testing.expectEqualStrings("", c.to_user);
    try std.testing.expectEqualStrings("", c.msg_type);
    try std.testing.expectEqual(@as(i64, 0), c.safe);
}

test "SendTextRequest 默认值" {
    const r = SendTextRequest{};
    try std.testing.expectEqualStrings("", r.common.agent_id);
    try std.testing.expectEqualStrings("", r.content);
}

test "SendImageRequest 默认值" {
    const r = SendImageRequest{};
    try std.testing.expectEqualStrings("", r.common.agent_id);
    try std.testing.expectEqualStrings("", r.media_id);
}

test "SendResponse 默认值" {
    const r = SendResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
    try std.testing.expectEqualStrings("", r.msgid);
}

test "serializeRequest 文本消息 JSON 含 msgtype/text/content" {
    const alloc = std.testing.allocator;
    const body = try serializeRequest(alloc, SendTextRequest{
        .common = .{
            .to_user = "UserA|UserB",
            .agent_id = "1000002",
            .msg_type = "text",
        },
        .content = "hi \"you\"\n",
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"touser\":\"UserA|UserB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"agentid\":\"1000002\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"you\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "serializeRequest 图片消息 JSON 含 msgtype/image/media_id" {
    const alloc = std.testing.allocator;
    const body = try serializeRequest(alloc, SendImageRequest{
        .common = .{
            .to_user = "UserA",
            .agent_id = "1000002",
            .msg_type = "image",
        },
        .media_id = "MEDIA_ID_123",
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"image\":{\"media_id\":\"MEDIA_ID_123\"}") != null);
}

test "serializeRequest 空 content 返回 InvalidArgument" {
    const alloc = std.testing.allocator;
    const result = serializeRequest(alloc, SendTextRequest{
        .common = .{ .msg_type = "text" },
        .content = "",
    });
    try std.testing.expectError(error.InvalidArgument, result);
}

test "serializeRequest 群推送 chat_id 序列化为 chatid 且与 touser 互斥" {
    const alloc = std.testing.allocator;
    const body = try serializeRequest(alloc, SendMarkdownRequest{
        .common = .{
            .chat_id = "wrk_group_1",
            .msg_type = "markdown",
        },
        .content = "群周报",
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"chatid\":\"wrk_group_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"touser\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"markdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"markdown\":{\"content\":\"群周报\"}") != null);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：token 失效自愈（util/retry.callApi 链路）
// ─────────────────────────────────────────────────────────────────────────────

/// 可按脚本换发 token 并统计作废次数的凭据 handle 状态。
const RetryTokenState = struct {
    /// 依次给出的 token；回源次数超出脚本后复用最后一项。
    tokens: []const []const u8 = &.{ "tok-old", "tok-new" },
    fetch_calls: usize = 0,
    invalidate_calls: usize = 0,

    fn getToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RetryTokenState = @ptrCast(@alignCast(ctx));
        const token = self.tokens[@min(self.fetch_calls, self.tokens.len - 1)];
        self.fetch_calls += 1;
        return allocator.dupe(u8, token);
    }

    fn invalidate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *RetryTokenState = @ptrCast(@alignCast(ctx));
        self.invalidate_calls += 1;
    }

    const vtable = @import("../../credential/mod.zig").AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

/// 构造借用 `state` 的 Context（handle 的 ptr 指向测试局部状态）。
fn makeRetryCtx(state: *RetryTokenState) Context {
    return .{
        .config = .{ .corp_id = "ww-msg-retry" },
        .access_token_handle = .{ .ptr = @ptrCast(state), .vtable = &RetryTokenState.vtable },
    };
}

/// 安装 mock transport 并返回之（调用方负责复位默认 client）。
fn useMockTransport(allocator: std.mem.Allocator, mt: *util_http.MockTransport) void {
    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(mt));
}

test "sendText token 失效：40001 → 作废缓存 → 用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=tok-old", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential, access_token is invalid or not latest\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=tok-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"MSGID1\"}",
    });

    useMockTransport(allocator, &mt);
    defer {
        util_http.getDefaultClient(allocator).setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = RetryTokenState{};
    var ctx = makeRetryCtx(&state);
    var msg = Message.init(&ctx, allocator);
    var parsed = try msg.sendText(.{
        .common = .{ .to_user = "UserA", .agent_id = "1000002" },
        .content = "hi",
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("MSGID1", parsed.value.msgid);
    // 作废恰好一次，且第二次请求带的是换发后的新 token。
    try std.testing.expectEqual(@as(usize, 1), state.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=tok-old"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=tok-new"));
}

test "sendImage 非 token 类 errcode：直接 ApiError，不作废也不重试" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=tok-old", .{
        .body = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    });

    useMockTransport(allocator, &mt);
    defer {
        util_http.getDefaultClient(allocator).setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = RetryTokenState{};
    var ctx = makeRetryCtx(&state);
    var msg = Message.init(&ctx, allocator);

    const result = msg.sendImage(.{ .common = .{ .to_user = "UserA" }, .media_id = "MID" });
    try std.testing.expectError(util_error.WechatError.ApiError, result);

    try std.testing.expectEqual(@as(usize, 0), state.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.fetch_calls);
}
