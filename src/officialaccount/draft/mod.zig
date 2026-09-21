// SPDX-License-Identifier: Apache-2.0
//! officialaccount/draft — 草稿箱（新增 / 删除 / 修改 / 获取 / 获取列表 / 总数）
//!
//! 对应 `_ref/wechat/officialaccount/draft/draft.go`。接口清单：
//! `draft/add`（新增）、`draft/get`（获取）、`draft/delete`（删除）、
//! `draft/update`（修改）、`draft/count`（总数）、`draft/batchget`（列表）。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Draft = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 新增草稿。
    ///
    /// `articles_json` 为完整请求体 JSON（形如 `{"articles":[...]}`），仅借用不接管。
    /// 返回微信原始响应字节，由本结构体的 allocator 分配，**调用方负责 `free`**。
    pub fn add(self: *Self, articles_json: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/add?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, articles_json);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DraftAdd")) |ce| {
            defer ce.deinit();
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    /// 获取草稿（单篇图文的完整内容）。
    ///
    /// 返回微信原始响应字节（含 `news_item` 数组），由本结构体的 allocator 分配，
    /// **调用方负责 `free`**。
    pub fn get(self: *Self, media_id: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/get?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"media_id\":\"{s}\"}}", .{media_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DraftGet")) |ce| {
            defer ce.deinit();
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    /// 删除草稿。
    pub fn delete(self: *Self, media_id: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/delete?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"media_id\":\"{s}\"}}", .{media_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DraftDelete")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 修改草稿。
    ///
    /// `index` 为要更新的文章在图文消息中的位置（多图文时才有意义），第一篇为 0。
    /// `article_json` 为单篇文章对象的 JSON 字符串，仅借用不接管。
    pub fn update(self: *Self, media_id: []const u8, index: i64, article_json: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/update?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"media_id\":\"{s}\",\"index\":{d},\"articles\":{s}}}",
            .{ media_id, index, article_json },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DraftUpdate")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取草稿总数。
    pub fn count(self: *Self) !i64 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/count?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.get(uri);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            total_count: i64 = 0,
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value.total_count;
    }

    /// 获取草稿列表。
    ///
    /// `count_n` 为返回数量，`no_content` 为 true 时不返回图文消息正文内容。
    /// 微信侧字段为布尔值，这里直接透传为 JSON 布尔（与 Go 参考 `no_content` 一致）。
    ///
    /// 返回微信原始响应字节，由本结构体的 allocator 分配，**调用方负责 `free`**。
    pub fn list(self: *Self, offset: i64, count_n: i64, no_content: bool) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/draft/batchget?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"offset\":{d},\"count\":{d},\"no_content\":{}}}",
            .{ offset, count_n, no_content },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DraftBatchGet")) |ce| {
            defer ce.deinit();
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：假 AccessTokenHandle（dupe 出 token，允许调用方 free）+
// 可捕获 URI / payload 的 transport。
// ─────────────────────────────────────────────────────────────────────────────

const credential = @import("../../credential/mod.zig");

const TestTokenState = struct {
    token: []const u8,
};

fn testGetAccessToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const state: *const TestTokenState = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, state.token);
}

const test_token_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = testGetAccessToken,
};

fn makeFakeTokenHandle(state: *TestTokenState) credential.AccessTokenHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &test_token_vtable,
    };
}

/// 捕获最近一次请求的 URI 与 payload，并返回预设响应。
const TestCapture = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    status: u16 = 200,
    uri: []u8 = &.{},
    payload: []u8 = &.{},

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = method;
        _ = content_type;
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }
};

/// 初始化默认 client + 注入 capture transport；返回后需在作用域末尾
/// `releaseTestClient()`。
fn setupTestClient(alloc: std.mem.Allocator, cap: *TestCapture) void {
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(TestCapture.dispatch, @ptrCast(cap));
}

fn releaseTestClient() void {
    const client = util_http.getDefaultClient(std.heap.page_allocator);
    client.setTransport(null, null);
    util_http.deinitDefaultClient();
}

test "Draft.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-draft" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const d = Draft.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-draft", d.ctx.config.app_id);
}

test "Draft.list 走 batchget 端点且 no_content 序列化为布尔" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"total_count\":1,\"item_count\":1,\"item\":[]}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, alloc);

    const resp = try d.list(0, 10, true);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/draft/batchget?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"offset\":0,\"count\":10,\"no_content\":true}", cap.payload);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"total_count\":1") != null);
}

test "Draft.list no_content=false 序列化为 false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"total_count\":0,\"item_count\":0,\"item\":[]}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, alloc);

    _ = try d.list(20, 5, false);
    try std.testing.expectEqualStrings("{\"offset\":20,\"count\":5,\"no_content\":false}", cap.payload);
}

test "Draft.count 解析 total_count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"total_count\":42}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, alloc);

    const total = try d.count();
    try std.testing.expectEqual(@as(i64, 42), total);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/draft/count?access_token=stub-ak",
        cap.uri,
    );
}

test "Draft.update 组装 media_id/index/articles 请求体" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, alloc);

    const article_json = "{\"title\":\"t\",\"thumb_media_id\":\"m\"}";
    try d.update("MEDIA123", 1, article_json);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/draft/update?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"media_id\":\"MEDIA123\",\"index\":1,\"articles\":{\"title\":\"t\",\"thumb_media_id\":\"m\"}}",
        cap.payload,
    );
}

test "Draft.delete errcode 非 0 返回 ApiError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":40007,\"errmsg\":\"invalid media_id\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, alloc);

    try std.testing.expectError(util_error.WechatError.ApiError, d.delete("BAD"));
}

test "Draft.get 走 draft/get 端点" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"news_item\":[{\"title\":\"t\"}]}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, alloc);

    const resp = try d.get("MEDIA9");
    defer alloc.free(resp);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/draft/get?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"media_id\":\"MEDIA9\"}", cap.payload);
}
