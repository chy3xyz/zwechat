//! work/work — 企业微信顶层 Work struct
//!
//! 对应 `_ref/wechat/work/work.go` 的 `Work` struct：聚合企业微信全部子模块
//! （externalcontact / invoice / addresslist / appchat / robot / oauth / jsapi 等）
//! 的运行时入口；当前阶段实现 framework + access_token / js_ticket 透传，
//! 各子模块的懒加载字段在后续 pass 填充。

const std = @import("std");
const cache = @import("../cache/mod.zig");
const credential = @import("../credential/mod.zig");
const Config = @import("config.zig").Config;
const Context = @import("context/mod.zig").Context;
const jsapi = @import("jsapi/mod.zig");

/// 企业微信业务 API 聚合入口。
///
/// 构造完成后可重复调用 `getAccessToken` / `getJsTicket` 拿到当前可用的 token 与
/// ticket；子模块（如 oauth / jsapi 等）将在后续阶段以懒加载方法的形式补齐。
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
        return w;
    }

    /// 返回内部 `Context` 指针。
    pub fn getContext(self: *Work) *Context {
        return &self.ctx;
    }

    /// 构造 `jsapi.Js` 子模块，并自动注入 corp / agent 两种 ticket handle。
    ///
    /// 调用方拿到 `Js` 后可直接调用 `getConfig`（corp）或 `getAgentConfig`（agent），
    /// 无需手动 `setJsTicketHandle`。
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
        const cache_inst = self.ctx.config.cache orelse return error.CacheUnavailable;
        if (self.work_ticket_cache == null) {
            self.work_ticket_cache = credential.WorkJsTicket.init(
                self.ctx.config.corp_id,
                self.ctx.config.agent_id,
                credential.CacheKeyWorkPrefix,
                cache_inst,
            );
        }
        return self.work_ticket_cache.?.getTicket(allocator, access_token, ticket_type);
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
};

const work_js_ticket_vtable = credential.JsTicketHandle.VTable{
    .getTicket = WorkJsTicketAdapter.getTicket,
};

// WorkAccessToken handle 的 vtable（包装到 access_token_handle 抽象接口）。
const work_access_token_handle_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = struct {
        fn f(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8 {
            const ak: *credential.WorkAccessToken = @ptrCast(@alignCast(ctx));
            return ak.getAccessToken(alloc);
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