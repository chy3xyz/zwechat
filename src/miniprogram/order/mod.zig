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
///
/// 官方枚举共 **6** 个值（`(6) 资金待结算`），见
/// [查询订单列表](https://developers.weixin.qq.com/miniprogram/dev/server/API/order_shipping/api_getorderlist.html)。
/// 此前只到 `refund = 5`，而本枚举是**穷举**的 —— `std.json` 对整数枚举走
/// `std.enums.fromInt(T, i) orelse error.InvalidEnumTag`，于是「资金待结算」的订单
/// 在 `get_order` / `get_order_list` 上**必然 `DecodeError`**（既有 mock 夹具只造过 1/2，
/// 所以测试全绿也没暴露）。
///
/// 现补上 `settled`，并声明为**非穷举**（`_`）：`std.enums.fromInt` 对非穷举枚举接受
/// 任意 tag 值，因此上游将来再新增状态值时**不会再让整条查单链路解析失败**（响应侧
/// 的枚举本就该按"未来可能加值"对待）。
pub const State = enum(u8) {
    wait_shipment = 1, // 待发货
    shipped = 2, // 已发货
    confirm = 3, // 确认收货
    complete = 4, // 交易完成
    refund = 5, // 已退款
    settled = 6, // 资金待结算
    _,
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

/// 物流信息列表元素（`order.shipping.shipping_list[]`）。
///
/// 官方还有 `goods_desc`（该物流单对应的商品描述）与 `contact`
/// （寄件人 / 收件人联系方式）两个字段，此前缺失 —— 因解析开了
/// `ignore_unknown_fields` 不会报错，只是**静默丢字段**，故补上。
pub const ShippingItem = struct {
    tracking_no: []const u8 = "",
    express_company: []const u8 = "",
    goods_desc: []const u8 = "",
    upload_time: i64 = 0,
    contact: ShippingContact = .{},
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

/// 支付时间所属范围。
///
/// 官方两个子字段都是**可选**语义：`begin_time` 不填视为从 0 开始，`end_time` 不填视为
/// 32 位无符号整型最大值。因此这里用 `?i64` 表示"不填"。
///
/// 此前两者是 `i64 = 0` 且序列化器**恒把整个 `pay_time_range` 写出去**，等于把区间锁死成
/// `[0, 0]` —— 调用方只想按 `openid` / `order_state` 查询时会拿到空列表。
pub const TimeRange = struct {
    begin_time: ?i64 = null,
    end_time: ?i64 = null,
};

pub const GetShippingOrderListRequest = struct {
    /// 支付时间所属范围。`null` = 整个键省略（不按支付时间过滤）。
    pay_time_range: ?TimeRange = null,
    order_state: ?State = null,
    openid: []const u8 = "",
    last_index: []const u8 = "",
    /// 返回列表长度，官方默认 **100**。`0` 视为「未设置」→ 省略该键，交给服务端默认值
    /// （此前恒写 `page_size: 0`）。
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
    ///
    /// **会做必填校验（fail-closed）**：官方把 `upload_time` 与 `payer.openid` 标为必填
    /// （[发货信息录入](https://developers.weixin.qq.com/miniprogram/dev/server/API/order_shipping/api_uploadshippinginfo.html)），
    /// 而这两个字段在本结构体里默认是空值、且序列化器会**跳过空值** —— 也就是说
    /// 裸构 `UploadShippingInfoRequest` 会静默发出**缺必填字段的请求体**（微信侧回
    /// `10060014` / `268485216` / `268485195`，且错误信息不指向缺失字段本身）。
    /// 因此这里直接返回 `error.InvalidArgument`，与 `SendTextRequest` 空 content 的处理口径一致。
    ///
    /// 注意 `upload_time` 必须是 RFC 3339 格式（如 `2022-12-15T13:29:35.120+08:00`），
    /// 且更新发货信息时它必须比上一次请求更新。
    pub fn uploadShippingInfo(self: *Self, req: UploadShippingInfoRequest) !void {
        if (req.upload_time.len == 0) return error.InvalidArgument;
        const payer = req.payer orelse return error.InvalidArgument;
        if (payer.openid.len == 0) return error.InvalidArgument;

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
                const uri = try allocator.print(
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
                const uri = try allocator.print(
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
    // `pay_time_range` 与 `page_size` 都是官方**可选**字段，未设置时整键省略；
    // 子字段 `begin_time` / `end_time` 同样只在非 null 时写出（官方「不填」有语义）。
    if (req.pay_time_range) |range| {
        try s.objectField("pay_time_range");
        try s.beginObject();
        if (range.begin_time) |bt| {
            try s.objectField("begin_time");
            try s.write(bt);
        }
        if (range.end_time) |et| {
            try s.objectField("end_time");
            try s.write(et);
        }
        try s.endObject();
    }
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
    if (req.page_size > 0) {
        try s.objectField("page_size");
        try s.write(req.page_size);
    }
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
    try std.testing.expect(std.mem.find(u8, body, "\"order_key\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"out_trade_no\":\"t1\"") != null);
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

    /// 释放并清空上一次捕获的 URI / payload。
    ///
    /// 同一个 transport 被**连续调用多次**时必须先 `reset`，否则 `dispatch` 会直接覆盖
    /// `uri` / `payload` 指针，丢掉上一份分配（该夹具的既有隐患）。`reset` 把两者置回
    /// 空串，因此随后的 `deinit` 仍可安全调用（零长度 free 是 no-op）。
    fn reset(self: *CapturingTransport, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.payload);
        self.uri = "";
        self.payload = "";
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
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"transaction_id\":\"tx-1\"") != null);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"merchant_id\":\"m1\"") != null);
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
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"page_size\":10") != null);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.order_list.len);
    try std.testing.expectEqualStrings("tx-2", parsed.value.order_list[0].transaction_id);
    try std.testing.expectEqual(State.wait_shipment, parsed.value.order_list[0].order_state);
}

