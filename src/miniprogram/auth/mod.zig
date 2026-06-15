//! miniprogram/auth — 小程序登录 / 用户信息
//!
//! 对应 `_ref/wechat/miniprogram/auth/auth.go`：jscode2session / getPhoneNumber / checkSession 等。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// `jscode2session` 返回。
pub const ResCode2Session = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    openid: []const u8 = "",
    session_key: []const u8 = "",
    unionid: []const u8 = "",
};

/// 加密数据校验返回。
pub const RspCheckEncryptedData = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    valid: bool = false,
    create_time: i64 = 0,
};

/// 手机号信息。
pub const PhoneInfo = struct {
    phone_number: []const u8 = "",
    pure_phone_number: []const u8 = "",
    country_code: []const u8 = "",
};

/// `getuserphonenumber` 返回。
pub const GetPhoneNumberResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    phone_info: PhoneInfo = .{},
};

pub const Auth = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// `jscode2session` — 小程序登录凭证校验。
    pub fn code2Session(self: *Self, js_code: []const u8) !ResCode2Session {
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/sns/jscode2session?appid={s}&secret={s}&js_code={s}&grant_type=authorization_code",
            .{ self.ctx.config.app_id, self.ctx.config.app_secret, js_code },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResCode2Session, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// `getuserphonenumber` — 通过 code 获取用户手机号。
    pub fn getPhoneNumber(self: *Self, code: []const u8) !GetPhoneNumberResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"code\":\"{s}\"}}", .{code});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetPhoneNumberResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// `checkencryptedmsg` — 检查加密信息是否由微信生成。
    pub fn checkEncryptedData(self: *Self, encrypted_msg_hash: []const u8) !RspCheckEncryptedData {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/business/checkencryptedmsg?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "encrypted_msg_hash={s}",
            .{encrypted_msg_hash},
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.post(uri, body, null);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(RspCheckEncryptedData, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// `checksession` — 检验登录态。
    pub fn checkSession(self: *Self, signature: []const u8, open_id: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/checksession?access_token={s}&signature={s}&openid={s}&sig_method=hmac_sha256",
            .{ access_token, signature, open_id },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.get(uri);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "CheckSession")) |_| {
            return util_error.WechatError.ApiError;
        }
    }
};

test "Auth.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-mp", .app_secret = "sec" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const a = Auth.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-mp", a.ctx.config.app_id);
}

test "ResCode2Session 默认值" {
    const r = ResCode2Session{};
    try std.testing.expectEqualStrings("", r.openid);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}

test "PhoneInfo 默认值" {
    const p = PhoneInfo{};
    try std.testing.expectEqualStrings("", p.phone_number);
}