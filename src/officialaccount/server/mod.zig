// SPDX-License-Identifier: Apache-2.0
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
const util_error = @import("../../util/error.zig");
const util_sig = @import("../../util/signature.zig");
const util_xml = @import("../../util/xml.zig");
const util_util = @import("../../util/util.zig");
const util_time = @import("../../util/time.zig");
const message = @import("../message/mod.zig");

/// MessageHandler：用户自定义的回调，根据收到的消息返回回复。
///
/// 返回 `null` 表示不回复（微信服务器侧应回 "success"）。
pub const MessageHandler = *const fn (ctx: *anyopaque, msg: *message.MixMessage) anyerror!?message.Reply;

/// HTTP query 参数集合（`signature / timestamp / nonce / echostr / msg_signature / encrypt_type / openid`）。
pub const Query = struct {
    signature: []const u8 = "",
    timestamp: []const u8 = "",
    nonce: []const u8 = "",
    echostr: []const u8 = "",
    msg_signature: []const u8 = "",
    encrypt_type: []const u8 = "",
    openid: []const u8 = "",
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

    /// 取任意字段值。返回的切片借用 `doc` 内部存储，随 `InboundMessage` 失效。
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
    /// `body` 的所有权仍归调用方，`Server` 只在其生命周期内借用。
    pub fn setRawBody(self: *Self, body: []u8) void {
        self.raw_body = body;
    }

    /// 计算服务端应当回显的签名（与微信的 signature 比较）。
    /// 公式：SHA1(sort([token, timestamp, nonce]))。
    /// 返回的切片由调用方负责 `allocator.free`。
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
    ///
    /// 返回的 `InboundMessage.raw_xml` 是本函数 `dupe` 出来的独立副本
    /// （`self.raw_body` 仍归调用方），由 `InboundMessage.deinit` 释放。
    pub fn parsePlainMessage(self: *Self, open_id: []const u8) !InboundMessage {
        const raw_xml_dup = try self.allocator.dupe(u8, self.raw_body);
        errdefer self.allocator.free(raw_xml_dup);
        const doc = try util_xml.parse(self.allocator, raw_xml_dup);
        return .{
            .allocator = self.allocator,
            .raw_xml = raw_xml_dup,
            .doc = doc,
            .open_id = open_id,
        };
    }

    /// 处理安全模式（`encrypt_type=aes`）的消息：验签 → AES 解密 → 解析 XML。
    ///
    /// 与 Go `server.getMessage` 对齐：消息签名 `msg_signature` 是对 **Encrypt 字段的
    /// base64 密文串** 做 SHA1(sort([token, timestamp, nonce, encrypt]))，
    /// 而不是对整个 body XML 做签名。
    pub fn parseEncryptedMessage(self: *Self, q: Query, open_id: []const u8) !InboundMessage {
        // 1) 先解析 body 取出 Encrypt 字段（签名对象就是它，不是整个 body）。
        var doc = try util_xml.parse(self.allocator, self.raw_body);
        defer doc.deinit();
        const encrypted_b64 = doc.get("Encrypt") orelse return error.MissingEncrypt;

        // 2) 验证消息签名：SHA1(sort([token, timestamp, nonce, encrypt_b64]))。
        const computed = try util_sig.signature(self.allocator, &[_][]const u8{
            self.ctx.config.token,
            q.timestamp,
            q.nonce,
            encrypted_b64,
        });
        defer self.allocator.free(computed);
        if (!std.mem.eql(u8, computed, q.msg_signature)) return error.SignatureMismatch;

        // 3) base64 解码出原始密文，再 AES 解密（aesDecryptMsg 收的是原始字节）。
        const cipher_len = std.base64.standard.Decoder.calcSizeForSlice(encrypted_b64) catch
            return util_error.WechatError.DecodeError;
        const cipher = try self.allocator.alloc(u8, cipher_len);
        defer self.allocator.free(cipher);
        std.base64.standard.Decoder.decode(cipher, encrypted_b64) catch
            return util_error.WechatError.DecodeError;

        const decoded = try util_crypto.aesDecryptMsg(self.allocator, cipher, self.ctx.config.encoding_aes_key);
        defer self.allocator.free(decoded.random);
        defer self.allocator.free(decoded.raw_xml_msg);
        defer self.allocator.free(decoded.app_id);

        // 4) 验证 AppID 匹配
        if (!std.mem.eql(u8, decoded.app_id, self.ctx.config.app_id)) return error.AppIDMismatch;

        // 5) dup 一份 raw_xml 供后续使用；doc 必须基于该持久副本解析，
        //    否则 elements 指向 decoded.raw_xml_msg（函数返回前被释放）造成 UAF。
        const raw_xml_dup = try self.allocator.dupe(u8, decoded.raw_xml_msg);
        errdefer self.allocator.free(raw_xml_dup);
        const inner_doc = try util_xml.parse(self.allocator, raw_xml_dup);

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
    /// 返回的切片由调用方负责 `allocator.free`。
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
    /// 返回的切片由调用方负责 `allocator.free`。
    pub fn buildEncryptedReply(self: *Self, to_user: []const u8, from_user: []const u8, content: []const u8, timestamp: i64, nonce: []const u8) ![]u8 {
        const reply_xml = try self.buildReply(to_user, from_user, content);
        defer self.allocator.free(reply_xml);
        return self.encryptXml(reply_xml, timestamp, nonce);
    }

    /// 把一段明文回复 XML 加密为安全模式响应包
    /// `<xml><Encrypt/><MsgSignature/><TimeStamp/><Nonce/></xml>`。
    fn encryptXml(self: *Self, plain_xml: []const u8, timestamp: i64, nonce: []const u8) ![]u8 {
        // 生成 16 字节随机数（OS 级随机源，同 work/smartbot 的取法）
        var random: [16]u8 = undefined;
        std.Io.Threaded.global_single_threaded.io().random(&random);

        // AES 加密（返回原始密文字节）
        const cipher = try util_crypto.aesEncryptMsg(self.allocator, &random, plain_xml, self.ctx.config.app_id, self.ctx.config.encoding_aes_key);
        defer self.allocator.free(cipher);

        // base64 编码（与 Go base64.StdEncoding 对齐，含 padding）。
        const b64_len = std.base64.standard.Encoder.calcSize(cipher.len);
        const cipher_b64 = try self.allocator.alloc(u8, b64_len);
        defer self.allocator.free(cipher_b64);
        _ = std.base64.standard.Encoder.encode(cipher_b64, cipher);

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
        return util_xml.serialize(self.allocator, "xml", &elements);
    }

    /// 从 XML doc 填充 `MixMessage`（明文 / 密文两条路径共用）。
    fn mixMessageFromDoc(doc: *const util_xml.XmlDoc) message.MixMessage {
        var msg = message.MixMessage{};
        msg.common.to_user_name = doc.get("ToUserName") orelse "";
        msg.common.from_user_name = doc.get("FromUserName") orelse "";
        if (doc.get("CreateTime")) |ts| msg.common.create_time = std.fmt.parseInt(i64, ts, 10) catch 0;
        if (doc.get("MsgType")) |mt| {
            msg.common.msg_type = std.meta.stringToEnum(message.MsgType, mt) orelse .text;
        }
        msg.content = doc.get("Content") orelse "";
        msg.msg_id = if (doc.get("MsgId")) |id| std.fmt.parseInt(i64, id, 10) catch 0 else 0;
        msg.media_id = doc.get("MediaId") orelse "";
        msg.pic_url = doc.get("PicUrl") orelse "";
        msg.url = doc.get("Url") orelse "";
        return msg;
    }

    /// 主入口：处理微信推送的请求。
    ///
    /// 流程（对照 Go `server.Serve`）：
    /// 1. 验证签名（`signature` query）
    /// 2. 处理 URL 握手（`echostr` query → 直接回显）
    /// 3. 解密 body（`encrypt_type=aes` 时走安全模式）
    /// 4. 解析 XML
    /// 5. 调用 handler 获取回复
    /// 6. 构造响应 XML（安全模式下加密返回）
    ///
    /// 返回的字符串直接写入 HTTP 响应 body，由调用方负责 `allocator.free`。
    pub fn serve(self: *Self, q: Query) ![]u8 {
        // 1. 验证签名
        if (!try self.validateURL(q)) return error.SignatureMismatch;

        // 2. URL 握手（GET 请求带 echostr）
        if (q.echostr.len > 0) {
            return self.allocator.dupe(u8, q.echostr);
        }

        const safe_mode = std.mem.eql(u8, q.encrypt_type, "aes");

        // 3 + 4. 解析消息（明文 / 安全模式）。
        // 注意：inbound 的生命周期必须覆盖整个 serve —— msg 内的切片借用其内部
        // doc 存储，提前 deinit 会造成 UAF。
        var inbound_storage: ?InboundMessage = null;
        defer if (inbound_storage) |*ib| ib.deinit();
        var msg_storage: message.MixMessage = undefined;
        if (safe_mode) {
            inbound_storage = try self.parseEncryptedMessage(q, q.openid);
            msg_storage = mixMessageFromDoc(&inbound_storage.?.doc);
        } else {
            var doc = try util_xml.parse(self.allocator, self.raw_body);
            defer doc.deinit();
            msg_storage = mixMessageFromDoc(&doc);
        }
        const msg = &msg_storage;

        // 5. 调用 handler
        const handler = self.handler orelse {
            // 没有 handler：返回 "success"
            return self.allocator.dupe(u8, "success");
        };
        const reply_opt = try handler(self.handler_ctx orelse @ptrCast(@constCast(&self)), msg);
        const reply = reply_opt orelse {
            return self.allocator.dupe(u8, "success");
        };

        // 6. 构造响应 XML（安全模式加密返回）
        const reply_xml = try reply.format(self.allocator, msg.common.from_user_name, msg.common.to_user_name);
        defer self.allocator.free(reply_xml);
        if (safe_mode) {
            const ts = std.fmt.parseInt(i64, q.timestamp, 10) catch 0;
            return self.encryptXml(reply_xml, ts, q.nonce);
        }
        return self.allocator.dupe(u8, reply_xml);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────────────────────────────────────

const aes_key = "0123456789abcdef0123456789abcdef"; // 32 字节测试 key

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

// —— 安全模式（encrypt_type=aes）回归测试 ——

/// 构造一段加密消息 body（与微信安全模式格式一致），返回 body 与 msg_signature。
fn buildEncryptedBody(
    allocator: std.mem.Allocator,
    token: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    app_id: []const u8,
    key: []const u8,
    inner_xml: []const u8,
) !struct { body: []u8, msg_sig: []u8 } {
    var random: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&random);
    const cipher = try util_crypto.aesEncryptMsg(allocator, &random, inner_xml, app_id, key);
    defer allocator.free(cipher);

    const b64_len = std.base64.standard.Encoder.calcSize(cipher.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, cipher);

    const body = try std.fmt.allocPrint(allocator, "<xml><Encrypt><![CDATA[{s}]]></Encrypt></xml>", .{b64});
    const msg_sig = try util_sig.signature(allocator, &[_][]const u8{ token, timestamp, nonce, b64 });
    return .{ .body = body, .msg_sig = msg_sig };
}

fn safeCtx(token: []const u8, app_id: []const u8) Context {
    return .{
        .config = .{
            .token = token,
            .app_id = app_id,
            .encoding_aes_key = aes_key,
        },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
}

test "parseEncryptedMessage 验签对象是 Encrypt 密文而非 body（回归）" {
    const allocator = std.testing.allocator;
    const token = "tok-enc";
    const app_id = "wx-enc-app";
    const timestamp = "1700000000";
    const nonce = "n-enc";
    const inner_xml = "<xml><ToUserName><![CDATA[gh_x]]></ToUserName><Content><![CDATA[secret hi]]></Content></xml>";

    const built = try buildEncryptedBody(allocator, token, timestamp, nonce, app_id, aes_key, inner_xml);
    defer allocator.free(built.body);
    defer allocator.free(built.msg_sig);

    var ctx = safeCtx(token, app_id);
    var s = Server.init(&ctx, allocator);
    s.setRawBody(built.body);

    var inbound = try s.parseEncryptedMessage(.{
        .timestamp = timestamp,
        .nonce = nonce,
        .msg_signature = built.msg_sig,
    }, "openid-1");
    defer inbound.deinit();

    try std.testing.expectEqualStrings("secret hi", inbound.get("Content").?);
    try std.testing.expectEqualStrings("openid-1", inbound.open_id);
    try std.testing.expectEqual(@as(i64, 1700000000), inbound.timestamp);
    try std.testing.expectEqualStrings(nonce, inbound.nonce);
}

test "parseEncryptedMessage msg_signature 不匹配返回 SignatureMismatch" {
    const allocator = std.testing.allocator;
    const inner_xml = "<xml><Content><![CDATA[x]]></Content></xml>";
    const built = try buildEncryptedBody(allocator, "tok-enc", "1700000000", "n-enc", "wx-enc-app", aes_key, inner_xml);
    defer allocator.free(built.body);
    defer allocator.free(built.msg_sig);

    var ctx = safeCtx("tok-enc", "wx-enc-app");
    var s = Server.init(&ctx, allocator);
    s.setRawBody(built.body);

    // 用错误的 msg_signature 必须失败（若仍按整个 body 签名则旧实现行为不同）。
    try std.testing.expectError(error.SignatureMismatch, s.parseEncryptedMessage(.{
        .timestamp = "1700000000",
        .nonce = "n-enc",
        .msg_signature = "deadbeef",
    }, ""));
}

test "parseEncryptedMessage AppID 不匹配返回 AppIDMismatch" {
    const allocator = std.testing.allocator;
    const inner_xml = "<xml><Content><![CDATA[x]]></Content></xml>";
    // 用另一个 app_id 加密
    const built = try buildEncryptedBody(allocator, "tok-enc", "1700000000", "n-enc", "wx-other-app", aes_key, inner_xml);
    defer allocator.free(built.body);
    defer allocator.free(built.msg_sig);

    var ctx = safeCtx("tok-enc", "wx-enc-app");
    var s = Server.init(&ctx, allocator);
    s.setRawBody(built.body);

    try std.testing.expectError(error.AppIDMismatch, s.parseEncryptedMessage(.{
        .timestamp = "1700000000",
        .nonce = "n-enc",
        .msg_signature = built.msg_sig,
    }, ""));
}

test "buildEncryptedReply 输出可解密的合法加密包（回归：base64 编码曾是潜在编译错误）" {
    const allocator = std.testing.allocator;
    const token = "tok-reply";
    const app_id = "wx-reply-app";
    var ctx = safeCtx(token, app_id);
    var s = Server.init(&ctx, allocator);

    // 注意：入参保持短小的原因是 util.crypto.encodeNetworkByteOrder 目前对
    // >255 字节的明文会 @intCast panic（属 util 域已知问题，超出本任务范围），
    // 这里只验证加密包结构与往返正确性。
    const body = try s.buildEncryptedReply("t", "f", "hi", 1700000000, "nonce-r");
    defer allocator.free(body);

    // 解析响应包。
    var doc = try util_xml.parse(allocator, body);
    defer doc.deinit();
    const encrypt_b64 = doc.get("Encrypt") orelse return error.TestUnexpectedResult;
    const msg_sig = doc.get("MsgSignature") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1700000000", doc.get("TimeStamp").?);
    try std.testing.expectEqualStrings("nonce-r", doc.get("Nonce").?);

    // 验签：SHA1(sort([token, timestamp, nonce, encrypt_b64]))。
    const expected_sig = try util_sig.signature(allocator, &[_][]const u8{ token, "1700000000", "nonce-r", encrypt_b64 });
    defer allocator.free(expected_sig);
    try std.testing.expectEqualStrings(expected_sig, msg_sig);

    // 解密并校验明文内容（先 base64 解码出原始密文）。
    const cipher_len = try std.base64.standard.Decoder.calcSizeForSlice(encrypt_b64);
    const cipher = try allocator.alloc(u8, cipher_len);
    defer allocator.free(cipher);
    try std.base64.standard.Decoder.decode(cipher, encrypt_b64);
    const decoded = try util_crypto.aesDecryptMsg(allocator, cipher, aes_key);
    defer allocator.free(decoded.random);
    defer allocator.free(decoded.raw_xml_msg);
    defer allocator.free(decoded.app_id);
    try std.testing.expectEqualStrings(app_id, decoded.app_id);
    try std.testing.expect(std.mem.indexOf(u8, decoded.raw_xml_msg, "<![CDATA[hi]]>") != null);
}

test "serve 安全模式端到端：解密入站消息并加密回复" {
    const allocator = std.testing.allocator;
    const token = "tok-serve-enc";
    const app_id = "wx-serve-enc";
    const timestamp = "1700000000";
    const nonce = "nonce-se";
    const inner_xml =
        "<xml><ToUserName><![CDATA[gh_s]]></ToUserName><FromUserName><![CDATA[user-se]]></FromUserName><CreateTime>1700000000</CreateTime><MsgType><![CDATA[text]]></MsgType><Content><![CDATA[加密你好]]></Content></xml>"
    ;

    const built = try buildEncryptedBody(allocator, token, timestamp, nonce, app_id, aes_key, inner_xml);
    defer allocator.free(built.body);
    defer allocator.free(built.msg_sig);

    var ctx = safeCtx(token, app_id);
    var s = Server.init(&ctx, allocator);
    s.setRawBody(built.body);
    s.setMessageHandler(struct {
        fn h(_: *anyopaque, msg: *message.MixMessage) anyerror!?message.Reply {
            if (msg.content.len == 0) return null;
            return .{ .msg_type = .text, .data = .{ .text = .{ .content = msg.content } } };
        }
    }.h, null);

    // URL 签名（对整个 URL 的 signature 参数）。
    const url_sig = try util_sig.signature(allocator, &[_][]const u8{ token, timestamp, nonce });
    defer allocator.free(url_sig);

    const q = Query{
        .signature = url_sig,
        .timestamp = timestamp,
        .nonce = nonce,
        .encrypt_type = "aes",
        .openid = "user-se",
        .msg_signature = built.msg_sig,
    };
    const response = try s.serve(q);
    defer allocator.free(response);

    // 响应是加密包：解密后应包含回显内容。
    var doc = try util_xml.parse(allocator, response);
    defer doc.deinit();
    const encrypt_b64 = doc.get("Encrypt") orelse return error.TestUnexpectedResult;
    const cipher_len = try std.base64.standard.Decoder.calcSizeForSlice(encrypt_b64);
    const cipher = try allocator.alloc(u8, cipher_len);
    defer allocator.free(cipher);
    try std.base64.standard.Decoder.decode(cipher, encrypt_b64);
    const decoded = try util_crypto.aesDecryptMsg(allocator, cipher, aes_key);
    defer allocator.free(decoded.random);
    defer allocator.free(decoded.raw_xml_msg);
    defer allocator.free(decoded.app_id);
    try std.testing.expect(std.mem.indexOf(u8, decoded.raw_xml_msg, "<![CDATA[加密你好]]>") != null);
}

test "serve 安全模式 msg_signature 错误返回 SignatureMismatch" {
    const allocator = std.testing.allocator;
    const inner_xml = "<xml><Content><![CDATA[x]]></Content></xml>";
    const built = try buildEncryptedBody(allocator, "tok-enc", "1700000000", "n-enc", "wx-enc-app", aes_key, inner_xml);
    defer allocator.free(built.body);
    defer allocator.free(built.msg_sig);

    var ctx = safeCtx("tok-enc", "wx-enc-app");
    var s = Server.init(&ctx, allocator);
    s.setRawBody(built.body);

    const url_sig = try util_sig.signature(allocator, &[_][]const u8{ "tok-enc", "1700000000", "n-enc" });
    defer allocator.free(url_sig);

    try std.testing.expectError(error.SignatureMismatch, s.serve(.{
        .signature = url_sig,
        .timestamp = "1700000000",
        .nonce = "n-enc",
        .encrypt_type = "aes",
        .msg_signature = "wrong-sig",
    }));
}

test "parsePlainMessage dupe raw_xml（调用方仍持有 raw_body 所有权）" {
    const allocator = std.testing.allocator;
    var ctx: Context = .{
        .config = .{ .token = "t" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var s = Server.init(&ctx, allocator);

    const raw = try allocator.dupe(u8, "<xml><Content><![CDATA[owned by caller]]></Content></xml>");
    defer allocator.free(raw); // 调用方释放自己的 buffer；InboundMessage 释放自己的副本。
    s.setRawBody(raw);

    var inbound = try s.parsePlainMessage("oid");
    defer inbound.deinit();
    try std.testing.expectEqualStrings("owned by caller", inbound.get("Content").?);
}
