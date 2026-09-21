# 升级指南（Upgrading zwechat）

面向**下游消费者**：把 `zwechat` 作为 submodule / git tag 依赖、跟着 tag 走的项目
（例如 `heysen_saas` 的 `api/zwechat`）。

本文只回答一个问题：**从 vA 拉到 vB，我需要改哪几行？**
不改代码会不会炸（编译失败）、或者更糟——不炸但行为悄悄变了（静默）。

版本演进的完整叙述见 [`../CHANGELOG.md`](../CHANGELOG.md)；
接口的当前形状见 [`api-reference.md`](api-reference.md)、[`../doc/api_guide.md`](../doc/api_guide.md)
与源码（本文每条都给出 `src/...:行号`，源码是唯一权威）。

> **版本锚点**：本文的"当前"= **v0.4.4**（`build.zig.zon` 的 `.version = "0.4.4"`，
> 发版提交 `4640e65`）。所有 `after` 代码块都已逐个 `grep` 比对源码签名，
> 并标出 `src/...:行号`。
>
> ⚠️ **行号会随并行改动漂移**：撰写期间仓库里正有若干重构落地
> （`util/uri.zig` / `util/json.zig` 的编码收敛、`cache/redis` 可选连接池等），
> 它们**可能不在 v0.4.4 tag 里**。因此本文给的 `src/...:行号` 是"查找锚点"，
> 不是"契约"——行号对不上时请用 `grep` 按符号名定位；
> 判断某个新能力是否存在于你的 checkout，也一律以 `grep` 为准
> （例：`grep -n "max_connections" src/cache/redis.zig`）。

---

## 0. 先看这里：我要改多少行？

| 升级路径 | 是否必须改调用方代码 | 说明 |
|---|---|---|
| v0.4.3 → **v0.4.4** | **是**（约 6~8 处调用点） | 见 §1.1，12 条变更中有 9 条会编译失败 |
| v0.3.0 → v0.4.4 | 是（在上一行基础上叠加） | 另需处理 v0.4.0 之后新增的 `Parsed(T)` 迁移，见 §1.4 |
| v0.4.2 → v0.4.3 | 否 | v0.4.3 只修了库内部的编译错误 |
| v0.2.0 → v0.4.4 | 是 | 中间跨越 0.3.0 的所有权变更（`Parsed(T)`），见 §1.4 |

**判断成本的最快方法**：拉完新 tag 后直接 `zig build test`（或你自己的入口构建）。
Zig 是编译期检查语言，**签名变更全部会变成编译错误**，编译器会把要改的点一个个指给你。
真正危险的是 §1.2 那几条"不改也能编译过"的条目——请务必读完。

---

## 1. 版本升级速查

### 1.1 v0.4.3 → v0.4.4：破坏性 / 必须改的变更

共 **9 条会编译失败的变更** + **3 条弃用标注**。逐条对照你的调用点。

---

#### ① `miniprogram/content.checkText` 新增 `openid` / `scene` 必填参数

- **变更**：`checkText(text)` → `checkText(openid, text, scene)`。
  `msg_sec_check` 的 `openid` / `scene` 在微信侧是必填，旧签名无法构造合法请求。
- **源码**：`src/miniprogram/content/mod.zig:54`
  `pub fn checkText(self: *Self, openid: []const u8, text: []const u8, scene: u8) ![]u8`
  `scene` 取值：1=资料，2=评论，3=论坛，4=社交日志。
- **不迁移的后果**：编译失败（`expected 3 arguments, found 1`）。

```zig
// ❌ v0.4.3
const resp = try mp.getContent().checkText(text);
defer allocator.free(resp);
```

```zig
// ✅ v0.4.4
const resp = try mp.getContent().checkText(openid, text, 2);
defer allocator.free(resp);
```

> **顺带建议**：`getContent()` 已在 v0.4.4 标注弃用，等价入口是
> `mp.getSecurity().msgSecCheck(allocator, openid, content, scene)`
> （`src/miniprogram/security/mod.zig:32`；注意 `Security.init` 只收 `ctx`，
> 没有 allocator，所以 allocator 要传给方法）。两版契约等价，可一次迁移到位。

