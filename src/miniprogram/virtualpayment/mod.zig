// SPDX-License-Identifier: Apache-2.0
//! miniprogram/virtualpayment — 小程序虚拟支付
//!
//! 对应 `_ref/wechat/miniprogram/virtualpayment/`：查询余额、代币支付、订单查询/取消/
//! 发货/赠送/账单/退款/提现等。请求 URL 需要 HMAC-SHA256 支付签名（pay_sig）与
//! 用户态签名（signature）。
//!
//! `access_token` 由 `util/retry.callApi` 注入：遇到 40001 等失效码会作废缓存、
//! 取新 token 后**只重试一次**。`pay_sig` / `signature` 只与 path + 请求体有关，
//! 重试时这些字节逐字不变（只有 `?access_token=` 的值被替换）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 环境：0 正式，1 沙箱。
pub const Env = enum(i64) {
    production = 0,
    sandbox = 1,
};

pub const CommonRequest = struct {
    openid: []const u8 = "",
    env: Env = .production,
};

pub const QueryUserBalanceRequest = struct {
    openid: []const u8 = "",
    env: Env = .production,
    user_ip: []const u8 = "",
};

pub const QueryUserBalanceResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    balance: i64 = 0,
    present_balance: i64 = 0,
    sum_save: i64 = 0,
    sum_present: i64 = 0,
    sum_balance: i64 = 0,
    sum_cost: i64 = 0,
    first_save_flag: i64 = 0,
};

pub const CurrencyPayRequest = struct {
    openid: []const u8 = "",
    env: Env = .production,
    user_ip: []const u8 = "",
    amount: i64 = 0,
    order_id: []const u8 = "",
    payitem: []const u8 = "",
    remark: []const u8 = "",
    device_type: []const u8 = "",
};

pub const CurrencyPayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    order_id: []const u8 = "",
    balance: i64 = 0,
    used_present_amount: i64 = 0,
};

pub const QueryOrderRequest = struct {
    openid: []const u8 = "",
    env: Env = .production,
    order_id: []const u8 = "",
    wx_order_id: []const u8 = "",
};

pub const QueryOrderResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    order: ?OrderItem = null,
};

pub const OrderItem = struct {
    order_id: []const u8 = "",
    create_time: i64 = 0,
    update_time: i64 = 0,
    status: i64 = 0,
    biz_type: i64 = 0,
    order_fee: i64 = 0,
    coupon_fee: i64 = 0,
    paid_fee: i64 = 0,
    order_type: i64 = 0,
    refund_fee: i64 = 0,
    paid_time: i64 = 0,
    provide_time: i64 = 0,
    biz_meta: []const u8 = "",
    env_type: i64 = 0,
    token: []const u8 = "",
    left_fee: i64 = 0,
    wx_order_id: []const u8 = "",
    channel_order_id: []const u8 = "",
    wxpay_order_id: []const u8 = "",
};

pub const CancelCurrencyPayRequest = struct {
    openid: []const u8 = "",
    env: Env = .production,
    user_ip: []const u8 = "",
    pay_order_id: []const u8 = "",
    order_id: []const u8 = "",
    amount: i64 = 0,
    device_type: i64 = 0,
};

pub const CancelCurrencyPayResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    order_id: []const u8 = "",
};

pub const NotifyProvideGoodsRequest = struct {
    order_id: []const u8 = "",
    wx_order_id: []const u8 = "",
    env: Env = .production,
};

pub const NotifyProvideGoodsResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const PresentCurrencyRequest = struct {
    openid: []const u8 = "",
    env: Env = .production,
    order_id: []const u8 = "",
    amount: i64 = 0,
    device_type: []const u8 = "",
};

pub const PresentCurrencyResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    balance: i64 = 0,
    order_id: []const u8 = "",
    present_balance: i64 = 0,
};

pub const DownloadBillRequest = struct {
    begin_ds: []const u8 = "",
    end_ds: []const u8 = "",
};

pub const DownloadBillResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    url: []const u8 = "",
};

pub const RefundOrderRequest = struct {
    openid: []const u8 = "",
    env: Env = .production,
    order_id: []const u8 = "",
    wx_order_id: []const u8 = "",
    refund_order_id: []const u8 = "",
    left_fee: i64 = 0,
    refund_fee: i64 = 0,
    biz_meta: []const u8 = "",
    refund_reason: []const u8 = "",
    req_from: []const u8 = "",
};

pub const RefundOrderResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    refund_order_id: []const u8 = "",
    refund_wx_order_id: []const u8 = "",
    pay_order_id: []const u8 = "",
    pay_wx_order_id: []const u8 = "",
};

pub const CreateWithdrawOrderRequest = struct {
    withdraw_no: []const u8 = "",
    withdraw_amount: []const u8 = "",
    env: Env = .production,
};

pub const CreateWithdrawOrderResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    withdraw_no: []const u8 = "",
    wx_withdraw_no: []const u8 = "",
};

pub const QueryWithdrawOrderRequest = struct {
    withdraw_no: []const u8 = "",
    env: Env = .production,
};

pub const QueryWithdrawOrderResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    withdraw_no: []const u8 = "",
    /// 1-创建成功/提现中 2-提现成功 3-提现失败。
    status: i64 = 0,
    withdraw_amount: []const u8 = "",
    wx_withdraw_no: []const u8 = "",
    withdraw_success_timestamp: i64 = 0,
    create_time: []const u8 = "",
    /// 提现失败的原因（官方文档字段名为 `fail_reason`）。
    fail_reason: []const u8 = "",

    /// 自定义 JSON 解析（`std.json` 自动调用，调用方无需直接调用）。
    ///
    /// 本响应有两处上游写法不统一，这里「官方为主、Go 参考兜底」都收，避免
    /// 静默丢掉业务值：
    /// - 提现失败原因：官方文档是 `fail_reason`，Go 参考与部分网关返回 `failReason`；
    /// - `withdraw_success_timestamp`：官方文档标注为 string，Go 参考与既有夹具是
    ///   number，两种形态都能解出秒级时间戳。
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !@This() {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        if (value != .object) return error.UnexpectedToken;
        var out: @This() = .{};
        var it = value.object.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const raw = kv.value_ptr.*;
            if (std.mem.eql(u8, key, "errcode")) {
                out.errcode = jsonValueInt(raw);
            } else if (std.mem.eql(u8, key, "errmsg")) {
                out.errmsg = jsonValueString(raw);
            } else if (std.mem.eql(u8, key, "withdraw_no")) {
                out.withdraw_no = jsonValueString(raw);
            } else if (std.mem.eql(u8, key, "status")) {
                out.status = jsonValueInt(raw);
            } else if (std.mem.eql(u8, key, "withdraw_amount")) {
                out.withdraw_amount = jsonValueString(raw);
            } else if (std.mem.eql(u8, key, "wx_withdraw_no")) {
                out.wx_withdraw_no = jsonValueString(raw);
            } else if (std.mem.eql(u8, key, "withdraw_success_timestamp")) {
                out.withdraw_success_timestamp = jsonValueInt(raw);
            } else if (std.mem.eql(u8, key, "create_time")) {
                out.create_time = jsonValueString(raw);
            } else if (std.mem.eql(u8, key, "fail_reason") or std.mem.eql(u8, key, "failReason")) {
                // 两种写法同时出现时以官方下划线写法为准。
                if (out.fail_reason.len == 0) out.fail_reason = jsonValueString(raw);
            }
        }
        return out;
    }
};

/// `std.json.Value` 的字面量取值：非字符串一律回退空串。
fn jsonValueString(raw: std.json.Value) []const u8 {
    return switch (raw) {
        .string => |s| s,
        else => "",
    };
}

/// `std.json.Value` 的整型取值：兼容 number / float / 数字字符串
/// （微信多数时间戳字段在文档里是 string，在既有夹具里是 number）。
fn jsonValueInt(raw: std.json.Value) i64 {
    return switch (raw) {
        .integer => |n| n,
        .float => |f| std.math.lossyCast(i64, f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " "), 10) catch 0,
        else => 0,
    };
}

pub const UploadItem = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    price: i64 = 0,
    remark: []const u8 = "",
    item_url: []const u8 = "",
    upload_status: i64 = 0,
    errmsg: []const u8 = "",
};

pub const StartUploadGoodsRequest = struct {
    upload_item: []const UploadItem = &.{},
    env: Env = .production,
};

pub const StartUploadGoodsResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const QueryUploadGoodsRequest = struct {
    env: Env = .production,
};

pub const QueryUploadGoodsResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    upload_item: []const UploadItem = &.{},
    status: i64 = 0,
};

pub const PublishItem = struct {
    id: []const u8 = "",
    publish_status: i64 = 0,
    errmsg: []const u8 = "",
};

pub const StartPublishGoodsRequest = struct {
    env: Env = .production,
    publish_item: []const PublishItem = &.{},
};

pub const StartPublishGoodsResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const QueryPublishGoodsRequest = struct {
    env: Env = .production,
};

pub const QueryPublishGoodsResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    publish_item: []const PublishItem = &.{},
    status: i64 = 0,
};

pub const StartDownloadOrderRequest = struct {
    env: Env = .production,
    begin_ds: []const u8 = "",
    end_ds: []const u8 = "",
};

pub const StartDownloadOrderResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const QueryDownloadOrderRequest = StartDownloadOrderRequest;

pub const QueryDownloadOrderResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    url: []const u8 = "",
};

pub const QueryBizBalanceRequest = struct {
    env: Env = .production,
};

pub const BizBalanceAvailable = struct {
    amount: []const u8 = "",
    currency_code: []const u8 = "",
};

pub const QueryBizBalanceResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    balance_available: ?BizBalanceAvailable = null,
};

pub const TransferAccount = struct {
    transfer_account_name: []const u8 = "",
    transfer_account_uid: i64 = 0,
    transfer_account_agency_id: i64 = 0,
    transfer_account_agency_name: []const u8 = "",
    state: i64 = 0,
    bind_result: i64 = 0,
    error_msg: []const u8 = "",
};

pub const QueryTransferAccountRequest = struct {
    env: Env = .production,
};

pub const QueryTransferAccountResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    acct_list: []const TransferAccount = &.{},
};

