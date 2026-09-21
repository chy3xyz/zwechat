// SPDX-License-Identifier: Apache-2.0
//! officialaccount/freepublish — 发布能力（发布 / 撤回 / 状态轮询 / 获取列表）
//!
//! 对应 `_ref/wechat/officialaccount/freepublish/freepublish.go`。接口清单：
//! `freepublish/submit`（发布）、`freepublish/get`（发布状态轮询）、
//! `freepublish/delete`（撤回）、`freepublish/getarticle`（单篇已发布文章）、
//! `freepublish/batchget`（成功发布列表）。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// 发布状态（与 Go 参考 `PublishStatus` 常量一一对应）。
pub const PublishStatus = enum(i32) {
    /// 0: 成功
    success = 0,
    /// 1: 发布中
    publishing = 1,
    /// 2: 原创失败
    original_failed = 2,
    /// 3: 常规失败
    failed = 3,
    /// 4: 平台审核不通过
    audit_refused = 4,
    /// 5: 成功后用户删除所有文章
    user_deleted = 5,
    /// 6: 成功后系统封禁所有文章
    system_banned = 6,
};

/// 发布任务成功的单篇文章详情。
pub const PublishArticleItem = struct {
    idx: i64 = 0,
    article_url: []const u8 = "",
};

/// 发布任务文章成功状态详情。
pub const PublishArticleDetail = struct {
    count: i64 = 0,
    item: []const PublishArticleItem = &.{},
};

/// 发布任务状态（`freepublish/get` 响应）。
pub const PublishStatusList = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    publish_id: i64 = 0,
    publish_status: i32 = 0,
    article_id: []const u8 = "",
    article_detail: PublishArticleDetail = .{},
    fail_idx: []const i64 = &.{},
};

pub const FreePublish = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 发布草稿。
    ///
    /// 返回微信原始响应字节（含 `publish_id`），由本结构体的 allocator 分配，
    /// **调用方负责 `free`**。
    pub fn publish(self: *Self, media_id: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/freepublish/submit?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"media_id\":\"{s}\"}}", .{media_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "FreePublishSubmit")) |ce| {
            defer ce.deinit();
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    /// 撤回发布。
    pub fn delete(self: *Self, article_id: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/freepublish/delete?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"article_id\":\"{s}\"}}", .{article_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "FreePublishDelete")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 发布状态轮询（`freepublish/get`）。
    ///
    /// 返回的 `std.json.Parsed(PublishStatusList)` 由调用方持有并负责 `deinit`。
    pub fn selectStatus(self: *Self, publish_id: i64) !std.json.Parsed(PublishStatusList) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/freepublish/get?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"publish_id\":{d}}}", .{publish_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(PublishStatusList, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 获取成功发布列表。
    ///
    /// `count_n` 为返回数量，`no_content` 为 true 时不返回正文内容
    /// （微信侧为布尔字段，与 Go 参考一致）。
    ///
    /// 返回微信原始响应字节，由本结构体的 allocator 分配，**调用方负责 `free`**。
    pub fn list(self: *Self, offset: i64, count_n: i64, no_content: bool) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/freepublish/batchget?access_token={s}",
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

        if (try util_error.decodeWithCommonError(self.allocator, resp, "FreePublishBatchGet")) |ce| {
            defer ce.deinit();
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：与 draft/mod.zig 同款的假 AccessTokenHandle + capture transport。
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

fn setupTestClient(alloc: std.mem.Allocator, cap: *TestCapture) void {
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(TestCapture.dispatch, @ptrCast(cap));
}

fn releaseTestClient() void {
    const client = util_http.getDefaultClient(std.heap.page_allocator);
    client.setTransport(null, null);
    util_http.deinitDefaultClient();
}

test "FreePublish.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-fp" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const fp = FreePublish.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-fp", fp.ctx.config.app_id);
}

test "PublishStatus 枚举值与 Go 参考一致" {
    try std.testing.expectEqual(@as(i32, 0), @backingInt(PublishStatus.success));
    try std.testing.expectEqual(@as(i32, 1), @backingInt(PublishStatus.publishing));
    try std.testing.expectEqual(@as(i32, 2), @backingInt(PublishStatus.original_failed));
    try std.testing.expectEqual(@as(i32, 3), @backingInt(PublishStatus.failed));
    try std.testing.expectEqual(@as(i32, 4), @backingInt(PublishStatus.audit_refused));
    try std.testing.expectEqual(@as(i32, 5), @backingInt(PublishStatus.user_deleted));
    try std.testing.expectEqual(@as(i32, 6), @backingInt(PublishStatus.system_banned));
}

test "FreePublish.list 走 batchget 端点且 no_content 序列化为布尔" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"total_count\":1,\"item_count\":1,\"item\":[]}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var fp = FreePublish.init(&ctx, alloc);

    const resp = try fp.list(0, 10, true);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/freepublish/batchget?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"offset\":0,\"count\":10,\"no_content\":true}", cap.payload);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"total_count\":1") != null);
}

test "FreePublish.selectStatus 解析发布状态" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"publish_id\":123,\"publish_status\":0,\"article_id\":\"AID\",\"article_detail\":{\"count\":1,\"item\":[{\"idx\":1,\"article_url\":\"https://mp.weixin.qq.com/s/x\"}]},\"fail_idx\":[]}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var fp = FreePublish.init(&ctx, alloc);

    var parsed = try fp.selectStatus(123);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 123), parsed.value.publish_id);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.publish_status);
    try std.testing.expectEqualStrings("AID", parsed.value.article_id);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.article_detail.count);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.article_detail.item[0].idx);
    try std.testing.expectEqualStrings("https://mp.weixin.qq.com/s/x", parsed.value.article_detail.item[0].article_url);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/freepublish/get?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"publish_id\":123}", cap.payload);
}

test "FreePublish.delete errcode 非 0 返回 ApiError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var fp = FreePublish.init(&ctx, alloc);

    try std.testing.expectError(util_error.WechatError.ApiError, fp.delete("AID"));
}
