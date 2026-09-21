// SPDX-License-Identifier: Apache-2.0
//! pay/v3 — 微信支付 v3 模块入口
//!
//! 包含 API v3 Config、Authorization 签名器、JSAPI/小程序拉起支付及 v3 退款。

const std = @import("std");

pub const Config = @import("config.zig").Config;
pub const signer = @import("signer.zig");
pub const OrderV3 = @import("order.zig").OrderV3;
pub const JsapiPayParams = @import("order.zig").JsapiPayParams;
pub const JsapiOrderParams = @import("order.zig").JsapiOrderParams;
pub const notify = @import("notify.zig");
pub const decryptNotifyResource = notify.decryptNotifyResource;
pub const RefundV3 = @import("refund.zig").RefundV3;
pub const RefundParams = @import("refund.zig").RefundParams;
pub const RefundAmount = @import("refund.zig").RefundAmount;
pub const RefundResult = @import("refund.zig").RefundResult;
pub const RefundNotifyResource = @import("refund.zig").RefundNotifyResource;

test "pay/v3 模块导出" {
    _ = Config;
    _ = signer;
    _ = OrderV3;
    _ = JsapiPayParams;
    _ = JsapiOrderParams;
    _ = notify;
    // 运行时引用（不能用 @hasDecl 之类纯 comptime 反射代替）：
    // Zig 懒分析下，未被实例化引用的文件连 inline test 都不会被发现。
    _ = RefundV3;
    _ = RefundParams;
    _ = RefundAmount;
    _ = RefundResult;
    _ = RefundNotifyResource;
}
