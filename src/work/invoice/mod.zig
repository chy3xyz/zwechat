// SPDX-License-Identifier: Apache-2.0
//! work/invoice — 电子发票
//!
//! 对应 `_ref/wechat/work/invoice/`：查询电子发票 / 批量查询电子发票
//! 等报销场景接口。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_json = @import("../../util/json.zig");
const credential = @import("../../credential/mod.zig");

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
    /// 走 `util/retry.callApi`：token 失效（40001 等）时自动作废缓存并重试一次。
    pub fn getInvoiceInfo(self: *Self, req: GetInvoiceInfoRequest) !std.json.Parsed(GetInvoiceInfoResponse) {
        // card_id / encrypt_code 均直接来自调用方，必须走 JSON 转义：旧实现用
        // `allocPrint` 裸插值，含 `"` / `\` / 控制字符时产出非法 JSON。
        const body = try encodeInvoiceRefJson(self.allocator, req.card_id, req.encrypt_code);
        defer self.allocator.free(body);

        const Sender = struct {
            self: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}",
                    .{ getInvoiceInfoURL, token },
                );
                defer allocator.free(uri);
                return util_http.getDefaultClient(c.self.allocator).postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "GetInvoiceInfo",
            Sender{ .self = self, .body = body },
        );
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetInvoiceInfoResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        return parsed;
    }

    /// 批量查询电子发票。
    ///
    /// 对应 `_ref/wechat/work/invoice/invoice.go` 的 `GetInvoiceInfoBatch`。
    /// 与 `getInvoiceInfo` 一样走 `util/retry.callApi` 的失效自愈链路。
    pub fn getInvoiceBatch(self: *Self, req: GetInvoiceBatchRequest) !std.json.Parsed(GetInvoiceBatchResponse) {
        const body = try encodeInvoiceBatchJson(self.allocator, req.item_list);
        defer self.allocator.free(body);

        const Sender = struct {
            self: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}",
                    .{ getInvoiceInfoBatchURL, token },
                );
                defer allocator.free(uri);
                return util_http.getDefaultClient(c.self.allocator).postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            "GetInvoiceInfoBatch",
            Sender{ .self = self, .body = body },
        );
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetInvoiceBatchResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        return parsed;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：手写 JSON 序列化
// ─────────────────────────────────────────────────────────────────────────────

/// 单张发票引用编码为 `{"card_id":"...","encrypt_code":"..."}`。
///
/// `card_id` / `encrypt_code` 来自调用方，此前 `getInvoiceInfo` 直接 `allocPrint`
/// 裸插值，含 `"` / `\` / 控制字符时会拼出非法 JSON。
fn encodeInvoiceRefJson(allocator: std.mem.Allocator, card_id: []const u8, encrypt_code: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendInvoiceRefJson(allocator, &buf, card_id, encrypt_code);
    return buf.toOwnedSlice(allocator);
}

/// 把单张发票引用追加到 `buf`（`encodeInvoiceRefJson` 与批量编码共用）。
fn appendInvoiceRefJson(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    card_id: []const u8,
    encrypt_code: []const u8,
) !void {
    try buf.appendSlice(allocator, "{\"card_id\":\"");
    try appendJsonString(allocator, buf, card_id);
    try buf.appendSlice(allocator, "\",\"encrypt_code\":\"");
    try appendJsonString(allocator, buf, encrypt_code);
    try buf.appendSlice(allocator, "\"}");
}

/// `GetInvoiceBatchRequest` 编码为 `{"item_list":[{"card_id":"...","encrypt_code":"..."},...]}`。
fn encodeInvoiceBatchJson(allocator: std.mem.Allocator, item_list: []const InvoiceRef) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"item_list\":[");
    for (item_list, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendInvoiceRefJson(allocator, &buf, item.card_id, item.encrypt_code);
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// JSON 字符串转义（实现收敛到 `util.json.appendEscapedString`；此前漏转义
/// `c < 0x20` 控制字符，`card_id` / `encrypt_code` 含控制字符时会产出非法 JSON）。
const appendJsonString = util_json.appendEscapedString;

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

/// 捕获最近一次请求的 URI 与 payload，并返回预设响应。
const TestCapture = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uri: []u8 = &.{},
    payload: []u8 = &.{},

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = method;
        _ = content_type;
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }
};

