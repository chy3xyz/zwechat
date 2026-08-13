// SPDX-License-Identifier: Apache-2.0
//! miniprogram/content — 内容安全（旧接口）
//!
//! 对应 `_ref/wechat/miniprogram/content/content.go`：`msg_sec_check` / `img_sec_check`。
//! 注意：微信已推荐使用 `security.MsgSecCheck` / `security.ImgSecCheck`（返回值更丰富），
//! 本模块保留旧接口以对齐上游参考实现。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 内容安全模块（旧接口）。
pub const Content = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 检测文字内容。
    pub fn checkText(self: *Self, text: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/msg_sec_check?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("content");
        try s.write(text);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "ContentCheckText")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 检测图片内容（`media` 为图片文件绝对路径）。
    pub fn checkImage(self: *Self, media: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/img_sec_check?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const fields = [_]util_http.MultipartField{
            .{
                .is_file = true,
                .field_name = "media",
                .filename = "media",
                .value = "",
                .file_path = media,
            },
        };
        const resp = try client.postMultipart(uri, &fields);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "ContentCheckImage")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }
};

test "Content.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ct" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const c = Content.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ct", c.ctx.config.app_id);
}
