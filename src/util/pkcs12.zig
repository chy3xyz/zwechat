// SPDX-License-Identifier: Apache-2.0
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
//! - 迭代次数超过 `max_pbkdf2_iterations` 的 P12（见该常量的 DoS 说明）
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

/// PBKDF2 迭代次数上限（DoS 防护）。
///
/// PBKDF2 的参数 `iterationCount` 完全取自 P12 文件，标准本身只要求它是正整数：
/// 一个损坏或恶意的文件可以写上 u32 的最大值（约 4.3e9），让 `deriveKey` 在
/// PBKDF2-HMAC-SHA256 上算上**小时级**的时间——解析线程被钉住、fuzz 也会卡死
/// （本文件的 fuzz 用例一直不敢喂真实 P12 语料，正是因为这个）。
///
/// 阈值取 5_000_000 的依据与余量：
/// - OpenSSL 导出 P12 时的默认迭代次数是 2048（`PKCS12_create`），微信支付商户平台
///   导出的证书同样是这个量级；本文件测试用的真实 P12 也是 2048；
/// - 5_000_000 是 OpenSSL 默认值的约 2400 倍、是「常见高配」（10 万量级）的 50 倍，
///   即使用户自建的文件把迭代次数调得很高也不会被误拒；
/// - 反过来，被拒的最坏情况也只是「注定要跑几百毫秒~数秒的派生」，而对 4.3e9
///   这种不可信取值则一律直接拒绝。
const max_pbkdf2_iterations: u32 = 5_000_000;

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

