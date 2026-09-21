// SPDX-License-Identifier: Apache-2.0
//! credential/work_js_ticket — 企业微信 JsAPI ticket
//!
//! 对应 `_ref/wechat/credential/work_js_ticket.go`：支持 corp / agent 两种 ticket。
//!
//! - corp ticket:  `https://qyapi.weixin.qq.com/cgi-bin/get_jsapi_ticket?access_token=...`
//! - agent ticket: `https://qyapi.weixin.qq.com/cgi-bin/ticket/get?access_token=...&type=agent_config`
//!
//! 缓存 key 前缀：`{prefix}_corp_jsapi_ticket_{corpid}` / `{prefix}_agent_jsapi_ticket_{corpid}_{agentid}`。
//! 锁范围同 `default_access_token.zig`：SpinMutex 只保护缓存临界区，HTTP 回源在锁外。

const std = @import("std");
const Cache = @import("../cache/mod.zig").Cache;
const util_http = @import("../util/http.zig");
const util_error = @import("../util/error.zig");
const credential = @import("mod.zig");
const SpinMutex = @import("../util/sync.zig").SpinMutex;

/// Ticket 类型（与 Go `TicketType` 对应）。
pub const TicketType = enum {
    corp_js,
    agent_js,
};

/// Ticket 响应结构。
pub const TicketResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    ticket: []const u8 = "",
    expires_in: i64 = 0,
};

/// Fetcher 函数签名（与 DefaultJsTicket 一致）。
pub const Fetcher = credential.Fetcher;

