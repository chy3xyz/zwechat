// SPDX-License-Identifier: Apache-2.0
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
    miniprogrampage,
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

/// `TransInfo` — 转客服消息的目标客服（对应 Go `TransInfo`，XML `KfAccount`）。
pub const TransInfo = struct {
    kf_account: []const u8,
};

/// `TransferCustomer` — 被动回复转客服消息（对应 Go `TransferCustomer`）。
/// `kf_account` 为空表示不指定客服，由微信随机分配。
pub const TransferCustomer = struct {
    kf_account: []const u8 = "",

    /// 转为被动回复 `Reply`（供 `Server` 消息处理回调返回）。
    pub fn toReply(self: TransferCustomer) Reply {
        return .{
            .msg_type = .transfer_customer_service,
            .data = if (self.kf_account.len > 0)
                .{ .transfer = .{ .kf_account = self.kf_account } }
            else
                .{ .transfer = null },
        };
    }
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
        /// 转客服消息；`null` 表示不指定客服（由微信随机分配）。
        transfer: ?TransInfo,
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
            .transfer => |ti| formatTransfer(allocator, to_user, from_user, ti),
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

fn formatTransfer(allocator: std.mem.Allocator, to: []const u8, from: []const u8, trans_info: ?TransInfo) ![]u8 {
    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{std.Io.Clock.now(.real, std.Options.debug_io).toSeconds()});
    defer allocator.free(ts_str);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.print(allocator, "<xml><ToUserName><![CDATA[{s}]]></ToUserName>", .{to});
    try buf.print(allocator, "<FromUserName><![CDATA[{s}]]></FromUserName>", .{from});
    try buf.print(allocator, "<CreateTime>{s}</CreateTime>", .{ts_str});
    try buf.print(allocator, "<MsgType><![CDATA[transfer_customer_service]]></MsgType>", .{});
    if (trans_info) |ti| {
        try buf.print(allocator, "<TransInfo><KfAccount><![CDATA[{s}]]></KfAccount></TransInfo>", .{ti.kf_account});
    }
    try buf.appendSlice(allocator, "</xml>");
    return buf.toOwnedSlice(allocator);
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

/// 客服消息类型（对应 Go `CustomerMessage.Msgtype`，JSON `msgtype` 取枚举名）。
pub const CustomerMsgType = enum {
    text,
    image,
    voice,
    video,
    music,
    news,
    mpnews,
    wxcard,
    msgmenu,
    miniprogrampage,
    mpnewsarticle,
};

/// 客服消息 — 文本。
pub const CustomerTextMessage = struct {
    touser: []const u8,
    content: []const u8,
};

/// `MediaText` — 文本消息负载（对应 Go `MediaText`）。
pub const MediaText = struct {
    content: []const u8,
};

/// `MediaResource` — 仅含永久素材 id 的负载（图片 / 语音 / mpnews，对应 Go `MediaResource`）。
pub const MediaResource = struct {
    media_id: []const u8,
};

/// `MediaVideo` — 视频消息负载（对应 Go `MediaVideo`）。
pub const MediaVideo = struct {
    media_id: []const u8,
    thumb_media_id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
};

/// `MediaMusic` — 音乐消息负载（对应 Go `MediaMusic`，JSON key 为 `musicurl`/`hqmusicurl`）。
pub const MediaMusic = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    musicurl: []const u8 = "",
    hqmusicurl: []const u8 = "",
    thumb_media_id: []const u8 = "",
};

/// `MediaArticles` — 客服图文单条（对应 Go `MediaArticles`，JSON key 为 `picurl`）。
pub const MediaArticles = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    url: []const u8 = "",
    picurl: []const u8 = "",
};

/// `MediaNews` — 客服图文消息负载（对应 Go `MediaNews`）。
pub const MediaNews = struct {
    articles: []const MediaArticles,
};

/// `MsgmenuItem` — 菜单消息的单个按钮（对应 Go `MsgmenuItem`）。
pub const MsgmenuItem = struct {
    id: []const u8,
    content: []const u8,
};

/// `MediaMsgmenu` — 菜单消息负载（对应 Go `MediaMsgmenu`）。
pub const MediaMsgmenu = struct {
    head_content: []const u8 = "",
    list: []const MsgmenuItem = &.{},
    tail_content: []const u8 = "",
};

