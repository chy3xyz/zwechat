// SPDX-License-Identifier: Apache-2.0
//! pay/v3/platform_cert — 微信支付 v3 平台证书下载 / 解密 / 验签公钥提取
//!
//! 依据官方文档：
//! - 下载平台证书 <https://pay.weixin.qq.com/doc/v3/merchant/4012551764>
//! - 如何使用平台证书验签名 <https://pay.weixin.qq.com/doc/v3/merchant/4013053420>
//!
//! `GET /v3/certificates` 应答里每张平台证书都放在 `encrypt_certificate` 中，用
//! APIv3 密钥做 AEAD_AES_256_GCM 解密得到 PEM 明文（与回调 `resource` 是同一套
//! 算法，故直接复用 `notify.decryptNotifyResource`，不另造轮子）。
//!
//! 解密出的是 X.509 **证书**，而验签需要的是其中的**公钥**——由
//! [`publicKeyPemFromCertificate`] 用 `std.crypto.Certificate` 解析证书后取出
//! `SubjectPublicKeyInfo`，再交给 `util/rsa.zig` 的 `rsaVerify`（PKCS#1 v1.5 /
//! RSA-SHA256，不手写 RSA）。
//!
//! 官方要求：**不要硬编码平台证书**，应定期（间隔 < 12 小时）刷新。本模块的
//! [`PlatformCertStore`] 按序列号做缓存，并在验签序列号未命中时自动刷新一次
//! （微信支付会不定期轮换平台证书）。

const std = @import("std");
const Config = @import("config.zig").Config;
const signer = @import("signer.zig");
const notify = @import("notify.zig");
const util_http = @import("../../util/http.zig");
const default_io = @import("../../util/default_io.zig");

/// 微信支付 v3 主域名。
pub const base_url = "https://api.mch.weixin.qq.com";

/// 平台证书下载路径。
pub const certificates_path = "/v3/certificates";

/// `data[].encrypt_certificate`：加密后的平台证书内容。
pub const EncryptCertificate = struct {
    /// 加密算法，目前只支持 `AEAD_AES_256_GCM`。
    algorithm: []const u8 = "",
    /// 加密随机串（AES-GCM 的 IV）。
    nonce: []const u8 = "",
    /// 附加数据，固定为 `certificate`。
    associated_data: []const u8 = "",
    /// 密文（base64，末尾含 16 字节 tag）。
    ciphertext: []const u8 = "",
};

/// `data[]`：一张平台证书。
pub const CertificateEntry = struct {
    serial_no: []const u8 = "",
    effective_time: []const u8 = "",
    expire_time: []const u8 = "",
    encrypt_certificate: EncryptCertificate = .{},
};

/// `GET /v3/certificates` 应答。
pub const CertificatesResponse = struct {
    data: []const CertificateEntry = &.{},
};

/// 解密并整理好的一张平台证书。
///
/// 三个切片都由创建它的 allocator 持有，必须经 [`PlatformCert.deinit`] 释放。
pub const PlatformCert = struct {
    /// 证书序列号（小写/大写按微信返回原样），验签时与 `Wechatpay-Serial` 逐字比对。
    serial_no: []u8,
    /// 证书本体（PEM，`-----BEGIN CERTIFICATE-----`）。
    cert_pem: []u8,
    /// 由证书提取出的验签公钥（PEM，`-----BEGIN PUBLIC KEY-----`）。
    public_key_pem: []u8,

    pub fn deinit(self: *PlatformCert, allocator: std.mem.Allocator) void {
        allocator.free(self.serial_no);
        allocator.free(self.cert_pem);
        allocator.free(self.public_key_pem);
        self.* = undefined;
    }
};

// -----------------------------------------------------------------------------
// 证书 → 公钥
// -----------------------------------------------------------------------------

