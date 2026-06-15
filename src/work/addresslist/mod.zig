//! work/addresslist — 通讯录（user / department）
//!
//! 对应 `_ref/wechat/work/addresslist/`：成员 / 部门的基础读写。
//! 当前落地 `GetUser`（按 userid 查成员）和 `GetDepartmentUsers`
//! （按 department_id 拉成员清单）两个最常用查询。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 读取单个成员详情。
pub const userGetURL = "https://qyapi.weixin.qq.com/cgi-bin/user/get";

/// 获取部门成员（简略）。
pub const userSimpleListURL = "https://qyapi.weixin.qq.com/cgi-bin/user/simplelist";

// ─────────────────────────────────────────────────────────────────────────────
// 响应 / 数据结构
// ─────────────────────────────────────────────────────────────────────────────

/// 部门成员（简略）。
pub const UserList = struct {
    userid: []const u8 = "",
    name: []const u8 = "",
    department: []i64 = &.{},
    open_userid: []const u8 = "",
};

/// `GetDepartmentUsers` 响应。
pub const UserSimpleListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userlist: []UserList = &.{},
};

/// 成员详情（`GetUser` 响应）。
pub const UserGetResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userid: []const u8 = "",
    name: []const u8 = "",
    department: []i64 = &.{},
    order: []i64 = &.{},
    position: []const u8 = "",
    mobile: []const u8 = "",
    /// 0=未定义，1=男，2=女。微信侧用字符串"0"/"1"/"2"。
    gender: []const u8 = "",
    email: []const u8 = "",
    biz_mail: []const u8 = "",
    is_leader_in_dept: []i64 = &.{},
    direct_leader: [][]const u8 = &.{},
    avatar: []const u8 = "",
    thumb_avatar: []const u8 = "",
    telephone: []const u8 = "",
    alias: []const u8 = "",
    address: []const u8 = "",
    open_userid: []const u8 = "",
    main_department: i64 = 0,
    /// 激活状态: 1=已激活，2=已禁用，4=未激活，5=退出企业。
    status: i64 = 0,
    qr_code: []const u8 = "",
    external_position: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 通讯录子模块聚合。
pub const AddressList = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 读取成员详情。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserGet`。
    pub fn getUser(self: *Self, user_id: []const u8) !UserGetResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}&userid={s}",
            .{ userGetURL, access_token, user_id },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(UserGetResponse, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 获取部门成员（简略列表）。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserSimpleList`。
    /// `fetch_child` 控制是否递归获取子部门，传 0/1。
    pub fn getDepartmentUsers(
        self: *Self,
        department_id: i64,
        fetch_child: i64,
    ) !UserSimpleListResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}&department_id={d}&fetch_child={d}",
            .{ userSimpleListURL, access_token, department_id, fetch_child },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(UserSimpleListResponse, self.allocator, body, .{}) catch {
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

test "AddressList.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-addr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const al = AddressList.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-addr", al.ctx.config.corp_id);
}

test "UserList 默认值" {
    const u = UserList{};
    try std.testing.expectEqualStrings("", u.userid);
    try std.testing.expectEqualStrings("", u.name);
    try std.testing.expectEqual(@as(usize, 0), u.department.len);
}

test "UserGetResponse 默认值" {
    const u = UserGetResponse{};
    try std.testing.expectEqualStrings("", u.userid);
    try std.testing.expectEqual(@as(i64, 0), u.status);
}

test "UserSimpleListResponse 默认值" {
    const r = UserSimpleListResponse{};
    try std.testing.expectEqual(@as(usize, 0), r.userlist.len);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}
