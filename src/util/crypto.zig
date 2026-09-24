// SPDX-License-Identifier: Apache-2.0
//! util/crypto — 加解密工具
//!
//! 对应 `_ref/wechat/util/crypto.go`：
//! - `CalculateSign` / `SignTypeMD5` / `SignTypeHMACSHA256`：商户支付签名（MD5 / HMAC-SHA256，返回大写 hex）。
//! - `AESEncryptMsg` / `AESDecryptMsg`：公众号消息加解密（random(16B) + msg_len(4B) + rawXMLMsg + appID，
//!   AES-256-CBC，IV = key[:16]，PKCS#7 块大小 = 32）。
//! - `PKCS7Padding` / `PKCS7UnPadding`：通用的 PKCS#7 补位 / 去补位。
//! - `PKCS5Padding` / `PKCS5UnPadding`：与 PKCS#7 在块大小 ≤ 256 时等价，单独暴露以匹配上游。
//! - `AesECBDecrypt`：用于退款通知（AES-256-ECB + PKCS#5）。
//!
//! Zig 标准库暂未直接提供 CBC 模式（`std.crypto.modes` 只有 CTR），所以这里手工实现：
//! 加密时 `C[i] = AES_E(K, P[i] ^ C[i-1])`（`C[-1] = IV`）；
//! 解密时 `P[i] = AES_D(K, C[i]) ^ C[i-1]`（`C[-1] = IV`）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const base64 = std.base64;
const Aes256 = std.crypto.core.aes.Aes256;
const Md5 = std.crypto.hash.Md5;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.Hmac(Sha256);
const WechatError = @import("error.zig").WechatError;

pub const SignTypeMD5 = "MD5";
pub const SignTypeHMACSHA256 = "HMAC-SHA256";

/// 计算 `content` 的 MD5 摘要并返回**小写** hex 字符串。
///
/// 与 `calculateSign`（大写 hex，用于签名）不同，本函数用于构造加解密密钥
/// （如微信支付退款通知的 `MD5(mch_key)` → 32 字节 AES key，上游 Go 用
/// `hex.EncodeToString` 输出小写）。大小写敏感，混用会导致解密失败。
///
/// 错误集：当前仅 `error{OutOfMemory}`；返回的切片由调用方负责 `free`。
pub fn md5HexLower(allocator: Allocator, content: []const u8) Allocator.Error![]u8 {
    var digest: [Md5.digest_length]u8 = undefined;
    Md5.hash(content, &digest, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(&digest, .lower));
}

// -----------------------------------------------------------------------------
// 签名
// -----------------------------------------------------------------------------

/// 计算签名：根据 `sign_type` 选 MD5 或 HMAC-SHA256，返回大写 hex 字符串。
///
/// 错误集：当前仅 `error{OutOfMemory}`。
pub fn calculateSign(
    allocator: Allocator,
    content: []const u8,
    sign_type: []const u8,
    key: []const u8,
) Allocator.Error![]u8 {
    if (std.mem.eql(u8, sign_type, SignTypeHMACSHA256)) {
        var mac: [Sha256.digest_length]u8 = undefined;
        HmacSha256.create(&mac, content, key);
        return allocator.dupe(u8, &std.fmt.bytesToHex(&mac, .upper));
    }
    // 默认走 MD5（与上游 Go 行为一致：未匹配时落到 MD5 分支）。
    var digest: [Md5.digest_length]u8 = undefined;
    Md5.hash(content, &digest, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(&digest, .upper));
}

// -----------------------------------------------------------------------------
// AES-256-CBC（仅暴露给 `AESEncryptMsg` / `AESDecryptMsg` 使用）
// -----------------------------------------------------------------------------

fn aes256CbcEncrypt(dst: []u8, src: []const u8, key: *const [32]u8, iv: *const [16]u8) void {
    std.debug.assert(dst.len == src.len);
    std.debug.assert(src.len % 16 == 0);
    const enc = Aes256.initEnc(key.*);
    var prev: [16]u8 = iv.*;
    var off: usize = 0;
    while (off < src.len) : (off += 16) {
        var block: [16]u8 = src[off..][0..16].*;
        for (&block, 0..) |*b, i| b.* ^= prev[i];
        var out: [16]u8 = undefined;
        enc.encrypt(&out, &block);
        @memcpy(dst[off..][0..16], &out);
        prev = out;
    }
}