/// 从平台证书（PEM）提取验签公钥，返回 `-----BEGIN PUBLIC KEY-----` / `-----BEGIN
/// RSA PUBLIC KEY-----` 形状的公钥 PEM。
///
/// - `-----BEGIN CERTIFICATE-----`（平台证书的常见形态）→ 用
///   `std.crypto.Certificate` 解析 X.509，取出 `SubjectPublicKeyInfo` 再编码为
///   PKCS#1 `RSA PUBLIC KEY` PEM（`util/rsa.zig` 两条公钥解析路径都认）；
/// - `-----BEGIN PUBLIC KEY-----` / `-----BEGIN RSA PUBLIC KEY-----`（微信支付
///   公钥模式，或调用方自行从证书导出的公钥）→ 原样透传。
///
/// 非 RSA 平台密钥返回 `error.UnsupportedKeyFormat`（微信支付平台证书恒为 RSA）。
pub fn publicKeyPemFromCertificate(allocator: std.mem.Allocator, cert_pem: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, cert_pem, " \t\r\n");

    if (std.mem.find(u8, trimmed, "BEGIN CERTIFICATE") == null) {
        if (std.mem.find(u8, trimmed, "PUBLIC KEY") != null) return allocator.dupe(u8, trimmed);
        return error.UnsupportedKeyFormat;
    }

    const der = try pemDecode(allocator, trimmed, "CERTIFICATE");
    defer allocator.free(der);

    const parsed = std.crypto.Certificate.parse(.{ .buffer = der, .index = 0 }) catch
        return error.CertParseFailed;

    switch (parsed.pub_key_algo) {
        .rsaEncryption, .rsassa_pss => {},
        else => return error.UnsupportedKeyFormat,
    }

    const key_der = der[parsed.pub_key_slice.start..parsed.pub_key_slice.end];
    return encodePem(allocator, "RSA PUBLIC KEY", key_der);
}

