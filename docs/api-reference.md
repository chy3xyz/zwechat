# 公共 API 索引

本文档列出 `zwechat` 全部公共 API 的入口点。完整签名请查阅源代码中的 `///` 中文 doc 注释。

> **事实来源优先级**：本文档以当前源码为准。若发现本文与源码不一致，以 `src/` 为唯一事实来源（必要时用 `grep -rn "pub fn 名字" src/` 核对），并欢迎提 PR 更正。本文只做导航式总览，长尾方法与精确签名见源码。

> 所有 API 都遵循 **`Allocator` 显式传递** 约定：调用方负责分配器生命周期，返回的 `[]u8` 由调用方 `free`。

---

## 0. 顶层（`src/root.zig`）

```zig
pub const version = "0.8.0"; // 与 build.zig.zon 保持一致（有测试对账）
pub const wechat = @import("wechat.zig")
pub const cache = @import("cache/mod.zig")
pub const credential = @import("credential/mod.zig")
pub const util = @import("util/mod.zig")
pub const officialaccount = @import("officialaccount/mod.zig")
pub const work = @import("work/mod.zig")
pub const pay = @import("pay/mod.zig")
pub const miniprogram = @import("miniprogram/mod.zig")
pub const openplatform = @import("openplatform/mod.zig")
pub const middleware = @import("middleware/mod.zig")
```

> 对应 `src/root.zig`。除上述 10 个 barrel 导出外，`src/root.zig` 不直接暴露其它符号。

---

## 1. `wechat` — 顶层容器

### `Wechat`

```zig
pub const Wechat = struct {
    cache: ?Cache = null, // 全局默认 cache，Config.cache 为空时回退使用

    pub fn init() Wechat;
    pub fn setCache(self: *Wechat, c: Cache) void;

    pub fn getOfficialAccount(
        self: *Wechat,
        allocator: std.mem.Allocator,
        cfg: officialaccount.Config,
        default_access_token_factory: *const fn (cfg: officialaccount.Config, cache: Cache) anyerror!AccessTokenHandle,
    ) !OfficialAccount;

    pub fn getWork(self: *Wechat, allocator: std.mem.Allocator, cfg: work.Config) !work.Work;
    pub fn getPay(self: *Wechat, cfg: pay.Config) pay.Pay; // 支付不依赖 cache
    pub fn getMiniProgram(
        self: *Wechat,
        allocator: std.mem.Allocator,
        cfg: miniprogram.Config,
        default_access_token_factory: *const fn (cfg: miniprogram.Config, cache: Cache) anyerror!AccessTokenHandle,
    ) !MiniProgram;
    pub fn getOpenPlatform(self: *Wechat, cfg: openplatform.Config) !OpenPlatform;

    // 各 getter 的窄错误集（仅本模块特有变体）
    pub const GetOfficialAccountError = error{CacheUnavailable};
    pub const GetWorkError = error{CacheUnavailable};
    pub const GetMiniProgramError = error{CacheUnavailable};
    pub const GetOpenPlatformError = error{CacheUnavailable};
};
```

> 对应 `src/wechat.zig`。`getOfficialAccount` / `getMiniProgram` / `getWork` / `getOpenPlatform` 在 `cfg.cache` 与全局 `cache` 都为空时返回 `error.CacheUnavailable`；`getPay` 不依赖 cache。

---

## 2. `cache` — 缓存抽象

### `Cache` (vtable 接口)

```zig
pub const CacheError = error{ NotFound, TypeMismatch, StorageError, OutOfMemory };

pub const Cache = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (*anyopaque, []const u8) CacheError!?[]const u8,
        set: *const fn (*anyopaque, []const u8, []const u8, i64) CacheError!void,
        isExist: *const fn (*anyopaque, []const u8) CacheError!bool,
        delete: *const fn (*anyopaque, []const u8) CacheError!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn get(self: Cache, key: []const u8) CacheError!?[]const u8;
    pub fn set(self: Cache, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void; // ttl<=0 表示永不过期
    pub fn isExist(self: Cache, key: []const u8) CacheError!bool;
    pub fn delete(self: Cache, key: []const u8) CacheError!void;
    pub fn deinit(self: Cache) void;
};
```

> `get` 返回**借用切片**：有效期至该实例的任何后续写操作（`set` / `delete` / 覆盖同 key）或 `deinit`；Memcache / Redis 后端在**任何后续 `get`** 后即失效。跨写持有时必须 `allocator.dupe`。

### `Memory`

```zig
pub const Memory = struct {
    pub fn create(allocator: std.mem.Allocator) !*Memory;
    pub fn createWithIo(allocator: std.mem.Allocator, io: std.Io) !*Memory;
    pub fn deinit(self: *Memory) void;
    pub fn asCache(self: *Memory) Cache;
};
```

### `Redis`

```zig
pub const PoolStats = struct { live, idle, in_use, peak_in_use, created, discarded, timeouts: usize };

pub const Redis = struct {
    pub const Options = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 6379,
        password: ?[]const u8 = null,
        db: i32 = 0,
        io: ?std.Io = null,              // 外部 Io 句柄，未提供时自行创建
        max_connections: usize = 1,      // 连接池上限（0 钳制为 1）
        pool_timeout_ms: u64 = 30_000,   // 等空闲连接的上限；超时 error.PoolTimeout
        recv_timeout_ms: u64 = 0,        // 单次读取超时；0 = 不超时
        connect_timeout_ms: u64 = 0,     // 建连超时；0 = 不超时（仅 POSIX 生效）
    };

    pub fn create(allocator: std.mem.Allocator, opts: Options) !*Redis;
    pub fn deinit(self: *Redis) void;
    pub fn asCache(self: *Redis) Cache;
    pub fn poolStats(self: *Redis) PoolStats; // 连接池运行观测
};
```

### `Memcache`

```zig
pub const Memcache = struct {
    pub const Options = struct {
        server: []const u8 = "127.0.0.1:11211", // host 可为 IPv4 / [IPv6] / 域名
        io: ?std.Io = null,                     // 外部 Io 句柄，未提供时自行创建
        recv_timeout_ms: u64 = 0,               // 单次读取超时；0 = 不超时
        connect_timeout_ms: u64 = 0,            // 建连超时；0 = 不超时（仅 POSIX 生效）
    };

    pub fn create(allocator: std.mem.Allocator, opts: Options) !*Memcache;
    pub fn deinit(self: *Memcache) void;
    pub fn asCache(self: *Memcache) Cache;
};
```

---

## 3. `credential` — 凭据管理

### 公共抽象

