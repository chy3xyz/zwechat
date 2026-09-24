// SPDX-License-Identifier: Apache-2.0
//! officialaccount/user — 用户管理 / 标签 / 黑名单

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 单个用户基本信息。
pub const UserInfo = struct {
    subscribe: i64 = 0,
    openid: []const u8 = "",
    nickname: []const u8 = "",
    sex: i64 = 0,
    city: []const u8 = "",
    country: []const u8 = "",
    province: []const u8 = "",
    language: []const u8 = "",
    headimgurl: []const u8 = "",
    subscribe_time: i64 = 0,
    unionid: []const u8 = "",
    remark: []const u8 = "",
    groupid: i64 = 0,
    tagid_list: []const i64 = &.{},
    subscribe_scene: []const u8 = "",
    qr_scene: i64 = 0,
    qr_scene_str: []const u8 = "",
};

/// 用户列表。`data.openid` 为嵌套结构，与微信实际响应及 Go user.go 对齐。
pub const OpenidList = struct {
    total: i64 = 0,
    count: i64 = 0,
    next_openid: []const u8 = "",
    data: struct {
        openid: []const []const u8 = &.{},
    } = .{},
};

/// TagInfo — 标签信息（对应 Go `TagInfo`）。
pub const TagInfo = struct {
    id: i64 = 0,
    name: []const u8 = "",
    count: i64 = 0,
};

/// TagCreateResponse — createTag 响应（内嵌 errcode 供 SDK 检查失败响应）。
/// 新建标签在 `.value.tag`。
pub const TagCreateResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    tag: TagInfo = .{},
};

/// TagListResponse — getTag 响应（内嵌 errcode 供 SDK 检查失败响应）。
/// 标签列表在 `.value.tags`。
pub const TagListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    tags: []const TagInfo = &.{},
};

/// TagOpenIDList — 标签下粉丝列表（对应 Go `TagOpenIDList`）。
pub const TagOpenIDList = struct {
    count: i64 = 0,
    data: struct {
        openid: []const []const u8 = &.{},
    } = .{},
    next_openid: []const u8 = "",
};

/// BatchGetUserListItem — 批量获取用户基本信息的单条参数（对应 Go `BatchGetUserListItem`）。
pub const BatchGetUserListItem = struct {
    openid: []const u8,
    lang: []const u8 = "zh_CN",
};

/// InfoList — BatchGetUserInfo 响应（对应 Go `InfoList`，内嵌 errcode 供 SDK 检查失败响应）。
/// 用户列表在 `.value.user_info_list`。
pub const InfoList = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    user_info_list: []const UserInfo = &.{},
};

