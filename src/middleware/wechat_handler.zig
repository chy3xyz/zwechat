//! middleware/wechat_handler — 微信回调服务中间件
//!
//! 专为 `zfinal` / `zigmodu` 等 Web 框架及标准 HTTP Handler 设计：
//! 1. 签名校验 (`verifyServerSignature`)：校验微信服务器推送的 URL 请求合法性。
//! 2. 消息解密处理 (`handleServerMessage`)：解密 AES 密文并提取用户 raw XML。

const std = @import("std");
const signature = @import("../util/signature.zig");
const crypto = @import("../util/crypto.zig");

pub const CallbackQuery = struct {
    signature: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    echostr: []const u8 = "",
};

/// 验证微信服务器发送的签名是否匹配
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

/// 微信加密消息解密结果
pub const DecryptedMessage = struct {
    random: []u8,
    raw_xml: []u8,
    app_id: []u8,

    pub fn deinit(self: *DecryptedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.random);
        allocator.free(self.raw_xml);
        allocator.free(self.app_id);
    }
};

/// 尝试解密服务器推送的加密消息 XML
pub fn handleServerMessage(
    allocator: std.mem.Allocator,
    encoding_aes_key: []const u8,
    encrypted_xml: []const u8,
) !DecryptedMessage {
    if (encoding_aes_key.len < 32) return error.InvalidArgument;
    const res = try crypto.aesDecryptMsg(allocator, encrypted_xml, encoding_aes_key[0..32]);
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
