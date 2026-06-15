//! officialaccount/draft — 草稿箱（新增 / 删除 / 更新 / 获取 / 获取列表）

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Draft = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 新增草稿（图文列表）。
    pub fn add(self: *Self, articles_json: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/add?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, articles_json);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DraftAdd")) |_| {
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    /// 删除草稿。
    pub fn delete(self: *Self, media_id: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/delete?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"media_id\":\"{s}\"}}", .{media_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DraftDelete")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取草稿列表。
    pub fn list(self: *Self, offset: i64, count: i64, no_content: i64) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/get?access_token={s}",
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

test "Draft.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-draft" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const d = Draft.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-draft", d.ctx.config.app_id);
}