```zig
pub const AccessTokenHandle = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getAccessToken: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        invalidate: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!void = null, // 可选
    };

    pub fn getAccessToken(self, allocator) anyerror![]u8;
    pub fn invalidateAccessToken(self, allocator) anyerror!void; // 未提供 hook 时 error.InvalidateNotSupported
};

pub const JsTicketHandle = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getTicket: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,
        invalidate: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!void = null, // 可选
    };

    pub fn getTicket(self, allocator, access_token: []const u8) anyerror![]u8;
    pub fn invalidateTicket(self, allocator) anyerror!void;
};

pub const Fetcher = *const fn (ctx: *anyopaque, allocator, url: []const u8) CredentialError![]u8; // 可注入的 HTTP 后端

pub fn tokenTTL(expires_in: i64) i64; // = max(expires_in -| 1500, 1)

pub const CredentialError = std.json.Error ||
    std.mem.Allocator.Error ||
    CacheError ||
    error{ ApiError, HttpError, DecodeError, ConfigMissing };

pub const CacheKeyOfficialAccountPrefix = "gowechat_officialaccount_";
pub const CacheKeyMiniProgramPrefix = "gowechat_miniprogram_";
pub const CacheKeyWorkPrefix = "gowechat_work_";
```

### `DefaultAccessToken`（公众号）

```zig
pub const DefaultAccessToken = struct {
    pub fn init(app_id, app_secret, cache_key_prefix, cache: Cache) DefaultAccessToken;
    pub fn initWithFetcher(app_id, app_secret, cache_key_prefix, cache, fetcher, fetcher_ctx) DefaultAccessToken; // 测试用
    pub fn buildURL(self: *const DefaultAccessToken, allocator) CredentialError![]u8;
    pub fn cacheKey(self: *const DefaultAccessToken, allocator) CredentialError![]u8;
    pub fn getAccessToken(self: *DefaultAccessToken, allocator) CredentialError![]u8;
    pub fn invalidate(self: *DefaultAccessToken, allocator) CredentialError!void;
    pub fn forceRefresh(self: *DefaultAccessToken, allocator) CredentialError![]u8;
    pub fn asHandle(self: *DefaultAccessToken) AccessTokenHandle;
};
```

### `DefaultJsTicket`（公众号）

```zig
pub const DefaultJsTicket = struct {
    pub fn init(app_id, cache_key_prefix, cache: Cache) DefaultJsTicket;
    pub fn initWithFetcher(..., fetcher, fetcher_ctx) DefaultJsTicket;
    pub fn buildURL(self: *const DefaultJsTicket, allocator, access_token: []const u8) CredentialError![]u8;
    pub fn cacheKey(self: *const DefaultJsTicket, allocator) CredentialError![]u8;
    pub fn getTicket(self: *DefaultJsTicket, allocator, access_token: []const u8) CredentialError![]u8;
    pub fn invalidate(self: *DefaultJsTicket, allocator) CredentialError!void;
    pub fn asHandle(self: *DefaultJsTicket) JsTicketHandle;
};
```

### `WorkAccessToken`（企业微信）

```zig
pub const workAccessTokenURL = "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid={s}&corpsecret={s}";
pub const ResAccessToken = struct { errcode, errmsg, access_token, expires_in, ... };

pub const WorkAccessToken = struct {
    pub fn init(corp_id, corp_secret, cache_key_prefix, cache: Cache) WorkAccessToken;
    pub fn initWithFetcher(...) WorkAccessToken;
    pub fn getAccessToken(self: *WorkAccessToken, allocator) CredentialError![]u8;
    pub fn invalidate(self: *WorkAccessToken, allocator) CredentialError!void;
    pub fn asHandle(self: *WorkAccessToken) AccessTokenHandle;
};
```

### `WorkJsTicket`（企业微信 corp + agent）

```zig
pub const TicketType = enum { corp_js, agent_js };

pub const WorkJsTicket = struct {
    pub fn init(corp_id, agent_id, cache_key_prefix, cache: Cache) WorkJsTicket;
    pub fn initWithFetcher(...) WorkJsTicket;
    pub fn getTicket(
        self: *WorkJsTicket,
        allocator: std.mem.Allocator,
        access_token: []const u8,
        ticket_type: TicketType,
    ) CredentialError![]u8;
    pub fn invalidate(self: *WorkJsTicket, allocator, ticket_type: TicketType) CredentialError!void;
    pub fn invalidateAll(self: *WorkJsTicket, allocator) CredentialError!void; // corp + agent 两个 key
};
```

> 对应 `src/credential/`。`retry` 失效恢复链路依赖 handle 的 `invalidate`（可选 hook）：自定义 handle 不实现时 `invalidateAccessToken` 返回 `error.InvalidateNotSupported`。

---

## 4. `util` — 通用工具集

### `util/http` — HTTP 客户端 + Mock

```zig
pub const default_max_response_bytes: usize = 16 * 1024 * 1024;
pub const default_connect_timeout_ms: u64 = 10_000;
pub const default_read_timeout_ms: u64 = 30_000;
pub const default_max_redirects: u16 = 3;

pub const HttpResponse = struct { status: std.http.Status, body: []u8, pub fn deinit(self, allocator) void };
pub const HeaderTransport = *const fn (...);
pub const MultipartField = struct { is_file, field_name, filename, value, file_path, data };
pub const UriModifier = *const fn (uri: []const u8) []const u8;

pub const HttpClient = struct {
    pub fn init(allocator: std.mem.Allocator) HttpClient;
    pub fn deinit(self: *HttpClient) void;

    pub fn get(self: *HttpClient, uri: []const u8) ![]u8;
    pub fn getFollowRedirect(self: *HttpClient, uri: []const u8) ![]u8;                 // 手动跟随 302（≤2 跳）
    pub fn getFollowRedirectLimited(self: *HttpClient, uri: []const u8, max_bytes: usize) ![]u8;
    pub fn getFollowRedirectToFile(self: *HttpClient, uri, path, max_bytes: usize) !u64; // 流式落盘
    pub fn post(self: *HttpClient, uri: []const u8, body: []const u8, content_type: ?[]const u8) ![]u8;
    pub fn postJSON(self: *HttpClient, uri: []const u8, body: []const u8) ![]u8;
    pub fn postXML(self: *HttpClient, uri: []const u8, body: []const u8) ![]u8;
    pub fn postMultipart(self: *HttpClient, uri: []const u8, fields: []const MultipartField) ![]u8;
    pub fn requestWithHeaders(self: *HttpClient, method: std.http.Method, uri, payload, content_type: ?[]const u8, headers: []const std.http.Header) !HttpResponse;
    pub fn sendWithHeaders(self: *HttpClient, method: std.http.Method, uri, payload, content_type: ?[]const u8, headers: []const std.http.Header) ![]u8;
    pub fn postWithHeaders(self: *HttpClient, uri, body, content_type: ?[]const u8, headers: []const std.http.Header) ![]u8;

    /// v2 mTLS：需构建时 `-Dmtls=true`；否则返回 `error.MtlsNotEnabled`，
    /// 运行期缺 libssl/libcrypto 时返回 `error.OpenSslNotAvailable`。
    pub fn postXMLWithTLS(self: *HttpClient, uri, body, p12_path: []const u8, p12_password: []const u8) ![]u8;

    /// 注入自定义 transport / 头部 transport（用于 Mock / 测试）
    pub fn setTransport(self: *HttpClient, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn setHeaderTransport(self: *HttpClient, t: ?HeaderTransport, ctx: ?*anyopaque) void;
    pub fn setMaxResponseBytes(self: *HttpClient, n: usize) void;
    pub fn setTimeouts(self: *HttpClient, connect_ms: u64, read_ms: u64) void; // 0 = 不限
};

pub fn getDefaultClient(allocator: std.mem.Allocator) *HttpClient;
pub fn initDefaultClient(allocator: std.mem.Allocator) !void; // 启动期严格模式（幂等）
pub fn defaultClientAllocatorMatches(allocator: std.mem.Allocator) bool;
pub fn deinitDefaultClient() void;
pub fn setUriModifier(m: ?UriModifier) void;

pub const MockTransport = struct {
    pub const Response = struct { ... };
    pub fn init(allocator: std.mem.Allocator) MockTransport;
    pub fn deinit(self: *MockTransport) void;
    pub fn addRoute(self: *MockTransport, uri: []const u8, response: Response) !void;
    pub fn dispatch(ctx, allocator, uri, method, payload, content_type) anyerror![]u8;
};
```

