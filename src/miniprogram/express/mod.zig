// SPDX-License-Identifier: Apache-2.0
//! miniprogram/express — 物流服务
//!
//! 对应 `_ref/wechat/miniprogram/express/delivery.go`：传运单、查询运单、更新物品信息、
//! 跟踪运单、获取运力 id 列表。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 运单状态。
pub const WaybillStatus = enum(i64) {
    not_exist = 0, // 运单不存在或者未揽收
    picked = 1, // 已揽件
    transporting = 2, // 运输中
    dispatching = 3, // 派件中
    signed = 4, // 已签收
};

pub const FollowWaybillGoodsInfo = struct {
    detail_list: []const FollowWaybillGoodsInfoItem = &.{},
};

pub const FollowWaybillGoodsInfoItem = struct {
    goods_name: []const u8 = "",
    goods_img_url: []const u8 = "",
    goods_desc: []const u8 = "",
};

pub const FollowWaybillShopInfo = struct {
    goods_info: FollowWaybillGoodsInfo = .{},
};

pub const FlowWaybillInfo = struct {
    waybill_id: []const u8 = "",
    status: WaybillStatus = .not_exist,
};

pub const FlowWaybillDeliveryInfo = struct {
    delivery_id: []const u8 = "",
    delivery_name: []const u8 = "",
};

pub const TraceWaybillRequest = struct {
    goods_info: FollowWaybillGoodsInfo = .{},
    openid: []const u8 = "",
    sender_phone: []const u8 = "",
    receiver_phone: []const u8 = "",
    delivery_id: []const u8 = "",
    waybill_id: []const u8 = "",
    trans_id: []const u8 = "",
    order_detail_path: []const u8 = "",
};

pub const TraceWaybillResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    waybill_token: []const u8 = "",
};

pub const QueryTraceRequest = struct {
    waybill_token: []const u8 = "",
};

pub const QueryTraceResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    waybill_info: FlowWaybillInfo = .{},
    shop_info: FollowWaybillShopInfo = .{},
    delivery_info: FlowWaybillDeliveryInfo = .{},
};

pub const UpdateWaybillGoodsRequest = struct {
    waybill_token: []const u8 = "",
    goods_info: FollowWaybillGoodsInfo = .{},
};

pub const FollowWaybillRequest = TraceWaybillRequest;
pub const FollowWaybillResponse = TraceWaybillResponse;
pub const QueryFollowTraceRequest = QueryTraceRequest;
pub const QueryFollowTraceResponse = QueryTraceResponse;
pub const UpdateFollowWaybillGoodsRequest = UpdateWaybillGoodsRequest;

pub const GetDeliveryListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    delivery_list: []const FlowWaybillDeliveryInfo = &.{},
    count: i64 = 0,
};

