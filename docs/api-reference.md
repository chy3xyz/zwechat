# 公共 API 索引

本文档列出 `zwechat` 全部公共 API 的入口点。完整签名请查阅源代码中的 `///` 中文 doc 注释。

> 所有 API 都遵循 **`Allocator` 显式传递** 约定：调用方负责分配器生命周期，返回的 `[]u8` 由调用方 `free`。

---

## 0. 顶层（`src/root.zig`）

```zig
pub const version: []const u8
pub const wechat = @import("wechat.zig")
pub const cache = @import("cache/mod.zig")
pub const credential = @import("credential/mod.zig")
pub const util = @import("util/mod.zig")
pub const officialaccount = @import("officialaccount/mod.zig")
```

---

## 1. `wechat` — 顶层容器

### `Wechat`

```zig
pub const Wechat = struct {
    cache: ?Cache = null,

    pub fn init() Wechat;
    pub fn setCache(self: *Wechat, c: Cache) void;
    pub fn getOfficialAccount(
        self: *Wechat,
        allocator: std.mem.Allocator,
        cfg: officialaccount.Config,
        default_access_token_factory: *const fn (...) anyerror!AccessTokenHandle,
    ) !OfficialAccount;
};
```

---

## 2. `cache` — 缓存抽象

### `Cache` (vtable 接口)

```zig
pub const CacheError = error{ NotFound, TypeMismatch, StorageError, OutOfMemory };

pub const Cache = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn get(self: Cache, key: []const u8) CacheError!?[]const u8;
    pub fn set(self: Cache, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void;
    pub fn isExist(self: Cache, key: []const u8) CacheError!bool;
    pub fn delete(self: Cache, key: []const u8) CacheError!void;
    pub fn deinit(self: Cache) void;
};
```

### `Memory`

```zig
pub const Memory = struct {
    pub fn create(allocator: std.mem.Allocator) !*Memory;
    pub fn deinit(self: *Memory) void;
    pub fn asCache(self: *Memory) Cache;
};
```

### `Redis`

```zig
pub const Redis = struct {
    pub const Options = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 6379,
        password: ?[]const u8 = null,
        db: i32 = 0,
        io: ?std.Io = null,  // 外部 Io 句柄，未提供时自行创建
    };

    pub fn create(allocator: std.mem.Allocator, opts: Options) !*Redis;
    pub fn deinit(self: *Redis) void;
    pub fn asCache(self: *Redis) Cache;
};
```

---

## 3. `credential` — 凭据管理

### 公共抽象

```zig
pub const AccessTokenHandle = struct {
    pub fn getAccessToken(self: AccessTokenHandle, allocator: std.mem.Allocator) ![]u8;
};

pub const JsTicketHandle = struct {
    pub fn getTicket(self: JsTicketHandle, allocator: std.mem.Allocator, access_token: []const u8) ![]u8;
};

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
    pub fn init(app_id, app_secret, cache_key_prefix, cache) DefaultAccessToken;
    pub fn initWithFetcher(...) DefaultAccessToken; // 测试用
    pub fn getAccessToken(self: *DefaultAccessToken, allocator) ![]u8;
    pub fn asHandle(self: *DefaultAccessToken) AccessTokenHandle;
};
```

### `DefaultJsTicket`（公众号）

```zig
pub const DefaultJsTicket = struct {
    pub fn init(app_id, cache_key_prefix, cache) DefaultJsTicket;
    pub fn getTicket(self: *DefaultJsTicket, allocator, access_token) ![]u8;
    pub fn asHandle(self: *DefaultJsTicket) JsTicketHandle;
};
```

### `WorkAccessToken`（企业微信）

```zig
pub const workAccessTokenURL = "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid={s}&corpsecret={s}";

pub const WorkAccessToken = struct {
    pub fn init(corp_id, corp_secret, cache_key_prefix, cache) WorkAccessToken;
    pub fn getAccessToken(self: *WorkAccessToken, allocator) CredentialError![]u8;
    pub fn asHandle(self: *WorkAccessToken) AccessTokenHandle;
};
```

### `WorkJsTicket`（企业微信 corp + agent）

```zig
pub const TicketType = enum { corp_js, agent_js };

pub const WorkJsTicket = struct {
    pub fn init(corp_id, agent_id, cache_key_prefix, cache) WorkJsTicket;
    pub fn initWithFetcher(...) WorkJsTicket;
    pub fn getTicket(
        self: *WorkJsTicket,
        allocator: std.mem.Allocator,
        access_token: []const u8,
        ticket_type: TicketType,
    ) CredentialError![]u8;
};
```

