// SPDX-License-Identifier: Apache-2.0
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
    /// JsTicket handle；未初始化时 `getConfig` 返回 `error.JsTicketHandleNotSet`。
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
    /// `uri` 为当前页面 URL（不含 #fragment），**必须参与签名**，同一页面不同
    /// URL（含 query）签出的 signature 不同。
    /// 返回的 `Config.nonce_str` / `Config.signature` 是堆分配，调用方 `deinit`。
    pub fn getConfig(self: *Self, allocator: std.mem.Allocator, uri: []const u8) !Config {
        const handle = self.ticket_handle orelse return error.JsTicketHandleNotSet;

        const access_token = try self.ctx.getAccessToken(allocator);
        defer allocator.free(access_token);

        const ticket = try handle.getTicket(allocator, access_token);
        defer allocator.free(ticket);

        const nonce_str = try util_util.randomStr(allocator, 16);
        errdefer allocator.free(nonce_str);
        const timestamp = util_time.getCurrTS();

        // 与 Go 对齐：signature = SHA1("jsapi_ticket=..&noncestr=..&timestamp=..&url=..")
        // （Go 侧 util.Signature 以单个字符串入参，排序不影响结果，即对整个拼接串做 SHA1）。
        const sign_src = try std.fmt.allocPrint(
            allocator,
            "jsapi_ticket={s}&noncestr={s}&timestamp={d}&url={s}",
            .{ ticket, nonce_str, timestamp, uri },
        );
        defer allocator.free(sign_src);

        const signature = try sha1Hex(allocator, sign_src);

        return .{
            .app_id = self.ctx.config.app_id,
            .timestamp = timestamp,
            .nonce_str = nonce_str,
            .signature = signature,
        };
    }
};

/// 对整段字符串做 SHA1，输出小写 hex（对应 Go `util.Signature(str)` 单参形式）。
fn sha1Hex(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(s, &digest, .{});
    const hex = try allocator.alloc(u8, digest.len * 2);
    errdefer allocator.free(hex);
    const hex_lower = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_lower[b >> 4];
        hex[i * 2 + 1] = hex_lower[b & 0x0F];
    }
    return hex;
}

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

// —— getConfig 签名回归测试（ticket/access_token 均为桩实现，无真实 HTTP） ——

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

const StubTicket = struct {
    fn getTicket(_: *anyopaque, allocator: std.mem.Allocator, access_token: []const u8) anyerror![]u8 {
        _ = access_token;
        return allocator.dupe(u8, "ticket-fixed");
    }
};
const ticket_vtable = credential.JsTicketHandle.VTable{ .getTicket = StubTicket.getTicket };

fn makeCtx(app_id: []const u8) Context {
    return .{
        .config = .{ .app_id = app_id },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "getConfig 签名 = SHA1(jsapi_ticket=..&noncestr=..&timestamp=..&url=..)（回归：uri 曾被忽略）" {
    const allocator = std.testing.allocator;
    var ctx = makeCtx("wx-js-sig");
    var j = Js.init(&ctx);
    j.setJsTicketHandle(.{ .ptr = undefined, .vtable = &ticket_vtable });

    const uri = "https://example.com/page?a=1&b=2";
    var cfg = try j.getConfig(allocator, uri);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("wx-js-sig", cfg.app_id);
    try std.testing.expectEqual(@as(usize, 16), cfg.nonce_str.len);

    const expected = try std.fmt.allocPrint(
        allocator,
        "jsapi_ticket={s}&noncestr={s}&timestamp={d}&url={s}",
        .{ "ticket-fixed", cfg.nonce_str, cfg.timestamp, uri },
    );
    defer allocator.free(expected);
    const expected_sig = try sha1Hex(allocator, expected);
    defer allocator.free(expected_sig);
    try std.testing.expectEqualStrings(expected_sig, cfg.signature);
}

test "getConfig 不同 uri 签出不同 signature" {
    const allocator = std.testing.allocator;
    var ctx = makeCtx("wx-js-sig");
    var j = Js.init(&ctx);
    j.setJsTicketHandle(.{ .ptr = undefined, .vtable = &ticket_vtable });

    var cfg_a = try j.getConfig(allocator, "https://example.com/a");
    defer cfg_a.deinit(allocator);
    var cfg_b = try j.getConfig(allocator, "https://example.com/b");
    defer cfg_b.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, cfg_a.signature, cfg_b.signature));
}

test "getConfig 未注入 ticket handle 返回 JsTicketHandleNotSet" {
    const allocator = std.testing.allocator;
    var ctx = makeCtx("wx-js-sig");
    var j = Js.init(&ctx);
    try std.testing.expectError(error.JsTicketHandleNotSet, j.getConfig(allocator, "https://example.com/"));
}
