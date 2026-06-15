//! miniprogram/qrcode — 小程序码（无数量限制）
//!
//! 对应 `_ref/wechat/miniprogram/qrcode/qrcode.go`：
//! `wxa/getwxacodeunlimit` 获取小程序码（永久有效，数量暂无限制）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");

/// 小程序码模块。
pub const QRCode = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 获取小程序码（无数量限制）。
    ///
    /// - `scene`：最大 32 个可见字符，必填。
    /// - `page`：默认首页；可传 `null`。
    /// - `width`：二维码宽度，默认 430。
    ///
    /// 返回图片二进制切片，调用方负责 `allocator.free`。
    pub fn getUnlimited(
        self: *Self,
        scene: []const u8,
        page: ?[]const u8,
        width: u32,
    ) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/getwxacodeunlimit?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body_json = if (page) |p|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"scene\":\"{s}\",\"page\":\"{s}\",\"width\":{d}}}",
                .{ scene, p, width },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"scene\":\"{s}\",\"width\":{d}}}",
                .{ scene, width },
            );
        defer self.allocator.free(body_json);

        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body_json);
    }
};

test "QRCode.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-qr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const q = QRCode.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-qr", q.ctx.config.app_id);
}
