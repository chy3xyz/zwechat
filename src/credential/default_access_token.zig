// SPDX-License-Identifier: Apache-2.0
//! credential/default_access_token — 默认 access_token 获取器
//!
//! 对应 `_ref/wechat/credential/default_access_token.go`：先从缓存中取，
//! 没有则从微信服务器拉取，并缓存；线程安全（`std.atomic.Value(u8)` 自旋锁 + 双检，
//! 与 Zig 0.17-dev 移除 `std.Thread.Mutex` 的现状对齐）。
//!
//! **singleflight 风格锁范围**：SpinMutex 只保护缓存读/写临界区，HTTP 回源在锁外执行
//! （自旋锁不适合持锁跨网络 I/O，否则同 appid 的其他线程只能空转烧 CPU）。
//! 取舍：极端并发 miss 时可能有 N 个并发回源请求（这些端点都是幂等 GET，
//! N 个结果都合法，last-write-wins 无害），这比 N-1 个线程空转划算得多。
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
const SpinMutex = @import("../util/sync.zig").SpinMutex;
const tokenTTL = mod_zig.tokenTTL;

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

/// Zig 0.17-dev 不再提供 `std.Thread.Mutex`，互斥统一使用
/// `util/sync.zig` 的 CAS 自旋锁（`std.atomic.spinLoopHint` + CAS，
/// 零依赖；缓存场景下临界区极短，足够使用）。
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
    /// 流程（singleflight 风格，HTTP 回源在锁外）：
    /// 1. 未上锁查缓存：非空直接返回（深拷贝）。
    /// 2. 加锁双检缓存：命中则用现成值（可能已被其他线程回写）。
    /// 3. 解锁后 HTTP GET 微信接口并解析（锁不跨网络 I/O）。
    /// 4. 若 `errcode != 0` 返回 `CredentialError.ApiError`。
    /// 5. 重新加锁，再次双检（回源期间可能已被回写，命中直接用现成的），
    ///    否则写入缓存（TTL 由 `tokenTTL` 计算），解锁返回深拷贝。
    /// 6. 返回深拷贝的 token（调用方负责 `allocator.free`）。
    ///
    /// 注意：极端并发 miss 时允许多个并发回源（端点为幂等 GET，last-write-wins 无害）。
    pub fn getAccessToken(self: *DefaultAccessToken, allocator: std.mem.Allocator) CredentialError![]u8 {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        // 1) 缓存快速路径：未上锁读取
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
        const url = try self.buildURL(allocator);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(TokenResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch {
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

        // 5) 写入缓存（TTL = expires_in - 1500 秒，边界处理见 `tokenTTL`）
        try self.cache.set(key, resp.access_token, tokenTTL(resp.expires_in));

        // 6) 返回深拷贝
        return allocator.dupe(u8, resp.access_token);
    }

    /// 作废缓存的 access_token：删除缓存条目，使下一次 `getAccessToken` 必须回源。
    ///
    /// 本实现不额外持有 token 副本（唯一副本就在 cache 里），删除缓存即作废完成；
    /// 锁范围与 `getAccessToken` 的缓存临界区一致，与并发 `set` / `delete` 互斥。
    /// 键不存在不视为错误（`cache.delete` 契约）。
    ///
    /// 用途：识别到微信 token 失效码（40001/40014/41001/42001）后的恢复第一步，
    /// 见 `util/retry.zig` 的 `callApi`；`forceRefresh` 等价于「作废 + 立即回源」。
    pub fn invalidate(self: *DefaultAccessToken, allocator: std.mem.Allocator) CredentialError!void {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        self.lock.lock();
        defer self.lock.unlock();
        try self.cache.delete(key);
    }

    /// 强制清空缓存并重新从服务端获取 Token（用于 Token 失效时的自动恢复机制）。
    ///
    /// 锁范围同 `getAccessToken`：清缓存与回写缓存在锁内，HTTP 回源在锁外。
    pub fn forceRefresh(self: *DefaultAccessToken, allocator: std.mem.Allocator) CredentialError![]u8 {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        // 1) 锁内清缓存
        self.lock.lock();
        self.cache.delete(key) catch {};
        self.lock.unlock();

        // 2) 锁外回源
        const url = try self.buildURL(allocator);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(TokenResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return CredentialError.DecodeError;
        };
        defer parsed.deinit();

        const resp = parsed.value;
        if (resp.errcode != 0) return CredentialError.ApiError;

        // 3) 锁内回写（并发 forceRefresh 之间 last-write-wins）
        self.lock.lock();
        defer self.lock.unlock();
        try self.cache.set(key, resp.access_token, tokenTTL(resp.expires_in));

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
        .invalidate = handleInvalidate,
    };

    fn handleGetAccessToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *DefaultAccessToken = @ptrCast(@alignCast(ctx));
        return self.getAccessToken(allocator);
    }

    fn handleInvalidate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const self: *DefaultAccessToken = @ptrCast(@alignCast(ctx));
        return self.invalidate(allocator);
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
/// 多次回源时先释放上一份 url 副本，避免桩自身泄漏；新副本先分配再替换，
/// 分配失败时 `last_url` 仍指向有效旧值（不会留下悬垂指针）。
fn stubFetcher(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) CredentialError![]u8 {
    const self: *StubFetcherCtx = @ptrCast(@alignCast(ctx));
    const url_dup = try allocator.dupe(u8, url);
    if (self.last_url.len > 0) allocator.free(@constCast(self.last_url));
    self.called_count += 1;
    self.last_url = url_dup;
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

test "DefaultAccessToken: invalidate 后缓存条目消失，下一次 getAccessToken 重新回源" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"access_token\":\"tok_v1\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    var dat = DefaultAccessToken.initWithFetcher(
        "wx_invalidate",
        "secret",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const key = try std.fmt.allocPrint(allocator, "gowechat_test__access_token_{s}", .{"wx_invalidate"});
    defer allocator.free(key);

    // 1) 首次回源并写入缓存
    const first = try dat.getAccessToken(allocator);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
    try std.testing.expect((try ctx.cache.get(key)) != null);

    // 2) 缓存命中：不再回源
    const cached = try dat.getAccessToken(allocator);
    defer allocator.free(cached);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);

    // 3) 作废：缓存条目被删除
    try dat.invalidate(allocator);
    try std.testing.expect((try ctx.cache.get(key)) == null);

    // 4) 再取必须重新回源
    const refreshed = try dat.getAccessToken(allocator);
    defer allocator.free(refreshed);
    try std.testing.expectEqualStrings("tok_v1", refreshed);
    try std.testing.expectEqual(@as(usize, 2), stub_ctx.called_count);

    // 5) 抽象 handle 转发到同一实现（不是 InvalidateNotSupported）
    const handle = dat.asHandle();
    try handle.invalidateAccessToken(allocator);
    try std.testing.expect((try ctx.cache.get(key)) == null);
}