test "uploadShippingInfo POST 发货信息录入（成功无返回体）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    try sh.uploadShippingInfo(.{
        .order_key = .{ .out_trade_no = "t1", .mchid = "m1" },
        .logistics_type = .virtual,
        .shipping_list = &[_]ShippingInfo{.{ .item_desc = "虚拟商品", .tracking_no = "no-tracking" }},
        // 官方必填（见 `uploadShippingInfo` 的必填校验）。
        .upload_time = "2022-12-15T13:29:35.120+08:00",
        .payer = .{ .openid = "openid-1" },
    });

    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/sec/order/upload_shipping_info?access_token=token-abc", tt.uri);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"out_trade_no\":\"t1\"") != null);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"logistics_type\":3") != null);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"item_desc\":\"虚拟商品\"") != null);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"upload_time\":\"2022-12-15T13:29:35.120+08:00\"") != null);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"payer\":{\"openid\":\"openid-1\"}") != null);
}

test "uploadShippingInfo 缺官方必填字段时 fail-closed（回归：此前静默发出非法请求体）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    const base = UploadShippingInfoRequest{
        .order_key = .{ .out_trade_no = "t1", .mchid = "m1" },
        .logistics_type = .virtual,
        .shipping_list = &[_]ShippingInfo{.{ .item_desc = "虚拟商品", .tracking_no = "no-tracking" }},
    };

    // 缺 upload_time
    try std.testing.expectError(error.InvalidArgument, sh.uploadShippingInfo(base));
    // 有 upload_time 但缺 payer
    try std.testing.expectError(error.InvalidArgument, sh.uploadShippingInfo(.{
        .order_key = base.order_key,
        .logistics_type = base.logistics_type,
        .shipping_list = base.shipping_list,
        .upload_time = "2022-12-15T13:29:35.120+08:00",
    }));
    // payer 给了但 openid 为空
    try std.testing.expectError(error.InvalidArgument, sh.uploadShippingInfo(.{
        .order_key = base.order_key,
        .logistics_type = base.logistics_type,
        .shipping_list = base.shipping_list,
        .upload_time = "2022-12-15T13:29:35.120+08:00",
        .payer = .{ .openid = "" },
    }));
    // 三次都应在发请求之前被拦下。
    try std.testing.expectEqualStrings("", tt.uri);
}

