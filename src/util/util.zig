// SPDX-License-Identifier: Apache-2.0
//! util/util — 通用工具
//!
//! 对应 `_ref/wechat/util/util.go`：提供 `SliceChunk` —— 把字符串切片切成固定大小的子切片，
//! 最后一个子切片可能更短。常用于把大批量 openid 拆分为多次群发请求。

const std = @import("std");
const default_io = @import("default_io.zig");

/// 把 `src` 切成大小为 `chunk_size` 的子切片（最后一个可能更短）。
///
/// 与 Go 版行为一致：
/// - 当 `chunk_size < 1` 时，按 1 处理；
/// - 当 `src` 为空时，返回空切片；
/// - `chunk_size` 大于 `src.len` 时，仅返回一块完整的 `src`。
///
/// 错误集：`error{OutOfMemory}`。
pub fn sliceChunk(
    allocator: std.mem.Allocator,
    src: []const []const u8,
    chunk_size: usize,
) std.mem.Allocator.Error![][]const []const u8 {
    const size = if (chunk_size == 0) 1 else chunk_size;
    if (src.len == 0) return &.{}; // 空输入：无任何分配，调用方无需 free

    // (len - 1) / size + 1 与 (len + size - 1) / size 等价，但避免 len 接近
    // maxInt(usize) 时 `len + size - 1` 的加法溢出。
    const chunk_num = (src.len - 1) / size + 1;
    const result = try allocator.alloc([]const []const u8, chunk_num);
    errdefer allocator.free(result);

    var i: usize = 0;
    while (i < chunk_num) : (i += 1) {
        const start = i * size;
        const end = @min(start + size, src.len);
        // 子切片本身不分配内存，只是原 `src` 的视图；调用方无需释放。
        result[i] = src[start..end];
    }
    return result;
}

test "sliceChunk chunks=2" {
    const allocator = std.testing.allocator;
    const src = [_][]const u8{ "1", "2", "3", "4", "5" };
    const chunks = try sliceChunk(allocator, src[0..], 2);
    defer allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqualSlices(u8, "1", chunks[0][0]);
    try std.testing.expectEqualSlices(u8, "2", chunks[0][1]);
    try std.testing.expectEqualSlices(u8, "3", chunks[1][0]);
    try std.testing.expectEqualSlices(u8, "4", chunks[1][1]);
    try std.testing.expectEqualSlices(u8, "5", chunks[2][0]);
    try std.testing.expectEqual(@as(usize, 1), chunks[2].len);
}

test "sliceChunk chunks=3" {
    const allocator = std.testing.allocator;
    const src = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g" };
    const chunks = try sliceChunk(allocator, src[0..], 3);
    defer allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqual(@as(usize, 3), chunks[0].len);
    try std.testing.expectEqual(@as(usize, 3), chunks[1].len);
    try std.testing.expectEqual(@as(usize, 1), chunks[2].len);
    try std.testing.expectEqualSlices(u8, "a", chunks[0][0]);
    try std.testing.expectEqualSlices(u8, "g", chunks[2][0]);
}

test "sliceChunk chunks>=src 返回单块" {
    const allocator = std.testing.allocator;
    const src = [_][]const u8{ "1", "2", "3" };
    const chunks = try sliceChunk(allocator, src[0..], 10);
    defer allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqual(@as(usize, 3), chunks[0].len);
}

