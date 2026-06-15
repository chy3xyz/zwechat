//! util/pkcs12 — 最小 PKCS#12 解析器
//!
//! 仅支持微信支付最常见的 P12 生成方式：
//! - PBES2 + PBKDF2-HMAC-SHA256 + AES-256-CBC
//! - 导出证书为 `-----BEGIN CERTIFICATE-----` PEM
//! - 导出私钥为 `-----BEGIN PRIVATE KEY-----` PKCS#8 PEM
//!
//! 不支持（返回 UnsupportedPbe）：
//! - 3DES/RC2 等 legacy PBE
//! - 无密码（空字符串）P12
//! - MAC 校验（当前忽略 macData，只解析内容）

const std = @import("std");
const asn1 = @import("asn1.zig");

pub const Error = error{
    InvalidP12File,
    BadPassword,
    UnsupportedPbe,
    OutOfMemory,
    InvalidDer,
    UnsupportedTag,
};

// ──────────────────────────────────────────────────────────────────────────────
// 常用 OID
// ──────────────────────────────────────────────────────────────────────────────

const OID_DATA = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01 };
const OID_ENCRYPTED_DATA = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x06 };
const OID_PBES2 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d };
const OID_PBKDF2 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c };
const OID_HMAC_WITH_SHA256 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09 };
const OID_HMAC_WITH_SHA1 = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x07 };
const OID_AES_256_CBC = &[_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a };
const OID_KEY_BAG = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x01 };
const OID_PKCS8_SHROUDED_KEY_BAG = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x02 };
const OID_CERT_BAG = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x03 };
const OID_X509_CERTIFICATE = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x16, 0x01 };

// ──────────────────────────────────────────────────────────────────────────────
// 公共入口
// ──────────────────────────────────────────────────────────────────────────────

pub const P12Result = struct {
    cert_pem: []u8,
    key_pem: []u8,

    pub fn deinit(self: *P12Result, allocator: std.mem.Allocator) void {
        allocator.free(self.cert_pem);
        allocator.free(self.key_pem);
    }
};

/// 解析 PKCS#12 文件，返回证书 PEM 与私钥 PEM。
///
/// `password` 是 P12 导出密码；当前仅支持 PBES2 + PBKDF2-HMAC-SHA256 + AES-256-CBC。
pub fn parse(allocator: std.mem.Allocator, p12_bytes: []const u8, password: []const u8) Error!P12Result {
    if (password.len == 0) return error.BadPassword;

    var state = ParseState{
        .allocator = allocator,
        .password = password,
        .cert_der = null,
        .key_der = null,
    };

    try parsePfx(&state, p12_bytes);
    errdefer {
        if (state.cert_der) |d| allocator.free(d);
        if (state.key_der) |d| allocator.free(d);
    }

    const cert_der = state.cert_der orelse return error.InvalidP12File;
    const key_der = state.key_der orelse return error.InvalidP12File;

    const cert_pem = try derToPem(allocator, cert_der, "CERTIFICATE");
    errdefer allocator.free(cert_pem);
    const key_pem = try derToPem(allocator, key_der, "PRIVATE KEY");

    allocator.free(cert_der);
    allocator.free(key_der);
    state.cert_der = null;
    state.key_der = null;

    return P12Result{ .cert_pem = cert_pem, .key_pem = key_pem };
}

const ParseState = struct {
    allocator: std.mem.Allocator,
    password: []const u8,
    cert_der: ?[]const u8,
    key_der: ?[]const u8,
};

// ──────────────────────────────────────────────────────────────────────────────
// PFX / authSafe / SafeContents 解析
// ──────────────────────────────────────────────────────────────────────────────

fn parsePfx(state: *ParseState, p12_bytes: []const u8) Error!void {
    var r = asn1.Reader.init(p12_bytes);
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    // version
    const version = try inner.readInteger();
    if (version.len == 0 or version[version.len - 1] != 3) return error.InvalidP12File;

    // authSafe ContentInfo
    try parseAuthSafe(state, &inner);

    // macData（忽略，不校验）
}