pub const AdverFundsFilter = struct {
    settle_begin: i64 = 0,
    settle_end: i64 = 0,
    fund_type: i64 = 0,
};

pub const AdverFundsRecord = struct {
    settle_begin: i64 = 0,
    settle_end: i64 = 0,
    total_amount: i64 = 0,
    remain_amount: i64 = 0,
    expire_time: i64 = 0,
    fund_type: i64 = 0,
    fund_id: []const u8 = "",
};

pub const QueryAdverFundsRequest = struct {
    env: Env = .production,
    page: i64 = 0,
    page_size: i64 = 0,
    filter: ?AdverFundsFilter = null,
};

pub const QueryAdverFundsResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    adver_funds_list: []const AdverFundsRecord = &.{},
    total_page: i64 = 0,
};

pub const CreateFundsBillRequest = struct {
    env: Env = .production,
    transfer_amount: i64 = 0,
    transfer_account_uid: i64 = 0,
    transfer_account_name: []const u8 = "",
    transfer_account_agency_id: i64 = 0,
    request_id: []const u8 = "",
    settle_begin: i64 = 0,
    settle_end: i64 = 0,
    authorize_advertise: i64 = 0,
    fund_type: i64 = 0,
};

pub const CreateFundsBillResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    bill_id: []const u8 = "",
};

pub const BindTransferAccountRequest = struct {
    env: Env = .production,
    transfer_account_uid: i64 = 0,
    transfer_account_org_name: []const u8 = "",
};

pub const BindTransferAccountResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const FundsBillFilter = struct {
    oper_time_begin: i64 = 0,
    oper_time_end: i64 = 0,
    bill_id: []const u8 = "",
    request_id: []const u8 = "",
};

pub const FundsBillRecord = struct {
    bill_id: []const u8 = "",
    oper_time: i64 = 0,
    settle_begin: i64 = 0,
    settle_end: i64 = 0,
    fund_id: []const u8 = "",
    transfer_account_name: []const u8 = "",
    transfer_account_uid: i64 = 0,
    transfer_amount: i64 = 0,
    status: i64 = 0,
    request_id: []const u8 = "",
};

pub const QueryFundsBillRequest = struct {
    env: Env = .production,
    page: i64 = 0,
    page_size: i64 = 0,
    filter: FundsBillFilter = .{},
};

pub const QueryFundsBillResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    bill_list: []const FundsBillRecord = &.{},
    total_page: i64 = 0,
};

pub const RecoverBillFilter = struct {
    recover_time_begin: i64 = 0,
    recover_time_end: i64 = 0,
    bill_id: []const u8 = "",
};

pub const RecoverBillRecord = struct {
    bill_id: []const u8 = "",
    recover_time: i64 = 0,
    settle_begin: i64 = 0,
    settle_end: i64 = 0,
    fund_id: []const u8 = "",
    recover_account_name: []const u8 = "",
    recover_amount: i64 = 0,
    refund_order_list: []const []const u8 = &.{},
};

pub const QueryRecoverBillRequest = struct {
    env: Env = .production,
    page: i64 = 0,
    page_size: i64 = 0,
    filter: RecoverBillFilter = .{},
};

pub const QueryRecoverBillResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    bill_list: []const RecoverBillRecord = &.{},
    total_page: i64 = 0,
};

pub const DownloadAdverFundsOrderRequest = struct {
    env: Env = .production,
    fund_id: []const u8 = "",
};

pub const DownloadAdverFundsOrderResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    url: []const u8 = "",
};

pub const GetComplaintListRequest = struct {
    env: Env = .production,
    /// 筛选偏移，从 0 开始（官方必填）。
    offset: i64 = 0,
    /// 筛选最多返回条数（官方必填）。
    ///
    /// ⚠ `0` **不是**有效值 —— 官方把本字段标为必填且给出的是「最多返回条数」语义，
    /// 传 0 会被服务端按参数错误拒（`268490002`）。本结构体保留 `0` 作默认只是
    /// 「未设置」的标记，调用方必须显式给一个正数（如 10 / 20）。
    limit: i64 = 0,
    begin_date: []const u8 = "",
    end_date: []const u8 = "",
};

pub const GetComplaintListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total: i64 = 0,
    complaints: []const ComplaintItem = &.{},
};

/// 投诉单关联订单信息（官方 `complaints[].complaint_order_info`）。
pub const ComplaintOrderInfo = struct {
    /// 投诉单关联的微信支付交易单号。
    transaction_id: []const u8 = "",
    /// 渠道单号，`query_order` 返回的 `channel_order_id`。
    out_trade_no: []const u8 = "",
    /// 订单金额，单位分。
    amount: i64 = 0,
    /// 商户单号，商家在拉起支付时传的单号。
    wxa_out_trade_no: []const u8 = "",
    /// 小程序侧单号。
    wx_order_id: []const u8 = "",
};

/// 投诉单关联服务单信息（官方 `complaints[].service_order_info`）。
pub const ComplaintServiceOrderInfo = struct {
    /// 微信支付服务订单号。
    order_id: []const u8 = "",
    /// 商户系统内部服务订单号。
    out_order_no: []const u8 = "",
    /// DOING-进行中 REVOKED-已取消 WAITPAY-待支付 DONE-已完成。
    state: []const u8 = "",
};

/// 投诉相关资料凭证（官方 `complaints[].complaint_media_list`，协商历史同构复用）。
pub const ComplaintMedia = struct {
    /// USER_COMPLAINT_IMAGE-用户提交投诉时上传；OPERATION_IMAGE-协商过程中上传。
    media_type: []const u8 = "",
    /// 媒体文件请求 url（官方为字符串数组，不是单个字符串）。
    media_url: []const []const u8 = &.{},
};

/// 投诉单（官方 `complaints[]` 元素，`get_complaint_detail` 的 `complaint` 同构）。
pub const ComplaintItem = struct {
    complaint_id: []const u8 = "",
    /// 投诉时间，格式 `yyyy-mm-dd'T'HH:MM:ssXXX`（官方为 string，不是时间戳）。
    complaint_time: []const u8 = "",
    complaint_detail: []const u8 = "",
    /// PENDING-待处理 PROCESSING-处理中 PROCESSED-已处理完成（官方为 string）。
    complaint_state: []const u8 = "",
    payer_phone: []const u8 = "",
    payer_openid: []const u8 = "",
    complaint_order_info: []const ComplaintOrderInfo = &.{},
    /// 投诉单下所有订单是否已全部全额退款。
    complaint_full_refunded: bool = false,
    /// 投诉单是否有待回复的用户留言。
    incoming_user_response: bool = false,
    /// 用户投诉次数（首次记为 1，之后每继续投诉一次加 1）。
    user_complaint_times: i64 = 0,
    complaint_media_list: []const ComplaintMedia = &.{},
    /// 用户发起投诉前选择的 faq 标题。
    problem_description: []const u8 = "",
    /// REFUND-申请退款 SERVICE_NOT_WORK-服务权益未生效 OTHERS-其他类型。
    problem_type: []const u8 = "",
    /// 问题类型为申请退款时有值，单位分。
    apply_refund_amount: i64 = 0,
    /// TRUSTED-满足极速退款条件 HIGH_RISK-高风险投诉。
    user_tag_list: []const []const u8 = &.{},
    service_order_info: []const ComplaintServiceOrderInfo = &.{},
};

pub const GetComplaintDetailRequest = struct {
    env: Env = .production,
    complaint_id: []const u8 = "",
};

pub const GetComplaintDetailResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 详情在 `complaint` 对象里（与 `complaints[]` 元素结构一致），不在顶层。
    complaint: ?ComplaintItem = null,
};

pub const GetNegotiationHistoryRequest = struct {
    env: Env = .production,
    complaint_id: []const u8 = "",
    /// 筛选偏移，从 0 开始（官方必填）。
    offset: i64 = 0,
    /// 筛选最多返回条数（官方必填）。
    limit: i64 = 0,
};

/// 一条协商历史记录（官方 `history[]`）。
pub const NegotiationHistory = struct {
    /// 操作流水号。
    log_id: []const u8 = "",
    /// 当前投诉协商记录的操作人。
    operator: []const u8 = "",
    /// 当前操作时间，格式 `yyyy-mm-dd'T'HH:MM:ssXXX`（官方为 string）。
    operate_time: []const u8 = "",
    /// USER_CREATE_COMPLAINT / MERCHANT_RESPONSE / ... 等枚举字符串。
    operate_type: []const u8 = "",
    /// 当前投诉协商记录的具体内容。
    operate_details: []const u8 = "",
    complaint_media_list: []const ComplaintMedia = &.{},
};

pub const GetNegotiationHistoryResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total: i64 = 0,
    history: []const NegotiationHistory = &.{},
};

pub const ResponseComplaintRequest = struct {
    env: Env = .production,
    complaint_id: []const u8 = "",
    response_content: []const u8 = "",
    /// 图片文件 ID 列表，元素取自 `upload_vp_file` 返回的 `file_id`。
    ///
    /// 官方把本字段标为**必填**（array of string），故即使为空也写出 `[]`
    /// （否则 `268490002`）。
    response_images: []const []const u8 = &.{},
};

pub const ResponseComplaintResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const CompleteComplaintRequest = struct {
    env: Env = .production,
    complaint_id: []const u8 = "",
};

pub const CompleteComplaintResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const UploadVPFileRequest = struct {
    env: Env = .production,
    /// 经 base64 编码后的图片内容，最大 1MB（与 `img_url` 至少提供一个）。
    base64_img: []const u8 = "",
    /// 图片 url，最高允许 2MB，优先使用本字段；为空则省略该字段。
    img_url: []const u8 = "",
    /// 图片名称。
    file_name: []const u8 = "",
};

pub const UploadVPFileResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    file_id: []const u8 = "",
};

pub const GetUploadFileSignRequest = struct {
    env: Env = .production,
    /// 微信支付的图片地址，形如
    /// `https://api.mch.weixin.qq.com/v3/merchant-service/images/{xxxxxx}`。
    wxpay_url: []const u8 = "",
    /// 是否转存到 COS（转存后 `cos_url` 有效 30 分钟）。官方必填，故始终写出。
    convert_cos: bool = false,
    /// 对应的反馈投诉 id。
    complaint_id: []const u8 = "",
};

