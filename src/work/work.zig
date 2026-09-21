// SPDX-License-Identifier: Apache-2.0
//! work/work — 企业微信顶层 Work struct
//!
//! 对应 `_ref/wechat/work/work.go` 的 `Work` struct：聚合企业微信全部子模块
//! （externalcontact / invoice / addresslist / appchat / robot / oauth / jsapi 等）
//! 的运行时入口；各子模块通过 `getXxx` 懒加载工厂按需构造。

const std = @import("std");
const cache = @import("../cache/mod.zig");
const credential = @import("../credential/mod.zig");
const Config = @import("config.zig").Config;
const Context = @import("context/mod.zig").Context;
const jsapi = @import("jsapi/mod.zig");
const oauth = @import("oauth/mod.zig");
const message = @import("message/mod.zig");
const externalcontact = @import("externalcontact/mod.zig");
const invoice = @import("invoice/mod.zig");
const addresslist = @import("addresslist/mod.zig");
const appchat = @import("appchat/mod.zig");
const checkin = @import("checkin/mod.zig");
const kf = @import("kf/mod.zig");
const material = @import("material/mod.zig");
const msgaudit = @import("msgaudit/mod.zig");
const robot = @import("robot/mod.zig");
const server = @import("server/mod.zig");
const smartbot = @import("smartbot/mod.zig");