test "DefaultAccessToken: invalidate 对不存在的键不报错（可重复调用）" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var dat = DefaultAccessToken.init("wx_no_cache_entry", "secret", "gowechat_test_", ctx.cache);
    try dat.invalidate(allocator);
    try dat.invalidate(allocator);
}

test "DefaultAccessToken: expires_in 取 i64 极值不溢出 panic 且缓存 TTL 不退化为永不过期" {
    // 回归：旧实现 `resp.expires_in - 1500` 在 expires_in = i64 min 时 Debug 下
    // 整数溢出 panic；即便不 panic，ttl <= 0 也会被 cache.Memory 当作永不过期。
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"access_token\":\"edge_token\",\"expires_in\":-9223372036854775808,\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    var dat = DefaultAccessToken.initWithFetcher(
        "wx_edge",
        "secret",
        "gowechat_test_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const token = try dat.getAccessToken(allocator);
    defer allocator.free(token);
    try std.testing.expectEqualStrings("edge_token", token);

    // 缓存条目存在，且 TTL 被钳制为 1 秒（非永不过期哨兵 0，且距今 ≤ 2 秒）。
    const key = try std.fmt.allocPrint(allocator, "gowechat_test__access_token_{s}", .{"wx_edge"});
    defer allocator.free(key);
    const entry = ctx.mem.data.getEntry(key).?;
    try std.testing.expect(entry.value_ptr.expire_at_ns > 0);
    const now_ns = std.Io.Clock.now(.awake, std.Options.debug_io).nanoseconds;
    try std.testing.expect(entry.value_ptr.expire_at_ns -| now_ns <= 2 * std.time.ns_per_s);
}

// ──────────────────────────────────────────────────────────────────────────────
// 并发 / 错误路径行为测试（singleflight 锁范围回归）
// ──────────────────────────────────────────────────────────────────────────────

