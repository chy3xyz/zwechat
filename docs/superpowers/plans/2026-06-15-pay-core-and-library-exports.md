# Pay core V2 and library exports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose `work`, `pay`, `miniprogram`, and `openplatform` from the library root and the top-level `Wechat` container, and fill in the missing Pay V2 core methods.

**Architecture:** Add root re-exports and `Wechat` factories. Extend `Pay` with `getTransfer`/`getRedpacket` and `Order` with query/close/convenience methods. Keep all HTTP/XML patterns identical to the existing `prePayOrder` implementation.

**Tech Stack:** Zig 0.17, existing `src/pay/*`, `src/util/*`, `src/cache/mod.zig`, `src/credential/mod.zig`.

---

## File Structure

- Modify: `src/root.zig` — export `work`, `pay`, `miniprogram`, `openplatform`.
- Modify: `src/wechat.zig` — add factories for the four business modules.
- Modify: `src/pay/pay.zig` — expose `Transfer` and `Redpacket` factories.
- Modify: `src/pay/order/mod.zig` — add `queryOrder`, `closeOrder`, `prePayID`, `bridgeAppConfig`.
- No new files.

## Task 1: Export work/pay/miniprogram/openplatform from root

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: Add re-exports after `officialaccount`**

```zig
/// 企业微信业务模块。
pub const work = @import("work/mod.zig");
/// 微信支付业务模块。
pub const pay = @import("pay/mod.zig");
/// 微信小程序业务模块。
pub const miniprogram = @import("miniprogram/mod.zig");
/// 微信开放平台业务模块。
pub const openplatform = @import("openplatform/mod.zig");
```

- [ ] **Step 2: Add module export test**

Append to the tests section of `src/root.zig`:

```zig
test "root 导出所有业务模块" {
    try std.testing.expect(@hasDecl(@This(), "work"));
    try std.testing.expect(@hasDecl(@This(), "pay"));
    try std.testing.expect(@hasDecl(@This(), "miniprogram"));
    try std.testing.expect(@hasDecl(@This(), "openplatform"));
}
```

- [ ] **Step 3: Build check**

Run: `zig build test`
Expected: PASS.

## Task 2: Add Wechat factories

**Files:**
- Modify: `src/wechat.zig`

- [ ] **Step 1: Import the four business modules**

At the top of `src/wechat.zig`, after the existing imports:

```zig
const work_mod = @import("work/mod.zig");
const pay_mod = @import("pay/mod.zig");
const miniprogram_mod = @import("miniprogram/mod.zig");
const openplatform_mod = @import("openplatform/mod.zig");
```

- [ ] **Step 2: Add `getWork`**

Inside `pub const Wechat = struct { ... }`:

```zig
pub const GetWorkError = error{CacheUnavailable};

/// 获取企业微信实例。
///
/// `cfg.cache` 为空时使用 `Wechat` 全局 cache；两者都为空则返回 `error.CacheUnavailable`。
pub fn getWork(
    self: *Wechat,
    allocator: std.mem.Allocator,
    cfg: work_mod.Config,
) (GetWorkError || anyerror)!work_mod.Work {
    var resolved_cfg = cfg;
    resolved_cfg.cache = cfg.cache orelse self.cache orelse return error.CacheUnavailable;
    return work_mod.Work.newDefaultWork(resolved_cfg, allocator);
}
```

- [ ] **Step 3: Add `getPay`**

```zig
/// 获取微信支付实例。
///
/// 微信支付当前不依赖 cache，因此直接返回实例。
pub fn getPay(self: *Wechat, cfg: pay_mod.Config) pay_mod.Pay {
    _ = self;
    return pay_mod.Pay.init(cfg);
}
```

- [ ] **Step 4: Add `getMiniProgram`**

