// SPDX-License-Identifier: Apache-2.0
//! miniprogram/message — 微信小程序订阅消息 (subscribeMessage)
//!
//! 发送端：`sendSubscribeMessage`（`subscribeMessage.send`）。
//! 接收端：`PushReceiver.getMsgData` 推送消息解析（对照 Go `miniprogram/message/message.go`
//! 的 `PushReceiver`/`GetMsgData`/`GetSubscribeMsgPopupEvents`），纯解析逻辑，无 HTTP。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const SubscribeMessageParams = struct {
    touser: []const u8,
    template_id: []const u8,
    page: []const u8 = "",
    data: []const u8, // JSON 数据字符串（原样注入请求体）
    miniprogram_state: []const u8 = "developer", // developer / trial / formal
    lang: []const u8 = "zh_CN",
};

pub const Message = struct {
    ctx: *Context,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    pub fn init(ctx: *Context) Message {
        return .{ .ctx = ctx };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Message, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 发送小程序订阅消息 (`subscribeMessage.send`)。
    ///
    /// 返回微信原始响应体，调用方负责 `allocator.free`；
    /// 响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn sendSubscribeMessage(
        self: Message,
        allocator: std.mem.Allocator,
        params: SubscribeMessageParams,
    ) ![]u8 {
        const access_token = try self.ctx.getAccessToken(allocator);
        defer allocator.free(access_token);

        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.weixin.qq.com/cgi-bin/message/subscribe/send?access_token={s}",
            .{access_token},
        );
        defer allocator.free(url);

        const body = try encodeSubscribeMessageBody(allocator, params);
        defer allocator.free(body);

        const resp = try self.postJSON(allocator, url, body);
        errdefer allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
        }, allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) {
            return util_error.WechatError.ApiError;
        }
        return resp;
    }

    fn postJSON(self: Message, allocator: std.mem.Allocator, uri: []const u8, payload: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, payload);
        }
        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();
        return client.postJSON(uri, payload);
    }
};

/// 构造 `subscribeMessage.send` 的 JSON 请求体。
///
/// `data` 为调用方拼好的模板数据 JSON，按原样注入（保持 raw 注入设计）；
/// 其余字符串字段统一走 `std.json.Stringify` 转义。
fn encodeSubscribeMessageBody(allocator: std.mem.Allocator, params: SubscribeMessageParams) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("touser");
    try s.write(params.touser);
    try s.objectField("template_id");
    try s.write(params.template_id);
    try s.objectField("page");
    try s.write(params.page);
    try s.objectField("data");
    try s.beginWriteRaw();
    try s.writer.writeAll(params.data);
    s.endWriteRaw();
    try s.objectField("miniprogram_state");
    try s.write(params.miniprogram_state);
    try s.objectField("lang");
    try s.write(params.lang);
    try s.endObject();
    return out.toOwnedSlice();
}

test "SubscribeMessageParams 默认开发状态" {
    const p = SubscribeMessageParams{
        .touser = "o_123",
        .template_id = "tpl_456",
        .data = "{}",
    };
    try std.testing.expectEqualStrings("developer", p.miniprogram_state);
    try std.testing.expectEqualStrings("zh_CN", p.lang);
}

test "encodeSubscribeMessageBody 字符串字段转义为合法 JSON" {
    const allocator = std.testing.allocator;
    const body = try encodeSubscribeMessageBody(allocator, .{
        .touser = "o_\"123\\",
        .template_id = "tpl_456\n",
        .data = "{\"thing1\":{\"value\":\"值\"}}",
    });
    defer allocator.free(body);

    // 整个 body 必须是合法 JSON。
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("o_\"123\\", obj.get("touser").?.string);
    try std.testing.expectEqualStrings("tpl_456\n", obj.get("template_id").?.string);
    // data 原样注入且自身可解析。
    const data_val = obj.get("data").?;
    try std.testing.expect(data_val == .object);
    try std.testing.expect(data_val.object.get("thing1") != null);
}

// —— mock 测试 ——

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

/// 捕获请求 payload 并返回预设响应的 transport，用于请求体断言。
const Capture = struct {
    response: []const u8,
    payload: []u8 = &.{},

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = content_type;
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (self.payload.len > 0) allocator.free(self.payload);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }
};

test "sendSubscribeMessage 模板字段含特殊字符时 body 为合法 JSON" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx = makeCtx();
    var m = Message.init(&ctx);
    m.setTransport(Capture.dispatch, &cap);

    const resp = try m.sendSubscribeMessage(allocator, .{
        .touser = "oABC",
        .template_id = "tpl\"quote\\",
        .page = "pages/index?x=1&y=2",
        .data = "{\"thing1\":{\"value\":\"书名《\\\"x\\\"》\"}}",
    });
    defer allocator.free(resp);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, cap.payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("oABC", obj.get("touser").?.string);
    try std.testing.expectEqualStrings("tpl\"quote\\", obj.get("template_id").?.string);
    try std.testing.expectEqualStrings("pages/index?x=1&y=2", obj.get("page").?.string);
    try std.testing.expectEqualStrings("developer", obj.get("miniprogram_state").?.string);
    try std.testing.expectEqualStrings("zh_CN", obj.get("lang").?.string);
    try std.testing.expect(obj.get("data").?.object.get("thing1") != null);
}

test "sendSubscribeMessage errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":43101,\"errmsg\":\"user refuse to accept the msg\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx = makeCtx();
    var m = Message.init(&ctx);
    m.setTransport(Capture.dispatch, &cap);

    const result = m.sendSubscribeMessage(allocator, .{
        .touser = "oABC",
        .template_id = "tpl",
        .data = "{}",
    });
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "sendSubscribeMessage 成功时返回响应体" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx = makeCtx();
    var m = Message.init(&ctx);
    m.setTransport(Capture.dispatch, &cap);

    const resp = try m.sendSubscribeMessage(allocator, .{
        .touser = "oABC",
        .template_id = "tpl",
        .data = "{}",
    });
    defer allocator.free(resp);
    try std.testing.expectEqualStrings("{\"errcode\":0,\"errmsg\":\"ok\"}", resp);
}

// ─────────────────────────────────────────────────────────────────────────────
// 接收端推送解析（对照 `_ref/wechat/miniprogram/message/message.go` 的 PushReceiver）。
// ─────────────────────────────────────────────────────────────────────────────

const util_xml = @import("../../util/xml.zig");

/// 推送数据格式（对照 Go `DataTypeXML` / `DataTypeJSON`）。
pub const PushDataType = enum { xml, json };

/// 固定消息类型：事件（对照 Go `MsgTypeEvent`）。
pub const msg_type_event = "event";
/// 事件类型：用户操作订阅通知弹窗（对照 Go `EventSubscribePopup`）。
pub const event_subscribe_popup = "subscribe_msg_popup_event";
/// 事件类型：用户管理订阅通知（对照 Go `EventSubscribeMsgChange`）。
pub const event_subscribe_msg_change = "subscribe_msg_change_event";
/// 事件类型：发送订阅通知（对照 Go `EventSubscribeMsgSent`）。
pub const event_subscribe_msg_sent = "subscribe_msg_sent_event";

// —— 交易管理（对照 Go `EventTypeTradeManage*`）——

/// 事件类型：提醒接入发货信息管理服务 API（对照 Go `EventTypeTradeManageRemindAccessAPI`）。
pub const event_trade_manage_remind_access_api = "trade_manage_remind_access_api";
/// 事件类型：提醒需要上传发货信息（对照 Go `EventTypeTradeManageRemindShipping`）。
pub const event_trade_manage_remind_shipping = "trade_manage_remind_shipping";
/// 事件类型：订单将要结算或已经结算（对照 Go `EventTypeTradeManageOrderSettlement`）。
pub const event_trade_manage_order_settlement = "trade_manage_order_settlement";
/// 确认收货方式：自动确认收货（对照 Go `ConfirmReceiveMethodAuto`）。
pub const confirm_receive_method_auto: i64 = 1;
/// 确认收货方式：手动确认收货（对照 Go `ConfirmReceiveMethodManual`）。
pub const confirm_receive_method_manual: i64 = 2;

// —— 物流助手 / 内容安全 / 短剧媒资（对照 Go `EventTypeAddExpressPath` 等）——

/// 事件类型：媒体内容安全异步审查结果通知（对照 Go `EventTypeWxaMediaCheck`）。
pub const event_wxa_media_check = "wxa_media_check";
/// 事件类型：运单轨迹更新（对照 Go `EventTypeAddExpressPath`）。
pub const event_add_express_path = "add_express_path";
/// 事件类型：短剧媒资上传完成（对照 Go `EventTypeSecvodUpload`）。
pub const event_secvod_upload = "secvod_upload_event";
/// 事件类型：短剧媒资审核状态（对照 Go `EventTypeSecvodAudit`）。
pub const event_secvod_audit = "secvod_audit_event";
/// 内容安全建议：违规风险（对照 Go `CheckSuggestRisky`）。
pub const check_suggest_risky = "risky";
/// 内容安全建议：安全（对照 Go `CheckSuggestPass`）。
pub const check_suggest_pass = "pass";
/// 内容安全建议：需要人工审查（对照 Go `CheckSuggestReview`）。
pub const check_suggest_review = "review";
/// 订阅通知状态：接受（对照 Go `InfoTypeAcceptSubscribeMessage`）。
pub const info_type_accept = "accept";
/// 订阅通知状态：拒绝（对照 Go `InfoTypeRejectSubscribeMessage`）。
pub const info_type_reject = "reject";

// —— 虚拟支付（对照 Go `EventTypeXpay*`）——

/// 事件类型：虚拟支付道具发货推送（对照 Go `EventTypeXpayGoodsDeliverNotify`）。
pub const event_xpay_goods_deliver_notify = "xpay_goods_deliver_notify";
/// 事件类型：虚拟支付代币支付推送（对照 Go `EventTypeXpayCoinPayNotify`）。
pub const event_xpay_coin_pay_notify = "xpay_coin_pay_notify";
/// 事件类型：虚拟支付退款推送（对照 Go `EventTypeXpayRefundNotify`）。
pub const event_xpay_refund_notify = "xpay_refund_notify";
/// 事件类型：虚拟支付 iOS Apple 支付退款问询（对照 Go `EventTypeXpaySubscribeIosRefundQueryNotify`）。
pub const event_xpay_subscribe_ios_refund_query_notify = "xpay_subscribe_ios_refund_query_notify";
/// 事件类型：虚拟支付用户投诉推送（对照 Go `EventTypeXpayComplaintNotify`）。
pub const event_xpay_complaint_notify = "xpay_complaint_notify";
/// 虚拟支付环境配置：现网（正式）环境（对照 Go `Env` 注释）。
pub const xpay_env_production: i64 = 0;
/// 虚拟支付环境配置：沙箱环境（对照 Go `Env` 注释）。
pub const xpay_env_sandbox: i64 = 1;

/// 推送数据通用头（对照 Go `CommonPushData`）。
pub const CommonPushData = struct {
    to_user_name: []const u8 = "",
    from_user_name: []const u8 = "",
    create_time: i64 = 0,
    msg_type: []const u8 = "",
    event: []const u8 = "",
};

/// 订阅通知弹窗事件列表项（对照 Go `SubscribeMsgPopupEventList`）。
pub const SubscribeMsgPopupEventItem = struct {
    template_id: []const u8 = "",
    subscribe_status_string: []const u8 = "",
    popup_scene: []const u8 = "",
};

/// 用户管理订阅通知事件列表项（对照 Go `SubscribeMsgChangeList`）。
pub const SubscribeMsgChangeEventItem = struct {
    template_id: []const u8 = "",
    subscribe_status_string: []const u8 = "",
};

/// 订阅通知发送结果事件列表项（对照 Go `SubscribeMsgSentList`）。
pub const SubscribeMsgSentEventItem = struct {
    template_id: []const u8 = "",
    msg_id: []const u8 = "",
    error_code: []const u8 = "",
    error_status: []const u8 = "",
};

/// 订阅通知弹窗事件推送数据（对照 Go `PushDataSubscribePopup`）。
///
/// `events` 为订阅消息事件列表：JSON 路径取顶层 `List`（对照 Go gjson `Get(msg, "List")`，
/// object / array 均接受），XML 路径取 `<SubscribeMsgPopupEvent><List><item>…`。
pub const PushDataSubscribePopup = struct {
    common: CommonPushData = .{},
    events: []SubscribeMsgPopupEventItem = &.{},

    /// 对照 Go `GetSubscribeMsgPopupEvents()`。
    pub fn getSubscribeMsgPopupEvents(self: *const PushDataSubscribePopup) []SubscribeMsgPopupEventItem {
        return self.events;
    }
};

/// 用户管理订阅通知事件推送数据（对照 Go `PushDataSubscribeMsgChange`）。
pub const PushDataSubscribeMsgChange = struct {
    common: CommonPushData = .{},
    events: []SubscribeMsgChangeEventItem = &.{},

    /// 对照 Go `GetSubscribeMsgChangeEvents()`。
    pub fn getSubscribeMsgChangeEvents(self: *const PushDataSubscribeMsgChange) []SubscribeMsgChangeEventItem {
        return self.events;
    }
};

