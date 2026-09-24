// SPDX-License-Identifier: Apache-2.0
//! pay/v3 — 微信支付 v3 模块入口
//!
//! 包含 API v3 Config、Authorization 签名器、JSAPI/小程序拉起支付、v3 退款
//! 与 v3 商家转账。

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
pub const TransferV3 = @import("transfer.zig").TransferV3;
pub const TransferParams = @import("transfer.zig").TransferParams;
pub const TransferSceneReportInfo = @import("transfer.zig").TransferSceneReportInfo;
pub const UserRecvStyle = @import("transfer.zig").UserRecvStyle;
pub const TransferResult = @import("transfer.zig").TransferResult;
pub const TransferBillResult = @import("transfer.zig").TransferBillResult;
pub const TransferCancelResult = @import("transfer.zig").TransferCancelResult;
pub const TransferNotifyResource = @import("transfer.zig").TransferNotifyResource;

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

    // 商家转账：构造真实实例并取其字段，确保 transfer.zig 被真正实例化
    // （否则其 inline test 在懒分析下可能被整文件丢弃）。
    var transfer_v3 = TransferV3.init(.{ .app_id = "wx-demo", .mch_id = "1900000109" });
    transfer_v3.setTransport(null, null);
    transfer_v3.setHeaderTransport(null, null);
    try std.testing.expectEqualStrings("wx-demo", transfer_v3.cfg.app_id);
    _ = TransferParams;
    _ = TransferSceneReportInfo;
    _ = UserRecvStyle;
    _ = TransferResult;
    _ = TransferBillResult;
    _ = TransferCancelResult;
    _ = TransferNotifyResource;
}
