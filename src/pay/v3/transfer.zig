// SPDX-License-Identifier: Apache-2.0
//! pay/v3/transfer — 微信支付 v3 商家转账（发起转账 / 查询转账单 / 撤销转账 / 结果通知）
//!
//! **新旧版选择：只做新版「商家转账」**（`/v3/fund-app/mch-transfer/transfer-bills`），
//! 不做旧版「商家转账到零钱」（`/v3/transfer/batches`）。理由：官方《商家转账到零钱升级说明》
//! 已把 `/v3/transfer/batches` 列入「需升级」接口清单（2025-01-15 起升级至新版商家转账），
//! 新接入商户只能使用新版接口；两套并存会让调用方无从选择，且旧版为批量模式、语义完全不同。
//! 参见 <https://pay.weixin.qq.com/doc/v3/merchant/4015273741>。
//!
//! 对照官方文档（Go 参考 `_ref/wechat` 无 v3 实现，契约以官方文档为准）：
//! - 发起转账：`POST /v3/fund-app/mch-transfer/transfer-bills`
//!   <https://pay.weixin.qq.com/doc/v3/merchant/4012716434>
//! - 查询转账单：`GET /v3/fund-app/mch-transfer/transfer-bills/out-bill-no/{out_bill_no}`
//!   <https://pay.weixin.qq.com/doc/v3/merchant/4024814206>
//! - 撤销转账：`POST /v3/fund-app/mch-transfer/transfer-bills/out-bill-no/{out_bill_no}/cancel`
//!   <https://pay.weixin.qq.com/doc/v3/merchant/4012716458>
//! - 结果通知：`event_type = MCHTRANSFER.BILL.FINISHED`，`resource_type = encrypt-resource`，
//!   `resource` 为 AEAD_AES_256_GCM 密文；解密复用 `notify.decryptNotifyResource`
//!   （不另造解密轮子），明文结构见 `TransferNotifyResource`。
//!   <https://pay.weixin.qq.com/doc/v3/merchant/4012712115>

