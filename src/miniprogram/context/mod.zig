//! miniprogram/context — 小程序调用上下文（骨架）

const std = @import("std");
const Config = @import("../config.zig").Config;
const credential = @import("../../credential/mod.zig");

pub const Context = struct {
    config: Config,
    access_token_handle: credential.AccessTokenHandle,

    pub fn getAccessToken(self: *Context, allocator: std.mem.Allocator) @TypeOf(self.access_token_handle.getAccessToken(allocator)) {
        return self.access_token_handle.getAccessToken(allocator);
    }
};

test "Context 默认值" {
    const ctx = Context{
        .config = .{ .app_id = "wx-ctx" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    try std.testing.expectEqualStrings("wx-ctx", ctx.config.app_id);
}