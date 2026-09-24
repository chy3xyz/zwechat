// SPDX-License-Identifier: Apache-2.0
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
const util_time = @import("../../util/time.zig");
const default_io = @import("../../util/default_io.zig");
const WechatError = @import("../../util/error.zig").WechatError;

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
///
/// 各字段切片指向内部持有的 XML 响应缓冲区，读取完毕后调用方必须调用
/// `deinit` 释放底层内存。
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

    /// 持有底层 XML 响应缓冲区的所有权（字段切片均指向它）。
    _raw: []const u8 = &.{},
    _allocator: ?std.mem.Allocator = null,

    /// 释放底层响应缓冲区。
    pub fn deinit(self: *PreOrder) void {
        if (self._allocator) |a| {
            if (self._raw.len > 0) a.free(@constCast(self._raw));
        }
        self.* = .{};
    }
};

/// JS SDK 用的拉起支付配置。
pub const BridgeConfig = struct {
    timestamp: []const u8,
    nonce_str: []const u8,
    package: []const u8,
    sign_type: []const u8,
    pay_sign: []const u8,
};

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

    /// 持有底层 XML 响应缓冲区的所有权（字段切片均指向它）。
    _raw: []const u8 = &.{},
    _allocator: ?std.mem.Allocator = null,

    /// 释放底层响应缓冲区。
    pub fn deinit(self: *QueryOrderResult) void {
        if (self._allocator) |a| {
            if (self._raw.len > 0) a.free(@constCast(self._raw));
        }
        self.* = .{};
    }
};

