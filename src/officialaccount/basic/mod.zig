//! officialaccount/basic — 基础接口
//!
//! 对应 `_ref/wechat/officialaccount/basic/basic.go`：获取微信服务器 IP 列表 + 清理接口配额。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Basic = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 获取微信 callback IP 列表。
    pub fn getCallbackIP(self: *Self) ![]const []const u8 {
        return self.fetchIPList(getCallbackIPURL, "GetCallbackIP");
    }

    /// 获取 API 域名 IP 列表。
    pub fn getAPIDomainIP(self: *Self) ![]const []const u8 {
        return self.fetchIPList(getAPIDomainIPURL, "GetAPIDomainIP");
    }

    /// 清理接口调用次数（`appid` 维度的配额）。
    pub fn clearQuota(self: *Self) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ clearQuotaURL, access_token });
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"appid\":\"{s}\"}}", .{self.ctx.config.app_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "ClearQuota")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    fn fetchIPList(self: *Self, url_template: []const u8, api_name: []const u8) ![]const []const u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ url_template, access_token });
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(IpListRes, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;

        const result = try self.allocator.alloc([]const u8, parsed.value.ip_list.len);
        for (parsed.value.ip_list, 0..) |ip, i| {
            result[i] = ip;
        }
        _ = api_name;
        return result;
    }
};

pub const IpListRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    ip_list: []const []const u8 = &.{},

    pub fn deinit(self: *IpListRes, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.ip_list));
    }
};

pub const getCallbackIPURL = "https://api.weixin.qq.com/cgi-bin/getcallbackip";
pub const getAPIDomainIPURL = "https://api.weixin.qq.com/cgi-bin/get_api_domain_ip";
pub const clearQuotaURL = "https://api.weixin.qq.com/cgi-bin/clear_quota";

test "Basic.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-b" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const b = Basic.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-b", b.ctx.config.app_id);
}

test "URL 常量值正确" {
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/getcallbackip", getCallbackIPURL);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/clear_quota", clearQuotaURL);
}