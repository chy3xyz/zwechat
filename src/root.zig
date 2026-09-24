// SPDX-License-Identifier: Apache-2.0
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
///
/// 测试会从 `build.zig.zon` 重新读取版本号对账，任何单侧修改都会让
/// `zig build test` 失败，防止再次漂移。
pub const version = "0.5.0";

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
/// 企业微信业务模块。
pub const work = @import("work/mod.zig");
/// 微信支付业务模块。
pub const pay = @import("pay/mod.zig");
/// 微信小程序业务模块。
pub const miniprogram = @import("miniprogram/mod.zig");
/// 微信开放平台业务模块。
pub const openplatform = @import("openplatform/mod.zig");
/// 常用 Web 框架 (zfinal/zigmodu) 回调中间件。
pub const middleware = @import("middleware/mod.zig");

test "version 与 build.zig.zon 保持一致" {
    // 从 build.zig.zon 源码中提取 `.version = "X.Y.Z"` 做对账，
    // 防止常量与包清单再次漂移（历史上曾停留在 0.0.1 而 zon 已升到 0.4.x）。
    const allocator = std.testing.allocator;
    // 测试由 test runner 托管一个 `Io` 实例（`std.testing.io`），
    // 库代码不应访问 `std.Options.debug_io`（那是给 `std.debug` 用的）。
    const io = std.testing.io;
    const zon = try std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", allocator, .limited(64 * 1024));
    defer allocator.free(zon);

    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, zon, marker) orelse return error.ZonVersionNotFound;
    const rest = zon[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.ZonVersionNotFound;
    try std.testing.expectEqualStrings(rest[0..end], version);
}

test "root 导出所有业务模块" {
    try std.testing.expect(@hasDecl(@This(), "work"));
    try std.testing.expect(@hasDecl(@This(), "pay"));
    try std.testing.expect(@hasDecl(@This(), "miniprogram"));
    try std.testing.expect(@hasDecl(@This(), "openplatform"));
    try std.testing.expect(@hasDecl(@This(), "middleware"));
}
