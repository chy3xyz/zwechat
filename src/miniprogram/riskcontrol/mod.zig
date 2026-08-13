// SPDX-License-Identifier: Apache-2.0
//! miniprogram/riskcontrol — 安全风控
//!
//! 对应 `_ref/wechat/miniprogram/riskcontrol/riskcontrol.go`：
//! `wxa/getuserriskrank` 获取用户安全等级。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 获取用户安全等级请求。
pub const UserRiskRankRequest = struct {
    appid: []const u8 = "",
    openid: []const u8 = "",
    /// 场景值：0=注册，1=营销作弊。
    scene: u8 = 0,
    client_ip: []const u8 = "",
    mobile_no: []const u8 = "",
    email_address: []const u8 = "",
    extended_info: []const u8 = "",
    is_test: bool = false,
};

/// 用户安全等级结果。
pub const UserRiskRank = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    union_id: i64 = 0,
    risk_rank: u8 = 0,
};

/// 安全风控模块。
pub const RiskControl = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 获取用户安全等级（返回 `std.json.Parsed(UserRiskRank)`，调用方负责 `deinit`）。
    pub fn getUserRiskRank(self: *Self, req: UserRiskRankRequest) !std.json.Parsed(UserRiskRank) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/getuserriskrank?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("appid");
        try s.write(req.appid);
        try s.objectField("openid");
        try s.write(req.openid);
        try s.objectField("scene");
        try s.write(req.scene);
        try s.objectField("client_ip");
        try s.write(req.client_ip);
        if (req.mobile_no.len > 0) {
            try s.objectField("mobile_no");
            try s.write(req.mobile_no);
        }
        if (req.email_address.len > 0) {
            try s.objectField("email_address");
            try s.write(req.email_address);
        }
        if (req.extended_info.len > 0) {
            try s.objectField("extended_info");
            try s.write(req.extended_info);
        }
        try s.objectField("is_test");
        try s.write(req.is_test);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(UserRiskRank, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

test "RiskControl.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-rc" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const rc = RiskControl.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-rc", rc.ctx.config.app_id);
}

test "UserRiskRank 默认值" {
    const r = UserRiskRank{};
    try std.testing.expectEqual(@as(u8, 0), r.risk_rank);
}
