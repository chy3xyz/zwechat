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
    /// `unoin_id` 是微信官方文档 `wxa/getuserriskrank` 中真实返回的 key
    /// （官方笔误，长期存在于线上响应体），以它为主解析。
    unoin_id: i64 = 0,
    /// `union_id` 作为别名兜底：若微信日后悄悄修正笔误，该字段可继续取到值，
    /// 防止回归。
    union_id: i64 = 0,
    risk_rank: u8 = 0,

    const Self = @This();

    /// 读取 union_id，返回 `unoin_id` 与 `union_id` 中**非零**的那个。
    ///
    /// 线上返回体以官方笔误 key `unoin_id` 为准；两者同时出现时取非零者
    /// （若都非零则优先 `unoin_id`，因为它对应真实线上 key）。
    pub fn getUnionId(self: Self) i64 {
        if (self.unoin_id != 0) return self.unoin_id;
        return self.union_id;
    }
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

        var parsed = std.json.parseFromSlice(UserRiskRank, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
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
    try std.testing.expectEqual(@as(i64, 0), r.getUnionId());
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock access_token 句柄（测试用）
// ─────────────────────────────────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-rc");
    }
};
const token_vtable = @import("../../credential/mod.zig").AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-rc" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "getUserRiskRank 解析官方笔误 key unoin_id" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/getuserriskrank?access_token=token-rc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"unoin_id\":123,\"risk_rank\":0}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var rc = RiskControl.init(&ctx, allocator);
    var parsed = try rc.getUserRiskRank(.{
        .appid = "wx-rc",
        .openid = "oAAA",
        .scene = 1,
        .client_ip = "127.0.0.1",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 123), parsed.value.unoin_id);
    try std.testing.expectEqual(@as(i64, 123), parsed.value.getUnionId());
}

test "getUserRiskRank union_id 别名兜底" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    // 无 typo 的正规 key：unoin_id 缺席，union_id 兜底取到值。
    try mt.addRoute("https://api.weixin.qq.com/wxa/getuserriskrank?access_token=token-rc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"union_id\":456}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var rc = RiskControl.init(&ctx, allocator);
    var parsed = try rc.getUserRiskRank(.{
        .appid = "wx-rc",
        .openid = "oAAA",
        .scene = 1,
        .client_ip = "127.0.0.1",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 0), parsed.value.unoin_id);
    try std.testing.expectEqual(@as(i64, 456), parsed.value.union_id);
    try std.testing.expectEqual(@as(i64, 456), parsed.value.getUnionId());
}

test "getUserRiskRank 两者并存时取非零者" {
    // 直接构造结果值验证 getUnionId 取舍逻辑，无需 mock。
    const both_nonzero = UserRiskRank{ .unoin_id = 123, .union_id = 456 };
    try std.testing.expectEqual(@as(i64, 123), both_nonzero.getUnionId());
    const only_alias = UserRiskRank{ .union_id = 456 };
    try std.testing.expectEqual(@as(i64, 456), only_alias.getUnionId());
    const only_typo = UserRiskRank{ .unoin_id = 789 };
    try std.testing.expectEqual(@as(i64, 789), only_typo.getUnionId());
    const neither = UserRiskRank{};
    try std.testing.expectEqual(@as(i64, 0), neither.getUnionId());
}
