// SPDX-License-Identifier: Apache-2.0
//! miniprogram/encryptor — 加密数据解密（用户信息 / 手机号）
//!
//! 对应 `_ref/wechat/miniprogram/encryptor/encryptor.go`：
//! 用 session_key + iv 对 `encryptedData` 做 AES-128-CBC 解密，得到明文 JSON，
//! 并校验 `watermark.appid` 是否与小程序 appid 一致。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const Aes128 = std.crypto.core.aes.Aes128;

/// 解密后的用户信息 / 手机号明文（字段名与微信返回的 camelCase JSON 一致）。
pub const PlainData = struct {
    openId: []const u8 = "",
    unionId: []const u8 = "",
    nickName: []const u8 = "",
    gender: i64 = 0,
    city: []const u8 = "",
    province: []const u8 = "",
    country: []const u8 = "",
    avatarUrl: []const u8 = "",
    language: []const u8 = "",
    phoneNumber: []const u8 = "",
    openGId: []const u8 = "",
    msgTicket: []const u8 = "",
    purePhoneNumber: []const u8 = "",
    countryCode: []const u8 = "",
    watermark: Watermark = .{},
};

pub const Watermark = struct {
    timestamp: i64 = 0,
    appid: []const u8 = "",
};

/// 小程序加密数据解密模块。
pub const Encryptor = struct {
    ctx: *Context,

    const Self = @This();

    pub fn init(ctx: *Context) Self {
        return .{ .ctx = ctx };
    }

    /// 解密 `encryptedData` 并返回 `std.json.Parsed(PlainData)`（调用方负责 `deinit`）。
    ///
    /// 校验 `watermark.appid` 是否匹配 `ctx.config.app_id`，不匹配返回 `error.AppIdNotMatch`。
    pub fn decrypt(
        self: *Self,
        allocator: std.mem.Allocator,
        session_key: []const u8,
        encrypted_data: []const u8,
        iv: []const u8,
    ) !std.json.Parsed(PlainData) {
        const plain = try getCipherText(allocator, session_key, encrypted_data, iv);
        defer allocator.free(plain);

        var parsed = std.json.parseFromSlice(PlainData, allocator, plain, .{ .allocate = .alloc_always }) catch {
            return error.DecodeError;
        };
        errdefer parsed.deinit();

        if (!std.mem.eql(u8, parsed.value.watermark.appid, self.ctx.config.app_id)) {
            return error.AppIdNotMatch;
        }
        return parsed;
    }
};

/// 用 session_key + iv 解密 `encryptedData`，返回去掉 PKCS#7 补位后的明文（调用方负责 `free`）。
pub fn getCipherText(
    allocator: std.mem.Allocator,
    session_key: []const u8,
    encrypted_data: []const u8,
    iv: []const u8,
) ![]u8 {
    const decoder = std.base64.standard.Decoder;

    const key_len = try decoder.calcSizeForSlice(session_key);
    if (key_len != 16) return error.InvalidSessionKey;
    const key = try allocator.alloc(u8, key_len);
    defer allocator.free(key);
    try decoder.decode(key, session_key);

    const cipher_len = try decoder.calcSizeForSlice(encrypted_data);
    if (cipher_len == 0 or cipher_len % 16 != 0) return error.InvalidCiphertext;
    const cipher = try allocator.alloc(u8, cipher_len);
    defer allocator.free(cipher);
    try decoder.decode(cipher, encrypted_data);

    const iv_len = try decoder.calcSizeForSlice(iv);
    if (iv_len != 16) return error.InvalidIv;
    const iv_bytes = try allocator.alloc(u8, iv_len);
    defer allocator.free(iv_bytes);
    try decoder.decode(iv_bytes, iv);

    const plain_padded = try allocator.alloc(u8, cipher_len);
    defer allocator.free(plain_padded);
    aes128CbcDecrypt(plain_padded, cipher, key[0..16], iv_bytes[0..16]);

    const plain = pkcs7Unpad(plain_padded) orelse return error.InvalidPadding;
    return allocator.dupe(u8, plain);
}

fn aes128CbcDecrypt(dst: []u8, src: []const u8, key: *const [16]u8, iv: *const [16]u8) void {
    std.debug.assert(dst.len == src.len);
    std.debug.assert(src.len % 16 == 0);
    const dec = Aes128.initDec(key.*);
    var prev: [16]u8 = iv.*;
    var off: usize = 0;
    while (off < src.len) : (off += 16) {
        const cipher_block: [16]u8 = src[off..][0..16].*;
        var plain: [16]u8 = undefined;
        dec.decrypt(&plain, &cipher_block);
        for (&plain, 0..) |*b, i| b.* ^= prev[i];
        @memcpy(dst[off..][0..16], &plain);
        prev = cipher_block;
    }
}

/// PKCS#7 去补位；数据非法时返回 `null`。
fn pkcs7Unpad(data: []const u8) ?[]const u8 {
    if (data.len == 0 or data.len % 16 != 0) return null;
    const pad = data[data.len - 1];
    if (pad == 0 or pad > 16 or pad > data.len) return null;
    for (data[data.len - pad ..]) |b| {
        if (b != pad) return null;
    }
    return data[0 .. data.len - pad];
}

test "Encryptor.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-enc" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const e = Encryptor.init(&ctx);
    try std.testing.expectEqualStrings("wx-enc", e.ctx.config.app_id);
}

test "pkcs7Unpad 去除合法补位" {
    const data = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 4, 4, 4, 4 };
    const out = pkcs7Unpad(&data).?;
    try std.testing.expectEqualStrings("abcdefghijkl", out);
}
