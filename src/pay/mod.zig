// SPDX-License-Identifier: Apache-2.0
//! pay — 微信支付（骨架，Wave 4d 实现各子模块）

const std = @import("std");
const config_mod = @import("config.zig");

pub const Config = config_mod.Config;
pub const Pay = @import("pay.zig").Pay;
pub const Order = @import("order/mod.zig").Order;
pub const OrderParams = @import("order/mod.zig").Params;
pub const PreOrder = @import("order/mod.zig").PreOrder;
pub const QueryOrderResult = @import("order/mod.zig").QueryOrderResult;
pub const CloseOrderResult = @import("order/mod.zig").CloseOrderResult;
pub const BridgeConfig = @import("order/mod.zig").BridgeConfig;
pub const AppConfig = @import("order/mod.zig").AppConfig;
pub const Refund = @import("refund/mod.zig").Refund;
pub const RefundParams = @import("refund/mod.zig").RefundParams;
pub const RefundResult = @import("refund/mod.zig").RefundResult;
pub const Notify = @import("notify/mod.zig").Notify;
pub const PaidNotify = @import("notify/mod.zig").PaidNotify;
pub const Transfer = @import("transfer/mod.zig").Transfer;
pub const TransferWalletParams = @import("transfer/mod.zig").TransferWalletParams;
pub const TransferWalletResult = @import("transfer/mod.zig").TransferWalletResult;
pub const Redpacket = @import("redpacket/mod.zig").Redpacket;
pub const RedpacketParams = @import("redpacket/mod.zig").RedpacketParams;
pub const RedpacketResult = @import("redpacket/mod.zig").RedpacketResult;
pub const v3 = @import("v3/mod.zig");

test "pay 模块导出" {
    try std.testing.expect(@hasDecl(Pay, "init"));
    try std.testing.expect(@hasDecl(Pay, "getOrder"));
    try std.testing.expect(@hasDecl(Order, "prePayOrder"));
    try std.testing.expect(@hasDecl(Order, "bridgeAppConfig"));
    try std.testing.expect(@hasDecl(Refund, "init"));
    try std.testing.expect(@hasDecl(Notify, "init"));
    try std.testing.expect(@hasDecl(Notify, "decryptRefund"));
    try std.testing.expect(@hasDecl(Transfer, "init"));
    try std.testing.expect(@hasDecl(Redpacket, "init"));
    try std.testing.expect(@hasDecl(v3.OrderV3, "init"));
    // 参数/返回类型导出（复用方构造与接收用）。
    try std.testing.expect(@hasField(OrderParams, "out_trade_no"));
    try std.testing.expect(@hasField(QueryOrderResult, "trade_state"));
    try std.testing.expect(@hasField(CloseOrderResult, "result_code"));
    try std.testing.expect(@hasField(RefundParams, "out_refund_no"));
    try std.testing.expect(@hasField(RefundResult, "return_code"));
    try std.testing.expect(@hasField(TransferWalletParams, "open_id"));
    try std.testing.expect(@hasField(TransferWalletResult, "payment_no"));
    try std.testing.expect(@hasField(RedpacketParams, "mch_billno"));
    try std.testing.expect(@hasField(RedpacketResult, "return_code"));
    try std.testing.expect(@hasField(PaidNotify, "transaction_id"));
}
