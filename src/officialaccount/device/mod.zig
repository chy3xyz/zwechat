//! officialaccount/device — 智能设备

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Device = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 主动发送设备消息（transmsg 转发）。
    pub fn transMsg(self: *Self, device_type: []const u8, device_id: []const u8, content: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/device/transmsg?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"device_type\":\"{s}\",\"device_id\":\"{s}\",\"content\":\"{s}\"}}",
            .{ device_type, device_id, content },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "TransMsg")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取设备二维码（device_id + device_type → qrcode_ticket）。
    pub fn createQRCode(self: *Self, device_ids: []const []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/device/create_qrcode?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"device_num\":");
        try buf.print(self.allocator, "{d}", .{device_ids.len});
        try buf.appendSlice(self.allocator, ",\"device_id_list\":[");
        for (device_ids, 0..) |id, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try buf.print(self.allocator, "\"{s}\"", .{id});
        }
        try buf.append(self.allocator, ']');
        try buf.append(self.allocator, '}');
        const body = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "CreateQRCode")) |_| {
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }
};

test "Device.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-d" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const d = Device.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-d", d.ctx.config.app_id);
}