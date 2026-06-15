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
pub const RefundResult = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    result_code: []const u8 = "",
    err_code: []const u8 = "",
    err_code_des: []const u8 = "",
};

pub const Refund = struct {
    cfg: Config,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
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

        // 退款需要 TLS 双向认证（PKCS#12），但当前 HttpClient.postXMLWithTLS 返回 TLSNotImplemented。
        // 此处使用 postXML 走普通 HTTPS；正式上线需要换 TLS 版本。
        const body = try client.postXML("https://api.mch.weixin.qq.com/secapi/pay/refund", xml_body);
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