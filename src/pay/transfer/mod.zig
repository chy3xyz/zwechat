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
};

pub const Transfer = struct {
    cfg: Config,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    pub fn toWallet(self: *Self, allocator: std.mem.Allocator, p: TransferWalletParams) !TransferWalletResult {
        const nonce_str = try util_util.randomStr(allocator, 32);
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
        const url = "https://api.mch.weixin.qq.com/mmpaymkttransfers/promotion/transfers";
        const body = if (self.cfg.root_ca.len > 0)
            try client.postXMLWithTLS(url, xml_body, self.cfg.root_ca, self.cfg.mch_id)
        else
            try client.postXML(url, xml_body);
        defer allocator.free(body);

        var doc = try util_xml.parse(allocator, body);
        defer doc.deinit();

        return .{
            .return_code = doc.get("return_code") orelse "",
            .return_msg = doc.get("return_msg") orelse "",
            .result_code = doc.get("result_code") orelse "",
            .err_code = doc.get("err_code") orelse "",
            .payment_no = doc.get("payment_no") orelse "",
            .payment_time = doc.get("payment_time") orelse "",
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