/// 企业微信业务 API 聚合入口。
///
/// 构造完成后可重复调用 `getAccessToken` / `getJsTicket` 拿到当前可用的 token 与
/// ticket；子模块（如 oauth / jsapi 等）将在后续阶段以懒加载方法的形式补齐。
///
/// ⚠️ **地址稳定性警告**：`Work` 实例一旦被 `getJs()` / 各 `getXxx()` 工厂使用，
/// 其内存地址就必须保持稳定——派生的子模块持有 `&self.ctx` 裸指针，`getJs()`
/// 注入的 `WorkJsTicketAdapter` 也持有 `*Work`。**禁止把 `Work` 按值拷贝 / 移动**
/// （包括从函数按值返回后再取地址、放入会搬迁的 ArrayList 等），
/// 否则已派生的 `Js` / 子模块会悬垂。需要传递时请使用 `*Work` 指针，
/// 并把 `Work` 放在 `var` 局部变量 / 堆上固定位置。
pub const Work = struct {
    ctx: Context,
    /// 缓存当前正在使用的 WorkJsTicket（按 agent_id 区分 corp / agent）。
    /// 当 `ctx.js_ticket_handle == null` 且 `ctx.config.cache != null` 时，
    /// `getJsTicket` 会懒加载并缓存到这里。
    work_ticket_cache: ?credential.WorkJsTicket = null,
    /// 当前默认 ticket 类型（corp / agent）。
    default_ticket_type: credential.TicketType = .corp_js,
    /// corp ticket 适配器（由 `getJs()` 初始化并复用）。
    corp_js_adapter: ?WorkJsTicketAdapter = null,
    /// agent ticket 适配器（由 `getJs()` 初始化并复用）。
    agent_js_adapter: ?WorkJsTicketAdapter = null,
    /// `newDefaultWork` 分配的 `WorkAccessToken` box（仅该路径非空）。
    /// `deinit` 时释放；`init` / `newWork` 构造的实例此字段为 null。
    owned_access_token: ?*credential.WorkAccessToken = null,

    /// 通过已构造好的 `Context` 直接组装实例。
    pub fn init(ctx: Context) Work {
        return .{ .ctx = ctx };
    }

    /// 一步构造：`Config` + 已构建好的 `AccessTokenHandle` + 可选 JsTicketHandle。
    pub fn newWork(
        cfg: Config,
        access_token_handle: credential.AccessTokenHandle,
        js_ticket_handle: ?credential.JsTicketHandle,
    ) Work {
        return .{ .ctx = .{
            .config = cfg,
            .access_token_handle = access_token_handle,
            .js_ticket_handle = js_ticket_handle,
        } };
    }

    /// 工厂方法：用 `cfg`（含 corp_id/corp_secret/agent_id/cache）自动构造
    /// `WorkAccessToken` + 懒加载 `WorkJsTicket`，开箱即用。
    ///
    /// 调用方无需手动构造 `DefaultAccessToken` 之类的实例；首次调用
    /// `getAccessToken` / `getJsTicket` 时会从缓存或服务端拉取。
    ///
    /// `cfg.cache` 必须非 null，否则返回 `error.CacheUnavailable`。
    pub fn newDefaultWork(cfg: Config, alloc: std.mem.Allocator) !Work {
        const cache_inst = cfg.cache orelse return error.CacheUnavailable;
        var w = Work{
            .ctx = .{
                .config = cfg,
                .access_token_handle = undefined,
                .js_ticket_handle = null,
            },
            .work_ticket_cache = credential.WorkJsTicket.init(
                cfg.corp_id,
                cfg.agent_id,
                credential.CacheKeyWorkPrefix,
                cache_inst,
            ),
        };
        // 构造 WorkAccessToken 实例，搬到分配器拥有的内存（避免 w 栈失效）。
        const ak_box = try alloc.create(credential.WorkAccessToken);
        ak_box.* = credential.WorkAccessToken.init(
            cfg.corp_id,
            cfg.corp_secret,
            credential.CacheKeyWorkPrefix,
            cache_inst,
        );
        // 把 box 的指针包成抽象 handle
        w.ctx.access_token_handle = .{
            .ptr = @ptrCast(ak_box),
            .vtable = &work_access_token_handle_vtable,
        };
        w.owned_access_token = ak_box;
        return w;
    }

    /// 释放 `newDefaultWork` 分配的 access_token box。
    ///
    /// `allocator` 必须与构造时传入 `newDefaultWork` 的 allocator 一致。
    /// 对 `init` / `newWork` 构造的实例是空操作（无堆资源）。
    /// 注意：`config.cache` 指向的缓存实例由调用方持有并自行释放，不在此处处理。
    pub fn deinit(self: *Work, allocator: std.mem.Allocator) void {
        if (self.owned_access_token) |box| {
            allocator.destroy(box);
            self.owned_access_token = null;
        }
    }

    /// 返回内部 `Context` 指针。
    pub fn getContext(self: *Work) *Context {
        return &self.ctx;
    }

    /// 构造 `jsapi.Js` 子模块，并自动注入 corp / agent 两种 ticket handle。
    ///
    /// 调用方拿到 `Js` 后可直接调用 `getConfig`（corp）或 `getAgentConfig`（agent），
    /// 无需手动 `setJsTicketHandle`。
    ///
    /// ⚠️ **生命周期警告**：返回的 `Js` 内部持有指向本 `Work` 实例
    /// （`&self.ctx` 以及 `self` 上的 `WorkJsTicketAdapter`）的裸指针。
    /// 调用方必须保证 `Work` 实例的地址在 `Js` 存活期内保持稳定：
    /// 禁止在调用 `getJs()` 后移动 / 按值拷贝 `Work`，否则 `Js` 内的指针悬空。
    pub fn getJs(self: *Work) jsapi.Js {
        if (self.corp_js_adapter == null) {
            self.corp_js_adapter = WorkJsTicketAdapter.init(self, .corp_js);
        }
        if (self.agent_js_adapter == null) {
            self.agent_js_adapter = WorkJsTicketAdapter.init(self, .agent_js);
        }
        var j = jsapi.Js.init(&self.ctx);
        j.setJsTicketHandle(self.corp_js_adapter.?.asHandle());
        j.setAgentJsTicketHandle(self.agent_js_adapter.?.asHandle());
        return j;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 子模块懒加载工厂（与 Go 参考的 GetXxx 对齐）
    // ─────────────────────────────────────────────────────────────────────────

    pub fn getOauth(self: *Work, allocator: std.mem.Allocator) oauth.Oauth {
        return oauth.Oauth.init(&self.ctx, allocator);
    }
    pub fn getMessage(self: *Work, allocator: std.mem.Allocator) message.Message {
        return message.Message.init(&self.ctx, allocator);
    }
    pub fn getExternalContact(self: *Work, allocator: std.mem.Allocator) externalcontact.ExternalContact {
        return externalcontact.ExternalContact.init(&self.ctx, allocator);
    }
    pub fn getInvoice(self: *Work, allocator: std.mem.Allocator) invoice.Invoice {
        return invoice.Invoice.init(&self.ctx, allocator);
    }
    pub fn getAddressList(self: *Work, allocator: std.mem.Allocator) addresslist.AddressList {
        return addresslist.AddressList.init(&self.ctx, allocator);
    }
    pub fn getAppChat(self: *Work, allocator: std.mem.Allocator) appchat.AppChat {
        return appchat.AppChat.init(&self.ctx, allocator);
    }
    pub fn getCheckin(self: *Work, allocator: std.mem.Allocator) checkin.Checkin {
        return checkin.Checkin.init(&self.ctx, allocator);
    }
    pub fn getKf(self: *Work, allocator: std.mem.Allocator) kf.Kf {
        return kf.Kf.init(&self.ctx, allocator);
    }
    pub fn getMaterial(self: *Work, allocator: std.mem.Allocator) material.Material {
        return material.Material.init(&self.ctx, allocator);
    }
    pub fn getMsgAudit(self: *Work, allocator: std.mem.Allocator) msgaudit.MsgAudit {
        return msgaudit.MsgAudit.init(&self.ctx, allocator);
    }
    pub fn getRobot(self: *Work, allocator: std.mem.Allocator) robot.Robot {
        _ = self; // webhook 机器人不需要 ctx
        return robot.Robot.init(allocator);
    }
    pub fn getServer(self: *Work) server.WorkServer {
        return server.WorkServer.init(&self.ctx);
    }
    pub fn getSmartbot(self: *Work, allocator: std.mem.Allocator) smartbot.Server {
        return smartbot.Server.init(&self.ctx, allocator);
    }

    /// 获取 access_token。
    pub fn getAccessToken(
        self: *Work,
        allocator: std.mem.Allocator,
    ) @TypeOf(self.ctx.getAccessToken(allocator)) {
        return self.ctx.getAccessToken(allocator);
    }

    /// 设置默认 ticket 类型（corp / agent）。
    pub fn setDefaultTicketType(self: *Work, ticket_type: credential.TicketType) void {
        self.default_ticket_type = ticket_type;
    }

    /// 注入自定义 JsTicketHandle（覆盖默认行为）。
    pub fn setJsTicketHandle(self: *Work, h: credential.JsTicketHandle) void {
        self.ctx.js_ticket_handle = h;
    }

    /// 获取企业微信 jsapi_ticket（遵循 `default_ticket_type`）。
    ///
    /// 三级回退：
    /// 1. `ctx.js_ticket_handle`（用户注入）；
    /// 2. 内部缓存的 `WorkJsTicket`（corp / agent 由 `default_ticket_type` 决定）；
    /// 3. 懒加载 `WorkJsTicket`（要求 `config.cache != null`，否则 `CacheUnavailable`）。
    pub fn getJsTicket(
        self: *Work,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) ![]u8 {
        if (self.ctx.js_ticket_handle) |h| {
            return h.getTicket(allocator, access_token);
        }
        return self.getJsTicketFromCache(allocator, access_token, self.default_ticket_type);
    }

    /// 获取 corp 类型 jsapi_ticket（忽略 `default_ticket_type` 与 `ctx.js_ticket_handle`）。
    pub fn getCorpJsTicket(
        self: *Work,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) ![]u8 {
        return self.getJsTicketFromCache(allocator, access_token, .corp_js);
    }

    /// 获取 agent 类型 jsapi_ticket（忽略 `default_ticket_type` 与 `ctx.js_ticket_handle`）。
    pub fn getAgentJsTicket(
        self: *Work,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) ![]u8 {
        return self.getJsTicketFromCache(allocator, access_token, .agent_js);
    }

    fn getJsTicketFromCache(
        self: *Work,
        allocator: std.mem.Allocator,
        access_token: []const u8,
        ticket_type: credential.TicketType,
    ) ![]u8 {
        try self.ensureTicketCache();
        return self.work_ticket_cache.?.getTicket(allocator, access_token, ticket_type);
    }

    /// 按类型作废缓存中的 jsapi_ticket，使下一次取值必须回源。
    ///
    /// **必须与 `getCorpJsTicket` / `getAgentJsTicket` 成对使用**：这两个取值入口
    /// 走的是缓存侧 `WorkJsTicket`（忽略 `ctx.js_ticket_handle`），因此作废也只能
    /// 清缓存侧的 key——用 `WorkJsTicket.invalidate(allocator, ticket_type)` 精确
    /// 清当前类型，另一种 ticket 由微信分别签发、有效期互不相关，保留其缓存避免
    /// 无谓回源（需要两者一起清时用 `WorkJsTicket.invalidateAll`）。
    ///
    /// `config.cache` 为空时返回 `error.CacheUnavailable`（与取值路径一致）；
    /// 键不存在不是错误（`cache.delete` 契约）。
    pub fn invalidateJsTicket(
        self: *Work,
        allocator: std.mem.Allocator,
        ticket_type: credential.TicketType,
    ) !void {
        try self.ensureTicketCache();
        try self.work_ticket_cache.?.invalidate(allocator, ticket_type);
    }

    /// 惰性构造缓存侧 `WorkJsTicket`；`config.cache == null` 时返回
    /// `error.CacheUnavailable`（`Work` 自己无法凭空造出缓存后端）。
    fn ensureTicketCache(self: *Work) !void {
        const cache_inst = self.ctx.config.cache orelse return error.CacheUnavailable;
        if (self.work_ticket_cache == null) {
            self.work_ticket_cache = credential.WorkJsTicket.init(
                self.ctx.config.corp_id,
                self.ctx.config.agent_id,
                credential.CacheKeyWorkPrefix,
                cache_inst,
            );
        }
    }
};

// 包装 `*Work` 与 `TicketType` 的 `JsTicketHandle` 实现。
//
// 生命周期：adapter 必须与 `Work` 实例共存；`Work.getJs()` 会把 adapter
// 存放在 `Work` 内部字段，避免栈逃逸。
pub const WorkJsTicketAdapter = struct {
    work: *Work,
    ticket_type: credential.TicketType,

    pub fn init(work: *Work, ticket_type: credential.TicketType) WorkJsTicketAdapter {
        return .{
            .work = work,
            .ticket_type = ticket_type,
        };
    }

    pub fn asHandle(self: *WorkJsTicketAdapter) credential.JsTicketHandle {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &work_js_ticket_vtable,
        };
    }

    fn getTicket(ctx: *anyopaque, allocator: std.mem.Allocator, access_token: []const u8) anyerror![]u8 {
        const adapter: *WorkJsTicketAdapter = @ptrCast(@alignCast(ctx));
        return switch (adapter.ticket_type) {
            .corp_js => adapter.work.getCorpJsTicket(allocator, access_token),
            .agent_js => adapter.work.getAgentJsTicket(allocator, access_token),
        };
    }

    /// 作废本 adapter 所属类型的 ticket。
    ///
    /// 只清 `adapter.ticket_type` 对应的那一个缓存 key，而不是 `invalidateAll`：
    /// adapter 是**类型化**的（`getTicket` 只会取 `.corp_js` 或 `.agent_js`），
    /// 作废范围必须与取值范围严丝合缝——从 corp handle 作废时顺手清掉 agent key
    /// 会让 agent 侧凭空多一次回源，而 agent ticket 的失效由它自己的 handle 负责。
    /// 另外 corp-only 配置（`agent_id` 为空）下，`invalidateAll` 会跳过 agent key
    /// 而 `invalidate(.corp_js)` 语义完全等价，因此按类型精确作废在两种配置下都成立。
    fn invalidate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        const adapter: *WorkJsTicketAdapter = @ptrCast(@alignCast(ctx));
        return adapter.work.invalidateJsTicket(allocator, adapter.ticket_type);
    }
};

