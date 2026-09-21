// SPDX-License-Identifier: Apache-2.0
//! miniprogram/context — 小程序调用上下文（骨架）
//!
//! 业务模块不应自己写「token 失效重试」，而是把发送逻辑包成一个 `sender`
//! 交给 `util/retry.callApi`——它负责「识别 40001 → 作废缓存 → 取新 token →
//! **只重试一次**」。

const std = @import("std");
const Config = @import("../config.zig").Config;
const credential = @import("../../credential/mod.zig");

pub const Context = struct {
    config: Config,
    access_token_handle: credential.AccessTokenHandle,

    pub fn getAccessToken(self: *Context, allocator: std.mem.Allocator) @TypeOf(self.access_token_handle.getAccessToken(allocator)) {
        return self.access_token_handle.getAccessToken(allocator);
    }

    /// 作废缓存的 access_token，使下一次 `getAccessToken` 必须回源。
    ///
    /// 转发给 `access_token_handle.invalidateAccessToken`；注入的 handle 未提供
    /// `invalidate` 钩子时返回 `error.InvalidateNotSupported`。
    /// 业务模块通常不直接调用，而是走 `util/retry.callApi` 的失效恢复链路。
    pub fn invalidateAccessToken(self: *Context, allocator: std.mem.Allocator) anyerror!void {
        return self.access_token_handle.invalidateAccessToken(allocator);
    }
};

test "Context 默认值" {
    const ctx = Context{
        .config = .{ .app_id = "wx-ctx" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    try std.testing.expectEqualStrings("wx-ctx", ctx.config.app_id);
}

/// 假凭据 handle：验证 Context 的作废转发与「未实现钩子」的明确报错。
const StubToken = struct {
    invalidates: usize = 0,

    fn getAccessToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "mp_token");
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *StubToken = @ptrCast(@alignCast(ptr));
        self.invalidates += 1;
    }
};

test "Context.invalidateAccessToken 转发到 handle，且未实现时返回 InvalidateNotSupported" {
    const allocator = std.testing.allocator;
    var stub = StubToken{};

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = StubToken.getAccessToken,
        .invalidate = StubToken.invalidate,
    };
    var ctx = Context{
        .config = .{ .app_id = "wx-mp-invalidate" },
        .access_token_handle = .{ .ptr = @ptrCast(&stub), .vtable = &vtable },
    };

    try ctx.invalidateAccessToken(allocator);
    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);

    const legacy_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getAccessToken };
    var legacy_ctx = Context{
        .config = .{ .app_id = "wx-mp-legacy" },
        .access_token_handle = .{ .ptr = @ptrCast(&stub), .vtable = &legacy_vtable },
    };
    try std.testing.expectError(error.InvalidateNotSupported, legacy_ctx.invalidateAccessToken(allocator));
}
