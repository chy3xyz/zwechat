// SPDX-License-Identifier: Apache-2.0
//! officialaccount/broadcast — 群发
//!
//! 提供按标签 / 按 openid 列表 / 全员（`filter.is_to_all = true`）的群发接口
//! （文本 / 图文 / 语音 / 视频 / 图片 / 卡券），
//! 以及删除群发、群发状态查询与群发速度设置。
//! 对应 `_ref/wechat/officialaccount/broadcast/broadcast.go`。
//!
//! token 注入 / errcode 检查 / token 失效自愈（40001 等 → 作废缓存 → 只重试一次）
//! 交给 `util/retry.callApi` 统一处理。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_json = @import("../../util/json.zig");

pub const sendURLByTag = "https://api.weixin.qq.com/cgi-bin/message/mass/sendall";
pub const sendURLByOpenID = "https://api.weixin.qq.com/cgi-bin/message/mass/send";
pub const deleteSendURL = "https://api.weixin.qq.com/cgi-bin/message/mass/delete";
pub const previewSendURL = "https://api.weixin.qq.com/cgi-bin/message/mass/preview";
pub const massStatusSendURL = "https://api.weixin.qq.com/cgi-bin/message/mass/get";
pub const getSpeedSendURL = "https://api.weixin.qq.com/cgi-bin/message/mass/speed/get";
pub const setSpeedSendURL = "https://api.weixin.qq.com/cgi-bin/message/mass/speed/set";

/// 消息体：文本内容、media_id（图文 / 语音 / 图片）、视频（含标题描述）或卡券。
pub const SendBody = union(enum) {
    text: struct { content: []const u8 },
    media_id: []const u8,
    mpvideo: struct { media_id: []const u8, title: []const u8, description: []const u8 },
    wxcard: struct { card_id: []const u8 },
    /// 图片群发（`images.media_ids`，对照 Go `Image` 结构体，非预览态使用）。
    images: Images,
};

/// 群发图片参数（对照 Go `broadcast.Image`）。
///
/// 序列化时所有字段始终输出（与 Go 结构体全字段序列化一致，无 omitempty）。
pub const Images = struct {
    media_ids: []const []const u8,
    recommend: []const u8 = "",
    need_open_comment: i64 = 0,
    only_fans_can_comment: i64 = 0,
};

/// 预览接收目标（对照 Go `Broadcast.Preview()` 链式 API）。
///
/// Go 的用法是 `broadcast.Preview().SendText(user, content)`——`Preview()` 返回自身并
/// 置状态位，后续 Send 请求发往 `mass/preview` 且接收人取 `user.OpenID[0]`（openid）。
/// 本仓库采用显式风格：不改动 Broadcast 状态，在调用点直接构造 `PreviewTarget`，
/// `to_openid` 对应 Go 预览请求体字段 `touser`，`to_wxname` 对应 `towxname`（微信号）。
pub const PreviewTarget = union(enum) {
    to_openid: []const u8,
    to_wxname: []const u8,
};

/// 群发速度返回结果（对照 Go `SpeedResult`）。
pub const SpeedResult = struct {
    speed: i64 = 0,
    realspeed: i64 = 0,
};

