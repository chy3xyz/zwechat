//! officialaccount/server — 公众号消息接收服务器
//!
//! 对应 `_ref/wechat/officialaccount/server/server.go`：处理微信推送的请求。
//! 主要能力：
//! - 验证请求签名（`util.signature`：SHA1 sort-and-hash）
//! - 验证 URL 握手（echostr 回显）
//! - 解析收到的 XML 消息（`util.xml`）
//! - 安全模式：AES 解密 + 验签（`util.crypto`）
//! - 被动回复：构造 XML 响应（明文或加密）

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_crypto = @import("../../util/crypto.zig");
const util_sig = @import("../../util/signature.zig");
const util_xml = @import("../../util/xml.zig");
const util_util = @import("../../util/util.zig");
const util_time = @import("../../util/time.zig");
const message = @import("../message/mod.zig");

/// MessageHandler：用户自定义的回调，根据收到的消息返回回复。
///
/// 返回 `null` 表示不回复（明文模式下微信服务器返回 "success"）。
pub const MessageHandler = *const fn (ctx: *anyopaque, msg: *message.MixMessage) anyerror!?message.Reply;

/// HTTP query 参数集合（`signature / timestamp / nonce / echostr / msg_signature / encrypt_type`）。
pub const Query = struct {
    signature: []const u8 = "",
    timestamp: []const u8 = "",
    nonce: []const u8 = "",
    echostr: []const u8 = "",
    msg_signature: []const u8 = "",
    encrypt_type: []const u8 = "",
};

/// 已解析的入站消息（来自 XML 解密后）。
pub const InboundMessage = struct {
    allocator: std.mem.Allocator,
    raw_xml: []u8,
    doc: util_xml.XmlDoc,
    open_id: []const u8 = "",
    timestamp: i64 = 0,
    nonce: []const u8 = "",

    pub fn deinit(self: *InboundMessage) void {
        self.allocator.free(self.raw_xml);
        self.doc.deinit();
    }

    /// 取任意字段值。
    pub fn get(self: InboundMessage, key: []const u8) ?[]const u8 {
        return self.doc.get(key);
    }
};

