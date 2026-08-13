// SPDX-License-Identifier: Apache-2.0
//! pay/refund — 退款

const std = @import("std");
const Config = @import("../config.zig").Config;
const util_http = @import("../../util/http.zig");
const util_param = @import("../../util/param.zig");
const util_crypto = @import("../../util/crypto.zig");
const util_xml = @import("../../util/xml.zig");
const util_util = @import("../../util/util.zig");

/// 退款参数。
pub const RefundParams = struct {
    out_trade_no: []const u8,
    out_refund_no: []const u8,
    total_fee: []const u8,
    refund_fee: []const u8,
    notify_url: []const u8,
    refund_desc: []const u8 = "",
};

/// 退款返回。
///
/// 各字段切片指向内部持有的 XML 响应缓冲区，读取完毕后调用方必须调用
/// `deinit` 释放底层内存（否则泄漏；不能提前释放，否则为 UAF）。
pub const RefundResult = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    result_code: []const u8 = "",
    err_code: []const u8 = "",
    err_code_des: []const u8 = "",

    /// 持有底层 XML 响应缓冲区的所有权（字段切片均指向它）。
    _raw: []const u8 = &.{},
    _allocator: ?std.mem.Allocator = null,

    /// 释放底层响应缓冲区。
    pub fn deinit(self: *RefundResult) void {
        if (self._allocator) |a| {
            if (self._raw.len > 0) a.free(@constCast(self._raw));
        }
        self.* = .{};
    }
};

pub const Refund = struct {
    cfg: Config,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    pub fn refund(self: *Self, allocator: std.mem.Allocator, p: RefundParams) !RefundResult {
        const nonce_str = try util_util.randomStr(allocator, 32);
        defer allocator.free(nonce_str);

        const params = [_]util_param.Param{
            .{ .key = "appid", .value = self.cfg.app_id },
            .{ .key = "mch_id", .value = self.cfg.mch_id },
            .{ .key = "nonce_str", .value = nonce_str },
            .{ .key = "out_trade_no", .value = p.out_trade_no },
            .{ .key = "out_refund_no", .value = p.out_refund_no },
            .{ .key = "total_fee", .value = p.total_fee },
            .{ .key = "refund_fee", .value = p.refund_fee },
            .{ .key = "notify_url", .value = p.notify_url },
            .{ .key = "refund_desc", .value = p.refund_desc },
        };

        const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{self.cfg.key});
        defer allocator.free(biz);
        const ordered = try util_param.orderParam(allocator, &params, biz);
        defer allocator.free(ordered);
        const sign = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeMD5, "");
        defer allocator.free(sign);

        var elements = std.ArrayList(util_xml.XmlElement).empty;
        defer elements.deinit(allocator);
        try elements.append(allocator, .{ .key = "appid", .value = self.cfg.app_id });
        try elements.append(allocator, .{ .key = "mch_id", .value = self.cfg.mch_id });
        try elements.append(allocator, .{ .key = "nonce_str", .value = nonce_str });
        try elements.append(allocator, .{ .key = "sign", .value = sign });
        try elements.append(allocator, .{ .key = "out_trade_no", .value = p.out_trade_no });
        try elements.append(allocator, .{ .key = "out_refund_no", .value = p.out_refund_no });
        try elements.append(allocator, .{ .key = "total_fee", .value = p.total_fee });
        try elements.append(allocator, .{ .key = "refund_fee", .value = p.refund_fee });
        try elements.append(allocator, .{ .key = "notify_url", .value = p.notify_url });
        if (p.refund_desc.len > 0) try elements.append(allocator, .{ .key = "refund_desc", .value = p.refund_desc });

        const xml_body = try util_xml.serialize(allocator, "xml", elements.items);
        defer allocator.free(xml_body);

        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        if (self.transport) |t| client.setTransport(t, self.transport_ctx);

        // 退款需要 TLS 双向认证（PKCS#12）。
        const url = "https://api.mch.weixin.qq.com/secapi/pay/refund";
        const body = if (self.cfg.root_ca.len > 0)
            try client.postXMLWithTLS(url, xml_body, self.cfg.root_ca, self.cfg.mch_id)
        else
            try client.postXML(url, xml_body);

        var doc = try util_xml.parse(allocator, body);
        defer doc.deinit();

        // body 的所有权随返回值转移给调用方（由 RefundResult.deinit 释放），
        // 避免字段切片在 body 被释放后悬垂（UAF）。
        return .{
            .return_code = doc.get("return_code") orelse "",
            .return_msg = doc.get("return_msg") orelse "",
            .result_code = doc.get("result_code") orelse "",
            .err_code = doc.get("err_code") orelse "",
            .err_code_des = doc.get("err_code_des") orelse "",
            ._raw = body,
            ._allocator = allocator,
        };
    }
};

test "RefundParams 默认值" {
    const p = RefundParams{
        .out_trade_no = "1",
        .out_refund_no = "2",
        .total_fee = "100",
        .refund_fee = "100",
        .notify_url = "https://example.com/cb",
    };
    try std.testing.expectEqualStrings("", p.refund_desc);
}

test "refund 返回值字段指向内部缓冲区（UAF 回归）" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.mch.weixin.qq.com/secapi/pay/refund", .{
        .body =
        \\<xml>
        \\  <return_code><![CDATA[SUCCESS]]></return_code>
        \\  <return_msg><![CDATA[OK]]></return_msg>
        \\  <result_code><![CDATA[SUCCESS]]></result_code>
        \\  <err_code><![CDATA[0]]></err_code>
        \\  <err_code_des><![CDATA[none]]></err_code_des>
        \\</xml>
        ,
    });

    var r = Refund.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "key" });
    r.setTransport(util_http.MockTransport.dispatch, &mt);

    var result = try r.refund(allocator, .{
        .out_trade_no = "t-1",
        .out_refund_no = "r-1",
        .total_fee = "100",
        .refund_fee = "100",
        .notify_url = "https://example.com/cb",
    });
    defer result.deinit();

    // 若 body 在返回前被释放，以下字段将读到悬垂内存导致断言失败。
    try std.testing.expectEqualStrings("SUCCESS", result.return_code);
    try std.testing.expectEqualStrings("OK", result.return_msg);
    try std.testing.expectEqualStrings("SUCCESS", result.result_code);
    try std.testing.expectEqualStrings("0", result.err_code);
    try std.testing.expectEqualStrings("none", result.err_code_des);
}
