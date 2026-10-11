# 架构与设计模式

`zwechat` 的目标是把 Go 的 [silenceper/wechat](https://github.com/silenceper/wechat) v2 SDK **完整** 移植到 Zig，同时充分利用 Zig 的语言特性（显式 Allocator、vtable、comptime、errdefer）让代码更安全、更高效。

本文说明核心架构决策与可复用的设计模式。

---

## 1. 顶层依赖图

```
                            ┌─────────────────────────────────┐
                            │  src/wechat.zig  (顶层容器)     │
                            │  + src/root.zig   (barrel)      │
                            └────────────┬────────────────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              │                          │                          │
        ┌─────▼──────┐          ┌────────▼─────────┐         ┌───────▼───────┐
        │ official-  │          │  work            │         │  openplatform │
        │ account    │          │  (企业微信)       │         │  开放平台     │
        │ 公众号     │          │                  │         │               │
        └─────┬──────┘          └────────┬─────────┘         └───────┬───────┘
              │                          │                          │
              │   ┌───────────────┐      │                          │
              └──►│  miniprogram  │◄─────┴──────────────────────────┘
              │   │  小程序       │
              │   └───────────────┘
              │   ┌───────────────┐
              └──►│  minigame     │     ┌─────────────────────────────┐
              │   │  小游戏       │     │  pay  (微信支付)             │
              │   └───────────────┘     │  - order/refund/notify      │
              │   ┌───────────────┐     │    /transfer/redpacket      │
              └──►│  aispeech     │     └─────────────────────────────┘
                  │  智能对话     │
                  └───────────────┘
                            │
                            ▼
        ┌──────────────────────────────────────────────┐
        │  credential  (AccessToken / JsTicket)        │
        │  cache       (Memory/Redis/Memcache)         │
        │  util        (http / crypto / sig / xml / …) │
        └──────────────────────────────────────────────┘
```

### 依赖规则

1. **底层 → 顶层**：只允许从 `credential` / `cache` / `util` 向上注入；业务模块横向**不**互相依赖。
2. **`test_runner.zig` 编译门**：每个新模块必须在 `src/test_runner.zig` 的 `@import` 列表中追加一行，并在编译门测试里加一句 `std.testing.refAllDecls(mod);`。否则 dead-strip 会把 inline test 排除掉，`zig build test` 报「假」成功（详见 §6.3）。

除图中的五大业务域外，`src/` 还包含：`middleware`（对 `zfinal` / `zigmodu` 的回调中间件，位于最上层、只依赖 `officialaccount` / `work` 的校验与解密能力）、`pay/v3`（RSA 签名的 v3 支付，无 mTLS 依赖）、`minigame`、`aispeech`、`util/mtls.zig`（`-Dmtls` 门控的 OpenSSL 桥）与 `test/error_set_snapshot.zig`（公开错误集门禁）。

---

## 2. 核心抽象模式

### 2.1 vtable 风格的接口（替代 Go interface）

Go 的 `interface{}` 在 Zig 中通过 *函数指针 + 不透明 ctx* 实现：

```zig
// cache/mod.zig
pub const Cache = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ctx: *anyopaque, key: []const u8) CacheError!?[]const u8,
        set: *const fn (ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void,
        isExist: *const fn (ctx: *anyopaque, key: []const u8) CacheError!bool,
        delete: *const fn (ctx: *anyopaque, key: []const u8) CacheError!void,
        deinit: *const fn (ctx: *anyopaque) void,
        /// 可选槽位（默认 null）：返回调用方拥有的副本，见 §2.7。
        getOwned: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) CacheError!?[]u8 = null,
    };
};
```

调用方只需要拿一个 `Cache` 值，通过 vtable 间接调用。`Memory` 是具体实现，测试里可以用自定义桩（stub）替换。

**好处**：
- ✅ 与 std.Io / std.Build 风格一致
- ✅ 无类型擦除，comptime 时已知具体类型
- ✅ 无堆分配（vtable 是静态 const）

**坏处**：
- ⚠️ 写起来繁琐（每个具体实现都要写 5 个必填 vtable 函数；`getOwned` 是可选的第 6 个）

### 2.2 显式 Allocator 传递

所有公开 API 接收 `std.mem.Allocator`：

```zig
pub fn getAccessToken(self: *Work, allocator: std.mem.Allocator) ![]u8 {
    // ...
}
```

**对照 Go**：

```go
// Go：context.Background() + 全局 alloc + 隐式 GC
func (w *Work) GetAccessToken() (string, error)
```

**区别**：
- ✅ 调用方控制分配器（可换 `ArenaAllocator` / `GeneralPurposeAllocator` 做 leak 检测）
- ✅ 错误路径上 `errdefer` 立即释放资源
- ⚠️ 每个函数签名变长；调用方需要保证 Allocator 生命周期正确

### 2.3 `errdefer` 链：构造时清理

```zig
pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Self {
    var cache = try Cache.init(allocator);
    errdefer cache.deinit();

    var cred = try Credential.init(allocator);
    errdefer cred.deinit();

    return Self{ .cache = cache, .cred = cred };
    // 若 `return` 失败，两次 errdefer 都自动触发。
}
```

**对照 Go**：defer + 双检锁需要写"先 check，再 lock，再 check"；Zig 的 errdefer 把这条流水线折叠成 1 行。

### 2.4 `Fetcher` 函数指针（HTTP 注入）

为了单元测试不发起真实 HTTP，每个可能产生外部请求的模块都接受一个 fetcher 函数指针：

```zig
// credential/default_access_token.zig
pub const Fetcher = *const fn (
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    url: []const u8,
) CredentialError![]u8;

pub const DefaultAccessToken = struct {
    fetcher: Fetcher,
    fetcher_ctx: *anyopaque,
    // ...
};

// 测试时：
const stub = struct {
    fn fetch(ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8) CredentialError![]u8 {
        const self: *StubCtx = @ptrCast(@alignCast(ctx));
        return alloc.dupe(u8, self.response_body);
    }
};
dat.fetcher = stub.fetch;
dat.fetcher_ctx = @ptrCast(&stub_ctx);
```

**好处**：不引入 `interface`，类型推导完全 comptime 完成。

### 2.5 Transport 抽象（HTTP 层）

`util/http.zig` 的 `HttpClient.transport` 字段允许运行时替换：

```zig
pub const HttpClient = struct {
    inner: std.http.Client,
    transport: ?Transport = null,
    transport_ctx: ?*anyopaque = null,

    pub const Transport = *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8;

    pub fn setTransport(self: *HttpClient, t: ?Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }
};
```

测试：

```zig
var mock = MockTransport.init(allocator);
defer mock.deinit();
try mock.addRoute("https://example.com/api", .{ .body = "{\"ok\":true}" });

var client = HttpClient.init(allocator);
defer client.deinit();
client.setTransport(MockTransport.dispatch, @ptrCast(&mock));

const resp = try client.get("https://example.com/api");
// 真实 std.http.Client 完全没被调用
```

### 2.6 `std.Io.Mutex` 代替已移除的 `std.Thread.Mutex`

Zig 0.17 移除了 `std.Thread.Mutex`。本仓统一改用 **`std.Io.Mutex`**：它是 `extern struct`，可静态初始化（`.init`）并**直接内嵌为结构体字段**，只有 `lock` / `unlock` 需要传入 `io`；底层走 futex（Linux `futex(2)`、macOS `__ulock_wait2`、Windows `RtlOnAddress`），**长临界区里等待者睡眠而不是空转**：

```zig
const std = @import("std");
const default_io = @import("../util/default_io.zig");

pub const Foo = struct {
    /// 可注入的 Io（默认进程级单例，见 `util/default_io.zig`）。
    io: std.Io = default_io.io(),
    /// 静态初始化，直接内嵌。
    mutex: std.Io.Mutex = .init,

    pub fn doWork(self: *Foo) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // ... 临界区 ...
    }
};
```

**约定**：结构体持有一个可注入的 `io: std.Io` 字段（默认 `default_io.io()`），临界区写成
`self.mutex.lockUncancelable(self.io); defer self.mutex.unlock(self.io);`。**新代码一律如此**。

`util/sync.zig` 的 `SpinMutex` 保留为**兼容层**（零参数 `lock()` / `unlock()` / `tryLock()` 语义不变，内部走 `lockUncancelable`），仅供尚未迁移的历史调用点使用；本仓已不再有任何真正的自旋锁。

**已知的长临界区是刻意为之**：Memcache 单连接模式的 `get` 跨整个 RTT（一条连接必须串行化）、credential 在锁内做缓存双检 + 回写、openplatform 在锁内串行化 authorizer 刷新（防 `refresh_token` 轮换被并发覆盖）。

### 2.7 Cache 后端、所有权与连接池

`Cache` 接口除 `get` / `set` / `isExist` / `delete` / `deinit` 外，另有一个**可选** vtable 槽位 `getOwned`（默认 `null`）：

- `get(key)` 返回**借用**切片，有效期只到本实例下一次写操作；Memcache / Redis 复用内部 `last_value` 缓冲区，**任何后续 `get` 都会让它立即悬垂**。跨写持有必须 `dupe`。
- `getOwned(allocator, key)` 返回**调用方拥有**的副本（记得 `free`）。拷贝由后端在**自己的临界区**内完成（Memory 的互斥区、Redis / Memcache 的独占借出连接期间），因此**多处共享同一 `Cache` 实例并发写同一 key 时依然安全**——这正是 credential 各获取器统一改走 `getOwned` 的原因。自定义实现不写该槽位即可继续编译（退化为 `get` + `dupe`）。

内置实现：`cache.Memory`（进程内、线程安全、TTL + 懒删除）、`cache.Redis`、`cache.Memcache`。后两者是单连接客户端，均支持**可选连接池**：`Options.max_connections`（默认 `1` = 历史单连接语义）与 `pool_timeout_ms`（默认 30s，等待有界，超时返回 `error.PoolTimeout` 并在 vtable 边界映射为 `CacheError.StorageError`）。坏连接（协议 / IO 错）**丢弃不进池**，池锁只护空闲表、网络 I/O 全在锁外。运行状况用 `redis.poolStats()` / `memcache.poolStats()` 观测（`live` / `idle` / `in_use` / `peak_in_use` / `created` / `discarded` / `timeouts`；单连接模式无池，恒返回全零）。

> 早期版本（无 `getOwned`）曾把"先 `get` 再 `dupe`"作为缓解，但那在共享 `Cache` 并发写同一 key 时是读已释放内存；`getOwned` 落地后 credential 各获取器已不再走该窗口。

---

## 3. 错误处理约定

### 3.1 窄错误集 + `||` 组合

```zig
pub const CacheError = error{
    NotFound,
    TypeMismatch,
    StorageError,
    OutOfMemory,
};

pub const CredentialError = std.json.Error ||
    std.mem.Allocator.Error ||
    CacheError ||
    error{
        ApiError,
        HttpError,
        DecodeError,
        ConfigMissing,
    };
```

**对照 Go**：Go 的 `error` 是 interface，无法静态保证涵盖所有错误变体；Zig 的 `error set` 在编译期就能检查 switch 的穷尽性。

### 3.2 业务错误透传到 HTTP 响应

```zig
// 任何 HTTP 接口都遵循这个模式：
const body = try client.postJSON(uri, request_body);
defer allocator.free(body);

if (try util_error.decodeWithCommonError(allocator, body, "API_NAME")) |ce| {
    std.debug.print("API_NAME 失败: {s}\n", .{ce.errmsg});
    return WechatError.ApiError;
}
```

### 3.3 凭据错误

| 错误变体 | 何时返回 |
|---|---|
| `ApiError` | 微信返回 `errcode != 0` |
| `HttpError` | 网络 / HTTP 层失败（来自 fetcher）|
| `DecodeError` | JSON / XML 解析失败 |
| `ConfigMissing` | 必需字段缺失（如 WorkAccessToken 无 corp_id）|

---

## 4. 内存所有权约定

| 返回类型 | 所有权 |
|---|---|
| `[]u8` | 调用方 `free` |
| `[]const u8` (静态字符串) | 借用，不可 free |
| `[]const u8` (运行时生成) | 调用方 `free` |
| `?[]const u8` (cache `get`) | 借用自 cache 内部，有效期至该实例下一次写操作（Memcache / Redis 后端任何后续 `get` 即失效）|
| `?[]u8` (cache `getOwned`) | **调用方拥有**，由传入的 allocator 分配，须 `free` |
| `std.json.Parsed(T)` | 持有自己的 arena；读字段走 `.value`，用完必须 `.deinit()` |
| `struct { ... }` (POD) | 值类型，调用方持有副本 |
| `*T` (指针) | 借用于父对象；父对象 deinit 前不要缓存 |
| `*OfficialAccount` / 子模块 | 地址必须稳定：`getXxx()` 派生的子模块持有 `&self.ctx` 裸指针，派发后**不可再拷贝 / 移动**父对象 |

每个 public API 的 doc 注释必须明确说明所有权归属。

---

## 5. XML codec 设计

微信消息的 XML 是单层结构：

```xml
<xml>
    <ToUserName><![CDATA[gh_abc]]></ToUserName>
    <FromUserName><![CDATA[user_123]]></FromUserName>
    <Content><![CDATA[hello]]></Content>
</xml>
```

`util/xml.zig` 用扁平 `[]XmlElement` 表示，避免了完整 DOM 解析：

```zig
pub const XmlDoc = struct {
    root_name: []const u8,
    elements: []XmlElement,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *XmlDoc) void;
    pub fn get(self: XmlDoc, key: []const u8) ?[]const u8;
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{MalformedXml})!XmlDoc;
pub fn serialize(allocator: std.mem.Allocator, root_name: []const u8, elements: []const XmlElement) std.mem.Allocator.Error![]u8;
```

**取舍**：
- ✅ 200 行实现，覆盖 99% 微信场景
- ✅ 内存占用小，无需树形结构
- ❌ 不支持嵌套 / 命名空间 / 处理指令（微信消息用不到）

---

## 6. 测试基础设施

### 6.1 MockTransport 模式

所有 HTTP 调用通过 `util.http.HttpClient` 发起 → 可注入 transport（业务模块如 `Menu` / `Order` 另有自己的 `setTransport`，注入在实例上）：

```zig
pub const MockTransport = struct {
    routes: std.HashMap([]const u8, Response, ...),
    history: std.ArrayList([]const u8),   // 每次调用的 URI，按序
    payloads: std.ArrayList([]const u8),  // 每次调用的请求体（GET 为空串）

    pub fn dispatch(ctx: *anyopaque, alloc, uri, method, payload, ct) anyerror![]u8;
    pub fn payloadAt(self: *const MockTransport, idx: usize) []const u8;
};
```

**测试好处**：CI 不依赖网络；可在 1 秒内跑完整集成测试。**多次调用同一个 capture transport 时**，务必在下一轮前释放上一轮留给你的 `uri` / `payload`（参考 `src/miniprogram/order/mod.zig` 的 `CapturingTransport.reset`），否则 `std.testing.allocator` 会报泄漏。

### 6.2 真实测试向量

涉及加密 / 签名 / 编解码的模块，附真实 RFC / 文档示例：

- `util/crypto.zig`：MD5("hello") = `5d41402abc4b2a76b9719d911017c592`
- `util/signature.zig`：SHA1 排序后的预期 hex（Python `hashlib.sha1` 计算）
- `util/rsa.zig`：RSA-SHA256 PKCS#1 v1.5（OpenSSL 生成的 1024-bit 测试向量）+ **RFC 8032 §7.1 Test 1**（Ed25519 完整公开示例）
- `pay/notify.zig`：微信支付文档示例参数 + 文档示例签名

### 6.2b Fuzz 目标（8 个）

`zig build test --fuzz=<N>`（`N` 是**迭代预算**，不是秒数）跑 Smith 变异；普通 `zig build test` 下只做零输入冒烟 + **语料回归**（不拖慢 CI）。现有 8 个目标：`util/{xml,asn1,pkcs12,json,uri,crypto,rsa_impl}.zig` 与 `pay/v3/notify.zig` 各一个（后者覆盖攻击者可控的 base64 + AES-GCM 回调密文）。fuzz 已发现 3 个真实缺陷（`queryEscape` 预留容量不足导致 ReleaseFast 堆溢出、`xml.parse` 接受空标签名、`json.appendEscapedString` 对非法 UTF-8 产出非法 JSON），**新增解析器 / 转义器 / 任何解析网络输入的代码时都应补一个 fuzz 用例**。

### 6.3 编译门（声明级）

`src/test_runner.zig` 用一个测试引用每个文件的**全部顶层声明**：

```zig
const cache_mod = @import("cache/mod.zig");
// ... 全部模块（119 个 @import）

test "test_runner 编译门 — 强制所有模块被解析 (v2)" {
    std.testing.refAllDecls(cache_mod);
    // ... 每个模块一行
}
```

**为什么需要**：Zig 的 dead-strip 会把未经使用的 `@import` 排除掉，导致 inline test 不被发现（历史上曾假报「All 1 tests passed」）。`refAllDecls` 把语义分析的粒度从「文件级可达」提升到「声明级可达」——从未被测试触达的代码同样会被编译（首次启用就暴露了 `util/crypto.pkcs5Pad` 的错误集不一致）。注意 `refAllDecls` **不实例化泛型**，所以「泛型参数位错位」仍必须靠真实调用测试兜底（仓库纪律：每个模块至少一个走 mock transport 的真实调用测试）。

### 6.4 公开错误集快照门禁

`src/test/error_set_snapshot.zig`（已接进编译门）把 **19 个**公开错误集的成员名快照成常量数组，用 `@typeInfo(E).error_set` 逐项对账（集合语义，顺序无关）。覆盖 `WechatError` / `CredentialError` / `pay.v3.NotifyError` / `rsa_impl.Error` / `CacheError` / `rsa.{RsaError,P12Error,Ed25519Error}` / `asn1.Error` / `pkcs12.Error` / `mtls.NotEnabledError` / openplatform 的 `access_token` `auth` `basic` `component` 四个 `Error`，以及 `wechat.zig` 的 4 个工厂错误集。

**意义**：错误集是结构化类型，下游对它做穷尽 `switch` 时，上游增删一个变体就会让对方编译失败——所以这层公开面**必须显式管理**。增删公开错误集成员会让本门禁变红（设计意图）；新增公开错误集时请一并补进快照。

### 6.5 API 面门禁与真实探针

- `tools/api_surface_check.sh`（快照生成器 `tools/api_surface.zig`，基于 `std.zig.Ast`；快照 `api/surface.txt`）为每个 `pub` 符号生成一行，另含一行 `sig`（参数类型 + 返回类型）——**改签名 / 返回类型也会触发门禁**。删除 / 改名公开符号必须在 `CHANGELOG.md` 最新段落或 `[Unreleased]` 里写明（`容器.旧名` 形式，只写裸叶名不认），否则 CI 失败；`--update` 刷新快照。
- `zig build live-probe`（env `ZWECHAT_LIVE_PROBE=1` + 各域凭据，默认不联网；`-Dstrict` 才以 FAIL 退非零）用于发现"上游改了字段名"这类 mock 测不出的漂移。

### 6.6 CI 覆盖面

`.github/workflows/ci.yml` 现在跑：**四种优化模式**（Debug + ReleaseSafe / ReleaseFast / ReleaseSmall；ReleaseFast 下 `page_allocator.ptr == null`、`@intFromPtr(&局部变量)` 会折叠，指针同一性断言必须改写）、`zig build fmt` 检查、API 面门禁，以及三个**独立 root module** 的辅助目标 `live-probe-test` / `bench` / `live-probe`（无凭据时 `live-probe` 打印说明并 exit 0）。

---

## 7. 性能特性

| 维度 | 表现 |
|---|---|
| 编译产物 | 单个静态可执行，无 libc 依赖（zig default target） |
| 运行时 | 零分配（除显式 `alloc` 调用外） |
| 内存占用 | 单 OfficialAccount 实例 ~1KB |
| HTTP 客户端 | 走 `std.http.Client`（libxev / io_uring / kqueue）；默认 connect 10s / read 30s 超时，响应体默认上限 16 MiB |
| 加密原语 | AES-256-CBC / MD5 / HMAC-SHA256 / **RSA-SHA256 PKCS#1 v1.5（纯 Zig，支持 PKCS#1/PKCS#8 私钥、CRT 签名、RSAES-PKCS1-v1_5 解密）** / **PKCS#12（PBES2/PBKDF2/AES-256-CBC）** / Ed25519（Zig stdlib 原生） |
| 并发 | `std.Io.Mutex`（futex）+ `std.Io` runtime（`SpinMutex` 仅兼容层） |

**生产环境建议**：
- 长时间运行的服务：用 `std.heap.GeneralPurposeAllocator` 检测泄漏。
- 请求级别：用 `ArenaAllocator` 在请求作用域内分配，结束时一次性 free。
- 大批量处理：用线程池 + `std.atomic.Value` 做无锁队列。

---

## 8. 与 Zig 标准库的集成

| stdlib 用法 | 项目中位置 |
|---|---|
| `std.Io.Clock.now(.real, io)`（`io` 由 `util/default_io.zig` 提供） | `util/time.zig` 的 `getCurrTSWithIo` |
| `std.Io.Mutex`（futex，静态初始化 + 内嵌字段） | `cache/*`、`credential/*`、`officialaccount/{material,server}`、`work/material`、`pay/v3/order` |
| `std.Io.net` / `net.HostName.lookup`（DNS，注意不是 `IpAddress.resolve`） | `cache/{redis,memcache,net}.zig` |
| `std.http.Client` + `HeaderTransport` | `util/http.zig` |
| `std.json.parseFromSlice(... .{ .ignore_unknown_fields = true })` | 几乎所有 HTTP 响应解析 |
| `std.crypto.sign.Ed25519` | `util/rsa.zig` |
| `std.crypto.core.aes.Aes256` | `util/crypto.zig`, `util/pkcs12.zig` |
| `std.crypto.pwhash.pbkdf2` | `util/pkcs12.zig` |
| `std.crypto.timing_safe.eql`（定长）/ `util/crypto.timingSafeEqlSlices`（切片） | `util/crypto.zig` |
| `std.DynLib`（运行时加载 `libssl`/`libcrypto`）| `util/mtls.zig`（`-Dmtls` 门控）|
| `std.mem.Allocator.Error!T` | 所有 public API |
| `std.testing.allocator` | 所有 inline test |

---

## 9. 未来工作

**近期已完成**（此前列在本节，现移入记录）：

- ✅ `util/http.postXMLWithTLS` 的 mTLS：由仓库内自建的 `util/mtls.zig`（`std.DynLib` 运行时加载 `libssl`/`libcrypto` + 手写 extern）实现，受构建选项 **`-Dmtls`（默认 `false`）** 门控；关闭时返回 `error.MtlsNotEnabled`，运行期缺库返回 `error.OpenSslNotAvailable`。默认构建零 Zig 包依赖、零 C 依赖。
- ✅ `work.jsapi.getConfig`：完整支持 corp + agent ticket 切换（`setAgentJsTicketHandle` 等）。
- ✅ 性能 benchmark：`zig build bench`（SHA1 签名 ~253 ns/op、AES-256-CBC 解密 ~116 ns/op、XML 解析 ~137 ns/op）。

**待办**：

| 计划 | 优先级 |
|---|---|
| vendor 更快的 big-int 库（替换当前 `std.math.big.int.Managed` RSA 实现；CRT 签名路径已完成）| 低 |
| `miniprogram/auth` 的本地加密数据校验（当前只有服务端 `checkEncryptedData`，不做本地解密）| 中 |
| 性能 benchmark 与 Go SDK 做对照基线 | 低 |
| 文档国际化（英文版）| 低 |