/// 订阅通知发送结果事件推送数据（对照 Go `PushDataSubscribeMsgSent`）。
pub const PushDataSubscribeMsgSent = struct {
    common: CommonPushData = .{},
    events: []SubscribeMsgSentEventItem = &.{},

    /// 对照 Go `GetSubscribeMsgSentEvents()`。
    pub fn getSubscribeMsgSentEvents(self: *const PushDataSubscribeMsgSent) []SubscribeMsgSentEventItem {
        return self.events;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 交易管理事件（对照 Go `PushDataRemindAccessAPI` / `PushDataRemindShipping` /
// `PushDataOrderSettlement`）。
// ─────────────────────────────────────────────────────────────────────────────

/// 提醒接入发货信息管理服务 API（对照 Go `PushDataRemindAccessAPI`）。
pub const PushDataRemindAccessApi = struct {
    common: CommonPushData = .{},
    /// 消息文本内容。
    msg: []const u8 = "",
};

/// 提醒需要上传发货信息（对照 Go `PushDataRemindShipping`）。
pub const PushDataRemindShipping = struct {
    common: CommonPushData = .{},
    /// 微信支付订单号。
    transaction_id: []const u8 = "",
    /// 商户号。
    merchant_id: []const u8 = "",
    /// 子商户号。
    sub_merchant_id: []const u8 = "",
    /// 商户订单号。
    merchant_trade_no: []const u8 = "",
    /// 支付成功时间，秒级时间戳。
    pay_time: i64 = 0,
    /// 消息文本内容。
    msg: []const u8 = "",
};

/// 订单将要结算或已经结算通知（对照 Go `PushDataOrderSettlement`）。
///
/// `estimated_settlement_time` 仅发货时推送有值；`confirm_receive_method` /
/// `confirm_receive_time` / `settlement_time` 仅结算时推送有值。
pub const PushDataOrderSettlement = struct {
    common: CommonPushData = .{},
    /// 支付订单号。
    transaction_id: []const u8 = "",
    /// 商户号。
    merchant_id: []const u8 = "",
    /// 子商户号。
    sub_merchant_id: []const u8 = "",
    /// 商户订单号。
    merchant_trade_no: []const u8 = "",
    /// 支付成功时间，秒级时间戳。
    pay_time: i64 = 0,
    /// 发货时间，秒级时间戳。
    shipped_time: i64 = 0,
    /// 预计结算时间，秒级时间戳。
    estimated_settlement_time: i64 = 0,
    /// 确认收货方式：`confirm_receive_method_auto` / `confirm_receive_method_manual`。
    confirm_receive_method: i64 = 0,
    /// 确认收货时间，秒级时间戳。
    confirm_receive_time: i64 = 0,
    /// 订单结算时间，秒级时间戳。
    settlement_time: i64 = 0,

    /// 是否为自动确认收货（对照 Go `ConfirmReceiveMethodAuto`）。
    pub fn isAutoConfirmReceive(self: *const PushDataOrderSettlement) bool {
        return self.confirm_receive_method == confirm_receive_method_auto;
    }

    /// 是否为手动确认收货（对照 Go `ConfirmReceiveMethodManual`）。
    pub fn isManualConfirmReceive(self: *const PushDataOrderSettlement) bool {
        return self.confirm_receive_method == confirm_receive_method_manual;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内容安全：媒体异步检测结果（对照 Go `MediaCheckAsyncData`）。
// ─────────────────────────────────────────────────────────────────────────────

/// 检测结果详情（对照 Go `MediaCheckDetail`）。
///
/// `suggest` 取 `check_suggest_*`；`label` 为命中标签（100 正常、20001 时政 …，对照
/// Go `security.CheckLabel`），保留原始整型避免未知标签被吞掉。
pub const MediaCheckDetail = struct {
    strategy: []const u8 = "",
    errcode: i64 = 0,
    suggest: []const u8 = "",
    label: i64 = 0,
    /// 置信度 0-100。
    prob: i64 = 0,
};

/// 检测综合结果（对照 Go `MediaCheckAsyncResult`）。
pub const MediaCheckAsyncResult = struct {
    suggest: []const u8 = "",
    label: i64 = 0,
};

/// 媒体内容安全异步审查结果通知（对照 Go `MediaCheckAsyncData`）。
pub const MediaCheckAsyncData = struct {
    common: CommonPushData = .{},
    appid: []const u8 = "",
    trace_id: []const u8 = "",
    version: i64 = 0,
    detail: []MediaCheckDetail = &.{},
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    result: MediaCheckAsyncResult = .{},

    /// 综合建议是否为「违规风险」（对照 Go `CheckSuggestRisky`）。
    pub fn isRisky(self: *const MediaCheckAsyncData) bool {
        return std.mem.eql(u8, self.result.suggest, check_suggest_risky);
    }

    /// 综合建议是否为「安全通过」（对照 Go `CheckSuggestPass`）。
    pub fn isPass(self: *const MediaCheckAsyncData) bool {
        return std.mem.eql(u8, self.result.suggest, check_suggest_pass);
    }

    /// 是否存在任一条命中的检测详情（判断依据：`errcode == 0` 且建议为 risky）。
    pub fn hasRiskyDetail(self: *const MediaCheckAsyncData) bool {
        for (self.detail) |d| {
            if (d.errcode == 0 and std.mem.eql(u8, d.suggest, check_suggest_risky)) return true;
        }
        return false;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 物流助手：运单轨迹更新（对照 Go `PushDataAddExpressPath`）。
// ─────────────────────────────────────────────────────────────────────────────

/// 轨迹节点（对照 Go `PushDataAddExpressPathAction`）。
pub const PushDataAddExpressPathAction = struct {
    /// 轨迹节点 Unix 时间戳。
    action_time: i64 = 0,
    /// 轨迹节点类型。
    action_type: i64 = 0,
    /// 轨迹节点详情。
    action_msg: []const u8 = "",
};

/// 运单轨迹更新信息（对照 Go `PushDataAddExpressPath`）。
pub const PushDataAddExpressPath = struct {
    common: CommonPushData = .{},
    /// 快递公司 ID。
    delivery_id: []const u8 = "",
    /// 运单 ID。
    waybill_id: []const u8 = "",
    /// 订单 ID。
    order_id: []const u8 = "",
    /// 轨迹版本号。
    version: i64 = 0,
    /// 轨迹节点数。
    count: i64 = 0,
    /// 轨迹节点列表。
    actions: []PushDataAddExpressPathAction = &.{},

    /// 轨迹节点列表（对照 Go `Actions` 字段直读）。
    pub fn getActions(self: *const PushDataAddExpressPath) []PushDataAddExpressPathAction {
        return self.actions;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 短视频：短剧媒资上传 / 审核（对照 Go `PushDataSecVodUpload` / `PushDataSecVodAudit`）。
// ─────────────────────────────────────────────────────────────────────────────

/// 短剧媒资上传完成事件（对照 Go `SecVodUploadEvent`）。
pub const SecVodUploadEvent = struct {
    /// 媒资 id。
    media_id: i64 = 0,
    /// 透传上传接口中开发者设置的值。
    source_context: []const u8 = "",
    /// 错误码，上传失败时非 0。
    errcode: i64 = 0,
    /// 错误提示。
    errmsg: []const u8 = "",
};

/// 短剧媒资上传完成推送（对照 Go `PushDataSecVodUpload`）。
pub const PushDataSecVodUpload = struct {
    common: CommonPushData = .{},
    upload_event: SecVodUploadEvent = .{},

    /// 上传是否成功（对照 Go `SecVodUploadEvent.ErrCode`）。
    pub fn isSuccess(self: *const PushDataSecVodUpload) bool {
        return self.upload_event.errcode == 0;
    }
};

/// 剧目审核结果（对照 Go `DramaAuditDetail`）。
///
/// `status`：0 无效值；1 审核中；2 最终失败；3 审核通过；4 驳回重填。
pub const DramaAuditDetail = struct {
    status: i64 = 0,
    /// 提审时间戳。
    create_time: i64 = 0,
    /// 审核时间戳。
    audit_time: i64 = 0,
};

/// 短剧媒资审核状态事件（对照 Go `SecVodAuditEvent`）。
pub const SecVodAuditEvent = struct {
    /// 剧目 id。
    drama_id: i64 = 0,
    source_context: []const u8 = "",
    audit_detail: DramaAuditDetail = .{},
};

/// 短剧媒资审核状态推送（对照 Go `PushDataSecVodAudit`）。
pub const PushDataSecVodAudit = struct {
    common: CommonPushData = .{},
    audit_event: SecVodAuditEvent = .{},

    /// 审核是否通过（对照 Go `DramaAuditDetail.Status == 3`）。
    pub fn isAuditPassed(self: *const PushDataSecVodAudit) bool {
        return self.audit_event.audit_detail.status == 3;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 虚拟支付（对照 Go `xpay_*` 系列结构体）。
// ─────────────────────────────────────────────────────────────────────────────

/// 微信支付信息（对照 Go `WeChatPayInfo`）。
pub const WeChatPayInfo = struct {
    /// 微信支付商户单号。
    mch_order_no: []const u8 = "",
    /// 交易单号（微信支付订单号）。
    transaction_id: []const u8 = "",
    /// 用户支付时间，Linux 秒级时间戳。
    paid_time: i64 = 0,
};

/// 道具参数信息（对照 Go `GoodsInfo`）。
pub const XpayGoodsInfo = struct {
    /// 道具 ID。
    product_id: []const u8 = "",
    quantity: i64 = 0,
    /// 物品原始价格（单位：分）。
    orig_price: i64 = 0,
    /// 物品实际支付价格（单位：分）。
    actual_price: i64 = 0,
    /// 透传信息。
    attach: []const u8 = "",
};

/// 代币参数信息（对照 Go `CoinInfo`）。
pub const XpayCoinInfo = struct {
    quantity: i64 = 0,
    /// 物品原始价格（单位：分）。
    orig_price: i64 = 0,
    /// 物品实际支付价格（单位：分）。
    actual_price: i64 = 0,
    /// 透传信息。
    attach: []const u8 = "",
};

/// 拼团信息（对照 Go `XpayTeamInfo`）。
pub const XpayTeamInfo = struct {
    /// 活动 id。
    activity_id: []const u8 = "",
    /// 团 id。
    team_id: []const u8 = "",
    /// 团类型：1-支付全部，拼成退款。
    team_type: i64 = 0,
    /// 0-创团；1-参团。
    team_action: i64 = 0,
};

/// 道具发货推送（对照 Go `PushDataXpayGoodsDeliverNotify`）。
pub const PushDataXpayGoodsDeliverNotify = struct {
    common: CommonPushData = .{},
    /// 用户 openid。
    open_id: []const u8 = "",
    /// 业务订单号。
    out_trade_no: []const u8 = "",
    /// 环境配置：`xpay_env_production` / `xpay_env_sandbox`。
    env: i64 = 0,
    /// 微信支付信息，非微信支付渠道可能缺省。
    wechat_pay_info: WeChatPayInfo = .{},
    /// 道具参数信息。
    goods_info: XpayGoodsInfo = .{},
    /// 拼团信息。
    team_info: XpayTeamInfo = .{},

    /// 是否沙箱环境（对照 Go `Env` 注释 1）。
    pub fn isSandbox(self: *const PushDataXpayGoodsDeliverNotify) bool {
        return self.env == xpay_env_sandbox;
    }
};

/// 代币支付推送（对照 Go `PushDataXpayCoinPayNotify`）。
pub const PushDataXpayCoinPayNotify = struct {
    common: CommonPushData = .{},
    /// 用户 openid。
    open_id: []const u8 = "",
    /// 业务订单号。
    out_trade_no: []const u8 = "",
    /// 环境配置：`xpay_env_production` / `xpay_env_sandbox`。
    env: i64 = 0,
    /// 微信支付信息，非微信支付渠道可能缺省。
    wechat_pay_info: WeChatPayInfo = .{},
    /// 代币参数信息。
    coin_info: XpayCoinInfo = .{},

    /// 是否沙箱环境（对照 Go `Env` 注释 1）。
    pub fn isSandbox(self: *const PushDataXpayCoinPayNotify) bool {
        return self.env == xpay_env_sandbox;
    }
};

/// 退款推送（对照 Go `PushDataXpayRefundNotify`）。
pub const PushDataXpayRefundNotify = struct {
    common: CommonPushData = .{},
    /// 用户 openid。
    open_id: []const u8 = "",
    /// 微信退款单号。
    wx_refund_id: []const u8 = "",
    /// 商户退款单号。
    mch_refund_id: []const u8 = "",
    /// 退款单对应支付单的微信单号。
    wx_order_id: []const u8 = "",
    /// 退款单对应支付单的商户单号。
    mch_order_id: []const u8 = "",
    /// 退款金额，单位分。
    refund_fee: i64 = 0,
    /// 退款结果，0 为成功。
    ret_code: i64 = 0,
    /// 退款结果详情。
    ret_msg: []const u8 = "",
    /// 开始退款时间，秒级时间戳。
    refund_start_timestamp: i64 = 0,
    /// 结束退款时间，秒级时间戳。
    refund_succ_timestamp: i64 = 0,
    /// 退款单的微信支付单号。
    wxpay_refund_transaction_id: []const u8 = "",
    /// 重试次数，从 0 开始。
    retry_times: i64 = 0,
    /// 拼团信息。
    team_info: XpayTeamInfo = .{},

    /// 退款是否成功（对照 Go `RetCode` 注释：0 为成功）。
    pub fn isSuccess(self: *const PushDataXpayRefundNotify) bool {
        return self.ret_code == 0;
    }
};

/// iOS Apple 支付退款问询事件（对照 Go `PushDataXpaySubscribeIosRefundQueryNotify`）。
///
/// 字段在 Go 中均为字符串（时间戳也是字符串），此处保持一致。
pub const PushDataXpaySubscribeIosRefundQueryNotify = struct {
    common: CommonPushData = .{},
    /// 问询时间，Unix 时间戳。
    refund_time: []const u8 = "",
    /// 该笔退款的订单时间，Unix 时间戳。
    order_time: []const u8 = "",
    /// Apple 支付票据号。
    channel_bill: []const u8 = "",
    /// 应用的 Apple bundleid。
    bundle_id: []const u8 = "",
    /// 道具 id。
    product_id: []const u8 = "",
    /// 道具 / 代币数量。
    p_count: []const u8 = "",
    /// 用户请求退款的原因。
    refund_request_reason: []const u8 = "",
    /// 发货状态：0 未发货；1 已发货；2 发货中。
    provide_status: []const u8 = "",
    /// 退款对应支付订单号。
    pay_order_id: []const u8 = "",
};

/// 用户投诉推送（对照 Go `PushDataXpayComplaintNotify`）。
pub const PushDataXpayComplaintNotify = struct {
    common: CommonPushData = .{},
    /// 用户 openid。
    open_id: []const u8 = "",
    /// 微信单号。
    wx_order_id: []const u8 = "",
    /// 商户单号。
    mch_order_id: []const u8 = "",
    /// 微信支付交易单号。
    transaction_id: []const u8 = "",
    /// 投诉单号。
    complaint_id: []const u8 = "",
    /// 投诉详情。
    complaint_detail: []const u8 = "",
    /// 投诉时间，秒级时间戳。
    complaint_time: i64 = 0,
    /// 重试次数，从 0 开始。
    retry_times: i64 = 0,
    /// 请求编号。
    request_id: []const u8 = "",
};

/// 推送数据（对照 Go `PushData` 接口）。
///
/// 已支持订阅通知三类事件之外的 12 类事件（对照 Go `getEvent` 的 15 个 case）；
/// 其余消息 / 事件类型返回 `.raw` 明文字节
/// （对照 Go `getEvent` fallback：暂不支持其他事件类型，直接返回解密后的数据，由调用方处理）。
pub const PushData = union(enum) {
    subscribe_msg_popup: PushDataSubscribePopup,
    subscribe_msg_change: PushDataSubscribeMsgChange,
    subscribe_msg_sent: PushDataSubscribeMsgSent,
    trade_manage_remind_access_api: PushDataRemindAccessApi,
    trade_manage_remind_shipping: PushDataRemindShipping,
    trade_manage_order_settlement: PushDataOrderSettlement,
    wxa_media_check: MediaCheckAsyncData,
    add_express_path: PushDataAddExpressPath,
    secvod_upload: PushDataSecVodUpload,
    secvod_audit: PushDataSecVodAudit,
    xpay_goods_deliver_notify: PushDataXpayGoodsDeliverNotify,
    xpay_coin_pay_notify: PushDataXpayCoinPayNotify,
    xpay_refund_notify: PushDataXpayRefundNotify,
    xpay_subscribe_ios_refund_query_notify: PushDataXpaySubscribeIosRefundQueryNotify,
    xpay_complaint_notify: PushDataXpayComplaintNotify,
    raw: []const u8,
};

/// `getMsgData` 的返回：消息类型、事件类型与结构化数据。
pub const ParsedPushMsg = struct {
    msg_type: []const u8,
    event: []const u8,
    data: PushData,
};

/// 推送消息接收解析器（对照 Go `PushReceiver`）。
///
/// Go 的 `PushReceiver` 绑定 `*http.Request`，负责验签 + AES 解密后再解析；
/// 本仓库中验签 / 解密由 `middleware`（wechat_handler）完成，此处定位为**纯解析器**：
/// 输入解密后的明文 XML / JSON，输出结构化推送数据，不涉及 HTTP。
pub const PushReceiver = struct {
    pub fn init() PushReceiver {
        return .{};
    }

    /// 解析推送消息（对照 Go `GetMsgData`）。
    ///
    /// **内存**：所有返回的字符串切片与事件列表数组（含 `.raw` 副本）均由 `allocator`
    /// 分配；推荐传入 arena 并由 arena 统一释放（测试即以 arena 包裹
    /// `std.testing.allocator`，泄漏会被检测）。
    pub fn getMsgData(
        self: PushReceiver,
        allocator: std.mem.Allocator,
        data: []const u8,
        data_type: PushDataType,
    ) !ParsedPushMsg {
        _ = self;
        return switch (data_type) {
            .json => parsePushJson(allocator, data),
            .xml => parsePushXml(allocator, data),
        };
    }
};

fn parsePushJson(allocator: std.mem.Allocator, data: []const u8) !ParsedPushMsg {
    var tree = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return util_error.WechatError.DecodeError;
    };
    defer tree.deinit();
    if (tree.value != .object) return util_error.WechatError.DecodeError;
    const obj = tree.value.object;

    // 字段全部复制出树，返回值的生存期与 tree 解耦。
    const common = CommonPushData{
        .to_user_name = try dupeOrEmpty(allocator, jsonStr(obj.get("ToUserName"))),
        .from_user_name = try dupeOrEmpty(allocator, jsonStr(obj.get("FromUserName"))),
        .create_time = jsonInt(obj.get("CreateTime")),
        .msg_type = try dupeOrEmpty(allocator, jsonStr(obj.get("MsgType"))),
        .event = try dupeOrEmpty(allocator, jsonStr(obj.get("Event"))),
    };

    if (!std.mem.eql(u8, common.msg_type, msg_type_event)) {
        return finishRaw(allocator, common, data);
    }
    if (std.mem.eql(u8, common.event, event_subscribe_popup)) {
        return .{ .msg_type = common.msg_type, .event = common.event, .data = .{ .subscribe_msg_popup = .{
            .common = common,
            .events = try parsePopupItemsJson(allocator, obj.get("List")),
        } } };
    }
    if (std.mem.eql(u8, common.event, event_subscribe_msg_change)) {
        return .{ .msg_type = common.msg_type, .event = common.event, .data = .{ .subscribe_msg_change = .{
            .common = common,
            .events = try parseChangeItemsJson(allocator, obj.get("List")),
        } } };
    }
    if (std.mem.eql(u8, common.event, event_subscribe_msg_sent)) {
        return .{ .msg_type = common.msg_type, .event = common.event, .data = .{ .subscribe_msg_sent = .{
            .common = common,
            .events = try parseSentItemsJson(allocator, obj.get("List")),
        } } };
    }
    // 其余 getEvent 分支（交易管理 / 内容安全 / 物流 / 短剧媒资 / 虚拟支付）。
    if (try eventJsonToPushData(allocator, common, obj)) |payload| {
        return .{ .msg_type = common.msg_type, .event = common.event, .data = payload };
    }
    // 暂不支持其他事件类型，直接返回明文（对照 Go getEvent fallback）。
    return finishRaw(allocator, common, data);
}

fn finishRaw(allocator: std.mem.Allocator, common: CommonPushData, data: []const u8) !ParsedPushMsg {
    return .{ .msg_type = common.msg_type, .event = common.event, .data = .{ .raw = try allocator.dupe(u8, data) } };
}

fn parsePushXml(allocator: std.mem.Allocator, data: []const u8) !ParsedPushMsg {
    // 头部字段直接按标签扫描（CDATA 感知）——事件体是嵌套 XML，util_xml 只支持单层结构。
    const common = CommonPushData{
        .to_user_name = xmlTagValue(data, "ToUserName") orelse "",
        .from_user_name = xmlTagValue(data, "FromUserName") orelse "",
        .create_time = std.fmt.parseInt(i64, xmlTagValue(data, "CreateTime") orelse "0", 10) catch 0,
        .msg_type = xmlTagValue(data, "MsgType") orelse "",
        .event = xmlTagValue(data, "Event") orelse "",
    };

    if (!std.mem.eql(u8, common.msg_type, msg_type_event)) {
        return finishRaw(allocator, common, data);
    }
    if (std.mem.eql(u8, common.event, event_subscribe_popup)) {
        return .{ .msg_type = common.msg_type, .event = common.event, .data = .{ .subscribe_msg_popup = .{
            .common = common,
            .events = try parseXmlEventItems(allocator, data, "SubscribeMsgPopupEvent", SubscribeMsgPopupEventItem, parsePopupItemXml),
        } } };
    }
    if (std.mem.eql(u8, common.event, event_subscribe_msg_change)) {
        return .{ .msg_type = common.msg_type, .event = common.event, .data = .{ .subscribe_msg_change = .{
            .common = common,
            .events = try parseXmlEventItems(allocator, data, "SubscribeMsgChangeEvent", SubscribeMsgChangeEventItem, parseChangeItemXml),
        } } };
    }
    if (std.mem.eql(u8, common.event, event_subscribe_msg_sent)) {
        return .{ .msg_type = common.msg_type, .event = common.event, .data = .{ .subscribe_msg_sent = .{
            .common = common,
            .events = try parseXmlEventItems(allocator, data, "SubscribeMsgSentEvent", SubscribeMsgSentEventItem, parseSentItemXml),
        } } };
    }
    // 其余 getEvent 分支（交易管理 / 内容安全 / 物流 / 短剧媒资 / 虚拟支付）。
    if (try eventXmlToPushData(allocator, common, data)) |payload| {
        return .{ .msg_type = common.msg_type, .event = common.event, .data = payload };
    }
    return finishRaw(allocator, common, data);
}

/// 解析嵌套事件体 `<EventTag><List><item>…</item></List></EventTag>` 的 `<item>` 列表。
///
/// 每个 `<item>` 内部是扁平结构，外包 `<xml>` 后走 `util_xml` 解析；字段值复制到 allocator。
fn parseXmlEventItems(
    allocator: std.mem.Allocator,
    data: []const u8,
    comptime event_tag: []const u8,
    comptime Item: type,
    comptime parseItemDoc: fn (std.mem.Allocator, util_xml.XmlDoc) std.mem.Allocator.Error!Item,
) ![]Item {
    const open = "<" ++ event_tag ++ ">";
    const close = "</" ++ event_tag ++ ">";
    const start = std.mem.indexOf(u8, data, open) orelse return &.{};
    const block_start = start + open.len;
    const block_end = std.mem.indexOfPos(u8, data, block_start, close) orelse return &.{};
    const block = data[block_start..block_end];

    var items: std.ArrayListUnmanaged(Item) = .empty;
    errdefer items.deinit(allocator);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, block, pos, "<item>")) |item_start| {
        const inner_start = item_start + "<item>".len;
        const item_end = std.mem.indexOfPos(u8, block, inner_start, "</item>") orelse return error.MalformedXml;
        const wrap = try std.fmt.allocPrint(allocator, "<xml>{s}</xml>", .{block[inner_start..item_end]});
        var doc = util_xml.parse(allocator, wrap) catch {
            allocator.free(wrap);
            return error.MalformedXml;
        };
        // 先复制字段（dupe），再释放 doc 与 wrap —— doc 的 value 指向 wrap 内部。
        const item = parseItemDoc(allocator, doc) catch |err| {
            doc.deinit();
            allocator.free(wrap);
            return err;
        };
        doc.deinit();
        allocator.free(wrap);
        try items.append(allocator, item);
        pos = item_end + "</item>".len;
    }
    return items.toOwnedSlice(allocator);
}

fn parsePopupItemXml(allocator: std.mem.Allocator, doc: util_xml.XmlDoc) std.mem.Allocator.Error!SubscribeMsgPopupEventItem {
    return .{
        .template_id = try dupeOrEmpty(allocator, doc.get("TemplateId")),
        .subscribe_status_string = try dupeOrEmpty(allocator, doc.get("SubscribeStatusString")),
        .popup_scene = try dupeOrEmpty(allocator, doc.get("PopupScene")),
    };
}

fn parseChangeItemXml(allocator: std.mem.Allocator, doc: util_xml.XmlDoc) std.mem.Allocator.Error!SubscribeMsgChangeEventItem {
    return .{
        .template_id = try dupeOrEmpty(allocator, doc.get("TemplateId")),
        .subscribe_status_string = try dupeOrEmpty(allocator, doc.get("SubscribeStatusString")),
    };
}

fn parseSentItemXml(allocator: std.mem.Allocator, doc: util_xml.XmlDoc) std.mem.Allocator.Error!SubscribeMsgSentEventItem {
    return .{
        .template_id = try dupeOrEmpty(allocator, doc.get("TemplateId")),
        .msg_id = try dupeOrEmpty(allocator, doc.get("MsgID")),
        .error_code = try dupeOrEmpty(allocator, doc.get("ErrorCode")),
        .error_status = try dupeOrEmpty(allocator, doc.get("ErrorStatus")),
    };
}

fn parsePopupItemsJson(allocator: std.mem.Allocator, list: ?std.json.Value) ![]SubscribeMsgPopupEventItem {
    const items = try jsonListLen(list) orelse return &.{};
    const out = try allocator.alloc(SubscribeMsgPopupEventItem, items);
    switch (list.?) {
        .object => |o| out[0] = try popupItemFromJson(allocator, o),
        .array => |a| for (a.items, 0..) |el, i| {
            out[i] = if (el == .object) try popupItemFromJson(allocator, el.object) else .{};
        },
        else => unreachable,
    }
    return out;
}

fn parseChangeItemsJson(allocator: std.mem.Allocator, list: ?std.json.Value) ![]SubscribeMsgChangeEventItem {
    const items = try jsonListLen(list) orelse return &.{};
    const out = try allocator.alloc(SubscribeMsgChangeEventItem, items);
    switch (list.?) {
        .object => |o| out[0] = try changeItemFromJson(allocator, o),
        .array => |a| for (a.items, 0..) |el, i| {
            out[i] = if (el == .object) try changeItemFromJson(allocator, el.object) else .{};
        },
        else => unreachable,
    }
    return out;
}

fn parseSentItemsJson(allocator: std.mem.Allocator, list: ?std.json.Value) ![]SubscribeMsgSentEventItem {
    const items = try jsonListLen(list) orelse return &.{};
    const out = try allocator.alloc(SubscribeMsgSentEventItem, items);
    switch (list.?) {
        .object => |o| out[0] = try sentItemFromJson(allocator, o),
        .array => |a| for (a.items, 0..) |el, i| {
            out[i] = if (el == .object) try sentItemFromJson(allocator, el.object) else .{};
        },
        else => unreachable,
    }
    return out;
}

/// 对照 Go gjson 行为：`List` 为 object 记 1 项、array 记 N 项，其他 / 缺省为无事件。
fn jsonListLen(list: ?std.json.Value) !?usize {
    const lv = list orelse return null;
    return switch (lv) {
        .object => @as(usize, 1),
        .array => |a| a.items.len,
        else => null,
    };
}

fn popupItemFromJson(allocator: std.mem.Allocator, o: std.json.ObjectMap) !SubscribeMsgPopupEventItem {
    return .{
        .template_id = try dupeOrEmpty(allocator, jsonStr(o.get("TemplateId"))),
        .subscribe_status_string = try dupeOrEmpty(allocator, jsonStr(o.get("SubscribeStatusString"))),
        .popup_scene = try dupeOrEmpty(allocator, jsonStr(o.get("PopupScene"))),
    };
}

fn changeItemFromJson(allocator: std.mem.Allocator, o: std.json.ObjectMap) !SubscribeMsgChangeEventItem {
    return .{
        .template_id = try dupeOrEmpty(allocator, jsonStr(o.get("TemplateId"))),
        .subscribe_status_string = try dupeOrEmpty(allocator, jsonStr(o.get("SubscribeStatusString"))),
    };
}

fn sentItemFromJson(allocator: std.mem.Allocator, o: std.json.ObjectMap) !SubscribeMsgSentEventItem {
    return .{
        .template_id = try dupeOrEmpty(allocator, jsonStr(o.get("TemplateId"))),
        .msg_id = try dupeOrEmpty(allocator, jsonStr(o.get("MsgID"))),
        .error_code = try dupeOrEmpty(allocator, jsonStr(o.get("ErrorCode"))),
        .error_status = try dupeOrEmpty(allocator, jsonStr(o.get("ErrorStatus"))),
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// 其余事件类型的 JSON / XML 分派（对照 Go `getEvent` 的 switch 分支）。
//
// Go 侧的 `unmarshal` 按 dataType 二选一，因此每个事件的两种格式都要支持；
// 字段名与 Go struct tag 逐字对齐（大小写敏感），解析一律忽略未知字段。
// ─────────────────────────────────────────────────────────────────────────────

/// 取子对象：缺省或非 object 时返回 null（对照 Go 嵌套 struct 字段）。
fn subObject(o: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .object => |m| m,
        else => null,
    };
}

fn jsonStrIn(allocator: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) std.mem.Allocator.Error![]const u8 {
    return dupeOrEmpty(allocator, jsonStr(o.get(key)));
}

fn jsonStrSub(allocator: std.mem.Allocator, o: ?std.json.ObjectMap, key: []const u8) std.mem.Allocator.Error![]const u8 {
    const obj = o orelse return dupeOrEmpty(allocator, null);
    return dupeOrEmpty(allocator, jsonStr(obj.get(key)));
}

fn jsonIntSub(o: ?std.json.ObjectMap, key: []const u8) i64 {
    const obj = o orelse return 0;
    return jsonInt(obj.get(key));
}

fn parseWeChatPayInfoJson(allocator: std.mem.Allocator, o: ?std.json.ObjectMap) std.mem.Allocator.Error!WeChatPayInfo {
    return .{
        .mch_order_no = try jsonStrSub(allocator, o, "MchOrderNo"),
        .transaction_id = try jsonStrSub(allocator, o, "TransactionId"),
        .paid_time = jsonIntSub(o, "PaidTime"),
    };
}

fn parseXpayGoodsInfoJson(allocator: std.mem.Allocator, o: ?std.json.ObjectMap) std.mem.Allocator.Error!XpayGoodsInfo {
    return .{
        .product_id = try jsonStrSub(allocator, o, "ProductId"),
        .quantity = jsonIntSub(o, "Quantity"),
        .orig_price = jsonIntSub(o, "OrigPrice"),
        .actual_price = jsonIntSub(o, "ActualPrice"),
        .attach = try jsonStrSub(allocator, o, "Attach"),
    };
}

fn parseXpayCoinInfoJson(allocator: std.mem.Allocator, o: ?std.json.ObjectMap) std.mem.Allocator.Error!XpayCoinInfo {
    return .{
        .quantity = jsonIntSub(o, "Quantity"),
        .orig_price = jsonIntSub(o, "OrigPrice"),
        .actual_price = jsonIntSub(o, "ActualPrice"),
        .attach = try jsonStrSub(allocator, o, "Attach"),
    };
}

fn parseXpayTeamInfoJson(allocator: std.mem.Allocator, o: ?std.json.ObjectMap) std.mem.Allocator.Error!XpayTeamInfo {
    return .{
        .activity_id = try jsonStrSub(allocator, o, "ActivityId"),
        .team_id = try jsonStrSub(allocator, o, "TeamId"),
        .team_type = jsonIntSub(o, "TeamType"),
        .team_action = jsonIntSub(o, "TeamAction"),
    };
}

fn mediaCheckDetailFromJson(allocator: std.mem.Allocator, o: std.json.ObjectMap) !MediaCheckDetail {
    return .{
        .strategy = try jsonStrIn(allocator, o, "strategy"),
        .errcode = jsonInt(o.get("errcode")),
        .suggest = try jsonStrIn(allocator, o, "suggest"),
        .label = jsonInt(o.get("label")),
        .prob = jsonInt(o.get("prob")),
    };
}

fn parseMediaCheckDetailsJson(allocator: std.mem.Allocator, list: ?std.json.Value) ![]MediaCheckDetail {
    const items = try jsonListLen(list) orelse return &.{};
    const out = try allocator.alloc(MediaCheckDetail, items);
    switch (list.?) {
        .object => |o| out[0] = try mediaCheckDetailFromJson(allocator, o),
        .array => |a| for (a.items, 0..) |el, i| {
            out[i] = if (el == .object) try mediaCheckDetailFromJson(allocator, el.object) else .{};
        },
        else => unreachable,
    }
    return out;
}

fn expressActionFromJson(allocator: std.mem.Allocator, o: std.json.ObjectMap) !PushDataAddExpressPathAction {
    return .{
        .action_time = jsonInt(o.get("ActionTime")),
        .action_type = jsonInt(o.get("ActionType")),
        .action_msg = try jsonStrIn(allocator, o, "ActionMsg"),
    };
}

fn parseExpressActionsJson(allocator: std.mem.Allocator, list: ?std.json.Value) ![]PushDataAddExpressPathAction {
    const items = try jsonListLen(list) orelse return &.{};
    const out = try allocator.alloc(PushDataAddExpressPathAction, items);
    switch (list.?) {
        .object => |o| out[0] = try expressActionFromJson(allocator, o),
        .array => |a| for (a.items, 0..) |el, i| {
            out[i] = if (el == .object) try expressActionFromJson(allocator, el.object) else .{};
        },
        else => unreachable,
    }
    return out;
}

/// 解析 Go `getEvent` 中订阅通知三类之外的 12 个事件分支（JSON 路径）。
///
/// 返回 `null` 表示事件类型不在已支持清单内，由调用方回退 `.raw`。
fn eventJsonToPushData(allocator: std.mem.Allocator, common: CommonPushData, obj: std.json.ObjectMap) !?PushData {
    const e = common.event;

    if (std.mem.eql(u8, e, event_trade_manage_remind_access_api)) {
        return .{ .trade_manage_remind_access_api = .{
            .common = common,
            .msg = try jsonStrIn(allocator, obj, "msg"),
        } };
    }
    if (std.mem.eql(u8, e, event_trade_manage_remind_shipping)) {
        return .{ .trade_manage_remind_shipping = .{
            .common = common,
            .transaction_id = try jsonStrIn(allocator, obj, "transaction_id"),
            .merchant_id = try jsonStrIn(allocator, obj, "merchant_id"),
            .sub_merchant_id = try jsonStrIn(allocator, obj, "sub_merchant_id"),
            .merchant_trade_no = try jsonStrIn(allocator, obj, "merchant_trade_no"),
            .pay_time = jsonInt(obj.get("pay_time")),
            .msg = try jsonStrIn(allocator, obj, "msg"),
        } };
    }
    if (std.mem.eql(u8, e, event_trade_manage_order_settlement)) {
        return .{ .trade_manage_order_settlement = .{
            .common = common,
            .transaction_id = try jsonStrIn(allocator, obj, "transaction_id"),
            .merchant_id = try jsonStrIn(allocator, obj, "merchant_id"),
            .sub_merchant_id = try jsonStrIn(allocator, obj, "sub_merchant_id"),
            .merchant_trade_no = try jsonStrIn(allocator, obj, "merchant_trade_no"),
            .pay_time = jsonInt(obj.get("pay_time")),
            .shipped_time = jsonInt(obj.get("shipped_time")),
            .estimated_settlement_time = jsonInt(obj.get("estimated_settlement_time")),
            .confirm_receive_method = jsonInt(obj.get("confirm_receive_method")),
            .confirm_receive_time = jsonInt(obj.get("confirm_receive_time")),
            .settlement_time = jsonInt(obj.get("settlement_time")),
        } };
    }
    if (std.mem.eql(u8, e, event_wxa_media_check)) {
        const result = subObject(obj, "result");
        return .{ .wxa_media_check = .{
            .common = common,
            .appid = try jsonStrIn(allocator, obj, "appid"),
            .trace_id = try jsonStrIn(allocator, obj, "trace_id"),
            .version = jsonInt(obj.get("version")),
            .detail = try parseMediaCheckDetailsJson(allocator, obj.get("detail")),
            .errcode = jsonInt(obj.get("errcode")),
            .errmsg = try jsonStrIn(allocator, obj, "errmsg"),
            .result = .{
                .suggest = try jsonStrSub(allocator, result, "suggest"),
                .label = jsonIntSub(result, "label"),
            },
        } };
    }
    if (std.mem.eql(u8, e, event_add_express_path)) {
        return .{ .add_express_path = .{
            .common = common,
            .delivery_id = try jsonStrIn(allocator, obj, "DeliveryID"),
            .waybill_id = try jsonStrIn(allocator, obj, "WaybillId"),
            .order_id = try jsonStrIn(allocator, obj, "OrderId"),
            .version = jsonInt(obj.get("Version")),
            .count = jsonInt(obj.get("Count")),
            .actions = try parseExpressActionsJson(allocator, obj.get("Actions")),
        } };
    }
    if (std.mem.eql(u8, e, event_secvod_upload)) {
        const ue = subObject(obj, "upload_event");
        return .{ .secvod_upload = .{
            .common = common,
            .upload_event = .{
                .media_id = jsonIntSub(ue, "media_id"),
                .source_context = try jsonStrSub(allocator, ue, "source_context"),
                .errcode = jsonIntSub(ue, "errcode"),
                .errmsg = try jsonStrSub(allocator, ue, "errmsg"),
            },
        } };
    }
    if (std.mem.eql(u8, e, event_secvod_audit)) {
        const ae = subObject(obj, "audit_event");
        const ad = if (ae) |m| subObject(m, "audit_detail") else null;
        return .{ .secvod_audit = .{
            .common = common,
            .audit_event = .{
                .drama_id = jsonIntSub(ae, "drama_id"),
                .source_context = try jsonStrSub(allocator, ae, "source_context"),
                .audit_detail = .{
                    .status = jsonIntSub(ad, "status"),
                    .create_time = jsonIntSub(ad, "create_time"),
                    .audit_time = jsonIntSub(ad, "audit_time"),
                },
            },
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_goods_deliver_notify)) {
        return .{ .xpay_goods_deliver_notify = .{
            .common = common,
            .open_id = try jsonStrIn(allocator, obj, "OpenId"),
            .out_trade_no = try jsonStrIn(allocator, obj, "OutTradeNo"),
            .env = jsonInt(obj.get("Env")),
            .wechat_pay_info = try parseWeChatPayInfoJson(allocator, subObject(obj, "WeChatPayInfo")),
            .goods_info = try parseXpayGoodsInfoJson(allocator, subObject(obj, "GoodsInfo")),
            .team_info = try parseXpayTeamInfoJson(allocator, subObject(obj, "TeamInfo")),
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_coin_pay_notify)) {
        return .{ .xpay_coin_pay_notify = .{
            .common = common,
            .open_id = try jsonStrIn(allocator, obj, "OpenId"),
            .out_trade_no = try jsonStrIn(allocator, obj, "OutTradeNo"),
            .env = jsonInt(obj.get("Env")),
            .wechat_pay_info = try parseWeChatPayInfoJson(allocator, subObject(obj, "WeChatPayInfo")),
            .coin_info = try parseXpayCoinInfoJson(allocator, subObject(obj, "CoinInfo")),
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_refund_notify)) {
        return .{ .xpay_refund_notify = .{
            .common = common,
            .open_id = try jsonStrIn(allocator, obj, "OpenId"),
            .wx_refund_id = try jsonStrIn(allocator, obj, "WxRefundId"),
            .mch_refund_id = try jsonStrIn(allocator, obj, "MchRefundId"),
            .wx_order_id = try jsonStrIn(allocator, obj, "WxOrderId"),
            .mch_order_id = try jsonStrIn(allocator, obj, "MchOrderId"),
            .refund_fee = jsonInt(obj.get("RefundFee")),
            .ret_code = jsonInt(obj.get("RetCode")),
            .ret_msg = try jsonStrIn(allocator, obj, "RetMsg"),
            .refund_start_timestamp = jsonInt(obj.get("RefundStartTimestamp")),
            .refund_succ_timestamp = jsonInt(obj.get("RefundSuccTimestamp")),
            .wxpay_refund_transaction_id = try jsonStrIn(allocator, obj, "WxpayRefundTransactionId"),
            .retry_times = jsonInt(obj.get("RetryTimes")),
            .team_info = try parseXpayTeamInfoJson(allocator, subObject(obj, "TeamInfo")),
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_subscribe_ios_refund_query_notify)) {
        return .{ .xpay_subscribe_ios_refund_query_notify = .{
            .common = common,
            .refund_time = try jsonStrIn(allocator, obj, "refund_time"),
            .order_time = try jsonStrIn(allocator, obj, "order_time"),
            .channel_bill = try jsonStrIn(allocator, obj, "channel_bill"),
            .bundle_id = try jsonStrIn(allocator, obj, "bundleid"),
            .product_id = try jsonStrIn(allocator, obj, "product_id"),
            .p_count = try jsonStrIn(allocator, obj, "p_count"),
            .refund_request_reason = try jsonStrIn(allocator, obj, "refund_request_reason"),
            .provide_status = try jsonStrIn(allocator, obj, "provide_status"),
            .pay_order_id = try jsonStrIn(allocator, obj, "pay_order_id"),
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_complaint_notify)) {
        return .{ .xpay_complaint_notify = .{
            .common = common,
            .open_id = try jsonStrIn(allocator, obj, "OpenId"),
            .wx_order_id = try jsonStrIn(allocator, obj, "WxOrderId"),
            .mch_order_id = try jsonStrIn(allocator, obj, "MchOrderId"),
            .transaction_id = try jsonStrIn(allocator, obj, "TransactionId"),
            .complaint_id = try jsonStrIn(allocator, obj, "ComplaintId"),
            .complaint_detail = try jsonStrIn(allocator, obj, "ComplaintDetail"),
            .complaint_time = jsonInt(obj.get("ComplaintTime")),
            .retry_times = jsonInt(obj.get("RetryTimes")),
            .request_id = try jsonStrIn(allocator, obj, "RequestId"),
        } };
    }
    return null;
}

/// 截取 `<tag>…</tag>` 的首个块内容（不含标签本身），返回指向 `data` 内部的切片。
///
/// 事件体是嵌套 XML，`util_xml` 只支持单层结构，故嵌套子结构一律先按块截取再取字段。
fn xmlBlockInner(data: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag ++ ">";
    const close = "</" ++ tag ++ ">";
    const start = std.mem.indexOf(u8, data, open) orelse return null;
    const inner_start = start + open.len;
    const end = std.mem.indexOfPos(u8, data, inner_start, close) orelse return null;
    return data[inner_start..end];
}

/// 解析标签的整数值（缺省 / 非法一律 0，与 Go 零值一致）。
fn xmlIntIn(data: []const u8, comptime tag: []const u8) i64 {
    const raw = xmlTagValue(data, tag) orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch 0;
}

fn xmlTagInBlock(data: []const u8, comptime block: []const u8, comptime tag: []const u8) ?[]const u8 {
    return xmlTagValue(xmlBlockInner(data, block) orelse return null, tag);
}

fn xmlIntInBlock(data: []const u8, comptime block: []const u8, comptime tag: []const u8) i64 {
    return xmlIntIn(xmlBlockInner(data, block) orelse return 0, tag);
}

/// 取最后一个 `</tag>` 之后的部分。
///
/// 用于 `wxa_media_check`：`<detail>` 块内也有 `<errcode>`，而顶层 `errcode` 出现在
/// 所有 `<detail>` 之后（与 Go 结构体的平铺解码语义一致）。
fn xmlAfterLast(data: []const u8, comptime tag: []const u8) []const u8 {
    const close = "</" ++ tag ++ ">";
    const i = std.mem.lastIndexOf(u8, data, close) orelse return data;
    return data[i + close.len ..];
}

fn parseWeChatPayInfoXml(allocator: std.mem.Allocator, block: ?[]const u8) std.mem.Allocator.Error!WeChatPayInfo {
    const b = block orelse return .{};
    return .{
        .mch_order_no = try dupeOrEmpty(allocator, xmlTagValue(b, "MchOrderNo")),
        .transaction_id = try dupeOrEmpty(allocator, xmlTagValue(b, "TransactionId")),
        .paid_time = xmlIntIn(b, "PaidTime"),
    };
}

fn parseXpayGoodsInfoXml(allocator: std.mem.Allocator, block: ?[]const u8) std.mem.Allocator.Error!XpayGoodsInfo {
    const b = block orelse return .{};
    return .{
        .product_id = try dupeOrEmpty(allocator, xmlTagValue(b, "ProductId")),
        .quantity = xmlIntIn(b, "Quantity"),
        .orig_price = xmlIntIn(b, "OrigPrice"),
        .actual_price = xmlIntIn(b, "ActualPrice"),
        .attach = try dupeOrEmpty(allocator, xmlTagValue(b, "Attach")),
    };
}

fn parseXpayCoinInfoXml(allocator: std.mem.Allocator, block: ?[]const u8) std.mem.Allocator.Error!XpayCoinInfo {
    const b = block orelse return .{};
    return .{
        .quantity = xmlIntIn(b, "Quantity"),
        .orig_price = xmlIntIn(b, "OrigPrice"),
        .actual_price = xmlIntIn(b, "ActualPrice"),
        .attach = try dupeOrEmpty(allocator, xmlTagValue(b, "Attach")),
    };
}

fn parseXpayTeamInfoXml(allocator: std.mem.Allocator, block: ?[]const u8) std.mem.Allocator.Error!XpayTeamInfo {
    const b = block orelse return .{};
    return .{
        .activity_id = try dupeOrEmpty(allocator, xmlTagValue(b, "ActivityId")),
        .team_id = try dupeOrEmpty(allocator, xmlTagValue(b, "TeamId")),
        .team_type = xmlIntIn(b, "TeamType"),
        .team_action = xmlIntIn(b, "TeamAction"),
    };
}

fn docInt(doc: util_xml.XmlDoc, key: []const u8) i64 {
    const v = doc.get(key) orelse return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t\r\n"), 10) catch 0;
}

fn parseExpressActionXml(allocator: std.mem.Allocator, doc: util_xml.XmlDoc) std.mem.Allocator.Error!PushDataAddExpressPathAction {
    return .{
        .action_time = docInt(doc, "ActionTime"),
        .action_type = docInt(doc, "ActionType"),
        .action_msg = try dupeOrEmpty(allocator, doc.get("ActionMsg")),
    };
}

fn parseMediaCheckDetailXml(allocator: std.mem.Allocator, doc: util_xml.XmlDoc) std.mem.Allocator.Error!MediaCheckDetail {
    return .{
        .strategy = try dupeOrEmpty(allocator, doc.get("strategy")),
        .errcode = docInt(doc, "errcode"),
        .suggest = try dupeOrEmpty(allocator, doc.get("suggest")),
        .label = docInt(doc, "label"),
        .prob = docInt(doc, "prob"),
    };
}

/// 解析重复出现的 `<tag>…</tag>` 扁平块，每块外包 `<xml>` 后交 `parseItemDoc` 解析。
///
/// 对照 Go 中 `[]*T \`xml:"Tag"\`` 的语义：同名标签出现几次就是几个元素。
/// 纯空白块（`<Tag></Tag>`）跳过，避免产生一个全零的伪元素。
fn parseXmlRepeatedFlat(
    allocator: std.mem.Allocator,
    data: []const u8,
    comptime tag: []const u8,
    comptime Item: type,
    comptime parseItemDoc: fn (std.mem.Allocator, util_xml.XmlDoc) std.mem.Allocator.Error!Item,
) ![]Item {
    const open = "<" ++ tag ++ ">";
    const close = "</" ++ tag ++ ">";
    var items: std.ArrayListUnmanaged(Item) = .empty;
    errdefer items.deinit(allocator);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, open)) |start| {
        const inner_start = start + open.len;
        const end = std.mem.indexOfPos(u8, data, inner_start, close) orelse return error.MalformedXml;
        pos = end + close.len;
        const inner = data[inner_start..end];
        if (std.mem.trim(u8, inner, " \t\r\n").len == 0) continue;

        const wrap = try std.fmt.allocPrint(allocator, "<xml>{s}</xml>", .{inner});
        var doc = util_xml.parse(allocator, wrap) catch {
            allocator.free(wrap);
            return error.MalformedXml;
        };
        // 先复制字段（dupe），再释放 doc 与 wrap —— doc 的 value 指向 wrap 内部。
        const item = parseItemDoc(allocator, doc) catch |err| {
            doc.deinit();
            allocator.free(wrap);
            return err;
        };
        doc.deinit();
        allocator.free(wrap);
        try items.append(allocator, item);
    }
    return items.toOwnedSlice(allocator);
}

/// 列表块解析：若存在 `<inner>` 子块则按嵌套形态取子块（如 `<Actions><Action>…`），
/// 否则按重复的 `<outer>` 扁平块解析（对照 Go slice 字段的 xml tag）。
fn parseXmlBlockList(
    allocator: std.mem.Allocator,
    data: []const u8,
    comptime outer: []const u8,
    comptime inner: []const u8,
    comptime Item: type,
    comptime parseItemDoc: fn (std.mem.Allocator, util_xml.XmlDoc) std.mem.Allocator.Error!Item,
) ![]Item {
    if (inner.len > 0 and std.mem.indexOf(u8, data, "<" ++ inner ++ ">") != null) {
        return parseXmlRepeatedFlat(allocator, data, inner, Item, parseItemDoc);
    }
    return parseXmlRepeatedFlat(allocator, data, outer, Item, parseItemDoc);
}

/// 解析 Go `getEvent` 中订阅通知三类之外的 12 个事件分支（XML 路径）。
///
/// 返回 `null` 表示事件类型不在已支持清单内，由调用方回退 `.raw`。
fn eventXmlToPushData(allocator: std.mem.Allocator, common: CommonPushData, data: []const u8) !?PushData {
    const e = common.event;

    if (std.mem.eql(u8, e, event_trade_manage_remind_access_api)) {
        return .{ .trade_manage_remind_access_api = .{
            .common = common,
            .msg = try dupeOrEmpty(allocator, xmlTagValue(data, "msg")),
        } };
    }
    if (std.mem.eql(u8, e, event_trade_manage_remind_shipping)) {
        return .{ .trade_manage_remind_shipping = .{
            .common = common,
            .transaction_id = try dupeOrEmpty(allocator, xmlTagValue(data, "transaction_id")),
            .merchant_id = try dupeOrEmpty(allocator, xmlTagValue(data, "merchant_id")),
            .sub_merchant_id = try dupeOrEmpty(allocator, xmlTagValue(data, "sub_merchant_id")),
            .merchant_trade_no = try dupeOrEmpty(allocator, xmlTagValue(data, "merchant_trade_no")),
            .pay_time = xmlIntIn(data, "pay_time"),
            .msg = try dupeOrEmpty(allocator, xmlTagValue(data, "msg")),
        } };
    }
    if (std.mem.eql(u8, e, event_trade_manage_order_settlement)) {
        return .{ .trade_manage_order_settlement = .{
            .common = common,
            .transaction_id = try dupeOrEmpty(allocator, xmlTagValue(data, "transaction_id")),
            .merchant_id = try dupeOrEmpty(allocator, xmlTagValue(data, "merchant_id")),
            .sub_merchant_id = try dupeOrEmpty(allocator, xmlTagValue(data, "sub_merchant_id")),
            .merchant_trade_no = try dupeOrEmpty(allocator, xmlTagValue(data, "merchant_trade_no")),
            .pay_time = xmlIntIn(data, "pay_time"),
            .shipped_time = xmlIntIn(data, "shipped_time"),
            .estimated_settlement_time = xmlIntIn(data, "estimated_settlement_time"),
            .confirm_receive_method = xmlIntIn(data, "confirm_receive_method"),
            .confirm_receive_time = xmlIntIn(data, "confirm_receive_time"),
            .settlement_time = xmlIntIn(data, "settlement_time"),
        } };
    }
    if (std.mem.eql(u8, e, event_wxa_media_check)) {
        const result = xmlBlockInner(data, "result");
        const tail = xmlAfterLast(data, "detail");
        return .{ .wxa_media_check = .{
            .common = common,
            .appid = try dupeOrEmpty(allocator, xmlTagValue(data, "appid")),
            .trace_id = try dupeOrEmpty(allocator, xmlTagValue(data, "trace_id")),
            .version = xmlIntIn(data, "version"),
            .detail = try parseXmlBlockList(allocator, data, "detail", "", MediaCheckDetail, parseMediaCheckDetailXml),
            .errcode = xmlIntIn(tail, "errcode"),
            .errmsg = try dupeOrEmpty(allocator, xmlTagValue(tail, "errmsg")),
            .result = .{
                .suggest = try dupeOrEmpty(allocator, if (result) |b| xmlTagValue(b, "suggest") else null),
                .label = if (result) |b| xmlIntIn(b, "label") else 0,
            },
        } };
    }
    if (std.mem.eql(u8, e, event_add_express_path)) {
        return .{ .add_express_path = .{
            .common = common,
            .delivery_id = try dupeOrEmpty(allocator, xmlTagValue(data, "DeliveryID")),
            .waybill_id = try dupeOrEmpty(allocator, xmlTagValue(data, "WaybillId")),
            .order_id = try dupeOrEmpty(allocator, xmlTagValue(data, "OrderId")),
            .version = xmlIntIn(data, "Version"),
            .count = xmlIntIn(data, "Count"),
            .actions = try parseXmlBlockList(allocator, data, "Actions", "Action", PushDataAddExpressPathAction, parseExpressActionXml),
        } };
    }
    if (std.mem.eql(u8, e, event_secvod_upload)) {
        return .{ .secvod_upload = .{
            .common = common,
            .upload_event = .{
                .media_id = xmlIntInBlock(data, "upload_event", "media_id"),
                .source_context = try dupeOrEmpty(allocator, xmlTagInBlock(data, "upload_event", "source_context")),
                .errcode = xmlIntInBlock(data, "upload_event", "errcode"),
                .errmsg = try dupeOrEmpty(allocator, xmlTagInBlock(data, "upload_event", "errmsg")),
            },
        } };
    }
    if (std.mem.eql(u8, e, event_secvod_audit)) {
        return .{ .secvod_audit = .{
            .common = common,
            .audit_event = .{
                .drama_id = xmlIntInBlock(data, "audit_event", "drama_id"),
                .source_context = try dupeOrEmpty(allocator, xmlTagInBlock(data, "audit_event", "source_context")),
                .audit_detail = .{
                    .status = xmlIntInBlock(data, "audit_detail", "status"),
                    .create_time = xmlIntInBlock(data, "audit_detail", "create_time"),
                    .audit_time = xmlIntInBlock(data, "audit_detail", "audit_time"),
                },
            },
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_goods_deliver_notify)) {
        return .{ .xpay_goods_deliver_notify = .{
            .common = common,
            .open_id = try dupeOrEmpty(allocator, xmlTagValue(data, "OpenId")),
            .out_trade_no = try dupeOrEmpty(allocator, xmlTagValue(data, "OutTradeNo")),
            .env = xmlIntIn(data, "Env"),
            .wechat_pay_info = try parseWeChatPayInfoXml(allocator, xmlBlockInner(data, "WeChatPayInfo")),
            .goods_info = try parseXpayGoodsInfoXml(allocator, xmlBlockInner(data, "GoodsInfo")),
            .team_info = try parseXpayTeamInfoXml(allocator, xmlBlockInner(data, "TeamInfo")),
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_coin_pay_notify)) {
        return .{ .xpay_coin_pay_notify = .{
            .common = common,
            .open_id = try dupeOrEmpty(allocator, xmlTagValue(data, "OpenId")),
            .out_trade_no = try dupeOrEmpty(allocator, xmlTagValue(data, "OutTradeNo")),
            .env = xmlIntIn(data, "Env"),
            .wechat_pay_info = try parseWeChatPayInfoXml(allocator, xmlBlockInner(data, "WeChatPayInfo")),
            .coin_info = try parseXpayCoinInfoXml(allocator, xmlBlockInner(data, "CoinInfo")),
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_refund_notify)) {
        return .{ .xpay_refund_notify = .{
            .common = common,
            .open_id = try dupeOrEmpty(allocator, xmlTagValue(data, "OpenId")),
            .wx_refund_id = try dupeOrEmpty(allocator, xmlTagValue(data, "WxRefundId")),
            .mch_refund_id = try dupeOrEmpty(allocator, xmlTagValue(data, "MchRefundId")),
            .wx_order_id = try dupeOrEmpty(allocator, xmlTagValue(data, "WxOrderId")),
            .mch_order_id = try dupeOrEmpty(allocator, xmlTagValue(data, "MchOrderId")),
            .refund_fee = xmlIntIn(data, "RefundFee"),
            .ret_code = xmlIntIn(data, "RetCode"),
            .ret_msg = try dupeOrEmpty(allocator, xmlTagValue(data, "RetMsg")),
            .refund_start_timestamp = xmlIntIn(data, "RefundStartTimestamp"),
            .refund_succ_timestamp = xmlIntIn(data, "RefundSuccTimestamp"),
            .wxpay_refund_transaction_id = try dupeOrEmpty(allocator, xmlTagValue(data, "WxpayRefundTransactionId")),
            .retry_times = xmlIntIn(data, "RetryTimes"),
            .team_info = try parseXpayTeamInfoXml(allocator, xmlBlockInner(data, "TeamInfo")),
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_subscribe_ios_refund_query_notify)) {
        return .{ .xpay_subscribe_ios_refund_query_notify = .{
            .common = common,
            .refund_time = try dupeOrEmpty(allocator, xmlTagValue(data, "refund_time")),
            .order_time = try dupeOrEmpty(allocator, xmlTagValue(data, "order_time")),
            .channel_bill = try dupeOrEmpty(allocator, xmlTagValue(data, "channel_bill")),
            .bundle_id = try dupeOrEmpty(allocator, xmlTagValue(data, "bundleid")),
            .product_id = try dupeOrEmpty(allocator, xmlTagValue(data, "product_id")),
            .p_count = try dupeOrEmpty(allocator, xmlTagValue(data, "p_count")),
            .refund_request_reason = try dupeOrEmpty(allocator, xmlTagValue(data, "refund_request_reason")),
            .provide_status = try dupeOrEmpty(allocator, xmlTagValue(data, "provide_status")),
            .pay_order_id = try dupeOrEmpty(allocator, xmlTagValue(data, "pay_order_id")),
        } };
    }
    if (std.mem.eql(u8, e, event_xpay_complaint_notify)) {
        return .{ .xpay_complaint_notify = .{
            .common = common,
            .open_id = try dupeOrEmpty(allocator, xmlTagValue(data, "OpenId")),
            .wx_order_id = try dupeOrEmpty(allocator, xmlTagValue(data, "WxOrderId")),
            .mch_order_id = try dupeOrEmpty(allocator, xmlTagValue(data, "MchOrderId")),
            .transaction_id = try dupeOrEmpty(allocator, xmlTagValue(data, "TransactionId")),
            .complaint_id = try dupeOrEmpty(allocator, xmlTagValue(data, "ComplaintId")),
            .complaint_detail = try dupeOrEmpty(allocator, xmlTagValue(data, "ComplaintDetail")),
            .complaint_time = xmlIntIn(data, "ComplaintTime"),
            .retry_times = xmlIntIn(data, "RetryTimes"),
            .request_id = try dupeOrEmpty(allocator, xmlTagValue(data, "RequestId")),
        } };
    }
    return null;
}

fn jsonStr(v: ?std.json.Value) []const u8 {
    if (v) |val| {
        if (val == .string) return val.string;
    }
    return "";
}

fn jsonInt(v: ?std.json.Value) i64 {
    if (v) |val| {
        switch (val) {
            .integer => |i| return i,
            // CreateTime 个别场景以字符串时间戳下发，兼容之。
            .string => |s| return std.fmt.parseInt(i64, s, 10) catch 0,
            else => {},
        }
    }
    return 0;
}

fn dupeOrEmpty(allocator: std.mem.Allocator, s: ?[]const u8) std.mem.Allocator.Error![]const u8 {
    return allocator.dupe(u8, s orelse "");
}

/// 在 XML 文本中查找 `<tag>` 的值（CDATA 或纯文本），返回指向 `data` 内部的切片。
///
/// 仅用于微信推送的扁平头部字段；同名多标签时取首个，不支持嵌套。
fn xmlTagValue(data: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag ++ ">";
    const close = "</" ++ tag ++ ">";
    const start = std.mem.indexOf(u8, data, open) orelse return null;
    var pos = start + open.len;
    if (std.mem.startsWith(u8, data[pos..], "<![CDATA[")) {
        pos += "<![CDATA[".len;
        const end = std.mem.indexOfPos(u8, data, pos, "]]>") orelse return null;
        return data[pos..end];
    }
    const end = std.mem.indexOfPos(u8, data, pos, close) orelse return null;
    return data[pos..end];
}

test "PushReceiver JSON 弹窗事件：List 为数组" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\{"ToUserName":"gh_123456789abc","FromUserName":"oABCDw1c8M9npEeo1uA8SJfu4pB0",
        \\ "CreateTime":1610969445,"MsgType":"event","Event":"subscribe_msg_popup_event",
        \\ "List":[{"TemplateId":"tpl_push_demo1","SubscribeStatusString":"accept","PopupScene":"SCENE_SUBSCRIBE"},
        \\         {"TemplateId":"tpl_push_demo2","SubscribeStatusString":"reject","PopupScene":""}]}
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .json);
    try std.testing.expectEqualStrings("event", got.msg_type);
    try std.testing.expectEqualStrings(event_subscribe_popup, got.event);
    const popup = got.data.subscribe_msg_popup;
    try std.testing.expectEqualStrings("gh_123456789abc", popup.common.to_user_name);
    try std.testing.expectEqualStrings("oABCDw1c8M9npEeo1uA8SJfu4pB0", popup.common.from_user_name);
    try std.testing.expectEqual(@as(i64, 1610969445), popup.common.create_time);
    const events = popup.getSubscribeMsgPopupEvents();
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("tpl_push_demo1", events[0].template_id);
    try std.testing.expectEqualStrings("accept", events[0].subscribe_status_string);
    try std.testing.expectEqualStrings("SCENE_SUBSCRIBE", events[0].popup_scene);
    try std.testing.expectEqualStrings("reject", events[1].subscribe_status_string);
}

test "PushReceiver JSON 弹窗事件：List 为单个 object（对照 Go gjson IsObject 分支）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":"1610969446",
        \\ "MsgType":"event","Event":"subscribe_msg_popup_event",
        \\ "List":{"TemplateId":"tpl_single","SubscribeStatusString":"accept","PopupScene":"SCENE_SHEET"}}
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .json);
    const events = got.data.subscribe_msg_popup.events;
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("tpl_single", events[0].template_id);
    // CreateTime 字符串时间戳兼容。
    try std.testing.expectEqual(@as(i64, 1610969446), got.data.subscribe_msg_popup.common.create_time);
}

test "PushReceiver JSON change / sent 事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = PushReceiver.init();

    const change =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1610969500,"MsgType":"event",
        \\ "Event":"subscribe_msg_change_event","List":[{"TemplateId":"tpl_c","SubscribeStatusString":"reject"}]}
    ;
    const got_change = try r.getMsgData(alloc, change, .json);
    const change_events = got_change.data.subscribe_msg_change.events;
    try std.testing.expectEqual(@as(usize, 1), change_events.len);
    try std.testing.expectEqualStrings("tpl_c", change_events[0].template_id);
    try std.testing.expectEqualStrings("reject", change_events[0].subscribe_status_string);

    const sent =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1610969600,"MsgType":"event",
        \\ "Event":"subscribe_msg_sent_event","List":[{"TemplateId":"tpl_s","MsgID":"12345","ErrorCode":"0","ErrorStatus":"ok"}]}
    ;
    const got_sent = try r.getMsgData(alloc, sent, .json);
    const sent_events = got_sent.data.subscribe_msg_sent.events;
    try std.testing.expectEqual(@as(usize, 1), sent_events.len);
    try std.testing.expectEqualStrings("tpl_s", sent_events[0].template_id);
    try std.testing.expectEqualStrings("12345", sent_events[0].msg_id);
    try std.testing.expectEqualStrings("0", sent_events[0].error_code);
    try std.testing.expectEqualStrings("ok", sent_events[0].error_status);
}

test "PushReceiver JSON 非事件消息与未知事件返回 raw 明文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = PushReceiver.init();

    const text_msg = "{\"ToUserName\":\"gh_x\",\"FromUserName\":\"oX\",\"CreateTime\":1,\"MsgType\":\"text\",\"Content\":\"hi\"}";
    const got_text = try r.getMsgData(alloc, text_msg, .json);
    try std.testing.expectEqualStrings("text", got_text.msg_type);
    try std.testing.expect(std.mem.indexOf(u8, got_text.data.raw, "\"Content\":\"hi\"") != null);

    const unknown_event =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1,"MsgType":"event",
        \\ "Event":"user_enter_tempsession","SessionFrom":"session-from"}
    ;
    const got_unknown = try r.getMsgData(alloc, unknown_event, .json);
    try std.testing.expectEqualStrings("event", got_unknown.msg_type);
    try std.testing.expectEqualStrings("user_enter_tempsession", got_unknown.event);
    try std.testing.expect(std.mem.indexOf(u8, got_unknown.data.raw, "user_enter_tempsession") != null);

    try std.testing.expectError(util_error.WechatError.DecodeError, r.getMsgData(alloc, "not-json", .json));
}

test "PushReceiver XML 弹窗事件：嵌套 SubscribeMsgPopupEvent 解析 item 列表" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_123456789abc]]></ToUserName>
        \\  <FromUserName><![CDATA[oABCDw1c8M9npEeo1uA8SJfu4pB0]]></FromUserName>
        \\  <CreateTime>1610969445</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[subscribe_msg_popup_event]]></Event>
        \\  <SubscribeMsgPopupEvent>
        \\    <List>
        \\      <item>
        \\        <TemplateId><![CDATA[tpl_xml_1]]></TemplateId>
        \\        <SubscribeStatusString><![CDATA[accept]]></SubscribeStatusString>
        \\        <PopupScene><![CDATA[SCENE_SUBSCRIBE]]></PopupScene>
        \\      </item>
        \\      <item>
        \\        <TemplateId><![CDATA[tpl_xml_2]]></TemplateId>
        \\        <SubscribeStatusString><![CDATA[reject]]></SubscribeStatusString>
        \\        <PopupScene><![CDATA[]]></PopupScene>
        \\      </item>
        \\    </List>
        \\  </SubscribeMsgPopupEvent>
        \\</xml>
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .xml);
    try std.testing.expectEqualStrings(event_subscribe_popup, got.event);
    const popup = got.data.subscribe_msg_popup;
    try std.testing.expectEqualStrings("gh_123456789abc", popup.common.to_user_name);
    try std.testing.expectEqual(@as(i64, 1610969445), popup.common.create_time);
    const events = popup.getSubscribeMsgPopupEvents();
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("tpl_xml_1", events[0].template_id);
    try std.testing.expectEqualStrings("accept", events[0].subscribe_status_string);
    try std.testing.expectEqualStrings("SCENE_SUBSCRIBE", events[0].popup_scene);
    try std.testing.expectEqualStrings("tpl_xml_2", events[1].template_id);
    try std.testing.expectEqualStrings("", events[1].popup_scene);
}

