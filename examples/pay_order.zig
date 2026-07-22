//! 微信支付统一下单与小程序/App调起配置示例
//!
//! 演示功能：
//! 1. 初始化微信支付 Config。
//! 2. 构造 Param 订单参数。
//! 3. 计算支付签名与生成调起参数配置 bridgeAppConfig。

const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== zwechat: 微信支付统一下单示例 ===\n", .{});

    // 1. 支付配置
    const pay_config = zwechat.pay.Config{
        .app_id = "wx1234567890abcdef",
        .mch_id = "1900000109",
        .key = "12345678901234567890123456789012", // 32 字节 API 密钥
        .notify_url = "https://example.com/pay/notify",
    };

    var wc = zwechat.wechat.Wechat.init();
    var pay_inst = wc.getPay(pay_config);
    var order = pay_inst.getOrder();

    // 2. 模拟统一下单并生成小程序前端拉起支付所需参数
    const pre_order = zwechat.pay.PreOrder{
        .prepay_id = "wx201411101639507cbf6ffd8b0779950800",
    };
    const app_config = try order.bridgeAppConfig(allocator, pre_order);
    defer {
        allocator.free(app_config.appid);
        allocator.free(app_config.partnerid);
        allocator.free(app_config.prepayid);
        allocator.free(app_config.nonce_str);
        allocator.free(app_config.timestamp);
        allocator.free(app_config.sign);
    }

    std.debug.print("[小程序/App 调起配置] appid: {s}\n", .{app_config.appid});
    std.debug.print("[小程序/App 调起配置] timeStamp: {s}\n", .{app_config.timestamp});
    std.debug.print("[小程序/App 调起配置] nonceStr: {s}\n", .{app_config.nonce_str});
    std.debug.print("[小程序/App 调起配置] package: {s}\n", .{app_config.package});
    std.debug.print("[小程序/App 调起配置] sign (签名): {s}\n", .{app_config.sign});

    std.debug.print("微信支付示例运行完毕。\n", .{});
}