pub const Broadcast = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 按标签群发文本消息。返回微信的 `msg_id`。
    pub fn sendTextToTag(self: *Self, tag_id: i64, content: []const u8) !i64 {
        return self.sendToTag("text", tag_id, .{ .text = .{ .content = content } });
    }

    /// 按标签群发图文消息（通过 media_id）。返回微信的 `msg_id`。
    pub fn sendNewsToTag(self: *Self, tag_id: i64, media_id: []const u8) !i64 {
        return self.sendToTag("mpnews", tag_id, .{ .media_id = media_id });
    }

    /// 按 openid 列表群发文本消息。返回微信的 `msg_id`。
    pub fn sendTextToOpenIDs(self: *Self, openids: []const []const u8, content: []const u8) !i64 {
        return self.sendToOpenIDs("text", openids, .{ .text = .{ .content = content } });
    }

    /// 按 openid 列表群发图文消息（通过 media_id）。返回微信的 `msg_id`。
    pub fn sendNewsToOpenIDs(self: *Self, openids: []const []const u8, media_id: []const u8) !i64 {
        return self.sendToOpenIDs("mpnews", openids, .{ .media_id = media_id });
    }

    /// 按标签群发语音消息（通过 media_id）。返回微信的 `msg_id`。
    pub fn sendVoiceToTag(self: *Self, tag_id: i64, media_id: []const u8) !i64 {
        return self.sendToTag("voice", tag_id, .{ .media_id = media_id });
    }

    /// 按 openid 列表群发语音消息（通过 media_id）。返回微信的 `msg_id`。
    pub fn sendVoiceToOpenIDs(self: *Self, openids: []const []const u8, media_id: []const u8) !i64 {
        return self.sendToOpenIDs("voice", openids, .{ .media_id = media_id });
    }

    /// 按标签群发视频消息（`mpvideo`，含标题与描述）。返回微信的 `msg_id`。
    pub fn sendVideoToTag(self: *Self, tag_id: i64, media_id: []const u8, title: []const u8, description: []const u8) !i64 {
        return self.sendToTag("mpvideo", tag_id, .{ .mpvideo = .{ .media_id = media_id, .title = title, .description = description } });
    }

    /// 按 openid 列表群发视频消息（`mpvideo`，含标题与描述）。返回微信的 `msg_id`。
    pub fn sendVideoToOpenIDs(self: *Self, openids: []const []const u8, media_id: []const u8, title: []const u8, description: []const u8) !i64 {
        return self.sendToOpenIDs("mpvideo", openids, .{ .mpvideo = .{ .media_id = media_id, .title = title, .description = description } });
    }

    /// 按标签群发卡券消息（`wxcard`，通过 card_id）。返回微信的 `msg_id`。
    pub fn sendWxCardToTag(self: *Self, tag_id: i64, card_id: []const u8) !i64 {
        return self.sendToTag("wxcard", tag_id, .{ .wxcard = .{ .card_id = card_id } });
    }

    /// 按 openid 列表群发卡券消息（`wxcard`，通过 card_id）。返回微信的 `msg_id`。
    pub fn sendWxCardToOpenIDs(self: *Self, openids: []const []const u8, card_id: []const u8) !i64 {
        return self.sendToOpenIDs("wxcard", openids, .{ .wxcard = .{ .card_id = card_id } });
    }

    /// 按标签群发图片消息（`msgtype=image`，`images.media_ids`）。返回微信的 `msg_id`。
    pub fn sendImageToTag(self: *Self, tag_id: i64, images: Images) !i64 {
        return self.sendToTag("image", tag_id, .{ .images = images });
    }

    /// 按 openid 列表群发图片消息（`msgtype=image`，`images.media_ids`）。返回微信的 `msg_id`。
    pub fn sendImageToOpenIDs(self: *Self, openids: []const []const u8, images: Images) !i64 {
        return self.sendToOpenIDs("image", openids, .{ .images = images });
    }

    // ── 全员群发（对照 Go `chooseTagOrOpenID` 的 `user == nil` 分支）────────────
    //
    // Go 的 `SendXxx(user *User, ...)` 在 `user == nil` 时把 filter 置为
    // `{"is_to_all": true}`（不带 tag_id）并仍请求 `mass/sendall`（`sendURLByTag`）。
    // 本仓库沿用显式风格，为每种消息类型提供独立的 `sendXxxToAll` 方法。

    /// 全员群发文本消息（`filter.is_to_all = true`，不带 tag_id）。返回微信的 `msg_id`。
    pub fn sendTextToAll(self: *Self, content: []const u8) !i64 {
        return self.sendToAll("text", .{ .text = .{ .content = content } }, "");
    }

    /// 全员群发图文消息（`mpnews`，通过 media_id）。返回微信的 `msg_id`。
    ///
    /// `ignore_reprint` 对应官方字段 `send_ignore_reprint`：图文为转载文章时是否忽略
    /// 转载校验继续群发，`true` 时输出 `"send_ignore_reprint":1`（对照 Go
    /// `SendNews` 的 `ignoreReprint`，Go 侧 `omitempty`，为 false 时不输出该字段）。
    pub fn sendNewsToAll(self: *Self, media_id: []const u8, ignore_reprint: bool) !i64 {
        const extra: []const u8 = if (ignore_reprint) ",\"send_ignore_reprint\":1" else "";
        return self.sendToAll("mpnews", .{ .media_id = media_id }, extra);
    }

    /// 全员群发语音消息（`voice`，通过 media_id）。返回微信的 `msg_id`。
    pub fn sendVoiceToAll(self: *Self, media_id: []const u8) !i64 {
        return self.sendToAll("voice", .{ .media_id = media_id }, "");
    }

    /// 全员群发视频消息（`mpvideo`，含标题与描述）。返回微信的 `msg_id`。
    pub fn sendVideoToAll(self: *Self, media_id: []const u8, title: []const u8, description: []const u8) !i64 {
        return self.sendToAll("mpvideo", .{ .mpvideo = .{ .media_id = media_id, .title = title, .description = description } }, "");
    }

    /// 全员群发卡券消息（`wxcard`，通过 card_id）。返回微信的 `msg_id`。
    pub fn sendWxCardToAll(self: *Self, card_id: []const u8) !i64 {
        return self.sendToAll("wxcard", .{ .wxcard = .{ .card_id = card_id } }, "");
    }

    /// 全员群发图片消息（`msgtype=image`，`images.media_ids`）。返回微信的 `msg_id`。
    ///
    /// 官方「图片群发」要求 `images` 全字段随请求输出：`recommend`（推荐语，可为空串）、
    /// `need_open_comment` / `only_fans_can_comment`（评论开关）；本方法与按标签 / 按
    /// openid 的变体一致，直接透传 `Images` 结构体（对照 Go 的 `*Image` 无 omitempty）。
    pub fn sendImageToAll(self: *Self, images: Images) !i64 {
        return self.sendToAll("image", .{ .images = images }, "");
    }

    /// 群发预览（`mass/preview`；对照 Go `Broadcast.Preview()` 链式 API，见 `PreviewTarget` 文档）。
    ///
    /// `msgtype` / `body` 与群发接口一致；图片预览使用 `.media_id`（取首张图，对照 Go
    /// `SendImage` 预览分支的 `images.MediaIDs[0]`）。
    /// 返回微信的 `msg_id`（预览响应通常无 msg_id，此时为 0）。
    pub fn previewToUser(self: *Self, msgtype: []const u8, body: SendBody, target: PreviewTarget) !i64 {
        const payload = try buildPayloadJson(self.allocator, msgtype, body);
        defer self.allocator.free(payload);

        const user_field: []const u8 = switch (target) {
            .to_openid => "touser",
            .to_wxname => "towxname",
        };
        const user_value: []const u8 = switch (target) {
            .to_openid => |v| v,
            .to_wxname => |v| v,
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.append(self.allocator, '{');
        try buf.append(self.allocator, '"');
        try buf.appendSlice(self.allocator, user_field);
        try buf.appendSlice(self.allocator, "\":\"");
        try appendJsonEscaped(self.allocator, &buf, user_value);
        try buf.appendSlice(self.allocator, "\",\"msgtype\":\"");
        try buf.appendSlice(self.allocator, msgtype);
        try buf.appendSlice(self.allocator, "\",");
        try buf.appendSlice(self.allocator, payload);
        try buf.append(self.allocator, '}');

        return self.postMass(previewSendURL, buf.items);
    }

    /// 删除群发消息（`mass/delete`）。`article_idx` 为要删除的文章位置，全部删除填 0。
    pub fn delete(self: *Self, msg_id: i64, article_idx: i64) !void {
        const Req = struct {
            msg_id: i64,
            article_idx: i64,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(a, "{s}?access_token={s}", .{ deleteSendURL, token });
                defer a.free(uri);

                const json_body = try std.fmt.allocPrint(
                    a,
                    "{{\"msg_id\":{d},\"article_idx\":{d}}}",
                    .{ c.msg_id, c.article_idx },
                );
                defer a.free(json_body);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, json_body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "Delete", Req{
            .msg_id = msg_id,
            .article_idx = article_idx,
        });
        self.allocator.free(resp);
    }

    /// 查询群发消息状态（`mass/get`）。
    ///
    /// 返回 `msg_status` 字符串（如 `SEND_SUCCESS`），由本结构体的 allocator
    /// 分配，**调用方负责 `free`**。
    pub fn getMassStatus(self: *Self, msg_id: []const u8) ![]u8 {
        const Req = struct {
            msg_id: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(a, "{s}?access_token={s}", .{ massStatusSendURL, token });
                defer a.free(uri);

                const json_body = try util_json.stringFieldObject(a, "msg_id", c.msg_id);
                defer a.free(json_body);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, json_body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "MassStatus", Req{ .msg_id = msg_id });
        defer self.allocator.free(resp);

        // errcode 已由 callApi 检查（非 0 直接 ApiError）。
        var parsed = std.json.parseFromSlice(struct {
            msg_status: []const u8 = "",
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        return self.allocator.dupe(u8, parsed.value.msg_status);
    }

    /// 获取群发速度（`mass/speed/get`）。
    pub fn getSpeed(self: *Self) !SpeedResult {
        return self.postSpeed(getSpeedSendURL, "{}");
    }

    /// 设置群发速度（`mass/speed/set`），`speed` 取值 0-4。
    pub fn setSpeed(self: *Self, speed: i64) !SpeedResult {
        const json_body = try std.fmt.allocPrint(self.allocator, "{{\"speed\":{d}}}", .{speed});
        defer self.allocator.free(json_body);
        return self.postSpeed(setSpeedSendURL, json_body);
    }

    fn postSpeed(self: *Self, url: []const u8, json_body: []const u8) !SpeedResult {
        const Req = struct {
            url: []const u8,
            json_body: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(a, "{s}?access_token={s}", .{ c.url, token });
                defer a.free(uri);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, c.json_body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "MassSpeed", Req{
            .url = url,
            .json_body = json_body,
        });
        defer self.allocator.free(resp);

        // errcode 已由 callApi 检查（非 0 直接 ApiError）。
        var parsed = std.json.parseFromSlice(struct {
            speed: i64 = 0,
            realspeed: i64 = 0,
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        return .{ .speed = parsed.value.speed, .realspeed = parsed.value.realspeed };
    }

    /// 全员群发的公共实现：`filter` 仅含 `{"is_to_all":true}`，仍请求 `mass/sendall`。
    ///
    /// `extra_fields` 追加在 msgtype 消息体之后的顶层字段（如
    /// `,"send_ignore_reprint":1`），空串表示不追加。
    fn sendToAll(self: *Self, msgtype: []const u8, body: SendBody, extra_fields: []const u8) !i64 {
        const payload = try buildPayloadJson(self.allocator, msgtype, body);
        defer self.allocator.free(payload);

        const json_body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"filter\":{{\"is_to_all\":true}},\"msgtype\":\"{s}\",{s}{s}}}",
            .{ msgtype, payload, extra_fields },
        );
        defer self.allocator.free(json_body);

        return self.postMass(sendURLByTag, json_body);
    }

    fn sendToTag(self: *Self, msgtype: []const u8, tag_id: i64, body: SendBody) !i64 {
        const payload = try buildPayloadJson(self.allocator, msgtype, body);
        defer self.allocator.free(payload);

        const json_body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"filter\":{{\"is_to_all\":false,\"tag_id\":{d}}},\"msgtype\":\"{s}\",{s}}}",
            .{ tag_id, msgtype, payload },
        );
        defer self.allocator.free(json_body);

        return self.postMass(sendURLByTag, json_body);
    }

    fn sendToOpenIDs(self: *Self, msgtype: []const u8, openids: []const []const u8, body: SendBody) !i64 {
        const openid_array = try buildOpenidArrayJson(self.allocator, openids);
        defer self.allocator.free(openid_array);

        const payload = try buildPayloadJson(self.allocator, msgtype, body);
        defer self.allocator.free(payload);

        const json_body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"touser\":{s},\"msgtype\":\"{s}\",{s}}}",
            .{ openid_array, msgtype, payload },
        );
        defer self.allocator.free(json_body);

        return self.postMass(sendURLByOpenID, json_body);
    }

    fn postMass(self: *Self, url: []const u8, json_body: []const u8) !i64 {
        const Req = struct {
            url: []const u8,
            json_body: []const u8,

            pub fn send(c: @This(), a: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(a, "{s}?access_token={s}", .{ c.url, token });
                defer a.free(uri);

                const client = util_http.getDefaultClient(a);
                return client.postJSON(uri, c.json_body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "MassSend", Req{
            .url = url,
            .json_body = json_body,
        });
        defer self.allocator.free(resp);

        // errcode 已由 callApi 检查（非 0 直接 ApiError）。
        var parsed = std.json.parseFromSlice(struct {
            msg_id: i64 = 0,
            msg_data_id: i64 = 0,
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        return parsed.value.msg_id;
    }
};

/// 组装 `"<msgtype>":{...}` 消息体片段（纯函数，便于测试）。
///
/// 文本内容会做 JSON 转义；media 分支输出完整的 `{"media_id":"..."}` 对象
/// （修复了此前缺花括号导致的 `"mpnews":"media_id":"..."` 非法 JSON）。
fn buildPayloadJson(allocator: std.mem.Allocator, msgtype: []const u8, body: SendBody) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "\"");
    try buf.appendSlice(allocator, msgtype);
    try buf.appendSlice(allocator, "\":");
    switch (body) {
        .text => |t| {
            try buf.appendSlice(allocator, "{\"content\":\"");
            try appendJsonEscaped(allocator, &buf, t.content);
            try buf.appendSlice(allocator, "\"}");
        },
        .media_id => |m| {
            try buf.appendSlice(allocator, "{\"media_id\":\"");
            try appendJsonEscaped(allocator, &buf, m);
            try buf.appendSlice(allocator, "\"}");
        },
        .mpvideo => |v| {
            try buf.appendSlice(allocator, "{\"media_id\":\"");
            try appendJsonEscaped(allocator, &buf, v.media_id);
            try buf.appendSlice(allocator, "\",\"title\":\"");
            try appendJsonEscaped(allocator, &buf, v.title);
            try buf.appendSlice(allocator, "\",\"description\":\"");
            try appendJsonEscaped(allocator, &buf, v.description);
            try buf.appendSlice(allocator, "\"}");
        },
        .wxcard => |c| {
            try buf.appendSlice(allocator, "{\"card_id\":\"");
            try appendJsonEscaped(allocator, &buf, c.card_id);
            try buf.appendSlice(allocator, "\"}");
        },
        .images => |imgs| {
            // 与 Go 结构体全字段序列化一致（media_ids / recommend / need_open_comment / only_fans_can_comment）。
            try buf.appendSlice(allocator, "{\"media_ids\":[");
            for (imgs.media_ids, 0..) |mid, i| {
                if (i > 0) try buf.append(allocator, ',');
                try buf.append(allocator, '"');
                try appendJsonEscaped(allocator, &buf, mid);
                try buf.append(allocator, '"');
            }
            try buf.appendSlice(allocator, "],\"recommend\":\"");
            try appendJsonEscaped(allocator, &buf, imgs.recommend);
            try buf.appendSlice(allocator, "\",\"need_open_comment\":");
            var num_buf: [24]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d}", .{imgs.need_open_comment}) catch unreachable;
            try buf.appendSlice(allocator, num);
            try buf.appendSlice(allocator, ",\"only_fans_can_comment\":");
            const num2 = std.fmt.bufPrint(&num_buf, "{d}", .{imgs.only_fans_can_comment}) catch unreachable;
            try buf.appendSlice(allocator, num2);
            try buf.appendSlice(allocator, "}");
        },
    }
    return buf.toOwnedSlice(allocator);
}

/// 组装 openid 的 JSON 字符串数组（纯函数，元素做 JSON 转义）。
fn buildOpenidArrayJson(allocator: std.mem.Allocator, openids: []const []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (openids, 0..) |id, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try appendJsonEscaped(allocator, &buf, id);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

/// 追加 JSON 字符串转义内容（不包裹引号；实现收敛到 `util.json.appendEscapedString`）。
/// 群发正文 / 图文标题 / 描述直接来自调用方，此前漏转义 `c < 0x20` 控制字符。
const appendJsonEscaped = util_json.appendEscapedString;

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：假 AccessTokenHandle + capture transport。
// ─────────────────────────────────────────────────────────────────────────────

const credential = @import("../../credential/mod.zig");

const TestTokenState = struct {
    /// 当前（缓存中的）token；`invalidate` 后换成 `refreshed`。
    token: []const u8,
    /// 作废后换发的新 token（模拟微信换发）；`null` 表示作废后仍返回同一 token。
    refreshed: ?[]const u8 = null,
    /// `invalidate` 被调用的次数。
    invalidates: usize = 0,

    fn getAccessToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const state: *const TestTokenState = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, state.token);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const state: *TestTokenState = @ptrCast(@alignCast(ptr));
        state.invalidates += 1;
        if (state.refreshed) |t| {
            state.token = t;
            state.refreshed = null;
        }
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getAccessToken,
        .invalidate = invalidate,
    };
};

fn makeFakeTokenHandle(state: *TestTokenState) credential.AccessTokenHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &TestTokenState.vtable,
    };
}

