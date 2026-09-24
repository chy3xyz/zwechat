// SPDX-License-Identifier: Apache-2.0
//! work/kf — 微信客服
//!
//! 对应 `_ref/wechat/work/kf/`。Go 参考实现的 `NewClient(cfg)` 接受 `*config.Config`
//! 并自行组装内部 `Context`（因为它需要额外的 `token` / `encodingAESKey` 等
//! 客服回调字段，且访问 token 时使用独立的 kf corpsecret）。Zig 版统一沿用
//! `Context` 抽象，由调用方在 `Config` 里填好客服 secret，再通过 `Context`
//! 走默认 access_token 即可。
//!
//! 已覆盖 `_ref/wechat/work/kf/` 的全部服务端 API（callback.go 的
//! `VerifyURL` / `GetCallbackMessage` 属回调消息加解密，不在本模块）：
//!
//! - 客服账号：`getAccountList` / `getAccountPage` / `addAccount` /
//!   `updateAccount` / `delAccount` / `addContactWay`
//! - 接待人员（servicer）：`addServicer` / `delServicer` / `getServicerList`
//! - 会话状态（servicestate）：`getServiceState` / `transServiceState`
//! - 消息：`sendMsg`（文本）/ `sendMsgRich`（富媒体：图片 / 语音 / 视频 / 文件 /
//!   图文链接 / 小程序 / 菜单 / 地理位置）/ `sendMsgOnEvent`（事件响应文本）/
//!   `syncMsg`（游标式增量拉取，`msg_list` 各消息类型强类型解析 + 原始 JSON
//!   留存于 `SyncMessage.origin_data`，等价 Go 的 `OriginData`）
//! - 客户：`customerBatchGet`
//! - 升级服务（upgrade）：`getUpgradeServiceConfig` / `upgradeService` /
//!   `upgradeMemberService` / `upgradeGroupChatService` / `cancelUpgradeService`
//! - 知识库（knowledge）：分组 `addKnowledgeGroup` / `delKnowledgeGroup` /
//!   `modKnowledgeGroup` / `listKnowledgeGroup`；问答 `addKnowledgeIntent` /
//!   `delKnowledgeIntent` / `modKnowledgeIntent` / `listKnowledgeIntent`
//! - 统计（statistic）：`getCorpStatistic` / `getServicerStatistic`
//! - 其他：`getCorpQualification`（视频号绑定状态）

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_json = @import("../../util/json.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 客服账号列表。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/kf/account/list?access_token=...`。
pub const accountListURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/account/list";

/// 添加客服账号。
pub const accountAddURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/account/add";

/// 删除客服账号。
pub const accountDelURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/account/del";

/// 修改客服账号。
pub const accountUpdateURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/account/update";

/// 获取客服账号链接（add_contact_way）。
pub const addContactWayURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/add_contact_way";

/// 添加接待人员。
pub const servicerAddURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/servicer/add";

/// 删除接待人员。
pub const servicerDelURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/servicer/del";

/// 接待人员列表（GET，需追加 `&open_kfid=`）。
pub const servicerListURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/servicer/list";

/// 获取会话状态。
pub const serviceStateGetURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/service_state/get";

/// 变更会话状态。
pub const serviceStateTransURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/service_state/trans";

/// 客服发消息。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=...`。
pub const sendMsgURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg";

/// 发送事件响应消息。
pub const sendMsgOnEventURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg_on_event";

/// 获取消息（游标式增量拉取）。
pub const syncMsgURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/sync_msg";

/// 客户基本信息批量获取。
pub const customerBatchGetURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/customer/batchget";

/// 获取配置的专员与客户群。
pub const upgradeServiceConfigURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/customer/get_upgrade_service_config";

/// 为客户升级服务（专员 / 客户群）。
pub const upgradeServiceURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/customer/upgrade_service";

/// 为客户取消推荐。
pub const upgradeServiceCancelURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/customer/cancel_upgrade_service";

/// 知识库分组添加。
pub const knowledgeAddGroupURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/add_group";

/// 知识库分组删除。
pub const knowledgeDelGroupURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/del_group";

/// 知识库分组修改。
pub const knowledgeModGroupURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/mod_group";

/// 知识库分组列表。
pub const knowledgeListGroupURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/list_group";

/// 知识库问答添加。
pub const knowledgeAddIntentURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/add_intent";

/// 知识库问答删除。
pub const knowledgeDelIntentURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/del_intent";

/// 知识库问答修改。
pub const knowledgeModIntentURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/mod_intent";

/// 知识库问答列表。
pub const knowledgeListIntentURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/list_intent";

/// 「客户数据统计」企业汇总数据。
pub const corpStatisticURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/get_corp_statistic";

/// 「客户数据统计」接待人员明细数据。
pub const servicerStatisticURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/get_servicer_statistic";

/// 获取视频号绑定状态。
pub const corpQualificationURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/get_corp_qualification";

// ─────────────────────────────────────────────────────────────────────────────
// 文本消息请求
// ─────────────────────────────────────────────────────────────────────────────

/// 文本消息（`msgtype = "text"`）请求体。
pub const TextMessage = struct {
    /// 客服账号 id。
    open_kfid: []const u8 = "",
    /// 客户 external_userid。
    touser: []const u8 = "",
    /// 消息类型，由 `sendMsg` 自动设置为 `"text"`。
    msgtype: []const u8 = "text",
    /// 文本内容（utf8，最长 2048 字节）。
    content: []const u8 = "",
};

/// 事件响应文本消息请求体（`sendMsgOnEvent`，`msgtype = "text"`）。
///
/// 对应 `_ref/wechat/work/kf/sendmsgonevent/message.go` 的 `Text`；
/// `code` 来自进入会话事件的 `welcome_code` 或变更会话状态返回的 `msg_code`。
pub const TextEventMessage = struct {
    /// 事件响应消息对应的 code，通过事件回调下发，仅可使用一次。
    code: []const u8 = "",
    /// 消息 id；指定则原样返回，不填由系统生成。
    msgid: []const u8 = "",
    /// 消息类型，由 `sendMsgOnEvent` 自动设置为 `"text"`。
    msgtype: []const u8 = "text",
    /// 文本内容（utf8，最长 2048 字节）。
    content: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 富媒体消息请求（sendMsgRich）
// ─────────────────────────────────────────────────────────────────────────────

/// 发送侧消息体联合（`sendMsgRich` 入参）。
///
/// 对应 `_ref/wechat/work/kf/sendmsg/message.go` 的 `Text` / `Image` / `Voice` /
/// `Video` / `File` / `Link` / `MiniProgram` / `Menu` / `Location` 结构。
/// Go 侧 `SendMsg` 接受 `interface{}`，Zig 版以 tagged union 在编译期约束消息类型。
/// `.text` 分支编码结果与 `sendMsg` 完全一致。
pub const SendMessage = union(enum) {
    /// 文本消息。
    text: TextMessage,
    /// 图片消息。
    image: ImageMessage,
    /// 语音消息。
    voice: VoiceMessage,
    /// 视频消息。
    video: VideoMessage,
    /// 文件消息。
    file: FileMessage,
    /// 图文链接消息。
    link: LinkMessage,
    /// 小程序消息。
    miniprogram: MiniProgramMessage,
    /// 菜单消息。
    menu: MenuMessage,
    /// 地理位置消息。
    location: LocationMessage,
};

/// 图片消息请求体（`msgtype = "image"`）。
pub const ImageMessage = struct {
    /// 指定发送消息的客服帐号 id。
    open_kfid: []const u8 = "",
    /// 指定接收消息的客户 userid。
    touser: []const u8 = "",
    /// 消息 id；不填由系统生成（对齐 Go `msgid,omitempty`，编码时非空才写入）。
    msgid: []const u8 = "",
    /// 图片文件 media_id（上传临时素材接口获取）。
    media_id: []const u8 = "",
};

/// 语音消息请求体（`msgtype = "voice"`）。
pub const VoiceMessage = struct {
    /// 指定发送消息的客服帐号 id。
    open_kfid: []const u8 = "",
    /// 指定接收消息的客户 userid。
    touser: []const u8 = "",
    /// 消息 id；不填由系统生成。
    msgid: []const u8 = "",
    /// 语音文件 media_id（上传临时素材接口获取）。
    media_id: []const u8 = "",
};

/// 视频消息请求体（`msgtype = "video"`）。
pub const VideoMessage = struct {
    /// 指定发送消息的客服帐号 id。
    open_kfid: []const u8 = "",
    /// 指定接收消息的客户 userid。
    touser: []const u8 = "",
    /// 消息 id；不填由系统生成。
    msgid: []const u8 = "",
    /// 视频文件 media_id（上传临时素材接口获取）。
    media_id: []const u8 = "",
};

/// 文件消息请求体（`msgtype = "file"`）。
pub const FileMessage = struct {
    /// 指定发送消息的客服帐号 id。
    open_kfid: []const u8 = "",
    /// 指定接收消息的客户 userid。
    touser: []const u8 = "",
    /// 消息 id；不填由系统生成。
    msgid: []const u8 = "",
    /// 文件 media_id（上传临时素材接口获取）。
    media_id: []const u8 = "",
};

/// 图文链接消息请求体（`msgtype = "link"`）。
pub const LinkMessage = struct {
    /// 指定发送消息的客服帐号 id。
    open_kfid: []const u8 = "",
    /// 指定接收消息的客户 userid。
    touser: []const u8 = "",
    /// 消息 id；不填由系统生成。
    msgid: []const u8 = "",
    /// 标题，不超过 128 字节，超过自动截断。
    title: []const u8 = "",
    /// 描述，不超过 512 字节，超过自动截断。
    desc: []const u8 = "",
    /// 点击后跳转的链接，最长 2048 字节，需包含协议头（http/https）。
    url: []const u8 = "",
    /// 缩略图 media_id（上传接口返回的 media_id）。
    thumb_media_id: []const u8 = "",
};

/// 小程序消息请求体（`msgtype = "miniprogram"`）。
pub const MiniProgramMessage = struct {
    /// 指定发送消息的客服帐号 id。
    open_kfid: []const u8 = "",
    /// 指定接收消息的客户 userid。
    touser: []const u8 = "",
    /// 消息 id；不填由系统生成。
    msgid: []const u8 = "",
    /// 小程序 appid，必须是关联到企业的小程序应用。
    appid: []const u8 = "",
    /// 小程序消息标题，最多 64 字节，超过自动截断。
    title: []const u8 = "",
    /// 封面 media_id（封面图建议尺寸 520*416）。
    thumb_media_id: []const u8 = "",
    /// 点击消息卡片后进入的小程序页面路径。
    pagepath: []const u8 = "",
};

/// 菜单消息请求体（`msgtype = "msgmenu"`）。
pub const MenuMessage = struct {
    /// 指定发送消息的客服帐号 id。
    open_kfid: []const u8 = "",
    /// 指定接收消息的客户 userid。
    touser: []const u8 = "",
    /// 消息 id；不填由系统生成。
    msgid: []const u8 = "",
    /// 菜单头部文本，不多于 1024 字节。
    head_content: []const u8 = "",
    /// 菜单项列表，不能多于 10 个。
    list: []const MenuItem = &.{},
    /// 菜单尾部文本，不多于 1024 字节。
    tail_content: []const u8 = "",
};

/// 菜单项（`msgmenu.list` 元素）。
///
/// 对应 Go `sendmsg.MenuClick` / `MenuView` / `MenuMiniProgram`，
/// 编码为 `{"type":"click","click":{...}}` 形态。
pub const MenuItem = union(enum) {
    /// 回复菜单（`type = "click"`）。
    click: MenuClickItem,
    /// 超链接菜单（`type = "view"`）。
    view: MenuViewItem,
    /// 小程序菜单（`type = "miniprogram"`）。
    miniprogram: MenuMiniProgramItem,
};

/// 回复菜单项（客户点击后触发一条带 `menu_id` 的文本消息，见 `SyncTextContent.menu_id`）。
pub const MenuClickItem = struct {
    /// 菜单 id，1~64 字节。
    id: []const u8 = "",
    /// 菜单显示内容，1~128 字节。
    content: []const u8 = "",
};

/// 超链接菜单项。
pub const MenuViewItem = struct {
    /// 点击后跳转的链接，1~2048 字节。
    url: []const u8 = "",
    /// 菜单显示内容，1~1024 字节。
    content: []const u8 = "",
};

/// 小程序菜单项。
pub const MenuMiniProgramItem = struct {
    /// 小程序 appid，1~32 字节。
    appid: []const u8 = "",
    /// 点击后进入的小程序页面，1~1024 字节。
    pagepath: []const u8 = "",
    /// 菜单显示内容，1~1024 字节。
    content: []const u8 = "",
};

/// 地理位置消息请求体（`msgtype = "location"`）。
pub const LocationMessage = struct {
    /// 指定发送消息的客服帐号 id。
    open_kfid: []const u8 = "",
    /// 指定接收消息的客户 userid。
    touser: []const u8 = "",
    /// 消息 id；不填由系统生成。
    msgid: []const u8 = "",
    /// 纬度，浮点数，范围 -90 ~ 90。
    latitude: f32 = 0,
    /// 经度，浮点数，范围 -180 ~ 180。
    longitude: f32 = 0,
    /// 位置名。
    name: []const u8 = "",
    /// 地址详情说明。
    address: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 客服账号请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 添加客服账号请求（`account/add`）。
pub const AccountAddRequest = struct {
    /// 客服帐号名称，不多于 16 个字符。
    name: []const u8 = "",
    /// 客服头像临时素材 media_id，不多于 128 字节。
    media_id: []const u8 = "",
};

/// 删除客服账号请求（`account/del`）。
pub const AccountDelRequest = struct {
    /// 客服帐号 ID，不多于 64 字节。
    open_kfid: []const u8 = "",
};

/// 修改客服账号请求（`account/update`）。
pub const AccountUpdateRequest = struct {
    /// 客服帐号 ID。
    open_kfid: []const u8 = "",
    /// 客服帐号名称，不多于 16 个字符。
    name: []const u8 = "",
    /// 客服头像临时素材 media_id。
    media_id: []const u8 = "",
};

/// 分页获取客服账号列表请求（`account/list`，POST）。
pub const AccountPageRequest = struct {
    /// 分页偏移。
    offset: i64 = 0,
    /// 分页大小。
    limit: i64 = 0,
};

/// 获取客服账号链接请求（`add_contact_way`）。
pub const ContactWayRequest = struct {
    /// 客服帐号 ID。
    open_kfid: []const u8 = "",
    /// 场景值，字符串类型，由开发者自定义（`[0-9a-zA-Z_-]*`），不多于 32 字节。
    scene: []const u8 = "",
};

/// `addAccount` 响应。
pub const AccountAddResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 新创建的客服帐号 ID。
    open_kfid: []const u8 = "",
};

/// 通用成功响应（仅有 errcode / errmsg）。
pub const CommonResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

/// `addContactWay` 响应。
pub const ContactWayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 客服链接，可嵌入 H5 页面或据此生成二维码。
    url: []const u8 = "",
};

/// 单个客服账号信息。
pub const AccountInfo = struct {
    open_kfid: []const u8 = "",
    name: []const u8 = "",
    avatar: []const u8 = "",
    /// 当前调用接口的应用身份，是否有该客服账号的管理权限。
    manage_privilege: bool = false,
};

/// `getAccountList` / `getAccountPage` 响应。
pub const AccountListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    account_list: []AccountInfo = &.{},
};

/// `sendMsg` / `sendMsgOnEvent` 响应。
pub const SendMsgResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 消息 id；如果请求参数指定了 msgid，则原样返回。
    msgid: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 接待人员（servicer）请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 添加 / 删除接待人员请求（`servicer/add`、`servicer/del`）。
pub const ServicerRequest = struct {
    /// 客服帐号 ID。
    open_kfid: []const u8 = "",
    /// 接待人员 userid 列表（第三方应用填密文 userid），1 ~ 100 个。
    userid_list: []const []const u8 = &.{},
    /// 接待人员部门 id 列表，0 ~ 100 个。
    department_id_list: []const i64 = &.{},
};

/// 接待人员操作结果项（`result_list` 元素）。
pub const ServicerResult = struct {
    userid: []const u8 = "",
    department_id: i64 = 0,
    /// 该项自身的错误码（0 表示成功）。
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

/// `addServicer` / `delServicer` 响应。
pub const ServicerResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    result_list: []ServicerResult = &.{},
};

/// 接待人员信息（`servicer_list` 元素）。
pub const ServicerInfo = struct {
    /// 接待人员 userid（第三方应用为密文 userid）。
    userid: []const u8 = "",
    /// 接待状态。0：接待中；1：停止接待。
    status: i64 = 0,
    department_id: i64 = 0,
    /// 停止接待的子类型。0：停止接待；1：暂时挂起。
    stop_type: i64 = 0,
};

