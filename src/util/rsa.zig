//! util/rsa — RSA 签名 / 验签 / 解密 + PKCS#12 工具
//!
//! 对应 `_ref/wechat/util/rsa.go`：RSA-SHA256 PKCS#1 v1.5 签名 + 验签。
//!
//! **Zig 0.17 现状**：标准库尚未提供 RSA 实现（参见
//! https://github.com/ziglang/zig/issues/14456），但 `std.crypto.sign.Ed25519` 已可用。
//! 因此本文件同时提供：
//!
//! 1. **RSA 接口**（`rsaSign` / `rsaVerify` / `rsaDecrypt` / `rsaDecryptBase64`）：
//!    纯 Zig 实现，支持 PKCS#1 / PKCS#8 私钥、X.509 / PKCS#1 公钥、CRT 签名路径。
//! 2. **Ed25519 实现**（`ed25519Sign` / `ed25519Verify`）：直接可用，Zig 0.17 原生支持。
//!    业务如可接受 Ed25519 替换 RSA，可立即启用。
//! 3. **PKCS#12**（`parseP12`）：由 `pkcs12.zig` 提供完整解析。

const std = @import("std");
const ed25519 = std.crypto.sign.Ed25519;
const rsa_impl = @import("rsa_impl.zig");
const pkcs12 = @import("pkcs12.zig");

/// RSA 签名错误集。
pub const RsaError = error{
    RsaNotImplemented,
    InvalidPemKey,
    InvalidSignature,
    InvalidCiphertext,
    OutOfMemory,
};

/// RSA-SHA256 签名（PKCS#1 v1.5）。
///
/// `private_key_pem` 支持 PKCS#1 `-----BEGIN RSA PRIVATE KEY-----` 格式。
pub fn rsaSign(allocator: std.mem.Allocator, content: []const u8, private_key_pem: []const u8) RsaError![]u8 {
    var pk = rsa_impl.parsePrivateKeyPem(allocator, private_key_pem) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPemKey,
    };
    defer pk.deinit();

    return rsa_impl.signSha256(allocator, pk, content) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EncodingFailed => return error.InvalidSignature,
        else => return error.InvalidSignature,
    };
}

/// RSA-SHA256 验签（PKCS#1 v1.5）。
///
/// `public_key_pem` 支持 PKCS#1 `-----BEGIN RSA PUBLIC KEY-----` 或
/// X.509 `-----BEGIN PUBLIC KEY-----`（SubjectPublicKeyInfo）格式。
/// `signature_b64` 是 base64 编码的签名（调用方通常来自 HTTP 参数或 XML）。
pub fn rsaVerify(
    allocator: std.mem.Allocator,
    content: []const u8,
    signature_b64: []const u8,
    public_key_pem: []const u8,
) RsaError!bool {
    var pk = rsa_impl.parsePublicKeyPem(allocator, public_key_pem) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPemKey,
    };
    defer pk.deinit();

    const decoder = std.base64.standard.Decoder;
    const sig_len = decoder.calcSizeForSlice(signature_b64) catch return error.InvalidSignature;
    const signature = allocator.alloc(u8, sig_len) catch return error.OutOfMemory;
    defer allocator.free(signature);
    decoder.decode(signature, signature_b64) catch return error.InvalidSignature;

    return rsa_impl.verifySha256(allocator, pk, content, signature) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSignature,
    };
}

/// RSAES-PKCS1-v1_5 解密（二进制密文）。
///
/// `private_key_pem` 支持 PKCS#1 `-----BEGIN RSA PRIVATE KEY-----` 和
/// PKCS#8 `-----BEGIN PRIVATE KEY-----` 格式。
/// 返回的明文由调用方负责释放。
pub fn rsaDecrypt(
    allocator: std.mem.Allocator,
    ciphertext: []const u8,
    private_key_pem: []const u8,
) RsaError![]u8 {
    var pk = rsa_impl.parsePrivateKeyPem(allocator, private_key_pem) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPemKey,
    };
    defer pk.deinit();

    return rsa_impl.decrypt(allocator, pk, ciphertext) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCiphertext,
    };
}

/// RSAES-PKCS1-v1_5 解密（base64 编码密文）。
pub fn rsaDecryptBase64(
    allocator: std.mem.Allocator,
    ciphertext_b64: []const u8,
    private_key_pem: []const u8,
) RsaError![]u8 {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(ciphertext_b64) catch return error.InvalidCiphertext;
    const cipher = allocator.alloc(u8, len) catch return error.OutOfMemory;
    defer allocator.free(cipher);
    decoder.decode(cipher, ciphertext_b64) catch return error.InvalidCiphertext;

    return rsaDecrypt(allocator, cipher, private_key_pem);
}

/// PKCS#12 解析（用于支付 TLS 双向认证）。
///
/// **当前实现**：返回 `P12NotImplemented`。标准库未提供 PKCS#12 解析。
/// Vendor 方案：参考 `golang.org/x/crypto/pkcs12` 的 Zig 移植（约 400-600 行）。
pub const P12Error = error{
    P12NotImplemented,
    InvalidP12File,
    BadPassword,
    OutOfMemory,
};

