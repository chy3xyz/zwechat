// SPDX-License-Identifier: Apache-2.0
//! credential — 凭据管理（access_token / js_ticket）
//!
//! 对应 `_ref/wechat/credential/`：默认从微信服务端获取 token 并缓存，
//! 上层通过 `AccessTokenHandle` / `JsTicketHandle` 抽象接口使用，便于注入自定义实现。
//!
//! 字段名约定：
//! - `AccessTokenHandle` / `JsTicketHandle` 用 `ptr` + `vtable`（与上游 Go 接口语义对齐，
//!   `ptr` 是“胖指针”中的指针部分）。
//! - `Cache`（来自 `cache/mod.zig`）用 `ctx` + `vtable`（与 `Memory` 的内部约定对齐）。
//!
//! 「token 失效 → 作废 → 重试一次」的统一入口见 `util/retry.zig`：它通过
//! `invalidateAccessToken` 调用本模块的作废钩子。

const std = @import("std");

const cache_mod = @import("../cache/mod.zig");
pub const Cache = cache_mod.Cache;
pub const CacheError = cache_mod.CacheError;

// ──────────────────────────────────────────────────────────────────────────────
// 错误集
// ──────────────────────────────────────────────────────────────────────────────

/// 凭据管理错误集合：JSON 解析、缓存、内存分配、HTTP、微信接口错误。
///
/// 所有公开 API 都返回 `CredentialError!T` 或其子集，避免泄漏 `anyerror`。
pub const CredentialError = std.json.Error ||
    std.mem.Allocator.Error ||
    CacheError ||
    error{
        /// 微信接口返回了 errcode != 0。
        ApiError,
        /// HTTP / 网络请求失败（来自注入的 fetcher）。
        HttpError,
        /// 解析响应失败（JSON 格式错误或关键字段缺失）。
        DecodeError,
        /// 配置缺失（如 agent_id 为空但请求 agent ticket）。
        ConfigMissing,
    };

// ──────────────────────────────────────────────────────────────────────────────
// AccessToken 抽象接口
// ──────────────────────────────────────────────────────────────────────────────

/// `access_token` 抽象接口。对应 `_ref/wechat/credential/access_token.go` 的
/// `AccessTokenHandle`。通过 `DefaultAccessToken.asHandle()` 获得。
pub const AccessTokenHandle = struct {
    /// 指向具体实现的指针（通常是 `*DefaultAccessToken`）。
    ptr: *anyopaque,
    /// vtable：`getAccessToken` 必填，`invalidate` 可选（未提供时见 `invalidateAccessToken`）。
    vtable: *const VTable,

    pub const VTable = struct {
        /// 返回堆分配的 `access_token` 字符串，由调用方负责 `allocator.free`。
        getAccessToken: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,

        /// 作废当前缓存的 access_token（删除缓存条目 + 清掉实现内部持有的副本），
        /// 使下一次 `getAccessToken` 必须回源。
        ///
        /// 可选字段（默认 `null`）：注入的自定义 handle 不实现作废也能继续工作；
        /// 触发 token 失效恢复链路时请实现它，否则会拿到
        /// `error.InvalidateNotSupported`。
        invalidate: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void = null,
    };

    /// 通过抽象接口获取 access_token。错误集合是 vtable 函数错误集的超集。
    pub fn getAccessToken(self: AccessTokenHandle, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.vtable.getAccessToken(self.ptr, allocator);
    }

    /// 通过抽象接口作废缓存的 access_token（token 失效时的恢复动作第一步）。
    ///
    /// 实现未提供 `invalidate` 钩子时返回 `error.InvalidateNotSupported`
    /// （`util/retry.callApi` 会捕获该错误并退化为「用同一 token 再试一次」）。
    pub fn invalidateAccessToken(self: AccessTokenHandle, allocator: std.mem.Allocator) anyerror!void {
        const f = self.vtable.invalidate orelse return error.InvalidateNotSupported;
        return f(self.ptr, allocator);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// JsTicket 抽象接口
// ──────────────────────────────────────────────────────────────────────────────

/// `jsapi_ticket` 抽象接口。对应 `_ref/wechat/credential/js_ticket.go` 的 `JsTicketHandle`。
pub const JsTicketHandle = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 返回堆分配的 ticket 字符串，由调用方负责 `allocator.free`。
        getTicket: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            access_token: []const u8,
        ) anyerror![]u8,

        /// 作废缓存的 ticket（ticket 同样会因 access_token 失效 / 提前作废而失效）。
        ///
        /// 可选字段（默认 `null`）：未提供的实现调用作废时返回
        /// `error.InvalidateNotSupported`。
        invalidate: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void = null,
    };

    /// 通过抽象接口获取 jsapi_ticket。
    pub fn getTicket(
        self: JsTicketHandle,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) anyerror![]u8 {
        return self.vtable.getTicket(self.ptr, allocator, access_token);
    }

    /// 通过抽象接口作废缓存的 ticket。
    ///
    /// 实现未提供 `invalidate` 钩子时返回 `error.InvalidateNotSupported`。
    pub fn invalidateTicket(self: JsTicketHandle, allocator: std.mem.Allocator) anyerror!void {
        const f = self.vtable.invalidate orelse return error.InvalidateNotSupported;
        return f(self.ptr, allocator);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 默认实现（re-export）
// ──────────────────────────────────────────────────────────────────────────────

pub const DefaultAccessToken = @import("default_access_token.zig").DefaultAccessToken;
pub const DefaultJsTicket = @import("js_ticket.zig").DefaultJsTicket;
pub const WorkAccessToken = @import("work_access_token.zig").WorkAccessToken;
pub const WorkJsTicket = @import("work_js_ticket.zig").WorkJsTicket;
pub const TicketType = @import("work_js_ticket.zig").TicketType;

// ──────────────────────────────────────────────────────────────────────────────
// Fetcher：可注入的 HTTP 后端
// ──────────────────────────────────────────────────────────────────────────────

/// HTTP fetcher 函数签名。生产代码默认指向 `util.http.getDefaultClient().get`；
/// 测试代码可注入桩 fetcher 返回预制的 JSON 响应，避免真实网络请求。
pub const Fetcher = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
) CredentialError![]u8;

