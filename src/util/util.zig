//! util/util — 通用工具
//!
//! 对应 `_ref/wechat/util/util.go`：提供 `SliceChunk` —— 把字符串切片切成固定大小的子切片，
//! 最后一个子切片可能更短。常用于把大批量 openid 拆分为多次群发请求。

const std = @import("std");

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
) (std.mem.Allocator.Error || error{InvalidArgument})![][]const []const u8 {
    const size = if (chunk_size == 0) 1 else chunk_size;
    if (src.len == 0) return &.{};
    if (size == 0) return error.InvalidArgument;

    const chunk_num = (src.len + size - 1) / size;
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
/// 使用 `std.Random.DefaultPrng` 播种自纳秒时间戳 —— 行为上对应 Go 的 `math/rand`（非加密场景）。
pub fn randomStr(allocator: std.mem.Allocator, length: usize) std.mem.Allocator.Error![]u8 {
    if (length == 0) return allocator.alloc(u8, 0);
    const out = try allocator.alloc(u8, length);
    errdefer allocator.free(out);
    var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Clock.now(.real, std.Options.debug_io).toNanoseconds() & 0xFFFFFFFF));
    const r = prng.random();
    var i: usize = 0;
    while (i < length) : (i += 1) {
        const idx = r.intRangeAtMost(u8, 0, randomAlphabet.len - 1);
        out[i] = randomAlphabet[idx];
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
