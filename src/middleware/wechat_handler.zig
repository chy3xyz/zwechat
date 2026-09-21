// SPDX-License-Identifier: Apache-2.0
//! middleware/wechat_handler — 微信回调服务中间件
//!
//! 专为 `zfinal` / `zigmodu` 等 Web 框架及标准 HTTP Handler 设计：
//! 1. URL 参数解析 (`parseCallbackQuery`)：把 `signature=...&timestamp=...&nonce=...`
//!    形式的 raw query string 解析为 `CallbackQuery`。
//! 2. 签名校验 (`verifyServerSignature` / `verifyURL`)：校验微信服务器推送的
//!    URL 请求合法性；`verifyURL` 在通过时返回应回显的 `echostr`。
//! 3. 消息解密处理 (`handleServerMessage`)：AES 解密并校验 AppID，
//!    提取用户 raw XML。

const std = @import("std");
const signature = @import("../util/signature.zig");
const crypto = @import("../util/crypto.zig");

/// 微信回调 URL 的 query 参数集合。
///
/// 各字段切片默认借用外部缓冲区（由调用方保证生命周期）；
/// 经 `parseCallbackQuery` 解析时借用传入的 `query_string`。
pub const CallbackQuery = struct {
    /// 微信服务器计算的 SHA1 签名（小写 hex）。
    signature: []const u8,
    /// 时间戳（秒）。
    timestamp: []const u8,
    /// 随机串。
    nonce: []const u8,
    /// URL 验证阶段的回显串；消息推送阶段为空。
    echostr: []const u8 = "",
};

/// 把 `a=b&c=d` 形式的 raw query string 解析为 `CallbackQuery`。
///
/// - 值按原样切片（**不做** percent-decoding，微信回调的 signature/timestamp/nonce
///   均为 hex / 数字，不会包含编码字符；echostr 如被框架预解码也请原样传入）。
/// - 缺少 `signature` / `timestamp` / `nonce` 任一字段时返回 `error.InvalidArgument`；
///   `echostr` 可缺省（默认为空切片）。
pub fn parseCallbackQuery(query_string: []const u8) !CallbackQuery {
    var q = CallbackQuery{
        .signature = "",
        .timestamp = "",
        .nonce = "",
    };
    var it = std.mem.splitScalar(u8, query_string, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "signature")) {
            q.signature = value;
        } else if (std.mem.eql(u8, key, "timestamp")) {
            q.timestamp = value;
        } else if (std.mem.eql(u8, key, "nonce")) {
            q.nonce = value;
        } else if (std.mem.eql(u8, key, "echostr")) {
            q.echostr = value;
        }
    }
    if (q.signature.len == 0 or q.timestamp.len == 0 or q.nonce.len == 0) {
        return error.InvalidArgument;
    }
    return q;
}

/// 验证微信服务器发送的 URL 签名是否匹配。
///
/// 公式：SHA1(sort([token, timestamp, nonce])) 的小写 hex 与 `query.signature` 比较。
/// 纯计算函数，不发生内存分配失败以外的错误；签名不匹配返回 `false`。
pub fn verifyServerSignature(
    allocator: std.mem.Allocator,
    token: []const u8,
    query: CallbackQuery,
) bool {
    const params = [_][]const u8{ token, query.timestamp, query.nonce };
    const computed = signature.signature(allocator, &params) catch return false;
    defer allocator.free(computed);
    return std.mem.eql(u8, computed, query.signature);
}

/// URL 验证（GET 握手）便捷入口。
///
/// 签名合法时返回应原样回显给微信服务器的 `echostr`（借用 `query` 内的切片），
/// 签名非法返回 `null`。`echostr` 为空时通过校验返回空切片。
pub fn verifyURL(
    allocator: std.mem.Allocator,
    token: []const u8,
    query: CallbackQuery,
) ?[]const u8 {
    if (!verifyServerSignature(allocator, token, query)) return null;
    return query.echostr;
}

