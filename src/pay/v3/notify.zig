// SPDX-License-Identifier: Apache-2.0
//! pay/v3/notify — 微信支付 v3 通知回调：**验签 + 解密**
//!
//! APIv3 回调的正确校验链是两步，缺一不可：
//!
//! 1. **验签**（本模块新增）：保证"回调确实来自微信支付、且报文体未被篡改"；
//! 2. **解密**（本模块原有）：用 APIv3 密钥做 AEAD_AES_256_GCM 解密 `resource`，
//!    保证密文完整性。
//!
//! 只做 ② 无法确认报文来源——任何人构造一份 GCM 密文都能让解密"成功"。
//!
//! 依据官方文档：
//! - 支付成功回调通知（含回调头与应答要求）<https://pay.weixin.qq.com/doc/v3/merchant/4012791861>
//! - 如何使用平台证书验签名（待签名串、时间戳窗口、探测流量）<https://pay.weixin.qq.com/doc/v3/merchant/4013053420>
//! - 下载平台证书 <https://pay.weixin.qq.com/doc/v3/merchant/4012551764>
//!
//! 待签名串（三行，行尾各一个 `\n`，**包括最后一行**）：
//!
//! ```text
//! Wechatpay-Timestamp\n
//! Wechatpay-Nonce\n
//! 应答/回调报文主体\n
//! ```
//!
//! 官方另有两点要求，本模块已实现：
//! - **时间戳窗口**：建议最多允许 5 分钟偏差（[`NotifyVerifier.default_max_timestamp_skew_seconds`]），
//!   超出即拒（防重放）；
//! - **签名探测流量**：极少数回调的签名值以 `WECHATPAY/SIGNTEST/` 开头，商户**不得特殊处理**，
//!   而是照常验签、失败即视为验签失败（`error.SignatureInvalid`）。
//!
//! 加密算法部分（`decryptNotifyResource`）使用 Zig 原生
//! `std.crypto.aead.aes_gcm.Aes256Gcm`，纯 Zig、零 C 依赖。

const std = @import("std");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const Config = @import("config.zig").Config;
const platform_cert = @import("platform_cert.zig");
const rsa = @import("../../util/rsa.zig");
const time = @import("../../util/time.zig");
const util_http = @import("../../util/http.zig");
const default_io = @import("../../util/default_io.zig");

// -----------------------------------------------------------------------------
// 回调报文结构
// -----------------------------------------------------------------------------

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

// -----------------------------------------------------------------------------
// 验签
// -----------------------------------------------------------------------------

/// 回调报文的四个签名请求头（名字取自 `Wechatpay-*`）。
pub const NotifyHeaders = struct {
    /// `Wechatpay-Signature`：base64 的签名值。
    signature: []const u8 = "",
    /// `Wechatpay-Timestamp`：签名时间戳（秒级 Unix 时间）。
    timestamp: []const u8 = "",
    /// `Wechatpay-Nonce`：签名随机串。
    nonce: []const u8 = "",
    /// `Wechatpay-Serial`：平台证书序列号（或 `PUB_KEY_ID_xxx` 形式的公钥 ID）。
    serial: []const u8 = "",
    /// `Wechatpay-Signature-Type`：目前恒为 `WECHATPAY2-SHA256-RSA2048`（可缺省）。
    signature_type: []const u8 = "",

    /// 从 HTTP 请求头里按名字（大小写不敏感）挑出四个签名头。
    ///
    /// 缺哪个就留空，由 [`verifySignature`] 统一报 `error.MissingSignatureHeader`。
    pub fn fromHeaders(headers: []const std.http.Header) NotifyHeaders {
        var out = NotifyHeaders{};
        for (headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Wechatpay-Signature")) {
                out.signature = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "Wechatpay-Timestamp")) {
                out.timestamp = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "Wechatpay-Nonce")) {
                out.nonce = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "Wechatpay-Serial")) {
                out.serial = h.value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "Wechatpay-Signature-Type")) {
                out.signature_type = h.value;
            }
        }
        return out;
    }
};

/// v3 回调验签 / 解密错误集。
///
/// 验签失败时**不要**给微信回 200——官方要求返回 4xx/5xx 等待重发（见模块文档）。
pub const NotifyError = error{
    /// 缺少 `Wechatpay-*` 四个签名头中的至少一个。
    MissingSignatureHeader,
    /// 时间戳不是合法的整数秒。
    InvalidTimestamp,
    /// 时间戳偏差超出允许窗口（默认 ±300s），按重放处理。
    TimestampOutOfWindow,
    /// 验签未通过（含 `WECHATPAY/SIGNTEST/` 探测流量）。
    SignatureInvalid,
    /// 拉取到的平台证书列表里没有该序列号。
    SerialNotFound,
    /// 平台证书列表拉取失败（网络 / HTTP 状态码非 200）。
    PlatformCertFetchFailed,
    /// 平台证书解密或解析失败。
    CertParseFailed,
    /// `cfg.api_v3_key` 未配置或不是 32 字节。
    ApiV3KeyRequired,
    /// `cfg.private_key_pem` 未配置（无法签名 `/v3/certificates` 请求）。
    MissingPrivateKey,
    /// `cfg.mch_id` 未配置。
    MissingMchId,
    /// 配置缺失 / 注入了 transport 但没给 ctx。
    ConfigMissing,
    OutOfMemory,
};

