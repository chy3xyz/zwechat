// SPDX-License-Identifier: Apache-2.0
//! officialaccount/draft — 草稿箱（新增 / 删除 / 修改 / 获取 / 获取列表 / 总数）
//!
//! 对应 `_ref/wechat/officialaccount/draft/draft.go`。接口清单：
//! `draft/add`（新增）、`draft/get`（获取）、`draft/delete`（删除）、
//! `draft/update`（修改）、`draft/count`（总数）、`draft/batchget`（列表）。
//!
//! token 注入 / errcode 检查 / token 失效自愈（40001 等 → 作废缓存 → 只重试一次）
//! 交给 `util/retry.callApi` 统一处理。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_json = @import("../../util/json.zig");

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
        const Req = struct {
            articles_json: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/cgi-bin/draft/add?access_token={s}",
                    .{token},
                );
                defer a.free(uri);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, c.articles_json);
            }
        };

        return util_retry.callApi(self.ctx, self.allocator, "DraftAdd", Req{ .articles_json = articles_json });
    }

    /// 获取草稿（单篇图文的完整内容）。
    ///
    /// 返回微信原始响应字节（含 `news_item` 数组），由本结构体的 allocator 分配，
    /// **调用方负责 `free`**。
    pub fn get(self: *Self, media_id: []const u8) ![]u8 {
        const Req = struct {
            media_id: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/cgi-bin/draft/get?access_token={s}",
                    .{token},
                );
                defer a.free(uri);

                const body = try util_json.stringFieldObject(a, "media_id", c.media_id);
                defer a.free(body);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, body);
            }
        };

        return util_retry.callApi(self.ctx, self.allocator, "DraftGet", Req{ .media_id = media_id });
    }

    /// 删除草稿。
    pub fn delete(self: *Self, media_id: []const u8) !void {
        const Req = struct {
            media_id: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/cgi-bin/draft/delete?access_token={s}",
                    .{token},
                );
                defer a.free(uri);

                const body = try util_json.stringFieldObject(a, "media_id", c.media_id);
                defer a.free(body);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "DraftDelete", Req{ .media_id = media_id });
        self.allocator.free(resp);
    }

    /// 修改草稿。
    ///
    /// `index` 为要更新的文章在图文消息中的位置（多图文时才有意义），第一篇为 0。
    /// `article_json` 为单篇文章对象的 JSON 字符串，仅借用不接管。
    pub fn update(self: *Self, media_id: []const u8, index: i64, article_json: []const u8) !void {
        const Req = struct {
            media_id: []const u8,
            index: i64,
            article_json: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/cgi-bin/draft/update?access_token={s}",
                    .{token},
                );
                defer a.free(uri);

                const body = try buildUpdateBody(a, c.media_id, c.index, c.article_json);
                defer a.free(body);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "DraftUpdate", Req{
            .media_id = media_id,
            .index = index,
            .article_json = article_json,
        });
        self.allocator.free(resp);
    }

    /// 获取草稿总数。
    pub fn count(self: *Self) !i64 {
        const Req = struct {
            pub fn send(_: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/cgi-bin/draft/count?access_token={s}",
                    .{token},
                );
                defer a.free(uri);

                const client = util_http.getDefaultClient(a);
                return client.get(uri);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "DraftCount", Req{});
        defer self.allocator.free(resp);

        // errcode 已由 callApi 检查（非 0 直接 ApiError）。
        var parsed = std.json.parseFromSlice(struct {
            total_count: i64 = 0,
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        return parsed.value.total_count;
    }

    /// 获取草稿列表。
    ///
    /// `count_n` 为返回数量，`no_content` 为 true 时不返回图文消息正文内容。
    /// 微信侧字段为布尔值，这里直接透传为 JSON 布尔（与 Go 参考 `no_content` 一致）。
    ///
    /// 返回微信原始响应字节，由本结构体的 allocator 分配，**调用方负责 `free`**。
    pub fn list(self: *Self, offset: i64, count_n: i64, no_content: bool) ![]u8 {
        const Req = struct {
            offset: i64,
            count_n: i64,
            no_content: bool,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    a,
                    "https://api.weixin.qq.com/cgi-bin/draft/batchget?access_token={s}",
                    .{token},
                );
                defer a.free(uri);

                const body = try std.fmt.allocPrint(
                    a,
                    "{{\"offset\":{d},\"count\":{d},\"no_content\":{}}}",
                    .{ c.offset, c.count_n, c.no_content },
                );
                defer a.free(body);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, body);
            }
        };

        return util_retry.callApi(self.ctx, self.allocator, "DraftBatchGet", Req{
            .offset = offset,
            .count_n = count_n,
            .no_content = no_content,
        });
    }
};