pub const GetUploadFileSignResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 微信支付图片请求的 `Authorization` 头部值。
    sign: []const u8 = "",
    /// `convert_cos=true` 时返回的转存地址，30 分钟有效。
    cos_url: []const u8 = "",
};

/// 小程序虚拟支付模块。
pub const VirtualPayment = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    session_key: []const u8 = "",

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 设置用户态签名 sessionKey。
    pub fn setSessionKey(self: *Self, session_key: []const u8) void {
        self.session_key = session_key;
    }

    /// 查询虚拟支付余额（需用户态签名 + 支付签名）。
    pub fn queryUserBalance(self: *Self, req: QueryUserBalanceRequest) !std.json.Parsed(QueryUserBalanceResponse) {
        return self.callUser("/xpay/query_user_balance", req, QueryUserBalanceResponse);
    }

    /// 扣减代币（需用户态签名 + 支付签名）。
    pub fn currencyPay(self: *Self, req: CurrencyPayRequest) !std.json.Parsed(CurrencyPayResponse) {
        return self.callUser("/xpay/currency_pay", req, CurrencyPayResponse);
    }

    /// 取消代币支付（需用户态签名 + 支付签名）。
    pub fn cancelCurrencyPay(self: *Self, req: CancelCurrencyPayRequest) !std.json.Parsed(CancelCurrencyPayResponse) {
        return self.callUser("/xpay/cancel_currency_pay", req, CancelCurrencyPayResponse);
    }

    /// 查询订单（支付签名）。
    pub fn queryOrder(self: *Self, req: QueryOrderRequest) !std.json.Parsed(QueryOrderResponse) {
        return self.callPay("/xpay/query_order", req, QueryOrderResponse);
    }

    /// 通知发货（支付签名）。
    pub fn notifyProvideGoods(self: *Self, req: NotifyProvideGoodsRequest) !std.json.Parsed(NotifyProvideGoodsResponse) {
        return self.callPay("/xpay/notify_provide_goods", req, NotifyProvideGoodsResponse);
    }

    /// 赠送代币（需用户态签名 + 支付签名）。
    pub fn presentCurrency(self: *Self, req: PresentCurrencyRequest) !std.json.Parsed(PresentCurrencyResponse) {
        return self.callUser("/xpay/present_currency", req, PresentCurrencyResponse);
    }

    /// 下载账单（支付签名）。
    pub fn downloadBill(self: *Self, req: DownloadBillRequest) !std.json.Parsed(DownloadBillResponse) {
        return self.callPay("/xpay/download_bill", req, DownloadBillResponse);
    }

    /// 退款（支付签名）。
    pub fn refundOrder(self: *Self, req: RefundOrderRequest) !std.json.Parsed(RefundOrderResponse) {
        return self.callPay("/xpay/refund_order", req, RefundOrderResponse);
    }

    /// 创建提现单（支付签名）。
    pub fn createWithdrawOrder(self: *Self, req: CreateWithdrawOrderRequest) !std.json.Parsed(CreateWithdrawOrderResponse) {
        return self.callPay("/xpay/create_withdraw_order", req, CreateWithdrawOrderResponse);
    }

    /// 查询提现单（支付签名）。
    pub fn queryWithdrawOrder(self: *Self, req: QueryWithdrawOrderRequest) !std.json.Parsed(QueryWithdrawOrderResponse) {
        return self.callPay("/xpay/query_withdraw_order", req, QueryWithdrawOrderResponse);
    }

    /// 启动批量上传道具任务。
    pub fn startUploadGoods(self: *Self, req: StartUploadGoodsRequest) !std.json.Parsed(StartUploadGoodsResponse) {
        return self.callPay("/xpay/start_upload_goods", req, StartUploadGoodsResponse);
    }

    /// 查询批量上传道具任务状态。
    pub fn queryUploadGoods(self: *Self, req: QueryUploadGoodsRequest) !std.json.Parsed(QueryUploadGoodsResponse) {
        return self.callPay("/xpay/query_upload_goods", req, QueryUploadGoodsResponse);
    }

    /// 启动批量发布道具任务。
    pub fn startPublishGoods(self: *Self, req: StartPublishGoodsRequest) !std.json.Parsed(StartPublishGoodsResponse) {
        return self.callPay("/xpay/start_publish_goods", req, StartPublishGoodsResponse);
    }

    /// 查询批量发布道具任务状态。
    pub fn queryPublishGoods(self: *Self, req: QueryPublishGoodsRequest) !std.json.Parsed(QueryPublishGoodsResponse) {
        return self.callPay("/xpay/query_publish_goods", req, QueryPublishGoodsResponse);
    }

    /// 发起下载订单明细任务。
    pub fn startDownloadOrder(self: *Self, req: StartDownloadOrderRequest) !std.json.Parsed(StartDownloadOrderResponse) {
        return self.callPay("/xpay/start_download_order", req, StartDownloadOrderResponse);
    }

    /// 查询下载订单任务结果。
    pub fn queryDownloadOrder(self: *Self, req: QueryDownloadOrderRequest) !std.json.Parsed(QueryDownloadOrderResponse) {
        return self.callPay("/xpay/query_download_order", req, QueryDownloadOrderResponse);
    }

    /// 查询商家账户可提现余额。
    pub fn queryBizBalance(self: *Self, req: QueryBizBalanceRequest) !std.json.Parsed(QueryBizBalanceResponse) {
        return self.callPay("/xpay/query_biz_balance", req, QueryBizBalanceResponse);
    }

    /// 查询广告金充值账户。
    pub fn queryTransferAccount(self: *Self, req: QueryTransferAccountRequest) !std.json.Parsed(QueryTransferAccountResponse) {
        return self.callPay("/xpay/query_transfer_account", req, QueryTransferAccountResponse);
    }

    /// 查询广告金发放记录。
    pub fn queryAdverFunds(self: *Self, req: QueryAdverFundsRequest) !std.json.Parsed(QueryAdverFundsResponse) {
        return self.callPay("/xpay/query_adver_funds", req, QueryAdverFundsResponse);
    }

    /// 充值广告金。
    pub fn createFundsBill(self: *Self, req: CreateFundsBillRequest) !std.json.Parsed(CreateFundsBillResponse) {
        return self.callPay("/xpay/create_funds_bill", req, CreateFundsBillResponse);
    }

    /// 绑定广告金充值账户。
    pub fn bindTransferAccount(self: *Self, req: BindTransferAccountRequest) !std.json.Parsed(BindTransferAccountResponse) {
        return self.callPay("/xpay/bind_transfer_accout", req, BindTransferAccountResponse);
    }

    /// 查询广告金充值记录。
    pub fn queryFundsBill(self: *Self, req: QueryFundsBillRequest) !std.json.Parsed(QueryFundsBillResponse) {
        return self.callPay("/xpay/query_funds_bill", req, QueryFundsBillResponse);
    }

    /// 查询广告金回收记录。
    pub fn queryRecoverBill(self: *Self, req: QueryRecoverBillRequest) !std.json.Parsed(QueryRecoverBillResponse) {
        return self.callPay("/xpay/query_recover_bill", req, QueryRecoverBillResponse);
    }

    /// 下载广告金对应的商户订单信息。
    pub fn downloadAdverFundsOrder(self: *Self, req: DownloadAdverFundsOrderRequest) !std.json.Parsed(DownloadAdverFundsOrderResponse) {
        return self.callPay("/xpay/download_adverfunds_order", req, DownloadAdverFundsOrderResponse);
    }

    /// 获取投诉列表。
    pub fn getComplaintList(self: *Self, req: GetComplaintListRequest) !std.json.Parsed(GetComplaintListResponse) {
        return self.callPay("/xpay/get_complaint_list", req, GetComplaintListResponse);
    }

    /// 获取投诉详情。
    pub fn getComplaintDetail(self: *Self, req: GetComplaintDetailRequest) !std.json.Parsed(GetComplaintDetailResponse) {
        return self.callPay("/xpay/get_complaint_detail", req, GetComplaintDetailResponse);
    }

    /// 获取协商历史。
    pub fn getNegotiationHistory(self: *Self, req: GetNegotiationHistoryRequest) !std.json.Parsed(GetNegotiationHistoryResponse) {
        return self.callPay("/xpay/get_negotiation_history", req, GetNegotiationHistoryResponse);
    }

    /// 回复用户。
    pub fn responseComplaint(self: *Self, req: ResponseComplaintRequest) !std.json.Parsed(ResponseComplaintResponse) {
        return self.callPay("/xpay/response_complaint", req, ResponseComplaintResponse);
    }

    /// 完成投诉处理。
    pub fn completeComplaint(self: *Self, req: CompleteComplaintRequest) !std.json.Parsed(CompleteComplaintResponse) {
        return self.callPay("/xpay/complete_complaint", req, CompleteComplaintResponse);
    }

    /// 上传媒体文件。
    pub fn uploadVPFile(self: *Self, req: UploadVPFileRequest) !std.json.Parsed(UploadVPFileResponse) {
        return self.callPay("/xpay/upload_vp_file", req, UploadVPFileResponse);
    }

    /// 获取上传文件签名头部。
    pub fn getUploadFileSign(self: *Self, req: GetUploadFileSignRequest) !std.json.Parsed(GetUploadFileSignResponse) {
        return self.callPay("/xpay/get_upload_file_sign", req, GetUploadFileSignResponse);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 内部：签名与请求
    // ─────────────────────────────────────────────────────────────────────────

    fn callUser(self: *Self, path: []const u8, req: anytype, comptime R: type) !std.json.Parsed(R) {
        return self.callSigned(path, req, true, R);
    }

    fn callPay(self: *Self, path: []const u8, req: anytype, comptime R: type) !std.json.Parsed(R) {
        return self.callSigned(path, req, false, R);
    }

    /// 带签名的接口调用。
    ///
    /// 请求体只序列化一次（pay_sig / signature 都基于同一份字节），发送交给
    /// `util_retry.callApi`：它负责「识别 40001 / 40014 / 41001 / 42001 → 作废缓存
    /// access_token → 取新 token → 只重试一次」。URI 组装与 transport 注入仍留在
    /// 本模块内（见 `SignedReq.send` / `requestAddress`），重试只是把 `?access_token=`
    /// 换成新值，`pay_sig` / `signature` 与 token 无关、逐字不变。
    fn callSigned(self: *Self, path: []const u8, req: anytype, with_signature: bool, comptime R: type) !std.json.Parsed(R) {
        const body = try jsonStringify(self.allocator, req);
        defer self.allocator.free(body);

        const resp = try util_retry.callApi(self.ctx, self.allocator, path, SignedReq{
            .vp = self,
            .path = path,
            .content = body,
            .with_signature = with_signature,
        });
        defer self.allocator.free(resp);

        return parseResponse(R, self.allocator, resp);
    }

    /// 计算请求地址（带 pay_sig，可选 signature）。
    ///
    /// `access_token` 由调用方注入——`SignedReq.send` 从 `util_retry.callApi` 拿到
    /// 当前 token（失效重试时是刷新后的新 token），本方法不再自己去取。
    fn requestAddress(
        self: *Self,
        allocator: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
        with_signature: bool,
        access_token: []const u8,
    ) ![]u8 {
        const pay_sig = try self.paySign(path, content);
        defer self.allocator.free(pay_sig);

        if (with_signature) {
            const sig = try self.signature(content);
            defer self.allocator.free(sig);
            return allocator.print(
                "https://api.weixin.qq.com{s}?access_token={s}&pay_sig={s}&signature={s}",
                .{ path, access_token, pay_sig, sig },
            );
        }
        return allocator.print(
            "https://api.weixin.qq.com{s}?access_token={s}&pay_sig={s}",
            .{ path, access_token, pay_sig },
        );
    }

    /// 支付签名 = HMAC-SHA256(app_key, path + "&" + content)。
    fn paySign(self: *Self, path: []const u8, content: []const u8) ![]u8 {
        if (self.ctx.config.app_key.len == 0) return error.AppKeyEmpty;
        var data = std.ArrayList(u8).empty;
        defer data.deinit(self.allocator);
        try data.appendSlice(self.allocator, path);
        try data.appendSlice(self.allocator, "&");
        try data.appendSlice(self.allocator, content);
        return hmacSha256Hex(self.allocator, self.ctx.config.app_key, data.items);
    }

    /// 用户态签名 = HMAC-SHA256(session_key, content)。
    fn signature(self: *Self, content: []const u8) ![]u8 {
        if (self.session_key.len == 0) return error.SessionKeyEmpty;
        return hmacSha256Hex(self.allocator, self.session_key, content);
    }

    /// 发送请求并返回原始响应体：所有权在返回时转移给调用方
    /// （`util_retry.callApi` 持有并在失败路径上释放）。
    ///
    /// 走 `getDefaultClient`（线程局部单例），测试通过 `setupTestClient` 注入
    /// transport，因此重试链路复用同一份注入。
    fn postRaw(self: *Self, uri: []const u8, body: []const u8) ![]u8 {
        const client = util_http.getDefaultClient(self.allocator);
        return client.post(uri, body, "application/json;charset=utf-8");
    }

    /// 解析响应体。errcode 检查已由 `util_retry.callApi` 完成（失败即抛 ApiError），
    /// 这里再兜一层「callApi 认不出错误体、但响应里 errcode 非 0」的情况，与改造前一致。
    fn parseResponse(comptime T: type, allocator: std.mem.Allocator, resp: []const u8) !std.json.Parsed(T) {
        var parsed = std.json.parseFromSlice(T, allocator, resp, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

/// 带签名的请求发送器（`util_retry.callApi` 的 `sender`）。
///
/// URI 组装与 transport 注入仍由本模块负责，`callApi` 只注入 / 刷新
/// `access_token`：token 失效重试时除 `access_token` 外的所有字节
/// （path、body、pay_sig、signature）逐字不变。
const SignedReq = struct {
    vp: *VirtualPayment,
    path: []const u8,
    content: []const u8,
    with_signature: bool,

    pub fn send(self: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const uri = try self.vp.requestAddress(allocator, self.path, self.content, self.with_signature, token);
        defer allocator.free(uri);
        return self.vp.postRaw(uri, self.content);
    }
};

fn hmacSha256Hex(allocator: std.mem.Allocator, key: []const u8, data: []const u8) ![]u8 {
    var out: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data, key);
    return allocator.dupe(u8, &std.fmt.bytesToHex(&out, .lower));
}

fn jsonStringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info != .@"struct") return error.InvalidType;
    try s.beginObject();
    inline for (info.@"struct".field_names, info.@"struct".field_types) |name, ftype| {
        const fv = @field(value, name);
        // 跳过空字符串 / 零值可选字段（与 Go omitempty 语义对齐的简化）；
        // 官方标注「必填」的数值字段不参与该省略（见 isAlwaysWritten）。
        const skip_if_empty = comptime (isSkippable(ftype) and !isAlwaysWritten(name));
        const should_write = if (skip_if_empty) !isEmpty(ftype, fv) else true;
        if (should_write) {
            try s.objectField(name);
            // 微信 xpay 契约要求 env 为数字（0 正式 / 1 沙箱，见 Go 参考 domain.go），
            // 而 exhaustive enum 经 stringify 会写成 tag 名字符串，这里特判写 backing int。
            if (comptime (ftype == Env)) {
                try s.write(@backingInt(fv));
            } else {
                try s.write(fv);
            }
        }
    }
    try s.endObject();
    return out.toOwnedSlice();
}