/// 微信加密消息解密结果。
///
/// 三个字段均为 `allocator` 独立分配的切片，由 `DecryptedMessage.deinit` 统一释放；
/// 调用方不得单独 `free` 某个字段。
pub const DecryptedMessage = struct {
    /// 消息头 16 字节随机数。
    random: []u8,
    /// 解密后的用户消息明文 XML。
    raw_xml: []u8,
    /// 消息尾部携带的 AppID（已校验与 `expected_app_id` 一致）。
    app_id: []u8,

    pub fn deinit(self: *DecryptedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.random);
        allocator.free(self.raw_xml);
        allocator.free(self.app_id);
    }
};

/// 解密微信服务器推送的安全模式消息（`<Encrypt>` 节点的 base64 密文）。
///
/// - `aes_key`：32 字节原始 AES key（即 Config 中的 `encoding_aes_key`，
///   **不是** 43 字符的 base64 EncodingAESKey；长度不为 32 返回 `error.InvalidArgument`）。
/// - `expected_app_id`：预期的接收方 AppID；解密出的 AppID 与其不一致时返回
///   `error.AppIDMismatch`（防跨账号伪造消息）。
///
/// 返回值三个字段由 `allocator` 分配，调用方负责调用 `deinit` 释放。
pub fn handleServerMessage(
    allocator: std.mem.Allocator,
    aes_key: []const u8,
    expected_app_id: []const u8,
    encrypted_xml: []const u8,
) !DecryptedMessage {
    if (aes_key.len != 32) return error.InvalidArgument;
    const res = try crypto.aesDecryptMsg(allocator, encrypted_xml, aes_key);
    errdefer allocator.free(res.random);
    errdefer allocator.free(res.raw_xml_msg);
    errdefer allocator.free(res.app_id);
    if (!std.mem.eql(u8, res.app_id, expected_app_id)) return error.AppIDMismatch;
    return .{
        .random = res.random,
        .raw_xml = res.raw_xml_msg,
        .app_id = res.app_id,
    };
}

test "verifyServerSignature 正确校验匹配签名" {
    const allocator = std.testing.allocator;
    const token = "my_token_secret";
    const ts = "1721641869";
    const nonce = "239847192";

    const params = [_][]const u8{ token, ts, nonce };
    const sig = try signature.signature(allocator, &params);
    defer allocator.free(sig);

    const query = CallbackQuery{
        .signature = sig,
        .timestamp = ts,
        .nonce = nonce,
    };

    try std.testing.expect(verifyServerSignature(allocator, token, query));
}

test "verifyServerSignature 拒绝篡改的签名 / 错误的 token" {
    const allocator = std.testing.allocator;
    const token = "tok-reject";
    const ts = "1721641869";
    const nonce = "239847192";

    const params = [_][]const u8{ token, ts, nonce };
    const sig = try signature.signature(allocator, &params);
    defer allocator.free(sig);

    // 1. 签名被篡改（改一位）
    var tampered_buf: [64]u8 = undefined;
    @memcpy(tampered_buf[0..sig.len], sig);
    tampered_buf[0] = if (sig[0] == 'a') 'b' else 'a';
    const tampered = tampered_buf[0..sig.len];

    try std.testing.expect(!verifyServerSignature(allocator, token, .{
        .signature = tampered,
        .timestamp = ts,
        .nonce = nonce,
    }));

    // 2. token 不匹配
    try std.testing.expect(!verifyServerSignature(allocator, "wrong-token", .{
        .signature = sig,
        .timestamp = ts,
        .nonce = nonce,
    }));

    // 3. nonce 被替换
    try std.testing.expect(!verifyServerSignature(allocator, token, .{
        .signature = sig,
        .timestamp = ts,
        .nonce = "other-nonce",
    }));
}

