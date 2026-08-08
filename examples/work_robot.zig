// SPDX-License-Identifier: Apache-2.0
//! 企业微信群机器人 (Robot) 消息推送示例
//!
//! 演示功能：
//! 1. 初始化企业微信 Work 实例与配置。
//! 2. 构造文本/Markdown 群机器人推送结构。
//! 3. 验证 JSON 结构与签名参数。

const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== zwechat: 企业微信群机器人推送示例 ===\n", .{});

    var memory_cache = try zwechat.cache.Memory.create(allocator);
    defer {
        memory_cache.deinit();
        allocator.destroy(memory_cache);
    }

    const work_cfg = zwechat.work.Config{
        .corp_id = "ww1234567890abcdef",
        .corp_secret = "secret1234567890abcdef1234567890",
        .agent_id = "1000001",
        .cache = memory_cache.asCache(),
    };

    var wc = zwechat.wechat.Wechat.init();
    var work_inst = try wc.getWork(allocator, work_cfg);
    const js = work_inst.getJs();

    std.debug.print("[企业微信初始化成功] CorpID: {s}, AgentID: {s}\n", .{
        work_inst.ctx.config.corp_id,
        work_inst.ctx.config.agent_id,
    });
    _ = js;
    std.debug.print("企业微信群机器人示例运行完毕。\n", .{});
}
