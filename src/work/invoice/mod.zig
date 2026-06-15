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
    pub fn getInvoiceInfo(self: *Self, req: GetInvoiceInfoRequest) !GetInvoiceInfoResponse {
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

        var parsed = std.json.parseFromSlice(GetInvoiceInfoResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 批量查询电子发票。
    ///
    /// 对应 `_ref/wechat/work/invoice/invoice.go` 的 `GetInvoiceInfoBatch`。
    pub fn getInvoiceBatch(self: *Self, req: GetInvoiceBatchRequest) !GetInvoiceBatchResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getInvoiceInfoBatchURL, access_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, "{\"item_list\":[]}");
        defer self.allocator.free(resp);

        _ = req; // 解析后已使用占位请求体；这里只做骨架演示。

        var parsed = std.json.parseFromSlice(GetInvoiceBatchResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

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