---

#### ② `officialaccount/customerservice.listAccounts` 改为返回类型化 `Parsed(KfListResponse)`

- **变更**：返回值由**未类型化的原始 JSON** 改为 `std.json.Parsed(KfListResponse)`，
  且失败（`errcode != 0`）时抛 `WechatError.ApiError` 而不是把错误体原样交给你。
- **源码**：`src/officialaccount/customerservice/mod.zig:202`
  `pub fn listAccounts(self: *Self) !std.json.Parsed(KfListResponse)`
  客服条目在 `.value.kf_list`（`[]KeFuInfo`），
  `KeFuInfo` 见 `src/officialaccount/customerservice/mod.zig:11`（公开类型）。
  注意 `KfListResponse` 本身是文件内 `const`（`src/officialaccount/customerservice/mod.zig:19`），
  **不导出**——你不需要写出类型名，靠类型推导访问字段即可。
- **不迁移的后果**：编译失败（旧代码对 `[]u8` 调用 `std.json.parseFromSlice` 的那行；
  或旧的 `defer allocator.free(resp)` 会报类型不符）。
- 若你 v0.4.3 的代码里 `listAccounts()` 的结果**已经**是 `Parsed(...)`，
  说明你在更早的 0.3.x 就迁过所有权，只需按下面调整字段访问与 `deinit`。

```zig
// ❌ v0.4.3（未类型化原始 JSON：自己 parse、自己判 errcode、自己 free）
const body = try cs.listAccounts();
defer allocator.free(body);
var parsed = try std.json.parseFromSlice(MyKfList, allocator, body, .{});
defer parsed.deinit();
for (parsed.value.kf_list) |kf| { ... }
```

```zig
// ✅ v0.4.4
const parsed = try cs.listAccounts();
defer parsed.deinit();
for (parsed.value.kf_list) |kf| {
    std.debug.print("{s} / {s}\n", .{ kf.kf_account, kf.nickname });
}
```

---

#### ③ `officialaccount/user.OpenidList.openids` → `.data.openid`

- **变更**：微信 `cgi-bin/user/get` 的真实响应把 openid 数组放在 `data.openid` 里，
  旧结构把 `openids` 放在顶层，永远解析为空。字段整体下移一层。
- **源码**：`src/officialaccount/user/mod.zig:32`

```zig
pub const OpenidList = struct {
    total: i64 = 0,
    count: i64 = 0,
    next_openid: []const u8 = "",
    data: struct {
        openid: []const []const u8 = &.{},
    } = .{},
};
```

- 影响面：`getOpenidList(next_openid)`（`src/officialaccount/user/mod.zig:154`，返回 `!std.json.Parsed(OpenidList)`）
  与 `getBlackList(begin_openid)`（`src/officialaccount/user/mod.zig:331`）的**同结构**返回值。
- **不迁移的后果**：**编译失败**（`no field named 'openids'`）。这一条是好事——
  旧字段名在新结构里根本不存在，编译器会拦住你。

```zig
// ❌ v0.4.3
const parsed = try oa.getUser().getOpenidList("");
defer parsed.deinit();
for (parsed.value.openids) |id| { ... }
```

```zig
// ✅ v0.4.4
const parsed = try oa.getUser().getOpenidList("");
defer parsed.deinit();
for (parsed.value.data.openid) |id| { ... }
```

> **顺带**：如果你只是为了"拿全部 openid"，v0.4.4 新增了分页封装，
> 自带游标不推进的兜底（避免死循环），直接返回 `[]const []const u8`：
> `listAllUserOpenIDs()`（`src/officialaccount/user/mod.zig:358`）
> 与 `getAllBlackList()`（`src/officialaccount/user/mod.zig:396`）。
> 用它们可以彻底绕开对 `OpenidList` 字段布局的依赖。

---

#### ④ `openplatform/account` 四方法的签名改为接收 `authorizer_access_token`