/// `getServicerList` 响应。
pub const ServicerListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    servicer_list: []ServicerInfo = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 会话状态（service_state）请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 获取会话状态请求（`service_state/get`）。
pub const ServiceStateGetRequest = struct {
    /// 客服帐号 ID。
    open_kfid: []const u8 = "",
    /// 微信客户的 external_userid。
    external_userid: []const u8 = "",
};

/// 变更会话状态请求（`service_state/trans`）。
pub const ServiceStateTransRequest = struct {
    /// 客服帐号 ID。
    open_kfid: []const u8 = "",
    /// 微信客户的 external_userid。
    external_userid: []const u8 = "",
    /// 变更的目标状态：0 未处理；1 智能助手接待；2 待接入池；3 人工接待；4 已结束。
    service_state: i64 = 0,
    /// 接待人员 userid，目标状态为 3 时必填。
    servicer_userid: []const u8 = "",
};

/// `getServiceState` 响应。
pub const ServiceStateGetResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 当前会话状态（0/1/2/3/4，定义见 `ServiceStateTransRequest`）。
    service_state: i64 = 0,
    /// 接待人员 userid，仅当 state=3 时有效。
    service_userid: []const u8 = "",
};

/// `transServiceState` 响应。
pub const ServiceStateTransResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 用于发送事件响应消息的 code；会话初次变更为 2/3 时返回回复语 code，变更为 4 时返回结束语 code。
    msg_code: []const u8 = "",
};

// ─────────────────────────────────────────────────────────────────────────────
// 消息拉取（sync_msg）请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 获取消息请求（`sync_msg`）。
///
/// 游标机制：首次拉取 `cursor` 留空，之后每次带上上次返回的 `next_cursor`
/// 实现增量拉取；`limit` 期望拉取条数，默认与最大均为 1000，实际返回条数
/// 可能少于 `limit`，必须结合 `has_more` 判断是否继续。
pub const SyncMsgRequest = struct {
    /// 上一次调用返回的 next_cursor；第一次拉取留空，不多于 64 字节。
    cursor: []const u8 = "",
    /// 回调事件返回的 token，10 分钟内有效；不填有严格频控。
    token: []const u8 = "",
    /// 期望请求的数据量，默认与最大均为 1000。
    limit: u32 = 0,
    /// 语音消息格式：0-Amr；1-Silk。为 0 时不写入请求体（对齐 Go `omitempty`）。
    voice_format: u32 = 0,
    /// 指定拉取某个客服帐号的消息；为空不写入请求体（对齐 Go `omitempty`）。
    open_kfid: []const u8 = "",
};

/// 文本消息负载（`msgtype = "text"`）。
pub const SyncTextContent = struct {
    /// 文本内容。
    content: []const u8 = "",
    /// 客户点击菜单触发的回复消息中附带的菜单 id。
    menu_id: []const u8 = "",
};

/// 媒体消息负载（image / voice / video / file 均只有 `media_id`）。
pub const SyncMediaContent = struct {
    /// 文件 id。
    media_id: []const u8 = "",
};

/// 地理位置消息负载（`msgtype = "location"`）。
pub const SyncLocationContent = struct {
    /// 纬度。
    latitude: f32 = 0,
    /// 经度。
    longitude: f32 = 0,
    /// 位置名。
    name: []const u8 = "",
    /// 地址详情说明。
    address: []const u8 = "",
};

/// 链接消息负载（`msgtype = "link"`）。
pub const SyncLinkContent = struct {
    /// 标题。
    title: []const u8 = "",
    /// 描述。
    desc: []const u8 = "",
    /// 点击后跳转的链接。
    url: []const u8 = "",
    /// 缩略图链接。
    pic_url: []const u8 = "",
};

/// 名片消息负载（`msgtype = "business_card"`）。
pub const SyncBusinessCardContent = struct {
    /// 名片 userid。
    userid: []const u8 = "",
};

/// 小程序消息负载（`msgtype = "miniprogram"`）。
pub const SyncMiniProgramContent = struct {
    /// 小程序 appid。
    appid: []const u8 = "",
    /// 小程序消息标题。
    title: []const u8 = "",
    /// 封面 media_id。
    thumb_media_id: []const u8 = "",
    /// 点击后进入的小程序页面路径。
    pagepath: []const u8 = "",
};

/// 事件消息的内层 `event` 对象。
///
/// 覆盖 `_ref/wechat/work/kf/syncmsg/message.go` 全部四类事件的字段：
/// `enter_session` / `msg_send_fail` / `servicer_status_change` /
/// `session_status_change`。按 `event_type` 取用对应字段，未知字段由
/// `ignore_unknown_fields` 策略容忍演进。
pub const SyncEvent = struct {
    /// 事件类型，如 `enter_session` / `msg_send_fail` / `servicer_status_change` / `session_status_change`。
    event_type: []const u8 = "",
    /// 客服账号 id（事件内层字段，enter_session / msg_send_fail / session_status_change 返回）。
    open_kfid: []const u8 = "",
    /// 客户 userid（事件内层字段，enter_session / msg_send_fail / session_status_change 返回）。
    external_userid: []const u8 = "",
    /// 进入会话的场景值（enter_session，客服帐号链接的自定义场景值）。
    scene: []const u8 = "",
    /// 进入会话的自定义参数（enter_session，按规范拼接的 scene_param）。
    scene_param: []const u8 = "",
    /// 欢迎语 code（enter_session，满足条件才返回；可用 `sendMsgOnEvent` 发送欢迎语）。
    welcome_code: []const u8 = "",
    /// 发送失败的消息 msgid（msg_send_fail）。
    fail_msgid: []const u8 = "",
    /// 失败类型（msg_send_fail）：0-未知原因 1-客服账号已删除 2-应用已关闭 4-会话已过期（超过48小时）5-会话已关闭 6-超过5条限制 7-未绑定视频号 8-主体未验证 9-未绑定视频号且主体未验证 10-用户拒收。
    fail_type: u32 = 0,
    /// 客服人员 userid（servicer_status_change）。
    servicer_userid: []const u8 = "",
    /// 接待状态（servicer_status_change）：1-接待中 2-停止接待。
    status: u32 = 0,
    /// 会话变更类型（session_status_change）：1-从接待池接入会话 2-转接会话 3-结束会话。
    change_type: u32 = 0,
    /// 原客服人员 userid（session_status_change，change_type 为 2/3 时有值）。
    old_servicer_userid: []const u8 = "",
    /// 新客服人员 userid（session_status_change，change_type 为 1/2 时有值）。
    new_servicer_userid: []const u8 = "",
    /// 事件响应消息 code（session_status_change，change_type 为 1/3 时返回；可用 `sendMsgOnEvent` 发送回复语 / 结束语）。
    msg_code: []const u8 = "",
};

/// 拉取到的单条消息（对应 Go `syncmsg` 包的公共字段 + 各消息类型负载）。
///
/// 与 Go 版不同，Zig 版不按 msgtype 拆分为多个结构体，而是把所有候选负载
/// 以默认值平铺在同一结构体上——微信只会下发与 `msgtype` 匹配的负载键，
/// 其余字段保持默认值；未知消息类型的负载由 `ignore_unknown_fields` 容忍。
///
/// Go 的 `OriginData`（gjson 截取的原始 JSON）在 Zig 版由 `origin_data`
/// 承接：`std.json` 单遍解析确实拿不到原始字节，但可以在解析该条目时先把
/// 整条消息物化成 `std.json.Value` 树并保留下来（见 `jsonParse`），
/// 再经 `getOriginData` / `originAs` / `originPayloadAs` 做二次解析。
/// 这样微信新增字段或下发新 `msgtype`（newtype）时，调用方无需等待 SDK 升级。
pub const SyncMessage = struct {
    msgid: []const u8 = "",
    /// msgtype 为 event 时不返回。
    open_kfid: []const u8 = "",
    /// msgtype 为 event 时不返回。
    external_userid: []const u8 = "",
    /// 接待客服 userid。
    servicer_userid: []const u8 = "",
    /// 消息发送时间（Unix 秒）。
    send_time: u64 = 0,
    /// 消息来源。3-微信客户发送；4-系统推送事件；5-接待人员在企业微信客户端发送。
    origin: u32 = 0,
    /// 消息类型：text/image/voice/video/file/location/link/business_card/miniprogram/event 等。
    msgtype: []const u8 = "",
    /// 文本负载（msgtype=text；menu_id 为菜单回复附带的菜单 id）。
    text: SyncTextContent = .{},
    /// 图片负载（msgtype=image）。
    image: SyncMediaContent = .{},
    /// 语音负载（msgtype=voice）。
    voice: SyncMediaContent = .{},
    /// 视频负载（msgtype=video）。
    video: SyncMediaContent = .{},
    /// 文件负载（msgtype=file）。
    file: SyncMediaContent = .{},
    /// 地理位置负载（msgtype=location）。
    location: SyncLocationContent = .{},
    /// 链接负载（msgtype=link）。
    link: SyncLinkContent = .{},
    /// 名片负载（msgtype=business_card）。
    business_card: SyncBusinessCardContent = .{},
    /// 小程序负载（msgtype=miniprogram）。
    miniprogram: SyncMiniProgramContent = .{},
    /// 事件负载（msgtype=event），字段按 event_type 取用。
    event: SyncEvent = .{},

    /// 该条目对应的原始 JSON 值树（Go `syncmsg.SyncMessage.OriginData` 的等价物）。
    ///
    /// 由 `jsonParse` 在解析每条消息时填充，**包含强类型结构体里没有的字段**
    /// （微信新增字段 / 未知 `msgtype` 的负载都完整保留），因此可用于二次解析。
    ///
    /// 生命周期：该 Value 树与 `msg_list` 中强类型字段的字符串同属
    /// `syncMsg` 返回的 `std.json.Parsed(SyncMsgResponse)` 内部 arena，
    /// `parsed.deinit()` 一并释放；`SyncMessage` 自身不持有裸切片、无需单独释放。
    /// 因此只应在 `parsed` 存活期间（即 `parsed.value` 的借用期内）读取；
    /// 需要长期保存时先用 `getOriginData` 拷出 JSON 字节。
    /// 手工构造的 `SyncMessage`（未走 `syncMsg`）该字段为 null。
    origin_data: ?std.json.Value = null,

    /// 自定义 JSON 解析：先把整条消息元素物化成 `std.json.Value` 树，
    /// 再从该树解码上面的强类型字段，最后把整棵树挂到 `origin_data`。
    ///
    /// 由 `std.json` 在解析 `msg_list` 元素时自动调用（`std.meta.hasFn(T, "jsonParse")`），
    /// 调用方无需直接调用。树与强类型字段共用调用方传入的 allocator
    /// （`syncMsg` 路径下即 `Parsed` 的 arena），无额外所有权转移。
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !@This() {
        const origin = try std.json.Value.jsonParse(allocator, source, options);
        var msg = try std.json.parseFromValueLeaky(@This(), allocator, origin, .{
            .ignore_unknown_fields = true,
        });
        msg.origin_data = origin;
        return msg;
    }

    /// 取出该条目的原始 JSON 值树（借用，不复制）。
    ///
    /// 返回的 `std.json.Value` 由 `parsed` 的 arena 持有，有效期同 `origin_data`；
    /// 未保留原始 JSON（手工构造的实例）时返回 null。
    pub fn getOriginValue(self: SyncMessage) ?std.json.Value {
        return self.origin_data;
    }

    /// 把原始 JSON 值树序列化回 JSON 字符串（等价 Go 的 `OriginData`）。
    ///
    /// 调用方负责 `allocator.free` 释放返回值；返回的字节可直接入库或交给
    /// 任意 JSON 解析器二次解析。`origin_data` 为 null 时返回
    /// `error.NoOriginData`。
    ///
    /// 注意：JSON 对象键序按微信下发顺序保留；空白与数字书写形式可能被
    /// 规范化（例如 `1.0` 可能被写成 `1`），即语义等价而非逐字节相同。
    pub fn getOriginData(self: SyncMessage, allocator: std.mem.Allocator) ![]u8 {
        const origin = self.origin_data orelse return error.NoOriginData;
        return std.json.Stringify.valueAlloc(allocator, origin, .{});
    }

    /// 把整条原始消息反序列化为调用方指定的类型 `T`（等价 Go 的 `GetOriginMessage`）。
    ///
    /// 用于微信新增字段的读取：`T` 只需声明关心的字段，未知字段一律忽略。
    /// 返回的 `std.json.Parsed(T)` 由调用方 `deinit`；`origin_data` 为 null 时
    /// 返回 `error.NoOriginData`，JSON 不匹配 `T` 时返回 `error.DecodeError`。
    pub fn originAs(
        self: SyncMessage,
        allocator: std.mem.Allocator,
        comptime T: type,
    ) !std.json.Parsed(T) {
        const origin = self.origin_data orelse return error.NoOriginData;
        return std.json.parseFromValue(T, allocator, origin, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.DecodeError,
        };
    }

    /// 把 `origin_data[msgtype]` 这个负载对象反序列化为调用方指定的类型 `T`
    /// （等价 Go 的 `GetTextMessage` / `GetImageMessage` 等按类型取负载的入口）。
    ///
    /// 应对未知 `msgtype`（newtype）最直接：强类型字段拿不到的负载，
    /// 这里用自定义 `T` 解出来。`origin_data` 缺失返回 `error.NoOriginData`；
    /// `msgtype` 为空或原始 JSON 中没有该负载对象时返回 `error.PayloadNotFound`。
    pub fn originPayloadAs(
        self: SyncMessage,
        allocator: std.mem.Allocator,
        comptime T: type,
    ) !std.json.Parsed(T) {
        const origin = self.origin_data orelse return error.NoOriginData;
        if (origin != .object or self.msgtype.len == 0) return error.PayloadNotFound;
        const payload = origin.object.get(self.msgtype) orelse return error.PayloadNotFound;
        return std.json.parseFromValue(T, allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.DecodeError,
        };
    }
};

/// `syncMsg` 响应。
pub const SyncMsgResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 下次调用带上该值则从当前位置继续往后拉（增量游标，建议入库保存）。
    next_cursor: []const u8 = "",
    /// 是否还有更多数据：0-否；1-是。不能通过 msg_list 是否为空判断停止。
    has_more: u32 = 0,
    msg_list: []SyncMessage = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 客户请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 客户基本信息批量获取请求（`customer/batchget`）。
pub const CustomerBatchGetRequest = struct {
    /// external_userid 列表。
    external_userid_list: []const []const u8 = &.{},
};

/// 微信客户基本资料。
pub const CustomerInfo = struct {
    external_userid: []const u8 = "",
    /// 微信昵称。
    nickname: []const u8 = "",
    /// 微信头像（第三方不可获取）。
    avatar: []const u8 = "",
    /// 性别。
    gender: i64 = 0,
    /// unionid，需绑定微信开发者帐号才能获取。
    unionid: []const u8 = "",
};

/// `customerBatchGet` 响应。
pub const CustomerBatchGetResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    customer_list: []CustomerInfo = &.{},
    invalid_external_userid: []const []const u8 = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 升级服务（upgrade_service）请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 推荐的服务专员（type=1 时有效）。
pub const UpgradeMember = struct {
    /// 服务专员的 userid。
    userid: []const u8 = "",
    /// 推荐语。
    wording: []const u8 = "",
};

/// 推荐的客户群（type=2 时有效）。
pub const UpgradeGroupChat = struct {
    /// 客户群 id。
    chat_id: []const u8 = "",
    /// 推荐语。
    wording: []const u8 = "",
};

/// 升级服务通用请求（同时携带 member 与 groupchat，对齐 Go `UpgradeServiceOptions`）。
pub const UpgradeServiceRequest = struct {
    open_kfid: []const u8 = "",
    external_userid: []const u8 = "",
    /// 升级到专员服务还是客户群服务：1-专员服务；2-客户群服务。序列化为 JSON key `type`。
    service_type: i64 = 0,
    member: UpgradeMember = .{},
    groupchat: UpgradeGroupChat = .{},
};

/// 升级专员服务请求（仅 member，对齐 Go `UpgradeMemberServiceOptions`）。
pub const UpgradeMemberServiceRequest = struct {
    open_kfid: []const u8 = "",
    external_userid: []const u8 = "",
    /// 固定应为 1。序列化为 JSON key `type`。
    service_type: i64 = 0,
    member: UpgradeMember = .{},
};

/// 升级客户群服务请求（仅 groupchat，对齐 Go `UpgradeServiceGroupChatOptions`）。
pub const UpgradeGroupChatServiceRequest = struct {
    open_kfid: []const u8 = "",
    external_userid: []const u8 = "",
    /// 固定应为 2。序列化为 JSON key `type`。
    service_type: i64 = 0,
    groupchat: UpgradeGroupChat = .{},
};

/// 取消升级服务推荐请求。
pub const UpgradeServiceCancelRequest = struct {
    open_kfid: []const u8 = "",
    external_userid: []const u8 = "",
};

/// `getUpgradeServiceConfig` 响应。
pub const UpgradeServiceConfigResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 专员服务配置范围。
    member_range: MemberRange = .{},
    /// 客户群配置范围。
    groupchat_range: GroupChatRange = .{},
};

