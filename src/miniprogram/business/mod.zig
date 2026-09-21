// SPDX-License-Identifier: Apache-2.0
//! miniprogram/business — 业务接口
//!
//! 对应 `_ref/wechat/miniprogram/business/`：`wxa/business/getuserphonenumber`
//! 通过 code 换取用户手机号（与 `auth.getPhoneNumber` 同一接口，保留以对齐上游）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 获取手机号请求。
pub const GetPhoneNumberRequest = struct {
    code: []const u8,
};

/// 手机号信息（字段名与微信返回的 camelCase JSON 一致）。
pub const PhoneInfo = struct {
    phoneNumber: []const u8 = "",
    purePhoneNumber: []const u8 = "",
    countryCode: []const u8 = "",
    watermark: Watermark = .{},
};

pub const Watermark = struct {
    appid: []const u8 = "",
    timestamp: i64 = 0,
};

const GetPhoneNumberResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    phone_info: PhoneInfo = .{},
};

/// 业务模块。
pub const Business = struct {
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

    /// code 换取用户手机号（返回 `std.json.Parsed(PhoneInfo)`，调用方负责 `deinit`）。
    ///
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次。
    pub fn getPhoneNumber(self: *Self, req: GetPhoneNumberRequest) !std.json.Parsed(PhoneInfo) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"code\":\"{s}\"}}", .{req.code});
        defer self.allocator.free(body);

        const Sender = struct {
            business: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                if (c.business.transport) |t| {
                    var client = util_http.HttpClient.init(c.business.allocator);
                    defer client.deinit();
                    client.setTransport(t, c.business.transport_ctx);
                    return client.postJSON(uri, c.body);
                }
                const client = util_http.getDefaultClient(c.business.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "BusinessGetPhoneNumber", Sender{
            .business = self,
            .body = body,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetPhoneNumberResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        // 把 arena 所有权随 phone_info 转移给调用方（Parsed(PhoneInfo)）。
        return .{ .arena = parsed.arena, .value = parsed.value.phone_info };
    }
};

test "Business.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-biz" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const b = Business.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-biz", b.ctx.config.app_id);
}

// —— mock 测试 ——

const retry_testing = @import("../retry_testing.zig");

test "getPhoneNumber 解析 camelCase phone_info" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"phone_info\":{\"phoneNumber\":\"13800001111\",\"purePhoneNumber\":\"13800001111\",\"countryCode\":\"86\",\"watermark\":{\"appid\":\"wx-biz\"}}}",
    });

    var stub = retry_testing.StubToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-biz" },
        .access_token_handle = .{ .ptr = @ptrCast(&stub), .vtable = &retry_testing.StubToken.vtable },
    };
    var b = Business.init(&ctx, allocator);
    b.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try b.getPhoneNumber(.{ .code = "code-xyz" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("13800001111", parsed.value.phoneNumber);
    try std.testing.expectEqualStrings("wx-biz", parsed.value.watermark.appid);
}

test "getPhoneNumber token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"phone_info\":{\"phoneNumber\":\"13800002222\"}}",
    });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-biz" },
        .access_token_handle = stub.asHandle(),
    };
    var b = Business.init(&ctx, allocator);
    b.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try b.getPhoneNumber(.{ .code = "code-xyz" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("13800002222", parsed.value.phoneNumber);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
