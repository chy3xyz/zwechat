# zwechat — AI Agent 指南

`zwechat` 是使用 Zig 语言重写/移植 [`silenceper/wechat`](https://github.com/silenceper/wechat) v2 这套 Go 微信开放接口 SDK，提供微信公众号、小程序、小游戏、微信支付、开放平台、企业微信、智能对话等能力。

> ✅ **当前状态**：`zig 0.17.0-dev.2151+2ec5523d5`。`zig build` / `zig build test` / `zig build run` 全部通过，**1087 个内联单元测试全部通过且零内存泄漏**。
>
> 目录包括：
> - `_ref/wechat/` — 完整克隆的 Go 参考实现（`silenceper/wechat/v2`，Apache-2.0），作为移植依据（**只读**）。
> - `.codegraph/` — 本地代码图谱缓存（SQLite，已 gitignore）。
> - `src/` — Zig 实现，**87 个文件 / 15711 行**，覆盖 `cache` / `credential` / `util` / `officialaccount` / `pay` / `miniprogram` / `work` / `openplatform` / `minigame` / `aispeech` 十大业务域。
> - `build.zig` / `build.zig.zon` — 构建脚本。
> - `LICENSE` — Apache-2.0。
> - `README.md` — 项目说明。
>
> 已实现（与 Go 版业务域一一对应）：
> - `cache`（vtable 接口 + Memory / Redis / Memcache 实现，线程安全 + TTL）
> - `credential`（默认 access_token + 默认 js_ticket + WorkAccessToken + WorkJsTicket 等）
> - `util`（http / crypto AES-CBC/ECB+PKCS7+MD5+HMAC-SHA256 / signature SHA1 / RSA-SHA256+PKCS#8+PKCS#1-decrypt / PKCS#12 / XML codec / 错误 / 时间 / 参数 / 通用）
> - `officialaccount` 14 个子模块（menu/oauth/basic/server/message/material/js/user/datacube/broadcast/device/customerservice/ocr/draft/freepublish）均含真实 HTTP 接口
> - `pay` 6 个子模块（order/refund/notify/transfer/redpacket + 顶层），order 增加 query/close/bridgeAppConfig/prePayID
> - `miniprogram` 24 个子模块全量实现（auth / qrcode / urlscheme / shortlink / encryptor / werun / urllink / riskcontrol / redpacketcover / privacy / content / business / order / ocr / subscribe / analysis / operation / tcb / express / minidrama / virtualpayment / message / security）
> - `work` 13 个子模块（oauth/jsapi/message/material/msgaudit/checkin/kf/externalcontact/invoice/addresslist/appchat/robot/smartbot），jsapi 完整支持 corp / agent ticket
> - `openplatform` + `account/miniprogram/officialaccount`，account 支持 component_access_token 缓存与 bind/unbind
> - `minigame` 顶层 + config + context
> - `aispeech` 骨架（Go 版本身为空）
> - `wechat.zig` 顶层容器，已暴露 work/pay/miniprogram/openplatform 工厂
>
> **已知限制**：
> - `util/http.zig.postXMLWithTLS` 的 mTLS 由**仓库内自建**的 `src/util/mtls.zig` 实现（运行时 `std.DynLib` 加载 `libssl`/`libcrypto`，手写 extern 函数指针，**无头文件 / 无 `translateC` / 无 `linkSystemLibrary`**），且**由构建选项 `-Dmtls`（默认 `false`）门控**：默认构建零 Zig 包依赖、零 C 依赖；关闭时 `postXMLWithTLS` 返回 `error.MtlsNotEnabled`，`-Dmtls=true` 且运行时有 `libssl`/`libcrypto` 才可用（否则 `error.OpenSslNotAvailable`）。
> - `pay/refund` / `pay/transfer` / `pay/redpacket` 在 `pay.Config.root_ca` 非空时自动走 `postXMLWithTLS`（**需 `-Dmtls=true`**）；空时退回到普通 HTTPS，便于无证书环境测试。v2 退款/转账建议迁到 v3（`pay/v3/refund.zig` / `pay/v3/transfer.zig`，RSA 签名 + 普通 HTTPS，无需客户端证书）；目前仅 **v2 现金红包**仍刚需 mTLS。

---

## 技术栈与目标形态

| 项 | 取值 |
|---|---|
| 语言 | Zig `0.17.0-dev.2151+2ec5523d5`（参考同 workspace 下 `zigmodu`） |
| 构建系统 | 原生 `zig build`（`build.zig` + `build.zig.zon`） |
| 许可证 | Apache License 2.0（与上游参考保持一致，保留 `_ref/wechat/LICENSE`） |
| 运行目标 | 静态库 + 可执行示例 |
| 单元测试 | `zig build test`，测试以内联 `test "..."` 形式写在源文件中，共 **1087 个测试（含 5 个 fuzz 测试），0 泄漏** |

外部依赖按需声明在 `build.zig.zon`，尽量减少三方依赖；优先使用 Zig 标准库。**当前为零三方依赖**：`build.zig.zon` 的 `.dependencies` 为空（原唯一依赖 `httpz`（`chy3xyz/zhttp`）已移除——它只为微信支付 v2 的 mTLS 服务，却把 OpenSSL + libc 链到所有构建目标）。mTLS 改为仓库内自建 + 构建选项 `-Dmtls`（默认 `false`）门控，详见「移植备注」。

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
│   ├── redis.zig          # RESP Redis 实现 ✅
│   └── memcache.zig       # text-protocol Memcache 实现 ✅
├── credential/
│   ├── mod.zig            # AccessTokenHandle / JsTicketHandle 接口 ✅
│   ├── default_access_token.zig  # DefaultAccessToken（双检 + 缓存）✅
│   ├── js_ticket.zig      # DefaultJsTicket（双检 + 缓存）✅
│   └── work_js_ticket.zig # WorkJsTicket（corp / agent ticket）✅
├── util/
│   ├── mod.zig            # barrel re-export ✅
│   ├── http.zig           # HttpClient（基于 std.http.Client + Io）✅
│   ├── crypto.zig         # AES-256-CBC/ECB、PKCS#7、MD5、HMAC-SHA256 ✅
│   ├── rsa.zig            # RSA-SHA256、PKCS#8、PKCS#1 decrypt、PKCS#12 ✅
│   ├── signature.zig      # SHA1 sort-and-sign ✅
│   ├── error.zig          # WechatError + CommonError ✅
│   ├── param.zig          # OrderParam ✅
│   ├── time.zig           # getCurrTS ✅
│   ├── util.zig           # SliceChunk ✅
│   ├── template.zig       # TODO：消息模板
│   ├── sync.zig           # SpinMutex 兼容层（零参数 API）+ defaultIo；内部已改为 std.Io.Mutex ✅
│   ├── retry.zig          # callApi：token 注入 + errcode 判定 + 失效自愈重试一次 ✅
│   ├── json.zig           # JSON 字符串转义/字段拼接 helper（全仓唯一实现）✅
│   ├── uri.zig            # queryEscape（Go url.QueryEscape 语义，全仓唯一实现）✅
│   ├── xml.zig            # XML 编解码（支付回调用）✅
│   ├── asn1.zig           # DER 解析器 ✅
│   ├── pkcs12.zig         # PKCS#12 解析器 ✅
│   └── mtls.zig           # 自建 OpenSSL 桥（std.DynLib + 手写 extern，-Dmtls 门控）✅
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
├── miniprogram/           # 小程序 API：24 个子模块全量实现
├── minigame/              # 小游戏 API（骨架）
├── pay/                   # 微信支付（config + 顶层 + order/refund/notify/transfer/redpacket 子模块）
├── openplatform/          # 开放平台：account/component_access_token 已实现，其余子模块待补齐
├── work/                  # 企业微信（顶层 Work + context + config + oauth + jsapi 已实现；addresslist/appchat/checkin/externalcontact/invoice/kf/material/message/msgaudit/robot 持续补齐）
├── aispeech/              # 智能对话（占位）
└── test_runner.zig        # ✅ 编译门（强制 @import 每个模块），1087 个测试全部发现
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
| `src/util/` | `util/`（14 文件） | — |
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

- `src/util/http.zig` 提供 `httpGet` / `httpPost` / `postJSON` / `postXML` / `postMultipart` / `postXMLWithTLS`，对应 `_ref/wechat/util/http.go`。
- 普通请求基于 `std.http.Client` + `std.Io`；`postXMLWithTLS` 的 mTLS 由 `src/util/mtls.zig`（自建 OpenSSL 桥：运行时 `std.DynLib` 加载 `libssl`/`libcrypto` + 手写 extern 函数指针）实现，**受 `-Dmtls`（默认 false）门控**——关闭时返回 `error.MtlsNotEnabled`，默认构建不链 OpenSSL / libc。
- `HttpClient` 支持可注入 `Transport`，`MockTransport` 用于离线单元测试。
- 微信支付回调验签需要的 PKCS#12 解析依赖 `crypto.zig` 与 `rsa.zig`（纯 Zig，无 C 依赖）。

---

## 安全注意事项

- **凭据保密**：`AppSecret`、商户密钥、`EncodingAESKey`、证书口令等绝不写入源码或日志；测试时使用占位字符串。
- **签名校验**：被动回复消息接收（`officialaccount/server`）必须校验微信签名（`util/signature.zig` 的 SHA1），并对加密消息用 AES 解密。
- **TLS**：支付相关请求（`pay/refund`、`pay/transfer`、`pay/redpacket`）在配置 `root_ca`（商户 P12 路径）后，使用 `postXMLWithTLS` 加载商户证书（PKCS#12 → PEM）完成 mTLS，**且构建时必须 `-Dmtls=true`**；未配置时退回到普通 HTTPS，仅用于测试/开发。自建桥的安全纪律（强制 `SSL_get_verify_result`、TLS1.2 下限、不复用会话）见 `src/util/mtls.zig` 与 `docs/OPEN_ITEMS.md` 第 12 条。
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
| `src/root.zig` | 顶层 barrel：wechat / cache / credential / util / officialaccount / pay / miniprogram / work / openplatform |
| `src/wechat.zig` | 顶层 Wechat struct + `setCache` + `getOfficialAccount` / `getWork` / `getPay` / `getMiniProgram` / `getOpenPlatform` |
| `src/cache/` | 缓存抽象 + Memory / Redis / Memcache 实现 |
| `src/credential/` | 默认 access_token / 默认 js_ticket / WorkAccessToken / WorkJsTicket（双检 + 缓存） |
| `src/util/` | http / crypto / signature / error / param / time / util / rsa / asn1 / pkcs12 |
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
- **SpinMutex 统一**：`cache.Memory` 与 `credential` 各令牌获取器原先各自内联一份 5 行 CAS 自旋锁（Zig 0.17-dev 移除了 `std.Thread.Mutex`），已统一收敛到 `src/util/sync.zig`（`util/mod.zig` 以 `sync` 导出；`work_access_token.zig` 的 `pub const SpinMutex` 保留为再导出以兼容已有引用）。
- **Credential 抽象**：`Fetcher` 函数指针让所有微信服务端交互可被 stub，测试无需真实 HTTP；JSON 响应结构体所有字段都有默认值，能同时容忍成功响应与 `errcode != 0` 的失败响应。
- **微信 JSON 契约对齐（批量修复）**：std.json 默认 `ignore_unknown_fields = false`——字段名与微信 JSON key 差一个字符即整个调用 DecodeError。已全仓清扫：解析微信 HTTP 响应的 `parseFromSlice` 站点一律加 `.ignore_unknown_fields = true`；字段名必须与微信返回 key **逐字一致**，包括官方笔误（`vaild`、msgaudit 的 `exteranalopenid`）、camelCase（`phoneNumber`/`purePhoneNumber`/`countryCode`）、`w/h`（img_size）、`chatid`（appchat）。请求侧凡嵌用户文本/JSON 的字段一律经 `std.json.Stringify` 转义，禁止 `allocPrint` 裸插值（tcb query、msgSecCheck content 曾因此产生非法 JSON）。virtualpayment 的 `env` 契约是**数字**（0/1）不是字符串，序列化处已特判 `@intFromEnum`。
- **懒分析陷阱（泛型参数顺序）**：Zig 只分析被实例化的泛型——多个模块的私有泛型 helper（`ocr.fetch`、`tcb.postParsed`/`databaseReq`、`virtualpayment.callUser`/`callPay`/`postBody`）曾出现 `comptime T` 声明位置与全部调用点不一致的潜伏编译错误，旧工具链下从未被触达。教训：新泛型 helper 落地时必须有一个**真实调用它的测试**，否则错位要等到别人第一次调用才炸。
- **公开 API 变更记录（契约修正，非兼容性保证）**：`work/material` 删除 `getMediaList`（`/cgi-bin/material/get_materiallist` 端点在企业微信不存在）；`work/msgaudit` 重写 `getRoomInfo(roomid)`（真实端点 `groupchat/get`）与 `getAgreeInfo`（真实端点 `check_single_agree`，响应用 `agree_status` 字符串）；`work/appchat` 的 `ChatInfo` 增加 `chat_info` 内层、`CreateChatResponse.chat_id`→`chatid`；`openplatform/account` 四方法（createOpenAccount/getOpenAccount/bind/unbind）均改收 `authorizer_access_token` 并以 `?access_token=` 注入，`Context` 新增 `getAuthrAccessToken`/`refreshAuthrAccessToken`（api_authorizer_token 刷新链路，缓存 key `authorizer_access_token_{appid}`）。`miniprogram/auth` 的 `checkEncryptedData` 请求体改 JSON。
- **工具链升级 0.17.0-dev.2151 适配**：`std.builtin.Type.Struct` 的 `.fields` 拆分为 `.field_names`/`.field_types` 并行遍历；`inline for` 内 `continue` 报 comptime control flow 错（重构为布尔标志）；`std.Uri.Component{ .raw = s }.formatQuery()` 是 0.17 的 query 编码入口（`isQueryChar` 已私有化）。
- **懒分析陷阱第二波（40 方法修复）**：miniprogram/{analysis,operation,minidrama,express,order,subscribe} 的私有泛型 helper 再现 `comptime T` 声明位与调用点错位（40 个公开方法首次调用即编译炸），连同 ocr/tcb/virtualpayment 共 9 个模块全部统一为「T 在参数末位」约定。**纪律**：每个模块至少要有 1 个走 mock transport 真实调用公开方法的测试——纯默认值断言的「伪测试」无法实例化泛型，永远发现不了这类错误。
- **并发模型决策（三轮评估后定案）**：① Memcache/Redis 是单连接客户端，SpinMutex 保护**整个请求-响应往返**（交错写 socket 即协议损坏）；② credential 四个获取器改 singleflight 式——锁只护缓存读/写双检，HTTP 回源在锁外（接受 N 个并发幂等回源，避免 N-1 线程持自旋锁空转烧 CPU）；③ openplatform token 链路**刻意持锁跨 HTTP**——authorizer 刷新会轮换 refresh_token，并发覆盖会永久丢凭据，串行化是必须的；④ `Cache.get` 返回借用切片，有效期至该实例任何后续写操作/deinit（Memcache/Redis 后端任何后续 get 即失效），跨写持有必须 dupe——`cache/mod.zig` 的 get 文档已写明。
- **公开 API 变更记录（追加）**：`miniprogram/content.checkText(text)` → `checkText(openid, text, scene)`（msg_sec_check 的 openid/scene 是必填）；`officialaccount/customerservice.listAccounts()` 改返回类型化 `Parsed(KfListResponse)`；`officialaccount/user.OpenidList.openids` → `.data.openid`（对齐微信真实嵌套响应）；`miniprogram/riskcontrol` 双收 `unoin_id`（官方笔误，真实线上 key）+ `union_id` 兜底，读用 `getUnionId()`；`work/externalcontact` 补 `ExternalProfile` 子树（ExternalAttr 三类平铺）。**弃用标注（不删方法）**：`MiniProgram.getMessage/getContent` 标记弃用（推荐 getSubscribe().send / getSecurity().msgSecCheck），`getBusiness.getPhoneNumber` 标注推荐用 `getAuth().getPhoneNumber`。**新增错误变体**：`util.http.postXMLWithTLS` 在 `-Dmtls=false`（默认）时返回 `error.MtlsNotEnabled`，运行期加载不到 `libssl`/`libcrypto` 时返回 `error.OpenSslNotAvailable`——使用 v2 mTLS 的调用方必须处理这两个变体（或迁移到 v3）。
- **errcode 漏检补齐**：`officialaccount/user`（getUserInfo/getOpenidList）、`customerservice/listAccounts`、`miniprogram/qrcode.getUnlimited`（接入此前零调用的 `util_error.handleFileResponse` 识别 JSON 错误体）。SDK 纪律：解析微信响应必须 errcode 检查或走 `decodeWithCommonError`，失败抛 `WechatError.ApiError`，不推给调用方。
- **P3 功能补齐批次（对照 Go 参考逐方法移植，全部带 mock-transport 调用测试）**：openplatform 首次授权链路（`context/auth.zig`：queryAuthCode/getPreCode/getAuthrInfo/getComponentLoginPage/getBindComponentURL(V2)）+ FastRegisterWeapp（`miniprogram/component.zig`）；work/addresslist 33/33 全覆盖（部门/成员/标签/互转/邀请/互联企业）；work/externalcontact 78/79（contact_way 全套、groupchat、离职/在职继承、群发、朋友圈、客户规则、获客助手；仅 GetCallbackMessage 非 REST 未移植）；work/kf 31 个服务端 API（syncMsg 游标、升级服务、知识库、统计）；officialaccount 客服消息全类型 + 转客服 + typing、用户标签/黑名单/batchGet；datacube 21/21、broadcast 12、material AddVideo、customerservice 账号管理 7。基础设施：`util/http.zig` 新增 `getFollowRedirect`（GET 手动 302 跟随，≤2 跳，仅 http/https，防开放重定向）+ `officialaccount/material.getMedia`/`work/material.getTempFile` 媒体下载；miniprogram 长尾 mediaCheckAsync/getPaidUnionID/queryScheme/uniformSend。要点：`std.Uri.Component.formatQuery` 不转义 `&=?/:`，与 Go `url.QueryEscape` 不兼容，授权链接构造需手写 Go 语义转义；返回 `std.json.Parsed` 必须 `.allocate = .alloc_always`。
- **P3 收尾批次**：openplatform/miniprogram 代运营接口（`basic.zig`：账号信息/昵称/签名/头像/搜索状态，走 authorizer token）；oa material AddMaterial 图片/语音、broadcast preview（PreviewTarget union，替代 Go 链式 API）+ SendImage；miniprogram 订阅推送解析（`PushReceiver.getMsgData` JSON/XML 双路径）；kf 富媒体（`sendMsgRich` 9 类消息 union、syncMsg 9 类消息 + 4 类事件强类型）；pay v3 退款（`pay/v3/refund.zig`，Go 参考无 v3，以微信官方文档为准；notify 解密复用现有 GCM 能力）；oa user 分页封装（`listAllUserOpenIDs`/`getAllBlackList`，带游标不推进兜底）。`doc/api_guide.md` 从 235 行扩到 ~620 行（开放平台授权全链路时序 + work/miniprogram/oa 高频场景 + 缓存凭据配置 + 每章「常见坑」框）。
- **msgaudit 解密 SDK 决策：明确不做**。企业微信会话存档消息解密依赖官方私有 `libWeWorkFinanceSdk`（C ABI + 预编译 .so/.dll），Go 参考也是 cgo 直连；Zig 侧引入需 link 闭源二进制且无法离线测试，与「测试不依赖外部服务」纪律冲突。当前只提供元数据接口（getRoomInfo/getAgreeInfo/getChatInfo）。如未来业务必需，再单独立项做 C ABI 绑定 + 真机集成测试。
- **最后三处尾巴（已清零）**：① broadcast 全员群发 `sendXxxToAll` 六组（`mass/sendall` + `filter:{is_to_all:true}`，对应 Go `chooseTagOrOpenID` 的 `user==nil` 分支）；② miniprogram 推送事件 **15/15 全覆盖**（getEvent 全部 case，JSON/XML 双路径，未知事件仍回退 raw 兜底）；③ kf `OriginData` 原始 JSON 回捕——用 `std.json` 的 `jsonParse` 钩子实现：`SyncMessage.jsonParse` 先把消息元素物化成 `std.json.Value` 树，再 `parseFromValueLeaky` 解出强类型字段并把树挂到 `origin_data`（单次解析、同一 arena、对既有代码零侵入），配套 `getOriginData`/`originAs`/`originPayloadAs` 支持对未建模字段/newtype 的二次解析。代价：每条消息多一份 Value 副本（解析开销与内存约翻倍），若成热点可按 msgtype 白名单开关；重复 JSON 键的默认行为仍是**报错**（`std.json` 的 `duplicate_field_behavior` 默认 `.@"error"`，且对 `Value` 路径同样生效）——原先此处写成"变为后者覆盖"是错的；若要容忍重复键需显式设 `.use_last`（未采用）。
- **Go 参考覆盖率现状**（对照 `_ref/wechat`）：officialaccount 客服消息/用户标签/黑名单/datacube 21/21/素材/broadcast 12+6/客服账号管理；work addresslist 33/33、externalcontact 78/79（仅非 REST 的 GetCallbackMessage 未移植）、kf 服务端 31/31 + 富媒体收发 + OriginData、appchat/message/oauth/robot/jsapi/server/material 对齐；miniprogram 全域含推送 15/15 事件解析；openplatform 授权全链路 + 代运营接口；pay v2 六模块 + v3（config/signer/order/notify/refund/transfer）。**唯一已知不做**：msgaudit 解密（见上条）。
- **错误可观测性（errcode 不再丢）**：`util/error.zig` 的 `parseCommonError`（含 `decodeWithCommonError` 与 `handleFileResponse`）在 errcode != 0 时把 `errcode/errmsg/api_name` 写入**线程局部零分配缓冲**，消费方用 `util_error.lastErrorDetail()` 取（借用，有效期至本线程下次记录/清除；成功不清除，需要「本次成功即无错」语义时先 `clearErrorDetail()`）。`WechatError` 错误集保持不变（兼容）。目的：区分 40001/45009/40003/48001，日志里能查到码。
- **token 失效自愈（全仓接线）**：机制 = `AccessTokenHandle.VTable.invalidate`（可选字段，默认 null 的实现返回 `error.InvalidateNotSupported`）+ `JsTicketHandle.VTable.invalidate` + 各 Context 的 `invalidateAccessToken`/`invalidateJsTicket` + `util/retry.zig` 的 `callApi(ctx, allocator, api_name, sender)`。语义：取 token → sender 发请求 → 若 errcode 是 token 失效码（40001/40014/41001/42001）→ 作废缓存 → 取新 token → **只重试一次**；非 token 类 errcode → `ApiError`；网络错误不重试。sender 必须提供 `pub fn send(self: @This(), allocator, token) anyerror![]u8`（**必须 pub**）。开放平台 token 链路是例外：**刻意持锁跨 HTTP**（authorizer 刷新会轮换 refresh_token，并发覆盖会永久丢凭据）。
- **媒体下载限额**：`util/http.zig` 的 `getFollowRedirectLimited(uri, max_bytes)` / `getFollowRedirectToFile(uri, path, max_bytes)`（超限 `error.ResponseTooLarge`，落盘失败会删不完整文件；真流式：Content-Length 预判 + 16KiB 分块累加；**注入 transport 的 mock 路径只能读完后判定**，已在文档写明）。`officialaccount/material` 与 `work/material` 的下载方法默认上限 100 MiB（图片 10 MiB / 语音 2 MiB 等常量另有区分），旧签名保留。
- **`getDefaultClient` 分配器契约**：启动期用 `initDefaultClient(allocator)` 进入严格模式（幂等；allocator 不一致 → `error.AllocatorMismatch`，其后 `getDefaultClient` 传错 allocator 会 `@panic`）；**懒初始化路径仍保持历史宽容语义**（首个 allocator 生效），可用 `defaultClientAllocatorMatches(allocator)` 自查。测试辅助一律走 `deinitDefaultClient()` 而非依赖宽容语义。
- **Redis 连接池**：`cache/redis.zig` 的 `Options.max_connections`（默认 1 = 历史单连接语义）与 `pool_timeout_ms`（默认 30s）；池锁**只护空闲表**，网络 I/O 全在锁外；坏连接（协议/IO 错）丢弃不进池；等待有界，超时返回 `error.PoolTimeout`（vtable 边界映射为 `StorageError`）并可用 `redis.poolStats()` 观测（live/idle/in_use/peak_in_use/created/discarded/timeouts）。
- **手写编码收敛**：`util/json.zig`（`appendEscapedString`：`"`、`\`、`\b`、`\f`、`\n`、`\r`、`\t`、其余 <0x20 → `\u00xx` 小写 hex）与 `util/uri.zig`（`queryEscape`：保留 Go 的 unreserved 集、空格→`+`）分别是全仓唯一实现——原先 11 份手写 JSON escaper 与 3 份手写 QueryEscape 已收敛。注意 `std.Uri.Component.formatQuery` **不**转义 `&=?/:`，与 Go `url.QueryEscape` 不兼容，拼 query 一律用 `util_uri.queryEscape`。有意保留的 raw 注入点（`draft.add` 的 `articles_json`、`subscribe` 的 `data`、`message.sendSubscribeMessage` 的 `data`）是调用方自带 JSON 对象的契约，勿"顺手"转义。
- **API 面门禁与真实探针**：`tools/api_surface_check.sh`（快照生成器是 `tools/api_surface.zig`，基于 `std.zig.Ast`；`tools/api_surface.awk` 保留作交叉校验参考；快照 `api/surface.txt`，CI 已在 test job 中调用）——删除/改名公开符号必须在 CHANGELOG 最新段落或 [Unreleased] 里写明（`容器.旧名` 或 `容器.字段.子字段`，**只写裸叶名不认**），否则 CI 失败；`--update` 刷新快照。快照为每个 pub fn 额外生成一行 `sig`（参数类型 + 返回类型），因此**改参数/返回类型也会触发门禁**（这是 AST 版相对 awk 版补上的漏报面）。`zig build live-probe`（env `ZWECHAT_LIVE_PROBE=1` + 各域凭据，默认不联网、`-Dstrict` 才以 FAIL 退非零）用于发现"上游改了字段名"这类 mock 测不出的漂移。
- **文档**：`docs/UPGRADING.md`（面向下游的版本升级速查，含 before/after 与 submodule bump 步骤）、`docs/OPEN_ITEMS.md`（已知取舍与开放项：msgaudit 不做、ignore_unknown_fields 的沉默另一面、redis 吞吐上限、媒体限额、懒初始化宽容语义、OriginData 内存代价、pay v2 错误内联等）。
- **并发原语：`std.Io.Mutex` 取代自旋锁（本仓不再有自旋锁）**：`std.Io.Mutex` 是 `extern struct`、可**静态初始化并直接内嵌为结构体字段**（`std/Io.zig` 的 `Mutex.init`），只有 `lock`/`unlock` 需要传 `io`；底层走 futex（Linux `futex(2)`、macOS `__ulock_wait2`、Windows `RtlOnAddress`），**长临界区里等待者睡眠而不是空转**。`util/sync.zig` 的 `SpinMutex` 保留为**兼容层**（零参数 `lock()`/`unlock()`/`tryLock()` 语义不变，内部 `lockUncancelable`），新代码一律直接用 `std.Io.Mutex` + 结构体 `io` 字段。约定：结构体持有一个可注入的 `io: std.Io`（默认 `std.Io.Threaded.global_single_threaded.io()`），临界区写法 `self.mutex.lockUncancelable(self.io); defer self.mutex.unlock(self.io);`。**已知的长临界区是刻意的**：memcache get 跨整个 RTT（单连接必须串行化）、credential 在锁内做缓存双检+回写、openplatform 在锁内串行化 authorizer 刷新（防 refresh_token 轮换被并发覆盖）。
- **测试编译门升级为声明级**：`src/test_runner.zig` 的 `_ = mod;` 已全部换成 `std.testing.refAllDecls(mod)`（`std.testing.refAllDeclsRecursive` 在本工具链**已移除**，别用）。语义从"文件被解析"提升到"每个顶层声明都被语义分析"——首次启用就暴露并修掉了 `util/crypto.pkcs5Pad` 的错误集不一致。**注意**：`refAllDecls` 不实例化泛型，所以「泛型参数位错位」仍必须靠真实调用测试（仓库纪律：每个模块至少一个走 mock transport 的真实调用测试）。
- **fuzz 测试（`zig build test --fuzz=<N>`）**：`util/{xml,asn1,pkcs12,json,uri}.zig` 各有 1 个 `std.testing.fuzz` 用例；普通 `zig build test` 下只做零输入冒烟（不拖慢 CI），fuzz 模式才真跑。**首次引入即发现 3 个真实缺陷**：① `util/uri.queryEscape` 容量按 1 倍预留却写最多 3 倍（Debug/ReleaseSafe panic、**ReleaseFast 堆溢出**）——已改 `3 *| len` 预留 + 自动扩容 `append`；② `util/xml.parse` 接受空标签名（`<>` 被当成合法文档）；③ `util/json.appendEscapedString` 对非法 UTF-8 产出非法 JSON（现按 Go 语义逐字节替换为 `\ufffd`）。新增解析器/转义器时**优先补一个 fuzz 用例**。
- **`zig build test` 的 `failed command: …--listen=-` 是工具链的上报不一致，不是测试失败**：只要测试步骤真的执行，输出里就会出现该行（并附带测试进程 stderr 转储），但同一份汇总仍是 `N/N tests passed` + `test success`、退出码 0。已实测：子进程 **exit 0**（lldb 验证）、无 abort/panic、一次构建只 spawn 一次测试二进制、干净缓存/静音日志/最小项目都不复现（最小项目 + fuzz 用例也不复现）。成因指向 `test_runner` 的 stdio 协议与仓库代码共用 `Io.Threaded.global_single_threaded` 这一非线程安全单例。**判据**：看 `--summary all` 的 `N/N tests passed` 与退出码，**不要**把这行当失败；需要干净输出时直接跑 `.zig-cache/o/*/test`。详见 `docs/OPEN_ITEMS.md` 第 13 条。
- **手写假 server 的端口约定**：测试用假 server **不要**用 `reuse_address = true` —— POSIX 上它同时打开 `SO_REUSEPORT`，会让**多个测试进程**绑定同一端口、内核把连接分摊给它们，导致某个假 server 的 `accept` 永远等不到请求、`defer join()` 永久挂住（实测挂死 14 分钟）。`util/http.zig` 的 `listenLocal` 已明确用 `reuse_address = false` + 端口递增。
- **Io 注入惯例（继续扩展）**：库代码**不直接取全局 Io**——需要 io 的模块把 `io: std.Io = std.Io.Threaded.global_single_threaded.io()` 作为**可注入字段**（`cache.*`、`credential.*`、`officialaccount/{material,server}`、`work/material`、`pay/v3/order` 已如此），纯工具函数提供 `*WithIo(...)` 变体（`getCurrTSWithIo` / `randomStrWithIo` / `ed25519GenerateKeyPairWithIo`，旧函数保留并委托，标 deprecated）。`std.Options.debug_io` **只用于 `std.debug` 语义**（打印/栈回溯），不要再当应用 Io 用；`main`/示例用 `std.process.Init` 的 `io`/`arena`。**迁移状态**：生产代码已全部迁完（`grep -rn "getCurrTS()\|randomStr(" src/` 只剩 `integration_test.zig` 的测试；`std.Options.debug_io` 只剩各测试块内的 `sleep`/取时）。**纪律**：新增代码一律用注入的 `io` 字段或 `*WithIo` 变体，不要直接取全局单例或 `debug_io`。
- **cache 层硬化要点**：① TTL 取时用 `Clock.boot`（**计入系统休眠**），纯耗时测量仍用 `.awake`——两者混用会导致"休眠唤醒后仍用已过期 token"；② 主机解析用 `std.Io.net.IpAddress.parse`（IPv4/IPv6 字面量，`[v6]:port`），**域名要走 `net.HostName.lookup`——`IpAddress.resolve` 不是 DNS**（它只多支持 IPv6 作用域后缀，实测 `resolve(io,"localhost",…)` 返回 `ParseFailed`）；③ 读超时 `Options.recv_timeout_ms` 与**建连超时 `Options.connect_timeout_ms` 都是 opt-in**（默认 `0` = 不超时，保持既有行为）；两者的区别是：前者只约束单次读取、后者约束 TCP 握手。超时都必须让连接**丢弃不进池**，否则残留半包会让后续请求协议失步。
- **PKCS#12 安全边界**：`iteration_count` 取自文件内容，必须设上限（当前 `max_pbkdf2_iterations = 5_000_000`，超限 `error.UnsupportedPbe`），否则畸形文件可让 PBKDF2 长时间占 CPU（DoS）。同类"文件里带的循环次数/长度"字段都应先做上限判断再使用。
- **HTTP 层的 std 化（0.17 能力）**：重定向已全部交给 `std.http.Client` 的 `RedirectBehavior.init(n)` + `receiveHead`（RFC 3986 解析、跨域换连、303/301+POST 改写 GET 均由 std 完成），对外错误名经 `mapRedirectError` 保持兼容（`TooManyRedirects` / `HttpStatusNotOk` / `InvalidRedirectLocation`）；响应体统一受 `HttpClient.max_response_bytes`（默认 16 MiB）约束，用 `Content-Length` 预判 + `Reader.allocRemaining(.limited(n))`（`allocRemaining` 按 limit+1 读，**恰好等于上限不误判**）。要自带头部（如 pay v3 的 `Authorization`）走 `HeaderTransport` / `requestWithHeaders`，不要另建 `std.http.Client`。**`util/mtls.zig` 的 `buildRequest` 必须自写**：std 的请求写出绑死在 `Connection` 上（读写端是具体类型、`Connection.Tls` 私有），没有自定义 TLS 后端入口 —— 而客户端证书正是 `std.crypto.tls.Client` 不支持的能力（其 `Options` 无证书字段，且 std 无 RSA 私钥签名）。
- **TLS / PKCS#12 / mTLS（`-Dmtls` 门控，仓库内自建）**：`util.pkcs12.zig` 已实现最小 PKCS#12 解析（PBES2/PBKDF2/AES-256-CBC），`util.rsa.zig` 提供 `parseP12` 包装，均为**纯 Zig**。mTLS 不再依赖第三方包：`src/util/mtls.zig` 用 `std.DynLib` **运行时**加载 `libssl`/`libcrypto` 并手写 extern 函数指针（**无头文件、无 `translateC`、无 `linkSystemLibrary`**）；`util.http.postXMLWithTLS` 读取 P12 → 解析 PEM → 走该桥完成 POST XML + 客户端证书。**安全纪律**：OpenSSL 宏在 extern 桥里不可用，设置 SNI 必须走 `SSL_ctrl(55)`（`SSL_CTRL_SET_TLSEXT_HOSTNAME`）、TLS 1.2 下限走 `SSL_CTX_ctrl(123)`（`SSL_CTRL_SET_MIN_PROTO_VERSION`）；握手后**必须**校验 `SSL_get_verify_result == X509_V_OK`；不复用会话。边界刻意收窄——只做这一条窄路径（POST XML + 客户端证书），不实现通用 TLS 客户端。
- **零依赖设计（移除 zhttp / httpz）**：结论——那唯一的第三方 Zig 依赖 `chy3xyz/zhttp` 只为微信支付 **v2** 的 mTLS 服务，代价却是把 OpenSSL + libc 链到**所有**构建目标、并要求消费方装 `libssl-dev` / `openssl@3`，收益远小于成本，故整体移除。`build.zig.zon` 现为**空 `.dependencies`**（零 Zig 包依赖、构建期不联网取依赖），默认构建零 C 依赖。原 httpz 能力改由 `src/util/mtls.zig` 承接，并以构建选项 **`-Dmtls`（默认 `false`）** 门控：关闭时 `postXMLWithTLS` 返回 `error.MtlsNotEnabled`；开启时只需**运行时**有 `libssl`/`libcrypto`（`dlopen` 失败 → `error.OpenSslNotAvailable`），构建期仍不需要头文件。同类取舍见 `docs/OPEN_ITEMS.md` 第 12 条。
- **测试基础设施**：`src/test_runner.zig` 顶部有一段「编译门」test，强制 `@import` 每个子文件，并在测试体内做 `_ = mod;` 引用 — 否则 0.17-dev 的 dead-strip 可能把带 inline test 的文件排除掉，导致 `zig build test` 报告「All 1 tests passed」假象。
- **最新增强**：
  - **移除 httpz，mTLS 改 `-Dmtls` 可选**：删除 `build.zig.zon` 的 `httpz` 依赖，新增 `src/util/mtls.zig`（`std.DynLib` + 手写 extern）；`build.zig` 去掉 `dependency("httpz")` / `setupOpenSSL` / `resolveOpenSSLInclude`，改为 `-Dmtls` 选项（默认 false）在启用时才链接 OpenSSL。**破坏性**：v2 mTLS 用户需显式 `-Dmtls=true`。CI 默认 job 不再安装 `libssl-dev`/`openssl@3`，新增"产物未链接 OpenSSL"回归检查与 `-Dmtls=true` 编译 job。（下文的 httpz v0.6.0 / v0.6.1 升级记录与"动态 OpenSSL 路径感知"均为**历史**，现已随依赖移除而不再适用。）
  - **httpz 升级 v0.6.0**：依赖改为 git URL（`chy3xyz/zhttp` v0.6.0）经 `zig fetch` 引入，删除 `vendor/httpz/`；上游官方支持 mTLS（`auth`/`cert`）与 `-Dopenssl-include` 参数化，本地补丁全部作废。
  - **httpz 升级 v0.6.1**：`zig fetch --save=httpz git+https://github.com/chy3xyz/zhttp#v0.6.1` 升级到 tag `v0.6.1`（commit `60a0212`），`build.zig.zon` 采用 `git+https://...#commit` 形式；v0.6.1 相对 v0.6.0 为内部修复（Headers 保留头、Request percent-encoding 安全、chunk 边界），无破坏性 API 变化，`build.zig` / `util/http.zig` 无需改动。
  - **动态 OpenSSL 路径感知**：`build.zig` 中新增基于 `std.Io.Dir.cwd().access` 的安全目录校验，兼容 macOS Homebrew `/opt/homebrew/opt/openssl@3` 与 `/usr/local/opt/openssl@3`。
  - **基准测试 (Benchmark)**：新增 `src/util/benchmark.zig` 与 `zig build bench` 命令，实测 SHA1 签名 ~253 ns/op，AES-256-CBC 解密 ~116 ns/op，XML 解析 ~137 ns/op。
  - **场景示例 (Examples)**：新增 `examples/officialaccount_server.zig`（公众号消息验证与 AES 解密）、`examples/pay_order.zig`（支付统一下单与 BridgeAppConfig 调起签名）、`examples/work_robot.zig`（企微机器人与 JSAPI 实例）。可通过 `zig build run-oa-server` / `zig build run-pay-order` / `zig build run-work-robot` 运行。
  - **CI/CD**：新增 `.github/workflows/ci.yml` 跨平台自动化测试。
  - **智能 Token 自动重试与强刷 (P1)**：新增 `isTokenInvalidErrCode` 判断及 `DefaultAccessToken.forceRefresh`，自动清理无效 Token 并重新回源拉取。
  - **微信支付 v3 拓展 (P2)**：新增 `src/pay/v3/`（`config`, `signer`, `order`, `notify`），实现 v3 HTTP `Authorization: WECHATPAY2-SHA256-RSA2048` 签名头部、小程序/JSAPI 拉起支付 RSA 签名算法及基于 `std.crypto.aead.aes_gcm.Aes256Gcm` 的零 C 依赖通知回调密文解密。
  - **Web 框架中间件适配 (P2)**：新增 `src/middleware/`（`wechat_handler`），专为 `zfinal` / `zigmodu` 等 Web 框架提供服务端 URL 签名校验 `verifyServerSignature` 与 AES 消息解密 `handleServerMessage`。
  - **小程序能力扩充**：新增 `src/miniprogram/message/`（`subscribeMessage.send` 订阅消息）与 `src/miniprogram/security/`（`msgSecCheck` 文本内容安全审核）。
  - **企业微信 Server 校验**：新增 `src/work/server/`（`WorkServer`），支持企业微信回调消息签名 `msg_signature` 校验与 `ReceiveID` (CorpID) 解密验证。
  - **开发者 API 指南**：创建 `doc/api_guide.md`，提供完整接口使用、方法速查及内存管理的最佳实践手册。
  - **编译期模板生成器 (`comptime`)**：新增 `src/util/template.zig`（`buildTemplateData`），利用 Zig `comptime` 类型反射，零堆开销将任意平铺 Zig 结构体转换为符合微信规范的 `{"field": {"value": "..."}}` 模板 JSON。
  - **CLI 开发者诊断工具箱**：升级 `src/main.zig`，适配 Zig 0.17 的 `std.process.Init` 规范，提供 `version`、`verify-sig`（签名快速验证）及 `template-demo`（模版生成调试）。
  - **工程化与合规增强（v0.2.0）**：
    - 版本对齐 `v0.2.0`（`build.zig.zon` / CHANGELOG / git tag 三者一致）；httpz 依赖升级为 `chy3xyz/zhttp` v0.6.0（URL + hash 引入），删除 `vendor/httpz/`。
    - `NOTICE.md`（项目根）：记录 httpz 上游来源（`chy3xyz/zhttp`，原 `allain/httpz.zig`）与"上游未提供 LICENSE"的许可证状态；本项目对其零本地补丁。
    - `util/http` 新增 `deinitDefaultClient()`：线程局部默认客户端的显式释放路径（首次调用传入的 allocator 决定该线程实例，文档已注明）。
    - `build.zig` 支持 `OPENSSL_DIR` 环境变量（优先于 Homebrew 路径探测），CI 与跨平台构建可注入；`zig build fmt` 提供格式化检查；示例改为安装产物（`zig build` 一并编译）。
    - CI 三平台（ubuntu / macos / windows-msys2-gnu），含缓存、`fmt` 检查、示例编译；新增 `.gitattributes` 强制 LF。
    - 全库源码补 Apache-2.0 SPDX 头；`zig fmt` 全库格式化；空断言"模块导出"测试全部改为 `@hasDecl`/`@hasField` 真实断言。

---

## 给 Agent 的注意事项

- **代码已存在**，开始任何编码前先 `ls src/` 与 `cat src/root.zig` 确认当前实现状态。
- **不要修改 `_ref/wechat/`**。它是只读参考；如有勘误，请记录到本 `AGENTS.md` 的"移植备注"小节。
- **不要触碰 `.codegraph/`**。这是分析缓存，不是源码；提交前不要 `git add` 它。
- **使用中文撰写注释与文档**，与上游参考保持一致；标识符（变量名、类型名）按 Zig 惯例用英文。
- **新加模块时**同步更新本文件中的"目录与模块划分"表与"移植对照"表。
- **新增测试时**在 `src/test_runner.zig` 中加一行 `@import`（即便内容只是占位），否则 `zig build test` 不会发现它。
- **`build.zig.zon` 的 fingerprint 字段**：写一个占位 hex（如 `0xd658b8e96476550b`）即可；若该值不被 Zig 接受，运行 `zig build` 会提示正确的值。
- **避免 Zig 0.17-dev 已被移除的 API**：`std.Thread.Mutex`/`Condition`（用 `std.Io.Mutex`/`Io.Condition`）、`std.time.timestamp()`（用 `std.Io.Clock.now`）、`std.fmt.AllocPrintError`（用 `Allocator.Error`）、`std.ArrayListUnmanaged = .{}`（用 `.empty`）。
- **修改完任何模块后**，必须 `zig build test` 确认 1087/1087 测试仍全部通过；任何内存泄漏会让测试失败。
- **避免 Zig 0.17-dev 已被移除的 API**：`std.fs.cwd()`（改用 `std.Io.Dir.cwd()`）、`std.Thread.Mutex`/`Condition`（用 `std.Io.Mutex`/`Io.Condition`）、`std.time.timestamp()`（用 `std.Io.Clock.now`）、`std.fmt.AllocPrintError`（用 `Allocator.Error`）、`std.ArrayListUnmanaged = .{}`（用 `.empty`）。