/// 物流服务模块。
pub const Express = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 传运单（返回 `Parsed(TraceWaybillResponse)`）。
    pub fn traceWaybill(self: *Self, req: TraceWaybillRequest) !std.json.Parsed(TraceWaybillResponse) {
        const body = try jsonStringifyTrace(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("cgi-bin/express/delivery/open_msg/trace_waybill", body, TraceWaybillResponse);
    }

    /// 查询运单详情信息。
    pub fn queryTrace(self: *Self, req: QueryTraceRequest) !std.json.Parsed(QueryTraceResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"waybill_token\":\"{s}\"}}", .{req.waybill_token});
        defer self.allocator.free(body);
        return self.postParsed("cgi-bin/express/delivery/open_msg/query_trace", body, QueryTraceResponse);
    }

    /// 更新物品信息。
    pub fn updateWaybillGoods(self: *Self, req: UpdateWaybillGoodsRequest) !void {
        const body = try jsonStringifyUpdateGoods(self.allocator, req);
        defer self.allocator.free(body);
        try self.postCommon("cgi-bin/express/delivery/open_msg/update_waybill_goods", body, "UpdateWaybillGoods");
    }

    /// 跟踪运单。
    pub fn followWaybill(self: *Self, req: FollowWaybillRequest) !std.json.Parsed(FollowWaybillResponse) {
        const body = try jsonStringifyTrace(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("cgi-bin/express/delivery/open_msg/follow_waybill", body, FollowWaybillResponse);
    }

    /// 查询跟踪运单详情。
    pub fn queryFollowTrace(self: *Self, req: QueryFollowTraceRequest) !std.json.Parsed(QueryFollowTraceResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"waybill_token\":\"{s}\"}}", .{req.waybill_token});
        defer self.allocator.free(body);
        return self.postParsed("cgi-bin/express/delivery/open_msg/query_follow_trace", body, QueryFollowTraceResponse);
    }

    /// 更新跟踪运单物品信息。
    pub fn updateFollowWaybillGoods(self: *Self, req: UpdateFollowWaybillGoodsRequest) !void {
        const body = try jsonStringifyUpdateGoods(self.allocator, req);
        defer self.allocator.free(body);
        try self.postCommon("cgi-bin/express/delivery/open_msg/update_follow_waybill_goods", body, "UpdateFollowWaybillGoods");
    }

    /// 获取运力 id 列表。
    pub fn getDeliveryList(self: *Self) !std.json.Parsed(GetDeliveryListResponse) {
        return self.postParsed("cgi-bin/express/delivery/open_msg/get_delivery_list", "{}", GetDeliveryListResponse);
    }

    fn postParsed(self: *Self, comptime T: type, endpoint: []const u8, body: []const u8) !std.json.Parsed(T) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(self.allocator, "https://api.weixin.qq.com/{s}?access_token={s}", .{ endpoint, access_token });
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

    fn postCommon(self: *Self, endpoint: []const u8, body: []const u8, api_name: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);
        const uri = try std.fmt.allocPrint(self.allocator, "https://api.weixin.qq.com/{s}?access_token={s}", .{ endpoint, access_token });
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, api_name)) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }
};

fn jsonStringifyTrace(allocator: std.mem.Allocator, req: TraceWaybillRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("goods_info");
    try s.beginObject();
    try s.objectField("detail_list");
    try s.beginArray();
    for (req.goods_info.detail_list) |item| {
        try s.beginObject();
        try s.objectField("goods_name");
        try s.write(item.goods_name);
        try s.objectField("goods_img_url");
        try s.write(item.goods_img_url);
        if (item.goods_desc.len > 0) {
            try s.objectField("goods_desc");
            try s.write(item.goods_desc);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.objectField("openid");
    try s.write(req.openid);
    try s.objectField("sender_phone");
    try s.write(req.sender_phone);
    try s.objectField("receiver_phone");
    try s.write(req.receiver_phone);
    try s.objectField("delivery_id");
    try s.write(req.delivery_id);
    try s.objectField("waybill_id");
    try s.write(req.waybill_id);
    try s.objectField("trans_id");
    try s.write(req.trans_id);
    if (req.order_detail_path.len > 0) {
        try s.objectField("order_detail_path");
        try s.write(req.order_detail_path);
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyUpdateGoods(allocator: std.mem.Allocator, req: UpdateWaybillGoodsRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("waybill_token");
    try s.write(req.waybill_token);
    try s.objectField("goods_info");
    try s.beginObject();
    try s.objectField("detail_list");
    try s.beginArray();
    for (req.goods_info.detail_list) |item| {
        try s.beginObject();
        try s.objectField("goods_name");
        try s.write(item.goods_name);
        try s.objectField("goods_img_url");
        try s.write(item.goods_img_url);
        if (item.goods_desc.len > 0) {
            try s.objectField("goods_desc");
            try s.write(item.goods_desc);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    return out.toOwnedSlice();
}

test "Express.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ex" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const e = Express.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ex", e.ctx.config.app_id);
}

test "TraceWaybillResponse 默认值" {
    const r = TraceWaybillResponse{};
    try std.testing.expectEqualStrings("", r.waybill_token);
}
