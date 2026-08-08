// SPDX-License-Identifier: Apache-2.0
//! pay/v3 — 微信支付 v3 模块入口
//!
//! 包含 API v3 Config、Authorization 签名器及 JSAPI/小程序拉起支付。

const std = @import("std");

pub const Config = @import("config.zig").Config;
pub const signer = @import("signer.zig");
pub const OrderV3 = @import("order.zig").OrderV3;
pub const JsapiPayParams = @import("order.zig").JsapiPayParams;
pub const JsapiOrderParams = @import("order.zig").JsapiOrderParams;
pub const notify = @import("notify.zig");
pub const decryptNotifyResource = notify.decryptNotifyResource;

test "pay/v3 模块导出" {
    _ = Config;
    _ = signer;
    _ = OrderV3;
    _ = JsapiPayParams;
    _ = JsapiOrderParams;
    _ = notify;
}