test "getInvoiceInfo 请求体转义：card_id / encrypt_code 含引号、反斜杠、控制字符仍为合法 JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"card_id\":\"card_1\"}",
    };
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(TestCapture.dispatch, @ptrCast(&cap));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var inv = Invoice.init(&ctx, alloc);

    // 正常输入：字节序列与旧的 `allocPrint` 实现逐字一致。
    var plain = try inv.getInvoiceInfo(.{ .card_id = "card_1", .encrypt_code = "enc1" });
    defer plain.deinit();
    try std.testing.expectEqualStrings(
        "{\"card_id\":\"card_1\",\"encrypt_code\":\"enc1\"}",
        cap.payload,
    );

    // 含特殊字符的入参：旧实现拼出非法 JSON，现在必须能被解析回原值。
    const card_id = "card\"1\\2";
    const encrypt_code = "enc\x01code";
    var parsed = try inv.getInvoiceInfo(.{ .card_id = card_id, .encrypt_code = encrypt_code });
    defer parsed.deinit();

    const body = try std.json.parseFromSlice(GetInvoiceInfoRequest, alloc, cap.payload, .{});
    defer body.deinit();
    try std.testing.expectEqualStrings(card_id, body.value.card_id);
    try std.testing.expectEqualStrings(encrypt_code, body.value.encrypt_code);
}

// ─────────────────────────────────────────────────────────────────────────────
// token 失效自愈（mock transport）
// ─────────────────────────────────────────────────────────────────────────────

/// 可自愈的假 token handle：`invalidate` 后把 `idx` 推进到下一个 token。
const HealState = struct {
    invalidates: usize = 0,
    idx: usize = 0,
    tokens: []const []const u8 = &.{ "old-token", "new-token" },

    fn getToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const st: *HealState = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, st.tokens[st.idx]);
    }

    fn invalidate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const st: *HealState = @ptrCast(@alignCast(ctx));
        st.invalidates += 1;
        if (st.idx + 1 < st.tokens.len) st.idx += 1;
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

fn makeHealCtx(state: *HealState) Context {
    return .{
        .config = .{ .corp_id = "ww-inv-heal" },
        .access_token_handle = .{ .ptr = @ptrCast(state), .vtable = &HealState.vtable },
    };
}

test "getInvoiceInfo token 失效自愈：40001 → 作废缓存 → 新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/card/invoice/reimburse/getinvoiceinfo?access_token=old-token", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/card/invoice/reimburse/getinvoiceinfo?access_token=new-token", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"card_id\":\"card_1\",\"openid\":\"o1\",\"type\":\"增值税电子普通发票\",\"user_info\":{\"fee\":100,\"title\":\"某某公司\"}}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var inv = Invoice.init(&ctx, allocator);
    var parsed = try inv.getInvoiceInfo(.{ .card_id = "card_1", .encrypt_code = "enc1" });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("card_1", parsed.value.card_id);
    try std.testing.expectEqual(@as(i64, 100), parsed.value.user_info.fee);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[0], "access_token=old-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-token") != null);
}

test "getInvoiceBatch token 失效自愈：41001 → 作废缓存 → 新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/card/invoice/reimburse/getinvoiceinfobatch?access_token=old-token", .{
        .body = "{\"errcode\":41001,\"errmsg\":\"access_token missing\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/card/invoice/reimburse/getinvoiceinfobatch?access_token=new-token", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"item_list\":[{\"card_id\":\"card_1\",\"openid\":\"o1\"}]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = HealState{};
    var ctx = makeHealCtx(&state);
    var inv = Invoice.init(&ctx, allocator);
    var items = [_]InvoiceRef{.{ .card_id = "card_1", .encrypt_code = "enc1" }};
    var parsed = try inv.getInvoiceBatch(.{ .item_list = &items });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.item_list.len);
    try std.testing.expectEqualStrings("card_1", parsed.value.item_list[0].card_id);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-token") != null);
}
