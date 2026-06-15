//! pay/pay — 微信支付顶层 struct
//!
//! 对应 `_ref/wechat/pay/pay.go`：聚合 order/refund/notify/transfer/redpacket 子模块。

const std = @import("std");
const Config = @import("config.zig").Config;
const Order = @import("order/mod.zig").Order;
const Refund = @import("refund/mod.zig").Refund;
const Notify = @import("notify/mod.zig").Notify;
const Transfer = @import("transfer/mod.zig").Transfer;
const Redpacket = @import("redpacket/mod.zig").Redpacket;

pub const Pay = struct {
    cfg: Config,

    pub fn init(cfg: Config) Pay {
        return .{ .cfg = cfg };
    }

    pub fn getOrder(self: *Pay) Order {
        return Order.init(self.cfg);
    }

    pub fn getRefund(self: *Pay) Refund {
        return Refund.init(self.cfg);
    }

    pub fn getNotify(self: *Pay) Notify {
        return Notify.init(self.cfg);
    }

    pub fn getTransfer(self: *Pay) Transfer {
        return Transfer.init(self.cfg);
    }

    pub fn getRedpacket(self: *Pay) Redpacket {
        return Redpacket.init(self.cfg);
    }
};

test "Pay.init 返回实例" {
    const p = Pay.init(.{ .app_id = "wx-p", .mch_id = "123" });
    try std.testing.expectEqualStrings("wx-p", p.cfg.app_id);
}

test "Pay.getTransfer / getRedpacket 返回实例" {
    var p = Pay.init(.{ .app_id = "wx-p", .mch_id = "m" });
    const t = p.getTransfer();
    try std.testing.expectEqualStrings("m", t.cfg.mch_id);
    const r = p.getRedpacket();
    try std.testing.expectEqualStrings("wx-p", r.cfg.app_id);
}