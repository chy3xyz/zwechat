// SPDX-License-Identifier: Apache-2.0
//! pay/v3/order — 微信支付 v3 统一下单（JSAPI/小程序）、查单、关单 + 前端调起参数
//!
//! 对照微信支付 v3 官方文档（Go 参考 `_ref/wechat` 无 v3 实现）：
//! - JSAPI/小程序下单：`POST /v3/pay/transactions/jsapi`
//!   <https://pay.weixin.qq.com/doc/v3/merchant/4012791856>
//! - 商户订单号查单：`GET /v3/pay/transactions/out-trade-no/{out_trade_no}?mchid=`
//!   <https://pay.weixin.qq.com/doc/v3/merchant/4012791859>
//! - 关闭订单：`POST /v3/pay/transactions/out-trade-no/{out_trade_no}/close`
//!   <https://pay.weixin.qq.com/doc/v3/merchant/4012791881>
//! - 前端拉起支付签名：`appId\ntimeStamp\nnonceStr\npackage\n`（RSA-SHA256）

const std = @import("std");
const Config = @import("config.zig").Config;
const signer = @import("signer.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const time = @import("../../util/time.zig");
const util = @import("../../util/util.zig");
const rsa = @import("../../util/rsa.zig");
const default_io = @import("../../util/default_io.zig");

/// 微信支付 v3 主域名。
pub const base_url = "https://api.mch.weixin.qq.com";

pub const Amount = struct {
    /// 订单总金额，单位为分，必须大于 0。
    total: i64,
    /// 货币类型，固定 CNY。
    currency: []const u8 = "CNY",
};

pub const Payer = struct {
    /// 用户在商户 appid 下的唯一标识。
    openid: []const u8,
};

pub const JsapiOrderParams = struct {
    description: []const u8,
    out_trade_no: []const u8,
    /// 支付成功回调地址；为空时回落到 `Config.notify_url`。
    notify_url: []const u8 = "",
    amount: Amount,
    payer: Payer,
    /// 支付结束时间（RFC3339，如 `2018-06-08T10:34:56+08:00`），选填。
    time_expire: []const u8 = "",
    /// 商户数据包（≤128 字符），选填；支付成功后原样返回。
    attach: []const u8 = "",
    /// 订单优惠标记，选填。
    goods_tag: []const u8 = "",
    /// 电子发票入口开放标识，选填。
    support_fapiao: bool = false,
};

/// `POST /v3/pay/transactions/jsapi` 应答。
pub const CreateOrderResult = struct {
    prepay_id: []const u8 = "",
};

/// 查单应答里的金额信息。
pub const OrderQueryAmount = struct {
    total: i64 = 0,
    payer_total: i64 = 0,
    currency: []const u8 = "",
    payer_currency: []const u8 = "",
};

/// 查单应答里的支付者信息。
pub const OrderQueryPayer = struct {
    openid: []const u8 = "",
};

/// `GET /v3/pay/transactions/out-trade-no/{out_trade_no}` 应答。
///
/// `trade_state` 枚举：`SUCCESS` / `REFUND` / `NOTPAY` / `CLOSED` / `REVOKED` /
/// `USERPAYING` / `PAYERROR`。
pub const OrderQueryResult = struct {
    appid: []const u8 = "",
    mchid: []const u8 = "",
    out_trade_no: []const u8 = "",
    transaction_id: []const u8 = "",
    trade_type: []const u8 = "",
    trade_state: []const u8 = "",
    trade_state_desc: []const u8 = "",
    bank_type: []const u8 = "",
    attach: []const u8 = "",
    success_time: []const u8 = "",
    payer: OrderQueryPayer = .{},
    amount: OrderQueryAmount = .{},
};

pub const JsapiPayParams = struct {
    app_id: []const u8,
    time_stamp: []const u8,
    nonce_str: []const u8,
    package: []const u8,
    sign_type: []const u8 = "RSA",
    pay_sign: []const u8,

    pub fn deinit(self: *JsapiPayParams, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.time_stamp));
        allocator.free(@constCast(self.nonce_str));
        allocator.free(@constCast(self.package));
        allocator.free(@constCast(self.pay_sign));
    }
};