/// 官方文档标注为「必填」的字段：即使取「零值」（`0` / 空数组）也必须出现在请求体里。
///
/// 本模块用「零值省略」近似 Go 的 `omitempty`，但有几类字段的零值是**合法取值**，
/// 省略它们会让接口直接返回 268490002（请求参数字段错误）：
/// - `offset` / `limit`：`get_complaint_list` / `get_negotiation_history` 的官方必填分页字段
///   （`offset=0` 就是合法的首屏偏移）；
/// - `response_images`：`response_complaint` 的官方必填图片列表，为空时要写 `[]` 而非省略。
fn isAlwaysWritten(name: []const u8) bool {
    return std.mem.eql(u8, name, "offset") or
        std.mem.eql(u8, name, "limit") or
        std.mem.eql(u8, name, "response_images");
}

fn isSkippable(comptime T: type) bool {
    return T == []const u8 or T == i64 or T == Env or T == []const []const u8;
}

fn isEmpty(comptime T: type, v: anytype) bool {
    if (T == []const u8) return v.len == 0;
    if (T == i64) return v == 0;
    if (T == Env) return v == .production;
    // 字符串数组：空数组视为「零值」。注意 `response_images` 虽是数组，但官方标注必填，
    // 已由 `isAlwaysWritten` 强制写出，本分支对它不生效。
    if (T == []const []const u8) return v.len == 0;
    return false;
}

test "VirtualPayment.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-vp", .app_key = "key" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const v = VirtualPayment.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-vp", v.ctx.config.app_id);
}

test "hmacSha256Hex 输出 64 字符 hex" {
    const allocator = std.testing.allocator;
    const out = try hmacSha256Hex(allocator, "key", "data");
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 64), out.len);
}

test "paySign 空 app_key 返回 AppKeyEmpty" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-vp2" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var v = VirtualPayment.init(&ctx, std.heap.page_allocator);
    const result = v.paySign("/xpay/test", "{}");
    try std.testing.expectError(error.AppKeyEmpty, result);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：假 AccessTokenHandle + capture transport。
// ─────────────────────────────────────────────────────────────────────────────

const credential = @import("../../credential/mod.zig");

fn testGetAccessToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, "stub-ak");
}

const test_token_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = testGetAccessToken,
};

const TestCapture = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    /// 非空时按调用次序取响应（越界复用最后一项），用于 token 失效重试测试。
    responses: []const []const u8 = &.{},
    /// 收到过的请求次数。
    calls: usize = 0,
    /// 每次请求的 HTTP method（越界不记录），用 `methodAt` 读取。
    methods: [4]std.http.Method = @splat(std.http.Method.POST),
    /// 最近一次请求的副本（借用 arena / 测试 allocator，测试结束前一直有效）。
    uri: []u8 = &.{},
    payload: []u8 = &.{},
    /// 每次请求 URI / 请求体的副本（越界不记录），用 `uriAt` / `payloadAt` 读取。
    uri_history: [4][400]u8 = @splat(@splat(0)),
    uri_lens: [4]usize = @splat(0),
    payload_history: [4][400]u8 = @splat(@splat(0)),
    payload_lens: [4]usize = @splat(0),

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = content_type;
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        if (self.calls < self.methods.len) self.methods[self.calls] = method;
        if (self.calls < self.uri_history.len and uri.len <= self.uri_history[0].len) {
            @memcpy(self.uri_history[self.calls][0..uri.len], uri);
            self.uri_lens[self.calls] = uri.len;
        }
        if (self.calls < self.payload_history.len and payload.len <= self.payload_history[0].len) {
            @memcpy(self.payload_history[self.calls][0..payload.len], payload);
            self.payload_lens[self.calls] = payload.len;
        }
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        const body = if (self.responses.len > 0)
            self.responses[@min(self.calls, self.responses.len - 1)]
        else
            self.response;
        self.calls += 1;
        return allocator.dupe(u8, body);
    }

    fn uriAt(self: *const TestCapture, idx: usize) []const u8 {
        return self.uri_history[idx][0..self.uri_lens[idx]];
    }

    fn payloadAt(self: *const TestCapture, idx: usize) []const u8 {
        return self.payload_history[idx][0..self.payload_lens[idx]];
    }

    fn methodAt(self: *const TestCapture, idx: usize) std.http.Method {
        return self.methods[idx];
    }
};

fn setupTestClient(alloc: std.mem.Allocator, cap: *TestCapture) void {
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(TestCapture.dispatch, @ptrCast(cap));
}

fn releaseTestClient() void {
    // 不依赖「用别的 allocator 再取一次指针」的宽容语义：直接销毁线程局部实例，
    // 注入的 transport 随实例一起消失（下次 getDefaultClient 会重新初始化）。
    util_http.deinitDefaultClient();
}

