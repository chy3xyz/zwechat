// SPDX-License-Identifier: Apache-2.0
//! miniprogram/message — 微信小程序订阅消息 (subscribeMessage)

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");

pub const SubscribeMessageParams = struct {
    touser: []const u8,
    template_id: []const u8,
    page: []const u8 = "",
    data: []const u8, // JSON 数据字符串
    miniprogram_state: []const u8 = "developer", // developer / trial / formal
    lang: []const u8 = "zh_CN",
};

pub const Message = struct {
    ctx: *Context,

    pub fn init(ctx: *Context) Message {
        return .{ .ctx = ctx };
    }

    /// 发送小程序订阅消息 (`subscribeMessage.send`)
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

        const body = try std.fmt.allocPrint(
            allocator,
            \\{{"touser":"{s}","template_id":"{s}","page":"{s}","data":{s},"miniprogram_state":"{s}","lang":"{s}"}}
        ,
            .{
                params.touser,
                params.template_id,
                params.page,
                params.data,
                params.miniprogram_state,
                params.lang,
            },
        );
        defer allocator.free(body);

        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();

        return client.postJSON(url, body);
    }
};

test "SubscribeMessageParams 默认开发状态" {
    const p = SubscribeMessageParams{
        .touser = "o_123",
        .template_id = "tpl_456",
        .data = "{}",
    };
    try std.testing.expectEqualStrings("developer", p.miniprogram_state);
    try std.testing.expectEqualStrings("zh_CN", p.lang);
}
