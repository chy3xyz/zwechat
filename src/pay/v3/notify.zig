// SPDX-License-Identifier: Apache-2.0
//! pay/v3/notify — 微信支付 v3 通知回调解密 (AES-256-GCM)
//!
//! 微信支付 v3 异步通知 (支付成功/退款等) 报文在 `resource` 中使用 AEAD_AES_256_GCM 加密。
//! 本模块使用 Zig 原生 `std.crypto.aead.aes_gcm.Aes256Gcm` 提供纯 Zig、零 C 依赖解密能力。

const std = @import("std");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const NotifyResource = struct {
    algorithm: []const u8 = "AEAD_AES_256_GCM",
    ciphertext: []const u8,
    associated_data: []const u8 = "",
    nonce: []const u8,
};

pub const NotifyResponseBody = struct {
    id: []const u8 = "",
    create_time: []const u8 = "",
    resource_type: []const u8 = "",
    event_type: []const u8 = "",
    summary: []const u8 = "",
    resource: NotifyResource,
};

/// 使用 APIv3 密钥解密 v3 通知里的 AES-256-GCM 密文资源
///
/// `api_v3_key`: 必须是 32 字节密钥
/// `ciphertext_b64`: base64 编码的密文（末尾包含 16 字节 Auth Tag）
/// `associated_data`: 关联附加数据 (aad)
/// `nonce`: 12 字节向量字符串
///
/// 返回堆分配的解密后明文 JSON 字节切片（由调用方负责 `allocator.free`）
pub fn decryptNotifyResource(
    allocator: std.mem.Allocator,
    api_v3_key: []const u8,
    ciphertext_b64: []const u8,
    associated_data: []const u8,
    nonce: []const u8,
) ![]u8 {
    if (api_v3_key.len != 32) return error.InvalidKeyLength;
    if (nonce.len != 12) return error.InvalidNonceLength;

    const key: [32]u8 = api_v3_key[0..32].*;
    const nonce_bytes: [12]u8 = nonce[0..12].*;

    // 1. Base64 解码密文
    const decoder = std.base64.standard.Decoder;
    const cipher_len = try decoder.calcSizeForSlice(ciphertext_b64);
    if (cipher_len < 16) return error.InvalidCiphertext;

    const cipher_bytes = try allocator.alloc(u8, cipher_len);
    defer allocator.free(cipher_bytes);
    try decoder.decode(cipher_bytes, ciphertext_b64);

    // 末尾 16 字节为 Tag，前面部分为密文
    const text_len = cipher_len - 16;
    const tag: [16]u8 = cipher_bytes[text_len..][0..16].*;
    const cipher_data = cipher_bytes[0..text_len];

    // 2. 分配明文缓冲区
    const plain_buf = try allocator.alloc(u8, text_len);
    errdefer allocator.free(plain_buf);

    // 3. Aes256Gcm 解密
    Aes256Gcm.decrypt(
        plain_buf,
        cipher_data,
        tag,
        associated_data,
        nonce_bytes,
        key,
    ) catch return error.DecryptFailed;

    return plain_buf;
}

test "decryptNotifyResource AES-256-GCM 加解密往返" {
    const allocator = std.testing.allocator;
    const api_v3_key = "12345678901234567890123456789012"; // 32 bytes
    const nonce = "123456789012"; // 12 bytes
    const aad = "transaction";
    const plain_text = "{\"mchid\":\"1900000109\",\"out_trade_no\":\"20260722001\",\"trade_state\":\"SUCCESS\"}";

    // 先用 Aes256Gcm 加密
    const key_bytes: [32]u8 = api_v3_key[0..32].*;
    const nonce_bytes: [12]u8 = nonce[0..12].*;
    const cipher_buf = try allocator.alloc(u8, plain_text.len);
    defer allocator.free(cipher_buf);
    var tag: [16]u8 = undefined;

    Aes256Gcm.encrypt(cipher_buf, &tag, plain_text, aad, nonce_bytes, key_bytes);

    // 拼接密文 + Tag 并 base64
    var full_cipher = try allocator.alloc(u8, plain_text.len + 16);
    defer allocator.free(full_cipher);
    @memcpy(full_cipher[0..plain_text.len], cipher_buf);
    @memcpy(full_cipher[plain_text.len..], &tag);

    const encoder = std.base64.standard.Encoder;
    const b64_buf = try allocator.alloc(u8, encoder.calcSize(full_cipher.len));
    defer allocator.free(b64_buf);
    _ = encoder.encode(b64_buf, full_cipher);

    // 调用 decryptNotifyResource 解密
    const decrypted = try decryptNotifyResource(allocator, api_v3_key, b64_buf, aad, nonce);
    defer allocator.free(decrypted);

    try std.testing.expectEqualStrings(plain_text, decrypted);
}
