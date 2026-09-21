// SPDX-License-Identifier: Apache-2.0
//! work/smartbot — 企业微信「智能机器人」回调处理
//!
//! 企业微信「智能机器人」是一种特殊的应用：
//! - 注册为「智能机器人」类型后，会获得一个 callback URL；
//! - 用户 @机器人 发消息时，企业微信把加密的 XML POST 到该 URL；
//! - 加密算法与微信公众号服务端完全相同：AES-256-CBC + SHA-1 签名，
//!   `EncodingAESKey` 为 43 字符 base64（见 `work/server.decodeAesKey`）。
//!
//! 与 officialaccount/server 的区别：
//! 1. 企业微信的 token / EncodingAESKey 来自企业应用配置（不是公众号 app）；
//! 2. 企业微信消息的 ToUserName 是 corp_id，FromUserName 是 userid；
//! 3. 智能机器人的回复内容是 markdown（不是纯文本），但 XML 结构相同；
//! 4. URL 握手（echostr）是 GET，校验通过后明文返回 echostr；
//! 5. 实际消息是 POST，body 是加密 XML，需解密后处理。
//!
//! 使用：
//! ```zig
//! var server = smartbot.Server.init(&work_ctx, allocator);
//! server.setMessageHandler(my_handler, my_ctx);
//! server.setRawBody(request_body);
//! if (try server.validateUrlSignature(query)) {
//!     return try allocator.dupe(u8, query.echostr); // GET 握手：明文返回 echostr
//! }
//! const inbound = try server.parseEncryptedMessage(query);
//! defer inbound.deinit();
//! // ... 调用 handler 处理 ...
//! ```

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const work_server = @import("../server/mod.zig");
const util_crypto = @import("../../util/crypto.zig");
const util_sig = @import("../../util/signature.zig");
const util_xml = @import("../../util/xml.zig");
const util_time = @import("../../util/time.zig");

/// 消息处理器：处理收到的消息；返回 null 表示不回复
/// （明文模式下企业微信平台会收到 "success"）。
pub const MessageHandler = *const fn (ctx: *anyopaque, msg: *InboundMessage) anyerror!?Reply;

/// HTTP query 参数集合（URL 握手 / 加密消息共用同一形状）。
pub const Query = struct {
    msg_signature: []const u8 = "",
    timestamp: []const u8 = "",
    nonce: []const u8 = "",
    echostr: []const u8 = "",
};

/// 解密并解析后的入站消息。
///
/// `deinit` 释放 `raw_xml` 与内部 XML 文档；`from_user` / `corp_id` /
/// `msg_type` / `content` / `nonce` 均为借用切片，随 `deinit` 失效。
pub const InboundMessage = struct {
    allocator: std.mem.Allocator,
    raw_xml: []u8,
    doc: util_xml.XmlDoc,
    /// 发送者的企业微信 userid（FromUserName）。
    from_user: []const u8 = "",
    /// corp_id（ToUserName）。
    corp_id: []const u8 = "",
    /// 消息创建时间（Unix 秒）。
    create_time: i64 = 0,
    /// URL 上的 nonce。
    nonce: []const u8 = "",
    /// MsgType："text" / "markdown" / "image" / "event" 等。
    msg_type: []const u8 = "",
    /// text / markdown 消息的正文。
    content: []const u8 = "",

    pub fn deinit(self: *InboundMessage) void {
        self.allocator.free(self.raw_xml);
        self.doc.deinit();
    }

    /// 按 key 取任意字段（如 "FromUserName" / "Content" / "Event"）。
    pub fn get(self: InboundMessage, key: []const u8) ?[]const u8 {
        return self.doc.get(key);
    }
};

/// 回复载荷：由 MessageHandler 返回；智能机器人接受 markdown（渲染为卡片）或 text。
pub const Reply = struct {
    msg_type: []const u8, // "markdown" | "text"
    content: []const u8,
};

