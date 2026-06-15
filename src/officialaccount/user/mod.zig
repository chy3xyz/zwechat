//! officialaccount/user — 用户管理 / 标签 / 黑名单

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 单个用户基本信息。
pub const UserInfo = struct {
    subscribe: i64 = 0,
    openid: []const u8 = "",
    nickname: []const u8 = "",
    sex: i64 = 0,
    city: []const u8 = "",
    country: []const u8 = "",
    province: []const u8 = "",
    language: []const u8 = "",
    headimgurl: []const u8 = "",
    subscribe_time: i64 = 0,
    unionid: []const u8 = "",
    remark: []const u8 = "",
    groupid: i64 = 0,
    tagid_list: []const i64 = &.{},
    subscribe_scene: []const u8 = "",
    qr_scene: i64 = 0,
    qr_scene_str: []const u8 = "",
};

pub const OpenidList = struct {
    total: i64 = 0,
    count: i64 = 0,
    next_openid: []const u8 = "",
    openids: []const []const u8 = &.{},
};

pub const User = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    pub fn getUserInfo(self: *Self, open_id: []const u8) !UserInfo {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/user/info?access_token={s}&openid={s}&lang=zh_CN",
            .{ access_token, open_id },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(UserInfo, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();
        return parsed.value;
    }

    pub fn getOpenidList(self: *Self, next_openid: []const u8) !OpenidList {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/user/get?access_token={s}&next_openid={s}",
            .{ access_token, next_openid },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(OpenidList, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.total == 0 and parsed.value.openids.len == 0) {
            // 可能返回 errcode；调用方应当检查
        }
        return parsed.value;
    }

    pub fn updateRemark(self: *Self, open_id: []const u8, remark: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/user/info/updateremark?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"openid\":\"{s}\",\"remark\":\"{s}\"}}",
            .{ open_id, remark },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "UpdateRemark")) |_| {
            return util_error.WechatError.ApiError;
        }
    }
};

test "UserInfo 默认值" {
    const u = UserInfo{};
    try std.testing.expectEqualStrings("", u.openid);
    try std.testing.expectEqual(@as(i64, 0), u.subscribe);
}

test "OpenidList 默认值" {
    const l = OpenidList{};
    try std.testing.expectEqual(@as(i64, 0), l.total);
    try std.testing.expectEqualStrings("", l.next_openid);
}