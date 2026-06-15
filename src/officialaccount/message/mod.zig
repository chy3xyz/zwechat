//! officialaccount/message — 消息相关 API
//!
//! 对应 `_ref/wechat/officialaccount/message/`：
//! - 消息 / 事件类型常量
//! - MixMessage 通用接收结构（消息解析需要 XML codec，下一波引入）
//! - TemplateMessage 发送接口（客服消息 / 模板消息的发送）

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_xml = @import("../../util/xml.zig");

/// 消息类型（与 Go `MsgType` 一一对应）。
pub const MsgType = enum {
    text,
    image,
    voice,
    video,
    miniprogrampage,
    shortvideo,
    location,
    link,
    music,
    news,
    transfer_customer_service,
    event,
};

/// 事件类型（与 Go `EventType` 一一对应）。
pub const EventType = enum {
    subscribe,
    unsubscribe,
    scan,
    location,
    click,
    view,
    scancode_push,
    scancode_waitmsg,
    pic_sysphoto,
    pic_photo_or_album,
    pic_weixin,
    location_select,
    view_miniprogram,
    template_send_job_finish,
    mass_send_job_finish,
    wxa_media_check,
    subscribe_msg_popup_event,
    publish_job_finish,
    weapp_audit_success,
    weapp_audit_fail,
    weapp_audit_delay,
};

/// 微信推送的通用消息头（与 Go `CommonToken` 对应）。
pub const CommonToken = struct {
    to_user_name: []const u8 = "",
    from_user_name: []const u8 = "",
    create_time: i64 = 0,
    msg_type: MsgType = .text,
};

/// `MixMessage` 是所有微信推送消息的统一载体。
/// 字段命名采用 snake_case 以匹配后续 XML/JSON 解析（实际 XML 解析需要 `util.xml` codec）。
pub const MixMessage = struct {
    common: CommonToken = .{},

    msg_id: i64 = 0,
    template_msg_id: i64 = 0,
    content: []const u8 = "",
    recognition: []const u8 = "",
    pic_url: []const u8 = "",
    media_id: []const u8 = "",
    format: []const u8 = "",
    thumb_media_id: []const u8 = "",
    location_x: f64 = 0.0,
    location_y: f64 = 0.0,
    scale: f64 = 0.0,
    label: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    url: []const u8 = "",

    event: ?EventType = null,
    event_key: []const u8 = "",
    ticket: []const u8 = "",
    menu_id: []const u8 = "",

    union_id: []const u8 = "",
};

/// `EncryptedXMLMsg` — 安全模式（消息加密）下收到的消息体。
pub const EncryptedXMLMsg = struct {
    to_user_name: []const u8 = "",
    encrypted_msg: []const u8 = "",
};

/// 被动回复类型枚举（与 Go `MsgType` 一致）。
pub const ReplyMsgType = enum {
    text,
    image,
    voice,
    video,
    music,
    news,
    transfer_customer_service,
};

/// `TextReply` — 文本被动回复载荷。
pub const TextReply = struct {
    content: []const u8,
};

/// `ImageReply` — 图片被动回复。
pub const ImageReply = struct {
    media_id: []const u8,
};

/// `VoiceReply` — 语音被动回复。
pub const VoiceReply = struct {
    media_id: []const u8,
};

/// `VideoReply` — 视频被动回复。
pub const VideoReply = struct {
    media_id: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
};

/// `MusicReply` — 音乐被动回复。
pub const MusicReply = struct {
    thumb_media_id: []const u8,
    title: []const u8 = "",
    description: []const u8 = "",
    music_url: []const u8 = "",
    hq_music_url: []const u8 = "",
};

/// `NewsArticle` — 图文单条。
pub const NewsArticle = struct {
    title: []const u8,
    description: []const u8 = "",
    pic_url: []const u8 = "",
    url: []const u8 = "",
};

/// `NewsReply` — 图文被动回复（最多 10 条）。
pub const NewsReply = struct {
    articles: []const NewsArticle,
};

/// `MiniprogramPageReply` — 小程序卡片（客服消息 / 模板消息用）。
pub const MiniprogramPageReply = struct {
    title: []const u8,
    appid: []const u8,
    pagepath: []const u8,
    thumb_media_id: []const u8,
};

