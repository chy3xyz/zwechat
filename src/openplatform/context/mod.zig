// SPDX-License-Identifier: Apache-2.0
//! openplatform/context — 开放平台（第三方平台）调用上下文
//!
//! 对应 `_ref/wechat/openplatform/context/context.go` 的 `Context`：
//! 在 Go 中仅嵌入 `*config.Config`，并在其 `accessToken.go` 内挂载一组
//! 与 component 平台有关的 token / preauthcode / authorizer 接口。
//!
//! Zig 版把 token 状态直接放到 Context 内（`access_token: ?[]const u8`），
//! 与上游 Go 端 `GetComponentAccessToken` 行为对齐：先返回缓存值，
//! 未命中时由调用方在收到 `SetComponentAccessToken` 后回填。

const std = @import("std");
const default_io = @import("../../util/default_io.zig");

const Config = @import("../config.zig").Config;

/// token 互斥量：**对外保持零参数 `lock()` / `unlock()`**，内部是
/// `std.Io.Mutex`（真阻塞的 futex 锁）。
///
/// 为什么保留零参数签名：`token_mutex` 的调用点在 `access_token.zig` /
/// `auth.zig`（`ctx.token_mutex.lock()` / `.unlock()`），本次迁移不动那两个文件；
/// 包装层让「自旋」换成「阻塞」而调用点零改动。
///
/// 原实现是 `util/sync.zig` 的 CAS 自旋锁，而这里**刻意持锁跨越
/// authorizer 刷新的 HTTP 往返**（见 `Context.token_mutex` 注释），
/// 自旋锁在长临界区里会把等待者整个时间片烧在 CPU 上空转——这正是迁移到
/// futex 阻塞锁收益最大的地方。
pub const TokenMutex = struct {
    /// futex 等待 / 唤醒所用的 `Io` 句柄，可注入（默认 `default_io.io()`，
    /// 其 futex 路径不依赖实例状态）。
    io: std.Io = default_io.io(),
    /// 真正的互斥量。非递归：同一线程重复 `lock` 会死锁。
    mutex: std.Io.Mutex = .init,

    /// 获取锁，阻塞直到成功（futex 等待，不空转）。
    pub fn lock(self: *TokenMutex) void {
        self.mutex.lockUncancelable(self.io);
    }

    /// 释放锁。锁必须已被当前线程持有。
    pub fn unlock(self: *TokenMutex) void {
        self.mutex.unlock(self.io);
    }

    /// 尝试获取锁，不阻塞。返回 `true` 表示获取成功。
    pub fn tryLock(self: *TokenMutex) bool {
        return self.mutex.tryLock();
    }
};