test "jsonStringify env=.sandbox 输出数字 1 且 production 省略 env 字段" {
    const allocator = std.testing.allocator;

    const sandbox_body = try jsonStringify(allocator, QueryBizBalanceRequest{ .env = .sandbox });
    defer allocator.free(sandbox_body);
    try std.testing.expect(std.mem.find(u8, sandbox_body, "\"env\":1") != null);
    try std.testing.expect(std.mem.find(u8, sandbox_body, "\"sandbox\"") == null);

    const prod_body = try jsonStringify(allocator, QueryBizBalanceRequest{ .env = .production });
    defer allocator.free(prod_body);
    try std.testing.expect(std.mem.find(u8, prod_body, "\"env\"") == null);
}

test "queryOrder env=.sandbox 请求体 env 为数字且 pay_sig 与发送体一致" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"order\":null}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var ctx: Context = .{
        .config = .{ .app_id = "wx-vp", .app_key = "appkey-123" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &test_token_vtable },
    };
    var v = VirtualPayment.init(&ctx, alloc);
    var parsed = try v.queryOrder(.{ .openid = "ou-1", .env = .sandbox, .order_id = "o-1" });
    defer parsed.deinit();

    // 微信 xpay 契约要求 env 为数字（1 沙箱），不得序列化为 "sandbox" 字符串。
    try std.testing.expect(std.mem.find(u8, cap.payload, "\"env\":1") != null);
    try std.testing.expect(std.mem.find(u8, cap.payload, "\"env\":\"sandbox\"") == null);

    // pay_sig = HMAC-SHA256(app_key, path + "&" + body)，签名体与发送体是同一份序列化结果。
    var data = std.ArrayList(u8).empty;
    defer data.deinit(alloc);
    try data.appendSlice(alloc, "/xpay/query_order");
    try data.appendSlice(alloc, "&");
    try data.appendSlice(alloc, cap.payload);
    const expected = try hmacSha256Hex(alloc, "appkey-123", data.items);
    try std.testing.expect(std.mem.find(u8, cap.uri, expected) != null);
}

test "queryUserBalance 用户态签名与支付签名共用同一份序列化结果" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var ctx: Context = .{
        .config = .{ .app_id = "wx-vp", .app_key = "appkey-123" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &test_token_vtable },
    };
    var v = VirtualPayment.init(&ctx, alloc);
    v.setSessionKey("sk-1");
    var parsed = try v.queryUserBalance(.{ .openid = "ou-1", .env = .sandbox, .user_ip = "1.2.3.4" });
    defer parsed.deinit();

    try std.testing.expect(std.mem.find(u8, cap.payload, "\"env\":1") != null);

    // signature = HMAC-SHA256(session_key, body)。
    const expected_sig = try hmacSha256Hex(alloc, "sk-1", cap.payload);
    try std.testing.expect(std.mem.find(u8, cap.uri, expected_sig) != null);

    // pay_sig = HMAC-SHA256(app_key, path + "&" + body)。
    var data = std.ArrayList(u8).empty;
    defer data.deinit(alloc);
    try data.appendSlice(alloc, "/xpay/query_user_balance");
    try data.appendSlice(alloc, "&");
    try data.appendSlice(alloc, cap.payload);
    const expected_pay = try hmacSha256Hex(alloc, "appkey-123", data.items);
    try std.testing.expect(std.mem.find(u8, cap.uri, expected_pay) != null);
}

// ─────────────────────────────────────────────────────────────────────────────
// token 失效自愈：业务接口返回 40001 → 作废缓存 token → 换新 token 重试一次
// ─────────────────────────────────────────────────────────────────────────────

/// 可作废的假凭据：作废前发 `tok-1`，作废后发 `tok-2`（模拟微信换发新 token）。
const HealToken = struct {
    cached: []const u8 = "tok-1",
    invalidates: usize = 0,

    fn getToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.cached);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        self.invalidates += 1;
        self.cached = "tok-2";
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

test "queryOrder token 失效自愈：40001 → 作废缓存 → 换新 token 只重试一次" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "",
        .responses = &.{
            "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
            "{\"errcode\":0,\"errmsg\":\"ok\",\"order\":null}",
        },
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var tk = HealToken{};
    var ctx: Context = .{
        .config = .{ .app_id = "wx-vp", .app_key = "appkey-123" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var v = VirtualPayment.init(&ctx, alloc);

    var parsed = try v.queryOrder(.{ .openid = "ou-1", .order_id = "o-1" });
    defer parsed.deinit();

    // 恰好作废一次、发送两次（40001 后只重试一次）。
    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), cap.calls);
    try std.testing.expectEqualStrings("tok-1", tokenOf(cap.uriAt(0)));
    try std.testing.expectEqualStrings("tok-2", tokenOf(cap.uriAt(1)));

    // 除 access_token 外两次请求逐字一致：path 前缀相同、请求体相同、
    // pay_sig（与 token 无关）也相同——重试没有改动任何签名输入。
    try std.testing.expectEqualStrings(cap.payloadAt(0), cap.payloadAt(1));
    const prefix = "https://api.weixin.qq.com/xpay/query_order?access_token=";
    try std.testing.expect(std.mem.startsWith(u8, cap.uriAt(0), prefix));
    try std.testing.expect(std.mem.startsWith(u8, cap.uriAt(1), prefix));

    var sig_input = std.ArrayList(u8).empty;
    defer sig_input.deinit(alloc);
    try sig_input.appendSlice(alloc, "/xpay/query_order");
    try sig_input.appendSlice(alloc, "&");
    try sig_input.appendSlice(alloc, cap.payloadAt(1));
    const expected_pay_sig = try hmacSha256Hex(alloc, "appkey-123", sig_input.items);
    try std.testing.expect(std.mem.find(u8, cap.uriAt(0), expected_pay_sig) != null);
    try std.testing.expect(std.mem.find(u8, cap.uriAt(1), expected_pay_sig) != null);
}

test "queryUserBalance 非 token 错误（45009）不重试也不作废" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var tk = HealToken{};
    var ctx: Context = .{
        .config = .{ .app_id = "wx-vp", .app_key = "appkey-123" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var v = VirtualPayment.init(&ctx, alloc);
    v.setSessionKey("sk-1");

    try std.testing.expectError(
        util_error.WechatError.ApiError,
        v.queryUserBalance(.{ .openid = "ou-1", .user_ip = "1.2.3.4" }),
    );
    try std.testing.expectEqual(@as(usize, 0), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 1), cap.calls);
}

test "requestAddress 逐字回归：callUser / callPay 两种 URI 拼装与改造前一致" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var ctx: Context = .{
        .config = .{ .app_id = "wx-vp", .app_key = "appkey-123" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &test_token_vtable },
    };
    var v = VirtualPayment.init(&ctx, alloc);
    v.setSessionKey("sk-1");

    // callUser：pay_sig + signature，顺序为 `?access_token=&pay_sig=&signature=`。
    var user_resp = try v.queryUserBalance(.{ .openid = "ou-1" });
    defer user_resp.deinit();

    var user_sig_input = std.ArrayList(u8).empty;
    defer user_sig_input.deinit(alloc);
    try user_sig_input.appendSlice(alloc, "/xpay/query_user_balance");
    try user_sig_input.appendSlice(alloc, "&");
    try user_sig_input.appendSlice(alloc, cap.payloadAt(0));
    const user_pay_sig = try hmacSha256Hex(alloc, "appkey-123", user_sig_input.items);
    const user_signature = try hmacSha256Hex(alloc, "sk-1", cap.payloadAt(0));
    const expected_user_uri = try alloc.print(
        "https://api.weixin.qq.com/xpay/query_user_balance?access_token=stub-ak&pay_sig={s}&signature={s}",
        .{ user_pay_sig, user_signature },
    );
    try std.testing.expectEqualStrings(expected_user_uri, cap.uriAt(0));

    // callPay：只有 pay_sig，尾部没有 signature。
    var pay_resp = try v.queryOrder(.{ .openid = "ou-1", .order_id = "o-1" });
    defer pay_resp.deinit();

    var pay_sig_input = std.ArrayList(u8).empty;
    defer pay_sig_input.deinit(alloc);
    try pay_sig_input.appendSlice(alloc, "/xpay/query_order");
    try pay_sig_input.appendSlice(alloc, "&");
    try pay_sig_input.appendSlice(alloc, cap.payloadAt(1));
    const pay_pay_sig = try hmacSha256Hex(alloc, "appkey-123", pay_sig_input.items);
    const expected_pay_uri = try alloc.print(
        "https://api.weixin.qq.com/xpay/query_order?access_token=stub-ak&pay_sig={s}",
        .{pay_pay_sig},
    );
    try std.testing.expectEqualStrings(expected_pay_uri, cap.uriAt(1));
}

/// 从 `...?access_token=X&pay_sig=...` 中取出 access_token 的值。
fn tokenOf(uri: []const u8) []const u8 {
    const key = "access_token=";
    const start = (std.mem.find(u8, uri, key) orelse return "") + key.len;
    const rest = uri[start..];
    const end = std.mem.findScalar(u8, rest, '&') orelse rest.len;
    return rest[0..end];
}

// ─────────────────────────────────────────────────────────────────────────────
// 公开 API 真实调用覆盖：下列每个接口各走一次真实调用（mock transport），
// 逐字核对「method + 完整 URI（access_token / pay_sig / signature 的位置与值）
// + 请求体」，并从响应里解析出业务字段。请求体断言同时锁住了 JSON 字段顺序，
// 因为 pay_sig / signature 的输入正是这份序列化结果。
// ─────────────────────────────────────────────────────────────────────────────

/// 建一套最小可用的 VirtualPayment 环境：注入 capture transport + 桩 token。
/// `arena` / `cap` / `ctx_out` / `vp_out` 由调用方持有，保证 ctx 指针稳定。
fn vpSetup(
    arena: *std.heap.ArenaAllocator,
    cap: *TestCapture,
    ctx_out: *Context,
    vp_out: *VirtualPayment,
    response: []const u8,
) void {
    arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    const alloc = arena.allocator();
    cap.* = .{ .allocator = alloc, .response = response };
    setupTestClient(alloc, cap);
    ctx_out.* = .{
        .config = .{ .app_id = "wx-vp", .app_key = "appkey-123" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &test_token_vtable },
    };
    vp_out.* = VirtualPayment.init(ctx_out, alloc);
}

