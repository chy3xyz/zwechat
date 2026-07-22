//! miniprogram/security — 微信小程序内容安全审核 (`security.msgSecCheck` / `imgSecCheck`)

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");

pub const Security = struct {
    ctx: *Context,

    pub fn init(ctx: *Context) Security {
        return .{ .ctx = ctx };
    }

    /// 检查一段文本是否含有违法违规内容 (`security.msgSecCheck` v2)
    pub fn msgSecCheck(
        self: Security,
        allocator: std.mem.Allocator,
        openid: []const u8,
        content: []const u8,
        scene: u8, // 1: 资料，2: 评论，3: 论坛，4: 社交日志
    ) ![]u8 {
        const access_token = try self.ctx.getAccessToken(allocator);
        defer allocator.free(access_token);

        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.weixin.qq.com/wxa/msg_sec_check?access_token={s}",
            .{access_token},
        );
        defer allocator.free(url);

        const body = try std.fmt.allocPrint(
            allocator,
            \\{{"openid":"{s}","scene":{d},"version":2,"content":"{s}"}}
        ,
            .{ openid, scene, content },
        );
        defer allocator.free(body);

        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();

        return client.postJSON(url, body);
    }
};

test "Security.init 构造实例" {
    var ctx: Context = .{
        .config = .{},
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const sec = Security.init(&ctx);
    try std.testing.expectEqual(&ctx, sec.ctx);
}