/// `MediaWxcard` — 卡券消息负载（对应 Go `MediaWxcard`）。
pub const MediaWxcard = struct {
    card_id: []const u8,
};

/// `MediaMiniprogrampage` — 小程序卡片消息负载（对应 Go `MediaMiniprogrampage`）。
pub const MediaMiniprogrampage = struct {
    title: []const u8 = "",
    appid: []const u8 = "",
    pagepath: []const u8 = "",
    thumb_media_id: []const u8 = "",
};

/// `MediaArticle` — 已发布文章 id 负载（`mpnewsarticle`，对应 Go `MediaArticle`）。
pub const MediaArticle = struct {
    article_id: []const u8,
};

/// 客服消息统一载体（对应 Go `CustomerMessage`）。
/// 按 `msgtype` 填充对应负载字段，未填充的字段不会出现在 JSON 中。
pub const CustomerMessage = struct {
    touser: []const u8,
    msgtype: CustomerMsgType,
    text: ?MediaText = null,
    image: ?MediaResource = null,
    voice: ?MediaResource = null,
    video: ?MediaVideo = null,
    music: ?MediaMusic = null,
    news: ?MediaNews = null,
    mpnews: ?MediaResource = null,
    wxcard: ?MediaWxcard = null,
    msgmenu: ?MediaMsgmenu = null,
    miniprogrampage: ?MediaMiniprogrampage = null,
    mpnewsarticle: ?MediaArticle = null,
};

/// 客服输入状态（对应 Go `customerservice.TypingStatus`）。
pub const TypingStatus = enum {
    typing,
    cancel_typing,

    /// 微信接口要求的 JSON 字符串值。
    pub fn jsonValue(self: TypingStatus) []const u8 {
        return switch (self) {
            .typing => "Typing",
            .cancel_typing => "CancelTyping",
        };
    }
};

pub const Message = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    fn post(self: *Self, uri: []const u8, body: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, body);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body);
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

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            msgid: i64 = 0,
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value.msgid;
    }

    /// 发送客服文本消息。
    pub fn sendCustomerText(self: *Self, msg: CustomerTextMessage) !void {
        return self.sendCustomer(.{
            .touser = msg.touser,
            .msgtype = .text,
            .text = .{ .content = msg.content },
        });
    }

    /// 发送客服消息（对应 Go `Manager.Send`，text/image/voice/video/music/news/mpnews/wxcard/msgmenu/miniprogrampage/mpnewsarticle 全类型通用）。
    /// 响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn sendCustomer(self: *Self, msg: CustomerMessage) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ customSendURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try serializeCustomer(self.allocator, msg);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "SendCustomer")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 下发客服输入状态给用户（对应 Go `Manager.SendTypingStatus`）。
    /// `command` 为 `.typing`（正在输入）或 `.cancel_typing`（取消输入）。
    pub fn sendTypingStatus(self: *Self, openid: []const u8, command: TypingStatus) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ customerTypingURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try serializeTypingStatus(self.allocator, openid, command);
        defer self.allocator.free(body);

        const resp = try self.post(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "SendTypingStatus")) |ce| {
            defer ce.deinit();
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

fn serializeCustomer(allocator: std.mem.Allocator, msg: CustomerMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("touser");
    try s.write(msg.touser);
    try s.objectField("msgtype");
    try s.write(msg.msgtype);
    if (msg.text) |t| {
        try s.objectField("text");
        try s.beginObject();
        try s.objectField("content");
        try s.write(t.content);
        try s.endObject();
    }
    if (msg.image) |v| {
        try s.objectField("image");
        try s.beginObject();
        try s.objectField("media_id");
        try s.write(v.media_id);
        try s.endObject();
    }
    if (msg.voice) |v| {
        try s.objectField("voice");
        try s.beginObject();
        try s.objectField("media_id");
        try s.write(v.media_id);
        try s.endObject();
    }
    if (msg.video) |v| {
        try s.objectField("video");
        try s.beginObject();
        try s.objectField("media_id");
        try s.write(v.media_id);
        try s.objectField("thumb_media_id");
        try s.write(v.thumb_media_id);
        try s.objectField("title");
        try s.write(v.title);
        try s.objectField("description");
        try s.write(v.description);
        try s.endObject();
    }
    if (msg.music) |m| {
        try s.objectField("music");
        try s.beginObject();
        try s.objectField("title");
        try s.write(m.title);
        try s.objectField("description");
        try s.write(m.description);
        try s.objectField("musicurl");
        try s.write(m.musicurl);
        try s.objectField("hqmusicurl");
        try s.write(m.hqmusicurl);
        try s.objectField("thumb_media_id");
        try s.write(m.thumb_media_id);
        try s.endObject();
    }
    if (msg.news) |n| {
        try s.objectField("news");
        try s.beginObject();
        try s.objectField("articles");
        try s.write(n.articles);
        try s.endObject();
    }
    if (msg.mpnews) |v| {
        try s.objectField("mpnews");
        try s.beginObject();
        try s.objectField("media_id");
        try s.write(v.media_id);
        try s.endObject();
    }
    if (msg.wxcard) |w| {
        try s.objectField("wxcard");
        try s.beginObject();
        try s.objectField("card_id");
        try s.write(w.card_id);
        try s.endObject();
    }
    if (msg.msgmenu) |m| {
        try s.objectField("msgmenu");
        try s.beginObject();
        try s.objectField("head_content");
        try s.write(m.head_content);
        try s.objectField("list");
        try s.write(m.list);
        try s.objectField("tail_content");
        try s.write(m.tail_content);
        try s.endObject();
    }
    if (msg.miniprogrampage) |mp| {
        try s.objectField("miniprogrampage");
        try s.beginObject();
        try s.objectField("title");
        try s.write(mp.title);
        try s.objectField("appid");
        try s.write(mp.appid);
        try s.objectField("pagepath");
        try s.write(mp.pagepath);
        try s.objectField("thumb_media_id");
        try s.write(mp.thumb_media_id);
        try s.endObject();
    }
    if (msg.mpnewsarticle) |a| {
        try s.objectField("mpnewsarticle");
        try s.beginObject();
        try s.objectField("article_id");
        try s.write(a.article_id);
        try s.endObject();
    }
    try s.endObject();

    return out.toOwnedSlice();
}

fn serializeTypingStatus(allocator: std.mem.Allocator, openid: []const u8, command: TypingStatus) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };

    try s.beginObject();
    try s.objectField("touser");
    try s.write(openid);
    try s.objectField("command");
    try s.write(command.jsonValue());
    try s.endObject();

    return out.toOwnedSlice();
}