/// 被动回复的统一结构（与上游 Go `message.Reply` 对应）。
pub const Reply = struct {
    msg_type: ReplyMsgType,
    /// 载荷 — 根据 msg_type 选择对应的具体类型。
    data: ReplyData,

    pub const ReplyData = union(enum) {
        text: TextReply,
        image: ImageReply,
        voice: VoiceReply,
        video: VideoReply,
        music: MusicReply,
        news: NewsReply,
        miniprogrampage: MiniprogramPageReply,
        transfer: void,
        /// 用户自行构造好的完整 XML（最灵活 — 任何未实现的类型都可以走这里）。
        raw_xml: RawXmlPayload,
    };

    pub const RawXmlPayload = struct {
        content: []const u8,
    };

    pub fn format(self: Reply, allocator: std.mem.Allocator, to_user: []const u8, from_user: []const u8) ![]u8 {
        return switch (self.data) {
            .text => |t| formatText(allocator, to_user, from_user, t.content),
            .image => |i| formatImage(allocator, to_user, from_user, i.media_id),
            .voice => |v| formatVoice(allocator, to_user, from_user, v.media_id),
            .video => |v| formatVideo(allocator, to_user, from_user, v.media_id, v.title, v.description),
            .music => |m| formatMusic(allocator, to_user, from_user, m),
            .news => |n| formatNews(allocator, to_user, from_user, n.articles),
            .miniprogrampage => |mp| formatMiniprogramPage(allocator, to_user, from_user, mp),
            .transfer => formatTransfer(allocator, to_user, from_user),
            .raw_xml => |r| allocator.dupe(u8, r.content) catch @as(anyerror![]u8, error.OutOfMemory),
        };
    }
};

/// 序列化为微信被动回复的文本 XML（明文模式）。
fn formatText(allocator: std.mem.Allocator, to: []const u8, from: []const u8, content: []const u8) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    const elements = [_]util_xml.XmlElement{
        .{ .key = "ToUserName", .value = to },
        .{ .key = "FromUserName", .value = from },
        .{ .key = "CreateTime", .value = ts_str },
        .{ .key = "MsgType", .value = "text" },
        .{ .key = "Content", .value = content },
    };
    return util_xml.serialize(allocator, "xml", &elements);
}

fn formatImage(allocator: std.mem.Allocator, to: []const u8, from: []const u8, media_id: []const u8) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    const elements = [_]util_xml.XmlElement{
        .{ .key = "ToUserName", .value = to },
        .{ .key = "FromUserName", .value = from },
        .{ .key = "CreateTime", .value = ts_str },
        .{ .key = "MsgType", .value = "image" },
        .{ .key = "Image", .value = "" },
        .{ .key = "MediaId", .value = media_id },
    };
    return util_xml.serialize(allocator, "xml", &elements);
}

fn formatTransfer(allocator: std.mem.Allocator, to: []const u8, from: []const u8) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    const elements = [_]util_xml.XmlElement{
        .{ .key = "ToUserName", .value = to },
        .{ .key = "FromUserName", .value = from },
        .{ .key = "CreateTime", .value = ts_str },
        .{ .key = "MsgType", .value = "transfer_customer_service" },
    };
    return util_xml.serialize(allocator, "xml", &elements);
}

fn formatVoice(allocator: std.mem.Allocator, to: []const u8, from: []const u8, media_id: []const u8) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    const elements = [_]util_xml.XmlElement{
        .{ .key = "ToUserName", .value = to },
        .{ .key = "FromUserName", .value = from },
        .{ .key = "CreateTime", .value = ts_str },
        .{ .key = "MsgType", .value = "voice" },
        .{ .key = "Voice", .value = "" },
        .{ .key = "MediaId", .value = media_id },
    };
    return util_xml.serialize(allocator, "xml", &elements);
}

fn formatVideo(allocator: std.mem.Allocator, to: []const u8, from: []const u8, media_id: []const u8, title: []const u8, description: []const u8) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    const elements = [_]util_xml.XmlElement{
        .{ .key = "ToUserName", .value = to },
        .{ .key = "FromUserName", .value = from },
        .{ .key = "CreateTime", .value = ts_str },
        .{ .key = "MsgType", .value = "video" },
        .{ .key = "Video", .value = "" },
        .{ .key = "MediaId", .value = media_id },
        .{ .key = "Title", .value = title },
        .{ .key = "Description", .value = description },
    };
    return util_xml.serialize(allocator, "xml", &elements);
}

fn formatMusic(allocator: std.mem.Allocator, to: []const u8, from: []const u8, m: MusicReply) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "<xml><ToUserName><![CDATA[{s}]]></ToUserName>", .{to});
    try buf.print(allocator, "<FromUserName><![CDATA[{s}]]></FromUserName>", .{from});
    try buf.print(allocator, "<CreateTime>{s}</CreateTime>", .{ts_str});
    try buf.print(allocator, "<MsgType><![CDATA[music]]></MsgType>", .{});
    try buf.print(allocator, "<Music><Title><![CDATA[{s}]]></Title><Description><![CDATA[{s}]]></Description>", .{ m.title, m.description });
    try buf.print(allocator, "<MusicUrl><![CDATA[{s}]]></MusicUrl><HQMusicUrl><![CDATA[{s}]]></HQMusicUrl>", .{ m.music_url, m.hq_music_url });
    try buf.print(allocator, "<ThumbMediaId><![CDATA[{s}]]></ThumbMediaId></Music></xml>", .{m.thumb_media_id});
    return buf.toOwnedSlice(allocator);
}