---

## 4. `util` — 通用工具集

### `util/http` — HTTP 客户端 + Mock

```zig
pub const HttpClient = struct {
    pub fn init(allocator: std.mem.Allocator) HttpClient;
    pub fn deinit(self: *HttpClient) void;

    pub fn get(self: *HttpClient, uri: []const u8) ![]u8;
    pub fn post(self: *HttpClient, uri: []const u8, body: []const u8, content_type: ?[]const u8) ![]u8;
    pub fn postJSON(self: *HttpClient, uri: []const u8, body: []const u8) ![]u8;
    pub fn postXML(self: *HttpClient, uri: []const u8, body: []const u8) ![]u8;
    pub fn postMultipart(self: *HttpClient, uri: []const u8, fields: []const MultipartField) ![]u8;
    pub fn postXMLWithTLS(self: *HttpClient, uri: []const u8, body: []const u8, p12_path: []const u8, p12_password: []const u8) ![]u8; // 占位

    /// 注入自定义 transport（用于 Mock / 测试）
    pub fn setTransport(self: *HttpClient, t: ?Transport, ctx: ?*anyopaque) void;
};

pub fn getDefaultClient(allocator: std.mem.Allocator) *HttpClient;
pub fn setUriModifier(m: ?UriModifier) void;

pub const MockTransport = struct {
    pub fn init(allocator: std.mem.Allocator) MockTransport;
    pub fn deinit(self: *MockTransport) void;
    pub fn addRoute(self: *MockTransport, uri: []const u8, response: Response) !void;
    pub fn dispatch(ctx, allocator, uri, method, payload, content_type) anyerror![]u8;
};
```

### `util/crypto` — 加解密

```zig
pub const SignTypeMD5 = "MD5";
pub const SignTypeHMACSHA256 = "HMAC-SHA256";

pub fn calculateSign(allocator, content, sign_type, key) ![]u8;
pub fn aesEncryptMsg(allocator, random_16B, raw_xml_msg, app_id, aes_key) ![]u8;
pub fn aesDecryptMsg(allocator, ciphertext, aes_key) !struct { random, raw_xml_msg, app_id };
pub fn pkcs7Pad(allocator, data, block_size) ![]u8;
pub fn pkcs7Unpad(data) []const u8;
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

pub const CommonError = struct {
    api_name: []const u8,
    errcode: i64,
    errmsg: []const u8,
    pub fn format(self: CommonError, allocator) ![]u8;
};

pub fn decodeWithCommonError(allocator, response, api_name) !?CommonError;
```

### `util/rsa` — 签名（RSA-SHA256 PKCS#1 v1.5 + Ed25519 native）

```zig
// RSA-SHA256 PKCS#1 v1.5（已可用）
pub fn rsaSign(allocator, content, private_key_pem) RsaError![]u8;
pub fn rsaVerify(allocator, content, signature_b64, public_key_pem) RsaError!bool;

// PKCS#12（已可用：PBES2 + PBKDF2-HMAC-SHA256 + AES-256-CBC）
pub fn parseP12(allocator, p12_bytes, password) P12Error!struct { cert_pem, key_pem };
pub fn p12Available() bool;

// Ed25519（Zig 0.17 native，可用）
pub fn ed25519GenerateKeyPair(allocator) !struct { secret_key: [64]u8, public_key: [32]u8 };
pub fn ed25519Sign(allocator, secret_key_bytes, message) Ed25519Error![]u8; // 返回 64 字节
pub fn ed25519Verify(signature, message, public_key_bytes) Ed25519Error!bool;

// PEM 粗略格式检查
pub fn looksLikeRsaPrivateKeyPem(pem) bool;
pub fn looksLikeRsaPublicKeyPem(pem) bool;
```

### `util/time`

```zig
pub fn getCurrTS() i64;  // 当前 Unix 秒
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
```

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
};
```

### `OfficialAccount`

```zig
pub const OfficialAccount = struct {
    ctx: Context,
    pub fn init(ctx: Context) OfficialAccount;
    pub fn getContext(self: *OfficialAccount) *Context;
    pub fn getAccessToken(self: *OfficialAccount, allocator) ![]u8;
};
```

### `officialaccount/menu`

```zig
pub const Menu = struct {
    pub fn init(ctx: *Context, allocator) Menu;
    pub fn setMenu(self: *Menu, buttons: []const Button) !void;
    pub fn getMenu(self: *Menu) !ResMenu;
    pub fn deleteMenu(self: *Menu) !void;
    pub fn addConditional(self: *Menu, buttons, match_rule) !void;
    pub fn menuTryMatch(self: *Menu, user_id) ![]Button;
};