pub const User = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    fn get(self: *Self, uri: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.get(uri);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.get(uri);
    }

    fn post(self: *Self, uri: []const u8, body: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, body);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body);
    }

    /// 返回的 `std.json.Parsed(UserInfo)` 由调用方持有并负责 `deinit`。
    /// 响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn getUserInfo(self: *Self, open_id: []const u8) !std.json.Parsed(UserInfo) {
        const suffix = try std.fmt.allocPrint(self.allocator, "&openid={s}&lang=zh_CN", .{open_id});
        defer self.allocator.free(suffix);

        const body = try util_retry.callApi(self.ctx, self.allocator, "GetUserInfo", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/user/info",
            .query_suffix = suffix,
        });
        defer self.allocator.free(body);

        // 失败响应形如 {"errcode":40013,"errmsg":"invalid openid"}，UserInfo 解析会
        // 静默吞成全默认值——errcode 检查已由 util_retry.callApi 完成（对齐 Go user.go 内嵌 CommonError）。

        var parsed = std.json.parseFromSlice(UserInfo, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        return parsed;
    }

    /// 返回的 `std.json.Parsed(OpenidList)` 由调用方持有并负责 `deinit`。
    /// 响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn getOpenidList(self: *Self, next_openid: []const u8) !std.json.Parsed(OpenidList) {
        const suffix = try std.fmt.allocPrint(self.allocator, "&next_openid={s}", .{next_openid});
        defer self.allocator.free(suffix);

        const body = try util_retry.callApi(self.ctx, self.allocator, "GetOpenidList", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/user/get",
            .query_suffix = suffix,
        });
        defer self.allocator.free(body);

        // 失败响应会被 OpenidList 静默吞成全默认值，errcode 检查已由 util_retry.callApi 完成。

        var parsed = std.json.parseFromSlice(OpenidList, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        return parsed;
    }

    pub fn updateRemark(self: *Self, open_id: []const u8, remark: []const u8) !void {
        const payload = try serializeRemarkBody(self.allocator, open_id, remark);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "UpdateRemark", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/user/info/updateremark",
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 创建标签（对应 Go `CreateTag`）。
    /// 返回的 `std.json.Parsed(TagCreateResponse)` 由调用方持有并负责 `deinit`，
    /// 新建标签在 `.value.tag`。响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn createTag(self: *Self, tag_name: []const u8) !std.json.Parsed(TagCreateResponse) {
        const payload = try serializeTagBody(self.allocator, null, tag_name);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "CreateTag", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/tags/create",
            .payload = payload,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(TagCreateResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return parsed;
    }

    /// 编辑标签（对应 Go `UpdateTag`）。
    pub fn updateTag(self: *Self, tag_id: i64, tag_name: []const u8) !void {
        const payload = try serializeTagBody(self.allocator, tag_id, tag_name);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "UpdateTag", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/tags/update",
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 删除标签（对应 Go `DeleteTag`）。
    pub fn deleteTag(self: *Self, tag_id: i64) !void {
        const payload = try serializeTagBody(self.allocator, tag_id, null);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "DeleteTag", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/tags/delete",
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 获取公众号已创建的标签（对应 Go `GetTag`）。
    /// 返回的 `std.json.Parsed(TagListResponse)` 由调用方持有并负责 `deinit`，
    /// 标签列表在 `.value.tags`。响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn getTag(self: *Self) !std.json.Parsed(TagListResponse) {
        const body = try util_retry.callApi(self.ctx, self.allocator, "GetTag", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/tags/get",
        });
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(TagListResponse, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return parsed;
    }

    /// 获取标签下粉丝列表（对应 Go `OpenIDListByTag`）。
    /// `next_openid` 传空串表示从头拉取。
    /// 返回的 `std.json.Parsed(TagOpenIDList)` 由调用方持有并负责 `deinit`。
    pub fn openIDListByTag(self: *Self, tag_id: i64, next_openid: []const u8) !std.json.Parsed(TagOpenIDList) {
        const payload = try serializeOpenIDListByTag(self.allocator, tag_id, next_openid);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "OpenIDListByTag", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/user/tag/get",
            .payload = payload,
        });
        defer self.allocator.free(resp);

        // 失败响应会被 TagOpenIDList 静默吞成全默认值，errcode 检查已由 util_retry.callApi 完成。

        var parsed = std.json.parseFromSlice(TagOpenIDList, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        return parsed;
    }

    /// 批量为用户打标签（对应 Go `BatchTag`）。
    pub fn batchTag(self: *Self, open_id_list: []const []const u8, tag_id: i64) !void {
        if (open_id_list.len == 0) return util_error.WechatError.InvalidArgument;
        const payload = try serializeOpenIDListWithTag(self.allocator, open_id_list, tag_id);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "BatchTag", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/tags/members/batchtagging",
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 批量为用户取消标签（对应 Go `BatchUntag`）。
    pub fn batchUntag(self: *Self, open_id_list: []const []const u8, tag_id: i64) !void {
        if (open_id_list.len == 0) return util_error.WechatError.InvalidArgument;
        const payload = try serializeOpenIDListWithTag(self.allocator, open_id_list, tag_id);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "BatchUntag", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/tags/members/batchuntagging",
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 获取用户身上的标签列表（对应 Go `UserTidList`）。
    /// 返回的切片由调用方持有并负责 `allocator.free`。
    pub fn userTidList(self: *Self, open_id: []const u8) ![]i64 {
        const payload = try serializeUserTidList(self.allocator, open_id);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "UserTidList", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/tags/getidlist",
            .payload = payload,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            tagid_list: []const i64 = &.{},
        }, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();
        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return self.allocator.dupe(i64, parsed.value.tagid_list);
    }

    /// 获取公众号的黑名单列表（对应 Go `GetBlackList`）。
    /// `begin_openid` 传空串表示从开头拉取，每次最多 1000 个。
    /// 返回的 `std.json.Parsed(OpenidList)` 由调用方持有并负责 `deinit`。
    pub fn getBlackList(self: *Self, begin_openid: []const u8) !std.json.Parsed(OpenidList) {
        const payload = try serializeBeginOpenID(self.allocator, begin_openid);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "GetBlackList", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/tags/members/getblacklist",
            .payload = payload,
        });
        defer self.allocator.free(resp);

        // 失败响应会被 OpenidList 静默吞成全默认值，errcode 检查已由 util_retry.callApi 完成。

        var parsed = std.json.parseFromSlice(OpenidList, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        return parsed;
    }

    /// 获取公众号全部用户 OpenID（对照 Go `ListAllUserOpenIDs`）。
    ///
    /// 内部循环 `getOpenidList`，以每页返回的 `next_openid` 作为下一页起点，
    /// 直到 `next_openid` 为空（或服务器重复返回同一游标，防死循环兜底）。
    ///
    /// 返回的 `[]const []const u8` 由调用方持有并负责释放：外层切片与每个
    /// openid 均为独立堆分配（每轮响应的借用切片已逐一 `dupe`）。
    pub fn listAllUserOpenIDs(self: *Self) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |id| self.allocator.free(id);
            list.deinit(self.allocator);
        }

        var next_openid: []u8 = try self.allocator.dupe(u8, "");
        defer self.allocator.free(next_openid);

        while (true) {
            var parsed = try self.getOpenidList(next_openid);
            defer parsed.deinit();

            for (parsed.value.data.openid) |id| {
                // parsed 的借用切片在 deinit 后失效，必须深拷贝。
                try list.append(self.allocator, try self.allocator.dupe(u8, id));
            }

            const nxt = parsed.value.next_openid;
            if (nxt.len == 0) break;
            // 服务器若重复返回同一游标会死循环，进度未推进时直接终止。
            if (std.mem.eql(u8, nxt, next_openid)) break;
            const dup = try self.allocator.dupe(u8, nxt);
            self.allocator.free(next_openid);
            next_openid = dup;
        }

        return list.toOwnedSlice(self.allocator);
    }

    /// 获取公众号完整黑名单（对照黑名单分页接口的全量封装）。
    ///
    /// 内部循环 `getBlackList`，以每页返回的 `next_openid` 作为下一页起点，
    /// 直到 `next_openid` 为空；结果按 openid 去重。
    ///
    /// 返回的 `[]const []const u8` 由调用方持有并负责释放：外层切片与每个
    /// openid 均为独立堆分配（每轮响应的借用切片已逐一 `dupe`）。
    pub fn getAllBlackList(self: *Self) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |id| self.allocator.free(id);
            list.deinit(self.allocator);
        }
        // 去重集合：键直接借用 list 持有的 dup 切片，随 list 一起释放。
        var seen: std.StringHashMap(void) = .init(self.allocator);
        defer seen.deinit();

        var next_openid: []u8 = try self.allocator.dupe(u8, "");
        defer self.allocator.free(next_openid);

        while (true) {
            var parsed = try self.getBlackList(next_openid);
            defer parsed.deinit();

            for (parsed.value.data.openid) |id| {
                if (seen.contains(id)) continue;
                const dup = try self.allocator.dupe(u8, id);
                errdefer self.allocator.free(dup);
                try seen.put(dup, {});
                try list.append(self.allocator, dup);
            }

            const nxt = parsed.value.next_openid;
            if (nxt.len == 0) break;
            if (std.mem.eql(u8, nxt, next_openid)) break;
            const dup = try self.allocator.dupe(u8, nxt);
            self.allocator.free(next_openid);
            next_openid = dup;
        }

        return list.toOwnedSlice(self.allocator);
    }

    /// 拉黑用户（对应 Go `BatchBlackList`）。
    /// `open_id_list` 每次最多 20 个，超出返回 `WechatError.InvalidArgument`。
    pub fn batchBlackList(self: *Self, open_id_list: []const []const u8) !void {
        return self.batchBlacklist("https://api.weixin.qq.com/cgi-bin/tags/members/batchblacklist", "BatchBlackList", open_id_list);
    }

    /// 取消拉黑用户（对应 Go `BatchUnBlackList`）。
    /// `open_id_list` 每次最多 20 个，超出返回 `WechatError.InvalidArgument`。
    pub fn batchUnBlackList(self: *Self, open_id_list: []const []const u8) !void {
        return self.batchBlacklist("https://api.weixin.qq.com/cgi-bin/tags/members/batchunblacklist", "BatchUnBlackList", open_id_list);
    }

    /// batch 公共方法（对应 Go `batch`）。
    fn batchBlacklist(self: *Self, url_base: []const u8, api_name: []const u8, open_id_list: []const []const u8) !void {
        if (open_id_list.len == 0 or open_id_list.len > 20) return util_error.WechatError.InvalidArgument;
        const payload = try serializeOpenIDList(self.allocator, open_id_list);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, api_name, TokenReq{
            .user = self,
            .url = url_base,
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 批量获取用户基本信息（对应 Go `BatchGetUserInfo`）。
    /// `items` 每次最多 100 条，超出返回 `WechatError.InvalidArgument`。
    /// 返回的 `std.json.Parsed(InfoList)` 由调用方持有并负责 `deinit`，
    /// 用户列表在 `.value.user_info_list`。
    pub fn batchGetUserInfo(self: *Self, items: []const BatchGetUserListItem) !std.json.Parsed(InfoList) {
        if (items.len == 0 or items.len > 100) return util_error.WechatError.InvalidArgument;
        const payload = try serializeBatchGetUserInfo(self.allocator, items);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "BatchGetUserInfo", TokenReq{
            .user = self,
            .url = "https://api.weixin.qq.com/cgi-bin/user/info/batchget",
            .payload = payload,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(InfoList, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return parsed;
    }
};

/// 单次带 token 调用的请求构造器：交给 `util/retry.callApi` 复用模块自己的
/// transport 注入逻辑（`payload` 为 null 时走 GET）。`url` 为不含 access_token 的
/// 接口地址，`query_suffix` 用于把固定参数拼在 access_token 之后（保持原有参数顺序）。
/// `send` 必须 `pub`（跨文件调用）。
const TokenReq = struct {
    user: *User,
    url: []const u8,
    payload: ?[]const u8 = null,
    query_suffix: []const u8 = "",

    pub fn send(self: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const uri = try std.fmt.allocPrint(allocator, "{s}?access_token={s}{s}", .{ self.url, token, self.query_suffix });
        defer allocator.free(uri);
        if (self.payload) |p| return self.user.post(uri, p);
        return self.user.get(uri);
    }
};

/// `{"tag":{"id":?,"name":?}}` — create/update/delete 标签共用（非空字段才输出）。
fn serializeTagBody(allocator: std.mem.Allocator, tag_id: ?i64, tag_name: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("tag");
    try s.beginObject();
    if (tag_id) |id| {
        try s.objectField("id");
        try s.write(id);
    }
    if (tag_name) |name| {
        try s.objectField("name");
        try s.write(name);
    }
    try s.endObject();
    try s.endObject();

    return out.toOwnedSlice();
}

/// `{"openid":"...","remark":"..."}` — updateRemark 请求体。
///
/// 字段名与顺序与改造前的手写插值版本逐字一致（`zig fmt` 之外的空白零差异），
/// 但值经 `std.json.Stringify` 转义：`open_id` / `remark` 含 `"` 或 `\` 时
/// 手写 `allocPrint` 会产出非法 JSON（微信侧直接返回解析错误）。
fn serializeRemarkBody(allocator: std.mem.Allocator, open_id: []const u8, remark: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("openid");
    try s.write(open_id);
    try s.objectField("remark");
    try s.write(remark);
    try s.endObject();

    return out.toOwnedSlice();
}

/// `{"tagid":N,"next_openid":"..."}`。
fn serializeOpenIDListByTag(allocator: std.mem.Allocator, tag_id: i64, next_openid: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("tagid");
    try s.write(tag_id);
    try s.objectField("next_openid");
    try s.write(next_openid);
    try s.endObject();

    return out.toOwnedSlice();
}

/// `{"openid_list":[...],"tagid":N}`。
fn serializeOpenIDListWithTag(allocator: std.mem.Allocator, open_id_list: []const []const u8, tag_id: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("openid_list");
    try s.write(open_id_list);
    try s.objectField("tagid");
    try s.write(tag_id);
    try s.endObject();

    return out.toOwnedSlice();
}

/// `{"openid_list":[...]}`。
fn serializeOpenIDList(allocator: std.mem.Allocator, open_id_list: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("openid_list");
    try s.write(open_id_list);
    try s.endObject();

    return out.toOwnedSlice();
}

/// `{"openid":"...","tagid":0}` — 对齐 Go UserTidList 的请求结构（tagid 恒为 0）。
fn serializeUserTidList(allocator: std.mem.Allocator, open_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("openid");
    try s.write(open_id);
    try s.objectField("tagid");
    try s.write(0);
    try s.endObject();

    return out.toOwnedSlice();
}

/// `{"begin_openid":"..."}`。
fn serializeBeginOpenID(allocator: std.mem.Allocator, begin_openid: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("begin_openid");
    try s.write(begin_openid);
    try s.endObject();

    return out.toOwnedSlice();
}

/// `{"user_list":[...]}`。
fn serializeBatchGetUserInfo(allocator: std.mem.Allocator, items: []const BatchGetUserListItem) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("user_list");
    try s.write(items);
    try s.endObject();

    return out.toOwnedSlice();
}

test "UserInfo 默认值" {
    const u = UserInfo{};
    try std.testing.expectEqualStrings("", u.openid);
    try std.testing.expectEqual(@as(i64, 0), u.subscribe);
}

test "OpenidList 默认值" {
    const l = OpenidList{};
    try std.testing.expectEqual(@as(i64, 0), l.total);
    try std.testing.expectEqualStrings("", l.next_openid);
    try std.testing.expectEqual(@as(usize, 0), l.data.openid.len);
}

// —— mock 测试 ——

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 返回预设响应的 transport。
const StaticResp = struct {
    response: []const u8,

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = payload;
        _ = content_type;
        const self: *StaticResp = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, self.response);
    }
};

