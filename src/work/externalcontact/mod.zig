// SPDX-License-Identifier: Apache-2.0
//! work/externalcontact — 客户联系（external_userid 管理）
//!
//! 对应 `_ref/wechat/work/externalcontact/`：客户列表/详情查询、批量获取、
//! 备注修改、「联系我」配置（contact_way）、客户群（groupchat / join_way）、
//! 在职与离职继承（transfer）、欢迎语与企业群发（msg）、朋友圈（moment）、
//! 企业标签（tag）、管理规则（customer strategy / moment strategy）、
//! 联系客户统计（statistic）与获客助手（customer_acquisition）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 获取客户列表（按员工 userid）。
pub const externalContactListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/list";

/// 获取客户详情（按 external_userid）。
pub const externalContactGetURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get";

/// 批量获取客户详情。
pub const batchGetExternalUserDetailURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/batch/get_by_user";

/// 修改客户备注信息。
pub const updateUserRemarkURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/remark";

/// 获取配置了客户联系功能的成员列表。
pub const followUserListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_follow_user_list";

/// 配置客户联系「联系我」方式。
pub const addContactWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_contact_way";

/// 获取企业已配置的「联系我」方式。
pub const getContactWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_contact_way";

/// 更新企业已配置的「联系我」方式。
pub const updateContactWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/update_contact_way";

/// 获取企业已配置的「联系我」列表。
pub const listContactWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/list_contact_way";

/// 删除企业已配置的「联系我」方式。
pub const delContactWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/del_contact_way";

/// 结束临时会话。
pub const closeTempChatURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/close_temp_chat";

/// 客户群接口前缀（`/list`、`/get`、`/onjob_transfer`、`/transfer`、
/// `/add_join_way`、`/get_join_way`、`/update_join_way`、`/del_join_way`、
/// `/statistic`、`/statistic_group_by_day` 均挂在其下）。
pub const groupChatURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat";

/// 获取客户群列表。
pub const groupChatListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/list";

/// 获取客户群详情。
pub const groupChatGetURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/get";

/// 添加群进群方式配置。
pub const addJoinWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/add_join_way";

/// 获取群进群方式配置。
pub const getJoinWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/get_join_way";

/// 更新群进群方式配置。
pub const updateJoinWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/update_join_way";

/// 删除群进群方式配置。
pub const delJoinWayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/del_join_way";

/// 客户群 opengid 转换。
pub const opengidToChatIDURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/opengid_to_chatid";

/// 分配在职成员的客户。
pub const transferCustomerURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/transfer_customer";

/// 查询在职客户接替状态。
pub const transferResultURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/transfer_result";

/// 分配在职成员的客户群。
pub const groupChatOnJobTransferURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/onjob_transfer";

/// 获取待分配的离职成员列表。
pub const getUnassignedListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_unassigned_list";

/// 分配离职成员的客户。
pub const resignedTransferCustomerURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/resigned/transfer_customer";

/// 查询离职客户接替状态。
pub const resignedTransferResultURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/resigned/transfer_result";

/// 分配离职成员的客户群。
pub const groupChatTransferURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/transfer";

/// 发送新客户欢迎语。
pub const sendWelcomeMsgURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/send_welcome_msg";

/// 添加入群欢迎语素材。
pub const addGroupWelcomeTemplateURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/group_welcome_template/add";

/// 编辑入群欢迎语素材。
pub const editGroupWelcomeTemplateURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/group_welcome_template/edit";

/// 获取入群欢迎语素材。
pub const getGroupWelcomeTemplateURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/group_welcome_template/get";

/// 删除入群欢迎语素材。
pub const delGroupWelcomeTemplateURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/group_welcome_template/del";

/// 创建企业群发。
pub const addMsgTemplateURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_msg_template";

/// 获取群发记录列表。
pub const getGroupMsgListV2URL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_groupmsg_list_v2";

/// 获取群发成员发送任务列表。
pub const getGroupMsgTaskURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_groupmsg_task";

/// 获取企业群发成员执行结果。
pub const getGroupMsgSendResultURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_groupmsg_send_result";

/// 提醒成员群发。
pub const remindGroupMsgSendURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/remind_groupmsg_send";

/// 停止企业群发。
pub const cancelGroupMsgSendURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/cancel_groupmsg_send";

/// 获取「联系客户统计」数据。
pub const getUserBehaviorDataURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_user_behavior_data";

/// 获取「群聊数据统计」数据（按群主聚合）。
pub const groupChatStatURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/statistic";

/// 获取「群聊数据统计」数据（按自然日聚合）。
pub const groupChatStatByDayURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/statistic_group_by_day";

/// 客户联系管理规则组接口前缀（`customer_strategy/*`）。
pub const customerStrategyURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_strategy";

/// 朋友圈管理规则组接口前缀（`moment_strategy/*`）。
pub const momentStrategyURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/moment_strategy";

/// 创建发表任务（企业朋友圈）。
pub const addMomentTaskURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_moment_task";

/// 获取任务创建结果（企业朋友圈），需附加 `&jobid=` 查询参数。
pub const getMomentTaskResultURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_task_result";

/// 停止发表企业朋友圈。
pub const cancelMomentTaskURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/cancel_moment_task";

/// 获取企业全部的发表列表（企业朋友圈）。
pub const getMomentListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_list";

/// 获取客户朋友圈企业发表的列表。
pub const getMomentTaskURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_task";

/// 获取客户朋友圈发表时选择的可见范围。
pub const getMomentCustomerListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_customer_list";

/// 获取客户朋友圈发表后的可见客户列表。
pub const getMomentSendResultURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_send_result";

/// 获取客户朋友圈的互动数据。
pub const getMomentCommentsURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_comments";

/// 获取企业标签库。
pub const getCropTagListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_corp_tag_list";

/// 添加企业客户标签。
pub const addCorpTagURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_corp_tag";

/// 修改企业客户标签。
pub const editCorpTagURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/edit_corp_tag";

/// 删除企业客户标签。
pub const delCorpTagURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/del_corp_tag";

/// 为客户打上、删除标签。
pub const markTagURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/mark_tag";

/// 获取指定规则组下的企业客户标签。
pub const getStrategyTagListURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_strategy_tag_list";

/// 为指定规则组创建企业客户标签。
pub const addStrategyTagURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_strategy_tag";

/// 编辑指定规则组下的企业客户标签。
pub const editStrategyTagURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/edit_strategy_tag";

/// 删除指定规则组下的企业客户标签。
pub const delStrategyTagURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/del_strategy_tag";

/// 获客助手接口前缀（`customer_acquisition/*` 挂在其下）。
pub const customerAcquisitionURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition";

/// 查询获客助手剩余使用量。
pub const customerAcquisitionQuotaURL = "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition_quota";

// ─────────────────────────────────────────────────────────────────────────────
// 响应 / 数据结构
// ─────────────────────────────────────────────────────────────────────────────

/// `GetExternalContactList` 响应。
pub const ExternalUserListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 客户 external_userid 列表。
    external_userid: []const []const u8 = &.{},
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
    /// 外部联系人的自定义展示信息（文本 / 网页 / 小程序属性）。
    external_profile: ExternalProfile = .{},
};

/// 外部联系人的自定义展示信息，可包含多个字段、多种类型
/// （文本、网页、小程序），对应 `_ref/wechat` 的 `ExternalProfile`。
pub const ExternalProfile = struct {
    external_corp_name: []const u8 = "",
    /// 须从企业绑定到企业微信的视频号中选择。
    wechat_channels: WechatChannels = .{},
    external_attr: []ExternalAttr = &.{},
};

/// 视频号属性（external_profile 内嵌）。
pub const WechatChannels = struct {
    nickname: []const u8 = "",
    status: i64 = 0,
};

/// external_attr 单条属性，目前支持文本、网页、小程序三种类型。
/// 对应 Go 侧三类可选指针字段，这里以「三类字段都给默认值」的平铺
/// struct 表示，按 `type` 判别有效字段。
pub const ExternalAttr = struct {
    /// 属性类型：0=文本，1=网页，2=小程序。
    type: i64 = 0,
    name: []const u8 = "",
    text: Text = .{},
    web: Web = .{},
    miniprogram: MiniProgram = .{},
};

/// 文本类型属性值。
pub const Text = struct {
    value: []const u8 = "",
};

/// 网页类型属性值。
pub const Web = struct {
    url: []const u8 = "",
    title: []const u8 = "",
};

/// 小程序类型属性值。
pub const MiniProgram = struct {
    appid: []const u8 = "",
    pagepath: []const u8 = "",
    title: []const u8 = "",
};

/// 跟进人（指企业内部用户）。
pub const FollowUser = struct {
    userid: []const u8 = "",
    remark: []const u8 = "",
    description: []const u8 = "",
    createtime: i64 = 0,
    /// 已绑定在外部联系人上的标签。
    tags: []Tag = &.{},
    remark_corp_name: []const u8 = "",
    /// 备注的手机号。
    remark_mobiles: []const []const u8 = &.{},
    oper_userid: []const u8 = "",
    add_way: i64 = 0,
    /// 视频号添加的场景。
    wechat_channels: WechatChannel = .{},
    state: []const u8 = "",
};

/// 已绑定在外部联系人的标签。
pub const Tag = struct {
    group_name: []const u8 = "",
    tag_name: []const u8 = "",
    type: i64 = 0,
    tag_id: []const u8 = "",
};

/// 视频号添加的场景。
pub const WechatChannel = struct {
    nickname: []const u8 = "",
    source: i64 = 0,
};

/// `GetExternalContact` 响应。
pub const ExternalUserDetailResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    external_contact: ExternalUser = .{},
    follow_user: []FollowUser = &.{},
    next_cursor: []const u8 = "",
};

/// 仅含 errcode/errmsg 的通用响应（更新、删除等写接口）。
pub const CommonErrorResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// contact_way —「联系我」配置
// ─────────────────────────────────────────────────────────────────────────────

/// 结束语文本。
pub const ConclusionsText = struct {
    content: []const u8 = "",
};

/// 结束语图片（请求侧）。
pub const ConclusionsImageRequest = struct {
    media_id: []const u8 = "",
};

/// 结束语链接。
pub const ConclusionsLink = struct {
    title: []const u8 = "",
    picurl: []const u8 = "",
    desc: []const u8 = "",
    url: []const u8 = "",
};

/// 结束语小程序。
pub const ConclusionsMiniProgram = struct {
    title: []const u8 = "",
    pic_media_id: []const u8 = "",
    appid: []const u8 = "",
    page: []const u8 = "",
};

/// 结束语请求（add / update 共用）。
pub const ConclusionsRequest = struct {
    text: ConclusionsText = .{},
    image: ConclusionsImageRequest = .{},
    link: ConclusionsLink = .{},
    miniprogram: ConclusionsMiniProgram = .{},
};

/// 结束语图片（响应侧，返回图片 URL）。
pub const ConclusionsImageResponse = struct {
    pic_url: []const u8 = "",
};

/// 结束语响应（get 返回）。
pub const ConclusionsResponse = struct {
    text: ConclusionsText = .{},
    image: ConclusionsImageResponse = .{},
    link: ConclusionsLink = .{},
    miniprogram: ConclusionsMiniProgram = .{},
};

/// `AddContactWay` 请求。
pub const AddContactWayRequest = struct {
    type: i64 = 0,
    scene: i64 = 0,
    style: i64 = 0,
    remark: []const u8 = "",
    skip_verify: bool = false,
    state: []const u8 = "",
    user: []const []const u8 = &.{},
    party: []const i64 = &.{},
    is_temp: bool = false,
    expires_in: i64 = 0,
    chat_expires_in: i64 = 0,
    unionid: []const u8 = "",
    is_exclusive: bool = false,
    mark_source: bool = false,
    conclusions: ConclusionsRequest = .{},
};

/// `AddContactWay` 响应。
pub const AddContactWayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    config_id: []const u8 = "",
    qr_code: []const u8 = "",
};

/// `GetContactWay` 请求。
pub const GetContactWayRequest = struct {
    config_id: []const u8 = "",
};

/// 「联系我」配置详情。
pub const ContactWay = struct {
    config_id: []const u8 = "",
    type: i64 = 0,
    scene: i64 = 0,
    style: i64 = 0,
    remark: []const u8 = "",
    skip_verify: bool = false,
    state: []const u8 = "",
    qr_code: []const u8 = "",
    user: []const []const u8 = &.{},
    party: []const i64 = &.{},
    is_temp: bool = false,
    expires_in: i64 = 0,
    chat_expires_in: i64 = 0,
    unionid: []const u8 = "",
    mark_source: bool = false,
    conclusions: ConclusionsResponse = .{},
};

/// `GetContactWay` 响应。
pub const GetContactWayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    contact_way: ContactWay = .{},
};

/// `UpdateContactWay` 请求。
pub const UpdateContactWayRequest = struct {
    config_id: []const u8 = "",
    remark: []const u8 = "",
    skip_verify: bool = false,
    style: i64 = 0,
    state: []const u8 = "",
    user: []const []const u8 = &.{},
    party: []const i64 = &.{},
    expires_in: i64 = 0,
    chat_expires_in: i64 = 0,
    unionid: []const u8 = "",
    mark_source: bool = false,
    conclusions: ConclusionsRequest = .{},
};

/// `ListContactWay` 请求。
pub const ListContactWayRequest = struct {
    start_time: i64 = 0,
    end_time: i64 = 0,
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// `ListContactWay` 列表条目（仅 config_id）。
pub const ContactWayForList = struct {
    config_id: []const u8 = "",
};

/// `ListContactWay` 响应。
pub const ListContactWayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    contact_way: []ContactWayForList = &.{},
    next_cursor: []const u8 = "",
};

/// `DelContactWay` 请求。
pub const DelContactWayRequest = struct {
    config_id: []const u8 = "",
};

/// `CloseTempChat` 请求。
pub const CloseTempChatRequest = struct {
    userid: []const u8 = "",
    external_userid: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// groupchat — 客户群
// ─────────────────────────────────────────────────────────────────────────────

/// 群主过滤。
pub const OwnerFilter = struct {
    userid_list: []const []const u8 = &.{},
};

/// `GetGroupChatList` 请求。
pub const GroupChatListRequest = struct {
    status_filter: i64 = 0,
    owner_filter: OwnerFilter = .{},
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// 客户群列表条目。
pub const GroupChatListItem = struct {
    chat_id: []const u8 = "",
    status: i64 = 0,
};

/// `GetGroupChatList` 响应。
pub const GroupChatListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    group_chat_list: []GroupChatListItem = &.{},
    next_cursor: []const u8 = "",
};

/// `GetGroupChatDetail` 请求。
pub const GroupChatDetailRequest = struct {
    chat_id: []const u8 = "",
    need_name: i64 = 0,
};

/// 邀请者。
pub const Invitor = struct {
    userid: []const u8 = "",
};

/// 群成员。
pub const GroupChatMember = struct {
    userid: []const u8 = "",
    /// 成员类型：1-企业成员，2-外部联系人。
    type: i64 = 0,
    join_time: i64 = 0,
    join_scene: i64 = 0,
    invitor: Invitor = .{},
    group_nickname: []const u8 = "",
    name: []const u8 = "",
    unionid: []const u8 = "",
    state: []const u8 = "",
};

/// 群管理员。
pub const GroupChatAdmin = struct {
    userid: []const u8 = "",
};

/// 客户群详情。
pub const GroupChat = struct {
    chat_id: []const u8 = "",
    name: []const u8 = "",
    owner: []const u8 = "",
    create_time: i64 = 0,
    notice: []const u8 = "",
    member_list: []GroupChatMember = &.{},
    admin_list: []GroupChatAdmin = &.{},
    member_version: []const u8 = "",
};

/// `GetGroupChatDetail` 响应。
pub const GroupChatDetailResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    group_chat: GroupChat = .{},
};

