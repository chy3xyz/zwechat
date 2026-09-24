// SPDX-License-Identifier: Apache-2.0
//! work/addresslist — 通讯录（user / department / tag / linkedcorp）
//!
//! 对应 `_ref/wechat/work/addresslist/`：部门、成员、标签的完整读写，
//! 以及互联企业（linkedcorp）查询。全部走 `qyapi.weixin.qq.com/cgi-bin/...`，
//! access_token 由 `Context` 注入，响应解析统一 `ignore_unknown_fields = true` + errcode 检查。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 读取单个成员详情。
pub const userGetURL = "https://qyapi.weixin.qq.com/cgi-bin/user/get";

/// 获取部门成员（简略）。
pub const userSimpleListURL = "https://qyapi.weixin.qq.com/cgi-bin/user/simplelist";

/// 创建成员。
pub const userCreateURL = "https://qyapi.weixin.qq.com/cgi-bin/user/create";

/// 更新成员。
pub const userUpdateURL = "https://qyapi.weixin.qq.com/cgi-bin/user/update";

/// 删除成员。
pub const userDeleteURL = "https://qyapi.weixin.qq.com/cgi-bin/user/delete";

/// 获取成员ID列表。
pub const userListIDURL = "https://qyapi.weixin.qq.com/cgi-bin/user/list_id";

/// userid 转 openid。
pub const convertToOpenIDURL = "https://qyapi.weixin.qq.com/cgi-bin/user/convert_to_openid";

/// openid 转 userid。
pub const convertToUserIDURL = "https://qyapi.weixin.qq.com/cgi-bin/user/convert_to_userid";

/// 批量删除成员。
pub const userBatchDeleteURL = "https://qyapi.weixin.qq.com/cgi-bin/user/batchdelete";

/// 登录二次验证。
pub const userAuthSuccURL = "https://qyapi.weixin.qq.com/cgi-bin/user/authsucc";

/// 邀请成员。
pub const batchInviteURL = "https://qyapi.weixin.qq.com/cgi-bin/batch/invite";

/// 获取加入企业二维码。
pub const getJoinQrcodeURL = "https://qyapi.weixin.qq.com/cgi-bin/corp/get_join_qrcode";

/// 手机号获取 userid。
pub const getUseridURL = "https://qyapi.weixin.qq.com/cgi-bin/user/getuserid";

/// 邮箱获取 userid。
pub const getUseridByEmailURL = "https://qyapi.weixin.qq.com/cgi-bin/user/get_userid_by_email";

/// 创建部门。
pub const departmentCreateURL = "https://qyapi.weixin.qq.com/cgi-bin/department/create";

/// 更新部门。
pub const departmentUpdateURL = "https://qyapi.weixin.qq.com/cgi-bin/department/update";

/// 删除部门。
pub const departmentDeleteURL = "https://qyapi.weixin.qq.com/cgi-bin/department/delete";

/// 获取子部门ID列表。
pub const departmentSimpleListURL = "https://qyapi.weixin.qq.com/cgi-bin/department/simplelist";

/// 获取部门列表。
pub const departmentListURL = "https://qyapi.weixin.qq.com/cgi-bin/department/list";

/// 获取单个部门详情。
pub const departmentGetURL = "https://qyapi.weixin.qq.com/cgi-bin/department/get";

/// 创建标签。
pub const tagCreateURL = "https://qyapi.weixin.qq.com/cgi-bin/tag/create";

/// 更新标签名字。
pub const tagUpdateURL = "https://qyapi.weixin.qq.com/cgi-bin/tag/update";

/// 删除标签。
pub const tagDeleteURL = "https://qyapi.weixin.qq.com/cgi-bin/tag/delete";

/// 获取标签成员。
pub const tagGetURL = "https://qyapi.weixin.qq.com/cgi-bin/tag/get";

/// 增加标签成员。
pub const tagAddUsersURL = "https://qyapi.weixin.qq.com/cgi-bin/tag/addtagusers";

/// 删除标签成员。
pub const tagDelUsersURL = "https://qyapi.weixin.qq.com/cgi-bin/tag/deltagusers";

/// 获取标签列表。
pub const tagListURL = "https://qyapi.weixin.qq.com/cgi-bin/tag/list";

/// 获取应用的可见范围（互联企业）。
pub const linkedcorpGetPermListURL = "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/agent/get_perm_list";

/// 获取互联企业成员详细信息。
pub const linkedcorpUserGetURL = "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/user/get";

/// 获取互联企业部门成员。
pub const linkedcorpSimpleListURL = "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/user/simplelist";

/// 获取互联企业部门成员详情。
pub const linkedcorpUserListURL = "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/user/list";

/// 获取互联企业部门列表。
pub const linkedcorpDepartmentListURL = "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/department/list";

// ─────────────────────────────────────────────────────────────────────────────
// 响应 / 数据结构
// ─────────────────────────────────────────────────────────────────────────────

/// 仅含 errcode/errmsg 的通用响应（user/create 等接口的响应体）。
pub const CommonResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

/// 部门成员（简略）。
pub const UserList = struct {
    userid: []const u8 = "",
    name: []const u8 = "",
    department: []i64 = &.{},
    open_userid: []const u8 = "",
};

/// `getDepartmentUsers` 响应。
pub const UserSimpleListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userlist: []UserList = &.{},
};

/// 成员详情（`getUser` 响应）。
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
    /// 扩展属性。
    extattr: Extattr = .{},
    /// 成员对外属性。
    external_profile: ExternalProfile = .{},
};

/// 扩展属性文本值。
pub const ExtattrText = struct {
    value: []const u8 = "",
};

/// 扩展属性网页值。
pub const ExtattrWeb = struct {
    url: []const u8 = "",
    title: []const u8 = "",
};

/// 扩展属性小程序值。
pub const ExtattrMiniprogram = struct {
    appid: []const u8 = "",
    pagepath: []const u8 = "",
    title: []const u8 = "",
};

/// 扩展属性条目（text / web / miniprogram 三选一，按 `type` 区分）。
pub const ExtattrItem = struct {
    type: i64 = 0,
    name: []const u8 = "",
    text: ExtattrText = .{},
    web: ExtattrWeb = .{},
    miniprogram: ExtattrMiniprogram = .{},
};

/// 成员扩展属性容器。
pub const Extattr = struct {
    attrs: []const ExtattrItem = &.{},
};

/// 视频号属性。
pub const WechatChannels = struct {
    nickname: []const u8 = "",
    status: i64 = 0,
};

/// 成员对外属性。
pub const ExternalProfile = struct {
    external_corp_name: []const u8 = "",
    wechat_channels: WechatChannels = .{},
    external_attr: []const ExtattrItem = &.{},
};

/// `createUser` 请求（对应 Go `UserCreateRequest`）。
pub const UserCreateRequest = struct {
    userid: []const u8 = "",
    name: []const u8 = "",
    alias: []const u8 = "",
    mobile: []const u8 = "",
    department: []const i64 = &.{},
    order: []const i64 = &.{},
    position: []const u8 = "",
    /// 0=未定义，1=男，2=女。
    gender: i64 = 0,
    email: []const u8 = "",
    biz_mail: []const u8 = "",
    is_leader_in_dept: []const i64 = &.{},
    direct_leader: []const []const u8 = &.{},
    /// 1=启用，0=禁用。
    enable: i64 = 0,
    avatar_mediaid: []const u8 = "",
    telephone: []const u8 = "",
    address: []const u8 = "",
    main_department: i64 = 0,
    extattr: Extattr = .{},
    to_invite: bool = false,
    external_position: []const u8 = "",
    external_profile: ExternalProfile = .{},
};