test "getUserInfo errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = StaticResp{ .response = "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}" };

    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = User.init(&ctx, allocator);
    u.setTransport(StaticResp.dispatch, &stub);

    const result = u.getUserInfo("bad-openid");
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "getUserInfo 正常响应解析成功" {
    const allocator = std.testing.allocator;
    var stub = StaticResp{
        .response =
        \\{"subscribe":1,"openid":"oABC","nickname":"测试","sex":1,"city":"深圳","tagid_list":[1,2]}
        ,
    };

    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = User.init(&ctx, allocator);
    u.setTransport(StaticResp.dispatch, &stub);

    const parsed = try u.getUserInfo("oABC");
    defer parsed.deinit();
    // 整体比较：一次覆盖 UserInfo 全部字段（响应里未下发的字段须保持默认值）。
    try std.testing.expectEqualDeep(UserInfo{
        .subscribe = 1,
        .openid = "oABC",
        .nickname = "测试",
        .sex = 1,
        .city = "深圳",
        .tagid_list = &.{ 1, 2 },
    }, parsed.value);
}

test "getOpenidList errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = StaticResp{ .response = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}" };

    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = User.init(&ctx, allocator);
    u.setTransport(StaticResp.dispatch, &stub);

    const result = u.getOpenidList("");
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "getOpenidList 正常响应解析成功" {
    const allocator = std.testing.allocator;
    var stub = StaticResp{
        .response =
        \\{"total":2,"count":2,"next_openid":"oB","data":{"openid":["oA","oB"]}}
        ,
    };

    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = User.init(&ctx, allocator);
    u.setTransport(StaticResp.dispatch, &stub);

    const parsed = try u.getOpenidList("");
    defer parsed.deinit();
    // 整体比较：一次覆盖 OpenidList 全部字段（含 data.openid 的全部元素）。
    try std.testing.expectEqualDeep(OpenidList{
        .total = 2,
        .count = 2,
        .next_openid = "oB",
        .data = .{ .openid = &.{ "oA", "oB" } },
    }, parsed.value);
}

