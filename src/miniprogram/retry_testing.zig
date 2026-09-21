// SPDX-License-Identifier: Apache-2.0
//! miniprogram/retry_testing — 「token 失效自愈」用例的假凭据 handle
//!
//! 各子模块用 `util/retry.callApi` 把「取 token → 发请求 → token 失效即作废
//! 重试一次」交给统一入口。要测出这条链路，注入的 handle 必须**真的换发新
//! token**（`invalidate` 只计数而不换 token 的话，重试仍拿旧 token，测不出自愈）。
//! 真实实现 `credential.DefaultAccessToken` 需要 HTTP 回源，因此这里提供纯内存替身。
//!
//! 本文件**仅供 inline test 引用**，不参与运行时代码路径。

const std = @import("std");
const credential = @import("../credential/mod.zig");

/// 固定 token 的假 handle（不提供 `invalidate`）：验证普通成功 / 非 token 类
/// 错误的路径。未实现作废钩子时会拿到 `error.InvalidateNotSupported`。
pub const StubToken = struct {
    token: []const u8 = "token-abc",

    pub fn getAccessToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *StubToken = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.token);
    }

    /// 该 handle 的 vtable（`invalidate` 留空）。
    pub const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = StubToken.getAccessToken,
    };
};

/// 会换发新 token 的假 handle：`getAccessToken` 按次序给出 `tokens` 中的下一个，
/// `invalidate` 计数并推进游标——模拟「作废缓存 → 回源拿到新 token」。
pub const RotatingToken = struct {
    /// 依次换发的 token；超出范围时复用最后一个。
    tokens: []const []const u8 = &.{ "token-abc", "token-new" },
    /// `getAccessToken` 被调用的次数（即取 token 的次数，含命中缓存）。
    fetch_calls: usize = 0,
    /// `invalidate` 被调用的次数。
    invalidates: usize = 0,

    pub fn getAccessToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RotatingToken = @ptrCast(@alignCast(ptr));
        const idx = @min(self.fetch_calls, self.tokens.len - 1);
        self.fetch_calls += 1;
        return allocator.dupe(u8, self.tokens[idx]);
    }

    pub fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *RotatingToken = @ptrCast(@alignCast(ptr));
        self.invalidates += 1;
    }

    pub fn asHandle(self: *RotatingToken) credential.AccessTokenHandle {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = RotatingToken.getAccessToken,
        .invalidate = RotatingToken.invalidate,
    };
};

test "RotatingToken: 作废后回源拿到下一个 token" {
    const allocator = std.testing.allocator;
    var stub = RotatingToken{};
    const handle = stub.asHandle();

    const first = try handle.getAccessToken(allocator);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("token-abc", first);

    try handle.invalidateAccessToken(allocator);
    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);

    const second = try handle.getAccessToken(allocator);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("token-new", second);
    try std.testing.expectEqual(@as(usize, 2), stub.fetch_calls);
}