/// `OpengIDToChatID` 请求。
pub const OpengIDToChatIDRequest = struct {
    opengid: []const u8 = "",
};

/// `OpengIDToChatID` 响应。
pub const OpengIDToChatIDResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    chat_id: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// join_way — 客户群进群方式
// ─────────────────────────────────────────────────────────────────────────────

/// `AddJoinWay` 请求。
pub const AddJoinWayRequest = struct {
    /// 1-群的小程序插件，2-群的二维码插件。
    scene: i64 = 0,
    remark: []const u8 = "",
    auto_create_room: i64 = 0,
    room_base_name: []const u8 = "",
    room_base_id: i64 = 0,
    chat_id_list: []const []const u8 = &.{},
    state: []const u8 = "",
    mark_source: bool = false,
};

/// `AddJoinWay` 响应。
pub const AddJoinWayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    config_id: []const u8 = "",
};

/// `GetJoinWay` / `DelJoinWay` 请求。
pub const JoinWayConfigRequest = struct {
    config_id: []const u8 = "",
};

/// 进群方式配置。
pub const JoinWay = struct {
    config_id: []const u8 = "",
    scene: i64 = 0,
    remark: []const u8 = "",
    auto_create_room: i64 = 0,
    room_base_name: []const u8 = "",
    room_base_id: i64 = 0,
    chat_id_list: []const []const u8 = &.{},
    qr_code: []const u8 = "",
    state: []const u8 = "",
    mark_source: bool = false,
};

/// `GetJoinWay` 响应。
pub const GetJoinWayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    join_way: JoinWay = .{},
};

/// `UpdateJoinWay` 请求。
pub const UpdateJoinWayRequest = struct {
    config_id: []const u8 = "",
    scene: i64 = 0,
    remark: []const u8 = "",
    auto_create_room: i64 = 0,
    room_base_name: []const u8 = "",
    room_base_id: i64 = 0,
    chat_id_list: []const []const u8 = &.{},
    state: []const u8 = "",
    mark_source: bool = false,
};

// ─────────────────────────────────────────────────────────────────────────────
// transfer — 在职 / 离职继承
// ─────────────────────────────────────────────────────────────────────────────

/// `TransferCustomer` 请求（分配在职成员的客户）。
pub const TransferCustomerRequest = struct {
    handover_userid: []const u8 = "",
    takeover_userid: []const u8 = "",
    external_userid: []const []const u8 = &.{},
    transfer_success_msg: []const u8 = "",
};

/// 客户分配结果条目。
pub const TransferCustomerItem = struct {
    external_userid: []const u8 = "",
    errcode: i64 = 0,
};

/// `TransferCustomer` 响应。
pub const TransferCustomerResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    customer: []TransferCustomerItem = &.{},
};

/// `TransferResult` 请求（查询在职客户接替状态）。
pub const TransferResultRequest = struct {
    handover_userid: []const u8 = "",
    takeover_userid: []const u8 = "",
    cursor: []const u8 = "",
};

/// 客户接替状态条目。
pub const TransferResultItem = struct {
    external_userid: []const u8 = "",
    status: i64 = 0,
    takeover_time: i64 = 0,
};

/// `TransferResult` 响应。
pub const TransferResultResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    customer: []TransferResultItem = &.{},
    next_cursor: []const u8 = "",
};

/// `GroupChatOnJobTransfer` / `GroupChatTransfer` 请求（分配客户群）。
pub const GroupChatTransferRequest = struct {
    chat_id_list: []const []const u8 = &.{},
    new_owner: []const u8 = "",
};

/// 没能成功继承的群。
pub const FailedChat = struct {
    chat_id: []const u8 = "",
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

/// `GroupChatOnJobTransfer` / `GroupChatTransfer` 响应。
pub const GroupChatTransferResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    failed_chat_list: []FailedChat = &.{},
};

/// `GetUnassignedList` 请求。
pub const GetUnassignedListRequest = struct {
    cursor: []const u8 = "",
    page_size: i64 = 0,
};

/// 待分配离职成员信息。
pub const UnassignedListInfo = struct {
    handover_userid: []const u8 = "",
    external_userid: []const u8 = "",
    dimission_time: i64 = 0,
};

/// `GetUnassignedList` 响应。
pub const GetUnassignedListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    info: []UnassignedListInfo = &.{},
    is_last: bool = false,
    next_cursor: []const u8 = "",
};

/// `ResignedTransferCustomer` 请求（分配离职成员的客户）。
pub const ResignedTransferCustomerRequest = struct {
    handover_userid: []const u8 = "",
    takeover_userid: []const u8 = "",
    external_userid: []const []const u8 = &.{},
};

/// `ResignedTransferCustomer` 响应。
pub const ResignedTransferCustomerResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    customer: []TransferCustomerItem = &.{},
};

/// `ResignedTransferResult` 请求（查询离职客户接替状态）。
pub const ResignedTransferResultRequest = struct {
    handover_userid: []const u8 = "",
    takeover_userid: []const u8 = "",
    cursor: []const u8 = "",
};

/// `ResignedTransferResult` 响应。
pub const ResignedTransferResultResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    customer: []TransferResultItem = &.{},
    next_cursor: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// msg — 欢迎语与企业群发
// ─────────────────────────────────────────────────────────────────────────────

/// 文本消息。
pub const MsgText = struct {
    content: []const u8 = "",
};

/// 图片附件。
pub const AttachmentImg = struct {
    media_id: []const u8 = "",
    pic_url: []const u8 = "",
};

/// 图文附件。
pub const AttachmentLink = struct {
    title: []const u8 = "",
    picurl: []const u8 = "",
    desc: []const u8 = "",
    url: []const u8 = "",
};

/// 小程序附件。
pub const AttachmentMiniProgram = struct {
    title: []const u8 = "",
    pic_media_id: []const u8 = "",
    appid: []const u8 = "",
    page: []const u8 = "",
};

/// 视频附件。
pub const AttachmentVideo = struct {
    media_id: []const u8 = "",
};

/// 文件附件。
pub const AttachmentFile = struct {
    media_id: []const u8 = "",
};

/// 群发附件（按 `msgtype` 判别有效字段）。
pub const Attachment = struct {
    msgtype: []const u8 = "",
    image: AttachmentImg = .{},
    link: AttachmentLink = .{},
    miniprogram: AttachmentMiniProgram = .{},
    video: AttachmentVideo = .{},
    file: AttachmentFile = .{},
};

/// 标签组过滤。
pub const TagGroupList = struct {
    tag_list: []const []const u8 = &.{},
};

/// 标签过滤。
pub const TagFilter = struct {
    group_list: []TagGroupList = &.{},
};

/// `AddMsgTemplate` 请求（创建企业群发）。
pub const AddMsgTemplateRequest = struct {
    chat_type: []const u8 = "",
    external_userid: []const []const u8 = &.{},
    sender: []const u8 = "",
    text: MsgText = .{},
    attachments: []const Attachment = &.{},
    allow_select: bool = false,
    chat_id_list: []const []const u8 = &.{},
    tag_filter: TagFilter = .{},
};

/// `AddMsgTemplate` 响应。
pub const AddMsgTemplateResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    fail_list: []const []const u8 = &.{},
    msgid: []const u8 = "",
};

/// `GetGroupMsgListV2` 请求。
pub const GetGroupMsgListV2Request = struct {
    chat_type: []const u8 = "",
    start_time: i64 = 0,
    end_time: i64 = 0,
    creator: []const u8 = "",
    filter_type: i64 = 0,
    limit: i64 = 0,
    cursor: []const u8 = "",
};

/// 群发消息记录。
pub const GroupMsg = struct {
    msgid: []const u8 = "",
    creator: []const u8 = "",
    create_time: i64 = 0,
    create_type: i64 = 0,
    text: MsgText = .{},
    attachments: []const Attachment = &.{},
};

/// `GetGroupMsgListV2` 响应。
pub const GetGroupMsgListV2Response = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    group_msg_list: []GroupMsg = &.{},
};

/// `GetGroupMsgTask` 请求。
pub const GetGroupMsgTaskRequest = struct {
    msgid: []const u8 = "",
    limit: i64 = 0,
    cursor: []const u8 = "",
};

/// 群发成员发送任务。
pub const MsgTask = struct {
    userid: []const u8 = "",
    status: i64 = 0,
    send_time: i64 = 0,
};

/// `GetGroupMsgTask` 响应。
pub const GetGroupMsgTaskResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    task_list: []MsgTask = &.{},
};

/// `GetGroupMsgSendResult` 请求。
pub const GetGroupMsgSendResultRequest = struct {
    msgid: []const u8 = "",
    userid: []const u8 = "",
    limit: i64 = 0,
    cursor: []const u8 = "",
};

/// 群发成员执行结果条目。
pub const MsgSend = struct {
    external_userid: []const u8 = "",
    chat_id: []const u8 = "",
    userid: []const u8 = "",
    status: i64 = 0,
    send_time: i64 = 0,
};

/// `GetGroupMsgSendResult` 响应。
pub const GetGroupMsgSendResultResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    send_list: []MsgSend = &.{},
};

/// `SendWelcomeMsg` 请求（发送新客户欢迎语）。
pub const SendWelcomeMsgRequest = struct {
    welcome_code: []const u8 = "",
    text: MsgText = .{},
    attachments: []const Attachment = &.{},
};

/// `AddGroupWelcomeTemplate` 请求（添加入群欢迎语素材）。
pub const AddGroupWelcomeTemplateRequest = struct {
    text: MsgText = .{},
    image: AttachmentImg = .{},
    link: AttachmentLink = .{},
    miniprogram: AttachmentMiniProgram = .{},
    file: AttachmentFile = .{},
    video: AttachmentVideo = .{},
    agentid: i64 = 0,
    notify: i64 = 0,
};

/// `AddGroupWelcomeTemplate` 响应。
pub const AddGroupWelcomeTemplateResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    template_id: []const u8 = "",
};

/// `EditGroupWelcomeTemplate` 请求。
pub const EditGroupWelcomeTemplateRequest = struct {
    template_id: []const u8 = "",
    text: MsgText = .{},
    image: AttachmentImg = .{},
    link: AttachmentLink = .{},
    miniprogram: AttachmentMiniProgram = .{},
    file: AttachmentFile = .{},
    video: AttachmentVideo = .{},
    agentid: i64 = 0,
};

/// `GetGroupWelcomeTemplate` 请求。
pub const GetGroupWelcomeTemplateRequest = struct {
    template_id: []const u8 = "",
};

/// `GetGroupWelcomeTemplate` 响应。
pub const GetGroupWelcomeTemplateResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    text: MsgText = .{},
    image: AttachmentImg = .{},
    link: AttachmentLink = .{},
    miniprogram: AttachmentMiniProgram = .{},
    file: AttachmentFile = .{},
    video: AttachmentVideo = .{},
};

/// `DelGroupWelcomeTemplate` 请求。
pub const DelGroupWelcomeTemplateRequest = struct {
    template_id: []const u8 = "",
    agentid: i64 = 0,
};

/// `RemindGroupMsgSend` / `CancelGroupMsgSend` 请求。
pub const GroupMsgSendRequest = struct {
    msgid: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// statistic — 联系客户统计
// ─────────────────────────────────────────────────────────────────────────────

/// `GetUserBehaviorData` 请求。
pub const GetUserBehaviorRequest = struct {
    userid: []const []const u8 = &.{},
    partyid: []const i64 = &.{},
    start_time: i64 = 0,
    end_time: i64 = 0,
};

/// 联系客户统计数据。
pub const BehaviorData = struct {
    stat_time: i64 = 0,
    chat_cnt: i64 = 0,
    message_cnt: i64 = 0,
    reply_percentage: f64 = 0,
    avg_reply_time: i64 = 0,
    negative_feedback_cnt: i64 = 0,
    new_apply_cnt: i64 = 0,
    new_contact_cnt: i64 = 0,
};

/// `GetUserBehaviorData` 响应。
pub const GetUserBehaviorResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    behavior_data: []BehaviorData = &.{},
};

/// `GetGroupChatStat` 请求（按群主聚合）。
pub const GetGroupChatStatRequest = struct {
    day_begin_time: i64 = 0,
    day_end_time: i64 = 0,
    owner_filter: OwnerFilter = .{},
    order_by: i64 = 0,
    order_asc: i64 = 0,
    offset: i64 = 0,
    limit: i64 = 0,
};

/// 群聊数据统计条目数据。
pub const GroupChatStatItemData = struct {
    new_chat_cnt: i64 = 0,
    chat_total: i64 = 0,
    chat_has_msg: i64 = 0,
    new_member_cnt: i64 = 0,
    member_total: i64 = 0,
    member_has_msg: i64 = 0,
    msg_total: i64 = 0,
    migrate_trainee_chat_cnt: i64 = 0,
};

/// 群聊数据统计（按群主聚合）条目。
pub const GroupChatStatItem = struct {
    owner: []const u8 = "",
    data: GroupChatStatItemData = .{},
};

/// `GetGroupChatStat` 响应。
pub const GetGroupChatStatResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total: i64 = 0,
    next_offset: i64 = 0,
    items: []GroupChatStatItem = &.{},
};

/// `GetGroupChatStatByDay` 请求（按自然日聚合）。
pub const GetGroupChatStatByDayRequest = struct {
    day_begin_time: i64 = 0,
    day_end_time: i64 = 0,
    owner_filter: OwnerFilter = .{},
};

/// 群聊数据统计（按自然日聚合）条目。
pub const GetGroupChatStatByDayItem = struct {
    stat_time: i64 = 0,
    data: GroupChatStatItemData = .{},
};

/// `GetGroupChatStatByDay` 响应。
pub const GetGroupChatStatByDayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    items: []GetGroupChatStatByDayItem = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// customer_strategy — 客户联系管理规则
// ─────────────────────────────────────────────────────────────────────────────

/// 规则组权限。
pub const Privilege = struct {
    view_customer_list: bool = false,
    view_customer_data: bool = false,
    view_room_list: bool = false,
    contact_me: bool = false,
    join_room: bool = false,
    share_customer: bool = false,
    oper_resign_customer: bool = false,
    oper_resign_group: bool = false,
    send_customer_msg: bool = false,
    edit_welcome_msg: bool = false,
    view_behavior_data: bool = false,
    view_room_data: bool = false,
    send_group_msg: bool = false,
    room_deduplication: bool = false,
    rapid_reply: bool = false,
    onjob_customer_transfer: bool = false,
    edit_anti_spam_rule: bool = false,
    export_customer_list: bool = false,
    export_customer_data: bool = false,
    export_customer_group_list: bool = false,
    manage_customer_tag: bool = false,
};

/// 规则组管理范围节点。
pub const StrategyRange = struct {
    type: i64 = 0,
    userid: []const u8 = "",
    partyid: i64 = 0,
};

/// `ListCustomerStrategy` 请求。
pub const ListCustomerStrategyRequest = struct {
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// 规则组 ID 条目。
pub const StrategyID = struct {
    strategy_id: i64 = 0,
};

/// `ListCustomerStrategy` 响应。
pub const ListCustomerStrategyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    strategy: []StrategyID = &.{},
    next_cursor: []const u8 = "",
};

/// 规则组。
pub const Strategy = struct {
    strategy_id: i64 = 0,
    parent_id: i64 = 0,
    strategy_name: []const u8 = "",
    create_time: i64 = 0,
    admin_list: []const []const u8 = &.{},
    privilege: Privilege = .{},
};