> 判重定向 / 响应体大小 / 超时都内建在 `HttpClient` 里；新增 HTTP 调用**不要**绕过它。

### `util/crypto` — 加解密

```zig
pub const SignTypeMD5 = "MD5";
pub const SignTypeHMACSHA256 = "HMAC-SHA256";

pub fn md5HexLower(allocator, content) Allocator.Error![]u8;
pub fn calculateSign(allocator, content, sign_type, key) Allocator.Error![]u8; // HMAC-SHA256 大写 hex，否则 MD5
pub fn aesEncryptMsg(allocator, random_16B, raw_xml_msg, app_id, aes_key) (Allocator.Error || WechatError)![]u8;
pub fn aesDecryptMsg(allocator, ciphertext, aes_key) (Allocator.Error || WechatError)!DecryptedMessage;
pub const DecryptedMessage = struct { random: []u8, raw_xml_msg: []u8, app_id: []u8 };
pub fn pkcs7Pad(allocator, data, block_size) ![]u8;
pub fn pkcs7Unpad(data) []const u8;
pub fn pkcs5Pad(allocator, data) Allocator.Error![]u8;
pub fn pkcs5Unpad(data) []const u8;
pub fn aesECBDecrypt(allocator, ciphertext, aes_key) ![]u8;
```

### `util/signature` — SHA1

```zig
pub fn signature(allocator: std.mem.Allocator, params: []const []const u8) ![]u8;
// 返回小写 hex
```

### `util/xml` — XML 编解码

```zig
pub const XmlElement = struct { key: []const u8, value: []const u8 };
pub const XmlDoc = struct {
    root_name: []const u8,
    elements: []XmlElement,

    pub fn deinit(self: *XmlDoc) void;
    pub fn get(self: XmlDoc, key: []const u8) ?[]const u8;
    pub fn count(self: XmlDoc) usize;
};

pub fn parse(allocator, input) (Allocator.Error || error{MalformedXml})!XmlDoc;
pub fn serialize(allocator, root_name, elements) Allocator.Error![]u8;
```

### `util/error` — 错误集

```zig
pub const WechatError = error{
    ApiError,
    NetworkError,
    DecodeError,
    AccessTokenExpired,
    ConfigMissing,
    InvalidArgument,
};

pub const WechatErrorDecodeError = WechatError || error{OutOfMemory};

pub const CommonError = struct {
    api_name: []const u8,
    errcode: i64,
    errmsg: []const u8,
    _allocator: ?std.mem.Allocator = null,
    pub fn format(self: CommonError, allocator) std.mem.Allocator.Error![]u8;
    pub fn deinit(self: CommonError) void; // 释放 errmsg 深拷贝
};

pub const ErrorDetail = struct { errcode: i64, errmsg: []const u8, api_name: []const u8 };

pub fn decodeWithCommonError(allocator, response, api_name) WechatErrorDecodeError!?CommonError;
pub fn parseCommonError(allocator, response, api_name) WechatErrorDecodeError!?CommonError;
pub fn decodeWithError(comptime T, allocator, response, api_name) WechatErrorDecodeError!std.json.Parsed(T);
pub fn handleFileResponse(response, api_name) WechatErrorDecodeError![]const u8;
pub fn isTokenInvalidErrCode(errcode: i64) bool; // 40001 / 40014 / 41001 / 42001

// 线程局部 errcode 详情（errcode 不再随错误变体丢失）：借用，有效期至本线程下次记录 / 清除
pub fn lastErrorDetail() ?ErrorDetail;
pub fn clearErrorDetail() void;
```

### `util/rsa` — 签名（RSA-SHA256 PKCS#1 v1.5 + Ed25519 native）

```zig
// RSA-SHA256 PKCS#1 v1.5（可用）
pub fn rsaSign(allocator, content, private_key_pem) RsaError![]u8;
pub fn rsaVerify(allocator, content, signature_b64, public_key_pem) RsaError!bool;
pub fn rsaDecrypt(allocator, ciphertext, private_key_pem) RsaError![]u8;         // RSAES-PKCS1-v1_5
pub fn rsaDecryptBase64(allocator, ciphertext_b64, private_key_pem) RsaError![]u8;

// PKCS#12（可用：PBES2 + PBKDF2-HMAC-SHA256 + AES-256-CBC）
pub fn parseP12(allocator, p12_bytes, password) P12Error!struct { cert_pem, key_pem };
pub fn p12Available() bool;

// Ed25519（Zig 0.17 native，可用；secret_key 32 字节种子 + public_key 32 字节）
pub fn ed25519GenerateKeyPair(allocator) !Ed25519KeyPair;
pub fn ed25519GenerateKeyPairWithIo(allocator, io: std.Io) !Ed25519KeyPair;
pub fn ed25519Sign(allocator, secret_key_bytes, message) Ed25519Error![]u8; // 返回 64 字节
pub fn ed25519Verify(signature, message, public_key_bytes) Ed25519Error!bool;

// PEM 粗略格式检查
pub fn looksLikeRsaPrivateKeyPem(pem) bool;
pub fn looksLikeRsaPublicKeyPem(pem) bool;
```

### `util/time`

```zig
pub fn getCurrTS() i64;            // 当前 Unix 秒
pub fn getCurrTSWithIo(io: std.Io) i64;
```

### `util/param`

```zig
pub const Param = struct { key: []const u8, value: []const u8 };
pub fn orderParam(allocator, params, biz_key) ![]u8;
```

### `util/util`

```zig
pub fn sliceChunk(allocator, src, chunk_size) ![][]const u8;
pub fn randomStr(allocator, length) ![]u8;
pub fn randomStrWithIo(allocator, io: std.Io, length: usize) ![]u8;
```

### `util` 的其它子模块（barrel 导出，按需查阅源码）

`util/mod.zig` 还导出：`mtls`（`-Dmtls` 门控的 OpenSSL 桥：`postXML` / `parseHttpsUri` / `enabled`）、
`asn1`（DER 解析）、`pkcs12`（PKCS#12 解析）、`xml`（`parse` / `serialize`）、
`template`（`buildTemplateData`，模板消息 JSON）、`sync`（`SpinMutex` 兼容层）、
`retry`（`callApi`：token 注入 + errcode 判定 + 失效自愈重试一次）、
`uri`（`queryEscape`，Go `url.QueryEscape` 语义）、`json`（`appendEscapedString` / `stringFieldObject` /
`stringFieldsObject` / `stringLiteral`，全仓唯一的 JSON 转义实现）。

