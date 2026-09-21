// SPDX-License-Identifier: Apache-2.0
//! miniprogram — 小程序（顶层 + 子模块聚合）

const std = @import("std");
const credential = @import("../credential/mod.zig");
pub const Config = @import("config.zig").Config;
pub const Context = @import("context/mod.zig").Context;

pub const Auth = @import("auth/mod.zig").Auth;
pub const ResCode2Session = @import("auth/mod.zig").ResCode2Session;
pub const RspCheckEncryptedData = @import("auth/mod.zig").RspCheckEncryptedData;
pub const PhoneInfo = @import("auth/mod.zig").PhoneInfo;
pub const GetPhoneNumberResponse = @import("auth/mod.zig").GetPhoneNumberResponse;
pub const qrcode = @import("qrcode/mod.zig");
pub const urlscheme = @import("urlscheme/mod.zig");
pub const message = @import("message/mod.zig");
pub const security = @import("security/mod.zig");
pub const shortlink = @import("shortlink/mod.zig");
pub const encryptor = @import("encryptor/mod.zig");
pub const werun = @import("werun/mod.zig");
pub const urllink = @import("urllink/mod.zig");
pub const riskcontrol = @import("riskcontrol/mod.zig");
pub const redpacketcover = @import("redpacketcover/mod.zig");
pub const privacy = @import("privacy/mod.zig");
pub const content = @import("content/mod.zig");
pub const business = @import("business/mod.zig");
pub const order = @import("order/mod.zig");
pub const ocr = @import("ocr/mod.zig");
pub const subscribe = @import("subscribe/mod.zig");
pub const analysis = @import("analysis/mod.zig");
pub const operation = @import("operation/mod.zig");
pub const tcb = @import("tcb/mod.zig");
pub const express = @import("express/mod.zig");
pub const minidrama = @import("minidrama/mod.zig");
pub const virtualpayment = @import("virtualpayment/mod.zig");