/// `GetCustomerStrategy` 请求。
pub const GetCustomerStrategyRequest = struct {
    strategy_id: i64 = 0,
};

/// `GetCustomerStrategy` 响应。
pub const GetCustomerStrategyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    strategy: Strategy = .{},
};

/// `GetRangeCustomerStrategy` 请求。
pub const GetRangeCustomerStrategyRequest = struct {
    strategy_id: i64 = 0,
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// `GetRangeCustomerStrategy` 响应。
pub const GetRangeCustomerStrategyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    range: []const StrategyRange = &.{},
    next_cursor: []const u8 = "",
};

/// `CreateCustomerStrategy` 请求。
pub const CreateCustomerStrategyRequest = struct {
    parent_id: i64 = 0,
    strategy_name: []const u8 = "",
    admin_list: []const []const u8 = &.{},
    privilege: Privilege = .{},
    range: []const StrategyRange = &.{},
};

/// `CreateCustomerStrategy` 响应。
pub const CreateCustomerStrategyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    strategy_id: i64 = 0,
};

/// `EditCustomerStrategy` 请求。
pub const EditCustomerStrategyRequest = struct {
    strategy_id: i64 = 0,
    strategy_name: []const u8 = "",
    admin_list: []const []const u8 = &.{},
    privilege: Privilege = .{},
    range_add: []const StrategyRange = &.{},
    range_del: []const StrategyRange = &.{},
};

/// `DelCustomerStrategy` 请求。
pub const DelCustomerStrategyRequest = struct {
    strategy_id: i64 = 0,
};

// ─────────────────────────────────────────────────────────────────────────────
// moment — 企业朋友圈
// ─────────────────────────────────────────────────────────────────────────────

/// 发表任务文本。
pub const MomentTaskText = struct {
    content: []const u8 = "",
};

/// 发表任务图片。
pub const MomentTaskImage = struct {
    media_id: []const u8 = "",
};

/// 发表任务视频。
pub const MomentTaskVideo = struct {
    media_id: []const u8 = "",
};

/// 发表任务图文链接。
pub const MomentTaskLink = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    media_id: []const u8 = "",
};

/// 发表任务附件。
pub const MomentTaskAttachment = struct {
    msgtype: []const u8 = "",
    image: MomentTaskImage = .{},
    video: MomentTaskVideo = .{},
    link: MomentTaskLink = .{},
};

/// 发表任务的执行者列表。
pub const MomentSenderList = struct {
    user_list: []const []const u8 = &.{},
    department_list: []const i64 = &.{},
};

/// 可见到该朋友圈的客户标签列表。
pub const MomentExternalContactList = struct {
    tag_list: []const []const u8 = &.{},
};

/// 朋友圈指定的发表范围。
pub const MomentVisibleRange = struct {
    sender_list: MomentSenderList = .{},
    external_contact_list: MomentExternalContactList = .{},
};

/// `AddMomentTask` 请求。
pub const AddMomentTaskRequest = struct {
    text: MomentTaskText = .{},
    attachments: []const MomentTaskAttachment = &.{},
    visible_range: MomentVisibleRange = .{},
};

/// `AddMomentTask` 响应。
pub const AddMomentTaskResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    jobid: []const u8 = "",
};

/// 不合法的执行者列表。
pub const MomentInvalidSenderList = struct {
    user_list: []const []const u8 = &.{},
    department_list: []const i64 = &.{},
};

/// 不合法的可见客户列表。
pub const MomentInvalidExternalContactList = struct {
    tag_list: []const []const u8 = &.{},
};

/// 任务创建结果。
pub const MomentTaskResult = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    moment_id: []const u8 = "",
    invalid_sender_list: MomentInvalidSenderList = .{},
    invalid_external_contact_list: MomentInvalidExternalContactList = .{},
};

/// `GetMomentTaskResult` 响应。
pub const GetMomentTaskResultResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    status: i64 = 0,
    type: []const u8 = "",
    result: MomentTaskResult = .{},
};

/// `CancelMomentTask` 请求。
pub const CancelMomentTaskRequest = struct {
    moment_id: []const u8 = "",
};

/// `GetMomentList` 请求。
pub const GetMomentListRequest = struct {
    start_time: i64 = 0,
    end_time: i64 = 0,
    creator: []const u8 = "",
    filter_type: i64 = 0,
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// 朋友圈文本。
pub const MomentText = struct {
    content: []const u8 = "",
};

/// 朋友圈图片。
pub const MomentImage = struct {
    media_id: []const u8 = "",
};

/// 朋友圈视频。
pub const MomentVideo = struct {
    media_id: []const u8 = "",
    thumb_media_id: []const u8 = "",
};

/// 朋友圈网页链接。
pub const MomentLink = struct {
    title: []const u8 = "",
    url: []const u8 = "",
};

/// 朋友圈地理位置。
pub const MomentLocation = struct {
    latitude: []const u8 = "",
    longitude: []const u8 = "",
    name: []const u8 = "",
};

/// 朋友圈发表条目。
pub const MomentItem = struct {
    moment_id: []const u8 = "",
    creator: []const u8 = "",
    create_time: i64 = 0,
    create_type: i64 = 0,
    visible_type: i64 = 0,
    text: MomentText = .{},
    image: []MomentImage = &.{},
    video: MomentVideo = .{},
    link: MomentLink = .{},
    location: MomentLocation = .{},
};

/// `GetMomentList` 响应。
pub const GetMomentListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    moment_list: []MomentItem = &.{},
};

/// `GetMomentTask` 请求（企业发表的列表）。
pub const GetMomentTaskListRequest = struct {
    moment_id: []const u8 = "",
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// 发表任务条目。
pub const MomentTaskEntry = struct {
    userid: []const u8 = "",
    publish_status: i64 = 0,
};

/// `GetMomentTask` 响应。
pub const GetMomentTaskResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    task_list: []MomentTaskEntry = &.{},
};

/// `GetMomentCustomerList` / `GetMomentSendResult` 请求。
pub const GetMomentCustomerListRequest = struct {
    moment_id: []const u8 = "",
    userid: []const u8 = "",
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// 成员可见客户条目。
pub const MomentCustomer = struct {
    userid: []const u8 = "",
    external_userid: []const u8 = "",
};

/// `GetMomentCustomerList` 响应。
pub const GetMomentCustomerListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    customer_list: []MomentCustomer = &.{},
};

/// 成员发送成功客户条目。
pub const MomentSendCustomer = struct {
    external_userid: []const u8 = "",
};

/// `GetMomentSendResult` 响应。
pub const GetMomentSendResultResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    customer_list: []MomentSendCustomer = &.{},
};

/// `GetMomentComments` 请求。
pub const GetMomentCommentsRequest = struct {
    moment_id: []const u8 = "",
    userid: []const u8 = "",
};

/// 朋友圈评论。
pub const MomentComment = struct {
    external_userid: []const u8 = "",
    userid: []const u8 = "",
    create_time: i64 = 0,
};

/// 朋友圈点赞。
pub const MomentLike = struct {
    external_userid: []const u8 = "",
    userid: []const u8 = "",
    create_time: i64 = 0,
};

/// `GetMomentComments` 响应。
pub const GetMomentCommentsResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    comment_list: []MomentComment = &.{},
    like_list: []MomentLike = &.{},
};

/// 朋友圈规则组权限。
pub const MomentPrivilege = struct {
    view_moment_list: bool = false,
    send_moment: bool = false,
    manage_moment_cover_and_sign: bool = false,
};

/// 朋友圈规则组管理范围节点。
pub const MomentStrategyRange = struct {
    type: i64 = 0,
    userid: []const u8 = "",
    partyid: i64 = 0,
};

/// `ListMomentStrategy` 请求。
pub const ListMomentStrategyRequest = struct {
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// 朋友圈规则组 ID 条目。
pub const MomentStrategyID = struct {
    strategy_id: i64 = 0,
};

/// `ListMomentStrategy` 响应。
pub const ListMomentStrategyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    strategy: []MomentStrategyID = &.{},
    next_cursor: []const u8 = "",
};

/// 朋友圈规则组。
pub const MomentStrategy = struct {
    strategy_id: i64 = 0,
    parent_id: i64 = 0,
    strategy_name: []const u8 = "",
    create_time: i64 = 0,
    admin_list: []const []const u8 = &.{},
    privilege: MomentPrivilege = .{},
};

/// `GetMomentStrategy` 请求。
pub const GetMomentStrategyRequest = struct {
    strategy_id: i64 = 0,
};

/// `GetMomentStrategy` 响应。
pub const GetMomentStrategyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    strategy: MomentStrategy = .{},
};

/// `GetRangeMomentStrategy` 请求。
pub const GetRangeMomentStrategyRequest = struct {
    strategy_id: i64 = 0,
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// `GetRangeMomentStrategy` 响应。
pub const GetRangeMomentStrategyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    range: []const MomentStrategyRange = &.{},
    next_cursor: []const u8 = "",
};

/// `CreateMomentStrategy` 请求。
pub const CreateMomentStrategyRequest = struct {
    parent_id: i64 = 0,
    strategy_name: []const u8 = "",
    admin_list: []const []const u8 = &.{},
    privilege: MomentPrivilege = .{},
    range: []const MomentStrategyRange = &.{},
};

/// `CreateMomentStrategy` 响应。
pub const CreateMomentStrategyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    strategy_id: i64 = 0,
};

/// `EditMomentStrategy` 请求。
pub const EditMomentStrategyRequest = struct {
    strategy_id: i64 = 0,
    strategy_name: []const u8 = "",
    admin_list: []const []const u8 = &.{},
    privilege: MomentPrivilege = .{},
    range_add: []const MomentStrategyRange = &.{},
    range_del: []const MomentStrategyRange = &.{},
};

/// `DelMomentStrategy` 请求。
pub const DelMomentStrategyRequest = struct {
    strategy_id: i64 = 0,
};

// ─────────────────────────────────────────────────────────────────────────────
// tag — 企业客户标签
// ─────────────────────────────────────────────────────────────────────────────

/// `GetCropTagList` 请求。
pub const GetCropTagRequest = struct {
    tag_id: []const []const u8 = &.{},
    group_id: []const []const u8 = &.{},
};

/// 企业标签内的子项。
pub const TagGroupTagItem = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    create_time: i64 = 0,
    order: i64 = 0,
    deleted: bool = false,
};

/// 企业标签组。
pub const TagGroup = struct {
    group_id: []const u8 = "",
    group_name: []const u8 = "",
    create_time: i64 = 0,
    group_order: i64 = 0,
    deleted: bool = false,
    tag: []TagGroupTagItem = &.{},
};

/// `GetCropTagList` 响应。
pub const GetCropTagListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    tag_group: []TagGroup = &.{},
};

/// 添加标签子项。
pub const AddCropTagItem = struct {
    name: []const u8 = "",
    order: i64 = 0,
};

/// `AddCropTag` 请求。
pub const AddCropTagRequest = struct {
    group_id: []const u8 = "",
    group_name: []const u8 = "",
    order: i64 = 0,
    tag: []const AddCropTagItem = &.{},
    agentid: i64 = 0,
};

/// `AddCropTag` 响应。
pub const AddCropTagResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    tag_group: TagGroup = .{},
};

/// `EditCropTag` 请求。
pub const EditCropTagRequest = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    order: i64 = 0,
    agent_id: []const u8 = "",
};

/// `DeleteCropTag` 请求。
pub const DeleteCropTagRequest = struct {
    tag_id: []const []const u8 = &.{},
    group_id: []const []const u8 = &.{},
    agent_id: []const u8 = "",
};

/// `MarkTag` 请求。
pub const MarkTagRequest = struct {
    userid: []const u8 = "",
    external_userid: []const u8 = "",
    add_tag: []const []const u8 = &.{},
    remove_tag: []const []const u8 = &.{},
};

/// 规则组下的企业标签。
pub const StrategyTag = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    create_time: i64 = 0,
    order: i64 = 0,
};

/// 规则组下的企业标签组。
pub const StrategyTagGroup = struct {
    group_id: []const u8 = "",
    group_name: []const u8 = "",
    create_time: i64 = 0,
    order: i64 = 0,
    strategy_id: i64 = 0,
    tag: []StrategyTag = &.{},
};

/// `GetStrategyTagList` 请求。
pub const GetStrategyTagListRequest = struct {
    strategy_id: i64 = 0,
    tag_id: []const []const u8 = &.{},
    group_id: []const []const u8 = &.{},
};

/// `GetStrategyTagList` 响应。
pub const GetStrategyTagListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    tag_group: []StrategyTagGroup = &.{},
};

/// 创建策略标签子项。
pub const AddStrategyTagItem = struct {
    name: []const u8 = "",
    order: i64 = 0,
};

/// `AddStrategyTag` 请求。
pub const AddStrategyTagRequest = struct {
    strategy_id: i64 = 0,
    group_id: []const u8 = "",
    group_name: []const u8 = "",
    order: i64 = 0,
    tag: []const AddStrategyTagItem = &.{},
};

/// `AddStrategyTag` 响应标签。
pub const AddStrategyTagResponseItem = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    create_time: i64 = 0,
    order: i64 = 0,
};

/// `AddStrategyTag` 响应标签组。
pub const AddStrategyTagResponseTagGroup = struct {
    group_id: []const u8 = "",
    group_name: []const u8 = "",
    create_time: i64 = 0,
    order: i64 = 0,
    tag: []AddStrategyTagResponseItem = &.{},
};

/// `AddStrategyTag` 响应。
pub const AddStrategyTagResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    tag_group: AddStrategyTagResponseTagGroup = .{},
};

/// `EditStrategyTag` 请求。
pub const EditStrategyTagRequest = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    order: i64 = 0,
};

/// `DelStrategyTag` 请求。
pub const DelStrategyTagRequest = struct {
    tag_id: []const []const u8 = &.{},
    group_id: []const []const u8 = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// customer_acquisition — 获客助手
// ─────────────────────────────────────────────────────────────────────────────

/// `ListLink` 请求。
pub const ListLinkRequest = struct {
    limit: i64 = 0,
    cursor: []const u8 = "",
};

/// `ListLink` 响应。
pub const ListLinkResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    link_id_list: []const []const u8 = &.{},
    next_cursor: []const u8 = "",
};

/// 获客链接。
pub const AcquisitionLink = struct {
    link_id: []const u8 = "",
    link_name: []const u8 = "",
    url: []const u8 = "",
    create_time: i64 = 0,
    skip_verify: bool = false,
    mark_source: bool = false,
};

/// 获客链接使用范围。
pub const CustomerAcquisitionRange = struct {
    user_list: []const []const u8 = &.{},
    department_list: []const i64 = &.{},
};

/// 获客链接优先选项。
pub const CustomerPriorityOption = struct {
    priority_type: i64 = 0,
    priority_userid_list: []const []const u8 = &.{},
};

/// `GetCustomerAcquisition` 请求。
pub const GetCustomerAcquisitionRequest = struct {
    link_id: []const u8 = "",
};

/// `GetCustomerAcquisition` 响应。
pub const GetCustomerAcquisitionResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    link: AcquisitionLink = .{},
    range: CustomerAcquisitionRange = .{},
    priority_option: CustomerPriorityOption = .{},
    skip_verify: bool = false,
};

/// `CreateCustomerAcquisitionLink` 请求。
pub const CreateCustomerAcquisitionLinkRequest = struct {
    link_name: []const u8 = "",
    range: CustomerAcquisitionRange = .{},
    skip_verify: bool = false,
    priority_option: CustomerPriorityOption = .{},
    mark_source: bool = false,
};

/// `CreateCustomerAcquisitionLink` 响应。
pub const CreateCustomerAcquisitionLinkResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    link: AcquisitionLink = .{},
};