const std = @import("std");
const Config = @import("config.zig").Config;
const signer = @import("signer.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// v3 商家转账接口主域名。
const transfer_host = "https://api.mch.weixin.qq.com";
/// 发起转账 / 撤销转账 / 查询转账单的公共路径前缀。
const transfer_path = "/v3/fund-app/mch-transfer/transfer-bills";

/// 转账场景报备信息（body.transfer_scene_report_infos 数组元素）。
///
/// `info_type` / `info_content` 为固定字段名（官方契约），取值需严格对照
/// 《转账场景报备信息字段说明》。
pub const TransferSceneReportInfo = struct {
    /// 信息类型（必填，不超过 15 字符）
    info_type: []const u8,
    /// 信息内容（必填，不超过 32 字符）
    info_content: []const u8,
};

/// 用户收款样式（body.user_recv_style）。
pub const UserRecvStyle = struct {
    /// 样式类型：`CONFIRM_PAGE`（收款确认页）/ `RED_PACKET`（红包，单笔 ≤ 200 元）
    type: []const u8,
};

/// 发起转账请求参数。
///
/// 必填项缺失（或金额非正）返回 `WechatError.InvalidArgument`。
pub const TransferParams = struct {
    /// 商户 AppID（选填，为空时回退 `Config.app_id`）
    appid: []const u8 = "",
    /// 商户单号（必填，仅数字 / 大小写字母，商户系统内唯一，≤ 32 字符）
    out_bill_no: []const u8,
    /// 转账场景 ID（必填，如 1000 现金营销 / 1006 企业报销）
    transfer_scene_id: []const u8,
    /// 收款用户 OpenID（必填，为该 appid 下的用户标识）
    openid: []const u8,
    /// 收款用户姓名（选填，**须为密文**：使用微信支付公钥 / 平台证书公钥 RSA-OAEP 加密后
    /// 的 base64 串；转账金额 ≥ 2000 元时必须传入）。传入密文时请求头需附带
    /// `Wechatpay-Serial`，由 `Config.wechatpay_serial` 提供。
    user_name: []const u8 = "",
    /// 转账金额（必填，单位「分」，必须为正整数）
    transfer_amount: i64,
    /// 转账备注（必填，用户收款时可见，UTF-8，≤ 32 字符）
    transfer_remark: []const u8,
    /// 异步接收转账结果的回调地址（选填，必须为 HTTPS 且不带参数；为空时回退 `Config.notify_url`）
    notify_url: []const u8 = "",
    /// 用户收款感知（选填，不填展示转账场景默认文案）
    user_recv_perception: []const u8 = "",
    /// 转账场景报备信息（必填，按转账场景准确填写）
    transfer_scene_report_infos: []const TransferSceneReportInfo = &.{},
    /// 用户收款样式（选填，不填按收款确认页展示）
    user_recv_style: ?UserRecvStyle = null,
};

/// 发起转账应答。
pub const TransferResult = struct {
    /// 商户单号
    out_bill_no: []const u8 = "",
    /// 微信转账单号（官方契约名，非 `bill_id`）
    transfer_bill_no: []const u8 = "",
    /// 单据创建时间（RFC3339，如 2015-05-20T13:29:35.120+08:00）
    create_time: []const u8 = "",
    /// 单据状态：`ACCEPTED` / `PROCESSING` / `WAIT_USER_CONFIRM` / `TRANSFERING` /
    /// `SUCCESS` / `FAIL` / `CANCELING` / `CANCELLED`
    state: []const u8 = "",
    /// 跳转微信收款页的 package 信息，仅 `WAIT_USER_CONFIRM` 时返回
    package_info: []const u8 = "",
};

/// 查询转账单应答。
pub const TransferBillResult = struct {
    mch_id: []const u8 = "",
    out_bill_no: []const u8 = "",
    transfer_bill_no: []const u8 = "",
    appid: []const u8 = "",
    /// 单据状态，取值同 `TransferResult.state`
    state: []const u8 = "",
    /// 转账金额（单位「分」）
    transfer_amount: i64 = 0,
    transfer_remark: []const u8 = "",
    /// 失败原因（单据失败 / 已退资金时返回）
    fail_reason: []const u8 = "",
    openid: []const u8 = "",
    /// 收款用户姓名（密文态，发起时传入则返回）
    user_name: []const u8 = "",
    create_time: []const u8 = "",
    update_time: []const u8 = "",
};

/// 撤销转账应答。
pub const TransferCancelResult = struct {
    out_bill_no: []const u8 = "",
    transfer_bill_no: []const u8 = "",
    /// 单据状态：`CANCELING`（撤销中）/ `CANCELLED`（已撤销）
    state: []const u8 = "",
    update_time: []const u8 = "",
};

/// 转账结果通知 `resource.ciphertext` 解密后的明文结构
/// （`event_type = MCHTRANSFER.BILL.FINISHED`）。
///
/// 用法与退款通知一致：先用 `notify.decryptNotifyResource` 解密，再解析到本结构。
pub const TransferNotifyResource = struct {
    out_bill_no: []const u8 = "",
    transfer_bill_no: []const u8 = "",
    /// 终态：`SUCCESS` / `FAIL` / `CANCELLED`
    state: []const u8 = "",
    mch_id: []const u8 = "",
    /// 转账金额（单位「分」）
    transfer_amount: i64 = 0,
    openid: []const u8 = "",
    fail_reason: []const u8 = "",
    create_time: []const u8 = "",
    update_time: []const u8 = "",
    /// 收款方式类型：微信零钱 `CFT`，香港钱包零钱 `WPHK`
    payment_method_type: []const u8 = "",
};

pub const TransferV3 = struct {
    cfg: Config,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP，
    /// 此时跳过本地 RSA 签名，直接以 mock 响应返回）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(cfg: Config) Self {
        return .{ .cfg = cfg };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTPS + 商户私钥签名）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 发起转账：`POST /v3/fund-app/mch-transfer/transfer-bills`。
    ///
    /// 返回的 `std.json.Parsed(TransferResult)` 由调用方持有并负责 `deinit`；
    /// 注意 HTTP 200 只代表本次请求受理，须以 `state` 判断单据状态
    /// （`WAIT_USER_CONFIRM` 可引导用户确认收款）。v3 错误应答
    /// （`{"code":...,"message":...}`）返回 `WechatError.ApiError`。
    pub fn transfer(
        self: *Self,
        allocator: std.mem.Allocator,
        p: TransferParams,
    ) !std.json.Parsed(TransferResult) {
        const appid = if (p.appid.len > 0) p.appid else self.cfg.app_id;
        if (appid.len == 0) return util_error.WechatError.InvalidArgument;
        if (p.out_bill_no.len == 0) return util_error.WechatError.InvalidArgument;
        if (p.transfer_scene_id.len == 0) return util_error.WechatError.InvalidArgument;
        if (p.openid.len == 0) return util_error.WechatError.InvalidArgument;
        if (p.transfer_remark.len == 0) return util_error.WechatError.InvalidArgument;
        if (p.transfer_amount <= 0) return util_error.WechatError.InvalidArgument;
        if (p.transfer_scene_report_infos.len == 0) return util_error.WechatError.InvalidArgument;

        const notify_url = if (p.notify_url.len > 0) p.notify_url else self.cfg.notify_url;

        const body = try serializeTransferBody(allocator, p, appid, notify_url);
        defer allocator.free(body);

        const full_url = transfer_host ++ transfer_path;
        const resp = try self.doRequest(allocator, .POST, transfer_path, full_url, body);
        defer allocator.free(resp);

        try checkV3Error(allocator, resp);

        return std.json.parseFromSlice(TransferResult, allocator, resp, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return util_error.WechatError.DecodeError;
    }

    /// 查询转账单：`GET /v3/fund-app/mch-transfer/transfer-bills/out-bill-no/{out_bill_no}`。
    ///
    /// 官方仅支持查询最近 30 天内的转账单。返回的 `std.json.Parsed(TransferBillResult)`
    /// 由调用方持有并负责 `deinit`。
    pub fn queryTransfer(
        self: *Self,
        allocator: std.mem.Allocator,
        out_bill_no: []const u8,
    ) !std.json.Parsed(TransferBillResult) {
        if (out_bill_no.len == 0) return util_error.WechatError.InvalidArgument;

        const canonical_url = try std.fmt.allocPrint(
            allocator,
            transfer_path ++ "/out-bill-no/{s}",
            .{out_bill_no},
        );
        defer allocator.free(canonical_url);

        const full_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ transfer_host, canonical_url });
        defer allocator.free(full_url);

        const resp = try self.doRequest(allocator, .GET, canonical_url, full_url, "");
        defer allocator.free(resp);

        try checkV3Error(allocator, resp);

        return std.json.parseFromSlice(TransferBillResult, allocator, resp, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return util_error.WechatError.DecodeError;
    }

    /// 撤销转账：`POST /v3/fund-app/mch-transfer/transfer-bills/out-bill-no/{out_bill_no}/cancel`。
    ///
    /// 在用户确认收款之前可撤销；返回成功仅代表撤销请求已受理，最终状态以
    /// `TransferCancelResult.state` / 查询接口为准。
    pub fn cancelTransfer(
        self: *Self,
        allocator: std.mem.Allocator,
        out_bill_no: []const u8,
    ) !std.json.Parsed(TransferCancelResult) {
        if (out_bill_no.len == 0) return util_error.WechatError.InvalidArgument;

        const canonical_url = try std.fmt.allocPrint(
            allocator,
            transfer_path ++ "/out-bill-no/{s}/cancel",
            .{out_bill_no},
        );
        defer allocator.free(canonical_url);

        const full_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ transfer_host, canonical_url });
        defer allocator.free(full_url);

        const resp = try self.doRequest(allocator, .POST, canonical_url, full_url, "");
        defer allocator.free(resp);

        try checkV3Error(allocator, resp);

        return std.json.parseFromSlice(TransferCancelResult, allocator, resp, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return util_error.WechatError.DecodeError;
    }

    /// 发送 v3 请求：先按 signer 惯例生成 `Authorization` 头（真实 HTTPS 路径），
    /// transport 已注入时直接走 mock（跳过签名，测试无需真实私钥）。
    fn doRequest(
        self: *Self,
        allocator: std.mem.Allocator,
        method: std.http.Method,
        canonical_url: []const u8,
        full_url: []const u8,
        body: []const u8,
    ) ![]u8 {
        var sign: ?signer.SignResult = null;
        defer if (sign) |*s| s.deinit(allocator);

        if (self.transport == null) {
            const method_str = switch (method) {
                .POST => "POST",
                .GET => "GET",
                else => return util_error.WechatError.InvalidArgument,
            };
            sign = try signer.buildAuthorizationHeader(allocator, self.cfg, method_str, canonical_url, body);
        }

        if (self.transport) |t| {
            const tctx = self.transport_ctx orelse return util_error.WechatError.ConfigMissing;
            return t(tctx, allocator, full_url, method, body, "application/json");
        }

        var client: std.http.Client = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
        };
        defer client.deinit();

        var body_writer: std.Io.Writer.Allocating = .init(allocator);
        defer body_writer.deinit();

        var header_buf: [2]std.http.Header = undefined;
        const extra_headers = buildExtraHeaders(self.cfg, &header_buf);

        const result = client.fetch(.{
            .method = method,
            .location = .{ .url = full_url },
            .payload = if (body.len == 0 and method == .GET) null else body,
            .response_writer = &body_writer.writer,
            .extra_headers = extra_headers,
            .headers = .{
                .authorization = .{ .override = sign.?.authorization },
                .content_type = .{ .override = "application/json" },
            },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return util_error.WechatError.NetworkError,
        };

        if (result.status != .ok) {
            try checkV3Error(allocator, body_writer.written());
            return util_error.WechatError.NetworkError;
        }

        var list = body_writer.toArrayList();
        defer list.deinit(allocator);
        return list.toOwnedSlice(allocator);
    }
};

