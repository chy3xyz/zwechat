//! officialaccount/broadcast — 群发
//!
//! 提供按标签 / 按 openid 列表的群发接口（文本 / 图文 / 语音 / 图片 / 视频 / 卡券）。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Broadcast = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 按标签群发文本消息。
    pub fn sendTextToTag(self: *Self, tag_id: i64, content: []const u8) !i64 {
        return self.sendToTag("text", tag_id, .{ .text = .{ .content = content } });
    }

    /// 按标签群发图文消息（通过 media_id）。
    pub fn sendNewsToTag(self: *Self, tag_id: i64, media_id: []const u8) !i64 {
        return self.sendToTag("mpnews", tag_id, .{ .media_id = media_id });
    }

    pub const SendBody = union(enum) {
        text: struct { content: []const u8 },
        media_id: []const u8,
    };

    fn sendToTag(self: *Self, msgtype: []const u8, tag_id: i64, body: SendBody) !i64 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const content_or_id = switch (body) {
            .text => |t| try std.fmt.allocPrint(self.allocator, "{{\"content\":\"{s}\"}}", .{t.content}),
            .media_id => |m| try std.fmt.allocPrint(self.allocator, "\"media_id\":\"{s}\"", .{m}),
        };
        defer self.allocator.free(content_or_id);

        const json_body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"filter\":{{\"is_to_all\":false,\"tag_id\":{d}}},\"msgtype\":\"{s}\",\"{s}\":{s}}}",
            .{ tag_id, msgtype, msgtype, content_or_id },
        );
        defer self.allocator.free(json_body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, json_body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            msg_id: i64 = 0,
            msg_data_id: i64 = 0,
        }, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value.msg_id;
    }
};

test "Broadcast.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-bc" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const b = Broadcast.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-bc", b.ctx.config.app_id);
}