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

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,
    /// 带请求头的 mock transport（测试用）：设置后优先于 `transport`，可直接
    /// 断言 `Authorization` / `Accept` 等头确实被发出。
    header_transport: ?util_http.HeaderTransport = null,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTPS）。
    ///
    /// 与 `setHeaderTransport` 互斥（会清掉后者）。
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

    /// 是否注入了任意 mock transport。
    fn hasTransport(self: *const Self) bool {
        return self.transport != null or self.header_transport != null;
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

    /// 发送 v3 请求：先用 `signer` 生成 `Authorization` 头，再交给
    /// `util_http.HttpClient.requestWithHeaders` 发出（全仓只有 `util/http.zig`
    /// 直接构造 `std.http.Client`）。
    ///
    /// - 真实 HTTPS 路径必须签名（缺私钥时 signer 返回 `error.MissingPrivateKey`）；
    /// - 注入了 mock transport 时：配置了私钥就照签（便于测试断言 `Authorization`），
    ///   没配私钥则跳过签名（历史行为，测试无需真实私钥）；
    /// - **不做状态码判定**：v3 的 4xx/5xx 应答体里带 `code`/`message`，先交给
    ///   `checkV3Error` 分类，认不出业务错误码才按 `NetworkError` 处理。
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

        const should_sign = !self.hasTransport() or self.cfg.private_key_pem.len > 0;
        if (should_sign) {
            const method_str = switch (method) {
                .POST => "POST",
                .GET => "GET",
                else => return util_error.WechatError.InvalidArgument,
            };
            sign = try signer.buildAuthorizationHeader(allocator, self.cfg, method_str, canonical_url, body);
        }

        if (self.hasTransport() and self.transport_ctx == null)
            return util_error.WechatError.ConfigMissing;

        // Authorization 仅在真的签了名时出现（mch_id / serial_no / signature 全部
        // 由 signer 生成，不在这里拼）。
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

        var resp = client.requestWithHeaders(
            method,
            full_url,
            body,
            "application/json",
            header_buf[0..header_count],
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return util_error.WechatError.NetworkError,
        };

        if (resp.status != .ok) {
            defer resp.deinit(allocator);
            try checkV3Error(allocator, resp.body);
            return util_error.WechatError.NetworkError;
        }

        // 成功路径把 body 的所有权交给调用方（不再 deinit）。
        return resp.body;
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

/// 测试用 RSA 私钥（1024-bit，一次性生成的公开 throwaway 密钥；`util/rsa.zig`
/// 的测试用的是同一把）。只为验证「真实/带私钥的 mock 路径确实走了 signer」。
const test_private_key_pkcs1 =
    "-----BEGIN RSA PRIVATE KEY-----\n" ++
    "MIICXAIBAAKBgQDeEfNBUM8LdVgybCmePyzqq4K4JeITO0tSI3cjLVIU0WNjn+/Z\n" ++
    "XQkp2wnxRwy7rejptcZ52VSisBkZ24O2nmQ1mggRQ62qHiMqOJdfBCr5eYIcC+nB\n" ++
    "hZTMCXeokzGXNQgWHSYSequj3b0IQLW/UJuoy4LshG69+3XtcOWFTitj6wIDAQAB\n" ++
    "AoGADhiVmE/I1LFeJ9U1zxWzhDHe2lGNSCs7XLtjlJgL3cZsyKYeU23UZxPATdB0\n" ++
    "vnULk8o2DwX8mVcUQM/uTGlBcwdJSYHDgxm/ALQLFk/HWndQZPhRG4beOPuleA/u\n" ++
    "nLyyI+WCs/kcTfkSVLxyWhd8mffdlPc8zJ3BeTscKuye9AECQQD3tfFTkRe3RXEY\n" ++
    "JYrYJTfcjqY/VQnNmoOCDcRkZ9hcf65+00ddGy2HVAYgbQIK0kSeW5h99duxfB1Q\n" ++
    "//n3enzzAkEA5YBaVbXfXtwYcm1Ay6yCrgF5M5dvWdbYqPxe7WSI+xA+x0Vo6VzT\n" ++
    "i4+LEBgXQHOj5sgD+ZBHDggm+yI4FxFbKQJBANzxXNITzVp7xtcpzUDjWYMRfXlp\n" ++
    "yTepRPlAfFauRU6j2ClpG/MQ5bgaGujbMgIi8G9q9YYMQCt7r85qszOo/j8CQBt7\n" ++
    "i1XIOb96S9MoEiJRvjRoKMNs1wDDIZ7a2eNDrsOh5mKmhTGs1AhaYCTFPcOSFYaF\n" ++
    "XTR9eoTLpR9dsanRgkECQBZ5QXRRn5m3ri33vEuQMVB4+zN4/WTsoTajjIsAquYS\n" ++
    "zNYkCg0jFcrx72bue1vi6XjuFCEB2dkA3BccoQjF+PQ=\n" ++
    "-----END RSA PRIVATE KEY-----";

/// 带请求头的 mock transport：记录方法 / body / 关心的请求头。
///
/// 头名与头值都拷进固定缓冲，因此调用返回后仍可读（`HeaderTransport` 只保证
/// 调用期间有效）。
const HeaderCapture = struct {
    response: []const u8,
    method: std.http.Method = .GET,
    payload_buf: [2048]u8 = undefined,
    payload_len: usize = 0,
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
        _ = content_type;
        const self: *HeaderCapture = @ptrCast(@alignCast(ctx));
        self.method = method;
        const plen = @min(payload.len, self.payload_buf.len);
        @memcpy(self.payload_buf[0..plen], payload[0..plen]);
        self.payload_len = plen;
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

test "RefundV3.refund 把 signer 生成的 Authorization 交给请求头入口（headers 路径）" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture{ .response = "{\"refund_id\":\"50000000382019052709732678859\"}" };

    var r = RefundV3.init(.{
        .app_id = "wx-v3",
        .mch_id = "1900000109",
        .serial_no = "1DDE557876238",
        .private_key_pem = test_private_key_pkcs1,
    });
    r.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));

    const parsed = try r.refund(allocator, .{
        .out_trade_no = "O1",
        .out_refund_no = "R1",
        .amount = .{ .refund = 100, .total = 100 },
    });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    // 签名必须仍由 pay/v3/signer.zig 生成（本模块不拼签名字符串）。
    try std.testing.expect(cap.headerValue("Authorization") != null);
    const auth = cap.headerValue("Authorization").?;
    try std.testing.expect(std.mem.startsWith(u8, auth, "WECHATPAY2-SHA256-RSA2048 "));
    try std.testing.expect(std.mem.indexOf(u8, auth, "mchid=\"1900000109\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth, "serial_no=\"1DDE557876238\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth, "signature=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth, "nonce_str=\"") != null);
    try std.testing.expectEqualStrings("application/json", cap.headerValue("Accept").?);

    // 签名前的 canonical URL 是路径 + query（不含 host），body 签名串与请求体一致。
    try std.testing.expectEqualStrings("{\"out_trade_no\":\"O1\",\"out_refund_no\":\"R1\",\"amount\":{\"refund\":100,\"total\":100,\"currency\":\"CNY\"}}", cap.payload_buf[0..cap.payload_len]);
}

