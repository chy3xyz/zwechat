//! openplatform/context/access_token — component_access_token 获取与缓存
//!
//! 对应 `_ref/wechat/openplatform/context/accessToken.go`：
//! 用 `component_verify_ticket` 换取 `component_access_token`，并在 cache 中缓存。

const std = @import("std");
const Context = @import("mod.zig").Context;
const cache_mod = @import("../../cache/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Error = error{
    VerifyTicketRequired,
    CacheUnavailable,
} || util_error.WechatError || cache_mod.CacheError || std.mem.Allocator.Error;

const TokenResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    component_access_token: []const u8 = "",
    expires_in: i64 = 0,
};

/// 获取 component_access_token。
///
/// 1. 以 `openplatform_component_access_token_{app_id}` 为 key 查缓存。
/// 2. 未命中时调用 `https://api.weixin.qq.com/cgi-bin/component/api_component_token`。
/// 3. 写入缓存 TTL 7000 秒（微信默认 7200 秒，预留 200 秒缓冲）。
///
/// 返回的 token 由调用方负责 `allocator.free`。
pub fn getComponentAccessToken(
    ctx: *Context,
    allocator: std.mem.Allocator,
    verify_ticket: []const u8,
) Error![]u8 {
    if (verify_ticket.len == 0) return error.VerifyTicketRequired;
    const cache_inst = ctx.config.cache orelse return error.CacheUnavailable;

    const cache_key = try std.fmt.allocPrint(
        allocator,
        "openplatform_component_access_token_{s}",
        .{ctx.config.app_id},
    );
    defer allocator.free(cache_key);

    if (try cache_inst.get(cache_key)) |cached| {
        return allocator.dupe(u8, cached);
    }

    const body_json = try std.fmt.allocPrint(
        allocator,
        "{{\"component_appid\":\"{s}\",\"component_appsecret\":\"{s}\",\"component_verify_ticket\":\"{s}\"}}",
        .{ ctx.config.app_id, ctx.config.app_secret, verify_ticket },
    );
    defer allocator.free(body_json);

    const client = util_http.getDefaultClient(allocator);
    const resp = client.postJSON(
        "https://api.weixin.qq.com/cgi-bin/component/api_component_token",
        body_json,
    ) catch return util_error.WechatError.NetworkError;
    defer allocator.free(resp);

    var parsed = std.json.parseFromSlice(TokenResponse, allocator, resp, .{}) catch {
        return util_error.WechatError.DecodeError;
    };
    defer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    if (parsed.value.component_access_token.len == 0) return util_error.WechatError.ApiError;

    const token = try allocator.dupe(u8, parsed.value.component_access_token);
    errdefer allocator.free(token);
    try cache_inst.set(cache_key, token, 7000);
    return token;
}

test "component token helper 需要 verify_ticket" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    const result = getComponentAccessToken(&ctx, std.testing.allocator, "");
    try std.testing.expectError(error.VerifyTicketRequired, result);
}