/// `UpdateCustomerAcquisitionLink` 请求。
pub const UpdateCustomerAcquisitionLinkRequest = struct {
    link_id: []const u8 = "",
    link_name: []const u8 = "",
    range: CustomerAcquisitionRange = .{},
    skip_verify: bool = false,
    priority_option: CustomerPriorityOption = .{},
    mark_source: bool = false,
};

/// `DeleteCustomerAcquisitionLink` 请求。
pub const DeleteCustomerAcquisitionLinkRequest = struct {
    link_id: []const u8 = "",
};

/// `GetCustomerInfoWithCustomerAcquisitionLink` 请求。
pub const GetCustomerInfoWithLinkRequest = struct {
    link_id: []const u8 = "",
    limit: i64 = 0,
    cursor: []const u8 = "",
};

/// 获客链接添加的客户条目。
pub const AcquisitionCustomer = struct {
    external_userid: []const u8 = "",
    userid: []const u8 = "",
    chat_status: i64 = 0,
    state: []const u8 = "",
};

/// `GetCustomerInfoWithCustomerAcquisitionLink` 响应。
pub const GetCustomerInfoWithLinkResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    customer_list: []AcquisitionCustomer = &.{},
    next_cursor: []const u8 = "",
};

/// 额度条目。
pub const QuotaItem = struct {
    expire_date: i64 = 0,
    balance: i64 = 0,
};

/// `CustomerAcquisitionQuota` 响应。
pub const CustomerAcquisitionQuotaResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total: i64 = 0,
    balance: i64 = 0,
    quota_list: []QuotaItem = &.{},
};

/// `CustomerAcquisitionStatistic` 请求。
pub const CustomerAcquisitionStatisticRequest = struct {
    link_id: []const u8 = "",
    start_time: i64 = 0,
    end_time: i64 = 0,
};

/// `CustomerAcquisitionStatistic` 响应。
pub const CustomerAcquisitionStatisticResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    click_link_customer_cnt: i64 = 0,
    new_customer_cnt: i64 = 0,
};

/// `GetChatInfo` 请求。
pub const GetChatInfoRequest = struct {
    chat_key: []const u8 = "",
};

/// 聊天信息。
pub const ChatInfo = struct {
    recv_msg_cnt: i64 = 0,
    link_id: []const u8 = "",
    state: []const u8 = "",
};

/// `GetChatInfo` 响应。
pub const GetChatInfoResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    userid: []const u8 = "",
    external_userid: []const u8 = "",
    chat_info: ChatInfo = .{},
};

/// `GetPermit` 响应。
pub const GetPermitResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    user_list: []const []const u8 = &.{},
    department_list: []const i64 = &.{},
    tag_list: []const i64 = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// external_user — 批量获取与备注
// ─────────────────────────────────────────────────────────────────────────────

/// `BatchGetExternalUserDetails` 请求。
pub const BatchGetExternalUserDetailsRequest = struct {
    userid_list: []const []const u8 = &.{},
    cursor: []const u8 = "",
    limit: i64 = 0,
};

/// 批量获取的外部联系人信息（`external_profile` 为原始 JSON 字符串）。
pub const ExternalContactInfo = struct {
    external_userid: []const u8 = "",
    name: []const u8 = "",
    position: []const u8 = "",
    avatar: []const u8 = "",
    corp_name: []const u8 = "",
    corp_full_name: []const u8 = "",
    type: i64 = 0,
    gender: i64 = 0,
    unionid: []const u8 = "",
    external_profile: []const u8 = "",
};

/// 批量获取的跟进人信息。
pub const FollowInfo = struct {
    userid: []const u8 = "",
    remark: []const u8 = "",
    description: []const u8 = "",
    createtime: i64 = 0,
    tag_id: []const []const u8 = &.{},
    remark_corp_name: []const u8 = "",
    remark_mobiles: []const []const u8 = &.{},
    oper_userid: []const u8 = "",
    add_way: i64 = 0,
    wechat_channels: WechatChannel = .{},
};

/// 批量获取客户详情条目。
pub const ExternalUserForBatch = struct {
    external_contact: ExternalContactInfo = .{},
    follow_info: FollowInfo = .{},
};

/// `BatchGetExternalUserDetails` 响应。
pub const ExternalUserDetailListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    external_contact_list: []ExternalUserForBatch = &.{},
    next_cursor: []const u8 = "",
};

/// `UpdateUserRemark` 请求。
pub const UpdateUserRemarkRequest = struct {
    userid: []const u8 = "",
    external_userid: []const u8 = "",
    remark: []const u8 = "",
    description: []const u8 = "",
    remark_company: []const u8 = "",
    remark_mobiles: []const []const u8 = &.{},
    remark_pic_mediaid: []const u8 = "",
};