const TestCapture = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    status: u16 = 200,
    method: std.http.Method = .POST,
    uri: []u8 = &.{},
    payload: []u8 = &.{},

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
        self.method = method;
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
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

/// 用 `MockTransport` 路由表替代 capture（按 URI 命中不同响应，见失效重试测试）。
fn setupMockClient(alloc: std.mem.Allocator, mt: *util_http.MockTransport) void {
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(mt));
}

test "Broadcast.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-bc" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const b = Broadcast.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-bc", b.ctx.config.app_id);
}

test "buildPayloadJson 文本分支转义特殊字符" {
    const allocator = std.testing.allocator;
    const payload = try buildPayloadJson(allocator, "text", .{ .text = .{ .content = "引\"号\\与\n换行" } });
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("\"text\":{\"content\":\"引\\\"号\\\\与\\n换行\"}", payload);
}

test "buildPayloadJson media 分支输出合法 JSON 对象" {
    const allocator = std.testing.allocator;
    // 回归：此前 media 分支缺花括号，生成 "mpnews":"media_id":"..." 非法 JSON。
    const payload = try buildPayloadJson(allocator, "mpnews", .{ .media_id = "MEDIA1" });
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("\"mpnews\":{\"media_id\":\"MEDIA1\"}", payload);
}

test "buildOpenidArrayJson 组装并转义 openid 数组" {
    const allocator = std.testing.allocator;
    const openids = [_][]const u8{ "o1\"x", "o2" };
    const arr = try buildOpenidArrayJson(allocator, &openids);
    defer allocator.free(arr);
    try std.testing.expectEqualStrings("[\"o1\\\"x\",\"o2\"]", arr);
}

