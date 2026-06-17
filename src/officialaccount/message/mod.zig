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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "<xml><ToUserName><![CDATA[{s}]]></ToUserName>", .{to});
    try buf.print(allocator, "<FromUserName><![CDATA[{s}]]></FromUserName>", .{from});
    try buf.print(allocator, "<CreateTime>{s}</CreateTime>", .{ts_str});
    try buf.print(allocator, "<MsgType><![CDATA[image]]></MsgType>", .{});
    try buf.print(allocator, "<Image><MediaId><![CDATA[{s}]]></MediaId></Image></xml>", .{media_id});
    return buf.toOwnedSlice(allocator);
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "<xml><ToUserName><![CDATA[{s}]]></ToUserName>", .{to});
    try buf.print(allocator, "<FromUserName><![CDATA[{s}]]></FromUserName>", .{from});
    try buf.print(allocator, "<CreateTime>{s}</CreateTime>", .{ts_str});
    try buf.print(allocator, "<MsgType><![CDATA[voice]]></MsgType>", .{});
    try buf.print(allocator, "<Voice><MediaId><![CDATA[{s}]]></MediaId></Voice></xml>", .{media_id});
    return buf.toOwnedSlice(allocator);
}

fn formatVideo(allocator: std.mem.Allocator, to: []const u8, from: []const u8, media_id: []const u8, title: []const u8, description: []const u8) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "<xml><ToUserName><![CDATA[{s}]]></ToUserName>", .{to});
    try buf.print(allocator, "<FromUserName><![CDATA[{s}]]></FromUserName>", .{from});
    try buf.print(allocator, "<CreateTime>{s}</CreateTime>", .{ts_str});
    try buf.print(allocator, "<MsgType><![CDATA[video]]></MsgType>", .{});
    try buf.print(allocator, "<Video><MediaId><![CDATA[{s}]]></MediaId>", .{media_id});
    try buf.print(allocator, "<Title><![CDATA[{s}]]></Title>", .{title});
    try buf.print(allocator, "<Description><![CDATA[{s}]]></Description></Video></xml>", .{description});
    return buf.toOwnedSlice(allocator);
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "<xml><ToUserName><![CDATA[{s}]]></ToUserName>", .{to});
    try buf.print(allocator, "<FromUserName><![CDATA[{s}]]></FromUserName>", .{from});
    try buf.print(allocator, "<CreateTime>{s}</CreateTime>", .{ts_str});
    try buf.print(allocator, "<MsgType><![CDATA[miniprogrampage]]></MsgType>", .{});
    try buf.print(allocator, "<MiniprogramPage><Title><![CDATA[{s}]]></Title>", .{mp.title});
    try buf.print(allocator, "<AppId><![CDATA[{s}]]></AppId>", .{mp.appid});
    try buf.print(allocator, "<PagePath><![CDATA[{s}]]></PagePath>", .{mp.pagepath});
    try buf.print(allocator, "<ThumbMediaId><![CDATA[{s}]]></ThumbMediaId></MiniprogramPage></xml>", .{mp.thumb_media_id});
    return buf.toOwnedSlice(allocator);
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

        const body = try serializeCustomerText(self.allocator, msg);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "SendCustomerText")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    fn serializeTemplate(allocator: std.mem.Allocator, msg: TemplateMessage) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };

        try s.beginObject();
        try s.objectField("touser");
        try s.write(msg.to_user);
        try s.objectField("template_id");
        try s.write(msg.template_id);
        if (msg.url.len > 0) {
            try s.objectField("url");
            try s.write(msg.url);
        }
        if (msg.miniprogram) |mp| {
            try s.objectField("miniprogram");
            try s.beginObject();
            try s.objectField("appid");
            try s.write(mp.appid);
            try s.objectField("pagepath");
            try s.write(mp.pagepath);
            try s.endObject();
        }
        try s.objectField("data");
        try s.beginObject();
        for (msg.data) |d| {
            try s.objectField(d.key);
            try s.beginObject();
            try s.objectField("value");
            try s.write(d.value);
            if (d.color.len > 0) {
                try s.objectField("color");
                try s.write(d.color);
            }
            try s.endObject();
        }
        try s.endObject();
        try s.endObject();

        return out.toOwnedSlice();
    }
};