/// 组装 `draft/update` 请求体：`{"media_id":"...","index":N,"articles":{...}}`。
/// 纯函数，便于单元测试。
///
/// `media_id` 来自调用方，按 JSON 字符串规则转义：此前手写 `allocPrint` 裸插值，
/// 含 `"` / `\` / 控制字符时会拼出非法 JSON。
///
/// `article_json` 是调用方预拼好的**单篇文章 JSON 对象**，这里**有意原样注入**
/// （对它转义会把它降级成字符串字面量，微信侧按对象解析会失败）。
fn buildUpdateBody(
    allocator: std.mem.Allocator,
    media_id: []const u8,
    index: i64,
    article_json: []const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"media_id\":\"");
    try util_json.appendEscapedString(allocator, &buf, media_id);
    try buf.appendSlice(allocator, "\",\"index\":");
    var num_buf: [24]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{index}) catch unreachable;
    try buf.appendSlice(allocator, num);
    try buf.appendSlice(allocator, ",\"articles\":");
    try buf.appendSlice(allocator, article_json);
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：假 AccessTokenHandle（dupe 出 token，允许调用方 free）+
// 可捕获 URI / payload 的 transport。
// ─────────────────────────────────────────────────────────────────────────────

const credential = @import("../../credential/mod.zig");

const TestTokenState = struct {
    /// 当前（缓存中的）token；`invalidate` 后换成 `refreshed`。
    token: []const u8,
    /// 作废后换发的新 token（模拟微信换发）；`null` 表示作废后仍返回同一 token。
    refreshed: ?[]const u8 = null,
    /// `invalidate` 被调用的次数。
    invalidates: usize = 0,

    fn getAccessToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const state: *const TestTokenState = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, state.token);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const state: *TestTokenState = @ptrCast(@alignCast(ptr));
        state.invalidates += 1;
        if (state.refreshed) |t| {
            state.token = t;
            state.refreshed = null;
        }
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getAccessToken,
        .invalidate = invalidate,
    };
};

fn makeFakeTokenHandle(state: *TestTokenState) credential.AccessTokenHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &TestTokenState.vtable,
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
    // 不依赖「用别的 allocator 再取一次指针」的宽容语义：直接销毁线程局部实例，
    // 注入的 transport 随实例一起消失（下次 getDefaultClient 会重新初始化）。
    util_http.deinitDefaultClient();
}

/// 用 `MockTransport` 路由表替代 capture（按 URI 命中不同响应，见失效重试测试）。
fn setupMockClient(alloc: std.mem.Allocator, mt: *util_http.MockTransport) void {
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(mt));
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

test "Draft.update media_id 含引号/反斜杠/控制字符时产出合法 JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, alloc);

    // 旧实现把 media_id 裸插进 JSON 字符串：这些字符会拼出非法 JSON。
    const media_id = "MED\"IA\\1\x01";
    const article_json = "{\"title\":\"t\"}";
    try d.update(media_id, 0, article_json);

    const body = try std.json.parseFromSlice(struct {
        media_id: []const u8,
        index: i64,
        articles: std.json.Value,
    }, alloc, cap.payload, .{});
    defer body.deinit();
    try std.testing.expectEqualStrings(media_id, body.value.media_id);
    try std.testing.expectEqual(@as(i64, 0), body.value.index);
    // articles 是有意 raw 注入：解析回来仍是对象（而不是被转义成字符串）。
    try std.testing.expectEqualStrings("t", body.value.articles.object.get("title").?.string);
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

test "Draft token 失效自愈：40001 → 作废缓存 → 新 token 重试成功" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/draft/batchget?access_token=old-ak", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential, access_token is invalid or not latest\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/draft/batchget?access_token=new-ak", .{
        .body = "{\"total_count\":1,\"item\":[]}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, allocator);

    const resp = try d.list(0, 10, true);
    defer allocator.free(resp);

    try std.testing.expectEqualStrings("{\"total_count\":1,\"item\":[]}", resp);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[0], "access_token=old-ak") != null);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-ak") != null);
}

test "Draft.count 走 token 失效自愈后仍解析 total_count" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/draft/count?access_token=old-ak", .{
        .body = "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/draft/count?access_token=new-ak", .{
        .body = "{\"total_count\":42}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, allocator);

    try std.testing.expectEqual(@as(i64, 42), try d.count());
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
}

test "Draft 非 token 类 errcode（45009）直接 ApiError：不作废、只请求一次" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/draft/batchget?access_token=old-ak", .{
        .body = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, allocator);

    try std.testing.expectError(util_error.WechatError.ApiError, d.list(0, 10, true));
    try std.testing.expectEqual(@as(usize, 0), state.invalidates);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}

test "Draft.add 走 draft/add 端点并透传 articles JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"media_id\":\"MEDIA_NEW\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var d = Draft.init(&ctx, alloc);

    const articles = "{\"articles\":[{\"title\":\"t\"}]}";
    const resp = try d.add(articles);
    defer alloc.free(resp);

    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/draft/add?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(articles, cap.payload);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"media_id\":\"MEDIA_NEW\"") != null);
}