/// 企业邮箱别名（`updateUser` 用）。
pub const BizMailAlias = struct {
    item: []const []const u8 = &.{},
};

/// `updateUser` 请求（对应 Go `UserUpdateRequest`）。
pub const UserUpdateRequest = struct {
    userid: []const u8 = "",
    new_userid: []const u8 = "",
    name: []const u8 = "",
    alias: []const u8 = "",
    mobile: []const u8 = "",
    department: []const i64 = &.{},
    order: []const i64 = &.{},
    position: []const u8 = "",
    gender: i64 = 0,
    email: []const u8 = "",
    biz_mail: []const u8 = "",
    biz_mail_alias: BizMailAlias = .{},
    is_leader_in_dept: []const i64 = &.{},
    direct_leader: []const []const u8 = &.{},
    enable: i64 = 0,
    avatar_mediaid: []const u8 = "",
    telephone: []const u8 = "",
    address: []const u8 = "",
    main_department: i64 = 0,
    extattr: Extattr = .{},
    to_invite: bool = false,
    external_position: []const u8 = "",
    external_profile: ExternalProfile = .{},
};

/// `batchDeleteUsers` 请求。
pub const UserBatchDeleteRequest = struct {
    useridlist: []const []const u8 = &.{},
};

/// `listUserIDs` 请求（游标分页）。
pub const UserListIDRequest = struct {
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// 用户-部门关系条目。
pub const DeptUser = struct {
    userid: []const u8 = "",
    department: i64 = 0,
};

/// `listUserIDs` 响应。
pub const UserListIDResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    dept_user: []DeptUser = &.{},
};

/// `convertToOpenID` 响应。
pub const ConvertToOpenIDResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    openid: []const u8 = "",
};

/// `convertToUserID` 响应。
pub const ConvertToUserIDResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userid: []const u8 = "",
};

/// `getJoinQrcode` 响应。
pub const GetJoinQrcodeResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    join_qrcode: []const u8 = "",
};

/// `getUseridByEmail` 请求。
pub const GetUseridByEmailRequest = struct {
    email: []const u8 = "",
    /// 1=企业邮箱（默认），2=企业微信邮箱别名。
    email_type: i64 = 0,
};

/// `getUseridByMobile` / `getUseridByEmail` 响应。
pub const GetUseridResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userid: []const u8 = "",
};

/// `batchInvite` 请求。
pub const BatchInviteRequest = struct {
    user: []const []const u8 = &.{},
    party: []const i64 = &.{},
    tag: []const i64 = &.{},
};

/// `batchInvite` 响应（invalid* 为邀请失败的 id 列表）。
pub const BatchInviteResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    invaliduser: [][]const u8 = &.{},
    invalidparty: []i64 = &.{},
    invalidtag: []i64 = &.{},
};

/// `createDepartment` 请求。
pub const DepartmentCreateRequest = struct {
    name: []const u8 = "",
    name_en: []const u8 = "",
    parentid: i64 = 0,
    order: i64 = 0,
    id: i64 = 0,
};

/// `createDepartment` 响应。
pub const DepartmentCreateResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    id: i64 = 0,
};

/// `updateDepartment` 请求。
pub const DepartmentUpdateRequest = struct {
    id: i64 = 0,
    name: []const u8 = "",
    name_en: []const u8 = "",
    parentid: i64 = 0,
    order: i64 = 0,
};

/// 子部门ID条目（`getDepartmentSimpleList`）。
pub const DepartmentID = struct {
    id: i64 = 0,
    parentid: i64 = 0,
    order: i64 = 0,
};

/// `getDepartmentSimpleList` 响应。
pub const DepartmentSimpleListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    department_id: []DepartmentID = &.{},
};

/// 部门详情。
pub const Department = struct {
    id: i64 = 0,
    name: []const u8 = "",
    name_en: []const u8 = "",
    department_leader: [][]const u8 = &.{},
    parentid: i64 = 0,
    order: i64 = 0,
};

/// `getDepartmentList` / `getDepartmentListByID` 响应。
pub const DepartmentListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    department: []Department = &.{},
};

/// `getDepartment` 响应。
pub const DepartmentGetResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    department: Department = .{},
};

/// `createTag` 请求。
pub const CreateTagRequest = struct {
    tagname: []const u8 = "",
    tagid: i64 = 0,
};

/// `createTag` 响应。
pub const CreateTagResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    tagid: i64 = 0,
};

/// `updateTag` 请求。
pub const UpdateTagRequest = struct {
    tagid: i64 = 0,
    tagname: []const u8 = "",
};

/// 标签成员条目。
pub const GetTagUser = struct {
    userid: []const u8 = "",
    name: []const u8 = "",
};

/// `getTag` 响应。
pub const GetTagResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    tagname: []const u8 = "",
    userlist: []GetTagUser = &.{},
    partylist: []i64 = &.{},
};

/// `addTagUsers` / `deleteTagUsers` 请求。
pub const TagUsersRequest = struct {
    tagid: i64 = 0,
    userlist: []const []const u8 = &.{},
    partylist: []const i64 = &.{},
};

/// `addTagUsers` / `deleteTagUsers` 响应。
pub const TagUsersResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    invalidlist: []const u8 = "",
    invalidparty: []i64 = &.{},
};

/// 标签条目。
pub const Tag = struct {
    tagid: i64 = 0,
    tagname: []const u8 = "",
};

/// `listTags` 响应。
pub const ListTagResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    taglist: []Tag = &.{},
};

/// `getPermList` 响应（互联企业可见范围）。
pub const GetPermListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userids: [][]const u8 = &.{},
    department_ids: [][]const u8 = &.{},
};

/// 互联企业成员扩展属性条目。
pub const LinkedCorpExtattrItem = struct {
    name: []const u8 = "",
    value: []const u8 = "",
    type: i64 = 0,
    text: ExtattrText = .{},
    web: ExtattrWeb = .{},
};

/// 互联企业成员扩展属性容器。
pub const LinkedCorpExtattr = struct {
    attrs: []LinkedCorpExtattrItem = &.{},
};

/// 互联企业成员详细信息。
pub const LinkedCorpUserInfo = struct {
    userid: []const u8 = "",
    name: []const u8 = "",
    department: [][]const u8 = &.{},
    mobile: []const u8 = "",
    telephone: []const u8 = "",
    email: []const u8 = "",
    position: []const u8 = "",
    corpid: []const u8 = "",
    extattr: LinkedCorpExtattr = .{},
};

/// `getLinkedCorpUser` 响应。
pub const GetLinkedCorpUserResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    user_info: LinkedCorpUserInfo = .{},
};

/// 互联企业部门成员（简略）。
pub const LinkedCorpUser = struct {
    userid: []const u8 = "",
    name: []const u8 = "",
    department: [][]const u8 = &.{},
    corpid: []const u8 = "",
};

/// `getLinkedCorpSimpleList` 响应。
pub const LinkedCorpSimpleListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userlist: []LinkedCorpUser = &.{},
};

/// `getLinkedCorpUserList` 响应。
pub const LinkedCorpUserListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userlist: []LinkedCorpUserInfo = &.{},
};

/// 互联企业部门。
pub const LinkedCorpDepartment = struct {
    department_id: []const u8 = "",
    department_name: []const u8 = "",
    parentid: []const u8 = "",
    order: i64 = 0,
};