/// 解析 `GET /v3/certificates` 应答，用 APIv3 密钥解密每张平台证书。
///
/// 返回的切片（含切片内每个 `PlatformCert` 的三个字段）全部由 `allocator` 分配，
/// 调用方负责逐项 `PlatformCert.deinit`，再 `allocator.free` 切片本身。
///
/// 单张证书解密/解析失败即整体 `error.CertParseFailed`（宁可整批拉取失败，也不
/// 让"缺失某张证书"变成后续验签时的 `SerialNotFound` 谜题）。
pub fn parseCertificates(
    allocator: std.mem.Allocator,
    api_v3_key: []const u8,
    body: []const u8,
) ![]PlatformCert {
    if (api_v3_key.len != 32) return error.ApiV3KeyRequired;

    const parsed = std.json.parseFromSlice(CertificatesResponse, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.CertParseFailed;
    defer parsed.deinit();

    var list: std.ArrayList(PlatformCert) = .empty;
    errdefer freeCertList(allocator, &list);

    for (parsed.value.data) |entry| {
        if (entry.serial_no.len == 0) continue;
        if (entry.encrypt_certificate.ciphertext.len == 0) continue;

        const cert_pem = notify.decryptNotifyResource(
            allocator,
            api_v3_key,
            entry.encrypt_certificate.ciphertext,
            entry.encrypt_certificate.associated_data,
            entry.encrypt_certificate.nonce,
        ) catch return error.CertParseFailed;
        errdefer allocator.free(cert_pem);

        const public_key_pem = publicKeyPemFromCertificate(allocator, cert_pem) catch
            return error.CertParseFailed;
        errdefer allocator.free(public_key_pem);

        const serial_no = try allocator.dupe(u8, entry.serial_no);
        errdefer allocator.free(serial_no);

        try list.append(allocator, .{
            .serial_no = serial_no,
            .cert_pem = cert_pem,
            .public_key_pem = public_key_pem,
        });
    }

    return list.toOwnedSlice(allocator);
}

/// 释放 [`parseCertificates`] 返回的切片（含内部各字段）。
pub fn freeCertificates(allocator: std.mem.Allocator, certs: []PlatformCert) void {
    for (certs) |*c| c.deinit(allocator);
    allocator.free(certs);
}

fn freeCertList(allocator: std.mem.Allocator, list: *std.ArrayList(PlatformCert)) void {
    for (list.items) |*c| c.deinit(allocator);
    list.deinit(allocator);
}

// -----------------------------------------------------------------------------
// 平台证书缓存
// -----------------------------------------------------------------------------

/// 平台证书存储：拉取 `/v3/certificates`、解密、按 `serial_no` 建缓存。
///
/// 内存归 `init` 传入的 allocator 管；`deinit` 释放全部缓存。
///
/// **非线程安全**：`refresh` 会整体替换 `certs`。回调通常由多线程 Web 框架处理，
/// 跨线程共享同一实例时请自行串行化（或用每线程一个实例）——否则 `certs`
/// 会出现数据竞争。并发未命中同一序列号时也只会多打几次 `/v3/certificates`
/// （官方限频 1000 次/s·商户号），不影响正确性。
pub const PlatformCertStore = struct {
    /// 长期持有，用于证书缓存。
    allocator: std.mem.Allocator,
    cfg: Config,
    /// 驱动取时 / 取随机的 `Io`（签名 `Authorization` 头需要）。可注入。
    io: std.Io = default_io.io(),
    /// 可注入 transport（测试用，拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,
    /// 带请求头的 mock transport（测试用）：设置后优先于 `transport`。
    header_transport: ?util_http.HeaderTransport = null,
    /// 当前缓存的平台证书（覆盖式刷新）。
    certs: []PlatformCert = &.{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Self {
        return .{ .allocator = allocator, .cfg = cfg };
    }

    pub fn deinit(self: *Self) void {
        self.clear();
    }

    /// 清空缓存（`deinit` 与刷新前都会调用）。
    pub fn clear(self: *Self) void {
        freeCertificates(self.allocator, self.certs);
        self.certs = &.{};
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTPS）。与 `setHeaderTransport` 互斥。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.header_transport = null;
        self.transport_ctx = ctx;
    }

    /// 注入带请求头的 mock transport（`null` 仅清除它）。与 `setTransport` 互斥。
    pub fn setHeaderTransport(self: *Self, t: ?util_http.HeaderTransport, ctx: ?*anyopaque) void {
        self.header_transport = t;
        self.transport = null;
        self.transport_ctx = ctx;
    }

    fn hasTransport(self: *const Self) bool {
        return self.transport != null or self.header_transport != null;
    }

    /// 已缓存的平台证书张数。
    pub fn count(self: *const Self) usize {
        return self.certs.len;
    }

    /// 按序列号查缓存（**不触发网络**）；返回的指针在下次 `refresh`/`clear` 前有效。
    pub fn find(self: *const Self, serial_no: []const u8) ?*const PlatformCert {
        for (self.certs) |*c| {
            if (std.mem.eql(u8, c.serial_no, serial_no)) return c;
        }
        return null;
    }

    /// 调 `GET /v3/certificates` 拉取当前可用平台证书，逐张解密后**覆盖**缓存。
    ///
    /// 官方要求定期刷新（间隔 < 12 小时），禁止硬编码平台证书。
    pub fn refresh(self: *Self) !void {
        if (self.cfg.api_v3_key.len != 32) return error.ApiV3KeyRequired;
        if (self.cfg.private_key_pem.len == 0) return error.MissingPrivateKey;
        if (self.cfg.mch_id.len == 0) return error.MissingMchId;
        if (self.hasTransport() and self.transport_ctx == null) return error.ConfigMissing;

        var sign = try signer.buildAuthorizationHeaderWithIo(
            self.allocator,
            self.io,
            self.cfg,
            "GET",
            certificates_path,
            "",
        );
        defer sign.deinit(self.allocator);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = sign.authorization },
            .{ .name = "Accept", .value = "application/json" },
        };

        var client = util_http.HttpClient.init(self.allocator);
        defer client.deinit();
        if (self.header_transport) |t| {
            client.setHeaderTransport(t, self.transport_ctx);
        } else {
            client.setTransport(self.transport, self.transport_ctx);
        }

        var resp = client.requestWithHeaders(
            .GET,
            base_url ++ certificates_path,
            "",
            null,
            &headers,
        ) catch return error.PlatformCertFetchFailed;
        defer resp.deinit(self.allocator);

        if (resp.status != .ok) return error.PlatformCertFetchFailed;

        const fresh = try parseCertificates(self.allocator, self.cfg.api_v3_key, resp.body);
        self.clear();
        self.certs = fresh;
    }

    /// 取 `serial_no` 对应的平台证书：命中缓存直接返回，**未命中则拉取一次证书
    /// 列表后重试一次**（应对微信支付轮换平台证书）。
    pub fn certificateForSerial(self: *Self, serial_no: []const u8) !*const PlatformCert {
        if (self.find(serial_no)) |c| return c;
        try self.refresh();
        return self.find(serial_no) orelse error.SerialNotFound;
    }
};

// -----------------------------------------------------------------------------
// PEM 编解码
// -----------------------------------------------------------------------------

/// 解码 PEM 块（忽略换行/空白），返回 DER 字节（调用方释放）。
fn pemDecode(allocator: std.mem.Allocator, pem: []const u8, label: []const u8) ![]u8 {
    const begin_marker = try allocator.print("-----BEGIN {s}-----", .{label});
    defer allocator.free(begin_marker);
    const end_marker = try allocator.print("-----END {s}-----", .{label});
    defer allocator.free(end_marker);

    const begin = std.mem.find(u8, pem, begin_marker) orelse return error.CertParseFailed;
    const body_start = begin + begin_marker.len;
    const end = std.mem.findPos(u8, pem, body_start, end_marker) orelse return error.CertParseFailed;

    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(allocator);
    for (pem[body_start..end]) |c| {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') continue;
        try b64.append(allocator, c);
    }
    if (b64.items.len == 0) return error.CertParseFailed;

    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(b64.items) catch return error.CertParseFailed;
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    decoder.decode(out, b64.items) catch return error.CertParseFailed;
    return out;
}