test "RefundV3.queryRefund（GET）同样带 Authorization 与 Accept" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture{ .response = "{\"out_refund_no\":\"R123\"}" };

    var r = RefundV3.init(.{
        .app_id = "wx-v3",
        .mch_id = "1900000109",
        .serial_no = "1DDE557876238",
        .private_key_pem = test_private_key_pkcs1,
    });
    r.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));

    const parsed = try r.queryRefund(allocator, "R123");
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, cap.method);
    try std.testing.expect(cap.headerValue("Authorization") != null);
    try std.testing.expectEqualStrings("application/json", cap.headerValue("Accept").?);
}

test "RefundV3.setTransport(null, null) 清掉带请求头的 transport，回到真实路径" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture{ .response = "{}" };
    var r = RefundV3.init(.{ .app_id = "wx-v3", .mch_id = "1900000109" });

    r.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));
    try std.testing.expect(r.header_transport != null);
    r.setTransport(null, null);
    try std.testing.expect(!r.hasTransport());

    // 真实路径（无 transport）必须先过 signer：没配私钥即 MissingPrivateKey，
    // 不会发出任何网络请求。
    try std.testing.expectError(error.MissingPrivateKey, r.queryRefund(allocator, "R1"));
}

test "RefundV3 注入 transport 但缺 transport_ctx 返回 ConfigMissing" {
    var r = RefundV3.init(.{ .app_id = "wx-v3", .mch_id = "1900000109" });
    r.header_transport = HeaderCapture.dispatch; // 故意不设 ctx
    try std.testing.expectError(
        util_error.WechatError.ConfigMissing,
        r.queryRefund(std.testing.allocator, "R1"),
    );
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
