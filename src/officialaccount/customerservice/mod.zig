//! officialaccount/customerservice — 客服管理

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const CustomerService = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 添加客服账号。
    pub fn addAccount(self: *Self, account: []const u8, nickname: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/customservice/kfaccount/add?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"kf_account\":\"{s}\",\"nickname\":\"{s}\"}}",
            .{ account, nickname },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "AddAccount")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取所有客服账号列表。
    pub fn listAccounts(self: *Self) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/customservice/getkflist?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        return body;
    }
};

test "CustomerService.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const cs = CustomerService.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-cs", cs.ctx.config.app_id);
}