//! pay/order — 微信支付下单 / 查询 / 关闭
//!
//! 对应 `_ref/wechat/pay/order/`：实现 V2 统一下单（`unifiedorder`）。
//! 签名方式：MD5（`util.crypto.calculateSign` + `util.param.orderParam`）。

const std = @import("std");
const Config = @import("../config.zig").Config;
const util_http = @import("../../util/http.zig");
const util_param = @import("../../util/param.zig");
const util_crypto = @import("../../util/crypto.zig");
const util_util = @import("../../util/util.zig");
const util_xml = @import("../../util/xml.zig");

/// 下单参数。
pub const Params = struct {
    total_fee: []const u8,
    create_ip: []const u8,
    body: []const u8,
    out_trade_no: []const u8,
    open_id: []const u8,
    trade_type: []const u8,
    notify_url: []const u8,
    detail: []const u8 = "",
    attach: []const u8 = "",
    goods_tag: []const u8 = "",
    time_expire: []const u8 = "",
    sign_type: []const u8 = "MD5",
};

/// `PreOrder` — 微信返回的 prepay 信息（XML）。
pub const PreOrder = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    appid: []const u8 = "",
    mch_id: []const u8 = "",
    nonce_str: []const u8 = "",
    sign: []const u8 = "",
    result_code: []const u8 = "",
    trade_type: []const u8 = "",
    prepay_id: []const u8 = "",
    code_url: []const u8 = "",
    mweb_url: []const u8 = "",
    err_code: []const u8 = "",
    err_code_des: []const u8 = "",
};

/// JS SDK 用的拉起支付配置。
pub const BridgeConfig = struct {
    timestamp: []const u8,
    nonce_str: []const u8,
    package: []const u8,
    sign_type: []const u8,
    pay_sign: []const u8,
};

pub const Order = struct {
    cfg: Config,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    /// 统一下单（POST XML）。
    pub fn prePayOrder(self: *Self, allocator: std.mem.Allocator, p: Params) !PreOrder {
        const nonce_str = try util_util.randomStr(allocator, 32);
        defer allocator.free(nonce_str);

        // 构造签名（MD5 over all params except `sign` itself）
        const param_array = [_]util_param.Param{
            .{ .key = "appid", .value = self.cfg.app_id },
            .{ .key = "mch_id", .value = self.cfg.mch_id },
            .{ .key = "nonce_str", .value = nonce_str },
            .{ .key = "body", .value = p.body },
            .{ .key = "out_trade_no", .value = p.out_trade_no },
            .{ .key = "total_fee", .value = p.total_fee },
            .{ .key = "spbill_create_ip", .value = p.create_ip },
            .{ .key = "notify_url", .value = p.notify_url },
            .{ .key = "trade_type", .value = p.trade_type },
            .{ .key = "openid", .value = p.open_id },
            .{ .key = "sign_type", .value = p.sign_type },
        };

        const sign = try signMd5(allocator, &param_array, self.cfg.key);
        defer allocator.free(sign);

        // 构造 XML 请求体
        const xml_body = try buildUnifiedOrderXml(allocator, self.cfg, p, nonce_str, sign);
        defer allocator.free(xml_body);

        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        const body = try client.postXML("https://api.mch.weixin.qq.com/pay/unifiedorder", xml_body);
        defer allocator.free(body);

        var doc = try util_xml.parse(allocator, body);
        defer doc.deinit();

        return .{
            .return_code = doc.get("return_code") orelse "",
            .return_msg = doc.get("return_msg") orelse "",
            .appid = doc.get("appid") orelse "",
            .mch_id = doc.get("mch_id") orelse "",
            .nonce_str = doc.get("nonce_str") orelse "",
            .sign = doc.get("sign") orelse "",
            .result_code = doc.get("result_code") orelse "",
            .trade_type = doc.get("trade_type") orelse "",
            .prepay_id = doc.get("prepay_id") orelse "",
            .code_url = doc.get("code_url") orelse "",
            .mweb_url = doc.get("mweb_url") orelse "",
            .err_code = doc.get("err_code") orelse "",
            .err_code_des = doc.get("err_code_des") orelse "",
        };
    }

    /// 构造 JS SDK 拉起支付参数。
    pub fn bridgeConfig(self: *Self, allocator: std.mem.Allocator, p: Params, pre_order: PreOrder) !BridgeConfig {
        _ = p;
        const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{std.time.timestamp()});
        defer allocator.free(timestamp);

        const nonce_str = try util_util.randomStr(allocator, 32);
        defer allocator.free(nonce_str);

        // 签名串：appId=...&nonceStr=...&package=prepay_id=...&signType=...&timeStamp=...&key=...
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.writer.print("appId={s}&nonceStr={s}&package=prepay_id={s}&signType=MD5&timeStamp={s}&key={s}", .{
            self.cfg.app_id,
            nonce_str,
            pre_order.prepay_id,
            timestamp,
            self.cfg.key,
        });
        const raw = buf.items;
        const sign_md5 = try util_crypto.calculateSign(allocator, raw, util_crypto.SignTypeMD5, "");
        defer allocator.free(sign_md5);

        // package 字段值是 "prepay_id=xxx"
        const package_val = try std.fmt.allocPrint(allocator, "prepay_id={s}", .{pre_order.prepay_id});
        defer allocator.free(package_val);

        return .{
            .timestamp = try allocator.dupe(u8, timestamp),
            .nonce_str = try allocator.dupe(u8, nonce_str),
            .package = try allocator.dupe(u8, package_val),
            .sign_type = "MD5",
            .pay_sign = try allocator.dupe(u8, sign_md5),
        };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 内部辅助
// ──────────────────────────────────────────────────────────────────────────────

fn signMd5(allocator: std.mem.Allocator, params: []const util_param.Param, key: []const u8) ![]u8 {
    const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{key});
    defer allocator.free(biz);
    const ordered = try util_param.orderParam(allocator, params, biz);
    defer allocator.free(ordered);
    return util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeMD5, "");
}