- **变更**：`createOpenAccount` / `getOpenAccount` / `bind` / `unbind` 从"只收 appid、
  不注入 token"改为**多收一个 `authorizer_access_token` 参数**，并以 `?access_token=` 注入 URL。
  修复前误用了 component token 且 URL 上没有 token，调用必然被微信拒绝。
- **源码**：`src/openplatform/account/mod.zig:61`（createOpenAccount）、`:101`（getOpenAccount）、
  `:139`（bind）、`:174`（unbind）。签名形状：

```zig
pub fn createOpenAccount(self: *Self, app_id: []const u8, authorizer_access_token: []const u8) ![]u8;
pub fn getOpenAccount(self: *Self, app_id: []const u8, authorizer_access_token: []const u8) ![]u8;
pub fn bind(self: *Self, app_id: []const u8, open_app_id: []const u8, authorizer_access_token: []const u8) !void;
pub fn unbind(self: *Self, app_id: []const u8, open_app_id: []const u8, authorizer_access_token: []const u8) !void;
```

- **不迁移的后果**：编译失败（参数个数不符）。**注意**：旧签名即使能编译，
  线上也会拿到 `errcode != 0`——所以这不是"可以拖一拖"的变更。
- `authorizer_access_token` 从哪来：新增的
  `Context.getAuthrAccessToken(allocator, authorizer_appid)`（`src/openplatform/context/mod.zig:82`，
  带缓存，缓存 key `authorizer_access_token_{appid}`）与
  `refreshAuthrAccessToken(...)`（`src/openplatform/context/mod.zig:101`，
  走 `api_authorizer_token`）。完整链路见 [`../doc/api_guide.md`](../doc/api_guide.md) §9。

```zig
// ❌ v0.4.3（签名不含 token）
const open_appid = try account.createOpenAccount(app_id);
```

```zig
// ✅ v0.4.4
const authr_token = try op.getContext().getAuthrAccessToken(allocator, app_id);
defer allocator.free(authr_token);

const open_appid = try account.createOpenAccount(app_id, authr_token);
defer allocator.free(open_appid);
```

---

#### ⑤ `middleware.handleServerMessage` 新增 `expected_app_id` 参数

- **变更**：解密后**强制校验**消息尾部携带的 AppID 与预期接收方一致，不一致返回
  `error.AppIDMismatch`（防跨账号伪造消息）。因此必须把"你是谁"传进去。
- **源码**：`src/middleware/wechat_handler.zig:120`

```zig
pub fn handleServerMessage(
    allocator: std.mem.Allocator,
    aes_key: []const u8,
    expected_app_id: []const u8,
    encrypted_xml: []const u8,
) !DecryptedMessage
```

- 参数位置：`expected_app_id` 插在 `aes_key` 与 `encrypted_xml` 之间（**不是**追加在末尾）。
- `aes_key` 校验：长度必须为 32 字节（原始 AES key），否则 `error.InvalidArgument`。
- **不迁移的后果**：编译失败。若你把 `encrypted_xml` 传到了 `expected_app_id` 的位置，
  类型都是 `[]const u8`，编译器**不会**报错，但运行期会立刻 `error.AppIDMismatch`——
  请按参数名核对位置。

```zig
// ❌ v0.4.3
var msg = try handleServerMessage(allocator, aes_key, encrypted_xml);
defer msg.deinit(allocator);
```

```zig
// ✅ v0.4.4
var msg = try handleServerMessage(allocator, aes_key, cfg.app_id, encrypted_xml);
defer msg.deinit(allocator);
```

---

#### ⑥ 删除 `work/material.getMediaList`

- **变更**：该端点（`/cgi-bin/material/get_materiallist`）**在企业微信侧不存在**，
  旧方法无论如何都拿不到数据，故整方法删除，**没有同名替代品**。
- **源码**：`src/work/material/mod.zig`（v0.4.4 中确认不存在 `getMediaList`；
  可用方法为 `upload`（:116）、`getTempFile`（:163）、`getTempFileWithLimit`（:175）、
  `getTempFileToFile`（:187）、`getTempFileToFileWithLimit`（:198））。
