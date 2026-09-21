// SPDX-License-Identifier: Apache-2.0
//! miniprogram/redpacketcover — 微信红包封面
//!
//! 对应 `_ref/wechat/miniprogram/redpacketcover/redpacketcover.go`：
//! `redpacketcover/wxapp/cover_url/get_by_token` 获取可领取的红包封面链接。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 获取红包封面请求。
pub const GetRedPacketCoverRequest = struct {
    openid: []const u8,
    ctoken: []const u8,
};

/// 获取红包封面返回。
pub const GetRedPacketCoverResp = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    data: RedPacketCoverData = .{},
};

pub const RedPacketCoverData = struct {
    url: []const u8 = "",
};

/// 微信红包封面模块。
pub const RedPacketCover = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 获取红包封面链接（返回 `std.json.Parsed(GetRedPacketCoverResp)`，调用方负责 `deinit`）。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次。
    pub fn getRedPacketCoverURL(self: *Self, req: GetRedPacketCoverRequest) !std.json.Parsed(GetRedPacketCoverResp) {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("openid");
        try s.write(req.openid);
        try s.objectField("ctoken");
        try s.write(req.ctoken);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const Sender = struct {
            cover: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/redpacketcover/wxapp/cover_url/get_by_token?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.cover.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "GetRedPacketCoverURL", Sender{
            .cover = self,
            .body = body,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetRedPacketCoverResp, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

test "RedPacketCover.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-rpc" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const c = RedPacketCover.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-rpc", c.ctx.config.app_id);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "getRedPacketCoverURL token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/redpacketcover/wxapp/cover_url/get_by_token?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":{\"url\":\"https://mp.weixin.qq.com/cover/abc\"}}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-rpc" },
        .access_token_handle = stub.asHandle(),
    };
    var c = RedPacketCover.init(&ctx, allocator);

    var parsed = try c.getRedPacketCoverURL(.{ .openid = "oABC", .ctoken = "ct-1" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://mp.weixin.qq.com/cover/abc", parsed.value.data.url);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
