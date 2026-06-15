//! credential/default_access_token — 默认 access_token 获取器
//!
//! 对应 `_ref/wechat/credential/default_access_token.go`：先从缓存中取，
//! 没有则从微信服务器拉取，并缓存；线程安全（`std.atomic.Value(u8)` 自旋锁 + 双检，
//! 与 Zig 0.17-dev 移除 `std.Thread.Mutex` 的现状对齐）。
//!
//! 缓存 key：`"{prefix}_access_token_{app_id}"`（与 Go 一致）。
//! 缓存 TTL：`expires_in - 1500` 秒，提前 25 分钟失效以避免边界 race。

const std = @import("std");

const cache_mod = @import("../cache/mod.zig");
const Cache = cache_mod.Cache;

const http = @import("../util/http.zig");

const mod_zig = @import("mod.zig");
const AccessTokenHandle = mod_zig.AccessTokenHandle;
const CredentialError = mod_zig.CredentialError;
const Fetcher = mod_zig.Fetcher;

/// access_token 接口 URL 模板（与 Go `accessTokenURL` 一致）。
/// 真实 URL：`https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid={appid}&secret={secret}`
pub const accessTokenURLTemplate =
    "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid={s}&secret={s}";

/// 默认 fetcher：通过线程局部的 `util.http.getDefaultClient` 拉取。
fn defaultFetcher(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) CredentialError![]u8 {
    _ = ctx;
    const client = http.getDefaultClient(allocator);
    return client.get(url) catch return CredentialError.HttpError;
}

/// Zig 0.17-dev 不再提供 `std.Thread.Mutex`，`std.atomic.spinLoopHint` 配合
/// CAS 自旋锁是保持零依赖的最简方案；缓存场景下临界区极短，足够使用。
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

