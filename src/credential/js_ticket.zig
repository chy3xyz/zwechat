//! credential/js_ticket — 默认 jsapi_ticket 获取器
//!
//! 对应 `_ref/wechat/credential/default_js_ticket.go`：先从缓存中取，
//! 没有则从微信服务器拉取，并缓存；线程安全（自旋锁 + 双检）。
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

/// 自旋锁实现（与 `default_access_token.zig` 保持一致）。
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
    /// 流程与 `DefaultAccessToken.getAccessToken` 一致，区别仅在于：
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

        // 2) 上锁 + 双检
        self.lock.lock();
        defer self.lock.unlock();

        if (try self.cache.get(key)) |val| {
            if (val.len > 0) return allocator.dupe(u8, val);
        }

        // 3) 从服务端拉取
        const url = try self.buildURL(allocator, access_token);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(TicketResponse, allocator, body, .{}) catch {
            return CredentialError.DecodeError;
        };
        defer parsed.deinit();

        const resp = parsed.value;
        if (resp.errcode != 0) return CredentialError.ApiError;

        // 4) 写入缓存
        const ttl = resp.expires_in - 1500;
        try self.cache.set(key, resp.ticket, ttl);

        return allocator.dupe(u8, resp.ticket);
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
    };

    fn handleGetTicket(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) anyerror![]u8 {
        const self: *DefaultJsTicket = @ptrCast(@alignCast(ctx));
        return self.getTicket(allocator, access_token);
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
    self.called_count += 1;
    // 注意：调用方在 fetcher 返回后会立即 free 掉 url 缓冲；这里必须 dup 一份独立副本。
    self.last_url = allocator.dupe(u8, url) catch return error.OutOfMemory;
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