/// `GetFollowUserList` 响应。
pub const FollowUserListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    follow_user: []const []const u8 = &.{},
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
    ) !std.json.Parsed(ExternalUserDetailResponse) {
        return self.getParsed(
            externalContactGetURL,
            "&external_userid={s}&cursor={s}",
            .{ external_userid, next_cursor },
            ExternalUserDetailResponse,
        );
    }

    /// 按员工 `userid` 列出其所有客户的 `external_userid`。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `GetExternalUserList`。
    pub fn getExternalContactList(
        self: *Self,
        userid: []const u8,
    ) !std.json.Parsed(ExternalUserListResponse) {
        return self.getParsed(externalContactListURL, "&userid={s}", .{userid}, ExternalUserListResponse);
    }

    // ── external_user 补充：批量获取 / 备注 / 配置了客户联系的成员 ──

    /// 批量获取客户详情。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `BatchGetExternalUserDetails`。
    pub fn batchGetExternalUserDetails(
        self: *Self,
        req: BatchGetExternalUserDetailsRequest,
    ) !std.json.Parsed(ExternalUserDetailListResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(batchGetExternalUserDetailURL, body, ExternalUserDetailListResponse);
    }

    /// 修改客户备注信息。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `UpdateUserRemark`。
    pub fn updateUserRemark(self: *Self, req: UpdateUserRemarkRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(updateUserRemarkURL, body);
    }

    /// 获取配置了客户联系功能的成员列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/follow_user.go` 的
    /// `GetFollowUserList`。
    pub fn getFollowUserList(self: *Self) !std.json.Parsed(FollowUserListResponse) {
        return self.getParsed(followUserListURL, "", .{}, FollowUserListResponse);
    }

    // ── contact_way —「联系我」配置 ──

    /// 配置客户联系「联系我」方式。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/contact_way.go` 的 `AddContactWay`。
    pub fn addContactWay(self: *Self, req: AddContactWayRequest) !std.json.Parsed(AddContactWayResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(addContactWayURL, body, AddContactWayResponse);
    }

    /// 获取企业已配置的「联系我」方式。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/contact_way.go` 的 `GetContactWay`。
    pub fn getContactWay(self: *Self, req: GetContactWayRequest) !std.json.Parsed(GetContactWayResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getContactWayURL, body, GetContactWayResponse);
    }

    /// 更新企业已配置的「联系我」方式。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/contact_way.go` 的 `UpdateContactWay`。
    pub fn updateContactWay(self: *Self, req: UpdateContactWayRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(updateContactWayURL, body);
    }

    /// 获取企业已配置的「联系我」列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/contact_way.go` 的 `ListContactWay`。
    pub fn listContactWay(self: *Self, req: ListContactWayRequest) !std.json.Parsed(ListContactWayResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(listContactWayURL, body, ListContactWayResponse);
    }

    /// 删除企业已配置的「联系我」方式。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/contact_way.go` 的 `DelContactWay`。
    pub fn delContactWay(self: *Self, req: DelContactWayRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(delContactWayURL, body);
    }

    /// 结束临时会话。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/contact_way.go` 的 `CloseTempChat`。
    pub fn closeTempChat(self: *Self, req: CloseTempChatRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(closeTempChatURL, body);
    }

    // ── groupchat — 客户群 ──

    /// 获取客户群列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/groupchat.go` 的 `GetGroupChatList`。
    pub fn getGroupChatList(self: *Self, req: GroupChatListRequest) !std.json.Parsed(GroupChatListResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(groupChatListURL, body, GroupChatListResponse);
    }

    /// 获取客户群详情。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/groupchat.go` 的 `GetGroupChatDetail`。
    pub fn getGroupChatDetail(self: *Self, req: GroupChatDetailRequest) !std.json.Parsed(GroupChatDetailResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(groupChatGetURL, body, GroupChatDetailResponse);
    }

    /// 客户群 opengid 转换。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/groupchat.go` 的 `OpengIDToChatID`。
    pub fn opengidToChatID(self: *Self, req: OpengIDToChatIDRequest) !std.json.Parsed(OpengIDToChatIDResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(opengidToChatIDURL, body, OpengIDToChatIDResponse);
    }

    // ── join_way — 客户群进群方式 ──

    /// 添加入群方式配置。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/join_way.go` 的 `AddJoinWay`。
    pub fn addJoinWay(self: *Self, req: AddJoinWayRequest) !std.json.Parsed(AddJoinWayResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(addJoinWayURL, body, AddJoinWayResponse);
    }

    /// 获取客户群进群方式配置。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/join_way.go` 的 `GetJoinWay`。
    pub fn getJoinWay(self: *Self, req: JoinWayConfigRequest) !std.json.Parsed(GetJoinWayResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getJoinWayURL, body, GetJoinWayResponse);
    }

    /// 更新客户群进群方式配置。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/join_way.go` 的 `UpdateJoinWay`。
    pub fn updateJoinWay(self: *Self, req: UpdateJoinWayRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(updateJoinWayURL, body);
    }

    /// 删除客户群进群方式配置。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/join_way.go` 的 `DelJoinWay`。
    pub fn delJoinWay(self: *Self, req: JoinWayConfigRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(delJoinWayURL, body);
    }

    // ── transfer — 在职 / 离职继承 ──

    /// 分配在职成员的客户。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/transfer.go` 的 `TransferCustomer`。
    pub fn transferCustomer(self: *Self, req: TransferCustomerRequest) !std.json.Parsed(TransferCustomerResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(transferCustomerURL, body, TransferCustomerResponse);
    }

    /// 查询在职客户接替状态。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/transfer.go` 的 `TransferResult`。
    pub fn transferResult(self: *Self, req: TransferResultRequest) !std.json.Parsed(TransferResultResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(transferResultURL, body, TransferResultResponse);
    }

    /// 分配在职成员的客户群。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/transfer.go` 的 `GroupChatOnJobTransfer`。
    pub fn groupChatOnJobTransfer(self: *Self, req: GroupChatTransferRequest) !std.json.Parsed(GroupChatTransferResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(groupChatOnJobTransferURL, body, GroupChatTransferResponse);
    }

    /// 获取待分配的离职成员列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/transfer.go` 的 `GetUnassignedList`。
    pub fn getUnassignedList(self: *Self, req: GetUnassignedListRequest) !std.json.Parsed(GetUnassignedListResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getUnassignedListURL, body, GetUnassignedListResponse);
    }

    /// 分配离职成员的客户。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/transfer.go` 的 `ResignedTransferCustomer`。
    pub fn resignedTransferCustomer(self: *Self, req: ResignedTransferCustomerRequest) !std.json.Parsed(ResignedTransferCustomerResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(resignedTransferCustomerURL, body, ResignedTransferCustomerResponse);
    }

    /// 查询离职客户接替状态。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/transfer.go` 的 `ResignedTransferResult`。
    pub fn resignedTransferResult(self: *Self, req: ResignedTransferResultRequest) !std.json.Parsed(ResignedTransferResultResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(resignedTransferResultURL, body, ResignedTransferResultResponse);
    }

    /// 分配离职成员的客户群。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/transfer.go` 的 `GroupChatTransfer`。
    pub fn groupChatTransfer(self: *Self, req: GroupChatTransferRequest) !std.json.Parsed(GroupChatTransferResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(groupChatTransferURL, body, GroupChatTransferResponse);
    }

    // ── msg — 欢迎语与企业群发 ──

    /// 发送新客户欢迎语。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `SendWelcomeMsg`。
    pub fn sendWelcomeMsg(self: *Self, req: SendWelcomeMsgRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(sendWelcomeMsgURL, body);
    }

    /// 添加入群欢迎语素材。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `AddGroupWelcomeTemplate`。
    pub fn addGroupWelcomeTemplate(self: *Self, req: AddGroupWelcomeTemplateRequest) !std.json.Parsed(AddGroupWelcomeTemplateResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(addGroupWelcomeTemplateURL, body, AddGroupWelcomeTemplateResponse);
    }

    /// 编辑入群欢迎语素材。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `EditGroupWelcomeTemplate`。
    pub fn editGroupWelcomeTemplate(self: *Self, req: EditGroupWelcomeTemplateRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(editGroupWelcomeTemplateURL, body);
    }

    /// 获取入群欢迎语素材。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `GetGroupWelcomeTemplate`。
    pub fn getGroupWelcomeTemplate(self: *Self, req: GetGroupWelcomeTemplateRequest) !std.json.Parsed(GetGroupWelcomeTemplateResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getGroupWelcomeTemplateURL, body, GetGroupWelcomeTemplateResponse);
    }

    /// 删除入群欢迎语素材。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `DelGroupWelcomeTemplate`。
    pub fn delGroupWelcomeTemplate(self: *Self, req: DelGroupWelcomeTemplateRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(delGroupWelcomeTemplateURL, body);
    }

    /// 创建企业群发。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `AddMsgTemplate`。
    pub fn addMsgTemplate(self: *Self, req: AddMsgTemplateRequest) !std.json.Parsed(AddMsgTemplateResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(addMsgTemplateURL, body, AddMsgTemplateResponse);
    }

    /// 获取群发记录列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `GetGroupMsgListV2`。
    pub fn getGroupMsgListV2(self: *Self, req: GetGroupMsgListV2Request) !std.json.Parsed(GetGroupMsgListV2Response) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getGroupMsgListV2URL, body, GetGroupMsgListV2Response);
    }

    /// 获取群发成员发送任务列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `GetGroupMsgTask`。
    pub fn getGroupMsgTask(self: *Self, req: GetGroupMsgTaskRequest) !std.json.Parsed(GetGroupMsgTaskResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getGroupMsgTaskURL, body, GetGroupMsgTaskResponse);
    }

    /// 获取企业群发成员执行结果。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `GetGroupMsgSendResult`。
    pub fn getGroupMsgSendResult(self: *Self, req: GetGroupMsgSendResultRequest) !std.json.Parsed(GetGroupMsgSendResultResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getGroupMsgSendResultURL, body, GetGroupMsgSendResultResponse);
    }

    /// 提醒成员群发。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `RemindGroupMsgSend`。
    pub fn remindGroupMsgSend(self: *Self, req: GroupMsgSendRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(remindGroupMsgSendURL, body);
    }

    /// 停止企业群发。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/msg.go` 的 `CancelGroupMsgSend`。
    pub fn cancelGroupMsgSend(self: *Self, req: GroupMsgSendRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(cancelGroupMsgSendURL, body);
    }

    // ── statistic — 联系客户统计 ──

    /// 获取「联系客户统计」数据。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/statistic.go` 的 `GetUserBehaviorData`。
    pub fn getUserBehaviorData(self: *Self, req: GetUserBehaviorRequest) !std.json.Parsed(GetUserBehaviorResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getUserBehaviorDataURL, body, GetUserBehaviorResponse);
    }

    /// 获取「群聊数据统计」数据（按群主聚合）。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/statistic.go` 的 `GetGroupChatStat`。
    pub fn getGroupChatStat(self: *Self, req: GetGroupChatStatRequest) !std.json.Parsed(GetGroupChatStatResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(groupChatStatURL, body, GetGroupChatStatResponse);
    }

    /// 获取「群聊数据统计」数据（按自然日聚合）。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/statistic.go` 的 `GetGroupChatStatByDay`。
    pub fn getGroupChatStatByDay(self: *Self, req: GetGroupChatStatByDayRequest) !std.json.Parsed(GetGroupChatStatByDayResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(groupChatStatByDayURL, body, GetGroupChatStatByDayResponse);
    }

    // ── customer_strategy — 客户联系管理规则 ──

    /// 获取规则组列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `ListCustomerStrategy`。
    pub fn listCustomerStrategy(self: *Self, req: ListCustomerStrategyRequest) !std.json.Parsed(ListCustomerStrategyResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerStrategyURL ++ "/list", body, ListCustomerStrategyResponse);
    }

    /// 获取规则组详情。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `GetCustomerStrategy`。
    pub fn getCustomerStrategy(self: *Self, req: GetCustomerStrategyRequest) !std.json.Parsed(GetCustomerStrategyResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerStrategyURL ++ "/get", body, GetCustomerStrategyResponse);
    }

    /// 获取规则组管理范围。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `GetRangeCustomerStrategy`。
    pub fn getRangeCustomerStrategy(self: *Self, req: GetRangeCustomerStrategyRequest) !std.json.Parsed(GetRangeCustomerStrategyResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerStrategyURL ++ "/get_range", body, GetRangeCustomerStrategyResponse);
    }

    /// 创建新的规则组。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `CreateCustomerStrategy`。
    pub fn createCustomerStrategy(self: *Self, req: CreateCustomerStrategyRequest) !std.json.Parsed(CreateCustomerStrategyResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerStrategyURL ++ "/create", body, CreateCustomerStrategyResponse);
    }

    /// 编辑规则组及其管理范围。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `EditCustomerStrategy`。
    pub fn editCustomerStrategy(self: *Self, req: EditCustomerStrategyRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(customerStrategyURL ++ "/edit", body);
    }

    /// 删除规则组。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/external_user.go` 的
    /// `DelCustomerStrategy`。
    pub fn delCustomerStrategy(self: *Self, req: DelCustomerStrategyRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(customerStrategyURL ++ "/del", body);
    }

    // ── moment — 企业朋友圈 ──

    /// 创建发表任务（企业朋友圈）。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `AddMomentTask`。
    pub fn addMomentTask(self: *Self, req: AddMomentTaskRequest) !std.json.Parsed(AddMomentTaskResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(addMomentTaskURL, body, AddMomentTaskResponse);
    }

    /// 获取任务创建结果（企业朋友圈）。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `GetMomentTaskResult`。
    pub fn getMomentTaskResult(self: *Self, jobid: []const u8) !std.json.Parsed(GetMomentTaskResultResponse) {
        return self.getParsed(getMomentTaskResultURL, "&jobid={s}", .{jobid}, GetMomentTaskResultResponse);
    }

    /// 停止发表企业朋友圈。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `CancelMomentTask`。
    pub fn cancelMomentTask(self: *Self, req: CancelMomentTaskRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(cancelMomentTaskURL, body);
    }

    /// 获取企业全部的发表列表（企业朋友圈）。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `GetMomentList`。
    pub fn getMomentList(self: *Self, req: GetMomentListRequest) !std.json.Parsed(GetMomentListResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getMomentListURL, body, GetMomentListResponse);
    }

    /// 获取客户朋友圈企业发表的列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `GetMomentTask`。
    pub fn getMomentTask(self: *Self, req: GetMomentTaskListRequest) !std.json.Parsed(GetMomentTaskResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getMomentTaskURL, body, GetMomentTaskResponse);
    }

    /// 获取客户朋友圈发表时选择的可见范围。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `GetMomentCustomerList`。
    pub fn getMomentCustomerList(self: *Self, req: GetMomentCustomerListRequest) !std.json.Parsed(GetMomentCustomerListResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getMomentCustomerListURL, body, GetMomentCustomerListResponse);
    }

    /// 获取客户朋友圈发表后的可见客户列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `GetMomentSendResult`。
    pub fn getMomentSendResult(self: *Self, req: GetMomentCustomerListRequest) !std.json.Parsed(GetMomentSendResultResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getMomentSendResultURL, body, GetMomentSendResultResponse);
    }

    /// 获取客户朋友圈的互动数据。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `GetMomentComments`。
    pub fn getMomentComments(self: *Self, req: GetMomentCommentsRequest) !std.json.Parsed(GetMomentCommentsResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getMomentCommentsURL, body, GetMomentCommentsResponse);
    }

    /// 获取朋友圈规则组列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `ListMomentStrategy`。
    pub fn listMomentStrategy(self: *Self, req: ListMomentStrategyRequest) !std.json.Parsed(ListMomentStrategyResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(momentStrategyURL ++ "/list", body, ListMomentStrategyResponse);
    }

    /// 获取朋友圈规则组详情。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `GetMomentStrategy`。
    pub fn getMomentStrategy(self: *Self, req: GetMomentStrategyRequest) !std.json.Parsed(GetMomentStrategyResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(momentStrategyURL ++ "/get", body, GetMomentStrategyResponse);
    }

    /// 获取朋友圈规则组管理范围。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `GetRangeMomentStrategy`。
    pub fn getRangeMomentStrategy(self: *Self, req: GetRangeMomentStrategyRequest) !std.json.Parsed(GetRangeMomentStrategyResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(momentStrategyURL ++ "/get_range", body, GetRangeMomentStrategyResponse);
    }

    /// 创建朋友圈规则组。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `CreateMomentStrategy`。
    pub fn createMomentStrategy(self: *Self, req: CreateMomentStrategyRequest) !std.json.Parsed(CreateMomentStrategyResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(momentStrategyURL ++ "/create", body, CreateMomentStrategyResponse);
    }

    /// 编辑朋友圈规则组及其管理范围。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `EditMomentStrategy`。
    pub fn editMomentStrategy(self: *Self, req: EditMomentStrategyRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(momentStrategyURL ++ "/edit", body);
    }

    /// 删除朋友圈规则组。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/moment.go` 的 `DelMomentStrategy`。
    pub fn delMomentStrategy(self: *Self, req: DelMomentStrategyRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(momentStrategyURL ++ "/del", body);
    }

    // ── tag — 企业客户标签 ──

    /// 获取企业标签库。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `GetCropTagList`。
    pub fn getCropTagList(self: *Self, req: GetCropTagRequest) !std.json.Parsed(GetCropTagListResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getCropTagListURL, body, GetCropTagListResponse);
    }

    /// 添加企业客户标签。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `AddCropTag`。
    pub fn addCropTag(self: *Self, req: AddCropTagRequest) !std.json.Parsed(AddCropTagResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(addCorpTagURL, body, AddCropTagResponse);
    }

    /// 修改企业客户标签。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `EditCropTag`。
    pub fn editCropTag(self: *Self, req: EditCropTagRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(editCorpTagURL, body);
    }

    /// 删除企业客户标签。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `DeleteCropTag`。
    pub fn deleteCropTag(self: *Self, req: DeleteCropTagRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(delCorpTagURL, body);
    }

    /// 为客户打上、删除标签。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `MarkTag`。
    pub fn markTag(self: *Self, req: MarkTagRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(markTagURL, body);
    }

    /// 获取指定规则组下的企业客户标签。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `GetStrategyTagList`。
    pub fn getStrategyTagList(self: *Self, req: GetStrategyTagListRequest) !std.json.Parsed(GetStrategyTagListResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(getStrategyTagListURL, body, GetStrategyTagListResponse);
    }

    /// 为指定规则组创建企业客户标签。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `AddStrategyTag`。
    pub fn addStrategyTag(self: *Self, req: AddStrategyTagRequest) !std.json.Parsed(AddStrategyTagResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(addStrategyTagURL, body, AddStrategyTagResponse);
    }

    /// 编辑指定规则组下的企业客户标签。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `EditStrategyTag`。
    pub fn editStrategyTag(self: *Self, req: EditStrategyTagRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(editStrategyTagURL, body);
    }

    /// 删除指定规则组下的企业客户标签。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/tag.go` 的 `DelStrategyTag`。
    pub fn delStrategyTag(self: *Self, req: DelStrategyTagRequest) !void {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postCommon(delStrategyTagURL, body);
    }

    // ── customer_acquisition — 获客助手 ──

    /// 获取获客链接列表。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的 `ListLink`。
    pub fn listLink(self: *Self, req: ListLinkRequest) !std.json.Parsed(ListLinkResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerAcquisitionURL ++ "/list_link", body, ListLinkResponse);
    }

    /// 获取获客链接详情。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的
    /// `GetCustomerAcquisition`。
    pub fn getCustomerAcquisition(self: *Self, req: GetCustomerAcquisitionRequest) !std.json.Parsed(GetCustomerAcquisitionResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerAcquisitionURL ++ "/get", body, GetCustomerAcquisitionResponse);
    }

    /// 创建获客链接。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的
    /// `CreateCustomerAcquisitionLink`。
    pub fn createCustomerAcquisitionLink(self: *Self, req: CreateCustomerAcquisitionLinkRequest) !std.json.Parsed(CreateCustomerAcquisitionLinkResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerAcquisitionURL ++ "/create_link", body, CreateCustomerAcquisitionLinkResponse);
    }

    /// 编辑获客链接。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的
    /// `UpdateCustomerAcquisitionLink`。
    pub fn updateCustomerAcquisitionLink(self: *Self, req: UpdateCustomerAcquisitionLinkRequest) !std.json.Parsed(CommonErrorResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerAcquisitionURL ++ "/update_link", body, CommonErrorResponse);
    }

    /// 删除获客链接。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的
    /// `DeleteCustomerAcquisitionLink`。
    pub fn deleteCustomerAcquisitionLink(self: *Self, req: DeleteCustomerAcquisitionLinkRequest) !std.json.Parsed(CommonErrorResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerAcquisitionURL ++ "/delete_link", body, CommonErrorResponse);
    }

    /// 获取由获客链接添加的客户信息。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的
    /// `GetCustomerInfoWithCustomerAcquisitionLink`。
    pub fn getCustomerInfoWithLink(self: *Self, req: GetCustomerInfoWithLinkRequest) !std.json.Parsed(GetCustomerInfoWithLinkResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerAcquisitionURL ++ "/customer", body, GetCustomerInfoWithLinkResponse);
    }

    /// 查询获客助手剩余使用量。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的
    /// `CustomerAcquisitionQuota`。
    pub fn customerAcquisitionQuota(self: *Self) !std.json.Parsed(CustomerAcquisitionQuotaResponse) {
        return self.getParsed(customerAcquisitionQuotaURL, "", .{}, CustomerAcquisitionQuotaResponse);
    }

    /// 查询获客链接使用详情。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的
    /// `CustomerAcquisitionStatistic`。
    pub fn customerAcquisitionStatistic(self: *Self, req: CustomerAcquisitionStatisticRequest) !std.json.Parsed(CustomerAcquisitionStatisticResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerAcquisitionURL ++ "/statistic", body, CustomerAcquisitionStatisticResponse);
    }

    /// 获取成员多次收消息详情。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的 `GetChatInfo`。
    pub fn getChatInfo(self: *Self, req: GetChatInfoRequest) !std.json.Parsed(GetChatInfoResponse) {
        const body = try encodeJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed(customerAcquisitionURL ++ "/get_chat_info", body, GetChatInfoResponse);
    }

    /// 获取客户可建联成员。
    ///
    /// 对应 `_ref/wechat/work/externalcontact/customer_acquisition.go` 的 `GetPermit`。
    pub fn getPermit(self: *Self) !std.json.Parsed(GetPermitResponse) {
        return self.getParsed(customerAcquisitionURL ++ "_app/get_permit", "", .{}, GetPermitResponse);
    }

    // ── 内部辅助 ──

    /// GET `url?access_token={token}` + 解析响应（errcode 非 0 抛 `WechatError.ApiError`）。
    ///
    /// 取 token / 拼 URI / 发请求 / errcode 检查（含 token 失效后作废缓存并重试一次）
    /// 统一走 `util/retry.callApi`；`fmt` / `args` 为该接口除 `access_token` 外的
    /// query 参数（如 `"&jobid={s}"` + `.{jobid}`），无附加参数时传 `""` 与 `.{}`。
    fn getParsed(
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

        return parseParsed(self.allocator, body, T);
    }

    /// POST JSON 并解析响应（errcode 非 0 抛 `WechatError.ApiError`）。
    fn postParsed(self: *Self, url: []const u8, body: []const u8, comptime T: type) !std.json.Parsed(T) {
        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            apiNameFromURL(url),
            PostSender{ .url = url, .body = body },
        );
        defer self.allocator.free(resp);

        return parseParsed(self.allocator, resp, T);
    }

    /// POST JSON 并仅校验 errcode（写接口）。
    fn postCommon(self: *Self, url: []const u8, body: []const u8) !void {
        const resp = try util_retry.callApi(
            self.ctx,
            self.allocator,
            apiNameFromURL(url),
            PostSender{ .url = url, .body = body },
        );
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(CommonErrorResponse, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    }
};

/// 取接口 URL 的末段作为 `api_name`（喂给 `util/retry.callApi`，进错误详情），
/// 如 `.../cgi-bin/externalcontact/get` → `get`。
fn apiNameFromURL(url: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[idx + 1 ..];
}

/// `util/retry.callApi` 的 GET sender：`{url}?access_token={token}` 后按 `fmt`
/// 追加 query 参数（`fmt` 为空则不追加），如 `"&jobid={s}"` + `.{jobid}`。
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

/// 解析微信 JSON 响应：`.ignore_unknown_fields` + errcode 检查。
fn parseParsed(allocator: std.mem.Allocator, body: []const u8, comptime T: type) !std.json.Parsed(T) {
    var parsed = std.json.parseFromSlice(T, allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        return util_error.WechatError.DecodeError;
    };
    errdefer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    return parsed;
}

/// 经 `std.json.Stringify` 序列化请求体（字段名与声明顺序一致，自动转义）。
fn encodeJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.write(value);
    return out.toOwnedSlice();
}

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

test "getExternalContact 解析含 tags/remark_mobiles/wechat_channels 的真实响应" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get?access_token=token-abc&external_userid=wmAAA&cursor=", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"external_contact\":{\"external_userid\":\"wmAAA\",\"name\":\"张三\",\"external_profile\":{\"external_corp_name\":\"示例公司\"}},\"follow_user\":[{\"userid\":\"zhangsan\",\"remark\":\"客户A\",\"tags\":[{\"group_name\":\"分组\",\"tag_name\":\"标签\",\"type\":2,\"tag_id\":\"etAAA\"}],\"remark_mobiles\":[\"13800000000\"],\"wechat_channels\":{\"nickname\":\"视频号\",\"source\":2},\"state\":\"st\"}]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getExternalContact("wmAAA", "");
    defer parsed.deinit();

    // 期望值里的切片字段是可变切片（`[]FollowUser` / `[]Tag`），
    // 用局部 var 数组承载，避免 const 字面量无法强转。
    var follow_tags = [_]Tag{
        .{ .group_name = "分组", .tag_name = "标签", .type = 2, .tag_id = "etAAA" },
    };
    var follow_users = [_]FollowUser{
        .{
            .userid = "zhangsan",
            .remark = "客户A",
            .tags = &follow_tags,
            .remark_mobiles = &.{"13800000000"},
            .wechat_channels = .{ .nickname = "视频号", .source = 2 },
            .state = "st",
        },
    };

    // 整体比较：一次覆盖 ExternalUserDetailResponse 全部字段
    // （响应里未下发的字段须保持默认值，如 follow_user[0].description / add_way）。
    try std.testing.expectEqualDeep(ExternalUserDetailResponse{
        .errmsg = "ok",
        .external_contact = .{
            .external_userid = "wmAAA",
            .name = "张三",
            .external_profile = .{ .external_corp_name = "示例公司" },
        },
        .follow_user = &follow_users,
    }, parsed.value);
}