- **不迁移的后果**：编译失败（`no field or member function named 'getMediaList'`）。
- **迁移做法**：企业微信没有"素材列表"接口。请改为**自己记账**
  ——上传时把返回的 `media_id`（`UploadResponse.media_id`）落到你的库里，
  下载时用 `getTempFile` / `getTempFileToFile` 按 id 拉取。

---

#### ⑦ `work/msgaudit.getRoomInfo` 重写（真实端点 + 新响应结构）

- **变更**：端点从旧路径改为真实的
  `POST /cgi-bin/msgaudit/groupchat/get`（`src/work/msgaudit/mod.zig:30`），
  请求体 `{"roomid":"..."}`，响应结构整体替换。
- **入参签名不变**：`getRoomInfo(self: *Self, roomid: []const u8) !std.json.Parsed(RoomInfoResponse)`
  （`src/work/msgaudit/mod.zig:120`）。
- **变的是响应类型**（`src/work/msgaudit/mod.zig:42`）：

```zig
pub const RoomInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    roomname: []const u8 = "",
    creator: []const u8 = "",
    room_create_time: i64 = 0,
    notice: []const u8 = "",
    members: []RoomMember = &.{},   // RoomMember { memberid: []const u8 }
};
```

- **不迁移的后果**：**静默行为变化**——如果你的旧代码是 `std.json.parseFromSlice` 到自定义
  结构体（而不是用 SDK 的 `RoomInfoResponse`），改端点后字段可能全部解析成默认值 `""`/`0`，
  编译器不会提醒你。请对照上面的字段名逐个核对（`members[].memberid` 尤其容易漏）。

```zig
// ✅ v0.4.4
const parsed = try audit.getRoomInfo(roomid);
defer parsed.deinit();
for (parsed.value.members) |m| std.debug.print("{s}\n", .{m.memberid});
```

---

#### ⑧ `work/msgaudit.getAgreeInfo` 重写（入参结构 + 响应结构）

- **变更**：端点改为真实的 `POST /cgi-bin/msgaudit/check_single_agree`
  （`src/work/msgaudit/mod.zig:34`）。**签名与响应结构均为重写**，
  CHANGELOG 将其列为"公开 API 变更"。
- **v0.4.4 签名**（`src/work/msgaudit/mod.zig:161`）：

```zig
pub fn getAgreeInfo(self: *Self, req: AgreeInfoRequest) !std.json.Parsed(AgreeInfoResponse)
```

相关类型（`src/work/msgaudit/mod.zig:65` / `:74` / `:82` / `:93`）：

```zig
pub const AgreeInfoRequest = struct { info: []const AgreeInfoEntry = &.{} };
pub const AgreeInfoEntry = struct { userid: []const u8 = "", exteranalopenid: []const u8 = "" };

pub const AgreeInfo = struct {
    status_change_time: i64 = 0,
    userid: []const u8 = "",
    exteranalopenid: []const u8 = "",
    agree_status: []const u8 = "",   // "Agree" / "Disagree"
};
pub const AgreeInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    agreeinfo: []AgreeInfo = &.{},
};
```

- **⚠️ v0.4.3 的确切旧签名请以你本地的 v0.4.3 checkout 为准**——这是一次整体重写，
  不是加一个参数，本文不复述旧形状以免误导。迁移目标形状就是上面两个 `pub const`。
- **注意拼写**：字段名是微信官方笔误 `exteranalopenid`（少一个 `n`），
  请求和响应都使用这个拼写。**不要"修正"成 `externalopenid`**，
  否则 `.ignore_unknown_fields = true` 会让你静默拿到空串。
- **不迁移的后果**：入参结构不同 → 编译失败；响应字段不同 → 静默零值。

---

#### ⑨ `work/appchat` 响应结构：`ChatInfo` 增加 `chat_info` 内层，`chat_id` → `chatid`

