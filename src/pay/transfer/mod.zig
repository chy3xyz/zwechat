// SPDX-License-Identifier: Apache-2.0
//! pay/transfer — 企业付款到零钱（V2 接口）

const std = @import("std");
const Config = @import("../config.zig").Config;
const util_http = @import("../../util/http.zig");
const util_param = @import("../../util/param.zig");
const util_crypto = @import("../../util/crypto.zig");
const util_util = @import("../../util/util.zig");
const util_xml = @import("../../util/xml.zig");

pub const TransferWalletParams = struct {
    open_id: []const u8,
    amount: i64, // 单位：分
    desc: []const u8,
    partner_trade_no: []const u8,
    check_name: []const u8 = "NO_CHECK", // NO_CHECK / FORCE_CHECK
    re_user_name: []const u8 = "", // 收款用户真实姓名（FORCE_CHECK 时必填）
};

pub const TransferWalletResult = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    result_code: []const u8 = "",
    err_code: []const u8 = "",
    payment_no: []const u8 = "",
    payment_time: []const u8 = "",

    /// 持有底层 XML 响应缓冲区的所有权（字段切片均指向它）。
    _raw: []const u8 = &.{},
    _allocator: ?std.mem.Allocator = null,

    /// 释放底层响应缓冲区。
    pub fn deinit(self: *TransferWalletResult) void {
        if (self._allocator) |a| {
            if (self._raw.len > 0) a.free(@constCast(self._raw));
        }
        self.* = .{};
    }
};

pub const Transfer = struct {
    cfg: Config,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    /// 请求 `nonce_str` 由该 `Io` 驱动。默认 `global_single_threaded`
    /// （与历史行为一致），宿主可用 `.io = ...` 注入。
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    pub fn toWallet(self: *Self, allocator: std.mem.Allocator, p: TransferWalletParams) !TransferWalletResult {
        const nonce_str = try util_util.randomStrWithIo(allocator, self.io, 32);
        defer allocator.free(nonce_str);

        const amount_str = try std.fmt.allocPrint(allocator, "{d}", .{p.amount});
        defer allocator.free(amount_str);

        const params = [_]util_param.Param{
            .{ .key = "mch_appid", .value = self.cfg.app_id },
            .{ .key = "mchid", .value = self.cfg.mch_id },
            .{ .key = "nonce_str", .value = nonce_str },
            .{ .key = "partner_trade_no", .value = p.partner_trade_no },
            .{ .key = "openid", .value = p.open_id },
            .{ .key = "amount", .value = amount_str },
            .{ .key = "desc", .value = p.desc },
            .{ .key = "check_name", .value = p.check_name },
            // 与上游 Go 版一致：re_user_name 必须在 FORCE_CHECK 时参与签名，
            // 否则签名与实际发送字段不一致，微信返回「签名错误」。
            .{ .key = "re_user_name", .value = p.re_user_name },
        };

        const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{self.cfg.key});
        defer allocator.free(biz);
        const ordered = try util_param.orderParam(allocator, &params, biz);
        defer allocator.free(ordered);
        const sign = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeMD5, "");
        defer allocator.free(sign);

        var elements = std.ArrayList(util_xml.XmlElement).empty;
        defer elements.deinit(allocator);
        try elements.append(allocator, .{ .key = "mch_appid", .value = self.cfg.app_id });
        try elements.append(allocator, .{ .key = "mchid", .value = self.cfg.mch_id });
        try elements.append(allocator, .{ .key = "nonce_str", .value = nonce_str });
        try elements.append(allocator, .{ .key = "sign", .value = sign });
        try elements.append(allocator, .{ .key = "partner_trade_no", .value = p.partner_trade_no });
        try elements.append(allocator, .{ .key = "openid", .value = p.open_id });
        try elements.append(allocator, .{ .key = "amount", .value = amount_str });
        try elements.append(allocator, .{ .key = "desc", .value = p.desc });
        try elements.append(allocator, .{ .key = "check_name", .value = p.check_name });
        if (p.re_user_name.len > 0) try elements.append(allocator, .{ .key = "re_user_name", .value = p.re_user_name });

        const xml_body = try util_xml.serialize(allocator, "xml", elements.items);
        defer allocator.free(xml_body);

        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        if (self.transport) |t| client.setTransport(t, self.transport_ctx);
        // 企业付款（转账）需要 TLS 双向认证（PKCS#12）：走仓库内自建的 mTLS 通道，
        // 需要 `zig build -Dmtls=true` 构建（默认构建会返回 error.MtlsNotEnabled）；
        // 不便开启时可改用 v3 商家转账（pay/v3/transfer.zig，RSA 签名，无需客户端证书）。
        const url = "https://api.mch.weixin.qq.com/mmpaymkttransfers/promotion/transfers";
        const body = if (self.cfg.root_ca.len > 0)
            try client.postXMLWithTLS(url, xml_body, self.cfg.root_ca, self.cfg.mch_id)
        else
            try client.postXML(url, xml_body);

        var doc = try util_xml.parse(allocator, body);
        defer doc.deinit();

        // body 的所有权随返回值转移给调用方（由 TransferWalletResult.deinit 释放）。
        return .{
            .return_code = doc.get("return_code") orelse "",
            .return_msg = doc.get("return_msg") orelse "",
            .result_code = doc.get("result_code") orelse "",
            .err_code = doc.get("err_code") orelse "",
            .payment_no = doc.get("payment_no") orelse "",
            .payment_time = doc.get("payment_time") orelse "",
            ._raw = body,
            ._allocator = allocator,
        };
    }
};

