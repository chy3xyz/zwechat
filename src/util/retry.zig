// SPDX-License-Identifier: Apache-2.0
//! util/retry — 「取 token → 调接口 → token 失效即作废并重试一次」的统一封装
//!
//! 背景：微信 access_token 会在缓存 TTL 到期之前失效——多实例各自刷新互相顶掉、
//! 后台重置、AppSecret / 凭据变更等。此时若把 errcode 当成普通 API 错误抛出，
//! 该实例在 TTL 到期前的**所有**调用都会持续失败，消费方只能干等。
//! 业界标准恢复动作：识别 token 失效码（40001 / 40014 / 41001 / 42001）
//! → 作废本地缓存 → 重新取 token → **只重试一次**。
//!
//! 本模块把这套动作收敛到 `callApi` 一个函数，供各业务模块复用：
//! token 的取用与作废走调用方传入的 `ctx`（鸭子类型，通常是 `*Context`），
//! 实际发送走调用方传入的 `sender`——因此**各模块自己的发送逻辑与 transport
//! 注入被完整复用**，本模块不感知任何 HTTP 细节，测试也不需要真实网络。
//!
//! ## 用法
//!
//! ```zig
//! const retry = @import("../../util/retry.zig");
//!
//! const Sender = struct {
//!     mod: *Self,
//!     pub fn send(self: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
//!         // 复用模块自己的请求构造 + transport 注入，返回响应体
//!     }
//! };
//!
//! const body = try retry.callApi(self.ctx, self.allocator, "GetThing", Sender{ .mod = self });
//! defer self.allocator.free(body);
//! ```
//!
//! ## 所有权与重试语义
//!
//! - `ctx` 需提供 `getAccessToken(allocator) ![]u8` 与
//!   `invalidateAccessToken(allocator) anyerror!void`（见 `credential/mod.zig`）。
//!   token 由 `callApi` 自己释放，`sender` 只能借用，**不得保存或释放**该切片。
//! - `sender` 需提供 `pub fn send(self: @This(), allocator, token) anyerror![]u8`
//!   （`send` 必须 `pub`——它是从本模块跨文件调用的）；返回值（响应体）所有权
//!   在返回时刻转移给 `callApi`。
//! - `callApi` 返回的响应体所有权归调用方，用完需 `allocator.free`；任何失败路径
//!   都已释放内部持有的 body，不会泄漏。
//! - **只重试一次**：重试的目的是「换一个凭据」，不是「重试网络」。第二次仍失败说明
//!   问题不在 token（配额 / 权限 / 参数 / 频率），继续重试只会放大故障（微信对
//!   超频调用有配额惩罚），因此第二次的结果直接返回或报错。
//! - 网络层错误（`ctx.getAccessToken` 或 `sender.send` 抛出的非 errcode 错误）原样
//!   上抛、不重试——网络抖动是调用方重试策略的事，与凭据失效是两回事。

const std = @import("std");
const util_error = @import("error.zig");

/// 带 token 调用微信接口：自动注入 access_token、检查 errcode，
/// 遇到 token 失效码时作废缓存并重试一次。
///
/// - `ctx`：提供 `getAccessToken` / `invalidateAccessToken` 的对象（通常是 `*Context`）。
/// - `api_name`：接口名，喂给 `util_error.parseCommonError` 作为错误详情
///   （当前只用于 errcode 判定，详情不向上携带——与仓库其他 errcode 检查点一致）。
/// - `sender`：提供 `pub fn send(self: @This(), allocator, token)` 的对象（`send`
///   必须 `pub`，因为它是跨文件调用的）；按值传入，需要跨两次发送保留状态时请在
///   结构内放指针字段。
///
/// 成功（`errcode == 0` 或响应不是可识别的 JSON 错误体）时返回原始响应体，
/// 所有权归调用方。
///
/// 失败时返回：
/// - `error.ApiError`：errcode 非 0（token 类重试后仍失败，或本来就不是 token 类）；
/// - `ctx` / `sender` / `invalidateAccessToken` 抛出的原错误（原样上抛，不重试）。
pub fn callApi(ctx: anytype, allocator: std.mem.Allocator, api_name: []const u8, sender: anytype) ![]u8 {
    // sender 按值拷贝持有：`send` 声明成 `self: @This()` 或 `self: *@This()` 都能编译
    //（`&s` 让编译器认可 `s` 可能被写入，否则会报「局部变量从未被修改」）。
    var s = sender;
    _ = &s;

    const token = try ctx.getAccessToken(allocator);
    defer allocator.free(token);

    const body = try s.send(allocator, token);
    if (try util_error.parseCommonError(allocator, body, api_name)) |common_err| {
        // errcode != 0：先判断是不是 token 失效。
        var detail = common_err;
        defer detail.deinit();

        if (!util_error.isTokenInvalidErrCode(detail.errcode)) {
            allocator.free(body);
            return error.ApiError;
        }

        // token 失效：作废本地缓存 → 取新 token → 只重试一次。
        allocator.free(body);
        ctx.invalidateAccessToken(allocator) catch |err| switch (err) {
            // 自定义 handle 未实现 invalidate：退化为「用同一 token 再试一次」，
            // 仍然是最多 2 次发送；其他作废失败原样上抛，不静默吞掉。
            error.InvalidateNotSupported => {},
            else => return err,
        };

        const retry_token = try ctx.getAccessToken(allocator);
        defer allocator.free(retry_token);

        const retried = try s.send(allocator, retry_token);
        if (try util_error.parseCommonError(allocator, retried, api_name)) |retry_err| {
            var retry_detail = retry_err;
            retry_detail.deinit();
            allocator.free(retried);
            return error.ApiError;
        }
        return retried;
    }

    // errcode == 0（或非 JSON 响应，如二进制 / XML 端点）——原样交给调用方。
    return body;
}

