// SPDX-License-Identifier: Apache-2.0
//! work/server — 企业微信回调服务器消息校验与加解密 (`WorkServer`)
//!
//! 校验 `msg_signature`（SHA1 over token, timestamp, nonce, encrypt_msg），
//! 解密 AES 消息并验证 `ReceiveID` 是否匹配 `CorpID`。

const std = @import("std");
const signature = @import("../../util/signature.zig");
const crypto = @import("../../util/crypto.zig");
const Context = @import("../context/mod.zig").Context;

pub const WorkCallbackQuery = struct {
    msg_signature: []const u8,
    timestamp: []const u8,
    nonce: []const u8,
    echostr: []const u8 = "",
};

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

    /// 解密企业微信消息并返回明文消息与 CorpID 检验
    pub fn decryptMsg(
        self: WorkServer,
        allocator: std.mem.Allocator,
        encrypted_xml: []const u8,
    ) !crypto.DecryptedMessage {
        const aes_key = self.ctx.config.encoding_aes_key;
        if (aes_key.len == 0) return error.ConfigMissing;
        if (aes_key.len < 32) return error.InvalidArgument;

        const res = try crypto.aesDecryptMsg(allocator, encrypted_xml, aes_key[0..32]);
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

test "WorkServer 校验 CorpId 匹配" {
    const allocator = std.testing.allocator;
    const corp_id = "ww1234567890abcdef";
    const aes_key = "0123456789abcdef0123456789abcdef";

    var ctx = Context{
        .config = .{
            .corp_id = corp_id,
            .token = "token",
            .encoding_aes_key = aes_key,
        },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };

    const server = WorkServer.init(&ctx);
    const encrypted = try crypto.aesEncryptMsg(allocator, "1234567890abcdef", "<xml/>", corp_id, aes_key);
    defer allocator.free(encrypted);

    const dec = try server.decryptMsg(allocator, encrypted);
    defer {
        allocator.free(dec.random);
        allocator.free(dec.raw_xml_msg);
        allocator.free(dec.app_id);
    }

    try std.testing.expectEqualStrings(corp_id, dec.app_id);
}