pub const MemberRange = struct {
    userid_list: []const []const u8 = &.{},
    department_id_list: []const []const u8 = &.{},
};

pub const GroupChatRange = struct {
    chat_id_list: []const []const u8 = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 知识库（knowledge）请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 知识库分组添加请求。
pub const KnowledgeGroupAddRequest = struct {
    name: []const u8 = "",
};

/// 知识库分组删除请求。
pub const KnowledgeGroupDelRequest = struct {
    group_id: []const u8 = "",
};

/// 知识库分组修改请求。
pub const KnowledgeGroupModRequest = struct {
    group_id: []const u8 = "",
    name: []const u8 = "",
};

/// 知识库分组列表请求。
pub const KnowledgeGroupListRequest = struct {
    cursor: []const u8 = "",
    limit: i64 = 0,
    group_id: []const u8 = "",
};

/// 知识库分组。
pub const KnowledgeGroup = struct {
    group_id: []const u8 = "",
    name: []const u8 = "",
    is_default: i64 = 0,
};

/// `addKnowledgeGroup` 响应。
pub const KnowledgeGroupAddResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    group_id: []const u8 = "",
};

/// `listKnowledgeGroup` 响应。
pub const KnowledgeGroupListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    has_more: i64 = 0,
    group_list: []KnowledgeGroup = &.{},
};

/// 问题文本。
pub const IntentText = struct {
    content: []const u8 = "",
};

/// 主问题 / 相似问题项。
pub const IntentQuestion = struct {
    text: IntentText = .{},
};

/// 相似问题列表。
pub const IntentSimilarQuestions = struct {
    items: []const IntentQuestion = &.{},
};

/// 图片 / 视频附件（media_id）。
pub const IntentAttachmentMedia = struct {
    media_id: []const u8 = "",
};

/// 链接附件。
pub const IntentAttachmentLink = struct {
    title: []const u8 = "",
    picurl: []const u8 = "",
    desc: []const u8 = "",
    url: []const u8 = "",
};

/// 小程序附件（请求侧，含 thumb_media_id）。
pub const IntentAttachmentMiniProgram = struct {
    title: []const u8 = "",
    thumb_media_id: []const u8 = "",
    appid: []const u8 = "",
    pagepath: []const u8 = "",
};

/// 回答附件（请求侧）。
pub const IntentAttachment = struct {
    msgtype: []const u8 = "",
    image: IntentAttachmentMedia = .{},
    video: IntentAttachmentMedia = .{},
    link: IntentAttachmentLink = .{},
    miniprogram: IntentAttachmentMiniProgram = .{},
};

/// 回答（请求侧）。
pub const IntentAnswer = struct {
    text: IntentText = .{},
    attachments: []const IntentAttachment = &.{},
};

/// 知识库问答添加请求。
pub const KnowledgeIntentAddRequest = struct {
    group_id: []const u8 = "",
    question: IntentQuestion = .{},
    similar_questions: IntentSimilarQuestions = .{},
    answers: []const IntentAnswer = &.{},
};

/// 知识库问答删除请求。
pub const KnowledgeIntentDelRequest = struct {
    intent_id: []const u8 = "",
};

/// 知识库问答修改请求。
pub const KnowledgeIntentModRequest = struct {
    intent_id: []const u8 = "",
    question: IntentQuestion = .{},
    similar_questions: IntentSimilarQuestions = .{},
    answers: []const IntentAnswer = &.{},
};

/// 知识库问答列表请求。
pub const KnowledgeIntentListRequest = struct {
    cursor: []const u8 = "",
    limit: i64 = 0,
    group_id: []const u8 = "",
    intent_id: []const u8 = "",
};

/// 图片 / 视频附件（响应侧，返回 name）。
pub const IntentAttachmentName = struct {
    name: []const u8 = "",
};

/// 小程序附件（响应侧）。
pub const IntentAttachmentMiniProgramRes = struct {
    title: []const u8 = "",
    appid: []const u8 = "",
    pagepath: []const u8 = "",
};

/// 回答附件（响应侧）。
pub const IntentAttachmentRes = struct {
    msgtype: []const u8 = "",
    image: IntentAttachmentName = .{},
    video: IntentAttachmentName = .{},
    link: IntentAttachmentLink = .{},
    miniprogram: IntentAttachmentMiniProgramRes = .{},
};

/// 回答（响应侧）。
pub const IntentAnswerRes = struct {
    text: IntentText = .{},
    attachments: []const IntentAttachmentRes = &.{},
};

/// 问答摘要（`intent_list` 元素）。
pub const KnowledgeIntent = struct {
    group_id: []const u8 = "",
    intent_id: []const u8 = "",
    question: IntentQuestion = .{},
    similar_questions: IntentSimilarQuestions = .{},
    answers: []const IntentAnswerRes = &.{},
};

/// `addKnowledgeIntent` 响应。
pub const KnowledgeIntentAddResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    intent_id: []const u8 = "",
};

/// `listKnowledgeIntent` 响应。
pub const KnowledgeIntentListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    next_cursor: []const u8 = "",
    has_more: i64 = 0,
    intent_list: []KnowledgeIntent = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 统计（statistic）请求 / 响应
// ─────────────────────────────────────────────────────────────────────────────

/// 企业汇总数据请求（`get_corp_statistic`）。
pub const CorpStatisticRequest = struct {
    open_kfid: []const u8 = "",
    /// 开始时间（Unix 秒）。
    start_time: i64 = 0,
    /// 结束时间（Unix 秒）。
    end_time: i64 = 0,
};

/// 接待人员明细数据请求（`get_servicer_statistic`）。
pub const ServicerStatisticRequest = struct {
    open_kfid: []const u8 = "",
    servicer_userid: []const u8 = "",
    /// 开始时间（Unix 秒）。
    start_time: i64 = 0,
    /// 结束时间（Unix 秒）。
    end_time: i64 = 0,
};

/// 企业汇总统计一天的统计数据。
pub const CorpStatistic = struct {
    session_cnt: i64 = 0,
    customer_cnt: i64 = 0,
    customer_msg_cnt: i64 = 0,
    upgrade_service_customer_cnt: i64 = 0,
    ai_session_reply_cnt: i64 = 0,
    ai_transfer_rate: f64 = 0,
    ai_knowledge_hit_rate: f64 = 0,
    msg_rejected_customer_cnt: i64 = 0,
};

pub const CorpStatisticItem = struct {
    /// 数据统计日期（Unix 秒）。
    stat_time: i64 = 0,
    statistic: CorpStatistic = .{},
};

/// `getCorpStatistic` 响应。
pub const CorpStatisticResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    statistic_list: []CorpStatisticItem = &.{},
};

/// 接待人员明细统计一天的统计数据。
pub const ServicerStatistic = struct {
    session_cnt: i64 = 0,
    customer_cnt: i64 = 0,
    customer_msg_cnt: i64 = 0,
    reply_rate: f64 = 0,
    first_reply_average_sec: f64 = 0,
    satisfaction_investgate_cnt: i64 = 0,
    satisfaction_participation_rate: f64 = 0,
    satisfied_rate: f64 = 0,
    middling_rate: f64 = 0,
    dissatisfied_rate: f64 = 0,
    upgrade_service_customer_cnt: i64 = 0,
    upgrade_service_member_invite_cnt: i64 = 0,
    upgrade_service_member_customer_cnt: i64 = 0,
    upgrade_service_groupchat_invite_cnt: i64 = 0,
    upgrade_service_groupchat_customer_cnt: i64 = 0,
    msg_rejected_customer_cnt: i64 = 0,
};

pub const ServicerStatisticItem = struct {
    stat_time: i64 = 0,
    statistic: ServicerStatistic = .{},
};

/// `getServicerStatistic` 响应。
pub const ServicerStatisticResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    statistic_list: []ServicerStatisticItem = &.{},
};