test "order_state 的 6=资金待结算 可解析（回归：穷举枚举缺值导致必然 DecodeError）" {
    const allocator = std.testing.allocator;
    // 单查：order_state = 6
    var tt = CapturingTransport{ .response = "{\"order\":{\"transaction_id\":\"tx-6\",\"order_state\":6}}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try sh.getShippingOrder(.{ .transaction_id = "tx-6" });
    defer parsed.deinit();
    try std.testing.expectEqual(State.settled, parsed.value.order.order_state);
    try std.testing.expectEqual(@as(u8, 6), @backingInt(parsed.value.order.order_state));

    // 列表：order_state = 6
    tt.reset(allocator);
    tt.response = "{\"order_list\":[{\"transaction_id\":\"tx-7\",\"order_state\":6}],\"has_more\":false}";
    var parsed_list = try sh.getShippingOrderList(.{});
    defer parsed_list.deinit();
    try std.testing.expectEqual(State.settled, parsed_list.value.order_list[0].order_state);
}

test "order_state 非穷举：上游将来新增的状态值不再让整条链路 DecodeError" {
    const allocator = std.testing.allocator;
    // 99 不在官方枚举里；`State` 声明为 `enum(u8) { …, _ }`，`std.enums.fromInt` 接受任意 tag。
    var tt = CapturingTransport{ .response = "{\"order\":{\"transaction_id\":\"tx-99\",\"order_state\":99}}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try sh.getShippingOrder(.{ .transaction_id = "tx-99" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 99), @backingInt(parsed.value.order.order_state));
}

test "getShippingOrderList 的可选字段：未设置时整键省略（回归：恒写 {0,0} 锁死区间）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"order_list\":[],\"has_more\":false}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    // 1) 全部默认：请求体应为空对象 `{}`（三个可选键都不该出现）。
    var p1 = try sh.getShippingOrderList(.{});
    defer p1.deinit();
    try std.testing.expectEqualStrings("{}", tt.payload);

    // 2) 只给 begin_time：`end_time` 不填（官方语义 = u32 最大值），故不出现。
    tt.reset(allocator);
    var p2 = try sh.getShippingOrderList(.{ .pay_time_range = .{ .begin_time = 1727000000 } });
    defer p2.deinit();
    try std.testing.expectEqualStrings("{\"pay_time_range\":{\"begin_time\":1727000000}}", tt.payload);

    // 3) 完整区间 + page_size。
    tt.reset(allocator);
    var p3 = try sh.getShippingOrderList(.{
        .pay_time_range = .{ .begin_time = 1727000000, .end_time = 1727600000 },
        .page_size = 50,
    });
    defer p3.deinit();
    try std.testing.expectEqualStrings(
        "{\"pay_time_range\":{\"begin_time\":1727000000,\"end_time\":1727600000},\"page_size\":50}",
        tt.payload,
    );
}

test "ShippingItem 解析 goods_desc 与 contact（回归：静默丢字段）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"order\":{\"transaction_id\":\"tx-8\",\"order_state\":2,\"shipping\":{\"shipping_list\":[{\"tracking_no\":\"SF123\",\"express_company\":\"SF\",\"goods_desc\":\"抱枕*1\",\"upload_time\":1725000000,\"contact\":{\"consignor_contact\":\"189****1234\",\"receiver_contact\":\"138****5678\"}}]}}}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try sh.getShippingOrder(.{ .transaction_id = "tx-8" });
    defer parsed.deinit();
    const item = parsed.value.order.shipping.?.shipping_list[0];
    try std.testing.expectEqualDeep(ShippingItem{
        .tracking_no = "SF123",
        .express_company = "SF",
        .goods_desc = "抱枕*1",
        .upload_time = 1725000000,
        .contact = .{ .consignor_contact = "189****1234", .receiver_contact = "138****5678" },
    }, item);
}

test "notifyConfirmReceive POST 确认收货提醒（成功无返回体）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var sh = Shipping.init(&ctx, allocator);
    sh.setTransport(CapturingTransport.dispatch, &tt);

    try sh.notifyConfirmReceive(.{
        .transaction_id = "tx-1",
        .merchant_id = "m1",
        .received_time = 1725000000,
    });

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/sec/order/notify_confirm_receive?access_token=token-abc", tt.uri);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"transaction_id\":\"tx-1\"") != null);
    try std.testing.expect(std.mem.find(u8, tt.payload, "\"received_time\":1725000000") != null);
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