test "PushReceiver XML change / sent 事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = PushReceiver.init();

    const change =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1610969500</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[subscribe_msg_change_event]]></Event>
        \\  <SubscribeMsgChangeEvent>
        \\    <List>
        \\      <item>
        \\        <TemplateId><![CDATA[tpl_change]]></TemplateId>
        \\        <SubscribeStatusString><![CDATA[reject]]></SubscribeStatusString>
        \\      </item>
        \\    </List>
        \\  </SubscribeMsgChangeEvent>
        \\</xml>
    ;
    const got_change = try r.getMsgData(alloc, change, .xml);
    const change_events = got_change.data.subscribe_msg_change.events;
    try std.testing.expectEqual(@as(usize, 1), change_events.len);
    try std.testing.expectEqualStrings("tpl_change", change_events[0].template_id);
    try std.testing.expectEqualStrings("reject", change_events[0].subscribe_status_string);

    const sent =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1610969600</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[subscribe_msg_sent_event]]></Event>
        \\  <SubscribeMsgSentEvent>
        \\    <List>
        \\      <item>
        \\        <TemplateId><![CDATA[tpl_sent]]></TemplateId>
        \\        <MsgID><![CDATA[12345]]></MsgID>
        \\        <ErrorCode><![CDATA[0]]></ErrorCode>
        \\        <ErrorStatus><![CDATA[ok]]></ErrorStatus>
        \\      </item>
        \\    </List>
        \\  </SubscribeMsgSentEvent>
        \\</xml>
    ;
    const got_sent = try r.getMsgData(alloc, sent, .xml);
    const sent_events = got_sent.data.subscribe_msg_sent.events;
    try std.testing.expectEqual(@as(usize, 1), sent_events.len);
    try std.testing.expectEqualStrings("tpl_sent", sent_events[0].template_id);
    try std.testing.expectEqualStrings("12345", sent_events[0].msg_id);
    try std.testing.expectEqualStrings("0", sent_events[0].error_code);
    try std.testing.expectEqualStrings("ok", sent_events[0].error_status);
}