/// `getLinkedCorpDepartmentList` 响应。
pub const LinkedCorpDepartmentListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    department_list: []LinkedCorpDepartment = &.{},
};

/// convert_to_openid / linkedcorp user/get 等单字段请求体。
const UserIDRequest = struct {
    userid: []const u8 = "",
};

/// convert_to_userid 请求体。
const OpenIDRequest = struct {
    openid: []const u8 = "",
};

/// linkedcorp department_id 请求体。
const LinkedCorpDepartmentRequest = struct {
    department_id: []const u8 = "",
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

    // ─────────────────────────────────────────────────────────────────────────
    // 成员
    // ─────────────────────────────────────────────────────────────────────────

    /// 读取成员详情。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserGet`。
    pub fn getUser(self: *Self, user_id: []const u8) !std.json.Parsed(UserGetResponse) {
        return self.getDecode(userGetURL, "&userid={s}", .{user_id}, UserGetResponse);
    }

    /// 获取部门成员（简略列表）。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserSimpleList`。
    /// `fetch_child` 控制是否递归获取子部门，传 0/1。
    pub fn getDepartmentUsers(
        self: *Self,
        department_id: i64,
        fetch_child: i64,
    ) !std.json.Parsed(UserSimpleListResponse) {
        return self.getDecode(
            userSimpleListURL,
            "&department_id={d}&fetch_child={d}",
            .{ department_id, fetch_child },
            UserSimpleListResponse,
        );
    }

    /// 创建成员。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserCreate`。
    pub fn createUser(self: *Self, req: UserCreateRequest) !std.json.Parsed(CommonResponse) {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postDecode(userCreateURL, body, CommonResponse);
    }

    /// 更新成员。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserUpdate`。
    pub fn updateUser(self: *Self, req: UserUpdateRequest) !void {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postExpectOK(userUpdateURL, body);
    }

    /// 删除成员。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserDelete`。
    pub fn deleteUser(self: *Self, user_id: []const u8) !void {
        return self.getExpectOK(userDeleteURL, "&userid={s}", .{user_id});
    }

    /// 批量删除成员。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserBatchDelete`。
    pub fn batchDeleteUsers(self: *Self, req: UserBatchDeleteRequest) !void {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postExpectOK(userBatchDeleteURL, body);
    }

    /// 获取成员ID列表（游标分页）。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserListID`。
    pub fn listUserIDs(self: *Self, req: UserListIDRequest) !std.json.Parsed(UserListIDResponse) {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postDecode(userListIDURL, body, UserListIDResponse);
    }

    /// userid 转 openid。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `ConvertToOpenID`。
    /// 返回的字符串由调用方负责 `free`。
    pub fn convertToOpenID(self: *Self, user_id: []const u8) ![]u8 {
        const body = try stringifyRequest(self.allocator, UserIDRequest{ .userid = user_id });
        defer self.allocator.free(body);

        var parsed = try self.postDecode(convertToOpenIDURL, body, ConvertToOpenIDResponse);
        errdefer parsed.deinit();
        const openid = try self.allocator.dupe(u8, parsed.value.openid);
        parsed.deinit();
        return openid;
    }

    /// openid 转 userid。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `ConvertToUserID`。
    /// 返回的字符串由调用方负责 `free`。
    pub fn convertToUserID(self: *Self, open_id: []const u8) ![]u8 {
        const body = try stringifyRequest(self.allocator, OpenIDRequest{ .openid = open_id });
        defer self.allocator.free(body);

        var parsed = try self.postDecode(convertToUserIDURL, body, ConvertToUserIDResponse);
        errdefer parsed.deinit();
        const userid = try self.allocator.dupe(u8, parsed.value.userid);
        parsed.deinit();
        return userid;
    }

    /// 登录二次验证。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `UserAuthSucc`。
    pub fn userAuthSucc(self: *Self, user_id: []const u8) !void {
        return self.getExpectOK(userAuthSuccURL, "&userid={s}", .{user_id});
    }

    /// 获取加入企业二维码。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `GetJoinQrcode`。
    /// `size_type` 为 0 时不传该参数（使用微信默认）。
    pub fn getJoinQrcode(self: *Self, size_type: i64) !std.json.Parsed(GetJoinQrcodeResponse) {
        if (size_type > 0) {
            return self.getDecode(getJoinQrcodeURL, "&size_type={d}", .{size_type}, GetJoinQrcodeResponse);
        }
        return self.getDecode(getJoinQrcodeURL, "", .{}, GetJoinQrcodeResponse);
    }

    /// 手机号获取 userid。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `GetUserid`。
    pub fn getUseridByMobile(self: *Self, mobile: []const u8) !std.json.Parsed(GetUseridResponse) {
        const body = try stringifyRequest(self.allocator, struct { mobile: []const u8 = "" }{ .mobile = mobile });
        defer self.allocator.free(body);
        return self.postDecode(getUseridURL, body, GetUseridResponse);
    }

    /// 邮箱获取 userid。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `GetUseridByEmail`。
    pub fn getUseridByEmail(self: *Self, req: GetUseridByEmailRequest) !std.json.Parsed(GetUseridResponse) {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postDecode(getUseridByEmailURL, body, GetUseridResponse);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 部门
    // ─────────────────────────────────────────────────────────────────────────

    /// 创建部门。
    ///
    /// 对应 `_ref/wechat/work/addresslist/department.go` 的 `DepartmentCreate`。
    pub fn createDepartment(self: *Self, req: DepartmentCreateRequest) !std.json.Parsed(DepartmentCreateResponse) {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postDecode(departmentCreateURL, body, DepartmentCreateResponse);
    }

    /// 更新部门。
    ///
    /// 对应 `_ref/wechat/work/addresslist/department.go` 的 `DepartmentUpdate`。
    pub fn updateDepartment(self: *Self, req: DepartmentUpdateRequest) !void {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postExpectOK(departmentUpdateURL, body);
    }

    /// 删除部门。
    ///
    /// 对应 `_ref/wechat/work/addresslist/department.go` 的 `DepartmentDelete`。
    pub fn deleteDepartment(self: *Self, department_id: i64) !void {
        return self.getExpectOK(departmentDeleteURL, "&id={d}", .{department_id});
    }

    /// 获取子部门ID列表。
    ///
    /// 对应 `_ref/wechat/work/addresslist/department.go` 的 `DepartmentSimpleList`。
    pub fn getDepartmentSimpleList(self: *Self, department_id: i64) !std.json.Parsed(DepartmentSimpleListResponse) {
        return self.getDecode(departmentSimpleListURL, "&id={d}", .{department_id}, DepartmentSimpleListResponse);
    }

    /// 获取部门列表（全量，等价 Go `DepartmentList()`）。
    ///
    /// 对应 `_ref/wechat/work/addresslist/department.go` 的 `DepartmentList`。
    pub fn getDepartmentList(self: *Self) !std.json.Parsed(DepartmentListResponse) {
        return self.getDecode(departmentListURL, "", .{}, DepartmentListResponse);
    }

    /// 获取指定部门及其子部门列表。
    ///
    /// 对应 `_ref/wechat/work/addresslist/department.go` 的 `DepartmentListByID`。
    pub fn getDepartmentListByID(self: *Self, department_id: i64) !std.json.Parsed(DepartmentListResponse) {
        return self.getDecode(departmentListURL, "&id={d}", .{department_id}, DepartmentListResponse);
    }

    /// 获取单个部门详情。
    ///
    /// 对应 `_ref/wechat/work/addresslist/department.go` 的 `DepartmentGet`。
    pub fn getDepartment(self: *Self, department_id: i64) !std.json.Parsed(DepartmentGetResponse) {
        return self.getDecode(departmentGetURL, "&id={d}", .{department_id}, DepartmentGetResponse);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 标签
    // ─────────────────────────────────────────────────────────────────────────

    /// 创建标签。
    ///
    /// 对应 `_ref/wechat/work/addresslist/tag.go` 的 `CreateTag`。
    pub fn createTag(self: *Self, req: CreateTagRequest) !std.json.Parsed(CreateTagResponse) {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postDecode(tagCreateURL, body, CreateTagResponse);
    }

    /// 更新标签名字。
    ///
    /// 对应 `_ref/wechat/work/addresslist/tag.go` 的 `UpdateTag`。
    pub fn updateTag(self: *Self, req: UpdateTagRequest) !void {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postExpectOK(tagUpdateURL, body);
    }

    /// 删除标签。
    ///
    /// 对应 `_ref/wechat/work/addresslist/tag.go` 的 `DeleteTag`。
    pub fn deleteTag(self: *Self, tag_id: i64) !void {
        return self.getExpectOK(tagDeleteURL, "&tagid={d}", .{tag_id});
    }

    /// 获取标签成员。
    ///
    /// 对应 `_ref/wechat/work/addresslist/tag.go` 的 `GetTag`。
    pub fn getTag(self: *Self, tag_id: i64) !std.json.Parsed(GetTagResponse) {
        return self.getDecode(tagGetURL, "&tagid={d}", .{tag_id}, GetTagResponse);
    }

    /// 增加标签成员。
    ///
    /// 对应 `_ref/wechat/work/addresslist/tag.go` 的 `AddTagUsers`。
    pub fn addTagUsers(self: *Self, req: TagUsersRequest) !std.json.Parsed(TagUsersResponse) {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postDecode(tagAddUsersURL, body, TagUsersResponse);
    }

    /// 删除标签成员。
    ///
    /// 对应 `_ref/wechat/work/addresslist/tag.go` 的 `DelTagUsers`。
    pub fn deleteTagUsers(self: *Self, req: TagUsersRequest) !std.json.Parsed(TagUsersResponse) {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postDecode(tagDelUsersURL, body, TagUsersResponse);
    }

    /// 获取标签列表。
    ///
    /// 对应 `_ref/wechat/work/addresslist/tag.go` 的 `ListTag`。
    pub fn listTags(self: *Self) !std.json.Parsed(ListTagResponse) {
        return self.getDecode(tagListURL, "", .{}, ListTagResponse);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 邀请
    // ─────────────────────────────────────────────────────────────────────────

    /// 邀请成员（用户/部门/标签维度）。
    ///
    /// 对应 `_ref/wechat/work/addresslist/user.go` 的 `BatchInvite`。
    pub fn batchInvite(self: *Self, req: BatchInviteRequest) !std.json.Parsed(BatchInviteResponse) {
        const body = try stringifyRequest(self.allocator, req);
        defer self.allocator.free(body);
        return self.postDecode(batchInviteURL, body, BatchInviteResponse);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 互联企业（linkedcorp）
    // ─────────────────────────────────────────────────────────────────────────

    /// 获取应用的可见范围（互联企业）。
    ///
    /// 对应 `_ref/wechat/work/addresslist/linkedcorp.go` 的 `GetPermList`。
    pub fn getPermList(self: *Self) !std.json.Parsed(GetPermListResponse) {
        return self.postEmptyDecode(linkedcorpGetPermListURL, GetPermListResponse);
    }

    /// 获取互联企业成员详细信息。
    ///
    /// 对应 `_ref/wechat/work/addresslist/linkedcorp.go` 的 `GetLinkedCorpUser`。
    pub fn getLinkedCorpUser(self: *Self, user_id: []const u8) !std.json.Parsed(GetLinkedCorpUserResponse) {
        const body = try stringifyRequest(self.allocator, UserIDRequest{ .userid = user_id });
        defer self.allocator.free(body);
        return self.postDecode(linkedcorpUserGetURL, body, GetLinkedCorpUserResponse);
    }

    /// 获取互联企业部门成员。
    ///
    /// 对应 `_ref/wechat/work/addresslist/linkedcorp.go` 的 `LinkedCorpSimpleList`。
    pub fn getLinkedCorpSimpleList(self: *Self, department_id: []const u8) !std.json.Parsed(LinkedCorpSimpleListResponse) {
        const body = try stringifyRequest(self.allocator, LinkedCorpDepartmentRequest{ .department_id = department_id });
        defer self.allocator.free(body);
        return self.postDecode(linkedcorpSimpleListURL, body, LinkedCorpSimpleListResponse);
    }

    /// 获取互联企业部门成员详情。
    ///
    /// 对应 `_ref/wechat/work/addresslist/linkedcorp.go` 的 `LinkedCorpUserList`。
    pub fn getLinkedCorpUserList(self: *Self, department_id: []const u8) !std.json.Parsed(LinkedCorpUserListResponse) {
        const body = try stringifyRequest(self.allocator, LinkedCorpDepartmentRequest{ .department_id = department_id });
        defer self.allocator.free(body);
        return self.postDecode(linkedcorpUserListURL, body, LinkedCorpUserListResponse);
    }

    /// 获取互联企业部门列表。
    ///
    /// 对应 `_ref/wechat/work/addresslist/linkedcorp.go` 的 `LinkedCorpDepartmentList`。
    pub fn getLinkedCorpDepartmentList(self: *Self, department_id: []const u8) !std.json.Parsed(LinkedCorpDepartmentListResponse) {
        const body = try stringifyRequest(self.allocator, LinkedCorpDepartmentRequest{ .department_id = department_id });
        defer self.allocator.free(body);
        return self.postDecode(linkedcorpDepartmentListURL, body, LinkedCorpDepartmentListResponse);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 内部辅助
    // ─────────────────────────────────────────────────────────────────────────

    /// GET `url?access_token={token}` + 解析 + errcode 检查。
    ///
    /// 取 token / 拼 URI / 发请求 / errcode 检查（含 token 失效后作废缓存并重试一次）
    /// 统一走 `util/retry.callApi`，`GetSender.send` 只负责「用给定 token 发一次请求」。
    /// `fmt` / `args` 为该接口除 `access_token` 外的 query 参数（如
    /// `"&userid={s}"` + `.{user_id}`）；无附加参数时传 `""` 与 `.{}`。
    fn getDecode(
        self: *Self,
        url: []const u8,
        comptime fmt: []const u8,
        args: anytype,
        comptime T: type,
    ) !std.json.Parsed(T) {
        const body = try util_retry.callApi(
            self.ctx,
            self.allocator,
            apiNameFromURL(url),
            GetSender(fmt, @TypeOf(args)){ .url = url, .args = args },
        );
        defer self.allocator.free(body);
        return decodeChecked(self.allocator, body, T);
    }

    /// GET + 仅检查 errcode（void 方法）。
    ///
    /// errcode 检查已由 `util/retry.callApi` 完成（非 0 一律 `ApiError`），
    /// 这里只需把响应体释放掉。
    fn getExpectOK(
        self: *Self,
        url: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const body = try util_retry.callApi(
            self.ctx,
            self.allocator,
            apiNameFromURL(url),
            GetSender(fmt, @TypeOf(args)){ .url = url, .args = args },
        );
        self.allocator.free(body);
    }

    /// POST JSON + 解析 + errcode 检查。
    fn postDecode(self: *Self, url: []const u8, body: []const u8, comptime T: type) !std.json.Parsed(T) {
        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            apiNameFromURL(url),
            PostSender{ .url = url, .body = body },
        );
        defer self.allocator.free(resp);
        return decodeChecked(self.allocator, resp, T);
    }

    /// POST JSON + 仅检查 errcode（void 方法，对应 Go `DecodeWithCommonError`）。
    ///
    /// errcode 检查已由 `util/retry.callApi` 完成（非 0 一律 `ApiError`），
    /// 这里只需把响应体释放掉。
    fn postExpectOK(self: *Self, url: []const u8, body: []const u8) !void {
        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            apiNameFromURL(url),
            PostSender{ .url = url, .body = body },
        );
        self.allocator.free(resp);
    }

    /// POST（空 body，无 content-type——linkedcorp `get_perm_list` 要求这种方式）+ 解析。
    fn postEmptyDecode(self: *Self, url: []const u8, comptime T: type) !std.json.Parsed(T) {
        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            apiNameFromURL(url),
            PostEmptySender{ .url = url },
        );
        defer self.allocator.free(resp);
        return decodeChecked(self.allocator, resp, T);
    }
};

/// 取接口 URL 的末段作为 `api_name`（喂给 `util/retry.callApi`，进错误详情），
/// 如 `.../cgi-bin/user/get` → `get`。
fn apiNameFromURL(url: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[idx + 1 ..];
}

/// `util/retry.callApi` 的 GET sender：`{url}?access_token={token}` 后按 `fmt`
/// 追加 query 参数（`fmt` 为空则不追加），如 `"&userid={s}"` + `.{user_id}`。
fn GetSender(comptime fmt: []const u8, comptime Args: type) type {
    return struct {
        url: []const u8,
        args: Args,

        pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
            const uri = try std.fmt.allocPrint(
                allocator,
                "{s}?access_token={s}" ++ fmt,
                .{ c.url, token } ++ c.args,
            );
            defer allocator.free(uri);

            const client = util_http.getDefaultClient(allocator);
            return client.get(uri);
        }
    };
}

/// `util/retry.callApi` 的 POST JSON sender。
const PostSender = struct {
    url: []const u8,
    body: []const u8,

    pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const uri = try std.fmt.allocPrint(allocator, "{s}?access_token={s}", .{ c.url, token });
        defer allocator.free(uri);

        const client = util_http.getDefaultClient(allocator);
        return client.postJSON(uri, c.body);
    }
};

