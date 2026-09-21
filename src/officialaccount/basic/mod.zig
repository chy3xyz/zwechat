// SPDX-License-Identifier: Apache-2.0
//! officialaccount/basic — 基础接口
//!
//! 对应 `_ref/wechat/officialaccount/basic/basic.go`：获取微信服务器 IP 列表 + 清理接口配额。

const std = @import("std");
const Context = @import("../context.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// IP 列表结果（`getCallbackIP` / `getAPIDomainIP` 的返回类型）。
///
/// 所有权：`items` 外层数组与每个元素均由本次调用分配，
/// 调用方负责调用 `deinit` 一次性释放。
pub const IpList = struct {
    items: [][]u8,

    pub fn deinit(self: IpList, allocator: std.mem.Allocator) void {
        for (self.items) |ip| allocator.free(ip);
        allocator.free(self.items);
    }
};

pub const Basic = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 获取微信 callback IP 列表。
    /// 返回的 `IpList` 由调用方负责 `deinit`。
    pub fn getCallbackIP(self: *Self) !IpList {
        return self.fetchIPList(getCallbackIPURL);
    }

    /// 获取 API 域名 IP 列表。
    /// 返回的 `IpList` 由调用方负责 `deinit`。
    pub fn getAPIDomainIP(self: *Self) !IpList {
        return self.fetchIPList(getAPIDomainIPURL);
    }

    /// 清理接口调用次数（`appid` 维度的配额）。
    pub fn clearQuota(self: *Self) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ clearQuotaURL, access_token });
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"appid\":\"{s}\"}}", .{self.ctx.config.app_id});
        defer self.allocator.free(body);

        const resp = try self.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "ClearQuota")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    fn fetchIPList(self: *Self, url_template: []const u8) !IpList {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ url_template, access_token });
        defer self.allocator.free(uri);

        const body = try self.httpGet(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(IpListRes, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;

        // 深拷贝每个 IP：parsed 内的切片借用 `body`，函数返回后 `body` 即被释放，
        // 直接返回内部切片会造成悬垂指针（UAF）。
        const items = try self.allocator.alloc([]u8, parsed.value.ip_list.len);
        errdefer self.allocator.free(items);
        for (parsed.value.ip_list, 0..) |ip, i| {
            items[i] = try self.allocator.dupe(u8, ip);
        }
        return .{ .items = items };
    }

    fn httpGet(self: *Self, uri: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.get(uri);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.get(uri);
    }

    fn postJSON(self: *Self, uri: []const u8, payload: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, payload);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, payload);
    }
};

pub const IpListRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    ip_list: []const []const u8 = &.{},
};

pub const getCallbackIPURL = "https://api.weixin.qq.com/cgi-bin/getcallbackip";
pub const getAPIDomainIPURL = "https://api.weixin.qq.com/cgi-bin/get_api_domain_ip";
pub const clearQuotaURL = "https://api.weixin.qq.com/cgi-bin/clear_quota";

// —— 测试 ——

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-b" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

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

test "getCallbackIP 返回深拷贝 IP 列表（UAF 回归）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/getcallbackip?access_token=token-abc", .{
        .body = "{\"ip_list\":[\"101.226.103.0/25\",\"101.226.62.0/25\"]}",
    });

    var ctx = makeCtx();
    var b = Basic.init(&ctx, allocator);
    b.setTransport(util_http.MockTransport.dispatch, &mt);

    var list = try b.getCallbackIP();
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("101.226.103.0/25", list.items[0]);
    try std.testing.expectEqualStrings("101.226.62.0/25", list.items[1]);
}

test "getAPIDomainIP 解析正常" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/get_api_domain_ip?access_token=token-abc", .{
        .body = "{\"ip_list\":[\"1.2.3.4\"]}",
    });

    var ctx = makeCtx();
    var b = Basic.init(&ctx, allocator);
    b.setTransport(util_http.MockTransport.dispatch, &mt);

    var list = try b.getAPIDomainIP();
    defer list.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("1.2.3.4", list.items[0]);
}

test "getCallbackIP errcode != 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/getcallbackip?access_token=token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });

    var ctx = makeCtx();
    var b = Basic.init(&ctx, allocator);
    b.setTransport(util_http.MockTransport.dispatch, &mt);

    try std.testing.expectError(util_error.WechatError.ApiError, b.getCallbackIP());
}

test "clearQuota 请求体携带 appid 且成功时无错误" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/clear_quota?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    var ctx = makeCtx();
    var b = Basic.init(&ctx, allocator);
    b.setTransport(util_http.MockTransport.dispatch, &mt);

    try b.clearQuota();
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}
