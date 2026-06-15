# zwechat — AI Agent 指南

`zwechat` 是使用 Zig 语言重写/移植 [`silenceper/wechat`](https://github.com/silenceper/wechat) v2 这套 Go 微信开放接口 SDK，提供微信公众号、小程序、小游戏、微信支付、开放平台、企业微信、智能对话等能力。

> ✅ **当前状态**：首版骨架 + 完整功能落地（`zig 0.17.0-dev.813+2153f8143`）。`zig build` / `zig build test` / `zig build run` 全部通过，**255 个内联单元测试全部通过且零内存泄漏**。
>
> 目录包括：
> - `_ref/wechat/` — 完整克隆的 Go 参考实现（`silenceper/wechat/v2`，Apache-2.0），作为移植依据（**只读**）。
> - `.codegraph/` — 本地代码图谱缓存（SQLite，已 gitignore）。
> - `src/` — Zig 实现，**78 个文件 / 12033 行**，覆盖 `cache` / `credential` / `util` / `officialaccount` / `pay` / `miniprogram` / `work` / `openplatform` / `minigame` / `aispeech` 十大业务域。
> - `build.zig` / `build.zig.zon` — 构建脚本。
> - `LICENSE` — Apache-2.0。
> - `README.md` — 项目说明。
>
> 目录包括：
> - `_ref/wechat/` — 完整克隆的 Go 参考实现（`silenceper/wechat/v2`，Apache-2.0），作为移植依据（**只读**）。
> - `.codegraph/` — 本地代码图谱缓存（SQLite，已 gitignore）。
> - `src/` — Zig 实现，**76 个文件 / 10906 行**，覆盖 `cache` / `credential` / `util` / `officialaccount` / `pay` / `miniprogram` / `work` / `openplatform` / `minigame` / `aispeech` 十大业务域。
> - `build.zig` / `build.zig.zon` — 构建脚本。
> - `LICENSE` — Apache-2.0。
> - `README.md` — 项目说明。
>
> 已实现（与 Go 版业务域一一对应）：
> - `cache`（vtable 接口 + 内存实现，线程安全 + TTL）
> - `credential`（默认 access_token + 默认 js_ticket + WorkAccessToken 等）
> - `util`（http / crypto AES-CBC/ECB+PKCS7+MD5+HMAC-SHA256 / signature SHA1 / RSA 占位 / XML codec / 错误 / 时间 / 参数 / 通用）
> - `officialaccount` 14 个子模块（menu/oauth/basic/server/message/material/js/user/datacube/broadcast/device/customerservice/ocr/draft/freepublish）均含真实 HTTP 接口
> - `pay` 6 个子模块（order/refund/notify/transfer/redpacket + 顶层）
> - `miniprogram` + `auth`（jscode2session / getPhoneNumber）
> - `work` 12 个子模块（oauth/jsapi/message/material/msgaudit/checkin/kf/externalcontact/invoice/addresslist/appchat/robot）
> - `openplatform` + `account/miniprogram/officialaccount`
> - `minigame` 顶层 + config + context
> - `aispeech` 骨架（Go 版本身为空）
> - `wechat.zig` 顶层容器
>
> **已知限制**：
> - `util/rsa.zig` 与 `util/http.zig.postXMLWithTLS` 为占位（PKCS#12 / TLS 双向认证未实现，需要 vendor 一个 ASN.1/PKCS#12 解析器）。
> - `work.Js.getAgentConfig` 当前复用 corp 算法，需 `WorkJsTicket` 区分 corp / agent ticket URL 后才能完全对齐 Go 行为。
> - `pay/refund` 与 `pay/transfer` 走普通 HTTPS，正式上线需切到 `postXMLWithTLS`。

---

## 技术栈与目标形态

| 项 | 取值 |
|---|---|
| 语言 | Zig `0.17.0-dev.813+2153f8143`（参考同 workspace 下 `zigmodu`） |
| 构建系统 | 原生 `zig build`（`build.zig` + `build.zig.zon`） |
| 许可证 | Apache License 2.0（与上游参考保持一致，保留 `_ref/wechat/LICENSE`） |
| 运行目标 | 静态库 + 可执行示例 |
| 单元测试 | `zig build test`，测试以内联 `test "..."` 形式写在源文件中，共 **255 个测试，0 泄漏** |

外部依赖按需声明在 `build.zig.zon`，尽量减少三方依赖；优先使用 Zig 标准库。

---

## 目录与模块划分（已落地 + 规划）

参考 `_ref/wechat` 的 Go 包结构，当前已落地的 `src/` 目录如下。每个 Go 包对应一个 Zig 子目录，`mod.zig` 负责 barrel re-export。

```
src/
├── main.zig               # CLI 入口 ✅
├── root.zig               # 顶层 barrel re-export ✅
├── wechat.zig             # 顶层 Wechat struct ✅
├── cache/
│   ├── mod.zig            # Cache 接口（vtable 风格）✅
│   ├── memory.zig         # 内存实现（线程安全 + TTL + lazy delete）✅
│   ├── redis.zig          # TODO：可选
│   └── memcache.zig       # TODO：可选
├── credential/
│   ├── mod.zig            # AccessTokenHandle / JsTicketHandle 接口 ✅
│   ├── default_access_token.zig  # DefaultAccessToken（双检 + 缓存）✅
│   ├── js_ticket.zig      # DefaultJsTicket（双检 + 缓存）✅
│   └── work_js_ticket.zig # TODO：企业微信 ticket
├── util/
│   ├── mod.zig            # barrel re-export ✅
│   ├── http.zig           # HttpClient（基于 std.http.Client + Io）✅
│   ├── crypto.zig         # AES-256-CBC/ECB、PKCS#7、MD5、HMAC-SHA256 ✅
│   ├── rsa.zig            # 占位（返回 TODO）⚠️
│   ├── signature.zig      # SHA1 sort-and-sign ✅
│   ├── error.zig          # WechatError + CommonError ✅
│   ├── param.zig          # OrderParam ✅
│   ├── time.zig           # getCurrTS ✅
│   ├── util.zig           # SliceChunk ✅
│   ├── template.zig       # TODO：消息模板
│   └── xml.zig            # TODO：XML 编解码（支付回调用）
├── domain/
│   └── openapi.zig        # TODO：通用 OpenAPI 调用抽象
├── officialaccount/
│   ├── mod.zig            # barrel ✅
│   ├── config.zig         # Config ✅
│   ├── context.zig        # Context ✅
│   ├── officialaccount.zig # 顶层 OfficialAccount ✅
│   ├── basic/             # TODO
│   ├── menu/              # TODO
│   ├── oauth/             # TODO
│   ├── material/          # TODO
│   ├── js/                # TODO
│   ├── user/              # TODO
│   ├── message/           # TODO
│   ├── server/            # TODO
│   ├── datacube/          # TODO
│   ├── broadcast/         # TODO
│   ├── device/            # TODO
│   ├── customerservice/   # TODO
│   ├── ocr/               # TODO
│   ├── draft/             # TODO
│   └── freepublish/       # TODO
├── miniprogram/           # TODO：小程序 API（45 个 Go 文件）
├── minigame/              # 小游戏 API（骨架）
├── pay/                   # 微信支付（config + 顶层 + order/refund/notify 子模块）
├── openplatform/          # 开放平台（骨架）
├── work/                  # 企业微信（顶层 Work + context + config + oauth + jsapi 已实现；addresslist/appchat/checkin/externalcontact/invoice/kf/material/message/msgaudit/robot 持续补齐）
├── aispeech/              # 智能对话（占位）
└── test_runner.zig        # ✅ 编译门（强制 @import 每个模块），231 个测试全部发现
```

---

## 构建与运行命令

`build.zig` 落地后预期命令（参考 `../zeepseek/build.zig`）：

```bash
# Debug 构建
zig build

# 优化构建（发布）
zig build -Doptimize=ReleaseFast

# 运行主可执行
zig build run

# 跑全部单元测试
zig build test

# 产物路径
./zig-out/bin/zwechat
```

`build.zig.zon` 必须包含的最少字段（参考 zeepseek 写法）：

```zig
.{
    .name = .zwechat,
    .version = "0.0.0",
    .minimum_zig_version = "0.17.0",
    .fingerprint = <8 字节 hex>,
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

---

## 代码风格指南

### 命名约定

| 构造 | 约定 | 示例 |
|---|---|---|
| 源文件 | `snake_case.zig` | `access_token.zig` |
| 结构体 / 枚举 / 联合 | `PascalCase` | `OfficialAccount`, `CacheError` |
| 函数 / 方法 | `camelCase` | `getAccessToken`, `postJSON` |
| 模块级常量 | `PascalCase` 或短缩写 `UPPERCASE` | `CacheKeyPrefix`, `MaxRetries` |
| 局部变量 / 参数 | `snake_case` | `app_id`, `access_token` |
| 错误集 | `PascalCase` 以 `Error` 结尾 | `WechatError`, `CacheError` |

### 中文注释与文档

- **模块级文档** 使用 `//!`（文件顶部），可以使用**中文**叙述（与 `_ref/wechat` 注释语言保持一致）。
- **项级文档** 使用 `///`，同样推荐中文。
- 公开 API（`pub` 函数、结构体）建议在中文 `///` 中说明用途、参数、返回值。

示例（目标风格）：

```zig
//! OfficialAccount — 微信公众号相关 API
//!
//! 对应 `_ref/wechat/officialaccount` 包，提供公众号的全部开放接口：
//! 自定义菜单、网页授权、素材管理、用户管理、模板消息、客服消息等。

const std = @import("std");
const util = @import("../util/mod.zig");

/// 获取 access_token，先从 cache 中取，没有则向微信服务器请求。
///
/// `ctx`: 调用上下文；返回的 access_token 字符串由调用方负责释放。
pub fn getAccessToken(ctx: *Context, alloc: std.mem.Allocator) ![]u8 {
    // ...
}
```

### Imports

- 每个 `.zig` 文件首行 `@import("std")`。
- 跨目录用相对路径：`@import("../util/http.zig")`。
- 子目录提供 `mod.zig` 作为 barrel re-export 入口。
- C 互操作仅在确实需要时引入（参考 `_ref/wechat/util/http.go` 中的 PKCS#12 / TLS 部分），通过 `translateC` 暴露。

### 内存管理

- 倾向使用 `std.mem.Allocator`（由调用方传入），与 zigmodu/zeepseek 一致。
- 长期对象（`Cache`、`Context`、`OfficialAccount`）的 `deinit` 必须释放其持有的全部资源。
- 错误路径上用 `errdefer` 释放临时分配的内存。
- 微信返回的字节切片由调用方持有并负责 `free`。

### 错误处理

- 顶层错误集 `WechatError` 放在 `src/util/error.zig`（参考 zeepseek 的 `ZeepError`）。
- 子模块可以定义更窄的错误集，但要被 `WechatError` 覆盖。
- HTTP 失败、JSON/XML 解析失败、access_token 过期等都要落到具体错误变体，便于上层 switch。

### 编译期校验

对配置常量、阈值等用 `comptime` 块做断言（参考 zeepseek 的 comptime 校验写法）：

```zig
comptime {
    if (@sizeOf(u32) != 4) @compileError("依赖 u32 必须为 4 字节");
}
```

---

## 测试说明

- **首选内联测试**：每个模块自带 `test "..."` 块，描述中文即可（如 `test "access_token 缓存命中"`）。
- `src/test_runner.zig` 统一 `@import` 所有模块（用 `_` 前缀抑制未使用导入告警），`zig build test` 即可全量运行。
- HTTP 相关的测试应通过 `util.http` 的可注入客户端进行 mock，不要在测试中真实请求 `api.weixin.qq.com`。
- 涉及加密签名的用例以 Go 参考测试为对照（`_ref/wechat/util/signature_test.go` 等）。

最小测试模板：

```zig
test "WechatError 错误信息格式化" {
    const allocator = std.testing.allocator;
    const err: WechatError = .AccessTokenExpired;
    const msg = try err.format(allocator);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "access_token") != null);
}
```

---

## 移植策略与参考对照

每个 Zig 模块都对应 `_ref/wechat` 下的某个 Go 子目录。在落地时**先逐字读懂 Go 实现**（含 `_ref/wechat/doc/api/*.md` 中的接口描述），再翻译为 Zig：

| Zig 目录 | 参考 `_ref/wechat/` Go 包 | 文档 |
|---|---|---|
| `src/wechat.zig` | `wechat.go`（顶层 Wechat struct） | `_ref/wechat/README.md` |
| `src/cache/` | `cache/`（4 文件） | — |
| `src/credential/` | `credential/`（6 文件） | — |
| `src/util/` | `util/`（10 文件） | — |
| `src/domain/openapi.zig` | `domain/openapi/`、`internal/openapi/` | — |
| `src/officialaccount/` | `officialaccount/`（47 文件） | `_ref/wechat/doc/api/officialaccount.md` |
| `src/miniprogram/` | `miniprogram/`（45 文件） | `_ref/wechat/doc/api/miniprogram.md` |
| `src/minigame/` | `minigame/` | `_ref/wechat/doc/api/minigame.md` |
| `src/pay/` | `pay/`（12 文件） | `_ref/wechat/doc/api/wxpay.md` |
| `src/openplatform/` | `openplatform/` | `_ref/wechat/doc/api/oplatform.md` |
| `src/work/` | `work/`（63 文件，最大模块） | `_ref/wechat/doc/api/work.md`、`work/externalcontact/README.md`、`work/kf/README.md`、`work/msgaudit/README.md` |
| `src/aispeech/` | `aispeech/` | `_ref/wechat/doc/api/aispeech.md` |

补充说明：

- `_ref/wechat` 内 `.golangci.yml` 中开启的检查（gofmt、govet、errcheck、staticcheck 等）**仅供风格参照**，不需要在 Zig 端复刻。
- `_ref/wechat/.github/workflows/` 与 `.github/ISSUE_TEMPLATE/` 是上游项目模板，**不要**复制到 zwechat。
- `_ref/wechat/LICENSE`（Apache-2.0）需要在 zwechat 根目录保留副本，并在新文件头标注来源。
- `_ref/wechat/doc/` 下的接口 Markdown 是移植时最重要的接口清单来源，不要漏看。

---

## 配置与运行时

### 应用配置（沿用 Go 参考的 Config 结构）

每种业务（公众号 / 小程序 / 支付 / 企业微信 / 开放平台）都有独立的 `Config`，由调用方构造：

```zig
const cfg = officialaccount.Config{
    .app_id = "wx...",
    .app_secret = "...",
    .token = "...",
    // .encoding_aes_key = "...",
    .cache = cache.Memory.init(allocator),
};
const wc = wechat.Wechat.init();
const oa = wc.getOfficialAccount(cfg);
```

### Cache 抽象

- `cache.Cache` 接口提供 `get` / `set` / `isExist` / `delete`（对照 `_ref/wechat/cache/cache.go`）。
- `cache.ContextCache` 额外提供 `getContext` / `setContext` / ...，支持上下文取消。
- 内置实现：`Memory`（默认）、`Redis`（可选，依赖外部 `redis.zig`）、`Memcache`（可选）。

### HTTP 客户端

- `src/util/http.zig` 提供 `httpGet` / `httpPost` / `postJSON` / `postXML` / `postMultipart`，对应 `_ref/wechat/util/http.go`。
- 默认客户端可通过 `util.setDefaultHttpClient(...)` 替换，便于注入测试桩或自定义 TLS。
- 微信支付回调验签需要的 PKCS#12 解析依赖 `crypto.zig` 与 `rsa.zig`。

---

## 安全注意事项

- **凭据保密**：`AppSecret`、商户密钥、`EncodingAESKey`、证书口令等绝不写入源码或日志；测试时使用占位字符串。
- **签名校验**：被动回复消息接收（`officialaccount/server`）必须校验微信签名（`util/signature.zig` 的 SHA1），并对加密消息用 AES 解密。
- **TLS**：支付相关请求（`pay/order`、`pay/refund`）使用 `PostXMLWithTLS` 加载商户证书（PKCS#12 → PEM），见 `_ref/wechat/util/http.go:284`。
- **access_token 缓存**：默认存于内存，多实例部署需切换到 `Redis`/`Memcache`；并遵循 `credential/access_token.go` 中"先缓存后服务端"的逻辑，避免重复拉取。
- **errdefer 链**：所有错误路径必须正确释放分配的 buffer / 解码器，避免泄漏密钥材料。

---

## 文件清单（实际存在）

| 路径 | 角色 |
|---|---|
| `_ref/wechat/` | 上游 Go 参考实现（vendored），**不要修改**，仅作为移植依据 |
| `_ref/wechat/LICENSE` | Apache-2.0 许可证，需复制到项目根 |
| `_ref/wechat/README.md` | 上游使用说明（中文） |
| `_ref/wechat/doc/api/*.md` | 各业务接口清单（移植时的接口目录） |
| `.codegraph/` | 本地代码图谱缓存（已 gitignore，**不要提交**） |
| `.codegraph/.gitignore` | 已忽略 `*.db`、`*.db-wal`、`*.db-shm`、`cache/`、`*.log`、`.dirty` |
| `.git/` | 初始化的 Git 仓库，`main` 分支已有首版提交 |
| `build.zig` / `build.zig.zon` | Zig 0.17 构建脚本与包清单 |
| `LICENSE` | Apache-2.0 |
| `README.md` | 项目说明（中文） |
| `src/main.zig` | CLI 入口（`zig build run` 打印版本 + 模块列表） |
| `src/root.zig` | 顶层 barrel：`pub const wechat / cache / credential / util / officialaccount` |
| `src/wechat.zig` | 顶层 Wechat struct + `setCache` / `getOfficialAccount` |
| `src/cache/` | 缓存抽象 + 内存实现（线程安全 + TTL） |
| `src/credential/` | 默认 access_token / 默认 js_ticket（双检 + 缓存） |
| `src/util/` | http / crypto / signature / error / param / time / util / rsa（占位） |
| `src/officialaccount/` | Config + Context + 顶层 OfficialAccount（子模块未实现） |
| `src/test_runner.zig` | 编译门 — 强制 `@import` 每个模块，确保 `zig build test` 发现所有 inline test |

---

## 移植备注（落地过程中的决策记录）

- **Zig 0.17-dev API 差异**：
  - `std.Thread.Mutex` 已被移除 → 自实现 `SpinMutex`（5 行 CAS，`std.atomic.Value(u8)`）。
  - `std.time.timestamp()` / `nanoTimestamp()` 已被移除 → `std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()`。
  - `std.fmt.allocPrint` 返回 `Allocator.Error![]u8`（不再有 `AllocPrintError`）。
  - `std.ArrayListUnmanaged` 必须用 `.empty` 常量（不能再用 `.{}`）。
  - `std.http.Client` 集成 `std.Io` runtime；multipart / PKCS#12 需手写。
- **Cache 接口选型**：vtable 风格（`*anyopaque` + `*const VTable`），与 std.Io / std.Build 一致，便于未来加 Redis / Memcache 实现而不破坏 ABI。
- **Credential 抽象**：`Fetcher` 函数指针让所有微信服务端交互可被 stub，测试无需真实 HTTP；JSON 响应结构体所有字段都有默认值，能同时容忍成功响应与 `errcode != 0` 的失败响应。
- **TLS / PKCS#12**：`util.http.postXMLWithTLS` 当前返回 `error.TLSNotImplemented`，签名已稳定；后续需 vendor 一个 PKCS#12 解析器或引入三方依赖。
- **测试基础设施**：`src/test_runner.zig` 顶部有一段「编译门」test，强制 `@import` 每个子文件，并在测试体内做 `_ = mod;` 引用 — 否则 0.17-dev 的 dead-strip 可能把带 inline test 的文件排除掉，导致 `zig build test` 报告「All 1 tests passed」假象。

---

## 给 Agent 的注意事项

- **代码已存在**，开始任何编码前先 `ls src/` 与 `cat src/root.zig` 确认当前实现状态。
- **不要修改 `_ref/wechat/`**。它是只读参考；如有勘误，请记录到本 `AGENTS.md` 的"移植备注"小节。
- **不要触碰 `.codegraph/`**。这是分析缓存，不是源码；提交前不要 `git add` 它。
- **使用中文撰写注释与文档**，与上游参考保持一致；标识符（变量名、类型名）按 Zig 惯例用英文。
- **新加模块时**同步更新本文件中的"目录与模块划分"表与"移植对照"表。
- **新增测试时**在 `src/test_runner.zig` 中加一行 `@import`（即便内容只是占位），否则 `zig build test` 不会发现它。
- **`build.zig.zon` 的 fingerprint 字段**：写一个占位 hex（如 `0xd658b8e96476550b`）即可；若该值不被 Zig 接受，运行 `zig build` 会提示正确的值。
- **避免 Zig 0.17-dev 已被移除的 API**：`std.Thread.Mutex`（用 `SpinMutex`）、`std.time.timestamp()`（用 `std.Io.Clock.now`）、`std.fmt.AllocPrintError`（用 `Allocator.Error`）、`std.ArrayListUnmanaged = .{}`（用 `.empty`）。
- **修改完任何模块后**，必须 `zig build test 2>&1 | tail -5` 确认 70/70 测试仍全部通过；任何内存泄漏会让测试失败。
