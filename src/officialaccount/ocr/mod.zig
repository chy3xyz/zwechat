// SPDX-License-Identifier: Apache-2.0
//! officialaccount/ocr — OCR（身份证 / 银行卡 / 行驶证 / 驾驶证 / 营业执照 / 通用印刷体 / 车牌号）
//!
//! 对应 `_ref/wechat/officialaccount/ocr/ocr.go`。与 Go 实现一致：`img_url` 以
//! `url.QueryEscape` 语义百分号编码后放在 **query** 中（不是 JSON body），请求体为空。

const std = @import("std");
const Context = @import("../context.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Ocr = struct {
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

    /// 身份证 OCR。返回响应原文（堆分配），由调用方负责 `allocator.free`。
    pub fn idCard(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost(ocrIDCardURL, img_url);
    }

    /// 银行卡 OCR。返回响应原文（堆分配），由调用方负责 `allocator.free`。
    pub fn bankCard(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost(ocrBankCardURL, img_url);
    }

    /// 行驶证 OCR（`cv/ocr/driving`）。返回响应原文（堆分配），由调用方负责 `allocator.free`。
    pub fn driving(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost(ocrDrivingURL, img_url);
    }

    /// 驾驶证 OCR（`cv/ocr/drivinglicense`）。返回响应原文（堆分配），由调用方负责 `allocator.free`。
    pub fn driverLicense(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost(ocrDrivingLicenseURL, img_url);
    }

    /// 营业执照 OCR。返回响应原文（堆分配），由调用方负责 `allocator.free`。
    pub fn bizLicense(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost(ocrBizLicenseURL, img_url);
    }

    /// 通用印刷体 OCR。返回响应原文（堆分配），由调用方负责 `allocator.free`。
    pub fn common(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost(ocrCommonURL, img_url);
    }

    /// 车牌号 OCR。返回响应原文（堆分配），由调用方负责 `allocator.free`。
    pub fn plateNumber(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost(ocrPlateNumberURL, img_url);
    }

    fn ocrPost(self: *Self, url: []const u8, img_url: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        // 与 Go 对齐：img_url 以 url.QueryEscape 编码后放在 query，body 为空串。
        const escaped = try queryEscape(self.allocator, img_url);
        defer self.allocator.free(escaped);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?img_url={s}&access_token={s}",
            .{ url, escaped, access_token },
        );
        defer self.allocator.free(uri);

        const resp = try self.post(uri, "");
        errdefer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "OCR")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    fn post(self: *Self, uri: []const u8, payload: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.post(uri, payload, null);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.post(uri, payload, null);
    }
};

pub const ocrIDCardURL = "https://api.weixin.qq.com/cv/ocr/idcard";
pub const ocrBankCardURL = "https://api.weixin.qq.com/cv/ocr/bankcard";
pub const ocrDrivingURL = "https://api.weixin.qq.com/cv/ocr/driving";
pub const ocrDrivingLicenseURL = "https://api.weixin.qq.com/cv/ocr/drivinglicense";
pub const ocrBizLicenseURL = "https://api.weixin.qq.com/cv/ocr/bizlicense";
pub const ocrCommonURL = "https://api.weixin.qq.com/cv/ocr/comm";
pub const ocrPlateNumberURL = "https://api.weixin.qq.com/cv/ocr/platenum";

/// `url.QueryEscape` 语义：保留 `[A-Za-z0-9-_.~]`，空格 → `+`，其余字节 → `%XX`（大写 hex）。
fn queryEscape(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const hex_upper = "0123456789ABCDEF";
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try buf.append(allocator, c),
            ' ' => try buf.append(allocator, '+'),
            else => {
                try buf.append(allocator, '%');
                try buf.append(allocator, hex_upper[c >> 4]);
                try buf.append(allocator, hex_upper[c & 0x0F]);
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}

// —— 测试 ——

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-ocr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "Ocr.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ocr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const o = Ocr.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ocr", o.ctx.config.app_id);
}

test "queryEscape 与 Go url.QueryEscape 对齐" {
    const allocator = std.testing.allocator;
    const escaped = try queryEscape(allocator, "https://example.com/a b.jpg?x=1&y=2");
    defer allocator.free(escaped);
    // Go: url.QueryEscape("https://example.com/a b.jpg?x=1&y=2")
    //  = "https%3A%2F%2Fexample.com%2Fa+b.jpg%3Fx%3D1%26y%3D2"
    try std.testing.expectEqualStrings(
        "https%3A%2F%2Fexample.com%2Fa+b.jpg%3Fx%3D1%26y%3D2",
        escaped,
    );
}

test "行驶证 / 驾驶证 endpoint 不再互换（回归）" {
    // 与 _ref/wechat/officialaccount/ocr/ocr.go 常量逐字对齐。
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cv/ocr/driving", ocrDrivingURL);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cv/ocr/drivinglicense", ocrDrivingLicenseURL);
}

test "idCard 走 query 参数且 img_url 被转义（回归：body 携带 JSON 不符合 Go 实现）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    // "https://example.com/a b.jpg" QueryEscape = https%3A%2F%2Fexample.com%2Fa+b.jpg
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/idcard?img_url=https%3A%2F%2Fexample.com%2Fa+b.jpg&access_token=token-abc", .{
        .body = "{\"type\":\"Front\",\"name\":\"张三\",\"id\":\"110101199001011234\"}",
    });

    var ctx = makeCtx();
    var o = Ocr.init(&ctx, allocator);
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    const resp = try o.idCard("https://example.com/a b.jpg");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "110101199001011234") != null);
}

test "driving / driverLicense 命中正确 URL" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/driving?img_url=u&access_token=token-abc", .{
        .body = "{\"plate_num\":\"沪A12345\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/drivinglicense?img_url=u&access_token=token-abc", .{
        .body = "{\"id_num\":\"310101199001011234\"}",
    });

    var ctx = makeCtx();
    var o = Ocr.init(&ctx, allocator);
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    const r1 = try o.driving("u");
    defer allocator.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "沪A12345") != null);

    const r2 = try o.driverLicense("u");
    defer allocator.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "310101199001011234") != null);
}

test "errcode != 0 返回 ApiError 且释放响应" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/bankcard?img_url=u&access_token=token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });

    var ctx = makeCtx();
    var o = Ocr.init(&ctx, allocator);
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    try std.testing.expectError(util_error.WechatError.ApiError, o.bankCard("u"));
}

test "新增 bizLicense / common / plateNumber endpoint 常量" {
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cv/ocr/bizlicense", ocrBizLicenseURL);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cv/ocr/comm", ocrCommonURL);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cv/ocr/platenum", ocrPlateNumberURL);
}
