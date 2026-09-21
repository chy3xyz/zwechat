// SPDX-License-Identifier: Apache-2.0
//! credential/js_ticket — 默认 jsapi_ticket 获取器
//!
//! 对应 `_ref/wechat/credential/default_js_ticket.go`：先从缓存中取，
//! 没有则从微信服务器拉取，并缓存；线程安全（自旋锁 + 双检）。
//!
//! **singleflight 风格锁范围**：SpinMutex 只保护缓存读/写临界区，HTTP 回源在锁外执行；
//! 极端并发 miss 时允许多个并发回源（幂等 GET，last-write-wins 无害），
//! 避免其他线程在锁上空转烧 CPU。
//!
//! 缓存 key：`"{prefix}_jsapi_ticket_{app_id}"`（与 Go 一致）。
//! 缓存 TTL：`expires_in - 1500` 秒。

const std = @import("std");

const cache_mod = @import("../cache/mod.zig");
const Cache = cache_mod.Cache;

const http = @import("../util/http.zig");

const mod_zig = @import("mod.zig");
const JsTicketHandle = mod_zig.JsTicketHandle;
const CredentialError = mod_zig.CredentialError;
const Fetcher = mod_zig.Fetcher;
const SpinMutex = @import("../util/sync.zig").SpinMutex;
const tokenTTL = mod_zig.tokenTTL;

/// jsapi_ticket 接口 URL 模板（与 Go `getTicketURL` 一致）。
/// 真实 URL：`https://api.weixin.qq.com/cgi-bin/ticket/getticket?access_token={ak}&type=jsapi`
pub const getTicketURLTemplate =
    "https://api.weixin.qq.com/cgi-bin/ticket/getticket?access_token={s}&type=jsapi";

/// 默认 fetcher：通过线程局部的 `util.http.getDefaultClient` 拉取。
fn defaultFetcher(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) CredentialError![]u8 {
    _ = ctx;
    const client = http.getDefaultClient(allocator);
    return client.get(url) catch return CredentialError.HttpError;
}

