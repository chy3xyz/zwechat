//! zwechat — 微信开发者 CLI 调试与诊断工具箱
//!
//! 提供客户端及服务端常用的诊断命令：
//! - `version`     : 打印 SDK 与 Zig 运行时版本
//! - `verify-sig`  : 快速验证微信服务器推送的 SHA1 URL 签名是否正确
//! - `template-demo`: 演示编译期模板消息 JSON 转换

const std = @import("std");
const zwechat = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_iter = init.minimal.args.iterate();

    _ = args_iter.next(); // 跳过程序路径名

    const cmd_opt = args_iter.next();
    if (cmd_opt == null or std.mem.eql(u8, cmd_opt.?, "version") or std.mem.eql(u8, cmd_opt.?, "-v")) {
        std.debug.print("=====================================================\n", .{});
        std.debug.print("         zwechat SDK version {s} (Zig 0.17)\n", .{zwechat.version});
        std.debug.print("=====================================================\n", .{});

        const demo_data = .{
            .first = "订单支付成功提醒",
            .trade_no = "20260722192800123",
            .amount = "88.00元",
            .remark = "如有疑问请联系客服",
        };
        const json_out = try zwechat.util.template.buildTemplateData(allocator, demo_data);
        defer allocator.free(json_out);
        std.debug.print("\n[编译期模板转换演示]\n{s}\n\n", .{json_out});
        return;
    }

    const cmd = cmd_opt.?;
    if (std.mem.eql(u8, cmd, "verify-sig")) {
        const token = args_iter.next() orelse {
            std.debug.print("错误: 缺少 token 参数\n", .{});
            return;
        };
        const timestamp = args_iter.next() orelse {
            std.debug.print("错误: 缺少 timestamp 参数\n", .{});
            return;
        };
        const nonce = args_iter.next() orelse {
            std.debug.print("错误: 缺少 nonce 参数\n", .{});
            return;
        };
        const expected_sig = args_iter.next() orelse {
            std.debug.print("错误: 缺少 signature 参数\n", .{});
            return;
        };

        const query = zwechat.middleware.CallbackQuery{
            .signature = expected_sig,
            .timestamp = timestamp,
            .nonce = nonce,
        };
        const ok = zwechat.middleware.verifyServerSignature(allocator, token, query);
        if (ok) {
            std.debug.print("✅ 微信 URL 签名校验匹配成功！\n", .{});
        } else {
            std.debug.print("❌ 微信 URL 签名校验失败！请检查 Token/Timestamp/Nonce 是否匹配。\n", .{});
        }
    } else if (std.mem.eql(u8, cmd, "template-demo")) {
        const demo_data = .{
            .first = "订单支付成功提醒",
            .trade_no = "20260722192800123",
            .amount = "88.00元",
            .remark = "如有疑问请联系客服",
        };
        const json_out = try zwechat.util.template.buildTemplateData(allocator, demo_data);
        defer allocator.free(json_out);
        std.debug.print("模板消息转换结果:\n{s}\n", .{json_out});
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\=====================================================
        \\         zwechat — 微信开发者 CLI 调试与诊断工具
        \\=====================================================
        \\用法:
        \\  zwechat version                             查看当前 SDK 版本
        \\  zwechat verify-sig <token> <ts> <nonce> <sig> 校验微信回调签名
        \\  zwechat template-demo                       测试编译期模板数据生成
        \\
    , .{});
}