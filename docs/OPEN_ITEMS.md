# 已知取舍与开放项（OPEN_ITEMS）

本文记录 `zwechat` **有意为之的取舍**与**尚未闭环的开放项**，供下游消费者评估风险。
每条按四段式：**决策 → 影响 → 缓解 → 触发再评估的条件**，并给出可复核的代码位置。

> **口径**：事实只来自源码、`AGENTS.md`（维护者决策记录）与 `CHANGELOG.md`。
> 凡是三者不一致的地方，以**源码为准**并在条目内明确标注差异。
> 版本锚点：**v0.4.4**（发版提交 `4640e65`，`build.zig.zon` 的 `.version = "0.4.4"`）。
>
> ⚠️ **本文核对的是"撰写时的工作树"，而工作树可能已领先 v0.4.4 tag。**
> 撰写期间仓库里正有若干并行重构（`util/uri.zig` 与 `util/json.zig` 的编码收敛、
> `cache/redis` 的可选连接池、测试辅助去懒路径化、`work/addresslist`/`externalcontact` 等）。
> 因此凡是**可能不在 v0.4.4 tag 里**的条目，本文在条目内单独标注了
> "版本口径"提示与自查命令。判断某能力是否在你的 checkout 中，
> **一律以 `grep` 自查为准，不要只信本文叙述**。

---

## 1. 企业微信会话存档（msgaudit）消息解密：明确不支持

**决策**
不移植会话存档的**密文解密**能力。官方解密依赖企微私有闭源 SDK
`libWeWorkFinanceSdk`（C ABI + 预编译 `.so`/`.dll`），Go 参考实现也是 cgo 直连；
Zig 侧引入需链接闭源二进制，且无法离线测试，与"测试不依赖外部服务"的项目纪律冲突。

**影响**
- `src/work/msgaudit/mod.zig` 只提供**元数据接口**：
  `getRoomInfo`（`src/work/msgaudit/mod.zig:120`，端点 `groupchat/get`）与
  `getAgreeInfo`（`src/work/msgaudit/mod.zig:161`，端点 `check_single_agree`）。
- 无法从本 SDK 拿到聊天记录明文。需要存档链路的下游必须另接官方 SDK
  （或走企微侧已解密的落库/转发通道）。