/// 企业微信 JsTicket 句柄。
pub const WorkJsTicket = struct {
    corp_id: []const u8,
    agent_id: []const u8,
    cache_key_prefix: []const u8,
    cache: Cache,
    lock: SpinMutex = .{},
    fetcher: Fetcher,
    fetcher_ctx: *anyopaque,

    const Self = @This();

    /// 默认 fetcher：通过 HTTP 客户端拉取。
    fn defaultFetcher(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) credential.CredentialError![]u8 {
        _ = ctx;
        const client = util_http.getDefaultClient(allocator);
        return client.get(url) catch return credential.CredentialError.HttpError;
    }

    /// 默认构造：使用 `util.http.getDefaultClient().get` 作为后端 fetcher。
    pub fn init(
        corp_id: []const u8,
        agent_id: []const u8,
        cache_key_prefix: []const u8,
        cache: Cache,
    ) WorkJsTicket {
        return .{
            .corp_id = corp_id,
            .agent_id = agent_id,
            .cache_key_prefix = cache_key_prefix,
            .cache = cache,
            .fetcher = defaultFetcher,
            .fetcher_ctx = undefined,
        };
    }

    /// 测试用构造：注入自定义 fetcher。
    pub fn initWithFetcher(
        corp_id: []const u8,
        agent_id: []const u8,
        cache_key_prefix: []const u8,
        cache: Cache,
        fetcher: Fetcher,
        fetcher_ctx: *anyopaque,
    ) WorkJsTicket {
        return .{
            .corp_id = corp_id,
            .agent_id = agent_id,
            .cache_key_prefix = cache_key_prefix,
            .cache = cache,
            .fetcher = fetcher,
            .fetcher_ctx = fetcher_ctx,
        };
    }

    /// 构造缓存 key。
    fn cacheKey(self: *const Self, allocator: std.mem.Allocator, ticket_type: TicketType) credential.CredentialError![]u8 {
        return switch (ticket_type) {
            .corp_js => std.fmt.allocPrint(
                allocator,
                "{s}_corp_jsapi_ticket_{s}",
                .{ self.cache_key_prefix, self.corp_id },
            ),
            .agent_js => blk: {
                if (self.agent_id.len == 0) return credential.CredentialError.ConfigMissing;
                break :blk std.fmt.allocPrint(
                    allocator,
                    "{s}_agent_jsapi_ticket_{s}_{s}",
                    .{ self.cache_key_prefix, self.corp_id, self.agent_id },
                );
            },
        };
    }

    /// 构造 ticket URL。
    fn buildURL(self: *const Self, allocator: std.mem.Allocator, ticket_type: TicketType, access_token: []const u8) credential.CredentialError![]u8 {
        _ = self;
        return switch (ticket_type) {
            .corp_js => std.fmt.allocPrint(
                allocator,
                "https://qyapi.weixin.qq.com/cgi-bin/get_jsapi_ticket?access_token={s}",
                .{access_token},
            ),
            .agent_js => std.fmt.allocPrint(
                allocator,
                "https://qyapi.weixin.qq.com/cgi-bin/ticket/get?access_token={s}&type=agent_config",
                .{access_token},
            ),
        };
    }

    /// 获取 ticket（singleflight 风格：加锁双检缓存 → 锁外回源 →
    /// 重新加锁双检并回写）。并发 miss 允许多个并发回源（幂等 GET，last-write-wins 无害）。
    pub fn getTicket(
        self: *Self,
        allocator: std.mem.Allocator,
        access_token: []const u8,
        ticket_type: TicketType,
    ) credential.CredentialError![]u8 {
        const key = try self.cacheKey(allocator, ticket_type);
        defer allocator.free(key);

        // 1) 先查缓存
        if (try self.cache.get(key)) |val| {
            if (val.len > 0) return allocator.dupe(u8, val);
        }

        // 2) 加锁双检：命中则直接用现成值
        self.lock.lock();
        if (try self.cache.get(key)) |val| {
            if (val.len > 0) {
                self.lock.unlock();
                return allocator.dupe(u8, val);
            }
        }
        self.lock.unlock();

        // 3) 锁外从服务端拉取（自旋锁不跨网络 I/O）
        const url = try self.buildURL(allocator, ticket_type, access_token);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(TicketResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return credential.CredentialError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return credential.CredentialError.ApiError;

        // 4) 重新加锁双检：回源期间可能已被其他线程回写，命中直接用现成的
        self.lock.lock();
        defer self.lock.unlock();
        if (try self.cache.get(key)) |val| {
            if (val.len > 0) return allocator.dupe(u8, val);
        }

        // 5) 写入缓存（TTL 由 `credential.tokenTTL` 计算：expires_in - 1500，极值防溢出）
        try self.cache.set(key, parsed.value.ticket, credential.tokenTTL(parsed.value.expires_in));

        return allocator.dupe(u8, parsed.value.ticket);
    }
};

test "WorkJsTicket.cacheKey corp" {
    const t = WorkJsTicket.init("wxcorp", "", "gowechat_work_", undefined);
    const key = try t.cacheKey(std.testing.allocator, .corp_js);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("gowechat_work__corp_jsapi_ticket_wxcorp", key);
}

test "WorkJsTicket.cacheKey agent" {
    const t = WorkJsTicket.init("wxcorp", "agent1", "gowechat_work_", undefined);
    const key = try t.cacheKey(std.testing.allocator, .agent_js);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("gowechat_work__agent_jsapi_ticket_wxcorp_agent1", key);
}

test "WorkJsTicket.cacheKey agent 无 agent_id 返回 ConfigMissing" {
    const t = WorkJsTicket.init("wxcorp", "", "gowechat_work_", undefined);
    const result = t.cacheKey(std.testing.allocator, .agent_js);
    try std.testing.expectError(credential.CredentialError.ConfigMissing, result);
}

test "WorkJsTicket.buildURL corp 与 agent URL 不同" {
    const t = WorkJsTicket.init("wxcorp", "", "gk_", undefined);
    const url_corp = try t.buildURL(std.testing.allocator, .corp_js, "AT");
    defer std.testing.allocator.free(url_corp);
    try std.testing.expect(std.mem.indexOf(u8, url_corp, "get_jsapi_ticket") != null);

    const t2 = WorkJsTicket.init("wxcorp", "a1", "gk_", undefined);
    const url_agent = try t2.buildURL(std.testing.allocator, .agent_js, "AT");
    defer std.testing.allocator.free(url_agent);
    try std.testing.expect(std.mem.indexOf(u8, url_agent, "/ticket/get") != null);
    try std.testing.expect(std.mem.indexOf(u8, url_agent, "type=agent_config") != null);
}

test "TicketType 枚举值" {
    try std.testing.expectEqualStrings("corp_js", @tagName(TicketType.corp_js));
    try std.testing.expectEqualStrings("agent_js", @tagName(TicketType.agent_js));
}

test "TicketResponse 默认值" {
    const r = TicketResponse{};
    try std.testing.expectEqualStrings("", r.ticket);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}