// —— 标签 / 黑名单 / 批量查询 mock 测试 ——

/// 捕获最后一次请求的 transport：记录 uri/method/payload 并返回预设响应。
const CaptureResp = struct {
    response: []const u8,
    last_uri: [512]u8 = undefined,
    last_uri_len: usize = 0,
    last_payload: [2048]u8 = undefined,
    last_payload_len: usize = 0,
    last_method: std.http.Method = .GET,

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = content_type;
        const self: *CaptureResp = @ptrCast(@alignCast(ctx));
        const ulen = @min(uri.len, self.last_uri.len);
        @memcpy(self.last_uri[0..ulen], uri[0..ulen]);
        self.last_uri_len = ulen;
        const plen = @min(payload.len, self.last_payload.len);
        @memcpy(self.last_payload[0..plen], payload[0..plen]);
        self.last_payload_len = plen;
        self.last_method = method;
        return allocator.dupe(u8, self.response);
    }

    fn lastUri(self: *const CaptureResp) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }

    fn lastPayload(self: *const CaptureResp) []const u8 {
        return self.last_payload[0..self.last_payload_len];
    }
};

fn newCaptureUser(ctx: *Context, alloc: std.mem.Allocator, stub: *CaptureResp) User {
    var u = User.init(ctx, alloc);
    u.setTransport(CaptureResp.dispatch, stub);
    return u;
}