/// 关闭订单结果。
pub const CloseOrderResult = struct {
    return_code: []const u8 = "",
    return_msg: []const u8 = "",
    result_code: []const u8 = "",
    err_code: []const u8 = "",
    err_code_des: []const u8 = "",

    /// 持有底层 XML 响应缓冲区的所有权（字段切片均指向它）。
    _raw: []const u8 = &.{},
    _allocator: ?std.mem.Allocator = null,

    /// 释放底层响应缓冲区。
    pub fn deinit(self: *CloseOrderResult) void {
        if (self._allocator) |a| {
            if (self._raw.len > 0) a.free(@constCast(self._raw));
        }
        self.* = .{};
    }
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

pub const Order = struct {
    cfg: Config,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    /// 下单 / 查询 / 关闭 / 拉起支付所需的 `nonce_str` 与 `timestamp` 由该 `Io` 驱动。
    /// 默认 `default_io.io()`（与历史行为一致），宿主可用 `.io = ...` 注入。
    io: std.Io = default_io.io(),

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 统一下单（POST XML）。
    pub fn prePayOrder(self: *Self, allocator: std.mem.Allocator, p: Params) !PreOrder {
        const nonce_str = try util_util.randomStrWithIo(allocator, self.io, 32);
        defer allocator.free(nonce_str);

        // 构造签名：参与签名的参数必须与 XML 请求体完全一致
        //（含 detail/attach/goods_tag/time_expire，空值由 orderParam 跳过），
        // 否则微信会返回「签名错误」。算法由 p.sign_type 决定（MD5 / HMAC-SHA256）。
        const param_array = [_]util_param.Param{
            .{ .key = "appid", .value = self.cfg.app_id },
            .{ .key = "attach", .value = p.attach },
            .{ .key = "body", .value = p.body },
            .{ .key = "detail", .value = p.detail },
            .{ .key = "goods_tag", .value = p.goods_tag },
            .{ .key = "mch_id", .value = self.cfg.mch_id },
            .{ .key = "nonce_str", .value = nonce_str },
            .{ .key = "notify_url", .value = p.notify_url },
            .{ .key = "openid", .value = p.open_id },
            .{ .key = "out_trade_no", .value = p.out_trade_no },
            .{ .key = "sign_type", .value = p.sign_type },
            .{ .key = "spbill_create_ip", .value = p.create_ip },
            .{ .key = "time_expire", .value = p.time_expire },
            .{ .key = "total_fee", .value = p.total_fee },
            .{ .key = "trade_type", .value = p.trade_type },
        };

        const sign = try signParams(allocator, &param_array, self.cfg.key, p.sign_type);
        defer allocator.free(sign);

        // 构造 XML 请求体
        const xml_body = try buildUnifiedOrderXml(allocator, self.cfg, p, nonce_str, sign);
        defer allocator.free(xml_body);

        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        if (self.transport) |t| client.setTransport(t, self.transport_ctx);
        const body = try client.postXML("https://api.mch.weixin.qq.com/pay/unifiedorder", xml_body);

        var doc = try util_xml.parse(allocator, body);
        defer doc.deinit();

        // body 的所有权随返回值转移给调用方（由 PreOrder.deinit 释放）。
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
            ._raw = body,
            ._allocator = allocator,
        };
    }

    /// 查询订单（POST XML）。
    pub fn queryOrder(self: *Self, allocator: std.mem.Allocator, out_trade_no: []const u8) !QueryOrderResult {
        const nonce_str = try util_util.randomStrWithIo(allocator, self.io, 32);
        defer allocator.free(nonce_str);

        const params = [_]util_param.Param{
            .{ .key = "appid", .value = self.cfg.app_id },
            .{ .key = "mch_id", .value = self.cfg.mch_id },
            .{ .key = "out_trade_no", .value = out_trade_no },
            .{ .key = "nonce_str", .value = nonce_str },
        };
        const sign = try signParams(allocator, &params, self.cfg.key, util_crypto.SignTypeMD5);
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
        if (self.transport) |t| client.setTransport(t, self.transport_ctx);
        const body = try client.postXML("https://api.mch.weixin.qq.com/pay/orderquery", xml_body);

        var doc = try util_xml.parse(allocator, body);
        defer doc.deinit();

        // body 的所有权随返回值转移给调用方（由 QueryOrderResult.deinit 释放）。
        return .{
            .return_code = doc.get("return_code") orelse "",
            .return_msg = doc.get("return_msg") orelse "",
            .result_code = doc.get("result_code") orelse "",
            .err_code = doc.get("err_code") orelse "",
            .err_code_des = doc.get("err_code_des") orelse "",
            .trade_state = doc.get("trade_state") orelse "",
            .out_trade_no = doc.get("out_trade_no") orelse "",
            .transaction_id = doc.get("transaction_id") orelse "",
            ._raw = body,
            ._allocator = allocator,
        };
    }

    /// 关闭订单（POST XML）。
    pub fn closeOrder(self: *Self, allocator: std.mem.Allocator, out_trade_no: []const u8) !CloseOrderResult {
        const nonce_str = try util_util.randomStrWithIo(allocator, self.io, 32);
        defer allocator.free(nonce_str);

        const params = [_]util_param.Param{
            .{ .key = "appid", .value = self.cfg.app_id },
            .{ .key = "mch_id", .value = self.cfg.mch_id },
            .{ .key = "out_trade_no", .value = out_trade_no },
            .{ .key = "nonce_str", .value = nonce_str },
        };
        const sign = try signParams(allocator, &params, self.cfg.key, util_crypto.SignTypeMD5);
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
        if (self.transport) |t| client.setTransport(t, self.transport_ctx);
        const body = try client.postXML("https://api.mch.weixin.qq.com/pay/closeorder", xml_body);

        var doc = try util_xml.parse(allocator, body);
        defer doc.deinit();

        // body 的所有权随返回值转移给调用方（由 CloseOrderResult.deinit 释放）。
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

    pub fn prePayID(self: *Self, allocator: std.mem.Allocator, pre_order: PreOrder) (error{PrepayIdEmpty} || std.mem.Allocator.Error)![]u8 {
        _ = self;
        if (pre_order.prepay_id.len == 0) return error.PrepayIdEmpty;
        return allocator.dupe(u8, pre_order.prepay_id);
    }

    /// 构造 APP 拉起支付参数。
    pub fn bridgeAppConfig(self: *Self, allocator: std.mem.Allocator, pre_order: PreOrder) !AppConfig {
        const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{util_time.getCurrTSWithIo(self.io)});
        defer allocator.free(timestamp);

        const nonce_str = try util_util.randomStrWithIo(allocator, self.io, 32);
        defer allocator.free(nonce_str);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.print(
            allocator,
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

    /// 构造 JS SDK 拉起支付参数。
    ///
    /// 签名算法由 `p.sign_type` 决定（与上游 Go 版一致，修复前恒为 MD5）。
    pub fn bridgeConfig(self: *Self, allocator: std.mem.Allocator, p: Params, pre_order: PreOrder) !BridgeConfig {
        const timestamp = try std.fmt.allocPrint(allocator, "{d}", .{util_time.getCurrTSWithIo(self.io)});
        defer allocator.free(timestamp);

        const nonce_str = try util_util.randomStrWithIo(allocator, self.io, 32);
        defer allocator.free(nonce_str);

        const sign_md5 = try bridgeJsPaySign(
            allocator,
            self.cfg.app_id,
            nonce_str,
            pre_order.prepay_id,
            timestamp,
            p.sign_type,
            self.cfg.key,
        );
        defer allocator.free(sign_md5);

        // package 字段值是 "prepay_id=xxx"
        const package_val = try std.fmt.allocPrint(allocator, "prepay_id={s}", .{pre_order.prepay_id});
        defer allocator.free(package_val);

        return .{
            .timestamp = try allocator.dupe(u8, timestamp),
            .nonce_str = try allocator.dupe(u8, nonce_str),
            .package = try allocator.dupe(u8, package_val),
            .sign_type = p.sign_type,
            .pay_sign = try allocator.dupe(u8, sign_md5),
        };
    }
};

/// 计算 JS SDK 拉起支付的 paySign（纯函数，便于离线回归测试）。
///
/// 签名串：`appId=...&nonceStr=...&package=prepay_id=...&signType=...&timeStamp=...&key=...`，
/// 算法由 `sign_type` 决定（MD5 / HMAC-SHA256；HMAC 的 key 为商户 key，与上游 Go 一致）。
/// 返回的切片由调用方负责 `free`。
pub fn bridgeJsPaySign(
    allocator: std.mem.Allocator,
    app_id: []const u8,
    nonce_str: []const u8,
    prepay_id: []const u8,
    timestamp: []const u8,
    sign_type: []const u8,
    key: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "appId={s}&nonceStr={s}&package=prepay_id={s}&signType={s}&timeStamp={s}&key={s}", .{
        app_id,
        nonce_str,
        prepay_id,
        sign_type,
        timestamp,
        key,
    });
    return util_crypto.calculateSign(allocator, buf.items, sign_type, key);
}

// ──────────────────────────────────────────────────────────────────────────────
// 内部辅助
// ──────────────────────────────────────────────────────────────────────────────

/// 按 `sign_type` 计算参数签名（MD5 / HMAC-SHA256，与上游 Go `util.ParamSign` 对齐）。
///
/// 非法 `sign_type` 返回 `WechatError.InvalidArgument`。返回的大写 hex 切片由调用方 `free`。
fn signParams(
    allocator: std.mem.Allocator,
    params: []const util_param.Param,
    key: []const u8,
    sign_type: []const u8,
) ![]u8 {
    if (!std.mem.eql(u8, sign_type, util_crypto.SignTypeMD5) and
        !std.mem.eql(u8, sign_type, util_crypto.SignTypeHMACSHA256))
        return WechatError.InvalidArgument;
    const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{key});
    defer allocator.free(biz);
    const ordered = try util_param.orderParam(allocator, params, biz);
    defer allocator.free(ordered);
    return util_crypto.calculateSign(allocator, ordered, sign_type, key);
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

test "Order.prePayID 返回 prepay_id" {
    const allocator = std.testing.allocator;
    var o = Order.init(.{ .app_id = "wx", .mch_id = "m", .key = "k" });
    const id = try o.prePayID(allocator, .{ .prepay_id = "wx_prepay_123" });
    defer allocator.free(id);
    try std.testing.expectEqualStrings("wx_prepay_123", id);
}

test "Order.prePayID 空值返回错误" {
    var o = Order.init(.{});
    const result = o.prePayID(std.testing.allocator, .{});
    try std.testing.expectError(error.PrepayIdEmpty, result);
}

test "prePayOrder 返回值字段指向内部缓冲区（UAF 回归）" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.mch.weixin.qq.com/pay/unifiedorder", .{
        .body =
        \\<xml>
        \\  <return_code><![CDATA[SUCCESS]]></return_code>
        \\  <return_msg><![CDATA[OK]]></return_msg>
        \\  <result_code><![CDATA[SUCCESS]]></result_code>
        \\  <appid><![CDATA[wx-app]]></appid>
        \\  <mch_id><![CDATA[mch]]></mch_id>
        \\  <prepay_id><![CDATA[wx_prepay_123]]></prepay_id>
        \\  <trade_type><![CDATA[JSAPI]]></trade_type>
        \\</xml>
        ,
    });

    var o = Order.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "key" });
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    var result = try o.prePayOrder(allocator, .{
        .total_fee = "100",
        .create_ip = "127.0.0.1",
        .body = "test",
        .out_trade_no = "t-1",
        .open_id = "ox",
        .trade_type = "JSAPI",
        .notify_url = "https://example.com/cb",
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("SUCCESS", result.return_code);
    try std.testing.expectEqualStrings("OK", result.return_msg);
    try std.testing.expectEqualStrings("SUCCESS", result.result_code);
    try std.testing.expectEqualStrings("wx_prepay_123", result.prepay_id);
}

// 捕获最近一次请求 payload 的 transport，用于「签名 vs 实际发送 XML」一致性断言。
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
        return allocator.dupe(u8, "<xml><return_code>SUCCESS</return_code><result_code>SUCCESS</result_code><prepay_id>p1</prepay_id></xml>") catch return error.OutOfMemory;
    }
};