test "TransferWalletParams 默认值" {
    const p = TransferWalletParams{
        .open_id = "ox",
        .amount = 100,
        .desc = "test",
        .partner_trade_no = "tn",
    };
    try std.testing.expectEqualStrings("NO_CHECK", p.check_name);
}

test "toWallet 返回值字段指向内部缓冲区（UAF 回归）" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.mch.weixin.qq.com/mmpaymkttransfers/promotion/transfers", .{
        .body =
        \\<xml>
        \\  <return_code><![CDATA[SUCCESS]]></return_code>
        \\  <return_msg><![CDATA[OK]]></return_msg>
        \\  <result_code><![CDATA[SUCCESS]]></result_code>
        \\  <err_code><![CDATA[0]]></err_code>
        \\  <payment_no><![CDATA[pay-123]]></payment_no>
        \\  <payment_time><![CDATA[2026-01-01 00:00:00]]></payment_time>
        \\</xml>
        ,
    });

    var t = Transfer.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "key" });
    t.setTransport(util_http.MockTransport.dispatch, &mt);

    var result = try t.toWallet(allocator, .{
        .open_id = "ox",
        .amount = 100,
        .desc = "test",
        .partner_trade_no = "tn-1",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("SUCCESS", result.return_code);
    try std.testing.expectEqualStrings("OK", result.return_msg);
    try std.testing.expectEqualStrings("SUCCESS", result.result_code);
    try std.testing.expectEqualStrings("pay-123", result.payment_no);
    try std.testing.expectEqualStrings("2026-01-01 00:00:00", result.payment_time);
}

// 捕获最近一次请求 payload 的 transport（与 pay/order 回归测试同款）。
const CaptureTransport = struct {
    payload: ?[]u8 = null,
    allocator: std.mem.Allocator,

    fn deinit(self: *CaptureTransport) void {
        if (self.payload) |p| self.allocator.free(p);
    }

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = content_type;
        const self: *CaptureTransport = @ptrCast(@alignCast(ctx));
        if (self.payload) |p| self.allocator.free(p);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, "<xml><return_code>SUCCESS</return_code><result_code>SUCCESS</result_code></xml>") catch return error.OutOfMemory;
    }
};