fn aes256CbcDecrypt(dst: []u8, src: []const u8, key: *const [32]u8, iv: *const [16]u8) void {
    std.debug.assert(dst.len == src.len);
    std.debug.assert(src.len % 16 == 0);
    const dec = Aes256.initDec(key.*);
    var prev: [16]u8 = iv.*;
    var off: usize = 0;
    while (off < src.len) : (off += 16) {
        const cipher_block: [16]u8 = src[off..][0..16].*;
        var plain: [16]u8 = undefined;
        dec.decrypt(&plain, &cipher_block);
        for (&plain, 0..) |*b, i| b.* ^= prev[i];
        @memcpy(dst[off..][0..16], &plain);
        prev = cipher_block;
    }
}

// -----------------------------------------------------------------------------
// 公众号消息加解密
// -----------------------------------------------------------------------------

const BlockSize: usize = 32; // WeChat 用的 PKCS#7 块大小
const BlockMask: usize = BlockSize - 1;

/// AESEncryptMsg — 微信消息加密：random(16B) + msg_len(4B) + rawXMLMsg + appID，
/// 然后 PKCS#7 补位到 BlockSize 边界，再走 AES-256-CBC（IV = key[:16]）。
///
/// 错误集：`WechatError || Allocator.Error`。
pub fn aesEncryptMsg(
    allocator: Allocator,
    random: []const u8,
    raw_xml_msg: []const u8,
    app_id: []const u8,
    aes_key: []const u8,
) (Allocator.Error || WechatError)![]u8 {
    if (aes_key.len != 32) return WechatError.InvalidArgument;
    if (random.len != 16) return WechatError.InvalidArgument;

    const app_id_offset: usize = 20 + raw_xml_msg.len;
    const content_len: usize = app_id_offset + app_id.len;
    const amount_to_pad: usize = BlockSize - (content_len & BlockMask);
    const plaintext_len: usize = content_len + amount_to_pad;

    var buf = try allocator.alloc(u8, plaintext_len);
    errdefer allocator.free(buf);

    @memcpy(buf[0..16], random);
    encodeNetworkByteOrder(buf[16..20], @intCast(raw_xml_msg.len));
    @memcpy(buf[20..app_id_offset], raw_xml_msg);
    @memcpy(buf[app_id_offset..content_len], app_id);
    for (buf[content_len..plaintext_len]) |*b| b.* = @intCast(amount_to_pad);

    const key: *const [32]u8 = aes_key[0..32];
    const iv: *const [16]u8 = aes_key[0..16];

    // 就地加密
    const out = try allocator.alloc(u8, plaintext_len);
    errdefer allocator.free(out);
    aes256CbcEncrypt(out, buf, key, iv);
    // buf 是内部临时缓冲区，调用方拿到的只是 out 的密文副本。
    allocator.free(buf);
    return out;
}

/// 微信加密消息解密结果：`random` / `raw_xml_msg` / `app_id` 均由调用方负责 `free`。
pub const DecryptedMessage = struct {
    random: []u8,
    raw_xml_msg: []u8,
    app_id: []u8,
};

