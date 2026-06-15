//! credential/work_js_ticket — 企业微信 JsAPI ticket
//!
//! 对应 `_ref/wechat/credential/work_js_ticket.go`：支持 corp / agent 两种 ticket。
//!
//! - corp ticket:  `https://qyapi.weixin.qq.com/cgi-bin/get_jsapi_ticket?access_token=...`
//! - agent ticket: `https://qyapi.weixin.qq.com/cgi-bin/ticket/get?access_token=...&type=agent_config`
//!
//! 缓存 key 前缀：`{prefix}_corp_jsapi_ticket_{corpid}` / `{prefix}_agent_jsapi_ticket_{corpid}_{agentid}`。

const std = @import("std");
const Cache = @import("../cache/mod.zig").Cache;
const util_http = @import("../util/http.zig");
const util_error = @import("../util/error.zig");
const credential = @import("mod.zig");

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

    /// 自旋锁（与 default_js_ticket 一致；Zig 0.17 移除了 std.Thread.Mutex）。
    const SpinMutex = struct {
        state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        const UNLOCKED: u8 = 0;
        const LOCKED: u8 = 1;

        fn lock(self: *SpinMutex) void {
            while (self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
        }

        fn unlock(self: *SpinMutex) void {
            self.state.store(UNLOCKED, .release);
        }
    };

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

    /// 获取 ticket（双检 + 缓存 + fetcher）。
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

        // 2) 上锁 + 双检
        self.lock.lock();
        defer self.lock.unlock();

        if (try self.cache.get(key)) |val| {
            if (val.len > 0) return allocator.dupe(u8, val);
        }

        // 3) 从服务端拉取
        const url = try self.buildURL(allocator, ticket_type, access_token);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(TicketResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return credential.CredentialError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return credential.CredentialError.ApiError;

        // 4) 写入缓存
        const ttl = parsed.value.expires_in - 1500;
        try self.cache.set(key, parsed.value.ticket, ttl);

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