pub const OrderV3 = struct {
    cfg: Config,
    /// 时间戳 / 随机数所需的 `Io` 句柄。
    /// 默认 `default_io.io()`，宿主可注入自己的 `Io` 实例。
    io: std.Io = default_io.io(),

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,
    /// 带请求头的 mock transport（测试用）：设置后优先于 `transport`，可直接
    /// 断言 `Authorization` / `Accept` 等头确实被发出。
    header_transport: ?util_http.HeaderTransport = null,

    const Self = @This();

    pub fn init(cfg: Config) OrderV3 {
        return .{ .cfg = cfg };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTPS）。与 `setHeaderTransport` 互斥。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.header_transport = null;
        self.transport_ctx = ctx;
    }

    /// 注入带请求头的 mock transport（`null` 仅清除它）。与 `setTransport` 互斥。
    pub fn setHeaderTransport(self: *Self, t: ?util_http.HeaderTransport, ctx: ?*anyopaque) void {
        self.header_transport = t;
        self.transport = null;
        self.transport_ctx = ctx;
    }

    fn hasTransport(self: *const Self) bool {
        return self.transport != null or self.header_transport != null;
    }

    // -------------------------------------------------------------------------
    // 下单 / 查单 / 关单
    // -------------------------------------------------------------------------

    /// JSAPI / 小程序下单：`POST /v3/pay/transactions/jsapi`。
    ///
    /// `p.notify_url` 为空时回落到 `cfg.notify_url`；两者都为空返回
    /// `WechatError.InvalidArgument`（官方文档中 `notify_url` 为必填）。
    /// 返回的 `std.json.Parsed(CreateOrderResult)` 由调用方 `deinit`；
    /// v3 错误应答（`{"code":...,"message":...}`）返回 `WechatError.ApiError`。
    pub fn createJsapiOrder(
        self: *Self,
        allocator: std.mem.Allocator,
        p: JsapiOrderParams,
    ) !std.json.Parsed(CreateOrderResult) {
        if (p.description.len == 0) return util_error.WechatError.InvalidArgument;
        if (p.out_trade_no.len == 0) return util_error.WechatError.InvalidArgument;
        if (p.amount.total <= 0) return util_error.WechatError.InvalidArgument;
        if (p.payer.openid.len == 0) return util_error.WechatError.InvalidArgument;

        const notify_url = if (p.notify_url.len > 0) p.notify_url else self.cfg.notify_url;
        if (notify_url.len == 0) return util_error.WechatError.InvalidArgument;

        const body = try serializeJsapiOrderBody(allocator, self.cfg, p, notify_url);
        defer allocator.free(body);

        const path = "/v3/pay/transactions/jsapi";
        var resp = try self.doRequest(allocator, .POST, path, base_url ++ path, body);
        defer resp.deinit(allocator);

        try checkV3Error(allocator, resp.body);
        if (resp.status != .ok) return util_error.WechatError.NetworkError;

        return std.json.parseFromSlice(CreateOrderResult, allocator, resp.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return util_error.WechatError.DecodeError;
    }

    /// 商户订单号查单：`GET /v3/pay/transactions/out-trade-no/{out_trade_no}?mchid=...`。
    ///
    /// 订单未支付时只能用商户订单号查询（官方文档）。
    pub fn queryOrderByOutTradeNo(
        self: *Self,
        allocator: std.mem.Allocator,
        out_trade_no: []const u8,
    ) !std.json.Parsed(OrderQueryResult) {
        if (out_trade_no.len == 0) return util_error.WechatError.InvalidArgument;

        const canonical_url = try allocator.print(
            "/v3/pay/transactions/out-trade-no/{s}?mchid={s}",
            .{ out_trade_no, self.cfg.mch_id },
        );
        defer allocator.free(canonical_url);
        const full_url = try allocator.print("{s}{s}", .{ base_url, canonical_url });
        defer allocator.free(full_url);

        var resp = try self.doRequest(allocator, .GET, canonical_url, full_url, "");
        defer resp.deinit(allocator);

        try checkV3Error(allocator, resp.body);
        if (resp.status != .ok) return util_error.WechatError.NetworkError;

        return std.json.parseFromSlice(OrderQueryResult, allocator, resp.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return util_error.WechatError.DecodeError;
    }

    /// 关闭订单：`POST /v3/pay/transactions/out-trade-no/{out_trade_no}/close`。
    ///
    /// 成功应答为 `204 No Content`（无应答包体）；错误应答返回
    /// `WechatError.ApiError`。
    pub fn closeOrder(self: *Self, allocator: std.mem.Allocator, out_trade_no: []const u8) !void {
        if (out_trade_no.len == 0) return util_error.WechatError.InvalidArgument;

        const body = try serializeCloseBody(allocator, self.cfg);
        defer allocator.free(body);

        const canonical_url = try allocator.print(
            "/v3/pay/transactions/out-trade-no/{s}/close",
            .{out_trade_no},
        );
        defer allocator.free(canonical_url);
        const full_url = try allocator.print("{s}{s}", .{ base_url, canonical_url });
        defer allocator.free(full_url);

        var resp = try self.doRequest(allocator, .POST, canonical_url, full_url, body);
        defer resp.deinit(allocator);

        // 成功是 204 无包体；mock transport 只能回 200 + 空体，故两者都算成功。
        try checkV3Error(allocator, resp.body);
        if (resp.status != .ok and resp.status != .no_content) return util_error.WechatError.NetworkError;
    }

    /// 发送 v3 请求：先用 `signer` 生成 `Authorization` 头，再交给
    /// `util_http.HttpClient.requestWithHeaders` 发出（全仓只有 `util/http.zig`
    /// 直接构造 `std.http.Client`）。
    ///
    /// - 真实 HTTPS 路径必须签名（缺私钥时 signer 返回 `error.MissingPrivateKey`）；
    /// - 注入了 mock transport 时：配置了私钥就照签（便于测试断言 `Authorization`），
    ///   没配私钥则跳过签名；
    /// - **不做状态码判定**：v3 的 4xx/5xx 应答体里带 `code`/`message`，由调用方先交给
    ///   `checkV3Error` 分类，认不出业务错误码才按 `NetworkError` 处理。
    fn doRequest(
        self: *Self,
        allocator: std.mem.Allocator,
        method: std.http.Method,
        canonical_url: []const u8,
        full_url: []const u8,
        body: []const u8,
    ) !util_http.HttpResponse {
        var sign: ?signer.SignResult = null;
        defer if (sign) |*s| s.deinit(allocator);

        const should_sign = !self.hasTransport() or self.cfg.private_key_pem.len > 0;
        if (should_sign) {
            const method_str = switch (method) {
                .POST => "POST",
                .GET => "GET",
                else => return util_error.WechatError.InvalidArgument,
            };
            sign = try signer.buildAuthorizationHeaderWithIo(
                allocator,
                self.io,
                self.cfg,
                method_str,
                canonical_url,
                body,
            );
        }

        if (self.hasTransport() and self.transport_ctx == null)
            return util_error.WechatError.ConfigMissing;

        var header_buf: [2]std.http.Header = undefined;
        var header_count: usize = 0;
        if (sign) |s| {
            header_buf[header_count] = .{ .name = "Authorization", .value = s.authorization };
            header_count += 1;
        }
        header_buf[header_count] = .{ .name = "Accept", .value = "application/json" };
        header_count += 1;

        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        if (self.header_transport) |t| {
            client.setHeaderTransport(t, self.transport_ctx);
        } else {
            client.setTransport(self.transport, self.transport_ctx);
        }

        return client.requestWithHeaders(
            method,
            full_url,
            body,
            "application/json",
            header_buf[0..header_count],
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return util_error.WechatError.NetworkError,
        };
    }

    /// 生成前端调起微信支付的支付参数 (JSAPI / 小程序)。
    ///
    /// `cfg.private_key_pem` 为空时返回 `error.MissingPrivateKey`
    /// （修复前会静默生成伪签名，导致调起支付失败且难以排查）。
    pub fn getJsPayParams(
        self: OrderV3,
        allocator: std.mem.Allocator,
        prepay_id: []const u8,
    ) !JsapiPayParams {
        if (self.cfg.private_key_pem.len == 0) return error.MissingPrivateKey;

        const timestamp = try allocator.print("{d}", .{time.getCurrTSWithIo(self.io)});
        errdefer allocator.free(timestamp);

        const nonce_str = try util.randomStrWithIo(allocator, self.io, 32);
        errdefer allocator.free(nonce_str);

        const package_str = try allocator.print("prepay_id={s}", .{prepay_id});
        errdefer allocator.free(package_str);

        // v3 支付签名串：AppID\nTimeStamp\nNonceStr\nPackage\n
        const message = try allocator.print(
            "{s}\n{s}\n{s}\n{s}\n",
            .{ self.cfg.app_id, timestamp, nonce_str, package_str },
        );
        defer allocator.free(message);

        const raw_sig = try rsa.rsaSign(allocator, message, self.cfg.private_key_pem);
        defer allocator.free(raw_sig);

        const base64_sig = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw_sig.len));
        _ = std.base64.standard.Encoder.encode(base64_sig, raw_sig);

        return .{
            .app_id = self.cfg.app_id,
            .time_stamp = timestamp,
            .nonce_str = nonce_str,
            .package = package_str,
            .sign_type = "RSA",
            .pay_sign = base64_sig,
        };
    }
};