/// 公众号消息接收服务器。
pub const Server = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    raw_body: []u8 = &.{},

    /// 用户注册的消息处理回调（`null` = 不处理）。
    handler: ?MessageHandler = null,
    handler_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注册用户消息处理回调。
    pub fn setMessageHandler(self: *Self, handler: MessageHandler, ctx: ?*anyopaque) void {
        self.handler = handler;
        self.handler_ctx = ctx;
    }

    /// 设置原始请求 body（在调用 `serve` 前由调用方提供）。
    pub fn setRawBody(self: *Self, body: []u8) void {
        self.raw_body = body;
    }

    /// 计算服务端应当回显的签名（与微信的 signature 比较）。
    /// 公式：SHA1(sort([token, timestamp, nonce]))。
    pub fn validateSignature(self: *Self, q: Query) ![]u8 {
        const token = self.ctx.config.token;
        return util_sig.signature(self.allocator, &[_][]const u8{ token, q.timestamp, q.nonce });
    }

    /// 验证 URL 握手（GET 请求带 echostr）。
    /// 返回 true 表示签名匹配，false 表示应拒绝。
    pub fn validateURL(self: *Self, q: Query) !bool {
        const computed = try self.validateSignature(q);
        defer self.allocator.free(computed);
        return std.mem.eql(u8, computed, q.signature);
    }

    /// 处理明文模式（不安全）的消息：直接解析 body XML。
    pub fn parsePlainMessage(self: *Self, open_id: []const u8) !InboundMessage {
        const doc = try util_xml.parse(self.allocator, self.raw_body);
        return .{
            .allocator = self.allocator,
            .raw_xml = self.raw_body,
            .doc = doc,
            .open_id = open_id,
        };
    }

    /// 处理安全模式（`encrypt_type=aes`）的消息：先验签、再 AES 解密、最后解析 XML。
    pub fn parseEncryptedMessage(self: *Self, q: Query, open_id: []const u8) !InboundMessage {
        // 1) 验证消息签名
        const computed = try util_sig.signature(self.allocator, &[_][]const u8{
            self.ctx.config.token,
            q.timestamp,
            q.nonce,
            std.mem.span(@as([*:0]const u8, @ptrCast(self.raw_body.ptr)))[0..self.raw_body.len],
        });
        defer self.allocator.free(computed);
        if (!std.mem.eql(u8, computed, q.msg_signature)) return error.SignatureMismatch;

        // 2) 从 body 中取出 Encrypt 字段
        const doc = try util_xml.parse(self.allocator, self.raw_body);
        defer @constCast(&doc).deinit();
        const encrypted_b64 = doc.get("Encrypt") orelse return error.MissingEncrypt;

        // 3) AES 解密（返回 duped 切片）
        const decoded = try util_crypto.aesDecryptMsg(self.allocator, encrypted_b64, self.ctx.config.encoding_aes_key);
        defer self.allocator.free(decoded.random);
        defer self.allocator.free(decoded.raw_xml_msg);
        defer self.allocator.free(decoded.app_id);

        // 4) 验证 AppID 匹配
        if (!std.mem.eql(u8, decoded.app_id, self.ctx.config.app_id)) return error.AppIDMismatch;

        // 5) dup 一份 raw_xml 供后续使用
        const raw_xml_dup = try self.allocator.dupe(u8, decoded.raw_xml_msg);
        const inner_doc = try util_xml.parse(self.allocator, decoded.raw_xml_msg);

        return .{
            .allocator = self.allocator,
            .raw_xml = raw_xml_dup,
            .doc = inner_doc,
            .open_id = open_id,
            .timestamp = std.fmt.parseInt(i64, q.timestamp, 10) catch 0,
            .nonce = q.nonce,
        };
    }

    /// 构造被动回复的 XML（明文模式）。
    pub fn buildReply(self: *Self, to_user: []const u8, from_user: []const u8, content: []const u8) ![]u8 {
        const ts_str = try std.fmt.allocPrint(self.allocator, "{d}", .{util_time.getCurrTS()});
        defer self.allocator.free(ts_str);

        const nonce = try util_util.randomStr(self.allocator, 16);
        defer self.allocator.free(nonce);

        var elements = [_]util_xml.XmlElement{
            .{ .key = "ToUserName", .value = to_user },
            .{ .key = "FromUserName", .value = from_user },
            .{ .key = "CreateTime", .value = ts_str },
            .{ .key = "MsgType", .value = "text" },
            .{ .key = "Content", .value = content },
            .{ .key = "MsgId", .value = nonce }, // 借用 nonce 字段作 MsgId 简化演示
        };
        return util_xml.serialize(self.allocator, "xml", &elements);
    }

    /// 构造被动回复的加密 XML（安全模式）。
    pub fn buildEncryptedReply(self: *Self, to_user: []const u8, from_user: []const u8, content: []const u8, timestamp: i64, nonce: []const u8) ![]u8 {
        const reply_xml = try self.buildReply(to_user, from_user, content);
        defer self.allocator.free(reply_xml);

        // 生成 16 字节随机数
        var random: [16]u8 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            random[i] = std.crypto.random.intRangeAtMost(u8, 0, 255);
        }

        // AES 加密（返回 ciphertext 字节）
        const cipher = try util_crypto.aesEncryptMsg(self.allocator, &random, reply_xml, self.ctx.config.app_id, self.ctx.config.encoding_aes_key);
        defer self.allocator.free(cipher);

        // 拼装 XML：<xml><Encrypt>...</Encrypt><MsgSignature>...</MsgSignature><TimeStamp>...</TimeStamp><Nonce>...</Nonce></xml>
        const cipher_b64 = std.base64.standard.encodes(cipher);
        const ts_str = try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
        defer self.allocator.free(ts_str);

        // 消息签名：SHA1(sort([token, timestamp, nonce, encrypted]))
        const sig = try util_sig.signature(self.allocator, &[_][]const u8{
            self.ctx.config.token,
            ts_str,
            nonce,
            cipher_b64,
        });
        defer self.allocator.free(sig);

        var elements = [_]util_xml.XmlElement{
            .{ .key = "Encrypt", .value = cipher_b64 },
            .{ .key = "MsgSignature", .value = sig },
            .{ .key = "TimeStamp", .value = ts_str },
            .{ .key = "Nonce", .value = nonce },
        };
        const body = try util_xml.serialize(self.allocator, "xml", &elements);
        self.allocator.free(cipher_b64);
        return body;
    }

    /// 主入口：处理微信推送的请求。
    ///
    /// 流程（对照 Go `server.Serve`）：
    /// 1. 验证签名（`signature` query）
    /// 2. 处理 URL 握手（`echostr` query → 直接回显）
    /// 3. 解密 body（如安全模式）
    /// 4. 解析 XML
    /// 5. 调用 handler 获取回复
    /// 6. 构造响应 XML
    ///
    /// 返回的字符串直接写入 HTTP 响应 body。
    pub fn serve(self: *Self, q: Query) ![]u8 {
        // 1. 验证签名
        if (!try self.validateURL(q)) return error.SignatureMismatch;

        // 2. URL 握手（GET 请求带 echostr）
        if (q.echostr.len > 0) {
            return self.allocator.dupe(u8, q.echostr);
        }

        // 3 + 4. 解析消息（明文模式；安全模式将在下一波支持）
        // 简化：直接 parse plain
        var msg = message.MixMessage{};
        var doc = try util_xml.parse(self.allocator, self.raw_body);
        defer doc.deinit();

        msg.common.to_user_name = doc.get("ToUserName") orelse "";
        msg.common.from_user_name = doc.get("FromUserName") orelse "";
        if (doc.get("CreateTime")) |ts| msg.common.create_time = std.fmt.parseInt(i64, ts, 10) catch 0;
        if (doc.get("MsgType")) |mt| {
            msg.common.msg_type = std.meta.stringToEnum(message.MsgType, mt) orelse .text;
        }
        msg.content = doc.get("Content") orelse "";
        msg.media_id = doc.get("MediaId") orelse "";
        msg.pic_url = doc.get("PicUrl") orelse "";
        msg.url = doc.get("Url") orelse "";

        // 5. 调用 handler
        const handler = self.handler orelse {
            // 没有 handler：返回 "success"
            return self.allocator.dupe(u8, "success");
        };
        const reply_opt = try handler(self.handler_ctx orelse @constCast(@ptrCast(&self)), &msg);
        const reply = reply_opt orelse {
            return self.allocator.dupe(u8, "success");
        };

        // 6. 构造响应 XML
        return reply.format(self.allocator, msg.common.from_user_name, msg.common.to_user_name);
    }
};