- **变更**：企业微信 `GET /cgi-bin/appchat/get` 的真实返回把群字段包在 `chat_info` 里，
  key 也是 `chatid`（不是 `chat_id`）。旧结构平铺在顶层，永远解析为空。
- **源码**：`src/work/appchat/mod.zig:36`

```zig
pub const ChatInfo = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    chat_info: ChatInfoInner = .{},
};

pub const ChatInfoInner = struct {   // src/work/appchat/mod.zig:42
    chatid: []const u8 = "",
    name: []const u8 = "",
    owner: []const u8 = "",
    userlist: [][]const u8 = &.{},
};

pub const CreateChatResponse = struct {  // src/work/appchat/mod.zig:58
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    chatid: []const u8 = "",   // 旧字段名 chat_id
};
```

- **不迁移的后果**：**静默零值**（不是编译错误！）。
  字段名是字符串、缺字段时 `std.json` 用默认值 `""`，所以
  `resp.value.name` 会变成空串、`resp.value.userlist` 变成空数组，
  而 `chat_info` 那层如果被忽略，你会以为"这个群没有成员"。
  请把 `.chat_info.chatid` / `.chat_info.name` / `.chat_info.userlist` 逐字核对。

---

### 1.2 v0.4.3 → v0.4.4：**不改也能编译过**，但契约变了

这几条不报编译错，是升级中最容易"升完看起来没事、线上悄悄变错"的地方。

#### ⑩ `miniprogram/auth.checkEncryptedData` 请求体改为 JSON

- **变更**：请求体改为 JSON（此前构造出的体是非法的）。
- **签名不变**：`checkEncryptedData(self: *Self, encrypted_msg_hash: []const u8) !std.json.Parsed(RspCheckEncryptedData)`
  （`src/miniprogram/auth/mod.zig:156`）。
- **影响**：调用点无需改，但如果你此前在**用自己的代码绕过 SDK 直接请求该端点**、
  或 mock 了请求体做断言，需要同步改成 JSON。
- **为什么之前是错的**：见 §3.2 的"手写编码点"话题，与
  [`OPEN_ITEMS.md`](OPEN_ITEMS.md) 的编码收敛条目同源。

#### ⑪ `miniprogram/riskcontrol` 双收 `unoin_id` + `union_id` 兜底

- **变更**：`unoin_id`（微信官方文档中的真实 key，**官方笔误**）为主解析，
  另加 `union_id` 作为别名兜底（`src/miniprogram/riskcontrol/mod.zig:32`-`35`）。
- **推荐读法**：`getUnionId()`（`src/miniprogram/riskcontrol/mod.zig:44`），
  返回两者中非零的那个。
- **影响**：如果你直接读字段，继续读 `unoin_id` 也能工作；但建议改用 `getUnionId()`，
  这样微信日后修正笔误时你不用改代码。

#### ⑫ 其他解析契约修复（调用点无需改，但 mock / 断言要对齐）

CHANGELOG `[0.4.4] → Fixed` 段落列出了一批"字段名逐字对齐微信真实返回"的修复。
**这些不影响你的生产调用签名**，但会影响：

- 你自己写的 **MockTransport 响应夹具**（字段名要跟着改）；
- 你对响应结构体字段的**断言**。

要点（全部来自 CHANGELOG `[0.4.4]`）：
`vaild`（小程序 auth 官方笔误）、`phoneNumber`/`purePhoneNumber`/`countryCode`（camelCase）、
`img_size` 的 `w`/`h`、`watermark`、tcb 数据库 5 接口的 query JSON 转义、
virtualpayment 的 `env` 序列化为**数字** `0`/`1`（不是字符串）、
work/material 的 `created_at` 为**字符串**（`src/work/material/mod.zig:84` 的
`UploadResponse`，其中 `created_at: []const u8` 在 `:91`，与 Go 参考的 `string` 一致）。

### 1.3 v0.4.3 → v0.4.4：弃用标注（**方法未删、签名未改**，可暂不迁移）

v0.4.4 在顶层文档（`src/miniprogram/mod.zig` 的 doc comment）标注了三个"重复入口"。
**它们都保留、签名不变**，不迁移不会编译失败，只是功能面重复。