fn formatNews(allocator: std.mem.Allocator, to: []const u8, from: []const u8, articles: []const NewsArticle) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "<xml><ToUserName><![CDATA[{s}]]></ToUserName>", .{to});
    try buf.print(allocator, "<FromUserName><![CDATA[{s}]]></FromUserName>", .{from});
    try buf.print(allocator, "<CreateTime>{s}</CreateTime>", .{ts_str});
    try buf.print(allocator, "<MsgType><![CDATA[news]]></MsgType><ArticleCount>{d}</ArticleCount><Articles>", .{articles.len});
    for (articles) |a| {
        try buf.print(allocator, "<item><Title><![CDATA[{s}]]></Title><Description><![CDATA[{s}]]></Description>", .{ a.title, a.description });
        try buf.print(allocator, "<PicUrl><![CDATA[{s}]]></PicUrl><Url><![CDATA[{s}]]></Url></item>", .{ a.pic_url, a.url });
    }
    try buf.appendSlice(allocator, "</Articles></xml>");
    return buf.toOwnedSlice(allocator);
}

fn formatMiniprogramPage(allocator: std.mem.Allocator, to: []const u8, from: []const u8, mp: MiniprogramPageReply) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    const elements = [_]util_xml.XmlElement{
        .{ .key = "ToUserName", .value = to },
        .{ .key = "FromUserName", .value = from },
        .{ .key = "CreateTime", .value = ts_str },
        .{ .key = "MsgType", .value = "miniprogrampage" },
        .{ .key = "Title", .value = mp.title },
        .{ .key = "AppId", .value = mp.appid },
        .{ .key = "PagePath", .value = mp.pagepath },
        .{ .key = "ThumbMediaId", .value = mp.thumb_media_id },
    };
    return util_xml.serialize(allocator, "xml", &elements);
}

/// 模板消息数据结构（用于 `SendTemplate`）。
pub const TemplateMessage = struct {
    to_user: []const u8,
    template_id: []const u8,
    url: []const u8 = "",
    miniprogram: ?Miniprogram = null,
    data: []const TemplateData,

    pub const Miniprogram = struct {
        appid: []const u8,
        pagepath: []const u8,
    };

    pub const TemplateData = struct {
        key: []const u8,
        value: []const u8,
        color: []const u8 = "",
    };
};

/// 客服消息 — 文本。
pub const CustomerTextMessage = struct {
    touser: []const u8,
    content: []const u8,
};

pub const Message = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 发送模板消息。
    pub fn sendTemplate(self: *Self, msg: TemplateMessage) !i64 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ templateSendURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try serializeTemplate(self.allocator, msg);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            msgid: i64 = 0,
        }, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value.msgid;
    }

    /// 发送客服文本消息。
    pub fn sendCustomerText(self: *Self, msg: CustomerTextMessage) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ customSendURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"touser\":\"{s}\",\"msgtype\":\"text\",\"text\":{{\"content\":\"{s}\"}}}}",
            .{ msg.touser, msg.content },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "SendCustomerText")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    fn serializeTemplate(allocator: std.mem.Allocator, msg: TemplateMessage) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.writer.print("{{\"touser\":\"{s}\",\"template_id\":\"{s}\"", .{ msg.to_user, msg.template_id });
        if (msg.url.len > 0) {
            try buf.writer.print(",\"url\":\"{s}\"", .{msg.url});
        }
        if (msg.miniprogram) |mp| {
            try buf.writer.print(",\"miniprogram\":{{\"appid\":\"{s}\",\"pagepath\":\"{s}\"}}", .{ mp.appid, mp.pagepath });
        }
        try buf.appendSlice(allocator, ",\"data\":{");
        for (msg.data, 0..) |d, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.writer.print("\"{s}\":{{\"value\":\"{s}\"", .{ d.key, d.value });
            if (d.color.len > 0) try buf.writer.print(",\"color\":\"{s}\"", .{d.color});
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, '}');
        try buf.append(allocator, '}');
        return buf.toOwnedSlice(allocator);
    }
};

pub const templateSendURL = "https://api.weixin.qq.com/cgi-bin/message/template/send";
pub const customSendURL = "https://api.weixin.qq.com/cgi-bin/message/custom/send";

test "MsgType 枚举值" {
    try std.testing.expectEqualStrings("text", @tagName(MsgType.text));
    try std.testing.expectEqualStrings("event", @tagName(MsgType.event));
    try std.testing.expectEqualStrings("transfer_customer_service", @tagName(MsgType.transfer_customer_service));
}

test "EventType 枚举值" {
    try std.testing.expectEqualStrings("subscribe", @tagName(EventType.subscribe));
    try std.testing.expectEqualStrings("template_send_job_finish", @tagName(EventType.template_send_job_finish));
}

test "CommonToken 默认值" {
    const c = CommonToken{};
    try std.testing.expectEqual(MsgType.text, c.msg_type);
    try std.testing.expectEqualStrings("", c.to_user_name);
}

test "URL 常量值" {
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/message/template/send", templateSendURL);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/message/custom/send", customSendURL);
}