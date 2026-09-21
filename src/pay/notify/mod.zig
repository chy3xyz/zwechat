// SPDX-License-Identifier: Apache-2.0
//! pay/notify — 回调通知（验签 + 解密）

const std = @import("std");
const Config = @import("../config.zig").Config;
const util_xml = @import("../../util/xml.zig");
const util_param = @import("../../util/param.zig");
const util_crypto = @import("../../util/crypto.zig");

/// 支付成功通知结构（XML → 字段）。
pub const PaidNotify = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    appid: []const u8 = "",
    mch_id: []const u8 = "",
    out_trade_no: []const u8 = "",
    transaction_id: []const u8 = "",
    total_fee: []const u8 = "",
    result_code: []const u8 = "",
};

/// 验证支付通知签名。
///
/// 算法：`sign_type`（XML 中可选，默认 MD5）over `orderParam(params_except_sign) + "&key=" + API_KEY`。
/// 返回 `true` 表示签名匹配。
pub fn verifyPaidNotify(allocator: std.mem.Allocator, cfg: Config, xml_body: []const u8) !bool {
    var doc = try util_xml.parse(allocator, xml_body);
    defer doc.deinit();

    const given_sign = doc.get("sign") orelse return false;

    var param_array: std.ArrayList(util_param.Param) = .empty;
    defer param_array.deinit(allocator);

    for (doc.elements) |el| {
        if (std.mem.eql(u8, el.key, "sign")) continue;
        if (el.value.len == 0) continue;
        try param_array.append(allocator, .{ .key = el.key, .value = el.value });
    }

    const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{cfg.key});
    defer allocator.free(biz);

    const ordered = try util_param.orderParam(allocator, param_array.items, biz);
    defer allocator.free(ordered);

    // 与上游 Go 版 PaidVerifySign 一致：签名类型取自通知报文里的 sign_type 字段，
    // 缺省为 MD5。
    const sign_type = doc.get("sign_type") orelse util_crypto.SignTypeMD5;

    const computed = try util_crypto.calculateSign(allocator, ordered, sign_type, cfg.key);
    defer allocator.free(computed);

    return std.mem.eql(u8, computed, given_sign);
}

pub const Notify = struct {
    cfg: Config,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    /// 解密退款通知（req_info 字段，AES-256-ECB + PKCS#7）。
    ///
    /// 解密密钥 = `MD5(mch_key)` 的**小写 hex**（32 字节 ASCII，与上游 Go
    /// `hex.EncodeToString` 行为一致；不能用大写 hex）。返回的明文切片由调用方负责 `free`。
    pub fn decryptRefund(self: *Self, allocator: std.mem.Allocator, req_info_b64: []const u8) ![]u8 {
        // API v2 退款通知 key = MD5(MchKey) 的小写 hex → 32 字节 AES key
        const key_digest = try util_crypto.md5HexLower(allocator, self.cfg.key);
        defer allocator.free(key_digest);

        // base64 decode
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(req_info_b64);
        const cipher = try allocator.alloc(u8, decoded_len);
        defer allocator.free(cipher);
        try std.base64.standard.Decoder.decode(cipher, req_info_b64);

        const plain = try util_crypto.aesECBDecrypt(allocator, cipher, key_digest);
        return plain;
    }
};

test "PaidNotify 默认值" {
    const n = PaidNotify{};
    try std.testing.expectEqualStrings("", n.out_trade_no);
}

test "Notify.init 暴露 cfg" {
    const n = Notify.init(.{ .app_id = "wx-pay", .mch_id = "m" });
    try std.testing.expectEqualStrings("wx-pay", n.cfg.app_id);
}