| 已弃用 | 位置 | 推荐替代 | 替代位置 | 为何推荐 |
|---|---|---|---|---|
| `MiniProgram.getMessage` | `src/miniprogram/mod.zig:90` | `getSubscribe().send` / `sendGetMsgId` | `src/miniprogram/subscribe/mod.zig:125` / `:132` | 旧入口的 `data` 要求调用方**预拼 JSON 原始字符串**；新入口用类型化 `DataEntry`，且 `sendGetMsgId` 能拿到 msgid |
| `MiniProgram.getContent` | `src/miniprogram/mod.zig:145` | `getSecurity().msgSecCheck` | `src/miniprogram/security/mod.zig:32` | 同一端点（`msg_sec_check`）两处入口，语义归属内容安全域；契约等价（都带必填 `openid`/`scene`） |
| `MiniProgram.getBusiness().getPhoneNumber` | `src/miniprogram/mod.zig:155` → `src/miniprogram/business/mod.zig:61` | `getAuth().getPhoneNumber` | `src/miniprogram/auth/mod.zig:118` | 新签名更简（直接收 `code`，旧的要包 `GetPhoneNumberRequest`），归属登录域，响应含 `errcode`/`errmsg` |

> **注意替代品的签名差异**（迁移时容易踩）：
> - `subscribe.send(self: *Self, msg: Message) !void` —— 只收一个 `Message`。
> - `security.msgSecCheck(self: Security, allocator, openid, content, scene) ![]u8`
>   —— `Security.init(ctx)` **不**吃 allocator，allocator 要传给方法。
> - `auth.getPhoneNumber(self: *Self, code: []const u8) !std.json.Parsed(GetPhoneNumberResponse)`
>   —— 收裸 `code`，不是 `GetPhoneNumberRequest`。

### 1.4 更早版本的破坏性变更（如果你从更早的 tag 升上来）

#### v0.3.0 —— JSON 返回 API 改为所有权转移（大改，影响约 30 处）

- **变更**：JSON 接口返回类型由 `T` 改为 `std.json.Parsed(T)`，
  调用方需读 `.value.*` 并**必须 `deinit()`**。
- **为什么**：消除"结构体字段借用响应 body"导致的 use-after-free。
- **不迁移的后果**：编译失败为主；漏 `deinit` 会变成**内存泄漏**（`zig build test` 会抓到）。
- **同类变更**：`pay/refund` / `pay/transfer` / `pay/redpacket` / `pay/order` 的 XML 响应
  所有权随返回值转移，新增 `deinit()`（如 `src/pay/order/mod.zig:57`
  的 `PreOrder.deinit`、`src/pay/refund/mod.zig:38` 的 `RefundResult.deinit`）。
  **拿到 v2 支付返回值后务必调用 `deinit`。**
- 细节见 `CHANGELOG.md` 的 `[0.3.0]` 段落。

#### v0.4.0 —— 纯新增，无破坏性变更

补齐 miniprogram 17 个子模块、顶层懒加载工厂（`getXxx`）与导出。
若你从 v0.3.0 升到 v0.4.4，**不需要**为 v0.4.0 单独做迁移。

---

## 2. 升级操作步骤

### 2.1 submodule 型消费者（如 `heysen_saas` 的 `api/zwechat`）

你的仓库里 `api/zwechat` 是一个 git submodule，指针记录在**父仓库的 tree 里**。
bump 指针 = 在子模块里 checkout 新 tag，然后在父仓库提交一次新的指针。

```bash
# 1) 在子模块里落到新 tag（v0.4.4）
cd api/zwechat
git fetch --tags
git checkout v0.4.4
git submodule update --init --recursive   # 拉齐 zwechat 自己的依赖声明

# 2) 回到父仓库，查看指针变化
cd ../..
git status            # 应看到 modified: api/zwechat (new commits)
git diff --submodule=log api/zwechat      # 确认落在 v0.4.4

# 3) 按 §1.1 改调用点

# 4) 提交父仓库指针（cron/CI 里通常还需要把子模块也推上去，视你们的流程）
git add api/zwechat
git commit -m "bump zwechat to v0.4.4"
```