// ──────────────────────────────────────────────────────────────────────────────
// 缓存 key 前缀（与 Go `_ref/wechat/credential/default_access_token.go` 保持一致）
// ──────────────────────────────────────────────────────────────────────────────

pub const CacheKeyOfficialAccountPrefix = "gowechat_officialaccount_";
pub const CacheKeyMiniProgramPrefix = "gowechat_miniprogram_";
pub const CacheKeyWorkPrefix = "gowechat_work_";

/// 由微信返回的 `expires_in` 计算缓存 TTL（秒）。
///
/// 规则（与上游 Go 版对齐并修补其边界缺陷）：
/// - 提前 1500 秒（25 分钟）失效，避免边界 race（与 Go 一致）。
/// - 减法用饱和版本：恶意 / 异常的 `expires_in`（如 i64 最小值）不会让
///   `expires_in - 1500` 在 Debug 下整数溢出 panic。
/// - 结果下限钳制为 1 秒：Go 版在 `expires_in <= 1500` 时会写入一个
///   「已过期」的缓存条目（每次读取都 miss，等价于高频回源）；而本仓库
///   `cache.Memory` 的契约是 `ttl <= 0` 表示永不过期，直接透传会让
///   短寿命 token 变成**永不过期的陈旧 token**。钳制到 1 秒兼顾两者：
///   几乎立即回源，又绝不永久缓存。
pub fn tokenTTL(expires_in: i64) i64 {
    const ttl = expires_in -| 1500;
    return @max(ttl, 1);
}

// ──────────────────────────────────────────────────────────────────────────────
// 模块自检
// ──────────────────────────────────────────────────────────────────────────────