test "Broadcast.sendNewsToTag 组装合法请求并返回 msg_id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10001,\"msg_data_id\":20002}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const msg_id = try b.sendNewsToTag(2, "MEDIA1");
    try std.testing.expectEqual(@as(i64, 10001), msg_id);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"filter\":{\"is_to_all\":false,\"tag_id\":2},\"msgtype\":\"mpnews\",\"mpnews\":{\"media_id\":\"MEDIA1\"}}",
        cap.payload,
    );
}

test "Broadcast.sendTextToOpenIDs 走 mass/send 且 touser 为数组" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10002}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const openids = [_][]const u8{ "openid-a", "openid-b" };
    const msg_id = try b.sendTextToOpenIDs(&openids, "你好");
    try std.testing.expectEqual(@as(i64, 10002), msg_id);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/send?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"touser\":[\"openid-a\",\"openid-b\"],\"msgtype\":\"text\",\"text\":{\"content\":\"你好\"}}",
        cap.payload,
    );
}

test "Broadcast errcode 非 0 返回 ApiError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    try std.testing.expectError(util_error.WechatError.ApiError, b.sendTextToTag(2, "x"));
}

test "Broadcast.sendVideoToOpenIDs 组装 mpvideo 且转义标题" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10003}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const openids = [_][]const u8{"openid-a"};
    const msg_id = try b.sendVideoToOpenIDs(&openids, "MEDIA_V", "标\"题", "第一\n段");
    try std.testing.expectEqual(@as(i64, 10003), msg_id);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/send?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"touser\":[\"openid-a\"],\"msgtype\":\"mpvideo\",\"mpvideo\":{\"media_id\":\"MEDIA_V\",\"title\":\"标\\\"题\",\"description\":\"第一\\n段\"}}",
        cap.payload,
    );
}

