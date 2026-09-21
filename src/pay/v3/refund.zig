// SPDX-License-Identifier: Apache-2.0
//! pay/v3/refund — 微信支付 v3 退款（申请退款 / 查询退款）
//!
//! 对照微信支付 v3 官方文档（Go 参考 `_ref/wechat` 无 v3 实现）：
//! - 申请退款：`POST /v3/refund/domestic/refunds`（transaction_id / out_trade_no 二选一）
//! - 查询退款：`GET /v3/refund/domestic/refunds/{out_refund_no}?mchid=...`
//! - 退款结果通知：AES-256-GCM 解密复用 `notify.decryptNotifyResource`，解密后明文
//!   结构见 `RefundNotifyResource`。

const std = @import("std");
const Config = @import("config.zig").Config;
const signer = @import("signer.zig");
const notify = @import("notify.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 退款出资账户及金额（amount.from 数组元素）。
pub const RefundFrom = struct {
    account: []const u8,
    amount: i64,
};

/// 申请退款金额信息（body.amount）。
pub const RefundAmount = struct {
    /// 退款金额（币种最小单位，只能为整数，不能超过原订单支付金额）
    refund: i64,
    /// 原订单金额（币种最小单位）
    total: i64,
    /// 退款币种，固定 CNY
    currency: []const u8 = "CNY",
    /// 退款出资账户及金额（选填）
    from: []const RefundFrom = &.{},
};

/// 申请退款请求参数。
///
/// `transaction_id` 与 `out_trade_no` 必须二选一（同时为空或同时非空均返回
/// `WechatError.InvalidArgument`）。
pub const RefundParams = struct {
    /// 微信支付订单号（与 out_trade_no 二选一）
    transaction_id: []const u8 = "",
    /// 商户订单号（与 transaction_id 二选一）
    out_trade_no: []const u8 = "",
    /// 商户退款单号（必填，商户系统内部唯一）
    out_refund_no: []const u8,
    /// 退款原因（选填，不超过 80 字节）
    reason: []const u8 = "",
    /// 退款结果回调 url（选填）
    notify_url: []const u8 = "",
    /// 退款资金来源（选填，如 AVAILABLE / UNSETTLED）
    funds_account: []const u8 = "",
    /// 金额信息（必填）
    amount: RefundAmount,
};

/// 退款单金额信息（应答 amount，查询退款应答同构）。
pub const RefundQueryAmount = struct {
    total: i64 = 0,
    refund: i64 = 0,
    payer_total: i64 = 0,
    payer_refund: i64 = 0,
    settlement_refund: i64 = 0,
    settlement_total: i64 = 0,
    discount_refund: i64 = 0,
    currency: []const u8 = "",
    refund_fee: i64 = 0,
};

/// 申请退款 / 查询退款应答（`std.json.Parsed(RefundResult)` 由调用方 deinit）。
pub const RefundResult = struct {
    refund_id: []const u8 = "",
    out_refund_no: []const u8 = "",
    transaction_id: []const u8 = "",
    out_trade_no: []const u8 = "",
    channel: []const u8 = "",
    user_received_account: []const u8 = "",
    success_time: []const u8 = "",
    create_time: []const u8 = "",
    status: []const u8 = "",
    funds_account: []const u8 = "",
    amount: RefundQueryAmount = .{},
};

/// 退款结果通知 resource 解密后的明文结构（event_type = REFUND.SUCCESS）。
///
/// 用法：先用 `notify.decryptNotifyResource` 解密通知报文的 resource，
/// 再对明文 JSON 解析到本结构。
pub const RefundNotifyResource = struct {
    mchid: []const u8 = "",
    out_trade_no: []const u8 = "",
    transaction_id: []const u8 = "",
    out_refund_no: []const u8 = "",
    refund_id: []const u8 = "",
    refund_status: []const u8 = "",
    success_time: []const u8 = "",
    user_received_account: []const u8 = "",
    amount: RefundNotifyAmount = .{},
};

/// 退款通知金额信息。
pub const RefundNotifyAmount = struct {
    total: i64 = 0,
    refund: i64 = 0,
    payer_total: i64 = 0,
    payer_refund: i64 = 0,
    settlement_refund: i64 = 0,
    settlement_total: i64 = 0,
};

pub const RefundV3 = struct {
    cfg: Config,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP，
    /// 此时跳过本地 RSA 签名，直接以 mock 响应返回）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTPS + 商户私钥签名）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 申请退款：`POST /v3/refund/domestic/refunds`。
    ///
    /// 返回的 `std.json.Parsed(RefundResult)` 由调用方持有并负责 `deinit`；
    /// v3 错误应答（`{"code":...,"message":...}`）返回 `WechatError.ApiError`。
    pub fn refund(self: *Self, allocator: std.mem.Allocator, p: RefundParams) !std.json.Parsed(RefundResult) {
        if ((p.transaction_id.len == 0) == (p.out_trade_no.len == 0))
            return util_error.WechatError.InvalidArgument;

        const body = try serializeRefundBody(allocator, p);
        defer allocator.free(body);

        const resp = try self.doRequest(
            allocator,
            .POST,
            "/v3/refund/domestic/refunds",
            "https://api.mch.weixin.qq.com/v3/refund/domestic/refunds",
            body,
        );
        defer allocator.free(resp);

        try checkV3Error(allocator, resp);

        return std.json.parseFromSlice(RefundResult, allocator, resp, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return util_error.WechatError.DecodeError;
    }

    /// 查询退款：`GET /v3/refund/domestic/refunds/{out_refund_no}`。
    ///
    /// 返回的 `std.json.Parsed(RefundResult)` 由调用方持有并负责 `deinit`；
    /// v3 错误应答返回 `WechatError.ApiError`。
    pub fn queryRefund(self: *Self, allocator: std.mem.Allocator, out_refund_no: []const u8) !std.json.Parsed(RefundResult) {
        if (out_refund_no.len == 0) return util_error.WechatError.InvalidArgument;

        const canonical_url = try std.fmt.allocPrint(
            allocator,
            "/v3/refund/domestic/refunds/{s}?mchid={s}",
            .{ out_refund_no, self.cfg.mch_id },
        );
        defer allocator.free(canonical_url);

        const full_url = try std.fmt.allocPrint(
            allocator,
            "https://api.mch.weixin.qq.com{s}",
            .{canonical_url},
        );
        defer allocator.free(full_url);

        const resp = try self.doRequest(allocator, .GET, canonical_url, full_url, "");
        defer allocator.free(resp);

        try checkV3Error(allocator, resp);

        return std.json.parseFromSlice(RefundResult, allocator, resp, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return util_error.WechatError.DecodeError;
    }

    /// 发送 v3 请求：先按 signer 惯例生成 `Authorization` 头（真实 HTTPS 路径），
    /// transport 已注入时直接走 mock（跳过签名，测试无需真实私钥）。
    fn doRequest(
        self: *Self,
        allocator: std.mem.Allocator,
        method: std.http.Method,
        canonical_url: []const u8,
        full_url: []const u8,
        body: []const u8,
    ) ![]u8 {
        var sign: ?signer.SignResult = null;
        defer if (sign) |*s| s.deinit(allocator);

        if (self.transport == null) {
            const method_str = switch (method) {
                .POST => "POST",
                .GET => "GET",
                else => return util_error.WechatError.InvalidArgument,
            };
            sign = try signer.buildAuthorizationHeader(allocator, self.cfg, method_str, canonical_url, body);
        }

        if (self.transport) |t| {
            const tctx = self.transport_ctx orelse return util_error.WechatError.ConfigMissing;
            return t(tctx, allocator, full_url, method, body, "application/json");
        }

        var client: std.http.Client = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
        };
        defer client.deinit();

        var body_writer: std.Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();

        const extra_headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "application/json" },
        };

        const result = client.fetch(.{
            .method = method,
            .location = .{ .url = full_url },
            .payload = if (body.len == 0 and method == .GET) null else body,
            .response_writer = &body_writer.writer,
            .extra_headers = &extra_headers,
            .headers = .{
                .authorization = .{ .override = sign.?.authorization },
                .content_type = .{ .override = "application/json" },
            },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return util_error.WechatError.NetworkError,
        };

        if (result.status != .ok) {
            // v3 非 2xx 应答同样携带 {"code","message"}，能解析出业务错误码时
            // 按 SDK 纪律返回 ApiError。
            try checkV3Error(allocator, body_writer.written());
            return util_error.WechatError.NetworkError;
        }

        var list = body_writer.toArrayList();
        defer list.deinit(allocator);
        return list.toOwnedSlice(allocator);
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

/// 序列化申请退款 body（空字段不输出，字符串经 JSON 转义）。
fn serializeRefundBody(allocator: std.mem.Allocator, p: RefundParams) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    if (p.transaction_id.len > 0) {
        try s.objectField("transaction_id");
        try s.write(p.transaction_id);
    }
    if (p.out_trade_no.len > 0) {
        try s.objectField("out_trade_no");
        try s.write(p.out_trade_no);
    }
    try s.objectField("out_refund_no");
    try s.write(p.out_refund_no);
    if (p.reason.len > 0) {
        try s.objectField("reason");
        try s.write(p.reason);
    }
    if (p.notify_url.len > 0) {
        try s.objectField("notify_url");
        try s.write(p.notify_url);
    }
    if (p.funds_account.len > 0) {
        try s.objectField("funds_account");
        try s.write(p.funds_account);
    }
    try s.objectField("amount");
    try s.beginObject();
    try s.objectField("refund");
    try s.write(p.amount.refund);
    if (p.amount.from.len > 0) {
        try s.objectField("from");
        try s.write(p.amount.from);
    }
    try s.objectField("total");
    try s.write(p.amount.total);
    try s.objectField("currency");
    try s.write(p.amount.currency);
    try s.endObject();
    try s.endObject();

    return out.toOwnedSlice();
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

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

fn newCaptureRefund(stub: *CaptureResp) RefundV3 {
    var r = RefundV3.init(.{ .app_id = "wx-v3", .mch_id = "1900000109" });
    r.setTransport(CaptureResp.dispatch, stub);
    return r;
}

test "RefundV3.refund 双单号皆空或皆有返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{}" };
    var r = newCaptureRefund(&stub);

    const none = r.refund(allocator, .{
        .out_refund_no = "R1",
        .amount = .{ .refund = 100, .total = 100 },
    });
    try std.testing.expectError(util_error.WechatError.InvalidArgument, none);

    const both = r.refund(allocator, .{
        .transaction_id = "T1",
        .out_trade_no = "O1",
        .out_refund_no = "R1",
        .amount = .{ .refund = 100, .total = 100 },
    });
    try std.testing.expectError(util_error.WechatError.InvalidArgument, both);
}

test "RefundV3.refund 请求体与应答解析（对照官方文档示例）" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{
        .response =
        \\{"refund_id":"50000000382019052709732678859","out_refund_no":"1217752501201407033233368018","transaction_id":"1217752501201407033233368018","out_trade_no":"1217752501201407033233368018","channel":"ORIGINAL","user_received_account":"招商银行信用卡","success_time":"2020-12-01T16:18:12+08:00","create_time":"2020-12-01T16:18:12+08:00","status":"SUCCESS","funds_account":"UNSETTLED","amount":{"total":100,"refund":100,"payer_total":90,"payer_refund":90,"settlement_refund":100,"settlement_total":100,"discount_refund":10,"currency":"CNY","refund_fee":100}}
        ,
    };
    var r = newCaptureRefund(&stub);

    const parsed = try r.refund(allocator, .{
        .transaction_id = "1217752501201407033233368018",
        .out_refund_no = "1217752501201407033233368018",
        .reason = "商品已售完",
        .notify_url = "https://weixin.qq.com",
        .amount = .{ .refund = 888, .total = 888 },
    });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, stub.last_method);
    try std.testing.expectEqualStrings("https://api.mch.weixin.qq.com/v3/refund/domestic/refunds", stub.lastUri());
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"transaction_id\":\"1217752501201407033233368018\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"out_refund_no\":\"1217752501201407033233368018\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"refund\":888") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"currency\":\"CNY\"") != null);

    try std.testing.expectEqualStrings("50000000382019052709732678859", parsed.value.refund_id);
    try std.testing.expectEqualStrings("SUCCESS", parsed.value.status);
    try std.testing.expectEqual(@as(i64, 100), parsed.value.amount.refund);
    try std.testing.expectEqual(@as(i64, 90), parsed.value.amount.payer_refund);
    try std.testing.expectEqualStrings("招商银行信用卡", parsed.value.user_received_account);
}

