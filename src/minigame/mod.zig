//! minigame — 微信小游戏顶层模块
//!
//! 对应 `_ref/wechat/minigame/`：上游 Go 侧只有 README，没有具体业务实现。
//! 本 Zig 落地按"小游戏 = 小程序的子集"思路对齐 `miniprogram.MiniProgram` 形态：
//! 聚合 `Context` 作为运行时入口，子模块（消息推送、用户信息、客服等）以
//! `GetXxx()` 懒加载入口的形式在后续 pass 中补齐。

const std = @import("std");

const Config = @import("config.zig").Config;
const Context = @import("context/mod.zig").Context;
const credential = @import("../credential/mod.zig");

/// 微信小游戏顶层入口。
///
/// 与 `miniprogram.MiniProgram` 形态一致：内嵌 `Context`，调用方按需
/// `getContext()` 取回 ctx，或后续 pass 通过 `getXxx()` 拉取子模块。
pub const MiniGame = struct {
    /// 运行时上下文（持 Config + AccessTokenHandle）。
    ctx: Context,

    const Self = @This();

    /// 通过已构造好的 `Context` 直接组装实例。
    pub fn init(ctx: Context) Self {
        return .{ .ctx = ctx };
    }

    /// 一步构造：`Config` + 已构建好的 `AccessTokenHandle`。
    pub fn newMiniGame(cfg: Config, default_access_token: credential.AccessTokenHandle) Self {
        return .{ .ctx = .{
            .config = cfg,
            .access_token_handle = default_access_token,
        } };
    }

    /// 返回内部 `Context` 引用，便于子模块读取配置 / token。
    pub fn getContext(self: *Self) *Context {
        return &self.ctx;
    }

    /// 获取 access_token，委托给 `ctx.getAccessToken`。
    pub fn getAccessToken(self: *Self, allocator: std.mem.Allocator) @TypeOf(self.ctx.getAccessToken(allocator)) {
        return self.ctx.getAccessToken(allocator);
    }
};

test "MiniGame.init 持有传入 ctx" {
    const mg = MiniGame.init(.{
        .config = .{ .app_id = "wx-mg-init" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    });
    try std.testing.expectEqualStrings("wx-mg-init", mg.ctx.config.app_id);
}

test "MiniGame.newMiniGame 注入 config 与 handle" {
    var sentinel: u32 = 0;
    const handle_vtable: *const credential.AccessTokenHandle.VTable = &credential.AccessTokenHandle.VTable{
        .getAccessToken = undefined,
    };
    const handle = credential.AccessTokenHandle{
        .ptr = @ptrCast(&sentinel),
        .vtable = handle_vtable,
    };
    const mg = MiniGame.newMiniGame(.{ .app_id = "wx-mg-new" }, handle);
    try std.testing.expectEqualStrings("wx-mg-new", mg.ctx.config.app_id);
    // 验证 handle 句柄被原样转发：ptr 与 vtable 指针都保持一致
    try std.testing.expectEqual(@intFromPtr(handle.ptr), @intFromPtr(mg.ctx.access_token_handle.ptr));
    try std.testing.expectEqual(@intFromPtr(handle.vtable), @intFromPtr(mg.ctx.access_token_handle.vtable));
}

test "MiniGame.getContext 返回内部 ctx 指针" {
    var mg = MiniGame.newMiniGame(.{ .app_id = "wx-mg-gc" }, .{
        .ptr = undefined,
        .vtable = undefined,
    });
    const ctx_ptr = mg.getContext();
    try std.testing.expectEqual(ctx_ptr, &mg.ctx);
}