test "Broadcast.sendVideoToTag / sendVoiceToTag / sendWxCardToTag 消息体" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10004}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const cases = [_]struct {
        call: *const fn (*Broadcast) anyerror!i64,
        payload: []const u8,
    }{
        .{
            .call = struct {
                fn f(bb: *Broadcast) anyerror!i64 {
                    return bb.sendVideoToTag(3, "MV", "标题", "描述");
                }
            }.f,
            .payload = "{\"filter\":{\"is_to_all\":false,\"tag_id\":3},\"msgtype\":\"mpvideo\",\"mpvideo\":{\"media_id\":\"MV\",\"title\":\"标题\",\"description\":\"描述\"}}",
        },
        .{
            .call = struct {
                fn f(bb: *Broadcast) anyerror!i64 {
                    return bb.sendVoiceToTag(3, "VOICE1");
                }
            }.f,
            .payload = "{\"filter\":{\"is_to_all\":false,\"tag_id\":3},\"msgtype\":\"voice\",\"voice\":{\"media_id\":\"VOICE1\"}}",
        },
        .{
            .call = struct {
                fn f(bb: *Broadcast) anyerror!i64 {
                    return bb.sendWxCardToTag(3, "CARD1");
                }
            }.f,
            .payload = "{\"filter\":{\"is_to_all\":false,\"tag_id\":3},\"msgtype\":\"wxcard\",\"wxcard\":{\"card_id\":\"CARD1\"}}",
        },
    };

    for (cases) |case| {
        const msg_id = try case.call(&b);
        try std.testing.expectEqual(@as(i64, 10004), msg_id);
        try std.testing.expectEqualStrings(
            "https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=stub-ak",
            cap.uri,
        );
        try std.testing.expectEqualStrings(case.payload, cap.payload);
    }
}

