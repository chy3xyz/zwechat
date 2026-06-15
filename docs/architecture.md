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
        │  cache       (Memory)                        │
        │  util        (http / crypto / sig / xml / …) │
        └──────────────────────────────────────────────┘
```

### 依赖规则

1. **底层 → 顶层**：只允许从 `credential` / `cache` / `util` 向上注入；业务模块横向**不**互相依赖。
2. **`test_runner.zig` 编译门**：每个新模块必须在 `src/test_runner.zig` 的 `@import` 列表中追加一行。否则 0.17-dev 的 dead-strip 会把 inline test 排除掉，`zig build test` 报告"假"成功。

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
    };
};
```

调用方只需要拿一个 `Cache` 值，通过 vtable 间接调用。`Memory` 是具体实现，`MockCache` 可以在测试时替换。

**好处**：
- ✅ 与 std.Io / std.Build 风格一致
- ✅ 无类型擦除，comptime 时已知具体类型
- ✅ 无堆分配（vtable 是静态 const）

**坏处**：
- ⚠️ 写起来繁琐（每个具体实现都要写 5 个 vtable 函数）

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

### 2.6 自旋锁代替 std.Thread.Mutex

Zig 0.17-dev 移除了 `std.Thread.Mutex`，改为自实现 5 行 CAS 自旋锁：

```zig
const SpinMutex = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    const UNLOCKED: u8 = 0;
    const LOCKED: u8 = 1;

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(UNLOCKED, .release);
    }
};
```

**适用场景**：临界区极短（仅几个原子操作），自旋开销可忽略；不适合长任务（应改用 `std.Thread.Mutex` 等长任务锁）。

---

## 3. 错误处理约定

### 3.1 窄错误集 + `||` 组合

```zig
pub const CacheError = error{
    NotFound,
    TypeMismatch,
    StorageError,
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
| `?[]const u8` (cache get) | 借用自 cache 内部，cache 销毁前不可长期持有 |
| `struct { ... }` (POD) | 值类型，调用方持有副本 |
| `*T` (指针) | 借用于父对象；父对象 deinit 前不要缓存 |

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

所有 HTTP 调用通过 `util.http.HttpClient` 发起 → 可注入 transport：

```zig
pub const MockTransport = struct {
    routes: std.HashMap([]const u8, Response, ...),
    history: std.ArrayList([]const u8),

    pub fn dispatch(ctx: *anyopaque, alloc, uri, method, payload, ct) anyerror![]u8;
};
```

**测试好处**：CI 不依赖网络；可在 1 秒内跑完整集成测试。

### 6.2 真实测试向量

涉及加密 / 签名 / 编解码的模块，附真实 RFC / 文档示例：

- `util/crypto.zig`：MD5("hello") = `5d41402abc4b2a76b9719d911017c592`
- `util/signature.zig`：SHA1 排序后的预期 hex（Python `hashlib.sha1` 计算）
- `util/rsa.zig`：RSA-SHA256 PKCS#1 v1.5（OpenSSL 生成的 1024-bit 测试向量）+ **RFC 8032 §7.1 Test 1**（Ed25519 完整公开示例）
- `pay/notify.zig`：微信支付文档示例参数 + 文档示例签名

### 6.3 编译门

`src/test_runner.zig` 用一个测试强制 `@import` 所有模块：

```zig
const _cache = @import("cache/mod.zig");
const _credential = @import("credential/mod.zig");
// ... 全部模块

test "test_runner 编译门 — 强制所有模块被解析" {
    _ = _cache;
    _ = _credential;
    // ... 全部模块
    try std.testing.expect(true);
}
```

**为什么需要**：Zig 0.17-dev 在某些情况下会 dead-strip 未经使用的 `@import`，导致 inline test 不被发现。编译门里的 `_ = ...` 阻止 dead-strip。

---

## 7. 性能特性

| 维度 | 表现 |
|---|---|
| 编译产物 | 单个静态可执行，无 libc 依赖（zig default target） |
| 运行时 | 零分配（除显式 `alloc` 调用外） |
| 内存占用 | 单 OfficialAccount 实例 ~1KB |
| HTTP 客户端 | 走 `std.http.Client`（libxev / io_uring / kqueue） |
| 加密原语 | AES-256-CBC / MD5 / HMAC-SHA256 / **RSA-SHA256 PKCS#1 v1.5（纯 Zig）** / **PKCS#12（PBES2/PBKDF2/AES-256-CBC）** / Ed25519（Zig stdlib 原生） |
| 并发 | `SpinMutex` + `std.Io` runtime |

**生产环境建议**：
- 长时间运行的服务：用 `std.heap.GeneralPurposeAllocator` 检测泄漏。
- 请求级别：用 `ArenaAllocator` 在请求作用域内分配，结束时一次性 free。
- 大批量处理：用线程池 + `std.atomic.Value` 做无锁队列。

---

## 8. 与 Zig 标准库的集成

| stdlib 用法 | 项目中位置 |
|---|---|
| `std.Io.Clock.now(.real, std.Options.debug_io)` | `util/time.zig` |
| `std.atomic.Value(u8)` + CAS 自旋锁 | `credential/default_access_token.zig` 等 |
| `std.http.Client` + `std.Io.Threaded.global_single_threaded` | `util/http.zig` |
| `std.json.parseFromSlice(... .{ .ignore_unknown_fields = true })` | 几乎所有 HTTP 响应解析 |
| `std.crypto.sign.Ed25519` | `util/rsa.zig` |
| `std.crypto.core.aes.Aes256` | `util/crypto.zig`, `util/pkcs12.zig` |
| `std.crypto.pwhash.pbkdf2` | `util/pkcs12.zig` |
| `std.crypto.utils.timingSafeEql` | `util/crypto.zig` |
| `std.mem.Allocator.Error!T` | 所有 public API |
| `std.testing.allocator` | 所有 inline test |

---

## 9. 未来工作

| 计划 | 优先级 |
|---|---|
| vendor 更快的 big-int 库（替换当前 `std.math.big.int.Managed` RSA 实现）| 低 |
| `util/http.postXMLWithTLS` 与 `std.http.Client` 客户端证书对接 | 高 |
| 完整 wire `work.jsapi.getConfig`（corp + agent ticket 切换）| 中 |
| `miniprogram/auth` 的 `verifyEncryptedData` 真实加密算法 | 中 |
| 性能 benchmark（与 Go SDK 对照）| 低 |
| 文档国际化（英文版）| 低 |