test "getExternalContact 解析 external_profile 含三类 external_attr" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get?access_token=token-abc&external_userid=wmCorp&cursor=", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"external_contact\":{\"external_userid\":\"wmCorp\",\"name\":\"企业客户\",\"external_profile\":{\"external_corp_name\":\"示例公司\",\"wechat_channels\":{\"nickname\":\"绑定视频号\",\"status\":1},\"external_attr\":[{\"type\":0,\"name\":\"文本属性\",\"text\":{\"value\":\"文本值\"}},{\"type\":1,\"name\":\"网页属性\",\"web\":{\"url\":\"https://example.com\",\"title\":\"网页标题\"}},{\"type\":2,\"name\":\"小程序属性\",\"miniprogram\":{\"appid\":\"wx-app\",\"pagepath\":\"pages/index\",\"title\":\"小程序标题\"}}]}},\"follow_user\":[{\"userid\":\"lisi\"}]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getExternalContact("wmCorp", "");
    defer parsed.deinit();

    // 期望值里的切片字段是可变切片（`[]ExternalAttr` / `[]FollowUser`），
    // 用局部 var 数组承载，避免 const 字面量无法强转。
    var attrs = [_]ExternalAttr{
        .{ .type = 0, .name = "文本属性", .text = .{ .value = "文本值" } },
        .{ .type = 1, .name = "网页属性", .web = .{ .url = "https://example.com", .title = "网页标题" } },
        .{
            .type = 2,
            .name = "小程序属性",
            .miniprogram = .{ .appid = "wx-app", .pagepath = "pages/index", .title = "小程序标题" },
        },
    };
    var follow_users = [_]FollowUser{.{ .userid = "lisi" }};

    // 整体比较：一次覆盖 ExternalUserDetailResponse 全部字段——三类 external_attr
    // 各自的未用分支（text/web/miniprogram）也一并断言为默认值。
    try std.testing.expectEqualDeep(ExternalUserDetailResponse{
        .errmsg = "ok",
        .external_contact = .{
            .external_userid = "wmCorp",
            .name = "企业客户",
            .external_profile = .{
                .external_corp_name = "示例公司",
                .wechat_channels = .{ .nickname = "绑定视频号", .status = 1 },
                .external_attr = &attrs,
            },
        },
        .follow_user = &follow_users,
    }, parsed.value);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：记录请求 body 的 transport
// ─────────────────────────────────────────────────────────────────────────────

/// 包装 `MockTransport` 并记录每次请求的 payload，供测试断言请求体。
const RecordingTransport = struct {
    inner: *util_http.MockTransport,
    allocator: std.mem.Allocator,
    payloads: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator, inner: *util_http.MockTransport) RecordingTransport {
        return .{ .inner = inner, .allocator = allocator, .payloads = .empty };
    }

    fn deinit(self: *RecordingTransport) void {
        for (self.payloads.items) |p| self.allocator.free(p);
        self.payloads.deinit(self.allocator);
    }

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        const self: *RecordingTransport = @ptrCast(@alignCast(ctx));
        try self.payloads.append(self.allocator, try self.allocator.dupe(u8, payload));
        return util_http.MockTransport.dispatch(self.inner, allocator, uri, method, payload, content_type);
    }
};

fn installRecording(allocator: std.mem.Allocator, rt: *RecordingTransport) void {
    const client = util_http.getDefaultClient(allocator);
    client.setTransport(RecordingTransport.dispatch, @ptrCast(rt));
}

fn uninstallRecording() void {
    // 不依赖「用别的 allocator 再取一次指针」的宽容语义：直接销毁线程局部实例，
    // 注入的 transport 随实例一起消失（下次 getDefaultClient 会重新初始化）。
    util_http.deinitDefaultClient();
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：external_user 补充（批量获取 / 备注 / 配置了客户联系的成员）
// ─────────────────────────────────────────────────────────────────────────────

test "batchGetExternalUserDetails 批量获取客户详情" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/batch/get_by_user?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"external_contact_list\":[{\"external_contact\":{\"external_userid\":\"wmAAA\",\"name\":\"张三\",\"type\":1},\"follow_info\":{\"userid\":\"zhangsan\",\"remark\":\"客户A\",\"tag_id\":[\"et1\"],\"remark_mobiles\":[\"13800000000\"],\"add_way\":3}}],\"next_cursor\":\"CURS\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.batchGetExternalUserDetails(.{ .userid_list = &.{"zhangsan"}, .cursor = "", .limit = 100 });
    defer parsed.deinit();

    // 期望值里的切片字段是可变切片（`[]ExternalUserForBatch` / `[][]const u8`），
    // 用局部 var 数组承载，避免 const 字面量无法强转。
    var tag_ids = [_][]const u8{"et1"};
    var items = [_]ExternalUserForBatch{
        .{
            .external_contact = .{ .external_userid = "wmAAA", .name = "张三", .type = 1 },
            .follow_info = .{
                .userid = "zhangsan",
                .remark = "客户A",
                .tag_id = &tag_ids,
                .remark_mobiles = &.{"13800000000"},
                .add_way = 3,
            },
        },
    };
    // 整体比较：一次覆盖响应全部字段（含单个条目内 external_profile 原文、
    // follow_info 未下发字段的默认值）。
    try std.testing.expectEqualDeep(ExternalUserDetailListResponse{
        .errmsg = "ok",
        .external_contact_list = &items,
        .next_cursor = "CURS",
    }, parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"userid_list\":[\"zhangsan\"]") != null);
}

test "updateUserRemark 修改客户备注" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/remark?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.updateUserRemark(.{
        .userid = "zhangsan",
        .external_userid = "wmAAA",
        .remark = "备注\"引号\"",
        .description = "desc",
        .remark_company = "公司",
        .remark_mobiles = &.{"13800000000"},
        .remark_pic_mediaid = "",
    });

    try std.testing.expectEqual(@as(usize, 1), rt.payloads.items.len);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"remark\":\"备注\\\"引号\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"remark_mobiles\":[\"13800000000\"]") != null);
}

test "getFollowUserList 获取配置了客户联系功能的成员列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_follow_user_list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"follow_user\":[\"zhangsan\",\"lisi\"]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getFollowUserList();
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.follow_user.len);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.follow_user[0]);
    try std.testing.expectEqualStrings("lisi", parsed.value.follow_user[1]);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：contact_way —「联系我」配置
// ─────────────────────────────────────────────────────────────────────────────

test "addContactWay 配置联系我方式" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_contact_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"config_id\":\"42\",\"qr_code\":\"https://qr.example.com\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.addContactWay(.{
        .type = 1,
        .scene = 1,
        .style = 1,
        .remark = "渠道A",
        .skip_verify = true,
        .state = "state1",
        .user = &.{"zhangsan"},
        .party = &.{2},
        .conclusions = .{ .text = .{ .content = "欢迎语" } },
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("42", parsed.value.config_id);
    try std.testing.expectEqualStrings("https://qr.example.com", parsed.value.qr_code);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"skip_verify\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"user\":[\"zhangsan\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"party\":[2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"conclusions\":{\"text\":{\"content\":\"欢迎语\"}") != null);
}

test "getContactWay 获取联系我方式" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_contact_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"contact_way\":{\"config_id\":\"42\",\"type\":1,\"scene\":2,\"style\":3,\"remark\":\"渠道A\",\"skip_verify\":true,\"state\":\"st\",\"qr_code\":\"qr\",\"user\":[\"zhangsan\"],\"party\":[2],\"expires_in\":86400,\"unionid\":\"uni\",\"mark_source\":true,\"conclusions\":{\"text\":{\"content\":\"欢迎\"},\"image\":{\"pic_url\":\"https://pic\"}}}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getContactWay(.{ .config_id = "42" });
    defer parsed.deinit();

    const cw = parsed.value.contact_way;
    try std.testing.expectEqualStrings("42", cw.config_id);
    try std.testing.expectEqual(@as(i64, 2), cw.scene);
    try std.testing.expectEqual(@as(i64, 86400), cw.expires_in);
    try std.testing.expectEqualStrings("zhangsan", cw.user[0]);
    try std.testing.expectEqual(@as(i64, 2), cw.party[0]);
    try std.testing.expectEqualStrings("欢迎", cw.conclusions.text.content);
    try std.testing.expectEqualStrings("https://pic", cw.conclusions.image.pic_url);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"config_id\":\"42\"") != null);
}

test "updateContactWay 更新联系我方式" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/update_contact_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.updateContactWay(.{
        .config_id = "42",
        .remark = "新备注",
        .skip_verify = false,
        .style = 2,
        .state = "",
        .user = &.{"lisi"},
        .party = &.{},
    });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"config_id\":\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"remark\":\"新备注\"") != null);
}

test "listContactWay 获取联系我列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/list_contact_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"contact_way\":[{\"config_id\":\"42\"},{\"config_id\":\"43\"}],\"next_cursor\":\"NEXT\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.listContactWay(.{ .start_time = 1600000000, .end_time = 1600086400, .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.contact_way.len);
    try std.testing.expectEqualStrings("43", parsed.value.contact_way[1].config_id);
    try std.testing.expectEqualStrings("NEXT", parsed.value.next_cursor);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"limit\":100") != null);
}

test "delContactWay 删除联系我方式" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/del_contact_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.delContactWay(.{ .config_id = "42" });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"config_id\":\"42\"}"));
}

test "closeTempChat 结束临时会话" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/close_temp_chat?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.closeTempChat(.{ .userid = "zhangsan", .external_userid = "wmAAA" });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"userid\":\"zhangsan\",\"external_userid\":\"wmAAA\"}"));
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：groupchat — 客户群
// ─────────────────────────────────────────────────────────────────────────────

test "getGroupChatList 获取客户群列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"group_chat_list\":[{\"chat_id\":\"wrAAA\",\"status\":0}],\"next_cursor\":\"NC\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getGroupChatList(.{
        .status_filter = 0,
        .owner_filter = .{ .userid_list = &.{"zhangsan"} },
        .cursor = "",
        .limit = 100,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.group_chat_list.len);
    try std.testing.expectEqualStrings("wrAAA", parsed.value.group_chat_list[0].chat_id);
    try std.testing.expectEqualStrings("NC", parsed.value.next_cursor);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"owner_filter\":{\"userid_list\":[\"zhangsan\"]}") != null);
}

test "getGroupChatDetail 获取客户群详情" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/get?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"group_chat\":{\"chat_id\":\"wrAAA\",\"name\":\"客户群\",\"owner\":\"zhangsan\",\"create_time\":1600000000,\"notice\":\"公告\",\"member_list\":[{\"userid\":\"wmEXT\",\"type\":2,\"join_time\":1600000100,\"join_scene\":3,\"invitor\":{\"userid\":\"zhangsan\"},\"group_nickname\":\"昵称\",\"name\":\"名字\",\"unionid\":\"uni\",\"state\":\"st\"}],\"admin_list\":[{\"userid\":\"lisi\"}],\"member_version\":\"mv1\"}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getGroupChatDetail(.{ .chat_id = "wrAAA", .need_name = 1 });
    defer parsed.deinit();

    // 期望值里的成员/管理员列表是可变切片，用局部 var 数组承载。
    var members = [_]GroupChatMember{
        .{
            .userid = "wmEXT",
            .type = 2,
            .join_time = 1600000100,
            .join_scene = 3,
            .invitor = .{ .userid = "zhangsan" },
            .group_nickname = "昵称",
            .name = "名字",
            .unionid = "uni",
            .state = "st",
        },
    };
    var admins = [_]GroupChatAdmin{.{ .userid = "lisi" }};

    // 整体比较：一次覆盖客户群详情的全部字段。
    try std.testing.expectEqualDeep(GroupChatDetailResponse{
        .errmsg = "ok",
        .group_chat = .{
            .chat_id = "wrAAA",
            .name = "客户群",
            .owner = "zhangsan",
            .create_time = 1600000000,
            .notice = "公告",
            .member_list = &members,
            .admin_list = &admins,
            .member_version = "mv1",
        },
    }, parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"need_name\":1") != null);
}

test "opengidToChatID 客户群 opengid 转换" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/opengid_to_chatid?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"chat_id\":\"wrAAA\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.opengidToChatID(.{ .opengid = "ogAAA" });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("wrAAA", parsed.value.chat_id);
    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"opengid\":\"ogAAA\"}"));
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：join_way — 客户群进群方式
// ─────────────────────────────────────────────────────────────────────────────

test "addJoinWay 添加入群方式配置" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/add_join_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"config_id\":\"9\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.addJoinWay(.{
        .scene = 2,
        .remark = "渠道",
        .auto_create_room = 1,
        .room_base_name = "群名",
        .room_base_id = 10,
        .chat_id_list = &.{"wrAAA"},
        .state = "st",
        .mark_source = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("9", parsed.value.config_id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"chat_id_list\":[\"wrAAA\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"mark_source\":true") != null);
}

test "getJoinWay 获取入群方式配置" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/get_join_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"join_way\":{\"config_id\":\"9\",\"scene\":2,\"remark\":\"渠道\",\"auto_create_room\":1,\"room_base_name\":\"群名\",\"room_base_id\":10,\"chat_id_list\":[\"wrAAA\"],\"qr_code\":\"qr\",\"state\":\"st\",\"mark_source\":true}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getJoinWay(.{ .config_id = "9" });
    defer parsed.deinit();

    const jw = parsed.value.join_way;
    try std.testing.expectEqualStrings("9", jw.config_id);
    try std.testing.expectEqual(@as(i64, 1), jw.auto_create_room);
    try std.testing.expectEqualStrings("wrAAA", jw.chat_id_list[0]);
    try std.testing.expectEqualStrings("qr", jw.qr_code);
}

test "updateJoinWay 更新入群方式配置" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/update_join_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.updateJoinWay(.{
        .config_id = "9",
        .scene = 2,
        .remark = "新渠道",
        .auto_create_room = 0,
        .room_base_name = "",
        .room_base_id = 0,
        .chat_id_list = &.{"wrAAA"},
        .state = "",
        .mark_source = false,
    });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"config_id\":\"9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"remark\":\"新渠道\"") != null);
}

test "delJoinWay 删除入群方式配置" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/del_join_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.delJoinWay(.{ .config_id = "9" });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"config_id\":\"9\"}"));
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：transfer — 在职 / 离职继承
// ─────────────────────────────────────────────────────────────────────────────

test "transferCustomer 分配在职成员的客户" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/transfer_customer?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"customer\":[{\"external_userid\":\"wmAAA\",\"errcode\":0},{\"external_userid\":\"wmBBB\",\"errcode\":84061}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.transferCustomer(.{
        .handover_userid = "zhangsan",
        .takeover_userid = "lisi",
        .external_userid = &.{ "wmAAA", "wmBBB" },
        .transfer_success_msg = "继承提示",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.customer.len);
    try std.testing.expectEqualStrings("wmBBB", parsed.value.customer[1].external_userid);
    try std.testing.expectEqual(@as(i64, 84061), parsed.value.customer[1].errcode);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"handover_userid\":\"zhangsan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"external_userid\":[\"wmAAA\",\"wmBBB\"]") != null);
}

