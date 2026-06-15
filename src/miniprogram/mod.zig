//! miniprogram — 小程序（顶层 + 子模块聚合）

const std = @import("std");
const credential = @import("../credential/mod.zig");
pub const Config = @import("config.zig").Config;
const Context = @import("context/mod.zig").Context;

pub const Auth = @import("auth/mod.zig").Auth;
pub const MiniProgram = struct {
    ctx: Context,
    auth_instance: ?Auth = null,
    allocator: std.mem.Allocator = undefined,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: Config, access_token_handle: credential.AccessTokenHandle) MiniProgram {
        return .{
            .ctx = .{ .config = cfg, .access_token_handle = access_token_handle },
            .auth_instance = null,
            .allocator = allocator,
        };
    }

    pub fn getContext(self: *MiniProgram) *Context {
        return &self.ctx;
    }

    /// 懒加载 Auth 子模块。
    pub fn getAuth(self: *Self) Auth {
        return Auth.init(&self.ctx, self.allocator);
    }
};

test "MiniProgram.init 返回实例" {
    const allocator = std.heap.page_allocator;
    const mp = MiniProgram.init(allocator, .{ .app_id = "wx-mp" }, .{ .ptr = undefined, .vtable = undefined });
    try std.testing.expectEqualStrings("wx-mp", mp.ctx.config.app_id);
}