fn parseAuthSafe(state: *ParseState, r: *asn1.Reader) Error!void {
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    const content_type = try inner.readObjectIdentifier();
    if (!std.mem.eql(u8, content_type, OID_DATA)) return error.UnsupportedPbe;

    // content [0] EXPLICIT OCTET STRING
    const ctx_tag = try inner.readTag();
    if (ctx_tag.number != 0) return error.InvalidP12File;
    const ctx_len = try inner.readLength();
    const ctx_content = try inner.readSequenceContent(ctx_len);
    var ctx = asn1.Reader.init(ctx_content);

    const safe_contents = try ctx.readOctetString();
    try parseSafeContents(state, safe_contents);
}

fn parseSafeContents(state: *ParseState, data: []const u8) Error!void {
    var r = asn1.Reader.init(data);
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    while (inner.remaining() > 0) {
        try parseContentInfo(state, &inner);
    }
}

fn parseContentInfo(state: *ParseState, r: *asn1.Reader) Error!void {
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    const content_type = try inner.readObjectIdentifier();

    const ctx_tag = try inner.readTag();
    if (ctx_tag.number != 0) return error.InvalidP12File;
    const ctx_len = try inner.readLength();
    const ctx_content = try inner.readSequenceContent(ctx_len);

    if (std.mem.eql(u8, content_type, OID_DATA)) {
        var ctx = asn1.Reader.init(ctx_content);
        const safe_bags = try ctx.readOctetString();
        try parseSafeBags(state, safe_bags);
    } else if (std.mem.eql(u8, content_type, OID_ENCRYPTED_DATA)) {
        // 解析 EncryptedContentInfo 并解密
        const plain = try parseEncryptedContentInfo(state, ctx_content);
        defer state.allocator.free(plain);
        try parseSafeBags(state, plain);
    } else {
        return error.UnsupportedPbe;
    }
}

fn parseSafeBags(state: *ParseState, data: []const u8) Error!void {
    var r = asn1.Reader.init(data);
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    while (inner.remaining() > 0) {
        try parseSafeBag(state, &inner);
    }
}

fn parseSafeBag(state: *ParseState, r: *asn1.Reader) Error!void {
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    const bag_id = try inner.readObjectIdentifier();

    const ctx_tag = try inner.readTag();
    if (ctx_tag.number != 0) return error.InvalidP12File;
    const ctx_len = try inner.readLength();
    const ctx_content = try inner.readSequenceContent(ctx_len);

    if (std.mem.eql(u8, bag_id, OID_CERT_BAG)) {
        const cert_der = try parseCertBag(ctx_content);
        if (state.cert_der == null) {
            state.cert_der = try state.allocator.dupe(u8, cert_der);
        }
    } else if (std.mem.eql(u8, bag_id, OID_PKCS8_SHROUDED_KEY_BAG)) {
        const key_der = try decryptEncryptedPrivateKeyInfo(state, ctx_content);
        if (state.key_der == null) {
            state.key_der = key_der;
        } else {
            state.allocator.free(key_der);
        }
    } else if (std.mem.eql(u8, bag_id, OID_KEY_BAG)) {
        if (state.key_der == null) {
            state.key_der = try state.allocator.dupe(u8, ctx_content);
        }
    }

    // attributes 忽略
}

fn parseCertBag(data: []const u8) Error![]const u8 {
    var r = asn1.Reader.init(data);
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    const cert_type = try inner.readObjectIdentifier();
    if (!std.mem.eql(u8, cert_type, OID_X509_CERTIFICATE)) return error.UnsupportedPbe;

    const ctx_tag = try inner.readTag();
    if (ctx_tag.number != 0) return error.InvalidP12File;
    const ctx_len = try inner.readLength();
    const ctx_content = try inner.readSequenceContent(ctx_len);
    var ctx = asn1.Reader.init(ctx_content);

    return try ctx.readOctetString();
}

// ──────────────────────────────────────────────────────────────────────────────
// EncryptedContentInfo / EncryptedPrivateKeyInfo 解密
// ──────────────────────────────────────────────────────────────────────────────