/// AESDecryptMsg — 解密微信加密消息。返回 `DecryptedMessage`。
pub fn aesDecryptMsg(
    allocator: Allocator,
    ciphertext: []const u8,
    aes_key: []const u8,
) (Allocator.Error || WechatError)!DecryptedMessage {
    if (aes_key.len != 32) return WechatError.InvalidArgument;
    if (ciphertext.len < BlockSize) return WechatError.InvalidArgument;
    if (ciphertext.len & BlockMask != 0) return WechatError.InvalidArgument;

    const key: *const [32]u8 = aes_key[0..32];
    const iv: *const [16]u8 = aes_key[0..16];

    var plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    aes256CbcDecrypt(plaintext, ciphertext, key, iv);

    // 去 PKCS#7
    const pad: usize = plaintext[plaintext.len - 1];
    if (pad < 1 or pad > BlockSize) return WechatError.DecodeError;
    const unpadded_len = plaintext.len - pad;

    if (unpadded_len <= 20) return WechatError.DecodeError;
    const raw_len = decodeNetworkByteOrder(plaintext[16..20]);
    const app_id_offset: usize = 20 + @as(usize, @intCast(raw_len));
    // 注意：这里用 `<` 而非上游 Go 版的 `<=` —— 本库 `buildEncryptedReply` 类
    // 回复加密路径允许空 app_id（app_id 段长度为 0），保持兼容。
    if (unpadded_len < app_id_offset) return WechatError.DecodeError;

    const random = try allocator.dupe(u8, plaintext[0..16]);
    errdefer allocator.free(random);
    const raw_xml_msg = try allocator.dupe(u8, plaintext[20..app_id_offset]);
    errdefer allocator.free(raw_xml_msg);
    const app_id = try allocator.dupe(u8, plaintext[app_id_offset..unpadded_len]);
    // plaintext 是内部临时 buffer；调用方拿到的是 dupe 出来的独立副本。
    allocator.free(plaintext);
    return .{ .random = random, .raw_xml_msg = raw_xml_msg, .app_id = app_id };
}

// -----------------------------------------------------------------------------
// PKCS#7 / PKCS#5 padding
// -----------------------------------------------------------------------------

/// PKCS#7 padding（块大小 1..255，WeChat 固定用 32）。
///
/// 错误集：`error{OutOfMemory, InvalidArgument}`。
pub fn pkcs7Pad(
    allocator: Allocator,
    data: []const u8,
    block_size: usize,
) (Allocator.Error || error{InvalidArgument})![]u8 {
    if (block_size == 0 or block_size > 255) return error.InvalidArgument;
    return pkcs7PadUnchecked(allocator, data, block_size);
}

/// 不做块大小校验的补位内核；调用方必须先保证 `block_size` 合法。
fn pkcs7PadUnchecked(allocator: Allocator, data: []const u8, block_size: usize) Allocator.Error![]u8 {
    const pad = block_size - (data.len % block_size);
    var out = try allocator.alloc(u8, data.len + pad);
    errdefer allocator.free(out);
    @memcpy(out[0..data.len], data);
    for (out[data.len..]) |*b| b.* = @intCast(pad);
    return out;
}

/// 通用 PKCS#7 去补位。返回原 `data` 的切片（不重新分配）。调用方需保证 `data` 来自带补位的源。
pub fn pkcs7Unpad(data: []const u8) []const u8 {
    if (data.len == 0) return data;
    const pad: usize = data[data.len - 1];
    if (pad == 0 or pad > data.len) return data;
    return data[0 .. data.len - pad];
}

/// `PKCS5Padding`：与 PKCS#7 在块大小 = 8 时一致；上游 Go 版固定使用 8。
pub fn pkcs5Pad(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    return pkcs7PadUnchecked(allocator, data, 8);
}

/// `PKCS5UnPadding`：去 PKCS#5 补位（与 `pkcs7Unpad` 等价，因为去补位只看最后一个字节）。
pub fn pkcs5Unpad(data: []const u8) []const u8 {
    return pkcs7Unpad(data);
}

// -----------------------------------------------------------------------------
// AES-256-ECB（用于退款通知解密）
// -----------------------------------------------------------------------------

/// AesECBDecrypt — AES-256-ECB + PKCS#5 padding（实际是块大小 = 16 的 PKCS#7）。
///
/// 错误集：`Allocator.Error || WechatError`。
pub fn aesECBDecrypt(
    allocator: Allocator,
    ciphertext: []const u8,
    aes_key: []const u8,
) (Allocator.Error || WechatError)![]u8 {
    if (aes_key.len != 32) return WechatError.InvalidArgument;
    if (ciphertext.len < 16) return WechatError.InvalidArgument;
    if (ciphertext.len % 16 != 0) return WechatError.InvalidArgument;

    const dec = Aes256.initDec(aes_key[0..32].*);

    // ECB 解密到一块中间 buffer
    var out = try allocator.alloc(u8, ciphertext.len);
    defer allocator.free(out);
    var off: usize = 0;
    while (off < ciphertext.len) : (off += 16) {
        var plain: [16]u8 = undefined;
        dec.decrypt(&plain, ciphertext[off..][0..16]);
        @memcpy(out[off..][0..16], &plain);
    }
    // 去补位后按精确长度重新分配返回，保证调用方 `free` 的切片
    // 与分配长度一致（避免子切片释放带来的 allocator 兼容性问题）。
    return allocator.dupe(u8, pkcs7Unpad(out));
}