- ⚠️ **文档与源码不一致**：`AGENTS.md` 的「移植备注」写"当前只提供元数据接口
  （getRoomInfo/getAgreeInfo/**getChatInfo**）"，但 v0.4.4 源码中
  `msgaudit` **不存在** `getChatInfo`（该文件仅有上述两个 `pub fn`，`init` 与
  内嵌 `send` 除外）。若你按 AGENTS 去找 `getChatInfo`，会找不到。

**缓解**
- 元数据侧（群信息、同意存档状态）用现有两接口即可，见 `doc/api_guide.md` 中
  企业微信章节。
- 若必须做解密：单独立项做 C ABI 绑定 + 真机集成测试，不要混进单元测试。

**触发再评估的条件**
业务上出现"必须在 Zig 进程内解密会话存档"的硬需求；
或企微提供 REST/HTTP 形式的解密接口；或上游开放可再分发的 SDK 二进制。

---

## 2. `.ignore_unknown_fields = true` 的沉默另一面（外部评审 #10）

**决策**
全仓解析微信响应的站点统一使用 `.ignore_unknown_fields = true`
（`std.json` 默认 `false`——字段名差一个字符就会让整个调用 `DecodeError`）。
CHANGELOG `[0.4.4] → Fixed` 记录本批次统一了 **41 个解析站点**。

> **现状口径**（当前 checkout 实测，方便你判断覆盖面）：
> `ignore_unknown_fields` 在 `src/` 中共出现 **124 次**，
> `parseFromSlice` 共 **136 处**——绝大多数解析站点已开启宽容模式，
> 少数未开启的多为 `pay` 的 XML/自有结构或 mock 夹具。

**影响（这是本条的重点）**
宽容模式的代价是**另一端也静默**：上游字段**改名**时不会报错，而是解析成该字段的
默认值（`""` / `0` / 空数组）。也就是说：

- 类型错误（字符串 ↔ 数字）仍会报错；
- **字段名拼写错误不会报错**，只会让你拿到零值。

这正是 `vaild`（小程序 auth 的官方笔误）、`exteranalopenid`
（`src/work/msgaudit/mod.zig:74`，企微官方笔误）这类 key 只能靠**真实调用**发现的
原因——离线 mock 夹具是你自己按文档写的，写错了测试也跟着错。
同理，`work/appchat` 的 `chat_info` 包装层（`src/work/appchat/mod.zig:35`）
和 `officialaccount/user.OpenidList.data.openid`
（`src/officialaccount/user/mod.zig:32`）在修复前都是"结构对不上 → 静默空值"。

**缓解**
1. **可选 live probe**：对关键链路保留一个"打真接口"的冒烟脚本
   （只在发布前/CI 的手动 job 里跑，不进单元测试），专门核对字段是否还有值。
2. **关键字段非空断言**：解析后在业务侧断言
   `roomname.len > 0` / `kf_account.len > 0` / `userlist.len > 0` 等；
   零值往往说明结构已经漂移，而不是"微信真返回了空"。
3. **查错误详情**：`util_error.lastErrorDetail()`（`src/util/error.zig:189`）
   在线程局部槽位里保留最近一次失败的 `errcode` / `errmsg` / `api_name`
   （`clearErrorDetail()` 在 `:198`），在 `catch` 分支里随时可取；
   配套的 `handleFileResponse`（`:319`）用于识别"本该是文件、实际是 JSON 错误体"。
   注意 `errmsg` / `api_name` 是**指向线程局部缓冲的借用切片**，跨线程或长期保存要自己 `dupe`。
4. 读响应结构体时**逐字比对微信官方文档 key**，包括官方笔误
   （`vaild`、`exteranalopenid`、`unoin_id`）。仓库内有意保留的笔误字段都写了注释。

**触发再评估的条件**
微信发布字段改名/结构调整公告；线上出现"某个字段突然全为空"的工单；
或某条链路对正确性要求高到需要把该站点**收紧为 `ignore_unknown_fields = false`**
（代价是上游加字段就会 DecodeError，需要按站点逐个权衡）。

---

## 3. `cache/memcache` 单连接串行化；`cache/redis` 已提供可选连接池

### 3a. `cache/memcache`：单连接 + 全往返串行化（无池）

**决策**
Memcache 后端只维护**一条 TCP 连接**，用 `SpinMutex` 把
**整个请求-响应往返**（写 socket → 读响应）串行化，而不是只保护缓冲区读写。
理由：交错写 socket 会直接损坏 text protocol——并发不是"慢"而是"错"。
模块文档写明"仅实现单连接（无连接池），满足 access_token / js_ticket 共享缓存场景"。

**影响**
- 多线程不再出现协议损坏（v0.4.4 修复项），代价是**吞吐上限 ≈ 1 / RTT**：
  同一实例上的缓存操作串行排队。高并发下延迟随排队线性增长。
- 临界区含网络 I/O，与 `SpinMutex` 的适用前提（临界区极短）相悖：
  自旋等待期间在烧 CPU。这是知情取舍，不是疏漏。
- `get` 返回的切片借用自 `Memcache.last_value`，**下一次缓存操作前**有效。

**代码位置**
- `src/cache/memcache.zig:9`（模块文档：单连接无池 + 串行化）、`:49`（`mutex: SpinMutex`）、
  `:111` / `:128` / `:149` / `:165`（四处 `mutex.lock()`）。

**缓解**
1. **多实例/多进程部署**是当前推荐的水平扩展方式——每个实例一条连接，
   服务端自身并发处理，SDK 侧不成为瓶颈。
2. 减少 `cache` 往返：把 access_token / js_ticket 的有效期交给缓存，
   避免热路径反复 `get`。
3. 需要更高单机吞吐时改用 `cache/redis`（可选连接池，见 3b）。

**触发再评估的条件**
单机 memcache 缓存 QPS 触顶、P99 被 RTT 排队明显拖慢；
或出现"自旋锁占用 CPU"的实测证据。

---

### 3b. `cache/redis`：可选连接池（`Options.max_connections`）

**决策**
Redis 后端提供**可选连接池**，把这组取舍从"二选一"变成"可配置"：

- `Options.max_connections`（`src/cache/redis.zig:43`）**默认 1**，
  等价于历史单连接行为（既有调用点零改动）；
  `0` 会被钳制为 `1`。
- 设为 N > 1 时最多 N 条连接并行服务 N 个并发调用，
  吞吐不再被 `1/RTT` 卡住——"串行化修好了协议交错损坏，但代价是把并发压成单连接；
  连接池两者兼得"。
- **池锁只保护空闲连接表与计数器**：建连、AUTH/SELECT、请求-响应往返、`close`
  全部在池锁之外进行。持池锁做网络 I/O 会让池退化回单连接串行——这是实现的核心纪律，
  模块文档明确要求"改动时不要破坏"。
- **等待有上界**：池已满时在**不持池锁**的前提下"短自旋 + 小睡"等待归还，
  超过 `Options.pool_timeout_ms`（`src/cache/redis.zig:54`，默认 30 000 ms；
  `0` 表示不等待）返回 `error.PoolTimeout`，在 vtable 边界映射为
  `CacheError.StorageError` 并打印 warn 日志，同时自增 `poolStats().timeouts`。
  **永远不会挂死。**
- **坏连接不进池**：读写失败 / 协议解析失败的连接已失步或已断开，直接关闭丢弃，
  下次取连接时重建；服务端返回 `-ERR`（回复完整、协议仍同步）的连接照常复用。

**影响**
- 默认配置下行为不变（仍是单连接串行，吞吐受 `1/RTT` 限制）——
  **想拿到并发收益必须显式设置 `max_connections > 1`**。
- 池已满时是**有界等待**而非无限排队：超时后调用方拿到 `CacheError.StorageError`，
  需要在业务侧区分"缓存不可用"（降级/重试）与"缓存未命中"。
- `get` 返回的切片借用自**当前借出连接的复用值缓冲**：任何后续 `get`
  （含其它线程的 `get`）之后都不保证有效，跨操作持有必须 `allocator.dupe`。
- 不支持 TLS；如需 TLS 可外部用 stunnel / redis+tls 代理。

**代码位置**
- `src/cache/redis.zig:43`（`max_connections` 默认值）、`:54`（`pool_timeout_ms`）、
  `:58`（`PoolStats`）、`:215`（`pool_mutex`）、`:289`（`poolStats()`）、
  `:313`（`acquire`）、`:362`（`release`）；模块级设计取舍见 `:1`-`:26`。
- vtable 边的错误映射：`src/cache/redis.zig:443` 起（`acquireForOp`）。

**缓解**
1. 按并发度设 `max_connections`（例如与工作线程数同量级），并显式设
   `pool_timeout_ms` 以匹配你的超时预算。
2. 用 `Redis.poolStats()`（`src/cache/redis.zig:289`）把
   `live` / 借出峰值 / `timeouts` 接进监控，别等超时才发现池太小。
3. `get` 的返回值要跨操作使用时一律 `dupe`（默认单连接下也成立）。

**触发再评估的条件**
`poolStats().timeouts` 持续非零（说明池太小或下游太慢）；
或出现"池锁被网络 I/O 持住"的性能回归（会退化回单连接行为）。

> **⚠️ 版本口径**：本节的连接池是**撰写时工作树**中的实现。
> v0.4.4 tag 的 `redis.zig` 只有单连接 + 一把 `mutex`（无 `max_connections`）。
> 升级/选型前请在你的 checkout 上确认：
> `grep -n "max_connections" src/cache/redis.zig`——有输出才说明连接池可用。
>
> 另外，无论 Redis 还是 Memcache，`credential` 的获取器都已改成 singleflight 式
> （锁只护缓存读/写双检，HTTP 回源在锁外，避免 N-1 线程持自旋锁空转）；
> 取舍见 `AGENTS.md`「并发模型决策（三轮评估后定案）」小节。

---

## 4. 媒体下载默认限额与 `ResponseTooLarge`

**决策**
所有媒体下载都带**默认体积上限**（"防爆内存"安全网），超限返回
`error.ResponseTooLarge`，并提供 `*WithLimit` 变体让调用方覆盖。
落盘变体额外保证**不留下不完整文件**。

**默认值一览（均可复核）**

| 常数 | 值 | 位置 |
|---|---|---|
| `officialaccount/material.max_media_bytes` | 100 MiB | `src/officialaccount/material/mod.zig:25` |
| `officialaccount/material.max_image_bytes` | 10 MiB | `src/officialaccount/material/mod.zig:28` |
| `officialaccount/material.max_voice_bytes` | 2 MiB | `src/officialaccount/material/mod.zig:31` |
| `officialaccount/material.max_video_bytes` | 100 MiB | `src/officialaccount/material/mod.zig:34` |
| `work/material.max_media_bytes` | 100 MiB | `src/work/material/mod.zig:55` |
| `work/material.max_image_bytes` | 10 MiB | `src/work/material/mod.zig:58` |
| `work/material.max_voice_bytes` | 2 MiB | `src/work/material/mod.zig:61` |
| `work/material.max_video_bytes` | 10 MiB | `src/work/material/mod.zig:64` |
| `work/material.max_file_bytes` | 20 MiB | `src/work/material/mod.zig:67` |
| `max_redirect_hops`（302 跟随跳数上限） | 2 | `src/util/http.zig:649` |

- 企业微信侧口径（图片 10 MB、语音 2 MB、视频 10 MB、普通文件 20 MB）见
  `src/work/material/mod.zig` 的注释；`maxBytesFor(mtype)`（`:70`）按类型给出推荐值。
- 官方公众号侧**没有** `max_file_bytes` 与 `maxBytesFor`，只有四个常数。
- `max_media_bytes` 刻意取 100 MB：大于任何合法素材，仅作安全网。
  缺省值不等于"微信允许的大小"。

**影响**
- 下载超过默认上限的素材会直接失败（`error.ResponseTooLarge`），
  而不是截断——这是刻意的 fail-closed。
- **注入 transport（MockTransport）的路径下限额是"读完后判定"**：
  mock 没有流式能力，只能先把 body 读进内存，再比对长度。
  真实 HTTPS 路径才是真流式（先用 `Content-Length` 预判，再逐块累加，
  超限立即中止）。
  - `getFollowRedirectLimited`：真实路径说明见 `src/util/http.zig:261`-`:262`（文档），
    注入路径实现在 `:266`-`:273`。
  - `getFollowRedirectToFile`：注入路径在 `:296`-`:301`（先在内存收完再落盘）。
- 因此**不要用注入 transport 的测试来验证"大文件不会 OOM"**——它证明不了。
  要验证流式行为，用真实 HTTPS 路径（仓库内已有基于本地 fake server 的测试）。

**相关 API**
`src/util/http.zig:246` `getFollowRedirect`（无限额、仅跟 2 跳）、
`:265` `getFollowRedirectLimited(uri, max_bytes)`、
`:289` `getFollowRedirectToFile(uri, file_path, max_bytes)`；
素材侧封装：`src/officialaccount/material/mod.zig:372` `getMedia` / `:384` `getMediaWithLimit` /
`:409` `getMediaToFileWithLimit`，`src/work/material/mod.zig:163` `getTempFile` /
`:175` `getTempFileWithLimit` / `:198` `getTempFileToFileWithLimit`。
落盘路径还会**回读小文件判定是否为 JSON 错误体**，避免把错误 JSON 当素材留在磁盘上。

**缓解**
1. 大素材（尤其视频）用 `*ToFile*` 变体落盘，别读进内存。
2. 明确知道业务素材上限时传显式 `max_bytes`（可用 `maxBytesFor`）。
3. `catch` 里区分 `error.ResponseTooLarge` 与 `WechatError.ApiError`：
   前者是"你没给够额度"，后者是"media_id 无效/无权限"，处置方式不同。

**触发再评估的条件**
合法素材被默认上限挡住；或微信上调素材体积上限；
或引入第三方 HTTP 客户端后注入路径也具备流式能力。

---

## 5. `util.http.getDefaultClient` 懒初始化仍保持"首个 allocator 生效"的宽容语义

**决策**
线程局部默认 `HttpClient` 有两种初始化模式：

- **严格模式**：调用 `initDefaultClient(allocator)`（`src/util/http.zig:102`）显式初始化后，
  再用**不一致的 allocator** 调 `getDefaultClient` 会 `@panic`（fail-closed，
  因为实例的 allocator 在初始化时固定，用错会变成静默的悬垂分配）。
- **懒模式（历史写法，予以保留）**：直接调 `getDefaultClient(allocator)`
  （`src/util/http.zig:128`）时，实例沿用**首次**传入的 allocator；
  之后传其它 allocator **不 panic、也不生效**，仍返回同一实例。

保留宽容语义的原因：`getDefaultClient` 的返回类型是 `*HttpClient`，
全仓大量调用点依赖这一签名；改成错误联合会破坏兼容。

**影响**
- 懒模式下"传错 allocator"是**静默**的：你以为在用 `std.testing.allocator`，
  实际分配仍走首个 allocator，`std.testing.allocator` 的泄漏检测因此**看不到**这批分配。
- 严格模式只影响**当前线程**；多线程程序需每个线程各自初始化。

**缓解**
- 启动期调一次 `initDefaultClient(allocator)` 进入严格模式（推荐）；
- 懒模式下用 `defaultClientAllocatorMatches(allocator)`（`src/util/http.zig:149`）
  显式校验，不一致就报错/重初始化；
- 线程退出前调 `deinitDefaultClient()`（`:158`）释放连接池等资源，
  之后可用新 allocator 重新初始化。

**当前依赖这份宽容语义的地方（撰写时实测，正在被改造）**
各业务模块的测试辅助函数（`setupTestClient` / `releaseTestClient` 模式）此前靠"再传一个
`std.heap.page_allocator` 取一次指针、断言拿到同一实例"来验证懒语义。
**这批测试正在被改成不依赖它**——`releaseTestClient()` 现在直接调用
`deinitDefaultClient()` 销毁线程局部实例（其注释写明"不依赖『用别的 allocator
再取一次指针』的宽容语义"）。撰写时仍有 7 个模块保留 `releaseTestClient`，
另有 2 个模块的辅助带同样的注释：

```bash
# 保留 releaseTestClient 辅助的模块
grep -rln "fn releaseTestClient" src/
#   -> officialaccount/{draft,freepublish,datacube,broadcast,material}
#      miniprogram/{virtualpayment,tcb}
# 带"不依赖宽容语义"注释（已改造）的模块
grep -rn "不依赖「用别的 allocator" src/ | cut -d: -f1 | sort -u
#   -> 上述 6 个 + work/{addresslist,externalcontact}
```

懒语义本身的回归测试仍在：
`"getDefaultClient 懒初始化沿用首个 allocator，可用校验函数发现不一致"`
（`test` 块起于 `src/util/http.zig:1233`），断言"懒初始化后传别的 allocator
不 panic，仍返回同一实例"。

**触发再评估的条件**
所有测试辅助都不再触碰懒路径、且调用点不再依赖 `*HttpClient` 返回类型
（可改为错误联合）时，把懒模式收敛成"必须显式初始化"。
在那之前，**下游应当把 `initDefaultClient` 当作必做步骤**，不要依赖懒语义。

---

## 6. `work/kf` 的 `OriginData` 用 `std.json` 的 `jsonParse` 钩子实现

**决策**
Go 版 `syncmsg` 用 `gjson` 从原始 JSON 里按路径取字段（`OriginData`）。
Zig 版没有等价的 gjson，改为：为 `SyncMessage` 实现 `jsonParse`
（`src/work/kf/mod.zig:706`），解析时**先把整条消息元素物化成 `std.json.Value` 树**，
再 `parseFromValueLeaky` 解出强类型字段，最后把整棵树挂到 `origin_data`
（`src/work/kf/mod.zig:698`）。对既有代码零侵入（`std.meta.hasFn(T, "jsonParse")` 自动调用）。

**影响（代价）**
1. **每条消息多一份 Value 副本**：解析开销与内存占用约**翻倍**
   （强类型结构体 + Value 树各一份）。批量 `syncMsg` 拉取时是实打实的开销。
2. **重复 JSON 键从"报错"变为"后者覆盖"**：`std.json.Value` 的 ObjectMap
   语义如此。微信不下发重复键，因此可接受；但如果上游出现重复键，
   强类型字段与 `origin_data` 可能取到**不同**的值。
3. `origin_data` 的类型是 `?std.json.Value`（`:697`），其生命周期绑定
   `std.json.Parsed` 的 arena；`getOriginData` 的注释明确"对象键序保留，
   空白与数字书写形式可能被规范化（`1.0` 可能被写成 `1`）"，
   即**语义等价而非逐字节相同**。

**缓解**
- 只需要强类型字段时，不要碰 `origin_data`（代价已经付了，但别再多付一次序列化）。
- 需要原始 JSON 时用 `getOriginData`（`:735`，调用方 `free`）；
  需要"读取强类型未建模的新字段"时用 `originAs`（`:745`）或
  `originPayloadAs`（`:765`），二者都返回 `std.json.Parsed(T)`，
  **由调用方 `deinit`**。
- ⚠️ `origin_data` 无法在 `std.json.parseFromValue` 里被直接"裁剪"，
  若要省内存，只能在**上游**按 `msgtype` 白名单开关（见触发条件）。

**触发再评估的条件**
`syncMsg` 成为内存/CPU 热点（实测）；
或引入更轻量的路径取值实现（如自写的 wire-level 扫描）可替代全量 Value 物化；
或出现重复 JSON 键导致的字段不一致问题。

---

## 7. 微信支付 v2：错误以字段形式内联返回，而不是错误集

**决策**
v2 的 XML 应答沿用微信原生语义：**HTTP 200 + `return_code`/`result_code`**，
SDK 不把它折叠成 `error.ApiError`，而是原样放进返回结构体。

**影响**
- 调用方**必须自行判定**：
  - `return_code != "SUCCESS"` → 通信层/签名失败；
  - `return_code == "SUCCESS"` 但 `result_code != "SUCCESS"` → 业务失败，
    看 `err_code` / `err_code_des`。
- 这与 v0.4.4 起 JSON 接口的纪律（errcode 非 0 → `WechatError.ApiError`）**不一致**。
  混用两套风格时容易漏判。
- 返回值**持有底层 XML 响应缓冲区**（字段切片指向它），因此：
  **读取完毕后必须调用 `deinit()`**，否则泄漏。

**代码位置**
- `src/pay/order/mod.zig:38` `return_code`（`PreOrder`，`:44` 为 `result_code`，
  `deinit` 在 `:57`）；`QueryOrderResult`（`:75`，`deinit` 在 `:90`）、
  `CloseOrderResult`（`:99`，`deinit` 在 `:111`）。
- `src/pay/refund/mod.zig:26` `RefundResult`（`return_code`/`return_msg`/`result_code`/
  `err_code`/`err_code_des`），`deinit` 在 `:38`。
- 对照：`pay/v3` 走的是错误应答判定（`src/pay/v3/refund.zig:134` `refund` /
  `:162` `queryRefund`，v3 错误体 `{"code":...,"message":...}` 映射为
  `WechatError.ApiError`）。

**缓解**
- 在每个 v2 调用点写一个统一的小判定函数（例如 `fn isPayOk(r) bool`），
  别散落 `if`——v2 有 5 个返回值结构体。
- 用 `defer result.deinit();` 紧跟调用点，避免漏释放。
- 需要严格失败语义时，可在业务包装层把 `result_code != "SUCCESS"` 转成自己的错误。

**触发再评估的条件**
出现"v2 返回成功码但业务没成功"的线上事故；
或项目决定统一错误语义（届时属于**破坏性变更**，需按
[`UPGRADING.md`](UPGRADING.md) §3.1 的 `0.x` 约定发 minor）。

---

## 8. `miniprogram/virtualpayment.requestAddress` 未接入 token 自愈重试

**决策（现状，而非有意设计）**
`virtualpayment` 的所有请求都经过 `requestAddress`
（`src/miniprogram/virtualpayment/mod.zig:745`）取 access_token 并拼 URL，
**没有**走 `util_retry.callApi`（`src/util/retry.zig:66`，
全仓统一的"token 失效 → 作废缓存 → 重取 → 只重试一次"链路）。
该文件中不存在 `util_retry` 的引用。

**影响**
- access_token 中途失效（微信侧提前作废，如被其他实例刷新）时，
  该模块的调用会直接失败（`errcode` 非 0），**不会自动重取重试**；
  而同一仓库里走 `util_retry` 的模块会自动恢复。
- 表现为"偶发失败、重试一次就好"的抖动，容易被误判为网络问题。

**缓解**
1. 上层对 `virtualpayment` 调用做一次业务级重试（失败即重试一次），
   等价于手工补上缺失的自愈。
2. 调用前用 `MiniProgram`/`Context` 的入口主动确认 token 新鲜度；
   跨实例共享缓存时优先用 Redis/Memcache 后端，减少"别的实例刷新了但我不知道"。
3. 请求失败时用 `util_error.lastErrorDetail()`（`src/util/error.zig:189`）
   确认是不是 token 类错误码（判定函数 `isTokenInvalidErrCode`，`:233`）。

**触发再评估的条件**
`virtualpayment` 出现 token 失效导致的线上失败；
或该模块被改造为经 `util_retry.callApi`（届时需注意 `pay_sig` 是对
`path + "&" + content` 的 HMAC-SHA256，**与 token 无关**，重试安全）。

---

## 9. 手写 JSON / URL 编码点的收敛进度

**决策**
为对齐微信的真实契约（字段名逐字、编码逐字），部分请求体**手写**序列化，
而不是依赖 `std.json` 反向映射——因为微信存在大量官方笔误 key
（`vaild`、`exteranalopenid`、`unoin_id`）与非常规形状（`chat_info` 包装、
`env` 为数字等），反向映射容易构造出"结构合法但微信不认"的请求。
收敛方向是"手写但只写一份"：把转义逻辑提取到 `util`，各业务模块复用。

**现状（以当前 checkout 实测为准，可复核；分三块）**

**（a）URL query 转义 —— 已收敛 ✅**
唯一实现是 `src/util/uri.zig:21` 的 `queryEscape`
（Go `url.QueryEscape` 语义：保留 `[0-9A-Za-z-_.~]`，空格转 `+`，其余 `%XX` 大写）。
原先三处各自手写的副本已改为**别名再导出**，不再有重复实现：

| 原调用点 | 现状 | 位置 |
|---|---|---|
| 公众号 OCR `img_url` 转义 | `const queryEscape = util_uri.queryEscape;` | `src/officialaccount/ocr/mod.zig:126` |
| 开放平台授权链接构造 | `const escapeQuery = util_uri.queryEscape;` | `src/openplatform/context/auth.zig:196` |
| 企微网页授权 `redirect_uri` | `const queryEscape = util_uri.queryEscape;` | `src/work/oauth/mod.zig:71` |

**（b）JSON 字符串转义 —— 大规模收敛进行中 ⚠️（本条是主要开放项）**
唯一实现已建立：`src/util/json.zig`（`appendEscapedString:22`、`stringFieldObject:51`、
`stringLiteral:69`；覆盖 RFC 8259 要求的全部控制字符，含 `\u00xx` 小写 hex），
并在编译门 `src/test_runner.zig:43` 注册。

迁移采用"别名再导出"模式（最小 diff、调用点不动）：
`const appendJsonString = util_json.appendEscapedString;`。
**截至撰文时**，原先各自内联的 10 份 `appendJsonString` 副本里 **8 份已迁移**，
另有 broadcast 的异名副本 `appendJsonEscaped` 也一并迁移：

| 模块 | 别名位置 | 别名名 |
|---|---|---|
| 公众号 menu | `src/officialaccount/menu/mod.zig:423` | `appendJsonString` |
| 公众号 material | `src/officialaccount/material/mod.zig:558` | `appendJsonString` |
| 公众号 broadcast | `src/officialaccount/broadcast/mod.zig:478` | `appendJsonEscaped`（异名） |
| 企微 appchat | `src/work/appchat/mod.zig:259` | `appendJsonString` |
| 企微 kf | `src/work/kf/mod.zig:1686` | `appendJsonString` |
| 企微 message | `src/work/message/mod.zig:276` | `appendJsonString` |
| 企微 msgaudit | `src/work/msgaudit/mod.zig:234` | `appendJsonString` |
| 企微 checkin | `src/work/checkin/mod.zig:296` | `appendJsonString` |
| 企微 invoice | `src/work/invoice/mod.zig:239` | `appendJsonString` |

**尚未迁移的旧内联实现还剩 2 份**（**只转义 `"`、`\`、`\n`、`\r`、`\t`，
漏掉其余 `U+0000`–`U+001F` 控制字符**）：

| 模块 | 旧实现位置 |
|---|---|
| `util/template` | `src/util/template.zig:13` |
| 企微 robot | `src/work/robot/mod.zig:171` |

> **⚠️ 这一块正在被并发重构，"已完成 / 未迁移"清单与行号都会变动。**
> 判断当前状态的权威方法（不要依赖本文的清单）：
>
> ```bash
> # 还有哪些文件内联了旧实现（漏控制字符转义的那版）——“还有输出”就是风险面
> grep -rn "^fn appendJsonString\|^    fn appendJsonString" src/
> # 哪些文件已改为别名再导出
> grep -rn "util_json.appendEscapedString" src/
> ```
>
> 只要第一条还有输出，那些模块就仍可能产出非法 JSON。
> 用户输入含控制字符（剪贴板 / OCR 文本里的 `\x00`-`\x1F`）时尤其要小心。

**（c）`allocPrint` 裸插值拼 JSON —— 仍有约 33 处**
（`grep -rn 'allocPrint' src/ --include=*.zig | grep '\"' | wc -l`）多为固定形状的单字段体，
如 `{"media_id":"{s}"}`、`{"code":"{s}"}`；嵌的是 id/code 一类通常不含自由文本的值，
风险可控但不为零。`util/json.zig` 的 `stringFieldObject` 正是为替换这类调用点而写的
（其文档点名了 openid / media_id / 运单号 / action 等来源），但截至撰文时
**除 `src/util/mod.zig:43` 的 `@hasDecl` 断言外尚无业务调用方**。

**（d）一处与 (a) 相悖的遗漏 ⚠️**
`src/miniprogram/ocr/mod.zig:172` 仍在使用
`(std.Uri.Component{ .raw = img_url }).formatQuery(...)` 转义 `img_url`。
而 `src/util/uri.zig:8`-`:12` 的模块文档**明确禁止**这种做法
（`formatQuery` 让 `&`/`=`/`?`/`/`/`:` 原样通过、空格编码为 `%20`，
值里的 `&`/`=` 会被服务端当成参数分隔符 → 参数被截断）。
公众号侧的同名接口（`src/officialaccount/ocr/mod.zig:126`）已改用
`util_uri.queryEscape`，**小程序侧尚未对齐**。

**影响**
- 修复成本高、回归面广：任一处的转义漏掉控制字符或 `"` 就会产生非法 JSON
  （历史上 `tcb` 的数据库 query、`msg_sec_check` 的 content 就因此出过非法请求体）。
- 而 `std.json` 侧的宽容解析（见第 2 条）让"请求发错"与"响应读错"两个方向
  都容易被静默掩盖。

**已知的硬约束（不要再踩）**
`std.Uri.Component.formatQuery()` **不能**替代 Go 的 `url.QueryEscape`：
它的保留字符集允许 `&` `=` `?` `/` `:` `+` `*` `!` `'` `(` `)` 原样通过，
且空格编码为 `%20`；而 Go 语义只保留 `[0-9A-Za-z-_.~]`。
依据：`src/util/uri.zig:8`-`:12`（模块文档）、
`src/openplatform/context/auth.zig:194`（调用点注释）。
**任何新增的 query 参数拼接都必须走 `util.uri.queryEscape`。**

**缓解**
- 新增请求体一律优先用 `std.json.Stringify` 序列化结构体。
- 必须手写时：
  - 单字段对象用 `util.json.stringFieldObject(allocator, field, value)`；
  - 只要转义后的字符串用 `util.json.appendEscapedString` / `stringLiteral`；
  - **不要**再复制第 N 份 `appendJsonString`（旧副本漏控制字符转义）。
- 含用户自由文本的字段**一律禁止** `allocPrint` 裸插值。
- 每个编码点配套一个"转义正确性"测试（现有先例：
  `src/util/uri.zig:43` 起的多个用例、`src/officialaccount/ocr/mod.zig:176` 的
  `"queryEscape 与 Go url.QueryEscape 对齐"`、`src/work/oauth/mod.zig:460` 的
  `"queryEscape 符合 Go QueryEscape 语义"`）。

**触发再评估的条件**
1. 把余下的内联 `appendJsonString` 与约 33 处裸插值全部迁移到 `util/json.zig`
   （纯内部重构，不构成公开 API 变更，`0.x` 期间可随时做）——
   **收敛完成的判据**：`grep -rn "^fn appendJsonString\|^    fn appendJsonString" src/`
   再无输出；
2. 修正 `src/miniprogram/ocr/mod.zig:172` 的 `formatQuery` 用法；
3. 或出现新的"非法请求体"事故时按事故驱动收敛。

---

## 10. 附：仓库内文档与源码/测试数不同步（超出题面枚举的额外观察）

**决策（现状）**
文档更新与代码节奏未完全对齐，属于**已知的文档债**。

**影响**
- ~~`README.md:10` 与 `README.md:49` 写"**357** 个内联测试"~~ →
  **已在 v0.4.5 修正为 1004**；此后以实际 `zig build test` 输出与 CHANGELOG 为准。
- `docs/api-reference.md` 部分章节早于 v0.4.4：
  例如 §5.6 的 `officialaccount/material` 只列了 4 个方法
  （`addNews`/`deleteMaterial`/`getMaterialCount`/`batchGetMaterial`），
  未含 v0.4.4 新增的 `getMedia`/`getMediaWithLimit`/`getMediaToFile*`
  与 `AddVideo`/`AddMaterial`；§7 的小程序段落也未列出 24 个子模块的全貌。
  **需要精确签名时以源码为准**（本文与 [`UPGRADING.md`](UPGRADING.md) 都按此口径标注）。
- ~~工具链版本记录也不完全一致：CI 钉的是 `0.17.0-dev.1567+f0354179a`~~
  → **已在 v0.4.5 统一为 `0.17.0-dev.2151+2ec5523d5`**（旧版缺 `Type.Struct.field_names` 等，实际编译不过）。

**缓解**
- 下游按"源码 > CHANGELOG > `doc/api_guide.md` > `docs/api-reference.md` > README"的
  优先级判断事实。
- 本次新增的 [`UPGRADING.md`](UPGRADING.md) 每条变更都带 `src/...:行号`，
  就是为了绕过这批文档债。

**触发再评估的条件**
`docs/api-reference.md` 完成一轮与最新源码的对齐（届时本条可删除）。

---

## 11. 测试套件在极端并发负载下偶发失败（端口探测与绑定的 TOCTOU）

**决策（现状）**
`src/cache/redis.zig` 与 `src/cache/memcache.zig` 的 mock server 测试用
`findFreePort()`：先随机取端口 `listen` 探测、**关闭**、再把端口交给 mock server 绑定。
探测与真正绑定之间存在窗口，机器上其它进程（或另一个同时在跑的测试进程）若恰好抢占该端口，
mock server 绑定失败 → 测试失败。（`findFreePort` 的 20 次重试只覆盖探测阶段的冲突。）

**影响**
- 在「同一仓库并行跑多个测试进程」或机器负载很高时偶发：本会话实测约 2 次 / 20 次运行。
- 串行运行（CI 的正常形态）10 次连续全绿，**不影响 CI 稳定性**；属测试基础设施脆弱性，
  不是产品代码缺陷。
- v0.4.5 已先消除同一用例里的**时序**脆弱性（`pool_timeout_ms=150` 用例放大 holder 命令耗时与断言余量）。

**缓解**
- 复跑即可（失败信息会指向 redis/memcache 的 mock server 绑定）。
- 彻底修法：把**已绑定的 listener** 直接交给 mock server（不再释放端口），
  或让 mock server 在 `AddressInUse` 时自行换端口重试。

**触发再评估的条件**
出现一次非并发场景下的重复失败（说明不只是 TOCTOU），或 CI 开始并行跑测试进程。

---

## 12. mTLS（微信支付 v2 客户端证书）改用运行时 dlopen，构建默认零依赖

**决策**
仓库内不再依赖第三方 Zig 包 `httpz`（zhttp）——它只为微信支付 v2 的 mTLS 服务，
却把 OpenSSL + libc 链接到**所有**构建目标（lib / exe / test / bench / examples），
让每个消费者都背 C 依赖。改为：

- 新增 `src/util/mtls.zig`：**运行时**用 `std.DynLib` 加载 `libssl` / `libcrypto`，
  **手写 extern 函数指针**（不需要头文件 / `translateC` / `linkSystemLibrary`）；
- 由构建选项 **`-Dmtls`（默认 `false`）** 门控：默认构建**零 Zig 包依赖、零 C 依赖**
  （不链 OpenSSL、不链 libc、构建期不联网取依赖）；
- 关闭时 `util.http.postXMLWithTLS` 返回 `error.MtlsNotEnabled`。

**影响**
- 默认（`-Dmtls=false`）下**没有** mTLS 能力：微信支付 v2 中 `root_ca` 非空
  （退款 / 转账 / 现金红包）的路径不可用，报 `error.MtlsNotEnabled`；
  未配 `root_ca` 的路径仍走普通 HTTPS，不受影响。**这是破坏性变更**。
- 开启（`-Dmtls=true`）后仍**不需要构建期头文件**，但**运行时要能加载到
  `libssl` / `libcrypto` 动态库**；缺失时错误边界是 `error.OpenSslNotAvailable`。
- 失败模式是**运行期**而非编译期（`dlopen` 在首次调用时发生），拿不到库/符号
  只会在第一次 `postXMLWithTLS` 时暴露——部署前必须自测。
- 自建 OpenSSL 桥是**安全敏感面**：手写 extern 一旦少校验一步（SNI、证书链、
  TLS 版本），可能静默降级到不安全的连接。

**缓解（自建桥的硬边界）**
- **边界刻意收窄**：`mtls.zig` 只做**一条窄路径**——POST XML + 客户端证书，
  不实现通用 TLS 客户端（因此不需要 HTTP/2、重定向、连接池等）。
- **强制校验 `SSL_get_verify_result`**：握手后必须确认返回 `X509_V_OK`，
  否则拒绝继续，避免"连上了但证书链没验"的静默信任。
- **TLS 1.2 下限**：通过 `SSL_CTX_ctrl(123)`（`SSL_CTRL_SET_MIN_PROTO_VERSION`）设置，
  不接受更老协议。
- **设置 SNI**：通过 `SSL_ctrl(55)`（`SSL_CTRL_SET_TLSEXT_HOSTNAME`）设置——
  宏在 Zig extern 桥里不可用，必须走 ctrl 变体。
- **不复用会话**：每次请求新建 SSL 上下文 / 连接，不复用会话票据。
- 需要 mTLS 的下游也可评估**迁移到 v3**：v3 的退款 / 转账用 RSA 签名 + 普通
  HTTPS，根本不需要客户端证书（见「触发再评估」）。

**代码位置**
- `src/util/mtls.zig`（自建 OpenSSL 桥：`std.DynLib` + 手写 extern）；
- `src/util/http.zig`（`postXMLWithTLS`：`-Dmtls` 关闭时返回 `error.MtlsNotEnabled`）；
- `build.zig`（`-Dmtls` 选项与链接开关）；
- v3 替代路径：`src/pay/v3/refund.zig`、`src/pay/v3/transfer.zig`。

**触发再评估的条件**
- 只有 **v2 现金红包**（`src/pay/redpacket`）仍无 v3 等价物、刚需 mTLS；
  若微信下线 v2 接口，可整体删除 `mtls.zig` 与 `-Dmtls`；
- 上游出现可直接依赖、且**不污染所有构建目标**的 mTLS 库时，可评估换回依赖；
- `dlopen` 方案在目标平台（静态链接 / musl / 受限容器）上无法加载动态库时，
  需为该平台提供静态链接变体。

---

## 13. `zig build test` 打印 `failed command: …--listen=-`（**根因已查明：工具链展示口径**）

**决策（现状）**
**已定性为 Zig 0.17-dev 构建运行器的展示问题，与本仓代码无关**；按 CI 判据（退出码）无影响，不修。

**根因（读工具链源码 + 实测，已独立复核）**
`lib/compiler/Maker.zig:2698-2702`：

```zig
// No matter the result, we want to display error/warning messages.
if (make_step.result_error_bundle.errorMessageCount() > 0 or
    make_step.result_error_msgs.items.len > 0 or
    make_step.result_stderr.len > 0)
{
    ... printErrorMessages(maker, step_index, ...);
}
```

即：**只要某步骤产生了任何 stderr（哪怕该步骤完全成功），就调用 `printErrorMessages`**；
而该函数在 verbose 上下文里会**无条件**打印 `failed command: <argv>`（同文件 `:3198`）。
本仓的测试二进制会向 stderr 写**约 102 KB**（test runner 的告警 + 各超时/连接池用例的 `std.log.warn`），
因此每次真正执行测试步骤都会看到那一行。

**支持该结论的实测（可复核）**
1. 步骤**缓存命中**（没有 spawn 子进程）时该行**不出现**；
2. 直接执行测试二进制：stdout 0 字节、stderr 约 102 KB；
3. 天然对照组 `zig build live-probe-test`（8 个用例、不写 stderr）**不出现**该行；
4. 汇总始终是 `N/N tests passed` + `test success`，`zig build test` 退出码 0。

**曾被怀疑但已排除的原因**
- ~~"测试进程以非零码退出/崩溃"~~：lldb 附加实测 `exited with status = 0`，`abort`/`debug.defaultPanic`/SIGABRT 断点均未命中；早前记录过的 `test-*.ips` SIGABRT 属更早阶段的现象，现已不复现。
- ~~"多个测试进程/构建系统重试"~~：`--verbose` 实测一次构建只 spawn 一次；构建系统对 run 步骤无重试机制。
- ~~"陈旧缓存 / 日志噪声 / fuzz 用例"~~：干净缓存副本、把 `std.log.warn` 降为 `debug`、最小项目（含 fuzz 用例）逐一排除。
- ~~"库代码与 test runner 共用 `Io.Threaded.global_single_threaded`（非线程安全）"~~：**2026-09 按此假设做了实测**——把全仓 59 处默认 io 换成本仓私有的进程级单例后，该行**仍然每次出现（10/10）**，假设被证伪。

**顺带的实际收益（虽不修 #13，但值得保留）**
前述 Io 私有化改动本身是一处**合理加固**：`std.Io.Threaded.global_single_threaded` 与 `std.Options.debug_io` 的默认值指向**同一个非线程安全实例**，而 test runner 用它承载 stdio 协议；库代码不再共用它，可降低"库与运行器互相干扰"的隐患。见 `src/util/default_io.zig`（文件头写明了动机、与本条的关系，以及"不要把 #13 当作本文件的修复目标"）。

**影响**
- CI 按退出码判定 → 不受影响；本地看到该行时按 `--summary all` 的 `N/N tests passed` 与 `test success` 判断真结论。
- 唯一实质影响：日志噪声 + 容易被误读为"测试失败"。

**缓解**
- 需要干净输出时直接运行测试二进制：`BIN=$(ls -t .zig-cache/o/*/test | head -1) && "$BIN"`。
- 若将来希望彻底没有这行：让测试步骤**不写 stderr**（本仓测试刻意走 `std.log.warn` 超时路径，且 test runner 强制 `testing.log_level = .warn`，库侧没有干净的抑制手段）；或等上游调整该打印口径。

**触发再评估的条件**
Zig 工具链升级后；或该行**伴随** `zig build test` 退出码非 0（那才代表真实失败）。

## 14. Io 注入尚未全量覆盖 + 读超时是 opt-in

**决策（现状）**
库代码的 Io 来源已从"直接取全局单例"改为**可注入字段 + `*WithIo` 变体**，但**尚未全量覆盖**，且网络超时默认关闭。

**影响**
- 生产代码**已全部迁完**（`getCurrTS()` / `randomStr()` / `std.Options.debug_io` 仅剩测试块内使用），
  因此"把本库嵌入自定义 Io 宿主"已不再被取时/取随机挡住；剩下的边界见下。
- 网络超时仍是 **opt-in**：`Options.recv_timeout_ms`（单次读取）与 `Options.connect_timeout_ms`（TCP 握手）
  **默认都是 0 = 不超时**，即默认配置下"服务端半死/黑洞"仍会阻塞到内核上限。

**缓解**
- 新代码一律用注入的 `io` 字段或 `*WithIo` 变体；迁移清单见 `AGENTS.md`「移植备注 · Io 注入惯例」。
- 需要"客户端超时兜底"的场景显式设 `recv_timeout_ms` 与 `connect_timeout_ms`（超时会丢弃连接、不建连、不进池，避免协议失步）。

**触发再评估的条件**
需要把本库嵌入 evented/协程运行时；或因"服务端半死"出现过线上挂起事故。

---

---

## 复核方法

本文所有位置均可就地验证，例如：

```bash
# msgaudit 只有两个 pub 方法（确认无 getChatInfo）
grep -n "pub fn " src/work/msgaudit/mod.zig

