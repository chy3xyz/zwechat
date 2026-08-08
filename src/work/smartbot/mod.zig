//! work/smartbot — 企业微信"智能机器人" callback handler
//!
//! 对应 `silenceper/wechat` Go 版的 `work/robot/smartbot.go`（如果存在），
//! 或 `_ref/wechat/officialaccount/server/server.go`（最接近的参考）。
//!
//! 企业微信"智能机器人"是一种特殊的 application：
//! - 注册为"智能机器人"类型后，会获得一个 callback URL
//! - 用户 @机器人 发消息时，WeCom 把加密的 XML POST 到该 URL
//! - 加密算法与微信公众号完全相同：AES-256-CBC + SHA-1 签名
//!
//! 与 officialaccount/server 的区别：
//! 1. WeCom 的 token/EncodingAESKey 来自 corp 应用配置（不是 OA app）
//! 2. WeCom 的 ToUserName 是 corp_id，FromUserName 是 userid
//! 3. WeCom 的 reply 字段是 markdown（不是纯 text）— 但 XML 结构相同
//! 4. URL 握手（echostr）是 GET，明文返回 echostr
//! 5. 实际消息是 POST，body 是加密 XML，需解密后处理
//!
//! 使用：
//!   var server = smartbot.Server.init(&work_ctx, allocator);
//!   server.setMessageHandler(my_handler, my_ctx);
//!   server.setRawBody(request_body);
//!   if (try server.validateURL(query)) { return server.echostr(); }
//!   const inbound = try server.parseEncryptedMessage(query, corp_id);
//!   defer inbound.deinit();
//!   // ... call handler ...

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_crypto = @import("../../util/crypto.zig");
const util_sig = @import("../../util/signature.zig");
const util_xml = @import("../../util/xml.zig");
const util_util = @import("../../util/util.zig");
const util_time = @import("../../util/time.zig");

/// MessageHandler: callback for received messages. Returns null to skip
/// (in plain-text mode, the WeCom platform will receive "success").
pub const MessageHandler = *const fn (ctx: *anyopaque, msg: *InboundMessage) anyerror!?Reply;

/// HTTP query parameter set (URL 握手 / encrypted message share the same shape).
pub const Query = struct {
    msg_signature: []const u8 = "",
    timestamp: []const u8 = "",
    nonce: []const u8 = "",
    echostr: []const u8 = "",
};

/// Decrypted + parsed inbound message.
pub const InboundMessage = struct {
    allocator: std.mem.Allocator,
    raw_xml: []u8,
    doc: util_xml.XmlDoc,
    /// Sender's wecom userid (FromUserName).
    from_user: []const u8 = "",
    /// corp_id (ToUserName).
    corp_id: []const u8 = "",
    /// Message create time (epoch seconds).
    create_time: i64 = 0,
    /// Nonce from URL.
    nonce: []const u8 = "",
    /// MsgType: "text", "markdown", "image", "event", etc.
    msg_type: []const u8 = "",
    /// Content for text/markdown messages.
    content: []const u8 = "",

    pub fn deinit(self: *InboundMessage) void {
        self.allocator.free(self.raw_xml);
        self.doc.deinit();
    }

    /// Get any field by key (e.g. "FromUserName", "Content", "Event").
    pub fn get(self: InboundMessage, key: []const u8) ?[]const u8 {
        return self.doc.get(key);
    }
};

/// Reply payload: returned by MessageHandler. WeCom's smart bot accepts
/// markdown (rendered as a card) or text.
pub const Reply = struct {
    msg_type: []const u8, // "markdown" | "text"
    content: []const u8,
};

