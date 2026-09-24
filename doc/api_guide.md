# zwechat API 使用指南与速查手册

`zwechat` 是基于 Zig 0.17 打造的高性能、零内存泄漏微信开放接口 SDK，全面覆盖公众号、小程序、小游戏、微信支付 v2/v3、企业微信及开放平台。

> 本文所有示例均从 `examples/` 与 `src/` 现有实现提取 / 改写，import 一律使用 root 导出形态 `@import("zwechat")`。
> 每个 API 的逐方法签名请以 [`docs/api-reference.md`](../docs/api-reference.md)（完整 API 索引）为准。

---

## 目录
1. [快速开始 (Quick Start)](#1-快速开始-quick-start)
2. [微信公众号 (OfficialAccount)](#2-微信公众号-officialaccount)
3. [微信支付 v2/v3 (Pay v2 & v3)](#3-微信支付-v2v3-pay-v2--v3)
4. [企业微信 (Work)](#4-企业微信-work)
5. [小程序 (MiniProgram)](#5-小程序-miniprogram)
6. [编译期模板生成器 (Comptime Template)](#6-编译期模板生成器-comptime-template)
7. [Web 框架中间件适配 (Middleware)](#7-web-框架中间件适配-middleware)
8. [内存管理与最佳实践 (Memory Management)](#8-内存管理与最佳实践-memory-management)
9. [开放平台第三方平台授权流程 (OpenPlatform)](#9-开放平台第三方平台授权流程-openplatform)
10. [缓存与凭据配置 (Cache & Credential)](#10-缓存与凭据配置-cache--credential)

---

## 1. 快速开始 (Quick Start)

### 引入依赖 (`build.zig.zon`)
```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .dependencies = .{
        .zwechat = .{
            .path = "path/to/zwechat",
        },
    },
}
```

> `zwechat` 自身**默认零依赖**（无 Zig 包依赖、无 C 依赖），上游拉取时不会给 `zig build` 引入 OpenSSL / libc。
> 唯一例外：微信支付 **v2** 的 mTLS（客户端证书）需构建时加 `-Dmtls=true`，见 [§3「v2 mTLS 与 v3 的选择」](#3-微信支付-v2v3-pay-v2--v3)。

### 构造业务实例的通用骨架

公众号 / 小程序需要调用方提供 access_token 工厂（企业微信、支付、开放平台不需要）：

```zig
const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var memory_cache = try zwechat.cache.Memory.create(allocator);
    defer {
        memory_cache.deinit();
        allocator.destroy(memory_cache);
    }

    const cfg = zwechat.officialaccount.Config{
        .app_id = "wx1234567890abcdef",
        .app_secret = "0123456789abcdef0123456789abcdef",
        .cache = memory_cache.asCache(),
    };

    // ⚠️ 所有权：handle.ptr 指向 DefaultAccessToken 实例本身，必须活到 handle 不再被使用。
    var default_token = zwechat.credential.DefaultAccessToken.init(
        cfg.app_id,
        cfg.app_secret,
        zwechat.credential.CacheKeyOfficialAccountPrefix,
        cfg.cache.?,
    );

    const factory = struct {
        var token_ptr: *zwechat.credential.DefaultAccessToken = undefined;
        fn create(_: zwechat.officialaccount.Config, _: zwechat.cache.Cache) anyerror!zwechat.credential.AccessTokenHandle {
            return token_ptr.asHandle();
        }
    };
    factory.token_ptr = &default_token;

    var wc = zwechat.wechat.Wechat.init();
    var oa = try wc.getOfficialAccount(allocator, cfg, factory.create);
    _ = &oa; // 后续 oa.getMenu(...) 等子模块工厂持有 &oa.ctx，oa 必须保持可变且地址稳定
}
```

### 凭据自动刷洗与 Token 强刷
当 Token 失效（如微信返回 `40001` / `40014`）时，可调用 `forceRefresh` 手动重新回源拉取：
```zig
const access_token = try default_token.forceRefresh(allocator);
defer allocator.free(access_token);
```

> **常见坑**
> - **工厂绝不能返回指向栈上临时变量的 handle**——函数返回后即悬垂，线上表现为偶发 segfault。用 `create` 在堆上分配或让实例与业务对象同生命周期（见上例）。
> - `Config.cache` 与 `Wechat.cache` 同时为空时，`getOfficialAccount` / `getMiniProgram` / `getWork` / `getOpenPlatform` 都会返回 `error.CacheUnavailable`。

---

## 2. 微信公众号 (OfficialAccount)

> **涉及模块**：`src/officialaccount/`（`menu` / `message` / `user` / `material` / `server` 等）
> **API 索引**：`docs/api-reference.md` 第 5 节「officialaccount」

### URL 签名校验与消息加解密
```zig
const zwechat = @import("zwechat");

// 解析并校验微信推送 URL 签名（GET 握手阶段回显 echostr）
const query = try zwechat.middleware.parseCallbackQuery(query_string);
if (zwechat.middleware.verifyURL(allocator, token, query)) |echostr| {
    // 将 echostr 原样写入 HTTP 响应 body
}

// 校验消息推送签名
const is_valid = zwechat.middleware.verifyServerSignature(allocator, token, .{
    .signature = signature_str,
    .timestamp = timestamp_str,
    .nonce = nonce_str,
});

// 解密 AES 消息（aes_key 为 32 字节原始 key；app_id 不匹配返回 AppIDMismatch）
var decrypted = try zwechat.middleware.handleServerMessage(
    allocator,
    aes_key,
    app_id,
    encrypted_xml_data,
);
defer decrypted.deinit(allocator);

std.debug.print("收到明文 XML: {s}\n", .{decrypted.raw_xml});
```

### 自定义菜单
```zig
var menu = oa.getMenu(allocator);

// 一级菜单 + 二级菜单；Button 提供 setClick / setView / setScanCodePush 等构造助手
try menu.setMenu(&.{
    .{
        .name = "服务",
        .sub_button = &.{
            zwechat.officialaccount.menu.Button.setView("官网", "https://example.com"),
            zwechat.officialaccount.menu.Button.setClick("今日签到", "KEY_CHECKIN"),
        },
    },
    zwechat.officialaccount.menu.Button.setView("关于我们", "https://example.com/about"),
});

// 查询 / 删除
var cur = try menu.getMenu();
defer cur.deinit();
try menu.deleteMenu();
```

### 客服消息（48 小时会话窗口内）
```zig
var msg_api = oa.getMessage(allocator);

// 文本客服消息（ CustomerMsgType 枚举：text / image / voice / news / miniprogrampage ... ）
try msg_api.sendCustomer(.{
    .touser = openid,
    .msgtype = .text,
    .text = .{ .content = "您好，有什么可以帮您？" },
});

// 输入状态提示（客服端显示"正在输入"）
try msg_api.sendTypingStatus(openid, .typing);
```

### 模板消息
```zig
const msgid = try msg_api.sendTemplate(.{
    .to_user = openid,
    .template_id = "tmpl_0123456789abcdef",
    .url = "https://example.com/order/123",
    .data = &.{
        .{ .key = "first", .value = "订单支付成功", .color = "#173177" },
        .{ .key = "amount", .value = "88.00元" },
        .{ .key = "remark", .value = "如有疑问请联系客服" },
    },
});
// sendTemplate 返回 i64 msgid
```

`data` 字段也可先用编译期模板生成器构造（见第 6 章 `util.template.buildTemplateData`）。

### 用户信息与标签
```zig
var user = oa.getUser(allocator);

// 单个用户信息
var info = try user.getUserInfo(openid);
defer info.deinit();
std.debug.print("nickname={s} unionid={s}\n", .{ info.value.nickname, info.value.unionid });

// 创建标签并批量打标
var tag = try user.createTag("VIP");
defer tag.deinit();
try user.batchTag(&.{openid}, tag.value.tag.id);

// 粉丝 openid 列表（公众号）
var list = try user.getOpenidList("");
defer list.deinit();
for (list.value.data.openid) |one_openid| {
    // 注意：openid 在 .data.openid 嵌套层，与微信真实响应一致
}
```

### 素材上传与下载（getMedia 自动跟随 302）
```zig
var material = oa.getMaterial(allocator);

// 永久视频素材上传（multipart；图片 / 图文等见 addNews / addVideoFromBytes 家族）
var added = try material.addVideoFromBytes(video_bytes, "demo.mp4", "标题", "简介");
defer added.deinit();
const media_id = added.value.media_id; // 借用自 Parsed，切勿 free

// 下载素材：内部走 getFollowRedirect（GET 手动 302 跟随，≤2 跳），
// 返回完整二进制，调用方负责 free
const img_bytes = try material.getMedia(media_id);
defer allocator.free(img_bytes);
```

> **常见坑**
> - **errcode 检查**：本 SDK 所有解析微信响应的方法都已内建 errcode 检查（非 0 抛 `WechatError.ApiError`），调用方拿到的 `std.json.Parsed` 一定是成功响应；不要自己再解析错误体。
> - **`Parsed` 借用语义**：`info.value.nickname`、`media_id` 等切片借用自 `std.json.Parsed` 所有权域，只能 `defer parsed.deinit()`，**逐个 free 会 double free**。
> - **officialaccount 同样存在地址稳定性约束**：`oa.getMenu(allocator)` 等子模块持有 `&oa.ctx` 指针，禁止按值拷贝 / 移动 `OfficialAccount`。
> - 微信后台给出的 EncodingAESKey 是 43 字符 base64 串，而 `handleServerMessage` / `Config.encoding_aes_key` 需要 **32 字节原始 key**（见 `examples/officialaccount_server.zig`）。

---

## 3. 微信支付 v2/v3 (Pay v2 & v3)

> **涉及模块**：`src/pay/`（v2：`order` / `refund` / `notify` / `transfer` / `redpacket`；v3：`v3/` 含 `config` / `signer` / `order` / `refund` / `transfer` / `notify`）
> **API 索引**：`docs/api-reference.md` 第 6 节「pay」

### 微信支付 v3 签名 Header 生成
```zig
const zwechat = @import("zwechat");

const v3_cfg = zwechat.pay.v3.Config{
    .app_id = "wx12345",
    .mch_id = "1900000109",
    .serial_no = "1DDE557876238...",
    .private_key_pem = "-----BEGIN PRIVATE KEY-----\n...",
};

var sign_res = try zwechat.pay.v3.signer.buildAuthorizationHeader(
    allocator,
    v3_cfg,
    "POST",
    "/v3/pay/transactions/jsapi",
    json_body,
);
defer sign_res.deinit(allocator);

// 发送 HTTP 请求时添加标头：
// Authorization: sign_res.authorization
```

### 微信支付 v3 异步通知解密 (AES-256-GCM 纯 Zig 原生)
```zig
const plain_json = try zwechat.pay.v3.decryptNotifyResource(
    allocator,
    api_v3_key,           // 32 字节 APIv3 密钥
    resource.ciphertext,  // base64 密文（含末尾 16 字节 Tag）
    resource.associated_data,
    resource.nonce,       // 12 字节向量
);
defer allocator.free(plain_json);
```

### 微信支付 v3 推荐入口速查（下单 / 退款 / 商家转账 / 通知解密）

```zig
const zwechat = @import("zwechat");
const v3 = zwechat.pay.v3;

// 四个入口共用同一份 Config：api_v3_key 用于通知解密，私钥/序列号用于请求签名
const v3_cfg = v3.Config{
    .app_id = "wx12345",
    .mch_id = "1900000109",
    .api_v3_key = "12345678901234567890123456789012", // 32 字节 APIv3 密钥
    .serial_no = "1DDE557876238...",
    .private_key_pem = "-----BEGIN PRIVATE KEY-----\n...",
    .notify_url = "https://merchant.example.com/wxpay/notify",
};

// ① 下单：拿到 prepay_id 后生成前端拉起支付参数（JSAPI / 小程序）
var order = v3.OrderV3.init(v3_cfg);
var pay_params = try order.getJsPayParams(allocator, "wx201411101639507cbf6ffd8b0779950800");
defer pay_params.deinit(allocator); // time_stamp / nonce_str / package / pay_sign 均为堆内存

// ② 退款（transaction_id 与 out_trade_no 二选一）
var refund = v3.RefundV3.init(v3_cfg);
var refund_res = try refund.refund(allocator, .{
    .transaction_id = "4200000119202504081234567890",
    .out_refund_no = "R20260722001",
    .reason = "商品已售完",
    .amount = .{ .refund = 100, .total = 100 },
});
defer refund_res.deinit();
// var queried = try refund.queryRefund(allocator, "R20260722001");

// ③ 商家转账（新版商家转账；不做已升级停用的「商家转账到零钱」）
var transfer = v3.TransferV3.init(v3_cfg);
var bill = try transfer.transfer(allocator, .{
    .out_bill_no = "plfk2020042013",        // 仅数字/大小写字母，商户内唯一
    .transfer_scene_id = "1000",            // 转账场景：1000 现金营销
    .openid = "o-MYE42l80oelYMDE34nYD456Xoy",
    .transfer_amount = 400000,              // 单位：分
    .transfer_remark = "新会员开通有礼",
    .transfer_scene_report_infos = &.{      // 官方必填，按转账场景报备
        .{ .info_type = "活动名称", .info_content = "新会员有礼" },
    },
    // .user_name = "密文...",              // ≥2000 元必填，须为微信支付公钥加密后的密文
});
defer bill.deinit();
if (std.mem.eql(u8, bill.value.state, "WAIT_USER_CONFIRM")) {
    // HTTP 200 只代表受理成功：用 bill.value.package_info 拉起微信收款确认页
}
// var q = try transfer.queryTransfer(allocator, "plfk2020042013");
// var c = try transfer.cancelTransfer(allocator, "plfk2020042013");

// ④ 通知解密：支付 / 退款 / 商家转账回调共用同一套 AES-256-GCM 解密
const plain = try v3.decryptNotifyResource(
    allocator,
    v3_cfg.api_v3_key,
    notify_body.resource.ciphertext,
    notify_body.resource.associated_data,
    notify_body.resource.nonce,
);
defer allocator.free(plain);

// 解密后的 JSON 按 event_type 选结构体：
//   REFUND.SUCCESS            → v3.RefundNotifyResource
//   MCHTRANSFER.BILL.FINISHED → v3.TransferNotifyResource
const parsed = try std.json.parseFromSlice(v3.TransferNotifyResource, allocator, plain, .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
});
defer parsed.deinit();
```

> **常见坑**：
> - v3 signer 在 `private_key_pem` 为空时返回 `error.MissingPrivateKey`（不会静默生成伪签名）；v3 通知解密是 AES-256-GCM，与 v2 的 AES-256-CBC + PKCS#7 完全不同，不要混用。
> - 商家转账只做新版 `/v3/fund-app/mch-transfer/transfer-bills`（2025-01-15 起取代「商家转账到零钱」`/v3/transfer/batches`）；撤销路径是 `.../out-bill-no/{out_bill_no}/cancel`，**不是** `.../transfer-bills/{bill_id}/cancel`。
> - 转账传入 `user_name` 时必须是**密文**（微信支付公钥 RSA-OAEP 加密，SDK 不做加密），并设置 `Config.wechatpay_serial`（微信支付公钥 ID 如 `PUB_KEY_ID_3000000001`，或平台证书序列号），SDK 会自动附带 `Wechatpay-Serial` 请求头。
> - HTTP 200 不代表转账成功：以应答 `state` 判断单据状态（`WAIT_USER_CONFIRM` 可引导确认收款；`SUCCESS` / `FAIL` / `CANCELLED` 为终态）。发起转账报错时**不要换单号重试**，先查单确认原单结果，否则有重复转账的资金风险。
> - 转账单的微信侧单号字段名是 `transfer_bill_no`（官方契约），不是 `bill_id`。

### v2 mTLS 与 v3 的选择

微信支付有两条互不相同的链路，**是否需要客户端证书**是选择的首要依据：

| | v3（推荐） | v2 |
|---|---|---|
| 认证方式 | RSA 私钥签名（`Authorization: WECHATPAY2-SHA256-RSA2048`）+ **普通 HTTPS** | 证书 + 密钥的 **mTLS 双向认证**（部分接口） |
| 是否需要客户端证书 | **不需要** | 退款 / 转账 / 现金红包在 `pay.Config.root_ca` 非空时需要 |
| 需要 `-Dmtls=true` | 不需要 | **需要**（否则 `postXMLWithTLS` 直接报错） |
| 需要的凭据 | `pay.v3.Config.private_key_pem` + `serial_no`（通知解密另需 `api_v3_key`） | PKCS#12 证书（`root_ca`）+ 商户号 |

- **v3（推荐）**：退款用 `zwechat.pay.v3.RefundV3`（`src/pay/v3/refund.zig`），转账用 `zwechat.pay.v3.TransferV3`（`src/pay/v3/transfer.zig`），都是 RSA 签名 + 普通 HTTPS，**无需任何 OpenSSL / 客户端证书**。配置见上文 v3 速查（私钥 `private_key_pem`、序列号 `serial_no`）。
- **v2**：`pay/refund`、`pay/transfer`、`pay/redpacket` 在 `root_ca` 非空时走 `util.http.postXMLWithTLS`。该能力受构建开关控制，必须显式开启：

```bash
# 你自己的项目（含把 zwechat 作为 path / submodule 依赖时）
zig build -Dmtls=true
```

- 开启后**只需要运行时有 `libssl` / `libcrypto` 动态库**（构建期不要求头文件）；未开启时调用会得到：

```
error.MtlsNotEnabled
```

> **建议**：新业务优先用 v3（退款 / 转账已有 v3 实现），可以完全绕开 mTLS 与 `-Dmtls` 开关。
> 目前**只有 v2 现金红包没有 v3 等价物**，是唯一仍刚需 `-Dmtls=true` 的场景。

---

## 4. 企业微信 (Work)

> **涉及模块**：`src/work/`（`message` / `addresslist` / `externalcontact` / `kf` / `jsapi` / `server` 等）
> **API 索引**：`docs/api-reference.md` 第 9 节「work」

### 实例化与地址稳定性
```zig
var work_inst = try wc.getWork(allocator, .{
    .corp_id = "ww1234567890abcdef",
    .corp_secret = "secret1234567890abcdef1234567890",
    .agent_id = "1000002",
    .cache = memory_cache.asCache(), // 或经 wc.setCache 全局注入
});
defer work_inst.deinit(allocator);
```

### 应用消息发送（`/cgi-bin/message/send`）
```zig
var msg_api = work_inst.getMessage(allocator);

var resp = try msg_api.sendText(.{
    .common = .{
        .to_user = "zhangsan|lisi", // "|" 分隔，最多 1000 个；"@all" 为全员
        .agent_id = "1000002",
    },
    .content = "今晚八点例会，请准时参加。",
});
defer resp.deinit();

// 部分失败不会抛错：不合法的成员 / 部门 / 标签在回执里
if (resp.value.invalid_user.len > 0) {
    std.debug.print("发送失败成员: {s}\n", .{resp.value.invalid_user});
}
```

### 通讯录（33 个方法的代表用法）
```zig
var addr = work_inst.getAddressList(allocator);

// 读取成员
var u = try addr.getUser("zhangsan");
defer u.deinit();

// 新建成员（userid 为字符串类型，非 i64）
var created = try addr.createUser(.{
    .userid = "wangwu",
    .name = "王五",
    .mobile = "13800138000",
    .department = &.{1},
});
defer created.deinit();

// 部门树
var depts = try addr.getDepartmentList();
defer depts.deinit();
```

### 客户联系（externalcontact）
```zig
var ext = work_inst.getExternalContact(allocator);

// 配置了「联系我」的跟进成员列表
var followers = try ext.getFollowUserList();
defer followers.deinit();

// 创建「联系我」二维码方式
var way = try ext.addContactWay(.{
    .type = 1,                       // 1=单人，2=多人
    .scene = 2,                      // 2=二维码
    .user = &.{"zhangsan"},
    .state = "from-api-guide",       // 回调透传参数，做渠道统计
    .skip_verify = true,
});
defer way.deinit();
std.debug.print("config_id={s}\n", .{way.value.config_id});
```

### 微信客服（kf）syncMsg 游标拉取循环
```zig
var kf = work_inst.getKf(allocator);

// ⚠️ next_cursor 必须持久化（入库），重启后从上次游标继续，否则会重复拉取
var cursor_buf: []u8 = loadCursorFromDB() orelse "";
defer if (cursor_buf.len > 0) allocator.free(cursor_buf);

while (true) {
    var sync = try kf.syncMsg(.{
        .cursor = cursor_buf, // 首次拉取留空
        .token = callback_token, // 回调事件 token，10 分钟内有效；不填有严格频控
        .limit = 1000,
    });
    defer sync.deinit();

    for (sync.value.msg_list) |m| {
        handleKfMessage(m);
    }

    // 停止条件：has_more == 0（不能用 msg_list 是否为空判断！）
    if (sync.value.has_more == 0) break;

    // next_cursor 借用自本 Parsed，跨迭代持有必须先 dupe
    const next = try allocator.dupe(u8, sync.value.next_cursor);
    if (cursor_buf.len > 0) allocator.free(cursor_buf);
    cursor_buf = next;
    saveCursorToDB(cursor_buf);
}
```

### JS-SDK Agent Ticket 签名计算
```zig
var wc = zwechat.wechat.Wechat.init();
var work_inst = try wc.getWork(allocator, work_cfg);
var js = work_inst.getJs();

var agent_cfg = try js.getAgentConfig(allocator, "https://example.com/page");
defer agent_cfg.deinit(allocator);

std.debug.print("Agent 签名: {s}\n", .{agent_cfg.signature});
```

### 企业微信回调服务器校验与消息解密 (`WorkServer`)
```zig
const work_server = zwechat.work.WorkServer.init(work_inst.getContext());

// 1. 签名校验
const ok = work_server.verifyMsgSignature(allocator, encrypted_msg_body, .{
    .msg_signature = msg_signature_str,
    .timestamp = timestamp_str,
    .nonce = nonce_str,
});

// 2. 解密并自动校验 CorpID (ReceiveID)
var dec_msg = try work_server.decryptMsg(allocator, encrypted_xml_body);
defer {
    allocator.free(dec_msg.random);
    allocator.free(dec_msg.raw_xml_msg);
    allocator.free(dec_msg.app_id);
}
```

> **常见坑**
> - **Work / MiniProgram 地址稳定性**：`getMessage` / `getKf` / `getJs` 等工厂返回的子模块持有 `&work_inst.ctx` 裸指针，调用 `getJs()` 等工厂后**禁止移动 / 按值拷贝 `Work`**；多实例场景请放堆上（`allocator.create`）或用 `*Work` 传递。
> - **kf 游标两个坑**：① 判停看 `has_more`，`msg_list` 为空不代表拉完；② `next_cursor` 借用自 `Parsed`，跨迭代 / 跨请求持有必须 `dupe`（Redis / Memcache 后端任何后续 `get` 都会使借用切片失效）。
> - `Work.getJs()` 已自动注入 corp / agent 两种 ticket handle；`encoding_aes_key` 传 43 字符 base64 即可，`WorkServer` 内部自动解码，无需手工转 32 字节。
> - 企业微信 userid 是**字符串**（如 `"zhangsan"`），不要当 i64 处理。

---

## 5. 小程序 (MiniProgram)

> **涉及模块**：`src/miniprogram/`（`auth` / `subscribe` / `security` / `urlscheme` / `urllink` / `qrcode` 等）
> **API 索引**：`docs/api-reference.md` 第 7 节「miniprogram」

### 登录链路：code2Session → getPhoneNumber
```zig
const zwechat = @import("zwechat");

var mp = try wc.getMiniProgram(allocator, mp_cfg, factory.create); // factory 同第 1 章
var auth = mp.getAuth();

// ① wx.login 拿到的 js_code 换 openid + session_key
var sess = try auth.code2Session(js_code);
defer sess.deinit();
std.debug.print("openid={s} unionid={s}\n", .{ sess.value.openid, sess.value.unionid });

// ② 手机号快速验证组件拿到的 code 换手机号（推荐 getAuth().getPhoneNumber，签名最简）
var phone = try auth.getPhoneNumber(phone_code);
defer phone.deinit();
std.debug.print("phone={s}\n", .{phone.value.phone_info.purePhoneNumber});
```

### 订阅消息发送（推荐 `subscribe.send`，`getMessage` 已弃用）
```zig
var sub = mp.getSubscribe();

// data 是类型化 DataEntry 列表，无需手工预序列化 JSON 字符串
try sub.send(.{
    .touser = openid,
    .template_id = "template_id_456",
    .page = "pages/index/index",
    .data = &.{
        .{ .key = "thing1", .value = "会议提醒" },
        .{ .key = "time2", .value = "2026-09-21 19:00" },
    },
    .miniprogram_state = "formal", // developer / trial / formal
});

// 需要 msgid 时：
const msgid = try sub.sendGetMsgId(.{
    .touser = openid,
    .template_id = "template_id_456",
    .data = &.{.{ .key = "thing1", .value = "会议提醒" }},
});
```

> `mp.getMessage().sendSubscribeMessage` 覆盖同一端点，但要求手工预拼 `data` JSON 原始字符串，已标记弃用，仅为兼容保留；新代码请统一走 `getSubscribe()`。

### 文本 / 媒体内容安全审核（security）
```zig
var sec = mp.getSecurity();

// 文本同步审核（openid / scene 均为必填）
const check_res = try sec.msgSecCheck(
    allocator,
    "openid_123",
    "待审核文本内容",
    1, // 1: 资料, 2: 评论, 3: 论坛, 4: 社交日志
);
defer allocator.free(check_res);

// 图片 / 音频异步审核：返回 trace_id，供后续回调匹配
const trace_id = try sec.mediaCheckAsync(
    allocator,
    "https://cdn.example.com/img/a.png",
    2,            // 1: 音频, 2: 图片
    "openid_123",
    2,
);
defer allocator.free(trace_id);
```

### 生成 URL Scheme / URL Link / 小程序码
```zig
// URL Scheme（短信、邮件等外部场景拉起小程序）
var scheme = mp.getURLScheme();
var g = try scheme.generate("{\"path\":\"pages/index/index\",\"query\":\"a=1\"}");
defer g.deinit();
std.debug.print("openlink={s}\n", .{g.value.openlink});

// URL Link（H5 / 公众号网页跳转小程序）
var ul = mp.getURLLink();
const link = try ul.generate(.{
    .path = "pages/index/index",
    .query = "a=1",
    .env_version = "release",
    .is_expire = true,
    .expire_type = .interval,
    .expire_interval = 30, // 30 天后失效
});
defer allocator.free(link);

// 小程序码（无数量限制；失败时微信返回 JSON 错误体，SDK 识别后抛 ApiError）
var qrcode = mp.getQRCode();
const png_bytes = try qrcode.getUnlimited("scene_id_123", "pages/index/index", 430);
defer allocator.free(png_bytes);
```

> **常见坑**
> - **`MiniProgram` 地址稳定性**：与 Work 相同，`getAuth()` / `getSubscribe()` 等工厂持有 `&mp.ctx`，**禁止按值拷贝 / 移动 `MiniProgram`**（包括从函数按值返回后再取地址）。需要传递时用 `*MiniProgram`。
> - **camelCase 响应字段**：`phone_info` 内是微信原始 key——`phoneNumber` / `purePhoneNumber` / `countryCode`（Zig 字段名逐字一致），不是 snake_case。
> - **弃用入口**：`getMessage()` / `getContent()` / `getBusiness().getPhoneNumber` 均为兼容保留的重复入口，新代码用 `getSubscribe()` / `getSecurity()` / `getAuth().getPhoneNumber`。
> - `mediaCheckAsync` 要求用户**近两小时访问过小程序**，否则微信侧报错。
> - 二进制端点（`getUnlimited` / 素材下载）失败时微信返回 JSON 错误体而非图片字节，SDK 已统一识别并抛 `WechatError.ApiError`。

---

## 6. 编译期模板生成器 (Comptime Template)

> **涉及模块**：`src/util/template.zig` ｜ **API 索引**：`docs/api-reference.md` 第 4 节「util」

利用 Zig 的 `comptime` 类型反射，零开销自动序列化结构体为微信模板格式：

```zig
const zwechat = @import("zwechat");

const OrderNotice = struct {
    first: []const u8,
    trade_no: []const u8,
    amount: []const u8,
    remark: []const u8,
};

const notice = OrderNotice{
    .first = "订单支付成功",
    .trade_no = "202607221938001",
    .amount = "88.00元",
    .remark = "如有疑问请联系客服",
};

const json_str = try zwechat.util.template.buildTemplateData(allocator, notice);
defer allocator.free(json_str);

// 输出结果:
// {"first":{"value":"订单支付成功"},"trade_no":{"value":"202607221938001"},"amount":{"value":"88.00元"},"remark":{"value":"如有疑问请联系客服"}}
```

---

## 7. Web 框架中间件适配 (Middleware)

> **涉及模块**：`src/middleware/` ｜ **API 索引**：`docs/api-reference.md` 第 2 节起各业务「server」小节

支持无缝接入 `zfinal` / `zigmodu` / `zap` / `httpz` 路由框架。

```zig
pub fn handleWeChatCallback(req: *zfinal.Request, res: *zfinal.Response) !void {
    const query = zwechat.middleware.CallbackQuery{
        .signature = req.query("signature"),
        .timestamp = req.query("timestamp"),
        .nonce = req.query("nonce"),
    };
    if (!zwechat.middleware.verifyServerSignature(req.allocator, MY_TOKEN, query)) {
        return res.status(403).send("Forbidden");
    }
    // ...
}
```

---

## 8. 内存管理与最佳实践 (Memory Management)

1. **堆分配返回值处理**：SDK 中绝大多数返回切片的方法（如 `getAccessToken`, `signSHA1`, `decryptNotifyResource`）均在传入的 `allocator` 上分配内存，必须配对使用 `defer allocator.free(...)`。
2. **结构体资源释放**：返回 `Config` / `JsapiPayParams` / `DecryptedMessage` / `AuthBaseInfo` / `AuthrAccessToken` 等复杂结构体时，使用对应的 `defer obj.deinit(allocator)` 释放其内部堆字段。
3. **`std.json.Parsed` 只 deinit、不逐字段 free**：`parsed.value` 内全部切片借用自所有权域，读完 `defer parsed.deinit()` 即可；逐字段 `free` 会 double free。
4. **借用切片及时 dupe**：`Cache.get` 返回借用切片（Redis / Memcache 后端任何后续 `get` 即失效），跨写 / 跨迭代持有必须 `allocator.dupe` 后再用。
5. **单元测试验证**：推荐在你的程序中使用 `std.testing.allocator`，它能帮助你在单元测试阶段发现 100% 的内存泄漏与双重释放问题。

---

## 9. 开放平台第三方平台授权流程 (OpenPlatform)

> **涉及模块**：`src/openplatform/`（`context`（含 `access_token` / `auth`）/ `account` / `miniprogram`（component））
> **API 索引**：`docs/api-reference.md` 第 8 节「openplatform」

第三方平台（代公众号 / 小程序运营）的授权链路是全套 SDK 中最容易踩坑的部分，完整时序如下：

```
微信推送 component_verify_ticket（每 10 分钟一次，AES 加密）
        │
        ▼
① 解密票据并持久化 ──► ② getComponentAccessToken（换平台 token，缓存 7000s）
        │
        ▼
③ getComponentLoginPage 构造扫码授权链接（内部自动 getPreCode）
        │
        ▼  管理员扫码确认，微信 302 回调你的 redirect_uri 并带 authorization_code
        │
        ▼
④ queryAuthCode(authorization_code) ──► 回写 authorizer_access_token_{appid}
        │                              与 authorizer_refresh_token_{appid} 双缓存
        ▼
⑤ 后续业务调用 getAuthrAccessToken(authorizer_appid)（命中缓存零请求；
  miss 自动用 refresh_token 回源并轮换回存）
```

### ① 接收并解密 component_verify_ticket

微信每 10 分钟向第三方平台「授权事件 URL」推送一次票据，消息体与公众号安全模式消息**同格式**（AES-256-CBC + PKCS#7，XML 内 `<Encrypt>`）：

```zig
const zwechat = @import("zwechat");

// aes_key 为 32 字节原始 key（由 43 字符 EncodingAESKey base64 解码得到）；
// expected_app_id 传第三方平台自己的 component appid，SDK 会校验防伪造
var decrypted = try zwechat.middleware.handleServerMessage(
    allocator,
    raw_aes_key_32,
    component_appid,
    encrypted_xml_body,
);
defer decrypted.deinit(allocator);

// decrypted.raw_xml 形如：
// <xml><ComponentVerifyTicket><![CDATA[ticket@@@xxx...]]></ComponentVerifyTicket></xml>
// 用 util.xml 解析后把 ticket 持久化到数据库（重启不能丢）
const verify_ticket = try parseTicketFromXml(allocator, decrypted.raw_xml);
defer allocator.free(verify_ticket);
saveTicketToDB(verify_ticket);
```

### ②③④⑤ 完整授权代码链路

```zig
var wc = zwechat.wechat.Wechat.init();
wc.setCache(memory_cache.asCache()); // 或 cfg.cache 直接注入；openplatform 必须有 cache

var op = try wc.getOpenPlatform(.{
    .app_id = "wxcomponent1234567890",
    .app_secret = "component-secret-0123456789abcdef",
    .token = "component-token",
    .encoding_aes_key = "component-aes-key-43chars-base64...",
});
const ctx = op.getContext();

// ② 用 verify_ticket 换 component_access_token（缓存 key
//    openplatform_component_access_token_{appid}，TTL 7000s；命中后零请求直接返回）
const comp_token = try ctx.getComponentAccessToken(allocator, verify_ticket);
defer allocator.free(comp_token);

// ③ 构造扫码授权链接（内部先 getPreCode 取预授权码，再纯本地拼 URL；
//    redirect_uri 按 Go url.QueryEscape 语义转义，可直接 302 给浏览器）
const login_url = try ctx.getComponentLoginPage(
    allocator,
    "https://cb.example.com/openplatform/callback",
    3,    // auth_type: 1=公众号, 2=小程序, 3=全部（仅展示已有权限）
    "",   // biz_app_id：指定候选授权账号时填，否则留空
);
defer allocator.free(login_url);
// 移动端 H5 授权用 ctx.getBindComponentURL(...) / getBindComponentURLV2(...)

// ④ 回调拿到 authorization_code（10 分钟内一次性有效）→ 换 authorizer 凭据。
//    成功后 SDK 自动回写双缓存：
//      authorizer_access_token_{appid}  （TTL = expires_in - 1500，钳制下限 1s）
//      authorizer_refresh_token_{appid} （10 年）
var info = try ctx.queryAuthCode(allocator, authorization_code);
defer info.deinit(allocator);
std.debug.print("authorizer={s} expires_in={d}\n", .{ info.appid, info.expires_in });

// ⑤ 之后一切按 authorizer_appid 取 token：缓存命中零请求；
//    miss 时自动读 refresh_token 缓存走 api_authorizer_token 刷新（轮换会回存新值）
const authr_token = try ctx.getAuthrAccessToken(allocator, info.appid);
defer allocator.free(authr_token);
```

### 查询授权方信息
```zig
var parsed = try ctx.getAuthrInfo(allocator, info.appid);
defer parsed.deinit();

const ai = parsed.value.authorizer_info;
std.debug.print("{s} ({s}) status={d}\n", .{ ai.nick_name, ai.principal_name, ai.account_status });
// 授权账号为小程序时存在 ai.@"MiniProgramInfo" 子树（注意微信 JSON key 大写开头）
```

### 开放平台账号管理（create / get / bind / unbind）

> ⚠️ 四个接口全部以**被授权方身份**调用，query 参数必须是
> `access_token={authorizer_access_token}`（`12_` 前缀），**不是** `component_access_token`。

```zig
var account = op.getAccountManager(allocator);

// 创建开放平台账号并绑定
const open_appid = try account.createOpenAccount(info.appid, authr_token);
defer allocator.free(open_appid);

// 查询 / 绑定 / 解绑
const existing = try account.getOpenAccount(info.appid, authr_token);
defer allocator.free(existing);
try account.bind(info.appid, open_appid, authr_token);
try account.unbind(info.appid, open_appid, authr_token);
```

> **常见坑**
> - **双 token 体系不要混**：component 系接口（`/cgi-bin/component/*`）用 component_access_token；account 四方法用 authorizer_access_token 且参数名就是 `access_token=`（写成 `component_access_token=` 线上必失败，SDK 源码注释专门强调过）。
> - **verify_ticket 必须持久化**：它只通过推送下发，内存丢了只能等下一次推送（最长 10 分钟），期间所有 component 接口不可用。
> - **getPreCode / queryAuthCode / getAuthrInfo 只读 component token 缓存**：未命中返回 `error.VerifyTicketRequired`，调用方先带 ticket 调 `getComponentAccessToken` 回源，不要传空 ticket 硬试。
> - **authorizer 刷新持锁跨 HTTP 是刻意的**：刷新会轮换 refresh_token，并发覆盖会**永久丢失凭据**；SDK 用 `token_mutex` 串行化整个「取 component token → 刷新 → 双写缓存」链路，调用方无需再加锁。
> - **authorization_code 一次性且 10 分钟过期**，回调里立即消费；消费失败只能重新走扫码授权。
> - `queryAuthCode` 返回的 `AuthBaseInfo` 是自有切片结构体，用 `info.deinit(allocator)` 释放；`getAuthrInfo` 返回的 `Parsed` 只 deinit。

---

## 10. 缓存与凭据配置 (Cache & Credential)

> **涉及模块**：`src/cache/`（`Memory` / `Redis` / `Memcache`）、`src/credential/`（`DefaultAccessToken` / `DefaultJsTicket` / `WorkAccessToken` / `WorkJsTicket`）
> **API 索引**：`docs/api-reference.md` 第 2 节「cache」、第 3 节「credential」

### 切换 Redis / Memcache 后端

单实例部署用 `Memory` 即可；**多实例部署必须切换到 Redis / Memcache**，否则各实例各自回源，极易触发微信 access_token 频控。

```zig
const zwechat = @import("zwechat");

// Redis（RESP 协议，单连接 + SpinMutex 串行化整个请求-响应往返）
const redis = try zwechat.cache.Redis.create(allocator, .{
    .host = "127.0.0.1",
    .port = 6379,
    .password = null, // 或 "your-password"
    .db = 0,
});
defer {
    redis.deinit();
    allocator.destroy(redis);
}

// Memcache（文本协议）
const memcache = try zwechat.cache.Memcache.create(allocator, .{
    .server = "127.0.0.1:11211",
});
defer {
    memcache.deinit();
    allocator.destroy(memcache);
}

// 任选其一注入全局（所有 Config.cache == null 的业务实例共享）
var wc = zwechat.wechat.Wechat.init();
wc.setCache(redis.asCache());
```

### credential：自定义 Fetcher 与 forceRefresh

默认 `DefaultAccessToken` 走内置 HTTP 客户端回源；需要走自有 HTTP 栈（代理、mock、可观测性）时注入 `Fetcher`：

```zig
const my_fetcher: zwechat.credential.Fetcher = struct {
    fn fetch(ctx: *anyopaque, alloc: std.mem.Allocator, url: []const u8) zwechat.credential.CredentialError![]u8 {
        _ = ctx;
        _ = url;
        // 生产：换成你自己的 HTTP 调用；测试：返回预制的 JSON 桩
        return alloc.dupe(u8, "{\"access_token\":\"stub_token\",\"expires_in\":7200}");
    }
}.fetch;

var dat = zwechat.credential.DefaultAccessToken.initWithFetcher(
    app_id,
    app_secret,
    zwechat.credential.CacheKeyOfficialAccountPrefix, // 公众号前缀；
    // 小程序用 CacheKeyMiniProgramPrefix，企业微信用 CacheKeyWorkPrefix
    cache_inst,
    my_fetcher,
    undefined, // fetcher_ctx，不需要透传状态可传 undefined
);

const token = try dat.getAccessToken(allocator); // 缓存 miss 时经 fetcher 回源并双检回写
defer allocator.free(token);

// Token 被判定无效（40001/40014 等）后手动强刷：清缓存 + 立即回源
const fresh = try dat.forceRefresh(allocator);
defer allocator.free(fresh);
```

### 多实例部署注意事项

1. **必须共享缓存**：credential 四个获取器（公众号 / 小程序 / 企微 / 企微 js_ticket）都是「缓存 miss → 锁内双检 → 回源 → 回写」；共享 Redis 后，N 个实例只有一个真正回源。
2. **credential 回源锁不跨 HTTP**（singleflight 式取舍）：锁只护缓存读 / 写，HTTP 回源在锁外，极端并发下接受 N 个幂等回源，避免 N-1 个线程持自旋锁空转烧 CPU。微信对 access_token 回源有频率宽容，此取舍安全。
3. **openplatform token 链路例外**：authorizer 刷新持锁跨 HTTP（见第 9 章），因为 refresh_token 轮换丢失不可逆。
4. **TTL 钳制**：`credential.tokenTTL(expires_in)` = `expires_in -| 1500`，下限 1 秒——既不会把短寿命 token 缓存成永不过期，也不会因异常 `expires_in` 整数溢出。
5. **借用切片**：`Cache.get` 返回借用切片，有效期至该实例任何后续写操作 / deinit（Redis / Memcache 后端任何后续 `get` 即失效）；跨写持有必须先 `dupe`。

> **常见坑**
> - 不要把凭据缓存 key 前缀当配置项改来改去——前缀与 Go 版对齐（`gowechat_officialaccount_` 等），已有线上缓存数据依赖同一前缀。
> - `DefaultAccessToken` 里的 `SpinMutex` 不适合长临界区：不要在持锁回调里做慢操作，`Fetcher` 内部应保持轻量。
> - `Memory` 缓存是**进程内**的：进程重启后所有 token 重新回源一次属正常现象，不要在启动路径上并发打满微信接口。
