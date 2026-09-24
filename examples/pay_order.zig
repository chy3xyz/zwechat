// SPDX-License-Identifier: Apache-2.0
//! 微信支付统一下单与小程序/App调起配置示例
//!
//! 演示功能：
//! 1. 初始化微信支付 Config。
//! 2. 注入 MockTransport 模拟微信统一下单接口（离线演示真实 prePayOrder 流程）。
//! 3. 解析 PreOrder 响应，生成小程序/App 调起参数 bridgeAppConfig（含二次签名）。
//!
//! 运行：`zig build run-pay-order`

const std = @import("std");
const zwechat = @import("zwechat");

pub fn main(init: std.process.Init) !void {
    // 示例为一次性进程：临时分配统一走进程级 arena（`init.arena`）。
    // 本示例不碰缓存 / 凭据获取器，因此不需要 `init.io`；
    // 需要注入 `Io` 的示例见 officialaccount_server.zig / work_robot.zig。
    const allocator = init.arena.allocator();

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

    // 2. 注入 MockTransport，拦截统一下单请求并返回模拟成功响应
    var mock = zwechat.util.http.MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute("https://api.mch.weixin.qq.com/pay/unifiedorder", .{
        .status = 200,
        .body =
        \\<xml>
        \\  <return_code><![CDATA[SUCCESS]]></return_code>
        \\  <result_code><![CDATA[SUCCESS]]></result_code>
        \\  <appid><![CDATA[wx1234567890abcdef]]></appid>
        \\  <mch_id><![CDATA[1900000109]]></mch_id>
        \\  <nonce_str><![CDATA[mocknonce]]></nonce_str>
        \\  <trade_type><![CDATA[JSAPI]]></trade_type>
        \\  <prepay_id><![CDATA[wx201411101639507cbf6ffd8b0779950800]]></prepay_id>
        \\</xml>
        ,
    });
    order.setTransport(zwechat.util.http.MockTransport.dispatch, @ptrCast(&mock));

    // 3. 构造订单参数并发起统一下单（被 MockTransport 截获，不会真实请求微信）
    const params = zwechat.pay.OrderParams{
        .total_fee = "88",
        .create_ip = "123.12.12.123",
        .body = "zwechat 示例商品",
        .out_trade_no = "202409180001",
        .open_id = "oUpF8uMuAJO_M2pxb1Q9zNjWeS6o",
        .trade_type = "JSAPI",
        .notify_url = pay_config.notify_url,
    };
    var pre_order = try order.prePayOrder(allocator, params);
    defer pre_order.deinit();

    std.debug.print("[统一下单] return_code={s}, result_code={s}, prepay_id={s}\n", .{
        pre_order.return_code,
        pre_order.result_code,
        pre_order.prepay_id,
    });
    std.debug.print("[统一下单] 实际请求次数: {} 次\n", .{mock.history.items.len});

    // 4. 生成小程序/App 前端拉起支付所需参数（二次签名）
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
