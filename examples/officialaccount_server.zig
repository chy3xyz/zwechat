// SPDX-License-Identifier: Apache-2.0
//! 微信公众号服务端消息接收与被动回复示例
//!
//! 演示功能：
//! 1. 初始化 OfficialAccount 客户端与配置。
//! 2. 通过 `middleware.parseCallbackQuery` 解析微信回调 URL query。
//! 3. 通过 `middleware.verifyURL` / `verifyServerSignature` 校验签名（GET 握手回显 echostr）。
//! 4. 通过 `middleware.handleServerMessage` 解密 AES 密文并校验 AppID。
//!
//! 运行：`zig build run-oa-server`

const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== zwechat: 微信公众号 Server 消息处理示例 ===\n", .{});

    // 1. 初始化通用 Cache
    var memory_cache = try zwechat.cache.Memory.create(allocator);
    defer {
        memory_cache.deinit();
        allocator.destroy(memory_cache);
    }

    // 2. 构造公众号配置
    //    注意：encoding_aes_key 在本 SDK 中是 **32 字节原始 AES key**
    //    （不是微信后台 43 字符的 base64 EncodingAESKey；若为后者需先 base64 解码）。
    const cfg = zwechat.officialaccount.Config{
        .app_id = "wx1234567890abcdef",
        .app_secret = "0123456789abcdef0123456789abcdef",
        .token = "my_custom_token_123",
        .encoding_aes_key = "0123456789abcdef0123456789abcdef",
        .cache = memory_cache.asCache(),
    };

    // 3. 实例化 OfficialAccount
    var default_token = zwechat.credential.DefaultAccessToken.init(
        cfg.app_id,
        cfg.app_secret,
        zwechat.credential.CacheKeyOfficialAccountPrefix,
        cfg.cache.?,
    );

    const factory = struct {
        var token_ptr: *zwechat.credential.DefaultAccessToken = undefined;
        fn create(_: zwechat.officialaccount.Config, _: zwechat.cache.Cache) anyerror!zwechat.credential.AccessTokenHandle {
            return token_ptr.asHandle();
        }
    };
    factory.token_ptr = &default_token;

    var wc = zwechat.wechat.Wechat.init();
    const oa = try wc.getOfficialAccount(
        allocator,
        cfg,
        factory.create,
    );
    _ = oa;

    // 4. 模拟微信服务器发起的 GET URL 验证请求
    //    真实场景：Web 框架收到 /wechat?signature=...&timestamp=...&nonce=...&echostr=...
    const timestamp = "1721641869";
    const nonce = "239847192";
    const token = cfg.token;

    const params = [_][]const u8{ token, timestamp, nonce };
    const computed_signature = try zwechat.util.signature.signature(allocator, &params);
    defer allocator.free(computed_signature);

    const raw_query = try std.fmt.allocPrint(
        allocator,
        "signature={s}&timestamp={s}&nonce={s}&echostr=OK-VERIFY-PASSED",
        .{ computed_signature, timestamp, nonce },
    );
    defer allocator.free(raw_query);

    std.debug.print("[URL 校验] 模拟微信请求 query: {s}\n", .{raw_query});

    const query = try zwechat.middleware.parseCallbackQuery(raw_query);
    if (zwechat.middleware.verifyURL(allocator, token, query)) |echostr| {
        std.debug.print("[URL 校验] 签名通过，应回显 echostr: {s}\n", .{echostr});
    } else {
        std.debug.print("[URL 校验] 签名校验失败，拒绝请求\n", .{});
    }

    // 5. 模拟解密收到的加密 XML 消息（安全模式）
    const raw_user_msg = "Hello! 这是一个来自微信用户的文本消息";
    const random16 = "1234567890abcdef";
    const encrypted_xml = try zwechat.util.crypto.aesEncryptMsg(allocator, random16, raw_user_msg, cfg.app_id, cfg.encoding_aes_key);
    defer allocator.free(encrypted_xml);

    std.debug.print("[消息解密] 加密后的密文长度: {} 字节\n", .{encrypted_xml.len});

    var decrypted = try zwechat.middleware.handleServerMessage(allocator, cfg.encoding_aes_key, cfg.app_id, encrypted_xml);
    defer decrypted.deinit(allocator);

    std.debug.print("[消息解密] 解密成功！明文内容: '{s}' (AppID 匹配: {s})\n", .{ decrypted.raw_xml, decrypted.app_id });
    std.debug.print("示例运行完毕。\n", .{});
}