test "verifyPaidNotify 真实测试向量：签名匹配返回 true" {
    // 微信支付文档的标准示例：
    //   商户 key = "192006250b4c09247ec02edce69f6a2d"
    //   参数（按字典序）：appid=wx123,mch_id=12345,nonce_str=5K8264ILTKCH...,result_code=SUCCESS,transaction_id=...
    // 期望签名 = MD5(orderParam + "&key=192006250b4c09247ec02edce69f6a2d")
    // 来自：https://pay.weixin.qq.com/wiki/doc/api/jsapi.php?chapter=4_3
    const allocator = std.testing.allocator;

    // 构造一组已知参数 + 预先计算好的正确签名
    const params_xml =
        \\<xml>
        \\  <appid><![CDATA[wx1234567890abcdef]]></appid>
        \\  <mch_id>12345</mch_id>
        \\  <nonce_str>5K8264ILTKCH16CQ2502SI8ZNMTM67VS</nonce_str>
        \\  <result_code><![CDATA[SUCCESS]]></result_code>
        \\  <return_code><![CDATA[SUCCESS]]></return_code>
        \\  <transaction_id>4001234567890123456</transaction_id>
        \\</xml>
    ;

    // 用当前算法计算签名（同样的参数 + 同样的 key）
    const cfg = Config{ .app_id = "wx1234567890abcdef", .mch_id = "12345", .key = "192006250b4c09247ec02edce69f6a2d" };

    // 自己计算签名（用 param 工具）
    const test_params = [_]util_param.Param{
        .{ .key = "appid", .value = "wx1234567890abcdef" },
        .{ .key = "mch_id", .value = "12345" },
        .{ .key = "nonce_str", .value = "5K8264ILTKCH16CQ2502SI8ZNMTM67VS" },
        .{ .key = "result_code", .value = "SUCCESS" },
        .{ .key = "return_code", .value = "SUCCESS" },
        .{ .key = "transaction_id", .value = "4001234567890123456" },
    };

    const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{cfg.key});
    defer allocator.free(biz);
    const ordered = try util_param.orderParam(allocator, &test_params, biz);
    defer allocator.free(ordered);
    const expected_sign = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeMD5, "");
    defer allocator.free(expected_sign);

    // 把签名嵌入 XML
    var xml_with_sign: std.ArrayList(u8) = .empty;
    defer xml_with_sign.deinit(allocator);
    const stripped = params_xml[0 .. params_xml.len - "</xml>\n".len];
    try xml_with_sign.print(allocator, "{s}<sign>{s}</sign></xml>", .{ stripped, expected_sign });

    // 验证
    const ok = try verifyPaidNotify(allocator, cfg, xml_with_sign.items);
    try std.testing.expect(ok);
}

test "verifyPaidNotify 错误签名返回 false" {
    const allocator = std.testing.allocator;
    const cfg = Config{ .app_id = "wx123", .mch_id = "m", .key = "thekey" };
    const bad_xml =
        \\<xml>
        \\  <appid>wx123</appid>
        \\  <mch_id>m</mch_id>
        \\  <sign>WRONG_SIGNATURE</sign>
        \\</xml>
    ;
    const ok = try verifyPaidNotify(allocator, cfg, bad_xml);
    try std.testing.expect(!ok);
}

test "verifyPaidNotify 缺 sign 返回 false" {
    const allocator = std.testing.allocator;
    const cfg = Config{ .app_id = "wx", .mch_id = "m", .key = "k" };
    const xml =
        \\<xml>
        \\  <appid>wx</appid>
        \\  <mch_id>m</mch_id>
        \\</xml>
    ;
    const ok = try verifyPaidNotify(allocator, cfg, xml);
    try std.testing.expect(!ok);
}