const work_js_ticket_vtable = credential.JsTicketHandle.VTable{
    .getTicket = WorkJsTicketAdapter.getTicket,
    .invalidate = WorkJsTicketAdapter.invalidate,
};

// WorkAccessToken handle 的 vtable（包装到 access_token_handle 抽象接口）。
//
// `invalidate` 必须与 `WorkAccessToken.asHandle` 保持一致：`newDefaultWork` 构造的
// `Work` 走的是这条 vtable，缺了它 `ctx.invalidateAccessToken` 会返回
// `error.InvalidateNotSupported`，`util/retry.callApi` 只能退化成「用旧 token 再试一次」，
// access_token 失效时就无法自愈。
const work_access_token_handle_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = struct {
        fn f(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8 {
            const ak: *credential.WorkAccessToken = @ptrCast(@alignCast(ctx));
            return ak.getAccessToken(alloc);
        }
    }.f,
    .invalidate = struct {
        fn f(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror!void {
            const ak: *credential.WorkAccessToken = @ptrCast(@alignCast(ctx));
            return ak.invalidate(alloc);
        }
    }.f,
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试用的假 vtable：模拟一个返回静态字符串的 AccessTokenHandle。
// ─────────────────────────────────────────────────────────────────────────────

const TestHandleState = struct {
    token: []const u8,
};

fn fakeGetAccessToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = allocator;
    const state: *const TestHandleState = @ptrCast(@alignCast(ctx));
    // 静态测试数据，所有权属于测试本身；调用方不得 free。
    return @constCast(state.token);
}

const fake_access_token_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = fakeGetAccessToken,
};