test "PushReceiver XML 未知事件返回 raw 明文" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1610969700</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[user_enter_tempsession]]></Event>
        \\  <SessionFrom><![CDATA[session-from]]></SessionFrom>
        \\</xml>
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .xml);
    try std.testing.expectEqualStrings("event", got.msg_type);
    try std.testing.expectEqualStrings("user_enter_tempsession", got.event);
    try std.testing.expect(std.mem.indexOf(u8, got.data.raw, "<![CDATA[session-from]]>") != null);
}

// ─────────────────────────────────────────────────────────────────────────────
// 其余 12 类事件（对照 Go getEvent 的 15 个 case 减去已实现的订阅通知三类）。
// ─────────────────────────────────────────────────────────────────────────────

test "PushReceiver JSON 交易管理三类事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const remind_api =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000001,"MsgType":"event",
        \\ "Event":"trade_manage_remind_access_api","msg":"please upload shipping info"}
    ;
    const got_api = try r.getMsgData(alloc, remind_api, .json);
    const api = got_api.data.trade_manage_remind_access_api;
    try std.testing.expectEqualStrings("gh_x", api.common.to_user_name);
    try std.testing.expectEqualStrings("oX", api.common.from_user_name);
    try std.testing.expectEqual(@as(i64, 1700000001), api.common.create_time);
    try std.testing.expectEqualStrings("event", api.common.msg_type);
    try std.testing.expectEqualStrings("please upload shipping info", api.msg);

    const remind_shipping =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000002,"MsgType":"event",
        \\ "Event":"trade_manage_remind_shipping","transaction_id":"4200001234","merchant_id":"1900000109",
        \\ "sub_merchant_id":"","merchant_trade_no":"MCH1234","pay_time":1700000000,"msg":"请上传发货信息"}
    ;
    const got_ship = try r.getMsgData(alloc, remind_shipping, .json);
    const ship = got_ship.data.trade_manage_remind_shipping;
    try std.testing.expectEqualStrings("4200001234", ship.transaction_id);
    try std.testing.expectEqualStrings("1900000109", ship.merchant_id);
    try std.testing.expectEqualStrings("", ship.sub_merchant_id);
    try std.testing.expectEqualStrings("MCH1234", ship.merchant_trade_no);
    try std.testing.expectEqual(@as(i64, 1700000000), ship.pay_time);
    try std.testing.expectEqualStrings("请上传发货信息", ship.msg);

    const settlement =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000003,"MsgType":"event",
        \\ "Event":"trade_manage_order_settlement","transaction_id":"4200001234","merchant_id":"1900000109",
        \\ "sub_merchant_id":"","merchant_trade_no":"MCH1234","pay_time":1699990000,"shipped_time":1699990500,
        \\ "estimated_settlement_time":0,"confirm_receive_method":2,"confirm_receive_time":1699991000,
        \\ "settlement_time":1699991100}
    ;
    const got_st = try r.getMsgData(alloc, settlement, .json);
    const st = got_st.data.trade_manage_order_settlement;
    try std.testing.expectEqualStrings("4200001234", st.transaction_id);
    try std.testing.expectEqualStrings("1900000109", st.merchant_id);
    try std.testing.expectEqualStrings("MCH1234", st.merchant_trade_no);
    try std.testing.expectEqual(@as(i64, 1699990000), st.pay_time);
    try std.testing.expectEqual(@as(i64, 1699990500), st.shipped_time);
    try std.testing.expectEqual(@as(i64, 0), st.estimated_settlement_time);
    try std.testing.expectEqual(@as(i64, 2), st.confirm_receive_method);
    try std.testing.expectEqual(@as(i64, 1699991000), st.confirm_receive_time);
    try std.testing.expectEqual(@as(i64, 1699991100), st.settlement_time);
    try std.testing.expect(st.isManualConfirmReceive());
    try std.testing.expect(!st.isAutoConfirmReceive());
}

