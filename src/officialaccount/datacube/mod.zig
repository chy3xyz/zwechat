//! officialaccount/datacube — 数据统计
//!
//! 提供公众号用户、消息、接口、图文等维度的统计接口。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const DataCube = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 获取用户增减数据（begin_date / end_date 格式：YYYY-MM-DD）。
    pub fn getUserSummary(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getusersummary", begin_date, end_date);
    }

    pub fn getUserCumulate(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getusercumulate", begin_date, end_date);
    }

    pub fn getArticleSummary(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getarticlesummary", begin_date, end_date);
    }

    pub fn getInterfaceSummary(self: *Self, begin_date: []const u8, end_date: []const u8) ![]u8 {
        return self.fetchJson("getinterfacesummary", begin_date, end_date);
    }

    fn fetchJson(self: *Self, endpoint: []const u8, begin_date: []const u8, end_date: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/datacube/{s}?access_token={s}",
            .{ endpoint, access_token },
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"begin_date\":\"{s}\",\"end_date\":\"{s}\"}}",
            .{ begin_date, end_date },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, endpoint)) |_| {
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }
};

test "DataCube.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-dc" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const dc = DataCube.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-dc", dc.ctx.config.app_id);
}