---

## 5. `officialaccount` — 公众号

### `Config`

```zig
pub const Config = struct {
    app_id: []const u8 = "",
    app_secret: []const u8 = "",
    token: []const u8 = "",
    encoding_aes_key: []const u8 = "",
    cache: ?Cache = null,
    use_stable_ak: bool = false,
};
```

### `Context`

```zig
pub const Context = struct {
    config: Config,
    access_token_handle: AccessTokenHandle,
    pub fn getAccessToken(self: *Context, allocator) @TypeOf(self.access_token_handle.getAccessToken(allocator));
    pub fn invalidateAccessToken(self: *Context, allocator) anyerror!void;
};
```

### `OfficialAccount`

```zig
pub const OfficialAccount = struct {
    ctx: Context,
    pub fn init(ctx: Context) OfficialAccount;
    pub fn newOfficialAccount(cfg: Config, default_access_token: AccessTokenHandle) OfficialAccount;
    pub fn getContext(self: *OfficialAccount) *Context;
    pub fn getAccessToken(self: *OfficialAccount, allocator) ![]u8;

    // 子模块懒加载工厂（各返回对应子结构，持有 &self.ctx）：
    pub fn getBasic(self, allocator) basic.Basic;
    pub fn getBroadcast(self, allocator) broadcast.Broadcast;
    pub fn getCustomerService(self, allocator) customerservice.CustomerService;
    pub fn getDataCube(self, allocator) datacube.DataCube;
    pub fn getDevice(self, allocator) device.Device;
    pub fn getDraft(self, allocator) draft.Draft;
    pub fn getFreePublish(self, allocator) freepublish.FreePublish;
    pub fn getJs(self) js.Js;              // 不接 allocator
    pub fn getMaterial(self, allocator) material.Material;
    pub fn getMenu(self, allocator) menu.Menu;
    pub fn getMessage(self, allocator) message.Message;
    pub fn getOauth(self, allocator) oauth.Oauth;
    pub fn getOcr(self, allocator) ocr.Ocr;
    pub fn getServer(self, allocator) server.Server;
    pub fn getUser(self, allocator) user.User;
};
```

> ⚠️ `OfficialAccount` / `MiniProgram` 一旦被 `getXxx()` 工厂使用，地址必须保持稳定（子模块持有 `&self.ctx`）；**禁止按值拷贝 / 移动**，传递时用指针。

### `officialaccount/menu`

```zig
pub const Menu = struct {
    pub fn init(ctx: *Context, allocator) Menu;
    pub fn setTransport(self: *Menu, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn setMenu(self: *Menu, buttons: []const Button) !void;
    pub fn getMenu(self: *Menu) !std.json.Parsed(ResMenu);
    pub fn deleteMenu(self: *Menu) !void;
    pub fn addConditional(self: *Menu, buttons, match_rule: ?MatchRule) !void;
    pub fn deleteConditional(self: *Menu, menu_id: i64) !void;
    pub fn menuTryMatch(self: *Menu, user_id) !std.json.Parsed(TryMatchResult);
    pub fn getCurrentSelfMenuInfo(self: *Menu) !std.json.Parsed(ResSelfMenuInfo);
};

pub const Button = struct {
    // 共 11 种类型构造器 + setSub：
    pub fn setClick(name, key) Button;          pub fn setView(name, url) Button;
    pub fn setScanCodePush(name, key) Button;   pub fn setScanCodeWaitMsg(name, key) Button;
    pub fn setPicSysPhoto(name, key) Button;    pub fn setPicPhotoOrAlbum(name, key) Button;
    pub fn setPicWeixin(name, key) Button;      pub fn setLocationSelect(name, key) Button;
    pub fn setMediaID(name, media_id) Button;   pub fn setViewLimited(name, media_id) Button;
    pub fn setMiniprogram(name, url, appid, pagepath) Button;
    pub fn setSub(name, sub: []const Button) Button;
};
```

> `getMenu` / `menuTryMatch` / `getCurrentSelfMenuInfo` 返回 `std.json.Parsed(T)`，取值用 `.value`，用完 `deinit()`。

### `officialaccount/oauth`

```zig
pub const Oauth = struct {
    pub fn init(ctx, allocator) Oauth;
    pub fn getRedirectURL(self, redirect_uri, scope, state) ![]u8;
    pub fn getUserAccessToken(self, code) !std.json.Parsed(ResAccessToken);
    pub fn refreshAccessToken(self, refresh_token) !std.json.Parsed(ResAccessToken);
    pub fn checkAccessToken(self, access_token, open_id) !bool;
    pub fn getUserInfo(self, access_token, open_id, lang) !std.json.Parsed(UserInfo);
};
```

### `officialaccount/basic`

```zig
pub const Basic = struct {
    pub fn init(ctx, allocator) Basic;
    pub fn setTransport(self: *Basic, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn getCallbackIP(self: *Basic) !IpList;      // IpList 含 deinit
    pub fn getAPIDomainIP(self: *Basic) !IpList;
    pub fn clearQuota(self: *Basic) !void;
};
```

### `officialaccount/js`

```zig
pub const Js = struct {
    pub fn init(ctx: *Context) Js;
    pub fn setJsTicketHandle(self: *Js, h: JsTicketHandle) void;
    pub fn getConfig(self: *Js, allocator, uri: []const u8) !Config; // 返回的 Config 需 deinit
};
```

### `officialaccount/server`

```zig
pub const Query = struct { signature, timestamp, nonce, echostr, msg_signature, encrypt_type, openid };
pub const InboundMessage = struct { raw_xml, doc, open_id, timestamp, nonce, pub fn deinit() void, pub fn get(key) ?[]const u8 };
pub const MessageHandler = *const fn (ctx: *anyopaque, msg: *message.MixMessage) anyerror!?message.Reply;

pub const Server = struct {
    pub fn init(ctx, allocator) Server;
    pub fn setMessageHandler(self, handler: MessageHandler, ctx: ?*anyopaque) void;
    pub fn setRawBody(self, body) void;
    pub fn validateSignature(self, q: Query) ![]u8;
    pub fn validateURL(self, q: Query) !bool;
    pub fn parsePlainMessage(self, open_id: []const u8) !InboundMessage;
    pub fn parseEncryptedMessage(self, q: Query, open_id: []const u8) !InboundMessage;
    pub fn buildReply(self, to_user, from_user, content) ![]u8;
    pub fn buildEncryptedReply(self, to_user, from_user, content, timestamp: i64, nonce) ![]u8;
    pub fn serve(self, q: Query) ![]u8;
};
```

### `officialaccount/message`

