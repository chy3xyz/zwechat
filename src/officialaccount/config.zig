//! officialaccount/config — 公众号配置
//!
//! 对应 `_ref/wechat/officialaccount/config/config.go` 的 `Config`：
//! 包含 AppID、AppSecret、Token、EncodingAESKey、Cache、UseStableAK。
//! 由调用方构造后传入 `OfficialAccount.newOfficialAccount` 或 `Context`。

const std = @import("std");
const cache_mod = @import("../cache/mod.zig");

/// 公众号配置结构。
///
/// 字段名与 Go 端 `Config` 一一对应（小写转 snake_case），默认值均为"空"。
/// 实际拼装时：
///
/// ```zig
/// const cfg = officialaccount.Config{
///     .app_id = "wx...",
///     .app_secret = "...",
///     .token = "...",
///     .encoding_aes_key = "...",
///     .cache = cache.Memory.init(allocator),
///     .use_stable_ak = false,
/// };
/// ```
pub const Config = struct {
    /// 公众号 AppID。
    app_id: []const u8 = "",
    /// 公众号 AppSecret。
    app_secret: []const u8 = "",
    /// 消息校验 Token。
    token: []const u8 = "",
    /// 消息加解密 EncodingAESKey。
    encoding_aes_key: []const u8 = "",
    /// 公众号 cache（可空；为空时由父级 Wechat 注入）。
    cache: ?cache_mod.Cache = null,
    /// 是否使用稳定版 access_token。
    use_stable_ak: bool = false,
};

/// `cache.Cache` 的语义化重导出，方便调用方引用。
pub const Cache = cache_mod.Cache;

test "Config 默认值" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("", cfg.app_id);
    try std.testing.expectEqualStrings("", cfg.app_secret);
    try std.testing.expectEqualStrings("", cfg.token);
    try std.testing.expectEqualStrings("", cfg.encoding_aes_key);
    try std.testing.expect(cfg.cache == null);
    try std.testing.expect(cfg.use_stable_ak == false);
}

test "Config 自定义值" {
    const cfg = Config{
        .app_id = "wx-test-id",
        .app_secret = "secret-value",
        .token = "verify-token",
        .encoding_aes_key = "aes-key-bytes",
        .use_stable_ak = true,
    };
    try std.testing.expectEqualStrings("wx-test-id", cfg.app_id);
    try std.testing.expectEqualStrings("secret-value", cfg.app_secret);
    try std.testing.expectEqualStrings("verify-token", cfg.token);
    try std.testing.expectEqualStrings("aes-key-bytes", cfg.encoding_aes_key);
    try std.testing.expect(cfg.use_stable_ak);
    // 显式未设置 cache → 默认为 null
    try std.testing.expect(cfg.cache == null);
}
