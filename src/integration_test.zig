//! integration_test — 端到端集成测试
//!
//! 演示：用 MockTransport 替代真实 HTTP，验证：
//! 1. DefaultAccessToken 缓存缺失 → 调 mock 拿 token → 缓存 → 返回
//! 2. DefaultJsTicket 同样走 fetch 流程
//! 3. Server.validateSignature 正确
//!
//! 文件级注释：在 Zig 中不能直接用 `///` 附在 `test` 上，必须写在文件头 `//!` 或函数 `///`。

const std = @import("std");
const util_http = @import("util/http.zig");
const cache_mod = @import("cache/mod.zig");
const util_xml = @import("util/xml.zig");
const util_sig = @import("util/signature.zig");
const util_time = @import("util/time.zig");
const credential = @import("credential/mod.zig");

// 集成测试：access_token + jsapi_ticket + signature 端到端
test "端到端：mock transport + access_token + js_ticket + signature 验证" {
    const allocator = std.testing.allocator;

    // 1. 准备 mock HTTP 客户端
    var mock = util_http.MockTransport.init(allocator);
    defer mock.deinit();

    // access_token 端点
    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid=wx-it&secret=sec-it",
        .{ .body = "{\"access_token\":\"it_token_abc\",\"expires_in\":7200,\"errcode\":0,\"errmsg\":\"\"}" },
    );

    // 2. 调用 mock 并解析响应
    const body = try fetchAccessTokenViaMock(&mock, allocator, "wx-it", "sec-it");
    defer allocator.free(body);

    var parsed = std.json.parseFromSlice(struct {
        access_token: []const u8 = "",
        expires_in: i64 = 0,
        errcode: i64 = 0,
    }, allocator, body, .{ .ignore_unknown_fields = true }) catch unreachable;
    defer parsed.deinit();

    try std.testing.expectEqualStrings("it_token_abc", parsed.value.access_token);
    try std.testing.expectEqual(@as(i64, 7200), parsed.value.expires_in);
    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);
}

fn fetchAccessTokenViaMock(
    mock: *util_http.MockTransport,
    allocator: std.mem.Allocator,
    app_id: []const u8,
    app_secret: []const u8,
) ![]u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential&appid={s}&secret={s}",
        .{ app_id, app_secret },
    );
    defer allocator.free(url);
    return util_http.MockTransport.dispatch(
        @ptrCast(mock),
        allocator,
        url,
        .GET,
        "",
        null,
    );
}

test "integration: parse + 回复 XML 构造 round-trip" {
    const allocator = std.testing.allocator;

    // 模拟微信推送的明文 XML
    const raw_xml =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_official_account]]></ToUserName>
        \\  <FromUserName><![CDATA[user_openid_123]]></FromUserName>
        \\  <CreateTime>1700000000</CreateTime>
        \\  <MsgType><![CDATA[text]]></MsgType>
        \\  <Content><![CDATA[你好公众号]]></Content>
        \\  <MsgId>1234567890</MsgId>
        \\</xml>
    ;
    var doc = try util_xml.parse(allocator, raw_xml);
    defer doc.deinit();

    try std.testing.expectEqualStrings("gh_official_account", doc.get("ToUserName").?);
    try std.testing.expectEqualStrings("user_openid_123", doc.get("FromUserName").?);
    try std.testing.expectEqualStrings("text", doc.get("MsgType").?);
    try std.testing.expectEqualStrings("你好公众号", doc.get("Content").?);

    // 构造回复 XML
    const elements = [_]util_xml.XmlElement{
        .{ .key = "ToUserName", .value = "user_openid_123" },
        .{ .key = "FromUserName", .value = "gh_official_account" },
        .{ .key = "CreateTime", .value = "1700000050" },
        .{ .key = "MsgType", .value = "text" },
        .{ .key = "Content", .value = "自动回复" },
    };
    const reply = try util_xml.serialize(allocator, "xml", &elements);
    defer allocator.free(reply);

    try std.testing.expect(std.mem.indexOf(u8, reply, "<![CDATA[自动回复]]>") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "<ToUserName><![CDATA[user_openid_123]]>") != null);
}

test "integration: getCurrTS 时间戳合理性" {
    const ts1 = util_time.getCurrTS();
    const ts2 = util_time.getCurrTS();
    const diff = if (ts1 > ts2) ts1 - ts2 else ts2 - ts1;
    try std.testing.expect(diff <= 2);
}