# 媒体下载上限常数
grep -n "^pub const max_" src/officialaccount/material/mod.zig src/work/material/mod.zig

# getMediaList 已删除（期望：无匹配）
grep -rn "getMediaList" src/

# 单连接串行化
grep -n "SpinMutex\|mutex.lock" src/cache/redis.zig src/cache/memcache.zig

# 依赖懒路径的 8 个测试 + util/http 自身回归测试
grep -rn "getDefaultClient(std.heap.page_allocator)" src/

# 手写编码点现状
# (a) URL 转义已收敛到唯一实现，业务侧只剩别名：
grep -rn "util_uri.queryEscape" src/
# (b) JSON 转义的收敛进度（“还有输出”= 仍有模块内联旧实现，漏 \u00xx 控制字符转义）
grep -rn "^fn appendJsonString\|^    fn appendJsonString" src/
grep -rn "util_json.appendEscapedString" src/
#     新 helper 是否已被业务接入：
grep -rn "stringFieldObject\|stringLiteral" src/
# (c) 仍有约 33 处 allocPrint 裸插值拼 JSON：
grep -rn 'allocPrint' src/ --include=*.zig | grep '\\"' | wc -l
# (d) 小程序 OCR 仍用被明令禁止的 formatQuery：
grep -rn "formatQuery" src/

