//! officialaccount/officialaccount — 公众号顶层实例
//!
//! 对应 `_ref/wechat/officialaccount/officialaccount.go` 的 `OfficialAccount` struct。
//! 聚合公众号全部子模块（basic / menu / oauth / material / js / user / templateMsg /
//! broadcast / datacube / ocr / customerservice / device / freepublish / draft / openapi）
//! 的懒加载入口；当前阶段仅实现框架与 access_token 透传，子模块字段在后续 pass 填充。

const std = @import("std");
const credential = @import("../credential/mod.zig");
const Config = @import("config.zig").Config;
const Context = @import("context.zig").Context;

/// 微信公众号相关 API 聚合入口。
///
/// 构造完成后可重复调用 `getAccessToken` 拿到当前可用的 token；
/// 子模块（如 menu / material 等）将在后续阶段以 `?*Submodule = null`
/// 懒加载字段 + `Get*` 方法的形式补齐。
pub const OfficialAccount = struct {
    ctx: Context,

    /// 通过已构造好的 `Context` 直接组装实例。
    pub fn init(ctx: Context) OfficialAccount {
        return .{ .ctx = ctx };
    }

    /// 一步构造：`Config` + 已构建好的 `AccessTokenHandle`。
    ///
    /// 调用方负责创建 `default_access_token`（默认 / 稳定版 / 自定义实现）；
    /// 当 `cfg.use_stable_ak == true` 时调用方应选用稳定版 token 获取器。
    pub fn newOfficialAccount(cfg: Config, default_access_token: credential.AccessTokenHandle) OfficialAccount {
        return .{ .ctx = .{
            .config = cfg,
            .access_token_handle = default_access_token,
        } };
    }

    /// 返回内部 `Context` 指针，便于直接操作 ctx（与 Go 的 `GetContext` 对齐）。
    pub fn getContext(self: *OfficialAccount) *Context {
        return &self.ctx;
    }

    /// 获取 access_token，委托给 `ctx.getAccessToken`。
    pub fn getAccessToken(self: *OfficialAccount, allocator: std.mem.Allocator) @TypeOf(self.ctx.getAccessToken(allocator)) {
        return self.ctx.getAccessToken(allocator);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试用的假 vtable：模拟一个返回静态字符串的 AccessTokenHandle。
// 通过文件作用域常量 + 函数指针来填充 `credential.AccessTokenHandle`。
// 注意：vtable 函数签名必须与 `credential.AccessTokenHandle.VTable.getAccessToken`
// 完全一致（`ctx: *anyopaque, allocator: std.mem.Allocator`）。
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

test "OfficialAccount.init 持有传入的 ctx" {
    const oa = OfficialAccount.init(.{
        .config = .{ .app_id = "wx-init" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    });
    try std.testing.expectEqualStrings("wx-init", oa.ctx.config.app_id);
}

test "OfficialAccount.newOfficialAccount 注入 config 与 handle" {
    var state = TestHandleState{ .token = "stub-ak" };
    const handle = makeFakeHandle(&state);
    const oa = OfficialAccount.newOfficialAccount(.{ .app_id = "wx-new" }, handle);
    try std.testing.expectEqualStrings("wx-new", oa.ctx.config.app_id);
    try std.testing.expectEqual(@intFromPtr(&state), @intFromPtr(oa.ctx.access_token_handle.ptr));
    try std.testing.expectEqual(&fake_access_token_vtable, oa.ctx.access_token_handle.vtable);
}

test "OfficialAccount.getContext 返回内部 ctx 指针" {
    var oa = OfficialAccount.init(.{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    });
    const ctx_ptr = oa.getContext();
    try std.testing.expectEqual(ctx_ptr, &oa.ctx);
}

test "OfficialAccount.getAccessToken 透传到 handle" {
    var state = TestHandleState{ .token = "fake-access-token-xyz" };
    var oa = OfficialAccount.newOfficialAccount(
        .{ .app_id = "wx-fake" },
        makeFakeHandle(&state),
    );
    const tok = try oa.getAccessToken(std.testing.allocator);
    try std.testing.expectEqualStrings("fake-access-token-xyz", tok);
}