/// 默认 `access_token` 实现（对应 Go 的 `DefaultAccessToken`）。
///
/// 字段说明：
/// - `app_id` / `app_secret` / `cache_key_prefix`：调用方持有（通常是字符串字面量）。
/// - `cache`：必须早于本对象存活；不持有所有权。
/// - `lock`：并发获取 token 时的自旋互斥锁，保证双检模式正确性。
/// - `fetcher` / `fetcher_ctx`：默认指向 `util.http.getDefaultClient().get`，测试时可注入。
pub const DefaultAccessToken = struct {
    app_id: []const u8,
    app_secret: []const u8,
    cache_key_prefix: []const u8,
    cache: Cache,
    lock: SpinMutex = .{},
    fetcher: Fetcher,
    fetcher_ctx: *anyopaque,

    /// 默认构造：使用 `util.http.getDefaultClient().get` 作为后端 fetcher。
    pub fn init(
        app_id: []const u8,
        app_secret: []const u8,
        cache_key_prefix: []const u8,
        cache: Cache,
    ) DefaultAccessToken {
        return .{
            .app_id = app_id,
            .app_secret = app_secret,
            .cache_key_prefix = cache_key_prefix,
            .cache = cache,
            .fetcher = defaultFetcher,
            .fetcher_ctx = undefined,
        };
    }

    /// 测试用构造：注入自定义 fetcher 与上下文。
    ///
    /// `fetcher_ctx` 是任意透传给 fetcher 的指针（典型用途：测试桩里的状态对象）。
    pub fn initWithFetcher(
        app_id: []const u8,
        app_secret: []const u8,
        cache_key_prefix: []const u8,
        cache: Cache,
        fetcher: Fetcher,
        fetcher_ctx: *anyopaque,
    ) DefaultAccessToken {
        return .{
            .app_id = app_id,
            .app_secret = app_secret,
            .cache_key_prefix = cache_key_prefix,
            .cache = cache,
            .fetcher = fetcher,
            .fetcher_ctx = fetcher_ctx,
        };
    }

    /// 构造 `access_token` 接口 URL（`accessTokenURLTemplate` + appid + secret）。
    pub fn buildURL(self: *const DefaultAccessToken, allocator: std.mem.Allocator) CredentialError![]u8 {
        return std.fmt.allocPrint(
            allocator,
            accessTokenURLTemplate,
            .{ self.app_id, self.app_secret },
        );
    }

    /// 构造 cache key：`"{prefix}_access_token_{app_id}"`。
    pub fn cacheKey(self: *const DefaultAccessToken, allocator: std.mem.Allocator) CredentialError![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}_access_token_{s}",
            .{ self.cache_key_prefix, self.app_id },
        );
    }

    /// 微信 `/cgi-bin/token` 接口返回的 JSON 结构。
    /// 所有字段都允许缺失：成功响应有 access_token/expires_in，失败响应只有 errcode/errmsg。
    const TokenResponse = struct {
        access_token: []const u8 = "",
        expires_in: i64 = 0,
        errcode: i64 = 0,
        errmsg: []const u8 = "",
    };

    /// 获取 access_token，先缓存后服务端。
    ///
    /// 流程（与 Go `GetAccessTokenContext` 一致）：
    /// 1. 先查缓存：非空直接返回（深拷贝）。
    /// 2. 上锁 + 二次检查缓存（防止并发回源）。
    /// 3. HTTP GET 微信接口，JSON 解析。
    /// 4. 若 `errcode != 0` 返回 `CredentialError.ApiError`。
    /// 5. 写入缓存，TTL = `expires_in - 1500` 秒。
    /// 6. 返回深拷贝的 token（调用方负责 `allocator.free`）。
    pub fn getAccessToken(self: *DefaultAccessToken, allocator: std.mem.Allocator) CredentialError![]u8 {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        // 1) 缓存快速路径：未上锁读取
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
        const url = try self.buildURL(allocator);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(TokenResponse, allocator, body, .{}) catch {
            return CredentialError.DecodeError;
        };
        defer parsed.deinit();

        const resp = parsed.value;
        if (resp.errcode != 0) return CredentialError.ApiError;

        // 4) 写入缓存（TTL = expires_in - 1500 秒）
        const ttl = resp.expires_in - 1500;
        try self.cache.set(key, resp.access_token, ttl);

        // 5) 返回深拷贝
        return allocator.dupe(u8, resp.access_token);
    }

    /// 包装为抽象接口 `AccessTokenHandle`，便于注入到 `Context` 等。
    pub fn asHandle(self: *DefaultAccessToken) AccessTokenHandle {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable_instance,
        };
    }

    /// vtable 单例：所有 `DefaultAccessToken` 实例共用，函数通过 `ctx` 查回实例。
    const vtable_instance = AccessTokenHandle.VTable{
        .getAccessToken = handleGetAccessToken,
    };

    fn handleGetAccessToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *DefaultAccessToken = @ptrCast(@alignCast(ctx));
        return self.getAccessToken(allocator);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 内联测试（使用真实的 `cache.Memory`）
// ──────────────────────────────────────────────────────────────────────────────

/// Stub fetcher 上下文：用于验证 fetcher 是否被调用、是否收到正确的 URL。
///
/// `last_url` 是堆分配的拷贝——直接保存 `url` 切片会产生 use-after-free
/// （`getAccessToken` 内部用 `defer allocator.free(url)` 释放）。
const StubFetcherCtx = struct {
    response: []const u8,
    called_count: usize = 0,
    last_url: []const u8 = "",
};

/// 返回固定 JSON 响应的 fetcher（深拷贝 response 与 url）。
fn stubFetcher(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) CredentialError![]u8 {
    const self: *StubFetcherCtx = @ptrCast(@alignCast(ctx));
    self.called_count += 1;
    self.last_url = try allocator.dupe(u8, url);
    return allocator.dupe(u8, self.response);
}

/// 测试辅助：在指定 allocator 上分配一个 Memory 缓存，并返回其 Cache 句柄。
/// 失败时 panic（测试不应该看到分配失败）。
fn makeMemoryCache(allocator: std.mem.Allocator) struct {
    mem: *cache_mod.Memory,
    cache: Cache,
} {
    const mem = cache_mod.Memory.create(allocator) catch @panic("Memory.create failed");
    return .{ .mem = mem, .cache = mem.asCache() };
}