/// 默认允许的时间戳偏差（秒）：官方建议"最多 5 分钟"。
pub const default_max_timestamp_skew_seconds: i64 = 300;

/// 微信支付公钥 ID 的前缀（官方文档：公钥 ID 形如 `PUB_KEY_ID_3000000001`）。
pub const pub_key_id_prefix = "PUB_KEY_ID_";

/// 用平台证书/公钥 PEM 校验回调签名（**纯函数，不触网**）。
///
/// `public_key_pem` 可以是 `-----BEGIN CERTIFICATE-----` 平台证书本体，也可以是
/// 已提取好的公钥 PEM——两种形态都会先经
/// [`platform_cert.publicKeyPemFromCertificate`] 归一。
///
/// 使用默认 `Io` 取当前时间；需要注入 `Io` 时用 [`verifySignatureWithIo`]。
pub fn verifySignature(
    allocator: std.mem.Allocator,
    headers: NotifyHeaders,
    body: []const u8,
    public_key_pem: []const u8,
) NotifyError!void {
    return verifySignatureWithIo(
        allocator,
        default_io.io(),
        headers,
        body,
        public_key_pem,
        default_max_timestamp_skew_seconds,
    );
}

/// 同 [`verifySignature`]，但由调用方注入取时的 `Io` 并指定时间戳窗口。
pub fn verifySignatureWithIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    headers: NotifyHeaders,
    body: []const u8,
    public_key_pem: []const u8,
    max_timestamp_skew_seconds: i64,
) NotifyError!void {
    try checkHeadersAndTimestamp(io, headers, max_timestamp_skew_seconds);

    // 待签名串：timestamp\nnonce\nbody\n（最后一行也要有换行符）
    const message = try allocator.print("{s}\n{s}\n{s}\n", .{
        headers.timestamp,
        headers.nonce,
        body,
    });
    defer allocator.free(message);

    // 归一为公钥 PEM（平台证书 / 微信支付公钥 / 裸公钥都接受）。
    const raw_key = platform_cert.publicKeyPemFromCertificate(allocator, public_key_pem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CertParseFailed,
    };
    defer allocator.free(raw_key);

    const ok = rsa.rsaVerify(allocator, message, headers.signature, raw_key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPemKey => return error.CertParseFailed,
        // 含探测流量的 `WECHATPAY/SIGNTEST/...`（base64 解不出）与真实验签不过。
        else => return error.SignatureInvalid,
    };
    if (!ok) return error.SignatureInvalid;
}

/// 不需要公钥的两项检查：四个签名头齐全 + 时间戳在窗口内。
///
/// 单独抽出来是为了让 [`NotifyVerifier.verify`] 在**拉取平台证书之前**就拒掉
/// 缺头/超窗的回调，不必为此多打一次 `/v3/certificates`。
fn checkHeadersAndTimestamp(io: std.Io, headers: NotifyHeaders, max_timestamp_skew_seconds: i64) NotifyError!void {
    if (headers.signature.len == 0 or headers.timestamp.len == 0 or
        headers.nonce.len == 0 or headers.serial.len == 0)
        return error.MissingSignatureHeader;

    const timestamp = std.fmt.parseInt(i64, headers.timestamp, 10) catch
        return error.InvalidTimestamp;

    // 防重放：|now - timestamp| 不得超过窗口（用 i128 避免 i64 极端值溢出）。
    const delta = @as(i128, time.getCurrTSWithIo(io)) - @as(i128, timestamp);
    const limit: i128 = max_timestamp_skew_seconds;
    if (delta > limit or delta < -limit) return error.TimestampOutOfWindow;
}

// -----------------------------------------------------------------------------
// 解密
// -----------------------------------------------------------------------------

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

// -----------------------------------------------------------------------------
// 验签 + 解密一站式入口
// -----------------------------------------------------------------------------

/// 验签通过且已解密的回调。
///
/// `deinit` 释放 `plaintext` 与 `body`（两者都归调用方）。
pub const VerifiedNotify = struct {
    /// 回调信封（`id` / `event_type` / `summary` / `resource` …）。
    body: std.json.Parsed(NotifyResponseBody),
    /// `resource.ciphertext` 解密后的业务明文 JSON。
    ///
    /// 业务结构由调用方按 `event_type` 自行解析（如支付成功用
    /// `pay/v3/order` 的交易结构，退款用 `RefundNotifyResource`）。
    plaintext: []u8,

    pub fn deinit(self: *VerifiedNotify, allocator: std.mem.Allocator) void {
        allocator.free(self.plaintext);
        self.body.deinit();
        self.* = undefined;
    }
};