test "createTag 请求与响应解析" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"tag\":{\"id\":100,\"name\":\"测试标签\",\"count\":0}}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const parsed = try u.createTag("测试标签");
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, stub.last_method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/create?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"tag\":{\"name\":\"测试标签\"}}", stub.lastPayload());
    try std.testing.expectEqual(@as(i64, 100), parsed.value.tag.id);
    try std.testing.expectEqualStrings("测试标签", parsed.value.tag.name);
}

test "createTag errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":45057,\"errmsg\":\"tag name already exist\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const result = u.createTag("重复");
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "updateTag 请求体含 id 与 name" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    try u.updateTag(100, "新名字\"x");

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/update?access_token=token-abc", stub.lastUri());
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"id\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "新名字\\\"x") != null);
}

test "deleteTag 请求体仅含 id" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    try u.deleteTag(100);

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/delete?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"tag\":{\"id\":100}}", stub.lastPayload());
}

test "getTag 解析 tags 列表" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"tags\":[{\"id\":1,\"name\":\"a\",\"count\":10},{\"id\":2,\"name\":\"b\",\"count\":0}]}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const parsed = try u.getTag();
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/get?access_token=token-abc", stub.lastUri());

    // 期望值的 tags 是可变切片（`[]TagInfo`），用局部 var 数组承载。
    var tags = [_]TagInfo{
        .{ .id = 1, .name = "a", .count = 10 },
        .{ .id = 2, .name = "b" },
    };
    // 整体比较：一次覆盖 TagListResponse 与两个标签的全部字段。
    try std.testing.expectEqualDeep(TagListResponse{
        .tags = &tags,
    }, parsed.value);
}

test "getTag errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const result = u.getTag();
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "openIDListByTag 请求体与粉丝列表解析" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"count\":2,\"data\":{\"openid\":[\"oA\",\"oB\"]},\"next_openid\":\"oB\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const parsed = try u.openIDListByTag(1, "oA");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/user/tag/get?access_token=token-abc", stub.lastUri());
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"tagid\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"next_openid\":\"oA\"") != null);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.count);
    try std.testing.expectEqualStrings("oB", parsed.value.next_openid);
    try std.testing.expectEqualStrings("oA", parsed.value.data.openid[0]);
}

