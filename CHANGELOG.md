# Changelog

All notable changes to `zwechat` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] — 2026-09-24

### Changed

- **移除第三方 Zig 依赖 `httpz`（zhttp）**：该依赖只为微信支付 **v2** 的 mTLS（客户端证书）服务，却把 OpenSSL + libc 链接到**所有**构建目标（lib / exe / test / bench / examples），使每个消费者都被迫背 C 依赖；现改为仓库内自建、按构建开关启用。
- **mTLS 改为 `-Dmtls` 可选，默认关闭（默认 `false`）——破坏性变更**：默认构建**零 Zig 包依赖、零 C 依赖**（不链 OpenSSL、不链 libc、构建期不联网取依赖）。默认（`-Dmtls=false`）下调用 `util.http.postXMLWithTLS` 返回 `error.MtlsNotEnabled`。**使用微信支付 v2 且配置了 `root_ca`（mTLS）的下游必须显式加 `-Dmtls=true`**（`zig build -Dmtls=true`），迁移步骤见 `docs/UPGRADING.md`。

### Added

- **`src/util/mtls.zig`**：仓库内自建的 OpenSSL 桥——运行时用 `std.DynLib` 加载 `libssl`/`libcrypto`，手写 extern 函数指针，**不需要头文件 / `translateC` / `linkSystemLibrary`**；`-Dmtls=true` 时 `postXMLWithTLS` 走该实现，用商户 PKCS#12 证书完成 mTLS POST。
- **CI**：新增"默认产物未链接 OpenSSL"的回归检查（防止 C 依赖悄然回归），并新增一个 `-Dmtls=true` 的编译 job。
- **响应体硬上限**：`util/http.zig` 的 `HttpClient.max_response_bytes`（默认 `default_max_response_bytes` = 16 MiB，`0` = 不限量），覆盖 `get`/`post`/`postJSON`/`postXML`/`postMultipart` 与 mock transport 路径；先按 `Content-Length` 预判（声明超限则一个字都不读），再边读边判，超限 `error.ResponseTooLarge`。
- **带头请求的传输入口**：`HeaderTransport` / `HttpResponse` / `HttpClient.requestWithHeaders` / `sendWithHeaders` / `postWithHeaders` / `setHeaderTransport`——`pay/v3/refund.zig` 与 `pay/v3/transfer.zig` 改用它（签名仍走 `pay/v3/signer.zig`），全仓对 `std.http.Client` 的直接构造收敛到 `util/http.zig` 一处。
- **fuzz 测试（5 个）**：`util/xml.zig`、`util/asn1.zig`、`util/pkcs12.zig`、`util/json.zig`、`util/uri.zig` 各一个 `std.testing.fuzz` 用例（`zig build test --fuzz=<N>`；普通测试下只做零输入冒烟）。**首次引入即发现 3 个真实缺陷，见 Fixed。**
- **`util/sync.zig` 的 `defaultIo`**、**`cache/memory.zig` 的 `Memory.io` 字段与 `createWithIo()`**、**`util/mtls.zig` 的 `max_head_bytes`**（64 KiB）。

- **`Options.connect_timeout_ms`（redis / memcache，默认 `0` = 不超时）**：补上"建连超时"这一缺口——`recv_timeout_ms` 只约束单次读取，对端黑洞时 TCP 握手仍可能阻塞到内核上限；配置后超时会放弃本次操作且**不创建/不池化连接**。
- **Io 注入补全（生产路径不再取全局单例）**：`officialaccount/message.Reply`、`officialaccount/js.Js`、`pay/{order,transfer,refund,redpacket}`、`work/jsapi.Js` 新增可注入的 `io` 字段；`pay/v3/signer.buildAuthorizationHeaderWithIo` 供签名链路注入 io。至此**生产代码里已无 `getCurrTS()` / `randomStr()` / `std.Options.debug_io` 的直接调用**（残余仅在测试块内）。

### Fixed