// ──────────────────────────────────────────────────────────────────────────────
// 测试：假 ctx（带缓存与作废）+ 假 sender（脚本化响应）
// ──────────────────────────────────────────────────────────────────────────────

const token_invalid_body =
    \\{"errcode":40001,"errmsg":"invalid credential, access_token is invalid or not latest"}
;
const quota_body =
    \\{"errcode":45009,"errmsg":"reach max api daily quota limit"}
;
const ok_body =
    \\{"errcode":0,"errmsg":"ok","data":"payload"}
;

/// 假 Context：模拟真实凭据的「缓存命中 → 作废 → 回源」行为。
///
/// 每次回源按 `tokens` 顺序给出下一个 token（模拟微信换发新 token）；
/// `invalidate` 清掉内存里的缓存副本，因此下一次 `getAccessToken` 必然回源。
const FakeCtx = struct {
    tokens: []const []const u8 = &.{ "tok_1", "tok_2" },
    cached: ?[]const u8 = null,
    /// 回源次数（`getAccessToken` 真正去取 token 的次数）。
    fetch_calls: usize = 0,
    invalidate_calls: usize = 0,
    /// 非 null：`getAccessToken` 直接抛该错误（模拟取 token 失败）。
    token_error: ?anyerror = null,
    /// 非 null：`invalidateAccessToken` 抛该错误（模拟作废缓存失败）。
    invalidate_error: ?anyerror = null,
    /// 置位：`invalidateAccessToken` 报 `error.InvalidateNotSupported`（模拟旧 handle）。
    invalidate_unsupported: bool = false,

    fn getAccessToken(self: *FakeCtx, allocator: std.mem.Allocator) anyerror![]u8 {
        if (self.token_error) |err| return err;
        if (self.cached) |token| return allocator.dupe(u8, token);
        const token = self.tokens[@min(self.fetch_calls, self.tokens.len - 1)];
        self.fetch_calls += 1;
        self.cached = token;
        return allocator.dupe(u8, token);
    }

    fn invalidateAccessToken(self: *FakeCtx, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        self.invalidate_calls += 1;
        if (self.invalidate_error) |err| return err;
        if (self.invalidate_unsupported) return error.InvalidateNotSupported;
        // 与 DefaultAccessToken.invalidate 一致：删掉缓存副本，下次必然回源。
        self.cached = null;
    }
};

/// 假 sender 的共享状态（sender 按值传入，状态必须经指针共享）。
const SenderState = struct {
    /// 按调用次序返回的响应体；超出脚本的调用复用最后一项。
    responses: []const []const u8,
    calls: usize = 0,
    /// 置位：所有发送都返回网络错误。
    fail: bool = false,
    /// 每次发送收到的 token 副本（token 由 callApi 释放，不能借用原切片）。
    token_buf: [2][16]u8 = @splat(@splat(0)),
    token_len: [2]usize = .{ 0, 0 },

    fn tokenAt(self: *const SenderState, idx: usize) []const u8 {
        return self.token_buf[idx][0..self.token_len[idx]];
    }
};

