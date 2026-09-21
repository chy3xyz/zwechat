// SPDX-License-Identifier: Apache-2.0
//! miniprogram/ocr — OCR 识别
//!
//! 对应 `_ref/wechat/miniprogram/ocr/ocr.go`：身份证 / 银行卡 / 行驶证 / 驾驶证 /
//! 营业执照 / 通用印刷体 OCR。`img_url` 传**原始**图片地址即可——本模块按 Go
//! `url.QueryEscape` 语义转义后放进 query（与参考实现逐字对齐）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_uri = @import("../../util/uri.zig");

pub const Position = struct {
    left_top: Coordinate = .{},
    right_top: Coordinate = .{},
    right_bottom: Coordinate = .{},
    left_bottom: Coordinate = .{},
};

pub const Coordinate = struct {
    x: i64 = 0,
    y: i64 = 0,
};

pub const ImageSize = struct {
    w: i64 = 0,
    h: i64 = 0,
};

pub const ResIDCard = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 微信返回 `"type"`（Front/Back），字段名与之保持一致。
    type: []const u8 = "",
    name: []const u8 = "",
    id: []const u8 = "",
    addr: []const u8 = "",
    gender: []const u8 = "",
    nationality: []const u8 = "",
    valid_date: []const u8 = "",
};

pub const ResBankCard = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    number: []const u8 = "",
};

pub const ResDriving = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    plate_num: []const u8 = "",
    vehicle_type: []const u8 = "",
    owner: []const u8 = "",
    addr: []const u8 = "",
    use_character: []const u8 = "",
    model: []const u8 = "",
    vin: []const u8 = "",
    engine_num: []const u8 = "",
    register_date: []const u8 = "",
    issue_date: []const u8 = "",
    plate_num_b: []const u8 = "",
    record: []const u8 = "",
    passengers_num: []const u8 = "",
    total_quality: []const u8 = "",
    prepare_quality: []const u8 = "",
    overall_size: []const u8 = "",
    img_size: ImageSize = .{},
};

pub const ResDrivingLicense = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    id_num: []const u8 = "",
    name: []const u8 = "",
    sex: []const u8 = "",
    nationality: []const u8 = "",
    address: []const u8 = "",
    birth_date: []const u8 = "",
    issue_date: []const u8 = "",
    car_class: []const u8 = "",
    valid_from: []const u8 = "",
    valid_to: []const u8 = "",
    official_seal: []const u8 = "",
};

pub const ResBizLicense = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    reg_num: []const u8 = "",
    serial: []const u8 = "",
    legal_representative: []const u8 = "",
    enterprise_name: []const u8 = "",
    type_of_organization: []const u8 = "",
    address: []const u8 = "",
    type_of_enterprise: []const u8 = "",
    business_scope: []const u8 = "",
    registered_capital: []const u8 = "",
    paid_in_capital: []const u8 = "",
    valid_period: []const u8 = "",
    registered_date: []const u8 = "",
    img_size: ImageSize = .{},
};

pub const CommonItem = struct {
    pos: Position = .{},
    text: []const u8 = "",
};

pub const ResCommon = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    items: []const CommonItem = &.{},
    img_size: ImageSize = .{},
};