/// 把 DER 编码为 PEM（base64 每行 64 字符，尾随换行）。
fn encodePem(allocator: std.mem.Allocator, label: []const u8, der: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "-----BEGIN ");
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, "-----\n");

    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(der.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, der);

    var i: usize = 0;
    while (i < b64.len) : (i += 64) {
        const n = @min(64, b64.len - i);
        try out.appendSlice(allocator, b64[i .. i + n]);
        try out.append(allocator, '\n');
    }

    try out.appendSlice(allocator, "-----END ");
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, "-----");
    return out.toOwnedSlice(allocator);
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

const rsa = @import("../../util/rsa.zig");

/// 测试用 RSA 私钥（1024-bit，一次性生成的公开 throwaway 密钥；`util/rsa.zig`
/// 与 `pay/v3/{signer,refund,order}.zig` 的测试用的是同一把）。
pub const test_private_key_pkcs1 =
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

/// 自签平台证书（自造，**仅用于离线测试**）：CN=Tenpay.com，公钥对应上面那把
/// 私钥。由 `openssl req -x509 -new -key <上面的 PEM> -sha256 -subj
/// "/CN=Tenpay.com/O=Tenpay/OU=WXPay"` 生成，不含任何真实凭据。
pub const test_platform_cert_pem =
    "-----BEGIN CERTIFICATE-----\n" ++
    "MIICVTCCAb6gAwIBAgIUeRhT2yA2rmv6PfmblzXIIL97lW0wDQYJKoZIhvcNAQEL\n" ++
    "BQAwNjETMBEGA1UEAwwKVGVucGF5LmNvbTEPMA0GA1UECgwGVGVucGF5MQ4wDAYD\n" ++
    "VQQLDAVXWFBheTAeFw0yNjEwMDgwMjU5MDJaFw00NjEwMDMwMjU5MDJaMDYxEzAR\n" ++
    "BgNVBAMMClRlbnBheS5jb20xDzANBgNVBAoMBlRlbnBheTEOMAwGA1UECwwFV1hQ\n" ++
    "YXkwgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBAN4R80FQzwt1WDJsKZ4/LOqr\n" ++
    "grgl4hM7S1IjdyMtUhTRY2Of79ldCSnbCfFHDLut6Om1xnnZVKKwGRnbg7aeZDWa\n" ++
    "CBFDraoeIyo4l18EKvl5ghwL6cGFlMwJd6iTMZc1CBYdJhJ6q6PdvQhAtb9Qm6jL\n" ++
    "guyEbr37de1w5YVOK2PrAgMBAAGjYDBeMB0GA1UdDgQWBBRRdPkk3j3BIjPwuWrH\n" ++
    "Se60AV3VQjAfBgNVHSMEGDAWgBRRdPkk3j3BIjPwuWrHSe60AV3VQjAMBgNVHRMB\n" ++
    "Af8EAjAAMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOBgQDNyUPdpomT\n" ++
    "jsGx5vPqrJr9+/am/Zy8G4C9oLl3SBgYLC1VnbB1kfk0ms9APfpVN3dbA+IK+oZx\n" ++
    "KKU6COR0/lkCy22CDA3Bg/zqlIfD5lcxLXAOvuawp13BICcZNPuGnFy6TrZPwghq\n" ++
    "N6IRdnFXKBKlvlTzZXGoocx68IbqC/FzmQ==\n" ++
    "-----END CERTIFICATE-----";

test "publicKeyPemFromCertificate 从自签平台证书提取公钥并可用于 rsaVerify" {
    const allocator = std.testing.allocator;

    const pub_pem = try publicKeyPemFromCertificate(allocator, test_platform_cert_pem);
    defer allocator.free(pub_pem);

    try std.testing.expect(std.mem.startsWith(u8, pub_pem, "-----BEGIN RSA PUBLIC KEY-----"));
    try std.testing.expect(std.mem.endsWith(u8, pub_pem, "-----END RSA PUBLIC KEY-----"));

    // 提取出的公钥必须真的能验签（不是「看起来像 PEM」就算数）。
    const msg = "1700000000\nnonce-abc\n{\"id\":\"EV-1\"}\n";
    const raw_sig = try rsa.rsaSign(allocator, msg, test_private_key_pkcs1);
    defer allocator.free(raw_sig);
    const sig_b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw_sig.len));
    defer allocator.free(sig_b64);
    _ = std.base64.standard.Encoder.encode(sig_b64, raw_sig);

    try std.testing.expect(try rsa.rsaVerify(allocator, msg, sig_b64, pub_pem));
    try std.testing.expect(!try rsa.rsaVerify(allocator, "tampered", sig_b64, pub_pem));
}