test "openIDListByTag errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const result = u.openIDListByTag(1, "");
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "batchTag 请求体含 openid_list 与 tagid" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const list = [_][]const u8{ "oA", "oB" };
    try u.batchTag(&list, 1);

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/members/batchtagging?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"openid_list\":[\"oA\",\"oB\"],\"tagid\":1}", stub.lastPayload());
}

test "batchUntag 请求 batchuntagging 端点" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const list = [_][]const u8{"oA"};
    try u.batchUntag(&list, 1);

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/members/batchuntagging?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"openid_list\":[\"oA\"],\"tagid\":1}", stub.lastPayload());
}

test "batchTag 空列表返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const result = u.batchTag(&.{}, 1);
    try std.testing.expectError(util_error.WechatError.InvalidArgument, result);
}

test "userTidList 返回标签 id 切片" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"tagid_list\":[1,2,100]}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const tids = try u.userTidList("oA");
    defer allocator.free(tids);

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/getidlist?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"openid\":\"oA\",\"tagid\":0}", stub.lastPayload());
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 100 }, tids);
}

test "userTidList errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const result = u.userTidList("bad");
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "getBlackList 请求体与黑名单解析" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"total\":2,\"count\":2,\"next_openid\":\"oB\",\"data\":{\"openid\":[\"oA\",\"oB\"]}}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const parsed = try u.getBlackList("oA");
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, stub.last_method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/members/getblacklist?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"begin_openid\":\"oA\"}", stub.lastPayload());
    try std.testing.expectEqual(@as(i64, 2), parsed.value.total);
    try std.testing.expectEqualStrings("oB", parsed.value.data.openid[1]);
}

test "getBlackList errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const result = u.getBlackList("");
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "batchBlackList 请求端点与 openid_list" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const list = [_][]const u8{ "oA", "oB" };
    try u.batchBlackList(&list);

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/members/batchblacklist?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"openid_list\":[\"oA\",\"oB\"]}", stub.lastPayload());
}

test "batchUnBlackList 请求 batchunblacklist 端点" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const list = [_][]const u8{"oA"};
    try u.batchUnBlackList(&list);

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/tags/members/batchunblacklist?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"openid_list\":[\"oA\"]}", stub.lastPayload());
}

test "batchBlackList 参数个数 1-20 校验" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const result0 = u.batchBlackList(&.{});
    try std.testing.expectError(util_error.WechatError.InvalidArgument, result0);

    var too_many: [21][]const u8 = undefined;
    for (&too_many) |*item| item.* = "oX";
    const result21 = u.batchBlackList(&too_many);
    try std.testing.expectError(util_error.WechatError.InvalidArgument, result21);

    const one = [_][]const u8{"oA"};
    try u.batchBlackList(&one);
}

test "batchGetUserInfo 请求体与解析" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"user_info_list\":[{\"openid\":\"oA\",\"nickname\":\"小明\",\"subscribe\":1},{\"openid\":\"oB\",\"nickname\":\"小红\",\"subscribe\":0}]}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const items = [_]BatchGetUserListItem{
        .{ .openid = "oA" },
        .{ .openid = "oB", .lang = "en" },
    };
    const parsed = try u.batchGetUserInfo(&items);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/user/info/batchget?access_token=token-abc", stub.lastUri());
    try std.testing.expectEqualStrings("{\"user_list\":[{\"openid\":\"oA\",\"lang\":\"zh_CN\"},{\"openid\":\"oB\",\"lang\":\"en\"}]}", stub.lastPayload());
    // 整体比较：一次覆盖 InfoList 与两个 UserInfo 的全部字段。
    try std.testing.expectEqualDeep(InfoList{
        .user_info_list = &.{
            .{ .subscribe = 1, .openid = "oA", .nickname = "小明" },
            .{ .openid = "oB", .nickname = "小红" },
        },
    }, parsed.value);
}

test "batchGetUserInfo 参数个数校验" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newCaptureUser(&ctx, allocator, &stub);

    const result0 = u.batchGetUserInfo(&.{});
    try std.testing.expectError(util_error.WechatError.InvalidArgument, result0);

    var too_many: [101]BatchGetUserListItem = undefined;
    for (&too_many) |*item| item.* = .{ .openid = "oX" };
    const result101 = u.batchGetUserInfo(&too_many);
    try std.testing.expectError(util_error.WechatError.InvalidArgument, result101);
}

// —— 全量分页封装 mock 测试 ——

/// 按调用次序返回多页响应的 transport，并记录每次请求的 uri。
const PageStub = struct {
    responses: []const []const u8,
    calls: usize = 0,
    uris: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, responses: []const []const u8) PageStub {
        return .{ .responses = responses, .allocator = allocator };
    }

    fn deinit(self: *PageStub) void {
        for (self.uris.items) |u| self.allocator.free(u);
        self.uris.deinit(self.allocator);
    }

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = method;
        _ = payload;
        _ = content_type;
        const self: *PageStub = @ptrCast(@alignCast(ctx));
        if (self.calls >= self.responses.len) return error.MockNoRoute;
        defer self.calls += 1;
        try self.uris.append(self.allocator, try allocator.dupe(u8, uri));
        return allocator.dupe(u8, self.responses[self.calls]);
    }
};