/// `util/retry.callApi` 的 POST 空 body sender（不带 content-type）。
const PostEmptySender = struct {
    url: []const u8,

    pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const uri = try std.fmt.allocPrint(allocator, "{s}?access_token={s}", .{ c.url, token });
        defer allocator.free(uri);

        const client = util_http.getDefaultClient(allocator);
        return client.post(uri, "", null);
    }
};

/// 解析微信 JSON 响应：`.ignore_unknown_fields = true` + `.alloc_always`，
/// 解析失败返回 `DecodeError`，`errcode != 0` 返回 `ApiError`。
fn decodeChecked(allocator: std.mem.Allocator, body: []const u8, comptime T: type) !std.json.Parsed(T) {
    var parsed = std.json.parseFromSlice(T, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        return util_error.WechatError.DecodeError;
    };
    errdefer parsed.deinit();
    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    return parsed;
}

/// 把请求结构体序列化为 JSON（`std.json.Stringify`），字符串自动转义。
///
/// 空字符串 / 零值整数 / false / 空 slice / 全零嵌套结构体一律跳过，
/// 与 Go `omitempty` 语义对齐（递归作用于嵌套结构体与 slice 元素）；
/// 微信侧对缺省值按零值处理。
fn stringifyRequest(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    if (comptime @typeInfo(@TypeOf(value)) != .@"struct") return error.InvalidType;
    try writeReqValue(&s, value);
    return out.toOwnedSlice();
}

