// SPDX-License-Identifier: Apache-2.0
//! work/server — 企业微信回调服务器消息校验与加解密 (`WorkServer`)
//!
//! 校验 `msg_signature`（SHA1 over token, timestamp, nonce, encrypt_msg），
//! 解密 AES 消息并验证 `ReceiveID` 是否匹配 `CorpID`。

const std = @import("std");
const signature = @import("../../util/signature.zig");
const crypto = @import("../../util/crypto.zig");
const util_error = @import("../../util/error.zig");
const Context = @import("../context/mod.zig").Context;

pub const WorkCallbackQuery = struct {
    msg_signature: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    echostr: []const u8 = "",
};

/// 把微信 `EncodingAESKey`（43 字符 base64，可带 `=` padding）解码为 32 字节原始 AES key。
///
/// 与 Go 参考 `util.crypto` 的 `aesKeyDecode` 行为一致；解码结果长度不是 32 字节
/// 或 base64 非法时返回 `WechatError.InvalidArgument`。
pub fn decodeAesKey(encoding_aes_key: []const u8) util_error.WechatError![32]u8 {
    // EncodingAESKey 的 '=' padding 只出现在尾部；trim 两侧等价的保守写法即可。
    const trimmed = std.mem.trim(u8, encoding_aes_key, "=");
    if (trimmed.len == 0) return util_error.WechatError.InvalidArgument;
    const decoded_len = std.base64.standard_no_pad.Decoder.calcSizeForSlice(trimmed) catch
        return util_error.WechatError.InvalidArgument;
    if (decoded_len != 32) return util_error.WechatError.InvalidArgument;
    var key: [32]u8 = undefined;
    std.base64.standard_no_pad.Decoder.decode(&key, trimmed) catch
        return util_error.WechatError.InvalidArgument;
    return key;
}

pub const WorkServer = struct {
    ctx: *Context,

    pub fn init(ctx: *Context) WorkServer {
        return .{ .ctx = ctx };
    }

    /// 校验企业微信签名 `msg_signature`
    pub fn verifyMsgSignature(
        self: WorkServer,
        allocator: std.mem.Allocator,
        encrypt_msg: []const u8,
        query: WorkCallbackQuery,
    ) bool {
        const token = self.ctx.config.token;
        if (token.len == 0) return false;
        const params = [_][]const u8{ token, query.timestamp, query.nonce, encrypt_msg };
        const computed = signature.signature(allocator, &params) catch return false;
        defer allocator.free(computed);
        return std.mem.eql(u8, computed, query.msg_signature);
    }

    /// 解密企业微信消息并返回明文消息与 CorpID 检验。
    ///
    /// `encrypted_base64` 是回调 XML 中 `<Encrypt>` 节点的 base64 内容
    /// （与 Go 参考 `util.DecryptMsg` 的入参一致）；`config.encoding_aes_key`
    /// 是 43 字符 base64 的 `EncodingAESKey`，内部会自动解码。
    ///
    /// 返回的 `crypto.DecryptedMessage` 字段（`random` / `raw_xml_msg` / `app_id`）
    /// 均由调用方负责 `free`。
    pub fn decryptMsg(
        self: WorkServer,
        allocator: std.mem.Allocator,
        encrypted_base64: []const u8,
    ) !crypto.DecryptedMessage {
        const aes_key = self.ctx.config.encoding_aes_key;
        if (aes_key.len == 0) return error.ConfigMissing;
        const key = try decodeAesKey(aes_key);

        const cipher_len = std.base64.standard.Decoder.calcSizeForSlice(encrypted_base64) catch
            return util_error.WechatError.InvalidArgument;
        const cipher = try allocator.alloc(u8, cipher_len);
        defer allocator.free(cipher);
        std.base64.standard.Decoder.decode(cipher, encrypted_base64) catch
            return util_error.WechatError.InvalidArgument;

        const res = try crypto.aesDecryptMsg(allocator, cipher, &key);
        errdefer {
            allocator.free(res.random);
            allocator.free(res.raw_xml_msg);
            allocator.free(res.app_id);
        }

        // 校验 ReceiveID == CorpID
        if (!std.mem.eql(u8, res.app_id, self.ctx.config.corp_id)) {
            return error.CorpIdMismatch;
        }

        return .{
            .random = res.random,
            .raw_xml_msg = res.raw_xml_msg,
            .app_id = res.app_id,
        };
    }
};

test "WorkServer 校验 CorpId 匹配（真实 43 字符 EncodingAESKey）" {
    const allocator = std.testing.allocator;
    const corp_id = "ww1234567890abcdef";
    // 32 字节原始 key 的 base64（无 padding，43 字符），与微信后台 EncodingAESKey 形态一致。
    const aes_key = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY";

    var ctx = Context{
        .config = .{
            .corp_id = corp_id,
            .token = "token",
            .encoding_aes_key = aes_key,
        },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };

    const server = WorkServer.init(&ctx);

    // 用解码后的 32 字节原始 key 加密，再按回调契约以 base64 密文传入解密。
    const raw_key = try decodeAesKey(aes_key);
    const cipher = try crypto.aesEncryptMsg(allocator, "1234567890abcdef", "<xml/>", corp_id, &raw_key);
    defer allocator.free(cipher);
    const b64_len = std.base64.standard.Encoder.calcSize(cipher.len);
    const encrypted_b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(encrypted_b64);
    _ = std.base64.standard.Encoder.encode(encrypted_b64, cipher);

    const dec = try server.decryptMsg(allocator, encrypted_b64);
    defer {
        allocator.free(dec.random);
        allocator.free(dec.raw_xml_msg);
        allocator.free(dec.app_id);
    }

    try std.testing.expectEqualStrings(corp_id, dec.app_id);
    try std.testing.expectEqualStrings("<xml/>", dec.raw_xml_msg);
}

test "decodeAesKey 解码 43 字符 base64 为 32 字节原始 key" {
    const key = try decodeAesKey("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY");
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", &key);

    // 容忍 '=' padding。
    const padded = try decodeAesKey("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=");
    try std.testing.expectEqual(key, padded);
}

test "decodeAesKey 拒绝非法输入" {
    // 空串。
    try std.testing.expectError(util_error.WechatError.InvalidArgument, decodeAesKey(""));
    // 非 base64。
    try std.testing.expectError(util_error.WechatError.InvalidArgument, decodeAesKey("!!!not-base64!!!"));
    // base64 合法但解码后不是 32 字节。
    try std.testing.expectError(util_error.WechatError.InvalidArgument, decodeAesKey("QUJD"));
}

test "WorkServer.decryptMsg CorpId 不匹配返回 CorpIdMismatch" {
    const allocator = std.testing.allocator;
    const aes_key = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY";

    var ctx = Context{
        .config = .{
            .corp_id = "ww-other-corp",
            .encoding_aes_key = aes_key,
        },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const server = WorkServer.init(&ctx);

    const raw_key = try decodeAesKey(aes_key);
    const cipher = try crypto.aesEncryptMsg(allocator, "1234567890abcdef", "<xml/>", "ww-real-corp", &raw_key);
    defer allocator.free(cipher);
    const b64_len = std.base64.standard.Encoder.calcSize(cipher.len);
    const encrypted_b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(encrypted_b64);
    _ = std.base64.standard.Encoder.encode(encrypted_b64, cipher);

    const result = server.decryptMsg(allocator, encrypted_b64);
    try std.testing.expectError(error.CorpIdMismatch, result);
}