fn makeFakeHandle(state: *TestHandleState) credential.AccessTokenHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &fake_access_token_vtable,
    };
}

// 假 JsTicketHandle：用于验证 Work.getJsTicket 的转发行为。
const TicketHandleTestState = struct {
    ticket: []const u8,
};

fn fakeGetJsTicket(ctx: *anyopaque, allocator: std.mem.Allocator, access_token: []const u8) anyerror![]u8 {
    _ = allocator;
    _ = access_token;
    const s: *const TicketHandleTestState = @ptrCast(@alignCast(ctx));
    return @constCast(s.ticket);
}

const fake_js_ticket_vtable = credential.JsTicketHandle.VTable{
    .getTicket = fakeGetJsTicket,
};

fn makeFakeJsTicketHandle(state: *TicketHandleTestState) credential.JsTicketHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &fake_js_ticket_vtable,
    };
}

test "Work.init 持有传入的 ctx" {
    const w = Work.init(.{
        .config = .{ .corp_id = "ww-init" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    });
    try std.testing.expectEqualStrings("ww-init", w.ctx.config.corp_id);
    try std.testing.expect(w.ctx.js_ticket_handle == null);
}

test "Work.newWork 注入 config 与 handle" {
    var state = TestHandleState{ .token = "stub-work-ak" };
    const handle = makeFakeHandle(&state);
    const w = Work.newWork(
        .{ .corp_id = "ww-new", .agent_id = "1000001" },
        handle,
        null,
    );
    try std.testing.expectEqualStrings("ww-new", w.ctx.config.corp_id);
    try std.testing.expectEqualStrings("1000001", w.ctx.config.agent_id);
    try std.testing.expectEqual(@intFromPtr(&state), @intFromPtr(w.ctx.access_token_handle.ptr));
    try std.testing.expect(w.ctx.js_ticket_handle == null);
}

test "Work.getContext 返回内部 ctx 指针" {
    var w = Work.init(.{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    });
    try std.testing.expectEqual(w.getContext(), &w.ctx);
}

test "Work.getAccessToken 透传到 handle" {
    var state = TestHandleState{ .token = "fake-work-access-token-xyz" };
    var w = Work.newWork(
        .{ .corp_id = "ww-fake" },
        makeFakeHandle(&state),
        null,
    );
    const tok = try w.getAccessToken(std.testing.allocator);
    try std.testing.expectEqualStrings("fake-work-access-token-xyz", tok);
}

test "Work.getJsTicket cache 为空时返回 CacheUnavailable" {
    var w = Work.newWork(
        .{ .corp_id = "ww-no-cache" }, // cache 默认为 null
        .{ .ptr = undefined, .vtable = undefined },
        null, // 也没有自定义 js_ticket_handle
    );
    const result = w.getJsTicket(std.testing.allocator, "fake_ak");
    try std.testing.expectError(error.CacheUnavailable, result);
}

test "Work.getJsTicket 已设置 js_ticket_handle 时直接转发" {
    // 通过 fake vtable 验证转发行为：fakeGetJsTicket 把 ticket 写到一个静态切片上，
    // 再断言 Work.getJsTicket 返回相同的字符串。
    var ticket_state = TicketHandleTestState{ .ticket = "fake-work-jsapi-ticket" };

    var w = Work.newWork(
        .{ .corp_id = "ww-handle" },
        .{ .ptr = undefined, .vtable = undefined },
        makeFakeJsTicketHandle(&ticket_state),
    );

    const ticket = try w.getJsTicket(std.testing.allocator, "any_ak");
    try std.testing.expectEqualStrings("fake-work-jsapi-ticket", ticket);
}

test "Work.newDefaultWork 在 cache 为空时返回 CacheUnavailable" {
    const result = Work.newDefaultWork(.{ .corp_id = "ww-no", .corp_secret = "s", .agent_id = "a" }, std.testing.allocator);
    try std.testing.expectError(error.CacheUnavailable, result);
}

test "Work.newDefaultWork + deinit 无内存泄漏" {
    const allocator = std.testing.allocator;
    var mem = try cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }
    var w = try Work.newDefaultWork(.{
        .corp_id = "ww-deinit",
        .corp_secret = "secret",
        .agent_id = "1000001",
        .cache = mem.asCache(),
    }, allocator);
    // deinit 释放 newDefaultWork 分配的 access_token box；
    // testing.allocator 会校验无泄漏。
    w.deinit(allocator);
    try std.testing.expect(w.owned_access_token == null);
    // 二次 deinit 是安全的（幂等）。
    w.deinit(allocator);
}