test "PushReceiver XML 交易管理三类事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const remind_api =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000001</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[trade_manage_remind_access_api]]></Event>
        \\  <msg><![CDATA[please upload shipping info]]></msg>
        \\</xml>
    ;
    const got_api = try r.getMsgData(alloc, remind_api, .xml);
    const api = got_api.data.trade_manage_remind_access_api;
    try std.testing.expectEqualStrings("gh_x", api.common.to_user_name);
    try std.testing.expectEqual(@as(i64, 1700000001), api.common.create_time);
    try std.testing.expectEqualStrings("please upload shipping info", api.msg);

    const remind_shipping =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000002</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[trade_manage_remind_shipping]]></Event>
        \\  <transaction_id><![CDATA[4200001234]]></transaction_id>
        \\  <merchant_id><![CDATA[1900000109]]></merchant_id>
        \\  <sub_merchant_id><![CDATA[]]></sub_merchant_id>
        \\  <merchant_trade_no><![CDATA[MCH1234]]></merchant_trade_no>
        \\  <pay_time>1700000000</pay_time>
        \\  <msg><![CDATA[请上传发货信息]]></msg>
        \\</xml>
    ;
    const got_ship = try r.getMsgData(alloc, remind_shipping, .xml);
    const ship = got_ship.data.trade_manage_remind_shipping;
    try std.testing.expectEqualStrings("4200001234", ship.transaction_id);
    try std.testing.expectEqualStrings("1900000109", ship.merchant_id);
    try std.testing.expectEqualStrings("", ship.sub_merchant_id);
    try std.testing.expectEqualStrings("MCH1234", ship.merchant_trade_no);
    try std.testing.expectEqual(@as(i64, 1700000000), ship.pay_time);
    try std.testing.expectEqualStrings("请上传发货信息", ship.msg);

    const settlement =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000003</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[trade_manage_order_settlement]]></Event>
        \\  <transaction_id><![CDATA[4200001234]]></transaction_id>
        \\  <merchant_id><![CDATA[1900000109]]></merchant_id>
        \\  <sub_merchant_id><![CDATA[]]></sub_merchant_id>
        \\  <merchant_trade_no><![CDATA[MCH1234]]></merchant_trade_no>
        \\  <pay_time>1699990000</pay_time>
        \\  <shipped_time>1699990500</shipped_time>
        \\  <estimated_settlement_time>1699990600</estimated_settlement_time>
        \\  <confirm_receive_method>1</confirm_receive_method>
        \\  <confirm_receive_time>1699991000</confirm_receive_time>
        \\  <settlement_time>1699991100</settlement_time>
        \\</xml>
    ;
    const got_st = try r.getMsgData(alloc, settlement, .xml);
    const st = got_st.data.trade_manage_order_settlement;
    try std.testing.expectEqualStrings("4200001234", st.transaction_id);
    try std.testing.expectEqual(@as(i64, 1699990000), st.pay_time);
    try std.testing.expectEqual(@as(i64, 1699990500), st.shipped_time);
    try std.testing.expectEqual(@as(i64, 1699990600), st.estimated_settlement_time);
    try std.testing.expectEqual(@as(i64, 1), st.confirm_receive_method);
    try std.testing.expectEqual(@as(i64, 1699991000), st.confirm_receive_time);
    try std.testing.expectEqual(@as(i64, 1699991100), st.settlement_time);
    try std.testing.expect(st.isAutoConfirmReceive());
    try std.testing.expect(!st.isManualConfirmReceive());
}

