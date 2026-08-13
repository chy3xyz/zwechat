# Changelog

All notable changes to `zwechat` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.2] — 2026-08-13

### Fixed

- **inline for 遍历 tuple 字面量编译失败（根因修复）**：`material.writeArticleJson`、`menu.writeJsonMatchRule`、`work.message` 公共字段、`operation` JS 错误序列化等 5 处 `inline for` 遍历匿名 struct tuple（字符串字面量长度不同导致元素类型不一致），在部分 Zig 版本下编译失败；统一改为显式 struct 数组 + 普通 `for`。

## [0.4.1] — 2026-08-13

### Fixed

- **material.addNews 编译失败**：`return dupe(...)` 的复合隐式类型转换（`Allocator.Error![]u8` → `anyerror![]const u8`，错误集扩大 + 负载 const 化）在部分 Zig 版本下编译失败，级联拖垮整个 `officialaccount` 模块；改为 `try` 解包后返回，并将 `ArticleListContent.news_item` / `ArticleList.item` 改为 const 切片。

## [0.4.0] — 2026-08-13

### Added

- **miniprogram 补齐 17 个子模块**（共 24 个，与 Go 参考实现 1:1 对齐）：`shortlink`、`encryptor`、`werun`、`urllink`、`riskcontrol`、`redpacketcover`、`privacy`、`content`、`business`、`order`（发货）、`ocr`、`subscribe`、`analysis`、`operation`、`tcb`（云开发）、`express`（物流）、`minidrama`（微短剧，含分片上传）、`virtualpayment`（虚拟支付，含 HMAC-SHA256 支付/用户态签名）。
- **顶层容器懒加载工厂**：`OfficialAccount` 新增 15 个 `getXxx`、`Work` 新增 13 个 `getXxx`、`MiniProgram` 新增 18 个 `getXxx`。
- **导出补齐**：`officialaccount` 补齐 10 个子模块导出、`work` 补齐 4 个、`pay` 补齐参数/返回类型、`miniprogram` 补齐 Context 与 auth 返回类型。
- **`util_http.MultipartField.data`**：支持内存字节直接上传（微短剧分片）。
- **`util_crypto.DecryptedMessage`**：`aesDecryptMsg` 返回命名类型。

### Fixed

- **test_runner 遗漏注册**：补齐 `mp_message/mp_security/pay_transfer/pay_redpacket/pay_v3/work_server/work_smartbot` 等显式注册，暴露并修复 `work/server` 长期隐藏的编译错误（`crypto.DecryptedMessage` 不存在、对非 optional 字段误用 `orelse`）。

## [0.3.0] — 2026-08-13

### Changed

- **httpz 升级 v0.6.1（git 依赖）**：`build.zig.zon` 改为 `git+https://github.com/chy3xyz/zhttp?ref=v0.6.1#60a0212...` 形式；v0.6.1 为内部修复（Headers 保留头 / Request percent-encoding 安全 / chunk 边界），无破坏性 API 变化，`build.zig` / `util/http.zig` 无需改动。
- **JSON 返回 API 改为所有权转移**：约 30 处 JSON 接口返回类型由 `T` 改为 `std.json.Parsed(T)`（调用方读取 `.value.*` 并负责 `deinit`），消除字段借用响应 body 的 use-after-free。涉及 `officialaccount` / `miniprogram` / `work` 三大域。

### Fixed

- **支付模块返回值 UAF**：`pay/refund` / `pay/transfer` / `pay/redpacket` / `pay/order` 的 XML 响应 body 原先被 `defer free` 而返回字段指向它，改为 body 所有权随返回值转移并新增 `deinit()`；新增 4 个离线回归测试。
- **XML 解析 UAF**：`officialaccount/server` 与 `work/smartbot` 的 `parseEncryptedMessage` 中 `doc` 改为基于持久副本 `raw_xml_dup` 解析，避免指向被释放的 `decoded.raw_xml_msg`。
- **`util/error` UAF**：`CommonError.errmsg` 改为深拷贝拥有并新增 `deinit()`；`decodeWithError` 改为返回 `Parsed(T)`；`decodeWithCommonError` 调用方补 `deinit`。

## [0.2.0] — 2026-08-10

### Added

