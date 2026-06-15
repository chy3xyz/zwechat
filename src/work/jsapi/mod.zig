//! work/jsapi — 企业微信 JS-SDK 配置
//!
//! 对应 `_ref/wechat/work/jsapi/jsapi.go`：根据 jsapi_ticket + 当前 URL 计算
//! 企业微信 JS-SDK 所需的 `appId / timestamp / nonceStr / signature`。
//!
//! 调用方需通过 `setJsTicketHandle` 注入 ticket 获取器（默认走
//! `Work.getJsTicket` 懒加载的 `DefaultJsTicket`，但 cache key prefix 已经匹配 work）。
//!
//! 与官方账号 `js` 模块的差异：
//! - ticket 类型不同：企业微信有两种（corp `get_jsapi_ticket` 与 agent `ticket/get?type=agent_config`）。
//!   本模块 `getConfig` 对应 corp（与官方账号 js 的 `GetConfig` 同名），`getAgentConfig` 对应 agent。
//! - 算法完全相同：signature_str = `jsapi_ticket=X&noncestr=Y&timestamp=Z&url=W`，
//!   signature = SHA1(signature_str) 小写 hex。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_time = @import("../../util/time.zig");
const util_sig = @import("../../util/signature.zig");
const util_util = @import("../../util/util.zig");

/// JS-SDK 配置返回结构（与官方账号 js 的 `Config` 保持一致以减少认知负担）。
///
/// - `app_id` 借用自 `ctx.config.corp_id`，**不需要** `deinit`。
/// - `nonce_str` / `signature` 是堆分配，调用方需在 `Config.deinit` 中释放。
pub const Config = struct {
    /// 企业 corp_id（借引用，调用方无需 free）。
    app_id: []const u8 = "",
    /// 秒级 Unix 时间戳（与 `util_time.getCurrTS` 一致）。
    timestamp: i64 = 0,
    /// 16 字节随机字符串（堆分配，需要 `deinit`）。
    nonce_str: []const u8 = "",
    /// SHA1 签名（堆分配，需要 `deinit`）。
    signature: []const u8 = "",

    /// 释放 `nonce_str` / `signature` 持有的堆内存；幂等。
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.nonce_str.len > 0) {
            allocator.free(@constCast(self.nonce_str));
            self.nonce_str = "";
        }
        if (self.signature.len > 0) {
            allocator.free(@constCast(self.signature));
            self.signature = "";
        }
    }
};