```zig
pub const MsgType = enum { text, image, voice, video, miniprogrampage, shortvideo, location, link, music, news, transfer_customer_service, event };
pub const EventType = enum { subscribe, unsubscribe, scan, location, click, view, ..., weapp_audit_delay }; // 21 种
pub const MixMessage = struct { ... };
pub const EncryptedXMLMsg = struct { ... };
pub const TemplateMessage = struct { ... };
pub const CustomerMsgType = enum { text, image, voice, video, music, news, mpnews, wxcard, msgmenu, miniprogrampage, mpnewsarticle };
pub const CustomerTextMessage = struct { touser, content };
pub const CustomerMessage = struct { touser, msgtype: CustomerMsgType, text/image/voice/... ?... }; // 按 msgtype 填充
pub const TypingStatus = enum { typing, cancel_typing };

pub const Message = struct {
    pub fn init(ctx, allocator) Message;
    pub fn setTransport(self, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn sendTemplate(self, msg) !i64;
    pub fn sendCustomerText(self, msg) !void;
    pub fn sendCustomer(self, msg: CustomerMessage) !void;
    pub fn sendTypingStatus(self, openid, command: TypingStatus) !void; // 转客服 / 输入中
};

pub const Reply = struct { ... };
pub const ReplyMsgType = enum { text, image, voice, video, music, news, miniprogrampage, transfer_customer_service };
pub const TextReply, ImageReply, VoiceReply, VideoReply, MusicReply, NewsReply, MiniprogramPageReply = ...;
```

### `officialaccount/material`

```zig
pub const PermanentMaterialType = enum { image, video, voice, news };
pub const max_media_bytes: usize = 100 * 1024 * 1024; // 通用素材下载上限
pub const max_image_bytes: usize = 10 * 1024 * 1024;
pub const max_voice_bytes: usize = 2 * 1024 * 1024;
pub const max_video_bytes: usize = 100 * 1024 * 1024;
pub fn maxBytesFor(mtype: PermanentMaterialType) usize;

pub const Article / ResMaterialCount / ArticleList / GetNewsResult / AddMaterialResult = ...;

pub const Material = struct {
    pub fn init(ctx, allocator) Material;

    // 图文
    pub fn addNews(self, articles: []const Article) ![]u8;             // 返回 media_id，调用方 free
    pub fn updateNews(self, article: *const Article, media_id, index: i64) !void;
    pub fn getNews(self, media_id) !std.json.Parsed(GetNewsResult);

    // 永久视频 / 图片 / 语音（multipart）
    pub fn addVideoFromBytes(self, data, filename, title, introduction) !std.json.Parsed(AddMaterialResult);
    pub fn addVideo(self, file_path, title, introduction) !std.json.Parsed(AddMaterialResult);
    pub fn addMaterialFromBytes(self, mtype: PermanentMaterialType, data, filename) !std.json.Parsed(AddMaterialResult);
    pub fn addMaterial(self, mtype: PermanentMaterialType, file_path) !std.json.Parsed(AddMaterialResult);

    // 临时素材下载（getMedia* 走 302 跟随 + 体积限额，超限 error.ResponseTooLarge）
    pub fn getMediaURL(self, media_id) ![]u8;
    pub fn getMedia(self, media_id) ![]u8;                              // 默认上限 max_media_bytes
    pub fn getMediaWithLimit(self, media_id, max_bytes: usize) ![]u8;
    pub fn getMediaToFile(self, media_id, file_path) !u64;              // 流式落盘，返回字节数
    pub fn getMediaToFileWithLimit(self, media_id, file_path, max_bytes: usize) !u64;

    // 素材管理
    pub fn deleteMaterial(self, media_id) !void;
    pub fn getMaterialCount(self) !std.json.Parsed(ResMaterialCount);
    pub fn batchGetMaterial(self, mtype: PermanentMaterialType, offset: i64, count: i64) !std.json.Parsed(ArticleList);
};
```

> 落盘路径会把微信的错误 JSON 体回读识别（避免把错误 JSON 当素材留在磁盘上）并删除。

### 其他 `officialaccount` 子模块

`officialaccount` 共 **15 个业务子模块**（`src/officialaccount/mod.zig` 全部 re-export），均遵循
`init(ctx, allocator) + setTransport（测试用）+ N 个 method` 的模式；详细签名查阅对应 `.zig`：

- `user` — 用户信息 / 标签 CRUD / 黑名单 / `batchTag` / `batchGetUserInfo` / 分页封装 `listAllUserOpenIDs`·`getAllBlackList`
- `datacube` — 用户、图文、接口、消息、分享各维度统计 + 流量主广告（`getPublisherAdPosGeneral` / `getPublisherCpsGeneral` / `getPublisherSettlement`）
- `broadcast` — 六类消息（text/news/voice/video/wxcard/image）分别 `sendXxxToTag` / `sendXxxToOpenIDs` / `sendXxxToAll` + `previewToUser` / `delete` / `getMassStatus` / `getSpeed`·`setSpeed`
- `device` — `transMsg` / `createQRCode`
- `customerservice` — 客服账号管理（`addAccount` / `updateAccount` / `deleteAccount` / `inviteBind` / `onlineList` / `uploadHeadImg` / `listAccounts`）
- `ocr` — `idCard` / `bankCard` / `driving` / `driverLicense` / `bizLicense` / `common` / `plateNumber`
- `draft` — `add` / `get` / `delete` / `update` / `count` / `list`
- `freepublish` — `publish` / `delete` / `selectStatus` / `list`

（`basic` / `menu` / `oauth` / `js` / `server` / `message` / `material` 见上。）

---

## 6. `pay` — 微信支付

### `Config`

```zig
pub const Config = struct {
    app_id: []const u8 = "",
    mch_id: []const u8 = "",
    key: []const u8 = "",          // v2 商户支付密钥
    notify_url: []const u8 = "",
    root_ca: []const u8 = "",      // 商户 P12 证书路径；非空时退款/转账/红包走 mTLS（需 -Dmtls=true）
};
```

### `Pay`

```zig
pub const Pay = struct {
    cfg: Config,
    pub fn init(cfg: Config) Pay;
    pub fn getOrder(self: *Pay) Order;
    pub fn getRefund(self: *Pay) Refund;
    pub fn getNotify(self: *Pay) Notify;
    pub fn getTransfer(self: *Pay) Transfer;
    pub fn getRedpacket(self: *Pay) Redpacket;
};
```

### `pay/order`

```zig
pub const Params = struct {
    total_fee, create_ip, body, out_trade_no, open_id, trade_type, notify_url: []const u8,
    detail, attach, goods_tag, time_expire: []const u8 = "",
    sign_type: []const u8 = "MD5",
};

pub const PreOrder / QueryOrderResult / CloseOrderResult = ...;  // 含 deinit 释放 _raw
pub const BridgeConfig = struct { timestamp, nonce_str, package, sign_type, pay_sign };
pub const AppConfig = struct { ... };                            // bridgeAppConfig 返回

pub const Order = struct {
    pub fn init(cfg: Config) Order;
    pub fn setTransport(self: *Self, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn prePayOrder(self: *Self, allocator, p: Params) !PreOrder;
    pub fn queryOrder(self: *Self, allocator, out_trade_no) !QueryOrderResult;
    pub fn closeOrder(self: *Self, allocator, out_trade_no) !CloseOrderResult;
    pub fn prePayID(self: *Self, allocator, pre_order: PreOrder) ![]u8;
    pub fn bridgeConfig(self: *Self, allocator, p: Params, pre_order: PreOrder) !BridgeConfig;
    pub fn bridgeAppConfig(self: *Self, allocator, pre_order: PreOrder) !AppConfig;
};
```