pub const templateSendURL = "https://api.weixin.qq.com/cgi-bin/message/template/send";
pub const customSendURL = "https://api.weixin.qq.com/cgi-bin/message/custom/send";
pub const customerTypingURL = "https://api.weixin.qq.com/cgi-bin/message/custom/typing";

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

// —— mock 测试 ——

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 捕获最后一次请求的 transport：记录 uri/method/payload 并返回预设响应。
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

fn newTestMessage(ctx: *Context, alloc: std.mem.Allocator, stub: *CaptureResp) Message {
    var m = Message.init(ctx, alloc);
    m.setTransport(CaptureResp.dispatch, stub);
    return m;
}

test "sendCustomerText 走 transport 并序列化 text" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomerText(.{ .touser = "oA\"x", .content = "说 \"hi\"" });

    try std.testing.expectEqual(std.http.Method.POST, stub.last_method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/message/custom/send?access_token=token-abc", stub.lastUri());
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "说 \\\"hi\\\"") != null);
}

test "sendCustomer 图片消息 body 含 image.media_id" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .image,
        .image = .{ .media_id = "media_img" },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"image\":{\"media_id\":\"media_img\"}") != null);
}

test "sendCustomer 语音消息 body 含 voice.media_id" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .voice,
        .voice = .{ .media_id = "media_voice" },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"voice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"voice\":{\"media_id\":\"media_voice\"}") != null);
}

test "sendCustomer 视频消息 body 含 video 四字段" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .video,
        .video = .{
            .media_id = "m_video",
            .thumb_media_id = "m_thumb",
            .title = "标题",
            .description = "描述",
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"video\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"media_id\":\"m_video\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"thumb_media_id\":\"m_thumb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"title\":\"标题\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"description\":\"描述\"") != null);
}

test "sendCustomer 音乐消息 body 含 music 五字段" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .music,
        .music = .{
            .title = "歌名",
            .description = "歌手",
            .musicurl = "https://a/1.mp3",
            .hqmusicurl = "https://a/1hq.mp3",
            .thumb_media_id = "m_thumb",
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"music\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"musicurl\":\"https://a/1.mp3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"hqmusicurl\":\"https://a/1hq.mp3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"thumb_media_id\":\"m_thumb\"") != null);
}