test "Broadcast.sendVoiceToOpenIDs / sendWxCardToOpenIDs 走 mass/send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10005}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const openids = [_][]const u8{ "o1", "o2" };

    _ = try b.sendVoiceToOpenIDs(&openids, "V1");
    try std.testing.expectEqualStrings(
        "{\"touser\":[\"o1\",\"o2\"],\"msgtype\":\"voice\",\"voice\":{\"media_id\":\"V1\"}}",
        cap.payload,
    );

    _ = try b.sendWxCardToOpenIDs(&openids, "C1");
    try std.testing.expectEqualStrings(
        "{\"touser\":[\"o1\",\"o2\"],\"msgtype\":\"wxcard\",\"wxcard\":{\"card_id\":\"C1\"}}",
        cap.payload,
    );
}

test "Broadcast.delete 请求 mass/delete 且校验响应" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    try b.delete(100, 1);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/delete?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"msg_id\":100,\"article_idx\":1}", cap.payload);

    cap.response = "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}";
    try std.testing.expectError(util_error.WechatError.ApiError, b.delete(100, 0));
}

test "Broadcast.getMassStatus 返回 msg_status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"msg_id\":100,\"msg_status\":\"SEND_SUCCESS\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const status = try b.getMassStatus("100");
    defer alloc.free(status);
    try std.testing.expectEqualStrings("SEND_SUCCESS", status);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/get?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"msg_id\":\"100\"}", cap.payload);

    cap.response = "{\"errcode\":45009,\"errmsg\":\"quota\"}";
    try std.testing.expectError(util_error.WechatError.ApiError, b.getMassStatus("100"));
}

test "Broadcast.getSpeed/setSpeed 请求与解析" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"speed\":4,\"realspeed\":3}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const got = try b.getSpeed();
    try std.testing.expectEqual(@as(i64, 4), got.speed);
    try std.testing.expectEqual(@as(i64, 3), got.realspeed);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/speed/get?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{}", cap.payload);

    cap.response = "{\"speed\":2,\"realspeed\":2}";
    const set = try b.setSpeed(2);
    try std.testing.expectEqual(@as(i64, 2), set.speed);
    try std.testing.expectEqual(@as(i64, 2), set.realspeed);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/speed/set?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"speed\":2}", cap.payload);

    cap.response = "{\"errcode\":40013,\"errmsg\":\"invalid appid\"}";
    try std.testing.expectError(util_error.WechatError.ApiError, b.setSpeed(5));
}

test "buildPayloadJson images 分支全字段输出且转义" {
    const allocator = std.testing.allocator;
    const media_ids = [_][]const u8{ "M1\"x", "M2" };
    const payload = try buildPayloadJson(allocator, "image", .{
        .images = .{ .media_ids = &media_ids, .recommend = "推\n荐" },
    });
    defer allocator.free(payload);
    try std.testing.expectEqualStrings(
        "\"image\":{\"media_ids\":[\"M1\\\"x\",\"M2\"],\"recommend\":\"推\\n荐\",\"need_open_comment\":0,\"only_fans_can_comment\":0}",
        payload,
    );
}

test "Broadcast.sendImageToTag / sendImageToOpenIDs 组装 images 消息体" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10010}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const media_ids = [_][]const u8{ "IMG1", "IMG2" };
    const msg_id = try b.sendImageToTag(7, .{ .media_ids = &media_ids, .need_open_comment = 1 });
    try std.testing.expectEqual(@as(i64, 10010), msg_id);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"filter\":{\"is_to_all\":false,\"tag_id\":7},\"msgtype\":\"image\",\"image\":{\"media_ids\":[\"IMG1\",\"IMG2\"],\"recommend\":\"\",\"need_open_comment\":1,\"only_fans_can_comment\":0}}",
        cap.payload,
    );

    const openids = [_][]const u8{"o1"};
    _ = try b.sendImageToOpenIDs(&openids, .{ .media_ids = &media_ids });
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/send?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"touser\":[\"o1\"],\"msgtype\":\"image\",\"image\":{\"media_ids\":[\"IMG1\",\"IMG2\"],\"recommend\":\"\",\"need_open_comment\":0,\"only_fans_can_comment\":0}}",
        cap.payload,
    );

    cap.response = "{\"errcode\":40009,\"errmsg\":\"invalid media_id\"}";
    try std.testing.expectError(
        util_error.WechatError.ApiError,
        b.sendImageToOpenIDs(&openids, .{ .media_ids = &media_ids }),
    );
}