### `pay/refund`

```zig
pub const RefundParams = struct {
    out_trade_no, out_refund_no, total_fee, refund_fee, notify_url: []const u8,
    refund_desc: []const u8 = "",
};

pub const RefundResult = struct { return_code, return_msg, result_code, err_code, err_code_des, ... };

pub const Refund = struct {
    pub fn init(cfg: Config) Refund;
    pub fn setTransport(self: *Self, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn refund(self: *Self, allocator, p: RefundParams) !RefundResult;
};
```

### `pay/notify`

```zig
pub fn verifyPaidNotify(allocator: std.mem.Allocator, cfg: Config, xml_body: []const u8) !bool;
pub const PaidNotify = struct { return_code, return_msg, appid, mch_id, out_trade_no, transaction_id, total_fee, result_code };

pub const Notify = struct {
    pub fn init(cfg: Config) Notify;
    pub fn decryptRefund(self: *Self, allocator, req_info_b64) ![]u8;
};
```

### `pay/transfer` / `pay/redpacket`

```zig
pub const Transfer = struct {                  // 企业付款到零钱
    pub fn init(cfg: Config) Transfer;
    pub fn setTransport(self: *Self, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn toWallet(self: *Self, allocator, p: TransferWalletParams) !TransferWalletResult;
};

pub const Redpacket = struct {                 // 现金红包
    pub fn init(cfg: Config) Redpacket;
    pub fn setTransport(self: *Self, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn sendNormal(self: *Self, allocator, p: RedpacketParams) !RedpacketResult;
};
```

> 退款 / 转账 / 红包在 `Config.root_ca` 非空时走 mTLS（`postXMLWithTLS`，**需 `-Dmtls=true`**）；为空时退回普通 HTTPS，默认构建下 mTLS 调用返回 `error.MtlsNotEnabled`。

### `pay/v3` — APIv3（`src/pay/v3/`）

```zig
pub const Config = struct { app_id, mch_id, api_v3_key, serial_no, private_key_pem, notify_url, wechatpay_serial };
pub const signer = struct { pub fn buildAuthorizationHeader(allocator, cfg, method, canonical_url, body) !SignResult;
                            pub fn buildAuthorizationHeaderWithIo(allocator, io, cfg, method, canonical_url, body) !SignResult; };

pub const OrderV3 = struct {   // 下单 / 查单 / 关单 / JSAPI 调起参数
    pub fn init(cfg: Config) OrderV3;
    pub fn setTransport(self, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn setHeaderTransport(self, t: ?HeaderTransport, ctx: ?*anyopaque) void;
    pub fn createJsapiOrder(self, allocator, p: JsapiOrderParams) !std.json.Parsed(CreateOrderResult);
    pub fn queryOrderByOutTradeNo(self, allocator, out_trade_no) !std.json.Parsed(OrderQueryResult);
    pub fn closeOrder(self, allocator, out_trade_no) !void;   // 成功为 204
    pub fn getJsPayParams(self: OrderV3, allocator, prepay_id) !JsapiPayParams; // 前端拉起支付签名
};

pub const RefundV3 = struct {  // v3 退款（官方文档为准，Go 参考无 v3）
    pub fn init(cfg: Config) RefundV3;
    pub fn setTransport / setHeaderTransport(...) void;
    pub fn refund(self, allocator, p: RefundParams) !std.json.Parsed(RefundResult);
    pub fn queryRefund(self, allocator, out_refund_no) !std.json.Parsed(RefundResult);
};

pub const TransferV3 = struct { // 商家转账
    pub fn init(cfg: Config) TransferV3;
    pub fn setTransport / setHeaderTransport(...) void;
    pub fn transfer(self, allocator, p: TransferParams) !std.json.Parsed(TransferResult);
    pub fn queryTransfer(self, allocator, out_bill_no) !std.json.Parsed(TransferBillResult);
    pub fn cancelTransfer(self, allocator, out_bill_no) !std.json.Parsed(TransferCancelResult);
};

pub const NotifyVerifier = struct {  // 回调验签 + 解密（含平台证书自动拉取 / 轮换）
    pub fn init(allocator, cfg: Config) NotifyVerifier;
    pub fn verify(self: *Self, headers: NotifyHeaders, body: []const u8) NotifyError!void;
    pub fn verifyAndDecrypt(self: *Self, allocator, headers: NotifyHeaders, body: []const u8) !VerifiedNotify;
    pub fn cachedCertCount(self: *const Self) usize;
};
pub fn decryptNotifyResource(allocator, api_v3_key, ciphertext_b64, associated_data, nonce) ![]u8; // 仅 AES-GCM 解密，不含验签
pub const PlatformCertStore = struct { refresh / find / certificateForSerial ... };
pub const NotifyHeaders / VerifiedNotify / PlatformCert / CertificatesResponse = ...;
```

> ⚠️ 回调**必须**走 `NotifyVerifier.verifyAndDecrypt`：只做 AES-GCM 解密不足以确认来源。`NotifyVerifier` / `PlatformCertStore` 非线程安全。

---

## 7. `miniprogram` — 小程序

```zig
pub const Config = struct {
    app_id, app_secret, app_key, offer_id, token, encoding_aes_key: []const u8 = "",
    cache: ?Cache = null,
    use_stable_ak: bool = false,
};

pub const Context = struct {
    config: Config,
    access_token_handle: AccessTokenHandle,
    pub fn getAccessToken(self: *Context, allocator) ...;
    pub fn invalidateAccessToken(self: *Context, allocator) anyerror!void;
};

pub const MiniProgram = struct {
    ctx: Context,
    pub fn init(allocator, cfg, access_token_handle) MiniProgram;
    pub fn getContext(self: *MiniProgram) *Context;

    // 23 个懒加载工厂（各返回对应子模块）：
    pub fn getAuth(self) Auth;
    pub fn getQRCode(self) qrcode.QRCode;
    pub fn getURLScheme(self) urlscheme.URLScheme;
    pub fn getMessage(self) message.Message;            // ⚠️ 弃用（重复入口）
    pub fn getSecurity(self) security.Security;
    pub fn getShortLink(self) shortlink.ShortLink;
    pub fn getEncryptor(self) encryptor.Encryptor;
    pub fn getWeRun(self) werun.WeRun;
    pub fn getURLLink(self) urllink.URLLink;
    pub fn getRiskControl(self) riskcontrol.RiskControl;
    pub fn getRedPacketCover(self) redpacketcover.RedPacketCover;
    pub fn getPrivacy(self) privacy.Privacy;
    pub fn getContent(self) content.Content;            // ⚠️ 弃用（重复入口）
    pub fn getBusiness(self) business.Business;         // ⚠️ getPhoneNumber 建议改用 getAuth
    pub fn getOrder(self) order.Shipping;
    pub fn getOCR(self) ocr.OCR;
    pub fn getSubscribe(self) subscribe.Subscribe;
    pub fn getAnalysis(self) analysis.Analysis;
    pub fn getOperation(self) operation.Operation;
    pub fn getTcb(self) tcb.Tcb;
    pub fn getExpress(self) express.Express;
    pub fn getMiniDrama(self) minidrama.MiniDrama;
    pub fn getVirtualPayment(self) virtualpayment.VirtualPayment;
};

pub const Auth = struct {
    pub fn init(ctx: *Context, allocator) Auth;
    pub fn setTransport(self, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn code2Session(self, js_code) !std.json.Parsed(ResCode2Session);
    pub fn getPhoneNumber(self, code) !std.json.Parsed(GetPhoneNumberResponse);
    pub fn checkEncryptedData(self, encrypted_msg_hash) !std.json.Parsed(RspCheckEncryptedData);
    pub fn checkSession(self, signature, open_id) !void;
    pub fn getPaidUnionID(self, req: GetPaidUnionIDRequest) ![]u8;
};
```

