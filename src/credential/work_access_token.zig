//! credential/work_access_token — 企业微信 access_token 获取器
//!
//! 对应 `_ref/wechat/credential/default_access_token.go` 中的 `WorkAccessToken`：
//! 与 `DefaultAccessToken` 实现完全一致，但 URL 用 `qyapi.weixin.qq.com/cgi-bin/gettoken`
//! 并把字段名 `app_id/app_secret` 换成 `corp_id/corp_secret`。

const std = @import("std");
const Cache = @import("../cache/mod.zig").Cache;
const credential = @import("mod.zig");

/// 企业微信 access_token URL（使用 `{s}` 占位符以匹配 `std.fmt`）。
pub const workAccessTokenURL = "https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid={s}&corpsecret={s}";

/// Token 响应。
pub const ResAccessToken = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    access_token: []const u8 = "",
    expires_in: i64 = 0,
};

/// 自旋锁（与 default_access_token 一致）。
pub const SpinMutex = struct {
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

/// 企业微信 AccessToken 实现。
pub const WorkAccessToken = struct {
    corp_id: []const u8,
    corp_secret: []const u8,
    cache_key_prefix: []const u8,
    cache: Cache,
    lock: SpinMutex = .{},
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
        return std.fmt.allocPrint(
            allocator,
            "{s}_access_token_{s}",
            .{ self.cache_key_prefix, self.corp_id },
        );
    }

    fn buildURL(self: *const Self, allocator: std.mem.Allocator) credential.CredentialError![]u8 {
        return std.fmt.allocPrint(
            allocator,
            workAccessTokenURL,
            .{ self.corp_id, self.corp_secret },
        );
    }

    pub fn getAccessToken(self: *Self, allocator: std.mem.Allocator) credential.CredentialError![]u8 {
        const key = try self.cacheKey(allocator);
        defer allocator.free(key);

        if (try self.cache.get(key)) |val| {
            if (val.len > 0) return allocator.dupe(u8, val);
        }

        self.lock.lock();
        defer self.lock.unlock();

        if (try self.cache.get(key)) |val| {
            if (val.len > 0) return allocator.dupe(u8, val);
        }

        const url = try self.buildURL(allocator);
        defer allocator.free(url);

        const body = try self.fetcher(self.fetcher_ctx, allocator, url);
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(ResAccessToken, allocator, body, .{ .ignore_unknown_fields = true }) catch {
            return credential.CredentialError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return credential.CredentialError.ApiError;

        const ttl = parsed.value.expires_in - 1500;
        try self.cache.set(key, parsed.value.access_token, ttl);

        return allocator.dupe(u8, parsed.value.access_token);
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
    try std.testing.expect(std.mem.indexOf(u8, url, "qyapi.weixin.qq.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "corpid=ww-it") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "corpsecret=sec") != null);
}

test "ResAccessToken 默认值" {
    const r = ResAccessToken{};
    try std.testing.expectEqualStrings("", r.access_token);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}