pub const Button = struct {
    pub fn setClick(name, key) Button;
    pub fn setView(name, url) Button;
    pub fn setScanCodePush(name, key) Button;
    // ... 共 11 种类型 + setSub
};
```

### `officialaccount/oauth`

```zig
pub const Oauth = struct {
    pub fn init(ctx, allocator) Oauth;
    pub fn getRedirectURL(self, redirect_uri, scope, state) ![]u8;
    pub fn getUserAccessToken(self, code) !ResAccessToken;
    pub fn refreshAccessToken(self, refresh_token) !ResAccessToken;
    pub fn checkAccessToken(self, access_token, open_id) !bool;
    pub fn getUserInfo(self, access_token, open_id, lang) !UserInfo;
};
```

### `officialaccount/basic`

```zig
pub const Basic = struct {
    pub fn init(ctx, allocator) Basic;
    pub fn getCallbackIP(self: *Basic) ![]const []const u8;
    pub fn getAPIDomainIP(self: *Basic) ![]const []const u8;
    pub fn clearQuota(self: *Basic) !void;
};
```

### `officialaccount/js`

```zig
pub const Js = struct {
    pub fn init(ctx: *Context) Js;
    pub fn setJsTicketHandle(self: *Js, h: JsTicketHandle) void;
    pub fn getConfig(self: *Js, allocator, uri) !Config;
};
```

### `officialaccount/server`

```zig
pub const Server = struct {
    pub fn init(ctx, allocator) Server;
    pub fn setMessageHandler(self, handler, ctx) void;
    pub fn setRawBody(self, body) void;
    pub fn validateSignature(self, q) ![]u8;
    pub fn validateURL(self, q) !bool;
    pub fn buildReply(self, to_user, from_user, content) ![]u8;
    pub fn buildEncryptedReply(self, to_user, from_user, content, timestamp, nonce) ![]u8;
    pub fn serve(self, q) ![]u8;
};
```

### `officialaccount/message`

```zig
pub const MsgType = enum { text, image, voice, video, miniprogrampage, shortvideo, location, link, music, news, transfer_customer_service, event };
pub const EventType = enum { ... };
pub const MixMessage = struct { ... };
pub const EncryptedXMLMsg = struct { ... };
pub const TemplateMessage = struct { ... };

pub const Message = struct {
    pub fn init(ctx, allocator) Message;
    pub fn sendTemplate(self, msg) !i64;
    pub fn sendCustomerText(self, msg) !void;
};

