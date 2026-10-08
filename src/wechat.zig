// SPDX-License-Identifier: Apache-2.0
//! wechat — 顶层 Wechat struct
//!
//! 对应 `_ref/wechat/wechat.go`：聚合官方账号、小程序、支付、开放平台、
//! 企业微信等子模块，提供 `init` / `setCache` / `getOfficialAccount` /
//! `getMiniProgram` / `getPay` / `getWork` / `getOpenPlatform` 入口。
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
//! const oa = try wc.getOfficialAccount(allocator, cfg, defaultAccessTokenFactory);
//! ```
//!
//! 其中 `default_access_token_factory` 由调用方提供，典型实现如下：
//!
//! ```zig
//! fn defaultAccessTokenFactory(
//!     cfg: officialaccount.Config,
//!     c: cache.Cache,
//! ) anyerror!credential.AccessTokenHandle {
//!     // ⚠️ 所有权：`handle.ptr` 指向 `DefaultAccessToken` 实例本身，
//!     // 该实例必须活到 handle 不再被使用（通常与 OfficialAccount 同生命周期）。
//!     // 绝不要返回指向栈上临时变量的 handle —— 函数返回后即悬垂。
//!     const dat = try allocator.create(credential.DefaultAccessToken);
//!     dat.* = credential.DefaultAccessToken.init(
//!         cfg.app_id,
//!         cfg.app_secret,
//!         credential.CacheKeyOfficialAccountPrefix,
//!         c,
//!     );
//!     return dat.asHandle();
//! }
//! ```

const std = @import("std");
const cache_mod = @import("cache/mod.zig");
const officialaccount_mod = @import("officialaccount/mod.zig");
const credential_mod = @import("credential/mod.zig");
const work_mod = @import("work/mod.zig");
const pay_mod = @import("pay/mod.zig");
const miniprogram_mod = @import("miniprogram/mod.zig");
const openplatform_mod = @import("openplatform/mod.zig");

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

    pub const GetWorkError = error{CacheUnavailable};

    /// 获取企业微信实例。
    ///
    /// `cfg.cache` 为空时使用 `Wechat` 全局 cache；两者都为空则返回 `error.CacheUnavailable`。
    pub fn getWork(
        self: *Wechat,
        allocator: std.mem.Allocator,
        cfg: work_mod.Config,
    ) (GetWorkError || anyerror)!work_mod.Work {
        var resolved_cfg = cfg;
        resolved_cfg.cache = cfg.cache orelse self.cache orelse return error.CacheUnavailable;
        return work_mod.Work.newDefaultWork(resolved_cfg, allocator);
    }

    /// 获取微信支付实例。
    ///
    /// 微信支付当前不依赖 cache，因此直接返回实例。
    pub fn getPay(self: *Wechat, cfg: pay_mod.Config) pay_mod.Pay {
        _ = self;
        return pay_mod.Pay.init(cfg);
    }

    pub const GetMiniProgramError = error{CacheUnavailable};

    /// 获取小程序实例。
    ///
    /// `default_access_token_factory` 与 `getOfficialAccount` 的工厂参数语义一致。
    pub fn getMiniProgram(
        self: *Wechat,
        allocator: std.mem.Allocator,
        cfg: miniprogram_mod.Config,
        default_access_token_factory: *const fn (
            cfg: miniprogram_mod.Config,
            cache: cache_mod.Cache,
        ) anyerror!credential_mod.AccessTokenHandle,
    ) (GetMiniProgramError || anyerror)!miniprogram_mod.MiniProgram {
        const resolved_cache = cfg.cache orelse self.cache orelse return error.CacheUnavailable;
        var resolved_cfg = cfg;
        resolved_cfg.cache = resolved_cache;
        const handle = try default_access_token_factory(resolved_cfg, resolved_cache);
        return miniprogram_mod.MiniProgram.init(allocator, resolved_cfg, handle);
    }

    pub const GetOpenPlatformError = error{CacheUnavailable};

    /// 获取开放平台（第三方平台）实例。
    pub fn getOpenPlatform(
        self: *Wechat,
        cfg: openplatform_mod.Config,
    ) GetOpenPlatformError!openplatform_mod.OpenPlatform {
        var resolved_cfg = cfg;
        resolved_cfg.cache = cfg.cache orelse self.cache orelse return error.CacheUnavailable;
        return openplatform_mod.OpenPlatform.newOpenPlatform(resolved_cfg);
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

test "Wechat.getPay 返回 Pay 实例" {
    var wc = Wechat.init();
    const p = wc.getPay(.{ .app_id = "wx-pay", .mch_id = "123" });
    try std.testing.expectEqualStrings("wx-pay", p.cfg.app_id);
}

test "Wechat.getOpenPlatform 注入全局 cache" {
    const allocator = std.testing.allocator;
    const mem = try cache_mod.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }
    var wc = Wechat.init();
    wc.setCache(mem.asCache());
    const op = try wc.getOpenPlatform(.{ .app_id = "wx-op" });
    try std.testing.expect(op.ctx.config.cache != null);
}