const FakeSender = struct {
    state: *SenderState,

    fn send(self: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const st = self.state;
        if (st.calls < st.token_buf.len and token.len <= st.token_buf[0].len) {
            std.mem.copyForwards(u8, st.token_buf[st.calls][0..token.len], token);
            st.token_len[st.calls] = token.len;
        }
        st.calls += 1;
        if (st.fail) return error.ConnectionResetByPeer;
        return allocator.dupe(u8, st.responses[@min(st.calls - 1, st.responses.len - 1)]);
    }
};

test "callApi: 首次 40001 → 作废缓存 → 用新 token 重试一次并成功" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{};
    var state = SenderState{ .responses = &.{ token_invalid_body, ok_body } };

    const body = try callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(ok_body, body);
    // 作废恰好一次，且作废后确实回源取到了新 token。
    try std.testing.expectEqual(@as(usize, 1), ctx.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 2), ctx.fetch_calls);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    try std.testing.expectEqualStrings("tok_1", state.tokenAt(0));
    try std.testing.expectEqualStrings("tok_2", state.tokenAt(1));
    try std.testing.expect(!std.mem.eql(u8, state.tokenAt(0), state.tokenAt(1)));
}

test "callApi: 非 token 类 errcode（45009）直接 ApiError，不作废也不重试" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{};
    var state = SenderState{ .responses = &.{quota_body} };

    try std.testing.expectError(
        error.ApiError,
        callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state }),
    );

    try std.testing.expectEqual(@as(usize, 0), ctx.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.fetch_calls);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

test "callApi: 重试仍是 40001 → ApiError 且总发送次数为 2（不再重试）" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{};
    var state = SenderState{ .responses = &.{ token_invalid_body, token_invalid_body } };

    try std.testing.expectError(
        error.ApiError,
        callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state }),
    );

    try std.testing.expectEqual(@as(usize, 1), ctx.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
}

test "callApi: 成功路径不作废、不重试，token 与 body 释放正确" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{};
    var state = SenderState{ .responses = &.{ok_body} };

    const body = try callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(ok_body, body);
    try std.testing.expectEqual(@as(usize, 0), ctx.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.fetch_calls);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqualStrings("tok_1", state.tokenAt(0));
}

test "callApi: sender 网络错误原样上抛且不重试" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{};
    var state = SenderState{ .responses = &.{ok_body}, .fail = true };

    try std.testing.expectError(
        error.ConnectionResetByPeer,
        callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state }),
    );

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.invalidate_calls);
}

test "callApi: token 取用失败原样上抛，一次请求都不发" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{ .token_error = error.ConnectionRefused };
    var state = SenderState{ .responses = &.{ok_body} };

    try std.testing.expectError(
        error.ConnectionRefused,
        callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state }),
    );

    try std.testing.expectEqual(@as(usize, 0), state.calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.invalidate_calls);
}

test "callApi: 非 JSON 响应视为成功原样返回（不误判为错误）" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{};
    var state = SenderState{ .responses = &.{"<xml><ok>1</ok></xml>"} };

    const body = try callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state });
    defer allocator.free(body);

    try std.testing.expectEqualStrings("<xml><ok>1</ok></xml>", body);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.invalidate_calls);
}

test "callApi: handle 未实现 invalidate 时仍最多发送 2 次（复用旧 token）" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{ .invalidate_unsupported = true };
    var state = SenderState{ .responses = &.{ token_invalid_body, ok_body } };

    const body = try callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state });
    defer allocator.free(body);

    try std.testing.expectEqualStrings(ok_body, body);
    try std.testing.expectEqual(@as(usize, 1), ctx.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 2), state.calls);
    // 缓存没被清掉，两次发送用的是同一个 token。
    try std.testing.expectEqualStrings("tok_1", state.tokenAt(0));
    try std.testing.expectEqualStrings("tok_1", state.tokenAt(1));
}

test "callApi: 作废缓存失败（非 InvalidateNotSupported）原样上抛且不重试" {
    const allocator = std.testing.allocator;
    var ctx = FakeCtx{ .invalidate_error = error.StorageError };
    var state = SenderState{ .responses = &.{ token_invalid_body, ok_body } };

    try std.testing.expectError(
        error.StorageError,
        callApi(&ctx, allocator, "GetThing", FakeSender{ .state = &state }),
    );

    try std.testing.expectEqual(@as(usize, 1), ctx.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}
