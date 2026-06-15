//! util/rsa_impl — 纯 Zig 实现的 RSA-SHA256 PKCS#1 v1.5 签名 / 验签
//!
//! 用于填补 Zig 0.17 标准库没有 RSA 的空白。当前实现：
//! - 解析 PKCS#1 RSA PRIVATE KEY / RSA PUBLIC KEY PEM
//! - 解析 SubjectPublicKeyInfo（X.509）公钥 PEM
//! - RSASSA-PKCS1-v1_5 with SHA-256 签名与验签
//!
//! 性能说明：使用 `std.math.big.int.Managed` + 二进制模幂，未做 CRT / Montgomery
//! 优化；对 2048-bit 签名/验签可用但不够快。后续可用更快的 big-int 库替换。

const std = @import("std");

pub const Error = error{
    InvalidPemKey,
    InvalidSignature,
    UnsupportedKeyFormat,
    OutOfMemory,
    EncodingFailed,
};

// ──────────────────────────────────────────────────────────────────────────────
// RSA 密钥结构
// ──────────────────────────────────────────────────────────────────────────────

pub const PublicKey = struct {
    n: std.math.big.int.Managed,
    e: std.math.big.int.Managed,

    pub fn deinit(self: *PublicKey) void {
        self.n.deinit();
        self.e.deinit();
    }
};