/// v3 错误应答结构：成功应答不含 `code` 字段，存在非空 code 即视为业务错误。
const V3ErrorBody = struct {
    code: []const u8 = "",
    message: []const u8 = "",
};

/// 若应答体可解析出非空 `code`，返回 `WechatError.ApiError`；否则正常返回。
fn checkV3Error(allocator: std.mem.Allocator, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(V3ErrorBody, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    if (parsed.value.code.len > 0) return util_error.WechatError.ApiError;
}

/// 序列化 JSAPI 下单 body（对照官方文档的字段与层级）。
fn serializeJsapiOrderBody(
    allocator: std.mem.Allocator,
    cfg: Config,
    p: JsapiOrderParams,
    notify_url: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("appid");
    try s.write(cfg.app_id);
    try s.objectField("mchid");
    try s.write(cfg.mch_id);
    try s.objectField("description");
    try s.write(p.description);
    try s.objectField("out_trade_no");
    try s.write(p.out_trade_no);
    if (p.time_expire.len > 0) {
        try s.objectField("time_expire");
        try s.write(p.time_expire);
    }
    if (p.attach.len > 0) {
        try s.objectField("attach");
        try s.write(p.attach);
    }
    try s.objectField("notify_url");
    try s.write(notify_url);
    if (p.goods_tag.len > 0) {
        try s.objectField("goods_tag");
        try s.write(p.goods_tag);
    }
    if (p.support_fapiao) {
        try s.objectField("support_fapiao");
        try s.write(true);
    }
    try s.objectField("amount");
    try s.beginObject();
    try s.objectField("total");
    try s.write(p.amount.total);
    try s.objectField("currency");
    try s.write(p.amount.currency);
    try s.endObject();
    try s.objectField("payer");
    try s.beginObject();
    try s.objectField("openid");
    try s.write(p.payer.openid);
    try s.endObject();
    try s.endObject();

    return out.toOwnedSlice();
}

/// 序列化关单 body：`{"mchid":"..."}`。
fn serializeCloseBody(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("mchid");
    try s.write(cfg.mch_id);
    try s.endObject();

    return out.toOwnedSlice();
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

const rsa_test_key = @import("platform_cert.zig").test_private_key_pkcs1;

/// 记录方法 / URL / body 的 mock transport。
const CaptureResp = struct {
    response: []const u8,
    last_uri: [512]u8 = undefined,
    last_uri_len: usize = 0,
    last_payload: [2048]u8 = undefined,
    last_payload_len: usize = 0,
    last_method: std.http.Method = .GET,

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = content_type;
        const self: *CaptureResp = @ptrCast(@alignCast(ctx));
        const ulen = @min(uri.len, self.last_uri.len);
        @memcpy(self.last_uri[0..ulen], uri[0..ulen]);
        self.last_uri_len = ulen;
        const plen = @min(payload.len, self.last_payload.len);
        @memcpy(self.last_payload[0..plen], payload[0..plen]);
        self.last_payload_len = plen;
        self.last_method = method;
        return allocator.dupe(u8, self.response);
    }

    fn lastUri(self: *const CaptureResp) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }

    fn lastPayload(self: *const CaptureResp) []const u8 {
        return self.last_payload[0..self.last_payload_len];
    }
};