> **常见坑**：只 `git commit` 父仓库、忘了子模块本身是否处于 detached HEAD 的预期提交；
> 以及 CI 里没有 `--init --recursive`，导致依赖没拉齐。
> 提交前用 `git diff --submodule=log api/zwechat` 复核，它会明确打印新旧 tag/commit。

### 2.2 依赖 git tag / URL 的消费者

不引 submodule，而是在你的 `build.zig.zon` 里写 URL：

```zig
.zwechat = .{
    // <your-org> 按你们实际托管地址替换
    .url = "git+https://github.com/<your-org>/zwechat?ref=v0.4.4#<commit-sha>",
    .hash = "zwechat-0.4.4-<zig-fetch-给出的 hash>",
},
```

**改 version 的正确做法**（不要手抄 hash，交给 `zig fetch`）：

```bash
# --save 会把 .url 与 .hash 一起写回你的 build.zig.zon
zig fetch --save=zwechat "git+https://github.com/<your-org>/zwechat?ref=v0.4.4"
```

参考：`zwechat` 自己就是这样引 httpz 的（`build.zig.zon` 的 `.dependencies.httpz`，
`git+https://github.com/chy3xyz/zhttp?ref=v0.6.1#60a0212...`）。

### 2.3 依赖 path 的消费者（同 workspace / monorepo）

把 `build.zig.zon` 的 `.path` 指到新 checkout 即可，无指针概念：

```zig
.zwechat = .{ .path = "path/to/zwechat" },
```

接模块的方式见 [`getting-started.md`](getting-started.md) §2（Zig 0.17 用
`b.dependency("zwechat", ...).module("zwechat")` + `addImport`）。

### 2.4 升级后的验证清单（建议按顺序跑）

```bash
# 1) 先格式化门禁：CI 里 zig build fmt 是绿灯前提（等价 zig fmt --check）
zig build fmt

# 2) 全量单元测试（827 个内联测试，零内存泄漏）
#    在 zwechat 自己的 checkout 里跑；它同时是"编译门"，会实例化绝大多数公开 API
cd path/to/zwechat && zig build test

# 3) 你自己的项目构建（签名变更会在这里全部暴露）
zig build

# 4) 你自己的测试
zig build test
```

> **工具链提示**：`build.zig.zon` 的 `.minimum_zig_version = "0.17.0"`。
> 本仓库在 `0.17.0-dev` 系列上开发（AGENTS.md 记录为 `0.17.0-dev.2151+2ec5523d5`），
> 而 CI 里钉的是一个更早的 dev 快照（`.github/workflows/ci.yml:26` 的
> `ZIG_VERSION="0.17.0-dev.1567+f0354179a"`）。
> **建议你仍然用 `0.17.0-dev.2151+2ec5523d5`**（开发/测试所用版本）；
> 换工具链本身就可能引入编译错误，与 SDK 升级分开提交，便于定位。

---

## 3. 通用策略

### 3.1 语义化版本约定（务必读完再决定"能不能自动升"）

- 版本号遵循 [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html)，
  CHANGELOG 遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)。
- 但当前处于 **`0.x`** 阶段：**minor 位（`0.4` → `0.5`）允许不兼容变更**，
  v0.4.3 → v0.4.4 这次是 **patch 位却带了 9 处签名变更**——
  因为上游把契约修复成批发布，且项目在 `0.x` 明确声明
  "公开 API 变更记录（契约修正，**非兼容性保证**）"（AGENTS.md 的「移植备注」小节）。
- **实务结论**：
  1. **不要**假设 patch 位可以无痛升级，每次 bump 都跑 §2.4 的四步；
  2. 升级前先读 `CHANGELOG.md` 新版本段落的 **`### Changed`** 子节，
     "公开 API 变更" 全部列在那里；
  3. 把 SDK 升级做成**独立提交**（尤其 submodule 指针），不要和其它改动混在一起，
     否则回滚时要一起回滚。