/// 回调验签 + 解密协调器：持有一份平台证书缓存。
///
/// 用法：
/// ```zig
/// var verifier = NotifyVerifier.init(allocator, cfg);
/// defer verifier.deinit();
/// var verified = try verifier.verifyAndDecrypt(allocator, NotifyHeaders.fromHeaders(req.headers), body);
/// defer verified.deinit(allocator);
/// ```
///
/// 验签失败时**不要**应答 200：官方要求返回 4xx/5xx，让微信支付携带正确签名重发。
///
/// **非线程安全**（内部平台证书缓存会被 `refresh` 整体替换）：多线程 Web 框架下
/// 请串行化回调处理，或每个线程各持一个实例。实例跨线程移动是安全的。
/// 回调须在 5 秒内应答（官方要求），因此验签失败时请立刻回 4xx/5xx，
/// 业务处理（改订单状态等）建议异步做。
pub const NotifyVerifier = struct {
    cfg: Config,
    /// 平台证书缓存（内存归 `init` 的 allocator）。
    store: platform_cert.PlatformCertStore,
    /// 取时用的 `Io`（时间戳窗口校验）。可注入。
    io: std.Io = default_io.io(),
    /// 允许的时间戳偏差（秒），默认 300。
    max_timestamp_skew_seconds: i64 = default_max_timestamp_skew_seconds,
    /// 微信支付公钥（PEM，`-----BEGIN PUBLIC KEY-----`）。
    ///
    /// 非空且 `Wechatpay-Serial` 形如 `PUB_KEY_ID_xxx` 时，直接用它验签，不查平台
    /// 证书——这是微信支付正在推广的「公钥模式」。为空（默认）时公钥 ID 的回调会
    /// 走平台证书路径并最终 `SerialNotFound`。
    wechatpay_public_key_pem: []const u8 = "",

    const Self = @This();

    /// `allocator` 由平台证书缓存长期持有，直到 `deinit`。
    pub fn init(allocator: std.mem.Allocator, cfg: Config) Self {
        return .{
            .cfg = cfg,
            .store = platform_cert.PlatformCertStore.init(allocator, cfg),
        };
    }

    pub fn deinit(self: *Self) void {
        self.store.deinit();
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTPS）。与 `setHeaderTransport` 互斥。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.store.setTransport(t, ctx);
    }

    /// 注入带请求头的 mock transport（`null` 仅清除它）。与 `setTransport` 互斥。
    pub fn setHeaderTransport(self: *Self, t: ?util_http.HeaderTransport, ctx: ?*anyopaque) void {
        self.store.setHeaderTransport(t, ctx);
    }

    /// 已缓存的平台证书张数。
    pub fn cachedCertCount(self: *const Self) usize {
        return self.store.count();
    }

    /// 只验签（不解密）。
    ///
    /// `Wechatpay-Serial` 是平台证书序列号时：命中缓存直接验；未命中则**拉取一次**
    /// `/v3/certificates` 后重试一次（微信支付会不定期轮换平台证书）。
    ///
    /// `Wechatpay-Serial` 是 `PUB_KEY_ID_xxx`（微信支付公钥模式）时：用
    /// [`NotifyVerifier.wechatpay_public_key_pem`] 验签，**不拉取平台证书**。
    pub fn verify(self: *Self, headers: NotifyHeaders, body: []const u8) NotifyError!void {
        // 先做不需要公钥的检查（头齐全 + 时间戳窗口），避免头缺失/超窗时白白拉一次证书。
        try checkHeadersAndTimestamp(self.io, headers, self.max_timestamp_skew_seconds);

        const key_pem = if (self.wechatpay_public_key_pem.len > 0 and
            std.mem.startsWith(u8, headers.serial, pub_key_id_prefix))
            self.wechatpay_public_key_pem
        else blk: {
            const cert = self.store.certificateForSerial(headers.serial) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.SerialNotFound => return error.SerialNotFound,
                error.ApiV3KeyRequired => return error.ApiV3KeyRequired,
                error.MissingPrivateKey => return error.MissingPrivateKey,
                error.MissingMchId => return error.MissingMchId,
                error.ConfigMissing => return error.ConfigMissing,
                else => return error.PlatformCertFetchFailed,
            };
            break :blk cert.public_key_pem;
        };

        return verifySignatureWithIo(
            self.store.allocator,
            self.io,
            headers,
            body,
            key_pem,
            self.max_timestamp_skew_seconds,
        );
    }

    /// 验签 + 解密：**推荐的回调处理入口**。
    ///
    /// 任一环节失败都不应给微信回 200（官方要求 4xx/5xx 等待重发）。
    pub fn verifyAndDecrypt(
        self: *Self,
        allocator: std.mem.Allocator,
        headers: NotifyHeaders,
        body: []const u8,
    ) !VerifiedNotify {
        try self.verify(headers, body);

        const parsed = std.json.parseFromSlice(NotifyResponseBody, allocator, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.DecodeError;
        errdefer parsed.deinit();

        const plaintext = try decryptNotifyResource(
            allocator,
            self.cfg.api_v3_key,
            parsed.value.resource.ciphertext,
            parsed.value.resource.associated_data,
            parsed.value.resource.nonce,
        );

        return .{ .body = parsed, .plaintext = plaintext };
    }
};

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