/// 记录请求头的 mock transport。
const HeaderCapture = struct {
    response: []const u8,
    method: std.http.Method = .GET,
    names: [8][64]u8 = undefined,
    values: [8][512]u8 = undefined,
    name_lens: [8]usize = @splat(0),
    value_lens: [8]usize = @splat(0),
    count: usize = 0,

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
        headers: []const std.http.Header,
    ) anyerror![]u8 {
        _ = uri;
        _ = payload;
        _ = content_type;
        const self: *HeaderCapture = @ptrCast(@alignCast(ctx));
        self.method = method;
        self.count = @min(headers.len, self.names.len);
        for (headers[0..self.count], 0..) |header, i| {
            const nl = @min(header.name.len, self.names[i].len);
            @memcpy(self.names[i][0..nl], header.name[0..nl]);
            self.name_lens[i] = nl;
            const vl = @min(header.value.len, self.values[i].len);
            @memcpy(self.values[i][0..vl], header.value[0..vl]);
            self.value_lens[i] = vl;
        }
        return allocator.dupe(u8, self.response);
    }

    fn headerValue(self: *const HeaderCapture, name: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.ascii.eqlIgnoreCase(self.names[i][0..self.name_lens[i]], name))
                return self.values[i][0..self.value_lens[i]];
        }
        return null;
    }
};