/// 从实际发送的 XML 重新计算 MD5 签名，验证与 `<sign>` 字段一致
/// （签名参数集合必须与实际发送字段完全一致）。
fn expectXmlSignConsistent(allocator: std.mem.Allocator, key: []const u8, xml_body: []const u8) !void {
    var doc = try util_xml.parse(allocator, xml_body);
    defer doc.deinit();

    var params: std.ArrayList(util_param.Param) = .empty;
    defer params.deinit(allocator);
    for (doc.elements) |el| {
        if (std.mem.eql(u8, el.key, "sign")) continue;
        if (el.value.len == 0) continue;
        try params.append(allocator, .{ .key = el.key, .value = el.value });
    }
    const biz = try std.fmt.allocPrint(allocator, "&key={s}", .{key});
    defer allocator.free(biz);
    const ordered = try util_param.orderParam(allocator, params.items, biz);
    defer allocator.free(ordered);
    const expected = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeMD5, "");
    defer allocator.free(expected);

    const given = doc.get("sign") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, expected, given);
}

test "prePayOrder 签名与实际发送 XML 一致（含可选字段，签名错误回归）" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{ .allocator = allocator };
    defer cap.deinit();

    var o = Order.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "test_key" });
    o.setTransport(CaptureTransport.dispatch, &cap);

    var result = try o.prePayOrder(allocator, .{
        .total_fee = "100",
        .create_ip = "127.0.0.1",
        .body = "test",
        .out_trade_no = "t-1",
        .open_id = "ox",
        .trade_type = "JSAPI",
        .notify_url = "https://example.com/cb",
        .detail = "{\"goods_detail\":[]}",
        .attach = "metadata",
        .goods_tag = "TAG",
        .time_expire = "20260919120000",
    });
    defer result.deinit();

    try std.testing.expect(cap.payload != null);
    try expectXmlSignConsistent(allocator, "test_key", cap.payload.?);
}

