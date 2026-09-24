// SPDX-License-Identifier: Apache-2.0
//! pay/v3/signer — 微信支付 v3 HTTP 请求头签名算法 (RSA-SHA256)
//!
//! 根据微信支付 v3 官方文档计算 `Authorization: WECHATPAY2-SHA256-RSA2048 ...` 标头：
//! 签名串格式：`Method\nURL\nTimestamp\nNonceStr\nBody\n`

const std = @import("std");
const Config = @import("config.zig").Config;
const rsa = @import("../../util/rsa.zig");
const time = @import("../../util/time.zig");
const util = @import("../../util/util.zig");

pub const SignResult = struct {
    authorization: []const u8,
    timestamp: i64,
    nonce_str: []const u8,

    pub fn deinit(self: *SignResult, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.authorization));
        allocator.free(@constCast(self.nonce_str));
    }
};

/// 构造微信支付 v3 HTTP Authorization 请求头。
///
/// `method`: HTTP 方法字符串（大写，如 "POST" / "GET"）。
/// `canonical_url`: 请求 URI 相对路径及 query（如 "/v3/pay/transactions/jsapi"）。
/// `body`: HTTP 请求体（GET 时传 ""）。
///
/// `cfg.private_key_pem` 为空时返回 `error.MissingPrivateKey`
/// （修复前会静默生成伪签名，导致线上请求被微信拒收且难以排查）。
///
/// 签名串里的 timestamp / nonce_str 取自全局单例 `Io`；需要宿主注入 `Io` 时
/// 改用 [`buildAuthorizationHeaderWithIo`]。本函数保留为等价的默认实现。
pub fn buildAuthorizationHeader(
    allocator: std.mem.Allocator,
    cfg: Config,
    method: []const u8,
    canonical_url: []const u8,
    body: []const u8,
) !SignResult {
    return buildAuthorizationHeaderWithIo(
        allocator,
        std.Io.Threaded.global_single_threaded.io(),
        cfg,
        method,
        canonical_url,
        body,
    );
}

/// 同 [`buildAuthorizationHeader`]，但由调用方注入驱动取时 / 取随机的 `Io`。
///
/// 参数顺序与 `util.time.getCurrTSWithIo` / `util.util.randomStrWithIo` 一致
/// （`allocator` 之后紧跟 `io`）。
pub fn buildAuthorizationHeaderWithIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    method: []const u8,
    canonical_url: []const u8,
    body: []const u8,
) !SignResult {
    if (cfg.private_key_pem.len == 0) return error.MissingPrivateKey;

    const timestamp = time.getCurrTSWithIo(io);
    const nonce_str = try util.randomStrWithIo(allocator, io, 32);
    errdefer allocator.free(nonce_str);

    // 构造待签名 Message
    const message = try std.fmt.allocPrint(
        allocator,
        "{s}\n{s}\n{d}\n{s}\n{s}\n",
        .{ method, canonical_url, timestamp, nonce_str, body },
    );
    defer allocator.free(message);

    // RSA-SHA256 签名（支持私钥 PEM）
    const raw_sig = try rsa.rsaSign(allocator, message, cfg.private_key_pem);
    defer allocator.free(raw_sig);

    const base64_sig = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw_sig.len));
    defer allocator.free(base64_sig);
    _ = std.base64.standard.Encoder.encode(base64_sig, raw_sig);

    const auth_header = try std.fmt.allocPrint(
        allocator,
        "WECHATPAY2-SHA256-RSA2048 mchid=\"{s}\",nonce_str=\"{s}\",signature=\"{s}\",timestamp=\"{d}\",serial_no=\"{s}\"",
        .{ cfg.mch_id, nonce_str, base64_sig, timestamp, cfg.serial_no },
    );

    return .{
        .authorization = auth_header,
        .timestamp = timestamp,
        .nonce_str = nonce_str,
    };
}

