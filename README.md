# zwechat

> Zig 重写 / 移植 [`silenceper/wechat`](https://github.com/silenceper/wechat) v2 这套 Go 微信开放接口 SDK，提供微信公众号、小程序、小游戏、微信支付、开放平台、企业微信、智能对话等能力的 Zig 实现。

**当前版本：v0.0.1（基础设施阶段）**

> ⚠️ 仓库处于早期建设阶段：抽象层、`util` 工具集、`credential` 凭据骨架以及
> `officialaccount` 入口已落地，业务模块的具体 API（菜单、素材、模板消息、支付下单等）
> 按 Go 参考实现逐个分阶段补齐。详细进度见下方"特性 / 进度"小节。

---

## 特性 / 进度

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| 顶层 `Wechat` | ✅ | `init` / `setCache` / `getOfficialAccount`（含 cache 回退逻辑） |
| `cache` 抽象 + 内存实现 | ✅ | `Cache` vtable 接口；`Memory` 支持 TTL、惰性删除、`std.testing.allocator` 友好 |
| `credential` 凭据骨架 | ✅ | `AccessTokenHandle` / `JsTicketHandle` vtable；提供 `TestCache` 便于单元测试 |
| `util` 工具集 | ✅ | HTTP 客户端、加解密、签名、时间、参数排序、RSA、错误集（部分模块占位） |
| `officialaccount` 入口 | ✅ | `Config` / `Context` / `OfficialAccount.init` / `newOfficialAccount` / `getAccessToken` |
| `miniprogram` / `minigame` / `pay` / `openplatform` / `work` / `aispeech` | ⏳ | 仅在 `_ref/wechat` 中存在参考，规划中 |

后续阶段会按 `_ref/wechat/officialaccount/*.go` 的同名 API 一一翻译，每个 Go 子包
对应 `src/officialaccount/<sub>/` 下的 Zig 子目录。

---

## 快速开始

```bash
# Debug 构建
zig build

# 优化构建（发布）
zig build -Doptimize=ReleaseFast

# 运行示例 CLI（当前仅打印模块版本号）
zig build run

# 跑全部单元测试（`zig build test` 以 src/test_runner.zig 为根，
# 递归执行所有内联 test "..." 块）
zig build test

# 产物路径
./zig-out/bin/zwechat
```

> 需要 Zig ≥ 0.17.0（参考 `build.zig.zon` 中的 `minimum_zig_version`）。

最小用法示例：

```zig
const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. 构造 Wechat，注入全局 cache
    var wc = zwechat.wechat.Wechat.init();
    const mem = try zwechat.cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }
    wc.setCache(mem.asCache());

    // 2. 获取公众号实例
    const cfg = zwechat.officialaccount.Config{
        .app_id = "wx...",
        .app_secret = "...",
        .token = "...",
    };
    const oa = try wc.getOfficialAccount(
        allocator,
        cfg,
        // 调用方决定 access_token 获取策略（默认 / 稳定版 / 自定义 fetcher）
        zwechat.credential.DefaultAccessToken.asHandleFactory(),
    );

    // 3. 透明获取 access_token
    const tok = try oa.getAccessToken(allocator);
    defer allocator.free(tok);
    std.debug.print("access_token = {s}\n", .{tok});
}
```

---

## 模块列表

| Zig 模块 | 参考文档 |
| --- | --- |
| [`src/wechat.zig`](src/wechat.zig) | [`_ref/wechat/README.md`](_ref/wechat/README.md) |
| [`src/cache/`](src/cache/) | [`_ref/wechat/cache/`](_ref/wechat/cache/) |
| [`src/credential/`](src/credential/) | [`_ref/wechat/credential/`](_ref/wechat/credential/) |
| [`src/util/`](src/util/) | [`_ref/wechat/util/`](_ref/wechat/util/) |
| [`src/officialaccount/`](src/officialaccount/) | [`_ref/wechat/doc/api/officialaccount.md`](_ref/wechat/doc/api/officialaccount.md) |
| `src/miniprogram/`（规划） | [`_ref/wechat/doc/api/miniprogram.md`](_ref/wechat/doc/api/miniprogram.md) |
| `src/minigame/`（规划） | [`_ref/wechat/doc/api/minigame.md`](_ref/wechat/doc/api/minigame.md) |
| `src/pay/`（规划） | [`_ref/wechat/doc/api/wxpay.md`](_ref/wechat/doc/api/wxpay.md) |
| `src/openplatform/`（规划） | [`_ref/wechat/doc/api/oplatform.md`](_ref/wechat/doc/api/oplatform.md) |
| `src/work/`（规划） | [`_ref/wechat/doc/api/work.md`](_ref/wechat/doc/api/work.md) |
| `src/aispeech/`（规划） | [`_ref/wechat/doc/api/aispeech.md`](_ref/wechat/doc/api/aispeech.md) |

接口文档以 `_ref/wechat/doc/api/*.md` 为准，移植时优先对照这些清单文件。

---

## 上游参考

`_ref/wechat/` 目录里克隆了完整的 Go 参考实现（[silenceper/wechat](https://github.com/silenceper/wechat)，
Apache-2.0），作为移植依据。所有接口形态与行为均以其为准；Zig 版本在不破坏 API 兼容性的
前提下，可以做小幅语言层面的简化（例如显式 allocator 代替隐式 GC、用 vtable 代替 Go interface）。

> 该目录在仓库中只读，请勿直接修改；`AGENTS.md` 中也明确写了"不要修改 `_ref/wechat/`"。

---

## 许可证

本项目使用 [Apache License 2.0](LICENSE)，与上游 `silenceper/wechat` 保持一致。
上游版权声明见 [`_ref/wechat/LICENSE`](_ref/wechat/LICENSE)。