/// 组装附加请求头：`Accept` 恒有；配置了 `wechatpay_serial` 时附带 `Wechatpay-Serial`
/// （v3 商家转账在 body 中传入加密的 `user_name` 时，官方要求标注加密所用公钥 ID /
/// 平台证书序列号）。
///
/// `buf` 至少两元素，返回切片借用 `buf`。
fn buildExtraHeaders(cfg: Config, buf: *[2]std.http.Header) []const std.http.Header {
    var n: usize = 0;
    buf[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (cfg.wechatpay_serial.len > 0) {
        buf[n] = .{ .name = "Wechatpay-Serial", .value = cfg.wechatpay_serial };
        n += 1;
    }
    return buf[0..n];
}

/// v3 错误应答结构：成功应答不含 `code` 字段，存在非空 code 即视为业务错误。
const V3ErrorBody = struct {
    code: []const u8 = "",
    message: []const u8 = "",
};

/// 若应答体可解析出非空 `code`，返回 `WechatError.ApiError`；否则正常返回。
fn checkV3Error(allocator: std.mem.Allocator, body: []const u8) !void {
    const parsed = std.json.parseFromSlice(V3ErrorBody, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    if (parsed.value.code.len > 0) return util_error.WechatError.ApiError;
}

/// 序列化发起转账 body（`appid` / `notify_url` 已按「参数优先、配置兜底」解析）。
///
/// 空的可选字段一律省略（官方契约：`user_name` 仅在传入密文时出现，
/// `user_recv_style` / `user_recv_perception` 同理）；字符串经 `std.json.Stringify`
/// 转义，不做裸插值。
fn serializeTransferBody(
    allocator: std.mem.Allocator,
    p: TransferParams,
    appid: []const u8,
    notify_url: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("appid");
    try s.write(appid);
    try s.objectField("out_bill_no");
    try s.write(p.out_bill_no);
    try s.objectField("transfer_scene_id");
    try s.write(p.transfer_scene_id);
    try s.objectField("openid");
    try s.write(p.openid);
    if (p.user_name.len > 0) {
        try s.objectField("user_name");
        try s.write(p.user_name);
    }
    try s.objectField("transfer_amount");
    try s.write(p.transfer_amount);
    try s.objectField("transfer_remark");
    try s.write(p.transfer_remark);
    if (notify_url.len > 0) {
        try s.objectField("notify_url");
        try s.write(notify_url);
    }
    if (p.user_recv_perception.len > 0) {
        try s.objectField("user_recv_perception");
        try s.write(p.user_recv_perception);
    }
    try s.objectField("transfer_scene_report_infos");
    try s.write(p.transfer_scene_report_infos);
    if (p.user_recv_style) |style| {
        try s.objectField("user_recv_style");
        try s.beginObject();
        try s.objectField("type");
        try s.write(style.type);
        try s.endObject();
    }
    try s.endObject();

    return out.toOwnedSlice();
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

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

const test_cfg = Config{
    .app_id = "wxf636efh567hg4356",
    .mch_id = "1900000109",
    .notify_url = "https://merchant.example.com/wxpay/transfer/notify",
};

fn newCaptureTransfer(stub: *CaptureResp) TransferV3 {
    var t = TransferV3.init(test_cfg);
    t.setTransport(CaptureResp.dispatch, stub);
    return t;
}

/// 一份字段齐全的合法请求，测试中按需改写单个字段。
fn baseParams() TransferParams {
    return .{
        .out_bill_no = "plfk2020042013",
        .transfer_scene_id = "1000",
        .openid = "o-MYE42l80oelYMDE34nYD456Xoy",
        .transfer_amount = 400000,
        .transfer_remark = "新会员开通有礼",
        .transfer_scene_report_infos = &.{
            .{ .info_type = "活动名称", .info_content = "新会员有礼" },
            .{ .info_type = "奖励说明", .info_content = "注册会员抽奖一等奖" },
        },
    };
}

test "TransferV3.transfer 缺必填参数返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{}" };
    var t = newCaptureTransfer(&stub);

    // out_bill_no 缺失
    var p1 = baseParams();
    p1.out_bill_no = "";
    try std.testing.expectError(util_error.WechatError.InvalidArgument, t.transfer(allocator, p1));

    // transfer_scene_id 缺失
    var p2 = baseParams();
    p2.transfer_scene_id = "";
    try std.testing.expectError(util_error.WechatError.InvalidArgument, t.transfer(allocator, p2));

    // openid 缺失
    var p3 = baseParams();
    p3.openid = "";
    try std.testing.expectError(util_error.WechatError.InvalidArgument, t.transfer(allocator, p3));

    // transfer_remark 缺失
    var p4 = baseParams();
    p4.transfer_remark = "";
    try std.testing.expectError(util_error.WechatError.InvalidArgument, t.transfer(allocator, p4));

    // 转账金额非正
    var p5 = baseParams();
    p5.transfer_amount = 0;
    try std.testing.expectError(util_error.WechatError.InvalidArgument, t.transfer(allocator, p5));

    // 转账场景报备信息为空（官方标注必填）
    var p6 = baseParams();
    p6.transfer_scene_report_infos = &.{};
    try std.testing.expectError(util_error.WechatError.InvalidArgument, t.transfer(allocator, p6));

    // appid 参数与 Config 皆为空
    var t_no_appid = TransferV3.init(.{ .mch_id = "1900000109" });
    t_no_appid.setTransport(CaptureResp.dispatch, &stub);
    const p7 = baseParams();
    try std.testing.expectError(util_error.WechatError.InvalidArgument, t_no_appid.transfer(allocator, p7));
}

test "TransferV3.transfer 请求体与应答解析（对照官方文档示例）" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{
        .response =
        \\{"out_bill_no":"plfk2020042013","transfer_bill_no":"1330000071100999991182020050700019480001","create_time":"2015-05-20T13:29:35.120+08:00","state":"ACCEPTED","package_info":"affffddafdfafddffda=="}
        ,
    };
    var t = newCaptureTransfer(&stub);

    const parsed = try t.transfer(allocator, .{
        .out_bill_no = "plfk2020042013",
        .transfer_scene_id = "1000",
        .openid = "o-MYE42l80oelYMDE34nYD456Xoy",
        .user_name = "757b340b45ebef5467rter35gf464344v3542sdf4t6re4tb4f54ty45t4yyry45",
        .transfer_amount = 400000,
        .transfer_remark = "含\"引号\"\n换行的备注",
        .user_recv_perception = "现金奖励",
        .transfer_scene_report_infos = &.{
            .{ .info_type = "活动名称", .info_content = "新会员有礼" },
        },
        .user_recv_style = .{ .type = "RED_PACKET" },
    });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, stub.last_method);
    try std.testing.expectEqualStrings(
        "https://api.mch.weixin.qq.com/v3/fund-app/mch-transfer/transfer-bills",
        stub.lastUri(),
    );

    const payload = stub.lastPayload();
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"out_bill_no\":\"plfk2020042013\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"transfer_scene_id\":\"1000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"openid\":\"o-MYE42l80oelYMDE34nYD456Xoy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"transfer_amount\":400000") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"appid\":\"wxf636efh567hg4356\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"user_recv_perception\":\"现金奖励\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"user_recv_style\":{\"type\":\"RED_PACKET\"}") != null);
    // 报备信息数组逐字对齐官方字段名
    try std.testing.expect(std.mem.indexOf(u8, payload, "{\"info_type\":\"活动名称\",\"info_content\":\"新会员有礼\"}") != null);
    // 字符串转义：备注中的 " 与换行必须被 JSON 转义，不得裸插值
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"transfer_remark\":\"含\\\"引号\\\"\\n换行的备注\"") != null);
    // notify_url 未显式传入时回退 Config.notify_url
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"notify_url\":\"https://merchant.example.com/wxpay/transfer/notify\"") != null);
    // user_name 以密文原样透传（SDK 不做加密）
    try std.testing.expect(std.mem.indexOf(u8, payload, "757b340b45ebef5467rter35gf464344v3542sdf4t6re4tb4f54ty45t4yyry45") != null);

    try std.testing.expectEqualStrings("plfk2020042013", parsed.value.out_bill_no);
    try std.testing.expectEqualStrings("1330000071100999991182020050700019480001", parsed.value.transfer_bill_no);
    try std.testing.expectEqualStrings("ACCEPTED", parsed.value.state);
    try std.testing.expectEqualStrings("affffddafdfafddffda==", parsed.value.package_info);
    try std.testing.expectEqualStrings("2015-05-20T13:29:35.120+08:00", parsed.value.create_time);
}