```zig
pub const GetMiniProgramError = error{CacheUnavailable};

/// 获取小程序实例。
///
/// `default_access_token_factory` 与 `getOfficialAccount` 的工厂参数语义一致。
pub fn getMiniProgram(
    self: *Wechat,
    allocator: std.mem.Allocator,
    cfg: miniprogram_mod.Config,
    default_access_token_factory: *const fn (
        cfg: miniprogram_mod.Config,
        cache: cache_mod.Cache,
    ) anyerror!credential_mod.AccessTokenHandle,
) (GetMiniProgramError || anyerror)!miniprogram_mod.MiniProgram {
    var resolved_cfg = cfg;
    resolved_cfg.cache = cfg.cache orelse self.cache orelse return error.CacheUnavailable;
    const handle = try default_access_token_factory(resolved_cfg, resolved_cfg.cache);
    return miniprogram_mod.MiniProgram.init(allocator, resolved_cfg, handle);
}
```

- [ ] **Step 5: Add `getOpenPlatform`**

```zig
pub const GetOpenPlatformError = error{CacheUnavailable};

/// 获取开放平台（第三方平台）实例。
pub fn getOpenPlatform(
    self: *Wechat,
    cfg: openplatform_mod.Config,
) GetOpenPlatformError!openplatform_mod.OpenPlatform {
    var resolved_cfg = cfg;
    resolved_cfg.cache = cfg.cache orelse self.cache orelse return error.CacheUnavailable;
    return openplatform_mod.OpenPlatform.newOpenPlatform(resolved_cfg);
}
```

- [ ] **Step 6: Add factory tests**

Append to the tests section of `src/wechat.zig`:

```zig
test "Wechat.getPay 返回 Pay 实例" {
    const p = Wechat.init().getPay(.{ .app_id = "wx-pay", .mch_id = "123" });
    try std.testing.expectEqualStrings("wx-pay", p.cfg.app_id);
}

test "Wechat.getOpenPlatform 注入全局 cache" {
    const allocator = std.testing.allocator;
    const mem = try cache_mod.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }
    var wc = Wechat.init();
    wc.setCache(mem.asCache());
    const op = wc.getOpenPlatform(.{ .app_id = "wx-op" });
    try std.testing.expect(op.ctx.config.cache != null);
}

test "Wechat.getWork 无 cache 返回 CacheUnavailable" {
    const result = Wechat.init().getWork(std.testing.allocator, .{ .corp_id = "ww" });
    try std.testing.expectError(error.CacheUnavailable, result);
}

test "Wechat.getMiniProgram 无 cache 返回 CacheUnavailable" {
    const result = Wechat.init().getMiniProgram(
        std.testing.allocator,
        .{ .app_id = "wx-mp" },
        undefined,
    );
    try std.testing.expectError(error.CacheUnavailable, result);
}
```

- [ ] **Step 7: Build check**

Run: `zig build test`
Expected: PASS.

## Task 3: Add Pay.getTransfer/getRedpacket

**Files:**
- Modify: `src/pay/pay.zig`

- [ ] **Step 1: Add factory methods**

Inside `pub const Pay = struct { ... }`:

```zig
pub fn getTransfer(self: *Pay) Transfer {
    return Transfer.init(self.cfg);
}

pub fn getRedpacket(self: *Pay) Redpacket {
    return Redpacket.init(self.cfg);
}
```

- [ ] **Step 2: Add tests**

Append to the tests section:

```zig
test "Pay.getTransfer / getRedpacket 返回实例" {
    var p = Pay.init(.{ .app_id = "wx-p", .mch_id = "m" });
    const t = p.getTransfer();
    try std.testing.expectEqualStrings("m", t.cfg.mch_id);
    const r = p.getRedpacket();
    try std.testing.expectEqualStrings("wx-p", r.cfg.app_id);
}
```

- [ ] **Step 3: Build check**

Run: `zig build test`
Expected: PASS.

## Task 4: Add Order.queryOrder/closeOrder/prePayID/bridgeAppConfig

**Files:**
- Modify: `src/pay/order/mod.zig`

- [ ] **Step 1: Add result structs after `BridgeConfig`**