const test_api_v3_key = "12345678901234567890123456789012";
const test_serial = "5157F09EFDC096DE15EBE81A47057A7232F1B8E1";
const test_now: i64 = 1_700_000_000;

/// 冻结时钟的 `Io`：`now` 恒返回 `test_now`，`random` 恒填 `0xAB`。
const FixedIo = struct {
    vtable: std.Io.VTable = undefined,

    fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        return .{ .nanoseconds = @as(i96, test_now) * std.time.ns_per_s };
    }

    fn random(_: ?*anyopaque, buf: []u8) void {
        @memset(buf, 0xAB);
    }

    fn io(self: *FixedIo) std.Io {
        self.vtable = default_io.io().vtable.*;
        self.vtable.now = now;
        self.vtable.random = random;
        return .{ .userdata = null, .vtable = &self.vtable };
    }
};

/// 记录请求（方法 / URL / body / 头），并返回预置应答。
///
/// `responses` 按调用次序依次返回（末条会重复返回），用来模拟"证书轮换"。
const CertTransport = struct {
    responses: []const []const u8,
    calls: usize = 0,
    last_uri_buf: [512]u8 = undefined,
    last_uri_len: usize = 0,
    last_method: std.http.Method = .GET,
    names: [8][64]u8 = undefined,
    values: [8][512]u8 = undefined,
    name_lens: [8]usize = @splat(0),
    value_lens: [8]usize = @splat(0),
    header_count: usize = 0,

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
        headers: []const std.http.Header,
    ) anyerror![]u8 {
        _ = payload;
        _ = content_type;
        const self: *CertTransport = @ptrCast(@alignCast(ctx));

        const ulen = @min(uri.len, self.last_uri_buf.len);
        @memcpy(self.last_uri_buf[0..ulen], uri[0..ulen]);
        self.last_uri_len = ulen;
        self.last_method = method;

        self.header_count = @min(headers.len, self.names.len);
        for (headers[0..self.header_count], 0..) |h, i| {
            const nl = @min(h.name.len, self.names[i].len);
            @memcpy(self.names[i][0..nl], h.name[0..nl]);
            self.name_lens[i] = nl;
            const vl = @min(h.value.len, self.values[i].len);
            @memcpy(self.values[i][0..vl], h.value[0..vl]);
            self.value_lens[i] = vl;
        }

        const idx = @min(self.calls, self.responses.len - 1);
        self.calls += 1;
        return allocator.dupe(u8, self.responses[idx]);
    }

    fn headerValue(self: *const CertTransport, name: []const u8) ?[]const u8 {
        for (0..self.header_count) |i| {
            if (std.ascii.eqlIgnoreCase(self.names[i][0..self.name_lens[i]], name))
                return self.values[i][0..self.value_lens[i]];
        }
        return null;
    }

    fn lastUri(self: *const CertTransport) []const u8 {
        return self.last_uri_buf[0..self.last_uri_len];
    }
};

const TestCfg = Config{
    .app_id = "wx-v3-notify",
    .mch_id = "1900000109",
    .api_v3_key = test_api_v3_key,
    .serial_no = "1DDE557876238",
    .private_key_pem = platform_cert.test_private_key_pkcs1,
};

fn base64Signature(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const raw = try rsa.rsaSign(allocator, message, platform_cert.test_private_key_pkcs1);
    defer allocator.free(raw);
    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    _ = std.base64.standard.Encoder.encode(b64, raw);
    return b64;
}

/// 构造一份支付成功回调 body（`resource` 用 APIv3 密钥加密），并给出 biz 明文。
fn buildNotifyBody(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
) ![]u8 {
    const ciphertext = try platform_cert.encryptResourceB64(
        allocator,
        test_api_v3_key,
        "resource1234",
        "transaction",
        plaintext,
    );
    defer allocator.free(ciphertext);

    return allocator.print(
        "{{\"id\":\"EV-2018022511223320873\",\"create_time\":\"2015-05-20T13:29:35+08:00\"," ++
            "\"resource_type\":\"encrypt-resource\",\"event_type\":\"TRANSACTION.SUCCESS\"," ++
            "\"summary\":\"支付成功\",\"resource\":{{\"original_type\":\"transaction\"," ++
            "\"algorithm\":\"AEAD_AES_256_GCM\",\"ciphertext\":\"{s}\"," ++
            "\"associated_data\":\"transaction\",\"nonce\":\"resource1234\"}}}}",
        .{ciphertext},
    );
}

/// 为 `body` 造一组合法签名头（时间戳固定为 `test_now`）。
fn signHeaders(
    allocator: std.mem.Allocator,
    serial: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    body: []const u8,
) !NotifyHeaders {
    const message = try allocator.print("{s}\n{s}\n{s}\n", .{ timestamp, nonce, body });
    defer allocator.free(message);
    const sig = try base64Signature(allocator, message);
    return .{ .signature = sig, .timestamp = timestamp, .nonce = nonce, .serial = serial };
}

