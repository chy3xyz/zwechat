//! pay — 微信支付（骨架，Wave 4d 实现各子模块）

const std = @import("std");
const config_mod = @import("config.zig");

pub const Config = config_mod.Config;
pub const Pay = @import("pay.zig").Pay;
pub const Order = @import("order/mod.zig").Order;
pub const Refund = @import("refund/mod.zig").Refund;
pub const Notify = @import("notify/mod.zig").Notify;
pub const Transfer = @import("transfer/mod.zig").Transfer;
pub const Redpacket = @import("redpacket/mod.zig").Redpacket;

test "pay 模块导出" {
    _ = Pay;
    _ = Order;
    _ = Refund;
    _ = Notify;
    _ = Transfer;
    _ = Redpacket;
}