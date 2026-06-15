//! work/externalcontact — 客户联系（external_userid 管理）
//!
//! 对应 `_ref/wechat/work/externalcontact/`：实现按 `external_userid` 查详情
//! 与按员工 userid 列出客户两个核心查询接口。其他子能力（备注、标签、群发等）
//! 在后续 pass 中按需补齐。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 获取客户列表（按员工 userid）。
pub const externalContactListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/list";

/// 获取客户详情（按 external_userid）。
pub const externalContactGetURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get";

// ─────────────────────────────────────────────────────────────────────────────
// 响应 / 数据结构
// ─────────────────────────────────────────────────────────────────────────────

/// `GetExternalContactList` 响应。
pub const ExternalUserListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 客户 external_userid 列表。
    external_userid: [][]const u8 = &.{},
};

/// 外部联系人。
pub const ExternalUser = struct {
    external_userid: []const u8 = "",
    name: []const u8 = "",
    avatar: []const u8 = "",
    /// 1 表示微信用户，2 表示企业微信用户。
    type: i64 = 0,
    /// 0=未定义，1=男，2=女。
    gender: i64 = 0,
    unionid: []const u8 = "",
    position: []const u8 = "",
    corp_name: []const u8 = "",
    corp_full_name: []const u8 = "",
};

/// 跟进人（指企业内部用户）。
pub const FollowUser = struct {
    userid: []const u8 = "",
    remark: []const u8 = "",
    description: []const u8 = "",
    createtime: i64 = 0,
    remark_corp_name: []const u8 = "",
    oper_userid: []const u8 = "",
    add_way: i64 = 0,
    state: []const u8 = "",
};

/// `GetExternalContact` 响应。
pub const ExternalUserDetailResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    external_contact: ExternalUser = .{},
    follow_user: []FollowUser = &.{},
    next_cursor: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 客户联系子模块聚合。
pub const ExternalContact = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 按 `external_userid` 查客户详情。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `GetExternalUserDetail`。`next_cursor` 可选，用于分页拉取「跟进人」列表。
    pub fn getExternalContact(
        self: *Self,
        external_userid: []const u8,
        next_cursor: []const u8,
    ) !ExternalUserDetailResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}&external_userid={s}&cursor={s}",
            .{ externalContactGetURL, access_token, external_userid, next_cursor },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ExternalUserDetailResponse, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 按员工 `userid` 列出其所有客户的 `external_userid`。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `GetExternalUserList`。
    pub fn getExternalContactList(
        self: *Self,
        userid: []const u8,
    ) !ExternalUserListResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}&userid={s}",
            .{ externalContactListURL, access_token, userid },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ExternalUserListResponse, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

test "ExternalContact.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const ec = ExternalContact.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-test", ec.ctx.config.corp_id);
}

test "ExternalUser 默认值" {
    const u = ExternalUser{};
    try std.testing.expectEqualStrings("", u.external_userid);
    try std.testing.expectEqualStrings("", u.name);
    try std.testing.expectEqual(@as(i64, 0), u.type);
}

test "ExternalUserListResponse 默认值" {
    const r = ExternalUserListResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
    try std.testing.expectEqualStrings("", r.errmsg);
    try std.testing.expectEqual(@as(usize, 0), r.external_userid.len);
}
