// SPDX-License-Identifier: Apache-2.0
//! credential/work_access_token — 企业微信 access_token 获取器
//!
//! 对应 `_ref/wechat/credential/default_access_token.go` 中的 `WorkAccessToken`：
//! 与 `DefaultAccessToken` 实现完全一致，但 URL 用 `qyapi.weixin.qq.com/cgi-bin/gettoken`
//! 并把字段名 `app_id/app_secret` 换成 `corp_id/corp_secret`。
//! 锁范围同 `default_access_token.zig`：锁只保护缓存临界区，HTTP 回源在锁外。

const std = @import("std");
const Cache = @import("../cache/mod.zig").Cache;
const credential = @import("mod.zig");
const default_io = @import("../util/default_io.zig");

/// 企业微信 access_token URL（使用 `{s}` 占位符以匹配 `std.fmt`）。
pub const workAccessTokenURL = "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid={s}&corpsecret={s}";

/// Token 响应。
pub const ResAccessToken = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    access_token: []const u8 = "",
    expires_in: i64 = 0,
};

/// **已弃用**：本模块的锁已迁移到 `std.Io.Mutex`（`lock` 需要 `io` 参数，
/// 见 `WorkAccessToken.io`）。保留本别名仅为兼容既有引用，新代码请直接用 `std.Io.Mutex`。
pub const SpinMutex = std.Io.Mutex;

/// 企业微信 AccessToken 实现。
pub const WorkAccessToken = struct {
    corp_id: []const u8,
    corp_secret: []const u8,
    cache_key_prefix: []const u8,
    cache: Cache,
    /// futex 等待 / 唤醒所用的 `Io` 句柄（默认 `default_io.io()`，可注入）。
    io: std.Io = default_io.io(),
    lock: std.Io.Mutex = .init,
    fetcher: Fetcher,
    fetcher_ctx: *anyopaque,

    const Self = @This();

    /// 可注入的 fetcher（测试时用 stub）。
    pub const Fetcher = credential.Fetcher;

    /// 默认 fetcher：调用 `util.http.getDefaultClient().get`。
    fn defaultFetcher(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) credential.CredentialError![]u8 {
        _ = ctx;
        const client = @import("../util/http.zig").getDefaultClient(allocator);
        return client.get(url) catch return credential.CredentialError.HttpError;
    }

    /// 生产用构造：默认 fetcher。
    pub fn init(
        corp_id: []const u8,
        corp_secret: []const u8,
        cache_key_prefix: []const u8,
        cache: Cache,
    ) WorkAccessToken {
        return .{
            .corp_id = corp_id,
            .corp_secret = corp_secret,
            .cache_key_prefix = cache_key_prefix,
            .cache = cache,
            .fetcher = defaultFetcher,
            .fetcher_ctx = undefined,
        };
    }

    /// 测试用构造：注入自定义 fetcher。
    pub fn initWithFetcher(
        corp_id: []const u8,
        corp_secret: []const u8,
        cache_key_prefix: []const u8,
        cache: Cache,
        fetcher: Fetcher,
        fetcher_ctx: *anyopaque,
    ) WorkAccessToken {
        return .{
            .corp_id = corp_id,
            .corp_secret = corp_secret,
            .cache_key_prefix = cache_key_prefix,
            .cache = cache,
            .fetcher = fetcher,
            .fetcher_ctx = fetcher_ctx,
        };
    }

    fn cacheKey(self: *const Self, allocator: std.mem.Allocator) credential.CredentialError![]u8 {
        return allocator.print(
            "{s}_access_token_{s}",
            .{ self.cache_key_prefix, self.corp_id },
        );
    }

    fn buildURL(self: *const Self, allocator: std.mem.Allocator) credential.CredentialError![]u8 {
        return allocator.print(
            workAccessTokenURL,
            .{ self.corp_id, self.corp_secret },
        );
    }

    /// 持锁读缓存并返回**所有权副本**（`null` = 未命中或值为空）。
    ///
    /// 副本由 cache 后端在**它自己的临界区**内拷出（`Cache.getOwned`），因此即使
    /// 另一个凭据对象 / 宿主模块共享同一个 `Cache` 实例并在并发写同一 key，
    /// 拿到的也是独立内存（`Cache.get` 返回的借用切片只到本实例下一次写操作为止）。
    /// 本对象的 `lock` 仍保留：它串行化本实例自己的缓存操作。
    fn readCachedCopy(self: *Self, allocator: std.mem.Allocator, key: []const u8) credential.CredentialError!?[]u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        const owned = try self.cache.getOwned(allocator, key);
        const val = owned orelse return null;
        if (val.len == 0) {
            // 空值视为未命中；副本的所有权已在调用方，必须归还。
            allocator.free(val);
            return null;
        }
        return val;
    }

    /// 获取 access_token（singleflight 风格：加锁双检缓存 → 锁外回源 →
    /// 重新加锁双检并回写）。并发 miss 允许多个并发回源（幂等 GET，last-write-wins 无害）。
    pub fn getAccessToken(self: *Self, allocator: std.mem.Allocator) credential.CredentialError![]u8 {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        // 加锁双检：命中则直接用现成值（副本由 cache 后端在自己的临界区拷出）
        if (try self.readCachedCopy(allocator, key)) |tok| return tok;

        // 锁外从服务端拉取（锁不跨网络 I/O）
        const url = try self.buildURL(allocator);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(ResAccessToken, allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return credential.CredentialError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return credential.CredentialError.ApiError;

        // 重新加锁双检：回源期间可能已被其他线程回写，命中直接用现成的。
        // 读取走 `getOwned`（副本由 cache 后端在自己的临界区拷出），共享同一
        // Cache 实例的其它对象并发写同一 key 时也不会读到已释放内存。
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (try self.cache.getOwned(allocator, key)) |existing| {
            if (existing.len > 0) return existing;
            allocator.free(existing);
        }

        try self.cache.set(key, parsed.value.access_token, credential.tokenTTL(parsed.value.expires_in));

        return allocator.dupe(u8, parsed.value.access_token);
    }

    /// 作废缓存的 access_token：删除缓存条目，使下一次 `getAccessToken` 必须回源。
    ///
    /// 与 `DefaultAccessToken.invalidate` 语义一致：本实现不额外持有 token 副本，
    /// 删除 cache 里的条目即作废完成；键不存在不视为错误。
    /// 用于 token 失效码（40001/40014/41001/42001）后的恢复链路，见 `util/retry.zig`。
    pub fn invalidate(self: *Self, allocator: std.mem.Allocator) credential.CredentialError!void {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        try self.cache.delete(key);
    }

    /// 包成抽象接口（用于 Context）。
    pub fn asHandle(self: *WorkAccessToken) credential.AccessTokenHandle {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &access_token_vtable,
        };
    }
};

