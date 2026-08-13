// SPDX-License-Identifier: Apache-2.0
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
pub const basic = @import("basic/mod.zig");
pub const broadcast = @import("broadcast/mod.zig");
pub const customerservice = @import("customerservice/mod.zig");
pub const datacube = @import("datacube/mod.zig");
pub const device = @import("device/mod.zig");
pub const draft = @import("draft/mod.zig");
pub const freepublish = @import("freepublish/mod.zig");
pub const js = @import("js/mod.zig");
pub const material = @import("material/mod.zig");
pub const menu = @import("menu/mod.zig");
pub const message = @import("message/mod.zig");
pub const oauth = @import("oauth/mod.zig");
pub const ocr = @import("ocr/mod.zig");
pub const server = @import("server/mod.zig");
pub const user = @import("user/mod.zig");

test "officialaccount 模块全部导出" {
    try std.testing.expect(@hasDecl(OfficialAccount, "init"));
    try std.testing.expect(@hasDecl(OfficialAccount, "newOfficialAccount"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getContext"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getAccessToken"));
    // 子模块懒加载工厂。
    try std.testing.expect(@hasDecl(OfficialAccount, "getBasic"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getBroadcast"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getCustomerService"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getDataCube"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getDevice"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getDraft"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getFreePublish"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getJs"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getMaterial"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getMenu"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getMessage"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getOauth"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getOcr"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getServer"));
    try std.testing.expect(@hasDecl(OfficialAccount, "getUser"));
    try std.testing.expect(@hasDecl(Context, "getAccessToken"));
    try std.testing.expect(@hasField(Config, "app_id"));
    // 子模块 barrel 导出（复用方通过 officialaccount.<module>.<Type> 访问）。
    try std.testing.expect(@hasDecl(basic, "Basic"));
    try std.testing.expect(@hasDecl(broadcast, "Broadcast"));
    try std.testing.expect(@hasDecl(customerservice, "CustomerService"));
    try std.testing.expect(@hasDecl(datacube, "DataCube"));
    try std.testing.expect(@hasDecl(device, "Device"));
    try std.testing.expect(@hasDecl(draft, "Draft"));
    try std.testing.expect(@hasDecl(freepublish, "FreePublish"));
    try std.testing.expect(@hasDecl(material, "Material"));
    try std.testing.expect(@hasDecl(ocr, "Ocr"));
    try std.testing.expect(@hasDecl(user, "User"));
}
