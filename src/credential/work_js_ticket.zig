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

    /// 作废指定类型的缓存 ticket：删除对应缓存 key，使下一次 `getTicket` 必须回源。
    ///
    /// - `.corp_js`  → `"{prefix}_corp_jsapi_ticket_{corpid}"`
    /// - `.agent_js` → `"{prefix}_agent_jsapi_ticket_{corpid}_{agentid}"`
    ///   （`agent_id` 为空时返回 `CredentialError.ConfigMissing`，与 `getTicket` 一致）
    ///
    /// 本实例可能同时持有 corp / agent 两个 key（agent key 还要叠加 `agent_id`），
    /// 但两种 ticket 由微信分别签发、有效期互不相关，因此按类型精确作废：
    /// 只作废当前使用的那一种，另一种仍可继续命中缓存。需要两者一起清掉时用
    /// `invalidateAll`。锁范围与 `getTicket` 的缓存临界区一致，键不存在不视为错误
    /// （`cache.delete` 契约）。
    pub fn invalidate(
        self: *Self,
        allocator: std.mem.Allocator,
        ticket_type: TicketType,
    ) credential.CredentialError!void {
        const key = try self.cacheKey(allocator, ticket_type);
        defer allocator.free(key);

        self.lock.lock();
        defer self.lock.unlock();
        try self.cache.delete(key);
    }

    /// 一次作废本实例可能用到的**两个**缓存 key（corp + agent）。
    ///
    /// `agent_id` 为空时跳过 agent key（`cacheKey` 会返回 `ConfigMissing`），
    /// 只清 corp；corp key 的删除错误照常上抛。适合「凭据整体变更 / 需要强制
    /// 全量回源」的场景。
    pub fn invalidateAll(self: *Self, allocator: std.mem.Allocator) credential.CredentialError!void {
        try self.invalidate(allocator, .corp_js);
        if (self.agent_id.len == 0) return;
        try self.invalidate(allocator, .agent_js);
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

// ──────────────────────────────────────────────────────────────────────────────
// invalidate：缓存写入 → 作废 → 下次 getTicket 重新回源（corp / agent 两个 key）
// ──────────────────────────────────────────────────────────────────────────────

/// Stub fetcher 上下文：计数 + 保存最后一次 URL 的深拷贝（避免悬垂；
/// 多次回源时先释放上一份副本，防止桩自身泄漏）。
const StubFetcherCtx = struct {
    response: []const u8,
    called_count: usize = 0,
    last_url: []const u8 = "",
};

fn stubFetcher(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) credential.CredentialError![]u8 {
    const self: *StubFetcherCtx = @ptrCast(@alignCast(ctx));
    const url_dup = try allocator.dupe(u8, url);
    if (self.last_url.len > 0) allocator.free(@constCast(self.last_url));
    self.called_count += 1;
    self.last_url = url_dup;
    return allocator.dupe(u8, self.response);
}

fn makeMemoryCache(allocator: std.mem.Allocator) struct {
    mem: *@import("../cache/mod.zig").Memory,
    cache: Cache,
} {
    const Memory = @import("../cache/mod.zig").Memory;
    const mem = Memory.create(allocator) catch @panic("Memory.create failed");
    return .{ .mem = mem, .cache = mem.asCache() };
}

test "WorkJsTicket: invalidate 按类型作废，corp / agent 两个 key 都覆盖且互不影响" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"work_ticket_v1\",\"expires_in\":7200}",
    };
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    var t = WorkJsTicket.initWithFetcher(
        "ww-invalidate",
        "agent1",
        "gowechat_work_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    // 作废用的 key 必须与 getTicket 真正写入的一致。
    const corp_key = try t.cacheKey(allocator, .corp_js);
    defer allocator.free(corp_key);
    try std.testing.expectEqualStrings("gowechat_work__corp_jsapi_ticket_ww-invalidate", corp_key);

    const agent_key = try t.cacheKey(allocator, .agent_js);
    defer allocator.free(agent_key);
    try std.testing.expectEqualStrings("gowechat_work__agent_jsapi_ticket_ww-invalidate_agent1", agent_key);

    // 1) 两类 ticket 各回源一次，分别写入各自的 key
    const corp = try t.getTicket(allocator, "ak", .corp_js);
    defer allocator.free(corp);
    const agent = try t.getTicket(allocator, "ak", .agent_js);
    defer allocator.free(agent);
    try std.testing.expectEqualStrings("work_ticket_v1", corp);
    try std.testing.expectEqualStrings("work_ticket_v1", agent);
    try std.testing.expectEqual(@as(usize, 2), stub_ctx.called_count);
    try std.testing.expect((try ctx.cache.get(corp_key)) != null);
    try std.testing.expect((try ctx.cache.get(agent_key)) != null);

    // 2) 两者都命中缓存：不再回源
    const corp_cached = try t.getTicket(allocator, "ak", .corp_js);
    defer allocator.free(corp_cached);
    const agent_cached = try t.getTicket(allocator, "ak", .agent_js);
    defer allocator.free(agent_cached);
    try std.testing.expectEqual(@as(usize, 2), stub_ctx.called_count);

    // 3) 只作废 corp：agent 条目必须原样保留
    try t.invalidate(allocator, .corp_js);
    try std.testing.expect((try ctx.cache.get(corp_key)) == null);
    try std.testing.expect((try ctx.cache.get(agent_key)) != null);

    // 4) corp 再取必须重新回源，agent 仍是缓存命中
    const corp_refreshed = try t.getTicket(allocator, "ak", .corp_js);
    defer allocator.free(corp_refreshed);
    try std.testing.expectEqual(@as(usize, 3), stub_ctx.called_count);
    const agent_still_cached = try t.getTicket(allocator, "ak", .agent_js);
    defer allocator.free(agent_still_cached);
    try std.testing.expectEqual(@as(usize, 3), stub_ctx.called_count);

    // 5) 只作废 agent：corp 条目保留
    try t.invalidate(allocator, .agent_js);
    try std.testing.expect((try ctx.cache.get(agent_key)) == null);
    try std.testing.expect((try ctx.cache.get(corp_key)) != null);

    // 6) invalidateAll 一次清掉两个 key，且可重复调用（键不存在不报错）
    try t.invalidateAll(allocator);
    try std.testing.expect((try ctx.cache.get(corp_key)) == null);
    try std.testing.expect((try ctx.cache.get(agent_key)) == null);
    try t.invalidateAll(allocator);
}

test "WorkJsTicket: agent_id 为空时 invalidate(.agent_js) 报 ConfigMissing，invalidateAll 只清 corp" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"corp_only_ticket\",\"expires_in\":7200}",
    };
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    var t = WorkJsTicket.initWithFetcher(
        "ww-corp-only",
        "",
        "gowechat_work_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const corp_key = try t.cacheKey(allocator, .corp_js);
    defer allocator.free(corp_key);

    const corp = try t.getTicket(allocator, "ak", .corp_js);
    defer allocator.free(corp);
    try std.testing.expect((try ctx.cache.get(corp_key)) != null);

    // agent key 无法构造（缺少 agent_id），作废请求按配置错误上报。
    try std.testing.expectError(
        credential.CredentialError.ConfigMissing,
        t.invalidate(allocator, .agent_js),
    );

    // invalidateAll 跳过 agent key，只清 corp，且不报错。
    try t.invalidateAll(allocator);
    try std.testing.expect((try ctx.cache.get(corp_key)) == null);
    try t.invalidateAll(allocator);
}
