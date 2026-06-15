//! work/kf — 微信客服
//!
//! 对应 `_ref/wechat/work/kf/`。Go 参考实现的 `NewClient(cfg)` 接受 `*config.Config`
//! 并自行组装内部 `Context`（因为它需要额外的 `token` / `encodingAESKey` 等
//! 客服回调字段，且访问 token 时使用独立的 kf corpsecret）。Zig 版统一沿用
//! `Context` 抽象，由调用方在 `Config` 里填好客服 secret，再通过 `Context`
//! 走默认 access_token 即可。
//!
//! 当前落地两个最常用入口：
//!
//! - `getAccountList` — 拉取客服账号列表
//!   (`GET /cgi-bin/kf/account/list`)
//! - `sendMsg` — 客服向客户发文本消息
//!   (`POST /cgi-bin/kf/send_msg`)

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 客服账号列表。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/kf/account/list?access_token=...`。
pub const accountListURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/account/list";

/// 客服发消息。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg?access_token=...`。
pub const sendMsgURL = "https://qyapi.weixin.qq.com/cgi-bin/kf/send_msg";

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

// ─────────────────────────────────────────────────────────────────────────────
// 响应结构
// ─────────────────────────────────────────────────────────────────────────────

/// 单个客服账号信息。
pub const AccountInfo = struct {
    open_kfid: []const u8 = "",
    name: []const u8 = "",
    avatar: []const u8 = "",
    /// 当前调用接口的应用身份，是否有该客服账号的管理权限。
    manage_privilege: bool = false,
};

/// `getAccountList` 响应。
pub const AccountListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    account_list: []AccountInfo = &.{},
};

/// `sendMsg` 响应。
pub const SendMsgResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 消息 id；如果请求参数指定了 msgid，则原样返回。
    msgid: []const u8 = "",
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

    /// 拉取客服账号列表。
    ///
    /// 对应 `_ref/wechat/work/kf/account.go` 的 `AccountList`。
    pub fn getAccountList(self: *Self) !AccountListResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ accountListURL, access_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(AccountListResponse, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 客服向客户发送文本消息。
    ///
    /// 对应 `_ref/wechat/work/kf/sendmsg.go` 的 `SendMsg`，并固定 `msgtype = "text"`。
    pub fn sendMsg(self: *Self, msg: TextMessage) !SendMsgResponse {
        if (msg.open_kfid.len == 0 or msg.touser.len == 0 or msg.content.len == 0) {
            return util_error.WechatError.InvalidArgument;
        }

        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ sendMsgURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try encodeTextMessageJson(self.allocator, msg);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(SendMsgResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助：手写 JSON 序列化
// ─────────────────────────────────────────────────────────────────────────────

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

fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
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