test "Work.newWork 构造的实例 deinit 是空操作" {
    var state = TestHandleState{ .token = "tok" };
    var w = Work.newWork(.{ .corp_id = "ww-nowork" }, makeFakeHandle(&state), null);
    w.deinit(std.testing.allocator);
    try std.testing.expect(w.owned_access_token == null);
}

test "Work.setDefaultTicketType 切换 corp / agent" {
    var w = Work.init(.{ .config = .{}, .access_token_handle = .{ .ptr = undefined, .vtable = undefined } });
    try std.testing.expectEqual(credential.TicketType.corp_js, w.default_ticket_type);
    w.setDefaultTicketType(.agent_js);
    try std.testing.expectEqual(credential.TicketType.agent_js, w.default_ticket_type);
}

test "Work.getCorpJsTicket / getAgentJsTicket 返回对应类型 ticket" {
    const allocator = std.testing.allocator;
    var mem = try cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    var w = Work.newWork(
        .{ .corp_id = "ww-corp", .agent_id = "1000001", .cache = mem.asCache() },
        .{ .ptr = undefined, .vtable = undefined },
        null,
    );

    // 注入带 fetcher 的 WorkJsTicket，按 URL 区分 corp / agent。
    const FetcherCtx = struct {
        fn fetch(_: *anyopaque, alloc: std.mem.Allocator, url: []const u8) credential.CredentialError![]u8 {
            const is_agent = std.mem.indexOf(u8, url, "type=agent_config") != null;
            const ticket = if (is_agent) "agent-ticket-xyz" else "corp-ticket-xyz";
            return std.fmt.allocPrint(alloc, "{{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"{s}\",\"expires_in\":7200}}", .{ticket}) catch return credential.CredentialError.HttpError;
        }
    };

    w.work_ticket_cache = credential.WorkJsTicket.initWithFetcher(
        "ww-corp",
        "1000001",
        credential.CacheKeyWorkPrefix,
        mem.asCache(),
        FetcherCtx.fetch,
        @ptrCast(&w),
    );

    const corp = try w.getCorpJsTicket(allocator, "ak");
    defer allocator.free(corp);
    try std.testing.expectEqualStrings("corp-ticket-xyz", corp);

    const agent = try w.getAgentJsTicket(allocator, "ak");
    defer allocator.free(agent);
    try std.testing.expectEqualStrings("agent-ticket-xyz", agent);
}

