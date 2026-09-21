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
    status: i64 = 0,
    withdraw_amount: []const u8 = "",
    wx_withdraw_no: []const u8 = "",
    withdraw_success_timestamp: i64 = 0,
    create_time: []const u8 = "",
};

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
    page: i64 = 0,
    page_size: i64 = 0,
    begin_date: []const u8 = "",
    end_date: []const u8 = "",
};

pub const GetComplaintListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total: i64 = 0,
    complaint_list: []const ComplaintInfo = &.{},
};

pub const ComplaintInfo = struct {
    complaint_id: []const u8 = "",
    create_time: i64 = 0,
    state: i64 = 0,
};

pub const GetComplaintDetailRequest = struct {
    env: Env = .production,
    complaint_id: []const u8 = "",
};

pub const GetComplaintDetailResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    complaint_id: []const u8 = "",
    state: i64 = 0,
};

pub const GetNegotiationHistoryRequest = struct {
    env: Env = .production,
    complaint_id: []const u8 = "",
};

pub const GetNegotiationHistoryResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const ResponseComplaintRequest = struct {
    env: Env = .production,
    complaint_id: []const u8 = "",
    response_content: []const u8 = "",
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
};

pub const UploadVPFileResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    file_id: []const u8 = "",
};

pub const GetUploadFileSignRequest = struct {
    env: Env = .production,
    file_id: []const u8 = "",
};

pub const GetUploadFileSignResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    sign: []const u8 = "",
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
            return std.fmt.allocPrint(
                allocator,
                "https://api.weixin.qq.com{s}?access_token={s}&pay_sig={s}&signature={s}",
                .{ path, access_token, pay_sig, sig },
            );
        }
        return std.fmt.allocPrint(
            allocator,
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
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, 64);
    for (&out, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 15];
    }
    return result;
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
        // 跳过空字符串 / 零值可选字段（与 Go omitempty 语义对齐的简化）。
        const should_write = if (comptime isSkippable(ftype)) !isEmpty(ftype, fv) else true;
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

fn isSkippable(comptime T: type) bool {
    return T == []const u8 or T == i64 or T == Env;
}

fn isEmpty(comptime T: type, v: anytype) bool {
    if (T == []const u8) return v.len == 0;
    if (T == i64) return v == 0;
    if (T == Env) return v == .production;
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
        _ = method;
        _ = content_type;
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
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
    try std.testing.expect(std.mem.indexOf(u8, sandbox_body, "\"env\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sandbox_body, "\"sandbox\"") == null);

    const prod_body = try jsonStringify(allocator, QueryBizBalanceRequest{ .env = .production });
    defer allocator.free(prod_body);
    try std.testing.expect(std.mem.indexOf(u8, prod_body, "\"env\"") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "\"env\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "\"env\":\"sandbox\"") == null);

    // pay_sig = HMAC-SHA256(app_key, path + "&" + body)，签名体与发送体是同一份序列化结果。
    var data = std.ArrayList(u8).empty;
    defer data.deinit(alloc);
    try data.appendSlice(alloc, "/xpay/query_order");
    try data.appendSlice(alloc, "&");
    try data.appendSlice(alloc, cap.payload);
    const expected = try hmacSha256Hex(alloc, "appkey-123", data.items);
    try std.testing.expect(std.mem.indexOf(u8, cap.uri, expected) != null);
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

    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "\"env\":1") != null);

    // signature = HMAC-SHA256(session_key, body)。
    const expected_sig = try hmacSha256Hex(alloc, "sk-1", cap.payload);
    try std.testing.expect(std.mem.indexOf(u8, cap.uri, expected_sig) != null);

    // pay_sig = HMAC-SHA256(app_key, path + "&" + body)。
    var data = std.ArrayList(u8).empty;
    defer data.deinit(alloc);
    try data.appendSlice(alloc, "/xpay/query_user_balance");
    try data.appendSlice(alloc, "&");
    try data.appendSlice(alloc, cap.payload);
    const expected_pay = try hmacSha256Hex(alloc, "appkey-123", data.items);
    try std.testing.expect(std.mem.indexOf(u8, cap.uri, expected_pay) != null);
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
    try std.testing.expect(std.mem.indexOf(u8, cap.uriAt(0), expected_pay_sig) != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.uriAt(1), expected_pay_sig) != null);
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
    const expected_user_uri = try std.fmt.allocPrint(
        alloc,
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
    const expected_pay_uri = try std.fmt.allocPrint(
        alloc,
        "https://api.weixin.qq.com/xpay/query_order?access_token=stub-ak&pay_sig={s}",
        .{pay_pay_sig},
    );
    try std.testing.expectEqualStrings(expected_pay_uri, cap.uriAt(1));
}

/// 从 `...?access_token=X&pay_sig=...` 中取出 access_token 的值。
fn tokenOf(uri: []const u8) []const u8 {
    const key = "access_token=";
    const start = (std.mem.indexOf(u8, uri, key) orelse return "") + key.len;
    const rest = uri[start..];
    const end = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
    return rest[0..end];
}