/// `getCorpQualification` 响应（视频号绑定状态）。
pub const CorpQualificationResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 企业是否有绑定成功的视频号。
    wechat_channels_binding: bool = false,
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 微信客服子模块。
pub const Kf = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    // ── 内部辅助 ────────────────────────────────────────────────────────────

    /// 解析微信 JSON 响应：失败转 `DecodeError`，errcode != 0 转 `ApiError`。
    fn parseChecked(self: *Self, comptime T: type, body: []const u8) !std.json.Parsed(T) {
        var parsed = std.json.parseFromSlice(T, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// POST JSON 到 `url?access_token=...` 并解析响应。
    ///
    /// 取 token / 拼 URI / 发请求 / errcode 检查（含 token 失效后作废缓存并重试一次）
    /// 统一走 `util/retry.callApi`，`Req.send` 只负责「用给定 token 发一次请求」。
    fn postJsonParsed(self: *Self, comptime T: type, url: []const u8, body: []const u8) !std.json.Parsed(T) {
        const Req = struct {
            url: []const u8,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}",
                    .{ c.url, token },
                );
                defer allocator.free(uri);

                const client = util_http.getDefaultClient(allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, apiNameFromURL(url), Req{ .url = url, .body = body });
        defer self.allocator.free(resp);

        return self.parseChecked(T, resp);
    }

    /// GET `url?access_token=...` 并解析响应。
    fn getParsed(self: *Self, comptime T: type, url: []const u8) !std.json.Parsed(T) {
        const Req = struct {
            url: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}",
                    .{ c.url, token },
                );
                defer allocator.free(uri);

                const client = util_http.getDefaultClient(allocator);
                return client.get(uri);
            }
        };

        const body = try util_retry.callApi(self.ctx, self.allocator, apiNameFromURL(url), Req{ .url = url });
        defer self.allocator.free(body);

        return self.parseChecked(T, body);
    }

    // ── 客服账号 ────────────────────────────────────────────────────────────

    /// 拉取客服账号列表。
    ///
    /// 对应 `_ref/wechat/work/kf/account.go` 的 `AccountList`。
    /// 返回的 `std.json.Parsed(AccountListResponse)` 由调用方持有并负责 `deinit`。
    pub fn getAccountList(self: *Self) !std.json.Parsed(AccountListResponse) {
        return self.getParsed(AccountListResponse, accountListURL);
    }

    /// 分页拉取客服账号列表。
    ///
    /// 对应 `_ref/wechat/work/kf/account.go` 的 `AccountPaging`（POST 同一 list 端点）。
    pub fn getAccountPage(self: *Self, req: AccountPageRequest) !std.json.Parsed(AccountListResponse) {
        const body = try jsonStringifyAccountPage(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(AccountListResponse, accountListURL, body);
    }

    /// 添加客服账号。
    ///
    /// 对应 `_ref/wechat/work/kf/account.go` 的 `AccountAdd`。
    pub fn addAccount(self: *Self, req: AccountAddRequest) !std.json.Parsed(AccountAddResponse) {
        if (req.name.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyAccountAdd(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(AccountAddResponse, accountAddURL, body);
    }

    /// 删除客服账号。
    ///
    /// 对应 `_ref/wechat/work/kf/account.go` 的 `AccountDel`。
    pub fn delAccount(self: *Self, req: AccountDelRequest) !std.json.Parsed(CommonResponse) {
        if (req.open_kfid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyAccountDel(self.allocator, req.open_kfid);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, accountDelURL, body);
    }

    /// 修改客服账号。
    ///
    /// 对应 `_ref/wechat/work/kf/account.go` 的 `AccountUpdate`。
    pub fn updateAccount(self: *Self, req: AccountUpdateRequest) !std.json.Parsed(CommonResponse) {
        if (req.open_kfid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyAccountUpdate(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, accountUpdateURL, body);
    }

    /// 获取客服账号链接。
    ///
    /// 对应 `_ref/wechat/work/kf/account.go` 的 `AddContactWay`。
    pub fn addContactWay(self: *Self, req: ContactWayRequest) !std.json.Parsed(ContactWayResponse) {
        if (req.open_kfid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyContactWay(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(ContactWayResponse, addContactWayURL, body);
    }

    // ── 接待人员 ────────────────────────────────────────────────────────────

    /// 添加接待人员。
    ///
    /// 对应 `_ref/wechat/work/kf/servicer.go` 的 `ReceptionistAdd`。
    pub fn addServicer(self: *Self, req: ServicerRequest) !std.json.Parsed(ServicerResponse) {
        if (req.open_kfid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyServicer(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(ServicerResponse, servicerAddURL, body);
    }

    /// 删除接待人员。
    ///
    /// 对应 `_ref/wechat/work/kf/servicer.go` 的 `ReceptionistDel`。
    pub fn delServicer(self: *Self, req: ServicerRequest) !std.json.Parsed(ServicerResponse) {
        if (req.open_kfid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyServicer(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(ServicerResponse, servicerDelURL, body);
    }

    /// 获取接待人员列表。
    ///
    /// 对应 `_ref/wechat/work/kf/servicer.go` 的 `ReceptionistList`。
    /// `open_kfid` 直接拼接在 query 上（与 Go 一致，不做额外转义）。
    pub fn getServicerList(self: *Self, open_kfid: []const u8) !std.json.Parsed(ServicerListResponse) {
        if (open_kfid.len == 0) return util_error.WechatError.InvalidArgument;

        const Req = struct {
            open_kfid: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}&open_kfid={s}",
                    .{ servicerListURL, token, c.open_kfid },
                );
                defer allocator.free(uri);

                const client = util_http.getDefaultClient(allocator);
                return client.get(uri);
            }
        };

        const body = try util_retry.callApi(self.ctx, self.allocator, apiNameFromURL(servicerListURL), Req{ .open_kfid = open_kfid });
        defer self.allocator.free(body);

        return self.parseChecked(ServicerListResponse, body);
    }

    // ── 会话状态 ────────────────────────────────────────────────────────────

    /// 获取会话状态。
    ///
    /// 对应 `_ref/wechat/work/kf/servicestate.go` 的 `ServiceStateGet`。
    pub fn getServiceState(self: *Self, req: ServiceStateGetRequest) !std.json.Parsed(ServiceStateGetResponse) {
        if (req.open_kfid.len == 0 or req.external_userid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyServiceStateGet(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(ServiceStateGetResponse, serviceStateGetURL, body);
    }

    /// 变更会话状态。
    ///
    /// 对应 `_ref/wechat/work/kf/servicestate.go` 的 `ServiceStateTrans`。
    pub fn transServiceState(self: *Self, req: ServiceStateTransRequest) !std.json.Parsed(ServiceStateTransResponse) {
        if (req.open_kfid.len == 0 or req.external_userid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyServiceStateTrans(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(ServiceStateTransResponse, serviceStateTransURL, body);
    }

    // ── 消息 ────────────────────────────────────────────────────────────────

    /// 客服向客户发送文本消息。
    ///
    /// 对应 `_ref/wechat/work/kf/sendmsg.go` 的 `SendMsg`，并固定 `msgtype = "text"`。
    /// 返回的 `std.json.Parsed(SendMsgResponse)` 由调用方持有并负责 `deinit`。
    pub fn sendMsg(self: *Self, msg: TextMessage) !std.json.Parsed(SendMsgResponse) {
        if (msg.open_kfid.len == 0 or msg.touser.len == 0 or msg.content.len == 0) {
            return util_error.WechatError.InvalidArgument;
        }

        const Req = struct {
            msg: TextMessage,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "{s}?access_token={s}",
                    .{ sendMsgURL, token },
                );
                defer allocator.free(uri);

                const body = try encodeTextMessageJson(allocator, c.msg);
                defer allocator.free(body);

                const client = util_http.getDefaultClient(allocator);
                return client.postJSON(uri, body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, apiNameFromURL(sendMsgURL), Req{ .msg = msg });
        defer self.allocator.free(resp);

        return self.parseChecked(SendMsgResponse, resp);
    }

    /// 客服向客户发送富媒体消息。
    ///
    /// 对应 `_ref/wechat/work/kf/sendmsg.go` 的 `SendMsg`（Go 侧接受
    /// `interface{}`，Zig 侧以 `SendMessage` union 在编译期约束消息体）；
    /// `.text` 分支编码结果与 `sendMsg` 完全一致。限频：客户主动发消息后的
    /// 48 小时内最多可发 5 条；若用户继续发送消息，企业可再次下发。
    /// 返回的 `std.json.Parsed(SendMsgResponse)` 由调用方持有并负责 `deinit`。
    pub fn sendMsgRich(self: *Self, msg: SendMessage) !std.json.Parsed(SendMsgResponse) {
        try validateSendMessage(msg);
        const body = try jsonStringifySendMessage(self.allocator, msg);
        defer self.allocator.free(body);
        return self.postJsonParsed(SendMsgResponse, sendMsgURL, body);
    }

    /// 发送事件响应文本消息（欢迎语 / 提示语 / 结束语）。
    ///
    /// 对应 `_ref/wechat/work/kf/sendmsgonevent.go` 的 `SendMsgOnEvent`，固定 `msgtype = "text"`。
    pub fn sendMsgOnEvent(self: *Self, msg: TextEventMessage) !std.json.Parsed(SendMsgResponse) {
        if (msg.code.len == 0 or msg.content.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyTextEventMessage(self.allocator, msg);
        defer self.allocator.free(body);
        return self.postJsonParsed(SendMsgResponse, sendMsgOnEventURL, body);
    }

    /// 获取消息（游标式增量拉取）。
    ///
    /// 对应 `_ref/wechat/work/kf/syncmsg.go` 的 `SyncMsg`。
    /// 首次调用 `cursor` 留空；之后每次传入上次返回的 `next_cursor`。
    /// 返回 `has_more == 1` 时必须继续拉取，即便 `msg_list` 为空。
    ///
    /// 每条 `SyncMessage` 同时保留原始 JSON（`origin_data`，等价 Go 的
    /// `OriginData`），可用 `getOriginData` / `originAs` / `originPayloadAs`
    /// 二次解析，应对微信新增字段与新 `msgtype`。原始 JSON 随返回的
    /// `Parsed(SyncMsgResponse).deinit()` 释放。
    pub fn syncMsg(self: *Self, req: SyncMsgRequest) !std.json.Parsed(SyncMsgResponse) {
        if (req.limit > 1000) return util_error.WechatError.InvalidArgument;
        const body = try encodeSyncMsgJson(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(SyncMsgResponse, syncMsgURL, body);
    }

    // ── 客户 ────────────────────────────────────────────────────────────────

    /// 客户基本信息批量获取。
    ///
    /// 对应 `_ref/wechat/work/kf/customer.go` 的 `CustomerBatchGet`。
    pub fn customerBatchGet(self: *Self, req: CustomerBatchGetRequest) !std.json.Parsed(CustomerBatchGetResponse) {
        if (req.external_userid_list.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyCustomerBatchGet(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CustomerBatchGetResponse, customerBatchGetURL, body);
    }

    // ── 升级服务 ────────────────────────────────────────────────────────────

    /// 获取配置的专员与客户群。
    ///
    /// 对应 `_ref/wechat/work/kf/upgrade.go` 的 `UpgradeServiceConfig`。
    pub fn getUpgradeServiceConfig(self: *Self) !std.json.Parsed(UpgradeServiceConfigResponse) {
        return self.getParsed(UpgradeServiceConfigResponse, upgradeServiceConfigURL);
    }

    /// 为客户升级服务（同时携带专员与客户群字段，对齐 Go `UpgradeService`）。
    pub fn upgradeService(self: *Self, req: UpgradeServiceRequest) !std.json.Parsed(CommonResponse) {
        if (req.open_kfid.len == 0 or req.external_userid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyUpgradeService(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, upgradeServiceURL, body);
    }

    /// 为客户升级为专员服务（type=1）。
    ///
    /// 对应 `_ref/wechat/work/kf/upgrade.go` 的 `UpgradeMemberService`。
    pub fn upgradeMemberService(self: *Self, req: UpgradeMemberServiceRequest) !std.json.Parsed(CommonResponse) {
        if (req.open_kfid.len == 0 or req.external_userid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyUpgradeMemberService(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, upgradeServiceURL, body);
    }

    /// 为客户升级为客户群服务（type=2）。
    ///
    /// 对应 `_ref/wechat/work/kf/upgrade.go` 的 `UpgradeGroupChatService`。
    pub fn upgradeGroupChatService(self: *Self, req: UpgradeGroupChatServiceRequest) !std.json.Parsed(CommonResponse) {
        if (req.open_kfid.len == 0 or req.external_userid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyUpgradeGroupChatService(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, upgradeServiceURL, body);
    }

    /// 为客户取消推荐。
    ///
    /// 对应 `_ref/wechat/work/kf/upgrade.go` 的 `UpgradeServiceCancel`。
    pub fn cancelUpgradeService(self: *Self, req: UpgradeServiceCancelRequest) !std.json.Parsed(CommonResponse) {
        if (req.open_kfid.len == 0 or req.external_userid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyUpgradeServiceCancel(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, upgradeServiceCancelURL, body);
    }

    // ── 知识库：分组 ────────────────────────────────────────────────────────

    /// 知识库分组添加。
    ///
    /// 对应 `_ref/wechat/work/kf/knowledge.go` 的 `AddKnowledgeGroup`。
    pub fn addKnowledgeGroup(self: *Self, req: KnowledgeGroupAddRequest) !std.json.Parsed(KnowledgeGroupAddResponse) {
        if (req.name.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyKnowledgeGroupAdd(self.allocator, req.name);
        defer self.allocator.free(body);
        return self.postJsonParsed(KnowledgeGroupAddResponse, knowledgeAddGroupURL, body);
    }

    /// 知识库分组删除。
    ///
    /// 对应 `_ref/wechat/work/kf/knowledge.go` 的 `DelKnowledgeGroup`。
    pub fn delKnowledgeGroup(self: *Self, req: KnowledgeGroupDelRequest) !std.json.Parsed(CommonResponse) {
        if (req.group_id.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyKnowledgeGroupDel(self.allocator, req.group_id);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, knowledgeDelGroupURL, body);
    }

    /// 知识库分组修改。
    ///
    /// 对应 `_ref/wechat/work/kf/knowledge.go` 的 `ModKnowledgeGroup`。
    pub fn modKnowledgeGroup(self: *Self, req: KnowledgeGroupModRequest) !std.json.Parsed(CommonResponse) {
        if (req.group_id.len == 0 or req.name.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyKnowledgeGroupMod(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, knowledgeModGroupURL, body);
    }

    /// 知识库分组列表（游标分页）。
    ///
    /// 对应 `_ref/wechat/work/kf/knowledge.go` 的 `ListKnowledgeGroup`。
    pub fn listKnowledgeGroup(self: *Self, req: KnowledgeGroupListRequest) !std.json.Parsed(KnowledgeGroupListResponse) {
        const body = try jsonStringifyKnowledgeGroupList(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(KnowledgeGroupListResponse, knowledgeListGroupURL, body);
    }

    // ── 知识库：问答 ────────────────────────────────────────────────────────

    /// 知识库问答添加。
    ///
    /// 对应 `_ref/wechat/work/kf/knowledge.go` 的 `AddKnowledgeIntent`。
    pub fn addKnowledgeIntent(self: *Self, req: KnowledgeIntentAddRequest) !std.json.Parsed(KnowledgeIntentAddResponse) {
        if (req.group_id.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyKnowledgeIntentAdd(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(KnowledgeIntentAddResponse, knowledgeAddIntentURL, body);
    }

    /// 知识库问答删除。
    ///
    /// 对应 `_ref/wechat/work/kf/knowledge.go` 的 `DelKnowledgeIntent`。
    pub fn delKnowledgeIntent(self: *Self, req: KnowledgeIntentDelRequest) !std.json.Parsed(CommonResponse) {
        if (req.intent_id.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyKnowledgeIntentDel(self.allocator, req.intent_id);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, knowledgeDelIntentURL, body);
    }

    /// 知识库问答修改。
    ///
    /// 对应 `_ref/wechat/work/kf/knowledge.go` 的 `ModKnowledgeIntent`。
    pub fn modKnowledgeIntent(self: *Self, req: KnowledgeIntentModRequest) !std.json.Parsed(CommonResponse) {
        if (req.intent_id.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyKnowledgeIntentMod(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CommonResponse, knowledgeModIntentURL, body);
    }

    /// 知识库问答列表（游标分页）。
    ///
    /// 对应 `_ref/wechat/work/kf/knowledge.go` 的 `ListKnowledgeIntent`。
    pub fn listKnowledgeIntent(self: *Self, req: KnowledgeIntentListRequest) !std.json.Parsed(KnowledgeIntentListResponse) {
        const body = try jsonStringifyKnowledgeIntentList(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(KnowledgeIntentListResponse, knowledgeListIntentURL, body);
    }

    // ── 统计 ────────────────────────────────────────────────────────────────

    /// 获取「客户数据统计」企业汇总数据。
    ///
    /// 对应 `_ref/wechat/work/kf/statistic.go` 的 `GetCorpStatistic`。
    pub fn getCorpStatistic(self: *Self, req: CorpStatisticRequest) !std.json.Parsed(CorpStatisticResponse) {
        if (req.open_kfid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyCorpStatistic(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(CorpStatisticResponse, corpStatisticURL, body);
    }

    /// 获取「客户数据统计」接待人员明细数据。
    ///
    /// 对应 `_ref/wechat/work/kf/statistic.go` 的 `GetServicerStatistic`。
    pub fn getServicerStatistic(self: *Self, req: ServicerStatisticRequest) !std.json.Parsed(ServicerStatisticResponse) {
        if (req.open_kfid.len == 0) return util_error.WechatError.InvalidArgument;
        const body = try jsonStringifyServicerStatistic(self.allocator, req);
        defer self.allocator.free(body);
        return self.postJsonParsed(ServicerStatisticResponse, servicerStatisticURL, body);
    }

    // ── 其他 ────────────────────────────────────────────────────────────────

    /// 获取视频号绑定状态。
    ///
    /// 对应 `_ref/wechat/work/kf/other.go` 的 `GetCorpQualification`。
    pub fn getCorpQualification(self: *Self) !std.json.Parsed(CorpQualificationResponse) {
        return self.getParsed(CorpQualificationResponse, corpQualificationURL);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：手写 JSON 序列化（TextMessage / SyncMsgRequest）
// ─────────────────────────────────────────────────────────────────────────────

/// 取接口 URL 的末段作为 `api_name`（喂给 `util/retry.callApi`，进错误详情），
/// 如 `.../cgi-bin/kf/account/list` → `list`。
fn apiNameFromURL(url: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[idx + 1 ..];
}

/// 编码 `TextMessage` 为
/// `{"touser":"...","open_kfid":"...","msgtype":"text","text":{"content":"..."}}`。
fn encodeTextMessageJson(allocator: std.mem.Allocator, msg: TextMessage) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"touser\":\"");
    try appendJsonString(allocator, &buf, msg.touser);
    try buf.appendSlice(allocator, "\",\"open_kfid\":\"");
    try appendJsonString(allocator, &buf, msg.open_kfid);
    try buf.appendSlice(allocator, "\",\"msgtype\":\"text\",\"text\":{\"content\":\"");
    try appendJsonString(allocator, &buf, msg.content);
    try buf.appendSlice(allocator, "\"}}");
    return buf.toOwnedSlice(allocator);
}

/// 编码 `SyncMsgRequest` 为 sync_msg 请求体。
///
/// `voice_format` 为 0、`open_kfid` 为空时不写入请求体（对齐 Go 的 `omitempty`）。
fn encodeSyncMsgJson(allocator: std.mem.Allocator, req: SyncMsgRequest) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"cursor\":\"");
    try appendJsonString(allocator, &buf, req.cursor);
    try buf.appendSlice(allocator, "\",\"token\":\"");
    try appendJsonString(allocator, &buf, req.token);
    try buf.appendSlice(allocator, "\",\"limit\":");
    var num: [20]u8 = undefined;
    try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{req.limit}) catch unreachable);
    if (req.voice_format != 0) {
        try buf.appendSlice(allocator, ",\"voice_format\":");
        try buf.appendSlice(allocator, std.fmt.bufPrint(&num, "{d}", .{req.voice_format}) catch unreachable);
    }
    if (req.open_kfid.len > 0) {
        try buf.appendSlice(allocator, ",\"open_kfid\":\"");
        try appendJsonString(allocator, &buf, req.open_kfid);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

/// JSON 字符串转义（实现收敛到 `util.json.appendEscapedString`；
/// 同时把 `\b`/`\f` 由 `\u0008`/`\u000c` 改为与 Go / `std.json` 一致的短转义）。
const appendJsonString = util_json.appendEscapedString;

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：std.json.Stringify 请求体编码
// ─────────────────────────────────────────────────────────────────────────────

fn jsonStringifyAccountAdd(allocator: std.mem.Allocator, req: AccountAddRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("name");
    try s.write(req.name);
    try s.objectField("media_id");
    try s.write(req.media_id);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyAccountDel(allocator: std.mem.Allocator, open_kfid: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(open_kfid);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyAccountUpdate(allocator: std.mem.Allocator, req: AccountUpdateRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(req.open_kfid);
    try s.objectField("name");
    try s.write(req.name);
    try s.objectField("media_id");
    try s.write(req.media_id);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyAccountPage(allocator: std.mem.Allocator, req: AccountPageRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("offset");
    try s.write(req.offset);
    try s.objectField("limit");
    try s.write(req.limit);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyContactWay(allocator: std.mem.Allocator, req: ContactWayRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(req.open_kfid);
    try s.objectField("scene");
    try s.write(req.scene);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyServicer(allocator: std.mem.Allocator, req: ServicerRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(req.open_kfid);
    try s.objectField("userid_list");
    try s.beginArray();
    for (req.userid_list) |id| try s.write(id);
    try s.endArray();
    try s.objectField("department_id_list");
    try s.beginArray();
    for (req.department_id_list) |id| try s.write(id);
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyServiceStateGet(allocator: std.mem.Allocator, req: ServiceStateGetRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(req.open_kfid);
    try s.objectField("external_userid");
    try s.write(req.external_userid);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyServiceStateTrans(allocator: std.mem.Allocator, req: ServiceStateTransRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(req.open_kfid);
    try s.objectField("external_userid");
    try s.write(req.external_userid);
    try s.objectField("service_state");
    try s.write(req.service_state);
    try s.objectField("servicer_userid");
    try s.write(req.servicer_userid);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyTextEventMessage(allocator: std.mem.Allocator, msg: TextEventMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("code");
    try s.write(msg.code);
    try s.objectField("msgid");
    try s.write(msg.msgid);
    try s.objectField("msgtype");
    try s.write("text");
    try s.objectField("text");
    try s.beginObject();
    try s.objectField("content");
    try s.write(msg.content);
    try s.endObject();
    try s.endObject();
    return out.toOwnedSlice();
}

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：富媒体消息编码（sendMsgRich）
// ─────────────────────────────────────────────────────────────────────────────

/// 校验 `SendMessage` 必填字段（对齐各消息类型的微信文档必填项）。
fn validateSendMessage(msg: SendMessage) !void {
    switch (msg) {
        .text => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.content.len == 0) {
                return util_error.WechatError.InvalidArgument;
            }
        },
        .image => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.media_id.len == 0) {
                return util_error.WechatError.InvalidArgument;
            }
        },
        .voice => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.media_id.len == 0) {
                return util_error.WechatError.InvalidArgument;
            }
        },
        .video => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.media_id.len == 0) {
                return util_error.WechatError.InvalidArgument;
            }
        },
        .file => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.media_id.len == 0) {
                return util_error.WechatError.InvalidArgument;
            }
        },
        .link => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.title.len == 0 or m.url.len == 0) {
                return util_error.WechatError.InvalidArgument;
            }
        },
        .miniprogram => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.appid.len == 0 or m.pagepath.len == 0) {
                return util_error.WechatError.InvalidArgument;
            }
        },
        .menu => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.head_content.len == 0 or
                m.list.len == 0 or m.list.len > 10)
            {
                return util_error.WechatError.InvalidArgument;
            }
        },
        .location => |m| {
            if (m.open_kfid.len == 0 or m.touser.len == 0 or m.name.len == 0) {
                return util_error.WechatError.InvalidArgument;
            }
        },
    }
}

/// 写入发送消息公共头部：`touser` / `open_kfid` / `msgid`（非空才写，对齐 Go `omitempty`）/ `msgtype`。
fn writeSendHead(
    s: *std.json.Stringify,
    touser: []const u8,
    open_kfid: []const u8,
    msgid: []const u8,
    msgtype: []const u8,
) !void {
    try s.objectField("touser");
    try s.write(touser);
    try s.objectField("open_kfid");
    try s.write(open_kfid);
    if (msgid.len > 0) {
        try s.objectField("msgid");
        try s.write(msgid);
    }
    try s.objectField("msgtype");
    try s.write(msgtype);
}

/// 写入菜单项列表（`msgmenu.list`）。
fn writeMenuItemList(s: *std.json.Stringify, list: []const MenuItem) !void {
    try s.beginArray();
    for (list) |item| {
        switch (item) {
            .click => |it| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("click");
                try s.objectField("click");
                try s.beginObject();
                try s.objectField("id");
                try s.write(it.id);
                try s.objectField("content");
                try s.write(it.content);
                try s.endObject();
                try s.endObject();
            },
            .view => |it| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("view");
                try s.objectField("view");
                try s.beginObject();
                try s.objectField("url");
                try s.write(it.url);
                try s.objectField("content");
                try s.write(it.content);
                try s.endObject();
                try s.endObject();
            },
            .miniprogram => |it| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("miniprogram");
                try s.objectField("miniprogram");
                try s.beginObject();
                try s.objectField("appid");
                try s.write(it.appid);
                try s.objectField("pagepath");
                try s.write(it.pagepath);
                try s.objectField("content");
                try s.write(it.content);
                try s.endObject();
                try s.endObject();
            },
        }
    }
    try s.endArray();
}

/// 编码 `SendMessage` 为 send_msg 请求体。
///
/// `.text` 分支复用 `encodeTextMessageJson`，与 `sendMsg` 输出逐字节一致；
/// 其余分支输出对应负载对象（image/voice/video/file/link/miniprogram/
/// msgmenu/location）。
fn jsonStringifySendMessage(allocator: std.mem.Allocator, msg: SendMessage) ![]u8 {
    if (msg == .text) return encodeTextMessageJson(allocator, msg.text);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    switch (msg) {
        .image => |m| {
            try writeSendHead(&s, m.touser, m.open_kfid, m.msgid, "image");
            try s.objectField("image");
            try s.beginObject();
            try s.objectField("media_id");
            try s.write(m.media_id);
            try s.endObject();
        },
        .voice => |m| {
            try writeSendHead(&s, m.touser, m.open_kfid, m.msgid, "voice");
            try s.objectField("voice");
            try s.beginObject();
            try s.objectField("media_id");
            try s.write(m.media_id);
            try s.endObject();
        },
        .video => |m| {
            try writeSendHead(&s, m.touser, m.open_kfid, m.msgid, "video");
            try s.objectField("video");
            try s.beginObject();
            try s.objectField("media_id");
            try s.write(m.media_id);
            try s.endObject();
        },
        .file => |m| {
            try writeSendHead(&s, m.touser, m.open_kfid, m.msgid, "file");
            try s.objectField("file");
            try s.beginObject();
            try s.objectField("media_id");
            try s.write(m.media_id);
            try s.endObject();
        },
        .link => |m| {
            try writeSendHead(&s, m.touser, m.open_kfid, m.msgid, "link");
            try s.objectField("link");
            try s.beginObject();
            try s.objectField("title");
            try s.write(m.title);
            try s.objectField("desc");
            try s.write(m.desc);
            try s.objectField("url");
            try s.write(m.url);
            try s.objectField("thumb_media_id");
            try s.write(m.thumb_media_id);
            try s.endObject();
        },
        .miniprogram => |m| {
            try writeSendHead(&s, m.touser, m.open_kfid, m.msgid, "miniprogram");
            try s.objectField("miniprogram");
            try s.beginObject();
            try s.objectField("appid");
            try s.write(m.appid);
            try s.objectField("title");
            try s.write(m.title);
            try s.objectField("thumb_media_id");
            try s.write(m.thumb_media_id);
            try s.objectField("pagepath");
            try s.write(m.pagepath);
            try s.endObject();
        },
        .menu => |m| {
            try writeSendHead(&s, m.touser, m.open_kfid, m.msgid, "msgmenu");
            try s.objectField("msgmenu");
            try s.beginObject();
            try s.objectField("head_content");
            try s.write(m.head_content);
            try s.objectField("list");
            try writeMenuItemList(&s, m.list);
            try s.objectField("tail_content");
            try s.write(m.tail_content);
            try s.endObject();
        },
        .location => |m| {
            try writeSendHead(&s, m.touser, m.open_kfid, m.msgid, "location");
            try s.objectField("location");
            try s.beginObject();
            try s.objectField("latitude");
            try s.write(m.latitude);
            try s.objectField("longitude");
            try s.write(m.longitude);
            try s.objectField("name");
            try s.write(m.name);
            try s.objectField("address");
            try s.write(m.address);
            try s.endObject();
        },
        .text => unreachable,
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyCustomerBatchGet(allocator: std.mem.Allocator, req: CustomerBatchGetRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("external_userid_list");
    try s.beginArray();
    for (req.external_userid_list) |id| try s.write(id);
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

fn writeUpgradeHead(
    s: *std.json.Stringify,
    open_kfid: []const u8,
    external_userid: []const u8,
    service_type: i64,
) !void {
    try s.objectField("open_kfid");
    try s.write(open_kfid);
    try s.objectField("external_userid");
    try s.write(external_userid);
    try s.objectField("type");
    try s.write(service_type);
}

fn writeUpgradeMember(s: *std.json.Stringify, member: UpgradeMember) !void {
    try s.objectField("member");
    try s.beginObject();
    try s.objectField("userid");
    try s.write(member.userid);
    try s.objectField("wording");
    try s.write(member.wording);
    try s.endObject();
}

fn writeUpgradeGroupChat(s: *std.json.Stringify, groupchat: UpgradeGroupChat) !void {
    try s.objectField("groupchat");
    try s.beginObject();
    try s.objectField("chat_id");
    try s.write(groupchat.chat_id);
    try s.objectField("wording");
    try s.write(groupchat.wording);
    try s.endObject();
}

fn jsonStringifyUpgradeService(allocator: std.mem.Allocator, req: UpgradeServiceRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try writeUpgradeHead(&s, req.open_kfid, req.external_userid, req.service_type);
    try writeUpgradeMember(&s, req.member);
    try writeUpgradeGroupChat(&s, req.groupchat);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyUpgradeMemberService(allocator: std.mem.Allocator, req: UpgradeMemberServiceRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try writeUpgradeHead(&s, req.open_kfid, req.external_userid, req.service_type);
    try writeUpgradeMember(&s, req.member);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyUpgradeGroupChatService(allocator: std.mem.Allocator, req: UpgradeGroupChatServiceRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try writeUpgradeHead(&s, req.open_kfid, req.external_userid, req.service_type);
    try writeUpgradeGroupChat(&s, req.groupchat);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyUpgradeServiceCancel(allocator: std.mem.Allocator, req: UpgradeServiceCancelRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(req.open_kfid);
    try s.objectField("external_userid");
    try s.write(req.external_userid);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyKnowledgeGroupAdd(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyKnowledgeGroupDel(allocator: std.mem.Allocator, group_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("group_id");
    try s.write(group_id);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyKnowledgeGroupMod(allocator: std.mem.Allocator, req: KnowledgeGroupModRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("group_id");
    try s.write(req.group_id);
    try s.objectField("name");
    try s.write(req.name);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyKnowledgeGroupList(allocator: std.mem.Allocator, req: KnowledgeGroupListRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("cursor");
    try s.write(req.cursor);
    try s.objectField("limit");
    try s.write(req.limit);
    try s.objectField("group_id");
    try s.write(req.group_id);
    try s.endObject();
    return out.toOwnedSlice();
}

/// 写入知识库问答的 question / similar_questions / answers 三段（add / mod 共用）。
fn writeKnowledgeIntentBody(
    s: *std.json.Stringify,
    question: IntentQuestion,
    similar_questions: IntentSimilarQuestions,
    answers: []const IntentAnswer,
) !void {
    try s.objectField("question");
    try s.beginObject();
    try s.objectField("text");
    try s.beginObject();
    try s.objectField("content");
    try s.write(question.text.content);
    try s.endObject();
    try s.endObject();

    try s.objectField("similar_questions");
    try s.beginObject();
    try s.objectField("items");
    try s.beginArray();
    for (similar_questions.items) |item| {
        try s.beginObject();
        try s.objectField("text");
        try s.beginObject();
        try s.objectField("content");
        try s.write(item.text.content);
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    try s.objectField("answers");
    try s.beginArray();
    for (answers) |a| {
        try s.beginObject();
        try s.objectField("text");
        try s.beginObject();
        try s.objectField("content");
        try s.write(a.text.content);
        try s.endObject();
        try s.objectField("attachments");
        try s.beginArray();
        for (a.attachments) |att| {
            try s.beginObject();
            try s.objectField("msgtype");
            try s.write(att.msgtype);
            try s.objectField("image");
            try s.beginObject();
            try s.objectField("media_id");
            try s.write(att.image.media_id);
            try s.endObject();
            try s.objectField("video");
            try s.beginObject();
            try s.objectField("media_id");
            try s.write(att.video.media_id);
            try s.endObject();
            try s.objectField("link");
            try s.beginObject();
            try s.objectField("title");
            try s.write(att.link.title);
            try s.objectField("picurl");
            try s.write(att.link.picurl);
            try s.objectField("desc");
            try s.write(att.link.desc);
            try s.objectField("url");
            try s.write(att.link.url);
            try s.endObject();
            try s.objectField("miniprogram");
            try s.beginObject();
            try s.objectField("title");
            try s.write(att.miniprogram.title);
            try s.objectField("thumb_media_id");
            try s.write(att.miniprogram.thumb_media_id);
            try s.objectField("appid");
            try s.write(att.miniprogram.appid);
            try s.objectField("pagepath");
            try s.write(att.miniprogram.pagepath);
            try s.endObject();
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
}

fn jsonStringifyKnowledgeIntentAdd(allocator: std.mem.Allocator, req: KnowledgeIntentAddRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("group_id");
    try s.write(req.group_id);
    try writeKnowledgeIntentBody(&s, req.question, req.similar_questions, req.answers);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyKnowledgeIntentDel(allocator: std.mem.Allocator, intent_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("intent_id");
    try s.write(intent_id);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyKnowledgeIntentMod(allocator: std.mem.Allocator, req: KnowledgeIntentModRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("intent_id");
    try s.write(req.intent_id);
    try writeKnowledgeIntentBody(&s, req.question, req.similar_questions, req.answers);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyKnowledgeIntentList(allocator: std.mem.Allocator, req: KnowledgeIntentListRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("cursor");
    try s.write(req.cursor);
    try s.objectField("limit");
    try s.write(req.limit);
    try s.objectField("group_id");
    try s.write(req.group_id);
    try s.objectField("intent_id");
    try s.write(req.intent_id);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyCorpStatistic(allocator: std.mem.Allocator, req: CorpStatisticRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(req.open_kfid);
    try s.objectField("start_time");
    try s.write(req.start_time);
    try s.objectField("end_time");
    try s.write(req.end_time);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyServicerStatistic(allocator: std.mem.Allocator, req: ServicerStatisticRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("open_kfid");
    try s.write(req.open_kfid);
    try s.objectField("servicer_userid");
    try s.write(req.servicer_userid);
    try s.objectField("start_time");
    try s.write(req.start_time);
    try s.objectField("end_time");
    try s.write(req.end_time);
    try s.endObject();
    return out.toOwnedSlice();
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：stub token + mock transport
// ─────────────────────────────────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = @import("../../credential/mod.zig").AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .corp_id = "ww-kf-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

/// 安装 mock transport 并返回默认 client（测试结束时用 `dropMock` 复位）。
fn useMock(allocator: std.mem.Allocator, mt: *util_http.MockTransport) *util_http.HttpClient {
    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(mt));
    return client;
}

fn dropMock(client: *util_http.HttpClient) void {
    client.setTransport(null, null);
    util_http.deinitDefaultClient();
}

/// 把 `msg_list` 拷进 `out` 并抹掉每条消息的 `origin_data`，返回可整体比较的切片。
///
/// `origin_data` 是 `jsonParse` 挂载的原始 JSON 树（内容由 OriginData 专项用例覆盖），
/// 解析类用例只关心强类型字段，故比较前统一置空——这样仍可用
/// `expectEqualDeep` 整体比较，失败时能打印出具体字段路径。
fn typedOnlyList(out: []SyncMessage, in: []const SyncMessage) []SyncMessage {
    std.debug.assert(out.len >= in.len);
    for (in, out[0..in.len]) |msg, *slot| {
        slot.* = msg;
        slot.origin_data = null;
    }
    return out[0..in.len];
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

test "Kf.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-kf" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const k = Kf.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-kf", k.ctx.config.corp_id);
}

test "TextMessage 默认值" {
    const m = TextMessage{};
    try std.testing.expectEqualStrings("", m.open_kfid);
    try std.testing.expectEqualStrings("", m.touser);
    try std.testing.expectEqualStrings("text", m.msgtype);
    try std.testing.expectEqualStrings("", m.content);
}

test "AccountInfo 默认值" {
    const a = AccountInfo{};
    try std.testing.expectEqualStrings("", a.open_kfid);
    try std.testing.expect(!a.manage_privilege);
}

test "AccountListResponse 默认值" {
    const r = AccountListResponse{};
    try std.testing.expectEqual(@as(usize, 0), r.account_list.len);
}

test "SendMsgResponse 默认值" {
    const r = SendMsgResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
    try std.testing.expectEqualStrings("", r.msgid);
}

test "encodeTextMessageJson 生成正确 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeTextMessageJson(alloc, .{
        .open_kfid = "kf_001",
        .touser = "ext_user_abc",
        .content = "hello \"world\"\n",
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"touser\":\"ext_user_abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"open_kfid\":\"kf_001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"msgtype\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":{\"content\":\"hello \\\"world\\\"\\n\"}") != null);
}

test "encodeTextMessageJson 转义控制字符生成合法 JSON" {
    const alloc = std.testing.allocator;
    const body = try encodeTextMessageJson(alloc, .{
        .touser = "user\x07x",
        .open_kfid = "wkf",
        .content = "beep\x07bell\x0b",
    });
    defer alloc.free(body);

    // <0x20 控制字符必须被转义，不能原样写入。
    try std.testing.expect(std.mem.indexOf(u8, body, "\\u0007") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\u000b") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\x07") == null);

    // 输出可被 std.json 解析回原文。
    const Decoded = struct {
        touser: []const u8,
        open_kfid: []const u8,
        msgtype: []const u8,
        text: struct { content: []const u8 },
    };
    var parsed = try std.json.parseFromSlice(Decoded, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("user\x07x", parsed.value.touser);
    try std.testing.expectEqualStrings("beep\x07bell\x0b", parsed.value.text.content);
}

// ── 客服账号 ──────────────────────────────────────────────────────────────────

test "addAccount POST account/add 并解析 open_kfid" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/account/add?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"open_kfid\":\"wkf_new001\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.addAccount(.{ .name = "客服一号", .media_id = "m_1" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("wkf_new001", parsed.value.open_kfid);
}

test "addAccount name 为空返回 InvalidArgument" {
    var ctx = makeCtx();
    var k = Kf.init(&ctx, std.testing.allocator);
    const result = k.addAccount(.{ .name = "" });
    try std.testing.expectError(util_error.WechatError.InvalidArgument, result);
}

test "delAccount POST account/del 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/account/del?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.delAccount(.{ .open_kfid = "wkf_del001" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "delAccount errcode!=0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/account/del?access_token=token-abc", .{
        .body = "{\"errcode\":95074,\"errmsg\":\"open_kfid not exist\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    const result = k.delAccount(.{ .open_kfid = "wkf_bad" });
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "updateAccount POST account/update 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/account/update?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.updateAccount(.{ .open_kfid = "wkf_1", .name = "新名字", .media_id = "m_2" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
}

test "getAccountPage POST account/list 带 offset/limit 分页" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/account/list?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"account_list\":[{\"open_kfid\":\"wkf_p1\",\"name\":\"分页账号\",\"avatar\":\"http://a/1.png\",\"manage_privilege\":true}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.getAccountPage(.{ .offset = 10, .limit = 20 });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.account_list.len);
    try std.testing.expectEqualStrings("wkf_p1", parsed.value.account_list[0].open_kfid);
    try std.testing.expect(parsed.value.account_list[0].manage_privilege);
}

test "addContactWay POST add_contact_way 并解析 url" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/add_contact_way?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://work.weixin.qq.com/kf/kfcbf8f8d07ac7215f?enc_scene=ENCGFSDF567DF\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.addContactWay(.{ .open_kfid = "wkf_1", .scene = "s_123" });
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.url, "enc_scene=") != null);
}

// ── 接待人员 ──────────────────────────────────────────────────────────────────

test "addServicer POST servicer/add 并解析 result_list" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/servicer/add?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"result_list\":[{\"userid\":\"zhangsan\",\"department_id\":0,\"errcode\":0,\"errmsg\":\"ok\"},{\"userid\":\"lisi\",\"department_id\":2,\"errcode\":0,\"errmsg\":\"ok\"}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.addServicer(.{
        .open_kfid = "wkf_1",
        .userid_list = &.{ "zhangsan", "lisi" },
        .department_id_list = &.{2},
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.result_list.len);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.result_list[0].userid);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.result_list[1].department_id);
}

test "delServicer POST servicer/del 并解析 result_list" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/servicer/del?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"result_list\":[{\"userid\":\"wangwu\",\"department_id\":0,\"errcode\":0,\"errmsg\":\"ok\"}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.delServicer(.{
        .open_kfid = "wkf_1",
        .userid_list = &.{"wangwu"},
        .department_id_list = &.{},
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.result_list.len);
    try std.testing.expectEqualStrings("wangwu", parsed.value.result_list[0].userid);
}

test "getServicerList GET servicer/list 拼 open_kfid query" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/servicer/list?access_token=token-abc&open_kfid=wkf_1", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"servicer_list\":[{\"userid\":\"zhangsan\",\"status\":0,\"department_id\":0,\"stop_type\":0},{\"userid\":\"lisi\",\"status\":1,\"department_id\":2,\"stop_type\":1}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.getServicerList("wkf_1");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.servicer_list.len);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.servicer_list[1].status);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.servicer_list[1].stop_type);
}

// ── 会话状态 ──────────────────────────────────────────────────────────────────

test "getServiceState POST service_state/get 并解析 service_state" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/service_state/get?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"service_state\":3,\"service_userid\":\"zhangsan\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.getServiceState(.{ .open_kfid = "wkf_1", .external_userid = "wm_ext_1" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 3), parsed.value.service_state);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.service_userid);
}

test "transServiceState POST service_state/trans 并解析 msg_code" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/service_state/trans?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_code\":\"code_123\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.transServiceState(.{
        .open_kfid = "wkf_1",
        .external_userid = "wm_ext_1",
        .service_state = 3,
        .servicer_userid = "zhangsan",
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("code_123", parsed.value.msg_code);
}

// ── 消息 ────────────────────────────────────────────────────────────────────

test "sendMsgOnEvent POST send_msg_on_event 并解析 msgid" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg_on_event?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_evt_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgOnEvent(.{
        .code = "welcome_code_1",
        .msgid = "msg_evt_1",
        .content = "您好，欢迎咨询",
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_evt_1", parsed.value.msgid);
}

test "syncMsg POST sync_msg 游标与 has_more 解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/sync_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"cursor_next_456\",\"has_more\":1,\"msg_list\":[{\"msgid\":\"msg_1\",\"open_kfid\":\"wkf_1\",\"external_userid\":\"wm_ext_1\",\"servicer_userid\":\"zhangsan\",\"send_time\":1700000000,\"origin\":3,\"msgtype\":\"text\",\"text\":{\"content\":\"你好\"}},{\"msgid\":\"evt_1\",\"send_time\":1700000001,\"origin\":4,\"msgtype\":\"event\",\"event\":{\"event_type\":\"enter_session\",\"open_kfid\":\"wkf_1\",\"external_userid\":\"wm_ext_1\",\"welcome_code\":\"wc_1\"}}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.syncMsg(.{
        .cursor = "cursor_prev_123",
        .token = "tk_1",
        .limit = 100,
        .voice_format = 1,
        .open_kfid = "wkf_1",
    });
    defer parsed.deinit();

    // 游标机制：next_cursor 出参供下次增量拉取。
    // 整体比较覆盖每条 SyncMessage 的全部字段（消息级 origin_data 由 typedOnlyList 抹掉）。
    var want = [_]SyncMessage{
        .{
            .msgid = "msg_1",
            .open_kfid = "wkf_1",
            .external_userid = "wm_ext_1",
            .servicer_userid = "zhangsan",
            .send_time = 1700000000,
            .origin = 3,
            .msgtype = "text",
            .text = .{ .content = "你好" },
        },
        .{
            .msgid = "evt_1",
            .send_time = 1700000001,
            .origin = 4,
            .msgtype = "event",
            .event = .{
                // 事件消息不返回顶层 open_kfid / external_userid（应为默认空串）。
                .event_type = "enter_session",
                .open_kfid = "wkf_1",
                .external_userid = "wm_ext_1",
                .welcome_code = "wc_1",
            },
        },
    };
    try std.testing.expectEqual(@as(usize, want.len), parsed.value.msg_list.len);

    // 实际值：把 origin_data 抹掉的副本（expected/actual 的参数顺序不能颠倒）。
    var got_buf: [want.len]SyncMessage = undefined;
    var got = parsed.value;
    got.msg_list = typedOnlyList(&got_buf, parsed.value.msg_list);
    try std.testing.expectEqualDeep(SyncMsgResponse{
        .errmsg = "ok",
        .next_cursor = "cursor_next_456",
        .has_more = 1,
        .msg_list = &want,
    }, got);
}

test "syncMsg limit 超过 1000 返回 InvalidArgument" {
    var ctx = makeCtx();
    var k = Kf.init(&ctx, std.testing.allocator);
    const result = k.syncMsg(.{ .limit = 1001 });
    try std.testing.expectError(util_error.WechatError.InvalidArgument, result);
}

// ── 富媒体消息（sendMsgRich） ────────────────────────────────────────────────

test "jsonStringifySendMessage 各消息类型 body JSON" {
    const alloc = std.testing.allocator;

    // text 分支与 sendMsg 编码逐字节一致。
    const rich_text = try jsonStringifySendMessage(alloc, .{
        .text = .{ .open_kfid = "kf_1", .touser = "wm_1", .content = "hi" },
    });
    defer alloc.free(rich_text);
    const plain_text = try encodeTextMessageJson(alloc, .{ .open_kfid = "kf_1", .touser = "wm_1", .content = "hi" });
    defer alloc.free(plain_text);
    try std.testing.expectEqualStrings(plain_text, rich_text);

    const image = try jsonStringifySendMessage(alloc, .{
        .image = .{ .open_kfid = "kf_1", .touser = "wm_1", .msgid = "m_1", .media_id = "media_img" },
    });
    defer alloc.free(image);
    try std.testing.expectEqualStrings(
        "{\"touser\":\"wm_1\",\"open_kfid\":\"kf_1\",\"msgid\":\"m_1\",\"msgtype\":\"image\",\"image\":{\"media_id\":\"media_img\"}}",
        image,
    );

    const voice = try jsonStringifySendMessage(alloc, .{
        .voice = .{ .open_kfid = "kf_1", .touser = "wm_1", .media_id = "media_v" },
    });
    defer alloc.free(voice);
    // msgid 为空时不写入（对齐 Go omitempty）。
    try std.testing.expect(std.mem.indexOf(u8, voice, "msgid") == null);
    try std.testing.expect(std.mem.indexOf(u8, voice, "\"msgtype\":\"voice\",\"voice\":{\"media_id\":\"media_v\"}") != null);

    const video = try jsonStringifySendMessage(alloc, .{
        .video = .{ .open_kfid = "kf_1", .touser = "wm_1", .media_id = "media_vid" },
    });
    defer alloc.free(video);
    try std.testing.expect(std.mem.indexOf(u8, video, "\"msgtype\":\"video\",\"video\":{\"media_id\":\"media_vid\"}") != null);

    const file = try jsonStringifySendMessage(alloc, .{
        .file = .{ .open_kfid = "kf_1", .touser = "wm_1", .media_id = "media_f" },
    });
    defer alloc.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "\"msgtype\":\"file\",\"file\":{\"media_id\":\"media_f\"}") != null);

    const link = try jsonStringifySendMessage(alloc, .{
        .link = .{
            .open_kfid = "kf_1",
            .touser = "wm_1",
            .title = "标题 \"引号\"",
            .desc = "描述",
            .url = "https://example.com/faq",
            .thumb_media_id = "media_t",
        },
    });
    defer alloc.free(link);
    try std.testing.expect(std.mem.indexOf(u8, link, "\"msgtype\":\"link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, link, "\"link\":{\"title\":\"标题 \\\"引号\\\"\",\"desc\":\"描述\",\"url\":\"https://example.com/faq\",\"thumb_media_id\":\"media_t\"}") != null);

    const miniprogram = try jsonStringifySendMessage(alloc, .{
        .miniprogram = .{
            .open_kfid = "kf_1",
            .touser = "wm_1",
            .appid = "wx_mp_1",
            .title = "小程序标题",
            .thumb_media_id = "media_t",
            .pagepath = "pages/faq/index",
        },
    });
    defer alloc.free(miniprogram);
    try std.testing.expect(std.mem.indexOf(u8, miniprogram, "\"msgtype\":\"miniprogram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, miniprogram, "\"miniprogram\":{\"appid\":\"wx_mp_1\",\"title\":\"小程序标题\",\"thumb_media_id\":\"media_t\",\"pagepath\":\"pages/faq/index\"}") != null);

    const location = try jsonStringifySendMessage(alloc, .{
        .location = .{
            .open_kfid = "kf_1",
            .touser = "wm_1",
            .latitude = 39.9042,
            .longitude = 116.4074,
            .name = "天安门",
            .address = "北京市东城区",
        },
    });
    defer alloc.free(location);
    try std.testing.expect(std.mem.indexOf(u8, location, "\"msgtype\":\"location\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, location, "\"name\":\"天安门\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, location, "\"address\":\"北京市东城区\"") != null);

    const menu = try jsonStringifySendMessage(alloc, .{
        .menu = .{
            .open_kfid = "kf_1",
            .touser = "wm_1",
            .head_content = "请选择要咨询的内容",
            .list = &.{
                .{ .click = .{ .id = "c1", .content = "人工客服" } },
                .{ .view = .{ .url = "https://example.com/faq", .content = "常见问题" } },
                .{ .miniprogram = .{ .appid = "wx_mp_1", .pagepath = "pages/faq", .content = "小程序答疑" } },
            },
            .tail_content = "感谢咨询",
        },
    });
    defer alloc.free(menu);
    try std.testing.expect(std.mem.indexOf(u8, menu, "\"msgtype\":\"msgmenu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu, "\"head_content\":\"请选择要咨询的内容\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu, "{\"type\":\"click\",\"click\":{\"id\":\"c1\",\"content\":\"人工客服\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu, "{\"type\":\"view\",\"view\":{\"url\":\"https://example.com/faq\",\"content\":\"常见问题\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu, "{\"type\":\"miniprogram\",\"miniprogram\":{\"appid\":\"wx_mp_1\",\"pagepath\":\"pages/faq\",\"content\":\"小程序答疑\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, menu, "\"tail_content\":\"感谢咨询\"") != null);
}

test "sendMsgRich image POST send_msg 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_img_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgRich(.{ .image = .{ .open_kfid = "kf_1", .touser = "wm_1", .media_id = "media_img" } });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_img_1", parsed.value.msgid);
}

test "sendMsgRich voice POST send_msg 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_voice_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgRich(.{ .voice = .{ .open_kfid = "kf_1", .touser = "wm_1", .msgid = "msg_voice_1", .media_id = "media_v" } });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_voice_1", parsed.value.msgid);
}

test "sendMsgRich video POST send_msg 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_video_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgRich(.{ .video = .{ .open_kfid = "kf_1", .touser = "wm_1", .media_id = "media_vid" } });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_video_1", parsed.value.msgid);
}

test "sendMsgRich file POST send_msg 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_file_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgRich(.{ .file = .{ .open_kfid = "kf_1", .touser = "wm_1", .media_id = "media_f" } });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_file_1", parsed.value.msgid);
}

test "sendMsgRich link POST send_msg 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_link_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgRich(.{ .link = .{
        .open_kfid = "kf_1",
        .touser = "wm_1",
        .title = "退款政策",
        .desc = "详见",
        .url = "https://example.com/r",
        .thumb_media_id = "media_t",
    } });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_link_1", parsed.value.msgid);
}