### 3.2 用 API 面门禁自查你的用法

本仓库正在引入一个 API 面检查脚本（外部评审建议，用于把"公开签名快照"固化下来），
预期路径：

```
tools/api_surface_check.sh
```

用法预期：对当前 checkout 生成/比对公开 API 面，**你可以在升级前先跑一次、
在升级后再跑一次，diff 出"我要动的行"**。

> **⚠️ 在 v0.4.4 的 tag 上它还不存在**：`ls tools/` 目前只有
> `tools/_probe.zig`（一个用 comptime 反射枚举公开 API 面的临时探针），
> **没有** `api_surface_check.sh`。若你的 checkout 里也没有，说明该门禁尚未合入，
> 请用下面的兜底自查：
>
> ```bash
> # 你实际调用到的符号，逐个 grep 是否存在（示例）
> grep -rn "pub fn checkText"                src/miniprogram/content/mod.zig
> grep -rn "pub fn listAccounts"             src/officialaccount/customerservice/mod.zig
> grep -rn "pub fn handleServerMessage"      src/middleware/wechat_handler.zig
> grep -rn "pub fn getMediaList"             src/work/material/mod.zig   # 期望：无匹配
> ```
>
> 更省事的办法：直接 `zig build`，让编译器把缺失/变形的符号一次性列出来。

### 3.3 测试与格式化门禁

- **`zig build test`**：在 zwechat checkout 里是"827 个内联测试 + 零泄漏"的完整回归；
  在**你的项目**里跑则只覆盖你的调用点。CI 同时跑两者才有意义。
  （`zig build` 里的 `src/test_runner.zig` 是编译门，强制 `@import` 每个子文件——
  否则 Zig 的 dead-strip 会静默跳过带 inline test 的文件，报出 "All 1 tests passed" 的假绿。）
- **`zig fmt --check` / `zig build fmt`**：CI（`.github/workflows/ci.yml`）把
  `zig build fmt` 当作第一步门禁。你的仓库如果 vendored 了 zwechat 源码，
  格式化检查要排除它，否则会因上游风格差异误报。
- **建议**：把"bump SDK"的 PR 里附上 `zig build test` 的输出，
  而不是只写"本地跑过"。

### 3.4 升级前 checklist

- [ ] `git diff --submodule=log`（或 `zig fetch --save` 后的 `git diff build.zig.zon`）确认落到目标 tag
- [ ] 读新版本 CHANGELOG 的 `### Changed`（"公开 API 变更"）
- [ ] 逐个对照 §1.1 的 9 条，特别检查 §1.2 那几条**不会编译失败**的静默变更
- [ ] `zig build` → 修完所有编译错误
- [ ] `zig build test`（自己 + 若 vendored 则连同 zwechat）
- [ ] 检查是否有新增的 `deinit()` 义务（`Parsed(T)` / pay v2 返回值）
- [ ] mock 夹具/断言同步（字段名逐字对齐）
- [ ] 独立提交，提交信息写明 `bump zwechat to vX.Y.Z`

---

## 4. 进一步参考

| 想知道什么 | 去哪 |
|---|---|
| 版本演进的完整叙述 | [`../CHANGELOG.md`](../CHANGELOG.md) |
| 接口的当前形状（必读，含 §9 开放平台授权链路） | [`../doc/api_guide.md`](../doc/api_guide.md) |
| 公共 API 索引（部分章节早于 v0.4.4，以源码为准） | [`api-reference.md`](api-reference.md) |
| 从 Go SDK 迁移 | [`migration-from-go.md`](migration-from-go.md) |
| 架构与内存所有权约定 | [`architecture.md`](architecture.md) |
| 已知取舍与开放项 | [`OPEN_ITEMS.md`](OPEN_ITEMS.md) |
| 首次接入 | [`getting-started.md`](getting-started.md) |
| 维护者的决策记录 | [`../AGENTS.md`](../AGENTS.md) 的「移植备注」小节 |