test "buildAuthorizationHeader 缺私钥返回 MissingPrivateKey（不再静默伪签名）" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .app_id = "wx12345",
        .mch_id = "1900000109",
        .serial_no = "1DDE557876238",
    };

    const r = buildAuthorizationHeader(
        allocator,
        cfg,
        "POST",
        "/v3/pay/transactions/jsapi",
        "{\"amount\":{\"total\":100}}",
    );
    try std.testing.expectError(error.MissingPrivateKey, r);

    // WithIo 入口同样在缺私钥时报错（两个入口行为一致）。
    try std.testing.expectError(error.MissingPrivateKey, buildAuthorizationHeaderWithIo(
        allocator,
        std.testing.io,
        cfg,
        "POST",
        "/v3/pay/transactions/jsapi",
        "",
    ));
}

// —— io 注入：timestamp / nonce_str 不再直接访问全局单例 ——

/// 冻结时钟的可观测 `Io`：`now` 恒定返回 `frozen_ns`。
const FixedIo = struct {
    vtable: std.Io.VTable = undefined,

    const frozen_ns: i96 = 1_700_000_000 * std.time.ns_per_s;

    fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        return .{ .nanoseconds = frozen_ns };
    }

    fn io(self: *FixedIo) std.Io {
        self.vtable = std.Io.Threaded.global_single_threaded.io().vtable.*;
        self.vtable.now = now;
        return .{ .userdata = null, .vtable = &self.vtable };
    }
};

/// 测试用 RSA 私钥（1024-bit，一次性生成的公开 throwaway 密钥；
/// `util/rsa.zig` 与 `pay/v3/transfer.zig` 的测试用的是同一把）。
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

test "buildAuthorizationHeaderWithIo 的 timestamp / nonce_str 取自注入的 io" {
    const allocator = std.testing.allocator;
    var fixed = FixedIo{};
    const cfg = Config{
        .app_id = "wx12345",
        .mch_id = "1900000109",
        .serial_no = "1DDE557876238",
        .private_key_pem = test_private_key_pkcs1,
    };

    var r = try buildAuthorizationHeaderWithIo(
        allocator,
        fixed.io(),
        cfg,
        "POST",
        "/v3/pay/transactions/jsapi",
        "{\"amount\":{\"total\":100}}",
    );
    defer r.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 1_700_000_000), r.timestamp);
    try std.testing.expect(std.mem.indexOf(u8, r.authorization, "timestamp=\"1700000000\"") != null);

    const nonce_field = try std.fmt.allocPrint(allocator, "nonce_str=\"{s}\"", .{r.nonce_str});
    defer allocator.free(nonce_field);
    try std.testing.expect(std.mem.indexOf(u8, r.authorization, nonce_field) != null);
}

test "buildAuthorizationHeaderWithIo 冻结时钟下 nonce_str 可复现（证明走注入 io）" {
    const allocator = std.testing.allocator;
    var fixed = FixedIo{};
    const io = fixed.io();
    const cfg = Config{
        .app_id = "wx12345",
        .mch_id = "1900000109",
        .serial_no = "1DDE557876238",
        .private_key_pem = test_private_key_pkcs1,
    };

    var r1 = try buildAuthorizationHeaderWithIo(allocator, io, cfg, "POST", "/v3/pay/transactions/jsapi", "{}");
    defer r1.deinit(allocator);
    var r2 = try buildAuthorizationHeaderWithIo(allocator, io, cfg, "POST", "/v3/pay/transactions/jsapi", "{}");
    defer r2.deinit(allocator);

    try std.testing.expectEqualStrings(r1.nonce_str, r2.nonce_str);
}

test "buildAuthorizationHeader 默认 io 取真实当前时间（未注入时的历史行为）" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .app_id = "wx12345",
        .mch_id = "1900000109",
        .serial_no = "1DDE557876238",
        .private_key_pem = test_private_key_pkcs1,
    };

    var r = try buildAuthorizationHeader(allocator, cfg, "GET", "/v3/certificates", "");
    defer r.deinit(allocator);

    const now = time.getCurrTSWithIo(std.Io.Threaded.global_single_threaded.io());
    try std.testing.expect(r.timestamp <= now and now - r.timestamp <= 5);
}