/// 自旋锁实现统一取自 `util/sync.zig`（与 `default_access_token.zig` 保持一致）。
/// 默认 `jsapi_ticket` 实现（对应 Go 的 `DefaultJsTicket`）。
pub const DefaultJsTicket = struct {
    app_id: []const u8,
    cache_key_prefix: []const u8,
    cache: Cache,
    lock: SpinMutex = .{},
    fetcher: Fetcher,
    fetcher_ctx: *anyopaque,

    /// 默认构造：使用 `util.http.getDefaultClient().get` 作为后端 fetcher。
    pub fn init(
        app_id: []const u8,
        cache_key_prefix: []const u8,
        cache: Cache,
    ) DefaultJsTicket {
        return .{
            .app_id = app_id,
            .cache_key_prefix = cache_key_prefix,
            .cache = cache,
            .fetcher = defaultFetcher,
            .fetcher_ctx = undefined,
        };
    }

    /// 测试用构造：注入自定义 fetcher。
    pub fn initWithFetcher(
        app_id: []const u8,
        cache_key_prefix: []const u8,
        cache: Cache,
        fetcher: Fetcher,
        fetcher_ctx: *anyopaque,
    ) DefaultJsTicket {
        return .{
            .app_id = app_id,
            .cache_key_prefix = cache_key_prefix,
            .cache = cache,
            .fetcher = fetcher,
            .fetcher_ctx = fetcher_ctx,
        };
    }

    /// 构造 jsapi_ticket 接口 URL。
    pub fn buildURL(
        self: *const DefaultJsTicket,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) CredentialError![]u8 {
        _ = self; // 当前 URL 模板不依赖 app_id，预留对齐 `DefaultAccessToken.buildURL`。
        return std.fmt.allocPrint(
            allocator,
            getTicketURLTemplate,
            .{access_token},
        );
    }

    /// 构造 cache key：`"{prefix}_jsapi_ticket_{app_id}"`。
    pub fn cacheKey(self: *const DefaultJsTicket, allocator: std.mem.Allocator) CredentialError![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}_jsapi_ticket_{s}",
            .{ self.cache_key_prefix, self.app_id },
        );
    }

    /// 微信 `/cgi-bin/ticket/getticket` 接口返回的 JSON 结构。
    /// 所有字段都允许缺失：成功响应有 ticket/expires_in，失败响应只有 errcode/errmsg。
    const TicketResponse = struct {
        ticket: []const u8 = "",
        expires_in: i64 = 0,
        errcode: i64 = 0,
        errmsg: []const u8 = "",
    };

    /// 获取 jsapi_ticket，先缓存后服务端。
    ///
    /// 流程与 `DefaultAccessToken.getAccessToken` 一致（singleflight 风格，HTTP 回源在锁外），
    /// 区别仅在于：
    /// - 拉取前需要传入 `access_token`。
    /// - 响应字段名为 `ticket`（而非 `access_token`）。
    pub fn getTicket(
        self: *DefaultJsTicket,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) CredentialError![]u8 {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        // 1) 缓存快速路径
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
        const url = try self.buildURL(allocator, access_token);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(TicketResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return CredentialError.DecodeError;
        };
        defer parsed.deinit();

        const resp = parsed.value;
        if (resp.errcode != 0) return CredentialError.ApiError;

        // 4) 重新加锁双检：回源期间可能已被其他线程回写，命中直接用现成的
        self.lock.lock();
        defer self.lock.unlock();
        if (try self.cache.get(key)) |val| {
            if (val.len > 0) return allocator.dupe(u8, val);
        }

        // 5) 写入缓存（TTL 由 `tokenTTL` 计算：expires_in - 1500，极值防溢出）
        try self.cache.set(key, resp.ticket, tokenTTL(resp.expires_in));

        return allocator.dupe(u8, resp.ticket);
    }

    /// 作废缓存的 jsapi_ticket：删除缓存条目，使下一次 `getTicket` 必须回源。
    ///
    /// 本实现不额外持有 ticket 副本（唯一副本就在 cache 里），删除缓存即作废完成；
    /// 删除的 key 与 `getTicket` 使用的完全一致（`"{prefix}_jsapi_ticket_{app_id}"`），
    /// 锁范围与 `getTicket` 的缓存临界区一致，与并发 `set` / `delete` 互斥。
    /// 键不存在不视为错误（`cache.delete` 契约）。
    ///
    /// 用途：ticket 会随 access_token 失效而一起失效，`JsTicketHandle.invalidateTicket`
    /// （如 `work/context/mod.zig` 的 `Context.invalidateJsTicket`）在识别到失效后调用本方法。
    pub fn invalidate(self: *DefaultJsTicket, allocator: std.mem.Allocator) CredentialError!void {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        self.lock.lock();
        defer self.lock.unlock();
        try self.cache.delete(key);
    }

    /// 包装为抽象接口 `JsTicketHandle`。
    pub fn asHandle(self: *DefaultJsTicket) JsTicketHandle {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_instance,
        };
    }

    /// vtable 单例：所有 `DefaultJsTicket` 实例共用。
    const vtable_instance = JsTicketHandle.VTable{
        .getTicket = handleGetTicket,
        .invalidate = handleInvalidate,
    };

    fn handleGetTicket(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) anyerror![]u8 {
        const self: *DefaultJsTicket = @ptrCast(@alignCast(ctx));
        return self.getTicket(allocator, access_token);
    }

    fn handleInvalidate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DefaultJsTicket = @ptrCast(@alignCast(ctx));
        return self.invalidate(allocator);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 内联测试（使用真实的 `cache.Memory`）
// ──────────────────────────────────────────────────────────────────────────────

const StubFetcherCtx = struct {
    response: []const u8,
    called_count: usize = 0,
    last_url: ?[]const u8 = null,
};