test "PushReceiver JSON 内容安全媒体异步检测结果" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000010,"MsgType":"event",
        \\ "Event":"wxa_media_check","appid":"wx123456","trace_id":"trace-abc","version":2,
        \\ "detail":[{"strategy":"content_model","errcode":0,"suggest":"risky","label":20001,"prob":90},
        \\           {"strategy":"keyword","errcode":0,"suggest":"pass","label":100,"prob":50}],
        \\ "errcode":0,"errmsg":"ok","result":{"suggest":"risky","label":20001}}
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .json);
    const check = got.data.wxa_media_check;
    try std.testing.expectEqualStrings("gh_x", check.common.to_user_name);
    try std.testing.expectEqual(@as(i64, 1700000010), check.common.create_time);
    try std.testing.expectEqualStrings("wx123456", check.appid);
    try std.testing.expectEqualStrings("trace-abc", check.trace_id);
    try std.testing.expectEqual(@as(i64, 2), check.version);
    try std.testing.expectEqual(@as(usize, 2), check.detail.len);
    try std.testing.expectEqualStrings("content_model", check.detail[0].strategy);
    try std.testing.expectEqual(@as(i64, 0), check.detail[0].errcode);
    try std.testing.expectEqualStrings("risky", check.detail[0].suggest);
    try std.testing.expectEqual(@as(i64, 20001), check.detail[0].label);
    try std.testing.expectEqual(@as(i64, 90), check.detail[0].prob);
    try std.testing.expectEqualStrings("keyword", check.detail[1].strategy);
    try std.testing.expectEqualStrings("pass", check.detail[1].suggest);
    try std.testing.expectEqual(@as(i64, 0), check.errcode);
    try std.testing.expectEqualStrings("ok", check.errmsg);
    try std.testing.expectEqualStrings("risky", check.result.suggest);
    try std.testing.expectEqual(@as(i64, 20001), check.result.label);
    try std.testing.expect(check.isRisky());
    try std.testing.expect(!check.isPass());
    try std.testing.expect(check.hasRiskyDetail());
}