pub const Reply = struct { ... };
pub const ReplyMsgType = enum { text, image, voice, video, music, news, transfer_customer_service };
pub const TextReply, ImageReply, VoiceReply, VideoReply, MusicReply, NewsReply, MiniprogramPageReply = ...;
```

### `officialaccount/material`

```zig
pub const Material = struct {
    pub fn init(ctx, allocator) Material;
    pub fn addNews(self, articles) ![]const u8;
    pub fn deleteMaterial(self, media_id) !void;
    pub fn getMaterialCount(self) !ResMaterialCount;
    pub fn batchGetMaterial(self, mtype, offset, count) !ArticleList;
};
```

### 其他 `officialaccount` 子模块

`user` / `datacube` / `broadcast` / `device` / `customerservice` / `ocr` / `draft` / `freepublish` 同样遵循 `init(ctx, allocator) + 2-3 个 method` 的模式。详细签名查阅对应 `.zig` 文件。

---

## 6. `pay` — 微信支付

### `Config`

```zig
pub const Config = struct {
    app_id: []const u8 = "",
    mch_id: []const u8 = "",
    key: []const u8 = "",
    notify_url: []const u8 = "",
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

pub const Order = struct {
    pub fn init(cfg: Config) Order;
    pub fn prePayOrder(self: *Self, allocator, p: Params) !PreOrder;
    pub fn bridgeConfig(self: *Self, allocator, p, pre_order) !BridgeConfig;
};
```

### `pay/refund`

```zig
pub const RefundParams = struct {
    out_trade_no, out_refund_no, total_fee, refund_fee, notify_url: []const u8,
    refund_desc: []const u8 = "",
};

pub const Refund = struct {
    pub fn init(cfg: Config) Refund;
    pub fn refund(self: *Self, allocator, p: RefundParams) !RefundResult;
};
```

### `pay/notify`

```zig
pub fn verifyPaidNotify(allocator: std.mem.Allocator, cfg: Config, xml_body: []const u8) !bool;

pub const Notify = struct {
    pub fn init(cfg: Config) Notify;
    pub fn decryptRefund(self: *Self, allocator, req_info_b64) ![]u8;
};
```

### `pay/transfer` / `pay/redpacket`

同样遵循 `init(cfg) + transfer/send method` 模式。

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
};

pub const MiniProgram = struct {
    ctx: Context,
    pub fn init(allocator, cfg, access_token_handle) MiniProgram;
    pub fn getContext(self: *MiniProgram) *Context;
    pub fn getAuth(self: *Self) Auth;
};

pub const Auth = struct {
    pub fn init(ctx: *Context, allocator) Auth;
    pub fn code2Session(self, js_code) !ResCode2Session;
    pub fn getPhoneNumber(self, code) !GetPhoneNumberResponse;
    pub fn checkEncryptedData(self, encrypted_msg_hash) !RspCheckEncryptedData;
    pub fn checkSession(self, signature, open_id) !void;
};
```

---

## 8. `openplatform` — 开放平台

```zig
pub const Config = struct {
    app_id, app_secret, token, encoding_aes_key: []const u8 = "",
    cache: ?Cache = null,
};

pub const Context = struct { config: Config, access_token: ?[]const u8 = null };

pub const OpenPlatform = struct {
    ctx: Context,
    pub fn init(ctx: Context) OpenPlatform;
    pub fn getAccountManager(self: *OpenPlatform) Account;
    pub fn getMiniProgram(self: *OpenPlatform, app_id) OpenMiniProgram;
    pub fn getOfficialAccount(self: *OpenPlatform, app_id) OpenOfficialAccount;
};
```

---

## 9. `work` — 企业微信

```zig
pub const Config = struct {
    corp_id, corp_secret, agent_id: []const u8 = "",
    cache: ?Cache = null,
};

pub const Context = struct {
    config: Config,
    access_token_handle: AccessTokenHandle,
    js_ticket_handle: ?JsTicketHandle = null,
};

pub const Work = struct {
    ctx: Context,
    work_ticket_cache: ?WorkJsTicket = null,
    default_ticket_type: TicketType = .corp_js,

    pub fn init(ctx: Context) Work;
    pub fn newWork(cfg, access_token_handle, js_ticket_handle) Work;
    pub fn newDefaultWork(cfg: Config, alloc: std.mem.Allocator) !Work;  // 工厂方法
    pub fn getContext(self: *Work) *Context;
    pub fn getAccessToken(self: *Work, allocator) ![]u8;
    pub fn getJsTicket(self: *Work, allocator, access_token) ![]u8;
    pub fn setDefaultTicketType(self: *Work, ticket_type: TicketType) void;
    pub fn setJsTicketHandle(self: *Work, h: JsTicketHandle) void;
};
```

12 个子模块（`oauth` / `jsapi` / `message` / `material` / `msgaudit` / `checkin` / `kf` / `externalcontact` / `invoice` / `addresslist` / `appchat` / `robot`）同样遵循 `init(ctx, allocator) + 2-3 个 method` 模式。

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
};
```

---

## 11. `aispeech` — 智能对话（骨架）

```zig
pub const AiSpeech = struct {
    pub fn init() AiSpeech;
};
```

---

## 错误集速查

| 错误集 | 变体 |
|---|---|
| `CacheError` | `NotFound`, `TypeMismatch`, `StorageError`, `OutOfMemory` |
| `CredentialError` | `ApiError`, `HttpError`, `DecodeError`, `ConfigMissing`（+ 标准 std.json / Allocator 错误）|
| `WechatError` | `ApiError`, `NetworkError`, `DecodeError`, `AccessTokenExpired`, `ConfigMissing`, `InvalidArgument` |
| `RsaError` | `RsaNotImplemented`, `InvalidPemKey`, `InvalidSignature`, `OutOfMemory` |
| `P12Error` | `P12NotImplemented`, `InvalidP12File`, `BadPassword` |
| `Ed25519Error` | `InvalidSecretKey`, `InvalidPublicKey`, `InvalidSignature`, `SigningFailed` |