test "publicKeyPemFromCertificate 公钥 PEM 原样透传，非法输入报错" {
    const allocator = std.testing.allocator;
    const pub_pem_in =
        "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDe\n-----END PUBLIC KEY-----";
    const out = try publicKeyPemFromCertificate(allocator, pub_pem_in);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(pub_pem_in, out);

    try std.testing.expectError(
        error.UnsupportedKeyFormat,
        publicKeyPemFromCertificate(allocator, "-----BEGIN EC PRIVATE KEY-----\nAA==\n-----END EC PRIVATE KEY-----"),
    );

    // 头部像证书但 base64 解不出 → CertParseFailed（不 panic、不返回半个结果）。
    try std.testing.expectError(
        error.CertParseFailed,
        publicKeyPemFromCertificate(
            allocator,
            "-----BEGIN CERTIFICATE-----\nnot-base64!!!\n-----END CERTIFICATE-----",
        ),
    );
}

/// 把明文按 AES-256-GCM 加密并 base64（末尾拼 16 字节 tag），模拟微信下发的
/// `encrypt_certificate.ciphertext` / `resource.ciphertext`。
pub fn encryptResourceB64(
    allocator: std.mem.Allocator,
    api_v3_key: []const u8,
    nonce: []const u8,
    associated_data: []const u8,
    plaintext: []const u8,
) ![]u8 {
    const key: [32]u8 = api_v3_key[0..32].*;
    const nonce_bytes: [12]u8 = nonce[0..12].*;

    const cipher = try allocator.alloc(u8, plaintext.len);
    defer allocator.free(cipher);
    var tag: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(cipher, &tag, plaintext, associated_data, nonce_bytes, key);

    const full = try allocator.alloc(u8, plaintext.len + 16);
    defer allocator.free(full);
    @memcpy(full[0..plaintext.len], cipher);
    @memcpy(full[plaintext.len..], &tag);

    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(full.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, full);
    return allocator.dupe(u8, b64);
}

/// 构造一份 `GET /v3/certificates` 应答（证书内容用上面那把 APIv3 密钥加密）。
pub fn buildCertificatesResponse(
    allocator: std.mem.Allocator,
    api_v3_key: []const u8,
    serial_no: []const u8,
) ![]u8 {
    const ciphertext = try encryptResourceB64(
        allocator,
        api_v3_key,
        "certnonce123",
        "certificate",
        test_platform_cert_pem,
    );
    defer allocator.free(ciphertext);

    return allocator.print(
        "{{\"data\":[{{\"serial_no\":\"{s}\",\"effective_time\":\"2026-01-01T00:00:00+08:00\"," ++
            "\"expire_time\":\"2031-01-01T00:00:00+08:00\",\"encrypt_certificate\":{{" ++
            "\"algorithm\":\"AEAD_AES_256_GCM\",\"nonce\":\"certnonce123\"," ++
            "\"associated_data\":\"certificate\",\"ciphertext\":\"{s}\"}}}}]}}",
        .{ serial_no, ciphertext },
    );
}

test "parseCertificates 解密 /v3/certificates 应答并按序列号建索引" {
    const allocator = std.testing.allocator;
    const key = "12345678901234567890123456789012";
    const body = try buildCertificatesResponse(allocator, key, "5157F09EFDC096DE15EBE81A47057A7232F1B8E1");
    defer allocator.free(body);

    const certs = try parseCertificates(allocator, key, body);
    defer freeCertificates(allocator, certs);

    try std.testing.expectEqual(@as(usize, 1), certs.len);
    try std.testing.expectEqualStrings("5157F09EFDC096DE15EBE81A47057A7232F1B8E1", certs[0].serial_no);
    try std.testing.expectEqualStrings(test_platform_cert_pem, certs[0].cert_pem);
    try std.testing.expect(std.mem.startsWith(u8, certs[0].public_key_pem, "-----BEGIN RSA PUBLIC KEY-----"));

    // 错误密钥（GCM 认证失败）→ CertParseFailed，且不泄漏。
    const wrong_key = "abcdefghijklmnopqrstuvwxyz012345";
    try std.testing.expectError(error.CertParseFailed, parseCertificates(allocator, wrong_key, body));

    // APIv3 密钥长度不对 → 立即拒绝。
    try std.testing.expectError(error.ApiV3KeyRequired, parseCertificates(allocator, "short", body));
}
