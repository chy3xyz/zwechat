//! zwechat — 微信开放接口 SDK（Zig 重写版）
//!
//! 对应 [`silenceper/wechat`](https://github.com/silenceper/wechat) v2 这套 Go 微信开放接口 SDK，
//! 提供微信公众号、小程序、小游戏、微信支付、开放平台、企业微信、智能对话等能力。
//!
//! ## 模块组织
//!
//! - `cache`        — 缓存抽象（内存 / Redis / Memcache）
//! - `credential`   — access_token / js_ticket 凭据管理
//! - `util`         — 通用工具（HTTP、加解密、签名、时间、参数排序等）
//! - `wechat`       — 顶层 Wechat struct
//! - `officialaccount` — 微信公众号相关 API
//!
//! 所有依赖都通过 `@import` 静态解析；下游包只需 `b.dependOn` 本模块即可。

const std = @import("std");

/// 版本号，与 `build.zig.zon` 保持一致。
pub const version = "0.0.1";

/// 顶层 Wechat 入口。
pub const wechat = @import("wechat.zig");
/// 缓存抽象与内置实现。
pub const cache = @import("cache/mod.zig");
/// 凭据管理（access_token / js_ticket）。
pub const credential = @import("credential/mod.zig");
/// 通用工具集。
pub const util = @import("util/mod.zig");
/// 微信公众号业务模块。
pub const officialaccount = @import("officialaccount/mod.zig");

test "version 与 build.zig.zon 保持一致" {
    try std.testing.expectEqualStrings("0.0.1", version);
}