test "prePayOrder 非法 sign_type 返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{ .allocator = allocator };
    defer cap.deinit();

    var o = Order.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "test_key" });
    o.setTransport(CaptureTransport.dispatch, &cap);

    const r = o.prePayOrder(allocator, .{
        .total_fee = "100",
        .create_ip = "127.0.0.1",
        .body = "test",
        .out_trade_no = "t-1",
        .open_id = "ox",
        .trade_type = "JSAPI",
        .notify_url = "https://example.com/cb",
        .sign_type = "SHA1",
    });
    try std.testing.expectError(WechatError.InvalidArgument, r);
}

test "prePayOrder HMAC-SHA256 sign_type 签名与 XML 一致" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{ .allocator = allocator };
    defer cap.deinit();

    var o = Order.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "test_key" });
    o.setTransport(CaptureTransport.dispatch, &cap);

    var result = try o.prePayOrder(allocator, .{
        .total_fee = "100",
        .create_ip = "127.0.0.1",
        .body = "test",
        .out_trade_no = "t-1",
        .open_id = "ox",
        .trade_type = "JSAPI",
        .notify_url = "https://example.com/cb",
        .sign_type = "HMAC-SHA256",
    });
    defer result.deinit();

    // 从发送的 XML 重算 HMAC-SHA256 签名（orderParam + "&key=" + key），与 <sign> 比对。
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
    const expected = try util_crypto.calculateSign(allocator, ordered, util_crypto.SignTypeHMACSHA256, "test_key");
    defer allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, doc.get("sign").?);
}