fn serializeCustomerText(allocator: std.mem.Allocator, msg: CustomerTextMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("touser");
    try s.write(msg.touser);
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

test "serializeTemplate produces valid JSON and escapes quotes" {
    const allocator = std.testing.allocator;
    const msg = TemplateMessage{
        .to_user = "user\"quote",
        .template_id = "tid123",
        .url = "https://example.com",
        .miniprogram = .{
            .appid = "wx_appid",
            .pagepath = "pages/index",
        },
        .data = &.{
            .{ .key = "first", .value = "hello \"world\"", .color = "#FF0000" },
            .{ .key = "keyword1", .value = "line1\nline2", .color = "" },
        },
    };
    const body = try Message.serializeTemplate(allocator, msg);
    defer allocator.free(body);

    // 验证特殊字符被正确转义。
    try std.testing.expect(std.mem.indexOf(u8, body, "user\\\"quote") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello \\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "line1\\nline2") != null);

    // 验证 JSON 可解析且结构正确。
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("user\"quote", parsed.value.object.get("touser").?.string);
    try std.testing.expectEqualStrings("tid123", parsed.value.object.get("template_id").?.string);
    try std.testing.expectEqualStrings("https://example.com", parsed.value.object.get("url").?.string);
    const mp = parsed.value.object.get("miniprogram").?.object;
    try std.testing.expectEqualStrings("wx_appid", mp.get("appid").?.string);
    try std.testing.expectEqualStrings("pages/index", mp.get("pagepath").?.string);
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("hello \"world\"", data.get("first").?.object.get("value").?.string);
    try std.testing.expectEqualStrings("#FF0000", data.get("first").?.object.get("color").?.string);
    try std.testing.expectEqualStrings("line1\nline2", data.get("keyword1").?.object.get("value").?.string);
    try std.testing.expect(data.get("keyword1").?.object.get("color") == null);
}

test "serializeCustomerText produces valid JSON and escapes content" {
    const allocator = std.testing.allocator;
    const msg = CustomerTextMessage{
        .touser = "user\"test",
        .content = "say \"hi\"",
    };
    const body = try serializeCustomerText(allocator, msg);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "user\\\"test") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "say \\\"hi\\\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("user\"test", parsed.value.object.get("touser").?.string);
    try std.testing.expectEqualStrings("text", parsed.value.object.get("msgtype").?.string);
    try std.testing.expectEqualStrings("say \"hi\"", parsed.value.object.get("text").?.object.get("content").?.string);
}

test "Reply.format image produces nested XML" {
    const allocator = std.testing.allocator;
    const reply = Reply{
        .msg_type = .image,
        .data = .{ .image = .{ .media_id = "media_123" } },
    };
    const xml = try reply.format(allocator, "toUser", "fromUser");
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Image><MediaId><![CDATA[media_123]]></MediaId></Image>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<MsgType><![CDATA[image]]></MsgType>") != null);
}

test "Reply.format voice produces nested XML" {
    const allocator = std.testing.allocator;
    const reply = Reply{
        .msg_type = .voice,
        .data = .{ .voice = .{ .media_id = "voice_123" } },
    };
    const xml = try reply.format(allocator, "toUser", "fromUser");
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Voice><MediaId><![CDATA[voice_123]]></MediaId></Voice>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<MsgType><![CDATA[voice]]></MsgType>") != null);
}

test "Reply.format video produces nested XML" {
    const allocator = std.testing.allocator;
    const reply = Reply{
        .msg_type = .video,
        .data = .{ .video = .{ .media_id = "video_123", .title = "title\"x", .description = "desc\\y" } },
    };
    const xml = try reply.format(allocator, "toUser", "fromUser");
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Video><MediaId><![CDATA[video_123]]></MediaId>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Title><![CDATA[title\"x]]></Title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Description><![CDATA[desc\\y]]></Description></Video>") != null);
}

test "Reply.format miniprogrampage produces nested XML" {
    const allocator = std.testing.allocator;
    const reply = Reply{
        .msg_type = .text,
        .data = .{ .miniprogrampage = .{
            .title = "title",
            .appid = "appid",
            .pagepath = "pages/index",
            .thumb_media_id = "thumb_123",
        } },
    };
    const xml = try reply.format(allocator, "toUser", "fromUser");
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<MiniprogramPage>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Title><![CDATA[title]]></Title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<AppId><![CDATA[appid]]></AppId>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<PagePath><![CDATA[pages/index]]></PagePath>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<ThumbMediaId><![CDATA[thumb_123]]></ThumbMediaId>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "</MiniprogramPage>") != null);
}