pub const PrivateKey = struct {
    n: std.math.big.int.Managed,
    e: std.math.big.int.Managed,
    d: std.math.big.int.Managed,
    // CRT 参数（可选，当前实现未使用 CRT）。
    p: ?std.math.big.int.Managed,
    q: ?std.math.big.int.Managed,
    dp: ?std.math.big.int.Managed,
    dq: ?std.math.big.int.Managed,
    qinv: ?std.math.big.int.Managed,

    pub fn deinit(self: *PrivateKey) void {
        self.n.deinit();
        self.e.deinit();
        self.d.deinit();
        if (self.p) |*v| v.deinit();
        if (self.q) |*v| v.deinit();
        if (self.dp) |*v| v.deinit();
        if (self.dq) |*v| v.deinit();
        if (self.qinv) |*v| v.deinit();
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// PEM 解析
// ──────────────────────────────────────────────────────────────────────────────

const PemKind = enum {
    rsa_private_key, // PKCS#1
    rsa_public_key, // PKCS#1
    public_key, // SubjectPublicKeyInfo (X.509)
};

fn detectPemKind(pem: []const u8) ?PemKind {
    if (std.mem.indexOf(u8, pem, "BEGIN RSA PRIVATE KEY") != null) return .rsa_private_key;
    if (std.mem.indexOf(u8, pem, "BEGIN RSA PUBLIC KEY") != null) return .rsa_public_key;
    if (std.mem.indexOf(u8, pem, "BEGIN PUBLIC KEY") != null) return .public_key;
    return null;
}

fn stripPemArmor(pem: []const u8) Error![]const u8 {
    var start: usize = 0;
    var end: usize = pem.len;

    if (std.mem.indexOf(u8, pem, "-----BEGIN ")) |s| {
        if (std.mem.indexOfPos(u8, pem, s, "\n")) |nl| {
            start = nl + 1;
        } else return error.InvalidPemKey;
    }

    if (std.mem.indexOf(u8, pem, "-----END ")) |e| {
        // 找到 END 所在行的开头
        end = e;
        // 去掉该行之前的换行（如果 base64 最后一行之后有换行）
        if (end > start and pem[end - 1] == '\n') end -= 1;
        if (end > start and pem[end - 1] == '\r') end -= 1;
    }

    if (start >= end) return error.InvalidPemKey;
    return std.mem.trim(u8, pem[start..end], " \t\r\n");
}

fn base64Decode(allocator: std.mem.Allocator, b64: []const u8) Error![]u8 {
    // 去掉 PEM 中的换行与空格。
    const cleaned = allocator.alloc(u8, b64.len) catch return error.OutOfMemory;
    defer allocator.free(cleaned);
    var j: usize = 0;
    for (b64) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        cleaned[j] = c;
        j += 1;
    }
    const payload = cleaned[0..j];

    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return error.InvalidPemKey;
    const out = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    decoder.decode(out, payload) catch return error.InvalidPemKey;
    return out;
}

pub fn parsePrivateKeyPem(allocator: std.mem.Allocator, pem: []const u8) Error!PrivateKey {
    const kind = detectPemKind(pem) orelse return error.InvalidPemKey;
    if (kind != .rsa_private_key) return error.UnsupportedKeyFormat;

    const b64 = try stripPemArmor(pem);
    const der = try base64Decode(allocator, b64);
    defer allocator.free(der);

    return try parseRsaPrivateKeyDer(allocator, der);
}

pub fn parsePublicKeyPem(allocator: std.mem.Allocator, pem: []const u8) Error!PublicKey {
    const kind = detectPemKind(pem) orelse return error.InvalidPemKey;
    const b64 = try stripPemArmor(pem);
    const der = try base64Decode(allocator, b64);
    defer allocator.free(der);

    return switch (kind) {
        .rsa_public_key => try parseRsaPublicKeyDer(allocator, der),
        .public_key => try parseSubjectPublicKeyInfoDer(allocator, der),
        else => error.UnsupportedKeyFormat,
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// ASN.1 DER 最小解析器
// ──────────────────────────────────────────────────────────────────────────────

const DerReader = struct {
    data: []const u8,
    pos: usize,

    const Tag = struct {
        class: u2,
        constructed: bool,
        number: u5,
    };

    fn readTag(self: *DerReader) Error!Tag {
        if (self.pos >= self.data.len) return error.InvalidPemKey;
        const b = self.data[self.pos];
        self.pos += 1;
        return Tag{
            .class = @intCast((b >> 6) & 0x3),
            .constructed = ((b >> 5) & 0x1) != 0,
            .number = @intCast(b & 0x1f),
        };
    }

    fn readLength(self: *DerReader) Error!usize {
        if (self.pos >= self.data.len) return error.InvalidPemKey;
        const first = self.data[self.pos];
        self.pos += 1;
        if (first & 0x80 == 0) return first;
        const num_bytes = first & 0x7f;
        if (num_bytes == 0 or num_bytes > 4 or self.pos + num_bytes > self.data.len) return error.InvalidPemKey;
        var len: usize = 0;
        for (0..num_bytes) |_| {
            len = (len << 8) | self.data[self.pos];
            self.pos += 1;
        }
        return len;
    }

    fn readSequence(self: *DerReader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x10 or !tag.constructed) return error.InvalidPemKey;
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidPemKey;
        const seq = self.data[self.pos..self.pos + len];
        self.pos += len;
        return seq;
    }

    fn readIntegerBytes(self: *DerReader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x02) return error.InvalidPemKey;
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidPemKey;
        const bytes = self.data[self.pos..self.pos + len];
        self.pos += len;
        return bytes;
    }

    fn readBitString(self: *DerReader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x03) return error.InvalidPemKey;
        const len = try self.readLength();
        if (self.pos + len > self.data.len or len < 1) return error.InvalidPemKey;
        const unused_bits = self.data[self.pos];
        if (unused_bits != 0) return error.InvalidPemKey;
        const bs = self.data[self.pos + 1 .. self.pos + len];
        self.pos += len;
        return bs;
    }

    fn readObjectIdentifier(self: *DerReader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x06) return error.InvalidPemKey;
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidPemKey;
        const oid = self.data[self.pos..self.pos + len];
        self.pos += len;
        return oid;
    }
};

