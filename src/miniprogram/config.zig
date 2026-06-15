//! miniprogram/config — 小程序配置

const std = @import("std");
const cache_mod = @import("../cache/mod.zig");
const Cache = cache_mod.Cache;

pub const Config = struct {
    app_id: []const u8 = "",
    app_secret: []const u8 = "",
    app_key: []const u8 = "",
    offer_id: []const u8 = "",
    token: []const u8 = "",
    encoding_aes_key: []const u8 = "",
    cache: ?Cache = null,
    use_stable_ak: bool = false,
};

test "Config 默认值" {
    const c = Config{};
    try std.testing.expectEqualStrings("", c.app_id);
    try std.testing.expect(c.cache == null);
}