```zig
/// 查询订单结果。
pub const QueryOrderResult = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    result_code: []const u8 = "",
    err_code: []const u8 = "",
    err_code_des: []const u8 = "",
    trade_state: []const u8 = "",
    out_trade_no: []const u8 = "",
    transaction_id: []const u8 = "",
};

/// 关闭订单结果。
pub const CloseOrderResult = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    result_code: []const u8 = "",
    err_code: []const u8 = "",
    err_code_des: []const u8 = "",
};

/// APP 拉起支付配置。
pub const AppConfig = struct {
    appid: []const u8,
    partnerid: []const u8,
    prepayid: []const u8,
    package: []const u8,
    nonce_str: []const u8,
    timestamp: []const u8,
    sign: []const u8,
};
```

- [ ] **Step 2: Add helper `buildSimpleXml` in the internal helper section**

After `buildUnifiedOrderXml`:

```zig
fn buildSimpleXml(
    allocator: std.mem.Allocator,
    root: []const u8,
    elements: []const util_xml.XmlElement,
) ![]u8 {
    var list = std.ArrayList(util_xml.XmlElement).empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, elements);
    return util_xml.serialize(allocator, root, list.items);
}
```

- [ ] **Step 3: Add `queryOrder`**

Inside `pub const Order = struct { ... }` after `prePayOrder`:

```zig
/// 查询订单（POST XML）。
pub fn queryOrder(self: *Self, allocator: std.mem.Allocator, out_trade_no: []const u8) !QueryOrderResult {
    const nonce_str = try util_util.randomStr(allocator, 32);
    defer allocator.free(nonce_str);

    const params = [_]util_param.Param{
        .{ .key = "appid", .value = self.cfg.app_id },
        .{ .key = "mch_id", .value = self.cfg.mch_id },
        .{ .key = "out_trade_no", .value = out_trade_no },
        .{ .key = "nonce_str", .value = nonce_str },
    };
    const sign = try signMd5(allocator, &params, self.cfg.key);
    defer allocator.free(sign);

    const xml_body = try buildSimpleXml(allocator, "xml", &[_]util_xml.XmlElement{
        .{ .key = "appid", .value = self.cfg.app_id },
        .{ .key = "mch_id", .value = self.cfg.mch_id },
        .{ .key = "out_trade_no", .value = out_trade_no },
        .{ .key = "nonce_str", .value = nonce_str },
        .{ .key = "sign", .value = sign },
    });
    defer allocator.free(xml_body);

    var client = util_http.HttpClient.init(allocator);
    defer client.deinit();
    const body = try client.postXML("https://api.mch.weixin.qq.com/pay/orderquery", xml_body);
    defer allocator.free(body);

    var doc = try util_xml.parse(allocator, body);
    defer doc.deinit();

    return .{
        .return_code = doc.get("return_code") orelse "",
        .return_msg = doc.get("return_msg") orelse "",
        .result_code = doc.get("result_code") orelse "",
        .err_code = doc.get("err_code") orelse "",
        .err_code_des = doc.get("err_code_des") orelse "",
        .trade_state = doc.get("trade_state") orelse "",
        .out_trade_no = doc.get("out_trade_no") orelse "",
        .transaction_id = doc.get("transaction_id") orelse "",
    };
}
```

- [ ] **Step 4: Add `closeOrder`**