/// 开放平台（第三方平台）调用上下文。
///
/// 设计要点：
/// - 持有不可变 `Config`（调用方持有原 slice 的所有权）。
/// - `access_token` 字段是"component_access_token"，用于开放平台内部接口
///   （`/cgi-bin/component/*`），与"authorizer_access_token"（被授权方的 token）
///   不是一回事。后者由 `getAuthrAccessToken` / `refreshAuthrAccessToken`
///   按 `authorizer_appid` 单独管理。
/// - `setAccessToken` / `getAccessToken` 是最小可用的存取接口，调用方负责
///   在拉取新 token 后调用 `setAccessToken` 回填。
pub const Context = struct {
    /// 开放平台配置（不可变引用）。
    config: Config,
    /// 当前的 component_access_token（`null` 表示尚未获取）。
    access_token: ?[]const u8 = null,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP；
    /// 与 `officialaccount/menu` 等模块的惯例一致，生产环境保持 `null`）。
    transport: ?@import("../../util/http.zig").HttpClient.Transport = null,
    /// `transport` 被调用时透传的不透明上下文。
    transport_ctx: ?*anyopaque = null,

    /// token 获取互斥锁：串行化 component / authorizer token 的「缓存 miss →
    /// 回源 → 回写」链路（锁内双检，持锁回源）。
    ///
    /// **刻意持锁跨 HTTP**：authorizer 刷新会轮换 `refresh_token`（新值回存缓存），
    /// 并发刷新互相覆盖会永久丢失凭据；单实例回源串行化是刻意的取舍。
    ///
    /// 锁已从 CAS 自旋迁移为 `std.Io.Mutex`（真阻塞的 futex 锁，见 `TokenMutex`）：
    /// 临界区含 HTTP 往返时，等待者在内核 futex 上睡眠而不是空转烧 CPU。
    /// 持锁跨 HTTP 的语义**没有变**——只是等待方式从「自旋」变成「阻塞」。
    /// `io`（futex 等待 / 唤醒）在锁自身字段上：`token_mutex.io`，
    /// 需要注入宿主运行时 Io 时写 `.token_mutex = .{ .io = my_io }`。
    token_mutex: TokenMutex = .{},

    /// 写入新的 component_access_token。
    ///
    /// 注：本骨架仅做赋值语义；Go 版还会把 token 写进 `cache.Cache`（TTL = expires_in - 1500），
    /// 后续 pass 在引入完整 SetComponentAccessToken 流程时再补齐。
    pub fn setAccessToken(self: *Context, token: []const u8) void {
        self.access_token = token;
    }

    /// 取出当前缓存的 component_access_token。
    ///
    /// 返回 `null` 表示尚未获取过 token。调用方拿到 `null` 后应通过
    /// `SetComponentAccessToken`（后续 pass 实现）从微信服务端拉取并回填。
    pub fn getAccessToken(self: *const Context) ?[]const u8 {
        return self.access_token;
    }

    /// 获取或刷新 component_access_token。
    ///
    /// `verify_ticket` 是微信第三方平台推送的「票据」，每次换取 token 时必填。
    /// 结果会写入 `config.cache`；命中缓存时直接返回。
    pub fn getComponentAccessToken(
        self: *Context,
        allocator: std.mem.Allocator,
        verify_ticket: []const u8,
    ) ![]u8 {
        return @import("access_token.zig").getComponentAccessToken(self, allocator, verify_ticket);
    }

    /// 获取被授权方（公众号 / 小程序）的 `authorizer_access_token`。
    ///
    /// 对照 Go 端 `GetAuthrAccessTokenContext`：
    /// 1. 以 `authorizer_access_token_{appid}` 为 key 查缓存，命中直接返回；
    /// 2. 未命中时从缓存读 `authorizer_refresh_token_{appid}`（首次授权由
    ///    `QueryAuthCode` 写入），再用 `refreshAuthrAccessToken` 刷新。
    ///
    /// 返回的 token 由调用方负责 `allocator.free`。
    pub fn getAuthrAccessToken(
        self: *Context,
        allocator: std.mem.Allocator,
        authorizer_appid: []const u8,
    ) @import("access_token.zig").Error![]u8 {
        return @import("access_token.zig").getAuthrAccessToken(self, allocator, authorizer_appid);
    }

    /// 用 `authorizer_refresh_token` 刷新被授权方的接口调用凭据。
    ///
    /// 对照 Go 端 `RefreshAuthrTokenContext`：
    /// - URL：`POST /cgi-bin/component/api_authorizer_token?component_access_token={s}`
    /// - 新 access_token 按 `authorizer_access_token_{appid}` 缓存（TTL 钳制），
    ///   新 refresh_token 按 `authorizer_refresh_token_{appid}` 缓存 10 年并回存。
    ///
    /// `verify_ticket` 仅在 component token 缓存未命中时用于回源换取；
    /// 缓存命中时该参数不参与网络请求。
    ///
    /// 返回结构体内字段由 `AuthrAccessToken.deinit` 释放。
    pub fn refreshAuthrAccessToken(
        self: *Context,
        allocator: std.mem.Allocator,
        verify_ticket: []const u8,
        authorizer_appid: []const u8,
        authorizer_refresh_token: []const u8,
    ) @import("access_token.zig").Error!@import("access_token.zig").AuthrAccessToken {
        return @import("access_token.zig").refreshAuthrAccessToken(
            self,
            allocator,
            verify_ticket,
            authorizer_appid,
            authorizer_refresh_token,
        );
    }

    /// 获取预授权码 `pre_auth_code`（Go `GetPreCode`）。
    ///
    /// component_access_token 仅读缓存；未命中返回 `error.VerifyTicketRequired`，
    /// 调用方应先带 `verify_ticket` 调 `getComponentAccessToken` 回源。
    /// 返回的字符串由调用方负责 `allocator.free`。
    pub fn getPreCode(
        self: *Context,
        allocator: std.mem.Allocator,
    ) @import("auth.zig").Error![]u8 {
        return @import("auth.zig").getPreCode(self, allocator);
    }

    /// 用授权码换取授权方的接口调用凭据和授权信息（Go `QueryAuthCode`）。
    ///
    /// 成功后按 `authorizer_appid` 回写 `authorizer_access_token_{appid}` /
    /// `authorizer_refresh_token_{appid}` 两个缓存 key（锁内串行），
    /// 后续可直接用 `getAuthrAccessToken` 消费。返回结构体由 `deinit` 释放。
    pub fn queryAuthCode(
        self: *Context,
        allocator: std.mem.Allocator,
        authorization_code: []const u8,
    ) @import("auth.zig").Error!@import("auth.zig").AuthBaseInfo {
        return @import("auth.zig").queryAuthCode(self, allocator, authorization_code);
    }

    /// 获取授权方的帐号基本信息（Go `GetAuthrInfo`）。
    ///
    /// 返回 `std.json.Parsed(AuthrInfoResponse)`：`.value` 内全部切片借用其
    /// 所有权域，调用方读完之后 `deinit` 即可。
    pub fn getAuthrInfo(
        self: *Context,
        allocator: std.mem.Allocator,
        authorizer_appid: []const u8,
    ) @import("auth.zig").Error!std.json.Parsed(@import("auth.zig").AuthrInfoResponse) {
        return @import("auth.zig").getAuthrInfo(self, allocator, authorizer_appid);
    }

    /// 构造第三方平台扫码授权链接（Go `GetComponentLoginPage`）。
    ///
    /// 内部先取 `pre_auth_code`（一次 HTTP），再纯本地拼链接；
    /// `redirect_uri` 按 URI query 规则转义。返回的链接由调用方 `allocator.free`。
    pub fn getComponentLoginPage(
        self: *Context,
        allocator: std.mem.Allocator,
        redirect_uri: []const u8,
        auth_type: i64,
        biz_app_id: []const u8,
    ) @import("auth.zig").Error![]u8 {
        return @import("auth.zig").getComponentLoginPage(self, allocator, redirect_uri, auth_type, biz_app_id);
    }

    /// 构造链接跳转授权链接（移动端，Go `GetBindComponentURL`）。
    pub fn getBindComponentURL(
        self: *Context,
        allocator: std.mem.Allocator,
        redirect_uri: []const u8,
        auth_type: i64,
        biz_app_id: []const u8,
    ) @import("auth.zig").Error![]u8 {
        return @import("auth.zig").getBindComponentURL(self, allocator, redirect_uri, auth_type, biz_app_id);
    }

    /// 构造新版链接跳转授权链接（移动端，Go `GetBindComponentURLV2`）。
    pub fn getBindComponentURLV2(
        self: *Context,
        allocator: std.mem.Allocator,
        redirect_uri: []const u8,
        auth_type: i64,
        biz_app_id: []const u8,
    ) @import("auth.zig").Error![]u8 {
        return @import("auth.zig").getBindComponentURLV2(self, allocator, redirect_uri, auth_type, biz_app_id);
    }
};