test "sendMsgRich miniprogram POST send_msg 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_mp_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgRich(.{ .miniprogram = .{
        .open_kfid = "kf_1",
        .touser = "wm_1",
        .appid = "wx_mp_1",
        .title = "小程序标题",
        .thumb_media_id = "media_t",
        .pagepath = "pages/faq",
    } });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_mp_1", parsed.value.msgid);
}

test "sendMsgRich menu POST send_msg 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_menu_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgRich(.{ .menu = .{
        .open_kfid = "kf_1",
        .touser = "wm_1",
        .head_content = "请选择",
        .list = &.{.{ .click = .{ .id = "c1", .content = "人工客服" } }},
        .tail_content = "感谢",
    } });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_menu_1", parsed.value.msgid);
}

test "sendMsgRich location POST send_msg 成功解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msgid\":\"msg_loc_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.sendMsgRich(.{ .location = .{
        .open_kfid = "kf_1",
        .touser = "wm_1",
        .latitude = 39.9042,
        .longitude = 116.4074,
        .name = "天安门",
        .address = "北京市东城区",
    } });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("msg_loc_1", parsed.value.msgid);
}

test "sendMsgRich 必填字段缺失返回 InvalidArgument" {
    var ctx = makeCtx();
    var k = Kf.init(&ctx, std.testing.allocator);

    // 媒体类缺 media_id。
    try std.testing.expectError(util_error.WechatError.InvalidArgument, k.sendMsgRich(.{
        .image = .{ .open_kfid = "kf_1", .touser = "wm_1", .media_id = "" },
    }));
    // link 缺 url。
    try std.testing.expectError(util_error.WechatError.InvalidArgument, k.sendMsgRich(.{
        .link = .{ .open_kfid = "kf_1", .touser = "wm_1", .title = "t", .url = "" },
    }));
    // miniprogram 缺 appid。
    try std.testing.expectError(util_error.WechatError.InvalidArgument, k.sendMsgRich(.{
        .miniprogram = .{ .open_kfid = "kf_1", .touser = "wm_1", .appid = "", .pagepath = "p" },
    }));
    // menu 缺 head_content / 空 list。
    try std.testing.expectError(util_error.WechatError.InvalidArgument, k.sendMsgRich(.{
        .menu = .{ .open_kfid = "kf_1", .touser = "wm_1", .head_content = "", .list = &.{.{ .click = .{ .id = "c1", .content = "x" } }} },
    }));
    try std.testing.expectError(util_error.WechatError.InvalidArgument, k.sendMsgRich(.{
        .menu = .{ .open_kfid = "kf_1", .touser = "wm_1", .head_content = "h", .list = &.{} },
    }));
    // menu 超过 10 个菜单项。
    const too_many = [_]MenuItem{
        .{ .click = .{ .id = "c1", .content = "1" } },   .{ .click = .{ .id = "c2", .content = "2" } },
        .{ .click = .{ .id = "c3", .content = "3" } },   .{ .click = .{ .id = "c4", .content = "4" } },
        .{ .click = .{ .id = "c5", .content = "5" } },   .{ .click = .{ .id = "c6", .content = "6" } },
        .{ .click = .{ .id = "c7", .content = "7" } },   .{ .click = .{ .id = "c8", .content = "8" } },
        .{ .click = .{ .id = "c9", .content = "9" } },   .{ .click = .{ .id = "c10", .content = "10" } },
        .{ .click = .{ .id = "c11", .content = "11" } },
    };
    try std.testing.expectError(util_error.WechatError.InvalidArgument, k.sendMsgRich(.{
        .menu = .{ .open_kfid = "kf_1", .touser = "wm_1", .head_content = "h", .list = &too_many },
    }));
    // location 缺 name。
    try std.testing.expectError(util_error.WechatError.InvalidArgument, k.sendMsgRich(.{
        .location = .{ .open_kfid = "kf_1", .touser = "wm_1", .name = "" },
    }));
}

