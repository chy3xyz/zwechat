// SPDX-License-Identifier: Apache-2.0
//! officialaccount/basic — 基础接口
//!
//! 对应 `_ref/wechat/officialaccount/basic/basic.go`：获取微信服务器 IP 列表 + 清理接口配额。

const std = @import("std");
const Context = @import("../context.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_json = @import("../../util/json.zig");

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
        return self.fetchIPList(getCallbackIPURL, "GetCallbackIP");
    }

    /// 获取 API 域名 IP 列表。
    /// 返回的 `IpList` 由调用方负责 `deinit`。
    pub fn getAPIDomainIP(self: *Self) !IpList {
        return self.fetchIPList(getAPIDomainIPURL, "GetAPIDomainIP");
    }

    /// 清理接口调用次数（`appid` 维度的配额）。
    pub fn clearQuota(self: *Self) !void {
        const payload = try util_json.stringFieldObject(self.allocator, "appid", self.ctx.config.app_id);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "ClearQuota", TokenReq{
            .mod = self,
            .url = clearQuotaURL,
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    fn fetchIPList(self: *Self, url_template: []const u8, api_name: []const u8) !IpList {
        const body = try util_retry.callApi(self.ctx, self.allocator, api_name, TokenReq{
            .mod = self,
            .url = url_template,
        });
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(IpListRes, self.allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。

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

/// 单次带 token 调用的请求构造器：交给 `util/retry.callApi` 复用模块自己的
/// transport 注入逻辑（`payload` 为 null 时走 GET）。`send` 必须 `pub`（跨文件调用）。
const TokenReq = struct {
    mod: *Basic,
    url: []const u8,
    payload: ?[]const u8 = null,

    pub fn send(self: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const uri = try std.fmt.allocPrint(allocator, "{s}?access_token={s}", .{ self.url, token });
        defer allocator.free(uri);
        if (self.payload) |p| return self.mod.postJSON(uri, p);
        return self.mod.httpGet(uri);
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

// —— token 失效自愈 / 非 token 错误不重试 ——

/// 可作废的假凭据：作废前发 `token-abc`，作废后发 `token-new`（模拟微信换发新 token）。
const HealToken = struct {
    cached: []const u8 = "token-abc",
    invalidates: usize = 0,

    fn getToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.cached);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        self.invalidates += 1;
        self.cached = "token-new";
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

/// 按调用次序返回响应、并记录每次请求 URI 的 transport。
const SeqResp = struct {
    responses: []const []const u8,
    calls: usize = 0,
    uris: [4][160]u8 = @splat(@splat(0)),
    uri_lens: [4]usize = @splat(0),

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = method;
        _ = payload;
        _ = content_type;
        const self: *SeqResp = @ptrCast(@alignCast(ctx));
        if (self.calls < self.uris.len and uri.len <= self.uris[0].len) {
            @memcpy(self.uris[self.calls][0..uri.len], uri);
            self.uri_lens[self.calls] = uri.len;
        }
        const idx = @min(self.calls, self.responses.len - 1);
        self.calls += 1;
        return allocator.dupe(u8, self.responses[idx]);
    }

    fn uriAt(self: *const SeqResp, idx: usize) []const u8 {
        return self.uris[idx][0..self.uri_lens[idx]];
    }
};

test "getCallbackIP 40001 自愈：作废缓存 → 换新 token 重试一次并成功" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"ip_list\":[\"1.2.3.4\"]}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-b" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var b = Basic.init(&ctx, allocator);
    b.setTransport(SeqResp.dispatch, &stub);

    var list = try b.getCallbackIP();
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("1.2.3.4", list.items[0]);
    // 第一次用旧 token，重试必须用作废后换发的新 token。
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/getcallbackip?access_token=token-abc",
        stub.uriAt(0),
    );
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/getcallbackip?access_token=token-new",
        stub.uriAt(1),
    );
}

test "clearQuota 40001 自愈：重试后成功且第二次请求带新 token" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"errcode\":0,\"errmsg\":\"ok\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-b" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var b = Basic.init(&ctx, allocator);
    b.setTransport(SeqResp.dispatch, &stub);

    try b.clearQuota();

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/clear_quota?access_token=token-new",
        stub.uriAt(1),
    );
}

test "getCallbackIP 非 token 错误（45009）不重试也不作废" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-b" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var b = Basic.init(&ctx, allocator);
    b.setTransport(SeqResp.dispatch, &stub);

    try std.testing.expectError(util_error.WechatError.ApiError, b.getCallbackIP());

    try std.testing.expectEqual(@as(usize, 0), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
}