test "credential 模块导出默认实现与前缀常量" {
    try std.testing.expect(@hasDecl(DefaultAccessToken, "init"));
    try std.testing.expect(@hasDecl(DefaultAccessToken, "getAccessToken"));
    try std.testing.expect(@hasDecl(DefaultAccessToken, "asHandle"));
    try std.testing.expect(@hasDecl(DefaultAccessToken, "invalidate"));

    try std.testing.expect(@hasDecl(DefaultJsTicket, "init"));
    try std.testing.expect(@hasDecl(DefaultJsTicket, "getTicket"));
    try std.testing.expect(@hasDecl(DefaultJsTicket, "asHandle"));
    try std.testing.expect(@hasDecl(DefaultJsTicket, "invalidate"));

    try std.testing.expect(@hasDecl(WorkAccessToken, "getAccessToken"));
    try std.testing.expect(@hasDecl(WorkAccessToken, "asHandle"));
    try std.testing.expect(@hasDecl(WorkAccessToken, "invalidate"));

    // 企微 ticket 有 corp / agent 两种，作废钩子分「按类型」与「全量」两级。
    try std.testing.expect(@hasDecl(WorkJsTicket, "getTicket"));
    try std.testing.expect(@hasDecl(WorkJsTicket, "invalidate"));
    try std.testing.expect(@hasDecl(WorkJsTicket, "invalidateAll"));

    try std.testing.expect(@hasDecl(AccessTokenHandle, "getAccessToken"));
    try std.testing.expect(@hasDecl(AccessTokenHandle, "invalidateAccessToken"));
    try std.testing.expect(@hasDecl(JsTicketHandle, "getTicket"));
    try std.testing.expect(@hasDecl(JsTicketHandle, "invalidateTicket"));

    try std.testing.expectEqualStrings("gowechat_officialaccount_", CacheKeyOfficialAccountPrefix);
    try std.testing.expectEqualStrings("gowechat_miniprogram_", CacheKeyMiniProgramPrefix);
    try std.testing.expectEqualStrings("gowechat_work_", CacheKeyWorkPrefix);
}

/// 旧式 vtable：只实现 `getAccessToken`（`invalidate` 走可选字段的默认值）。
/// 用于证明「新增可选钩子」不破坏既有注入点（各业务模块测试的 stub vtable 即此形态）。
const legacy_token_stub_vtable = AccessTokenHandle.VTable{
    .getAccessToken = struct {
        fn f(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "legacy_token");
        }
    }.f,
};

test "AccessTokenHandle: 未提供 invalidate 钩子时返回 InvalidateNotSupported" {
    var dummy: u8 = 0;
    const handle = AccessTokenHandle{ .ptr = @ptrCast(&dummy), .vtable = &legacy_token_stub_vtable };

    const token = try handle.getAccessToken(std.testing.allocator);
    defer std.testing.allocator.free(token);
    try std.testing.expectEqualStrings("legacy_token", token);

    try std.testing.expectError(
        error.InvalidateNotSupported,
        handle.invalidateAccessToken(std.testing.allocator),
    );
}

test "AccessTokenHandle / JsTicketHandle: 提供 invalidate 钩子时转发到实现" {
    const Stub = struct {
        var invalidate_calls: usize = 0;

        fn getAccessToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "stub_token");
        }

        fn invalidate(_: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
            _ = allocator;
            invalidate_calls += 1;
        }

        fn getTicket(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return allocator.dupe(u8, "stub_ticket");
        }

        const access_vtable = AccessTokenHandle.VTable{
            .getAccessToken = getAccessToken,
            .invalidate = invalidate,
        };
        const ticket_vtable = JsTicketHandle.VTable{
            .getTicket = getTicket,
            .invalidate = invalidate,
        };
    };

    var dummy: u8 = 0;
    const access_handle = AccessTokenHandle{ .ptr = @ptrCast(&dummy), .vtable = &Stub.access_vtable };
    const ticket_handle = JsTicketHandle{ .ptr = @ptrCast(&dummy), .vtable = &Stub.ticket_vtable };

    try access_handle.invalidateAccessToken(std.testing.allocator);
    try ticket_handle.invalidateTicket(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), Stub.invalidate_calls);
}

test "tokenTTL 常规值提前 1500 秒" {
    try std.testing.expectEqual(@as(i64, 5700), tokenTTL(7200));
    try std.testing.expectEqual(@as(i64, 1), tokenTTL(1500));
    try std.testing.expectEqual(@as(i64, 1), tokenTTL(0));
}

test "tokenTTL 极值不溢出且不退化为永不过期" {
    // i64 最小值：旧实现 `expires_in - 1500` 在 Debug 下溢出 panic。
    try std.testing.expectEqual(@as(i64, 1), tokenTTL(std.math.minInt(i64)));
    // i64 最大值：饱和后仍为巨大正数。
    try std.testing.expect(tokenTTL(std.math.maxInt(i64)) > 0);
    // 任何输入结果都必须 >= 1，避免 cache.Memory 把 ttl <= 0 当作永不过期。
    try std.testing.expectEqual(@as(i64, 1), tokenTTL(-5));
}