- **`util/uri.queryEscape` 堆越界写（fuzz 发现，内存安全）**：容量按 1 倍预留却用 `appendAssumeCapacity` 写入最多 3 倍字节——Debug/ReleaseSafe 下 panic、ReleaseFast 下堆溢出；受影响面包括 OCR 的 `img_url`、网页授权 / 开放平台 / work 的 `redirect_uri`、datacube 查询串。已改为按 `3 *| s.len` 预留并换用自动扩容的 `append`，并补"最坏情况输入"回归测试。
- **cache TTL 取时改用 `Clock.boot`（计入系统休眠）**：`cache/memory.zig` 原先用 `Clock.awake`，它**排除**系统休眠时间——笔记本合盖/容器冻结数小时再唤醒后 `expire_at_ns` 不前进，缓存里会继续用微信侧**已过期**的 access_token。纯耗时测量（连接池等待、测试计时）仍保持 `.awake`。
- **PKCS#12 的 PBKDF2 迭代次数加上限（DoS 面）**：`iteration_count` 完全取自文件内容，此前一个畸形/恶意 P12 只要把它写成大值就能让解析长时间占用 CPU；现 `> 5_000_000` 直接 `error.UnsupportedPbe`（并覆盖长度 0/超 4 字节的畸形 INTEGER）。
- **`util/xml.parse` 接受空标签名（fuzz 发现）**：`<>` / `<></>` 曾被"解析成功"并返回空 `root_name`；现 root 与子元素标签名为空一律 `MalformedXml`。
- **`util/json.appendEscapedString` 对非法 UTF-8 产出非法 JSON（fuzz 发现）**：合法 UTF-8 仍逐字节透传；非法字节改为 `\ufffd`（与 Go `encoding/json` 一致），保证 `'"' ++ escaped ++ '"'` 必能被 `std.json` 读回。
- **`util/crypto.pkcs5Pad` 错误集不一致**（编译门升级后暴露）：声明 `Allocator.Error![]u8` 却调用了可能返回 `InvalidArgument` 的 `pkcs7Pad`；抽出无校验内核后两个公开函数签名与错误集保持不变。
- **multipart 与请求头注入面**：`postMultipart` 的字段名/文件名按 RFC 9110 quoted-string 转义，控制字符（含 CR/LF）与空名/含冒号的头名一律 `error.InvalidArgument`（ReleaseFast 下 std 不做该断言）。
- **cache 主机解析**：`redis`/`memcache` 各自手写的 IPv4 解析（两份重复、不支持 IPv6）换成 `std.Io.net.IpAddress.parse`（IPv4/IPv6 字面量，含 `[v6]:port`），域名走 `net.HostName.lookup`；非法输入仍 `InvalidAddress`。注意实测结论：**`IpAddress.resolve` 不是 DNS**（它只多支持 IPv6 作用域后缀），DNS 必须用 `HostName.lookup`。

### Changed

- **Io 注入（继续收敛全局单例）**：`util/time.getCurrTSWithIo`、`util/util.randomStrWithIo`、`util/rsa.ed25519GenerateKeyPairWithIo` 新增（旧函数保留并委托，标注 deprecated，便于分批迁移）；`officialaccount/material.Material`、`officialaccount/server.Server`、`work/material.Material`、`pay/v3/order.OrderV3` 新增可注入的 `io: std.Io` 字段（默认 `std.Io.Threaded.global_single_threaded.io()`，既有结构体字面量与 `init()` 调用点无需改动）；`util/benchmark.zig`、`live_probe.zig`、`examples/*.zig` 改用 `std.process.Init` 的 `io`/`arena`（取代 `std.Options.debug_io` 与手搭 arena）。
- **cache 读路径**：`redis`/`memcache` 的逐字节 `readLine` 换成 `Io.Reader.takeDelimiterExclusive`（协议帧逐字节一致）；新增 **opt-in** 的 `Options.recv_timeout_ms`（默认 `0` = 不超时，保持现状），超时会让连接被丢弃、不进池（复用既有坏连接逻辑），避免"服务端半死导致永久阻塞并占死池连接"。
- **API 面门禁升级为 AST 解析**：`tools/api_surface.zig`（基于 `std.zig.Ast`）取代 `tools/api_surface.awk` 作为快照生成器（awk 保留作交叉校验参考），新增 `zig build api-surface` 步骤；快照新增 **`sig` 行**（函数签名：参数类型 + 返回类型），补上了此前"只记函数名、改参数/返回类型不触发门禁"的漏报面（实测：改参数类型旧工具无差异、新工具判红）。快照条目 6464 → **7418**（+944 条 `sig`），**无条目丢失**（与 awk 输出逐行 diff 为零差异）。