test "DefaultAccessToken: cache hit 返回缓存值，fetcher 不被调用" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    const prefix = "gowechat_test_";
    const app_id = "wx_cache_hit";
    const app_secret = "secret_ignored";
    const expected = "token_from_cache_xyz";

    // 预填缓存
    const key = try std.fmt.allocPrint(allocator, "{s}_access_token_{s}", .{ prefix, app_id });
    defer allocator.free(key);
    try ctx.cache.set(key, expected, 7000);

    // 注入一个会 panic 的 fetcher——一旦被调用测试就失败
    const PanicFetcher = struct {
        fn fetch(_: *anyopaque, _: std.mem.Allocator, _: []const u8) CredentialError![]u8 {
            @panic("fetcher 不应在缓存命中时被调用");
        }
    };

    var dat = DefaultAccessToken.initWithFetcher(
        app_id,
        app_secret,
        prefix,
        ctx.cache,
        PanicFetcher.fetch,
        undefined,
    );

    const token = try dat.getAccessToken(allocator);
    defer allocator.free(token);

    try std.testing.expectEqualStrings(expected, token);
}

test "DefaultAccessToken: cache miss 走 fetcher、解析、写入缓存并返回" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"access_token\":\"fresh_token_abc\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}",
    };

    const prefix = "gowechat_test_";
    const app_id = "wx_fresh";
    const app_secret = "secret_x";

    var dat = DefaultAccessToken.initWithFetcher(
        app_id,
        app_secret,
        prefix,
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    // 1) 第一次调用：cache miss → 走 fetcher
    const token = try dat.getAccessToken(allocator);
    defer allocator.free(token);

    try std.testing.expectEqualStrings("fresh_token_abc", token);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
    try std.testing.expect(stub_ctx.last_url.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, stub_ctx.last_url, app_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, stub_ctx.last_url, app_secret) != null);

    // 2) 验证缓存被写入
    const key = try std.fmt.allocPrint(allocator, "{s}_access_token_{s}", .{ prefix, app_id });
    defer allocator.free(key);
    const cached = (try ctx.cache.get(key)).?;
    try std.testing.expectEqualStrings("fresh_token_abc", cached);

    // 3) 第二次调用：cache hit → fetcher 不再被调用
    const token2 = try dat.getAccessToken(allocator);
    defer allocator.free(token2);
    try std.testing.expectEqualStrings("fresh_token_abc", token2);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
}

test "DefaultAccessToken: errcode != 0 返回 ApiError 且不写入缓存" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    // 注：响应里仍然包含 `access_token` / `expires_in`，否则 JSON 解析先于
    // errcode 检查失败，会被翻译为 `CredentialError.DecodeError`。
    var stub_ctx = StubFetcherCtx{
        .response = "{\"access_token\":\"\",\"expires_in\":0,\"errcode\":40013,\"errmsg\":\"invalid appid\"}",
    };
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    var dat = DefaultAccessToken.initWithFetcher(
        "wx_bad",
        "secret",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const result = dat.getAccessToken(allocator);
    try std.testing.expectError(CredentialError.ApiError, result);

    // 不应写入缓存
    const key = try std.fmt.allocPrint(allocator, "gowechat_test__access_token_{s}", .{"wx_bad"});
    defer allocator.free(key);
    try std.testing.expect((try ctx.cache.get(key)) == null);
}

test "DefaultAccessToken: 畸形 JSON 返回 DecodeError" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{not valid json",
    };
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    var dat = DefaultAccessToken.initWithFetcher(
        "wx_bad_json",
        "secret",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const result = dat.getAccessToken(allocator);
    try std.testing.expectError(CredentialError.DecodeError, result);
}

test "DefaultAccessToken: AccessTokenHandle 抽象接口派发正确" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"access_token\":\"handle_token\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    var dat = DefaultAccessToken.initWithFetcher(
        "wx_handle",
        "secret",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const handle = dat.asHandle();
    const token = try handle.getAccessToken(allocator);
    defer allocator.free(token);

    try std.testing.expectEqualStrings("handle_token", token);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
}

test "DefaultAccessToken: buildURL 拼接正确" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    const dat = DefaultAccessToken.init("wxid", "the_secret", "pfx", ctx.cache);
    const url = try dat.buildURL(allocator);
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "wxid") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "the_secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "grant_type=client_credential") != null);
}

test "DefaultAccessToken: cacheKey 拼接正确" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    const dat = DefaultAccessToken.init("wxid", "sec", "pfx", ctx.cache);
    const key = try dat.cacheKey(allocator);
    defer allocator.free(key);

    try std.testing.expectEqualStrings("pfx_access_token_wxid", key);
}