test "RefundV3.refund 错误应答返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"code\":\"NOT_ENOUGH\",\"message\":\"余额不足\"}" };
    var r = newCaptureRefund(&stub);

    const result = r.refund(allocator, .{
        .out_trade_no = "O1",
        .out_refund_no = "R1",
        .amount = .{ .refund = 100, .total = 100 },
    });
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "RefundV3.queryRefund 路径含 mchid 且应答解析" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{
        .response =
        \\{"refund_id":"50000000382019052709732678859","out_refund_no":"R123","transaction_id":"T1","out_trade_no":"O1","channel":"ORIGINAL","user_received_account":"支付用户零钱","create_time":"2020-12-01T16:18:12+08:00","status":"PROCESSING","amount":{"total":100,"refund":50,"payer_total":100,"payer_refund":50,"settlement_refund":50,"settlement_total":100,"currency":"CNY"}}
        ,
    };
    var r = newCaptureRefund(&stub);

    const parsed = try r.queryRefund(allocator, "R123");
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, stub.last_method);
    try std.testing.expectEqualStrings(
        "https://api.mch.weixin.qq.com/v3/refund/domestic/refunds/R123?mchid=1900000109",
        stub.lastUri(),
    );
    try std.testing.expectEqualStrings("R123", parsed.value.out_refund_no);
    try std.testing.expectEqualStrings("PROCESSING", parsed.value.status);
    try std.testing.expectEqual(@as(i64, 50), parsed.value.amount.refund);
}