- **work/smartbot（企业微信智能机器人）**：新增 `src/work/smartbot/` 回调模块，支持 WeCom 智能机器人消息签名校验与回调处理。
- **work/message Markdown 消息**：新增 `SendMarkdownRequest` + `Message.sendMarkdown`（`msg_type='markdown'`，内部复用 `send()` 管线）。
- **officialaccount 模块导出补齐**：menu / oauth / server / js / message 子模块对外导出（`officialaccount/mod.zig`）。

### Changed

- **httpz 升级 v0.6.0（git URL 方式）**：依赖从 `vendor/httpz`（v0.2.0 + 本地补丁）改为 `build.zig.zon` 声明 URL + hash，经 `zig fetch` 从 `https://github.com/chy3xyz/zhttp` 拉取 v0.6.0；删除 `vendor/httpz/` 目录。上游 v0.6.0 官方内置 mTLS 客户端证书（`tls.config.Client.auth` / `cert`，提交 `0431984`）与 `-Dopenssl-include` 参数化（提交 `46dad65`），本地补丁全部作废。`build.zig` 适配：模块名 `httpz` → `zhttp`、`-Dh3=false`、探测 OpenSSL include 路径透传（`@\"openssl-include\"`）；`util/http` 适配 `Client.init` 返回 `error{OutOfMemory}!Client`（加 `try`）。合规说明迁移至项目根 `NOTICE.md`。
- **vendor/httpz 构建跨平台化**：Linux 改用系统 OpenSSL headers（`/usr/include/{arch}-linux-gnu`），并支持 `XCOMPILE_ROOT` 交叉编译注入。
- 测试总数提升至 **316**（合并远端提交新增 10 个测试），仍保持 0 内存泄漏。

### Fixed

- **officialaccount/message**：`miniprogrampage` 加入 `ReplyMsgType`；模板消息 JSON 转义修复；media 回复 XML 嵌套结构修正。
- **officialaccount/server**：允许 `const XmlDoc` 经 `@constCast` 调用 `deinit`；oauth JSON 解析结果保持存活，避免悬垂。
- **工程化与合规修复（最佳实践升级）**：
  - 版本对齐：`build.zig.zon` / CHANGELOG 同步至 `v0.1.0`，与 git tag 一致。
  - `build.zig.zon` 的 `.paths` 精确打包 `vendor` / `doc` / `docs`，修复 `zig build publish` 发布包缺失 path 依赖的问题。
  - `vendor/httpz` 新增 `NOTICE.md` 记录上游来源与许可证状态（上游 `allain/httpz.zig` 未提供 LICENSE 文件）。
  - `util/http` 新增 `deinitDefaultClient()`，为线程局部默认客户端提供显式释放路径。
  - `build.zig` 支持 `OPENSSL_DIR` 环境变量，OpenSSL 探测不再仅依赖 macOS Homebrew 硬编码路径。
  - CI 增强：新增 `zig build fmt` 门禁、示例安装编译、Zig 缓存、Windows（msys2 + OpenSSL）job；修复 dev 版本过期导致的 Setup Zig 失败（`dev.1422` → `dev.1567`）。
  - 源码新增 Apache-2.0 SPDX 头；`zig fmt` 全库格式化。

## [0.1.0] — 2026-07-22

### Added

- **Wave 19 — 微信支付 mTLS 支持**：
  - 引入 `vendor/httpz`（httpz.zig v0.2.0）并本地打补丁，为 OpenSSL 后端增加客户端证书加载能力。
  - 实现 `src/util/http.zig` 的 `postXMLWithTLS`：读取商户 P12 → `util.rsa.parseP12` 解析 PEM → 通过 httpz 完成 TLS 双向认证 POST。
  - `pay/refund`、`pay/transfer`、`pay/redpacket` 在 `pay.Config.root_ca` 非空时自动调用 `postXMLWithTLS`；空时退回到普通 HTTPS，便于无证书环境测试。
  - 新增 2 个内联测试（缺少 P12 文件返回 `FileNotFound`、非法 P12 返回 `InvalidP12File`）。
  - 测试总数从 **296** 提升至 **297**，仍保持 0 内存泄漏。

- **Wave 18 — RSA 后端优化 + Pay V2 补齐 + 小程序二维码/URL Scheme + 开放平台 component_token**：
  - RSA 后端切换到更快的 big-int 实现。
  - 微信支付 order 增加 query/close/bridgeAppConfig/prePayID；refund/transfer/redpacket 接口完善。
  - 小程序新增 `qrcode` / `urlscheme` 子模块。
  - 开放平台 account 支持 component_access_token 缓存与 bind/unbind。

