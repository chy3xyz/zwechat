//! openplatform — 微信开放平台（第三方平台）顶层模块
//!
//! 对应 `_ref/wechat/openplatform/openplatform.go` 的 `OpenPlatform` struct：
//! 聚合 `Context` + `Account` + `MiniProgram` + `OfficialAccount` 四个入口。
//! 上层通过 `OpenPlatform.init(cfg)` 拿到实例，再分别 `getXxx()` 拉取子业务。
//!
//! Zig 版的内存模型与 Go 不同——`OpenPlatform` 是值类型（不是指针），
//! 因此需要在调用方栈 / 堆上存活期间保持 `ctx` 引用有效；子模块工厂
//! （`getAccountManager` / `getMiniProgram` / `getOfficialAccount`）返回
//! 新的子结构，调用方负责按需保留。

const std = @import("std");

pub const Config = @import("config.zig").Config;
pub const Context = @import("context/mod.zig").Context;
pub const Account = @import("account/mod.zig").Account;
pub const OpenMiniProgram = @import("miniprogram/mod.zig").OpenMiniProgram;
pub const OpenOfficialAccount = @import("officialaccount/mod.zig").OpenOfficialAccount;

/// 微信开放平台（第三方平台）顶层入口。
///
/// 与上游 Go 版 `OpenPlatform`（`OpenPlatform struct { *context.Context }`）对应，
/// 内嵌一个 `Context` 值（持有 `Config` 与 `access_token`）。
pub const OpenPlatform = struct {
    /// 运行时上下文（持 config + access_token 状态）。
    ctx: Context,

    const Self = @This();

    /// 通过已构造好的 `Context` 组装 `OpenPlatform`。
    pub fn init(ctx: Context) Self {
        return .{ .ctx = ctx };
    }

    /// 通过 `Config` 一步构造（与 Go 端 `NewOpenPlatform(cfg)` 对齐）。
    pub fn newOpenPlatform(cfg: Config) Self {
        return .{ .ctx = .{ .config = cfg } };
    }

    /// 返回内部 `Context` 引用（与 Go 端 `OpenPlatform.Context` 嵌入字段语义一致）。
    pub fn getContext(self: *Self) *Context {
        return &self.ctx;
    }

    /// `GetAccountManager` — 账号管理入口（对应 Go 端 `GetAccountManager`）。
    ///
    /// 工厂方法：每次调用都返回新的 `Account` 实例，调用方负责保持其与 ctx 同寿命。
    pub fn getAccountManager(self: *Self, allocator: std.mem.Allocator) Account {
        return Account.init(&self.ctx, allocator);
    }

    /// `GetMiniProgram` — 代小程序业务入口（对应 Go 端 `GetMiniProgram(appID)`）。
    ///
    /// `app_id` — 被代运营的小程序 AppID。
    pub fn getMiniProgram(self: *Self, app_id: []const u8) OpenMiniProgram {
        return OpenMiniProgram.init(&self.ctx, app_id);
    }

    /// `GetOfficialAccount` — 代公众号业务入口（对应 Go 端 `GetOfficialAccount(appID)`）。
    ///
    /// `app_id` — 被代运营的公众号 AppID（非开放平台第三方平台 AppID）。
    pub fn getOfficialAccount(self: *Self, app_id: []const u8) OpenOfficialAccount {
        return OpenOfficialAccount.init(&self.ctx, app_id);
    }
};

test "OpenPlatform.init 持有传入 ctx" {
    const op = OpenPlatform.init(.{ .config = .{ .app_id = "wx-op-init" } });
    try std.testing.expectEqualStrings("wx-op-init", op.ctx.config.app_id);
    try std.testing.expect(op.ctx.getAccessToken() == null);
}

test "OpenPlatform.newOpenPlatform 通过 Config 一步构造" {
    const op = OpenPlatform.newOpenPlatform(.{
        .app_id = "wx-op-new",
        .app_secret = "op-secret",
        .token = "op-token",
    });
    try std.testing.expectEqualStrings("wx-op-new", op.ctx.config.app_id);
    try std.testing.expectEqualStrings("op-secret", op.ctx.config.app_secret);
    try std.testing.expectEqualStrings("op-token", op.ctx.config.token);
}

test "OpenPlatform.getContext 返回内部 ctx 指针" {
    var op = OpenPlatform.newOpenPlatform(.{ .app_id = "wx-op-gc" });
    const ctx_ptr = op.getContext();
    try std.testing.expectEqual(ctx_ptr, &op.ctx);
}

test "OpenPlatform.getMiniProgram / getOfficialAccount 各自返回带 app_id 的子模块" {
    var op = OpenPlatform.newOpenPlatform(.{ .app_id = "wx-op-factory" });
    const mp = op.getMiniProgram("wx-mp-1");
    try std.testing.expectEqualStrings("wx-mp-1", mp.app_id);
    try std.testing.expectEqual(@intFromPtr(&op.ctx), @intFromPtr(mp.open_context));

    const oa = op.getOfficialAccount("wx-oa-1");
    try std.testing.expectEqualStrings("wx-oa-1", oa.app_id);
    try std.testing.expectEqual(@intFromPtr(&op.ctx), @intFromPtr(oa.open_context));
}

test "OpenPlatform.getAccountManager 工厂每次返回新实例" {
    var op = OpenPlatform.newOpenPlatform(.{ .app_id = "wx-op-am" });
    const allocator = std.heap.page_allocator;
    const a1 = op.getAccountManager(allocator);
    const a2 = op.getAccountManager(allocator);
    // 两个 Account 实例独立，但都指向同一个 ctx
    try std.testing.expectEqual(@intFromPtr(&op.ctx), @intFromPtr(a1.ctx));
    try std.testing.expectEqual(@intFromPtr(&op.ctx), @intFromPtr(a2.ctx));
}