/// 递归写出请求值：结构体按字段逐个判断 omitempty，slice 逐元素递归。
fn writeReqValue(s: *std.json.Stringify, value: anytype) std.json.Stringify.Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info == .@"struct") {
        try s.beginObject();
        inline for (info.@"struct".field_names, info.@"struct".field_types) |name, ftype| {
            const fv = @field(value, name);
            const should_write = if (comptime isSkippable(ftype)) !isEmpty(ftype, fv) else true;
            if (should_write) {
                try s.objectField(name);
                try writeReqValue(s, fv);
            }
        }
        try s.endObject();
    } else if (info == .pointer and info.pointer.size == .slice and info.pointer.child != u8) {
        try s.beginArray();
        for (value) |elem| try writeReqValue(s, elem);
        try s.endArray();
    } else {
        try s.write(value);
    }
}

fn isSkippable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .pointer => |p| p.size == .slice,
        .int, .bool => true,
        else => false,
    };
}

fn isEmpty(comptime T: type, v: T) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            var all_empty = true;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |fname, ftype| {
                if (all_empty and !isEmpty(ftype, @field(v, fname))) all_empty = false;
            }
            break :blk all_empty;
        },
        .pointer => |p| p.size == .slice and v.len == 0,
        .int => v == 0,
        .bool => !v,
        else => false,
    };
}

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

// ─────────────────────────────────────────────────────────────────────────────
// Mock access_token 句柄（测试用）
// ─────────────────────────────────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = @import("../../credential/mod.zig").AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .corp_id = "ww-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

/// 捕获 uri / method / payload / content_type 的测试 transport，
/// 返回预设响应体（MockTransport 只按 uri 路由、不记录 body，这里补足 body 断言）。
const CaptureTransport = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uri: []u8 = &.{},
    payload: ?[]u8 = null,
    method: std.http.Method = .GET,
    content_type: ?[]u8 = null,

    fn deinit(self: *CaptureTransport) void {
        if (self.uri.len > 0) self.allocator.free(self.uri);
        if (self.payload) |p| self.allocator.free(p);
        if (self.content_type) |c| self.allocator.free(c);
    }

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        const self: *CaptureTransport = @ptrCast(@alignCast(ctx));
        if (self.uri.len > 0) self.allocator.free(self.uri);
        self.uri = try self.allocator.dupe(u8, uri);
        if (self.payload) |p| self.allocator.free(p);
        self.payload = try allocator.dupe(u8, payload);
        self.method = method;
        if (self.content_type) |c| self.allocator.free(c);
        self.content_type = if (content_type) |ct| try allocator.dupe(u8, ct) else null;
        return allocator.dupe(u8, self.response) catch return error.OutOfMemory;
    }
};

fn useCapture(cap: *CaptureTransport) void {
    const client = util_http.getDefaultClient(cap.allocator);
    client.setTransport(CaptureTransport.dispatch, @ptrCast(cap));
}