// ── 消息拉取（syncMsg）富媒体强类型解析 ─────────────────────────────────────

test "syncMsg 富媒体消息强类型解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/sync_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"nc_1\",\"has_more\":0,\"msg_list\":[" ++
            "{\"msgid\":\"m_t\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"servicer_userid\":\"zhangsan\",\"send_time\":1700000000,\"origin\":3,\"msgtype\":\"text\",\"text\":{\"content\":\"你好\",\"menu_id\":\"menu_1\"}}," ++
            "{\"msgid\":\"m_i\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"send_time\":1700000001,\"origin\":3,\"msgtype\":\"image\",\"image\":{\"media_id\":\"media_i\"}}," ++
            "{\"msgid\":\"m_v\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"send_time\":1700000002,\"origin\":3,\"msgtype\":\"voice\",\"voice\":{\"media_id\":\"media_v\"}}," ++
            "{\"msgid\":\"m_vid\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"send_time\":1700000003,\"origin\":3,\"msgtype\":\"video\",\"video\":{\"media_id\":\"media_vid\"}}," ++
            "{\"msgid\":\"m_f\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"send_time\":1700000004,\"origin\":3,\"msgtype\":\"file\",\"file\":{\"media_id\":\"media_f\"}}," ++
            "{\"msgid\":\"m_l\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"send_time\":1700000005,\"origin\":3,\"msgtype\":\"location\",\"location\":{\"latitude\":39.9042,\"longitude\":116.4074,\"name\":\"天安门\",\"address\":\"北京市东城区\"}}," ++
            "{\"msgid\":\"m_k\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"send_time\":1700000006,\"origin\":3,\"msgtype\":\"link\",\"link\":{\"title\":\"标题\",\"desc\":\"描述\",\"url\":\"https://example.com\",\"pic_url\":\"http://a/1.png\"}}," ++
            "{\"msgid\":\"m_b\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"send_time\":1700000007,\"origin\":3,\"msgtype\":\"business_card\",\"business_card\":{\"userid\":\"zhangsan\"}}," ++
            "{\"msgid\":\"m_p\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"send_time\":1700000008,\"origin\":3,\"msgtype\":\"miniprogram\",\"miniprogram\":{\"appid\":\"wx_mp_1\",\"title\":\"小程序标题\",\"thumb_media_id\":\"media_t\",\"pagepath\":\"pages/index\"}}" ++
            "]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.syncMsg(.{ .limit = 100 });
    defer parsed.deinit();

    var want = [_]SyncMessage{
        .{
            .msgid = "m_t",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .servicer_userid = "zhangsan",
            .send_time = 1700000000,
            .origin = 3,
            .msgtype = "text",
            .text = .{ .content = "你好", .menu_id = "menu_1" },
        },
        .{
            .msgid = "m_i",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .send_time = 1700000001,
            .origin = 3,
            .msgtype = "image",
            .image = .{ .media_id = "media_i" },
        },
        .{
            .msgid = "m_v",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .send_time = 1700000002,
            .origin = 3,
            .msgtype = "voice",
            .voice = .{ .media_id = "media_v" },
        },
        .{
            .msgid = "m_vid",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .send_time = 1700000003,
            .origin = 3,
            .msgtype = "video",
            .video = .{ .media_id = "media_vid" },
        },
        .{
            .msgid = "m_f",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .send_time = 1700000004,
            .origin = 3,
            .msgtype = "file",
            .file = .{ .media_id = "media_f" },
        },
        .{
            .msgid = "m_l",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .send_time = 1700000005,
            .origin = 3,
            .msgtype = "location",
            // f32 按位比较：std.json 直接解析为 f32，与字面量一致（无 f64 中转）。
            .location = .{ .latitude = 39.9042, .longitude = 116.4074, .name = "天安门", .address = "北京市东城区" },
        },
        .{
            .msgid = "m_k",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .send_time = 1700000006,
            .origin = 3,
            .msgtype = "link",
            .link = .{ .title = "标题", .desc = "描述", .url = "https://example.com", .pic_url = "http://a/1.png" },
        },
        .{
            .msgid = "m_b",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .send_time = 1700000007,
            .origin = 3,
            .msgtype = "business_card",
            .business_card = .{ .userid = "zhangsan" },
        },
        .{
            .msgid = "m_p",
            .open_kfid = "kf_1",
            .external_userid = "wm_1",
            .send_time = 1700000008,
            .origin = 3,
            .msgtype = "miniprogram",
            .miniprogram = .{
                .appid = "wx_mp_1",
                .title = "小程序标题",
                .thumb_media_id = "media_t",
                .pagepath = "pages/index",
            },
        },
    };
    try std.testing.expectEqual(@as(usize, want.len), parsed.value.msg_list.len);

    // 整体比较：一次覆盖每条消息的全部字段——除本用例显式断言过的负载外，
    // 「不该出现的其他负载」与未下发字段也一并断言为默认值。
    var got_buf: [want.len]SyncMessage = undefined;
    var got = parsed.value;
    got.msg_list = typedOnlyList(&got_buf, parsed.value.msg_list);
    try std.testing.expectEqualDeep(SyncMsgResponse{
        .errmsg = "ok",
        .next_cursor = "nc_1",
        .msg_list = &want,
    }, got);
}