pub const Js = struct {
    ctx: *Context,
    /// corp 类型 JsTicket handle；未初始化时 `getConfig` 返回 `error.JsTicketHandleNotSet`。
    ticket_handle: ?credential.JsTicketHandle = null,
    /// agent 类型 JsTicket handle；未初始化时 `getAgentConfig` 返回 `error.JsTicketHandleNotSet`。
    agent_ticket_handle: ?credential.JsTicketHandle = null,

    const Self = @This();

    pub fn init(ctx: *Context) Self {
        return .{ .ctx = ctx };
    }

    /// 注入 corp JsTicket handle（典型来源：`Work.getCorpJsTicket` / 自定义实现）。
    pub fn setJsTicketHandle(self: *Self, h: credential.JsTicketHandle) void {
        self.ticket_handle = h;
    }

    /// 注入 agent JsTicket handle（典型来源：`Work.getAgentJsTicket` / 自定义实现）。
    pub fn setAgentJsTicketHandle(self: *Self, h: credential.JsTicketHandle) void {
        self.agent_ticket_handle = h;
    }

    /// 计算企业微信 JS-SDK 配置（corp 类型 ticket）。
    ///
    /// 流程：
    /// 1. 若 `ticket_handle == null`，返回 `error.JsTicketHandleNotSet`。
    /// 2. 通过 `ctx.getAccessToken` 拿到 access_token。
    /// 3. 通过 `ticket_handle.getTicket` 拿到 jsapi_ticket。
    /// 4. 生成 16 字节随机 `nonce_str`、调用 `util_time.getCurrTS` 拿 timestamp。
    /// 5. 拼 `jsapi_ticket=X&noncestr=Y&timestamp=Z&url=W`，SHA1 取小写 hex 作为 signature。
    /// 6. 返回 `Config`。
    ///
    /// 返回值的 `nonce_str` / `signature` 由调用方 `deinit` 释放。
    pub fn getConfig(self: *Self, allocator: std.mem.Allocator, uri: []const u8) !Config {
        return self.getConfigWithHandle(allocator, uri, self.ticket_handle, error.JsTicketHandleNotSet);
    }

    /// 计算企业微信**应用** JS-SDK 配置（agent 类型 ticket）。
    ///
    /// 算法与 `getConfig` 一致；区别仅在于 ticket 由 `agent_ticket_handle` 提供。
    pub fn getAgentConfig(self: *Self, allocator: std.mem.Allocator, uri: []const u8) !Config {
        return self.getConfigWithHandle(allocator, uri, self.agent_ticket_handle, error.JsTicketHandleNotSet);
    }

    fn getConfigWithHandle(
        self: *Self,
        allocator: std.mem.Allocator,
        uri: []const u8,
        handle: ?credential.JsTicketHandle,
        err: anyerror,
    ) !Config {
        const h = handle orelse return err;

        const access_token = try self.ctx.getAccessToken(allocator);
        defer allocator.free(access_token);
        const ticket = try h.getTicket(allocator, access_token);
        defer allocator.free(ticket);

        return computeConfig(allocator, self.ctx.config.corp_id, ticket, uri);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 内部：算法核心
// ──────────────────────────────────────────────────────────────────────────────

/// 计算 JS-SDK 配置的核心算法。
///
/// `app_id` 通常传入 `corp_id`；`ticket` 是已经获取的 jsapi_ticket；
/// `uri` 是当前页面 URL（不含 `#fragment`）。
///
/// 错误集：`Allocator.Error`。
fn computeConfig(
    allocator: std.mem.Allocator,
    app_id: []const u8,
    ticket: []const u8,
    uri: []const u8,
) !Config {
    const nonce_str = try util_util.randomStr(allocator, 16);
    errdefer allocator.free(nonce_str);

    const timestamp = util_time.getCurrTS();

    // 拼接签名字符串（与 Go 一致：jsapi_ticket=X&noncestr=Y&timestamp=Z&url=W）。
    const to_sign = try std.fmt.allocPrint(
        allocator,
        "jsapi_ticket={s}&noncestr={s}&timestamp={d}&url={s}",
        .{ ticket, nonce_str, timestamp, uri },
    );
    defer allocator.free(to_sign);

    // signature = SHA1(to_sign) 小写 hex。
    // util_sig.signature 接收 []const []const u8 并按字典序排序后再拼接，
    // 这里只传一个参数，等价于直接 SHA1(to_sign)。
    const signature = try util_sig.signature(allocator, &[_][]const u8{to_sign});

    return .{
        .app_id = app_id,
        .timestamp = timestamp,
        .nonce_str = nonce_str,
        .signature = signature,
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// 内联测试
// ──────────────────────────────────────────────────────────────────────────────

test "Js.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-js" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const j = Js.init(&ctx);
    try std.testing.expectEqualStrings("ww-js", j.ctx.config.corp_id);
    try std.testing.expect(j.ticket_handle == null);
}

test "Js.getConfig handle 为空时返回 JsTicketHandleNotSet" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-js2" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var j = Js.init(&ctx);
    const result = j.getConfig(std.testing.allocator, "https://example.com/");
    try std.testing.expectError(error.JsTicketHandleNotSet, result);
}

test "Config.deinit 释放 nonce/signature" {
    const allocator = std.testing.allocator;
    var c = Config{
        .nonce_str = try allocator.dupe(u8, "nonceXYZ"),
        .signature = try allocator.dupe(u8, "sigXYZ"),
    };
    c.deinit(allocator);
    // 二次 deinit 不应崩溃（幂等）。
    c.deinit(allocator);
    try std.testing.expectEqualStrings("", c.nonce_str);
    try std.testing.expectEqualStrings("", c.signature);
}

test "Config 默认值" {
    const c = Config{};
    try std.testing.expectEqualStrings("", c.app_id);
    try std.testing.expectEqualStrings("", c.nonce_str);
    try std.testing.expectEqualStrings("", c.signature);
    try std.testing.expectEqual(@as(i64, 0), c.timestamp);
}

test "computeConfig 输出 40 字符小写 hex 的 signature" {
    const allocator = std.testing.allocator;
    var cfg = try computeConfig(
        allocator,
        "ww-test",
        "ticket_xyz",
        "https://example.com/page?x=1",
    );
    defer cfg.deinit(allocator);

    // app_id 借用，未分配内存。
    try std.testing.expectEqualStrings("ww-test", cfg.app_id);
    // signature 是 SHA1 hex，共 40 字符。
    try std.testing.expectEqual(@as(usize, 40), cfg.signature.len);
    for (cfg.signature) |c| {
        try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    }
    // nonce_str 是 16 字符。
    try std.testing.expectEqual(@as(usize, 16), cfg.nonce_str.len);
    // timestamp > 0。
    try std.testing.expect(cfg.timestamp > 0);
}

// 测试用的假 AccessTokenHandle。
const FakeAccessTokenState = struct {
    token: []const u8,
};

fn fakeAccessTokenGet(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const s: *const FakeAccessTokenState = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, s.token);
}

const fake_access_token_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = fakeAccessTokenGet,
};

