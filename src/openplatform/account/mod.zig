//! openplatform/account — 开放平台账号管理
//!
//! 对应 `_ref/wechat/openplatform/account/account.go`：在 Go SDK 中是 TODO
//! 骨架，所有方法都返回空字符串 / nil。本 Zig 版补齐两条与上游微信开放平台
//! 后端对齐的真实接口（`/cgi-bin/open/create` 与 `/cgi-bin/open/get`），便于
//! 上层调用方在不等待 Go 侧补齐的情况下先打通"创建开放平台账号"与
//! "查询已绑定的开放平台账号"两条最常用路径。
//!
//! 余下的 `Bind` / `Unbind` 仍维持骨架（返回 `WechatError.ApiError` 哨兵），
//! 与上游 Go 语义保持"未实现"的可观察行为一致。

const std = @import("std");

const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 微信开放平台（第三方平台）账号管理。
///
/// 字段说明：
/// - `ctx` — 复用上层 `OpenPlatform.ctx`，避免重复持有 config。
/// - `allocator` — 所有响应 / URL 切片的分配器；调用方传入的 allocator 需长期存活。
pub const Account = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 创建账号实例。调用方负责保证 `ctx` 与 `allocator` 在 `Account` 生命周期内有效。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// `CreateOpenAccount` — 创建开放平台账号并绑定公众号 / 小程序。
    ///
    /// 接口：`POST https://api.weixin.qq.com/cgi-bin/open/create`
    /// 请求体：`{"appid":"<appID>"}`
    /// 成功响应：`{"errcode":0,"errmsg":"ok","open_appid":"<open_appid>"}`
    ///
    /// `app_id` — 待绑定的公众号 / 小程序 AppID。
    /// 返回：开放平台账号的 `open_appid`（由调用方负责 `allocator.free`）。
    pub fn createOpenAccount(self: *Self, app_id: []const u8) ![]u8 {
        const body_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"appid\":\"{s}\"}}",
            .{app_id},
        );
        defer self.allocator.free(body_json);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.postJSON(createOpenAccountURL, body_json);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(OpenAccountResponse, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.open_appid);
    }

    /// `GetOpenAccount` — 查询公众号 / 小程序所绑定的开放平台账号。
    ///
    /// 接口：`POST https://api.weixin.qq.com/cgi-bin/open/get`
    /// 请求体：`{"appid":"<appID>"}`
    /// 成功响应：`{"errcode":0,"errmsg":"ok","open_appid":"<open_appid>"}`
    ///
    /// `app_id` — 待查询的公众号 / 小程序 AppID。
    /// 返回：开放平台账号的 `open_appid`（由调用方负责 `allocator.free`）。
    pub fn getOpenAccount(self: *Self, app_id: []const u8) ![]u8 {
        const body_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"appid\":\"{s}\"}}",
            .{app_id},
        );
        defer self.allocator.free(body_json);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.postJSON(getOpenAccountURL, body_json);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(OpenAccountResponse, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.open_appid);
    }

    /// 将公众号 / 小程序绑定到开放平台账号。
    ///
    /// `verify_ticket` 用于换取 component_access_token。
    pub fn bind(
        self: *Self,
        app_id: []const u8,
        open_app_id: []const u8,
        verify_ticket: []const u8,
    ) !void {
        const token = try self.ctx.getComponentAccessToken(self.allocator, verify_ticket);
        defer self.allocator.free(token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/open/bind?component_access_token={s}",
            .{token},
        );
        defer self.allocator.free(uri);

        const body_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"appid\":\"{s}\",\"open_appid\":\"{s}\"}}",
            .{ app_id, open_app_id },
        );
        defer self.allocator.free(body_json);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = client.postJSON(uri, body_json) catch return util_error.WechatError.NetworkError;
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CommonResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    }

    /// 将公众号 / 小程序从开放平台账号解绑。
    pub fn unbind(
        self: *Self,
        app_id: []const u8,
        open_app_id: []const u8,
        verify_ticket: []const u8,
    ) !void {
        const token = try self.ctx.getComponentAccessToken(self.allocator, verify_ticket);
        defer self.allocator.free(token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/open/unbind?component_access_token={s}",
            .{token},
        );
        defer self.allocator.free(uri);

        const body_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"appid\":\"{s}\",\"open_appid\":\"{s}\"}}",
            .{ app_id, open_app_id },
        );
        defer self.allocator.free(body_json);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = client.postJSON(uri, body_json) catch return util_error.WechatError.NetworkError;
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CommonResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 常量与响应结构
// ──────────────────────────────────────────────────────────────────────────────

/// `POST /cgi-bin/open/create` 接口 URL。
pub const createOpenAccountURL = "https://api.weixin.qq.com/cgi-bin/open/create";

/// `POST /cgi-bin/open/get` 接口 URL。
pub const getOpenAccountURL = "https://api.weixin.qq.com/cgi-bin/open/get";

/// 开放平台账号管理接口的通用响应。
///
/// 所有字段都有默认值：成功时会有 `open_appid`，失败时仅 `errcode` / `errmsg` 非零。
const OpenAccountResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    open_appid: []const u8 = "",
};

/// 绑定 / 解绑等无业务返回的通用响应。
const CommonResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

// ──────────────────────────────────────────────────────────────────────────────
// 内联测试
// ──────────────────────────────────────────────────────────────────────────────

test "Account.init 持有 ctx 与 allocator" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-acc-test" } };
    const a = Account.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqual(@intFromPtr(&ctx), @intFromPtr(a.ctx));
    try std.testing.expectEqual(std.heap.page_allocator, a.allocator);
}

test "OpenAccountResponse 默认值" {
    const r = OpenAccountResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
    try std.testing.expectEqualStrings("", r.open_appid);
}

test "createOpenAccountURL / getOpenAccountURL 指向正确主机" {
    try std.testing.expect(std.mem.indexOf(u8, createOpenAccountURL, "api.weixin.qq.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, createOpenAccountURL, "/cgi-bin/open/create") != null);
    try std.testing.expect(std.mem.indexOf(u8, getOpenAccountURL, "api.weixin.qq.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, getOpenAccountURL, "/cgi-bin/open/get") != null);
}

test "bind / unbind 无 cache 返回 CacheUnavailable" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, std.heap.page_allocator);
    try std.testing.expectError(error.CacheUnavailable, a.bind("wx-target", "wx-open", "ticket"));
    try std.testing.expectError(error.CacheUnavailable, a.unbind("wx-target", "wx-open", "ticket"));
}