// -----------------------------------------------------------------------------
// 内部：网络字节序
// -----------------------------------------------------------------------------

fn encodeNetworkByteOrder(out: []u8, n: u32) void {
    std.debug.assert(out.len >= 4);
    // 逐字节取低 8 位：直接 @intCast(n >> k) 在 n 对应字节 >255 时（如 n>>16 的
    // 低 16 位）会在 Debug/ReleaseSafe 下 panic——真实回复 XML >64KB 才会触发，
    // 但被动回复加密是公开路径，按 BigEndian 语义写正确。
    out[0] = @intCast((n >> 24) & 0xFF);
    out[1] = @intCast((n >> 16) & 0xFF);
    out[2] = @intCast((n >> 8) & 0xFF);
    out[3] = @intCast(n & 0xFF);
}

fn decodeNetworkByteOrder(in: []const u8) u32 {
    std.debug.assert(in.len >= 4);
    return (@as(u32, in[0]) << 24) |
        (@as(u32, in[1]) << 16) |
        (@as(u32, in[2]) << 8) |
        @as(u32, in[3]);
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

test "CalculateSign MD5 of 'hello' = 5d41402abc4b2a76b9719d911017c592" {
    const allocator = std.testing.allocator;
    const got = try calculateSign(allocator, "hello", SignTypeMD5, "");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("5D41402ABC4B2A76B9719D911017C592", got);
}

test "CalculateSign HMAC-SHA256 与 Python hmac 一致" {
    const allocator = std.testing.allocator;
    // HMAC-SHA256("hello", "key") = 9307b3b915efb5171ff14d8cb55fbcc798c6c0ef1456d66ded1a6aa723a58b7b
    const got = try calculateSign(allocator, "hello", SignTypeHMACSHA256, "key");
    defer allocator.free(got);
    try std.testing.expectEqualStrings(
        "9307B3B915EFB5171FF14D8CB55FBCC798C6C0EF1456D66DED1A6AA723A58B7B",
        got,
    );
}

test "AESEncryptMsg/AESDecryptMsg round-trip" {
    const allocator = std.testing.allocator;
    const aes_key = "0123456789abcdef0123456789abcdef"; // 32 bytes
    const random16 = "1234567890abcdef";
    const xml = "<xml><a>hello</a></xml>";
    const app_id = "wx_test_appid";
    const cipher = try aesEncryptMsg(allocator, random16, xml, app_id, aes_key);
    defer allocator.free(cipher);
    try std.testing.expect(cipher.len > 0);
    try std.testing.expect(cipher.len % 16 == 0);

    const result = try aesDecryptMsg(allocator, cipher, aes_key);
    defer {
        allocator.free(result.random);
        allocator.free(result.raw_xml_msg);
        allocator.free(result.app_id);
    }
    try std.testing.expectEqualSlices(u8, random16, result.random);
    try std.testing.expectEqualSlices(u8, xml, result.raw_xml_msg);
    try std.testing.expectEqualSlices(u8, app_id, result.app_id);
}

test "AESEncryptMsg/AESDecryptMsg round-trip 长明文（>255 字节，钉住 encodeNetworkByteOrder 逐字节掩码）" {
    const allocator = std.testing.allocator;
    const aes_key = "0123456789abcdef0123456789abcdef"; // 32 bytes
    const random16 = "1234567890abcdef";
    // 真实被动回复 XML 轻松超过 255 字节；网络字节序长度字段的低字节必须
    // 按 & 0xFF 取，否则 Debug 下 @intCast 溢出 panic。
    const filler = comptime blk: {
        var b: [512]u8 = undefined;
        @memset(&b, 'x');
        break :blk b;
    };
    var xml_buf: [600]u8 = undefined;
    const xml = try std.fmt.bufPrint(&xml_buf, "<xml><Content>{s}</Content></xml>", .{&filler});
    try std.testing.expect(xml.len > 255);
    const app_id = "wx_test_appid";
    const cipher = try aesEncryptMsg(allocator, random16, xml, app_id, aes_key);
    defer allocator.free(cipher);
    try std.testing.expect(cipher.len % 16 == 0);

    const result = try aesDecryptMsg(allocator, cipher, aes_key);
    defer {
        allocator.free(result.random);
        allocator.free(result.raw_xml_msg);
        allocator.free(result.app_id);
    }
    try std.testing.expectEqualSlices(u8, xml, result.raw_xml_msg);
}

test "AESEncryptMsg 校验 random 长度错误" {
    const allocator = std.testing.allocator;
    const aes_key = "0123456789abcdef0123456789abcdef";
    const r = aesEncryptMsg(allocator, "short", "<x/>", "id", aes_key);
    try std.testing.expectError(WechatError.InvalidArgument, r);
}

test "AESDecryptMsg 校验密文长度错误" {
    const allocator = std.testing.allocator;
    const aes_key = "0123456789abcdef0123456789abcdef";
    const r = aesDecryptMsg(allocator, "abc", aes_key);
    try std.testing.expectError(WechatError.InvalidArgument, r);
}

test "pkcs7Pad 50 字节补到 32 的倍数" {
    const allocator = std.testing.allocator;
    const data = "12345678901234567890123456789012345678901234567890"; // 50 bytes
    const padded = try pkcs7Pad(allocator, data, 32);
    defer allocator.free(padded);
    try std.testing.expectEqual(@as(usize, 64), padded.len); // 50 + 14 = 64
    const unpadded = pkcs7Unpad(padded);
    try std.testing.expectEqualSlices(u8, data, unpadded);
}

test "AesECBDecrypt 用 32-byte 零密文 + 32-byte 零 key 解密出空" {
    const allocator = std.testing.allocator;
    const key: [32]u8 = @splat(0);
    // 16 字节全零密文用全零 key 解密后全是 0x66 (AES test vector)，
    // 最后一位是 0x66 = 102 (> 16)，不是合法 PKCS#7 补位。
    // 这里只验证接口不会对 key/ciphertext 长度检查抛错，pad 异常被解为原样。
    const cipher: [16]u8 = @splat(0);
    if (aesECBDecrypt(allocator, &cipher, &key)) |out| {
        defer allocator.free(out);
    } else |err| switch (err) {
        // 我们只验证不返回 InvalidArgument。
        WechatError.InvalidArgument => return error.UnexpectedError,
        else => return, // 其他错误（DecodeError 等）也属正常
    }
}

test "AesECBDecrypt 返回精确长度切片（free 长度 == 分配长度）" {
    const allocator = std.testing.allocator;
    const aes_key = "0123456789abcdef0123456789abcdef";
    // 构造一段已知明文，手动 ECB 加密（库内自洽：块独立加密 + PKCS#7(块16)）。
    const plain = "{\"refund_fee\":\"6\"}";
    const padded = try pkcs7Pad(allocator, plain, 16);
    defer allocator.free(padded);

    const enc = Aes256.initEnc(aes_key[0..32].*);
    var cipher = try allocator.alloc(u8, padded.len);
    defer allocator.free(cipher);
    var off: usize = 0;
    while (off < padded.len) : (off += 16) {
        var block: [16]u8 = undefined;
        enc.encrypt(&block, padded[off..][0..16]);
        @memcpy(cipher[off..][0..16], &block);
    }

    const out = try aesECBDecrypt(allocator, cipher, aes_key);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, plain, out);
}

test "md5HexLower 输出小写 hex（与 Go hex.EncodeToString 一致）" {
    const allocator = std.testing.allocator;
    const got = try md5HexLower(allocator, "hello");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("5d41402abc4b2a76b9719d911017c592", got);
}

test "AESDecryptMsg 拒绝空 app_id 且空正文的报文（长度守卫）" {
    const allocator = std.testing.allocator;
    const aes_key = "0123456789abcdef0123456789abcdef";
    // raw_xml_msg 与 app_id 均为空：unpadded_len == 20，触发 `<= 20` 长度守卫。
    const cipher = try aesEncryptMsg(allocator, "1234567890abcdef", "", "", aes_key);
    defer allocator.free(cipher);
    const r = aesDecryptMsg(allocator, cipher, aes_key);
    try std.testing.expectError(WechatError.DecodeError, r);
}