### Notes

- **`SpinMutex` → `std.Io.Mutex`（真阻塞的 futex 实现，不再自旋烧 CPU）——公开字段类型变更**：`SpinMutex.state`、`Memory.mutex`、`Memcache.mutex`、`Redis.pool_mutex`、`DefaultAccessToken.lock`、`DefaultJsTicket.lock`、`WorkAccessToken.lock`、`WorkJsTicket.lock`、`Context.token_mutex` 的锁字段类型均由 `SpinMutex` 改为 `std.Io.Mutex`（相关结构体新增可注入的 `io` 字段）。`util/sync.zig` 的 `SpinMutex` **保留为兼容层**（零参数 `lock()`/`unlock()`/`tryLock()` 语义不变，内部走 `lockUncancelable`），未迁移的调用点不受影响。
- **测试编译门升级为声明级**：`src/test_runner.zig` 的 `_ = mod;` 全部改为 `std.testing.refAllDecls(mod)`——从"文件级可达"提升到"每个顶层声明都被语义分析"，用于提前暴露"懒分析陷阱"类问题（已借此修掉上一条 Fixed）。
- **hex 编码统一到 `std.fmt.bytesToHex`**：`util/crypto.zig`、`util/signature.zig`、`officialaccount/js/mod.zig`、`miniprogram/virtualpayment/mod.zig`、`util/http.zig` 的 `generateBoundary` 共 5 处手写字符表/循环删除（公开签名与输出大小写逐处核对未变）。
- **重定向全量改走 `std.http.Client` 原生能力**：删除约 134 行手写（`ManualGetResult`、自写跳数循环、`isRedirectStatus`、`resolveRedirectUri`、sink 的 `accepts`），改由 `RedirectBehavior.init(n)` + `receiveHead` 处理（RFC 3986 解析、跨域换连、303/301+POST 改写 GET 均由 std 完成）；对外错误名经 `mapRedirectError` **保持兼容**（`TooManyRedirects` / `HttpStatusNotOk` / `InvalidRedirectLocation`）。行为变化：协议相对 `Location`（`//host/path`）现在会被跟随；`ws`/`wss` 目标在连接建立后才被拒绝。
- **`util/mtls.zig` 的响应解析改走 std 公开解析器**（`Response.Head.parse` + `http.Reader.bodyReader`）：删除 73 行手写的 status/header/chunked 解析；`buildRequest` **保留**（std 无自定义 TLS 后端入口，客户端证书场景必须自写请求字节）。行为收紧：超过 64 KiB 的 head、冲突的 `Content-Length`、obs-fold 续行、畸形/溢出 chunk 一律拒绝。

### Notes

- **建议迁移**：v2 退款 → `pay/v3/refund.zig`，v2 转账 → `pay/v3/transfer.zig`——v3 用 RSA 签名 + 普通 HTTPS，**不需要客户端证书**，因此不需要 `-Dmtls`；v2 现金红包（`src/pay/redpacket`）暂无 v3 等价物，仍刚需 mTLS（须 `-Dmtls=true`）。

## [0.4.5] — 2026-09-21

### Added