test "NotifyVerifier.verifyAndDecrypt 验签 + 解密全链路（平台证书自动拉取并缓存）" {
    const allocator = std.testing.allocator;

    const cert_resp = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, test_serial);
    defer allocator.free(cert_resp);
    const responses = [_][]const u8{cert_resp};

    var transport = CertTransport{ .responses = &responses };
    var fixed = FixedIo{};

    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();
    verifier.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    const biz = "{\"mchid\":\"1900000109\",\"out_trade_no\":\"20260722001\",\"trade_state\":\"SUCCESS\"}";
    const body = try buildNotifyBody(allocator, biz);
    defer allocator.free(body);

    const headers = try signHeaders(allocator, test_serial, "1700000000", "nonce-abc", body);
    defer allocator.free(@constCast(headers.signature));

    var verified = try verifier.verifyAndDecrypt(allocator, headers, body);
    defer verified.deinit(allocator);

    try std.testing.expectEqualStrings("TRANSACTION.SUCCESS", verified.body.value.event_type);
    try std.testing.expectEqualStrings("EV-2018022511223320873", verified.body.value.id);
    try std.testing.expectEqualStrings(biz, verified.plaintext);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), verifier.cachedCertCount());

    // 证书拉取请求必须是带签名的 GET /v3/certificates。
    try std.testing.expectEqual(std.http.Method.GET, transport.last_method);
    try std.testing.expectEqualStrings("https://api.mch.weixin.qq.com/v3/certificates", transport.lastUri());
    const auth = transport.headerValue("Authorization").?;
    try std.testing.expect(std.mem.startsWith(u8, auth, "WECHATPAY2-SHA256-RSA2048 "));
    try std.testing.expect(std.mem.find(u8, auth, "mchid=\"1900000109\"") != null);
    try std.testing.expectEqualStrings("application/json", transport.headerValue("Accept").?);

    // 第二次验签：命中缓存，不再拉取证书。
    const headers2 = try signHeaders(allocator, test_serial, "1700000000", "nonce-abc", body);
    defer allocator.free(@constCast(headers2.signature));
    try verifier.verify(headers2, body);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
}

test "NotifyVerifier 平台证书轮换：旧序列号命中缓存，新序列号触发一次重拉" {
    const allocator = std.testing.allocator;

    const old_serial = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const new_serial = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
    const resp_old = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, old_serial);
    defer allocator.free(resp_old);
    const resp_new = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, new_serial);
    defer allocator.free(resp_new);

    // 第 1 次调用返回旧证书；第 2 次起返回轮换后的新证书。
    const responses = [_][]const u8{ resp_old, resp_new };
    var transport = CertTransport{ .responses = &responses };
    var fixed = FixedIo{};

    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();
    verifier.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    const biz = "{\"trade_state\":\"SUCCESS\"}";
    const body = try buildNotifyBody(allocator, biz);
    defer allocator.free(body);

    // 旧序列号：首次未命中 → 拉一次 → 验签通过。
    const h1 = try signHeaders(allocator, old_serial, "1700000000", "n1", body);
    defer allocator.free(@constCast(h1.signature));
    try verifier.verify(h1, body);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expect(verifier.store.find(old_serial) != null);

    // 新序列号（微信轮换平台证书）：未命中 → 再拉一次 → 拿到新证书并验签通过。
    const h2 = try signHeaders(allocator, new_serial, "1700000000", "n2", body);
    defer allocator.free(@constCast(h2.signature));
    try verifier.verify(h2, body);
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expect(verifier.store.find(new_serial) != null);
    try std.testing.expectEqual(@as(usize, 1), verifier.cachedCertCount()); // 覆盖式刷新

    // 换回旧序列号：已不在缓存里（被刷新覆盖）→ 再拉一次拿到新列表 → SerialNotFound。
    const h3 = try signHeaders(allocator, old_serial, "1700000000", "n3", body);
    defer allocator.free(@constCast(h3.signature));
    try std.testing.expectError(error.SerialNotFound, verifier.verify(h3, body));
    try std.testing.expectEqual(@as(usize, 3), transport.calls);
}

test "负例①：篡改 body → SignatureInvalid" {
    const allocator = std.testing.allocator;
    const cert_resp = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, test_serial);
    defer allocator.free(cert_resp);
    const responses = [_][]const u8{cert_resp};
    var transport = CertTransport{ .responses = &responses };
    var fixed = FixedIo{};

    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();
    verifier.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    const body = try buildNotifyBody(allocator, "{\"trade_state\":\"SUCCESS\"}");
    defer allocator.free(body);

    const headers = try signHeaders(allocator, test_serial, "1700000000", "nonce-abc", body);
    defer allocator.free(@constCast(headers.signature));

    // 签名是对原 body 做的；把 body 改一个字节必须整体拒签。
    const tampered = try allocator.dupe(u8, body);
    defer allocator.free(tampered);
    tampered[tampered.len - 3] = 'X';

    try std.testing.expectError(error.SignatureInvalid, verifier.verifyAndDecrypt(allocator, headers, tampered));
}

