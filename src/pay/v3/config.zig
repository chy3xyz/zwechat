// SPDX-License-Identifier: Apache-2.0
//! pay/v3/config — 微信支付 v3 规范配置
//!
//! 包含 AppID、商户号 MchID、商户 APIv3 密钥 Key、RSA 私钥 PEM 以及商户证书序列号 SerialNo。

const std = @import("std");

pub const Config = struct {
    /// 直连商户 AppID 或服务商 AppID
    app_id: []const u8 = "",
    /// 商户号 MchID
    mch_id: []const u8 = "",
    /// APIv3 密钥（32 字节 AES-GCM 解密密钥）
    api_v3_key: []const u8 = "",
    /// 商户 API 证书序列号
    serial_no: []const u8 = "",
    /// 商户私钥（PKCS#8 PEM 字符串或路径）
    private_key_pem: []const u8 = "",
    /// 支付通知回调地址
    notify_url: []const u8 = "",
};