- **errcode 详情通道**：`util_error.lastErrorDetail()` / `clearErrorDetail()`——`decodeWithCommonError`/`handleFileResponse` 在 errcode != 0 时把 `errcode`/`errmsg`/`api_name` 写入线程局部零分配缓冲，消费方终于能区分 40001（token 失效）/45009（超频）/40003（openid 非法）/48001（未授权），不再只有粗粒度的 `ApiError`。`WechatError` 错误集保持不变。
- **token 失效自愈（全仓接线）**：`AccessTokenHandle`/`JsTicketHandle` 新增可选 `invalidate` 钩子（含 `DefaultAccessToken`/`WorkAccessToken`/`DefaultJsTicket`/`WorkJsTicket` 真实实现与 Context 转发），配合新增 `util/retry.zig` 的 `callApi`——取 token → 调用 → 命中 token 失效码（40001/40014/41001/42001）→ 作废缓存 → 取新 token → **只重试一次**。officialaccount / work / miniprogram 三个域的高频接口已全部接入。
- **微信支付 v3 商家转账**（`pay/v3/transfer.zig`）：发起转账 / 查询转账单 / 撤销转账 / 结果通知解密（新版 `/v3/fund-app/mch-transfer/transfer-bills`，字段以官方文档为准；Go 参考无 v3 实现）。`pay/v3/config.zig` 新增 `wechatpay_serial` 以便传加密 `user_name`。
- **媒体下载限额与落盘**：`util_http.getFollowRedirectLimited(uri, max_bytes)` / `getFollowRedirectToFile(uri, path, max_bytes)`（真流式：Content-Length 预判 + 16 KiB 分块累加，超限 `error.ResponseTooLarge`，落盘失败删除不完整文件）；`officialaccount/material` 与 `work/material` 的下载方法新增带限额与落盘变体（默认 100 MiB 安全网，图片/语音另有更严常量）。
- **启动期 HTTP 客户端初始化**：`util_http.initDefaultClient(allocator)` 进入严格模式（allocator 不一致 → `error.AllocatorMismatch`；其后 `getDefaultClient` 传错 allocator 会 `@panic`），并提供 `defaultClientAllocatorMatches` 供自查。
- **Redis 连接池**：`cache/redis.zig` 新增 `Options.max_connections`（默认 1，等价历史单连接语义）与 `pool_timeout_ms`；池锁只护空闲表、网络 I/O 全在锁外，坏连接丢弃不进池，等待有界（`error.PoolTimeout`），`redis.poolStats()` 可观测。
- **编码收敛基础设施**：新增 `util/json.zig`（`appendEscapedString`/`stringFieldObject`/`stringLiteral`）与 `util/uri.zig`（`queryEscape`，Go `url.QueryEscape` 语义），分别成为全仓唯一的 JSON 转义与 query 转义实现——原先 11 份手写 JSON escaper 与 3 份手写 QueryEscape 已收敛。
- **公开 API 面门禁**：`tools/api_surface_check.sh` + `api/surface.txt` 快照（CI 已接入）——删除/改名的公开符号必须在 CHANGELOG 里写明，否则 CI 失败。
- **可选真实接口探针**：`zig build live-probe`（env `ZWECHAT_LIVE_PROBE=1` + 凭据才联网，默认只报告、`-Dstrict` 才以 FAIL 退非零），用于发现"上游改了字段名"这类 mock 测不出的漂移。
- **文档**：新增 `docs/UPGRADING.md`（面向下游的升级速查，含 before/after 与 submodule bump 步骤）与 `docs/OPEN_ITEMS.md`（已知取舍与开放项）。

### Fixed

