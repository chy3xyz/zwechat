// SPDX-License-Identifier: Apache-2.0
//! miniprogram/business — 业务接口
//!
//! 对应 `_ref/wechat/miniprogram/business/`：`wxa/business/getuserphonenumber`
//! 通过 code 换取用户手机号（与 `auth.getPhoneNumber` 同一接口，保留以对齐上游）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

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

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// code 换取用户手机号（返回 `std.json.Parsed(PhoneInfo)`，调用方负责 `deinit`）。
    pub fn getPhoneNumber(self: *Self, req: GetPhoneNumberRequest) !std.json.Parsed(PhoneInfo) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"code\":\"{s}\"}}", .{req.code});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
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