test "RefundV3.queryRefund 空单号返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{}" };
    var r = newCaptureRefund(&stub);

    const result = r.queryRefund(allocator, "");
    try std.testing.expectError(util_error.WechatError.InvalidArgument, result);
}

test "RefundNotifyResource 解密明文解析（退款结果通知）" {
    const allocator = std.testing.allocator;
    const plain =
        \\{"mchid":"1900000109","out_trade_no":"20260722001","transaction_id":"4200000119202504081234567890","out_refund_no":"R20260722001","refund_id":"50302025040812345678901","refund_status":"SUCCESS","success_time":"2026-07-22T10:00:00+08:00","user_received_account":"支付用户零钱","amount":{"total":100,"refund":100,"payer_total":100,"payer_refund":100,"settlement_refund":100,"settlement_total":100}}
    ;

    const parsed = try std.json.parseFromSlice(RefundNotifyResource, allocator, plain, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("50302025040812345678901", parsed.value.refund_id);
    try std.testing.expectEqualStrings("SUCCESS", parsed.value.refund_status);
    try std.testing.expectEqual(@as(i64, 100), parsed.value.amount.payer_refund);

    // 与 notify.decryptNotifyResource 的 AES-256-GCM 往返能力组合验证：
    // 退款通知 resource 的加解密与支付通知完全同构（复用，不另造轮子）。
    const api_v3_key = "12345678901234567890123456789012";
    const nonce = "123456789012";
    const aad = "refund";
    const key_bytes: [32]u8 = api_v3_key[0..32].*;
    const nonce_bytes: [12]u8 = nonce[0..12].*;

    const cipher_buf = try allocator.alloc(u8, plain.len);
    defer allocator.free(cipher_buf);
    var tag: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(cipher_buf, &tag, plain, aad, nonce_bytes, key_bytes);

    const full = try allocator.alloc(u8, plain.len + 16);
    defer allocator.free(full);
    @memcpy(full[0..plain.len], cipher_buf);
    @memcpy(full[plain.len..], &tag);

    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(full.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, full);

    const decrypted = try notify.decryptNotifyResource(allocator, api_v3_key, b64, aad, nonce);
    defer allocator.free(decrypted);

    const reparsed = try std.json.parseFromSlice(RefundNotifyResource, allocator, decrypted, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("R20260722001", reparsed.value.out_refund_no);
}