fn newPagingUser(ctx: *Context, alloc: std.mem.Allocator, stub: *PageStub) User {
    var u = User.init(ctx, alloc);
    u.setTransport(PageStub.dispatch, stub);
    return u;
}

test "listAllUserOpenIDs 多页聚合并携带 next_openid 终止" {
    const allocator = std.testing.allocator;
    const pages = [_][]const u8{
        "{\"total\":3,\"count\":2,\"next_openid\":\"oB\",\"data\":{\"openid\":[\"oA\",\"oB\"]}}",
        "{\"total\":3,\"count\":1,\"next_openid\":\"\",\"data\":{\"openid\":[\"oC\"]}}",
    };
    var stub = PageStub.init(allocator, &pages);
    defer stub.deinit();
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newPagingUser(&ctx, allocator, &stub);

    const all = try u.listAllUserOpenIDs();
    defer {
        for (all) |id| allocator.free(id);
        allocator.free(all);
    }

    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("oA", all[0]);
    try std.testing.expectEqualStrings("oB", all[1]);
    try std.testing.expectEqualStrings("oC", all[2]);
    // 第二轮请求必须携带第一页返回的 next_openid 作为游标。
    try std.testing.expect(std.mem.indexOf(u8, stub.uris.items[1], "next_openid=oB") != null);
}

test "listAllUserOpenIDs 单页 next_openid 为空只调一次" {
    const allocator = std.testing.allocator;
    const pages = [_][]const u8{
        "{\"total\":2,\"count\":2,\"next_openid\":\"\",\"data\":{\"openid\":[\"oA\",\"oB\"]}}",
    };
    var stub = PageStub.init(allocator, &pages);
    defer stub.deinit();
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newPagingUser(&ctx, allocator, &stub);

    const all = try u.listAllUserOpenIDs();
    defer {
        for (all) |id| allocator.free(id);
        allocator.free(all);
    }

    try std.testing.expectEqual(@as(usize, 1), stub.calls);
    try std.testing.expectEqual(@as(usize, 2), all.len);
}

test "getAllBlackList 多页聚合去重并终止" {
    const allocator = std.testing.allocator;
    const pages = [_][]const u8{
        "{\"total\":3,\"count\":2,\"next_openid\":\"oB\",\"data\":{\"openid\":[\"oA\",\"oB\"]}}",
        // 第二页重复返回 oB（翻页重叠），应被去重。
        "{\"total\":3,\"count\":2,\"next_openid\":\"\",\"data\":{\"openid\":[\"oB\",\"oC\"]}}",
    };
    var stub = PageStub.init(allocator, &pages);
    defer stub.deinit();
    var ctx: Context = .{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var u = newPagingUser(&ctx, allocator, &stub);

    const all = try u.getAllBlackList();
    defer {
        for (all) |id| allocator.free(id);
        allocator.free(all);
    }

    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("oA", all[0]);
    try std.testing.expectEqualStrings("oB", all[1]);
    try std.testing.expectEqualStrings("oC", all[2]);
    try std.testing.expect(std.mem.indexOf(u8, stub.uris.items[1], "access_token=token-abc") != null);
}

// —— token 失效自愈 / 非 token 错误不重试 ——

/// 可作废的假凭据：作废前发 `token-abc`，作废后发 `token-new`（模拟微信换发新 token）。
const HealToken = struct {
    cached: []const u8 = "token-abc",
    invalidates: usize = 0,

    fn getToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.cached);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        self.invalidates += 1;
        self.cached = "token-new";
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

/// 按调用次序返回响应、并记录每次请求 URI 的 transport。
const SeqResp = struct {
    responses: []const []const u8,
    calls: usize = 0,
    uris: [4][200]u8 = @splat(@splat(0)),
    uri_lens: [4]usize = @splat(0),
    /// 每次请求体的副本（超出容量的请求体不记录，只影响事后断言）。
    payloads: [4][200]u8 = @splat(@splat(0)),
    payload_lens: [4]usize = @splat(0),

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = method;
        _ = content_type;
        const self: *SeqResp = @ptrCast(@alignCast(ctx));
        if (self.calls < self.uris.len and uri.len <= self.uris[0].len) {
            @memcpy(self.uris[self.calls][0..uri.len], uri);
            self.uri_lens[self.calls] = uri.len;
        }
        if (self.calls < self.payloads.len and payload.len <= self.payloads[0].len) {
            @memcpy(self.payloads[self.calls][0..payload.len], payload);
            self.payload_lens[self.calls] = payload.len;
        }
        const idx = @min(self.calls, self.responses.len - 1);
        self.calls += 1;
        return allocator.dupe(u8, self.responses[idx]);
    }

    fn uriAt(self: *const SeqResp, idx: usize) []const u8 {
        return self.uris[idx][0..self.uri_lens[idx]];
    }

    fn payloadAt(self: *const SeqResp, idx: usize) []const u8 {
        return self.payloads[idx][0..self.payload_lens[idx]];
    }
};