/// 解析 PBKDF2 的迭代次数（INTEGER，大端；PKCS#12/PKCS#5 按 ASN.1 1988 约定，
/// 正整数最高位为 1 时会补一个前导 `0x00`）。
///
/// **安全**：迭代次数完全取自文件内容。若不设上限，一个畸形/恶意 P12 只要把该字段
/// 写成很大的值（最大 u32），`deriveKey` 就会让 PBKDF2 长时间占用 CPU（DoS）。
/// 因此这里对 `> max_pbkdf2_iterations` 直接返回 `error.UnsupportedPbe`。
fn parseIterationCount(bytes: []const u8) Error!u32 {
    if (bytes.len == 0 or bytes.len > 5) return error.InvalidP12File;
    var i: usize = 0;
    // 允许一个前导 0x00（正数补位）；其后的字节按大端累加。
    if (bytes.len > 1 and bytes[0] == 0) i = 1;
    var value: u64 = 0;
    while (i < bytes.len) : (i += 1) {
        value = (value << 8) | bytes[i];
    }
    if (value > std.math.maxInt(u32)) return error.InvalidP12File;
    const count: u32 = @intCast(value);
    if (count > max_pbkdf2_iterations) return error.UnsupportedPbe;
    return count;
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
    const iteration_count = try parseIterationCount(try p.readInteger());

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
    "MIIGjwIBAzCCBkUGCSqGSIb3DQEHAaCCBjYEggYyMIIGLjCCAuoGCSqGSIb3DQEHBqCCAtswggLXAgEA" ++
    "MIIC0AYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBBxtvItsd34oNlBZWx6" ++
    "XW0oAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQGiK60PknaIRi7wji3wTHJICCAmBg6eXa" ++
    "5PetjoeXpuT/N3b3iIQfL3KUMMkVuWSrZ1n2Cw4BKpaejeiuvcDcKgjYAlo5fxQj/WW+Ol3+TWvZOuUS" ++
    "lWshwPI28u32ZEulIemUWaFpRSXJX52rMYkjbbpE9IOeD1rFlbl3HhGKvOP6qNB0uScZTQV0RAiXLHj4" ++
    "ipTuAvL5wc2xvhn/NN3S/R50q9BD0if8s0MH74LOGVwidx8FD33b8qg1GH6kfJmUNIOHzXVDVhW3Ew/G" ++
    "yw5jwyycJhinoxkcGrRvQonvWAuTAsemzuxoFiIAHODnhscCJCy9SKT3jIL2QmSyn0TO2seJhuR/4gAR" ++
    "hO3ZGLac89AFM3QXwEZeNFwgZa9fxli9RFVT/jpAlqCmvLQhCl/owI0PBB7AbfUB44kwLyM1zIP+Fn4g" ++
    "NtNnOnER5zRwmpKiOocBwdCjO9NP23/od+WB4y+97zIcteZT0LNjF5m1Lo+tTwe2f1dyOg3xqXgUrrLx" ++
    "zqSMWUKBz9SGs4xwb4I5laoIRRnVggHPs2QeJmze2+DAefrRo1UvYa0SjllGgczavZaqvWg+vK0yzNmX" ++
    "IkpPMkz4aR7z4UFJy+/klt+paLvd0cZ+JQteRMDu87aQtY0dfdXLiCXjoaml36DGksgHxCvAYrvMiQI5" ++
    "I56E0gUaqZYAEof+zUYep6UhCdRBQNSHva0P4BolNkRarqZ7REUIvuG6Qn3rgHyRYcphxPOb3urjDb1/" ++
    "jqTPeHH9c+c/Knb8ncIpVma80BDZyR4IPuIILkIGuO+puj5A3jUQulYrZk3ZhJGTpgk9MiWbtYQNE2/1" ++
    "Tdy9tjCCAzwGCSqGSIb3DQEHAaCCAy0EggMpMIIDJTCCAyEGCyqGSIb3DQEMCgECoIIC6TCCAuUwXwYJ" ++
    "KoZIhvcNAQUNMFIwMQYJKoZIhvcNAQUMMCQEEGPm2T/NhJNPLCYHyBNBZ/MCAggAMAwGCCqGSIb3DQIJ" ++
    "BQAwHQYJYIZIAWUDBAEqBBD7iKzNu7UUcskever+3Q8tBIICgKyMC/hLXBm6p/ZaZuzfytbFd5KHD9QJ" ++
    "0qSxtxsPiuVuMH3uJ0NFxzDo2pB3ejoZmQNE5XY1VlQ4dDnIpgFqAi8UE/ipGeG7JNR1dLsggFJNTAli" ++
    "ptYMblBK2uQPzZ9vOa6euXe906Oam0fFi64nF7dj9q4Ww95nZ8+DAIeHRE5XJz+oV6NN/MsB4wf51+45" ++
    "qxKzgoDaUVxpFl5VYf1wUy8ZH7MufmiDytVCDR0xqTPyDuA7WzulwmeeJDCnPy4lHqsEe7GuJN6n7MPA" ++
    "AEMmnATzfHQOqKyVzHGxdIjSYYV6QjyFZiZ9T8zk//3D7nAKa97bPVxSN3vJ812a2lLGF5ZAm5/WX4X2" ++
    "EEEl8f/9cjHRQvSjPfwn7U6WdDpLBO7uIK4dGXFt/Vi6Ge1OXrxtNDqq7vtN4go7k+Pin9AvE2jccvyS" ++
    "QNgAAcy00THbxbMZZWE/lDyyQVnOUlo9pPcv2RnhCb5GhvIzHqawUUHbrt9rxizBhPT5h3rkhbuAC8n7" ++
    "k12wwsRHWAWYMIZwf0ZzeTwANFi6+MBd7QXodkWUtafO9AxoIKXFPhgCudBfTzo44prdAHnuxunyrZ3n" ++
    "4MrGm21pbc9wqsimIxoPXA1ZX9uUiwjsMP8Ezs0gKJg61O14cdfHcjypMcvFRWfNrKBS12MCGipLMQU+" ++
    "l8N8R72nAFOLggU9sgZjEd9SisFbarYYjkMv3oDMx2nNUafOYZVrvP0FF6tCmErNxpPhHfoynQoVf9vH" ++
    "7cuocukXEWANKQp9tF/qK9ePFEur3Qh2y5HgDWCIAjDCDcOp9ZCFU7D/80fW6fGlC4JAqS119nzlc/LI" ++
    "IUGrQf/dAssZ9FameNGEfdExJTAjBgkqhkiG9w0BCRUxFgQUPrjHUCU7hTTxexD8MDJomPJQC6kwQTAx" ++
    "MA0GCWCGSAFlAwQCAQUABCDn0TahMfxdqHhzYI9HU+xf7cQQEbZifSP/CwxSfAvP3wQILcnnpWYyr+kC" ++
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

test "parse 对真实 P12 的任意前缀都安静失败（长度字段越界回归）" {
    const allocator = std.testing.allocator;
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(TEST_P12_B64);
    const p12_bytes = try allocator.alloc(u8, size);
    defer allocator.free(p12_bytes);
    try decoder.decode(p12_bytes, TEST_P12_B64);

    // 逐字节截断：每个严格前缀都必须失败，且失败路径不得泄漏/越界。
    // （这是「长度字段比实际数据大」这一类 bug 最直接的回归网）
    for (1..p12_bytes.len) |n| {
        const result = parse(allocator, p12_bytes[0..n], "testpwd");
        if (result) |ok| {
            var parsed_ok = ok;
            parsed_ok.deinit(allocator);
            std.debug.print("前缀 {d} 字节竟然解析成功\n", .{n});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// PBKDF2 迭代次数上限（DoS 防护）
// ──────────────────────────────────────────────────────────────────────────────

test "parseIterationCount 边界与错误变体（5_000_000 通过 / 更大拒绝）" {
    // 真实 P12 里的取值（本文件 TEST_P12_B64 是 OpenSSL 默认的 2048 次）
    try std.testing.expectEqual(@as(u32, 2048), try parseIterationCount(&[_]u8{ 0x08, 0x00 }));
    // 恰好等于上限：放行（上限是「超过才拒绝」，留足余量给高迭代次数的合法文件）
    try std.testing.expectEqual(
        max_pbkdf2_iterations,
        try parseIterationCount(&[_]u8{ 0x00, 0x4c, 0x4b, 0x40 }),
    );
    // 上限 + 1：拒绝
    try std.testing.expectError(
        error.UnsupportedPbe,
        parseIterationCount(&[_]u8{ 0x00, 0x4c, 0x4b, 0x41 }),
    );
    // u32 最大值（约 4.3e9 次派生 = 小时级）：拒绝，而不是交给 PBKDF2 慢慢算
    try std.testing.expectError(
        error.UnsupportedPbe,
        parseIterationCount(&[_]u8{ 0x00, 0xff, 0xff, 0xff, 0xff }),
    );
    // 0 次迭代不在本函数的职责里：照原样放行，交给 PBKDF2 判 WeakParameters
    // → 上层映射成 `BadPassword`（保持旧行为，不改既有错误语义）
    try std.testing.expectEqual(@as(u32, 0), try parseIterationCount(&[_]u8{0x00}));
}

test "parseIterationCount 对畸形/超长 INTEGER 不溢出、不 panic" {
    // 5 字节且最高位非 0：值超出 u32，判文件畸形。
    // （旧实现按 u32 逐字节 `<<8`：超过 4 字节的高位会被**静默丢弃**，等于把畸形值
    //  猜成一个数；这里改成显式拒绝。）
    try std.testing.expectError(
        error.InvalidP12File,
        parseIterationCount(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff }),
    );
    // 任意超长 INTEGER（> 5 字节）：一律拒绝，不做逐字节累加
    try std.testing.expectError(
        error.InvalidP12File,
        parseIterationCount(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1 }),
    );
    // 空 INTEGER（DER 里长度 0 的 `02 00`）：畸形文件
    try std.testing.expectError(error.InvalidP12File, parseIterationCount(&[_]u8{}));
}

/// 构造一份「PBES2 的 keyDerivationFunc」DER（`deriveKey` 收到的正是这段字节）：
///   SEQUENCE {
///       OID 1.2.840.113549.1.5.12 (PBKDF2)
///       SEQUENCE { OCTET STRING salt="salt0123", INTEGER iteration_count }
///   }
/// `iteration_count` 按大端写在 `count_digits` 里（4 字节足够表达 u32 全量）。
/// 总长固定 29 = OID(11) + SEQUENCE 头(2) + salt TLV(10) + INTEGER TLV(6)，
/// 尾部不留未定义字节——否则 `deriveKey` 会去读「可选的 prf」并读到垃圾。
fn pbkdf2KdfWithIterationCount(count_digits: [4]u8) [29]u8 {
    const oid = [_]u8{ 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c };
    const params = [_]u8{
        0x30, 0x10, // SEQUENCE，长度 16
        0x04, 0x08, 's', 'a', 'l', 't', '0', '1', '2', '3', // salt
        0x02, 0x04, // INTEGER，长度 4
    };

    var buf: [oid.len + params.len + 4]u8 = undefined;
    @memcpy(buf[0..oid.len], &oid);
    @memcpy(buf[oid.len..][0..params.len], &params);
    @memcpy(buf[oid.len + params.len ..][0..4], &count_digits);
    return buf;
}

test "deriveKey 对超限迭代次数快速返回 UnsupportedPbe（不卡住）" {
    const allocator = std.testing.allocator;
    var state = ParseState{
        .allocator = allocator,
        .password = "testpwd",
        .cert_der = null,
        .key_der = null,
    };

    // 迭代次数 = 0xFFFFFFFF：真去算 PBKDF2-HMAC-SHA256 是小时级，必须在派生之前就拒绝。
    const kdf = pbkdf2KdfWithIterationCount([_]u8{ 0xff, 0xff, 0xff, 0xff });
    const started_ns = std.Io.Clock.now(.real, std.Options.debug_io).toNanoseconds();
    try std.testing.expectError(error.UnsupportedPbe, deriveKey(&state, &kdf));
    const elapsed_ns = std.Io.Clock.now(.real, std.Options.debug_io).toNanoseconds() - started_ns;

    // 时间断言只是把「没有卡住」钉死：上限内最慢的合法文件也只有几百毫秒级，
    // 而 4.29e9 轮 PBKDF2 需要小时级，10 秒的余量足以区分且不会误报。
    if (elapsed_ns > 10 * std.time.ns_per_s) {
        std.debug.print("deriveKey 超限迭代次数耗时 {d} ns，疑似真的在做派生\n", .{elapsed_ns});
        return error.TestUnexpectedResult;
    }
}

test "deriveKey 接受上限内的迭代次数（合法文件不被误拒）" {
    const allocator = std.testing.allocator;
    var state = ParseState{
        .allocator = allocator,
        .password = "testpwd",
        .cert_der = null,
        .key_der = null,
    };

    // 2048 次（OpenSSL 默认）：正常派生出一个 32 字节的 AES-256 key。
    const kdf = pbkdf2KdfWithIterationCount([_]u8{ 0x00, 0x00, 0x08, 0x00 });
    const key = try deriveKey(&state, &kdf);
    defer allocator.free(key);
    try std.testing.expectEqual(@as(usize, 32), key.len);

    // 与直接调用 PBKDF2 的结果一致（确认迭代次数确实被按原值使用，没有被改写成别的值）
    var expected: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(
        &expected,
        "testpwd",
        "salt0123",
        2048,
        std.crypto.auth.hmac.sha2.HmacSha256,
    );
    try std.testing.expectEqualSlices(u8, &expected, key);
}

// ──────────────────────────────────────────────────────────────────────────────
// fuzz（`zig build test --fuzz=<N>` 才真正变异；普通 `zig build test` 会先跑 corpus 里
// 的真实 P12、再跑一次空输入冒烟 —— 见文件末尾的 `fuzz_corpus`）
// ──────────────────────────────────────────────────────────────────────────────
const fuzz_byte_weights = [_]std.testing.Smith.Weight{
    .value(u8, 0x30, 6), // SEQUENCE
    .value(u8, 0x02, 4), // INTEGER
    .value(u8, 0x04, 4), // OCTET STRING
    .value(u8, 0x06, 4), // OBJECT IDENTIFIER
    .value(u8, 0xa0, 4), // [0] constructed
    .rangeAtMost(u8, 0x00, 0x1f, 3), // 短长度 / 常见 tag
    .value(u8, 0x80, 3), // 长格式长度，num_bytes = 0（非法）
    .rangeAtMost(u8, 0x81, 0x84, 4), // 长格式长度，num_bytes = 1..4（合法边界）
    .rangeAtMost(u8, 0x85, 0xff, 2), // 长格式长度，num_bytes > 4（必须拒绝）
    .rangeAtMost(u8, 0x00, 0xff, 2),
};

/// 输入的**长度**分布。真实 P12 有 1.6 KiB 级（本文件的 `TEST_P12_B64` 解出来 1683 字节），
/// 但绝大多数迭代应当落在短输入上（每个迭代都要走一遍 ASN.1 扫描），所以大输入只给
/// 1 份权重。
///
/// 这个分布同时决定 corpus 能否生效：`Smith` 只在「声明长度落在某个区间内」时才采用它，
/// 否则把长度重置成 `weights[0].min`——1683 落在第二段里，因此真实语料不会被截成 0 字节。
const fuzz_len_weights = [_]std.testing.Smith.Weight{
    .rangeAtMost(u32, 0, 256, 100),
    .rangeAtMost(u32, 257, fuzz_max_len, 1),
};

/// 输入长度上限：够装下本仓库的真实语料（1683 字节），又不必按真实商户证书
/// （常见 2~4 KiB）再放大。
const fuzz_max_len: usize = 2048;

/// 性质：任意字节 + 任意密码都不 panic（不越界、不整数溢出）、不泄漏；失败只允许
/// 是声明的错误变体；成功时的 PEM 头尾必须齐全（`derToPem` 的输出契约）。
///
/// 输入布局（= `Smith` 的输入流布局，也是 corpus 的布局）：
/// `[P12 段 u32 小端长度][P12 字节][密码段 u32 小端长度][密码]`。
///
/// 密码与 P12 分成两段是刻意的：旧写法把密码取成 `data[0..8]`，而真实 P12 的头 8 字节
/// 是 DER 头，永远不可能等于正确密码，于是真实语料只能覆盖到 `BadPassword` 早退。
/// 分开之后「真实 P12 + 正确密码」既能被 corpus 原样跑通成功路径（下面 4 条 PEM 断言
/// 因此第一次对真实文件生效），也让 fuzzer 有一个能走到 PBKDF2 → AES → PKCS#7 解包的
/// 成功起点；两段各自独立变异，覆盖面不减（密码段缺失时长度为 0，即空密码）。
///
/// 段序必须与这里的读取顺序（先 `sliceWeighted` 取 P12、再 `sliceWeightedBytes` 取密码）
/// 一致：顺序反了**不会报错**——两段会错位成「7 字节乱码 + 空密码」，语料悄悄退化成
/// 垃圾输入而断言照旧通过。下面的 `fuzz corpus 布局` 测试把它钉住。
fn testPkcs12ParseNeverPanics(allocator: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
    var buf: [fuzz_max_len]u8 = undefined;
    const len = smith.sliceWeighted(&buf, &fuzz_len_weights, &fuzz_byte_weights);
    const data = buf[0..len];

    var pw_buf: [16]u8 = undefined;
    const pw_len = smith.sliceWeightedBytes(&pw_buf, &fuzz_byte_weights);
    const password = pw_buf[0..pw_len];

    var result = parse(allocator, data, password) catch |err| switch (err) {
        error.InvalidP12File,
        error.BadPassword,
        error.UnsupportedPbe,
        error.InvalidDer,
        error.UnsupportedTag,
        error.OutOfMemory,
        => return,
    };
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.cert_pem, "-----BEGIN CERTIFICATE-----"));
    try std.testing.expect(std.mem.endsWith(u8, result.cert_pem, "-----END CERTIFICATE-----\n"));
    try std.testing.expect(std.mem.startsWith(u8, result.key_pem, "-----BEGIN PRIVATE KEY-----"));
    try std.testing.expect(std.mem.endsWith(u8, result.key_pem, "-----END PRIVATE KEY-----\n"));
}