- **Wave 17 — Memcache 缓存后端**：
  - 新增 `src/cache/memcache.zig`：最小 Memcache 文本协议客户端，实现 `Cache` vtable 的 `get` / `set` / `isExist` / `delete` / `deinit`。
  - 支持外部传入 `std.Io` 句柄；未提供时自行创建 `std.Io.Threaded`。
  - 新增 3 个内联测试（set/get/exists/delete 往返、不存在的 key 返回 null、公共 API 导出），使用本进程 mock Memcache 服务器，无外部依赖。
  - 测试总数从 278 提升至 **281**，仍保持 0 内存泄漏。

- **Wave 16 — Redis 缓存后端**：
  - 新增 `src/cache/redis.zig`：最小 RESP Redis 客户端，实现 `Cache` vtable 的 `get` / `set` / `isExist` / `delete` / `deinit`。
  - 支持外部传入 `std.Io` 句柄；未提供时自行创建 `std.Io.Threaded`。
  - 支持 `AUTH` / `SELECT`（可选密码与非 0 数据库）。
  - 新增 3 个内联测试（set/get/exists/delete 往返、不存在的 key 返回 null、公共 API 导出），使用本进程 mock Redis 服务器，无外部依赖。
  - 测试总数从 275 提升至 **278**，仍保持 0 内存泄漏。

- **Wave 15 — ASN.1 解析器提取 + PKCS#12 解析**：
  - 新增 `src/util/asn1.zig`：最小 DER 解析器，支持 SEQUENCE / INTEGER / OCTET STRING / BIT STRING / OID / NULL，供 RSA PEM 与 PKCS#12 复用。
  - 新增 `src/util/pkcs12.zig`：纯 Zig 实现 PKCS#12 解析，支持 PBES2 + PBKDF2-HMAC-SHA256 + AES-256-CBC，可从 `.p12` 导出 `-----BEGIN CERTIFICATE-----` 与 `-----BEGIN PRIVATE KEY-----` PEM。
  - `util/rsa.parseP12` 与 `p12Available()` 接入 `pkcs12.parse`，不再返回 `P12NotImplemented`。
  - 新增 3 个 PKCS#12 内联测试（成功解析、错误密码返回 `BadPassword`、空密码返回 `BadPassword`）。
  - 测试总数从 260 提升至 **275**，仍保持 0 内存泄漏。

### Changed

- `src/util/rsa_impl.zig` 重构为使用共享 `src/util/asn1.zig` 解析器，减少重复代码。

### Planned

- **`work.jsapi.getConfig` corp / agent 完整 wire**：`WorkJsTicket` 已就绪，待 `Context.js_ticket_handle` 完成 plug-and-play。
- **跨平台 OpenSSL 路径**：当前 `vendor/httpz/build.zig` 硬编码 `/opt/homebrew/opt/openssl@3/include`，后续需要为 Linux / Windows 提供条件 include/lib 路径。

---

## [0.0.1] — 2026-06-15

首版落地。10 个业务域完整覆盖，260 个内联测试通过，0 内存泄漏。

### Added

#### 基础设施

- `build.zig` / `build.zig.zon`：原生 Zig 0.17 构建脚本；`addModule("zwechat", ...)` 暴露给下游包。
- `LICENSE`：Apache-2.0（与上游 `silenceper/wechat` 一致）。
- `src/root.zig`：顶层 barrel re-export。
- `src/main.zig`：CLI 入口（`zig build run` 打印版本 + 模块列表）。
- `src/test_runner.zig`：测试编译门，强制 `@import` 所有子模块以确保 `zig build test` 发现 inline test。
- `src/integration_test.zig`：端到端集成测试（含 MockTransport + 完整 XML 往返）。
- `AGENTS.md` / `README.md` / `CONTRIBUTING.md` / `CHANGELOG.md`。
- `.gitignore`：排除 `.zig-cache` / `zig-out` / `*.o` / `.codegraph` / 编辑器配置。
- 首版 git commit：`c16d836`。

#### `cache` 模块

- `Cache` vtable 接口（`get` / `set` / `isExist` / `delete` / `deinit`）。
- `Memory.create` / `Memory.deinit` / `Memory.asCache`：线程安全 + TTL + lazy delete + 双检锁。
- 5 个内联测试（基本 set/get round-trip、TTL 过期、并发安全）。