fn newCaptureOrder(stub: *CaptureResp) OrderV3 {
    var o = OrderV3.init(.{ .app_id = "wx-v3", .mch_id = "1900000109" });
    o.setTransport(CaptureResp.dispatch, stub);
    return o;
}

test "OrderV3.getJsPayParams 缺私钥返回 MissingPrivateKey（不再静默伪签名）" {
    const allocator = std.testing.allocator;
    const cfg = Config{
        .app_id = "wx_v3_appid",
        .mch_id = "1900000109",
    };
    const order_v3 = OrderV3.init(cfg);
    const r = order_v3.getJsPayParams(allocator, "wx201411101639507cbf6ffd8b0779950800");
    try std.testing.expectError(error.MissingPrivateKey, r);
}

test "OrderV3.createJsapiOrder 请求体与应答解析（对照官方文档示例）" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"prepay_id\":\"wx201410272009395522657a690389285100\"}" };
    var o = newCaptureOrder(&stub);

    const parsed = try o.createJsapiOrder(allocator, .{
        .description = "Image形象店-深圳腾大-QQ公仔",
        .out_trade_no = "1217752501201407033233368018",
        .notify_url = "https://www.weixin.qq.com/wxpay/pay.php",
        .amount = .{ .total = 100, .currency = "CNY" },
        .payer = .{ .openid = "oUpF8uMuAJO_M2pxb1Q9zNjWeS6o" },
    });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, stub.last_method);
    try std.testing.expectEqualStrings(
        "https://api.mch.weixin.qq.com/v3/pay/transactions/jsapi",
        stub.lastUri(),
    );
    // 请求体字段与层级按官方文档，选填字段未设置时不出现。
    try std.testing.expectEqualStrings(
        "{\"appid\":\"wx-v3\",\"mchid\":\"1900000109\"," ++
            "\"description\":\"Image形象店-深圳腾大-QQ公仔\"," ++
            "\"out_trade_no\":\"1217752501201407033233368018\"," ++
            "\"notify_url\":\"https://www.weixin.qq.com/wxpay/pay.php\"," ++
            "\"amount\":{\"total\":100,\"currency\":\"CNY\"}," ++
            "\"payer\":{\"openid\":\"oUpF8uMuAJO_M2pxb1Q9zNjWeS6o\"}}",
        stub.lastPayload(),
    );
    try std.testing.expectEqualStrings("wx201410272009395522657a690389285100", parsed.value.prepay_id);
}

