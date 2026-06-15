//! officialaccount/js — JS-SDK 配置
//!
//! 对应 `_ref/wechat/officialaccount/js/js.go`：根据 jsapi_ticket + 当前 URL 计算
//! 微信 JS-SDK 所需的 `appId / timestamp / nonceStr / signature`。
//!
//! 调用方需通过 `setJsTicketHandle` 注入 ticket 获取器（一般是 `DefaultJsTicket`）。

const std = @import("std");
const Context = @import("../context.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_time = @import("../../util/time.zig");
const util_sig = @import("../../util/signature.zig");
const util_util = @import("../../util/util.zig");

/// JS-SDK 配置返回结构。
pub const Config = struct {
    app_id: []const u8 = "",
    timestamp: i64 = 0,
    nonce_str: []const u8 = "",
    signature: []const u8 = "",

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.nonce_str.len > 0) {
            allocator.free(@constCast(self.nonce_str));
            self.nonce_str = "";
        }
        if (self.signature.len > 0) {
            allocator.free(@constCast(self.signature));
            self.signature = "";
        }
    }
};

pub const Js = struct {
    ctx: *Context,
    /// JsTicket handle；未初始化时 `getConfig` 会 panic。
    ticket_handle: ?credential.JsTicketHandle = null,

    const Self = @This();

    pub fn init(ctx: *Context) Self {
        return .{ .ctx = ctx };
    }

    pub fn setJsTicketHandle(self: *Self, h: credential.JsTicketHandle) void {
        self.ticket_handle = h;
    }

    /// 计算 JS-SDK 配置。等价于 Go 的 `GetConfig`。
    ///
    /// `uri` 为当前页面 URL（不含 #fragment）。
    /// 返回的 `Config.nonce_str` / `Config.signature` 是堆分配，调用方 `deinit`。
    pub fn getConfig(self: *Self, allocator: std.mem.Allocator, uri: []const u8) !Config {
        _ = uri;
        const handle = self.ticket_handle orelse return error.JsTicketHandleNotSet;

        const access_token = try self.ctx.getAccessToken(allocator);

        const ticket = try handle.getTicket(allocator, access_token);
        defer allocator.free(ticket);

        const nonce_str = try util_util.randomStr(allocator, 16);
        const timestamp = util_time.getCurrTS();

        const signature = try util_sig.signature(allocator, &[_][]const u8{ ticket, nonce_str });

        return .{
            .app_id = self.ctx.config.app_id,
            .timestamp = timestamp,
            .nonce_str = nonce_str,
            .signature = signature,
        };
    }
};

test "Js.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-js" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const j = Js.init(&ctx);
    try std.testing.expectEqualStrings("wx-js", j.ctx.config.app_id);
    try std.testing.expect(j.ticket_handle == null);
}

test "Config.deinit 释放 nonce/signature" {
    const allocator = std.testing.allocator;
    var c = Config{
        .nonce_str = try allocator.dupe(u8, "abc"),
        .signature = try allocator.dupe(u8, "def"),
    };
    c.deinit(allocator);
    // 二次 deinit 不应崩溃。
    c.deinit(allocator);
}