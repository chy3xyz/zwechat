// SPDX-License-Identifier: Apache-2.0
//! zwechat 基准测试 (Benchmark)
//!
//! 包含关键算法与工具函数的性能基准：
//! - SHA1 Sort & Sign 签名计算
//! - AES-256-CBC 微信消息解密
//! - XML 编解码
//! - RSA-SHA256 签名

const std = @import("std");
const crypto = @import("crypto.zig");
const signature = @import("signature.zig");
const xml = @import("xml.zig");
const time = @import("time.zig");

fn getNanoTS() i96 {
    return std.Io.Clock.now(.real, std.Options.debug_io).toNanoseconds();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=========================================\n", .{});
    std.debug.print("       zwechat Benchmark Suite           \n", .{});
    std.debug.print("=========================================\n\n", .{});

    // 1. SHA1 签名 Benchmark
    {
        const params = [_][]const u8{ "token_secret_key_123456", "1721641869", "239847192", "nonce_str_random" };
        const iterations: usize = 100000;

        const start = getNanoTS();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const sig = try signature.signature(allocator, &params);
            allocator.free(sig);
        }
        const elapsed_ns = getNanoTS() - start;
        const avg_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
        std.debug.print("[SHA1 Sign] {} iterations, total: {d:.2} ms, avg: {d:.2} ns/op\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            avg_ns,
        });
    }

    // 2. AES-256-CBC 微信消息解密 Benchmark
    {
        const aes_key = "12345678901234567890123456789012"; // 32 字符 EncodingAESKey
        const plain_text = "Hello, zwechat high performance Zig WeChat SDK benchmark test message!";
        const random16 = "1234567890abcdef";
        const encrypted = try crypto.aesEncryptMsg(allocator, random16, plain_text, "wx1234567890abcdef", aes_key);
        defer allocator.free(encrypted);

        const iterations: usize = 50000;
        const start = getNanoTS();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const res = try crypto.aesDecryptMsg(allocator, encrypted, aes_key);
            allocator.free(res.random);
            allocator.free(res.raw_xml_msg);
            allocator.free(res.app_id);
        }
        const elapsed_ns = getNanoTS() - start;
        const avg_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
        std.debug.print("[AES-256-CBC Decrypt] {} iterations, total: {d:.2} ms, avg: {d:.2} ns/op\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            avg_ns,
        });
    }

    // 3. XML 基础解析 Benchmark
    {
        const xml_data =
            \\<xml>
            \\  <ToUserName><![CDATA[toUser]]></ToUserName>
            \\  <FromUserName><![CDATA[fromUser]]></FromUserName>
            \\  <CreateTime>1348831860</CreateTime>
            \\  <MsgType><![CDATA[text]]></MsgType>
            \\  <Content><![CDATA[this is a test]]></Content>
            \\  <MsgId>1234567890123456</MsgId>
            \\</xml>
        ;

        const iterations: usize = 100000;
        const start = getNanoTS();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            var doc = try xml.parse(allocator, xml_data);
            doc.deinit();
        }
        const elapsed_ns = getNanoTS() - start;
        const avg_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
        std.debug.print("[XML Parse] {} iterations, total: {d:.2} ms, avg: {d:.2} ns/op\n", .{
            iterations,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            avg_ns,
        });
    }

    std.debug.print("\n=========================================\n", .{});
    std.debug.print("         Benchmark Complete              \n", .{});
    std.debug.print("=========================================\n", .{});
}