`src/miniprogram/` 共 **25 个子目录**：`config` / `context` 两个基础设施目录 + **23 个业务子模块**（上表 23 个工厂各对应一个）。各业务子模块要点：

- `qrcode` — `getUnlimited`；`urlscheme` — `generate` / `queryScheme`
- `encryptor` — 用户加密数据解密（`decrypt`，AES-128-CBC）
- `message` — 订阅消息 `sendSubscribeMessage`（旧入口，`data` 需预拼 JSON；推荐改用 `subscribe`）
- `security` / `content` — `msgSecCheck`（`content.checkText(openid, text, scene)` 为旧入口）
- `subscribe` — 订阅消息 `send` / `sendGetMsgId` / `uniformSend` / `listTemplates` / `getCategory`（类型化 `DataEntry`，推荐入口）
- `analysis` / `operation` — 数据分析 / 运维中心；`privacy` — 隐私设置
- `business` / `order` / `express` / `tcb` / `ocr` / `werun` / `shortlink` / `urllink`
- `riskcontrol` / `redpacketcover` / `minidrama`
- `virtualpayment` — 虚拟支付：余额/扣费（`queryUserBalance` / `currencyPay` / `cancelCurrencyPay`）、
  下单（`queryOrder` / `notifyProvideGoods` / `presentCurrency` / `downloadBill` / `refundOrder`）、
  提现（`createWithdrawOrder` / `queryWithdrawOrder`）、广告金
  （`queryBizBalance` / `queryAdverFunds` / `createFundsBill` / `queryFundsBill` / `queryRecoverBill` / …）、
  商品（`startUploadGoods` / `queryUploadGoods` / `startPublishGoods` / `queryPublishGoods`）、
  下载（`startDownloadOrder` / `queryDownloadOrder`）、
  投诉（`getComplaintList` / `getComplaintDetail` / `getNegotiationHistory` / `responseComplaint` / `completeComplaint`）、
  上传与签名（`uploadVPFile` / `getUploadFileSign`）。
  ⚠️ 这批方法的请求字段以**微信官方文档**为准（与 Go 参考冲突处以官方为准）。

> 完整方法清单见各 `src/miniprogram/<模块>/mod.zig`。

---

## 8. `openplatform` — 开放平台

```zig
pub const Config = struct {
    app_id, app_secret, token, encoding_aes_key: []const u8 = "",
    cache: ?Cache = null,
};

pub const Context = struct {
    config: Config,
    access_token: ?[]const u8 = null,   // component_access_token
    transport / transport_ctx, token_mutex,

    pub fn setAccessToken(self: *Context, token: []const u8) void;
    pub fn getAccessToken(self: *const Context) ?[]const u8;

    // 首次授权链路（src/openplatform/context/auth.zig）
    pub fn getComponentAccessToken(self, allocator, verify_ticket) ![]u8;
    pub fn getPreCode(self, allocator) ![]u8;
    pub fn queryAuthCode(self, allocator, authorization_code) !AuthBaseInfo;
    pub fn getAuthrInfo(self, allocator, authorizer_appid) !std.json.Parsed(AuthrInfoResponse);
    pub fn getComponentLoginPage(self, allocator, redirect_uri, auth_type, biz_app_id) ![]u8;
    pub fn getBindComponentURL(self, allocator, redirect_uri, auth_type, biz_app_id) ![]u8;
    pub fn getBindComponentURLV2(self, allocator, redirect_uri, auth_type, biz_app_id) ![]u8;

    // authorizer_access_token 缓存与刷新（src/openplatform/context/access_token.zig）
    pub fn getAuthrAccessToken(self, allocator, authorizer_appid) ![]u8;
    pub fn refreshAuthrAccessToken(self, allocator, verify_ticket, authorizer_appid, authorizer_refresh_token) !AuthrAccessToken;
};

pub const OpenPlatform = struct {
    ctx: Context,
    pub fn init(ctx: Context) OpenPlatform;
    pub fn newOpenPlatform(cfg: Config) OpenPlatform;
    pub fn getContext(self: *Self) *Context;
    pub fn getAccountManager(self: *Self, allocator) Account;
    pub fn getMiniProgram(self: *OpenPlatform, app_id) OpenMiniProgram;
    pub fn getOfficialAccount(self: *OpenPlatform, app_id) OpenOfficialAccount;
};

pub const Account = struct {   // 第三方平台账号管理（src/openplatform/account/）
    pub fn init(ctx: *Context, allocator) Account;
    pub fn setTransport(self, t: ?Transport, ctx: ?*anyopaque) void;
    pub fn createOpenAccount(self, app_id, authorizer_access_token) ![]u8;
    pub fn getOpenAccount(self, app_id, authorizer_access_token) ![]u8;
    pub fn bind(self, app_id, open_app_id, authorizer_access_token) !void;
    pub fn unbind(self, app_id, open_app_id, authorizer_access_token) !void;
};

pub const OpenMiniProgram = struct {   // 代小程序
    pub fn init(open_context: *Context, app_id) OpenMiniProgram;
    pub fn getContext(self) *Context;
    pub fn getComponent(self) @import("component.zig").Component; // registerMiniProgram / getRegistrationStatus
    pub fn getBasic(self) @import("basic.zig").Basic;             // 账号信息 / 昵称 / 签名 / 头像 / 搜索状态
};

pub const OpenOfficialAccount = struct { // 代公众号（骨架）
    pub fn init(open_context: *Context, app_id) OpenOfficialAccount;
    pub fn getContext(self) *Context;
};
```

> 授权链路时序见 [`../doc/api_guide.md`](../doc/api_guide.md) §9。authorizer token 的刷新**刻意持锁跨 HTTP**（刷新会轮换 refresh_token）。

---

## 9. `work` — 企业微信

