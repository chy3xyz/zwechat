//! work/config — 企业微信配置
//!
//! 对应 `_ref/wechat/work/config/config.go` 的 `Config`：
//! 包含 CorpID、CorpSecret、AgentID、Cache、Token、EncodingAESKey 等。
//! 由调用方构造后传入 `Work` 聚合实例或各子模块的 `Context`。

const std = @import("std");
const cache_mod = @import("../cache/mod.zig");

/// 企业微信配置结构。
///
/// 字段名与 Go 端 `Config` 一一对应（小写转 snake_case），默认值均为"空"。
/// 实际拼装时：
///
/// ```zig
/// const cfg = work.Config{
///     .corp_id = "ww...",
///     .corp_secret = "...",
///     .agent_id = "1000001",
///     .cache = cache.Memory.init(allocator),
/// };
/// ```
pub const Config = struct {
    /// 企业 CorpID（"ww" 开头）。
    corp_id: []const u8 = "",
    /// 应用 Secret。
    corp_secret: []const u8 = "",
    /// 应用 AgentID。
    agent_id: []const u8 = "",
    /// 企业微信 cache（可空；为空时由父级 Wechat 注入）。
    cache: ?cache_mod.Cache = null,
    /// 消息加密私钥（可选，用于会话存档等场景）。
    ras_private_key: []const u8 = "",
    /// 微信客服回调 Token（用于校验回调请求签名）。
    token: []const u8 = "",
    /// 微信客服回调 EncodingAESKey（用于解密回调消息内容）。
    encoding_aes_key: []const u8 = "",
};

/// `cache.Cache` 的语义化重导出，方便调用方引用。
pub const Cache = cache_mod.Cache;

test "Config 默认值" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("", cfg.corp_id);
    try std.testing.expectEqualStrings("", cfg.corp_secret);
    try std.testing.expectEqualStrings("", cfg.agent_id);
    try std.testing.expectEqualStrings("", cfg.ras_private_key);
    try std.testing.expectEqualStrings("", cfg.token);
    try std.testing.expectEqualStrings("", cfg.encoding_aes_key);
    try std.testing.expect(cfg.cache == null);
}

test "Config 自定义值" {
    const cfg = Config{
        .corp_id = "ww-test-corp",
        .corp_secret = "secret-value",
        .agent_id = "1000002",
        .token = "verify-token",
        .encoding_aes_key = "aes-key-bytes",
    };
    try std.testing.expectEqualStrings("ww-test-corp", cfg.corp_id);
    try std.testing.expectEqualStrings("secret-value", cfg.corp_secret);
    try std.testing.expectEqualStrings("1000002", cfg.agent_id);
    try std.testing.expectEqualStrings("verify-token", cfg.token);
    try std.testing.expectEqualStrings("aes-key-bytes", cfg.encoding_aes_key);
    // 显式未设置 cache → 默认为 null
    try std.testing.expect(cfg.cache == null);
}
