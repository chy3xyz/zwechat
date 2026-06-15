//! officialaccount/freepublish — 发布能力（发布 / 撤回 / 获取 / 获取列表）

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const PublishStatus = enum(i32) {
    success = 0,
    publishing = 1,
    original_publish_failed = 2,
    partial_failed = 3,
    failed = 4,
};

pub const FreePublish = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 发布草稿。
    pub fn publish(self: *Self, media_id: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/freepublish/submit?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"media_id\":\"{s}\"}}", .{media_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "FreePublishSubmit")) |_| {
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    /// 撤回发布。
    pub fn delete(self: *Self, article_id: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/freepublish/delete?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"article_id\":\"{s}\"}}", .{article_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "FreePublishDelete")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取发布列表。
    pub fn list(self: *Self, offset: i64, count: i64, no_content: i64) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/freepublish/get?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"offset\":{d},\"count\":{d},\"no_content\":{d}}}",
            .{ offset, count, no_content },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body);
    }
};

test "FreePublish.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-fp" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const fp = FreePublish.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-fp", fp.ctx.config.app_id);
}

test "PublishStatus 枚举值" {
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(PublishStatus.success));
    try std.testing.expectEqual(@as(i32, 4), @intFromEnum(PublishStatus.failed));
}