/// Smart bot server.
pub const Server = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    raw_body: []u8 = &.{},

    /// User-registered message handler.
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

    pub fn setRawBody(self: *Self, body: []u8) void {
        self.raw_body = body;
    }

    /// Compute the signature that the server should send back. We use this to
    /// verify msg_signature (POST) and echostr (GET).
    pub fn computeSignature(self: *Self, items: []const []const u8) ![]u8 {
        return util_sig.signature(self.allocator, items);
    }

    /// Validate the msg_signature on a POST request.
    /// WeCom's signature is SHA1(sort([token, timestamp, nonce, encrypt])).
    pub fn validateMessageSignature(self: *Self, q: Query) !bool {
        // Extract Encrypt from body
        const doc = try util_xml.parse(self.allocator, self.raw_body);
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

    /// Validate the signature on a GET URL-handshake request.
    /// WeCom's signature is SHA1(sort([token, timestamp, nonce, echostr])).
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

    /// Process an encrypted message: validate signature, AES-decrypt, parse XML.
    pub fn parseEncryptedMessage(self: *Self, q: Query) !InboundMessage {
        // 1) Verify signature
        if (!try self.validateMessageSignature(q)) return error.SignatureMismatch;

        // 2) Pull Encrypt field from body
        const doc = try util_xml.parse(self.allocator, self.raw_body);
        defer doc.deinit();
        const encrypted_b64 = doc.get("Encrypt") orelse return error.MissingEncrypt;

        // 3) AES decrypt
        const decoded = try util_crypto.aesDecryptMsg(self.allocator, encrypted_b64, self.ctx.config.encoding_aes_key);
        defer self.allocator.free(decoded.random);
        defer self.allocator.free(decoded.raw_xml_msg);
        defer self.allocator.free(decoded.app_id);

        // 4) Verify corp_id matches (decode.app_id carries it in WeCom)
        // Note: in WeCom's smart bot, the app_id field of the AES envelope
        // actually holds the corp_id.
        if (!std.mem.eql(u8, decoded.app_id, self.ctx.config.corp_id)) return error.CorpIDMismatch;

        // 5) Parse inner XML
        const inner_doc = try util_xml.parse(self.allocator, decoded.raw_xml_msg);
        const raw_xml_dup = try self.allocator.dupe(u8, decoded.raw_xml_msg);

        // 6) Pull standard fields
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

    /// Build the reply XML body (plain text — for unauthenticated mode,
    /// or as the inner XML before encryption).
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

    /// Build the encrypted reply XML for safe-mode transport.
    /// This is the function that callers (HTTP server) use to construct the
    /// HTTP response body.
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

        // 16-byte random IV (required for AES-CBC PKCS#7 padding in the spec)
        var random: [16]u8 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            random[i] = std.crypto.random.intRangeAtMost(u8, 0, 255);
        }

        // AES encrypt
        const cipher = try util_crypto.aesEncryptMsg(
            self.allocator,
            &random,
            reply_xml,
            self.ctx.config.corp_id,
            self.ctx.config.encoding_aes_key,
        );
        defer self.allocator.free(cipher);

        const cipher_b64 = std.base64.standard.encodes(cipher);
        const ts_str = try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
        defer self.allocator.free(ts_str);

        // Compute signature
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

    /// High-level: handle an inbound request. Returns the response XML body
    /// (or null if no response — caller should return "success" string).
    pub fn serve(self: *Self, q: Query, is_post: bool) !?[]u8 {
        if (!is_post) {
            // GET: URL handshake. Validate signature; on success, return echostr plain text.
            if (!try self.validateUrlSignature(q)) return null;
            // Return echostr as raw string (not XML-wrapped — WeCom expects plain text)
            return try self.allocator.dupe(u8, q.echostr);
        }

        // POST: encrypted message
        const inbound = try self.parseEncryptedMessage(q);
        defer @constCast(&inbound).deinit();

        if (self.handler) |handler| {
            if (try handler(self.handler_ctx orelse undefined, &inbound)) |reply| {
                // Build encrypted reply
                return try self.buildEncryptedReply(
                    inbound.from_user, // reply ToUserName is the original sender
                    inbound.corp_id, // reply FromUserName is the corp_id
                    reply.msg_type,
                    reply.content,
                    inbound.create_time,
                    inbound.nonce,
                );
            }
        }
        return null;
    }
};

test "smartbot module: Server public surface" {
    // Compile-time contract
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