fn parseEncryptedContentInfo(state: *ParseState, data: []const u8) Error![]u8 {
    var r = asn1.Reader.init(data);
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    _ = try inner.readInteger(); // version

    // PKCS#7 EncryptedData: version INTEGER + EncryptedContentInfo SEQUENCE
    const eci_tag = try inner.readTag();
    if (eci_tag.number != 0x10 or !eci_tag.constructed) return error.InvalidP12File;
    const eci_len = try inner.readLength();
    const eci = try inner.readSequenceContent(eci_len);
    var eci_inner = asn1.Reader.init(eci);

    const content_type = try eci_inner.readObjectIdentifier();
    if (!std.mem.eql(u8, content_type, OID_DATA)) return error.UnsupportedPbe;

    const encrypted_content = try parseEncryptedAlgorithmAndData(&eci_inner);
    return try decryptPbes2(state, encrypted_content.alg, encrypted_content.data);
}

fn decryptEncryptedPrivateKeyInfo(state: *ParseState, data: []const u8) Error![]u8 {
    var r = asn1.Reader.init(data);
    const tag = try r.readTag();
    if (tag.number != 0x10 or !tag.constructed) return error.InvalidP12File;
    const len = try r.readLength();
    const seq = try r.readSequenceContent(len);
    var inner = asn1.Reader.init(seq);

    const encrypted_content = try parseEncryptedAlgorithmAndData(&inner);
    return try decryptPbes2(state, encrypted_content.alg, encrypted_content.data);
}

const EncryptedContent = struct {
    alg: []const u8,
    data: []const u8,
};

fn parseEncryptedAlgorithmAndData(r: *asn1.Reader) Error!EncryptedContent {
    // AlgorithmIdentifier
    const alg_tag = try r.readTag();
    if (alg_tag.number != 0x10 or !alg_tag.constructed) return error.InvalidP12File;
    const alg_len = try r.readLength();
    const alg = try r.readSequenceContent(alg_len);

    // 加密数据可能是 context-specific [0]（CMS EncryptedContentInfo）
    // 或普通 OCTET STRING（PKCS#8 EncryptedPrivateKeyInfo）。
    const data_tag = try r.readTag();
    const data_len = try r.readLength();
    const data = try r.readSequenceContent(data_len);
    if (data_tag.number == 0x04) {
        // OCTET STRING
    } else if (data_tag.class == 0b10 and data_tag.number == 0) {
        // [0] IMPLICIT OCTET STRING
    } else {
        return error.InvalidP12File;
    }
    return .{ .alg = alg, .data = data };
}

// ──────────────────────────────────────────────────────────────────────────────
// PBES2 解密
// ──────────────────────────────────────────────────────────────────────────────

fn decryptPbes2(state: *ParseState, alg: []const u8, encrypted_data: []const u8) Error![]u8 {
    var r = asn1.Reader.init(alg);
    const alg_oid = try r.readObjectIdentifier();
    if (!std.mem.eql(u8, alg_oid, OID_PBES2)) return error.UnsupportedPbe;

    const params_tag = try r.readTag();
    if (params_tag.number != 0x10 or !params_tag.constructed) return error.InvalidP12File;
    const params_len = try r.readLength();
    const params = try r.readSequenceContent(params_len);
    var p = asn1.Reader.init(params);

    // keyDerivationFunc
    const kdf_tag = try p.readTag();
    if (kdf_tag.number != 0x10 or !kdf_tag.constructed) return error.InvalidP12File;
    const kdf_len = try p.readLength();
    const kdf = try p.readSequenceContent(kdf_len);

    // encryptionScheme
    const enc_tag = try p.readTag();
    if (enc_tag.number != 0x10 or !enc_tag.constructed) return error.InvalidP12File;
    const enc_len = try p.readLength();
    const enc = try p.readSequenceContent(enc_len);

    const key = try deriveKey(state, kdf);
    defer state.allocator.free(key);

    return try decryptWithScheme(state, enc, key, encrypted_data);
}

