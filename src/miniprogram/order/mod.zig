// SPDX-License-Identifier: Apache-2.0
//! miniprogram/order — 订单发货信息管理
//!
//! 对应 `_ref/wechat/miniprogram/order/shipping.go`：发货信息录入、查询订单发货状态、
//! 查询订单列表、确认收货提醒。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 发货模式。
pub const DeliveryMode = enum(u8) {
    unified_delivery = 1, // 统一发货
    split_delivery = 2, // 分拆发货
};

/// 物流模式。
pub const LogisticsType = enum(u8) {
    express = 1, // 实体物流
    same_city = 2, // 同城配送
    virtual = 3, // 虚拟商品
    self_pickup = 4, // 用户自提
};

/// 订单单号类型。
pub const NumberType = enum(u8) {
    out_trade_no = 1, // 商户号和商户侧单号
    transaction_id = 2, // 微信支付单号
};

/// 订单状态。
pub const State = enum(u8) {
    wait_shipment = 1, // 待发货
    shipped = 2, // 已发货
    confirm = 3, // 确认收货
    complete = 4, // 交易完成
    refund = 5, // 已退款
};

pub const ShippingOrderKey = struct {
    order_number_type: NumberType = .out_trade_no,
    transaction_id: []const u8 = "",
    mchid: []const u8 = "",
    out_trade_no: []const u8 = "",
};

pub const ShippingPayer = struct {
    openid: []const u8 = "",
};

pub const ShippingContact = struct {
    consignor_contact: []const u8 = "",
    receiver_contact: []const u8 = "",
};

pub const ShippingInfo = struct {
    tracking_no: []const u8 = "",
    express_company: []const u8 = "",
    item_desc: []const u8 = "",
    contact: ShippingContact = .{},
};

pub const UploadShippingInfoRequest = struct {
    order_key: ShippingOrderKey = .{},
    logistics_type: LogisticsType = .express,
    delivery_mode: DeliveryMode = .unified_delivery,
    is_all_delivered: bool = false,
    shipping_list: []const ShippingInfo = &.{},
    upload_time: []const u8 = "",
    payer: ?ShippingPayer = null,
};

pub const GetShippingOrderRequest = struct {
    transaction_id: []const u8 = "",
    merchant_id: []const u8 = "",
    sub_merchant_id: []const u8 = "",
    merchant_trade_no: []const u8 = "",
};

pub const ShippingItem = struct {
    tracking_no: []const u8 = "",
    express_company: []const u8 = "",
    upload_time: i64 = 0,
};

pub const ShippingDetail = struct {
    delivery_mode: DeliveryMode = .unified_delivery,
    logistics_type: LogisticsType = .express,
    finish_shipping: bool = false,
    finish_shipping_count: i64 = 0,
    goods_desc: []const u8 = "",
    shipping_list: []const ShippingItem = &.{},
};

pub const ShippingOrder = struct {
    transaction_id: []const u8 = "",
    merchant_trade_no: []const u8 = "",
    merchant_id: []const u8 = "",
    sub_merchant_id: []const u8 = "",
    description: []const u8 = "",
    paid_amount: i64 = 0,
    openid: []const u8 = "",
    trade_create_time: i64 = 0,
    pay_time: i64 = 0,
    in_complaint: bool = false,
    order_state: State = .wait_shipment,
    shipping: ?ShippingDetail = null,
};

pub const ShippingOrderResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    order: ShippingOrder = .{},
};

pub const TimeRange = struct {
    begin_time: i64 = 0,
    end_time: i64 = 0,
};

pub const GetShippingOrderListRequest = struct {
    pay_time_range: TimeRange = .{},
    order_state: ?State = null,
    openid: []const u8 = "",
    last_index: []const u8 = "",
    page_size: i64 = 0,
};

pub const GetShippingOrderListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    order_list: []const ShippingOrder = &.{},
    last_index: []const u8 = "",
    has_more: bool = false,
};

pub const NotifyConfirmReceiveRequest = struct {
    transaction_id: []const u8 = "",
    merchant_id: []const u8 = "",
    sub_merchant_id: []const u8 = "",
    merchant_trade_no: []const u8 = "",
    received_time: i64 = 0,
};