```zig
pub const Config = struct {
    corp_id, corp_secret, agent_id: []const u8 = "",
    cache: ?Cache = null,
    ras_private_key: []const u8 = "",          // 消息加密私钥（可选，用于会话存档等场景）
    token: []const u8 = "",                    // 微信客服回调校验 Token
    encoding_aes_key: []const u8 = "",         // 回调消息 EncodingAESKey（43 字符 base64）
};

pub const Context = struct {
    config: Config,
    access_token_handle: AccessTokenHandle,
    js_ticket_handle: ?JsTicketHandle = null,
    pub fn getAccessToken(self, allocator) ...;
    pub fn getJsTicket(self, allocator, access_token) ...;
    pub fn invalidateAccessToken(self, allocator) anyerror!void;
    pub fn invalidateJsTicket(self, allocator) anyerror!void;
};

pub const Work = struct {
    ctx: Context,
    work_ticket_cache: ?WorkJsTicket = null,
    default_ticket_type: TicketType = .corp_js,

    pub fn init(ctx: Context) Work;
    pub fn newWork(cfg, access_token_handle, js_ticket_handle: ?JsTicketHandle) Work;
    pub fn newDefaultWork(cfg: Config, alloc: std.mem.Allocator) !Work;  // 工厂方法，开箱即用
    pub fn deinit(self: *Work, allocator) void;   // 释放 newDefaultWork 分配的 box
    pub fn getContext(self: *Work) *Context;
    pub fn getAccessToken(self: *Work, allocator) ![]u8;
    pub fn getJsTicket(self: *Work, allocator, access_token) ![]u8;   // 遵循 default_ticket_type
    pub fn getCorpJsTicket(self: *Work, allocator, access_token) ![]u8;
    pub fn getAgentJsTicket(self: *Work, allocator, access_token) ![]u8;
    pub fn invalidateJsTicket(self: *Work, allocator, ticket_type) !void;
    pub fn setDefaultTicketType(self: *Work, ticket_type: TicketType) void;
    pub fn setJsTicketHandle(self: *Work, h: JsTicketHandle) void;

    // 14 个懒加载工厂：
    pub fn getJs(self: *Work) jsapi.Js;                    // 不接 allocator
    pub fn getServer(self: *Work) server.WorkServer;       // 不接 allocator
    pub fn getOauth(self, allocator) oauth.Oauth;
    pub fn getMessage(self, allocator) message.Message;
    pub fn getExternalContact(self, allocator) externalcontact.ExternalContact;
    pub fn getInvoice(self, allocator) invoice.Invoice;
    pub fn getAddressList(self, allocator) addresslist.AddressList;
    pub fn getAppChat(self, allocator) appchat.AppChat;
    pub fn getCheckin(self, allocator) checkin.Checkin;
    pub fn getKf(self, allocator) kf.Kf;
    pub fn getMaterial(self, allocator) material.Material;
    pub fn getMsgAudit(self, allocator) msgaudit.MsgAudit;
    pub fn getRobot(self, allocator) robot.Robot;
    pub fn getSmartbot(self, allocator) smartbot.Server;
};

pub const WorkJsTicketAdapter = struct { ... }; // 包装 *Work + TicketType 成 JsTicketHandle
```

`src/work/` 共 **15 个子目录**：`context` 基础设施 + **14 个业务子模块**
（`oauth` / `jsapi` / `message` / `material` / `msgaudit` / `checkin` / `kf` /
`externalcontact` / `invoice` / `addresslist` / `appchat` / `robot` / `server` / `smartbot`），
均遵循 `init(ctx, allocator) + N 个 method` 模式：

- `jsapi` — `getConfig`（corp ticket） / `getAgentConfig`（agent ticket） / `setJsTicketHandle`
- `oauth` — `getRedirectURL` / `userInfoToId` / `getUserInfo` / `getUserDetail`
- `externalcontact` — 客户联系全量（客户/标签/群/联系我/离职继承/群发/朋友圈/客户规则/获客助手）
- `kf` — 客服服务端 API（账号/消息/升级服务/知识库/统计）+ 富媒体收发 + `OriginData` 原始 JSON 回捕
- `addresslist` — 部门/成员/标签/互转/邀请/互联企业
- `msgaudit` — 仅元数据接口（`getRoomInfo` / `getAgreeInfo`）；**消息解密不做**（依赖官方闭源 SDK）
- `server` — `WorkServer`：回调 `msg_signature` 校验 + `ReceiveID` 解密验证
- 其余 `message` / `material` / `checkin` / `invoice` / `appchat` / `robot` / `smartbot`

> 完整方法清单见各 `src/work/<模块>/mod.zig`。

---

## 10. `minigame` — 小游戏

```zig
pub const Config = struct {
    app_id: []const u8 = "",
    app_secret: []const u8 = "",
    cache: ?Cache = null,
};

pub const Context = struct { config: Config, access_token_handle: AccessTokenHandle };

pub const MiniGame = struct {
    ctx: Context,
    pub fn init(ctx: Context) MiniGame;
    pub fn newMiniGame(cfg: Config, default_access_token: AccessTokenHandle) MiniGame;
    pub fn getContext(self: *Self) *Context;
    pub fn getAccessToken(self: *Self, allocator) ...;
};
```

> 对应 `src/minigame/`。上游 Go 侧小游戏只有 README；本 Zig 版按"小游戏 = 小程序子集"落地顶层容器，
> 尚无 `getXxx()` 业务子模块。

---

## 11. `aispeech` — 智能对话（骨架）

```zig
pub const AiSpeech = struct {
    _placeholder: u8 = 0,
    pub fn init() AiSpeech;
};
```

> 对应 `src/aispeech/mod.zig`，上游 Go 侧同样为空实现。

---

## 12. `middleware` — Web 框架回调中间件

```zig
pub const handler = @import("wechat_handler.zig");
pub const CallbackQuery = struct { ... };
pub const DecryptedMessage = struct { ... };

pub fn parseCallbackQuery(query_string: []const u8) !CallbackQuery;
pub fn verifyServerSignature(...) !bool;
pub fn verifyURL(...) !bool;
pub fn handleServerMessage(...) !DecryptedMessage;   // AES 解密 + 验签
```

> 对应 `src/middleware/wechat_handler.zig`，专为 zfinal / zigmodu 等框架提供服务端 URL 签名校验与消息解密。

---

## 错误集速查

| 错误集 | 变体 |
|---|---|
| `CacheError` | `NotFound`, `TypeMismatch`, `StorageError`, `OutOfMemory` |
| `CredentialError` | `ApiError`, `HttpError`, `DecodeError`, `ConfigMissing`（+ 标准 std.json / Allocator / CacheError）|
| `WechatError` | `ApiError`, `NetworkError`, `DecodeError`, `AccessTokenExpired`, `ConfigMissing`, `InvalidArgument` |
| `WechatErrorDecodeError` | `WechatError` + `OutOfMemory` |
| `RsaError` | `RsaNotImplemented`, `InvalidPemKey`, `InvalidSignature`, `InvalidCiphertext`, `OutOfMemory` |
| `P12Error` | `P12NotImplemented`, `InvalidP12File`, `BadPassword`, `OutOfMemory` |
| `Ed25519Error` | `InvalidSecretKey`, `InvalidPublicKey`, `InvalidSignature`, `SigningFailed` |
| `NotifyError`（pay/v3） | 回调验签 / 解密相关（见 `src/pay/v3/notify.zig`） |

> 另有两个 mTLS 专属错误变体（`postXMLWithTLS`，见 §4）：`error.MtlsNotEnabled`（`-Dmtls=false`，默认）与 `error.OpenSslNotAvailable`（运行期缺 `libssl`/`libcrypto`）。
> 微信接口的 `errcode` 不随错误变体传出，而是记录在线程局部槽位，用 `util.error.lastErrorDetail()` 读取。