test "transferResult 查询在职客户接替状态" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/transfer_result?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"customer\":[{\"external_userid\":\"wmAAA\",\"status\":1,\"takeover_time\":1600000200}],\"next_cursor\":\"\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.transferResult(.{
        .handover_userid = "zhangsan",
        .takeover_userid = "lisi",
        .cursor = "",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.customer.len);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.customer[0].status);
    try std.testing.expectEqual(@as(i64, 1600000200), parsed.value.customer[0].takeover_time);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"takeover_userid\":\"lisi\"") != null);
}

test "groupChatOnJobTransfer 分配在职成员的客户群" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/onjob_transfer?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"failed_chat_list\":[{\"chat_id\":\"wrAAA\",\"errcode\":0,\"errmsg\":\"ok\"}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.groupChatOnJobTransfer(.{
        .chat_id_list = &.{"wrAAA"},
        .new_owner = "lisi",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.failed_chat_list.len);
    try std.testing.expectEqualStrings("wrAAA", parsed.value.failed_chat_list[0].chat_id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"new_owner\":\"lisi\"") != null);
}

test "getUnassignedList 获取待分配的离职成员列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_unassigned_list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"info\":[{\"handover_userid\":\"zhangsan\",\"external_userid\":\"wmAAA\",\"dimission_time\":1600000000}],\"is_last\":true,\"next_cursor\":\"\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getUnassignedList(.{ .cursor = "", .page_size = 100 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.info.len);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.info[0].handover_userid);
    try std.testing.expectEqual(@as(i64, 1600000000), parsed.value.info[0].dimission_time);
    try std.testing.expect(parsed.value.is_last);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"page_size\":100") != null);
}

test "resignedTransferCustomer 分配离职成员的客户" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/resigned/transfer_customer?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"customer\":[{\"external_userid\":\"wmAAA\",\"errcode\":0}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.resignedTransferCustomer(.{
        .handover_userid = "zhangsan",
        .takeover_userid = "lisi",
        .external_userid = &.{"wmAAA"},
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.customer.len);
    try std.testing.expectEqualStrings("wmAAA", parsed.value.customer[0].external_userid);
}

test "resignedTransferResult 查询离职客户接替状态" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/resigned/transfer_result?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"customer\":[{\"external_userid\":\"wmAAA\",\"status\":2,\"takeover_time\":1600000300}],\"next_cursor\":\"NC2\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.resignedTransferResult(.{
        .handover_userid = "zhangsan",
        .takeover_userid = "lisi",
        .cursor = "C1",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 2), parsed.value.customer[0].status);
    try std.testing.expectEqualStrings("NC2", parsed.value.next_cursor);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"cursor\":\"C1\"") != null);
}

test "groupChatTransfer 分配离职成员的客户群" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/transfer?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"failed_chat_list\":[]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.groupChatTransfer(.{
        .chat_id_list = &.{ "wrAAA", "wrBBB" },
        .new_owner = "lisi",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 0), parsed.value.failed_chat_list.len);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"chat_id_list\":[\"wrAAA\",\"wrBBB\"]") != null);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：msg — 欢迎语与企业群发
// ─────────────────────────────────────────────────────────────────────────────

test "sendWelcomeMsg 发送新客户欢迎语" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/send_welcome_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.sendWelcomeMsg(.{
        .welcome_code = "wc",
        .text = .{ .content = "欢迎" },
        .attachments = &.{.{ .msgtype = "image", .image = .{ .media_id = "m1", .pic_url = "" } }},
    });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"welcome_code\":\"wc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"msgtype\":\"image\"") != null);
}

test "addGroupWelcomeTemplate 添加入群欢迎语素材" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/group_welcome_template/add?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"template_id\":\"tpl1\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.addGroupWelcomeTemplate(.{
        .text = .{ .content = "欢迎入群" },
        .image = .{ .media_id = "m1", .pic_url = "" },
        .link = .{},
        .miniprogram = .{},
        .file = .{},
        .video = .{},
        .agentid = 1000,
        .notify = 1,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("tpl1", parsed.value.template_id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"notify\":1") != null);
}

test "editGroupWelcomeTemplate 编辑入群欢迎语素材" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/group_welcome_template/edit?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.editGroupWelcomeTemplate(.{
        .template_id = "tpl1",
        .text = .{ .content = "新欢迎语" },
        .agentid = 1000,
    });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"template_id\":\"tpl1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"text\":{\"content\":\"新欢迎语\"}") != null);
}

test "getGroupWelcomeTemplate 获取入群欢迎语素材" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/group_welcome_template/get?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"text\":{\"content\":\"欢迎入群\"},\"image\":{\"media_id\":\"m1\",\"pic_url\":\"https://pic\"},\"link\":{\"title\":\"t\",\"picurl\":\"p\",\"desc\":\"d\",\"url\":\"u\"}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getGroupWelcomeTemplate(.{ .template_id = "tpl1" });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("欢迎入群", parsed.value.text.content);
    try std.testing.expectEqualStrings("https://pic", parsed.value.image.pic_url);
    try std.testing.expectEqualStrings("t", parsed.value.link.title);
}

test "delGroupWelcomeTemplate 删除入群欢迎语素材" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/group_welcome_template/del?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.delGroupWelcomeTemplate(.{ .template_id = "tpl1", .agentid = 1000 });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"template_id\":\"tpl1\",\"agentid\":1000}"));
}

test "addMsgTemplate 创建企业群发" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_msg_template?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"fail_list\":[],\"msgid\":\"msg1\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.addMsgTemplate(.{
        .chat_type = "single",
        .external_userid = &.{"wmAAA"},
        .sender = "zhangsan",
        .text = .{ .content = "群发文本" },
        .attachments = &.{.{ .msgtype = "link", .link = .{ .title = "标题", .picurl = "p", .desc = "d", .url = "u" } }},
        .allow_select = true,
        .chat_id_list = &.{},
        .tag_filter = .{},
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("msg1", parsed.value.msgid);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.fail_list.len);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"chat_type\":\"single\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"link\":{\"title\":\"标题\",\"picurl\":\"p\",\"desc\":\"d\",\"url\":\"u\"}") != null);
}

test "getGroupMsgListV2 获取群发记录列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_groupmsg_list_v2?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"\",\"group_msg_list\":[{\"msgid\":\"msg1\",\"creator\":\"zhangsan\",\"create_time\":1600000000,\"create_type\":0,\"text\":{\"content\":\"内容\"},\"attachments\":[{\"msgtype\":\"image\",\"image\":{\"media_id\":\"m1\",\"pic_url\":\"p\"}}]}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getGroupMsgListV2(.{
        .chat_type = "single",
        .start_time = 1600000000,
        .end_time = 1600086400,
        .filter_type = 2,
        .limit = 50,
        .cursor = "",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.group_msg_list.len);
    const gm = parsed.value.group_msg_list[0];
    try std.testing.expectEqualStrings("msg1", gm.msgid);
    try std.testing.expectEqualStrings("内容", gm.text.content);
    try std.testing.expectEqualStrings("m1", gm.attachments[0].image.media_id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"filter_type\":2") != null);
}

test "getGroupMsgTask 获取群发成员发送任务列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_groupmsg_task?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"\",\"task_list\":[{\"userid\":\"zhangsan\",\"status\":1,\"send_time\":1600000000}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getGroupMsgTask(.{ .msgid = "msg1", .limit = 100, .cursor = "" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.task_list.len);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.task_list[0].userid);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.task_list[0].status);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"msgid\":\"msg1\"") != null);
}

test "getGroupMsgSendResult 获取企业群发成员执行结果" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_groupmsg_send_result?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"\",\"send_list\":[{\"external_userid\":\"wmAAA\",\"chat_id\":\"\",\"userid\":\"zhangsan\",\"status\":1,\"send_time\":1600000000}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getGroupMsgSendResult(.{ .msgid = "msg1", .userid = "zhangsan", .limit = 100, .cursor = "" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.send_list.len);
    try std.testing.expectEqualStrings("wmAAA", parsed.value.send_list[0].external_userid);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"userid\":\"zhangsan\"") != null);
}

test "remindGroupMsgSend 提醒成员群发" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/remind_groupmsg_send?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.remindGroupMsgSend(.{ .msgid = "msg1" });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"msgid\":\"msg1\"}"));
}

test "cancelGroupMsgSend 停止企业群发" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/cancel_groupmsg_send?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.cancelGroupMsgSend(.{ .msgid = "msg1" });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"msgid\":\"msg1\"}"));
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：statistic — 联系客户统计
// ─────────────────────────────────────────────────────────────────────────────

test "getUserBehaviorData 获取联系客户统计数据" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_user_behavior_data?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"behavior_data\":[{\"stat_time\":1600000000,\"chat_cnt\":10,\"message_cnt\":100,\"reply_percentage\":0.8,\"avg_reply_time\":30,\"negative_feedback_cnt\":0,\"new_apply_cnt\":5,\"new_contact_cnt\":3}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getUserBehaviorData(.{
        .userid = &.{"zhangsan"},
        .partyid = &.{},
        .start_time = 1600000000,
        .end_time = 1600086400,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.behavior_data.len);
    const bd = parsed.value.behavior_data[0];
    try std.testing.expectEqual(@as(i64, 10), bd.chat_cnt);
    try std.testing.expectEqual(@as(f64, 0.8), bd.reply_percentage);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"userid\":[\"zhangsan\"]") != null);
}

test "getGroupChatStat 获取群聊数据统计（按群主聚合）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/statistic?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1,\"next_offset\":1,\"items\":[{\"owner\":\"zhangsan\",\"data\":{\"new_chat_cnt\":2,\"chat_total\":5,\"chat_has_msg\":4,\"new_member_cnt\":10,\"member_total\":50,\"member_has_msg\":40,\"msg_total\":500,\"migrate_trainee_chat_cnt\":0}}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getGroupChatStat(.{
        .day_begin_time = 1600000000,
        .day_end_time = 1600086400,
        .owner_filter = .{ .userid_list = &.{"zhangsan"} },
        .order_by = 1,
        .order_asc = 0,
        .offset = 0,
        .limit = 100,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1), parsed.value.total);
    try std.testing.expectEqual(@as(i64, 500), parsed.value.items[0].data.msg_total);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.items[0].owner);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"day_begin_time\":1600000000") != null);
}

test "getGroupChatStatByDay 获取群聊数据统计（按自然日聚合）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/groupchat/statistic_group_by_day?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"items\":[{\"stat_time\":1600000000,\"data\":{\"new_chat_cnt\":1,\"chat_total\":3,\"chat_has_msg\":3,\"new_member_cnt\":5,\"member_total\":20,\"member_has_msg\":18,\"msg_total\":200,\"migrate_trainee_chat_cnt\":0}}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getGroupChatStatByDay(.{
        .day_begin_time = 1600000000,
        .day_end_time = 1600086400,
        .owner_filter = .{},
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.items.len);
    try std.testing.expectEqual(@as(i64, 200), parsed.value.items[0].data.msg_total);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"owner_filter\":{\"userid_list\":[]}") != null);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：customer_strategy — 客户联系管理规则
// ─────────────────────────────────────────────────────────────────────────────

test "listCustomerStrategy 获取规则组列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_strategy/list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"strategy\":[{\"strategy_id\":1},{\"strategy_id\":2}],\"next_cursor\":\"NC\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.listCustomerStrategy(.{ .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.strategy.len);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.strategy[1].strategy_id);
    try std.testing.expectEqualStrings("NC", parsed.value.next_cursor);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"limit\":100") != null);
}

test "getCustomerStrategy 获取规则组详情" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_strategy/get?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"strategy\":{\"strategy_id\":1,\"parent_id\":0,\"strategy_name\":\"默认规则\",\"create_time\":1600000000,\"admin_list\":[\"zhangsan\"],\"privilege\":{\"view_customer_list\":true,\"send_customer_msg\":true,\"manage_customer_tag\":false}}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getCustomerStrategy(.{ .strategy_id = 1 });
    defer parsed.deinit();

    const st = parsed.value.strategy;
    try std.testing.expectEqualStrings("默认规则", st.strategy_name);
    try std.testing.expectEqualStrings("zhangsan", st.admin_list[0]);
    try std.testing.expect(st.privilege.view_customer_list);
    try std.testing.expect(st.privilege.send_customer_msg);
    try std.testing.expect(!st.privilege.manage_customer_tag);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"strategy_id\":1") != null);
}

test "getRangeCustomerStrategy 获取规则组管理范围" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_strategy/get_range?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"range\":[{\"type\":1,\"userid\":\"zhangsan\"},{\"type\":2,\"partyid\":5}],\"next_cursor\":\"\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getRangeCustomerStrategy(.{ .strategy_id = 1, .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.range.len);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.range[0].userid);
    try std.testing.expectEqual(@as(i64, 5), parsed.value.range[1].partyid);
}

test "createCustomerStrategy 创建规则组" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_strategy/create?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"strategy_id\":3}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.createCustomerStrategy(.{
        .parent_id = 0,
        .strategy_name = "新规则",
        .admin_list = &.{"zhangsan"},
        .privilege = .{ .view_customer_list = true },
        .range = &.{.{ .type = 1, .userid = "lisi" }},
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 3), parsed.value.strategy_id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"strategy_name\":\"新规则\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"range\":[{\"type\":1,\"userid\":\"lisi\",\"partyid\":0}]") != null);
}

test "editCustomerStrategy 编辑规则组" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_strategy/edit?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.editCustomerStrategy(.{
        .strategy_id = 3,
        .strategy_name = "改名规则",
        .admin_list = &.{},
        .privilege = .{},
        .range_add = &.{},
        .range_del = &.{},
    });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"strategy_id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"range_add\":[]") != null);
}

test "delCustomerStrategy 删除规则组" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_strategy/del?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.delCustomerStrategy(.{ .strategy_id = 3 });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"strategy_id\":3}"));
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：moment — 企业朋友圈
// ─────────────────────────────────────────────────────────────────────────────

test "addMomentTask 创建朋友圈发表任务" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_moment_task?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"jobid\":\"job1\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.addMomentTask(.{
        .text = .{ .content = "朋友圈内容" },
        .attachments = &.{.{ .msgtype = "image", .image = .{ .media_id = "m1" } }},
        .visible_range = .{
            .sender_list = .{ .user_list = &.{"zhangsan"}, .department_list = &.{} },
            .external_contact_list = .{ .tag_list = &.{} },
        },
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("job1", parsed.value.jobid);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"msgtype\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"sender_list\":{\"user_list\":[\"zhangsan\"],\"department_list\":[]}") != null);
}

test "getMomentTaskResult 获取任务创建结果" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_task_result?access_token=token-abc&jobid=job1", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"status\":1,\"type\":\"add_moment_task\",\"result\":{\"errcode\":0,\"errmsg\":\"ok\",\"moment_id\":\"mom1\",\"invalid_sender_list\":{\"user_list\":[],\"department_list\":[]},\"invalid_external_contact_list\":{\"tag_list\":[]}}}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getMomentTaskResult("job1");
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1), parsed.value.status);
    try std.testing.expectEqualStrings("add_moment_task", parsed.value.type);
    try std.testing.expectEqualStrings("mom1", parsed.value.result.moment_id);
}

test "cancelMomentTask 停止发表企业朋友圈" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/cancel_moment_task?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.cancelMomentTask(.{ .moment_id = "mom1" });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"moment_id\":\"mom1\"}"));
}