test "负例②：Wechatpay-Serial 不在平台证书列表 → SerialNotFound" {
    const allocator = std.testing.allocator;
    const cert_resp = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, test_serial);
    defer allocator.free(cert_resp);
    const responses = [_][]const u8{cert_resp};
    var transport = CertTransport{ .responses = &responses };
    var fixed = FixedIo{};

    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();
    verifier.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    const body = try buildNotifyBody(allocator, "{\"trade_state\":\"SUCCESS\"}");
    defer allocator.free(body);

    const headers = try signHeaders(allocator, "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF", "1700000000", "n", body);
    defer allocator.free(@constCast(headers.signature));

    try std.testing.expectError(error.SerialNotFound, verifier.verify(headers, body));
    // 未命中会先拉一次证书列表（应对轮换），仍然找不到才报错。
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
}

test "负例③：时间戳超窗 → TimestampOutOfWindow（含 301 秒负例与探测流量前缀）" {
    const allocator = std.testing.allocator;
    const cert_resp = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, test_serial);
    defer allocator.free(cert_resp);
    const responses = [_][]const u8{cert_resp};
    var transport = CertTransport{ .responses = &responses };
    var fixed = FixedIo{};

    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();
    verifier.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    const body = try buildNotifyBody(allocator, "{\"trade_state\":\"SUCCESS\"}");
    defer allocator.free(body);

    // 早于 now 301 秒（窗口 300 秒）。
    const old = try signHeaders(allocator, test_serial, "1699999699", "n", body);
    defer allocator.free(@constCast(old.signature));
    try std.testing.expectError(error.TimestampOutOfWindow, verifier.verify(old, body));

    // 晚于 now 301 秒（未来时间戳同样拒）。
    const future = try signHeaders(allocator, test_serial, "1700000301", "n", body);
    defer allocator.free(@constCast(future.signature));
    try std.testing.expectError(error.TimestampOutOfWindow, verifier.verify(future, body));

    // 边界：恰好 300 秒（含）应放行。
    const edge = try signHeaders(allocator, test_serial, "1699999700", "n", body);
    defer allocator.free(@constCast(edge.signature));
    try verifier.verify(edge, body);

    // 非数字时间戳 → InvalidTimestamp。
    var bad = try signHeaders(allocator, test_serial, "1700000000", "n", body);
    defer allocator.free(@constCast(bad.signature));
    bad.timestamp = "not-a-number";
    try std.testing.expectError(error.InvalidTimestamp, verifier.verify(bad, body));
}

test "负例④：缺签名头 → MissingSignatureHeader（四种头各自缺失都拒绝）" {
    const allocator = std.testing.allocator;
    var fixed = FixedIo{};
    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();

    const body = "{}";
    const full = NotifyHeaders{
        .signature = "sig",
        .timestamp = "1700000000",
        .nonce = "n",
        .serial = test_serial,
    };

    try std.testing.expectError(error.MissingSignatureHeader, verifier.verify(NotifyHeaders{}, body));

    var no_sig = full;
    no_sig.signature = "";
    try std.testing.expectError(error.MissingSignatureHeader, verifier.verify(no_sig, body));

    var no_ts = full;
    no_ts.timestamp = "";
    try std.testing.expectError(error.MissingSignatureHeader, verifier.verify(no_ts, body));

    var no_nonce = full;
    no_nonce.nonce = "";
    try std.testing.expectError(error.MissingSignatureHeader, verifier.verify(no_nonce, body));

    var no_serial = full;
    no_serial.serial = "";
    try std.testing.expectError(error.MissingSignatureHeader, verifier.verify(no_serial, body));
}

test "签名探测流量 WECHATPAY/SIGNTEST/ 前缀按验签失败处理（不特殊放行）" {
    const allocator = std.testing.allocator;
    const cert_resp = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, test_serial);
    defer allocator.free(cert_resp);
    const responses = [_][]const u8{cert_resp};
    var transport = CertTransport{ .responses = &responses };
    var fixed = FixedIo{};

    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();
    verifier.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    const body = try buildNotifyBody(allocator, "{\"trade_state\":\"SUCCESS\"}");
    defer allocator.free(body);

    const headers = NotifyHeaders{
        .signature = "WECHATPAY/SIGNTEST/c0k+ZP6cSbveFpn0U5Bhq1Evz0A0rmmhGyuFXGqAtrlspDr3wrmaeauXJT6YYD4OmnDi767TImhRdV9hdmU0T5ZVfkOB/zka3mYthkxJ9V6UMoI",
        .timestamp = "1700000000",
        .nonce = "n",
        .serial = test_serial,
    };
    try std.testing.expectError(error.SignatureInvalid, verifier.verify(headers, body));
}