test "PushReceiver XML 内容安全媒体异步检测结果" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000010</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[wxa_media_check]]></Event>
        \\  <appid><![CDATA[wx123456]]></appid>
        \\  <trace_id><![CDATA[trace-abc]]></trace_id>
        \\  <version>2</version>
        \\  <detail>
        \\    <strategy>content_model</strategy>
        \\    <errcode>87014</errcode>
        \\    <suggest>pass</suggest>
        \\    <label>100</label>
        \\    <prob>50</prob>
        \\  </detail>
        \\  <detail>
        \\    <strategy>keyword</strategy>
        \\    <errcode>0</errcode>
        \\    <suggest>risky</suggest>
        \\    <label>20001</label>
        \\    <prob>90</prob>
        \\  </detail>
        \\  <errcode>0</errcode>
        \\  <errmsg><![CDATA[ok]]></errmsg>
        \\  <result>
        \\    <suggest>pass</suggest>
        \\    <label>100</label>
        \\  </result>
        \\</xml>
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .xml);
    const check = got.data.wxa_media_check;
    try std.testing.expectEqualStrings("gh_x", check.common.to_user_name);
    try std.testing.expectEqualStrings("wx123456", check.appid);
    try std.testing.expectEqualStrings("trace-abc", check.trace_id);
    try std.testing.expectEqual(@as(i64, 2), check.version);
    try std.testing.expectEqual(@as(usize, 2), check.detail.len);
    try std.testing.expectEqualStrings("content_model", check.detail[0].strategy);
    try std.testing.expectEqual(@as(i64, 87014), check.detail[0].errcode);
    try std.testing.expectEqualStrings("pass", check.detail[0].suggest);
    try std.testing.expectEqual(@as(i64, 50), check.detail[0].prob);
    try std.testing.expectEqualStrings("keyword", check.detail[1].strategy);
    try std.testing.expectEqual(@as(i64, 0), check.detail[1].errcode);
    try std.testing.expectEqualStrings("risky", check.detail[1].suggest);
    try std.testing.expectEqual(@as(i64, 20001), check.detail[1].label);
    try std.testing.expectEqual(@as(i64, 90), check.detail[1].prob);
    // 顶层 errcode 不能被 <detail> 内的同名标签（87014）污染。
    try std.testing.expectEqual(@as(i64, 0), check.errcode);
    try std.testing.expectEqualStrings("ok", check.errmsg);
    try std.testing.expectEqualStrings("pass", check.result.suggest);
    try std.testing.expectEqual(@as(i64, 100), check.result.label);
    try std.testing.expect(check.isPass());
    try std.testing.expect(!check.isRisky());
    try std.testing.expect(check.hasRiskyDetail());
}

test "PushReceiver JSON 运单轨迹更新事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000020,"MsgType":"event",
        \\ "Event":"add_express_path","DeliveryID":"SF","WaybillId":"SF1234567890","OrderId":"ORDER-1",
        \\ "Version":3,"Count":2,
        \\ "Actions":[{"ActionTime":1700000000,"ActionType":100001,"ActionMsg":"已揽收"},
        \\            {"ActionTime":1700000100,"ActionType":100002,"ActionMsg":"运输中"}]}
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .json);
    const express = got.data.add_express_path;
    try std.testing.expectEqualStrings("gh_x", express.common.to_user_name);
    try std.testing.expectEqualStrings("SF", express.delivery_id);
    try std.testing.expectEqualStrings("SF1234567890", express.waybill_id);
    try std.testing.expectEqualStrings("ORDER-1", express.order_id);
    try std.testing.expectEqual(@as(i64, 3), express.version);
    try std.testing.expectEqual(@as(i64, 2), express.count);
    const actions = express.getActions();
    try std.testing.expectEqual(@as(usize, 2), actions.len);
    try std.testing.expectEqual(@as(i64, 1700000000), actions[0].action_time);
    try std.testing.expectEqual(@as(i64, 100001), actions[0].action_type);
    try std.testing.expectEqualStrings("已揽收", actions[0].action_msg);
    try std.testing.expectEqual(@as(i64, 100002), actions[1].action_type);
    try std.testing.expectEqualStrings("运输中", actions[1].action_msg);
}

test "PushReceiver XML 运单轨迹更新事件：重复 Actions 块与内嵌 Action 块" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    // 形态一：重复 `<Actions>` 扁平块（对照 Go `[]*T \`xml:"Actions"\`` 的解码语义）。
    const repeated =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000020</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[add_express_path]]></Event>
        \\  <DeliveryID><![CDATA[SF]]></DeliveryID>
        \\  <WaybillId><![CDATA[SF1234567890]]></WaybillId>
        \\  <OrderId><![CDATA[ORDER-1]]></OrderId>
        \\  <Version>3</Version>
        \\  <Count>2</Count>
        \\  <Actions>
        \\    <ActionTime>1700000000</ActionTime>
        \\    <ActionType>100001</ActionType>
        \\    <ActionMsg><![CDATA[已揽收]]></ActionMsg>
        \\  </Actions>
        \\  <Actions>
        \\    <ActionTime>1700000100</ActionTime>
        \\    <ActionType>100002</ActionType>
        \\    <ActionMsg><![CDATA[运输中]]></ActionMsg>
        \\  </Actions>
        \\</xml>
    ;
    const got1 = try r.getMsgData(alloc, repeated, .xml);
    const e1 = got1.data.add_express_path;
    try std.testing.expectEqualStrings("SF", e1.delivery_id);
    try std.testing.expectEqualStrings("SF1234567890", e1.waybill_id);
    try std.testing.expectEqualStrings("ORDER-1", e1.order_id);
    try std.testing.expectEqual(@as(i64, 3), e1.version);
    try std.testing.expectEqual(@as(i64, 2), e1.count);
    try std.testing.expectEqual(@as(usize, 2), e1.getActions().len);
    try std.testing.expectEqual(@as(i64, 1700000000), e1.actions[0].action_time);
    try std.testing.expectEqual(@as(i64, 100001), e1.actions[0].action_type);
    try std.testing.expectEqualStrings("已揽收", e1.actions[0].action_msg);
    try std.testing.expectEqualStrings("运输中", e1.actions[1].action_msg);

    // 形态二：`<Actions><Action>…</Action></Actions>` 嵌套块。
    const nested =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000020</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[add_express_path]]></Event>
        \\  <DeliveryID><![CDATA[SF]]></DeliveryID>
        \\  <WaybillId><![CDATA[SF1234567890]]></WaybillId>
        \\  <OrderId><![CDATA[ORDER-1]]></OrderId>
        \\  <Version>3</Version>
        \\  <Count>1</Count>
        \\  <Actions>
        \\    <Action>
        \\      <ActionTime>1700000200</ActionTime>
        \\      <ActionType>100003</ActionType>
        \\      <ActionMsg><![CDATA[派送中]]></ActionMsg>
        \\    </Action>
        \\  </Actions>
        \\</xml>
    ;
    const got2 = try r.getMsgData(alloc, nested, .xml);
    const e2 = got2.data.add_express_path;
    try std.testing.expectEqual(@as(usize, 1), e2.actions.len);
    try std.testing.expectEqual(@as(i64, 1700000200), e2.actions[0].action_time);
    try std.testing.expectEqual(@as(i64, 100003), e2.actions[0].action_type);
    try std.testing.expectEqualStrings("派送中", e2.actions[0].action_msg);
}

test "PushReceiver JSON 短剧媒资上传与审核事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const upload =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000030,"MsgType":"event",
        \\ "Event":"secvod_upload_event",
        \\ "upload_event":{"media_id":73000001,"source_context":"ctx-1","errcode":0,"errmsg":""}}
    ;
    const got_up = try r.getMsgData(alloc, upload, .json);
    const up = got_up.data.secvod_upload;
    try std.testing.expectEqualStrings("gh_x", up.common.to_user_name);
    try std.testing.expectEqual(@as(i64, 73000001), up.upload_event.media_id);
    try std.testing.expectEqualStrings("ctx-1", up.upload_event.source_context);
    try std.testing.expectEqual(@as(i64, 0), up.upload_event.errcode);
    try std.testing.expectEqualStrings("", up.upload_event.errmsg);
    try std.testing.expect(up.isSuccess());

    const audit =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000040,"MsgType":"event",
        \\ "Event":"secvod_audit_event",
        \\ "audit_event":{"drama_id":73000002,"source_context":"ctx-2",
        \\                "audit_detail":{"status":3,"create_time":1700000035,"audit_time":1700000039}}}
    ;
    const got_au = try r.getMsgData(alloc, audit, .json);
    const au = got_au.data.secvod_audit;
    try std.testing.expectEqual(@as(i64, 73000002), au.audit_event.drama_id);
    try std.testing.expectEqualStrings("ctx-2", au.audit_event.source_context);
    try std.testing.expectEqual(@as(i64, 3), au.audit_event.audit_detail.status);
    try std.testing.expectEqual(@as(i64, 1700000035), au.audit_event.audit_detail.create_time);
    try std.testing.expectEqual(@as(i64, 1700000039), au.audit_event.audit_detail.audit_time);
    try std.testing.expect(au.isAuditPassed());
}

test "PushReceiver XML 短剧媒资上传与审核事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const upload =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000030</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[secvod_upload_event]]></Event>
        \\  <upload_event>
        \\    <media_id>73000001</media_id>
        \\    <source_context><![CDATA[ctx-1]]></source_context>
        \\    <errcode>0</errcode>
        \\    <errmsg><![CDATA[]]></errmsg>
        \\  </upload_event>
        \\</xml>
    ;
    const got_up = try r.getMsgData(alloc, upload, .xml);
    const up = got_up.data.secvod_upload;
    try std.testing.expectEqualStrings("gh_x", up.common.to_user_name);
    try std.testing.expectEqual(@as(i64, 73000001), up.upload_event.media_id);
    try std.testing.expectEqualStrings("ctx-1", up.upload_event.source_context);
    try std.testing.expectEqual(@as(i64, 0), up.upload_event.errcode);
    try std.testing.expectEqualStrings("", up.upload_event.errmsg);
    try std.testing.expect(up.isSuccess());

    const audit =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000040</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[secvod_audit_event]]></Event>
        \\  <audit_event>
        \\    <drama_id>73000002</drama_id>
        \\    <source_context><![CDATA[ctx-2]]></source_context>
        \\    <audit_detail>
        \\      <status>4</status>
        \\      <create_time>1700000035</create_time>
        \\      <audit_time>1700000039</audit_time>
        \\    </audit_detail>
        \\  </audit_event>
        \\</xml>
    ;
    const got_au = try r.getMsgData(alloc, audit, .xml);
    const au = got_au.data.secvod_audit;
    try std.testing.expectEqual(@as(i64, 73000002), au.audit_event.drama_id);
    try std.testing.expectEqualStrings("ctx-2", au.audit_event.source_context);
    try std.testing.expectEqual(@as(i64, 4), au.audit_event.audit_detail.status);
    try std.testing.expectEqual(@as(i64, 1700000035), au.audit_event.audit_detail.create_time);
    try std.testing.expectEqual(@as(i64, 1700000039), au.audit_event.audit_detail.audit_time);
    try std.testing.expect(!au.isAuditPassed());
}

test "PushReceiver JSON 虚拟支付道具发货与代币支付事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const goods =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000050,"MsgType":"event",
        \\ "Event":"xpay_goods_deliver_notify","OpenId":"oX","OutTradeNo":"T123","Env":0,
        \\ "WeChatPayInfo":{"MchOrderNo":"MCH1","TransactionId":"4200","PaidTime":1700000045},
        \\ "GoodsInfo":{"ProductId":"prod-1","Quantity":1,"OrigPrice":100,"ActualPrice":90,"Attach":"attach-1"},
        \\ "TeamInfo":{"ActivityId":"act-1","TeamId":"team-1","TeamType":1,"TeamAction":0}}
    ;
    const got_g = try r.getMsgData(alloc, goods, .json);
    const g = got_g.data.xpay_goods_deliver_notify;
    try std.testing.expectEqualStrings("gh_x", g.common.to_user_name);
    try std.testing.expectEqualStrings("oX", g.open_id);
    try std.testing.expectEqualStrings("T123", g.out_trade_no);
    try std.testing.expectEqual(@as(i64, 0), g.env);
    try std.testing.expectEqualStrings("MCH1", g.wechat_pay_info.mch_order_no);
    try std.testing.expectEqualStrings("4200", g.wechat_pay_info.transaction_id);
    try std.testing.expectEqual(@as(i64, 1700000045), g.wechat_pay_info.paid_time);
    try std.testing.expectEqualStrings("prod-1", g.goods_info.product_id);
    try std.testing.expectEqual(@as(i64, 1), g.goods_info.quantity);
    try std.testing.expectEqual(@as(i64, 100), g.goods_info.orig_price);
    try std.testing.expectEqual(@as(i64, 90), g.goods_info.actual_price);
    try std.testing.expectEqualStrings("attach-1", g.goods_info.attach);
    try std.testing.expectEqualStrings("act-1", g.team_info.activity_id);
    try std.testing.expectEqualStrings("team-1", g.team_info.team_id);
    try std.testing.expectEqual(@as(i64, 1), g.team_info.team_type);
    try std.testing.expectEqual(@as(i64, 0), g.team_info.team_action);
    try std.testing.expect(!g.isSandbox());

    const coin =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000060,"MsgType":"event",
        \\ "Event":"xpay_coin_pay_notify","OpenId":"oX","OutTradeNo":"T456","Env":1,
        \\ "WeChatPayInfo":{"MchOrderNo":"MCH2","TransactionId":"4201","PaidTime":1700000055},
        \\ "CoinInfo":{"Quantity":10,"OrigPrice":1000,"ActualPrice":800,"Attach":"attach-2"}}
    ;
    const got_c = try r.getMsgData(alloc, coin, .json);
    const c = got_c.data.xpay_coin_pay_notify;
    try std.testing.expectEqualStrings("T456", c.out_trade_no);
    try std.testing.expectEqual(@as(i64, 1), c.env);
    try std.testing.expectEqualStrings("MCH2", c.wechat_pay_info.mch_order_no);
    try std.testing.expectEqual(@as(i64, 1700000055), c.wechat_pay_info.paid_time);
    try std.testing.expectEqual(@as(i64, 10), c.coin_info.quantity);
    try std.testing.expectEqual(@as(i64, 1000), c.coin_info.orig_price);
    try std.testing.expectEqual(@as(i64, 800), c.coin_info.actual_price);
    try std.testing.expectEqualStrings("attach-2", c.coin_info.attach);
    try std.testing.expect(c.isSandbox());
}

test "PushReceiver XML 虚拟支付道具发货与代币支付事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const goods =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000050</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[xpay_goods_deliver_notify]]></Event>
        \\  <OpenId><![CDATA[oX]]></OpenId>
        \\  <OutTradeNo><![CDATA[T123]]></OutTradeNo>
        \\  <Env>1</Env>
        \\  <WeChatPayInfo>
        \\    <MchOrderNo><![CDATA[MCH1]]></MchOrderNo>
        \\    <TransactionId><![CDATA[4200]]></TransactionId>
        \\    <PaidTime>1700000045</PaidTime>
        \\  </WeChatPayInfo>
        \\  <GoodsInfo>
        \\    <ProductId><![CDATA[prod-1]]></ProductId>
        \\    <Quantity>1</Quantity>
        \\    <OrigPrice>100</OrigPrice>
        \\    <ActualPrice>90</ActualPrice>
        \\    <Attach><![CDATA[attach-1]]></Attach>
        \\  </GoodsInfo>
        \\  <TeamInfo>
        \\    <ActivityId><![CDATA[act-1]]></ActivityId>
        \\    <TeamId><![CDATA[team-1]]></TeamId>
        \\    <TeamType>1</TeamType>
        \\    <TeamAction>1</TeamAction>
        \\  </TeamInfo>
        \\</xml>
    ;
    const got_g = try r.getMsgData(alloc, goods, .xml);
    const g = got_g.data.xpay_goods_deliver_notify;
    try std.testing.expectEqualStrings("gh_x", g.common.to_user_name);
    try std.testing.expectEqualStrings("oX", g.open_id);
    try std.testing.expectEqualStrings("T123", g.out_trade_no);
    try std.testing.expectEqual(@as(i64, 1), g.env);
    try std.testing.expect(g.isSandbox());
    try std.testing.expectEqualStrings("MCH1", g.wechat_pay_info.mch_order_no);
    try std.testing.expectEqualStrings("4200", g.wechat_pay_info.transaction_id);
    try std.testing.expectEqual(@as(i64, 1700000045), g.wechat_pay_info.paid_time);
    try std.testing.expectEqualStrings("prod-1", g.goods_info.product_id);
    try std.testing.expectEqual(@as(i64, 1), g.goods_info.quantity);
    try std.testing.expectEqual(@as(i64, 100), g.goods_info.orig_price);
    try std.testing.expectEqual(@as(i64, 90), g.goods_info.actual_price);
    try std.testing.expectEqualStrings("attach-1", g.goods_info.attach);
    try std.testing.expectEqualStrings("act-1", g.team_info.activity_id);
    try std.testing.expectEqualStrings("team-1", g.team_info.team_id);
    try std.testing.expectEqual(@as(i64, 1), g.team_info.team_type);
    try std.testing.expectEqual(@as(i64, 1), g.team_info.team_action);

    const coin =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000060</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[xpay_coin_pay_notify]]></Event>
        \\  <OpenId><![CDATA[oX]]></OpenId>
        \\  <OutTradeNo><![CDATA[T456]]></OutTradeNo>
        \\  <Env>0</Env>
        \\  <WeChatPayInfo>
        \\    <MchOrderNo><![CDATA[MCH2]]></MchOrderNo>
        \\    <TransactionId><![CDATA[4201]]></TransactionId>
        \\    <PaidTime>1700000055</PaidTime>
        \\  </WeChatPayInfo>
        \\  <CoinInfo>
        \\    <Quantity>10</Quantity>
        \\    <OrigPrice>1000</OrigPrice>
        \\    <ActualPrice>800</ActualPrice>
        \\    <Attach><![CDATA[attach-2]]></Attach>
        \\  </CoinInfo>
        \\</xml>
    ;
    const got_c = try r.getMsgData(alloc, coin, .xml);
    const c = got_c.data.xpay_coin_pay_notify;
    try std.testing.expectEqualStrings("T456", c.out_trade_no);
    try std.testing.expectEqual(@as(i64, 0), c.env);
    try std.testing.expect(!c.isSandbox());
    try std.testing.expectEqualStrings("MCH2", c.wechat_pay_info.mch_order_no);
    try std.testing.expectEqual(@as(i64, 1700000055), c.wechat_pay_info.paid_time);
    try std.testing.expectEqual(@as(i64, 10), c.coin_info.quantity);
    try std.testing.expectEqual(@as(i64, 1000), c.coin_info.orig_price);
    try std.testing.expectEqual(@as(i64, 800), c.coin_info.actual_price);
    try std.testing.expectEqualStrings("attach-2", c.coin_info.attach);
}