/// 订单发货信息管理模块。
pub const Shipping = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 发货信息录入。
    pub fn uploadShippingInfo(self: *Self, req: UploadShippingInfoRequest) !void {
        const body = try jsonStringifyUpload(self.allocator, req);
        defer self.allocator.free(body);
        try self.postCommon("upload_shipping_info", body, "UploadShippingInfo");
    }

    /// 查询订单发货状态（返回 `Parsed(ShippingOrderResponse)`）。
    pub fn getShippingOrder(self: *Self, req: GetShippingOrderRequest) !std.json.Parsed(ShippingOrderResponse) {
        const body = try jsonStringifyGetOrder(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("get_order", body, ShippingOrderResponse);
    }

    /// 查询订单列表（返回 `Parsed(GetShippingOrderListResponse)`）。
    pub fn getShippingOrderList(self: *Self, req: GetShippingOrderListRequest) !std.json.Parsed(GetShippingOrderListResponse) {
        const body = try jsonStringifyGetOrderList(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("get_order_list", body, GetShippingOrderListResponse);
    }

    /// 确认收货提醒。
    pub fn notifyConfirmReceive(self: *Self, req: NotifyConfirmReceiveRequest) !void {
        const body = try jsonStringifyNotify(self.allocator, req);
        defer self.allocator.free(body);
        try self.postCommon("notify_confirm_receive", body, "NotifyConfirmReceive");
    }

    fn postCommon(self: *Self, path: []const u8, body: []const u8, api_name: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/sec/order/{s}?access_token={s}",
            .{ path, access_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, api_name)) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    fn postParsed(self: *Self, comptime T: type, path: []const u8, body: []const u8) !std.json.Parsed(T) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/sec/order/{s}?access_token={s}",
            .{ path, access_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(T, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

fn jsonStringifyUpload(allocator: std.mem.Allocator, req: UploadShippingInfoRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("order_key");
    try s.beginObject();
    try s.objectField("order_number_type");
    try s.write(@backingInt(req.order_key.order_number_type));
    try s.objectField("transaction_id");
    try s.write(req.order_key.transaction_id);
    try s.objectField("mchid");
    try s.write(req.order_key.mchid);
    try s.objectField("out_trade_no");
    try s.write(req.order_key.out_trade_no);
    try s.endObject();
    try s.objectField("logistics_type");
    try s.write(@backingInt(req.logistics_type));
    try s.objectField("delivery_mode");
    try s.write(@backingInt(req.delivery_mode));
    try s.objectField("is_all_delivered");
    try s.write(req.is_all_delivered);
    try s.objectField("shipping_list");
    try s.beginArray();
    for (req.shipping_list) |info| {
        try s.beginObject();
        try s.objectField("tracking_no");
        try s.write(info.tracking_no);
        try s.objectField("express_company");
        try s.write(info.express_company);
        try s.objectField("item_desc");
        try s.write(info.item_desc);
        try s.objectField("contact");
        try s.beginObject();
        try s.objectField("consignor_contact");
        try s.write(info.contact.consignor_contact);
        try s.objectField("receiver_contact");
        try s.write(info.contact.receiver_contact);
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    if (req.upload_time.len > 0) {
        try s.objectField("upload_time");
        try s.write(req.upload_time);
    }
    if (req.payer) |payer| {
        try s.objectField("payer");
        try s.beginObject();
        try s.objectField("openid");
        try s.write(payer.openid);
        try s.endObject();
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyGetOrder(allocator: std.mem.Allocator, req: GetShippingOrderRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("transaction_id");
    try s.write(req.transaction_id);
    try s.objectField("merchant_id");
    try s.write(req.merchant_id);
    try s.objectField("sub_merchant_id");
    try s.write(req.sub_merchant_id);
    try s.objectField("merchant_trade_no");
    try s.write(req.merchant_trade_no);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyGetOrderList(allocator: std.mem.Allocator, req: GetShippingOrderListRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("pay_time_range");
    try s.beginObject();
    try s.objectField("begin_time");
    try s.write(req.pay_time_range.begin_time);
    try s.objectField("end_time");
    try s.write(req.pay_time_range.end_time);
    try s.endObject();
    if (req.order_state) |st| {
        try s.objectField("order_state");
        try s.write(@backingInt(st));
    }
    if (req.openid.len > 0) {
        try s.objectField("openid");
        try s.write(req.openid);
    }
    if (req.last_index.len > 0) {
        try s.objectField("last_index");
        try s.write(req.last_index);
    }
    try s.objectField("page_size");
    try s.write(req.page_size);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyNotify(allocator: std.mem.Allocator, req: NotifyConfirmReceiveRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("transaction_id");
    try s.write(req.transaction_id);
    try s.objectField("merchant_id");
    try s.write(req.merchant_id);
    try s.objectField("sub_merchant_id");
    try s.write(req.sub_merchant_id);
    try s.objectField("merchant_trade_no");
    try s.write(req.merchant_trade_no);
    try s.objectField("received_time");
    try s.write(req.received_time);
    try s.endObject();
    return out.toOwnedSlice();
}

test "Shipping.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ship" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const sh = Shipping.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ship", sh.ctx.config.app_id);
}

test "UploadShippingInfoRequest 序列化包含 order_key" {
    const allocator = std.testing.allocator;
    const body = try jsonStringifyUpload(allocator, .{
        .order_key = .{ .out_trade_no = "t1", .mchid = "m1" },
    });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"order_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"out_trade_no\":\"t1\"") != null);
}