fn stubFetcher(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) CredentialError![]u8 {
    const self: *StubFetcherCtx = @ptrCast(@alignCast(ctx));
    // 注意：调用方在 fetcher 返回后会立即 free 掉 url 缓冲；这里必须 dup 一份独立副本。
    // 先分配新副本再释放旧副本：多次回源（如 invalidate 后再取）时不会泄漏，
    // 且分配失败时 `last_url` 仍指向有效旧值。
    const url_dup = try allocator.dupe(u8, url);
    if (self.last_url) |old| allocator.free(old);
    self.called_count += 1;
    self.last_url = url_dup;
    return allocator.dupe(u8, self.response);
}

fn makeMemoryCache(allocator: std.mem.Allocator) struct {
    mem: *cache_mod.Memory,
    cache: Cache,
} {
    const mem = cache_mod.Memory.create(allocator) catch @panic("Memory.create failed");
    return .{ .mem = mem, .cache = mem.asCache() };
}

test "DefaultJsTicket: cache hit 返回缓存值，fetcher 不被调用" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    const prefix = "gowechat_test_";
    const app_id = "wx_t_cache_hit";
    const expected = "ticket_from_cache";

    const key = try std.fmt.allocPrint(allocator, "{s}_jsapi_ticket_{s}", .{ prefix, app_id });
    defer allocator.free(key);
    try ctx.cache.set(key, expected, 7000);

    const PanicFetcher = struct {
        fn fetch(_: *anyopaque, _: std.mem.Allocator, _: []const u8) CredentialError![]u8 {
            @panic("fetcher 不应在缓存命中时被调用");
        }
    };

    var t = DefaultJsTicket.initWithFetcher(
        app_id,
        prefix,
        ctx.cache,
        PanicFetcher.fetch,
        undefined,
    );

    const ticket = try t.getTicket(allocator, "any_access_token");
    defer allocator.free(ticket);

    try std.testing.expectEqualStrings(expected, ticket);
}

test "DefaultJsTicket: cache miss 走 fetcher、解析、写入缓存并返回" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"ticket\":\"fresh_ticket_abc\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    defer if (stub_ctx.last_url) |u| allocator.free(u);

    const prefix = "gowechat_test_";
    const app_id = "wx_t_fresh";
    const ak = "test_access_token_123";

    var t = DefaultJsTicket.initWithFetcher(
        app_id,
        prefix,
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    // 1) 第一次调用：cache miss
    const ticket = try t.getTicket(allocator, ak);
    defer allocator.free(ticket);

    try std.testing.expectEqualStrings("fresh_ticket_abc", ticket);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
    try std.testing.expect(stub_ctx.last_url != null);
    try std.testing.expect(std.mem.indexOf(u8, stub_ctx.last_url.?, ak) != null);
    try std.testing.expect(std.mem.indexOf(u8, stub_ctx.last_url.?, "type=jsapi") != null);

    // 2) 验证缓存写入
    const key = try std.fmt.allocPrint(allocator, "{s}_jsapi_ticket_{s}", .{ prefix, app_id });
    defer allocator.free(key);
    const cached = (try ctx.cache.get(key)).?;
    try std.testing.expectEqualStrings("fresh_ticket_abc", cached);

    // 3) 第二次调用：cache hit
    const ticket2 = try t.getTicket(allocator, ak);
    defer allocator.free(ticket2);
    try std.testing.expectEqualStrings("fresh_ticket_abc", ticket2);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
}

test "DefaultJsTicket: errcode != 0 返回 ApiError 且不写入缓存" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    };
    defer if (stub_ctx.last_url) |u| allocator.free(u);

    var t = DefaultJsTicket.initWithFetcher(
        "wx_t_bad",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const result = t.getTicket(allocator, "bad_ak");
    try std.testing.expectError(CredentialError.ApiError, result);

    const key = try std.fmt.allocPrint(allocator, "gowechat_test__jsapi_ticket_{s}", .{"wx_t_bad"});
    defer allocator.free(key);
    try std.testing.expect((try ctx.cache.get(key)) == null);
}