test "Broadcast.previewToUser to_openid 文本预览走 mass/preview" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const msg_id = try b.previewToUser("text", .{ .text = .{ .content = "预览\"内容" } }, .{ .to_openid = "openid-x" });
    try std.testing.expectEqual(@as(i64, 0), msg_id);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/preview?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"touser\":\"openid-x\",\"msgtype\":\"text\",\"text\":{\"content\":\"预览\\\"内容\"}}",
        cap.payload,
    );
}

test "Broadcast.previewToUser to_wxname 图片预览（对照 Go Preview().SendImage 取首个 media_id）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    _ = try b.previewToUser("image", .{ .media_id = "IMG_FIRST" }, .{ .to_wxname = "gh_wx\"name" });
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/preview?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"towxname\":\"gh_wx\\\"name\",\"msgtype\":\"image\",\"image\":{\"media_id\":\"IMG_FIRST\"}}",
        cap.payload,
    );

    cap.response = "{\"errcode\":43004,\"errmsg\":\"require subscribe\"}";
    try std.testing.expectError(
        util_error.WechatError.ApiError,
        b.previewToUser("text", .{ .text = .{ .content = "x" } }, .{ .to_openid = "o1" }),
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// 全员群发（filter.is_to_all = true）测试
//
// 对照 Go `chooseTagOrOpenID`：`user == nil` 时 filter 只有 `is_to_all: true`，
// 请求仍发往 `mass/sendall`（`sendURLByTag`），且不带 `tag_id` / `touser`。
// ─────────────────────────────────────────────────────────────────────────────

/// 断言全员群发请求体形状：filter 仅含 is_to_all，且无 tag_id / touser。
fn expectAllMassBody(payload: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"filter\":{\"is_to_all\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "tag_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "touser") == null);
}

test "Broadcast.sendTextToAll 全员群发文本走 mass/sendall" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10020,\"msg_data_id\":20020}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const msg_id = try b.sendTextToAll("全员\"文本\n第二行");
    try std.testing.expectEqual(@as(i64, 10020), msg_id);
    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"filter\":{\"is_to_all\":true},\"msgtype\":\"text\",\"text\":{\"content\":\"全员\\\"文本\\n第二行\"}}",
        cap.payload,
    );
    try expectAllMassBody(cap.payload);
}

test "Broadcast.sendNewsToAll 全员群发图文并支持 send_ignore_reprint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10021}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const msg_id = try b.sendNewsToAll("MEDIA_N", true);
    try std.testing.expectEqual(@as(i64, 10021), msg_id);
    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"filter\":{\"is_to_all\":true},\"msgtype\":\"mpnews\",\"mpnews\":{\"media_id\":\"MEDIA_N\"},\"send_ignore_reprint\":1}",
        cap.payload,
    );
    try expectAllMassBody(cap.payload);

    // ignore_reprint = false 时省略 send_ignore_reprint（对照 Go 的 omitempty）。
    _ = try b.sendNewsToAll("MEDIA_N", false);
    try std.testing.expectEqualStrings(
        "{\"filter\":{\"is_to_all\":true},\"msgtype\":\"mpnews\",\"mpnews\":{\"media_id\":\"MEDIA_N\"}}",
        cap.payload,
    );
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "send_ignore_reprint") == null);
    try expectAllMassBody(cap.payload);
}

test "Broadcast.sendVoiceToAll / sendVideoToAll / sendWxCardToAll 全员消息体" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10022}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const cases = [_]struct {
        call: *const fn (*Broadcast) anyerror!i64,
        payload: []const u8,
    }{
        .{
            .call = struct {
                fn f(bb: *Broadcast) anyerror!i64 {
                    return bb.sendVoiceToAll("VOICE_ALL");
                }
            }.f,
            .payload = "{\"filter\":{\"is_to_all\":true},\"msgtype\":\"voice\",\"voice\":{\"media_id\":\"VOICE_ALL\"}}",
        },
        .{
            .call = struct {
                fn f(bb: *Broadcast) anyerror!i64 {
                    return bb.sendVideoToAll("VIDEO_ALL", "标\"题", "描\n述");
                }
            }.f,
            .payload = "{\"filter\":{\"is_to_all\":true},\"msgtype\":\"mpvideo\",\"mpvideo\":{\"media_id\":\"VIDEO_ALL\",\"title\":\"标\\\"题\",\"description\":\"描\\n述\"}}",
        },
        .{
            .call = struct {
                fn f(bb: *Broadcast) anyerror!i64 {
                    return bb.sendWxCardToAll("CARD_ALL");
                }
            }.f,
            .payload = "{\"filter\":{\"is_to_all\":true},\"msgtype\":\"wxcard\",\"wxcard\":{\"card_id\":\"CARD_ALL\"}}",
        },
    };

    for (cases) |case| {
        const msg_id = try case.call(&b);
        try std.testing.expectEqual(@as(i64, 10022), msg_id);
        try std.testing.expectEqual(std.http.Method.POST, cap.method);
        try std.testing.expectEqualStrings(
            "https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=stub-ak",
            cap.uri,
        );
        try std.testing.expectEqualStrings(case.payload, cap.payload);
        try expectAllMassBody(cap.payload);
    }
}