test "Wechat.getWork 无 cache 返回 CacheUnavailable" {
    var wc = Wechat.init();
    const result = wc.getWork(std.testing.allocator, .{ .corp_id = "ww" });
    try std.testing.expectError(error.CacheUnavailable, result);
}

test "Wechat.getMiniProgram 无 cache 返回 CacheUnavailable" {
    var wc = Wechat.init();
    const result = wc.getMiniProgram(
        std.testing.allocator,
        .{ .app_id = "wx-mp" },
        undefined,
    );
    try std.testing.expectError(error.CacheUnavailable, result);
}

// ─────────────────────────────────────────────────────────────────────────────
// getOfficialAccount（此前零调用）
// ─────────────────────────────────────────────────────────────────────────────

/// 测试用 access_token 工厂：把 handle 指向一个进程级静态实例，
/// 避免「工厂内 `allocator.create` 但无人 `destroy`」造成的测试内存泄漏。
var g_test_oa_token: credential_mod.DefaultAccessToken = undefined;
/// 工厂被调用时实际收到的 cache（用于断言「全局 cache 已回退注入」）。
var g_test_oa_factory_cache: ?cache_mod.Cache = null;
var g_test_oa_factory_calls: usize = 0;

fn testOfficialAccountTokenFactory(
    cfg: officialaccount_mod.Config,
    c: cache_mod.Cache,
) anyerror!credential_mod.AccessTokenHandle {
    g_test_oa_token = credential_mod.DefaultAccessToken.init(
        cfg.app_id,
        cfg.app_secret,
        credential_mod.CacheKeyOfficialAccountPrefix,
        c,
    );
    g_test_oa_factory_cache = c;
    g_test_oa_factory_calls += 1;
    return g_test_oa_token.asHandle();
}

fn failingOfficialAccountTokenFactory(
    _: officialaccount_mod.Config,
    _: cache_mod.Cache,
) anyerror!credential_mod.AccessTokenHandle {
    return error.FactoryBoom;
}

test "Wechat.getOfficialAccount 无 cache（cfg 与全局都为空）返回 CacheUnavailable" {
    var wc = Wechat.init();
    const result = wc.getOfficialAccount(
        std.testing.allocator,
        .{ .app_id = "wx-oa", .app_secret = "s" },
        testOfficialAccountTokenFactory,
    );
    try std.testing.expectError(error.CacheUnavailable, result);
}

test "Wechat.getOfficialAccount 回退到全局 cache 并据此构造 Context" {
    const allocator = std.testing.allocator;
    const mem = try cache_mod.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    g_test_oa_factory_cache = null;
    g_test_oa_factory_calls = 0;

    var wc = Wechat.init();
    wc.setCache(mem.asCache());

    var oa = try wc.getOfficialAccount(
        allocator,
        .{ .app_id = "wx-oa", .app_secret = "s" },
        testOfficialAccountTokenFactory,
    );

    // 工厂被调用一次，且收到的是「解析后」的 cache（cfg.cache 为空 → 回退全局）。
    try std.testing.expectEqual(@as(usize, 1), g_test_oa_factory_calls);
    try std.testing.expect(g_test_oa_factory_cache.?.ctx == mem.asCache().ctx);

    const ctx = oa.getContext();
    try std.testing.expectEqualStrings("wx-oa", ctx.config.app_id);
    try std.testing.expectEqualStrings("s", ctx.config.app_secret);
    try std.testing.expect(ctx.config.cache != null);
    try std.testing.expect(ctx.config.cache.?.ctx == mem.asCache().ctx);
}

test "Wechat.getOfficialAccount 的 cfg.cache 优先于全局 cache" {
    const allocator = std.testing.allocator;
    const global_mem = try cache_mod.Memory.create(allocator);
    defer {
        global_mem.deinit();
        allocator.destroy(global_mem);
    }
    const cfg_mem = try cache_mod.Memory.create(allocator);
    defer {
        cfg_mem.deinit();
        allocator.destroy(cfg_mem);
    }

    g_test_oa_factory_cache = null;

    var wc = Wechat.init();
    wc.setCache(global_mem.asCache());

    var oa = try wc.getOfficialAccount(
        allocator,
        .{ .app_id = "wx-oa-pref", .cache = cfg_mem.asCache() },
        testOfficialAccountTokenFactory,
    );
    try std.testing.expect(g_test_oa_factory_cache.?.ctx == cfg_mem.asCache().ctx);
    try std.testing.expect(oa.getContext().config.cache.?.ctx == cfg_mem.asCache().ctx);
}

test "Wechat.getOfficialAccount 传播工厂抛出的错误" {
    const allocator = std.testing.allocator;
    const mem = try cache_mod.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    var wc = Wechat.init();
    wc.setCache(mem.asCache());
    const result = wc.getOfficialAccount(
        allocator,
        .{ .app_id = "wx-oa-err" },
        failingOfficialAccountTokenFactory,
    );
    try std.testing.expectError(error.FactoryBoom, result);
}