#### `credential` 模块

- `AccessTokenHandle` / `JsTicketHandle` vtable 抽象接口。
- `DefaultAccessToken`（官方账号 URL：`api.weixin.qq.com/cgi-bin/token`）。
- `DefaultJsTicket`（官方账号 URL：`api.weixin.qq.com/cgi-bin/ticket/getticket`）。
- **`WorkAccessToken`**（企业微信 URL：`qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=...&corpsecret=...`）。
- **`WorkJsTicket`**（企业微信 corp + agent 两种 ticket 类型，支持 `setDefaultTicketType` 切换）。
- `CredentialError`（`ApiError` / `HttpError` / `DecodeError` / `ConfigMissing`）。
- 20+ 个内联测试（含 stub fetcher 注入、JSON 响应解析、错误响应处理）。

#### `util` 模块

- **`util/rsa_impl.zig`：纯 Zig RSA-SHA256 PKCS#1 v1.5 签名/验签**：
  - 最小 ASN.1 DER 解析器（SEQUENCE / INTEGER / BIT STRING / OID）。
  - PEM 解析：支持 PKCS#1 `RSA PRIVATE KEY`、X.509 `PUBLIC KEY`（SubjectPublicKeyInfo）。
  - `rsaSign` / `rsaVerify` 已接入；附 OpenSSL 生成的 1024-bit 测试向量。
  - 基于 `std.math.big.int.Managed` + 二进制模幂（功能正确，后续可替换更快后端）。
- **`util/http.HttpClient`**：基于 `std.http.Client` 与 `std.Io.Threaded.global_single_threaded`；支持 GET / POST / POST JSON / POST XML / multipart；提供 `getDefaultClient` 全局单例。
- **`util/http.Transport` 注入点**：vtable 风格的 transport 函数指针 + ctx，可被 `MockTransport` 替换，便于离线单元测试。
- **`util/http.MockTransport`**：内置 (uri → response) 映射 + 调用历史。`addRoute` 注册、`MockTransport.dispatch` 作为 transport 函数指针。
- **`util/crypto`**：
  - AES-256-CBC（含 `aesEncryptMsg` / `aesDecryptMsg`，对齐微信 XML 消息加密协议：随机 16B + length(4B) + msg + appID + PKCS7 pad）。
  - AES-256-ECB（用于退款通知解密）。
  - PKCS7 padding / unpadding。
  - MD5 / HMAC-SHA256（`calculateSign` 返回大写 hex）。
- **`util/signature.SHA1 sort-and-sign`**：微信 JS-SDK 与公众号消息签名。
- **`util/xml.XmlDoc`**：扁平 key→value 映射；`parse` / `serialize` / `get` / `count` / `deinit`。
- **`util/rsa`**：
  - RSA 接口（`rsaSign` / `rsaVerify`）保留签名，当前返回 `RsaNotImplemented`，注释指引 vendor ASN.1 / 改用 Ed25519。
  - **Ed25519 native**（`ed25519Sign` / `ed25519Verify` / `ed25519GenerateKeyPair`）：使用 `std.crypto.sign.Ed25519`，已可用。
  - **PKCS#12 stub**（`parseP12`）：返回 `P12NotImplemented`；提供 `p12Available()`。
  - **RFC 8032 §7.1 Test 1 真实测试向量**通过。
- `util/param.orderParam`（按 key 字典序拼接 + 追加 biz_key）。
- `util/time.getCurrTS`（基于 `std.Io.Clock.now(.real, .Options.debug_io).toSeconds()`，规避 Zig 0.17 中被移除的 `std.time.timestamp()`）。
- `util/error.WechatError` + `CommonError` + `decodeWithCommonError`。
- `util/util`（`SliceChunk` / `randomStr`）。

#### `officialaccount` 模块（1 顶层 + 14 子模块）