fn dropCapture() void {
    // 不依赖「用别的 allocator 再取一次指针」的宽容语义：直接销毁线程局部实例，
    // 注入的 transport 随实例一起消失（下次 getDefaultClient 会重新初始化）。
    util_http.deinitDefaultClient();
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "getUser 解析含 extattr/external_profile 的真实响应" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/user/get?access_token=token-abc&userid=zhangsan", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"userid\":\"zhangsan\",\"name\":\"张三\",\"department\":[1,2],\"extattr\":{\"attrs\":[{\"type\":2,\"name\":\"爱好\",\"text\":{\"value\":\"打球\"}}]},\"external_profile\":{\"external_corp_name\":\"示例公司\",\"wechat_channels\":{\"nickname\":\"视频号\",\"status\":1},\"external_attr\":[{\"type\":0,\"name\":\"文本\",\"text\":{\"value\":\"值\"}}]}}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getUser("zhangsan");
    defer parsed.deinit();

    // 期望值里的切片字段是可变切片（`[]i64` / `[]ExtattrItem`），
    // 用局部 var 数组承载，避免 const 字面量无法强转。
    var departments = [_]i64{ 1, 2 };
    var attrs = [_]ExtattrItem{
        .{ .type = 2, .name = "爱好", .text = .{ .value = "打球" } },
    };
    var profile_attrs = [_]ExtattrItem{
        .{ .type = 0, .name = "文本", .text = .{ .value = "值" } },
    };

    // 整体比较：一次覆盖 UserGetResponse 全部字段（响应里未下发的字段须保持默认值）。
    try std.testing.expectEqualDeep(UserGetResponse{
        .errmsg = "ok",
        .userid = "zhangsan",
        .name = "张三",
        .department = &departments,
        .extattr = .{ .attrs = &attrs },
        .external_profile = .{
            .external_corp_name = "示例公司",
            .wechat_channels = .{ .nickname = "视频号", .status = 1 },
            .external_attr = &profile_attrs,
        },
    }, parsed.value);
}

test "getDepartmentUsers 请求 URL 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"userlist\":[{\"userid\":\"u1\",\"name\":\"张三\",\"department\":[1],\"open_userid\":\"ou1\"}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getDepartmentUsers(2, 1);
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, cap.method);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/user/simplelist?access_token=token-abc&department_id=2&fetch_child=1",
        cap.uri,
    );
    try std.testing.expectEqual(@as(usize, 1), parsed.value.userlist.len);
    try std.testing.expectEqualStrings("u1", parsed.value.userlist[0].userid);
    try std.testing.expectEqualStrings("ou1", parsed.value.userlist[0].open_userid);
}

// ─────────────────────────────────────────────────────────────────────────────
// 成员方法测试
// ─────────────────────────────────────────────────────────────────────────────

test "createUser 请求 body 转义与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"created\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.createUser(.{
        .userid = "zhangsan",
        .name = "张\"三\"",
        .mobile = "13800138000",
        .department = &.{ 1, 2 },
        .gender = 1,
        .extattr = .{ .attrs = &.{
            .{ .type = 2, .name = "爱好", .text = .{ .value = "打球" } },
        } },
        .to_invite = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/user/create?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "\"userid\":\"zhangsan\"");
    // 引号必须被转义，防止非法 JSON。
    try expectContains(cap.payload.?, "\"name\":\"张\\\"三\\\"\"");
    try expectContains(cap.payload.?, "\"mobile\":\"13800138000\"");
    try expectContains(cap.payload.?, "\"department\":[1,2]");
    try expectContains(cap.payload.?, "\"gender\":1");
    try expectContains(cap.payload.?, "\"extattr\":{\"attrs\":[{\"type\":2,\"name\":\"爱好\",\"text\":{\"value\":\"打球\"}}]}");
    try expectContains(cap.payload.?, "\"to_invite\":true");
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "updateUser 请求 body 与成功路径" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"updated\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try al.updateUser(.{
        .userid = "zhangsan",
        .new_userid = "zhangsan2",
        .name = "张三",
        .department = &.{1},
        .biz_mail_alias = .{ .item = &.{"alias@corp.com"} },
    });

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/user/update?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "\"userid\":\"zhangsan\"");
    try expectContains(cap.payload.?, "\"new_userid\":\"zhangsan2\"");
    try expectContains(cap.payload.?, "\"biz_mail_alias\":{\"item\":[\"alias@corp.com\"]}");
}

test "updateUser errcode 非零返回 ApiError" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":60111,\"errmsg\":\"userid not found\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try std.testing.expectError(util_error.WechatError.ApiError, al.updateUser(.{ .userid = "ghost" }));
}

test "deleteUser 请求 URL 与成功路径" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"deleted\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try al.deleteUser("zhangsan");

    try std.testing.expectEqual(std.http.Method.GET, cap.method);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/user/delete?access_token=token-abc&userid=zhangsan",
        cap.uri,
    );
}

test "batchDeleteUsers 请求 body 与成功路径" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"deleted\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try al.batchDeleteUsers(.{ .useridlist = &.{ "u1", "u2" } });

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/user/batchdelete?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "\"useridlist\":[\"u1\",\"u2\"]");
}

test "listUserIDs 请求 body 与游标响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"CUR\",\"dept_user\":[{\"userid\":\"u1\",\"department\":2}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.listUserIDs(.{ .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/user/list_id?access_token=token-abc", cap.uri);
    // cursor 为空字符串应被跳过（omitempty 语义）。
    try expectContains(cap.payload.?, "\"limit\":100");
    try std.testing.expect(std.mem.indexOf(u8, cap.payload.?, "cursor") == null);
    try std.testing.expectEqualStrings("CUR", parsed.value.next_cursor);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.dept_user.len);
    try std.testing.expectEqualStrings("u1", parsed.value.dept_user[0].userid);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.dept_user[0].department);
}

test "convertToOpenID 请求 body 与返回值" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"openid\":\"oXxx\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    const openid = try al.convertToOpenID("zhangsan");
    defer allocator.free(openid);

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/user/convert_to_openid?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "{\"userid\":\"zhangsan\"}");
    try std.testing.expectEqualStrings("oXxx", openid);
}

test "convertToUserID 请求 body 与返回值" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"userid\":\"zhangsan\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    const userid = try al.convertToUserID("oXxx");
    defer allocator.free(userid);

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/user/convert_to_userid?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "{\"openid\":\"oXxx\"}");
    try std.testing.expectEqualStrings("zhangsan", userid);
}

test "userAuthSucc 请求 URL 与成功路径" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try al.userAuthSucc("zhangsan");

    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/user/authsucc?access_token=token-abc&userid=zhangsan",
        cap.uri,
    );
}

test "getJoinQrcode 带 size_type 的 URL 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"join_qrcode\":\"https://qr.example.com/x\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getJoinQrcode(2);
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, cap.method);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/corp/get_join_qrcode?access_token=token-abc&size_type=2",
        cap.uri,
    );
    try std.testing.expectEqualStrings("https://qr.example.com/x", parsed.value.join_qrcode);
}

test "getUseridByMobile 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"userid\":\"zhangsan\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getUseridByMobile("13800138000");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/user/getuserid?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "{\"mobile\":\"13800138000\"}");
    try std.testing.expectEqualStrings("zhangsan", parsed.value.userid);
}

test "getUseridByEmail 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"userid\":\"zhangsan\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getUseridByEmail(.{ .email = "a@corp.com", .email_type = 1 });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/user/get_userid_by_email?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "\"email\":\"a@corp.com\"");
    try expectContains(cap.payload.?, "\"email_type\":1");
    try std.testing.expectEqualStrings("zhangsan", parsed.value.userid);
}

// ─────────────────────────────────────────────────────────────────────────────
// 部门方法测试
// ─────────────────────────────────────────────────────────────────────────────