const access_token_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = struct {
        fn f(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8 {
            const self: *WorkAccessToken = @ptrCast(@alignCast(ctx));
            return self.getAccessToken(alloc);
        }
    }.f,
    .invalidate = struct {
        fn f(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!void {
            const self: *WorkAccessToken = @ptrCast(@alignCast(ctx));
            return self.invalidate(alloc);
        }
    }.f,
};

test "WorkAccessToken.cacheKey 拼接 corp_id" {
    const t = WorkAccessToken.init("ww-it", "sec", "gk_", undefined);
    const key = try t.cacheKey(std.testing.allocator);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("gk__access_token_ww-it", key);
}

test "WorkAccessToken.buildURL 使用 qyapi 域名" {
    const t = WorkAccessToken.init("ww-it", "sec", "gk_", undefined);
    const url = try t.buildURL(std.testing.allocator);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.find(u8, url, "qyapi.weixin.qq.com") != null);
    try std.testing.expect(std.mem.find(u8, url, "corpid=ww-it") != null);
    try std.testing.expect(std.mem.find(u8, url, "corpsecret=sec") != null);
}

test "ResAccessToken 默认值" {
    const r = ResAccessToken{};
    try std.testing.expectEqualStrings("", r.access_token);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}

// ──────────────────────────────────────────────────────────────────────────────
// invalidate：缓存写入 → 作废 → 下次 getAccessToken 重新回源
// ──────────────────────────────────────────────────────────────────────────────

/// Stub fetcher 计数桩（同 `default_access_token.zig` 的做法：深拷贝 url 避免悬垂；
/// 多次回源时会先释放上一份副本，避免桩自身泄漏）。
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

test "WorkAccessToken: invalidate 后缓存条目消失，下一次 getAccessToken 重新回源" {
    const allocator = std.testing.allocator;
    const ctx = makeMemoryCache(allocator);
    defer {
        ctx.mem.deinit();
        allocator.destroy(ctx.mem);
    }

    var stub_ctx = StubFetcherCtx{
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"access_token\":\"work_tok_v1\",\"expires_in\":7200}",
    };
    defer if (stub_ctx.last_url.len > 0) allocator.free(@constCast(stub_ctx.last_url));

    var token_handle = WorkAccessToken.initWithFetcher(
        "ww-invalidate",
        "sec",
        "gowechat_work_",
        ctx.cache,
        stubFetcher,
        @ptrCast(&stub_ctx),
    );

    const key = try token_handle.cacheKey(allocator);
    defer allocator.free(key);

    // 1) 首次回源并写缓存
    const first = try token_handle.getAccessToken(allocator);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);
    try std.testing.expect((try ctx.cache.get(key)) != null);

    // 2) 缓存命中：不再回源
    const cached = try token_handle.getAccessToken(allocator);
    defer allocator.free(cached);
    try std.testing.expectEqual(@as(usize, 1), stub_ctx.called_count);

    // 3) 作废：缓存条目被删除，且可重复调用不报错
    try token_handle.invalidate(allocator);
    try std.testing.expect((try ctx.cache.get(key)) == null);
    try token_handle.invalidate(allocator);

    // 4) 再取必须重新回源
    const refreshed = try token_handle.getAccessToken(allocator);
    defer allocator.free(refreshed);
    try std.testing.expectEqualStrings("work_tok_v1", refreshed);
    try std.testing.expectEqual(@as(usize, 2), stub_ctx.called_count);

    // 5) 抽象 handle 转发到同一实现（不是 InvalidateNotSupported）
    const handle = token_handle.asHandle();
    try handle.invalidateAccessToken(allocator);
    try std.testing.expect((try ctx.cache.get(key)) == null);
}