pub fn parseP12(allocator: std.mem.Allocator, p12_bytes: []const u8, password: []const u8) P12Error!struct {
    cert_pem: []u8,
    key_pem: []u8,
} {
    const result = pkcs12.parse(allocator, p12_bytes, password) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPassword => return error.BadPassword,
        error.InvalidP12File => return error.InvalidP12File,
        else => return error.P12NotImplemented,
    };
    return .{ .cert_pem = result.cert_pem, .key_pem = result.key_pem };
}

/// 检查 PKCS#12 是否可用（取决于 parseP12 是否成功）。
pub fn p12Available() bool {
    return true;
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

const test_private_key_pkcs1 =
    "-----BEGIN RSA PRIVATE KEY-----\n" ++
    "MIICXAIBAAKBgQDeEfNBUM8LdVgybCmePyzqq4K4JeITO0tSI3cjLVIU0WNjn+/Z\n" ++
    "XQkp2wnxRwy7rejptcZ52VSisBkZ24O2nmQ1mggRQ62qHiMqOJdfBCr5eYIcC+nB\n" ++
    "hZTMCXeokzGXNQgWHSYSequj3b0IQLW/UJuoy4LshG69+3XtcOWFTitj6wIDAQAB\n" ++
    "AoGADhiVmE/I1LFeJ9U1zxWzhDHe2lGNSCs7XLtjlJgL3cZsyKYeU23UZxPATdB0\n" ++
    "vnULk8o2DwX8mVcUQM/uTGlBcwdJSYHDgxm/ALQLFk/HWndQZPhRG4beOPuleA/u\n" ++
    "nLyyI+WCs/kcTfkSVLxyWhd8mffdlPc8zJ3BeTscKuye9AECQQD3tfFTkRe3RXEY\n" ++
    "JYrYJTfcjqY/VQnNmoOCDcRkZ9hcf65+00ddGy2HVAYgbQIK0kSeW5h99duxfB1Q\n" ++
    "//n3enzzAkEA5YBaVbXfXtwYcm1Ay6yCrgF5M5dvWdbYqPxe7WSI+xA+x0Vo6VzT\n" ++
    "i4+LEBgXQHOj5sgD+ZBHDggm+yI4FxFbKQJBANzxXNITzVp7xtcpzUDjWYMRfXlp\n" ++
    "yTepRPlAfFauRU6j2ClpG/MQ5bgaGujbMgIi8G9q9YYMQCt7r85qszOo/j8CQBt7\n" ++
    "i1XIOb96S9MoEiJRvjRoKMNs1wDDIZ7a2eNDrsOh5mKmhTGs1AhaYCTFPcOSFYaF\n" ++
    "XTR9eoTLpR9dsanRgkECQBZ5QXRRn5m3ri33vEuQMVB4+zN4/WTsoTajjIsAquYS\n" ++
    "zNYkCg0jFcrx72bue1vi6XjuFCEB2dkA3BccoQjF+PQ=\n" ++
    "-----END RSA PRIVATE KEY-----";

const test_public_key_x509 =
    "-----BEGIN PUBLIC KEY-----\n" ++
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDeEfNBUM8LdVgybCmePyzqq4K4\n" ++
    "JeITO0tSI3cjLVIU0WNjn+/ZXQkp2wnxRwy7rejptcZ52VSisBkZ24O2nmQ1mggR\n" ++
    "Q62qHiMqOJdfBCr5eYIcC+nBhZTMCXeokzGXNQgWHSYSequj3b0IQLW/UJuoy4Ls\n" ++
    "hG69+3XtcOWFTitj6wIDAQAB\n" ++
    "-----END PUBLIC KEY-----";

// 对消息 "hello, zwechat rsa" 用上述私钥签名的 base64 结果（SHA-256 / PKCS#1 v1.5）。
const test_signature_b64 = "I39FVzcM4KIyson4J73YCiyS5+h7/lhCOl/fCRRae4kGCDIqw1u+iBhgY7sU9MSts5pwOW2HFkakv3yix4QEeZYkMTIPdcISZ0l6cpsN3ouVhGb1JXHscSqKbj06yWUbxIiEO56GKRUhZ/CMkfXspuQAZiUsdT6S2yhcpvm8q1M=";

test "rsaSign 对已知消息生成可被 OpenSSL 验证的签名" {
    const allocator = std.testing.allocator;
    const msg = "hello, zwechat rsa";
    const sig = try rsaSign(allocator, msg, test_private_key_pkcs1);
    defer allocator.free(sig);

    // 签名长度等于密钥字节长度（1024-bit => 128 字节）。
    try std.testing.expectEqual(@as(usize, 128), sig.len);

    // 用公钥验签通过。
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(sig.len);
    const sig_b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(sig_b64);
    _ = encoder.encode(sig_b64, sig);
    const ok = try rsaVerify(allocator, msg, sig_b64, test_public_key_x509);
    try std.testing.expect(ok);
}

test "rsaVerify 验证 OpenSSL 预生成的 base64 签名" {
    const allocator = std.testing.allocator;
    const ok = try rsaVerify(allocator, "hello, zwechat rsa", test_signature_b64, test_public_key_x509);
    try std.testing.expect(ok);
}

test "rsaVerify 对篡改消息返回 false" {
    const allocator = std.testing.allocator;
    const ok = try rsaVerify(allocator, "hello, zwechat rsa!", test_signature_b64, test_public_key_x509);
    try std.testing.expect(!ok);
}

test "rsaSign 拒绝非法 PEM" {
    const result = rsaSign(std.testing.allocator, "content", "not a pem");
    try std.testing.expectError(error.InvalidPemKey, result);
}

test "rsaVerify 拒绝非法公钥 PEM" {
    const result = rsaVerify(std.testing.allocator, "content", "c2ln", "not a pem");
    try std.testing.expectError(error.InvalidPemKey, result);
}

test "parseP12 拒绝非法 P12 文件" {
    const result = parseP12(std.testing.allocator, "fake_p12", "pwd");
    try std.testing.expectError(error.InvalidP12File, result);
    try std.testing.expect(p12Available());
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

const test_private_key_pkcs8 =
    "-----BEGIN PRIVATE KEY-----\n" ++
    "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAN4R80FQzwt1WDJs\n" ++
    "KZ4/LOqrgrgl4hM7S1IjdyMtUhTRY2Of79ldCSnbCfFHDLut6Om1xnnZVKKwGRnb\n" ++
    "g7aeZDWaCBFDraoeIyo4l18EKvl5ghwL6cGFlMwJd6iTMZc1CBYdJhJ6q6PdvQhA\n" ++
    "tb9Qm6jLguyEbr37de1w5YVOK2PrAgMBAAECgYAOGJWYT8jUsV4n1TXPFbOEMd7a\n" ++
    "UY1IKztcu2OUmAvdxmzIph5TbdRnE8BN0HS+dQuTyjYPBfyZVxRAz+5MaUFzB0lJ\n" ++
    "gcODGb8AtAsWT8dad1Bk+FEbht44+6V4D+6cvLIj5YKz+RxN+RJUvHJaF3yZ992U\n" ++
    "9zzMncF5Oxwq7J70AQJBAPe18VORF7dFcRglitglN9yOpj9VCc2ag4INxGRn2Fx/\n" ++
    "rn7TR10bLYdUBiBtAgrSRJ5bmH3127F8HVD/+fd6fPMCQQDlgFpVtd9e3BhybUDL\n" ++
    "rIKuAXkzl29Z1tio/F7tZIj7ED7HRWjpXNOLj4sQGBdAc6PmyAP5kEcOCCb7IjgX\n" ++
    "EVspAkEA3PFc0hPNWnvG1ynNQONZgxF9eWnJN6lE+UB8Vq5FTqPYKWkb8xDluBoa\n" ++
    "6NsyAiLwb2r1hgxAK3uvzmqzM6j+PwJAG3uLVcg5v3pL0ygSIlG+NGgow2zXAMMh\n" ++
    "ntrZ40Ouw6HmYqaFMazUCFpgJMU9w5IVhoVdNH16hMulH12xqdGCQQJAFnlBdFGf\n" ++
    "mbeuLfe8S5AxUHj7M3j9ZOyhNqOMiwCq5hLM1iQKDSMVyvHvZu57W+LpeO4UIQHZ\n" ++
    "2QDcFxyhCMX49A==\n" ++
    "-----END PRIVATE KEY-----";

const test_ciphertext_b64 =
    "jt3dup80IEd7jeUrH9glmjeoVxRcjww3MgFdmmwvxUmgVPubOhKrww0bs7Xobhkm3F99zAXlrjXvdPQZOgqt5DjMI+Agy3I0D8Z7VXdKExXWJCnsxlVWLGxjMLsvmTQ2pXCma8S6ckuNxmXygR8Mq0uqxzGW6r2dVlf1SFAnN3A=";

test "rsaSign accepts PKCS#8 private key" {
    const allocator = std.testing.allocator;
    const sig = try rsaSign(allocator, "hello, zwechat rsa", test_private_key_pkcs8);
    defer allocator.free(sig);
    try std.testing.expectEqual(@as(usize, 128), sig.len);

    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(sig.len);
    const sig_b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(sig_b64);
    _ = encoder.encode(sig_b64, sig);
    const ok = try rsaVerify(allocator, "hello, zwechat rsa", sig_b64, test_public_key_x509);
    try std.testing.expect(ok);
}

test "rsaDecryptBase64 decrypts PKCS#1 v1.5 ciphertext" {
    const allocator = std.testing.allocator;
    const plain = try rsaDecryptBase64(allocator, test_ciphertext_b64, test_private_key_pkcs1);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("hello, zwechat decrypt", plain);
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