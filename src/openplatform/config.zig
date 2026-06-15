//! openplatform/config — 微信开放平台（第三方平台）配置
//!
//! 对应 `_ref/wechat/openplatform/config/config.go` 的 `Config`：
//! - `AppID`           — 第三方平台的 AppID
//! - `AppSecret`       — 第三方平台的 AppSecret
//! - `Token`           — 接收消息时使用的校验 Token
//! - `EncodingAESKey`  — 接收消息时使用的 AES 加密 Key
//! - `Cache`           — 凭据缓存后端（沿用 `cache.Cache` 抽象）
//!
//! 所有字段均有默认值 `""`，便于按需填充。Cache 字段允许为 `null`，
//! 父级 `Wechat` 容器在未注入时将使用内存缓存兜底（与公众号侧语义一致）。

const std = @import("std");

const cache_mod = @import("../cache/mod.zig");
pub const Cache = cache_mod.Cache;

/// 微信开放平台（第三方平台）配置结构。
///
/// 字段名与 Go 端 `Config` 一一对应（小写转 snake_case）。实际拼装示例：
///
/// ```zig
/// const cfg = openplatform.Config{
///     .app_id = "wx...",
///     .app_secret = "...",
///     .token = "...",
///     .encoding_aes_key = "...",
///     .cache = cache.Memory.init(allocator),
/// };
/// ```
pub const Config = struct {
    /// 第三方平台 AppID。
    app_id: []const u8 = "",
    /// 第三方平台 AppSecret。
    app_secret: []const u8 = "",
    /// 消息校验 Token。
    token: []const u8 = "",
    /// 消息加解密 EncodingAESKey。
    encoding_aes_key: []const u8 = "",
    /// 凭据缓存后端（可空；为空时由调用方自行管理）。
    cache: ?Cache = null,
};

test "Config 默认值" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("", cfg.app_id);
    try std.testing.expectEqualStrings("", cfg.app_secret);
    try std.testing.expectEqualStrings("", cfg.token);
    try std.testing.expectEqualStrings("", cfg.encoding_aes_key);
    try std.testing.expect(cfg.cache == null);
}

test "Config 自定义值" {
    const cfg = Config{
        .app_id = "wx-component-1",
        .app_secret = "comp-secret",
        .token = "comp-verify-token",
        .encoding_aes_key = "comp-aes-key",
    };
    try std.testing.expectEqualStrings("wx-component-1", cfg.app_id);
    try std.testing.expectEqualStrings("comp-secret", cfg.app_secret);
    try std.testing.expectEqualStrings("comp-verify-token", cfg.token);
    try std.testing.expectEqualStrings("comp-aes-key", cfg.encoding_aes_key);
    // 未显式设置 cache → 仍为 null
    try std.testing.expect(cfg.cache == null);
}
