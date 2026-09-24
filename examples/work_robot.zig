// SPDX-License-Identifier: Apache-2.0
//! 企业微信群机器人 (Robot) 消息推送示例
//!
//! 演示功能：
//! 1. 初始化企业微信 Work 实例（Robot 推送不依赖 access_token，仅需 webhook key）。
//! 2. 构造文本 (TextMessage) / Markdown (MarkdownMessage) 群机器人消息结构。
//! 3. 说明真实发送流程（`sendText` / `sendMarkdown` 需要真实 webhook key，会发起 HTTPS 请求）。
//!
//! 运行：`zig build run-work-robot`

const std = @import("std");
const zwechat = @import("zwechat");

pub fn main(init: std.process.Init) !void {
    // 示例为一次性进程：临时分配统一走进程级 arena（`init.arena`），
    // 缓存互斥量使用宿主注入的 `Io`（`init.io`）。
    const allocator = init.arena.allocator();

    std.debug.print("=== zwechat: 企业微信群机器人推送示例 ===\n", .{});

    var memory_cache = try zwechat.cache.Memory.createWithIo(allocator, init.io);
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
    var robot = work_inst.getRobot(allocator);

    std.debug.print("[企业微信初始化成功] CorpID: {s}, AgentID: {s}\n", .{
        work_inst.ctx.config.corp_id,
        work_inst.ctx.config.agent_id,
    });

    // 1. 文本消息：可附带 @ 成员列表（userid 或手机号）
    var mentioned = [_][]const u8{"zhangsan"};
    const text_content =
        \\仓库构建失败，请相关同事关注。
        \\> 分支: main
        \\> 提交: a1b2c3d
    ;
    // sendText 的 msg 参数类型为 work.robot.TextMessage，结构体字面量自动按字段名匹配。
    const text_msg = .{
        .content = text_content,
        .mentioned_list = @as([][]const u8, &mentioned),
    };
    std.debug.print("[文本消息] content:\n{s}\n", .{text_msg.content});
    std.debug.print("[文本消息] mentioned_list: {s}\n", .{text_msg.mentioned_list[0]});

    // 2. Markdown 消息：最长 4096 字节（参数类型 work.robot.MarkdownMessage）
    const md_content =
        \\# 发布提醒
        \\**服务**: payment
        \\**环境**: production
        \\[查看详情](https://example.com)
    ;
    const md_msg = .{ .content = md_content };
    std.debug.print("[Markdown 消息] content:\n{s}\n", .{md_msg.content});

    // 3. 真实发送（需要有效的 webhook key，会向 qyapi.weixin.qq.com 发起 HTTPS 请求）：
    //    const webhook_key = "your-robot-key";
    //    var resp = try robot.sendText(webhook_key, text_msg);
    //    defer resp.deinit();
    //    std.debug.print("errcode={d} errmsg={s}\n", .{ resp.value.errcode, resp.value.errmsg });
    _ = &robot;

    std.debug.print("企业微信群机器人示例运行完毕。\n", .{});
}