test "bridgeJsPaySign 固定向量（HMAC-SHA256 / MD5）" {
    const allocator = std.testing.allocator;
    // 向量由外部独立计算（Python hmac/hashlib）：
    //   串 = "appId=wx123&nonceStr=nonce123&package=prepay_id=prep_456&signType=HMAC-SHA256&timeStamp=1700000000&key=secret_key"
    const h = try bridgeJsPaySign(allocator, "wx123", "nonce123", "prep_456", "1700000000", "HMAC-SHA256", "secret_key");
    defer allocator.free(h);
    try std.testing.expectEqualStrings("D013C2C7C7B96BDF9096D459F2527DFCCA073427B72713169F6A1F58B885D542", h);

    const m = try bridgeJsPaySign(allocator, "wx123", "nonce123", "prep_456", "1700000000", "MD5", "secret_key");
    defer allocator.free(m);
    try std.testing.expectEqualStrings("27798197AF1D9AF19B7288EF35525735", m);
}

test "bridgeConfig 透传 sign_type（修复前恒为 MD5）" {
    const allocator = std.testing.allocator;
    var o = Order.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "key" });
    var pre: PreOrder = .{ .prepay_id = "p1" };
    defer pre.deinit();
    const cfg = try o.bridgeConfig(allocator, .{
        .total_fee = "100",
        .create_ip = "127.0.0.1",
        .body = "test",
        .out_trade_no = "t-1",
        .open_id = "ox",
        .trade_type = "JSAPI",
        .notify_url = "https://example.com/cb",
        .sign_type = "HMAC-SHA256",
    }, pre);
    // BridgeConfig 各字段为独立分配的切片，逐一释放。
    defer {
        allocator.free(@constCast(cfg.timestamp));
        allocator.free(@constCast(cfg.nonce_str));
        allocator.free(@constCast(cfg.package));
        allocator.free(@constCast(cfg.pay_sign));
    }
    try std.testing.expectEqualStrings("HMAC-SHA256", cfg.sign_type);
}

// —— io 注入：nonce_str / timestamp 不再直接访问全局单例 ——

