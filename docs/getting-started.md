# 5-Minute Getting Started

本教程带你用 5 分钟搭建一个最小的 `zwechat` 应用，演示公众号接入 + 企业微信接入 + MockTransport 单元测试。

## 1. 准备

```bash
zig version  # 应 >= 0.17.0
```

## 2. 添加依赖

将 `zwechat` 作为子模块加入你的 `build.zig.zon`：

```zig
.{
    .name = .myapp,
    .version = "0.1.0",
    .fingerprint = <8 字节 hex>,
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .zwechat = .{
            .path = "path/to/zwechat",
        },
    },
    .paths = .{ "" },
}
```

在 `build.zig` 中把 zwechat 接到你的模块：

```zig
const zwechat_mod = b.dependOn("zwechat");
my_module.addImport("zwechat", zwechat_mod);
```

## 3. 最小可运行示例

新建 `src/main.zig`：

```zig
const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. 构造内存 cache
    var mem = try zwechat.cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    // 2. 公众号 config + context
    const cfg = zwechat.officialaccount.Config{
        .app_id = "wx_your_app_id",
        .app_secret = "your_app_secret",
        .token = "your_token",
        .cache = mem.asCache(),
    };
    const ctx = zwechat.officialaccount.Context{
        .config = cfg,
        .access_token_handle = zwechat.credential.DefaultAccessToken
            .init(cfg.app_id, cfg.app_secret, zwechat.credential.CacheKeyOfficialAccountPrefix, mem.asCache())
            .asHandle(),
    };

    // 3. 构造 OfficialAccount 实例
    const oa = zwechat.officialaccount.OfficialAccount.init(ctx);

    // 4. 调用任意子模块（这里以 menu 为例）
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const menu = zwechat.officialaccount.menu.Menu.init(oa.getContext(), fba.allocator());
    _ = menu;

    std.debug.print("OfficialAccount 实例已构造 ✓\n", .{});
}
```

运行：`zig build run`

## 4. 企业微信（一行工厂）

```zig
const w = try zwechat.work.Work.newDefaultWork(
    .{
        .corp_id = "ww_your_corp_id",
        .corp_secret = "your_corp_secret",
        .agent_id = "1000001",
        .cache = mem.asCache(),
    },
    allocator,
);

// 拉取 access_token
const ak = try w.getAccessToken(allocator);
defer allocator.free(ak);

// 拉取 corp ticket（默认）
const ticket = try w.getJsTicket(allocator, ak);
defer allocator.free(ticket);

// 切到 agent ticket
w.setDefaultTicketType(.agent_js);
```

## 5. 单元测试：用 MockTransport 不打真实网络

```zig
const std = @import("std");
const testing = std.testing;
const zwechat = @import("zwechat");

test "用 mock 拉取 access_token 并验证调用历史" {
    const allocator = testing.allocator;

    // 1. 准备 mock
    var mock = zwechat.util.http.MockTransport.init(allocator);
    defer mock.deinit();

    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=wx-test&secret=sec",
        .{ .body = "{\"access_token\":\"mock-tok-abc\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"\"}" },
    );

    // 2. 注入 mock 到 HttpClient
    var client = zwechat.util.http.HttpClient.init(allocator);
    defer client.deinit();
    client.setTransport(zwechat.util.http.MockTransport.dispatch, @ptrCast(&mock));

    // 3. 发起 GET
    const body = try client.get("https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=wx-test&secret=sec");
    defer allocator.free(body);

    // 4. 断言响应 + 历史
    try testing.expect(std.mem.indexOf(u8, body, "mock-tok-abc") != null);
    try testing.expectEqual(@as(usize, 1), mock.history.items.len);
    try testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=wx-test&secret=sec", mock.history.items[0]);
}
```

运行：`zig build test` — 该测试**无需网络**，可在 CI 离线运行。

## 6. 服务端：MessageHandler 路由

完整代码见 [`examples/server.zig`](../examples/server.zig)（暂未提供）—— 公众号 URL 握手 + 加密消息解密 + handler 路由分发，单文件即可启动一个 Zig HTTP 服务对接微信服务器。

简化版核心：

```zig
var s = zwechat.officialaccount.server.Server.init(&ctx, allocator);

// 注册业务 handler
s.setMessageHandler(myHandler, &my_state);

// 处理微信推送（参数来自 HTTP query string）
const response = try s.serve(.{
    .signature = q.get("signature") orelse "",
    .timestamp = q.get("timestamp") orelse "",
    .nonce = q.get("nonce") orelse "",
    .echostr = q.get("echostr") orelse "",
    .msg_signature = q.get("msg_signature") orelse "",
});

fn myHandler(_: *anyopaque, msg: *zwechat.officialaccount.message.MixMessage) anyerror!?zwechat.officialaccount.message.Reply {
    return .{
        .msg_type = .text,
        .data = .{ .text = .{ .content = msg.content } },
    };
}
```

## 7. 下一步

- 阅读 [`architecture.md`](architecture.md) 了解模块依赖与接口设计
- 阅读 [`migration-from-go.md`](migration-from-go.md) 把现有 Go 代码迁移到 Zig
- 阅读 [`api-reference.md`](api-reference.md) 查看完整公共 API
- 对照 [`_ref/wechat/doc/api/*.md`](../_ref/wechat/doc/api/) 找具体业务接口