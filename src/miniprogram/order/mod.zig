// SPDX-License-Identifier: Apache-2.0
//! miniprogram/order — 订单发货信息管理
//!
//! 对应 `_ref/wechat/miniprogram/order/shipping.go`：发货信息录入、查询订单发货状态、
//! 查询订单列表、确认收货提醒。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

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

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
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
        const Sender = struct {
            shipping: *Self,
            path: []const u8,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/sec/order/{s}?access_token={s}",
                    .{ c.path, token },
                );
                defer allocator.free(uri);
                return c.shipping.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, api_name, Sender{
            .shipping = self,
            .path = path,
            .body = body,
        });
        self.allocator.free(resp);
    }

    fn postParsed(self: *Self, path: []const u8, body: []const u8, comptime T: type) !std.json.Parsed(T) {
        const Sender = struct {
            shipping: *Self,
            path: []const u8,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/sec/order/{s}?access_token={s}",
                    .{ c.path, token },
                );
                defer allocator.free(uri);
                return c.shipping.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, path, Sender{
            .shipping = self,
            .path = path,
            .body = body,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(T, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// POST JSON；注入 transport 时使用之，否则走线程默认 client。
    fn postJSON(self: *Self, uri: []const u8, body: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, body);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body);
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

// ── 可注入 transport 测试 ────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 记录 method / uri / payload 并返回预设响应的 transport。
const CapturingTransport = struct {
    method: std.http.Method = .GET,
    uri: []const u8 = "",
    payload: []const u8 = "",
    response: []const u8 = "",

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = content_type;
        const self: *CapturingTransport = @ptrCast(@alignCast(ctx));
        self.method = method;
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }

    fn deinit(self: *CapturingTransport, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.payload);
    }
};

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "getShippingOrder POST 查询发货状态并解析（回归：泛型 T 参数错位）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"order\":{\"transaction_id\":\"tx-1\",\"openid\":\"openid-1\",\"order_state\":2,\"shipping\":{\"delivery_mode\":1,\"logistics_type\":1,\"finish_shipping\":false,\"finish_shipping_count\":0,\"goods_desc\":\"\",\"shipping_list\":[]}}}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try sh.getShippingOrder(.{ .transaction_id = "tx-1", .merchant_id = "m1" });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/sec/order/get_order?access_token=token-abc", tt.uri);
    try std.testing.expect(std.mem.indexOf(u8, tt.payload, "\"transaction_id\":\"tx-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tt.payload, "\"merchant_id\":\"m1\"") != null);
    try std.testing.expectEqualStrings("tx-1", parsed.value.order.transaction_id);
    try std.testing.expectEqual(State.shipped, parsed.value.order.order_state);
}

test "getShippingOrderList POST 查询订单列表并解析" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"order_list\":[{\"transaction_id\":\"tx-2\",\"order_state\":1}],\"last_index\":\"idx-1\",\"has_more\":false}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try sh.getShippingOrderList(.{
        .pay_time_range = .{ .begin_time = 1727000000, .end_time = 1727600000 },
        .page_size = 10,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/sec/order/get_order_list?access_token=token-abc", tt.uri);
    try std.testing.expect(std.mem.indexOf(u8, tt.payload, "\"page_size\":10") != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.order_list.len);
    try std.testing.expectEqualStrings("tx-2", parsed.value.order_list[0].transaction_id);
    try std.testing.expectEqual(State.wait_shipment, parsed.value.order_list[0].order_state);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "getShippingOrder token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/wxa/sec/order/get_order?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"order\":{\"transaction_id\":\"tx-9\",\"order_state\":2}}",
    });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = stub.asHandle(),
    };
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try sh.getShippingOrder(.{ .transaction_id = "tx-9" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tx-9", parsed.value.order.transaction_id);
    try std.testing.expectEqual(State.shipped, parsed.value.order.order_state);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
