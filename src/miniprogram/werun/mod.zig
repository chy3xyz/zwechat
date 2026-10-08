// SPDX-License-Identifier: Apache-2.0
//! miniprogram/werun — 微信运动数据
//!
//! 对应 `_ref/wechat/miniprogram/werun/werun.go`：用 session_key + iv 解密
//! 微信运动步数数据。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const encryptor = @import("../encryptor/mod.zig");

/// 微信运动数据。
pub const Data = struct {
    stepInfoList: []StepInfo = &.{},
};

pub const StepInfo = struct {
    timestamp: i64 = 0,
    step: i64 = 0,
};

/// 微信运动模块。
pub const WeRun = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 解密微信运动数据，返回 `std.json.Parsed(Data)`（调用方负责 `deinit`）。
    pub fn getWeRunData(
        self: *Self,
        session_key: []const u8,
        encrypted_data: []const u8,
        iv: []const u8,
    ) !std.json.Parsed(Data) {
        const plain = try encryptor.getCipherText(self.allocator, session_key, encrypted_data, iv);
        defer self.allocator.free(plain);

        return std.json.parseFromSlice(Data, self.allocator, plain, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return error.DecodeError;
        };
    }
};

test "WeRun.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-run" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const wr = WeRun.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-run", wr.ctx.config.app_id);
}

test "Data 默认值" {
    const d = Data{};
    try std.testing.expectEqual(@as(usize, 0), d.stepInfoList.len);
}

// 由 openssl 生成的 AES-128-CBC + PKCS#7 向量（key = iv = "1234567890123456"）。
const test_session_key = "MTIzNDU2Nzg5MDEyMzQ1Ng==";
const test_iv = "MTIzNDU2Nzg5MDEyMzQ1Ng==";
const test_cipher = "YxlHvIiCifMxyRetQF2+QMYoLG487yT0IRmDJwLZIPqXUYr/aTvovR60LYroy9yhTsad/hUnzNVdvdcs47vRpw==";

test "getWeRunData 解密已知向量并解析步数" {
    const allocator = std.testing.allocator;
    var ctx: Context = .{
        .config = .{ .app_id = "wx-run" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var wr = WeRun.init(&ctx, allocator);

    var parsed = try wr.getWeRunData(test_session_key, test_cipher, test_iv);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.stepInfoList.len);
    try std.testing.expectEqual(@as(i64, 1234), parsed.value.stepInfoList[0].step);
    try std.testing.expectEqual(@as(i64, 1610969446), parsed.value.stepInfoList[0].timestamp);
}