test "TransferV3.transfer 省略空可选字段（不含 user_name / notify_url 键）" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"out_bill_no\":\"B1\",\"state\":\"WAIT_USER_CONFIRM\"}" };
    var t = TransferV3.init(.{ .app_id = "wx-appid-only" });
    t.setTransport(CaptureResp.dispatch, &stub);

    const parsed = try t.transfer(allocator, baseParams());
    defer parsed.deinit();

    const payload = stub.lastPayload();
    try std.testing.expect(std.mem.indexOf(u8, payload, "user_name") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "notify_url") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "user_recv_style") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"appid\":\"wx-appid-only\"") != null);
    // HTTP 200 但状态未终态：须能正常解析出状态
    try std.testing.expectEqualStrings("WAIT_USER_CONFIRM", parsed.value.state);
}

test "TransferV3.transfer 错误应答返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"code\":\"NOT_ENOUGH\",\"message\":\"资金不足\"}" };
    var t = newCaptureTransfer(&stub);

    const result = t.transfer(allocator, baseParams());
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "TransferV3.queryTransfer 路径与应答解析（对照官方文档示例）" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{
        .response =
        \\{"mch_id":"1900001109","out_bill_no":"plfk2020042013","transfer_bill_no":"1330000071100999991182020050700019480001","appid":"wxf636efh567hg4356","state":"SUCCESS","transfer_amount":400000,"transfer_remark":"新会员开通有礼","fail_reason":"PAYEE_ACCOUNT_ABNORMAL","openid":"o-MYE42l80oelYMDE34nYD456Xoy","user_name":"757b340b45ebef5467rter35gf464344v3542sdf4t6re4tb4f54ty45t4yyry45","create_time":"2015-05-20T13:29:35.120+08:00","update_time":"2015-05-20T13:29:35.120+08:00"}
        ,
    };
    var t = newCaptureTransfer(&stub);

    const parsed = try t.queryTransfer(allocator, "plfk2020042013");
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.GET, stub.last_method);
    try std.testing.expectEqualStrings(
        "https://api.mch.weixin.qq.com/v3/fund-app/mch-transfer/transfer-bills/out-bill-no/plfk2020042013",
        stub.lastUri(),
    );
    try std.testing.expectEqualStrings("", stub.lastPayload());

    try std.testing.expectEqualStrings("1900001109", parsed.value.mch_id);
    try std.testing.expectEqualStrings("SUCCESS", parsed.value.state);
    try std.testing.expectEqual(@as(i64, 400000), parsed.value.transfer_amount);
    try std.testing.expectEqualStrings("PAYEE_ACCOUNT_ABNORMAL", parsed.value.fail_reason);
    try std.testing.expectEqualStrings("o-MYE42l80oelYMDE34nYD456Xoy", parsed.value.openid);
    try std.testing.expectEqualStrings("新会员开通有礼", parsed.value.transfer_remark);
    try std.testing.expectEqualStrings("2015-05-20T13:29:35.120+08:00", parsed.value.update_time);
}

