# zwechat API 使用指南与速查手册

`zwechat` 是基于 Zig 0.17 打造的高性能、零内存泄漏微信开放接口 SDK，全面覆盖公众号、小程序、微信支付 v2/v3、企业微信及开放平台。

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

### 凭据自动刷洗与 Token 强刷
当 Token 失效（如微信返回 `40001` / `40014`）时，可调用 `forceRefresh` 手动重新回源拉取：
```zig
const access_token = try default_token_inst.forceRefresh(allocator);
defer allocator.free(access_token);
```

---

## 2. 微信公众号 (OfficialAccount)

### URL 签名校验与消息加解密
```zig
const zwechat = @import("zwechat");

// 校验微信推送签名
const is_valid = zwechat.middleware.verifyServerSignature(allocator, token, .{
    .signature = signature_str,
    .timestamp = timestamp_str,
    .nonce = nonce_str,
});

// 解密 AES 消息
var decrypted = try zwechat.middleware.handleServerMessage(
    allocator,
    encoding_aes_key,
    encrypted_xml_data,
);
defer decrypted.deinit(allocator);

std.debug.print("收到明文 XML: {s}\n", .{decrypted.raw_xml});
```

---

## 3. 微信支付 v2/v3 (Pay v2 & v3)

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

---

## 4. 企业微信 (Work)

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

---

## 5. 小程序 (MiniProgram)

### 小程序订阅消息发送 (`subscribeMessage.send`)
```zig
var mp = wc.getMiniProgram(allocator, mp_cfg, default_factory);
var msg = mp.getMessage();

const resp = try msg.sendSubscribeMessage(allocator, .{
    .touser = "openid_123",
    .template_id = "template_id_456",
    .data = "{\"thing1\":{\"value\":\"提醒\"}}",
});
defer allocator.free(resp);
```

### 文本内容安全审核 (`security.msgSecCheck`)
```zig
var sec = mp.getSecurity();
const check_res = try sec.msgSecCheck(
    allocator,
    "openid_123",
    "待审核文本内容",
    1, // 1: 资料, 2: 评论, 3: 论坛
);
defer allocator.free(check_res);
```

---

## 6. 编译期模板生成器 (Comptime Template)

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
2. **结构体资源释放**：返回 `Config` / `JsapiPayParams` / `DecryptedMessage` 等复杂结构体时，使用对应的 `defer obj.deinit(allocator)` 释放其内部堆字段。
3. **单元测试验证**：推荐在你的程序中使用 `std.testing.allocator`，它能帮助你在单元测试阶段发现 100% 的内存泄漏与双重释放问题。