fn deriveKey(state: *ParseState, kdf: []const u8) Error![]u8 {
    var r = asn1.Reader.init(kdf);
    const kdf_oid = try r.readObjectIdentifier();
    if (!std.mem.eql(u8, kdf_oid, OID_PBKDF2)) return error.UnsupportedPbe;

    const params_tag = try r.readTag();
    if (params_tag.number != 0x10 or !params_tag.constructed) return error.InvalidP12File;
    const params_len = try r.readLength();
    const params = try r.readSequenceContent(params_len);
    var p = asn1.Reader.init(params);

    const salt = try p.readOctetString();
    const iteration_count_bytes = try p.readInteger();
    var iteration_count: u32 = 0;
    for (iteration_count_bytes) |b| {
        iteration_count = (iteration_count << 8) | b;
    }

    // 默认 keyLength 由加密方案决定；这里先读可选 prf。
    var prf_oid: ?[]const u8 = null;
    if (p.remaining() > 0) {
        // 可能是 INTEGER keyLength 或 SEQUENCE prf
        const peek = try p.peekTagNumber();
        if (peek == 0x02) {
            _ = try p.readInteger(); // keyLength，忽略
            if (p.remaining() > 0) {
                const prf = try p.readRawValue();
                if (prf.tag.number == 0x10 and prf.tag.constructed) {
                    var pr = asn1.Reader.init(prf.content);
                    prf_oid = try pr.readObjectIdentifier();
                }
            }
        } else if (peek == 0x10) {
            const prf = try p.readRawValue();
            var pr = asn1.Reader.init(prf.content);
            prf_oid = try pr.readObjectIdentifier();
        }
    }

    // 默认 PRF 是 SHA-1，但 OpenSSL 默认通常是 SHA-256。
    const use_sha256 = prf_oid == null or std.mem.eql(u8, prf_oid.?, OID_HMAC_WITH_SHA256);

    const key_len: usize = 32; // AES-256
    const key = try state.allocator.alloc(u8, key_len);
    errdefer state.allocator.free(key);

    if (use_sha256) {
        std.crypto.pwhash.pbkdf2(key, state.password, salt, iteration_count, std.crypto.auth.hmac.sha2.HmacSha256) catch return error.BadPassword;
    } else if (std.mem.eql(u8, prf_oid.?, OID_HMAC_WITH_SHA1)) {
        std.crypto.pwhash.pbkdf2(key, state.password, salt, iteration_count, std.crypto.auth.hmac.HmacSha1) catch return error.BadPassword;
    } else {
        return error.UnsupportedPbe;
    }

    return key;
}

fn decryptWithScheme(state: *ParseState, enc: []const u8, key: []const u8, data: []const u8) Error![]u8 {
    var r = asn1.Reader.init(enc);
    const enc_oid = try r.readObjectIdentifier();

    if (std.mem.eql(u8, enc_oid, OID_AES_256_CBC)) {
        const params_tag = try r.readTag();
        if (params_tag.number != 0x04) return error.InvalidP12File;
        const params_len = try r.readLength();
        const iv = try r.readSequenceContent(params_len);
        if (iv.len != 16) return error.InvalidP12File;

        return try aes256CbcDecrypt(state.allocator, key, iv, data);
    }

    return error.UnsupportedPbe;
}

// ──────────────────────────────────────────────────────────────────────────────
// AES-256-CBC 解密（PKCS#7 去填充）
// ──────────────────────────────────────────────────────────────────────────────