test "TransferV3.queryTransfer 空单号返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{}" };
    var t = newCaptureTransfer(&stub);

    try std.testing.expectError(util_error.WechatError.InvalidArgument, t.queryTransfer(allocator, ""));
}

test "TransferV3.queryTransfer 记录不存在返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"code\":\"NOT_FOUND\",\"message\":\"记录不存在\"}" };
    var t = newCaptureTransfer(&stub);

    try std.testing.expectError(util_error.WechatError.ApiError, t.queryTransfer(allocator, "not-exist"));
}

test "TransferV3.cancelTransfer 路径与应答解析（对照官方文档示例）" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{
        .response =
        \\{"out_bill_no":"plfk2020042013","transfer_bill_no":"1330000071100999991182020050700019480001","state":"CANCELING","update_time":"2015-05-20T13:29:35.120+08:00"}
        ,
    };
    var t = newCaptureTransfer(&stub);

    const parsed = try t.cancelTransfer(allocator, "plfk2020042013");
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, stub.last_method);
    try std.testing.expectEqualStrings(
        "https://api.mch.weixin.qq.com/v3/fund-app/mch-transfer/transfer-bills/out-bill-no/plfk2020042013/cancel",
        stub.lastUri(),
    );
    try std.testing.expectEqualStrings("", stub.lastPayload());
    try std.testing.expectEqualStrings("plfk2020042013", parsed.value.out_bill_no);
    try std.testing.expectEqualStrings("CANCELING", parsed.value.state);
}