fn makeFakeAccessTokenHandle(state: *FakeAccessTokenState) credential.AccessTokenHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &fake_access_token_vtable,
    };
}

// 测试用的假 JsTicketHandle：记录被调用时的 ticket 类型。
const FakeTicketState = struct {
    ticket: []const u8,
};

fn fakeTicketGet(ctx: *anyopaque, allocator: std.mem.Allocator, access_token: []const u8) anyerror![]u8 {
    _ = access_token;
    const s: *const FakeTicketState = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, s.ticket);
}

const fake_ticket_vtable = credential.JsTicketHandle.VTable{
    .getTicket = fakeTicketGet,
};

fn makeFakeTicketHandle(state: *FakeTicketState) credential.JsTicketHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &fake_ticket_vtable,
    };
}

test "Js.getConfig 使用 corp ticket handle" {
    const allocator = std.testing.allocator;
    var ak_state = FakeAccessTokenState{ .token = "ak-corp" };
    var corp_state = FakeTicketState{ .ticket = "corp-ticket" };

    var ctx = Context{
        .config = .{ .corp_id = "ww-getconfig" },
        .access_token_handle = makeFakeAccessTokenHandle(&ak_state),
    };
    var j = Js.init(&ctx);
    j.setJsTicketHandle(makeFakeTicketHandle(&corp_state));

    var cfg = try j.getConfig(allocator, "https://example.com/");
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("ww-getconfig", cfg.app_id);
    try std.testing.expectEqual(@as(usize, 40), cfg.signature.len);
}

test "Js.getAgentConfig 使用 agent ticket handle" {
    const allocator = std.testing.allocator;
    var ak_state = FakeAccessTokenState{ .token = "ak-agent" };
    var agent_state = FakeTicketState{ .ticket = "agent-ticket" };

    var ctx = Context{
        .config = .{ .corp_id = "ww-getagent" },
        .access_token_handle = makeFakeAccessTokenHandle(&ak_state),
    };
    var j = Js.init(&ctx);
    j.setAgentJsTicketHandle(makeFakeTicketHandle(&agent_state));

    var cfg = try j.getAgentConfig(allocator, "https://example.com/");
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("ww-getagent", cfg.app_id);
    try std.testing.expectEqual(@as(usize, 40), cfg.signature.len);
}

test "Js.getAgentConfig 未设置 agent handle 时返回 JsTicketHandleNotSet" {
    const allocator = std.testing.allocator;
    var ak_state = FakeAccessTokenState{ .token = "ak" };
    var corp_state = FakeTicketState{ .ticket = "corp-ticket" };

    var ctx = Context{
        .config = .{ .corp_id = "ww-agent-missing" },
        .access_token_handle = makeFakeAccessTokenHandle(&ak_state),
    };
    var j = Js.init(&ctx);
    j.setJsTicketHandle(makeFakeTicketHandle(&corp_state));

    const result = j.getAgentConfig(allocator, "https://example.com/");
    try std.testing.expectError(error.JsTicketHandleNotSet, result);
}