```zig
/// 关闭订单（POST XML）。
pub fn closeOrder(self: *Self, allocator: std.mem.Allocator, out_trade_no: []const u8) !CloseOrderResult {
    const nonce_str = try util_util.randomStr(allocator, 32);
    defer allocator.free(nonce_str);

    const params = [_]util_param.Param{
        .{ .key = "appid", .value = self.cfg.app_id },
        .{ .key = "mch_id", .value = self.cfg.mch_id },
        .{ .key = "out_trade_no", .value = out_trade_no },
        .{ .key = "nonce_str", .value = nonce_str },
    };
    const sign = try signMd5(allocator, &params, self.cfg.key);
    defer allocator.free(sign);

    const xml_body = try buildSimpleXml(allocator, "xml", &[_]util_xml.XmlElement{
        .{ .key = "appid", .value = self.cfg.app_id },
        .{ .key = "mch_id", .value = self.cfg.mch_id },
        .{ .key = "out_trade_no", .value = out_trade_no },
        .{ .key = "nonce_str", .value = nonce_str },
        .{ .key = "sign", .value = sign },
    });
    defer allocator.free(xml_body);

    var client = util_http.HttpClient.init(allocator);
    defer client.deinit();
    const body = try client.postXML("https://api.mch.weixin.qq.com/pay/closeorder", xml_body);
    defer allocator.free(body);

    var doc = try util_xml.parse(allocator, body);
    defer doc.deinit();

    return .{
        .return_code = doc.get("return_code") orelse "",
        .return_msg = doc.get("return_msg") orelse "",
        .result_code = doc.get("result_code") orelse "",
        .err_code = doc.get("err_code") orelse "",
        .err_code_des = doc.get("err_code_des") orelse "",
    };
}
```

- [ ] **Step 5: Add `prePayID` convenience**

```zig
pub fn prePayID(self: *Self, allocator: std.mem.Allocator, pre_order: PreOrder) error{PrepayIdEmpty}![]u8 {
    _ = self;
    if (pre_order.prepay_id.len == 0) return error.PrepayIdEmpty;
    return allocator.dupe(u8, pre_order.prepay_id);
}
```

- [ ] **Step 6: Add `bridgeAppConfig`**

```zig
/// 构造 APP 拉起支付参数。
pub fn bridgeAppConfig(self: *Self, allocator: std.mem.Allocator, pre_order: PreOrder) !AppConfig {
    const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
    defer allocator.free(timestamp);

    const nonce_str = try util_util.randomStr(allocator, 32);
    defer allocator.free(nonce_str);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.writer.print(
        "appid={s}&noncestr={s}&package=Sign=WXPay&partnerid={s}&prepayid={s}&timestamp={s}&key={s}",
        .{ self.cfg.app_id, nonce_str, self.cfg.mch_id, pre_order.prepay_id, timestamp, self.cfg.key },
    );
    const raw = buf.items;
    const sign_md5 = try util_crypto.calculateSign(allocator, raw, util_crypto.SignTypeMD5, "");
    defer allocator.free(sign_md5);

    return .{
        .appid = try allocator.dupe(u8, self.cfg.app_id),
        .partnerid = try allocator.dupe(u8, self.cfg.mch_id),
        .prepayid = try allocator.dupe(u8, pre_order.prepay_id),
        .package = "Sign=WXPay",
        .nonce_str = try allocator.dupe(u8, nonce_str),
        .timestamp = try allocator.dupe(u8, timestamp),
        .sign = try allocator.dupe(u8, sign_md5),
    };
}
```

- [ ] **Step 7: Add tests**

Append to the tests section:

```zig
test "Order.prePayID 返回 prepay_id" {
    const allocator = std.testing.allocator;
    const o = Order.init(.{ .app_id = "wx", .mch_id = "m", .key = "k" });
    const id = try o.prePayID(allocator, .{ .prepay_id = "wx_prepay_123" });
    defer allocator.free(id);
    try std.testing.expectEqualStrings("wx_prepay_123", id);
}

test "Order.prePayID 空值返回错误" {
    const o = Order.init(.{});
    const result = o.prePayID(std.testing.allocator, .{});
    try std.testing.expectError(error.PrepayIdEmpty, result);
}
```

- [ ] **Step 8: Build check**

Run: `zig build test`
Expected: PASS.

## Task 5: Commit

- [ ] **Step 1: Commit**

```bash
git add src/root.zig src/wechat.zig src/pay/pay.zig src/pay/order/mod.zig
git commit -m "feat: library exports and pay V2 core methods"
```

## Verification

Run: `zig build test`
Expected: all tests pass, zero leaks.