fn aes256CbcDecrypt(allocator: std.mem.Allocator, key: []const u8, iv: []const u8, ciphertext: []const u8) Error![]u8 {
    if (ciphertext.len % 16 != 0) return error.InvalidP12File;
    const Aes256 = std.crypto.core.aes.Aes256;
    var key_bytes: [32]u8 = undefined;
    @memcpy(&key_bytes, key[0..32]);
    const cipher = Aes256.initDec(key_bytes);

    const plain = allocator.alloc(u8, ciphertext.len) catch return error.OutOfMemory;
    errdefer allocator.free(plain);

    var prev = iv;
    var i: usize = 0;
    while (i < ciphertext.len) : (i += 16) {
        var block: [16]u8 = undefined;
        cipher.decrypt(&block, ciphertext[i..][0..16]);
        for (0..16) |j| {
            plain[i + j] = block[j] ^ prev[j];
        }
        prev = ciphertext[i..][0..16];
    }

    // PKCS#7 unpadding。填充错误通常是密码错误（无法校验 MAC 时的唯一判断手段）。
    const pad_len = plain[plain.len - 1];
    if (pad_len == 0 or pad_len > 16) return error.BadPassword;
    for (plain[plain.len - pad_len ..]) |b| {
        if (b != pad_len) return error.BadPassword;
    }

    const trimmed_len = plain.len - pad_len;
    const result = allocator.alloc(u8, trimmed_len) catch return error.OutOfMemory;
    @memcpy(result, plain[0..trimmed_len]);
    allocator.free(plain);
    return result;
}

// ──────────────────────────────────────────────────────────────────────────────
// DER → PEM
// ──────────────────────────────────────────────────────────────────────────────

fn derToPem(allocator: std.mem.Allocator, der: []const u8, label: []const u8) Error![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(der.len);
    const header = try std.fmt.allocPrint(allocator, "-----BEGIN {s}-----\n", .{label});
    defer allocator.free(header);
    const footer = try std.fmt.allocPrint(allocator, "\n-----END {s}-----\n", .{label});
    defer allocator.free(footer);

    // 每 64 字符一行
    const lines = (b64_len + 63) / 64;
    const total_len = header.len + b64_len + lines + footer.len - 1; // lines-1 个额外换行已在 b64 末尾后算入
    const out = allocator.alloc(u8, total_len) catch return error.OutOfMemory;
    errdefer allocator.free(out);

    var pos: usize = 0;
    @memcpy(out[pos..][0..header.len], header);
    pos += header.len;

    var b64_buf = allocator.alloc(u8, b64_len) catch return error.OutOfMemory;
    defer allocator.free(b64_buf);
    _ = encoder.encode(b64_buf, der);

    var b64_pos: usize = 0;
    while (b64_pos < b64_len) {
        const line_len = @min(64, b64_len - b64_pos);
        @memcpy(out[pos..][0..line_len], b64_buf[b64_pos .. b64_pos + line_len]);
        pos += line_len;
        b64_pos += line_len;
        if (b64_pos < b64_len) {
            out[pos] = '\n';
            pos += 1;
        }
    }

    @memcpy(out[pos..][0..footer.len], footer);
    pos += footer.len;

    return out;
}

// ──────────────────────────────────────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────────────────────────────────────

const TEST_P12_B64 =
    "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" ++
    "AggA" ++
    "";

test "parseP12 解析 AES-256-CBC / PBKDF2-SHA256 P12" {
    const allocator = std.testing.allocator;
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(TEST_P12_B64);
    const p12_bytes = try allocator.alloc(u8, size);
    defer allocator.free(p12_bytes);
    try decoder.decode(p12_bytes, TEST_P12_B64);

    var result = try parse(allocator, p12_bytes, "testpwd");
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.cert_pem, "-----BEGIN CERTIFICATE-----"));
    try std.testing.expect(std.mem.indexOf(u8, result.cert_pem, "-----END CERTIFICATE-----") != null);
    try std.testing.expect(std.mem.startsWith(u8, result.key_pem, "-----BEGIN PRIVATE KEY-----"));
    try std.testing.expect(std.mem.indexOf(u8, result.key_pem, "-----END PRIVATE KEY-----") != null);
}

test "parseP12 密码错误返回 BadPassword" {
    const allocator = std.testing.allocator;
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(TEST_P12_B64);
    const p12_bytes = try allocator.alloc(u8, size);
    defer allocator.free(p12_bytes);
    try decoder.decode(p12_bytes, TEST_P12_B64);

    const result = parse(allocator, p12_bytes, "wrongpwd");
    try std.testing.expectError(error.BadPassword, result);
}

test "parseP12 空密码返回 BadPassword" {
    const allocator = std.testing.allocator;
    const result = parse(allocator, &[_]u8{0}, "");
    try std.testing.expectError(error.BadPassword, result);
}