test "verifyAndDecrypt 缺 api_v3_key / 私钥时分别报错（不触网）" {
    const allocator = std.testing.allocator;
    const cert_resp = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, test_serial);
    defer allocator.free(cert_resp);
    const responses = [_][]const u8{cert_resp};
    var transport = CertTransport{ .responses = &responses };
    var fixed = FixedIo{};

    // 未配 api_v3_key：拉取证书前就拒绝。
    var no_key = NotifyVerifier.init(allocator, .{
        .app_id = "wx",
        .mch_id = "1900000109",
        .serial_no = "1",
        .private_key_pem = platform_cert.test_private_key_pkcs1,
    });
    defer no_key.deinit();
    no_key.io = fixed.io();
    no_key.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    const body = "{}";
    const h = try signHeaders(allocator, test_serial, "1700000000", "n", body);
    defer allocator.free(@constCast(h.signature));

    try std.testing.expectError(error.ApiV3KeyRequired, no_key.verify(h, body));
    try std.testing.expectEqual(@as(usize, 0), transport.calls);

    // 未配私钥：无法签名 `/v3/certificates` 请求。
    var no_pk = NotifyVerifier.init(allocator, .{
        .app_id = "wx",
        .mch_id = "1900000109",
        .api_v3_key = test_api_v3_key,
        .serial_no = "1",
    });
    defer no_pk.deinit();
    no_pk.io = fixed.io();
    no_pk.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    try std.testing.expectError(error.MissingPrivateKey, no_pk.verify(h, body));
    try std.testing.expectEqual(@as(usize, 0), transport.calls);
}

test "微信支付公钥模式（PUB_KEY_ID_）用配置的公钥验签，不拉取平台证书" {
    const allocator = std.testing.allocator;

    // 同一把自签证书里提取出的公钥：模拟商户在商户平台配置的「微信支付公钥」。
    const configured_pub = try platform_cert.publicKeyPemFromCertificate(
        allocator,
        platform_cert.test_platform_cert_pem,
    );
    defer allocator.free(configured_pub);

    const cert_resp = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, test_serial);
    defer allocator.free(cert_resp);
    const responses = [_][]const u8{cert_resp};
    var transport = CertTransport{ .responses = &responses };
    var fixed = FixedIo{};

    const body = "{\"id\":\"EV-1\"}";
    const pub_key_id = "PUB_KEY_ID_3000000001";
    const h = try signHeaders(allocator, pub_key_id, "1700000000", "n", body);
    defer allocator.free(@constCast(h.signature));

    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();
    verifier.wechatpay_public_key_pem = configured_pub;
    verifier.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));

    try verifier.verify(h, body);
    // 公钥模式完全不触网（0 次 /v3/certificates）。
    try std.testing.expectEqual(@as(usize, 0), transport.calls);

    // 没配公钥时，公钥 ID 会走平台证书路径 → 列表里找不到该序列号。
    var no_pub = NotifyVerifier.init(allocator, TestCfg);
    defer no_pub.deinit();
    no_pub.io = fixed.io();
    no_pub.setHeaderTransport(CertTransport.dispatch, @ptrCast(&transport));
    try std.testing.expectError(error.SerialNotFound, no_pub.verify(h, body));
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
}

test "NotifyHeaders.fromHeaders 大小写不敏感地挑出四个签名头" {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "wechatpay-signature", .value = "SIG" },
        .{ .name = "Wechatpay-Timestamp", .value = "1700000000" },
        .{ .name = "WECHATPAY-NONCE", .value = "N" },
        .{ .name = "Wechatpay-Serial", .value = "SER" },
        .{ .name = "Wechatpay-Signature-Type", .value = "WECHATPAY2-SHA256-RSA2048" },
    };
    const h = NotifyHeaders.fromHeaders(&headers);
    try std.testing.expectEqualStrings("SIG", h.signature);
    try std.testing.expectEqualStrings("1700000000", h.timestamp);
    try std.testing.expectEqualStrings("N", h.nonce);
    try std.testing.expectEqualStrings("SER", h.serial);
    try std.testing.expectEqualStrings("WECHATPAY2-SHA256-RSA2048", h.signature_type);

    const empty = NotifyHeaders.fromHeaders(&.{});
    try std.testing.expectEqualStrings("", empty.signature);
}

test "verifySignatureWithIo 纯函数入口（不触网）验签通过 / 篡改拒绝" {
    const allocator = std.testing.allocator;
    var fixed = FixedIo{};

    const pub_pem = try platform_cert.publicKeyPemFromCertificate(allocator, platform_cert.test_platform_cert_pem);
    defer allocator.free(pub_pem);

    const body = "{\"id\":\"EV-1\"}";
    const headers = try signHeaders(allocator, test_serial, "1700000000", "nonce-1", body);
    defer allocator.free(@constCast(headers.signature));

    try verifySignatureWithIo(allocator, fixed.io(), headers, body, pub_pem, default_max_timestamp_skew_seconds);
    try std.testing.expectError(
        error.SignatureInvalid,
        verifySignatureWithIo(allocator, fixed.io(), headers, "{\"id\":\"EV-2\"}", pub_pem, default_max_timestamp_skew_seconds),
    );
    // 平台证书本体也能直接当公钥用（内部先归一）。
    try verifySignatureWithIo(
        allocator,
        fixed.io(),
        headers,
        body,
        platform_cert.test_platform_cert_pem,
        default_max_timestamp_skew_seconds,
    );
}