// rsaEncryption OID: 1.2.840.113549.1.1.1 = 0x2a 0x86 0x48 0x86 0xf7 0x0d 0x01 0x01 0x01
const RSA_ENCRYPTION_OID = &[_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

fn parseRsaPrivateKeyDer(allocator: std.mem.Allocator, der: []const u8) Error!PrivateKey {
    var r = DerReader{ .data = der, .pos = 0 };
    const seq = try r.readSequence();
    var inner = DerReader{ .data = seq, .pos = 0 };

    // Version
    const version = try inner.readIntegerBytes();
    if (version.len == 0) return error.InvalidPemKey;

    const readInt = struct {
        fn f(alloc: std.mem.Allocator, reader: *DerReader) Error!std.math.big.int.Managed {
            const bytes = try reader.readIntegerBytes();
            return try bigIntFromBytes(alloc, bytes);
        }
    }.f;

    var n = try readInt(allocator, &inner);
    errdefer n.deinit();
    var e = try readInt(allocator, &inner);
    errdefer e.deinit();
    var d = try readInt(allocator, &inner);
    errdefer d.deinit();
    var p = try readInt(allocator, &inner);
    errdefer p.deinit();
    var q = try readInt(allocator, &inner);
    errdefer q.deinit();
    var dp = try readInt(allocator, &inner);
    errdefer dp.deinit();
    var dq = try readInt(allocator, &inner);
    errdefer dq.deinit();
    const qinv = try readInt(allocator, &inner);

    return PrivateKey{
        .n = n,
        .e = e,
        .d = d,
        .p = p,
        .q = q,
        .dp = dp,
        .dq = dq,
        .qinv = qinv,
    };
}

fn parseRsaPublicKeyDer(allocator: std.mem.Allocator, der: []const u8) Error!PublicKey {
    var r = DerReader{ .data = der, .pos = 0 };
    const seq = try r.readSequence();
    var inner = DerReader{ .data = seq, .pos = 0 };

    const n_bytes = try inner.readIntegerBytes();
    const e_bytes = try inner.readIntegerBytes();

    var n = try bigIntFromBytes(allocator, n_bytes);
    errdefer n.deinit();
    const e = try bigIntFromBytes(allocator, e_bytes);

    return PublicKey{ .n = n, .e = e };
}

fn parseSubjectPublicKeyInfoDer(allocator: std.mem.Allocator, der: []const u8) Error!PublicKey {
    var r = DerReader{ .data = der, .pos = 0 };
    const seq = try r.readSequence();
    var inner = DerReader{ .data = seq, .pos = 0 };

    // AlgorithmIdentifier SEQUENCE
    const alg_seq = try inner.readSequence();
    var alg = DerReader{ .data = alg_seq, .pos = 0 };
    const oid = try alg.readObjectIdentifier();
    if (!std.mem.eql(u8, oid, RSA_ENCRYPTION_OID)) return error.UnsupportedKeyFormat;
    // 参数应为 NULL
    if (alg.pos < alg.data.len) {
        const null_tag = try alg.readTag();
        if (null_tag.number != 0x05) return error.UnsupportedKeyFormat;
        const null_len = try alg.readLength();
        if (null_len != 0) return error.UnsupportedKeyFormat;
    }

    // subjectPublicKey BIT STRING 内是 RSAPublicKey DER
    const key_bits = try inner.readBitString();
    return try parseRsaPublicKeyDer(allocator, key_bits);
}

// ──────────────────────────────────────────────────────────────────────────────
// 大整数辅助
// ──────────────────────────────────────────────────────────────────────────────

fn bigIntFromBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!std.math.big.int.Managed {
    // 去掉前导 0x00（ASN.1 INTEGER 对正数可能添加的符号位填充）
    var start: usize = 0;
    while (start + 1 < bytes.len and bytes[start] == 0) start += 1;
    const trimmed = bytes[start..];

    var m = try std.math.big.int.Managed.init(allocator);
    errdefer m.deinit();

    // 用 base-256 累加：value = value * 256 + byte
    var base256 = try std.math.big.int.Managed.initSet(allocator, 256);
    defer base256.deinit();
    var tmp = try std.math.big.int.Managed.init(allocator);
    defer tmp.deinit();

    for (trimmed) |b| {
        try m.mul(&m, &base256);
        try tmp.set(b);
        try m.add(&m, &tmp);
    }
    return m;
}

fn bigIntToBytes(allocator: std.mem.Allocator, value: std.math.big.int.Const, out_len: usize) Error![]u8 {
    const out = allocator.alloc(u8, out_len) catch return error.OutOfMemory;
    errdefer allocator.free(out);

    // 用 writeTwosComplement 要求 value 能放进 out_len 字节。
    if (!value.fitsInTwosComp(.unsigned, out_len * 8)) return error.EncodingFailed;
    std.math.big.int.Const.writeTwosComplement(value, out, .big);
    return out;
}

fn byteLenOfModulus(n: std.math.big.int.Const) usize {
    // k = ceil(bit_len(n) / 8)
    const bits = n.bitCountAbs();
    return (bits + 7) / 8;
}

/// 二进制模幂：result = base^exp mod mod
fn powMod(allocator: std.mem.Allocator, result: *std.math.big.int.Managed, base: std.math.big.int.Const, exp: std.math.big.int.Const, mod: std.math.big.int.Const) Error!void {
    var mod_managed = try std.math.big.int.Managed.init(allocator);
    defer mod_managed.deinit();
    try mod_managed.copy(mod);

    var b = try std.math.big.int.Managed.init(allocator);
    defer b.deinit();
    try b.copy(base);

    var e = try std.math.big.int.Managed.init(allocator);
    defer e.deinit();
    try e.copy(exp);

    var r = try std.math.big.int.Managed.initSet(allocator, 1);
    defer r.deinit();

    var tmp = try std.math.big.int.Managed.init(allocator);
    defer tmp.deinit();
    var q = try std.math.big.int.Managed.init(allocator);
    defer q.deinit();
    var tmp2 = try std.math.big.int.Managed.init(allocator);
    defer tmp2.deinit();
    var q2 = try std.math.big.int.Managed.init(allocator);
    defer q2.deinit();
    var two = try std.math.big.int.Managed.initSet(allocator, 2);
    defer two.deinit();

    while (!e.eqlZero()) {
        // e 是否为奇数
        try std.math.big.int.Managed.divTrunc(&q, &tmp, &e, &two);
        const is_odd = !tmp.eqlZero();

        if (is_odd) {
            try r.mul(&r, &b);
            try std.math.big.int.Managed.divTrunc(&q2, &tmp2, &r, &mod_managed);
            r.swap(&tmp2);
        }

        try b.mul(&b, &b);
        try std.math.big.int.Managed.divTrunc(&q2, &tmp2, &b, &mod_managed);
        b.swap(&tmp2);

        e.swap(&q);
    }

    try result.copy(r.toConst());
}

// ──────────────────────────────────────────────────────────────────────────────
// EMSA-PKCS1-v1_5 编码 (RFC 8017 §9.2)
// ──────────────────────────────────────────────────────────────────────────────

// DigestInfo for SHA-256: SEQUENCE { SEQUENCE { OID sha256, NULL }, OCTET STRING hash }
const SHA256_DIGEST_INFO_PREFIX = &[_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};

fn emsaPkcs1V15EncodeSha256(allocator: std.mem.Allocator, message: []const u8, em_len: usize) Error![]u8 {
    // Step 1: H = SHA-256(M)
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &hash, .{});

    // Step 2: T = DigestInfo prefix || H
    const t_len = SHA256_DIGEST_INFO_PREFIX.len + hash.len;

    // Step 3: em_len >= t_len + 11
    if (em_len < t_len + 11) return error.EncodingFailed;

    // Step 4: PS = 0xff * (em_len - t_len - 3)
    const ps_len = em_len - t_len - 3;

    // Step 5/6: EM = 0x00 || 0x01 || PS || 0x00 || T
    const em = allocator.alloc(u8, em_len) catch return error.OutOfMemory;
    errdefer allocator.free(em);

    em[0] = 0x00;
    em[1] = 0x01;
    @memset(em[2 .. 2 + ps_len], 0xff);
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len .. 3 + ps_len + SHA256_DIGEST_INFO_PREFIX.len], SHA256_DIGEST_INFO_PREFIX);
    @memcpy(em[3 + ps_len + SHA256_DIGEST_INFO_PREFIX.len ..], &hash);

    return em;
}