test "getMomentList 获取企业全部发表列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"\",\"moment_list\":[{\"moment_id\":\"mom1\",\"creator\":\"zhangsan\",\"create_time\":1600000000,\"create_type\":0,\"visible_type\":0,\"text\":{\"content\":\"内容\"},\"image\":[{\"media_id\":\"m1\"}],\"video\":{\"media_id\":\"\",\"thumb_media_id\":\"\"},\"link\":{\"title\":\"\",\"url\":\"\"},\"location\":{\"latitude\":\"\",\"longitude\":\"\",\"name\":\"\"}}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getMomentList(.{
        .start_time = 1600000000,
        .end_time = 1600086400,
        .filter_type = 0,
        .limit = 100,
        .cursor = "",
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.moment_list.len);
    const mi = parsed.value.moment_list[0];
    try std.testing.expectEqualStrings("mom1", mi.moment_id);
    try std.testing.expectEqualStrings("内容", mi.text.content);
    try std.testing.expectEqualStrings("m1", mi.image[0].media_id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"limit\":100") != null);
}

test "getMomentTask 获取企业发表的列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_task?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"\",\"task_list\":[{\"userid\":\"zhangsan\",\"publish_status\":1}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getMomentTask(.{ .moment_id = "mom1", .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.task_list.len);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.task_list[0].publish_status);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"moment_id\":\"mom1\"") != null);
}

test "getMomentCustomerList 获取发表时选择的可见范围" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_customer_list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"\",\"customer_list\":[{\"userid\":\"zhangsan\",\"external_userid\":\"wmAAA\"}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getMomentCustomerList(.{ .moment_id = "mom1", .userid = "zhangsan", .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("wmAAA", parsed.value.customer_list[0].external_userid);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"userid\":\"zhangsan\"") != null);
}

test "getMomentSendResult 获取发表后的可见客户列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_send_result?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"\",\"customer_list\":[{\"external_userid\":\"wmAAA\"}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getMomentSendResult(.{ .moment_id = "mom1", .userid = "zhangsan", .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.customer_list.len);
    try std.testing.expectEqualStrings("wmAAA", parsed.value.customer_list[0].external_userid);
}

test "getMomentComments 获取朋友圈互动数据" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_moment_comments?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"comment_list\":[{\"external_userid\":\"wmAAA\",\"userid\":\"\",\"create_time\":1600000000}],\"like_list\":[{\"external_userid\":\"wmBBB\",\"userid\":\"\",\"create_time\":1600000100}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getMomentComments(.{ .moment_id = "mom1", .userid = "zhangsan" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.comment_list.len);
    try std.testing.expectEqualStrings("wmAAA", parsed.value.comment_list[0].external_userid);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.like_list.len);
    try std.testing.expectEqualStrings("wmBBB", parsed.value.like_list[0].external_userid);
}

test "listMomentStrategy 获取朋友圈规则组列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/moment_strategy/list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"strategy\":[{\"strategy_id\":7}],\"next_cursor\":\"\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.listMomentStrategy(.{ .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 7), parsed.value.strategy[0].strategy_id);
}

test "getMomentStrategy 获取朋友圈规则组详情" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/moment_strategy/get?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"strategy\":{\"strategy_id\":7,\"parent_id\":0,\"strategy_name\":\"朋友圈规则\",\"create_time\":1600000000,\"admin_list\":[\"zhangsan\"],\"privilege\":{\"view_moment_list\":true,\"send_moment\":true,\"manage_moment_cover_and_sign\":false}}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getMomentStrategy(.{ .strategy_id = 7 });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("朋友圈规则", parsed.value.strategy.strategy_name);
    try std.testing.expect(parsed.value.strategy.privilege.send_moment);
}

test "getRangeMomentStrategy 获取朋友圈规则组管理范围" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/moment_strategy/get_range?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"range\":[{\"type\":1,\"userid\":\"zhangsan\"}],\"next_cursor\":\"\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getRangeMomentStrategy(.{ .strategy_id = 7, .cursor = "", .limit = 100 });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.range.len);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.range[0].userid);
}

test "createMomentStrategy 创建朋友圈规则组" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/moment_strategy/create?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"strategy_id\":8}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.createMomentStrategy(.{
        .parent_id = 0,
        .strategy_name = "新朋友圈规则",
        .admin_list = &.{"zhangsan"},
        .privilege = .{ .send_moment = true },
        .range = &.{.{ .type = 1, .userid = "lisi" }},
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 8), parsed.value.strategy_id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"send_moment\":true") != null);
}

test "editMomentStrategy 编辑朋友圈规则组" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/moment_strategy/edit?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.editMomentStrategy(.{
        .strategy_id = 8,
        .strategy_name = "改名",
        .admin_list = &.{},
        .privilege = .{},
        .range_add = &.{},
        .range_del = &.{},
    });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"strategy_id\":8") != null);
}

test "delMomentStrategy 删除朋友圈规则组" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/moment_strategy/del?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.delMomentStrategy(.{ .strategy_id = 8 });

    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"strategy_id\":8}"));
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：tag — 企业客户标签
// ─────────────────────────────────────────────────────────────────────────────

test "getCropTagList 获取企业标签库" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_corp_tag_list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"tag_group\":[{\"group_id\":\"grp1\",\"group_name\":\"分组\",\"create_time\":1600000000,\"group_order\":1,\"deleted\":false,\"tag\":[{\"id\":\"et1\",\"name\":\"标签\",\"create_time\":1600000000,\"order\":1,\"deleted\":false}]}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getCropTagList(.{ .tag_id = &.{}, .group_id = &.{"grp1"} });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.tag_group.len);
    const tg = parsed.value.tag_group[0];
    try std.testing.expectEqualStrings("分组", tg.group_name);
    try std.testing.expectEqual(@as(i64, 1), tg.group_order);
    try std.testing.expectEqualStrings("et1", tg.tag[0].id);
    try std.testing.expect(!tg.tag[0].deleted);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"group_id\":[\"grp1\"]") != null);
}

test "addCropTag 添加企业客户标签" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_corp_tag?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"tag_group\":{\"group_id\":\"grp2\",\"group_name\":\"新分组\",\"create_time\":1600000000,\"group_order\":2,\"deleted\":false,\"tag\":[{\"id\":\"et2\",\"name\":\"新标签\",\"create_time\":1600000000,\"order\":2,\"deleted\":false}]}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.addCropTag(.{
        .group_id = "",
        .group_name = "新分组",
        .order = 2,
        .tag = &.{.{ .name = "新标签", .order = 2 }},
        .agentid = 0,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("grp2", parsed.value.tag_group.group_id);
    try std.testing.expectEqualStrings("新标签", parsed.value.tag_group.tag[0].name);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"tag\":[{\"name\":\"新标签\",\"order\":2}]") != null);
}

test "editCropTag 修改企业客户标签" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/edit_corp_tag?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.editCropTag(.{ .id = "et1", .name = "改名标签", .order = 3, .agent_id = "" });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"id\":\"et1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"name\":\"改名标签\"") != null);
}

test "deleteCropTag 删除企业客户标签" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/del_corp_tag?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.deleteCropTag(.{ .tag_id = &.{"et1"}, .group_id = &.{}, .agent_id = "" });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"tag_id\":[\"et1\"]") != null);
}

test "markTag 为客户打标签" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/mark_tag?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.markTag(.{
        .userid = "zhangsan",
        .external_userid = "wmAAA",
        .add_tag = &.{"et1"},
        .remove_tag = &.{"et2"},
    });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"add_tag\":[\"et1\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"remove_tag\":[\"et2\"]") != null);
}

test "getStrategyTagList 获取规则组下企业客户标签" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get_strategy_tag_list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"tag_group\":[{\"group_id\":\"sg1\",\"group_name\":\"策略分组\",\"create_time\":1600000000,\"order\":1,\"strategy_id\":7,\"tag\":[{\"id\":\"st1\",\"name\":\"策略标签\",\"create_time\":1600000000,\"order\":1}]}]}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getStrategyTagList(.{ .strategy_id = 7, .tag_id = &.{}, .group_id = &.{"sg1"} });
    defer parsed.deinit();

    const tg = parsed.value.tag_group[0];
    try std.testing.expectEqual(@as(i64, 7), tg.strategy_id);
    try std.testing.expectEqualStrings("策略标签", tg.tag[0].name);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"strategy_id\":7") != null);
}

test "addStrategyTag 为规则组创建企业客户标签" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/add_strategy_tag?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"tag_group\":{\"group_id\":\"sg2\",\"group_name\":\"新策略分组\",\"create_time\":1600000000,\"order\":2,\"tag\":[{\"id\":\"st2\",\"name\":\"新策略标签\",\"create_time\":1600000000,\"order\":2}]}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.addStrategyTag(.{
        .strategy_id = 7,
        .group_id = "",
        .group_name = "新策略分组",
        .order = 2,
        .tag = &.{.{ .name = "新策略标签", .order = 2 }},
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("sg2", parsed.value.tag_group.group_id);
    try std.testing.expectEqualStrings("st2", parsed.value.tag_group.tag[0].id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"group_name\":\"新策略分组\"") != null);
}

test "editStrategyTag 编辑规则组下企业客户标签" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/edit_strategy_tag?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.editStrategyTag(.{ .id = "st1", .name = "改名", .order = 5 });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"id\":\"st1\"") != null);
}

test "delStrategyTag 删除规则组下企业客户标签" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/del_strategy_tag?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    try ec.delStrategyTag(.{ .tag_id = &.{"st1"}, .group_id = &.{"sg1"} });

    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"group_id\":[\"sg1\"]") != null);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：customer_acquisition — 获客助手
// ─────────────────────────────────────────────────────────────────────────────

test "listLink 获取获客链接列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition/list_link?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"link_id_list\":[\"link1\",\"link2\"],\"next_cursor\":\"NC\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.listLink(.{ .limit = 100, .cursor = "" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.link_id_list.len);
    try std.testing.expectEqualStrings("link2", parsed.value.link_id_list[1]);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"limit\":100") != null);
}

test "getCustomerAcquisition 获取获客链接详情" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition/get?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"link\":{\"link_id\":\"link1\",\"link_name\":\"链接名\",\"url\":\"https://a\",\"create_time\":1600000000,\"skip_verify\":true,\"mark_source\":true},\"range\":{\"user_list\":[\"zhangsan\"],\"department_list\":[2]},\"priority_option\":{\"priority_type\":1,\"priority_userid_list\":[\"lisi\"]},\"skip_verify\":true}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getCustomerAcquisition(.{ .link_id = "link1" });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("链接名", parsed.value.link.link_name);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.range.user_list[0]);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.range.department_list[0]);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.priority_option.priority_type);
    try std.testing.expect(parsed.value.skip_verify);
    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"link_id\":\"link1\"}"));
}

test "createCustomerAcquisitionLink 创建获客链接" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition/create_link?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"link\":{\"link_id\":\"link3\",\"link_name\":\"新链接\",\"url\":\"https://b\",\"create_time\":1600000000,\"skip_verify\":false,\"mark_source\":false}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.createCustomerAcquisitionLink(.{
        .link_name = "新链接",
        .range = .{ .user_list = &.{"zhangsan"}, .department_list = &.{} },
        .skip_verify = false,
        .priority_option = .{},
        .mark_source = false,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("link3", parsed.value.link.link_id);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"link_name\":\"新链接\"") != null);
}

test "updateCustomerAcquisitionLink 编辑获客链接" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition/update_link?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.updateCustomerAcquisitionLink(.{
        .link_id = "link1",
        .link_name = "改名链接",
        .range = .{},
        .skip_verify = true,
        .priority_option = .{},
        .mark_source = false,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"link_id\":\"link1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"skip_verify\":true") != null);
}

test "deleteCustomerAcquisitionLink 删除获客链接" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition/delete_link?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.deleteCustomerAcquisitionLink(.{ .link_id = "link1" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"link_id\":\"link1\"}"));
}

test "getCustomerInfoWithLink 获取获客链接添加的客户信息" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition/customer?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"customer_list\":[{\"external_userid\":\"wmAAA\",\"userid\":\"zhangsan\",\"chat_status\":1,\"state\":\"st\"}],\"next_cursor\":\"\"}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getCustomerInfoWithLink(.{ .link_id = "link1", .limit = 100, .cursor = "" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.customer_list.len);
    try std.testing.expectEqualStrings("wmAAA", parsed.value.customer_list[0].external_userid);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.customer_list[0].chat_status);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"link_id\":\"link1\"") != null);
}

test "customerAcquisitionQuota 查询剩余使用量" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition_quota?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1000,\"balance\":800,\"quota_list\":[{\"expire_date\":1609459200,\"balance\":800}]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.customerAcquisitionQuota();
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1000), parsed.value.total);
    try std.testing.expectEqual(@as(i64, 800), parsed.value.balance);
    try std.testing.expectEqual(@as(i64, 1609459200), parsed.value.quota_list[0].expire_date);
}

test "customerAcquisitionStatistic 查询链接使用详情" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition/statistic?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"click_link_customer_cnt\":10,\"new_customer_cnt\":6}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.customerAcquisitionStatistic(.{
        .link_id = "link1",
        .start_time = 1600000000,
        .end_time = 1600086400,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 10), parsed.value.click_link_customer_cnt);
    try std.testing.expectEqual(@as(i64, 6), parsed.value.new_customer_cnt);
    try std.testing.expect(std.mem.indexOf(u8, rt.payloads.items[0], "\"link_id\":\"link1\"") != null);
}

test "getChatInfo 获取成员多次收消息详情" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    var rt = RecordingTransport.init(allocator, &mt);
    defer rt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition/get_chat_info?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"userid\":\"zhangsan\",\"external_userid\":\"wmAAA\",\"chat_info\":{\"recv_msg_cnt\":5,\"link_id\":\"link1\",\"state\":\"st\"}}",
    });

    installRecording(allocator, &rt);
    defer uninstallRecording();

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getChatInfo(.{ .chat_key = "ck1" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 5), parsed.value.chat_info.recv_msg_cnt);
    try std.testing.expectEqualStrings("link1", parsed.value.chat_info.link_id);
    try std.testing.expect(std.mem.eql(u8, rt.payloads.items[0], "{\"chat_key\":\"ck1\"}"));
}

test "getPermit 获取客户可建联成员" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/customer_acquisition_app/get_permit?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"user_list\":[\"zhangsan\"],\"department_list\":[2],\"tag_list\":[3]}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx = makeCtx();
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getPermit();
    defer parsed.deinit();

    try std.testing.expectEqualStrings("zhangsan", parsed.value.user_list[0]);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.department_list[0]);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.tag_list[0]);
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
        .config = .{ .corp_id = "ww-ec-retry" },
        .access_token_handle = .{ .ptr = @ptrCast(state), .vtable = &RetryTokenState.vtable },
    };
}

test "getExternalContact token 失效：40001 → 作废缓存 → 用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get?access_token=tok-old&external_userid=wmAAA&cursor=", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get?access_token=tok-new&external_userid=wmAAA&cursor=", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"external_contact\":{\"external_userid\":\"wmAAA\",\"name\":\"张三\"}}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var state = RetryTokenState{};
    var ctx = makeRetryCtx(&state);
    var ec = ExternalContact.init(&ctx, allocator);
    var parsed = try ec.getExternalContact("wmAAA", "");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("张三", parsed.value.external_contact.name);
    try std.testing.expectEqual(@as(usize, 1), state.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get?access_token=tok-old&external_userid=wmAAA&cursor=",
        mt.history.items[0],
    );
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/externalcontact/get?access_token=tok-new&external_userid=wmAAA&cursor=",
        mt.history.items[1],
    );
}

test "updateUserRemark 非 token 类 errcode：直接 ApiError，不作废也不重试" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/externalcontact/remark?access_token=tok-old", .{
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
    var ec = ExternalContact.init(&ctx, allocator);

    const result = ec.updateUserRemark(.{ .userid = "zhangsan", .external_userid = "wmAAA", .remark = "客户A" });
    try std.testing.expectError(util_error.WechatError.ApiError, result);

    try std.testing.expectEqual(@as(usize, 0), state.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.fetch_calls);
}
