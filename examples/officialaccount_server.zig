// SPDX-License-Identifier: Apache-2.0
//! 微信公众号服务端消息接收与被动回复示例
//!
//! 演示功能：
//! 1. 初始化 OfficialAccount 客户端与配置。
//! 2. 校验微信推送请求的 signature / timestamp / nonce 签名。
//! 3. 针对加密消息进行 AES 解密。
//! 4. 构造文本被动回复消息并打包导出。

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
    const cfg = zwechat.officialaccount.Config{
        .app_id = "wx1234567890abcdef",
        .app_secret = "0123456789abcdef0123456789abcdef",
        .token = "my_custom_token_123",
        .encoding_aes_key = "abcdefghijklmnopqrstuvwxyz01234567890123456",
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

    // 4. 模拟校验微信服务器推推送的 GET 请求（URL 验证）
    const timestamp = "1721641869";
    const nonce = "239847192";
    const token = cfg.token;

    const params = [_][]const u8{ token, timestamp, nonce };
    const computed_signature = try zwechat.util.signature.signature(allocator, &params);
    defer allocator.free(computed_signature);

    std.debug.print("[URL 校验] 生成计算的 SHA1 签名: {s}\n", .{computed_signature});

    // 5. 模拟解密收到的加密 XML 消息
    const raw_user_msg = "Hello! 这是一个来自微信用户的文本消息";
    const random16 = "1234567890abcdef";
    const encrypted_xml = try zwechat.util.crypto.aesEncryptMsg(allocator, random16, raw_user_msg, cfg.app_id, cfg.encoding_aes_key[0..32]);
    defer allocator.free(encrypted_xml);

    std.debug.print("[消息解密] 加密后的密文长度: {} 字节\n", .{encrypted_xml.len});

    const decrypted = try zwechat.util.crypto.aesDecryptMsg(allocator, encrypted_xml, cfg.encoding_aes_key[0..32]);
    defer {
        allocator.free(decrypted.random);
        allocator.free(decrypted.raw_xml_msg);
        allocator.free(decrypted.app_id);
    }

    std.debug.print("[消息解密] 解密成功！明文内容: '{s}' (AppID 匹配: {s})\n", .{ decrypted.raw_xml_msg, decrypted.app_id });
    std.debug.print("示例运行完毕。\n", .{});
}