test "fuzz: parse 不 panic / 不泄漏（长度字段边界）" {
    try std.testing.fuzz(std.testing.allocator, testPkcs12ParseNeverPanics, .{
        .corpus = &fuzz_corpus,
    });
}

// ──────────────────────────────────────────────────────────────────────────────
// corpus（真实输入种子）
// ──────────────────────────────────────────────────────────────────────────────

/// corpus 种子：一份真实 P12（`TEST_P12_B64` 解出的 1683 字节）+ 它的正确密码 `testpwd`。
///
/// 布局同上面的输入流：`[P12 段长度][P12][密码段长度][testpwd]`。长度前缀不能省——
/// `Smith` 的切片生成器就是按这个格式从 corpus 里读的，直接塞裸 P12 会被当成
/// 「长度 = 前 4 字节」而切出一段垃圾。
///
/// `std.testing.FuzzInputOptions.corpus` 是 Zig 官方的语料入口（见
/// `lib/compiler/test_runner.zig` 的 `fuzz`，那里对每个元素调 `fuzzer_new_input`）：
/// 语料**写在代码里**，没有目录约定，也不需要 build.zig 接线。非 fuzz 模式下每个种子被
/// **原样**跑一遍 `testPkcs12ParseNeverPanics`（即「真实样本先过一次断言」，断言不成立
/// 会让 `zig build test` 直接变红——比放一个语料目录更能保证语料本身合法）；
/// fuzz 模式下它成为变异起点。
///
/// 敢喂真实 P12 的前提是 `deriveKey` 的迭代次数上限（`max_pbkdf2_iterations`）：
/// 没有它，变异出 2^32 次 PBKDF2 会让一次 fuzz 迭代跑几个小时。
const fuzz_corpus = [_][]const u8{&fuzz_corpus_seed};