test "toWallet FORCE_CHECK 时 re_user_name 参与签名（签名错误回归）" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{ .allocator = allocator };
    defer cap.deinit();

    var t = Transfer.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "test_key" });
    t.setTransport(CaptureTransport.dispatch, &cap);

    var result = try t.toWallet(allocator, .{
        .open_id = "ox",
        .amount = 100,
        .desc = "报销",
        .partner_trade_no = "tn-1",
        .check_name = "FORCE_CHECK",
        .re_user_name = "张三",
    });
    defer result.deinit();

    try std.testing.expect(cap.payload != null);

    // 从实际发送的 XML 重算签名（含 re_user_name），必须与 <sign> 一致。
    var doc = try util_xml.parse(allocator, cap.payload.?);
    defer doc.deinit();
    var params: std.ArrayList(util_param.Param) = .empty;
    defer params.deinit(allocator);
    for (doc.elements) |el| {
        if (std.mem.eql(u8, el.key, "sign")) continue;
        if (el.value.len == 0) continue;
        try params.append(allocator, .{ .key = el.key, .value = el.value });
    }
    const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{"test_key"});
    defer allocator.free(biz);
    const ordered = try util_param.orderParam(allocator, params.items, biz);
    defer allocator.free(ordered);
    const expected = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeMD5, "");
    defer allocator.free(expected);
    const given = doc.get("sign") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, expected, given);
    // re_user_name 确实被发送。
    try std.testing.expectEqualStrings("张三", doc.get("re_user_name").?);
}

// —— io 注入：nonce_str 不再直接访问全局单例 ——

/// 冻结时钟的可观测 `Io`：`now` 恒定返回 `frozen_ns`。
const FixedIo = struct {
    vtable: std.Io.VTable = undefined,

    const frozen_ns: i96 = 1_700_000_000 * std.time.ns_per_s;

    fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        return .{ .nanoseconds = frozen_ns };
    }

    fn io(self: *FixedIo) std.Io {
        self.vtable = std.Io.Threaded.global_single_threaded.io().vtable.*;
        self.vtable.now = now;
        return .{ .userdata = null, .vtable = &self.vtable };
    }
};

/// 捕获请求 payload 的 transport，并从中取出实际发送的 `<nonce_str>`。
const NonceCapture = struct {
    payload: ?[]u8 = null,
    allocator: std.mem.Allocator,

    fn deinit(self: *NonceCapture) void {
        if (self.payload) |p| self.allocator.free(p);
    }

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = content_type;
        const self: *NonceCapture = @ptrCast(@alignCast(ctx));
        if (self.payload) |p| self.allocator.free(p);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, "<xml><return_code>SUCCESS</return_code><result_code>SUCCESS</result_code></xml>");
    }

    fn nonce(self: *const NonceCapture, allocator: std.mem.Allocator) ![]u8 {
        var doc = try util_xml.parse(allocator, self.payload.?);
        defer doc.deinit();
        return allocator.dupe(u8, doc.get("nonce_str") orelse "");
    }
};

test "toWallet 的 nonce_str 取自注入的 io（冻结时钟 → 可复现）" {
    const allocator = std.testing.allocator;
    var fixed = FixedIo{};
    var cap = NonceCapture{ .allocator = allocator };
    defer cap.deinit();

    var t = Transfer.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "test_key" });
    t.io = fixed.io();
    t.setTransport(NonceCapture.dispatch, &cap);

    const p = TransferWalletParams{
        .open_id = "ox",
        .amount = 100,
        .desc = "报销",
        .partner_trade_no = "tn-1",
    };

    var r1 = try t.toWallet(allocator, p);
    defer r1.deinit();
    const n1 = try cap.nonce(allocator);
    defer allocator.free(n1);

    var r2 = try t.toWallet(allocator, p);
    defer r2.deinit();
    const n2 = try cap.nonce(allocator);
    defer allocator.free(n2);

    try std.testing.expectEqual(@as(usize, 32), n1.len);
    // 冻结时钟播种的 PRNG 可复现；若仍走全局单例（真实时间）两次结果不会相同。
    try std.testing.expectEqualStrings(n1, n2);
}