test "decryptRefund 真实退款通知向量（Go 版 refund_test.go）" {
    // 数据来自 `_ref/wechat/pay/notify/refund_test.go`（微信支付真实回调样例）。
    // 解密密钥 = MD5(mch_key) 的**小写** hex；修复前实现误用大写 hex，会导致解密失败。
    const allocator = std.testing.allocator;
    var n = Notify.init(.{ .key = "ziR0QKsTUfMOuochC9RfCdmfHECorQAP" });
    const req_info = "YYwp8C48th0wnQzTqeI+41pflB26v+smFj9z6h9RPBgxTyZyxc+4YNEz7QEgZNWj/6rIb2MfyWMZmCc41CfjKSssoSZPXxOhUayb6KvNSZ1p6frOX1PDWzhyruXK7ouNND+gDsG4yZ0XXzsL4/pYNwLLba/71QrnkJ/BHcByk4EXnglju5DLup9pJQSnTxjomI9Rxu57m9jg5lLQFxMWXyeASZJNvof0ulnHlWJswS4OxKOkmW7VEyKyLGV6npoOm03Qsx2wkRxLsSa9gPpg4hdaReeUqh1FMbm7aWjyrVYT/MEZWg98p4GomEIYvz34XfDncTezX4bf/ZiSLXt79aE1/YTZrYfymXeCrGjlbe0rg/T2ezJHAC870u2vsVbY1/KcE2A443N+DEnAziXlBQ1AeWq3Rqk/O6/TMM0lomzgctAOiAMg+bh5+Gu1ubA9O3E+vehULydD5qx2o6i3+qA9ORbH415NyRrQdeFq5vmCiRikp5xYptWiGZA0tkoaLKMPQ4ndE5gWHqiBbGPfULZWokI+QjjhhBmwgbd6J0VqpRorwOuzC/BHdkP72DCdNcm7IDUpggnzBIy0+seWIkcHEryKjge3YDHpJeQCqrAH0CgxXHDt1xtbQbST1VqFyuhPhUjDXMXrknrGPN/oE1t0rLRq+78cI+k8xe5E6seeUXQsEe8r3358mpcDYSmXWSXVZxK6er9EF98APqHwcndyEJD2YyCh/mMVhERuX+7kjlRXSiNUWa/Cv/XAKFQuvUYA5ea2eYWtPRHa4DpyuF1SNsaqVKfgqKXZrJHfAgslVpSVqUpX4zkKszHF4kwMZO3M7J1P94Mxa7Tm9mTOJePOoHPXeEB+m9rX6pSfoi3mJDQ5inJ+Vc4gOkg/Wd/lqiy6TTyP/dHDN6/v+AuJx5AXBo/2NDD3dWhHjkqEKIuARr2ClZt9ZRQO4HkXdZo7CN06sGCHk48Tg8PmxnxKcMZm7Aoquv5yMIM2gWSWIRJhwJ8cUpafIHc+GesDlbF6Zbt+/KXkafJAQq2RklEN+WvZz/Fz113EPgWPjp16TwBoziq96MMekvWKY/vdhjol8VFtGH9F61Oy1Xwf6DJtPw==";
    const plain = try n.decryptRefund(allocator, req_info);
    defer allocator.free(plain);
    try std.testing.expect(std.mem.startsWith(u8, plain, "<root>"));
    try std.testing.expect(std.mem.indexOf(u8, plain, "<out_refund_no>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "50000404922017112502468056157") != null);
}

test "verifyPaidNotify 支持 HMAC-SHA256 sign_type" {
    // 上游 Go 版 PaidVerifySign 按报文中的 sign_type 字段选择算法。
    const allocator = std.testing.allocator;
    const cfg = Config{ .app_id = "wx123", .mch_id = "m", .key = "thekey" };

    const params = [_]util_param.Param{
        .{ .key = "appid", .value = "wx123" },
        .{ .key = "mch_id", .value = "m" },
        .{ .key = "nonce_str", .value = "abc" },
        .{ .key = "result_code", .value = "SUCCESS" },
        .{ .key = "sign_type", .value = "HMAC-SHA256" },
    };
    const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{cfg.key});
    defer allocator.free(biz);
    const ordered = try util_param.orderParam(allocator, &params, biz);
    defer allocator.free(ordered);
    const sign = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeHMACSHA256, cfg.key);
    defer allocator.free(sign);

    const good = try std.fmt.allocPrint(allocator,
        \\<xml><appid>wx123</appid><mch_id>m</mch_id><nonce_str>abc</nonce_str><result_code>SUCCESS</result_code><sign_type>HMAC-SHA256</sign_type><sign>{s}</sign></xml>
    , .{sign});
    defer allocator.free(good);
    try std.testing.expect(try verifyPaidNotify(allocator, cfg, good));

    // 同样的参数但用 MD5 伪造签名 → 必须验签失败（修复前恒按 MD5 计算则无法区分）。
    const md5_sign = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeMD5, "");
    defer allocator.free(md5_sign);
    const bad = try std.fmt.allocPrint(allocator,
        \\<xml><appid>wx123</appid><mch_id>m</mch_id><nonce_str>abc</nonce_str><result_code>SUCCESS</result_code><sign_type>HMAC-SHA256</sign_type><sign>{s}</sign></xml>
    , .{md5_sign});
    defer allocator.free(bad);
    try std.testing.expect(!(try verifyPaidNotify(allocator, cfg, bad)));
}