test "sendCustomer 图文 news 消息 body 含 articles 数组" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    const articles = [_]MediaArticles{
        .{ .title = "t1", .description = "d1", .url = "https://u/1", .picurl = "https://p/1.png" },
        .{ .title = "t2", .description = "", .url = "", .picurl = "" },
    };
    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .news,
        .news = .{ .articles = &articles },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"news\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"articles\":[{\"title\":\"t1\",\"description\":\"d1\",\"url\":\"https://u/1\",\"picurl\":\"https://p/1.png\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "{\"title\":\"t2\",\"description\":\"\",\"url\":\"\",\"picurl\":\"\"}") != null);
}

test "sendCustomer mpnews 消息 body 含 mpnews.media_id" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .mpnews,
        .mpnews = .{ .media_id = "media_mpnews" },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"mpnews\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"mpnews\":{\"media_id\":\"media_mpnews\"}") != null);
}

test "sendCustomer wxcard 消息 body 含 wxcard.card_id" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .wxcard,
        .wxcard = .{ .card_id = "card_123" },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"wxcard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"wxcard\":{\"card_id\":\"card_123\"}") != null);
}

test "sendCustomer 小程序卡片 body 含 miniprogrampage 四字段" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .miniprogrampage,
        .miniprogrampage = .{
            .title = "卡片标题",
            .appid = "wx_appid",
            .pagepath = "pages/index",
            .thumb_media_id = "m_thumb",
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"miniprogrampage\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"appid\":\"wx_appid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"pagepath\":\"pages/index\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"thumb_media_id\":\"m_thumb\"") != null);
}

test "sendCustomer 菜单消息 body 含 msgmenu 且转义用户文本" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    const items = [_]MsgmenuItem{
        .{ .id = "101", .content = "满意\"非常满意\"" },
        .{ .id = "102", .content = "不满意" },
    };
    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .msgmenu,
        .msgmenu = .{
            .head_content = "您对本次服务是否满意呢？",
            .list = &items,
            .tail_content = "欢迎再次光临",
        },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"msgmenu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"head_content\":\"您对本次服务是否满意呢？\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "满意\\\"非常满意\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "{\"id\":\"102\",\"content\":\"不满意\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"tail_content\":\"欢迎再次光临\"") != null);
}

test "sendCustomer mpnewsarticle 消息 body 含 article_id" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .mpnewsarticle,
        .mpnewsarticle = .{ .article_id = "art_123" },
    });

    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"msgtype\":\"mpnewsarticle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"mpnewsarticle\":{\"article_id\":\"art_123\"}") != null);
}

test "sendCustomer errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":45047,\"errmsg\":\"out of response count limit\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    const result = m.sendCustomer(.{
        .touser = "oA",
        .msgtype = .text,
        .text = .{ .content = "hi" },
    });
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "sendTypingStatus 请求端点与 body" {
    const allocator = std.testing.allocator;
    var stub = CaptureResp{ .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-msg" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = newTestMessage(&ctx, allocator, &stub);

    try m.sendTypingStatus("oA", .typing);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/cgi-bin/message/custom/typing?access_token=token-abc", stub.lastUri());
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"touser\":\"oA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"command\":\"Typing\"") != null);

    try m.sendTypingStatus("oA", .cancel_typing);
    try std.testing.expect(std.mem.indexOf(u8, stub.lastPayload(), "\"command\":\"CancelTyping\"") != null);
}

test "TransferCustomer 带 KfAccount 的被动回复 XML" {
    const allocator = std.testing.allocator;
    const tc = TransferCustomer{ .kf_account = "kf1@test" };
    const reply = tc.toReply();
    const xml = try reply.format(allocator, "toUser", "fromUser");
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<MsgType><![CDATA[transfer_customer_service]]></MsgType>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<TransInfo><KfAccount><![CDATA[kf1@test]]></KfAccount></TransInfo>") != null);
}

test "TransferCustomer 不指定客服时 XML 无 TransInfo" {
    const allocator = std.testing.allocator;
    const tc = TransferCustomer{};
    const reply = tc.toReply();
    const xml = try reply.format(allocator, "toUser", "fromUser");
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<MsgType><![CDATA[transfer_customer_service]]></MsgType>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "TransInfo") == null);
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
        .msg_type = .miniprogrampage,
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
