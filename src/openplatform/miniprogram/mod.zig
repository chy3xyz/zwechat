// SPDX-License-Identifier: Apache-2.0
//! openplatform/miniprogram — 代小程序实现业务（骨架）
//!
//! 对应 `_ref/wechat/openplatform/miniprogram/`：在 Go SDK 中聚合
//! `miniprogram.MiniProgram`（小程序业务）并把 `access_token` 句柄替换为
//! `DefaultAuthrAccessToken`（从开放平台的角度拿"被授权方"的 token）。
//!
//! 已落地的 `GetXxx()` 懒加载入口：`getComponent`（快速注册小程序）、
//! `getBasic`（基础信息设置：昵称/签名/头像/搜索状态）；其余子模块
//! （urllink / rtc / membercard 等）在后续 pass 中补齐。

const std = @import("std");

const Context = @import("../context/mod.zig").Context;

/// 代小程序业务入口（骨架）。
///
/// 设计说明：
/// - 字段名 `app_id` 与 Go 端 `MiniProgram.AppID` 一致（小写转 snake_case）。
/// - `open_context` 复用上层 `OpenPlatform.ctx`（与 Go 嵌入语义等价）。
/// - 当前未持有 `*miniprogram.MiniProgram` 字段——避免在未实现子模块时
///   强引用尚未落地的业务类型。后续 pass 在引入 `minigame/minigame` 业务
///   层后补齐。
pub const OpenMiniProgram = struct {
    /// 被代运营的小程序 AppID。
    app_id: []const u8,
    /// 复用上层开放平台 ctx。
    open_context: *Context,

    const Self = @This();

    /// 构造代小程序实例。
    pub fn init(open_context: *Context, app_id: []const u8) Self {
        return .{ .app_id = app_id, .open_context = open_context };
    }

    /// 暴露内部 ctx 指针（与 Go 端 `GetContext` 语义一致），方便子模块读取配置 / token。
    pub fn getContext(self: *Self) *Context {
        return self.open_context;
    }

    /// `GetComponent` — 快速注册小程序入口（对应 Go 端 `GetComponent()`）。
    pub fn getComponent(self: *Self) @import("component.zig").Component {
        return @import("component.zig").Component.init(self.open_context);
    }

    /// `GetBasic` — 基础信息设置入口（对应 Go 端 `GetBasic()`）。
    ///
    /// 返回的 `Basic` 持有 `app_id`，接口调用走 `authorizer_access_token`
    /// （见 `basic.zig` 模块文档）。
    pub fn getBasic(self: *Self) @import("basic.zig").Basic {
        return @import("basic.zig").Basic.init(self.open_context, self.app_id);
    }
};

// 编译门：确保 component.zig（fastregisterweapp）被分析，其 inline test 被发现。
test "miniprogram/component 模块导出（编译门）" {
    const comp = @import("component.zig");
    try std.testing.expect(@hasDecl(comp, "Component"));
    try std.testing.expect(@hasDecl(comp, "RegisterMiniProgramParam"));
    try std.testing.expect(@hasDecl(comp, "RegistrationStatusParam"));
    try std.testing.expect(@hasDecl(comp.Component, "registerMiniProgram"));
    try std.testing.expect(@hasDecl(comp.Component, "getRegistrationStatus"));
}

// 编译门：确保 basic.zig（基础信息设置）被分析，其 inline test 被发现。
test "miniprogram/basic 模块导出（编译门）" {
    const basic = @import("basic.zig");
    try std.testing.expect(@hasDecl(basic, "Basic"));
    try std.testing.expect(@hasDecl(basic, "AccountBasicInfo"));
    try std.testing.expect(@hasDecl(basic, "CheckNickNameResp"));
    try std.testing.expect(@hasDecl(basic, "SetNickNameParam"));
    try std.testing.expect(@hasDecl(basic, "SetNickNameResp"));
    try std.testing.expect(@hasDecl(basic, "GetSearchStatusResp"));
    try std.testing.expect(@hasDecl(basic, "SetHeadImageParam"));
    try std.testing.expect(@hasDecl(basic.Basic, "getAccountBasicInfo"));
    try std.testing.expect(@hasDecl(basic.Basic, "checkNickName"));
    try std.testing.expect(@hasDecl(basic.Basic, "setNickName"));
    try std.testing.expect(@hasDecl(basic.Basic, "setNickNameFull"));
    try std.testing.expect(@hasDecl(basic.Basic, "setSignature"));
    try std.testing.expect(@hasDecl(basic.Basic, "getSearchStatus"));
    try std.testing.expect(@hasDecl(basic.Basic, "setSearchStatus"));
    try std.testing.expect(@hasDecl(basic.Basic, "setHeadImage"));
    try std.testing.expect(@hasDecl(basic.Basic, "setHeadImageFull"));
}

test "OpenMiniProgram.init 持有 app_id 与 ctx" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op-mp" } };
    var omp = OpenMiniProgram.init(&ctx, "wx-mp-authorized");

    try std.testing.expectEqualStrings("wx-mp-authorized", omp.app_id);
    try std.testing.expectEqual(@intFromPtr(&ctx), @intFromPtr(omp.open_context));
    try std.testing.expectEqual(@intFromPtr(&ctx), @intFromPtr(omp.getContext()));
}

test "OpenMiniProgram 默认 app_id 兼容空字符串" {
    var ctx: Context = .{ .config = .{} };
    const omp = OpenMiniProgram.init(&ctx, "");
    try std.testing.expectEqualStrings("", omp.app_id);
}
