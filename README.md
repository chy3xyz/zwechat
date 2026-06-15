# zwechat

> Zig 重写 [`silenceper/wechat`](https://github.com/silenceper/wechat) v2 这套 Go 微信开放接口 SDK，提供微信公众号、小程序、小游戏、微信支付、开放平台、企业微信、智能对话等能力的 Zig 实现。

**当前版本：v0.0.1（首版完整落地）**

| | |
|---|---|
| Zig 版本 | ≥ 0.17.0 |
| 测试覆盖 | 260 个内联测试，0 内存泄漏 |
| 代码规模 | 79 个 Zig 文件，~12.3k 行 |
| 许可证 | Apache-2.0（与上游一致） |
| Git 仓库 | `c16d836`（首版 commit） |

---

## 项目目标

`zwechat` 是 Go 微信生态 SDK 在 Zig 语言上的完整重写：

- ✅ **静态分发 + 显式内存**：所有公共 API 显式传递 `std.mem.Allocator`，无 GC，无运行时反射。
- ✅ **vtable 接口**：用 Zig 函数指针模拟 Go `interface`，抽象 `Cache`、`AccessTokenHandle`、`JsTicketHandle` 等。
- ✅ **零三方依赖**：除 Zig 标准库外不引入任何外部包；TLS / PKCS#12 / RSA 是仅有的未实现项（需要 vendor ASN.1）。
- ✅ **测试可离线**：所有 HTTP 调用可通过 `MockTransport` 注入，无需真实微信服务器即可跑 CI。
- ✅ **中文注释**：所有 `///` / `//!` 文档注释与上游 Go 注释一致，使用中文。

---

## 业务域覆盖

| 业务域 | 子模块数 | 状态 | 关键能力 |
|---|---|---|---|
| `cache` | 2 | ✅ | `Cache` vtable 接口 + 内存实现（线程安全 + TTL + lazy delete）|
| `credential` | 5 | ✅ | `DefaultAccessToken` / `DefaultJsTicket` / **`WorkAccessToken`** / **`WorkJsTicket`**（corp + agent）|
| `util` | 10 | ✅ | HTTP 客户端 / AES-CBC+ECB+PKCS7 / MD5 / HMAC-SHA256 / SHA1 / XML codec / 错误集 / 时间 / 参数 / **Ed25519 native** / RSA stub |
| `officialaccount` | 15 | ✅ | menu / oauth / basic / **server（MessageHandler 路由）** / message / material / js / user / datacube / broadcast / device / customerservice / ocr / draft / freepublish |
| `pay` | 6 | ✅ | order（统一下单 + JS 拉起） / refund（退款 + AES-ECB） / notify（**真实测试向量验签**） / transfer / redpacket |
| `miniprogram` | 4 | ✅ | auth（jscode2session / getPhoneNumber / checkSession）|
| `openplatform` | 6 | ✅ | account / miniprogram / officialaccount |
| `work` | 13 | ✅ | oauth / jsapi / message / material / msgaudit / checkin / kf / externalcontact / invoice / addresslist / appchat / robot + **工厂方法 `newDefaultWork`** |
| `minigame` | 3 | ✅ | config + context + 顶层 |
| `aispeech` | 1 | ✅ | 骨架（Go 参考本身为空）|

---

## 快速开始

### 安装

需要 Zig ≥ 0.17.0：

```bash
# 克隆仓库
git clone https://github.com/your-org/zwechat.git
cd zwechat

# 验证环境
zig version  # 应 >= 0.17.0
```

### 构建与运行

```bash
# Debug 构建
zig build

# 优化构建（生产）
zig build -Doptimize=ReleaseFast

# 运行示例 CLI
zig build run
# 输出:
#   zwechat v0.0.1
#   cache          : cache.mod
#   credential     : credential.mod
#   util           : util.mod
#   officialaccount: officialaccount.mod

# 跑全部单元测试
zig build test
```

### 最小业务示例

```zig
const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. 构造全局 cache
    var mem = try zwechat.cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    // 2. 公众号配置
    const cfg = zwechat.officialaccount.Config{
        .app_id = "wx_your_app_id",
        .app_secret = "your_app_secret",
        .token = "your_token_for_signature_check",
        .encoding_aes_key = "your_aes_key_for_encrypted_mode",
        .cache = mem.asCache(),
    };

    // 3. 构造公众号实例
    const oa = zwechat.officialaccount.OfficialAccount.init(
        zwechat.officialaccount.Context{
            .config = cfg,
            .access_token_handle = zwechat.credential.DefaultAccessToken
                .init(cfg.app_id, cfg.app_secret, zwechat.credential.CacheKeyOfficialAccountPrefix, mem.asCache())
                .asHandle(),
        },
    );

    // 4. 透明获取 access_token
    const tok = try oa.getAccessToken(allocator);
    defer allocator.free(tok);
    std.debug.print("access_token = {s}\n", .{tok});

    // 5. 调用任意子模块（如菜单）
    const menu = zwechat.officialaccount.menu.Menu.init(oa.getContext(), allocator);
    _ = menu;
}
```

### 企业微信示例（开箱即用）

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

// 拉取 corp ticket
const ticket = try w.getJsTicket(allocator, try w.getAccessToken(allocator));
defer allocator.free(ticket);

// 切到 agent ticket
w.setDefaultTicketType(.agent_js);
```

---

## 单元测试

```bash
zig build test --summary all
```

```
Build Summary: 3/3 steps succeeded
test success
+- run test 260 pass (260 total)
   +- compile test Debug native
```

所有内联测试使用 `std.testing.allocator`，自动检测内存泄漏；运行结果应严格 **260/260 pass, 0 leak**。

---

## 模块结构

```
src/
├── root.zig                  # 顶层 barrel re-export
├── wechat.zig                # Wechat 容器 + 业务获取
├── main.zig                  # CLI 入口
├── test_runner.zig           # 测试编译门（强制 @import 所有模块）
├── integration_test.zig      # 端到端集成测试（含 MockTransport）
│
├── cache/                    # 缓存抽象 + 内存实现
├── credential/               # 凭据管理（access_token + js_ticket × 2 种）
├── util/                     # 通用工具（10 个文件）
│   ├── http.zig              # HTTP 客户端 + MockTransport + Transport 注入
│   ├── crypto.zig            # AES / MD5 / HMAC-SHA256
│   ├── signature.zig         # SHA1 sort-and-sign
│   ├── xml.zig               # 微信消息 XML codec
│   ├── rsa.zig               # RSA stub + Ed25519 native
│   ├── error.zig, time.zig, param.zig, util.zig
│
├── officialaccount/          # 公众号（1 顶层 + 14 子模块）
├── pay/                      # 微信支付（1 顶层 + 5 子模块）
├── miniprogram/              # 小程序（1 顶层 + 3 子模块）
├── openplatform/             # 开放平台（1 顶层 + 4 子模块）
├── work/                     # 企业微信（1 顶层 + 12 子模块）
├── minigame/                 # 小游戏
└── aispeech/                 # 智能对话骨架
```

每个子模块的 `.zig` 文件与上游 `_ref/wechat/` 一一对应，例如：
- `src/officialaccount/menu/mod.zig` ↔ `_ref/wechat/officialaccount/menu/menu.go`
- `src/pay/order/mod.zig` ↔ `_ref/wechat/pay/order/pay.go`

---

## 已知限制

1. **RSA 签名**：✅ 已在 `src/util/rsa_impl.zig` 实现纯 Zig 的 RSA-SHA256 PKCS#1 v1.5 签名/验签；支持 PKCS#1 `RSA PRIVATE KEY` 与 X.509 `PUBLIC KEY` PEM。使用 `std.math.big.int.Managed` + 二进制模幂，**功能正确但速度不及优化 big-int 库**（后续可替换为更快的实现）。
2. **PKCS#12 / TLS 双向认证**：`util/http.postXMLWithTLS` 与 `util/rsa.parseP12` 仍为占位。生产支付（`pay/refund` + `pay/transfer`）需要 vendor ASN.1 / PKCS#12 解析器。
3. **`WorkJsTicket` 已就绪但 work.JsAPI 子模块尚未完整 wire** —— `Work.newDefaultWork` 会懒加载 `WorkJsTicket`，但子模块的业务方法（如 `jsapi.getConfig`）仍需后续接续。

---

## 文档索引

| 文档 | 内容 |
|---|---|
| [`AGENTS.md`](AGENTS.md) | 给 AI Agent 的项目导引（架构 / 命名 / 移植备注）|
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 贡献者指南（开发流程 / 命名 / 测试 / 提交规范）|
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更日志 |
| [`docs/getting-started.md`](docs/getting-started.md) | 5 分钟入门教程 |
| [`docs/architecture.md`](docs/architecture.md) | 模块设计与架构模式（vtable / Allocator 传递 / MockTransport） |
| [`docs/migration-from-go.md`](docs/migration-from-go.md) | 从 `silenceper/wechat` Go SDK 迁移的对照表 |
| [`docs/api-reference.md`](docs/api-reference.md) | 公共 API 索引（cache / credential / util / 各业务模块）|
| [`_ref/wechat/doc/api/*.md`](_ref/wechat/doc/api/) | 上游 Go 接口清单（移植时优先对照） |

---

## 许可证

本项目使用 [Apache License 2.0](LICENSE)，与上游 [`silenceper/wechat`](https://github.com/silenceper/wechat) 保持一致。
上游版权声明见 [`_ref/wechat/LICENSE`](_ref/wechat/LICENSE)。

---

## 致谢

- 上游参考：[silenceper/wechat](https://github.com/silenceper/wechat) — Apache-2.0
- Zig 社区：[ziglang.org](https://ziglang.org)
- 本项目在 `zig 0.17.0-dev.813+2153f8143` 上构建通过