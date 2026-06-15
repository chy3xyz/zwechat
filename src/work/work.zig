//! work/work — 企业微信顶层 Work struct
//!
//! 对应 `_ref/wechat/work/work.go` 的 `Work` struct：聚合企业微信全部子模块
//! （externalcontact / invoice / addresslist / appchat / robot / oauth / jsapi 等）
//! 的运行时入口；当前阶段实现 framework + access_token / js_ticket 透传，
//! 各子模块的懒加载字段在后续 pass 填充。

const std = @import("std");
const credential = @import("../credential/mod.zig");
const Config = @import("config.zig").Config;
const Context = @import("context/mod.zig").Context;

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

    /// 获取企业微信 jsapi_ticket。
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
        const cache_inst = self.ctx.config.cache orelse return error.CacheUnavailable;
        if (self.work_ticket_cache == null) {
            self.work_ticket_cache = credential.WorkJsTicket.init(
                self.ctx.config.corp_id,
                self.ctx.config.agent_id,
                credential.CacheKeyWorkPrefix,
                cache_inst,
            );
        }
        return self.work_ticket_cache.?.getTicket(allocator, access_token, self.default_ticket_type);
    }
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