test "PushReceiver JSON 虚拟支付退款事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000070,"MsgType":"event",
        \\ "Event":"xpay_refund_notify","OpenId":"oX","WxRefundId":"WXREF1","MchRefundId":"MREF1",
        \\ "WxOrderId":"WXORDER1","MchOrderId":"MORDER1","RefundFee":90,"RetCode":0,"RetMsg":"ok",
        \\ "RefundStartTimestamp":1700000065,"RefundSuccTimestamp":1700000069,
        \\ "WxpayRefundTransactionId":"4202","RetryTimes":0,
        \\ "TeamInfo":{"ActivityId":"act-2","TeamId":"team-2","TeamType":0,"TeamAction":1}}
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .json);
    const refund = got.data.xpay_refund_notify;
    try std.testing.expectEqualStrings("gh_x", refund.common.to_user_name);
    try std.testing.expectEqualStrings("oX", refund.open_id);
    try std.testing.expectEqualStrings("WXREF1", refund.wx_refund_id);
    try std.testing.expectEqualStrings("MREF1", refund.mch_refund_id);
    try std.testing.expectEqualStrings("WXORDER1", refund.wx_order_id);
    try std.testing.expectEqualStrings("MORDER1", refund.mch_order_id);
    try std.testing.expectEqual(@as(i64, 90), refund.refund_fee);
    try std.testing.expectEqual(@as(i64, 0), refund.ret_code);
    try std.testing.expectEqualStrings("ok", refund.ret_msg);
    try std.testing.expectEqual(@as(i64, 1700000065), refund.refund_start_timestamp);
    try std.testing.expectEqual(@as(i64, 1700000069), refund.refund_succ_timestamp);
    try std.testing.expectEqualStrings("4202", refund.wxpay_refund_transaction_id);
    try std.testing.expectEqual(@as(i64, 0), refund.retry_times);
    try std.testing.expectEqualStrings("act-2", refund.team_info.activity_id);
    try std.testing.expectEqualStrings("team-2", refund.team_info.team_id);
    try std.testing.expectEqual(@as(i64, 0), refund.team_info.team_type);
    try std.testing.expectEqual(@as(i64, 1), refund.team_info.team_action);
    try std.testing.expect(refund.isSuccess());
}

test "PushReceiver XML 虚拟支付退款事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000070</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[xpay_refund_notify]]></Event>
        \\  <OpenId><![CDATA[oX]]></OpenId>
        \\  <WxRefundId><![CDATA[WXREF1]]></WxRefundId>
        \\  <MchRefundId><![CDATA[MREF1]]></MchRefundId>
        \\  <WxOrderId><![CDATA[WXORDER1]]></WxOrderId>
        \\  <MchOrderId><![CDATA[MORDER1]]></MchOrderId>
        \\  <RefundFee>90</RefundFee>
        \\  <RetCode>1</RetCode>
        \\  <RetMsg><![CDATA[fail]]></RetMsg>
        \\  <RefundStartTimestamp>1700000065</RefundStartTimestamp>
        \\  <RefundSuccTimestamp>1700000069</RefundSuccTimestamp>
        \\  <WxpayRefundTransactionId><![CDATA[4202]]></WxpayRefundTransactionId>
        \\  <RetryTimes>2</RetryTimes>
        \\  <TeamInfo>
        \\    <ActivityId><![CDATA[act-2]]></ActivityId>
        \\    <TeamId><![CDATA[team-2]]></TeamId>
        \\    <TeamType>0</TeamType>
        \\    <TeamAction>1</TeamAction>
        \\  </TeamInfo>
        \\</xml>
    ;
    const r = PushReceiver.init();
    const got = try r.getMsgData(alloc, data, .xml);
    const refund = got.data.xpay_refund_notify;
    try std.testing.expectEqualStrings("gh_x", refund.common.to_user_name);
    try std.testing.expectEqualStrings("oX", refund.open_id);
    try std.testing.expectEqualStrings("WXREF1", refund.wx_refund_id);
    try std.testing.expectEqualStrings("MREF1", refund.mch_refund_id);
    try std.testing.expectEqualStrings("WXORDER1", refund.wx_order_id);
    try std.testing.expectEqualStrings("MORDER1", refund.mch_order_id);
    try std.testing.expectEqual(@as(i64, 90), refund.refund_fee);
    try std.testing.expectEqual(@as(i64, 1), refund.ret_code);
    try std.testing.expectEqualStrings("fail", refund.ret_msg);
    try std.testing.expectEqual(@as(i64, 1700000065), refund.refund_start_timestamp);
    try std.testing.expectEqual(@as(i64, 1700000069), refund.refund_succ_timestamp);
    try std.testing.expectEqualStrings("4202", refund.wxpay_refund_transaction_id);
    try std.testing.expectEqual(@as(i64, 2), refund.retry_times);
    try std.testing.expectEqualStrings("act-2", refund.team_info.activity_id);
    try std.testing.expectEqual(@as(i64, 1), refund.team_info.team_action);
    try std.testing.expect(!refund.isSuccess());
}

test "PushReceiver JSON iOS 退款问询与用户投诉事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const ios =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000080,"MsgType":"event",
        \\ "Event":"xpay_subscribe_ios_refund_query_notify","refund_time":"1700000075",
        \\ "order_time":"1699990000","channel_bill":"apple-bill-1","bundleid":"com.example.app",
        \\ "product_id":"prod-ios-1","p_count":"1","refund_request_reason":"误购",
        \\ "provide_status":"1","pay_order_id":"PAY-1"}
    ;
    const got_ios = try r.getMsgData(alloc, ios, .json);
    const q = got_ios.data.xpay_subscribe_ios_refund_query_notify;
    try std.testing.expectEqualStrings("gh_x", q.common.to_user_name);
    try std.testing.expectEqual(@as(i64, 1700000080), q.common.create_time);
    try std.testing.expectEqualStrings("1700000075", q.refund_time);
    try std.testing.expectEqualStrings("1699990000", q.order_time);
    try std.testing.expectEqualStrings("apple-bill-1", q.channel_bill);
    try std.testing.expectEqualStrings("com.example.app", q.bundle_id);
    try std.testing.expectEqualStrings("prod-ios-1", q.product_id);
    try std.testing.expectEqualStrings("1", q.p_count);
    try std.testing.expectEqualStrings("误购", q.refund_request_reason);
    try std.testing.expectEqualStrings("1", q.provide_status);
    try std.testing.expectEqualStrings("PAY-1", q.pay_order_id);

    const complaint =
        \\{"ToUserName":"gh_x","FromUserName":"oX","CreateTime":1700000090,"MsgType":"event",
        \\ "Event":"xpay_complaint_notify","OpenId":"oX","WxOrderId":"WXORDER1","MchOrderId":"MORDER1",
        \\ "TransactionId":"4203","ComplaintId":"C-1","ComplaintDetail":"金额不对",
        \\ "ComplaintTime":1700000085,"RetryTimes":0,"RequestId":"REQ-1"}
    ;
    const got_cp = try r.getMsgData(alloc, complaint, .json);
    const cp = got_cp.data.xpay_complaint_notify;
    try std.testing.expectEqualStrings("oX", cp.open_id);
    try std.testing.expectEqualStrings("WXORDER1", cp.wx_order_id);
    try std.testing.expectEqualStrings("MORDER1", cp.mch_order_id);
    try std.testing.expectEqualStrings("4203", cp.transaction_id);
    try std.testing.expectEqualStrings("C-1", cp.complaint_id);
    try std.testing.expectEqualStrings("金额不对", cp.complaint_detail);
    try std.testing.expectEqual(@as(i64, 1700000085), cp.complaint_time);
    try std.testing.expectEqual(@as(i64, 0), cp.retry_times);
    try std.testing.expectEqualStrings("REQ-1", cp.request_id);
}

test "PushReceiver XML iOS 退款问询与用户投诉事件" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const ios =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000080</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[xpay_subscribe_ios_refund_query_notify]]></Event>
        \\  <refund_time><![CDATA[1700000075]]></refund_time>
        \\  <order_time><![CDATA[1699990000]]></order_time>
        \\  <channel_bill><![CDATA[apple-bill-1]]></channel_bill>
        \\  <bundleid><![CDATA[com.example.app]]></bundleid>
        \\  <product_id><![CDATA[prod-ios-1]]></product_id>
        \\  <p_count><![CDATA[1]]></p_count>
        \\  <refund_request_reason><![CDATA[误购]]></refund_request_reason>
        \\  <provide_status><![CDATA[1]]></provide_status>
        \\  <pay_order_id><![CDATA[PAY-1]]></pay_order_id>
        \\</xml>
    ;
    const got_ios = try r.getMsgData(alloc, ios, .xml);
    const q = got_ios.data.xpay_subscribe_ios_refund_query_notify;
    try std.testing.expectEqualStrings("gh_x", q.common.to_user_name);
    try std.testing.expectEqual(@as(i64, 1700000080), q.common.create_time);
    try std.testing.expectEqualStrings("1700000075", q.refund_time);
    try std.testing.expectEqualStrings("1699990000", q.order_time);
    try std.testing.expectEqualStrings("apple-bill-1", q.channel_bill);
    try std.testing.expectEqualStrings("com.example.app", q.bundle_id);
    try std.testing.expectEqualStrings("prod-ios-1", q.product_id);
    try std.testing.expectEqualStrings("1", q.p_count);
    try std.testing.expectEqualStrings("误购", q.refund_request_reason);
    try std.testing.expectEqualStrings("1", q.provide_status);
    try std.testing.expectEqualStrings("PAY-1", q.pay_order_id);

    const complaint =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_x]]></ToUserName>
        \\  <FromUserName><![CDATA[oX]]></FromUserName>
        \\  <CreateTime>1700000090</CreateTime>
        \\  <MsgType><![CDATA[event]]></MsgType>
        \\  <Event><![CDATA[xpay_complaint_notify]]></Event>
        \\  <OpenId><![CDATA[oX]]></OpenId>
        \\  <WxOrderId><![CDATA[WXORDER1]]></WxOrderId>
        \\  <MchOrderId><![CDATA[MORDER1]]></MchOrderId>
        \\  <TransactionId><![CDATA[4203]]></TransactionId>
        \\  <ComplaintId><![CDATA[C-1]]></ComplaintId>
        \\  <ComplaintDetail><![CDATA[金额不对]]></ComplaintDetail>
        \\  <ComplaintTime>1700000085</ComplaintTime>
        \\  <RetryTimes>3</RetryTimes>
        \\  <RequestId><![CDATA[REQ-1]]></RequestId>
        \\</xml>
    ;
    const got_cp = try r.getMsgData(alloc, complaint, .xml);
    const cp = got_cp.data.xpay_complaint_notify;
    try std.testing.expectEqualStrings("oX", cp.open_id);
    try std.testing.expectEqualStrings("WXORDER1", cp.wx_order_id);
    try std.testing.expectEqualStrings("MORDER1", cp.mch_order_id);
    try std.testing.expectEqualStrings("4203", cp.transaction_id);
    try std.testing.expectEqualStrings("C-1", cp.complaint_id);
    try std.testing.expectEqualStrings("金额不对", cp.complaint_detail);
    try std.testing.expectEqual(@as(i64, 1700000085), cp.complaint_time);
    try std.testing.expectEqual(@as(i64, 3), cp.retry_times);
    try std.testing.expectEqualStrings("REQ-1", cp.request_id);
}

test "PushReceiver 12 类新增事件 JSON / XML 均命中对应 union 分支" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = PushReceiver.init();

    const events = [_][]const u8{
        event_trade_manage_remind_access_api,
        event_trade_manage_remind_shipping,
        event_trade_manage_order_settlement,
        event_wxa_media_check,
        event_add_express_path,
        event_secvod_upload,
        event_secvod_audit,
        event_xpay_goods_deliver_notify,
        event_xpay_coin_pay_notify,
        event_xpay_refund_notify,
        event_xpay_subscribe_ios_refund_query_notify,
        event_xpay_complaint_notify,
    };
    const tags = [_]std.meta.Tag(PushData){
        .trade_manage_remind_access_api,
        .trade_manage_remind_shipping,
        .trade_manage_order_settlement,
        .wxa_media_check,
        .add_express_path,
        .secvod_upload,
        .secvod_audit,
        .xpay_goods_deliver_notify,
        .xpay_coin_pay_notify,
        .xpay_refund_notify,
        .xpay_subscribe_ios_refund_query_notify,
        .xpay_complaint_notify,
    };
    try std.testing.expectEqual(events.len, tags.len);

    for (events, tags) |ev, want| {
        const json = try std.fmt.allocPrint(
            alloc,
            "{{\"ToUserName\":\"gh_x\",\"FromUserName\":\"oX\",\"CreateTime\":1,\"MsgType\":\"event\",\"Event\":\"{s}\"}}",
            .{ev},
        );
        const got_json = try r.getMsgData(alloc, json, .json);
        try std.testing.expectEqualStrings(ev, got_json.event);
        try std.testing.expectEqual(want, std.meta.activeTag(got_json.data));

        const xml = try std.fmt.allocPrint(
            alloc,
            "<xml><ToUserName><![CDATA[gh_x]]></ToUserName><CreateTime>1</CreateTime>" ++
                "<MsgType><![CDATA[event]]></MsgType><Event><![CDATA[{s}]]></Event></xml>",
            .{ev},
        );
        const got_xml = try r.getMsgData(alloc, xml, .xml);
        try std.testing.expectEqualStrings(ev, got_xml.event);
        try std.testing.expectEqual(want, std.meta.activeTag(got_xml.data));
    }
}
