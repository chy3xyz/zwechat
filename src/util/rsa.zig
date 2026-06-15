//! util/rsa — 签名 / 验签 + PKCS#12 工具
//!
//! 对应 `_ref/wechat/util/rsa.go`：RSA-SHA256 PKCS#1 v1.5 签名 + 验签。
//!
//! **Zig 0.17 现状**：标准库尚未提供 RSA 实现（参见
//! https://github.com/ziglang/zig/issues/14456），但 `std.crypto.sign.Ed25519` 已可用。
//! 因此本文件同时提供：
//!
//! 1. **RSA 接口**（`rsaSign` / `rsaVerify`）：保留签名，当前返回 `RsaNotImplemented`。
//!    生产路径：vendor 一个 ASN.1 / RSA 实现（推荐 Zig 社区的 `zig-crypto` 等三方包）。
//! 2. **Ed25519 实现**（`ed25519Sign` / `ed25519Verify`）：直接可用，Zig 0.17 原生支持。
//!    业务如可接受 Ed25519 替换 RSA，可立即启用。
//! 3. **PKCS#12**（`parseP12`）：返回 `P12NotImplemented`，需要 vendor ASN.1 解析器。

const std = @import("std");
const ed25519 = std.crypto.sign.Ed25519;

/// RSA 签名错误集。
pub const RsaError = error{
    RsaNotImplemented,
    InvalidPemKey,
    InvalidSignature,
};

/// RSA-SHA256 签名（PKCS#1 v1.5）。
///
/// **当前实现**：返回 `RsaNotImplemented`，因为 Zig 0.17 标准库没有 RSA。
/// 调用方应当在生产环境中 vendor 一个 RSA 实现，或改用 Ed25519。
pub fn rsaSign(allocator: std.mem.Allocator, content: []const u8, private_key_pem: []const u8) RsaError![]u8 {
    _ = allocator;
    _ = content;
    _ = private_key_pem;
    return error.RsaNotImplemented;
}

/// RSA-SHA256 验签（PKCS#1 v1.5）。
///
/// **当前实现**：返回 `RsaNotImplemented`。
pub fn rsaVerify(
    allocator: std.mem.Allocator,
    content: []const u8,
    signature_b64: []const u8,
    public_key_pem: []const u8,
) RsaError!bool {
    _ = allocator;
    _ = content;
    _ = signature_b64;
    _ = public_key_pem;
    return error.RsaNotImplemented;
}

/// PKCS#12 解析（用于支付 TLS 双向认证）。
///
/// **当前实现**：返回 `P12NotImplemented`。标准库未提供 PKCS#12 解析。
/// Vendor 方案：参考 `golang.org/x/crypto/pkcs12` 的 Zig 移植（约 400-600 行）。
pub const P12Error = error{
    P12NotImplemented,
    InvalidP12File,
    BadPassword,
};

pub fn parseP12(allocator: std.mem.Allocator, p12_bytes: []const u8, password: []const u8) P12Error!struct {
    cert_pem: []u8,
    key_pem: []u8,
} {
    _ = allocator;
    _ = p12_bytes;
    _ = password;
    return error.P12NotImplemented;
}

/// 检查 PKCS#12 是否可用（始终返回 false，因为尚未实现）。
pub fn p12Available() bool {
    return false;
}

/// 提示：检测 PEM 格式是否看起来是 RSA 私钥。
///
/// 仅做粗略字符串匹配（"-----BEGIN" + "PRIVATE KEY" 或 "RSA PRIVATE KEY"）。
/// 不做 ASN.1 解码，所以**不能**替代真实验签。
pub fn looksLikeRsaPrivateKeyPem(pem: []const u8) bool {
    return std.mem.indexOf(u8, pem, "-----BEGIN") != null and
        (std.mem.indexOf(u8, pem, "PRIVATE KEY") != null);
}

/// 提示：检测 PEM 格式是否看起来是 RSA 公钥。
pub fn looksLikeRsaPublicKeyPem(pem: []const u8) bool {
    return std.mem.indexOf(u8, pem, "-----BEGIN") != null and
        (std.mem.indexOf(u8, pem, "PUBLIC KEY") != null);
}

test "rsaSign 当前返回 RsaNotImplemented" {
    const result = rsaSign(std.testing.allocator, "content", "-----BEGIN PRIVATE KEY-----\nfoo\n-----END PRIVATE KEY-----");
    try std.testing.expectError(error.RsaNotImplemented, result);
}

test "rsaVerify 当前返回 RsaNotImplemented" {
    const result = rsaVerify(std.testing.allocator, "content", "sig_b64", "-----BEGIN PUBLIC KEY-----\nfoo\n-----END PUBLIC KEY-----");
    try std.testing.expectError(error.RsaNotImplemented, result);
}

test "parseP12 当前返回 P12NotImplemented" {
    const result = parseP12(std.testing.allocator, "fake_p12", "pwd");
    try std.testing.expectError(error.P12NotImplemented, result);
    try std.testing.expect(!p12Available());
}

