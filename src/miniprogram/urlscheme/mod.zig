//! miniprogram/urlscheme — 小程序 URL Scheme
//!
//! 对应 `_ref/wechat/miniprogram/urlscheme/urlscheme.go`：
//! `wxa/generatescheme` 生成 URL Scheme。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// `wxa/generatescheme` 响应。
pub const GenerateResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    openlink: []const u8 = "",
};

/// URL Scheme 模块。
pub const URLScheme = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 生成 URL Scheme。
    ///
    /// `jump_wxa_json` 为 `jump_wxa` 对象的 JSON 字符串，例如：
    /// `{"path":"pages/index","query":"a=1"}`。
    pub fn generate(self: *Self, jump_wxa_json: []const u8) !GenerateResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/generatescheme?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jump_wxa\":{s}}}",
            .{jump_wxa_json},
        );
        defer self.allocator.free(body_json);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body_json);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GenerateResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

test "URLScheme.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-link" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const u = URLScheme.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-link", u.ctx.config.app_id);
}