/// OCR 识别模块。
pub const OCR = struct {
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

    /// 身份证 OCR（`img_url` 传原始图片地址，本模块负责转义）。
    pub fn idCard(self: *Self, img_url: []const u8) !std.json.Parsed(ResIDCard) {
        return self.fetch(ResIDCard, "idcard", img_url);
    }

    /// 银行卡 OCR。
    pub fn bankCard(self: *Self, img_url: []const u8) !std.json.Parsed(ResBankCard) {
        return self.fetch(ResBankCard, "bankcard", img_url);
    }

    /// 行驶证 OCR。
    pub fn driving(self: *Self, img_url: []const u8) !std.json.Parsed(ResDriving) {
        return self.fetch(ResDriving, "driving", img_url);
    }

    /// 驾驶证 OCR。
    pub fn drivingLicense(self: *Self, img_url: []const u8) !std.json.Parsed(ResDrivingLicense) {
        return self.fetch(ResDrivingLicense, "drivinglicense", img_url);
    }

    /// 营业执照 OCR。
    pub fn bizLicense(self: *Self, img_url: []const u8) !std.json.Parsed(ResBizLicense) {
        return self.fetch(ResBizLicense, "bizlicense", img_url);
    }

    /// 通用印刷体 OCR。
    pub fn common(self: *Self, img_url: []const u8) !std.json.Parsed(ResCommon) {
        return self.fetch(ResCommon, "comm", img_url);
    }

    fn fetch(self: *Self, comptime T: type, path: []const u8, img_url: []const u8) !std.json.Parsed(T) {
        // img_url 作为 query 参数必须先按 Go `url.QueryEscape` 语义转义：
        // 值里的 `&` / `=` / `?` 否则会被服务端当成参数分隔符，把 img_url 截断
        // （CDN 签名 URL 带 `?sign=...&t=...` 时必现）。
        // 这里刻意不用 `std.Uri.Component.formatQuery`——它的保留集包含
        // `&=?/:`，正是导致截断的原因。
        const encoded = try util_uri.queryEscape(self.allocator, img_url);
        defer self.allocator.free(encoded);

        const Sender = struct {
            ocr: *Self,
            path: []const u8,
            encoded: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/cv/ocr/{s}?img_url={s}&access_token={s}",
                    .{ c.path, c.encoded, token },
                );
                defer allocator.free(uri);
                return c.ocr.post(uri);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, path, Sender{
            .ocr = self,
            .path = path,
            .encoded = encoded,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(T, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    fn post(self: *Self, uri: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.post(uri, "", null);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.post(uri, "", null);
    }
};

test "OCR.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ocr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const o = OCR.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ocr", o.ctx.config.app_id);
}

test "ResIDCard 默认值" {
    const r = ResIDCard{};
    try std.testing.expectEqualStrings("", r.name);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}

// —— mock 测试 ——

const credential = @import("../../credential/mod.zig");

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

test "idCard 解析 type 与未知字段容忍" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    // img_url 按 Go url.QueryEscape 语义转义（`:`→%3A、`/`→%2F）。
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/idcard?img_url=https%3A%2F%2Fexample.com%2Fa.jpg&access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"type\":\"Front\",\"name\":\"张三\",\"id\":\"11010119900307xxxx\",\"new_unknown_field\":42}",
    });

    var ctx = makeCtx();
    var o = OCR.init(&ctx, allocator);
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try o.idCard("https://example.com/a.jpg");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Front", parsed.value.type);
    try std.testing.expectEqualStrings("张三", parsed.value.name);
}

test "driving 解析 img_size 的 w/h 字段" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/driving?img_url=https%3A%2F%2Fexample.com%2Fb.jpg&access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"plate_num\":\"粤B12345\",\"img_size\":{\"w\":800,\"h\":600}}",
    });

    var ctx = makeCtx();
    var o = OCR.init(&ctx, allocator);
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try o.driving("https://example.com/b.jpg");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("粤B12345", parsed.value.plate_num);
    try std.testing.expectEqual(@as(i64, 800), parsed.value.img_size.w);
    try std.testing.expectEqual(@as(i64, 600), parsed.value.img_size.h);
}

test "bizLicense errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/bizlicense?img_url=https%3A%2F%2Fexample.com%2Fc.jpg&access_token=token-abc", .{
        .body = "{\"errcode\":47001,\"errmsg\":\"data format error\"}",
    });

    var ctx = makeCtx();
    var o = OCR.init(&ctx, allocator);
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    try std.testing.expectError(util_error.WechatError.ApiError, o.bizLicense("https://example.com/c.jpg"));
}

test "img_url 含 & 与 ? 时按 Go url.QueryEscape 转义（回归：曾被 formatQuery 截断）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    // 空格 → `+`；`:`→%3A、`/`→%2F、`?`→%3F、`=`→%3D、`&`→%26。
    // 若沿用 std.Uri.Component.formatQuery，`?`/`&`/`=` 会原样进入 query，
    // 服务端会把 `y=2` 当成独立参数、`access_token` 被后续值顶掉。
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/comm?img_url=https%3A%2F%2Fexample.com%2Fa+b%3Fx%3D1%26y%3D2&access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"items\":[],\"img_size\":{\"w\":100,\"h\":50}}",
    });

    var ctx = makeCtx();
    var o = OCR.init(&ctx, allocator);
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try o.common("https://example.com/a b?x=1&y=2");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 100), parsed.value.img_size.w);
    try std.testing.expectEqual(@as(i64, 50), parsed.value.img_size.h);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "idCard token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    // token 位于 img_url 之后，重试后仅该段变化。
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/idcard?img_url=https%3A%2F%2Fexample.com%2Fa.jpg&access_token=token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/cv/ocr/idcard?img_url=https%3A%2F%2Fexample.com%2Fa.jpg&access_token=token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"type\":\"Front\",\"name\":\"张三\"}",
    });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-ocr" },
        .access_token_handle = stub.asHandle(),
    };
    var o = OCR.init(&ctx, allocator);
    o.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try o.idCard("https://example.com/a.jpg");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("张三", parsed.value.name);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cv/ocr/idcard?img_url=https%3A%2F%2Fexample.com%2Fa.jpg&access_token=token-new",
        mt.history.items[1],
    );
}
