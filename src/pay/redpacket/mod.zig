//! pay/redpacket — 现金红包

const std = @import("std");
const Config = @import("../config.zig").Config;
const util_http = @import("../../util/http.zig");
const util_param = @import("../../util/param.zig");
const util_crypto = @import("../../util/crypto.zig");
const util_util = @import("../../util/util.zig");
const util_xml = @import("../../util/xml.zig");

pub const RedpacketParams = struct {
    mch_billno: []const u8,
    send_name: []const u8,
    act_name: []const u8,
    re_openid: []const u8,
    total_amount: i64, // 单位：分
    total_num: i64,
    wishing: []const u8,
    remark: []const u8 = "",
    client_ip: []const u8 = "",
};

pub const RedpacketResult = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    result_code: []const u8 = "",
    err_code: []const u8 = "",
    mch_billno: []const u8 = "",
};

pub const Redpacket = struct {
    cfg: Config,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    pub fn sendNormal(self: *Self, allocator: std.mem.Allocator, p: RedpacketParams) !RedpacketResult {
        const nonce_str = try util_util.randomStr(allocator, 32);
        defer allocator.free(nonce_str);

        const amount_str = try std.fmt.allocPrint(allocator, "{d}", .{p.total_amount});
        defer allocator.free(amount_str);
        const num_str = try std.fmt.allocPrint(allocator, "{d}", .{p.total_num});
        defer allocator.free(num_str);

        const params = [_]util_param.Param{
            .{ .key = "nonce_str", .value = nonce_str },
            .{ .key = "mch_billno", .value = p.mch_billno },
            .{ .key = "mch_id", .value = self.cfg.mch_id },
            .{ .key = "wxappid", .value = self.cfg.app_id },
            .{ .key = "send_name", .value = p.send_name },
            .{ .key = "re_openid", .value = p.re_openid },
            .{ .key = "total_amount", .value = amount_str },
            .{ .key = "total_num", .value = num_str },
            .{ .key = "wishing", .value = p.wishing },
            .{ .key = "act_name", .value = p.act_name },
            .{ .key = "remark", .value = p.remark },
            .{ .key = "client_ip", .value = p.client_ip },
        };

        const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{self.cfg.key});
        defer allocator.free(biz);
        const ordered = try util_param.orderParam(allocator, &params, biz);
        defer allocator.free(ordered);
        const sign = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeMD5, "");
        defer allocator.free(sign);

        var elements = std.ArrayList(util_xml.XmlElement).empty;
        defer elements.deinit(allocator);
        try elements.append(allocator, .{ .key = "nonce_str", .value = nonce_str });
        try elements.append(allocator, .{ .key = "sign", .value = sign });
        try elements.append(allocator, .{ .key = "mch_billno", .value = p.mch_billno });
        try elements.append(allocator, .{ .key = "mch_id", .value = self.cfg.mch_id });
        try elements.append(allocator, .{ .key = "wxappid", .value = self.cfg.app_id });
        try elements.append(allocator, .{ .key = "send_name", .value = p.send_name });
        try elements.append(allocator, .{ .key = "re_openid", .value = p.re_openid });
        try elements.append(allocator, .{ .key = "total_amount", .value = amount_str });
        try elements.append(allocator, .{ .key = "total_num", .value = num_str });
        try elements.append(allocator, .{ .key = "wishing", .value = p.wishing });
        try elements.append(allocator, .{ .key = "act_name", .value = p.act_name });
        try elements.append(allocator, .{ .key = "remark", .value = p.remark });
        if (p.client_ip.len > 0) try elements.append(allocator, .{ .key = "client_ip", .value = p.client_ip });

        const xml_body = try util_xml.serialize(allocator, "xml", elements.items);
        defer allocator.free(xml_body);

        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        const url = "https://api.mch.weixin.qq.com/mmpaymkttransfers/sendredpack";
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
            .mch_billno = doc.get("mch_billno") orelse "",
        };
    }
};

test "RedpacketParams 默认值" {
    const p = RedpacketParams{
        .mch_billno = "rn",
        .send_name = "x",
        .act_name = "a",
        .re_openid = "ox",
        .total_amount = 100,
        .total_num = 1,
        .wishing = "w",
    };
    try std.testing.expectEqualStrings("", p.remark);
}