test "createDepartment 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"created\",\"id\":123}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.createDepartment(.{ .name = "技术部", .parentid = 1, .id = 123 });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/department/create?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "\"name\":\"技术部\"");
    try expectContains(cap.payload.?, "\"parentid\":1");
    try expectContains(cap.payload.?, "\"id\":123");
    // name_en / order 为零值应跳过。
    try std.testing.expect(std.mem.indexOf(u8, cap.payload.?, "name_en") == null);
    try std.testing.expectEqual(@as(i64, 123), parsed.value.id);
}

test "updateDepartment 请求 body 与成功路径" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"updated\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try al.updateDepartment(.{ .id = 123, .name = "新技术部", .order = 5 });

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/department/update?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "{\"id\":123,\"name\":\"新技术部\",\"order\":5}");
}

test "deleteDepartment 请求 URL 与成功路径" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"deleted\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try al.deleteDepartment(123);

    try std.testing.expectEqual(std.http.Method.GET, cap.method);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/department/delete?access_token=token-abc&id=123",
        cap.uri,
    );
}

test "getDepartmentSimpleList 请求 URL 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"department_id\":[{\"id\":2,\"parentid\":1,\"order\":10}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getDepartmentSimpleList(1);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/department/simplelist?access_token=token-abc&id=1",
        cap.uri,
    );
    try std.testing.expectEqual(@as(usize, 1), parsed.value.department_id.len);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.department_id[0].id);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.department_id[0].parentid);
}

test "getDepartmentList 不带 id 的 URL 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"department\":[{\"id\":1,\"name\":\"根部门\",\"parentid\":0},{\"id\":2,\"name\":\"子部门\",\"name_en\":\"Sub\",\"department_leader\":[\"u1\"],\"parentid\":1,\"order\":5}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getDepartmentList();
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/department/list?access_token=token-abc", cap.uri);

    // 期望值里的切片字段是可变切片（`[]Department` / `[][]const u8`），
    // 用局部 var 数组承载，避免 const 字面量无法强转。
    var sub_leaders = [_][]const u8{"u1"};
    var departments = [_]Department{
        .{ .id = 1, .name = "根部门" },
        .{
            .id = 2,
            .name = "子部门",
            .name_en = "Sub",
            .department_leader = &sub_leaders,
            .parentid = 1,
            .order = 5,
        },
    };
    // 整体比较：一次覆盖两个部门的全部字段（未下发的字段须保持默认值）。
    try std.testing.expectEqualDeep(DepartmentListResponse{
        .errmsg = "ok",
        .department = &departments,
    }, parsed.value);
}

test "getDepartmentListByID 带 id 的 URL 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"department\":[{\"id\":2,\"name\":\"子部门\",\"parentid\":1}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getDepartmentListByID(2);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/department/list?access_token=token-abc&id=2",
        cap.uri,
    );
    try std.testing.expectEqual(@as(usize, 1), parsed.value.department.len);
    try std.testing.expectEqualStrings("子部门", parsed.value.department[0].name);
}

test "getDepartment 请求 URL 与详情解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"department\":{\"id\":2,\"name\":\"子部门\",\"name_en\":\"Sub\",\"department_leader\":[\"u1\"],\"parentid\":1,\"order\":5}}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getDepartment(2);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/department/get?access_token=token-abc&id=2",
        cap.uri,
    );
    // 期望值里的 department_leader 是可变切片（`[][]const u8`），
    // 用局部 var 数组承载，避免 const 字面量无法强转。
    var leaders = [_][]const u8{"u1"};
    // 整体比较：一次覆盖 Department 全部字段（未下发的字段须保持默认值）。
    try std.testing.expectEqualDeep(DepartmentGetResponse{
        .errmsg = "ok",
        .department = .{
            .id = 2,
            .name = "子部门",
            .name_en = "Sub",
            .department_leader = &leaders,
            .parentid = 1,
            .order = 5,
        },
    }, parsed.value);
}

// ─────────────────────────────────────────────────────────────────────────────
// 标签方法测试
// ─────────────────────────────────────────────────────────────────────────────

test "createTag 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"created\",\"tagid\":12}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.createTag(.{ .tagname = "标签一", .tagid = 12 });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/tag/create?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "{\"tagname\":\"标签一\",\"tagid\":12}");
    try std.testing.expectEqual(@as(i64, 12), parsed.value.tagid);
}

test "updateTag 请求 body 与成功路径" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"updated\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try al.updateTag(.{ .tagid = 12, .tagname = "新标签" });

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/tag/update?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "{\"tagid\":12,\"tagname\":\"新标签\"}");
}

test "deleteTag 请求 URL 与错误路径" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":40066,\"errmsg\":\"invalid tagid\"}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    try std.testing.expectError(util_error.WechatError.ApiError, al.deleteTag(999));

    try std.testing.expectEqual(std.http.Method.GET, cap.method);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/tag/delete?access_token=token-abc&tagid=999",
        cap.uri,
    );
}

test "getTag 请求 URL 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"tagname\":\"标签一\",\"userlist\":[{\"userid\":\"u1\",\"name\":\"张三\"}],\"partylist\":[2,3]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getTag(12);
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/tag/get?access_token=token-abc&tagid=12",
        cap.uri,
    );
    // 期望值里的 userlist / partylist 是可变切片，用局部 var 数组承载。
    var users = [_]GetTagUser{.{ .userid = "u1", .name = "张三" }};
    var parties = [_]i64{ 2, 3 };
    // 整体比较：一次覆盖 GetTagResponse 全部字段（用户与部门 id 全部元素）。
    try std.testing.expectEqualDeep(GetTagResponse{
        .errmsg = "ok",
        .tagname = "标签一",
        .userlist = &users,
        .partylist = &parties,
    }, parsed.value);
}

test "addTagUsers 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"invalidlist\":\"u9\",\"invalidparty\":[3]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.addTagUsers(.{ .tagid = 12, .userlist = &.{ "u1", "u2" }, .partylist = &.{2} });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/tag/addtagusers?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "\"tagid\":12");
    try expectContains(cap.payload.?, "\"userlist\":[\"u1\",\"u2\"]");
    try expectContains(cap.payload.?, "\"partylist\":[2]");
    try std.testing.expectEqualStrings("u9", parsed.value.invalidlist);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.invalidparty.len);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.invalidparty[0]);
}

test "deleteTagUsers 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"invalidlist\":\"\",\"invalidparty\":[]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.deleteTagUsers(.{ .tagid = 12, .userlist = &.{"u1"} });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/tag/deltagusers?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "{\"tagid\":12,\"userlist\":[\"u1\"]}");
    // partylist 为空 slice 应被跳过。
    try std.testing.expect(std.mem.indexOf(u8, cap.payload.?, "partylist") == null);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "listTags 请求 URL 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"taglist\":[{\"tagid\":12,\"tagname\":\"标签一\"}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.listTags();
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, cap.method);
    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/tag/list?access_token=token-abc", cap.uri);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.taglist.len);
    try std.testing.expectEqual(@as(i64, 12), parsed.value.taglist[0].tagid);
    try std.testing.expectEqualStrings("标签一", parsed.value.taglist[0].tagname);
}

// ─────────────────────────────────────────────────────────────────────────────
// 邀请 / 互转 / 互联企业方法测试
// ─────────────────────────────────────────────────────────────────────────────