test "DefaultJsTicket: 畸形 JSON 返回 DecodeError" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "<<< not json >>>",
    };
    defer if (stub_ctx.last_url) |u| allocator.free(u);

    var t = DefaultJsTicket.initWithFetcher(
        "wx_t_bad_json",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const result = t.getTicket(allocator, "ak");
    try std.testing.expectError(CredentialError.DecodeError, result);
}

test "DefaultJsTicket: JsTicketHandle 抽象接口派发正确" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"ticket\":\"handle_ticket\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    defer if (stub_ctx.last_url) |u| allocator.free(u);

    var t = DefaultJsTicket.initWithFetcher(
        "wx_t_handle",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const handle = t.asHandle();
    const ticket = try handle.getTicket(allocator, "ak_for_handle");
    defer allocator.free(ticket);

    try std.testing.expectEqualStrings("handle_ticket", ticket);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
}

test "DefaultJsTicket: buildURL 拼接正确" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    const t = DefaultJsTicket.init("wxid", "pfx", ctx.cache);
    const url = try t.buildURL(allocator, "my_ak");
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "my_ak") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "type=jsapi") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "api.weixin.qq.com") != null);
}

test "DefaultJsTicket: cacheKey 拼接正确" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    const t = DefaultJsTicket.init("wxid", "pfx", ctx.cache);
    const key = try t.cacheKey(allocator);
    defer allocator.free(key);

    try std.testing.expectEqualStrings("pfx_jsapi_ticket_wxid", key);
}

// ──────────────────────────────────────────────────────────────────────────────
// invalidate：缓存写入 → 作废 → 下次 getTicket 重新回源
// ──────────────────────────────────────────────────────────────────────────────

test "DefaultJsTicket: invalidate 后缓存条目消失，下一次 getTicket 重新回源" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"ticket\":\"ticket_v1\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    defer if (stub_ctx.last_url) |u| allocator.free(u);

    var t = DefaultJsTicket.initWithFetcher(
        "wx_t_invalidate",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    // 作废用的 key 必须是 getTicket 真正写入的那个（"{prefix}_jsapi_ticket_{app_id}"）。
    const key = try t.cacheKey(allocator);
    defer allocator.free(key);
    try std.testing.expectEqualStrings("gowechat_test__jsapi_ticket_wx_t_invalidate", key);

    // 1) 首次回源并写入缓存
    const first = try t.getTicket(allocator, "ak_1");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("ticket_v1", first);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
    try std.testing.expect((try ctx.cache.get(key)) != null);

    // 2) 缓存命中：不再回源
    const cached = try t.getTicket(allocator, "ak_1");
    defer allocator.free(cached);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);

    // 3) 作废：缓存条目被删除，且可重复调用不报错（键不存在不视为错误）
    try t.invalidate(allocator);
    try std.testing.expect((try ctx.cache.get(key)) == null);
    try t.invalidate(allocator);

    // 4) 再取必须重新回源
    const refreshed = try t.getTicket(allocator, "ak_1");
    defer allocator.free(refreshed);
    try std.testing.expectEqualStrings("ticket_v1", refreshed);
    try std.testing.expectEqual(@as(usize, 2), stub_ctx.called_count);

    // 5) 抽象 handle 转发到同一实现（不是 InvalidateNotSupported）
    const handle = t.asHandle();
    try handle.invalidateTicket(allocator);
    try std.testing.expect((try ctx.cache.get(key)) == null);

    // 6) 经 handle 重复作废（键已不存在）同样不报错
    try handle.invalidateTicket(allocator);
}

test "DefaultJsTicket: invalidate 对空缓存不报错（仅构造未使用过）" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var t = DefaultJsTicket.init("wx_no_cache_entry", "gowechat_test_", ctx.cache);
    try t.invalidate(allocator);
    try t.invalidate(allocator);

    const handle = t.asHandle();
    try handle.invalidateTicket(allocator);
}