fn newHealUser(ctx: *Context, alloc: std.mem.Allocator, stub: *SeqResp) User {
    var u = User.init(ctx, alloc);
    u.setTransport(SeqResp.dispatch, stub);
    return u;
}

test "getUserInfo 40001 自愈：作废缓存 → 换新 token 重试一次并成功" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"subscribe\":1,\"openid\":\"oABC\",\"nickname\":\"测试\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var u = newHealUser(&ctx, allocator, &stub);

    const parsed = try u.getUserInfo("oABC");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings("测试", parsed.value.nickname);
    // 参数顺序与改造前一致：access_token 在最前，其余参数跟随其后。
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/user/info?access_token=token-abc&openid=oABC&lang=zh_CN",
        stub.uriAt(0),
    );
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/user/info?access_token=token-new&openid=oABC&lang=zh_CN",
        stub.uriAt(1),
    );
}

test "getOpenidList 40001 自愈：重试后成功且第二次请求带新 token" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"total\":1,\"count\":1,\"next_openid\":\"\",\"data\":{\"openid\":[\"oA\"]}}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var u = newHealUser(&ctx, allocator, &stub);

    const parsed = try u.getOpenidList("oA");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings("oA", parsed.value.data.openid[0]);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/user/get?access_token=token-new&next_openid=oA",
        stub.uriAt(1),
    );
}

test "createTag 40001 自愈：重试后解析出新标签" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"tag\":{\"id\":100,\"name\":\"测试标签\",\"count\":0}}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var u = newHealUser(&ctx, allocator, &stub);

    const parsed = try u.createTag("测试标签");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqual(@as(i64, 100), parsed.value.tag.id);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/tags/create?access_token=token-new",
        stub.uriAt(1),
    );
}

test "updateRemark 40001 自愈：重试后成功（且走注入的 transport）" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"errcode\":0,\"errmsg\":\"ok\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var u = newHealUser(&ctx, allocator, &stub);

    try u.updateRemark("oA", "备注");

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/user/info/updateremark?access_token=token-new",
        stub.uriAt(1),
    );
}

test "updateRemark 请求体经 JSON 转义：含引号与反斜杠仍合法且字节与手写版一致" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{"{\"errcode\":0,\"errmsg\":\"ok\"}"} };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var u = newHealUser(&ctx, allocator, &stub);

    // 常规输入：字节必须与改造前的手写 allocPrint 完全一致
    //（字段名 / 顺序 / 无多余空格 / UTF-8 原样输出）。
    try u.updateRemark("oA", "备注");
    try std.testing.expectEqualStrings(
        "{\"openid\":\"oA\",\"remark\":\"备注\"}",
        stub.payloadAt(0),
    );

    // 含 `"` 与 `\` 的输入：手写插值会产出 `"openid":"o"A"` 这类非法 JSON。
    const weird_open_id = "o\"A";
    const weird_remark = "a\"b\\c";
    try u.updateRemark(weird_open_id, weird_remark);
    const payload = stub.payloadAt(1);
    try std.testing.expectEqualStrings(
        "{\"openid\":\"o\\\"A\",\"remark\":\"a\\\"b\\\\c\"}",
        payload,
    );

    // 合法 JSON 的最终证据：能被解析回原值。
    const ParsedRemark = struct {
        openid: []const u8 = "",
        remark: []const u8 = "",
    };
    const parsed = try std.json.parseFromSlice(ParsedRemark, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(weird_open_id, parsed.value.openid);
    try std.testing.expectEqualStrings(weird_remark, parsed.value.remark);
}

test "getBlackList 40001 自愈：重试后解析出黑名单" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}",
        "{\"total\":1,\"count\":1,\"next_openid\":\"\",\"data\":{\"openid\":[\"oA\"]}}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var u = newHealUser(&ctx, allocator, &stub);

    const parsed = try u.getBlackList("");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings("oA", parsed.value.data.openid[0]);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/tags/members/getblacklist?access_token=token-new",
        stub.uriAt(1),
    );
}

test "batchBlackList 40001 自愈：重试后成功且第二次请求带新 token" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40014,\"errmsg\":\"invalid access_token\"}",
        "{\"errcode\":0,\"errmsg\":\"ok\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var u = newHealUser(&ctx, allocator, &stub);

    const list = [_][]const u8{"oA"};
    try u.batchBlackList(&list);

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/tags/members/batchblacklist?access_token=token-new",
        stub.uriAt(1),
    );
}

test "getUserInfo 非 token 错误（45009）不重试也不作废" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-user" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var u = newHealUser(&ctx, allocator, &stub);

    try std.testing.expectError(util_error.WechatError.ApiError, u.getUserInfo("oA"));

    try std.testing.expectEqual(@as(usize, 0), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
}
