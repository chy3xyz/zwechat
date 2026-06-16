//! pay/config — 微信支付商户配置

const std = @import("std");

pub const Config = struct {
    /// 公众号 / 小程序 / APP 的 appid。
    app_id: []const u8 = "",
    /// 商户号。
    mch_id: []const u8 = "",
    /// 商户支付密钥（V2 API 用）。
    key: []const u8 = "",
    /// 支付回调地址。
    notify_url: []const u8 = "",
    /// 商户证书 P12 文件路径（退款 / 企业付款 / 红包等需 mTLS 的接口使用）。
    /// 密码固定为商户号 `mch_id`（与 Go 参考实现一致）。
    root_ca: []const u8 = "",
};

test "Config 默认值" {
    const c = Config{};
    try std.testing.expectEqualStrings("", c.app_id);
    try std.testing.expectEqualStrings("", c.mch_id);
}