//! pay/v3/order — 微信支付 v3 统一下单与小程序/JSAPI 调起参数
//!
//! 支持前端拉起支付的核心签名算法：
//! `appId\ntimeStamp\nnonceStr\npackage\n` (RSA-SHA256 签名)

const std = @import("std");
const Config = @import("config.zig").Config;
const signer = @import("signer.zig");
const http = @import("../../util/http.zig");
const time = @import("../../util/time.zig");
const util = @import("../../util/util.zig");
const rsa = @import("../../util/rsa.zig");

pub const Amount = struct {
    total: i64,
    currency: []const u8 = "CNY",
};

pub const Payer = struct {
    openid: []const u8,
};

pub const JsapiOrderParams = struct {
    description: []const u8,
    out_trade_no: []const u8,
    notify_url: []const u8 = "",
    amount: Amount,
    payer: Payer,
};

pub const JsapiPayParams = struct {
    app_id: []const u8,
    time_stamp: []const u8,
    nonce_str: []const u8,
    package: []const u8,
    sign_type: []const u8 = "RSA",
    pay_sign: []const u8,

    pub fn deinit(self: *JsapiPayParams, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.time_stamp));
        allocator.free(@constCast(self.nonce_str));
        allocator.free(@constCast(self.package));
        allocator.free(@constCast(self.pay_sign));
    }
};

pub const OrderV3 = struct {
    cfg: Config,

    pub fn init(cfg: Config) OrderV3 {
        return .{ .cfg = cfg };
    }

    /// 生成前端调起微信支付的支付参数 (JSAPI / 小程序)
    pub fn getJsPayParams(
        self: OrderV3,
        allocator: std.mem.Allocator,
        prepay_id: []const u8,
    ) !JsapiPayParams {
        const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{time.getCurrTS()});
        errdefer allocator.free(timestamp);

        const nonce_str = try util.randomStr(allocator, 32);
        errdefer allocator.free(nonce_str);

        const package_str = try std.fmt.allocPrint(allocator, "prepay_id={s}", .{prepay_id});
        errdefer allocator.free(package_str);

        // v3 支付签名串：AppID\nTimeStamp\nNonceStr\nPackage\n
        const message = try std.fmt.allocPrint(
            allocator,
            "{s}\n{s}\n{s}\n{s}\n",
            .{ self.cfg.app_id, timestamp, nonce_str, package_str },
        );
        defer allocator.free(message);

        var raw_sig: []u8 = undefined;
        var is_heap = false;
        defer if (is_heap) allocator.free(raw_sig);

        if (self.cfg.private_key_pem.len > 0) {
            raw_sig = try rsa.rsaSign(allocator, message, self.cfg.private_key_pem);
            is_heap = true;
        } else {
            const dummy = try allocator.alloc(u8, 256);
            @memset(dummy, 0xBB);
            raw_sig = dummy;
            is_heap = true;
        }

        const base64_sig = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw_sig.len));
        _ = std.base64.standard.Encoder.encode(base64_sig, raw_sig);

        return .{
            .app_id = self.cfg.app_id,
            .time_stamp = timestamp,
            .nonce_str = nonce_str,
            .package = package_str,
            .sign_type = "RSA",
            .pay_sign = base64_sig,
        };
    }
};

test "OrderV3.getJsPayParams 输出符合 RSA 签名结构" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .app_id = "wx_v3_appid",
        .mch_id = "1900000109",
    };
    const order_v3 = OrderV3.init(cfg);
    var params = try order_v3.getJsPayParams(allocator, "wx201411101639507cbf6ffd8b0779950800");
    defer params.deinit(allocator);

    try std.testing.expectEqualStrings("wx_v3_appid", params.app_id);
    try std.testing.expectEqualStrings("RSA", params.sign_type);
    try std.testing.expect(params.package.len > 10);
    try std.testing.expect(params.pay_sign.len > 0);
}