/// 并发回源协调桩：fetcher 内部等待两个线程都进入后才放行。
///
/// 自旋带迭代上限——若旧实现（持 SpinMutex 跨回源）回归，第二个线程会永远
/// 拿不到锁，这里在上限后设置 `deadlock_suspected` 并放行，而不是挂死测试。
const ConcurrentFetchCtx = struct {
    response: []const u8,
    entered: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    deadlock_suspected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn fetch(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, url: []const u8) CredentialError![]u8 {
        _ = url;
        const self: *ConcurrentFetchCtx = @ptrCast(@alignCast(ctx_ptr));
        _ = self.entered.fetchAdd(1, .monotonic);

        var spins: usize = 0;
        while (self.entered.load(.acquire) < 2) {
            std.atomic.spinLoopHint();
            spins += 1;
            if (spins > 100_000_000) {
                self.deadlock_suspected.store(true, .release);
                break;
            }
        }
        return allocator.dupe(u8, self.response);
    }
};

test "DefaultAccessToken: 并发 miss 两个线程都成功返回且结果一致（HTTP 回源在锁外）" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = ConcurrentFetchCtx{
        .response = "{\"access_token\":\"concurrent_token\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}",
    };

    var dat = DefaultAccessToken.initWithFetcher(
        "wx_concurrent",
        "secret",
        "gowechat_test_",
        ctx.cache,
        ConcurrentFetchCtx.fetch,
        @ptrCast(&stub_ctx),
    );

    const Worker = struct {
        fn run(d: *DefaultAccessToken, buf: *[32]u8, len: *usize) void {
            const a = std.testing.allocator;
            const token = d.getAccessToken(a) catch |e| {
                std.debug.panic("并发 getAccessToken 失败: {}", .{e});
            };
            defer a.free(token);
            std.mem.copyForwards(u8, buf[0..token.len], token);
            len.* = token.len;
        }
    };

    var results: [2][32]u8 = undefined;
    var lens: [2]usize = .{ 0, 0 };

    const threads = try allocator.alloc(std.Thread, 2);
    defer allocator.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &dat, &results[i], &lens[i] });
    }
    for (threads) |t| t.join();

    // 回源必须发生在锁外：两个线程都应能同时进入 fetcher（不规定去重次数本身，
    // 但协调桩要求双方都进入——若锁跨回源，第二个线程拿不到锁，这里会触发）。
    try std.testing.expect(!stub_ctx.deadlock_suspected.load(.acquire));
    // 两个调用都成功且返回结果一致。
    try std.testing.expectEqual(lens[0], lens[1]);
    try std.testing.expectEqualSlices(u8, results[0][0..lens[0]], results[1][0..lens[1]]);
    try std.testing.expectEqualStrings("concurrent_token", results[0][0..lens[0]]);
}

/// 先抛错后成功的 fetcher 桩：验证错误路径上锁被正确释放。
const FailThenOkCtx = struct {
    response: []const u8,
    calls: usize = 0,

    fn fetch(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, url: []const u8) CredentialError![]u8 {
        _ = url;
        const self: *FailThenOkCtx = @ptrCast(@alignCast(ctx_ptr));
        self.calls += 1;
        if (self.calls == 1) return CredentialError.HttpError;
        return allocator.dupe(u8, self.response);
    }
};

test "DefaultAccessToken: fetcher 抛错后锁被正确释放，可再次进入 fetcher" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = FailThenOkCtx{
        .response = "{\"access_token\":\"recovered_token\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"ok\"}",
    };

    var dat = DefaultAccessToken.initWithFetcher(
        "wx_fail_then_ok",
        "secret",
        "gowechat_test_",
        ctx.cache,
        FailThenOkCtx.fetch,
        @ptrCast(&stub_ctx),
    );

    // 1) 第一次调用：miss → fetch 抛错，锁必须已释放，且不写入缓存
    const result = dat.getAccessToken(allocator);
    try std.testing.expectError(CredentialError.HttpError, result);
    const key = try std.fmt.allocPrint(allocator, "gowechat_test__access_token_{s}", .{"wx_fail_then_ok"});
    defer allocator.free(key);
    try std.testing.expect((try ctx.cache.get(key)) == null);

    // 2) 第二次调用：若锁未释放会永久卡死；这里必须能再次进入 fetcher 并成功
    const token = try dat.getAccessToken(allocator);
    defer allocator.free(token);
    try std.testing.expectEqualStrings("recovered_token", token);
    try std.testing.expectEqual(@as(usize, 2), stub_ctx.calls);
}