test "looksLikeRsaPrivateKeyPem 识别 PEM 格式" {
    const valid = "-----BEGIN RSA PRIVATE KEY-----\nfoo\n-----END RSA PRIVATE KEY-----";
    try std.testing.expect(looksLikeRsaPrivateKeyPem(valid));
    const invalid = "not a PEM";
    try std.testing.expect(!looksLikeRsaPrivateKeyPem(invalid));
}

test "looksLikeRsaPublicKeyPem 识别 PEM 格式" {
    const valid = "-----BEGIN PUBLIC KEY-----\nfoo\n-----END PUBLIC KEY-----";
    try std.testing.expect(looksLikeRsaPublicKeyPem(valid));
    try std.testing.expect(!looksLikeRsaPublicKeyPem("plain text"));
}

// ──────────────────────────────────────────────────────────────────────────────
// Ed25519 实现（Zig 0.17 原生可用）
// ──────────────────────────────────────────────────────────────────────────────

/// Ed25519 签名错误集。
pub const Ed25519Error = error{
    InvalidSecretKey,
    InvalidPublicKey,
    InvalidSignature,
    SigningFailed,
};

/// 生成 Ed25519 密钥对。
///
/// `secret_key` 是 32 字节随机种子（用 `std.Io.Threaded.global_single_threaded` 生成）。
/// 返回 64 字节的 secret key bytes + 32 字节的 public key bytes。
pub fn ed25519GenerateKeyPair(_: std.mem.Allocator) !struct {
    secret_key: [ed25519.SecretKey.encoded_length]u8,
    public_key: [ed25519.PublicKey.encoded_length]u8,
} {
    var seed: [32]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&seed);

    const kp = try ed25519.KeyPair.generateDeterministic(seed);
    return .{
        .secret_key = kp.secret_key.toBytes(),
        .public_key = kp.public_key.toBytes(),
    };
}

/// Ed25519 签名 — 返回 64 字节原始签名。
pub fn ed25519Sign(
    allocator: std.mem.Allocator,
    secret_key_bytes: [ed25519.SecretKey.encoded_length]u8,
    message: []const u8,
) Ed25519Error![]u8 {
    const sk = ed25519.SecretKey.fromBytes(secret_key_bytes) catch return error.InvalidSecretKey;
    const kp = ed25519.KeyPair.fromSecretKey(sk) catch return error.InvalidSecretKey;
    const sig = ed25519.KeyPair.sign(kp, message, null) catch return error.SigningFailed;
    const out = allocator.alloc(u8, ed25519.Signature.encoded_length) catch return error.SigningFailed;
    @memcpy(out, &sig.toBytes());
    return out;
}

/// Ed25519 验签 — 返回 `true` 表示签名有效。
pub fn ed25519Verify(
    signature: []const u8,
    message: []const u8,
    public_key_bytes: [ed25519.PublicKey.encoded_length]u8,
) Ed25519Error!bool {
    if (signature.len != ed25519.Signature.encoded_length) return error.InvalidSignature;
    var sig_bytes: [ed25519.Signature.encoded_length]u8 = undefined;
    @memcpy(&sig_bytes, signature);
    const sig = ed25519.Signature.fromBytes(sig_bytes);
    const pk = ed25519.PublicKey.fromBytes(public_key_bytes) catch return error.InvalidPublicKey;
    ed25519.Signature.verify(sig, message, pk) catch return false;
    return true;
}

test "Ed25519 sign + verify round-trip" {
    const allocator = std.testing.allocator;
    const kp = try ed25519GenerateKeyPair(allocator);

    const msg = "hello, ed25519!";
    const sig = try ed25519Sign(allocator, kp.secret_key, msg);
    defer allocator.free(sig);

    try std.testing.expectEqual(@as(usize, ed25519.Signature.encoded_length), sig.len);
    const ok = try ed25519Verify(sig, msg, kp.public_key);
    try std.testing.expect(ok);

    // 篡改消息后应验签失败
    const bad = try ed25519Verify(sig, "hello, ed25519?", kp.public_key);
    try std.testing.expect(!bad);
}

test "Ed25519 用公开 RFC 8032 测试向量" {
    // RFC 8032 §7.1 Test 1
    // secret key seed: 9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60
    // public key:     d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
    // message:        (empty)
    // signature:      e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b

    const allocator = std.testing.allocator;
    const seed_bytes = [_]u8{
        0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
        0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
    };
    const expected_pk = [_]u8{
        0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7, 0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a,
        0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25, 0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a,
    };

    // 用 RFC seed 派生 KeyPair
    const kp = ed25519.KeyPair.generateDeterministic(seed_bytes) catch return error.InvalidSecretKey;

    try std.testing.expectEqualSlices(u8, &expected_pk, &kp.public_key.toBytes());

    // 签名空消息
    const sig = try ed25519Sign(allocator, kp.secret_key.toBytes(), "");
    defer allocator.free(sig);

    const ok = try ed25519Verify(sig, "", expected_pk);
    try std.testing.expect(ok);
}