/// 断言第 `idx` 次请求：POST + 请求体逐字 + 完整 URI（含 pay_sig 与可选
/// signature 的出现位置和值）。`session_key` 非 null 表示 callUser 双签名接口。
fn expectSignedCall(
    alloc: std.mem.Allocator,
    cap: *const TestCapture,
    idx: usize,
    path: []const u8,
    expected_body: []const u8,
    session_key: ?[]const u8,
) !void {
    try std.testing.expectEqual(std.http.Method.POST, cap.methodAt(idx));
    try std.testing.expectEqualStrings(expected_body, cap.payloadAt(idx));

    var sig_input = std.ArrayList(u8).empty;
    defer sig_input.deinit(alloc);
    try sig_input.appendSlice(alloc, path);
    try sig_input.appendSlice(alloc, "&");
    try sig_input.appendSlice(alloc, expected_body);
    const pay_sig = try hmacSha256Hex(alloc, "appkey-123", sig_input.items);

    if (session_key) |sk| {
        const user_sig = try hmacSha256Hex(alloc, sk, expected_body);
        const expected = try alloc.print(
            "https://api.weixin.qq.com{s}?access_token=stub-ak&pay_sig={s}&signature={s}",
            .{ path, pay_sig, user_sig },
        );
        try std.testing.expectEqualStrings(expected, cap.uriAt(idx));
        return;
    }
    const expected = try alloc.print(
        "https://api.weixin.qq.com{s}?access_token=stub-ak&pay_sig={s}",
        .{ path, pay_sig },
    );
    try std.testing.expectEqualStrings(expected, cap.uriAt(idx));
}

test "currencyPay 双签名：URI 与请求体逐字一致，响应解析 balance/used_present_amount" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"order_id\":\"o-1\",\"balance\":7,\"used_present_amount\":2}",
    );
    defer arena.deinit();
    defer releaseTestClient();
    v.setSessionKey("sk-1");

    var parsed = try v.currencyPay(.{
        .openid = "ou-1",
        .env = .sandbox,
        .user_ip = "1.2.3.4",
        .amount = 5,
        .order_id = "o-1",
        .payitem = "item-1",
        .remark = "remark",
        .device_type = "1",
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/currency_pay",
        "{\"openid\":\"ou-1\",\"env\":1,\"user_ip\":\"1.2.3.4\",\"amount\":5,\"order_id\":\"o-1\",\"payitem\":\"item-1\",\"remark\":\"remark\",\"device_type\":\"1\"}",
        "sk-1",
    );
    try std.testing.expectEqual(@as(i64, 7), parsed.value.balance);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.used_present_amount);
}

test "cancelCurrencyPay 双签名：env 缺省被省略、device_type 为数字" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\",\"order_id\":\"o-2\"}");
    defer arena.deinit();
    defer releaseTestClient();
    v.setSessionKey("sk-1");

    var parsed = try v.cancelCurrencyPay(.{
        .openid = "ou-1",
        .user_ip = "1.2.3.4",
        .pay_order_id = "p-1",
        .order_id = "o-2",
        .amount = 5,
        .device_type = 1,
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/cancel_currency_pay",
        "{\"openid\":\"ou-1\",\"user_ip\":\"1.2.3.4\",\"pay_order_id\":\"p-1\",\"order_id\":\"o-2\",\"amount\":5,\"device_type\":1}",
        "sk-1",
    );
    try std.testing.expectEqualStrings("o-2", parsed.value.order_id);
}

test "notifyProvideGoods 单签名：env 数字，尾部无 signature" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.notifyProvideGoods(.{ .order_id = "o-1", .env = .sandbox });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/notify_provide_goods",
        "{\"order_id\":\"o-1\",\"env\":1}",
        null,
    );
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
}

test "presentCurrency 双签名：请求体含 order_id/amount/device_type，响应解析 present_balance" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"balance\":9,\"order_id\":\"o-1\",\"present_balance\":4}",
    );
    defer arena.deinit();
    defer releaseTestClient();
    v.setSessionKey("sk-1");

    var parsed = try v.presentCurrency(.{
        .openid = "ou-1",
        .env = .sandbox,
        .order_id = "o-1",
        .amount = 3,
        .device_type = "2",
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/present_currency",
        "{\"openid\":\"ou-1\",\"env\":1,\"order_id\":\"o-1\",\"amount\":3,\"device_type\":\"2\"}",
        "sk-1",
    );
    try std.testing.expectEqual(@as(i64, 4), parsed.value.present_balance);
}

test "downloadBill 单签名：begin_ds/end_ds 逐字，响应解析 url" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://bill.example/b.csv\"}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.downloadBill(.{ .begin_ds = "20230801", .end_ds = "20230802" });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/download_bill",
        "{\"begin_ds\":\"20230801\",\"end_ds\":\"20230802\"}",
        null,
    );
    try std.testing.expectEqualStrings("https://bill.example/b.csv", parsed.value.url);
}

test "refundOrder 单签名：空字段省略，响应解析 refund_wx_order_id" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"refund_order_id\":\"r-1\",\"refund_wx_order_id\":\"wxr-1\",\"pay_order_id\":\"o-1\",\"pay_wx_order_id\":\"wxo-1\"}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.refundOrder(.{
        .openid = "ou-1",
        .order_id = "o-1",
        .refund_order_id = "r-1",
        .left_fee = 100,
        .refund_fee = 50,
        .refund_reason = "1",
        .req_from = "2",
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/refund_order",
        "{\"openid\":\"ou-1\",\"order_id\":\"o-1\",\"refund_order_id\":\"r-1\",\"left_fee\":100,\"refund_fee\":50,\"refund_reason\":\"1\",\"req_from\":\"2\"}",
        null,
    );
    try std.testing.expectEqualStrings("wxr-1", parsed.value.refund_wx_order_id);
}

test "createWithdrawOrder 单签名：withdraw_amount 是字符串，响应解析 wx_withdraw_no" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"withdraw_no\":\"w-1\",\"wx_withdraw_no\":\"wxw-1\"}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.createWithdrawOrder(.{
        .withdraw_no = "w-1",
        .withdraw_amount = "0.01",
        .env = .sandbox,
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/create_withdraw_order",
        "{\"withdraw_no\":\"w-1\",\"withdraw_amount\":\"0.01\",\"env\":1}",
        null,
    );
    try std.testing.expectEqualStrings("wxw-1", parsed.value.wx_withdraw_no);
}

test "queryWithdrawOrder 单签名：响应解析 status/withdraw_amount/fail_reason" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"withdraw_no\":\"w-1\",\"status\":2,\"withdraw_amount\":\"0.01\",\"wx_withdraw_no\":\"wxw-1\",\"withdraw_success_timestamp\":1700000000,\"create_time\":\"2024-01-01 00:00:00\",\"fail_reason\":\"\"}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryWithdrawOrder(.{ .withdraw_no = "w-1", .env = .sandbox });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_withdraw_order",
        "{\"withdraw_no\":\"w-1\",\"env\":1}",
        null,
    );
    try std.testing.expectEqual(@as(i64, 2), parsed.value.status);
    try std.testing.expectEqualStrings("0.01", parsed.value.withdraw_amount);
    try std.testing.expectEqual(@as(i64, 1700000000), parsed.value.withdraw_success_timestamp);
    try std.testing.expectEqualStrings("", parsed.value.fail_reason);
}

test "queryWithdrawOrder 兼容官方 string 时间戳与 camelCase 的 failReason" {
    // 官方文档把 withdraw_success_timestamp 标为 string；Go 参考（部分网关同样）
    // 用 camelCase 的 failReason。两种上游写法都必须能解出业务值，否则提现失败
    // 原因会静默丢失、成功时间戳会变成 0。
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"withdraw_no\":\"w-2\",\"status\":3,\"withdraw_success_timestamp\":\"1700000123\",\"failReason\":\"结算账户异常\"}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryWithdrawOrder(.{ .withdraw_no = "w-2" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 3), parsed.value.status);
    try std.testing.expectEqual(@as(i64, 1700000123), parsed.value.withdraw_success_timestamp);
    try std.testing.expectEqualStrings("结算账户异常", parsed.value.fail_reason);
}

test "queryWithdrawOrder errcode 非 0 仍报 ApiError（自定义 jsonParse 不吞错误码）" {
    // 该响应用自定义 jsonParse 解析（见 QueryWithdrawOrderResponse），
    // errcode 必须照旧喂给 parseResponse 的失败判定。
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":268490002,\"errmsg\":\"请求参数字段错误\"}");
    defer arena.deinit();
    defer releaseTestClient();

    try std.testing.expectError(
        util_error.WechatError.ApiError,
        v.queryWithdrawOrder(.{ .withdraw_no = "w-1" }),
    );
}

test "startUploadGoods 单签名：upload_item 数组元素字段序与 URL" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer arena.deinit();
    defer releaseTestClient();

    const items = [_]UploadItem{.{
        .id = "it-1",
        .name = "itemA",
        .price = 100,
        .item_url = "https://img.example/1.png",
    }};
    var parsed = try v.startUploadGoods(.{ .upload_item = &items, .env = .sandbox });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/start_upload_goods",
        "{\"upload_item\":[{\"id\":\"it-1\",\"name\":\"itemA\",\"price\":100,\"remark\":\"\",\"item_url\":\"https://img.example/1.png\",\"upload_status\":0,\"errmsg\":\"\"}],\"env\":1}",
        null,
    );
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
}

test "queryUploadGoods 单签名：请求体只有 env，响应解析 status 与 upload_item" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"upload_item\":[{\"id\":\"it-1\",\"name\":\"itemA\",\"price\":100,\"upload_status\":2}],\"status\":3}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryUploadGoods(.{ .env = .sandbox });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_upload_goods",
        "{\"env\":1}",
        null,
    );
    try std.testing.expectEqual(@as(i64, 3), parsed.value.status);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.upload_item.len);
    try std.testing.expectEqualStrings("it-1", parsed.value.upload_item[0].id);
}

test "startPublishGoods 单签名：publish_item 数组字段序与 URL" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer arena.deinit();
    defer releaseTestClient();

    const items = [_]PublishItem{.{ .id = "it-1" }};
    var parsed = try v.startPublishGoods(.{ .env = .sandbox, .publish_item = &items });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/start_publish_goods",
        "{\"env\":1,\"publish_item\":[{\"id\":\"it-1\",\"publish_status\":0,\"errmsg\":\"\"}]}",
        null,
    );
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
}