test "syncMsg 事件消息强类型解析" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/sync_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"nc_2\",\"has_more\":1,\"msg_list\":[" ++
            "{\"msgid\":\"e_1\",\"send_time\":1700000100,\"origin\":4,\"msgtype\":\"event\",\"event\":{\"event_type\":\"enter_session\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"scene\":\"s1\",\"scene_param\":\"sp1\",\"welcome_code\":\"wc_1\"}}," ++
            "{\"msgid\":\"e_2\",\"send_time\":1700000101,\"origin\":4,\"msgtype\":\"event\",\"event\":{\"event_type\":\"msg_send_fail\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"fail_msgid\":\"m_t\",\"fail_type\":4}}," ++
            "{\"msgid\":\"e_3\",\"send_time\":1700000102,\"origin\":4,\"msgtype\":\"event\",\"event\":{\"event_type\":\"servicer_status_change\",\"open_kfid\":\"kf_1\",\"servicer_userid\":\"zhangsan\",\"status\":2}}," ++
            "{\"msgid\":\"e_4\",\"send_time\":1700000103,\"origin\":4,\"msgtype\":\"event\",\"event\":{\"event_type\":\"session_status_change\",\"open_kfid\":\"kf_1\",\"external_userid\":\"wm_1\",\"change_type\":3,\"old_servicer_userid\":\"zhangsan\",\"new_servicer_userid\":\"\",\"msg_code\":\"mc_1\"}}" ++
            "]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.syncMsg(.{ .cursor = "c0", .limit = 10 });
    defer parsed.deinit();

    // 整体比较：一次覆盖每条事件消息的全部字段——含四类事件各自的完整 SyncEvent
    // （未下发字段须保持默认值，如 msg_send_fail 的 servicer_userid / status）。
    var want = [_]SyncMessage{
        .{
            .msgid = "e_1",
            .send_time = 1700000100,
            .origin = 4,
            .msgtype = "event",
            // enter_session：欢迎语 code / 场景值 / 事件内层 open_kfid。
            .event = .{
                .event_type = "enter_session",
                .open_kfid = "kf_1",
                .external_userid = "wm_1",
                .scene = "s1",
                .scene_param = "sp1",
                .welcome_code = "wc_1",
            },
        },
        .{
            .msgid = "e_2",
            .send_time = 1700000101,
            .origin = 4,
            .msgtype = "event",
            // msg_send_fail：失败消息 id / 失败类型。
            .event = .{
                .event_type = "msg_send_fail",
                .open_kfid = "kf_1",
                .external_userid = "wm_1",
                .fail_msgid = "m_t",
                .fail_type = 4,
            },
        },
        .{
            .msgid = "e_3",
            .send_time = 1700000102,
            .origin = 4,
            .msgtype = "event",
            // servicer_status_change：客服 userid / 状态。
            .event = .{
                .event_type = "servicer_status_change",
                .open_kfid = "kf_1",
                .servicer_userid = "zhangsan",
                .status = 2,
            },
        },
        .{
            .msgid = "e_4",
            .send_time = 1700000103,
            .origin = 4,
            .msgtype = "event",
            // session_status_change：变更类型 / 原客服 / 响应 code。
            .event = .{
                .event_type = "session_status_change",
                .open_kfid = "kf_1",
                .external_userid = "wm_1",
                .change_type = 3,
                .old_servicer_userid = "zhangsan",
                .msg_code = "mc_1",
            },
        },
    };
    try std.testing.expectEqual(@as(usize, want.len), parsed.value.msg_list.len);

    var got_buf: [want.len]SyncMessage = undefined;
    var got = parsed.value;
    got.msg_list = typedOnlyList(&got_buf, parsed.value.msg_list);
    try std.testing.expectEqualDeep(SyncMsgResponse{
        .errmsg = "ok",
        .next_cursor = "nc_2",
        .has_more = 1,
        .msg_list = &want,
    }, got);
}

// ── 消息拉取（syncMsg）OriginData 原始 JSON 回捕 ───────────────────────────

test "syncMsg 保留 OriginData 原始 JSON（含强类型未覆盖的新字段与 newtype）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/sync_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"nc_od\",\"has_more\":1,\"msg_list\":[" ++
            "{\"msgid\":\"m_t\",\"open_kfid\":\"kf_1\",\"send_time\":1700000000,\"origin\":3,\"msgtype\":\"text\",\"text\":{\"content\":\"你好\",\"new_text_field\":\"tx\"},\"new_wechat_field\":\"v1\"}," ++
            "{\"msgid\":\"m_new\",\"open_kfid\":\"kf_1\",\"send_time\":1700000001,\"origin\":3,\"msgtype\":\"order_info\",\"order_info\":{\"order_id\":\"12345\",\"amount\":100,\"status\":\"paid\"}}," ++
            "{\"msgid\":\"e_1\",\"send_time\":1700000002,\"origin\":4,\"msgtype\":\"event\",\"event\":{\"event_type\":\"enter_session\",\"open_kfid\":\"kf_1\",\"welcome_code\":\"wc_1\"}}" ++
            "]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.syncMsg(.{ .limit = 10 });
    defer parsed.deinit();

    const list = parsed.value.msg_list;
    try std.testing.expectEqual(@as(usize, 3), list.len);

    // 既有强类型解析不受影响。
    try std.testing.expectEqualStrings("你好", list[0].text.content);
    try std.testing.expectEqual(@as(u64, 1700000000), list[0].send_time);
    try std.testing.expectEqual(@as(u32, 3), list[0].origin);
    try std.testing.expectEqualStrings("enter_session", list[2].event.event_type);

    // 原始 JSON：微信新增字段（强类型结构体里并不存在）也完整保留。
    const origin = try list[0].getOriginData(allocator);
    defer allocator.free(origin);
    try std.testing.expect(std.mem.indexOf(u8, origin, "\"content\":\"你好\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, origin, "\"new_wechat_field\":\"v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, origin, "\"new_text_field\":\"tx\"") != null);

    // 二次解析后可取到强类型结构里没有的字段——本特性的核心价值。
    var reparsed = try std.json.parseFromSlice(std.json.Value, allocator, origin, .{});
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("v1", reparsed.value.object.get("new_wechat_field").?.string);
    const nested = reparsed.value.object.get("text").?.object;
    try std.testing.expectEqualStrings("tx", nested.get("new_text_field").?.string);

    // 未知 msgtype（newtype）：强类型负载保持默认值，原始 JSON 依然可用。
    try std.testing.expectEqualStrings("order_info", list[1].msgtype);
    try std.testing.expectEqualStrings("", list[1].text.content);
    const new_origin = try list[1].getOriginData(allocator);
    defer allocator.free(new_origin);
    try std.testing.expect(std.mem.indexOf(u8, new_origin, "\"order_id\":\"12345\"") != null);
    // 键序按微信下发顺序保留，语义等同于微信下发的原始元素 JSON。
    try std.testing.expect(std.mem.startsWith(u8, new_origin, "{\"msgid\":\"m_new\",\"open_kfid\":\"kf_1\""));
}

test "syncMsg OriginData 二次解析：getOriginValue / originAs / originPayloadAs" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/sync_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"has_more\":0,\"msg_list\":[{\"msgid\":\"m_min\",\"msgtype\":\"order_info\",\"order_info\":{\"order_id\":\"12345\",\"amount\":100}}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.syncMsg(.{ .limit = 10 });
    defer parsed.deinit();

    const msg = parsed.value.msg_list[0];

    // getOriginValue：借用原始 Value 树（由 Parsed 的 arena 持有）。
    const origin_value = msg.getOriginValue().?;
    try std.testing.expect(origin_value.object.get("order_info") != null);
    try std.testing.expectEqualStrings("m_min", origin_value.object.get("msgid").?.string);

    // getOriginData：紧凑序列化结果与微信下发的元素 JSON 逐字一致。
    const origin = try msg.getOriginData(allocator);
    defer allocator.free(origin);
    try std.testing.expectEqualStrings(
        "{\"msgid\":\"m_min\",\"msgtype\":\"order_info\",\"order_info\":{\"order_id\":\"12345\",\"amount\":100}}",
        origin,
    );

    // originAs：整条消息反序列化为调用方自定义类型（未知字段忽略）。
    const Envelope = struct {
        msgid: []const u8 = "",
        msgtype: []const u8 = "",
    };
    var envelope = try msg.originAs(allocator, Envelope);
    defer envelope.deinit();
    try std.testing.expectEqualStrings("m_min", envelope.value.msgid);
    try std.testing.expectEqualStrings("order_info", envelope.value.msgtype);

    // originPayloadAs：未知 msgtype 的负载用自定义类型解出来。
    const OrderInfo = struct {
        order_id: []const u8 = "",
        amount: i64 = 0,
    };
    var order = try msg.originPayloadAs(allocator, OrderInfo);
    defer order.deinit();
    try std.testing.expectEqualStrings("12345", order.value.order_id);
    try std.testing.expectEqual(@as(i64, 100), order.value.amount);
}

test "SyncMessage OriginData 缺失与负载缺失返回明确错误" {
    const allocator = std.testing.allocator;

    // 手工构造（未经 syncMsg 解析）的实例没有原始 JSON。
    const manual = SyncMessage{};
    try std.testing.expect(manual.getOriginValue() == null);
    try std.testing.expectError(error.NoOriginData, manual.getOriginData(allocator));
    try std.testing.expectError(
        error.NoOriginData,
        manual.originAs(allocator, struct { msgid: []const u8 = "" }),
    );
    try std.testing.expectError(
        error.NoOriginData,
        manual.originPayloadAs(allocator, struct { media_id: []const u8 = "" }),
    );

    // 有原始 JSON，但 msgtype 为空 → 找不到对应负载对象。
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/sync_msg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"has_more\":0,\"msg_list\":[{\"msgid\":\"m_t\",\"msgtype\":\"text\",\"text\":{\"content\":\"hi\"}}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.syncMsg(.{ .limit = 10 });
    defer parsed.deinit();

    var msg = parsed.value.msg_list[0];
    try std.testing.expect(msg.getOriginValue() != null);
    msg.msgtype = "";
    try std.testing.expectError(
        error.PayloadNotFound,
        msg.originPayloadAs(allocator, struct { content: []const u8 = "" }),
    );
}

// ── 客户 ────────────────────────────────────────────────────────────────────

test "customerBatchGet POST customer/batchget 并解析客户列表" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/customer/batchget?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"customer_list\":[{\"external_userid\":\"wm_ext_1\",\"nickname\":\"小明\",\"avatar\":\"http://a/1.png\",\"gender\":1,\"unionid\":\"union_x\"}],\"invalid_external_userid\":[\"wm_bad\"]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.customerBatchGet(.{ .external_userid_list = &.{ "wm_ext_1", "wm_bad" } });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.customer_list.len);
    try std.testing.expectEqualStrings("小明", parsed.value.customer_list[0].nickname);
    try std.testing.expectEqualStrings("union_x", parsed.value.customer_list[0].unionid);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.invalid_external_userid.len);
    try std.testing.expectEqualStrings("wm_bad", parsed.value.invalid_external_userid[0]);
}

// ── 升级服务 ──────────────────────────────────────────────────────────────────

test "getUpgradeServiceConfig GET 并解析专员与客户群范围" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/customer/get_upgrade_service_config?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"member_range\":{\"userid_list\":[\"zhangsan\"],\"department_id_list\":[\"2\"]},\"groupchat_range\":{\"chat_id_list\":[\"gc_1\"]}}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.getUpgradeServiceConfig();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.member_range.userid_list.len);
    try std.testing.expectEqualStrings("zhangsan", parsed.value.member_range.userid_list[0]);
    try std.testing.expectEqualStrings("gc_1", parsed.value.groupchat_range.chat_id_list[0]);
}