/// 冻结时钟的可观测 `Io`：`now` 恒定返回 `frozen_ns`。
const FixedIo = struct {
    vtable: std.Io.VTable = undefined,

    const frozen_ns: i96 = 1_700_000_000 * std.time.ns_per_s;

    fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        return .{ .nanoseconds = frozen_ns };
    }

    fn io(self: *FixedIo) std.Io {
        self.vtable = default_io.io().vtable.*;
        self.vtable.now = now;
        return .{ .userdata = null, .vtable = &self.vtable };
    }
};

test "bridgeConfig / bridgeAppConfig 的 timestamp 与 nonce_str 取自注入的 io" {
    const allocator = std.testing.allocator;
    var fixed = FixedIo{};
    const params = Params{
        .total_fee = "100",
        .create_ip = "127.0.0.1",
        .body = "test",
        .out_trade_no = "t-1",
        .open_id = "ox",
        .trade_type = "JSAPI",
        .notify_url = "https://example.com/cb",
    };

    var o = Order.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "key" });
    o.io = fixed.io();
    var pre: PreOrder = .{ .prepay_id = "p1" };
    defer pre.deinit();

    const cfg = try o.bridgeConfig(allocator, params, pre);
    defer {
        allocator.free(@constCast(cfg.timestamp));
        allocator.free(@constCast(cfg.nonce_str));
        allocator.free(@constCast(cfg.package));
        allocator.free(@constCast(cfg.pay_sign));
    }
    try std.testing.expectEqualStrings("1700000000", cfg.timestamp);

    // 冻结时钟播种的 PRNG：两次调用得到的 nonce_str 完全一致，
    // 证明 randomStr 走的是注入的 io 而不是全局单例（后者取真实时间，几乎不可能重复）。
    const cfg2 = try o.bridgeConfig(allocator, params, pre);
    defer {
        allocator.free(@constCast(cfg2.timestamp));
        allocator.free(@constCast(cfg2.nonce_str));
        allocator.free(@constCast(cfg2.package));
        allocator.free(@constCast(cfg2.pay_sign));
    }
    try std.testing.expectEqualStrings(cfg.nonce_str, cfg2.nonce_str);

    const app = try o.bridgeAppConfig(allocator, pre);
    defer {
        allocator.free(@constCast(app.appid));
        allocator.free(@constCast(app.partnerid));
        allocator.free(@constCast(app.prepayid));
        allocator.free(@constCast(app.nonce_str));
        allocator.free(@constCast(app.timestamp));
        allocator.free(@constCast(app.sign));
    }
    try std.testing.expectEqualStrings("1700000000", app.timestamp);
}

test "Order.io 默认值可用（未注入时 nonce_str 每次不同）" {
    const allocator = std.testing.allocator;
    var o = Order.init(.{ .app_id = "wx-app", .mch_id = "mch", .key = "key" });
    var pre: PreOrder = .{ .prepay_id = "p1" };
    defer pre.deinit();
    const params = Params{
        .total_fee = "100",
        .create_ip = "127.0.0.1",
        .body = "test",
        .out_trade_no = "t-1",
        .open_id = "ox",
        .trade_type = "JSAPI",
        .notify_url = "https://example.com/cb",
    };

    const a = try o.bridgeConfig(allocator, params, pre);
    defer {
        allocator.free(@constCast(a.timestamp));
        allocator.free(@constCast(a.nonce_str));
        allocator.free(@constCast(a.package));
        allocator.free(@constCast(a.pay_sign));
    }
    const b = try o.bridgeConfig(allocator, params, pre);
    defer {
        allocator.free(@constCast(b.timestamp));
        allocator.free(@constCast(b.nonce_str));
        allocator.free(@constCast(b.package));
        allocator.free(@constCast(b.pay_sign));
    }
    try std.testing.expect(!std.mem.eql(u8, a.nonce_str, b.nonce_str));
    try std.testing.expectEqual(@as(usize, 32), a.nonce_str.len);
}