test "queryPublishGoods 单签名：响应解析 status 与 publish_item" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"publish_item\":[{\"id\":\"it-1\",\"publish_status\":2,\"errmsg\":\"\"}],\"status\":3}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryPublishGoods(.{ .env = .sandbox });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_publish_goods",
        "{\"env\":1}",
        null,
    );
    try std.testing.expectEqual(@as(i64, 3), parsed.value.status);
    try std.testing.expectEqualStrings("it-1", parsed.value.publish_item[0].id);
}

test "startDownloadOrder 单签名：env/begin_ds/end_ds 字段序与 URL" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.startDownloadOrder(.{
        .env = .sandbox,
        .begin_ds = "20230801",
        .end_ds = "20230802",
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/start_download_order",
        "{\"env\":1,\"begin_ds\":\"20230801\",\"end_ds\":\"20230802\"}",
        null,
    );
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
}

test "queryDownloadOrder 单签名：响应解析 url" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://order.example/o.csv\"}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryDownloadOrder(.{
        .env = .sandbox,
        .begin_ds = "20230801",
        .end_ds = "20230802",
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_download_order",
        "{\"env\":1,\"begin_ds\":\"20230801\",\"end_ds\":\"20230802\"}",
        null,
    );
    try std.testing.expectEqualStrings("https://order.example/o.csv", parsed.value.url);
}

test "queryBizBalance 单签名：响应解析 balance_available" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"balance_available\":{\"amount\":\"12.34\",\"currency_code\":\"CNY\"}}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryBizBalance(.{ .env = .sandbox });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_biz_balance",
        "{\"env\":1}",
        null,
    );
    const available = parsed.value.balance_available orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("12.34", available.amount);
    try std.testing.expectEqualStrings("CNY", available.currency_code);
}

test "queryTransferAccount 单签名：响应解析 acct_list 元素" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"acct_list\":[{\"transfer_account_name\":\"acct\",\"transfer_account_uid\":42,\"transfer_account_agency_id\":7,\"transfer_account_agency_name\":\"agency\",\"state\":1,\"bind_result\":1,\"error_msg\":\"\"}]}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryTransferAccount(.{ .env = .sandbox });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_transfer_account",
        "{\"env\":1}",
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), parsed.value.acct_list.len);
    try std.testing.expectEqualStrings("acct", parsed.value.acct_list[0].transfer_account_name);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.acct_list[0].transfer_account_uid);
}

test "queryAdverFunds 单签名：filter 有值写对象、为 null 写 null，响应解析 total_page" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"adver_funds_list\":[{\"settle_begin\":100,\"settle_end\":200,\"total_amount\":1000,\"remain_amount\":500,\"expire_time\":300,\"fund_type\":1,\"fund_id\":\"f-1\"}],\"total_page\":3}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var with_filter = try v.queryAdverFunds(.{
        .env = .sandbox,
        .page = 1,
        .page_size = 10,
        .filter = .{ .settle_begin = 100, .fund_type = 1 },
    });
    defer with_filter.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_adver_funds",
        "{\"env\":1,\"page\":1,\"page_size\":10,\"filter\":{\"settle_begin\":100,\"settle_end\":0,\"fund_type\":1}}",
        null,
    );
    try std.testing.expectEqual(@as(i64, 3), with_filter.value.total_page);
    try std.testing.expectEqualStrings("f-1", with_filter.value.adver_funds_list[0].fund_id);

    var no_filter = try v.queryAdverFunds(.{ .env = .sandbox, .page = 2, .page_size = 10 });
    defer no_filter.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        1,
        "/xpay/query_adver_funds",
        "{\"env\":1,\"page\":2,\"page_size\":10,\"filter\":null}",
        null,
    );
}

test "createFundsBill 单签名：全部 10 个字段按声明序写出，响应解析 bill_id" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\",\"bill_id\":\"bill-1\"}");
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.createFundsBill(.{
        .env = .sandbox,
        .transfer_amount = 100,
        .transfer_account_uid = 42,
        .transfer_account_name = "acct",
        .transfer_account_agency_id = 7,
        .request_id = "req-1",
        .settle_begin = 100,
        .settle_end = 200,
        .authorize_advertise = 1,
        .fund_type = 1,
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/create_funds_bill",
        "{\"env\":1,\"transfer_amount\":100,\"transfer_account_uid\":42,\"transfer_account_name\":\"acct\",\"transfer_account_agency_id\":7,\"request_id\":\"req-1\",\"settle_begin\":100,\"settle_end\":200,\"authorize_advertise\":1,\"fund_type\":1}",
        null,
    );
    try std.testing.expectEqualStrings("bill-1", parsed.value.bill_id);
}

test "bindTransferAccount 单签名：URL 为参考实现的 bind_transfer_accout（官方笔误）" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.bindTransferAccount(.{
        .env = .sandbox,
        .transfer_account_uid = 42,
        .transfer_account_org_name = "org",
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/bind_transfer_accout",
        "{\"env\":1,\"transfer_account_uid\":42,\"transfer_account_org_name\":\"org\"}",
        null,
    );
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
}

test "queryFundsBill 单签名：filter 非可选始终写出，响应解析 bill_list" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"bill_list\":[{\"bill_id\":\"b-1\",\"oper_time\":1,\"settle_begin\":100,\"settle_end\":200,\"fund_id\":\"f-1\",\"transfer_account_name\":\"acct\",\"transfer_account_uid\":42,\"transfer_amount\":1000,\"status\":1,\"request_id\":\"req-1\"}],\"total_page\":2}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryFundsBill(.{
        .env = .sandbox,
        .page = 1,
        .page_size = 20,
        .filter = .{ .oper_time_begin = 100, .bill_id = "b-1" },
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_funds_bill",
        "{\"env\":1,\"page\":1,\"page_size\":20,\"filter\":{\"oper_time_begin\":100,\"oper_time_end\":0,\"bill_id\":\"b-1\",\"request_id\":\"\"}}",
        null,
    );
    try std.testing.expectEqual(@as(i64, 2), parsed.value.total_page);
    try std.testing.expectEqualStrings("b-1", parsed.value.bill_list[0].bill_id);
}

test "queryRecoverBill 单签名：响应解析 recover_amount 与 refund_order_list" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"bill_list\":[{\"bill_id\":\"b-1\",\"recover_time\":1,\"settle_begin\":100,\"settle_end\":200,\"fund_id\":\"f-1\",\"recover_account_name\":\"acct\",\"recover_amount\":500,\"refund_order_list\":[\"r-1\",\"r-2\"]}],\"total_page\":2}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.queryRecoverBill(.{
        .env = .sandbox,
        .page = 1,
        .page_size = 20,
        .filter = .{ .recover_time_begin = 100, .bill_id = "b-1" },
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/query_recover_bill",
        "{\"env\":1,\"page\":1,\"page_size\":20,\"filter\":{\"recover_time_begin\":100,\"recover_time_end\":0,\"bill_id\":\"b-1\"}}",
        null,
    );
    try std.testing.expectEqual(@as(i64, 500), parsed.value.bill_list[0].recover_amount);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.bill_list[0].refund_order_list.len);
    try std.testing.expectEqualStrings("r-2", parsed.value.bill_list[0].refund_order_list[1]);
}

test "downloadAdverFundsOrder 单签名：响应解析 url" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://adver.example/a.csv\"}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.downloadAdverFundsOrder(.{ .env = .sandbox, .fund_id = "f-1" });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/download_adverfunds_order",
        "{\"env\":1,\"fund_id\":\"f-1\"}",
        null,
    );
    try std.testing.expectEqualStrings("https://adver.example/a.csv", parsed.value.url);
}

test "getComplaintList 单签名：官方必填 offset/limit 与 complaints 全字段解析" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        // 官方返回体：列表在 `complaints`，元素字段为 complaint_time(string) /
        // complaint_state(string) 等（见 api_get_complaint_list）。
        "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1,\"complaints\":[{" ++
            "\"complaint_id\":\"c-1\"," ++
            "\"complaint_time\":\"2023-11-28T11:11:49+08:00\"," ++
            "\"complaint_detail\":\"音质太差\"," ++
            "\"complaint_state\":\"PENDING\"," ++
            "\"payer_phone\":\"13800000000\"," ++
            "\"payer_openid\":\"ou-1\"," ++
            "\"complaint_order_info\":[{\"transaction_id\":\"4200\",\"out_trade_no\":\"ch-1\",\"amount\":100,\"wxa_out_trade_no\":\"wxa-1\",\"wx_order_id\":\"wx-1\"}]," ++
            "\"complaint_full_refunded\":false," ++
            "\"incoming_user_response\":true," ++
            "\"user_complaint_times\":2," ++
            "\"complaint_media_list\":[{\"media_type\":\"USER_COMPLAINT_IMAGE\",\"media_url\":[\"https://img/1.png\",\"https://img/2.png\"]}]," ++
            "\"problem_description\":\"申请退款\"," ++
            "\"problem_type\":\"REFUND\"," ++
            "\"apply_refund_amount\":100," ++
            "\"user_tag_list\":[\"TRUSTED\"]," ++
            "\"service_order_info\":[{\"order_id\":\"so-1\",\"out_order_no\":\"so-out-1\",\"state\":\"DONE\"}]}]}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.getComplaintList(.{
        .env = .sandbox,
        .offset = 0,
        .limit = 10,
        .begin_date = "2024-01-01",
        .end_date = "2024-01-31",
    });
    defer parsed.deinit();

    // 官方必填的 `offset=0` 也必须落进请求体（零值省略不得吃掉首屏偏移），
    // 否则服务端直接返回 268490002（请求参数字段错误）。
    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/get_complaint_list",
        "{\"env\":1,\"offset\":0,\"limit\":10,\"begin_date\":\"2024-01-01\",\"end_date\":\"2024-01-31\"}",
        null,
    );
    // 整体比较：一次锁住 `complaints` 元素的全部官方字段。
    try std.testing.expectEqualDeep(GetComplaintListResponse{
        .errmsg = "ok",
        .total = 1,
        .complaints = &.{.{
            .complaint_id = "c-1",
            .complaint_time = "2023-11-28T11:11:49+08:00",
            .complaint_detail = "音质太差",
            .complaint_state = "PENDING",
            .payer_phone = "13800000000",
            .payer_openid = "ou-1",
            .complaint_order_info = &.{.{
                .transaction_id = "4200",
                .out_trade_no = "ch-1",
                .amount = 100,
                .wxa_out_trade_no = "wxa-1",
                .wx_order_id = "wx-1",
            }},
            .incoming_user_response = true,
            .user_complaint_times = 2,
            .complaint_media_list = &.{.{
                .media_type = "USER_COMPLAINT_IMAGE",
                .media_url = &.{ "https://img/1.png", "https://img/2.png" },
            }},
            .problem_description = "申请退款",
            .problem_type = "REFUND",
            .apply_refund_amount = 100,
            .user_tag_list = &.{"TRUSTED"},
            .service_order_info = &.{.{
                .order_id = "so-1",
                .out_order_no = "so-out-1",
                .state = "DONE",
            }},
        }},
    }, parsed.value);
}

