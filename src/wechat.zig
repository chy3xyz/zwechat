//! wechat — 顶层 Wechat struct
//!
//! 对应 `_ref/wechat/wechat.go`：聚合官方账号、小程序、支付、开放平台、
//! 企业微信等子模块。当前阶段实现 `init` / `setCache` / `getOfficialAccount` 三个入口，
//! 其它业务模块（小程序、支付、开放平台、企业微信）的方法将在后续阶段按
//! Go 参考实现的同名方法补齐。
//!
//! ## 用法
//!
//! ```zig
//! var wc = Wechat.init();
//! const mem = try cache.Memory.create(allocator);
//! defer { mem.deinit(); allocator.destroy(mem); }
//! wc.setCache(mem.asCache());
//!
//! const cfg = officialaccount.Config{ .app_id = "wx...", .app_secret = "..." };
//! const oa = try wc.getOfficialAccount(
//!     allocator,
//!     cfg,
//!     credential.DefaultAccessToken.asHandleFactory(),
//! );
//! ```

const std = @import("std");
const cache_mod = @import("cache/mod.zig");
const officialaccount_mod = @import("officialaccount/mod.zig");
const credential_mod = @import("credential/mod.zig");

/// 顶层 Wechat 入口。
///
/// 与 Go 参考实现 (`_ref/wechat/wechat.go`) 的 `Wechat` struct 一一对应：
/// - 持有可选的全局 cache；
/// - 通过 `getOfficialAccount` / `getMiniProgram` / `getPay` 等方法获取各业务模块实例。
///
/// 当各业务的 `Config.cache == null` 时，回退使用本结构体上的全局 `cache`。
pub const Wechat = struct {
    /// 全局默认 cache（可选）。
    ///
    /// 为 `null` 时，由各业务的 `Config.cache` 提供。
    cache: ?cache_mod.Cache = null,

    /// 构造一个空的 Wechat 实例；`cache` 默认为 `null`。
    pub fn init() Wechat {
        return .{};
    }

    /// 设置全局 cache。
    ///
    /// 对应 `_ref/wechat/wechat.go: SetCache`。
    /// 设置后，所有 `Config.cache == null` 的业务实例都会回退使用本 cache。
    pub fn setCache(self: *Wechat, c: cache_mod.Cache) void {
        self.cache = c;
    }

    /// `getOfficialAccount` 的窄错误集（除工厂本身抛出的 `anyerror` 之外的
    /// 本模块特有错误）。错误集合并通过 `||` 显式声明。
    pub const GetOfficialAccountError = error{
        /// `cfg.cache` 与 `self.cache` 都为空，无法解析出可用 cache。
        CacheUnavailable,
    };

    /// 获取公众号实例。
    ///
    /// 对应 `_ref/wechat/wechat.go: GetOfficialAccount`：
    /// 1. 若 `cfg.cache == null` 且 `self.cache != null`，使用 `self.cache`；否则使用 `cfg.cache`。
    ///    当两者都为 `null` 时返回 `error.CacheUnavailable`。
    /// 2. 调用 `default_access_token_factory` 构造 access_token 句柄（其错误集会一并向上传播）。
    /// 3. 构造 `Context` 并通过 `OfficialAccount.init` 返回实例。
    ///
    /// `allocator` 预留给后续阶段（例如在 `Context` 中复制 `Config` 字符串、或
    /// 缓存命中失败时回源拉取 access_token 的临时缓冲）。
    ///
    /// 错误集 = `GetOfficialAccountError || anyerror`（因工厂使用 `anyerror!`，
    /// 实际等价于 `anyerror!OfficialAccount`）。
    pub fn getOfficialAccount(
        self: *Wechat,
        allocator: std.mem.Allocator,
        cfg: officialaccount_mod.Config,
        default_access_token_factory: *const fn (cfg: officialaccount_mod.Config, cache: cache_mod.Cache) anyerror!credential_mod.AccessTokenHandle,
    ) (GetOfficialAccountError || anyerror)!officialaccount_mod.OfficialAccount {
        _ = allocator;
        const resolved_cache = cfg.cache orelse self.cache orelse return error.CacheUnavailable;
        var resolved_cfg = cfg;
        resolved_cfg.cache = resolved_cache;
        const handle = try default_access_token_factory(resolved_cfg, resolved_cache);
        const ctx = officialaccount_mod.Context{
            .config = resolved_cfg,
            .access_token_handle = handle,
        };
        return officialaccount_mod.OfficialAccount.init(ctx);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// inline tests
// ─────────────────────────────────────────────────────────────────────────────

test "Wechat.init 返回空实例" {
    const wc = Wechat.init();
    try std.testing.expect(wc.cache == null);
}

test "Wechat.setCache 缓存生效" {
    const allocator = std.testing.allocator;
    var wc = Wechat.init();
    try std.testing.expect(wc.cache == null);

    // 通过 `Memory.create` + `asCache()` 拿到一个真实的 Cache 实例，
    // 再交给 setCache；随后断言 `wc.cache` 字段被实际写入。
    const mem = try cache_mod.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    wc.setCache(mem.asCache());
    try std.testing.expect(wc.cache != null);
}