test "Broadcast.sendImageToAll 全员群发图片（images 全字段）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10023}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const media_ids = [_][]const u8{ "IMG_A", "IMG_B" };
    const msg_id = try b.sendImageToAll(.{
        .media_ids = &media_ids,
        .recommend = "推荐\"语",
        .need_open_comment = 1,
        .only_fans_can_comment = 0,
    });
    try std.testing.expectEqual(@as(i64, 10023), msg_id);
    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"filter\":{\"is_to_all\":true},\"msgtype\":\"image\",\"image\":{\"media_ids\":[\"IMG_A\",\"IMG_B\"],\"recommend\":\"推荐\\\"语\",\"need_open_comment\":1,\"only_fans_can_comment\":0}}",
        cap.payload,
    );
    try expectAllMassBody(cap.payload);
}

test "Broadcast 全员群发 errcode 非 0 → ApiError（6 个方法全覆盖）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, alloc);

    const calls = [_]*const fn (*Broadcast) anyerror!i64{
        struct {
            fn f(bb: *Broadcast) anyerror!i64 {
                return bb.sendTextToAll("x");
            }
        }.f,
        struct {
            fn f(bb: *Broadcast) anyerror!i64 {
                return bb.sendNewsToAll("M", true);
            }
        }.f,
        struct {
            fn f(bb: *Broadcast) anyerror!i64 {
                return bb.sendVoiceToAll("V");
            }
        }.f,
        struct {
            fn f(bb: *Broadcast) anyerror!i64 {
                return bb.sendVideoToAll("V", "t", "d");
            }
        }.f,
        struct {
            fn f(bb: *Broadcast) anyerror!i64 {
                return bb.sendWxCardToAll("C");
            }
        }.f,
        struct {
            fn f(bb: *Broadcast) anyerror!i64 {
                const media_ids = [_][]const u8{"IMG"};
                return bb.sendImageToAll(.{ .media_ids = &media_ids });
            }
        }.f,
    };

    for (calls) |call| {
        try std.testing.expectError(util_error.WechatError.ApiError, call(&b));
        try expectAllMassBody(cap.payload);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// token 失效自愈 / 非 token 错误不重试（`util/retry.callApi` 契约）
// ─────────────────────────────────────────────────────────────────────────────

test "Broadcast token 失效自愈：40001 → 作废缓存 → 新 token 重试成功" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=old-ak", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential, access_token is invalid or not latest\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=new-ak", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"msg_id\":10001}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, allocator);

    try std.testing.expectEqual(@as(i64, 10001), try b.sendTextToTag(2, "x"));
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[0], "access_token=old-ak") != null);
    try std.testing.expect(std.mem.indexOf(u8, mt.history.items[1], "access_token=new-ak") != null);
}

test "Broadcast.getMassStatus 走 token 失效自愈后仍解析 msg_status" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/get?access_token=old-ak", .{
        .body = "{\"errcode\":40014,\"errmsg\":\"invalid access_token\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/get?access_token=new-ak", .{
        .body = "{\"msg_id\":100,\"msg_status\":\"SEND_SUCCESS\"}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, allocator);

    const status = try b.getMassStatus("100");
    defer allocator.free(status);

    try std.testing.expectEqualStrings("SEND_SUCCESS", status);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
}

test "Broadcast.delete 走 token 失效自愈（void 返回不泄漏）" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/delete?access_token=old-ak", .{
        .body = "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/delete?access_token=new-ak", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, allocator);

    try b.delete(100, 1);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
}

test "Broadcast.getSpeed 走 token 失效自愈后仍解析 speed" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/speed/get?access_token=old-ak", .{
        .body = "{\"errcode\":41001,\"errmsg\":\"access_token missing\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/speed/get?access_token=new-ak", .{
        .body = "{\"speed\":4,\"realspeed\":3}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, allocator);

    const got = try b.getSpeed();
    try std.testing.expectEqual(@as(i64, 4), got.speed);
    try std.testing.expectEqual(@as(i64, 3), got.realspeed);
    try std.testing.expectEqual(@as(usize, 1), state.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
}

test "Broadcast 非 token 类 errcode（45009）直接 ApiError：不作废、只请求一次" {
    const allocator = std.testing.allocator;

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/cgi-bin/message/mass/sendall?access_token=old-ak", .{
        .body = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    });
    setupMockClient(allocator, &mt);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "old-ak", .refreshed = "new-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var b = Broadcast.init(&ctx, allocator);

    try std.testing.expectError(util_error.WechatError.ApiError, b.sendTextToAll("x"));
    try std.testing.expectEqual(@as(usize, 0), state.invalidates);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}