/// ⚠️ **地址稳定性警告**：`MiniProgram` 实例一旦被各 `getXxx()` 工厂使用，
/// 其内存地址就必须保持稳定——派生的子模块持有 `&self.ctx` 裸指针。
/// **禁止把 `MiniProgram` 按值拷贝 / 移动**（包括从函数按值返回后再取地址、
/// 放入会搬迁的 ArrayList 等），否则已派生的子模块会悬垂。
/// 需要传递时请使用 `*MiniProgram` 指针，并把 `MiniProgram` 放在
/// `var` 局部变量 / 堆上固定位置。
pub const MiniProgram = struct {
    ctx: Context,
    auth_instance: ?Auth = null,
    allocator: std.mem.Allocator = undefined,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cfg: Config, access_token_handle: credential.AccessTokenHandle) MiniProgram {
        return .{
            .ctx = .{ .config = cfg, .access_token_handle = access_token_handle },
            .auth_instance = null,
            .allocator = allocator,
        };
    }

    pub fn getContext(self: *MiniProgram) *Context {
        return &self.ctx;
    }

    /// 懒加载 Auth 子模块。
    ///
    /// 注意：`getPhoneNumber(code)` 与 `getBusiness().getPhoneNumber(req)` 重复覆盖
    /// 同一端点（`getuserphonenumber`）。新代码请优先用本方法：签名更简（直接收
    /// `code`，无需包一层请求结构体）、归属 auth 登录域（与 code2session /
    /// checkEncryptedData 同域），且响应含 `errcode` / `errmsg` 便于错误分支。
    pub fn getAuth(self: *Self) Auth {
        return Auth.init(&self.ctx, self.allocator);
    }

    /// 懒加载 QRCode 子模块。
    pub fn getQRCode(self: *Self) qrcode.QRCode {
        return qrcode.QRCode.init(&self.ctx, self.allocator);
    }

    /// 懒加载 URLScheme 子模块。
    pub fn getURLScheme(self: *Self) urlscheme.URLScheme {
        return urlscheme.URLScheme.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Message 订阅消息子模块。
    ///
    /// ⚠️ 已弃用（重复入口）：`sendSubscribeMessage` 与 `getSubscribe().send` /
    /// `sendGetMsgId` 重复覆盖同一端点（`message/subscribe/send`）。
    /// 新代码请优先用 `getSubscribe().send`（类型化 `DataEntry` 列表，无需手工预序列化
    /// `data` JSON 字符串）或 `sendGetMsgId`（可拿到 msgid）；`sendSubscribeMessage`
    /// 的 `data` 字段要求调用方预拼 JSON 原始字符串，且无 subscribe 版不具备的能力。
    /// 仅为兼容已有下游保留，不删方法、不改签名。
    pub fn getMessage(self: *Self) message.Message {
        return message.Message.init(&self.ctx);
    }

    /// 懒加载 Security 内容安全审核子模块。
    ///
    /// 注意：`msgSecCheck` 与 `getContent().checkText` 重复覆盖同一端点
    /// （`msg_sec_check`），两版契约等价（均带必填 `openid` / `scene` 参数）。
    /// 新代码请优先用本方法：语义归属内容安全域，统一走 security 域可避免
    /// 一处端点两处入口的重复维护。
    pub fn getSecurity(self: *Self) security.Security {
        return security.Security.init(&self.ctx);
    }

    /// 懒加载 ShortLink 短链接子模块。
    pub fn getShortLink(self: *Self) shortlink.ShortLink {
        return shortlink.ShortLink.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Encryptor 加密数据解密子模块。
    pub fn getEncryptor(self: *Self) encryptor.Encryptor {
        return encryptor.Encryptor.init(&self.ctx);
    }

    /// 懒加载 WeRun 微信运动子模块。
    pub fn getWeRun(self: *Self) werun.WeRun {
        return werun.WeRun.init(&self.ctx, self.allocator);
    }

    /// 懒加载 URLLink 子模块。
    pub fn getURLLink(self: *Self) urllink.URLLink {
        return urllink.URLLink.init(&self.ctx, self.allocator);
    }

    /// 懒加载 RiskControl 安全风控子模块。
    pub fn getRiskControl(self: *Self) riskcontrol.RiskControl {
        return riskcontrol.RiskControl.init(&self.ctx, self.allocator);
    }

    /// 懒加载 RedPacketCover 红包封面子模块。
    pub fn getRedPacketCover(self: *Self) redpacketcover.RedPacketCover {
        return redpacketcover.RedPacketCover.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Privacy 隐私设置子模块。
    pub fn getPrivacy(self: *Self) privacy.Privacy {
        return privacy.Privacy.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Content 内容安全（旧接口）子模块。
    ///
    /// ⚠️ 已弃用（重复入口）：`checkText` 与 `getSecurity().msgSecCheck` 重复覆盖
    /// 同一端点（`msg_sec_check`），两版契约等价（均带必填 `openid` / `scene`）。
    /// 新代码请优先用 `getSecurity().msgSecCheck`（语义归属内容安全域，统一入口）。
    /// 仅为兼容已有下游保留，不删方法、不改签名。
    pub fn getContent(self: *Self) content.Content {
        return content.Content.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Business 业务子模块。
    ///
    /// 注意：`getPhoneNumber(req)` 与 `getAuth().getPhoneNumber(code)` 重复覆盖
    /// 同一端点（`getuserphonenumber`）。新代码请优先用 `getAuth().getPhoneNumber`
    /// （签名更简、归属 auth 登录域、响应含 `errcode` / `errmsg`）；本方法需把 `code`
    /// 包进 `GetPhoneNumberRequest`，无 auth 版不具备的能力。仅为兼容已有下游保留。
    pub fn getBusiness(self: *Self) business.Business {
        return business.Business.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Order 订单发货子模块。
    pub fn getOrder(self: *Self) order.Shipping {
        return order.Shipping.init(&self.ctx, self.allocator);
    }

    /// 懒加载 OCR 识别子模块。
    pub fn getOCR(self: *Self) ocr.OCR {
        return ocr.OCR.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Subscribe 订阅消息子模块。
    ///
    /// 注意：`send` / `sendGetMsgId` 与 `getMessage().sendSubscribeMessage` 重复覆盖
    /// 同一端点（`message/subscribe/send`）。本方法为推荐入口：`data` 是类型化
    /// `DataEntry` 列表（无需手工预序列化 JSON 字符串），`sendGetMsgId` 还能拿到 msgid。
    pub fn getSubscribe(self: *Self) subscribe.Subscribe {
        return subscribe.Subscribe.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Analysis 数据分析子模块。
    pub fn getAnalysis(self: *Self) analysis.Analysis {
        return analysis.Analysis.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Operation 运维中心子模块。
    pub fn getOperation(self: *Self) operation.Operation {
        return operation.Operation.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Tcb 云开发子模块。
    pub fn getTcb(self: *Self) tcb.Tcb {
        return tcb.Tcb.init(&self.ctx, self.allocator);
    }

    /// 懒加载 Express 物流子模块。
    pub fn getExpress(self: *Self) express.Express {
        return express.Express.init(&self.ctx, self.allocator);
    }

    /// 懒加载 MiniDrama 微短剧子模块。
    pub fn getMiniDrama(self: *Self) minidrama.MiniDrama {
        return minidrama.MiniDrama.init(&self.ctx, self.allocator);
    }

    /// 懒加载 VirtualPayment 虚拟支付子模块。
    pub fn getVirtualPayment(self: *Self) virtualpayment.VirtualPayment {
        return virtualpayment.VirtualPayment.init(&self.ctx, self.allocator);
    }
};

test "MiniProgram.init 返回实例" {
    const allocator = std.heap.page_allocator;
    const mp = MiniProgram.init(allocator, .{ .app_id = "wx-mp" }, .{ .ptr = undefined, .vtable = undefined });
    try std.testing.expectEqualStrings("wx-mp", mp.ctx.config.app_id);
}

test "MiniProgram 暴露 qrcode / urlscheme 工厂" {
    try std.testing.expect(@hasDecl(MiniProgram, "getQRCode"));
    try std.testing.expect(@hasDecl(MiniProgram, "getURLScheme"));
}
