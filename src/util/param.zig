//! util/param — 参数排序
//!
//! 对应 `_ref/wechat/util/param.go` 的 `OrderParam`：按 key 升序拼接成 `k1=v1&k2=v2&...`，
//! 自动跳过空值与 `sign` 键，最后追加 `bizKey`（如 `&key=xxx`）。
//!
//! 上游 Go 接收 `map[string]string`，Zig 没有内置 map 的快速访问语法，但大多数调用方
//! 已经在调用前收集好 `Param` 列表，因此这里改为接收一个 `[]const Param` 数组。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 单个键值对。
pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

/// 计算参数签名所需的拼接串：排序后 `k=v&k=v...`，跳过空值与 `sign`，最后追加 `biz_key`。
///
/// 错误集：`error{OutOfMemory}`。
///
/// 行为对照 Go 版：
/// 1. 收集所有 `key != "sign"` 的索引。
/// 2. 按 key 字典序升序排序。
/// 3. 拼接 `key=value`，跳过 `value == ""`。
/// 4. 末尾追加 `biz_key`（不附加 `&`）。
pub fn orderParam(
    allocator: Allocator,
    params: []const Param,
    biz_key: []const u8,
) Allocator.Error![]u8 {
    // 1. 收集需要参与拼接的索引
    var indices: std.ArrayListUnmanaged(usize) = .empty;
    defer indices.deinit(allocator);
    try indices.ensureTotalCapacity(allocator, params.len);
    for (params, 0..) |p, i| {
        if (std.mem.eql(u8, p.key, "sign")) continue;
        indices.appendAssumeCapacity(i);
    }

    // 2. 按 key 排序
    const Items = struct {
        const Self = @This();
        fn lessThan(ctx: []const Param, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ctx[a].key, ctx[b].key);
        }
    };
    std.sort.block(usize, indices.items, params, Items.lessThan);

    // 3 & 4. 拼接
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var first = true;
    for (indices.items) |i| {
        const p = params[i];
        if (p.value.len == 0) continue;
        if (!first) try buf.append(allocator, '&');
        first = false;
        try buf.appendSlice(allocator, p.key);
        try buf.append(allocator, '=');
        try buf.appendSlice(allocator, p.value);
    }
    try buf.appendSlice(allocator, biz_key);
    return buf.toOwnedSlice(allocator);
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

test "orderParam 排序并跳过空值" {
    const allocator = std.testing.allocator;
    const params = [_]Param{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
        .{ .key = "c", .value = "" }, // 跳过
    };
    const out = try orderParam(allocator, &params, "&key=xxx");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a=1&b=2&key=xxx", out);
}

test "orderParam 跳过 sign 键" {
    const allocator = std.testing.allocator;
    const params = [_]Param{
        .{ .key = "sign", .value = "DUMMYSIGN" },
        .{ .key = "a", .value = "1" },
        .{ .key = "b", .value = "2" },
    };
    const out = try orderParam(allocator, &params, "&key=xyz");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a=1&b=2&key=xyz", out);
}

test "orderParam 空参数列表只追加 biz_key" {
    const allocator = std.testing.allocator;
    const params = [_]Param{};
    const out = try orderParam(allocator, &params, "&key=kk");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("&key=kk", out);
}

test "orderParam 与 Go 版实际输出对齐" {
    // 与 Go 测试用例 `_ref/wechat/util/query_test.go` 的 OrderParam 行为一致：
    // {"appid":"wx","mch_id":"1","key":"k"} + "&key=k" → "appid=wx&mch_id=1&key=k"
    const allocator = std.testing.allocator;
    const params = [_]Param{
        .{ .key = "mch_id", .value = "1" },
        .{ .key = "appid", .value = "wx" },
    };
    const out = try orderParam(allocator, &params, "&key=k");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("appid=wx&mch_id=1&key=k", out);
}