- **menu**：11 种按钮构造器（click / view / scancode_push / scancode_waitmsg / pic_sysphoto / pic_photo_or_album / pic_weixin / location_select / media_id / view_limited / miniprogram）+ 6 个 CRUD 接口 + 自研 JSON 序列化器。
- **oauth**：网页授权（`getRedirectURL` / `getUserAccessToken` / `refreshAccessToken` / `checkAccessToken` / `getUserInfo`）。
- **basic**：IP 列表 + 清理接口配额。
- **js**：JS-SDK 配置计算（含 corp / agent ticket 注入）。
- **server**：SHA1 验签 + AES-CBC 解密 + **MessageHandler 路由**（端到端 `serve()` 入口）。
- **message**：MsgType / EventType 枚举 + MixMessage 通用结构 + TemplateMessage / CustomerTextMessage 发送。
- **material**：永久素材 CRUD（add / delete / getMaterialCount / batchGet）。
- **user**：用户信息查询 + OpenID 列表 + 备注更新。
- **datacube**：用户增减 / 累计 / 文章 / 接口统计。
- **broadcast**：按标签群发（text / news）。
- **device**：transMsg + createQRCode。
- **customerservice**：客服账号 add / list。
- **ocr**：身份证 / 银行卡 / 行驶证 / 驾驶证 OCR。
- **draft**：草稿箱 add / delete / list。
- **freepublish**：发布 / 撤回 / 列表。

#### `pay` 模块（1 顶层 + 5 子模块）

- **pay.zig 顶层**：聚合 Order / Refund / Notify / Transfer / Redpacket。
- **order**：V2 统一下单（XML 请求 + MD5 签名）+ JS-SDK 拉起支付 `BridgeConfig`。
- **refund**：退款（XML 请求 + MD5 签名；TLS 双向认证为占位）。
- **notify**：支付成功通知验签 + 退款通知 AES-ECB 解密。
- **transfer**：企业付款到零钱（XML 请求 + MD5 签名）。
- **redpacket**：现金红包（XML 请求 + MD5 签名）。
- **`verifyPaidNotify` 真实测试向量**：RFC 风格 nonce + 微信文档示例参数。

#### `miniprogram` 模块（1 顶层 + 3 子模块）

- 顶层 `MiniProgram.init` + `getContext` + `getAuth`（懒加载）。
- **auth**：`jscode2session` / `getPhoneNumber` / `checkEncryptedData` / `checkSession`。

#### `openplatform` 模块（1 顶层 + 4 子模块）

- 顶层 `OpenPlatform`（含 createOpenAccount / getOpenAccount 子模块骨架）。
- `account` / `miniprogram` / `officialaccount` 子模块。

#### `work` 模块（1 顶层 + 12 子模块）

- **顶层 `Work`**：支持 `init` / `newWork` / **`newDefaultWork` 工厂方法**（一行代码自动构造 `WorkAccessToken` + 懒加载 `WorkJsTicket`）/ `setDefaultTicketType` / `setJsTicketHandle`。
- **oauth**：按 OAuth code 拿 userid / 用户信息。
- **jsapi**：jsapi_ticket 获取。
- **message**：发送应用消息（text / image）。
- **material**：永久素材上传 + 媒体列表。
- **msgaudit**：会话内容存档。
- **checkin**：打卡数据 + 选项。
- **kf**：客服账号 + 消息发送。
- **externalcontact**：外部联系人管理。
- **invoice**：电子发票。
- **addresslist**：通讯录（user / department）。
- **appchat**：应用群。
- **robot**：群机器人 webhook 推送（无需 access_token）。

#### `minigame` 模块

- config + context + 顶层 `MiniGame.init`。

#### `aispeech` 模块

- 骨架（Go 参考本身为空）。

### Changed

N/A（首版）。

### Deprecated

N/A。

### Removed

N/A。

### Fixed

N/A。

### Security

- 所有 access_token / jsapi_ticket 通过 cache 抽象层访问，不暴露明文 secret 到日志。
- 错误处理采用窄错误集，避免泄漏 `anyerror`。
- errdefer 链覆盖所有 `try X.init()` 路径，杜绝 init 失败的中间态泄漏。

---

## 版本说明

- **0.x**：初始开发版本，API 可能不兼容。
- **1.0**：计划完成 RSA / PKCS#12 完整实现、work.jsapi 完整 wire 后发布。

[Unreleased]: https://github.com/chy3xyz/zwechat/compare/v0.4.2...HEAD
[0.4.2]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.2
[0.4.1]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.1
[0.4.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.0
[0.3.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.3.0
[0.2.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.2.0
[0.1.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.1.0
[0.0.1]: https://github.com/chy3xyz/zwechat/releases/tag/v0.0.1