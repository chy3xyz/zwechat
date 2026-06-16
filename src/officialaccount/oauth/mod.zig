//! officialaccount/oauth — 网页授权
//!
//! 对应 `_ref/wechat/officialaccount/oauth/oauth.go`：构建跳转 URL、code 换 token、刷新 token、获取用户信息。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Oauth = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 构造网页授权跳转 URL（scope: snsapi_base / snsapi_userinfo）。
    ///
    /// 注意：`redirect_uri` 在传输前需要 URL 编码；Go 版调用了 `url.QueryEscape`，
    /// 这里同样需要调用方在传入前自行编码（或用 std.Uri.percentEncodeBackwardsCompatible 编码），
    /// 与 Go 行为对齐。
    pub fn getRedirectURL(self: *Self, redirect_uri: []const u8, scope: []const u8, state: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "https://open.weixin.qq.com/connect/oauth2/authorize?appid={s}&redirect_uri={s}&response_type=code&scope={s}&state={s}#wechat_redirect",
            .{ self.ctx.config.app_id, redirect_uri, scope, state },
        );
    }

    /// code → user access_token（含 openid / refresh_token）。
    /// 返回的 `std.json.Parsed(ResAccessToken)` 由调用方持有并负责 `deinit`，
    /// 避免内部切片（openid/unionid 等）在返回前被释放导致 use-after-free。
    pub fn getUserAccessToken(self: *Self, code: []const u8) !std.json.Parsed(ResAccessToken) {
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/sns/oauth2/access_token?appid={s}&secret={s}&code={s}&grant_type=authorization_code",
            .{ self.ctx.config.app_id, self.ctx.config.app_secret, code },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResAccessToken, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };

        if (parsed.value.errcode != 0) {
            parsed.deinit();
            return util_error.WechatError.ApiError;
        }
        return parsed;
    }

    /// 刷新 user access_token。
    pub fn refreshAccessToken(self: *Self, refresh_token: []const u8) !ResAccessToken {
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/sns/oauth2/refresh_token?appid={s}&grant_type=refresh_token&refresh_token={s}",
            .{ self.ctx.config.app_id, refresh_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResAccessToken, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 校验 user access_token 是否有效。
    pub fn checkAccessToken(self: *Self, access_token: []const u8, open_id: []const u8) !bool {
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/sns/auth?access_token={s}&openid={s}",
            .{ access_token, open_id },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(CommonError, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        return parsed.value.errcode == 0;
    }

    /// 获取用户基本信息（需 scope=snsapi_userinfo）。
    /// 返回的 `std.json.Parsed(UserInfo)` 由调用方持有并负责 `deinit`，
    /// 避免内部切片（nickname/headimgurl/unionid 等）在返回前被释放导致 use-after-free。
    pub fn getUserInfo(self: *Self, access_token: []const u8, open_id: []const u8, lang: []const u8) !std.json.Parsed(UserInfo) {
        const language = if (lang.len == 0) "zh_CN" else lang;
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/sns/userinfo?access_token={s}&openid={s}&lang={s}",
            .{ access_token, open_id, language },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(UserInfo, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };

        if (parsed.value.errcode != 0) {
            parsed.deinit();
            return util_error.WechatError.ApiError;
        }
        return parsed;
    }
};

pub const CommonError = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const ResAccessToken = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    access_token: []const u8 = "",
    expires_in: i64 = 0,
    refresh_token: []const u8 = "",
    openid: []const u8 = "",
    scope: []const u8 = "",
    unionid: []const u8 = "",
    is_snapshotuser: i64 = 0,
};

pub const UserInfo = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    openid: []const u8 = "",
    nickname: []const u8 = "",
    sex: i64 = 0,
    province: []const u8 = "",
    city: []const u8 = "",
    country: []const u8 = "",
    headimgurl: []const u8 = "",
    privilege: []const []const u8 = &.{},
    unionid: []const u8 = "",
};

test "Oauth.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-oa", .app_secret = "sec" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const o = Oauth.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-oa", o.ctx.config.app_id);
}

test "ResAccessToken 默认值" {
    const r = ResAccessToken{};
    try std.testing.expectEqualStrings("", r.access_token);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}