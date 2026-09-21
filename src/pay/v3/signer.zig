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
pub fn buildAuthorizationHeader(
    allocator: std.mem.Allocator,
    cfg: Config,
    method: []const u8,
    canonical_url: []const u8,
    body: []const u8,
) !SignResult {
    if (cfg.private_key_pem.len == 0) return error.MissingPrivateKey;

    const timestamp = time.getCurrTS();
    const nonce_str = try util.randomStr(allocator, 32);
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
}