test "OrderV3.createJsapiOrder 选填字段与 notify_url 回落 cfg" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"prepay_id\":\"P1\"}" };
    var o = OrderV3.init(.{
        .app_id = "wx-v3",
        .mch_id = "1900000109",
        .notify_url = "https://cfg.example/notify",
    });
    o.setTransport(CaptureResp.dispatch, &stub);

    const parsed = try o.createJsapiOrder(allocator, .{
        .description = "desc",
        .out_trade_no = "O1",
        .amount = .{ .total = 1 },
        .payer = .{ .openid = "openid-1" },
        .time_expire = "2018-06-08T10:34:56+08:00",
        .attach = "自定义数据说明",
        .goods_tag = "WXG",
        .support_fapiao = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "{\"appid\":\"wx-v3\",\"mchid\":\"1900000109\",\"description\":\"desc\"," ++
            "\"out_trade_no\":\"O1\",\"time_expire\":\"2018-06-08T10:34:56+08:00\"," ++
            "\"attach\":\"自定义数据说明\",\"notify_url\":\"https://cfg.example/notify\"," ++
            "\"goods_tag\":\"WXG\",\"support_fapiao\":true," ++
            "\"amount\":{\"total\":1,\"currency\":\"CNY\"}," ++
            "\"payer\":{\"openid\":\"openid-1\"}}",
        stub.lastPayload(),
    );
}

test "OrderV3.createJsapiOrder 必填字段缺失返回 InvalidArgument（不发请求）" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"prepay_id\":\"P1\"}" };
    var o = newCaptureOrder(&stub);

    const base = JsapiOrderParams{
        .description = "d",
        .out_trade_no = "O1",
        .notify_url = "https://x/y",
        .amount = .{ .total = 100 },
        .payer = .{ .openid = "openid-1" },
    };

    var no_desc = base;
    no_desc.description = "";
    try std.testing.expectError(util_error.WechatError.InvalidArgument, o.createJsapiOrder(allocator, no_desc));

    var no_no = base;
    no_no.out_trade_no = "";
    try std.testing.expectError(util_error.WechatError.InvalidArgument, o.createJsapiOrder(allocator, no_no));

    var bad_amount = base;
    bad_amount.amount = .{ .total = 0 };
    try std.testing.expectError(util_error.WechatError.InvalidArgument, o.createJsapiOrder(allocator, bad_amount));

    var no_openid = base;
    no_openid.payer = .{ .openid = "" };
    try std.testing.expectError(util_error.WechatError.InvalidArgument, o.createJsapiOrder(allocator, no_openid));

    // notify_url 与 cfg.notify_url 都为空 → InvalidArgument。
    var no_notify = base;
    no_notify.notify_url = "";
    try std.testing.expectError(util_error.WechatError.InvalidArgument, o.createJsapiOrder(allocator, no_notify));

    // 一个都没发出去。
    try std.testing.expectEqual(@as(usize, 0), stub.last_uri_len);
}

test "OrderV3.createJsapiOrder / queryOrderByOutTradeNo 错误应答返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"code\":\"OUT_TRADE_NO_USED\",\"message\":\"商户订单号重复\"}" };
    var o = newCaptureOrder(&stub);

    try std.testing.expectError(util_error.WechatError.ApiError, o.createJsapiOrder(allocator, .{
        .description = "d",
        .out_trade_no = "O1",
        .notify_url = "https://x/y",
        .amount = .{ .total = 100 },
        .payer = .{ .openid = "openid-1" },
    }));

    try std.testing.expectError(util_error.WechatError.ApiError, o.queryOrderByOutTradeNo(allocator, "O1"));
}

