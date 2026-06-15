//! officialaccount/ocr — OCR（身份证 / 银行卡 / 行驶证 / 驾驶证）

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Ocr = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 身份证 OCR。
    pub fn idCard(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost("cv/ocr/idcard", img_url);
    }

    /// 银行卡 OCR。
    pub fn bankCard(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost("cv/ocr/bankcard", img_url);
    }

    /// 行驶证 OCR。
    pub fn driving(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost("cv/ocr/drivinglicense", img_url);
    }

    /// 驾驶证 OCR。
    pub fn driverLicense(self: *Self, img_url: []const u8) ![]u8 {
        return self.ocrPost("cv/ocr/driving", img_url);
    }

    fn ocrPost(self: *Self, path: []const u8, img_url: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/{s}?access_token={s}",
            .{ path, access_token },
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"img_url\":\"{s}\"}}",
            .{img_url},
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, path)) |_| {
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }
};

test "Ocr.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ocr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const o = Ocr.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ocr", o.ctx.config.app_id);
}