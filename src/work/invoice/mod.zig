// SPDX-License-Identifier: Apache-2.0
//! work/invoice — 电子发票
//!
//! 对应 `_ref/wechat/work/invoice/`：查询电子发票 / 批量查询电子发票
//! 等报销场景接口。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 查询电子发票（POST JSON，`{card_id, encrypt_code}`）。
pub const getInvoiceInfoURL =
    "https://qyapi.weixin.qq.com/cgi-bin/card/invoice/reimburse/getinvoiceinfo";

/// 批量查询电子发票。
pub const getInvoiceInfoBatchURL =
    "https://qyapi.weixin.qq.com/cgi-bin/card/invoice/reimburse/getinvoiceinfobatch";

// ─────────────────────────────────────────────────────────────────────────────
// 响应 / 数据结构
// ─────────────────────────────────────────────────────────────────────────────

/// 发票中的商品条目。
pub const Info = struct {
    name: []const u8 = "",
    num: i64 = 0,
    unit: []const u8 = "",
    fee: i64 = 0,
    price: i64 = 0,
};

/// 发票的用户 / 报销信息。
pub const UserInfo = struct {
    fee: i64 = 0,
    title: []const u8 = "",
    billing_time: i64 = 0,
    billing_no: []const u8 = "",
    billing_code: []const u8 = "",
    info: []Info = &.{},
    fee_without_tax: i64 = 0,
    tax: i64 = 0,
    detail: []const u8 = "",
    pdf_url: []const u8 = "",
    trip_pdf_url: []const u8 = "",
    reimburse_status: []const u8 = "",
    check_code: []const u8 = "",
    buyer_number: []const u8 = "",
    buyer_address_and_phone: []const u8 = "",
    buyer_bank_account: []const u8 = "",
    seller_number: []const u8 = "",
    seller_address_and_phone: []const u8 = "",
    seller_bank_account: []const u8 = "",
    remarks: []const u8 = "",
    cashier: []const u8 = "",
    maker: []const u8 = "",
};

/// `GetInvoiceInfo` 请求体。
pub const GetInvoiceInfoRequest = struct {
    card_id: []const u8 = "",
    encrypt_code: []const u8 = "",
};

/// `GetInvoiceInfo` 响应。
pub const GetInvoiceInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    card_id: []const u8 = "",
    begin_time: i64 = 0,
    end_time: i64 = 0,
    openid: []const u8 = "",
    type: []const u8 = "",
    payee: []const u8 = "",
    detail: []const u8 = "",
    user_info: UserInfo = .{},
};

/// 批量查询条目。
pub const Item = struct {
    card_id: []const u8 = "",
    begin_time: i64 = 0,
    end_time: i64 = 0,
    openid: []const u8 = "",
    type: []const u8 = "",
    payee: []const u8 = "",
    detail: []const u8 = "",
    user_info: UserInfo = .{},
};

/// `GetInvoiceBatch` 请求体。
pub const GetInvoiceBatchRequest = struct {
    item_list: []InvoiceRef = &.{},
};

/// 单张发票引用（`card_id` + `encrypt_code`）。
pub const InvoiceRef = struct {
    card_id: []const u8 = "",
    encrypt_code: []const u8 = "",
};

/// `GetInvoiceBatch` 响应。
pub const GetInvoiceBatchResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    item_list: []Item = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 电子发票子模块聚合。
pub const Invoice = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 查询电子发票。
    ///
    /// 对应 `_ref/wechat/work/invoice/invoice.go` 的 `GetInvoiceInfo`。
    pub fn getInvoiceInfo(self: *Self, req: GetInvoiceInfoRequest) !std.json.Parsed(GetInvoiceInfoResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getInvoiceInfoURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"card_id\":\"{s}\",\"encrypt_code\":\"{s}\"}}",
            .{ req.card_id, req.encrypt_code },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetInvoiceInfoResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 批量查询电子发票。
    ///
    /// 对应 `_ref/wechat/work/invoice/invoice.go` 的 `GetInvoiceInfoBatch`。
    pub fn getInvoiceBatch(self: *Self, req: GetInvoiceBatchRequest) !std.json.Parsed(GetInvoiceBatchResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getInvoiceInfoBatchURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeInvoiceBatchJson(self.allocator, req.item_list);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetInvoiceBatchResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：手写 JSON 序列化
// ─────────────────────────────────────────────────────────────────────────────

/// `GetInvoiceBatchRequest` 编码为 `{"item_list":[{"card_id":"...","encrypt_code":"..."},...]}`。
fn encodeInvoiceBatchJson(allocator: std.mem.Allocator, item_list: []const InvoiceRef) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"item_list\":[");
    for (item_list, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"card_id\":\"");
        try appendJsonString(allocator, &buf, item.card_id);
        try buf.appendSlice(allocator, "\",\"encrypt_code\":\"");
        try appendJsonString(allocator, &buf, item.encrypt_code);
        try buf.appendSlice(allocator, "\"}");
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

test "Invoice.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-inv" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const inv = Invoice.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-inv", inv.ctx.config.corp_id);
}

test "GetInvoiceInfoRequest 默认值" {
    const r = GetInvoiceInfoRequest{};
    try std.testing.expectEqualStrings("", r.card_id);
    try std.testing.expectEqualStrings("", r.encrypt_code);
}

test "UserInfo 默认值" {
    const u = UserInfo{};
    try std.testing.expectEqual(@as(i64, 0), u.fee);
    try std.testing.expectEqualStrings("", u.title);
    try std.testing.expectEqual(@as(usize, 0), u.info.len);
}

test "GetInvoiceBatchRequest 默认值" {
    const r = GetInvoiceBatchRequest{};
    try std.testing.expectEqual(@as(usize, 0), r.item_list.len);
}

test "encodeInvoiceBatchJson 序列化 item_list" {
    const alloc = std.testing.allocator;
    const items = [_]InvoiceRef{
        .{ .card_id = "card_1", .encrypt_code = "enc\"1" },
        .{ .card_id = "card_2", .encrypt_code = "enc2" },
    };
    const body = try encodeInvoiceBatchJson(alloc, &items);
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"item_list\":[{\"card_id\":\"card_1\",\"encrypt_code\":\"enc\\\"1\"},{\"card_id\":\"card_2\",\"encrypt_code\":\"enc2\"}]}",
        body,
    );
}

test "encodeInvoiceBatchJson 空列表" {
    const alloc = std.testing.allocator;
    const body = try encodeInvoiceBatchJson(alloc, &.{});
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"item_list\":[]}", body);
}
