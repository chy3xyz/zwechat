//! minigame/config — 微信小游戏配置
//!
//! 对应 `_ref/wechat/minigame/`：上游 Go 侧只有 README，没有独立 `config` 包，
//! 但小程序侧 `miniprogram/config` 提供了完整 Config 模板。小游戏业务面
//! 与小程序高度同构（同一套 appid/appsecret + cache 抽象），本 Zig 落地
//! 复用了 `miniprogram.Config` 的字段集，去掉与小游戏无关的 `app_key` /
//! `offer_id`，仅保留"小游戏"语义必要的 4 个字段。
//!
//! 参考上游文档：<https://developers.weixin.qq.com/minigame/dev/api-backend/>

const std = @import("std");

const cache_mod = @import("../cache/mod.zig");
pub const Cache = cache_mod.Cache;

/// 微信小游戏配置结构。
///
/// 字段名与上游 Go `miniprogram/config` 保持同名同义，便于后续 pass
/// 把"小游戏"的子模块（消息推送、用户信息、客服等）直接对接。
///
/// ```zig
/// const cfg = minigame.Config{
///     .app_id = "wx...",
///     .app_secret = "...",
///     .cache = cache.Memory.init(allocator),
/// };
/// ```
pub const Config = struct {
    /// 小游戏 AppID。
    app_id: []const u8 = "",
    /// 小游戏 AppSecret。
    app_secret: []const u8 = "",
    /// 凭据缓存后端（可空；为空时由调用方自行管理）。
    cache: ?Cache = null,
};

test "Config 默认值" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("", cfg.app_id);
    try std.testing.expectEqualStrings("", cfg.app_secret);
    try std.testing.expect(cfg.cache == null);
}

test "Config 自定义值" {
    const cfg = Config{
        .app_id = "wx-minigame-1",
        .app_secret = "mg-secret",
    };
    try std.testing.expectEqualStrings("wx-minigame-1", cfg.app_id);
    try std.testing.expectEqualStrings("mg-secret", cfg.app_secret);
    try std.testing.expect(cfg.cache == null);
}
