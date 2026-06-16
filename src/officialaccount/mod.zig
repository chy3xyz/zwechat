//! officialaccount — 微信公众号业务模块
//!
//! 对应 `_ref/wechat/officialaccount/`：包含配置（config）、运行时上下文（context）、
//! 顶层 `OfficialAccount` 实例以及后续将逐步填充的子模块
//! （basic / menu / oauth / material / js / user / message / server 等）。

const std = @import("std");

pub const Config = @import("config.zig").Config;
pub const Cache = @import("config.zig").Cache;
pub const Context = @import("context.zig").Context;
pub const OfficialAccount = @import("officialaccount.zig").OfficialAccount;
pub const menu = @import("menu/mod.zig");

test "officialaccount 模块全部导出" {
    try std.testing.expect(@hasDecl(OfficialAccount, "init"));
    try std.testing.expect(@hasDecl(OfficialAccount, "newOfficialAccount"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getContext"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getAccessToken"));
    try std.testing.expect(@hasDecl(Context, "getAccessToken"));
    try std.testing.expect(@hasField(Config, "app_id"));
}
