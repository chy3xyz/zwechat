# zwechat

> Zig 语言重写/移植 [`silenceper/wechat`](https://github.com/silenceper/wechat) v2 这套 Go 微信开放接口 SDK，提供微信公众号、小程序、小游戏、微信支付 v2/v3、开放平台、企业微信、智能对话等能力的 Zig 原生实现。

**当前版本：v0.4.5**

| | |
|---|---|
| **Zig 版本** | ≥ `0.17.0-dev` |
| **外部依赖** | 默认**零依赖**：无 Zig 包依赖、无 C 依赖（不链 OpenSSL / libc、构建期不联网取依赖） |
| **测试覆盖** | 1004 个内联测试，**0 内存泄漏** |
| **基准性能** | SHA1 签名 ~274ns/op, AES 解密 ~107ns/op, XML 解析 ~148ns/op |
| **命令行工具** | `zig build run` (CLI 开发者诊断工具) |
| **基准测试** | `zig build bench` (基准性能评估) |
| **许可证** | Apache-2.0（与上游一致） |

---

## 🌟 核心亮点

- ✅ **零 GC & 显式内存管理**：所有 API 均显式传入 `std.mem.Allocator`，由调用方精准掌控内存释放与生命周期。
- ✅ **智能 Token 自动重试与强刷**：内置 `isTokenInvalidErrCode`，在遇到 `40001`/`40014` 等 Token 失效时自动清除缓存并强刷重试。
- ✅ **微信支付 v3 完整支持**：包含 HTTP `Authorization: WECHATPAY2-SHA256-RSA2048` 头签名、JSAPI/小程序调起签名及 **AEAD_AES_256_GCM** 零 C 依赖异步通知回调解密。
- ✅ **Web 框架通用中间件**：提供 `src/middleware/` 适配器，开箱即用无缝挂载至 `zfinal` / `zigmodu` / `zap` / `httpz` 等 Zig Web 框架。
- ✅ **编译期模板消息生成器 (`comptime`)**：基于 `comptime` 反射，零堆分配开销将任意平铺 Zig 结构体转换为符合微信规范的 `{"field":{"value":"..."}}` 模板 JSON。
- ✅ **开发者 CLI 诊断工具**：内置 CLI 命令，支持终端签名快速验证 `verify-sig` 与模板生成调试 `template-demo`。

---

## 📦 业务域覆盖

| 业务域 | 子模块数 | 状态 | 关键能力与新增特性 |
|---|---|---|---|
| `cache` | 4 | ✅ | `Cache` vtable 接口 + `Memory` / `Redis` / `Memcache` 后端（线程安全 + TTL）|
| `credential` | 5 | ✅ | `DefaultAccessToken` / `DefaultJsTicket` / `WorkAccessToken` / `WorkJsTicket` + **`forceRefresh` 强刷** |
| `util` | 14 | ✅ | HTTP 连接池复用 / AES-CBC+ECB+GCM / SHA1 签名 / **`template` 编译期生成器** / RSA-SHA256 / PKCS#12 / XML |
| `officialaccount` | 15 | ✅ | menu / oauth / basic / **server (Webhook 消息解密/路由)** / message / material / js / user / datacube / broadcast / device / customerservice / ocr / draft / freepublish |
| `pay` | 8 | ✅ | v2 (order/refund/notify/transfer/redpacket) + **v3 (signer/order/AEAD-AES-256-GCM notify 解密)** |
| `miniprogram` | 5 | ✅ | auth (jscode2session/getPhoneNumber) + qrcode + urlscheme + **message (订阅消息) + security (内容安全审核)** |
| `openplatform` | 6 | ✅ | account / miniprogram / officialaccount |
| `work` | 13 | ✅ | oauth / jsapi / message / robot / **server (ReceiveID/CorpID 校验加解密)** + **`newDefaultWork` 工厂** |
| `middleware` | 2 | ✅ | **通用 Web 框架中间件** (`verifyServerSignature` / `handleServerMessage`) |
| `aispeech` | 1 | ✅ | 智能对话接口骨架 |

---

## 🛠 构建与常用命令

```bash
# 1. 跑全部 1004 个单元测试（自动检测内存泄漏）
zig build test

# 2. 跑性能基准测试 (Benchmark)
zig build bench

# 3. 运行 CLI 开发者诊断工具
zig build run

# 4. 运行业务场景示例 (Examples)
zig build run-oa-server   # 运行公众号 Webhook 验签解密示例
zig build run-pay-order   # 运行微信支付下单与 JSAPI 调起示例
zig build run-work-robot  # 运行企业微信机器人与 JSAPI 示例

# 5. 需要微信支付 v2 mTLS 时（默认关闭）
zig build -Dmtls=true
```

> **依赖要求**：默认构建**零依赖**——不需要 `libssl-dev` / `openssl@3`（也不缺 C 头文件），不从 GitHub 取任何 Zig 包。
> 只有当你要走微信支付 **v2** 的客户端证书路径（`pay.Config.root_ca` 非空 → `postXMLWithTLS`）时才需要 `-Dmtls=true`，
> 且**运行时有 `libssl` / `libcrypto` 动态库**即可（构建期不需要头文件）。未开启时调用 `postXMLWithTLS` 会返回 `error.MtlsNotEnabled`。
> 微信支付 v3（含退款 / 商家转账）不需要客户端证书，无需该开关。

---

## 💡 快速上手代码示例

### 1. 微信公众号与签名校验/消息解密

```zig
const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. 验证微信推送签名
    const is_valid = zwechat.middleware.verifyServerSignature(allocator, "my_token", .{
        .signature = "b93fa1867a61b34643b3dab017c363a10cddeec2",
        .timestamp = "1721641869",
        .nonce = "239847192",
    });
    std.debug.print("签名有效: {}\n", .{is_valid});

    // 2. 解密加密接收的消息
    var msg = try zwechat.middleware.handleServerMessage(
        allocator,
        "0123456789abcdef0123456789abcdef", // EncodingAESKey
        encrypted_xml_string,
    );
    defer msg.deinit(allocator);

    std.debug.print("收到明文 XML 消息: {s}\n", .{msg.raw_xml});
}
```

### 2. 微信支付 v3 Authorization 签名 Header 与回调解密

```zig
const zwechat = @import("zwechat");

pub fn payV3Demo(allocator: std.mem.Allocator) !void {
    const v3_cfg = zwechat.pay.v3.Config{
        .app_id = "wx1234567890abcdef",
        .mch_id = "1900000109",
        .serial_no = "1DDE557876238...",
        .private_key_pem = "-----BEGIN PRIVATE KEY-----\n...",
    };

    // 生成 v3 HTTP 请求头签名
    var auth = try zwechat.pay.v3.signer.buildAuthorizationHeader(
        allocator,
        v3_cfg,
        "POST",
        "/v3/pay/transactions/jsapi",
        "{\"amount\":{\"total\":100}}",
    );
    defer auth.deinit(allocator);

    // 格式化后的 Header:
    // Authorization: auth.authorization

    // 解密 v3 异步通知 (AES-256-GCM 纯 Zig 原生解密)
    const plain_json = try zwechat.pay.v3.decryptNotifyResource(
        allocator,
        "12345678901234567890123456789012", // APIv3 密钥
        resource_b64_ciphertext,
        "transaction",
        "123456789012", // Nonce
    );
    defer allocator.free(plain_json);
}
```

### 3. 编译期模板消息 JSON 转换 (`comptime`)

```zig
const zwechat = @import("zwechat");

pub fn sendNotice(allocator: std.mem.Allocator) !void {
    // 平铺 Zig 结构体
    const notice = .{
        .first = "订单支付成功",
        .trade_no = "202607221938001",
        .remark = "感谢您的支持",
    };

    // 编译期自动转换为微信要求的 {"key": {"value": "..."}} JSON
    const json_str = try zwechat.util.template.buildTemplateData(allocator, notice);
    defer allocator.free(json_str);

    // json_str => '{"first":{"value":"订单支付成功"},"trade_no":{"value":"202607221938001"},"remark":{"value":"感谢您的支持"}}'
}
```

---

## 📁 项目结构

```
src/
├── root.zig                  # 顶层 barrel re-export
├── wechat.zig                # 顶层 Wechat struct 容器
├── main.zig                  # 开发者 CLI 诊断工具箱
├── test_runner.zig           # 编译门（强制 @import 每个模块）
├── middleware/               # 通用 Web 框架中间件适配器 (zfinal/zigmodu)
│
├── cache/                    # 缓存抽象 (Memory / Redis / Memcache)
├── credential/               # AccessToken & JsTicket (带强刷与双检)
├── util/                     # 加解密与基础工具集
│   ├── http.zig              # HttpClient + MockTransport + Keep-Alive 连接池
│   ├── template.zig          # comptime 编译期模板 JSON 生成器
│   ├── crypto.zig            # AES-CBC/ECB/PKCS7/MD5/HMAC
│   ├── rsa.zig               # RSA-SHA256 PKCS#1 v1.5 + PKCS#12
│   ├── xml.zig               # 微信消息 XML codec
│
├── officialaccount/          # 公众号 (15 个子模块)
├── pay/                      # 微信支付 (v2 + v3 完整子模块)
├── miniprogram/              # 小程序 (auth/qrcode/urlscheme/message/security)
├── work/                     # 企业微信 (oauth/jsapi/robot/server 检验)
├── openplatform/             # 开放平台
├── minigame/                 # 小游戏
└── aispeech/                 # 智能对话
```

---

## 📖 开发者文档索引

- [API 使用指南与速查手册 (`doc/api_guide.md`)](doc/api_guide.md)
- [AI Agent 架构与规范指南 (`AGENTS.md`)](AGENTS.md)
- [上游 Go 接口参考 Markdown](https://github.com/silenceper/wechat/tree/master/doc/api)（本地 `_ref/wechat/doc/api/` 为开发期对照，不入库）

---

## 📄 许可证

本项目基于 [Apache License 2.0](LICENSE) 许可证开源，与上游 `silenceper/wechat` 保持一致。