/// 智能机器人回调服务。
pub const Server = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    raw_body: []u8 = &.{},

    /// 用户注册的消息处理器。
    handler: ?MessageHandler = null,
    handler_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    pub fn setMessageHandler(self: *Self, handler: MessageHandler, ctx: ?*anyopaque) void {
        self.handler = handler;
        self.handler_ctx = ctx;
    }

    /// 设置原始请求体（加密 XML 文本）；生命周期由调用方保证。
    pub fn setRawBody(self: *Self, body: []u8) void {
        self.raw_body = body;
    }

    /// 计算 SHA1 签名（与 `util.signature.signature` 一致，暴露给调用方做调试用）。
    pub fn computeSignature(self: *Self, items: []const []const u8) ![]u8 {
        return util_sig.signature(self.allocator, items);
    }

    /// 校验 POST 请求的 msg_signature。
    /// 企业微信签名 = SHA1(字典序排序([token, timestamp, nonce, encrypt]))。
    pub fn validateMessageSignature(self: *Self, q: Query) !bool {
        var doc = try util_xml.parse(self.allocator, self.raw_body);
        defer doc.deinit();
        const encrypted = doc.get("Encrypt") orelse return false;
        const sig = try util_sig.signature(self.allocator, &[_][]const u8{
            self.ctx.config.token,
            q.timestamp,
            q.nonce,
            encrypted,
        });
        defer self.allocator.free(sig);
        return std.mem.eql(u8, sig, q.msg_signature);
    }

    /// 校验 GET URL 握手的 msg_signature。
    /// 企业微信签名 = SHA1(字典序排序([token, timestamp, nonce, echostr]))。
    pub fn validateUrlSignature(self: *Self, q: Query) !bool {
        const sig = try util_sig.signature(self.allocator, &[_][]const u8{
            self.ctx.config.token,
            q.timestamp,
            q.nonce,
            q.echostr,
        });
        defer self.allocator.free(sig);
        return std.mem.eql(u8, sig, q.msg_signature);
    }

    /// 处理加密消息：验签 → AES 解密 → 解析内部 XML。
    ///
    /// `config.encoding_aes_key` 是 43 字符 base64 的 EncodingAESKey（自动解码）；
    /// `raw_body` 必须是包含 `<Encrypt>` 节点的加密 XML。
    ///
    /// 返回的 `InboundMessage` 由调用方负责 `deinit`。
    pub fn parseEncryptedMessage(self: *Self, q: Query) !InboundMessage {
        // 1) 验签
        if (!try self.validateMessageSignature(q)) return error.SignatureMismatch;

        // 2) 从 body 中取 Encrypt 字段（base64 文本）
        var doc = try util_xml.parse(self.allocator, self.raw_body);
        defer doc.deinit();
        const encrypted_b64 = doc.get("Encrypt") orelse return error.MissingEncrypt;

        const cipher_len = std.base64.standard.Decoder.calcSizeForSlice(encrypted_b64) catch
            return error.InvalidArgument;
        const cipher = try self.allocator.alloc(u8, cipher_len);
        defer self.allocator.free(cipher);
        std.base64.standard.Decoder.decode(cipher, encrypted_b64) catch
            return error.InvalidArgument;

        // 3) AES 解密（key 从 EncodingAESKey base64 解码而来）
        const key = try work_server.decodeAesKey(self.ctx.config.encoding_aes_key);
        const decoded = try util_crypto.aesDecryptMsg(self.allocator, cipher, &key);
        defer self.allocator.free(decoded.random);
        defer self.allocator.free(decoded.raw_xml_msg);
        defer self.allocator.free(decoded.app_id);

        // 4) 校验 ReceiveID 与 corp_id 一致
        // 注意：企业微信 AES 信封的 app_id 字段实际存放的是 corp_id。
        if (!std.mem.eql(u8, decoded.app_id, self.ctx.config.corp_id)) return error.CorpIDMismatch;

        // 5) 解析内部 XML；doc 必须基于持久副本 raw_xml_dup 解析，
        //    否则 elements 指向 decoded.raw_xml_msg（函数返回前被释放）造成 UAF。
        const raw_xml_dup = try self.allocator.dupe(u8, decoded.raw_xml_msg);
        const inner_doc = try util_xml.parse(self.allocator, raw_xml_dup);

        // 6) 提取标准字段
        const from_user = inner_doc.get("FromUserName") orelse "";
        const corp_id = inner_doc.get("ToUserName") orelse "";
        const create_time_str = inner_doc.get("CreateTime") orelse "0";
        const msg_type = inner_doc.get("MsgType") orelse "text";
        const content = inner_doc.get("Content") orelse "";

        return .{
            .allocator = self.allocator,
            .raw_xml = raw_xml_dup,
            .doc = inner_doc,
            .from_user = from_user,
            .corp_id = corp_id,
            .create_time = std.fmt.parseInt(i64, create_time_str, 10) catch 0,
            .nonce = q.nonce,
            .msg_type = msg_type,
            .content = content,
        };
    }

    /// 构造明文回复 XML（用于不加密模式，或作为加密前的内部 XML）。
    pub fn buildReplyXml(self: *Self, to_user: []const u8, from_user: []const u8, msg_type: []const u8, content: []const u8) ![]u8 {
        const ts_str = try std.fmt.allocPrint(self.allocator, "{d}", .{util_time.getCurrTS()});
        defer self.allocator.free(ts_str);

        var elements = [_]util_xml.XmlElement{
            .{ .key = "ToUserName", .value = to_user },
            .{ .key = "FromUserName", .value = from_user },
            .{ .key = "CreateTime", .value = ts_str },
            .{ .key = "MsgType", .value = msg_type },
            .{ .key = "Content", .value = content },
        };
        return util_xml.serialize(self.allocator, "xml", &elements);
    }

    /// 构造加密回复 XML（安全模式）。
    /// 这是 HTTP server 构造响应 body 时使用的函数。
    ///
    /// 返回的 XML 文本由调用方负责 `free`。
    pub fn buildEncryptedReply(
        self: *Self,
        to_user: []const u8,
        from_user: []const u8,
        msg_type: []const u8,
        content: []const u8,
        timestamp: i64,
        nonce: []const u8,
    ) ![]u8 {
        const reply_xml = try self.buildReplyXml(to_user, from_user, msg_type, content);
        defer self.allocator.free(reply_xml);

        // 16 字节随机 IV（AES-CBC PKCS#7 填充所需）
        var random: [16]u8 = undefined;
        std.Io.Threaded.global_single_threaded.io().random(&random);

        // AES 加密（key 从 EncodingAESKey base64 解码而来）
        const key = try work_server.decodeAesKey(self.ctx.config.encoding_aes_key);
        const cipher = try util_crypto.aesEncryptMsg(
            self.allocator,
            &random,
            reply_xml,
            self.ctx.config.corp_id,
            &key,
        );
        defer self.allocator.free(cipher);

        const b64_len = std.base64.standard.Encoder.calcSize(cipher.len);
        const cipher_b64 = try self.allocator.alloc(u8, b64_len);
        defer self.allocator.free(cipher_b64);
        _ = std.base64.standard.Encoder.encode(cipher_b64, cipher);

        const ts_str = try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
        defer self.allocator.free(ts_str);

        // 计算签名
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

    /// 高层入口：处理一次回调请求。
    ///
    /// 返回响应 XML body；返回 null 表示无需响应（调用方应回 "success"）。
    /// `is_post = false` 时为 GET URL 握手：验签通过则明文返回 echostr。
    ///
    /// 返回的非空切片由调用方负责 `free`。
    pub fn serve(self: *Self, q: Query, is_post: bool) !?[]u8 {
        if (!is_post) {
            // GET：URL 握手。验签通过后明文返回 echostr（不是 XML 包装）。
            if (!try self.validateUrlSignature(q)) return null;
            return try self.allocator.dupe(u8, q.echostr);
        }

        // POST：加密消息
        var inbound = try self.parseEncryptedMessage(q);
        defer inbound.deinit();

        if (self.handler) |handler| {
            if (try handler(self.handler_ctx orelse undefined, &inbound)) |reply| {
                // 与 Go 参考（officialaccount server）一致：回复时间戳取当前时间。
                const reply_ts = util_time.getCurrTS();
                return try self.buildEncryptedReply(
                    inbound.from_user, // 回复的 ToUserName 是原始发送者
                    inbound.corp_id, // 回复的 FromUserName 是 corp_id
                    reply.msg_type,
                    reply.content,
                    reply_ts,
                    inbound.nonce,
                );
            }
        }
        return null;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const test_aes_key = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY"; // 43 字符 base64
const test_raw_key = "0123456789abcdef0123456789abcdef"; // 解码后的 32 字节原始 key
const test_corp_id = "ww1234567890abcdef";
const test_token = "smartbot_token";

fn makeTestCtx() Context {
    return .{
        .config = .{
            .corp_id = test_corp_id,
            .token = test_token,
            .encoding_aes_key = test_aes_key,
        },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
}

/// 构造一段加密回调 body：内部 XML → AES 加密 → base64 → 包上 <xml><Encrypt>。
fn makeEncryptedBody(
    allocator: std.mem.Allocator,
    inner_xml: []const u8,
) ![]u8 {
    const cipher = try util_crypto.aesEncryptMsg(allocator, "0123456789abcdef", inner_xml, test_corp_id, test_raw_key);
    defer allocator.free(cipher);
    const b64_len = std.base64.standard.Encoder.calcSize(cipher.len);
    const cipher_b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(cipher_b64);
    _ = std.base64.standard.Encoder.encode(cipher_b64, cipher);
    return std.fmt.allocPrint(allocator, "<xml><Encrypt>{s}</Encrypt></xml>", .{cipher_b64});
}

test "smartbot module: Server public surface" {
    // 编译期契约
    try std.testing.expect(@hasDecl(Server, "init"));
    try std.testing.expect(@hasDecl(Server, "setMessageHandler"));
    try std.testing.expect(@hasDecl(Server, "setRawBody"));
    try std.testing.expect(@hasDecl(Server, "computeSignature"));
    try std.testing.expect(@hasDecl(Server, "validateMessageSignature"));
    try std.testing.expect(@hasDecl(Server, "validateUrlSignature"));
    try std.testing.expect(@hasDecl(Server, "parseEncryptedMessage"));
    try std.testing.expect(@hasDecl(Server, "buildReplyXml"));
    try std.testing.expect(@hasDecl(Server, "buildEncryptedReply"));
    try std.testing.expect(@hasDecl(Server, "serve"));
}

test "smartbot module: InboundMessage has the expected fields" {
    const T = InboundMessage;
    try std.testing.expect(@hasField(T, "from_user"));
    try std.testing.expect(@hasField(T, "corp_id"));
    try std.testing.expect(@hasField(T, "msg_type"));
    try std.testing.expect(@hasField(T, "content"));
    try std.testing.expect(@hasField(T, "create_time"));
    try std.testing.expect(@hasField(T, "nonce"));
}

test "smartbot module: Query struct has the 4 expected fields" {
    const T = Query;
    try std.testing.expect(@hasField(T, "msg_signature"));
    try std.testing.expect(@hasField(T, "timestamp"));
    try std.testing.expect(@hasField(T, "nonce"));
    try std.testing.expect(@hasField(T, "echostr"));
}

test "smartbot module: Reply has the 2 expected fields" {
    const T = Reply;
    try std.testing.expect(@hasField(T, "msg_type"));
    try std.testing.expect(@hasField(T, "content"));
}

test "smartbot validateUrlSignature 正确校验 GET 握手" {
    const allocator = std.testing.allocator;
    var ctx = makeTestCtx();
    var server = Server.init(&ctx, allocator);

    const q = Query{
        .timestamp = "1721641869",
        .nonce = "239847192",
        .echostr = "echostr_abc",
    };
    const sig = try server.computeSignature(&[_][]const u8{ test_token, q.timestamp, q.nonce, q.echostr });
    defer allocator.free(sig);

    var good = q;
    good.msg_signature = sig;
    try std.testing.expect(try server.validateUrlSignature(good));

    var bad = q;
    bad.msg_signature = "0000000000000000000000000000000000000000";
    try std.testing.expect(!(try server.validateUrlSignature(bad)));
}

test "smartbot parseEncryptedMessage 解密并解析字段（43 字符 EncodingAESKey 全链路）" {
    const allocator = std.testing.allocator;
    var ctx = makeTestCtx();
    var server = Server.init(&ctx, allocator);

    const inner_xml = "<xml><ToUserName>ww1234567890abcdef</ToUserName><FromUserName>zhangsan</FromUserName><CreateTime>1721641900</CreateTime><MsgType>markdown</MsgType><Content>hello &lt;b&gt;bot&lt;/b&gt;</Content></xml>";
    const body = try makeEncryptedBody(allocator, inner_xml);
    defer allocator.free(body);
    server.setRawBody(body);

    const q = Query{
        .timestamp = "1721641900",
        .nonce = "nonce_123",
    };
    var outer_doc = try util_xml.parse(allocator, body);
    defer outer_doc.deinit();
    const encrypt_field = outer_doc.get("Encrypt").?;
    const sig = try server.computeSignature(&[_][]const u8{ test_token, q.timestamp, q.nonce, encrypt_field });
    defer allocator.free(sig);

    var good = q;
    good.msg_signature = sig;

    var inbound = try server.parseEncryptedMessage(good);
    defer inbound.deinit();

    try std.testing.expectEqualStrings("zhangsan", inbound.from_user);
    try std.testing.expectEqualStrings(test_corp_id, inbound.corp_id);
    try std.testing.expectEqualStrings("markdown", inbound.msg_type);
    // 注意：仓库的 XML 解析器不做实体解码，`&lt;` 原样保留在 content 中。
    try std.testing.expectEqualStrings("hello &lt;b&gt;bot&lt;/b&gt;", inbound.content);
    try std.testing.expectEqual(@as(i64, 1721641900), inbound.create_time);
    try std.testing.expectEqualStrings("nonce_123", inbound.nonce);
}

test "smartbot parseEncryptedMessage 签名错误返回 SignatureMismatch" {
    const allocator = std.testing.allocator;
    var ctx = makeTestCtx();
    var server = Server.init(&ctx, allocator);

    const body = try makeEncryptedBody(allocator, "<xml><MsgType>text</MsgType></xml>");
    defer allocator.free(body);
    server.setRawBody(body);

    const bad = Query{
        .msg_signature = "0000000000000000000000000000000000000000",
        .timestamp = "1",
        .nonce = "n",
    };
    const result = server.parseEncryptedMessage(bad);
    try std.testing.expectError(error.SignatureMismatch, result);
}

test "smartbot buildEncryptedReply 加密回复可被解密回原文" {
    const allocator = std.testing.allocator;
    var ctx = makeTestCtx();
    var server = Server.init(&ctx, allocator);

    const reply = try server.buildEncryptedReply("zhangsan", test_corp_id, "markdown", "收到 **收到**", 1721642000, "nonce_x");
    defer allocator.free(reply);

    // 解析外层 XML，验签并解密。
    var doc = try util_xml.parse(allocator, reply);
    defer doc.deinit();
    const encrypt_b64 = doc.get("Encrypt").?;
    const msg_sig = doc.get("MsgSignature").?;
    const ts = doc.get("TimeStamp").?;
    const nonce = doc.get("Nonce").?;
    try std.testing.expectEqualStrings("1721642000", ts);
    try std.testing.expectEqualStrings("nonce_x", nonce);

    // 签名 = SHA1(sort([token, timestamp, nonce, encrypt_b64]))。
    const expect_sig = try server.computeSignature(&[_][]const u8{ test_token, ts, nonce, encrypt_b64 });
    defer allocator.free(expect_sig);
    try std.testing.expectEqualStrings(expect_sig, msg_sig);

    // 解密并校验内容。
    const cipher_len = try std.base64.standard.Decoder.calcSizeForSlice(encrypt_b64);
    const cipher = try allocator.alloc(u8, cipher_len);
    defer allocator.free(cipher);
    try std.base64.standard.Decoder.decode(cipher, encrypt_b64);
    const key = try work_server.decodeAesKey(test_aes_key);
    const dec = try util_crypto.aesDecryptMsg(allocator, cipher, &key);
    defer allocator.free(dec.random);
    defer allocator.free(dec.raw_xml_msg);
    defer allocator.free(dec.app_id);
    try std.testing.expectEqualStrings(test_corp_id, dec.app_id);
    try std.testing.expect(std.mem.indexOf(u8, dec.raw_xml_msg, "收到 **收到**") != null);
}

const ServeHandlerState = struct {
    called: bool = false,
};

fn serveTestHandler(state_ptr: *anyopaque, msg: *InboundMessage) anyerror!?Reply {
    const state: *ServeHandlerState = @ptrCast(@alignCast(state_ptr));
    state.called = true;
    try std.testing.expectEqualStrings("text", msg.msg_type);
    return .{ .msg_type = "text", .content = "pong" };
}

test "smartbot serve POST 全流程：解密 → handler → 加密回复可再解密" {
    const allocator = std.testing.allocator;
    var ctx = makeTestCtx();
    var server = Server.init(&ctx, allocator);

    var handler_state = ServeHandlerState{};
    server.setMessageHandler(serveTestHandler, &handler_state);

    const inner_xml = "<xml><ToUserName>ww1234567890abcdef</ToUserName><FromUserName>lisi</FromUserName><CreateTime>1721641800</CreateTime><MsgType>text</MsgType><Content>ping</Content></xml>";
    const body = try makeEncryptedBody(allocator, inner_xml);
    defer allocator.free(body);
    server.setRawBody(body);

    const q = Query{
        .timestamp = "1721641800",
        .nonce = "nonce_srv",
    };
    var doc = try util_xml.parse(allocator, body);
    defer doc.deinit();
    const encrypt_b64 = doc.get("Encrypt").?;
    const sig = try server.computeSignature(&[_][]const u8{ test_token, q.timestamp, q.nonce, encrypt_b64 });
    defer allocator.free(sig);

    var good = q;
    good.msg_signature = sig;

    const reply_opt = try server.serve(good, true);    const reply = reply_opt orelse return error.TestUnexpectedResult;
    defer allocator.free(reply);
    try std.testing.expect(handler_state.called);

    // 回复可解析、验签、解密。
    var rdoc = try util_xml.parse(allocator, reply);
    defer rdoc.deinit();
    const r_encrypt = rdoc.get("Encrypt").?;
    const r_sig = rdoc.get("MsgSignature").?;
    const r_ts = rdoc.get("TimeStamp").?;
    const r_nonce = rdoc.get("Nonce").?;
    const expect_sig = try server.computeSignature(&[_][]const u8{ test_token, r_ts, r_nonce, r_encrypt });
    defer allocator.free(expect_sig);
    try std.testing.expectEqualStrings(expect_sig, r_sig);

    const cipher_len = try std.base64.standard.Decoder.calcSizeForSlice(r_encrypt);
    const cipher = try allocator.alloc(u8, cipher_len);
    defer allocator.free(cipher);
    try std.base64.standard.Decoder.decode(cipher, r_encrypt);
    const key = try work_server.decodeAesKey(test_aes_key);
    const dec = try util_crypto.aesDecryptMsg(allocator, cipher, &key);
    defer allocator.free(dec.random);
    defer allocator.free(dec.raw_xml_msg);
    defer allocator.free(dec.app_id);
    try std.testing.expect(std.mem.indexOf(u8, dec.raw_xml_msg, "pong") != null);
    // 回复方向：ToUserName 是发送者 lisi，FromUserName 是 corp_id。
    // serialize 用 CDATA 包裹值。
    try std.testing.expect(std.mem.indexOf(u8, dec.raw_xml_msg, "<ToUserName><![CDATA[lisi]]></ToUserName>") != null);
    try std.testing.expect(std.mem.indexOf(u8, dec.raw_xml_msg, "<FromUserName><![CDATA[ww1234567890abcdef]]></FromUserName>") != null);
}

test "smartbot serve GET 握手验签通过返回 echostr 明文" {
    const allocator = std.testing.allocator;
    var ctx = makeTestCtx();
    var server = Server.init(&ctx, allocator);

    const q = Query{
        .timestamp = "1721641869",
        .nonce = "239847192",
        .echostr = "plain_echostr_value",
    };
    const sig = try server.computeSignature(&[_][]const u8{ test_token, q.timestamp, q.nonce, q.echostr });
    defer allocator.free(sig);

    var good = q;
    good.msg_signature = sig;
    const resp = (try server.serve(good, false)).?;
    defer allocator.free(resp);
    try std.testing.expectEqualStrings("plain_echostr_value", resp);

    // 验签失败返回 null。
    var bad = q;
    bad.msg_signature = "0000000000000000000000000000000000000000";
    try std.testing.expect((try server.serve(bad, false)) == null);
}