test "Work.getJs 自动注入 corp / agent ticket handle" {
    const allocator = std.testing.allocator;
    var mem = try cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    var w = Work.newWork(
        .{ .corp_id = "ww-js", .agent_id = "1000002", .cache = mem.asCache() },
        .{ .ptr = undefined, .vtable = undefined },
        null,
    );

    const FetcherCtx = struct {
        fn fetch(_: *anyopaque, alloc: std.mem.Allocator, url: []const u8) credential.CredentialError![]u8 {
            const is_agent = std.mem.indexOf(u8, url, "type=agent_config") != null;
            const ticket = if (is_agent) "agent-js-ticket" else "corp-js-ticket";
            return std.fmt.allocPrint(alloc, "{{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"{s}\",\"expires_in\":7200}}", .{ticket}) catch return credential.CredentialError.HttpError;
        }
    };

    w.work_ticket_cache = credential.WorkJsTicket.initWithFetcher(
        "ww-js",
        "1000002",
        credential.CacheKeyWorkPrefix,
        mem.asCache(),
        FetcherCtx.fetch,
        @ptrCast(&w),
    );

    // Work.getJs 返回的 Js 已经注入两种 handle。
    const j = w.getJs();
    try std.testing.expect(j.ticket_handle != null);
    try std.testing.expect(j.agent_ticket_handle != null);

    // 由于 Js 内部会调用 ctx.getAccessToken，但 ctx 没有可用 handle，
    // 这里只验证 adapter 存在性；完整签名测试在 work/jsapi 模块中。
}