/// 语料用的密码（与 `parseP12 解析 AES-256-CBC / PBKDF2-SHA256 P12` 测试里的那份一致）。
const fuzz_corpus_password = "testpwd";

const fuzz_corpus_seed = fuzzCorpusSeed(&fuzz_corpus_p12, fuzz_corpus_password);

/// `TEST_P12_B64` 解码出的原始字节，comptime 求值。
const fuzz_corpus_p12 = blk: {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(TEST_P12_B64) catch
        @compileError("TEST_P12_B64 不是合法 base64");
    var bytes: [size]u8 = undefined;
    decoder.decode(&bytes, TEST_P12_B64) catch
        @compileError("TEST_P12_B64 解码失败");
    break :blk bytes;
};

/// 拼出 `[数据段长度][数据][密码段长度][密码]` 的 corpus 种子（comptime 求值）。
/// 段序与 fuzz body 的读取顺序一致，详见 body 的文档。
fn fuzzCorpusSeed(comptime data: []const u8, comptime password: []const u8) [4 + data.len + 4 + password.len]u8 {
    var seed: [4 + data.len + 4 + password.len]u8 = undefined;
    std.mem.writeInt(u32, seed[0..4], data.len, .little);
    @memcpy(seed[4..][0..data.len], data);
    std.mem.writeInt(u32, seed[4 + data.len ..][0..4], password.len, .little);
    @memcpy(seed[4 + data.len + 4 ..][0..password.len], password);
    return seed;
}