test "sliceChunk chunks=0 当作 1 处理" {
    const allocator = std.testing.allocator;
    const src = [_][]const u8{ "x", "y", "z" };
    const chunks = try sliceChunk(allocator, src[0..], 0);
    defer allocator.free(chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
}

test "sliceChunk 空输入返回空切片" {
    const allocator = std.testing.allocator;
    const chunks = try sliceChunk(allocator, &[_][]const u8{}, 5);
    try std.testing.expectEqual(@as(usize, 0), chunks.len);
}

/// 字符表：`0-9a-zA-Z`，对应 Go `util.RandomStr` 使用的字符集。
const randomAlphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// 生成 `length` 字节的随机字符串，字符集与 Go `util.RandomStr` 一致。
///
/// **deprecated**：请改用 [`randomStrWithIo`] 显式传入宿主的 `Io`；本函数保留为
/// 等价的默认实现（熵源取自 `default_io`），行为不变。
pub fn randomStr(allocator: std.mem.Allocator, length: usize) std.mem.Allocator.Error![]u8 {
    return randomStrWithIo(allocator, default_io.io(), length);
}

/// 生成 `length` 字节的随机字符串，字符集与 Go `util.RandomStr` 一致。
///
/// 熵源是注入的 `io.random`（`std.Random.IoSource` 桥接到 `std.Random` 接口），
/// 因此与时钟粒度无关：同一微秒内的两次调用也不会撞出相同的字符串。
/// 例如 `pay/*` / `officialaccount/js` / `work/jsapi` 的 `nonce_str` 都依赖它
/// 抵御重放，注入的 `io` 也由此真正生效（宿主可换成确定性 `Io` 以复现测试）。
///
/// 字符映射沿用 `intRangeAtMost` 的拒绝采样（无取模偏差），字符集与长度语义
/// 与历史实现完全一致；返回的切片由调用方负责 `free`。
pub fn randomStrWithIo(allocator: std.mem.Allocator, io: std.Io, length: usize) std.mem.Allocator.Error![]u8 {
    if (length == 0) return allocator.alloc(u8, 0);
    const out = try allocator.alloc(u8, length);
    errdefer allocator.free(out);
    var source: std.Random.IoSource = .{ .io = io };
    const r = source.interface();
    for (out) |*c| {
        const idx = r.intRangeAtMost(u8, 0, randomAlphabet.len - 1);
        c.* = randomAlphabet[idx];
    }
    return out;
}

test "randomStr 长度与字符集" {
    const allocator = std.testing.allocator;
    const s = try randomStr(allocator, 16);
    defer allocator.free(s);
    try std.testing.expectEqual(@as(usize, 16), s.len);
    for (s) |c| {
        var found = false;
        for (randomAlphabet) |a| if (a == c) {
            found = true;
            break;
        };
        try std.testing.expect(found);
    }
}

test "randomStrWithIo 注入 io 后长度与字符集一致" {
    const allocator = std.testing.allocator;
    const s = try randomStrWithIo(allocator, std.testing.io, 32);
    defer allocator.free(s);
    try std.testing.expectEqual(@as(usize, 32), s.len);
    for (s) |c| {
        try std.testing.expect(std.mem.findScalar(u8, randomAlphabet, c) != null);
    }
}

test "randomStrWithIo 长度为 0 返回空切片" {
    const allocator = std.testing.allocator;
    const s = try randomStrWithIo(allocator, std.testing.io, 0);
    defer allocator.free(s);
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

test "randomStrWithIo 紧邻两次调用不重复（熵源来自 io.random 而非时钟）" {
    const allocator = std.testing.allocator;
    // 回归：旧实现用 `now().toNanoseconds() & 0xFFFFFFFF` 播种 PRNG，而 macOS 上
    // real clock 只有 1µs 粒度 —— ReleaseFast 下这两次紧邻调用会拿到完全相同的
    // nonce（nonce 的防重放意义被打掉）。改用 `io.random` 后必须每次不同。
    const a = try randomStrWithIo(allocator, std.testing.io, 32);
    defer allocator.free(a);
    const b = try randomStrWithIo(allocator, std.testing.io, 32);
    defer allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

/// 只覆写 `random` 的 `Io`：固定字节流，用来证明 `randomStrWithIo` 真的走 `io.random`。
const FixedRandomIo = struct {
    vtable: std.Io.VTable = undefined,
    byte: u8,

    fn random(ctx: ?*anyopaque, buf: []u8) void {
        const self: *FixedRandomIo = @ptrCast(@alignCast(ctx.?));
        @memset(buf, self.byte);
    }

    fn io(self: *FixedRandomIo) std.Io {
        self.vtable = default_io.io().vtable.*;
        self.vtable.random = random;
        return .{ .userdata = self, .vtable = &self.vtable };
    }
};

test "randomStrWithIo 的熵源取自注入的 io（确定性 Io → 可复现）" {
    const allocator = std.testing.allocator;
    // 0x01 / 0x05 都落在拒绝采样区间外（无重取），映射结果确定可预测。
    var io_a = FixedRandomIo{ .byte = 0x01 };
    const a = try randomStrWithIo(allocator, io_a.io(), 16);
    defer allocator.free(a);
    var io_b = FixedRandomIo{ .byte = 0x01 };
    const b = try randomStrWithIo(allocator, io_b.io(), 16);
    defer allocator.free(b);
    var io_c = FixedRandomIo{ .byte = 0x05 };
    const c = try randomStrWithIo(allocator, io_c.io(), 16);
    defer allocator.free(c);

    try std.testing.expectEqualStrings("0000000000000000", a);
    // 同一确定性熵源 → 逐字节可复现（证明走的是注入的 io，而非全局单例）。
    try std.testing.expectEqualStrings(a, b);
    // 换一个字节流 → 输出随熵源改变（证明不是常量、也不是时钟播种）。
    try std.testing.expectEqualStrings("1111111111111111", c);
}