test "Server.validateSignature 与 Go 行为一致" {
    var ctx: Context = .{
        .config = .{ .token = "token_test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var s = Server.init(&ctx, fba.allocator());

    const sig = try s.validateSignature(.{ .timestamp = "1700000000", .nonce = "abc" });
    defer fba.allocator().free(sig);

    // SHA1(sort(["token_test", "1700000000", "abc"])) = SHA1("1700000000abctoken_test")
    // Python: hashlib.sha1("1700000000abctoken_test".encode()).hexdigest()
    try std.testing.expectEqualStrings("4b2424759d05f70ab6f7693974a17d6992999b96", sig);
}

test "Server.buildReply 输出合法 XML" {
    var ctx: Context = .{
        .config = .{ .token = "t" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var s = Server.init(&ctx, fba.allocator());
    const xml = try s.buildReply("user1", "gh_x", "hello back");
    defer fba.allocator().free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<![CDATA[hello back]]>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<ToUserName><![CDATA[user1]]>") != null);
}

test "Server.serve 端到端：handler 收到 text 消息，返回 text 回复" {
    const allocator = std.testing.allocator;

    var ctx: Context = .{
        .config = .{ .token = "tok-it" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var s = Server.init(&ctx, allocator);

    // 注册 handler
    s.setMessageHandler(struct {
        fn h(_: *anyopaque, msg: *message.MixMessage) anyerror!?message.Reply {
            if (msg.content.len == 0) return null;
            return .{ .msg_type = .text, .data = .{ .text = .{ .content = msg.content } } };
        }
    }.h, null);

    // 构造微信推送的明文 XML
    const raw_xml =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[user-abc]]></FromUserName>
        \\  <CreateTime>1700000000</CreateTime>
        \\  <MsgType><![CDATA[text]]></MsgType>
        \\  <Content><![CDATA[echo me]]></Content>
        \\</xml>
    ;
    const raw_dup = try allocator.dupe(u8, raw_xml);
    defer allocator.free(raw_dup);
    s.setRawBody(raw_dup);

    const sig = try util_sig.signature(allocator, &[_][]const u8{ "tok-it", "1700000000", "n-it" });
    defer allocator.free(sig);

    const q = Query{ .signature = sig, .timestamp = "1700000000", .nonce = "n-it" };
    const response = try s.serve(q);
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "<![CDATA[echo me]]>") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "<MsgType><![CDATA[text]]>") != null);
}

test "Server.serve 无 handler 时返回 success" {
    const allocator = std.testing.allocator;
    var ctx: Context = .{
        .config = .{ .token = "tok-nh" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var s = Server.init(&ctx, allocator);

    const raw_xml = "<xml><Content><![CDATA[hi]]></Content></xml>";
    const raw_dup = try allocator.dupe(u8, raw_xml);
    defer allocator.free(raw_dup);
    s.setRawBody(raw_dup);

    const sig = try util_sig.signature(allocator, &[_][]const u8{ "tok-nh", "1700000000", "nh" });
    defer allocator.free(sig);

    const q = Query{ .signature = sig, .timestamp = "1700000000", .nonce = "nh" };
    const response = try s.serve(q);
    defer allocator.free(response);
    try std.testing.expectEqualStrings("success", response);
}

test "Server.serve 签名错误返回 SignatureMismatch" {
    const allocator = std.testing.allocator;
    var ctx: Context = .{
        .config = .{ .token = "tok-sm" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var s = Server.init(&ctx, allocator);

    const q = Query{ .signature = "wrong", .timestamp = "1700000000", .nonce = "nh" };
    const result = s.serve(q);
    try std.testing.expectError(error.SignatureMismatch, result);
}