// corpus 是「先过一遍断言」的，但断言只要求「失败必须是声明的错误变体」——
// 一份错位的种子会被解析成 `BadPassword` 之类的合法失败，测试照旧全绿，
// 语料却已经退化成垃圾输入（写这份语料时就踩过一次）。
// 这个测试用**和 body 完全相同的 Smith 读取顺序与权重表**回放种子，钉住：
// 取出的就是那份真实 P12、密码就是 `testpwd`，而且它确实能解析成功。
test "fuzz corpus 布局：种子按 body 的读取顺序还原出真实 P12" {
    const allocator = std.testing.allocator;
    var smith: std.testing.Smith = .{ .in = &fuzz_corpus_seed };

    var buf: [fuzz_max_len]u8 = undefined;
    const len = smith.sliceWeighted(&buf, &fuzz_len_weights, &fuzz_byte_weights);
    try std.testing.expectEqualSlices(u8, &fuzz_corpus_p12, buf[0..len]);

    var pw_buf: [16]u8 = undefined;
    const pw_len = smith.sliceWeightedBytes(&pw_buf, &fuzz_byte_weights);
    try std.testing.expectEqualStrings(fuzz_corpus_password, pw_buf[0..pw_len]);

    var result = try parse(allocator, buf[0..len], pw_buf[0..pw_len]);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.cert_pem, "-----BEGIN CERTIFICATE-----"));
    try std.testing.expect(std.mem.startsWith(u8, result.key_pem, "-----BEGIN PRIVATE KEY-----"));
}