// ─────────────────────────────────────────────────────────────────────────────
// ticket 失效自愈：业务接口 40001 → handle.invalidate → 下次取值回源
// ─────────────────────────────────────────────────────────────────────────────

/// 桩 fetcher：记录回源次数，按 `version` 拼出可区分的 ticket（版本变化模拟
/// 微信换发新 ticket）。
const TicketFetchStub = struct {
    calls: usize = 0,
    version: usize = 1,

    fn fetch(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) credential.CredentialError![]u8 {
        _ = url;
        const self: *TicketFetchStub = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return std.fmt.allocPrint(
            allocator,
            "{{\"errcode\":0,\"errmsg\":\"ok\",\"ticket\":\"ticket-v{d}\",\"expires_in\":7200}}",
            .{self.version},
        ) catch return credential.CredentialError.HttpError;
    }
};

/// 构造注入了桩 fetcher 的 `Work`（缓存侧 `WorkJsTicket` 已就绪）。
fn makeTicketWork(mem: *cache.Memory, stub: *TicketFetchStub, corp_id: []const u8, agent_id: []const u8) Work {
    var w = Work.newWork(
        .{ .corp_id = corp_id, .agent_id = agent_id, .cache = mem.asCache() },
        .{ .ptr = undefined, .vtable = undefined },
        null,
    );
    w.work_ticket_cache = credential.WorkJsTicket.initWithFetcher(
        corp_id,
        agent_id,
        credential.CacheKeyWorkPrefix,
        mem.asCache(),
        TicketFetchStub.fetch,
        @ptrCast(stub),
    );
    return w;
}

test "Work.getJs 的 corp ticket handle 支持 invalidate：40001 后作废缓存并重取" {
    const allocator = std.testing.allocator;
    var mem = try cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    var stub = TicketFetchStub{};
    var w = makeTicketWork(mem, &stub, "ww-ticket-heal", "1000001");

    const j = w.getJs();
    const corp_handle = j.ticket_handle.?;

    const first = try corp_handle.getTicket(allocator, "ak");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("ticket-v1", first);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);

    // 缓存命中：不再回源（作废测试的分界点）。
    const cached = try corp_handle.getTicket(allocator, "ak");
    defer allocator.free(cached);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);

    // 业务接口返回 40001，调用方按标准恢复动作作废 ticket。改造前 adapter 的
    // vtable 没有 invalidate，这条路径会返回 error.InvalidateNotSupported。
    w.ctx.js_ticket_handle = corp_handle;
    stub.version = 2;
    try w.ctx.invalidateJsTicket(allocator);

    const refreshed = try corp_handle.getTicket(allocator, "ak");
    defer allocator.free(refreshed);
    try std.testing.expectEqualStrings("ticket-v2", refreshed);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}

