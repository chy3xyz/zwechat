// SPDX-License-Identifier: Apache-2.0
//! pay — 微信支付（骨架，Wave 4d 实现各子模块）

const std = @import("std");
const config_mod = @import("config.zig");

pub const Config = config_mod.Config;
pub const Pay = @import("pay.zig").Pay;
pub const Order = @import("order/mod.zig").Order;
pub const PreOrder = @import("order/mod.zig").PreOrder;
pub const BridgeConfig = @import("order/mod.zig").BridgeConfig;
pub const AppConfig = @import("order/mod.zig").AppConfig;
pub const Refund = @import("refund/mod.zig").Refund;
pub const Notify = @import("notify/mod.zig").Notify;
pub const Transfer = @import("transfer/mod.zig").Transfer;
pub const Redpacket = @import("redpacket/mod.zig").Redpacket;
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
}