- **手写 JSON 拼接漏转义**（用户入参含 `"`/`\`/控制字符时产出非法 JSON）：`officialaccount` 的 menu/material/draft/freepublish/broadcast/basic/device、`work` 的 oauth/invoice/checkin/kf/msgaudit/appchat/message/robot、`miniprogram` 的 tcb/express/operation/auth/business 等站点统一改走 `util/json.zig` 或 `std.json.Stringify`；其中 `officialaccount/user.updateRemark`、`draft.update` 的 `media_id`、`invoice` 的 `card_id`/`encrypt_code`、`tcb.databaseMigrateQueryInfo` 的 `env` 属用户可控输入，修复前会直接产出非法 JSON。
- **`miniprogram/ocr` 的 `img_url` 编码语义**：由 `std.Uri.Component.formatQuery`（保留 `&`/`=`/`?`，CDN 签名 URL 会被服务端截断参数）改为 Go `url.QueryEscape` 语义，与 Go 参考逐字一致。
- **Redis 连接池超时用例的时序脆弱性**：并发负载下的线程调度延迟不再触发误报（放大 holder 命令耗时与断言的余量）。

### Changed

- **公开 API 新增**（非破坏）：`work/oauth` 等模块补齐 `setTransport`/`transport` 注入点；`pay/v3` 导出 `TransferV3` 等符号；各 Context 新增 `invalidateAccessToken`/`invalidateJsTicket`。`api/surface.txt` 基线已同步刷新。

## [0.4.4] — 2026-09-21

### Added

- **企业微信 API 覆盖补齐**：`work/addresslist` 33/33（部门/成员/标签 CRUD、userid↔openid 互转、batch_invite、互联企业）；`work/externalcontact` 78/79（contact_way 全套、groupchat、离职/在职继承、企业群发、朋友圈、客户规则、标签、获客助手）；`work/kf` 31 个服务端 API（syncMsg 游标拉取、升级服务、知识库、统计）与富媒体消息收发强类型（发送 9 类 / 接收 9 类消息 + 4 类事件），并提供 `OriginData` 原始 JSON 回捕（`getOriginData`/`originAs`/`originPayloadAs`，基于 `std.json` 的 `jsonParse` 钩子 + Value 树）。
- **公众号补齐**：客服消息全类型（text/image/voice/video/music/news/mpnews/wxcard/菜单/小程序）+ 转客服被动回复 + typing 状态；用户标签全套 / 黑名单 / `batchGetUserInfo` / `listAllUserOpenIDs` / `getAllBlackList` 分页封装；`datacube` 21/21；`broadcast` 18 个方法（含全员群发 `sendXxxToAll` 六组与 `previewToUser`）；`material` AddVideo/AddMaterial；`customerservice` 账号管理 7 个。
- **小程序补齐**：推送事件解析 **15/15 全覆盖**（交易管理、内容安全、物流、短视频、虚拟支付各类，JSON + XML 双路径，未知事件回退 raw）；`mediaCheckAsync`、`getPaidUnionID`、`queryScheme`、`uniformSend`。
- **开放平台补齐**：首次授权链路（`api_query_auth` 换 token 三元组并回写双缓存、`pre_auth_code`、`api_get_authorizer_info`、扫码授权链接 `getComponentLoginPage`/`getBindComponentURL(V2)`）；`authorizer_access_token` 获取与刷新（`api_authorizer_token`）；FastRegisterWeapp（注册小程序 + 状态查询）；代运营 7 接口（账号信息/昵称/签名/头像/搜索状态）。
- **微信支付 v3 退款**：`pay/v3/refund.zig`（申请退款 / 查询退款 / 退款通知解密；Go 参考无 v3 实现，字段以官方文档为准）。
- **`util_http.getFollowRedirect`**：GET 手动 302 跟随（≤2 跳，仅 http/https，防开放重定向），并接入媒体下载（`officialaccount/material.getMedia`、`work/material.getTempFile`）。
- **`util/sync.zig`**：统一 `SpinMutex` 入口（原 cache/credential 各处内联副本收敛）。

### Fixed

- **懒分析陷阱：40 个方法首次调用即编译失败**（`analysis`/`operation`/`minidrama`/`express`/`order`/`subscribe` 私有泛型 helper 的 `comptime T` 声明位与调用点错位）——统一为「类型参数在末位」，并为每个模块补真实 mock-transport 调用测试。
- **响应解析契约（std.json 严格模式）**：全仓 41 个解析站点统一 `.ignore_unknown_fields = true`；字段名逐字对齐微信返回（`vaild`、`exteranalopenid` 等官方笔误，camelCase `phoneNumber`，`w`/`h`，`chatid`）。
- **miniprogram**：`auth`（vaild/phoneNumber/watermark、checkEncryptedData 请求体改 JSON）、`ocr`（`type`、img_size `w/h`、img_url 转义、`fetch` 泛型参数序）、`tcb`（数据库 5 接口非法 JSON：query 未转义）、`virtualpayment`（`env` 序列化为数字 0/1）、`security`/`content`/`qrcode`/`message`（JSON 转义与 errcode 检查）、`riskcontrol`（双收 `unoin_id` 官方笔误 + `union_id` 兜底）。
- **work**：`appchat`（`chat_info` 包装层 + `chatid`）、`material`（`created_at` 为字符串；删除不存在的 `getMediaList` 端点）、`msgaudit`（`getRoomInfo`/`getAgreeInfo` 重写为真实端点）、`invoice`/`oauth`/`message`/`server` 契约与转义修复、手写 JSON 编码器补控制字符 `\u00XX` 转义。
- **officialaccount**：`user` 的 errcode 漏检与 `OpenidList` 嵌套结构、`customerservice` errcode 漏检、`server` 验签与安全模式、`js` JSSDK 签名、`ocr` 端点、`draft`/`freepublish` URL。
- **openplatform**：`account` 四方法缺少 `access_token` query 且误用 component token（改为 authorizer token）；authorizer 刷新链路的借用切片 UAF 与 OOM 路径泄漏。
- **pay**：v3 签名漏字段与伪签名校验、`decryptRefund` 密钥大写 hex、`aesECBDecrypt` 缩短切片。
- **并发安全**：`cache/memcache`、`cache/redis` 单连接加锁串行化往返（此前并发即协议损坏）；`credential` 四个获取器改 singleflight（锁只护缓存读写，HTTP 回源移出锁外）；openplatform token 链路加锁（防 refresh_token 轮换丢失）；`middleware` 32 字节 AES key 校验。

### Changed

- **公开 API 变更**：`miniprogram/content.checkText` 增加 `openid`/`scene` 必填参数；`officialaccount/customerservice.listAccounts` 返回类型化 `Parsed(KfListResponse)`；`officialaccount/user.OpenidList.openids` → `.data.openid`；`openplatform/account` 四方法改为接收 `authorizer_access_token` 并以 `?access_token=` 注入；`middleware.handleServerMessage` 新增 `expected_app_id` 参数；删除 `work/material.getMediaList`（端点不存在）；`work/msgaudit.getRoomInfo`/`getAgreeInfo` 签名与响应结构重写。
- **弃用标注**（不删方法）：`MiniProgram.getMessage`/`getContent`/`getBusiness.getPhoneNumber` 在顶层文档标注弃用与推荐入口。
- **文档**：`doc/api_guide.md` 235 → 620 行（新增开放平台授权全链路时序与缓存凭据配置章节，补齐 work/miniprogram/officialaccount 高频场景与各章「常见坑」）。

### Tests

- 内联单元测试 **449 → 827**（+378），零内存泄漏；每个新增公开方法均有 mock-transport 真实调用测试。

## [0.4.3] — 2026-08-13

### Fixed

- **writeArticleJson/writeJsonMatchRule 编译失败**：v0.4.2 引入的 `buf.writer.print`（`std.ArrayListUnmanaged` 无 `writer` 字段）改为三条 `buf.appendSlice`（`"` + name + `":"`）。

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

[Unreleased]: https://github.com/chy3xyz/zwechat/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.5.0
[0.4.5]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.5
[0.4.4]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.4
[0.4.3]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.3
[0.4.2]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.2
[0.4.1]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.1
[0.4.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.4.0
[0.3.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.3.0
[0.2.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.2.0
[0.1.0]: https://github.com/chy3xyz/zwechat/releases/tag/v0.1.0
[0.0.1]: https://github.com/chy3xyz/zwechat/releases/tag/v0.0.1