// SPDX-License-Identifier: Apache-2.0
//! miniprogram/redpacketcover — 微信红包封面
//!
//! 对应 `_ref/wechat/miniprogram/redpacketcover/redpacketcover.go`：
//! `redpacketcover/wxapp/cover_url/get_by_token` 获取可领取的红包封面链接。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

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
    pub fn getRedPacketCoverURL(self: *Self, req: GetRedPacketCoverRequest) !std.json.Parsed(GetRedPacketCoverResp) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/redpacketcover/wxapp/cover_url/get_by_token?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

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

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
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