// ──────────────────────────────────────────────────────────────────────────────
// RSASSA-PKCS1-v1_5 签名 / 验签
// ──────────────────────────────────────────────────────────────────────────────

pub fn signSha256(allocator: std.mem.Allocator, private_key: PrivateKey, message: []const u8) Error![]u8 {
    const k = byteLenOfModulus(private_key.n.toConst());

    // Step 1: EM = EMSA-PKCS1-V1_5-ENCODE(M, k)
    const em = try emsaPkcs1V15EncodeSha256(allocator, message, k);
    defer allocator.free(em);

    // Step 2a: m = OS2IP(EM)
    var m = try bigIntFromBytes(allocator, em);
    defer m.deinit();

    // Step 2b: s = RSASP1(K, m) = m^d mod n
    var s = try std.math.big.int.Managed.init(allocator);
    defer s.deinit();
    try powMod(allocator, &s, m.toConst(), private_key.d.toConst(), private_key.n.toConst());

    // Step 2c/3: S = I2OSP(s, k)
    return try bigIntToBytes(allocator, s.toConst(), k);
}

pub fn verifySha256(allocator: std.mem.Allocator, public_key: PublicKey, message: []const u8, signature: []const u8) Error!bool {
    const k = byteLenOfModulus(public_key.n.toConst());
    if (signature.len != k) return error.InvalidSignature;

    // Step 1: s = OS2IP(S)
    var s = try bigIntFromBytes(allocator, signature);
    defer s.deinit();

    // 检查 0 <= s < n
    if (s.toConst().order(public_key.n.toConst()) != .lt) return error.InvalidSignature;

    // Step 2: m = RSAVP1((n, e), s) = s^e mod n
    var m = try std.math.big.int.Managed.init(allocator);
    defer m.deinit();
    try powMod(allocator, &m, s.toConst(), public_key.e.toConst(), public_key.n.toConst());

    // Step 3: EM' = I2OSP(m, k)
    const em_prime = try bigIntToBytes(allocator, m.toConst(), k);
    defer allocator.free(em_prime);

    // Step 4: EM = EMSA-PKCS1-V1_5-ENCODE(M, k)
    const em = try emsaPkcs1V15EncodeSha256(allocator, message, k);
    defer allocator.free(em);

    // 使用常数时间比较（k 是运行时值，所以手动循环）。
    var diff: u8 = 0;
    for (em_prime, em) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

// ──────────────────────────────────────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────────────────────────────────────

test "bigIntFromBytes 处理前导零" {
    const allocator = std.testing.allocator;
    const bytes = &[_]u8{ 0x00, 0x01, 0x02, 0x03 };
    var m = try bigIntFromBytes(allocator, bytes);
    defer m.deinit();
    const s = try m.toString(allocator, 10, .lower);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("66051", s);
}

test "bigIntToBytes / bigIntFromBytes round-trip" {
    const allocator = std.testing.allocator;
    const original = &[_]u8{ 0x00, 0xab, 0xcd, 0xef };
    var m = try bigIntFromBytes(allocator, original);
    defer m.deinit();
    const bytes = try bigIntToBytes(allocator, m.toConst(), 8);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0xab, 0xcd, 0xef }, bytes);
}
