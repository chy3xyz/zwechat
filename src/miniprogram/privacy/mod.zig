// SPDX-License-Identifier: Apache-2.0
//! miniprogram/privacy — 小程序授权隐私设置
//!
//! 对应 `_ref/wechat/miniprogram/privacy/privacy.go`：
//! `component/setprivacysetting` / `getprivacysetting` / `uploadprivacyextfile`。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 隐私版本。
pub const PrivacyV1: i64 = 1;
pub const PrivacyV2: i64 = 2;

/// 收集方（开发者）信息配置。
pub const OwnerSetting = struct {
    contact_email: []const u8 = "",
    contact_phone: []const u8 = "",
    contact_qq: []const u8 = "",
    contact_weixin: []const u8 = "",
    ext_file_media_id: []const u8 = "",
    notice_method: []const u8 = "",
    store_expire_timestamp: []const u8 = "",
};

/// 收集权限的配置。
pub const SettingItem = struct {
    privacy_key: []const u8,
    privacy_text: []const u8,
};

/// 设置权限请求参数。
pub const SetPrivacySettingRequest = struct {
    privacy_ver: i64,
    owner_setting: OwnerSetting = .{},
    setting_list: []const SettingItem = &.{},
};

/// 获取权限配置响应。
pub const GetPrivacySettingResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    code_exist: i64 = 0,
    privacy_list: []const []const u8 = &.{},
    setting_list: []SettingResponseItem = &.{},
    update_time: i64 = 0,
    owner_setting: OwnerSetting = .{},
    privacy_desc: DescList = .{},
};

pub const SettingResponseItem = struct {
    privacy_key: []const u8 = "",
    privacy_text: []const u8 = "",
    privacy_label: []const u8 = "",
};

pub const DescList = struct {
    privacy_desc_list: []Desc = &.{},
};

pub const Desc = struct {
    privacy_desc: []const u8 = "",
    privacy_key: []const u8 = "",
};

/// 上传权限定义模板响应。
pub const UploadPrivacyExtFileResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    ext_file_media_id: []const u8 = "",
};

/// 小程序隐私设置模块。
pub const Privacy = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 获取小程序权限配置（返回 `std.json.Parsed(GetPrivacySettingResponse)`）。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次。
    pub fn getPrivacySetting(self: *Self, privacy_ver: i64) !std.json.Parsed(GetPrivacySettingResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"privacy_ver\":{d}}}", .{privacy_ver});
        defer self.allocator.free(body);

        const Sender = struct {
            privacy: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/cgi-bin/component/getprivacysetting?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.privacy.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "GetPrivacySetting", Sender{
            .privacy = self,
            .body = body,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetPrivacySettingResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 更新小程序权限配置。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次。
    pub fn setPrivacySetting(self: *Self, req: SetPrivacySettingRequest) !void {
        if (req.privacy_ver == PrivacyV1 and req.setting_list.len > 0) {
            return error.InvalidArgument;
        }

        const body = try jsonStringifySetPrivacy(self.allocator, req);
        defer self.allocator.free(body);

        const Sender = struct {
            privacy: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/cgi-bin/component/setprivacysetting?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.privacy.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "setprivacysetting", Sender{
            .privacy = self,
            .body = body,
        });
        self.allocator.free(resp);
    }

    /// 上传权限定义模板（`file_data` 为文件字节；返回 `Parsed(UploadPrivacyExtFileResponse)`）。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次。
    pub fn uploadPrivacyExtFile(self: *Self, file_data: []const u8) !std.json.Parsed(UploadPrivacyExtFileResponse) {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("file");
        try s.write(file_data);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const Sender = struct {
            privacy: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/cgi-bin/component/uploadprivacyextfile?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.privacy.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "UploadPrivacyExtFile", Sender{
            .privacy = self,
            .body = body,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(UploadPrivacyExtFileResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

fn jsonStringifySetPrivacy(allocator: std.mem.Allocator, req: SetPrivacySettingRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("privacy_ver");
    try s.write(req.privacy_ver);
    try s.objectField("owner_setting");
    try s.beginObject();
    try s.objectField("contact_email");
    try s.write(req.owner_setting.contact_email);
    try s.objectField("contact_phone");
    try s.write(req.owner_setting.contact_phone);
    try s.objectField("contact_qq");
    try s.write(req.owner_setting.contact_qq);
    try s.objectField("contact_weixin");
    try s.write(req.owner_setting.contact_weixin);
    try s.objectField("ext_file_media_id");
    try s.write(req.owner_setting.ext_file_media_id);
    try s.objectField("notice_method");
    try s.write(req.owner_setting.notice_method);
    try s.objectField("store_expire_timestamp");
    try s.write(req.owner_setting.store_expire_timestamp);
    try s.endObject();
    try s.objectField("setting_list");
    try s.beginArray();
    for (req.setting_list) |item| {
        try s.beginObject();
        try s.objectField("privacy_key");
        try s.write(item.privacy_key);
        try s.objectField("privacy_text");
        try s.write(item.privacy_text);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

test "Privacy.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-pv" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const p = Privacy.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-pv", p.ctx.config.app_id);
}

test "SetPrivacySetting V1 带 setting_list 返回 InvalidArgument" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-pv2" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var p = Privacy.init(&ctx, std.heap.page_allocator);
    const result = p.setPrivacySetting(.{
        .privacy_ver = PrivacyV1,
        .setting_list = &[_]SettingItem{.{ .privacy_key = "k", .privacy_text = "t" }},
    });
    try std.testing.expectError(error.InvalidArgument, result);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "getPrivacySetting token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/cgi-bin/component/getprivacysetting?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"code_exist\":1,\"privacy_list\":[\"UserInfo\"]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-pv" },
        .access_token_handle = stub.asHandle(),
    };
    var p = Privacy.init(&ctx, allocator);

    var parsed = try p.getPrivacySetting(PrivacyV2);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.code_exist);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
