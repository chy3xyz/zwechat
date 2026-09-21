// SPDX-License-Identifier: Apache-2.0
//! miniprogram/privacy — 小程序授权隐私设置
//!
//! 对应 `_ref/wechat/miniprogram/privacy/privacy.go`：
//! `component/setprivacysetting` / `getprivacysetting` / `uploadprivacyextfile`。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

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
    pub fn getPrivacySetting(self: *Self, privacy_ver: i64) !std.json.Parsed(GetPrivacySettingResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/component/getprivacysetting?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"privacy_ver\":{d}}}", .{privacy_ver});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetPrivacySettingResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 更新小程序权限配置。
    pub fn setPrivacySetting(self: *Self, req: SetPrivacySettingRequest) !void {
        if (req.privacy_ver == PrivacyV1 and req.setting_list.len > 0) {
            return error.InvalidArgument;
        }

        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/component/setprivacysetting?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try jsonStringifySetPrivacy(self.allocator, req);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "setprivacysetting")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 上传权限定义模板（`file_data` 为文件字节；返回 `Parsed(UploadPrivacyExtFileResponse)`）。
    pub fn uploadPrivacyExtFile(self: *Self, file_data: []const u8) !std.json.Parsed(UploadPrivacyExtFileResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/component/uploadprivacyextfile?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("file");
        try s.write(file_data);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
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