test "TransferV3.cancelTransfer 空单号返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{}" };
    var t = newCaptureTransfer(&stub);

    try std.testing.expectError(util_error.WechatError.InvalidArgument, t.cancelTransfer(allocator, ""));
}

test "buildExtraHeaders 按配置附带 Wechatpay-Serial" {
    var buf: [2]std.http.Header = undefined;

    const plain = buildExtraHeaders(.{}, &buf);
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    try std.testing.expectEqualStrings("Accept", plain[0].name);
    try std.testing.expectEqualStrings("application/json", plain[0].value);

    const with_serial = buildExtraHeaders(.{ .wechatpay_serial = "PUB_KEY_ID_3000000001" }, &buf);
    try std.testing.expectEqual(@as(usize, 2), with_serial.len);
    try std.testing.expectEqualStrings("Wechatpay-Serial", with_serial[1].name);
    try std.testing.expectEqualStrings("PUB_KEY_ID_3000000001", with_serial[1].value);
}

test "TransferNotifyResource 解密明文解析（商家转账结果通知）" {
    const allocator = std.testing.allocator;
    // 官方《商家转账回调通知》给出的 resource.ciphertext 解密后明文示例
    const plain =
        \\{"out_bill_no":"plfk2020042013","transfer_bill_no":"1330000071100999991182020050700019480001","state":"SUCCESS","mch_id":"1900001109","transfer_amount":2000,"openid":"o-MYE421800elYMDE34nYD456Xoy","fail_reason":"PAYEE_ACCOUNT_ABNORMAL","create_time":"2015-05-20T13:29:35+08:00","update_time":"2023-08-15T20:33:22+08:00","payment_method_type":"CFT"}
    ;

    const parsed = try std.json.parseFromSlice(TransferNotifyResource, allocator, plain, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("plfk2020042013", parsed.value.out_bill_no);
    try std.testing.expectEqualStrings("SUCCESS", parsed.value.state);
    try std.testing.expectEqual(@as(i64, 2000), parsed.value.transfer_amount);
    try std.testing.expectEqualStrings("PAYEE_ACCOUNT_ABNORMAL", parsed.value.fail_reason);
    try std.testing.expectEqualStrings("CFT", parsed.value.payment_method_type);

    // 与 notify.decryptNotifyResource 的 AES-256-GCM 能力组合验证（复用，不另造解密轮子）。
    // 注意官方示例的 associated_data 为 "mch_payment"。
    const notify = @import("notify.zig");
    const api_v3_key = "12345678901234567890123456789012";
    const nonce = "fdasflkja484";
    const aad = "mch_payment";
    const key_bytes: [32]u8 = api_v3_key[0..32].*;
    const nonce_bytes: [12]u8 = nonce[0..12].*;

    const cipher_buf = try allocator.alloc(u8, plain.len);
    defer allocator.free(cipher_buf);
    var tag: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(cipher_buf, &tag, plain, aad, nonce_bytes, key_bytes);

    const full = try allocator.alloc(u8, plain.len + 16);
    defer allocator.free(full);
    @memcpy(full[0..plain.len], cipher_buf);
    @memcpy(full[plain.len..], &tag);

    const b64 = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(full.len));
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, full);

    const decrypted = try notify.decryptNotifyResource(allocator, api_v3_key, b64, aad, nonce);
    defer allocator.free(decrypted);

    const reparsed = try std.json.parseFromSlice(TransferNotifyResource, allocator, decrypted, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("1330000071100999991182020050700019480001", reparsed.value.transfer_bill_no);
    try std.testing.expectEqualStrings("1900001109", reparsed.value.mch_id);
    try std.testing.expectEqual(@as(i64, 2000), reparsed.value.transfer_amount);
}