# 宽容解析现状
grep -rc "ignore_unknown_fields" src/ --include=*.zig | awk -F: '{s+=$2} END {print s}'
grep -rn "parseFromSlice" src/ --include=*.zig | wc -l

# 文档与源码/测试数不同步
grep -n "个内联测试\|个单元测试" README.md
grep -n "ZIG_VERSION=" .github/workflows/ci.yml
grep -n "0.17.0-dev" AGENTS.md | head -3

# 零依赖 / mTLS（第 12 条）
#   build.zig.zon 不再有 httpz 依赖（期望：无输出）
grep -n "httpz\|zhttp" build.zig.zon
#   mtls 开关与自建桥
grep -rn "mtls" build.zig
ls src/util/mtls.zig
#   默认产物未链接 OpenSSL（CI 回归检查同款）：
#   macOS: otool -L zig-out/bin/zwechat | grep -i ssl   （期望：无输出）
#   Linux: ldd zig-out/lib/libzwechat.a 2>/dev/null; ldd zig-out/bin/zwechat | grep -i ssl
```

---

## 相关文档

| 想知道什么 | 去哪 |
|---|---|
| 升级要改哪几行、每条变更的 before/after | [`UPGRADING.md`](UPGRADING.md) |
| 版本演进完整叙述 | [`../CHANGELOG.md`](../CHANGELOG.md) |
| 使用指南（含常见坑） | [`../doc/api_guide.md`](../doc/api_guide.md) |
| 架构与内存所有权约定 | [`architecture.md`](architecture.md) |
| 维护者决策记录（并发模型、解析契约等） | [`../AGENTS.md`](../AGENTS.md)「移植备注」 |