test "OrderV3.queryOrderByOutTradeNo 路径含 mchid 且应答解析" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{
        .response =
        \\{"appid":"wxd678efh567hg6787","mchid":"1230000109","out_trade_no":"1217752501201407033233368018","transaction_id":"1217752501201407033233368018","trade_type":"MICROPAY","trade_state":"SUCCESS","trade_state_desc":"支付成功","bank_type":"CMC","attach":"自定义数据","success_time":"2018-06-08T10:34:56+08:00","payer":{"openid":"oUpF8uMuAJO_M2pxb1Q9zNjWeS6o"},"amount":{"total":100,"payer_total":100,"currency":"CNY","payer_currency":"CNY"},"scene_info":{"device_id":"013467007045764"}}
        ,
    };
    var o = newCaptureOrder(&stub);

    const parsed = try o.queryOrderByOutTradeNo(allocator, "1217752501201407033233368018");
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, stub.last_method);
    try std.testing.expectEqualStrings(
        "https://api.mch.weixin.qq.com/v3/pay/transactions/out-trade-no/1217752501201407033233368018?mchid=1900000109",
        stub.lastUri(),
    );
    // 整体比较（而非逐字段断言）：新增字段若被解析错/漏解析会立刻暴露。
    try std.testing.expectEqualDeep(OrderQueryResult{
        .appid = "wxd678efh567hg6787",
        .mchid = "1230000109",
        .out_trade_no = "1217752501201407033233368018",
        .transaction_id = "1217752501201407033233368018",
        .trade_type = "MICROPAY",
        .trade_state = "SUCCESS",
        .trade_state_desc = "支付成功",
        .bank_type = "CMC",
        .attach = "自定义数据",
        .success_time = "2018-06-08T10:34:56+08:00",
        .payer = .{ .openid = "oUpF8uMuAJO_M2pxb1Q9zNjWeS6o" },
        .amount = .{ .total = 100, .payer_total = 100, .currency = "CNY", .payer_currency = "CNY" },
    }, parsed.value);
}

test "OrderV3.queryOrderByOutTradeNo 空单号返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{}" };
    var o = newCaptureOrder(&stub);
    try std.testing.expectError(util_error.WechatError.InvalidArgument, o.queryOrderByOutTradeNo(allocator, ""));
}

test "OrderV3.closeOrder 请求体只有 mchid，空应答视为成功" {
    const allocator = std.testing.allocator;
    // mock transport 恒回 200；关单的 204 无包体在 mock 下等价于空串。
    var stub = CaptureResp{ .response = "" };
    var o = newCaptureOrder(&stub);

    try o.closeOrder(allocator, "1217752501201407033233368018");

    try std.testing.expectEqual(std.http.Method.POST, stub.last_method);
    try std.testing.expectEqualStrings(
        "https://api.mch.weixin.qq.com/v3/pay/transactions/out-trade-no/1217752501201407033233368018/close",
        stub.lastUri(),
    );
    try std.testing.expectEqualStrings("{\"mchid\":\"1900000109\"}", stub.lastPayload());
}

test "OrderV3.closeOrder 错误应答返回 ApiError，空单号返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"code\":\"ORDERNOTEXIST\",\"message\":\"订单不存在\"}" };
    var o = newCaptureOrder(&stub);

    try std.testing.expectError(util_error.WechatError.ApiError, o.closeOrder(allocator, "O1"));
    try std.testing.expectError(util_error.WechatError.InvalidArgument, o.closeOrder(allocator, ""));
}

test "OrderV3 带私钥时把 signer 生成的 Authorization 交给请求头入口" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture{ .response = "{\"prepay_id\":\"P1\"}" };

    var o = OrderV3.init(.{
        .app_id = "wx-v3",
        .mch_id = "1900000109",
        .serial_no = "1DDE557876238",
        .private_key_pem = rsa_test_key,
    });
    o.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));

    const parsed = try o.createJsapiOrder(allocator, .{
        .description = "d",
        .out_trade_no = "O1",
        .notify_url = "https://x/y",
        .amount = .{ .total = 100 },
        .payer = .{ .openid = "openid-1" },
    });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    const auth = cap.headerValue("Authorization").?;
    try std.testing.expect(std.mem.startsWith(u8, auth, "WECHATPAY2-SHA256-RSA2048 "));
    try std.testing.expect(std.mem.find(u8, auth, "mchid=\"1900000109\"") != null);
    try std.testing.expect(std.mem.find(u8, auth, "serial_no=\"1DDE557876238\"") != null);
    try std.testing.expectEqualStrings("application/json", cap.headerValue("Accept").?);
}

test "OrderV3 注入了 transport 但缺 transport_ctx 返回 ConfigMissing" {
    var o = OrderV3.init(.{ .app_id = "wx-v3", .mch_id = "1900000109" });
    o.header_transport = HeaderCapture.dispatch; // 故意不设 ctx
    try std.testing.expectError(
        util_error.WechatError.ConfigMissing,
        o.queryOrderByOutTradeNo(std.testing.allocator, "O1"),
    );
}