test "upgradeService POST upgrade_service（member + groupchat 全字段）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/customer/upgrade_service?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.upgradeService(.{
        .open_kfid = "wkf_1",
        .external_userid = "wm_ext_1",
        .service_type = 1,
        .member = .{ .userid = "special_1", .wording = "推荐专员" },
        .groupchat = .{ .chat_id = "gc_1", .wording = "推荐群" },
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "upgradeMemberService POST upgrade_service 专员动作" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/customer/upgrade_service?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.upgradeMemberService(.{
        .open_kfid = "wkf_1",
        .external_userid = "wm_ext_1",
        .service_type = 1,
        .member = .{ .userid = "special_1", .wording = "为您推荐专员" },
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
}

test "upgradeGroupChatService POST upgrade_service 客户群动作" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/customer/upgrade_service?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.upgradeGroupChatService(.{
        .open_kfid = "wkf_1",
        .external_userid = "wm_ext_1",
        .service_type = 2,
        .groupchat = .{ .chat_id = "gc_1", .wording = "为您推荐群" },
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "cancelUpgradeService POST cancel_upgrade_service" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/customer/cancel_upgrade_service?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.cancelUpgradeService(.{ .open_kfid = "wkf_1", .external_userid = "wm_ext_1" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

// ── 知识库：分组 ──────────────────────────────────────────────────────────────

test "addKnowledgeGroup POST knowledge/add_group 并解析 group_id" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/add_group?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"group_id\":\"grp_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.addKnowledgeGroup(.{ .name = "常见问题" });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("grp_1", parsed.value.group_id);
}

test "delKnowledgeGroup POST knowledge/del_group" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/del_group?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.delKnowledgeGroup(.{ .group_id = "grp_1" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "modKnowledgeGroup POST knowledge/mod_group" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/mod_group?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.modKnowledgeGroup(.{ .group_id = "grp_1", .name = "常见问题V2" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "listKnowledgeGroup POST knowledge/list_group 游标分页" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/list_group?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"\",\"has_more\":0,\"group_list\":[{\"group_id\":\"grp_1\",\"name\":\"常见问题\",\"is_default\":0}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.listKnowledgeGroup(.{ .cursor = "", .limit = 100, .group_id = "" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.has_more);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.group_list.len);
    try std.testing.expectEqualStrings("常见问题", parsed.value.group_list[0].name);
}

// ── 知识库：问答 ──────────────────────────────────────────────────────────────

test "addKnowledgeIntent POST knowledge/add_intent 并解析 intent_id" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/add_intent?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"intent_id\":\"intent_1\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.addKnowledgeIntent(.{
        .group_id = "grp_1",
        .question = .{ .text = .{ .content = "如何退款" } },
        .similar_questions = .{ .items = &.{.{ .text = .{ .content = "怎么退货" } }} },
        .answers = &.{
            .{
                .text = .{ .content = "请在订单页申请退款" },
                .attachments = &.{},
            },
        },
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("intent_1", parsed.value.intent_id);
}

test "delKnowledgeIntent POST knowledge/del_intent" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/del_intent?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.delKnowledgeIntent(.{ .intent_id = "intent_1" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "modKnowledgeIntent POST knowledge/mod_intent" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/mod_intent?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.modKnowledgeIntent(.{
        .intent_id = "intent_1",
        .question = .{ .text = .{ .content = "如何退款V2" } },
        .similar_questions = .{ .items = &.{} },
        .answers = &.{.{ .text = .{ .content = "请在订单页申请退款" }, .attachments = &.{} }},
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
}

test "listKnowledgeIntent POST knowledge/list_intent 解析嵌套问答" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/knowledge/list_intent?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"next_cursor\":\"cur_2\",\"has_more\":1,\"intent_list\":[{\"group_id\":\"grp_1\",\"intent_id\":\"intent_1\",\"question\":{\"text\":{\"content\":\"如何退款\"}},\"similar_questions\":{\"items\":[{\"text\":{\"content\":\"怎么退货\"}}]},\"answers\":[{\"text\":{\"content\":\"请在订单页申请退款\"},\"attachments\":[{\"msgtype\":\"link\",\"link\":{\"title\":\"退款政策\",\"picurl\":\"http://a/1.png\",\"desc\":\"详见\",\"url\":\"https://example.com/r\"}}]}]}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.listKnowledgeIntent(.{ .cursor = "", .limit = 10, .group_id = "grp_1", .intent_id = "" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1), parsed.value.has_more);
    try std.testing.expectEqualStrings("cur_2", parsed.value.next_cursor);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.intent_list.len);
    const intent = parsed.value.intent_list[0];
    try std.testing.expectEqualStrings("intent_1", intent.intent_id);
    try std.testing.expectEqualStrings("如何退款", intent.question.text.content);
    try std.testing.expectEqual(@as(usize, 1), intent.similar_questions.items.len);
    try std.testing.expectEqualStrings("怎么退货", intent.similar_questions.items[0].text.content);
    try std.testing.expectEqual(@as(usize, 1), intent.answers.len);
    try std.testing.expectEqualStrings("请在订单页申请退款", intent.answers[0].text.content);
    const att = intent.answers[0].attachments[0];
    try std.testing.expectEqualStrings("link", att.msgtype);
    try std.testing.expectEqualStrings("退款政策", att.link.title);
    try std.testing.expectEqualStrings("https://example.com/r", att.link.url);
}

// ── 统计 ────────────────────────────────────────────────────────────────────

test "getCorpStatistic POST get_corp_statistic 解析浮点字段" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/get_corp_statistic?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"statistic_list\":[{\"stat_time\":1699718400,\"statistic\":{\"session_cnt\":42,\"customer_cnt\":30,\"customer_msg_cnt\":120,\"upgrade_service_customer_cnt\":5,\"ai_session_reply_cnt\":10,\"ai_transfer_rate\":0.5,\"ai_knowledge_hit_rate\":0.8,\"msg_rejected_customer_cnt\":1}}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.getCorpStatistic(.{ .open_kfid = "wkf_1", .start_time = 1699600000, .end_time = 1699800000 });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.statistic_list.len);
    const st = parsed.value.statistic_list[0].statistic;
    try std.testing.expectEqual(@as(i64, 42), st.session_cnt);
    try std.testing.expectEqual(@as(f64, 0.5), st.ai_transfer_rate);
    try std.testing.expectEqual(@as(f64, 0.8), st.ai_knowledge_hit_rate);
}

test "getServicerStatistic POST get_servicer_statistic 解析明细" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/get_servicer_statistic?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"statistic_list\":[{\"stat_time\":1699718400,\"statistic\":{\"session_cnt\":20,\"customer_cnt\":15,\"customer_msg_cnt\":60,\"reply_rate\":0.9,\"first_reply_average_sec\":30.5,\"satisfaction_investgate_cnt\":10,\"satisfaction_participation_rate\":0.7,\"satisfied_rate\":0.6,\"middling_rate\":0.3,\"dissatisfied_rate\":0.1,\"upgrade_service_customer_cnt\":2,\"upgrade_service_member_invite_cnt\":3,\"upgrade_service_member_customer_cnt\":1,\"upgrade_service_groupchat_invite_cnt\":4,\"upgrade_service_groupchat_customer_cnt\":2,\"msg_rejected_customer_cnt\":0}}]}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.getServicerStatistic(.{
        .open_kfid = "wkf_1",
        .servicer_userid = "zhangsan",
        .start_time = 1699600000,
        .end_time = 1699800000,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.statistic_list.len);
    const st = parsed.value.statistic_list[0].statistic;
    try std.testing.expectEqual(@as(f64, 30.5), st.first_reply_average_sec);
    try std.testing.expectEqual(@as(i64, 4), st.upgrade_service_groupchat_invite_cnt);
}

// ── 其他 ────────────────────────────────────────────────────────────────────

test "getCorpQualification GET 解析视频号绑定状态" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/get_corp_qualification?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"wechat_channels_binding\":true}",
    });
    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var ctx = makeCtx();
    var k = Kf.init(&ctx, allocator);
    var parsed = try k.getCorpQualification();
    defer parsed.deinit();
    try std.testing.expect(parsed.value.wechat_channels_binding);
}

// ── 请求体编码断言 ────────────────────────────────────────────────────────────

test "kf 请求体编码：账号 / 联系链接 / 客户批量" {
    const alloc = std.testing.allocator;

    const add = try jsonStringifyAccountAdd(alloc, .{ .name = "客服\"一号", .media_id = "m_1" });
    defer alloc.free(add);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"name\":\"客服\\\"一号\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"media_id\":\"m_1\"") != null);

    const del = try jsonStringifyAccountDel(alloc, "wkf_1");
    defer alloc.free(del);
    try std.testing.expectEqualStrings("{\"open_kfid\":\"wkf_1\"}", del);

    const upd = try jsonStringifyAccountUpdate(alloc, .{ .open_kfid = "wkf_1", .name = "n", .media_id = "m" });
    defer alloc.free(upd);
    try std.testing.expect(std.mem.indexOf(u8, upd, "\"open_kfid\":\"wkf_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, upd, "\"name\":\"n\"") != null);

    const page = try jsonStringifyAccountPage(alloc, .{ .offset = 10, .limit = 20 });
    defer alloc.free(page);
    try std.testing.expectEqualStrings("{\"offset\":10,\"limit\":20}", page);

    const cw = try jsonStringifyContactWay(alloc, .{ .open_kfid = "wkf_1", .scene = "s_1" });
    defer alloc.free(cw);
    try std.testing.expect(std.mem.indexOf(u8, cw, "\"scene\":\"s_1\"") != null);

    const cb = try jsonStringifyCustomerBatchGet(alloc, .{ .external_userid_list = &.{ "wm_1", "wm_2" } });
    defer alloc.free(cb);
    try std.testing.expectEqualStrings("{\"external_userid_list\":[\"wm_1\",\"wm_2\"]}", cb);
}

test "kf 请求体编码：接待人员与会话状态" {
    const alloc = std.testing.allocator;

    const sv = try jsonStringifyServicer(alloc, .{
        .open_kfid = "wkf_1",
        .userid_list = &.{ "u1", "u2" },
        .department_id_list = &.{ 2, 3 },
    });
    defer alloc.free(sv);
    try std.testing.expect(std.mem.indexOf(u8, sv, "\"userid_list\":[\"u1\",\"u2\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "\"department_id_list\":[2,3]") != null);

    const get = try jsonStringifyServiceStateGet(alloc, .{ .open_kfid = "wkf_1", .external_userid = "wm_1" });
    defer alloc.free(get);
    try std.testing.expectEqualStrings("{\"open_kfid\":\"wkf_1\",\"external_userid\":\"wm_1\"}", get);

    const trans = try jsonStringifyServiceStateTrans(alloc, .{
        .open_kfid = "wkf_1",
        .external_userid = "wm_1",
        .service_state = 3,
        .servicer_userid = "zhangsan",
    });
    defer alloc.free(trans);
    try std.testing.expect(std.mem.indexOf(u8, trans, "\"service_state\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, trans, "\"servicer_userid\":\"zhangsan\"") != null);
}

test "encodeSyncMsgJson voice_format/open_kfid 条件写入" {
    const alloc = std.testing.allocator;

    // 默认：不写 voice_format / open_kfid（对齐 Go omitempty）。
    const bare = try encodeSyncMsgJson(alloc, .{ .cursor = "c1", .token = "t1", .limit = 100 });
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("{\"cursor\":\"c1\",\"token\":\"t1\",\"limit\":100}", bare);

    // 非零 voice_format 与非空 open_kfid 写入。
    const full = try encodeSyncMsgJson(alloc, .{
        .cursor = "c1",
        .token = "t1",
        .limit = 1000,
        .voice_format = 1,
        .open_kfid = "wkf_1",
    });
    defer alloc.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"voice_format\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"open_kfid\":\"wkf_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"limit\":1000") != null);
}

test "kf 请求体编码：事件响应消息与升级服务" {
    const alloc = std.testing.allocator;

    const evt = try jsonStringifyTextEventMessage(alloc, .{ .code = "wc_1", .msgid = "m_1", .content = "欢迎\x07语" });
    defer alloc.free(evt);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"code\":\"wc_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evt, "\"msgtype\":\"text\"") != null);
    // 控制字符必须被转义（Stringify 负责转义）。
    try std.testing.expect(std.mem.indexOf(u8, evt, "\x07") == null);

    const up = try jsonStringifyUpgradeService(alloc, .{
        .open_kfid = "wkf_1",
        .external_userid = "wm_1",
        .service_type = 1,
        .member = .{ .userid = "sp_1", .wording = "专员" },
        .groupchat = .{ .chat_id = "gc_1", .wording = "群" },
    });
    defer alloc.free(up);
    try std.testing.expect(std.mem.indexOf(u8, up, "\"type\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "\"member\":{\"userid\":\"sp_1\",\"wording\":\"专员\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, up, "\"groupchat\":{\"chat_id\":\"gc_1\",\"wording\":\"群\"}") != null);

    const upm = try jsonStringifyUpgradeMemberService(alloc, .{
        .open_kfid = "wkf_1",
        .external_userid = "wm_1",
        .service_type = 1,
        .member = .{ .userid = "sp_1", .wording = "" },
    });
    defer alloc.free(upm);
    try std.testing.expect(std.mem.indexOf(u8, upm, "\"member\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, upm, "groupchat") == null);

    const upg = try jsonStringifyUpgradeGroupChatService(alloc, .{
        .open_kfid = "wkf_1",
        .external_userid = "wm_1",
        .service_type = 2,
        .groupchat = .{ .chat_id = "gc_1", .wording = "" },
    });
    defer alloc.free(upg);
    try std.testing.expect(std.mem.indexOf(u8, upg, "\"type\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, upg, "\"groupchat\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, upg, "\"member\":{") == null);

    const cancel = try jsonStringifyUpgradeServiceCancel(alloc, .{ .open_kfid = "wkf_1", .external_userid = "wm_1" });
    defer alloc.free(cancel);
    try std.testing.expectEqualStrings("{\"open_kfid\":\"wkf_1\",\"external_userid\":\"wm_1\"}", cancel);
}

test "kf 请求体编码：知识库分组" {
    const alloc = std.testing.allocator;

    const add = try jsonStringifyKnowledgeGroupAdd(alloc, "常见问题");
    defer alloc.free(add);
    try std.testing.expectEqualStrings("{\"name\":\"常见问题\"}", add);

    const del = try jsonStringifyKnowledgeGroupDel(alloc, "grp_1");
    defer alloc.free(del);
    try std.testing.expectEqualStrings("{\"group_id\":\"grp_1\"}", del);

    const mod = try jsonStringifyKnowledgeGroupMod(alloc, .{ .group_id = "grp_1", .name = "n" });
    defer alloc.free(mod);
    try std.testing.expectEqualStrings("{\"group_id\":\"grp_1\",\"name\":\"n\"}", mod);

    const list = try jsonStringifyKnowledgeGroupList(alloc, .{ .cursor = "c1", .limit = 50, .group_id = "grp_1" });
    defer alloc.free(list);
    try std.testing.expectEqualStrings("{\"cursor\":\"c1\",\"limit\":50,\"group_id\":\"grp_1\"}", list);
}

test "kf 请求体编码：知识库问答嵌套结构" {
    const alloc = std.testing.allocator;

    const add = try jsonStringifyKnowledgeIntentAdd(alloc, .{
        .group_id = "grp_1",
        .question = .{ .text = .{ .content = "如何退款" } },
        .similar_questions = .{ .items = &.{.{ .text = .{ .content = "怎么退货" } }} },
        .answers = &.{
            .{
                .text = .{ .content = "答案" },
                .attachments = &.{
                    .{
                        .msgtype = "link",
                        .image = .{ .media_id = "" },
                        .video = .{ .media_id = "" },
                        .link = .{
                            .title = "退款政策",
                            .picurl = "http://a/1.png",
                            .desc = "详见",
                            .url = "https://example.com/r",
                        },
                        .miniprogram = .{ .title = "", .thumb_media_id = "", .appid = "", .pagepath = "" },
                    },
                },
            },
        },
    });
    defer alloc.free(add);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"group_id\":\"grp_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"question\":{\"text\":{\"content\":\"如何退款\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"items\":[{\"text\":{\"content\":\"怎么退货\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, add, "\"link\":{\"title\":\"退款政策\",\"picurl\":\"http://a/1.png\",\"desc\":\"详见\",\"url\":\"https://example.com/r\"}") != null);

    const mod = try jsonStringifyKnowledgeIntentMod(alloc, .{
        .intent_id = "intent_1",
        .question = .{ .text = .{ .content = "q" } },
        .similar_questions = .{ .items = &.{} },
        .answers = &.{},
    });
    defer alloc.free(mod);
    try std.testing.expect(std.mem.indexOf(u8, mod, "\"intent_id\":\"intent_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mod, "\"answers\":[]") != null);

    const list = try jsonStringifyKnowledgeIntentList(alloc, .{ .cursor = "c1", .limit = 10, .group_id = "g", .intent_id = "i" });
    defer alloc.free(list);
    try std.testing.expectEqualStrings("{\"cursor\":\"c1\",\"limit\":10,\"group_id\":\"g\",\"intent_id\":\"i\"}", list);
}

test "kf 请求体编码：统计" {
    const alloc = std.testing.allocator;

    const corp = try jsonStringifyCorpStatistic(alloc, .{ .open_kfid = "wkf_1", .start_time = 1699600000, .end_time = 1699800000 });
    defer alloc.free(corp);
    try std.testing.expectEqualStrings("{\"open_kfid\":\"wkf_1\",\"start_time\":1699600000,\"end_time\":1699800000}", corp);

    const svc = try jsonStringifyServicerStatistic(alloc, .{ .open_kfid = "wkf_1", .servicer_userid = "zhangsan", .start_time = 1, .end_time = 2 });
    defer alloc.free(svc);
    try std.testing.expect(std.mem.indexOf(u8, svc, "\"servicer_userid\":\"zhangsan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svc, "\"start_time\":1") != null);
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
        .config = .{ .corp_id = "ww-kf-retry" },
        .access_token_handle = .{ .ptr = @ptrCast(state), .vtable = &RetryTokenState.vtable },
    };
}

test "getAccountList token 失效：40001 → 作废缓存 → 用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/account/list?access_token=tok-old", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/account/list?access_token=tok-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"account_list\":[{\"open_kfid\":\"wkf1\",\"name\":\"客服1\"}]}",
    });

    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var state = RetryTokenState{};
    var ctx = makeRetryCtx(&state);
    var kf = Kf.init(&ctx, allocator);
    var parsed = try kf.getAccountList();
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.account_list.len);
    try std.testing.expectEqualStrings("wkf1", parsed.value.account_list[0].open_kfid);
    try std.testing.expectEqual(@as(usize, 1), state.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/kf/account/list?access_token=tok-old",
        mt.history.items[0],
    );
    try std.testing.expectEqualStrings(
        "https://qyapi.weixin.qq.com/cgi-bin/kf/account/list?access_token=tok-new",
        mt.history.items[1],
    );
}

test "sendMsg 非 token 类 errcode：直接 ApiError，不作废也不重试" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=tok-old", .{
        .body = "{\"errcode\":95001,\"errmsg\":\"not allowed to send msg\"}",
    });

    const client = useMock(allocator, &mt);
    defer dropMock(client);

    var state = RetryTokenState{};
    var ctx = makeRetryCtx(&state);
    var kf = Kf.init(&ctx, allocator);

    const result = kf.sendMsg(.{ .open_kfid = "wkf1", .touser = "wm1", .content = "hi" });
    try std.testing.expectError(util_error.WechatError.ApiError, result);

    try std.testing.expectEqual(@as(usize, 0), state.invalidate_calls);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.fetch_calls);
}