// 编译门：确保 auth.zig（首次授权链路）被分析，其 inline test 被发现。
test "auth 模块导出（编译门）" {
    const auth = @import("auth.zig");
    try std.testing.expect(@hasDecl(auth, "getPreCode"));
    try std.testing.expect(@hasDecl(auth, "queryAuthCode"));
    try std.testing.expect(@hasDecl(auth, "getAuthrInfo"));
    try std.testing.expect(@hasDecl(auth, "getComponentLoginPage"));
    try std.testing.expect(@hasDecl(auth, "getBindComponentURL"));
    try std.testing.expect(@hasDecl(auth, "getBindComponentURLV2"));
    try std.testing.expect(@hasDecl(auth, "AuthBaseInfo"));
    try std.testing.expect(@hasDecl(auth, "AuthorizerInfo"));
}

test "Context 默认值" {
    const ctx = Context{ .config = .{} };
    try std.testing.expectEqualStrings("", ctx.config.app_id);
    try std.testing.expectEqualStrings("", ctx.config.app_secret);
    try std.testing.expect(ctx.access_token == null);
}

test "Context 自定义配置 + token 存取" {
    var ctx = Context{
        .config = .{
            .app_id = "wx-op-ctx",
            .app_secret = "ctx-secret",
            .token = "ctx-token",
        },
        .access_token = null,
    };
    try std.testing.expectEqualStrings("wx-op-ctx", ctx.config.app_id);
    try std.testing.expect(ctx.getAccessToken() == null);

    ctx.setAccessToken("comp-ak-xyz");
    try std.testing.expect(ctx.getAccessToken() != null);
    try std.testing.expectEqualStrings("comp-ak-xyz", ctx.getAccessToken().?);

    // 覆写语义
    ctx.setAccessToken("comp-ak-rotated");
    try std.testing.expectEqualStrings("comp-ak-rotated", ctx.getAccessToken().?);
}

test "Context.getComponentAccessToken 需要 cache" {
    var ctx = Context{
        .config = .{ .app_id = "wx-op", .app_secret = "s" },
    };
    const result = ctx.getComponentAccessToken(std.testing.allocator, "ticket");
    try std.testing.expectError(error.CacheUnavailable, result);
}

test "TokenMutex 已迁移为 std.Io.Mutex：持锁期间同线程 tryLock 返回 false" {
    // 取证：`token_mutex` 不再自旋——底层是 `std.Io.Mutex`，`tryLock` 无参数；
    // 持锁时同线程再取锁会阻塞，这里用 tryLock 断言替代死锁测试。
    var m: TokenMutex = .{};
    m.lock();
    try std.testing.expect(!m.tryLock());
    m.unlock();

    try std.testing.expect(m.tryLock());
    m.unlock();

    // `io` 可注入（默认 `default_io.io()`）。
    var injected: TokenMutex = .{ .io = default_io.io() };
    injected.lock();
    injected.unlock();

    // Context 上的字段也走同一实现（零参数 `lock()` / `unlock()` 调用点不变）。
    var ctx = Context{ .config = .{} };
    ctx.token_mutex.lock();
    ctx.token_mutex.unlock();
}