fn buildUnifiedOrderXml(allocator: std.mem.Allocator, cfg: Config, p: Params, nonce_str: []const u8, sign: []const u8) ![]u8 {
    var elements = std.ArrayList(util_xml.XmlElement).empty;
    defer elements.deinit(allocator);

    try elements.append(allocator, .{ .key = "appid", .value = cfg.app_id });
    try elements.append(allocator, .{ .key = "mch_id", .value = cfg.mch_id });
    try elements.append(allocator, .{ .key = "nonce_str", .value = nonce_str });
    try elements.append(allocator, .{ .key = "sign", .value = sign });
    try elements.append(allocator, .{ .key = "sign_type", .value = p.sign_type });
    try elements.append(allocator, .{ .key = "body", .value = p.body });
    if (p.detail.len > 0) try elements.append(allocator, .{ .key = "detail", .value = p.detail });
    if (p.attach.len > 0) try elements.append(allocator, .{ .key = "attach", .value = p.attach });
    try elements.append(allocator, .{ .key = "out_trade_no", .value = p.out_trade_no });
    try elements.append(allocator, .{ .key = "total_fee", .value = p.total_fee });
    try elements.append(allocator, .{ .key = "spbill_create_ip", .value = p.create_ip });
    if (p.time_expire.len > 0) try elements.append(allocator, .{ .key = "time_expire", .value = p.time_expire });
    if (p.goods_tag.len > 0) try elements.append(allocator, .{ .key = "goods_tag", .value = p.goods_tag });
    try elements.append(allocator, .{ .key = "notify_url", .value = p.notify_url });
    try elements.append(allocator, .{ .key = "trade_type", .value = p.trade_type });
    try elements.append(allocator, .{ .key = "openid", .value = p.open_id });

    return util_xml.serialize(allocator, "xml", elements.items);
}

test "Params 默认值" {
    const p = Params{
        .total_fee = "1",
        .create_ip = "127.0.0.1",
        .body = "test",
        .out_trade_no = "123",
        .open_id = "ox",
        .trade_type = "JSAPI",
        .notify_url = "https://example.com/cb",
    };
    try std.testing.expectEqualStrings("MD5", p.sign_type);
}

test "PreOrder 默认值" {
    const o = PreOrder{};
    try std.testing.expectEqualStrings("", o.prepay_id);
}