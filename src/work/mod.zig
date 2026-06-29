//! work — 企业微信业务模块
//!
//! 对应 `_ref/wechat/work/`：包含配置（config）、运行时上下文（context）、
//! 顶层 `Work` 容器以及各子模块的懒加载入口
//! （externalcontact / invoice / addresslist / appchat / robot / oauth / jsapi 等）。
//!
//! 能力：
//! - `Work` 顶层 struct（access_token / js_ticket 透传 + 懒加载）
//! - `oauth` 子模块（UserInfoToId / GetUserInfo / GetUserDetail / Tfa）
//! - `jsapi` 子模块（GetConfig / GetAgentConfig，自动区分 corp / agent ticket）

const std = @import("std");

pub const Config = @import("config.zig").Config;
pub const Cache = @import("config.zig").Cache;
pub const Context = @import("context/mod.zig").Context;
pub const Work = @import("work.zig").Work;
pub const WorkJsTicketAdapter = @import("work.zig").WorkJsTicketAdapter;
pub const Oauth = @import("oauth/mod.zig").Oauth;
pub const Js = @import("jsapi/mod.zig").Js;
pub const JsConfig = @import("jsapi/mod.zig").Config;

pub const ExternalContact = @import("externalcontact/mod.zig").ExternalContact;
pub const Invoice = @import("invoice/mod.zig").Invoice;
pub const AddressList = @import("addresslist/mod.zig").AddressList;
pub const AppChat = @import("appchat/mod.zig").AppChat;
pub const Robot = @import("robot/mod.zig").Robot;
pub const smartbot = @import("smartbot/mod.zig");
pub const message = @import("message/mod.zig");

test "work 模块全部导出" {
    try std.testing.expect(@hasField(Config, "corp_id"));
    try std.testing.expect(@hasField(Config, "corp_secret"));
    try std.testing.expect(@hasField(Config, "agent_id"));
    try std.testing.expect(@hasDecl(Context, "getAccessToken"));
    try std.testing.expect(@hasDecl(Context, "getJsTicket"));
    try std.testing.expect(@hasDecl(Work, "init"));
    try std.testing.expect(@hasDecl(Work, "newWork"));
    try std.testing.expect(@hasDecl(Work, "getContext"));
    try std.testing.expect(@hasDecl(Work, "getAccessToken"));
    try std.testing.expect(@hasDecl(Work, "getJsTicket"));
    try std.testing.expect(@hasDecl(Work, "getCorpJsTicket"));
    try std.testing.expect(@hasDecl(Work, "getAgentJsTicket"));
    try std.testing.expect(@hasDecl(Work, "getJs"));
    try std.testing.expect(@hasDecl(Oauth, "getRedirectURL"));
    try std.testing.expect(@hasDecl(Oauth, "userInfoToId"));
    try std.testing.expect(@hasDecl(Oauth, "getUserInfo"));
    try std.testing.expect(@hasDecl(Oauth, "getUserDetail"));
    try std.testing.expect(@hasDecl(Js, "getConfig"));
    try std.testing.expect(@hasDecl(Js, "getAgentConfig"));
    try std.testing.expect(@hasDecl(Js, "setJsTicketHandle"));
    try std.testing.expect(@hasDecl(ExternalContact, "init"));
    try std.testing.expect(@hasDecl(Invoice, "init"));
    try std.testing.expect(@hasDecl(AddressList, "init"));
    try std.testing.expect(@hasDecl(AppChat, "init"));
    try std.testing.expect(@hasDecl(Robot, "init"));
    try std.testing.expect(@hasDecl(smartbot, "Server"));
}