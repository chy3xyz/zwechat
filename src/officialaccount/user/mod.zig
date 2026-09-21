// SPDX-License-Identifier: Apache-2.0
//! officialaccount/user — 用户管理 / 标签 / 黑名单

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

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
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/user/info?access_token={s}&openid={s}&lang=zh_CN",
            .{ access_token, open_id },
        );
        defer self.allocator.free(uri);

        const body = try self.get(uri);
        defer self.allocator.free(body);

        // 失败响应形如 {"errcode":40013,"errmsg":"invalid openid"}，UserInfo 解析会
        // 静默吞成全默认值，必须先按 CommonError 检查 errcode（对齐 Go user.go 内嵌 CommonError）。
        if (try util_error.decodeWithCommonError(self.allocator, body, "GetUserInfo")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }

        var parsed = std.json.parseFromSlice(UserInfo, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        return parsed;
    }

    /// 返回的 `std.json.Parsed(OpenidList)` 由调用方持有并负责 `deinit`。
    /// 响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn getOpenidList(self: *Self, next_openid: []const u8) !std.json.Parsed(OpenidList) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/user/get?access_token={s}&next_openid={s}",
            .{ access_token, next_openid },
        );
        defer self.allocator.free(uri);

        const body = try self.get(uri);
        defer self.allocator.free(body);

        // 失败响应会被 OpenidList 静默吞成全默认值，SDK 先按 CommonError 检查 errcode。
        if (try util_error.decodeWithCommonError(self.allocator, body, "GetOpenidList")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }

        var parsed = std.json.parseFromSlice(OpenidList, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        return parsed;
    }

    pub fn updateRemark(self: *Self, open_id: []const u8, remark: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/user/info/updateremark?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"openid\":\"{s}\",\"remark\":\"{s}\"}}",
            .{ open_id, remark },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "UpdateRemark")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 创建标签（对应 Go `CreateTag`）。
    /// 返回的 `std.json.Parsed(TagCreateResponse)` 由调用方持有并负责 `deinit`，
    /// 新建标签在 `.value.tag`。响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn createTag(self: *Self, tag_name: []const u8) !std.json.Parsed(TagCreateResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/tags/create?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeTagBody(self.allocator, null, tag_name);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(TagCreateResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 编辑标签（对应 Go `UpdateTag`）。
    pub fn updateTag(self: *Self, tag_id: i64, tag_name: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/tags/update?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeTagBody(self.allocator, tag_id, tag_name);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "UpdateTag")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 删除标签（对应 Go `DeleteTag`）。
    pub fn deleteTag(self: *Self, tag_id: i64) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/tags/delete?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeTagBody(self.allocator, tag_id, null);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DeleteTag")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取公众号已创建的标签（对应 Go `GetTag`）。
    /// 返回的 `std.json.Parsed(TagListResponse)` 由调用方持有并负责 `deinit`，
    /// 标签列表在 `.value.tags`。响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn getTag(self: *Self) !std.json.Parsed(TagListResponse) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/tags/get?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try self.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(TagListResponse, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 获取标签下粉丝列表（对应 Go `OpenIDListByTag`）。
    /// `next_openid` 传空串表示从头拉取。
    /// 返回的 `std.json.Parsed(TagOpenIDList)` 由调用方持有并负责 `deinit`。
    pub fn openIDListByTag(self: *Self, tag_id: i64, next_openid: []const u8) !std.json.Parsed(TagOpenIDList) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/user/tag/get?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeOpenIDListByTag(self.allocator, tag_id, next_openid);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        // 失败响应会被 TagOpenIDList 静默吞成全默认值，先按 CommonError 检查 errcode。
        if (try util_error.decodeWithCommonError(self.allocator, resp, "OpenIDListByTag")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }

        var parsed = std.json.parseFromSlice(TagOpenIDList, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        return parsed;
    }

    /// 批量为用户打标签（对应 Go `BatchTag`）。
    pub fn batchTag(self: *Self, open_id_list: []const []const u8, tag_id: i64) !void {
        if (open_id_list.len == 0) return util_error.WechatError.InvalidArgument;
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/tags/members/batchtagging?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeOpenIDListWithTag(self.allocator, open_id_list, tag_id);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "BatchTag")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 批量为用户取消标签（对应 Go `BatchUntag`）。
    pub fn batchUntag(self: *Self, open_id_list: []const []const u8, tag_id: i64) !void {
        if (open_id_list.len == 0) return util_error.WechatError.InvalidArgument;
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/tags/members/batchuntagging?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeOpenIDListWithTag(self.allocator, open_id_list, tag_id);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "BatchUntag")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取用户身上的标签列表（对应 Go `UserTidList`）。
    /// 返回的切片由调用方持有并负责 `allocator.free`。
    pub fn userTidList(self: *Self, open_id: []const u8) ![]i64 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/tags/getidlist?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeUserTidList(self.allocator, open_id);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            tagid_list: []const i64 = &.{},
        }, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(i64, parsed.value.tagid_list);
    }

    /// 获取公众号的黑名单列表（对应 Go `GetBlackList`）。
    /// `begin_openid` 传空串表示从开头拉取，每次最多 1000 个。
    /// 返回的 `std.json.Parsed(OpenidList)` 由调用方持有并负责 `deinit`。
    pub fn getBlackList(self: *Self, begin_openid: []const u8) !std.json.Parsed(OpenidList) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/tags/members/getblacklist?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeBeginOpenID(self.allocator, begin_openid);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        // 失败响应会被 OpenidList 静默吞成全默认值，先按 CommonError 检查 errcode。
        if (try util_error.decodeWithCommonError(self.allocator, resp, "GetBlackList")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }

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
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ url_base, access_token });
        defer self.allocator.free(uri);

        const body = try serializeOpenIDList(self.allocator, open_id_list);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, api_name)) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 批量获取用户基本信息（对应 Go `BatchGetUserInfo`）。
    /// `items` 每次最多 100 条，超出返回 `WechatError.InvalidArgument`。
    /// 返回的 `std.json.Parsed(InfoList)` 由调用方持有并负责 `deinit`，
    /// 用户列表在 `.value.user_info_list`。
    pub fn batchGetUserInfo(self: *Self, items: []const BatchGetUserListItem) !std.json.Parsed(InfoList) {
        if (items.len == 0 or items.len > 100) return util_error.WechatError.InvalidArgument;
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cgi-bin/user/info/batchget?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body = try serializeBatchGetUserInfo(self.allocator, items);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(InfoList, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
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
    try std.testing.expectEqual(@as(i64, 1), parsed.value.subscribe);
    try std.testing.expectEqualStrings("oABC", parsed.value.openid);
    try std.testing.expectEqualStrings("测试", parsed.value.nickname);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, parsed.value.tagid_list);
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
    try std.testing.expectEqual(@as(i64, 2), parsed.value.total);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.count);
    try std.testing.expectEqualStrings("oB", parsed.value.next_openid);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.data.openid.len);
    try std.testing.expectEqualStrings("oA", parsed.value.data.openid[0]);
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
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.tags[0].id);
    try std.testing.expectEqualStrings("b", parsed.value.tags[1].name);
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
    try std.testing.expectEqual(@as(usize, 2), parsed.value.user_info_list.len);
    try std.testing.expectEqualStrings("小明", parsed.value.user_info_list[0].nickname);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.user_info_list[1].subscribe);
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