test "parseCallbackQuery 解析完整 query string" {
    const q = try parseCallbackQuery("signature=abc123&timestamp=1721641869&nonce=239847192&echostr=hello-echo");
    try std.testing.expectEqualStrings("abc123", q.signature);
    try std.testing.expectEqualStrings("1721641869", q.timestamp);
    try std.testing.expectEqualStrings("239847192", q.nonce);
    try std.testing.expectEqualStrings("hello-echo", q.echostr);
}

test "parseCallbackQuery 缺省 echostr / 缺必填字段报错" {
    const q = try parseCallbackQuery("nonce=n1&signature=s1&timestamp=t1");
    try std.testing.expectEqualStrings("s1", q.signature);
    try std.testing.expectEqualStrings("", q.echostr);

    try std.testing.expectError(error.InvalidArgument, parseCallbackQuery("timestamp=t1&nonce=n1"));
    try std.testing.expectError(error.InvalidArgument, parseCallbackQuery("signature=s1&nonce=n1"));
    try std.testing.expectError(error.InvalidArgument, parseCallbackQuery("signature=s1&timestamp=t1"));
    try std.testing.expectError(error.InvalidArgument, parseCallbackQuery(""));
}

test "verifyURL 合法签名回显 echostr，非法返回 null" {
    const allocator = std.testing.allocator;
    const token = "tok-url";
    const ts = "1721641869";
    const nonce = "239847192";

    const params = [_][]const u8{ token, ts, nonce };
    const sig = try signature.signature(allocator, &params);
    defer allocator.free(sig);

    const ok_q = CallbackQuery{
        .signature = sig,
        .timestamp = ts,
        .nonce = nonce,
        .echostr = "echostr-abc",
    };
    try std.testing.expectEqualStrings("echostr-abc", verifyURL(allocator, token, ok_q).?);

    const bad_q = CallbackQuery{
        .signature = "deadbeef",
        .timestamp = ts,
        .nonce = nonce,
        .echostr = "echostr-abc",
    };
    try std.testing.expect(verifyURL(allocator, token, bad_q) == null);
}

test "handleServerMessage 解密并校验 AppID" {
    const allocator = std.testing.allocator;
    const aes_key = "0123456789abcdef0123456789abcdef"; // 32 字节原始 key
    const app_id = "wx1234567890abcdef";
    const raw_msg = "<xml><Content><![CDATA[hi]]></Content></xml>";

    const cipher = try crypto.aesEncryptMsg(allocator, "0123456789abcdef", raw_msg, app_id, aes_key);
    defer allocator.free(cipher);

    var decrypted = try handleServerMessage(allocator, aes_key, app_id, cipher);
    defer decrypted.deinit(allocator);
    try std.testing.expectEqualStrings(raw_msg, decrypted.raw_xml);
    try std.testing.expectEqualStrings(app_id, decrypted.app_id);
    try std.testing.expectEqualStrings("0123456789abcdef", decrypted.random);
}

test "handleServerMessage AppID 不匹配返回 AppIDMismatch 且无泄漏" {
    const allocator = std.testing.allocator;
    const aes_key = "0123456789abcdef0123456789abcdef";
    const cipher = try crypto.aesEncryptMsg(allocator, "0123456789abcdef", "<xml/>", "wx-real-app", aes_key);
    defer allocator.free(cipher);

    try std.testing.expectError(
        error.AppIDMismatch,
        handleServerMessage(allocator, aes_key, "wx-attacker-app", cipher),
    );
}

test "handleServerMessage 拒绝非 32 字节 key" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidArgument,
        handleServerMessage(allocator, "short-key", "wx-app", "whatever"),
    );
    // 43 字符 base64 EncodingAESKey 也必须显式解码为 32 字节后传入，不可直接截断
    try std.testing.expectError(
        error.InvalidArgument,
        handleServerMessage(allocator, "abcdefghijklmnopqrstuvwxyz01234567890123456", "wx-app", "whatever"),
    );
}
