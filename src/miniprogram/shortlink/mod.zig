// SPDX-License-Identifier: Apache-2.0
//! miniprogram/shortlink — 小程序 Short Link 短链接
//!
//! 对应 `_ref/wechat/miniprogram/shortlink/shortlink.go`：
//! `wxa/genwxashortlink` 生成短期/永久 Short Link。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 小程序 Short Link 模块。
pub const ShortLink = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 生成永久 Short Link（返回的 link 由调用方负责 `allocator.free`）。
    pub fn generateShortLinkPermanent(self: *Self, page_url: []const u8, page_title: []const u8) ![]u8 {
        return self.generate(page_url, page_title, true);
    }

    /// 生成临时 Short Link（返回的 link 由调用方负责 `allocator.free`）。
    pub fn generateShortLinkTemp(self: *Self, page_url: []const u8, page_title: []const u8) ![]u8 {
        return self.generate(page_url, page_title, null);
    }

    fn generate(self: *Self, page_url: []const u8, page_title: []const u8, is_permanent: ?bool) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/genwxashortlink?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        // 用 std.json.Stringify 序列化请求体，正确处理 page_url/page_title 中的特殊字符；
        // `is_permanent` 为 null 时（临时链接）不序列化该字段。
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("page_url");
        try s.write(page_url);
        try s.objectField("page_title");
        try s.write(page_title);
        if (is_permanent) |p| {
            try s.objectField("is_permanent");
            try s.write(p);
        }
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            link: []const u8 = "",
        }, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.link);
    }
};

test "ShortLink.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-sl" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const sl = ShortLink.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-sl", sl.ctx.config.app_id);
}

test "shortlink 请求体省略 is_permanent（临时链接语义）" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("page_url");
    try s.write("pages/index?x=\"1\"");
    try s.objectField("page_title");
    try s.write("首页");
    try s.endObject();
    const body = try out.toOwnedSlice();
    defer allocator.free(body);
    // 临时链接不携带 is_permanent 字段，且特殊字符被正确转义。
    try std.testing.expect(std.mem.indexOf(u8, body, "is_permanent") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"1\\\"") != null);
}