test "getComplaintList 旧字段名 complaint_list / page / page_size 已不再存在" {
    // 这三个名字是上一轮普查发现的契约缺陷：`page`/`page_size` 官方不认，
    // `complaint_list` 不是官方 key（ignore_unknown_fields 下会静默空列表）。
    try std.testing.expect(!@hasField(GetComplaintListRequest, "page"));
    try std.testing.expect(!@hasField(GetComplaintListRequest, "page_size"));
    try std.testing.expect(@hasField(GetComplaintListRequest, "offset"));
    try std.testing.expect(@hasField(GetComplaintListRequest, "limit"));
    try std.testing.expect(!@hasField(GetComplaintListResponse, "complaint_list"));
    try std.testing.expect(@hasField(GetComplaintListResponse, "complaints"));
}

test "getComplaintDetail 单签名：详情在 complaint 对象里（不再读顶层 state）" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"complaint\":{\"complaint_id\":\"c-1\",\"complaint_detail\":\"已处理\",\"complaint_state\":\"PROCESSED\",\"problem_type\":\"OTHERS\",\"user_complaint_times\":1}}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.getComplaintDetail(.{ .env = .sandbox, .complaint_id = "c-1" });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/get_complaint_detail",
        "{\"env\":1,\"complaint_id\":\"c-1\"}",
        null,
    );
    try std.testing.expectEqualDeep(GetComplaintDetailResponse{
        .errmsg = "ok",
        .complaint = .{
            .complaint_id = "c-1",
            .complaint_detail = "已处理",
            .complaint_state = "PROCESSED",
            .problem_type = "OTHERS",
            .user_complaint_times = 1,
        },
    }, parsed.value);
}

test "getComplaintDetail 顶层 complaint_id/state 不再被当作详情" {
    // 官方把详情放在 `complaint` 对象里；只有顶层同名字段时必须解析为 null，
    // 否则调用方会拿到一个除 id/state 外全空、看起来"成功"的假详情。
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"complaint_id\":\"c-1\",\"state\":2}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.getComplaintDetail(.{ .complaint_id = "c-1" });
    defer parsed.deinit();

    try std.testing.expect(!@hasField(GetComplaintDetailResponse, "complaint_id"));
    try std.testing.expect(!@hasField(GetComplaintDetailResponse, "state"));
    try std.testing.expectEqual(@as(?ComplaintItem, null), parsed.value.complaint);
}

test "getNegotiationHistory 单签名：官方必填 offset/limit 与 history 全字段解析" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"total\":1,\"history\":[{\"log_id\":\"l-1\",\"operator\":\"商户\",\"operate_time\":\"2023-11-28T11:11:49+08:00\",\"operate_type\":\"MERCHANT_RESPONSE\",\"operate_details\":\"已回复\",\"complaint_media_list\":[{\"media_type\":\"OPERATION_IMAGE\",\"media_url\":[\"https://img/3.png\"]}]}]}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.getNegotiationHistory(.{
        .env = .sandbox,
        .complaint_id = "c-1",
        .offset = 0,
        .limit = 20,
    });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/get_negotiation_history",
        "{\"env\":1,\"complaint_id\":\"c-1\",\"offset\":0,\"limit\":20}",
        null,
    );
    try std.testing.expectEqualDeep(GetNegotiationHistoryResponse{
        .errmsg = "ok",
        .total = 1,
        .history = &.{.{
            .log_id = "l-1",
            .operator = "商户",
            .operate_time = "2023-11-28T11:11:49+08:00",
            .operate_type = "MERCHANT_RESPONSE",
            .operate_details = "已回复",
            .complaint_media_list = &.{.{
                .media_type = "OPERATION_IMAGE",
                .media_url = &.{"https://img/3.png"},
            }},
        }},
    }, parsed.value);
}

test "responseComplaint 单签名：response_images 官方必填（为空写 []，非空写列表）" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer arena.deinit();
    defer releaseTestClient();

    // 带图片（file_id 来自 upload_vp_file）。
    var with_images = try v.responseComplaint(.{
        .env = .sandbox,
        .complaint_id = "c-1",
        .response_content = "resolved by merchant",
        .response_images = &.{ "fid-1", "fid-2" },
    });
    defer with_images.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/response_complaint",
        "{\"env\":1,\"complaint_id\":\"c-1\",\"response_content\":\"resolved by merchant\",\"response_images\":[\"fid-1\",\"fid-2\"]}",
        null,
    );
    try std.testing.expectEqualStrings("ok", with_images.value.errmsg);

    // 只有文字：官方把 response_images 标为必填，故空数组也要写 `[]`（不能省略）。
    var text_only = try v.responseComplaint(.{
        .env = .sandbox,
        .complaint_id = "c-1",
        .response_content = "hi",
    });
    defer text_only.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        1,
        "/xpay/response_complaint",
        "{\"env\":1,\"complaint_id\":\"c-1\",\"response_content\":\"hi\",\"response_images\":[]}",
        null,
    );
}

test "completeComplaint 单签名：请求体与 URL" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.completeComplaint(.{ .env = .sandbox, .complaint_id = "c-1" });
    defer parsed.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/complete_complaint",
        "{\"env\":1,\"complaint_id\":\"c-1\"}",
        null,
    );
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
}

test "uploadVPFile 单签名：base64_img / img_url / file_name 进请求体与响应解析 file_id" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(&arena, &cap, &ctx, &v, "{\"errcode\":0,\"errmsg\":\"ok\",\"file_id\":\"fid-1\"}");
    defer arena.deinit();
    defer releaseTestClient();

    // 官方把 base64_img / img_url 都标为必填，但说明里二者按大小二选一
    // （优先 img_url）；未提供的那个按既有 omitempty 风格省略。
    var with_base64 = try v.uploadVPFile(.{
        .env = .sandbox,
        .base64_img = "aGVsbG8=",
        .file_name = "a.png",
    });
    defer with_base64.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/upload_vp_file",
        "{\"env\":1,\"base64_img\":\"aGVsbG8=\",\"file_name\":\"a.png\"}",
        null,
    );
    try std.testing.expectEqualStrings("fid-1", with_base64.value.file_id);

    var with_url = try v.uploadVPFile(.{
        .env = .sandbox,
        .img_url = "https://img.example/1.png",
        .file_name = "b.png",
    });
    defer with_url.deinit();

    try expectSignedCall(
        arena.allocator(),
        &cap,
        1,
        "/xpay/upload_vp_file",
        "{\"env\":1,\"img_url\":\"https://img.example/1.png\",\"file_name\":\"b.png\"}",
        null,
    );
}

test "getUploadFileSign 单签名：wxpay_url/convert_cos/complaint_id 与响应解析 sign+cos_url" {
    var arena: std.heap.ArenaAllocator = undefined;
    var cap: TestCapture = undefined;
    var ctx: Context = undefined;
    var v: VirtualPayment = undefined;
    vpSetup(
        &arena,
        &cap,
        &ctx,
        &v,
        "{\"errcode\":0,\"errmsg\":\"ok\",\"sign\":\"SIGN-X\",\"cos_url\":\"https://cos.example/s.png?k=1\"}",
    );
    defer arena.deinit();
    defer releaseTestClient();

    var parsed = try v.getUploadFileSign(.{
        .env = .sandbox,
        .wxpay_url = "https://api.mch.weixin.qq.com/v3/merchant-service/images/1234",
        .convert_cos = true,
        .complaint_id = "c-1",
    });
    defer parsed.deinit();

    // `convert_cos` 是官方必填的布尔值，取 false 也照样写出（不做零值省略）。
    try expectSignedCall(
        arena.allocator(),
        &cap,
        0,
        "/xpay/get_upload_file_sign",
        "{\"env\":1,\"wxpay_url\":\"https://api.mch.weixin.qq.com/v3/merchant-service/images/1234\",\"convert_cos\":true,\"complaint_id\":\"c-1\"}",
        null,
    );
    try std.testing.expectEqualStrings("SIGN-X", parsed.value.sign);
    try std.testing.expectEqualStrings("https://cos.example/s.png?k=1", parsed.value.cos_url);

    // 旧的 `file_id` 字段官方不存在，已删除。
    try std.testing.expect(!@hasField(GetUploadFileSignRequest, "file_id"));
    try std.testing.expect(@hasField(GetUploadFileSignRequest, "wxpay_url"));
    try std.testing.expect(@hasField(GetUploadFileSignRequest, "convert_cos"));
    try std.testing.expect(@hasField(GetUploadFileSignRequest, "complaint_id"));
    try std.testing.expect(@hasField(GetUploadFileSignResponse, "cos_url"));
}

test "jsonStringify 必填分页字段 offset/limit 取 0 也写出" {
    const allocator = std.testing.allocator;
    // 全零请求：只有官方标注「必填」的 offset/limit 会出现在请求体里。
    const body = try jsonStringify(allocator, GetComplaintListRequest{});
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"offset\":0,\"limit\":0}", body);

    // 同一份序列化结果既发给服务端也参与 pay_sig 计算，因此这是签名不变量的一部分。
    const with_dates = try jsonStringify(allocator, GetNegotiationHistoryRequest{
        .env = .sandbox,
        .complaint_id = "c-1",
    });
    defer allocator.free(with_dates);
    try std.testing.expectEqualStrings("{\"env\":1,\"complaint_id\":\"c-1\",\"offset\":0,\"limit\":0}", with_dates);
}