test "Work.getJs 的 corp / agent handle 各自只作废自己的缓存键" {
    const allocator = std.testing.allocator;
    var mem = try cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    var stub = TicketFetchStub{};
    var w = makeTicketWork(mem, &stub, "ww-ticket-scope", "1000003");

    const j = w.getJs();
    const corp_handle = j.ticket_handle.?;
    const agent_handle = j.agent_ticket_handle.?;

    const corp = try corp_handle.getTicket(allocator, "ak");
    defer allocator.free(corp);
    const agent = try agent_handle.getTicket(allocator, "ak");
    defer allocator.free(agent);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);

    // 从 corp handle 作废：agent ticket 仍命中缓存（不回源）。
    stub.version = 2;
    try corp_handle.invalidateTicket(allocator);

    const agent_cached = try agent_handle.getTicket(allocator, "ak");
    defer allocator.free(agent_cached);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);

    const corp_refetched = try corp_handle.getTicket(allocator, "ak");
    defer allocator.free(corp_refetched);
    try std.testing.expectEqualStrings("ticket-v2", corp_refetched);
    try std.testing.expectEqual(@as(usize, 3), stub.calls);
}

test "Work.invalidateJsTicket 无缓存后端时返回 CacheUnavailable" {
    var w = Work.newWork(
        .{ .corp_id = "ww-ticket-nocache" },
        .{ .ptr = undefined, .vtable = undefined },
        null,
    );
    try std.testing.expectError(
        error.CacheUnavailable,
        w.invalidateJsTicket(std.testing.allocator, .corp_js),
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// access_token 失效自愈：newDefaultWork 构造的 handle 也必须能作废
// ─────────────────────────────────────────────────────────────────────────────

/// 桩 fetcher：按 `version` 返回可区分的 access_token。
const TokenFetchStub = struct {
    calls: usize = 0,
    version: usize = 1,

    fn fetch(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8) credential.CredentialError![]u8 {
        _ = url;
        const self: *TokenFetchStub = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return std.fmt.allocPrint(
            allocator,
            "{{\"errcode\":0,\"errmsg\":\"ok\",\"access_token\":\"work-token-v{d}\",\"expires_in\":7200}}",
            .{self.version},
        ) catch return credential.CredentialError.HttpError;
    }
};

test "Work.newDefaultWork 的 access_token handle 支持 invalidate：40001 后作废并重取" {
    const allocator = std.testing.allocator;
    var mem = try cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    var w = try Work.newDefaultWork(.{
        .corp_id = "ww-ak-heal",
        .corp_secret = "secret",
        .agent_id = "1000001",
        .cache = mem.asCache(),
    }, allocator);
    defer w.deinit(allocator);

    // 把 box 内的实例换成注入了桩 fetcher 的版本（handle 指向同一个 box）。
    var stub = TokenFetchStub{};
    w.owned_access_token.?.* = credential.WorkAccessToken.initWithFetcher(
        "ww-ak-heal",
        "secret",
        credential.CacheKeyWorkPrefix,
        mem.asCache(),
        TokenFetchStub.fetch,
        @ptrCast(&stub),
    );

    const first = try w.getAccessToken(allocator);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("work-token-v1", first);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);

    // 缓存命中：不再回源。
    const cached = try w.getAccessToken(allocator);
    defer allocator.free(cached);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);

    // token 失效码（40001）后的标准恢复动作。改造前 vtable 没有 invalidate，
    // 这条路径会返回 error.InvalidateNotSupported。
    stub.version = 2;
    try w.ctx.invalidateAccessToken(allocator);

    const refreshed = try w.getAccessToken(allocator);
    defer allocator.free(refreshed);
    try std.testing.expectEqualStrings("work-token-v2", refreshed);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
}
