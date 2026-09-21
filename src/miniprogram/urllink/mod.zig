// SPDX-License-Identifier: Apache-2.0
//! miniprogram/urllink — 小程序 URL Link
//!
//! 对应 `_ref/wechat/miniprogram/urllink/`：
//! `wxa/generate_urllink` 生成、`wxa/query_urllink` 查询。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 失效类型。
pub const ExpireType = enum(i32) {
    /// 指定时间戳后失效。
    time = 0,
    /// 间隔指定天数后失效。
    interval = 1,
};

/// `generate_urllink` 请求参数。
pub const ULParams = struct {
    path: []const u8,
    query: []const u8 = "",
    /// 打开版本：release / trial / develop。
    env_version: []const u8 = "",
    is_expire: bool = false,
    expire_type: ExpireType = .time,
    expire_time: i64 = 0,
    expire_interval: i64 = 0,
};

/// `query_urllink` 请求参数。
pub const ULQueryRequest = struct {
    url_link: []const u8,
    query_type: i64 = 0,
};

/// `query_urllink` 返回。
pub const ULQueryResult = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    url_link_info: UrlLinkInfo = .{},
    visit_openid: []const u8 = "",
    quota_info: QuotaInfo = .{},
};

pub const UrlLinkInfo = struct {
    appid: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",
    create_time: i64 = 0,
    expire_time: i64 = 0,
    env_version: []const u8 = "",
    cloud_base: CloudBase = .{},
};

pub const CloudBase = struct {
    env: []const u8 = "",
    domain: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",
    resource_appid: []const u8 = "",
};

pub const QuotaInfo = struct {
    remain_visit_quota: i64 = 0,
};

/// 小程序 URL Link 模块。
pub const URLLink = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 生成 URL Link（返回的 link 由调用方负责 `allocator.free`）。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次。
    pub fn generate(self: *Self, params: ULParams) ![]u8 {
        const body = try jsonStringifyULParams(self.allocator, params);
        defer self.allocator.free(body);

        const Sender = struct {
            link: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/generate_urllink?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.link.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "GenerateURL", Sender{ .link = self, .body = body });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            url_link: []const u8 = "",
        }, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.url_link);
    }

    /// 查询 URL Link 配置（返回 `std.json.Parsed(ULQueryResult)`，调用方负责 `deinit`）。
    pub fn query(self: *Self, url_link: []const u8) !std.json.Parsed(ULQueryResult) {
        return self.queryWithType(.{ .url_link = url_link });
    }

    /// 查询加密 URL Link（可指定 query_type）。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次。
    pub fn queryWithType(self: *Self, req: ULQueryRequest) !std.json.Parsed(ULQueryResult) {
        const body = try jsonStringifyULQuery(self.allocator, req);
        defer self.allocator.free(body);

        const Sender = struct {
            link: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/query_urllink?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.link.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "QueryURL", Sender{ .link = self, .body = body });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(ULQueryResult, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

fn jsonStringifyULParams(allocator: std.mem.Allocator, p: ULParams) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("path");
    try s.write(p.path);
    try s.objectField("query");
    try s.write(p.query);
    if (p.env_version.len > 0) {
        try s.objectField("env_version");
        try s.write(p.env_version);
    }
    try s.objectField("is_expire");
    try s.write(p.is_expire);
    try s.objectField("expire_type");
    try s.write(@backingInt(p.expire_type));
    try s.objectField("expire_time");
    try s.write(p.expire_time);
    try s.objectField("expire_interval");
    try s.write(p.expire_interval);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyULQuery(allocator: std.mem.Allocator, q: ULQueryRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("url_link");
    try s.write(q.url_link);
    try s.objectField("query_type");
    try s.write(q.query_type);
    try s.endObject();
    return out.toOwnedSlice();
}

test "URLLink.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ul" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const u = URLLink.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ul", u.ctx.config.app_id);
}

test "ULParams 序列化包含 path 与 is_expire" {
    const allocator = std.testing.allocator;
    const body = try jsonStringifyULParams(allocator, .{ .path = "pages/index" });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"path\":\"pages/index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_expire\":false") != null);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "queryWithType token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/wxa/query_urllink?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"url_link_info\":{\"appid\":\"wx-ul\",\"path\":\"pages/index\"}}",
    });

    // 本模块走线程默认 client，测试直接把 MockTransport 挂在它上面。
    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-ul" },
        .access_token_handle = stub.asHandle(),
    };
    var u = URLLink.init(&ctx, allocator);

    var parsed = try u.queryWithType(.{ .url_link = "https://wxaurl.cn/xyz" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("pages/index", parsed.value.url_link_info.path);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