test "batchInvite 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"invaliduser\":[\"ghost\"],\"invalidparty\":[99],\"invalidtag\":[]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.batchInvite(.{ .user = &.{ "u1", "u2" }, .party = &.{2}, .tag = &.{3} });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/batch/invite?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "\"user\":[\"u1\",\"u2\"]");
    try expectContains(cap.payload.?, "\"party\":[2]");
    try expectContains(cap.payload.?, "\"tag\":[3]");
    try std.testing.expectEqual(@as(usize, 1), parsed.value.invaliduser.len);
    try std.testing.expectEqualStrings("ghost", parsed.value.invaliduser[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.invalidparty.len);
    try std.testing.expectEqual(@as(i64, 99), parsed.value.invalidparty[0]);
}

test "getPermList POST 空 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"userids\":[\"u1\"],\"department_ids\":[\"LINKEDID1\"]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getPermList();
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/agent/get_perm_list?access_token=token-abc",
        cap.uri,
    );
    try std.testing.expectEqualStrings("", cap.payload.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.userids.len);
    try std.testing.expectEqualStrings("u1", parsed.value.userids[0]);
    try std.testing.expectEqualStrings("LINKEDID1", parsed.value.department_ids[0]);
}

test "getLinkedCorpUser 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"user_info\":{\"userid\":\"zhangsan\",\"name\":\"张三\",\"department\":[\"LINKEDID1/D2\"],\"mobile\":\"13800138000\",\"telephone\":\"0755\",\"email\":\"a@corp.com\",\"position\":\"工程师\",\"corpid\":\"ww-linked\",\"extattr\":{\"attrs\":[{\"name\":\"爱好\",\"type\":2,\"text\":{\"value\":\"打球\"}}]}}}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getLinkedCorpUser("zhangsan");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/user/get?access_token=token-abc", cap.uri);
    try expectContains(cap.payload.?, "{\"userid\":\"zhangsan\"}");
    try std.testing.expectEqualStrings("zhangsan", parsed.value.user_info.userid);
    try std.testing.expectEqualStrings("ww-linked", parsed.value.user_info.corpid);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.user_info.department.len);
    try std.testing.expectEqualStrings("LINKEDID1/D2", parsed.value.user_info.department[0]);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.user_info.extattr.attrs.len);
    try std.testing.expectEqualStrings("打球", parsed.value.user_info.extattr.attrs[0].text.value);
}

test "getLinkedCorpSimpleList 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"userlist\":[{\"userid\":\"u1\",\"name\":\"张三\",\"department\":[\"LINKEDID1/D2\"],\"corpid\":\"ww-linked\"}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getLinkedCorpSimpleList("LINKEDID1/D2");
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/user/simplelist?access_token=token-abc",
        cap.uri,
    );
    try expectContains(cap.payload.?, "{\"department_id\":\"LINKEDID1/D2\"}");
    try std.testing.expectEqual(@as(usize, 1), parsed.value.userlist.len);
    try std.testing.expectEqualStrings("u1", parsed.value.userlist[0].userid);
    try std.testing.expectEqualStrings("ww-linked", parsed.value.userlist[0].corpid);
}

test "getLinkedCorpUserList 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"userlist\":[{\"userid\":\"u1\",\"name\":\"张三\",\"department\":[\"LINKEDID1/D2\"],\"mobile\":\"13800138000\",\"telephone\":\"\",\"email\":\"\",\"position\":\"工程师\",\"corpid\":\"ww-linked\",\"extattr\":{\"attrs\":[]}}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getLinkedCorpUserList("LINKEDID1/D2");
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/user/list?access_token=token-abc",
        cap.uri,
    );
    try expectContains(cap.payload.?, "{\"department_id\":\"LINKEDID1/D2\"}");
    try std.testing.expectEqual(@as(usize, 1), parsed.value.userlist.len);
    try std.testing.expectEqualStrings("工程师", parsed.value.userlist[0].position);
    try std.testing.expectEqualStrings("13800138000", parsed.value.userlist[0].mobile);
}

test "getLinkedCorpDepartmentList 请求 body 与响应解析" {
    const allocator = std.testing.allocator;
    var cap = CaptureTransport{
        .allocator = allocator,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"department_list\":[{\"department_id\":\"LINKEDID1/D2\",\"department_name\":\"互联子部门\",\"parentid\":\"LINKEDID1\",\"order\":10}]}",
    };
    defer cap.deinit();
    useCapture(&cap);
    defer dropCapture();

    var ctx = makeCtx();
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getLinkedCorpDepartmentList("LINKEDID1");
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/linkedcorp/department/list?access_token=token-abc",
        cap.uri,
    );
    try expectContains(cap.payload.?, "{\"department_id\":\"LINKEDID1\"}");
    try std.testing.expectEqual(@as(usize, 1), parsed.value.department_list.len);
    try std.testing.expectEqualStrings("LINKEDID1/D2", parsed.value.department_list[0].department_id);
    try std.testing.expectEqualStrings("互联子部门", parsed.value.department_list[0].department_name);
    try std.testing.expectEqualStrings("LINKEDID1", parsed.value.department_list[0].parentid);
    try std.testing.expectEqual(@as(i64, 10), parsed.value.department_list[0].order);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：token 失效自愈（util/retry.callApi 链路）
// ─────────────────────────────────────────────────────────────────────────────

/// 可按脚本换发 token 并统计作废次数的凭据 handle 状态。
const RetryTokenState = struct {
    /// 依次给出的 token；回源次数超出脚本后复用最后一项。
    tokens: []const []const u8 = &.{ "tok-old", "tok-new" },
    fetch_calls: usize = 0,
    invalidate_calls: usize = 0,

    fn getToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *RetryTokenState = @ptrCast(@alignCast(ctx));
        const token = self.tokens[@min(self.fetch_calls, self.tokens.len - 1)];
        self.fetch_calls += 1;
        return allocator.dupe(u8, token);
    }

    fn invalidate(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *RetryTokenState = @ptrCast(@alignCast(ctx));
        self.invalidate_calls += 1;
    }

    const vtable = @import("../../credential/mod.zig").AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

/// 构造借用 `state` 的 Context（handle 的 ptr 指向测试局部状态）。
fn makeRetryCtx(state: *RetryTokenState) Context {
    return .{
        .config = .{ .corp_id = "ww-addr-retry" },
        .access_token_handle = .{ .ptr = @ptrCast(state), .vtable = &RetryTokenState.vtable },
    };
}

test "getUser token 失效：40001 → 作废缓存 → 用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/user/get?access_token=tok-old&userid=zhangsan", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/user/get?access_token=tok-new&userid=zhangsan", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"userid\":\"zhangsan\",\"name\":\"张三\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = RetryTokenState{};
    var ctx = makeRetryCtx(&state);
    var al = AddressList.init(&ctx, allocator);
    var parsed = try al.getUser("zhangsan");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("张三", parsed.value.name);
    try std.testing.expectEqual(@as(usize, 1), state.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/user/get?access_token=tok-old&userid=zhangsan",
        mt.history.items[0],
    );
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/user/get?access_token=tok-new&userid=zhangsan",
        mt.history.items[1],
    );
}

test "deleteUser 非 token 类 errcode：直接 ApiError，不作废也不重试" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/user/delete?access_token=tok-old&userid=zhangsan", .{
        .body = "{\"errcode\":60011,\"errmsg\":\"no privilege to access/modify contact/party/agent\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = RetryTokenState{};
    var ctx = makeRetryCtx(&state);
    var al = AddressList.init(&ctx, allocator);

    const result = al.deleteUser("zhangsan");
    try std.testing.expectError(util_error.WechatError.ApiError, result);

    try std.testing.expectEqual(@as(usize, 0), state.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.fetch_calls);
}