test "verifySignature 默认 Io 入口：真实时钟窗口内通过 / 篡改拒绝 / 超窗拒绝" {
    const allocator = std.testing.allocator;
    const pub_pem = try platform_cert.publicKeyPemFromCertificate(allocator, platform_cert.test_platform_cert_pem);
    defer allocator.free(pub_pem);

    const body = "{\"id\":\"EV-1\"}";
    // `verifySignature` 内部用默认 Io 取当前时间，故这里必须用真实时钟（不能用 FixedIo）。
    const now = time.getCurrTSWithIo(default_io.io());
    var ts_buf: [24]u8 = undefined;
    const ts = try std.mem.print(&ts_buf, "{d}", .{now});
    const headers = try signHeaders(allocator, test_serial, ts, "nonce-1", body);
    defer allocator.free(@constCast(headers.signature));

    try verifySignature(allocator, headers, body, pub_pem);
    try std.testing.expectError(error.SignatureInvalid, verifySignature(allocator, headers, "{\"id\":\"EV-2\"}", pub_pem));

    // 同一签名的头，仅把时间戳换到窗口外 → TimestampOutOfWindow（防重放）。
    var old_buf: [24]u8 = undefined;
    const stale_ts = try std.mem.print(&old_buf, "{d}", .{now - 4000});
    const stale = try signHeaders(allocator, test_serial, stale_ts, "nonce-1", body);
    defer allocator.free(@constCast(stale.signature));
    try std.testing.expectError(error.TimestampOutOfWindow, verifySignature(allocator, stale, body, pub_pem));
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

test "NotifyError 错误集可穷举且默认窗口为 300 秒" {
    // 穷举 switch：错误集新增变体时这里会编译失败，提醒同步文档与下游。
    const e: NotifyError = error.SignatureInvalid;
    const label = switch (e) {
        error.MissingSignatureHeader => "MissingSignatureHeader",
        error.InvalidTimestamp => "InvalidTimestamp",
        error.TimestampOutOfWindow => "TimestampOutOfWindow",
        error.SignatureInvalid => "SignatureInvalid",
        error.SerialNotFound => "SerialNotFound",
        error.PlatformCertFetchFailed => "PlatformCertFetchFailed",
        error.CertParseFailed => "CertParseFailed",
        error.ApiV3KeyRequired => "ApiV3KeyRequired",
        error.MissingPrivateKey => "MissingPrivateKey",
        error.MissingMchId => "MissingMchId",
        error.ConfigMissing => "ConfigMissing",
        error.OutOfMemory => "OutOfMemory",
    };
    try std.testing.expectEqualStrings("SignatureInvalid", label);
    try std.testing.expectEqual(@as(i64, 300), default_max_timestamp_skew_seconds);
}

test "NotifyVerifier.setTransport 注入普通 transport：拉取平台证书 + 验签解密全链路" {
    const allocator = std.testing.allocator;

    const cert_resp = try platform_cert.buildCertificatesResponse(allocator, test_api_v3_key, test_serial);
    defer allocator.free(cert_resp);

    // 普通 transport（不带请求头）路径：`setTransport` 走 `MockTransport`。
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.mch.weixin.qq.com/v3/certificates", .{ .body = cert_resp });

    var fixed = FixedIo{};
    var verifier = NotifyVerifier.init(allocator, TestCfg);
    defer verifier.deinit();
    verifier.io = fixed.io();
    verifier.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));

    const biz = "{\"mchid\":\"1900000109\",\"out_trade_no\":\"20260722002\",\"trade_state\":\"SUCCESS\"}";
    const body = try buildNotifyBody(allocator, biz);
    defer allocator.free(body);
    const headers = try signHeaders(allocator, test_serial, "1700000000", "nonce-abc", body);
    defer allocator.free(@constCast(headers.signature));

    var verified = try verifier.verifyAndDecrypt(allocator, headers, body);
    defer verified.deinit(allocator);

    try std.testing.expectEqualStrings(biz, verified.plaintext);
    try std.testing.expectEqualStrings("TRANSACTION.SUCCESS", verified.body.value.event_type);

    // 证书只拉一次并进入缓存；未命中已缓存的序列号不会再回源。
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
    try std.testing.expectEqualStrings(
        "https://api.mch.weixin.qq.com/v3/certificates",
        mt.history.items[0],
    );
    try std.testing.expectEqual(@as(usize, 1), verifier.cachedCertCount());

    // 再验一次仍命中缓存（history 长度不变）。
    const headers2 = try signHeaders(allocator, test_serial, "1700000000", "nonce-def", body);
    defer allocator.free(@constCast(headers2.signature));
    var verified2 = try verifier.verifyAndDecrypt(allocator, headers2, body);
    defer verified2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);

    // setTransport / setHeaderTransport 互斥且可清空（`null` = 恢复真实 HTTPS）；
    // 反向互斥（注入 header transport 清掉普通 transport）由 platform_cert 侧的用例覆盖。
    verifier.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    verifier.setHeaderTransport(null, null);
    try std.testing.expect(verifier.store.transport == null);
    try std.testing.expect(verifier.store.header_transport == null);
}
