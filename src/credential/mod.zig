//! credential — 凭据管理（access_token / js_ticket）
//!
//! 对应 `_ref/wechat/credential/`：默认从微信服务端获取 token 并缓存，
//! 上层通过 `AccessTokenHandle` / `JsTicketHandle` 抽象接口使用，便于注入自定义实现。
//!
//! 字段名约定：
//! - `AccessTokenHandle` / `JsTicketHandle` 用 `ptr` + `vtable`（与上游 Go 接口语义对齐，
//!   `ptr` 是“胖指针”中的指针部分）。
//! - `Cache`（来自 `cache/mod.zig`）用 `ctx` + `vtable`（与 `Memory` 的内部约定对齐）。

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
    /// vtable：仅含 `getAccessToken`，与 Go 接口保持一致。
    vtable: *const VTable,

    pub const VTable = struct {
        /// 返回堆分配的 `access_token` 字符串，由调用方负责 `allocator.free`。
        getAccessToken: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    };

    /// 通过抽象接口获取 access_token。错误集合是 vtable 函数错误集的超集。
    pub fn getAccessToken(self: AccessTokenHandle, allocator: std.mem.Allocator) anyerror![]u8 {
        return self.vtable.getAccessToken(self.ptr, allocator);
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
    };

    /// 通过抽象接口获取 jsapi_ticket。
    pub fn getTicket(
        self: JsTicketHandle,
        allocator: std.mem.Allocator,
        access_token: []const u8,
    ) anyerror![]u8 {
        return self.vtable.getTicket(self.ptr, allocator, access_token);
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

// ──────────────────────────────────────────────────────────────────────────────
// 模块自检
// ──────────────────────────────────────────────────────────────────────────────

test "credential 模块导出默认实现与前缀常量" {
    try std.testing.expect(@hasDecl(DefaultAccessToken, "init"));
    try std.testing.expect(@hasDecl(DefaultAccessToken, "getAccessToken"));
    try std.testing.expect(@hasDecl(DefaultAccessToken, "asHandle"));

    try std.testing.expect(@hasDecl(DefaultJsTicket, "init"));
    try std.testing.expect(@hasDecl(DefaultJsTicket, "getTicket"));
    try std.testing.expect(@hasDecl(DefaultJsTicket, "asHandle"));

    try std.testing.expectEqualStrings("gowechat_officialaccount_", CacheKeyOfficialAccountPrefix);
    try std.testing.expectEqualStrings("gowechat_miniprogram_", CacheKeyMiniProgramPrefix);
    try std.testing.expectEqualStrings("gowechat_work_", CacheKeyWorkPrefix);
}
