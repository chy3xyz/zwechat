// SPDX-License-Identifier: Apache-2.0
//! util/uri — URL query 转义
//!
//! 全仓唯一的 query 参数 percent-encode 实现，语义与 Go 标准库
//! `net/url.QueryEscape` 一致（`_ref/wechat` 中官方 OCR / 网页授权 / 开放平台
//! 授权链接构造均使用它）。
//!
//! **为什么不用 `std.Uri.Component.formatQuery`**：它的保留字符集允许
//! `&` `=` `?` `/` `:` `+` `*` `!` `'` `(` `)` 原样通过，且空格编码为 `%20`；
//! 把这样的值拼进微信接口的 query 时，值里的 `&` / `=` 会被服务端当成参数分隔符，
//! 直接导致参数被截断。Go 语义则只保留 `[0-9A-Za-z-_.~]`。

const std = @import("std");

/// 按 Go `url.QueryEscape` 语义做 percent-encode：
/// 保留 `[0-9A-Za-z-_.~]`；空格转 `+`；其余字节（含 `&` `=` `?` `#` `/` `%`
/// 与非 ASCII 字节）逐字节转 `%XX`（大写 hex）。
///
/// 返回的切片由 `allocator` 分配，调用方负责 `free`。
/// 错误集：`error{OutOfMemory}`。
pub fn queryEscape(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    const hex_upper = "0123456789ABCDEF";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    // 最坏情况：每个字节都编码成 `%XX`，输出是输入的 3 倍长。这里只是省掉重复
    // 扩容的预估——下面的写入一律走会自动扩容的 `append`，所以即便估少了也不会
    // 越界（历史上这里用 `appendAssumeCapacity` 配 `s.len` 的容量，超过分配器
    // 「1.5 倍 + 64 字节」余量就会越界写：Debug 下 panic、ReleaseFast 下堆溢出）。
    try buf.ensureTotalCapacity(allocator, 3 *| s.len);
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try buf.append(allocator, c),
            ' ' => try buf.append(allocator, '+'),
            else => {
                try buf.append(allocator, '%');
                try buf.append(allocator, hex_upper[c >> 4]);
                try buf.append(allocator, hex_upper[c & 0x0F]);
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}

test "queryEscape 长「最坏情况」输入不越界（容量估算回归）" {
    const allocator = std.testing.allocator;
    // 每个字节都编码成 `%XX`（3 倍长）时，输出长度会超过分配器给的
    // 「1.5 倍 + 64 字节」余量。旧实现只预留 `s.len` 却用 `appendAssumeCapacity`，
    // 在这里会越界写（Debug/ReleaseSafe 下 panic，ReleaseFast 下堆溢出）。
    var input: [256]u8 = undefined;
    @memset(&input, 0xff);
    const escaped = try queryEscape(allocator, &input);
    defer allocator.free(escaped);
    try std.testing.expectEqual(@as(usize, input.len * 3), escaped.len);
    for (escaped) |c| try std.testing.expect(c == '%' or c == 'F');
}

test "queryEscape 保留 Go 的 unreserved 字符集" {
    const allocator = std.testing.allocator;
    // Go: url.QueryEscape("AZaz09-_.~") == "AZaz09-_.~"
    const plain = try queryEscape(allocator, "AZaz09-_.~");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("AZaz09-_.~", plain);
}

test "queryEscape 空格转 + ，其余转大写 hex" {
    const allocator = std.testing.allocator;
    // Go: url.QueryEscape("a b&c=中") == "a+b%26c%3D%E4%B8%AD"
    const esc = try queryEscape(allocator, "a b&c=中");
    defer allocator.free(esc);
    try std.testing.expectEqualStrings("a+b%26c%3D%E4%B8%AD", esc);
}

test "queryEscape 转义格式串不保留的 & = ? # / :" {
    const allocator = std.testing.allocator;
    // Go: url.QueryEscape("https://example.com/a b.jpg?x=1&y=2")
    //  == "https%3A%2F%2Fexample.com%2Fa+b.jpg%3Fx%3D1%26y%3D2"
    // 这正是 std.Uri.Component.formatQuery 做不到的（它保留 :/?&）。
    const esc = try queryEscape(allocator, "https://example.com/a b.jpg?x=1&y=2");
    defer allocator.free(esc);
    try std.testing.expectEqualStrings("https%3A%2F%2Fexample.com%2Fa+b.jpg%3Fx%3D1%26y%3D2", esc);
}

test "queryEscape 转义 % 与 # （避免二次编码歧义与 fragment 截断）" {
    const allocator = std.testing.allocator;
    // Go: url.QueryEscape("100%#frag") == "100%25%23frag"
    const esc = try queryEscape(allocator, "100%#frag");
    defer allocator.free(esc);
    try std.testing.expectEqualStrings("100%25%23frag", esc);
}

test "queryEscape 空串返回空切片且无分配泄漏" {
    const allocator = std.testing.allocator;
    const esc = try queryEscape(allocator, "");
    defer allocator.free(esc);
    try std.testing.expectEqual(@as(usize, 0), esc.len);
}

test "queryEscape 高字节逐字节编码（UTF-8 多字节）" {
    const allocator = std.testing.allocator;
    // Go: url.QueryEscape("\xff\x00") == "%FF%00"
    const esc = try queryEscape(allocator, "\xff\x00");
    defer allocator.free(esc);
    try std.testing.expectEqualStrings("%FF%00", esc);
}

// ──────────────────────────────────────────────────────────────────────────────
// fuzz（`zig build test --fuzz=<N>` 才真正变异；普通 `zig build test` 只跑空输入冒烟）
// ──────────────────────────────────────────────────────────────────────────────

const fuzz_byte_weights = [_]std.testing.Smith.Weight{
    .rangeAtMost(u8, 'A', 'Z', 3),
    .rangeAtMost(u8, 'a', 'z', 3),
    .rangeAtMost(u8, '0', '9', 3),
    .value(u8, ' ', 6),
    .value(u8, '%', 6),
    .value(u8, '+', 5),
    .value(u8, '&', 4),
    .value(u8, '=', 4),
    .value(u8, '?', 4),
    .value(u8, '#', 4),
    .value(u8, '/', 4),
    .value(u8, ':', 4),
    .value(u8, '-', 3),
    .value(u8, '_', 3),
    .value(u8, '.', 3),
    .value(u8, '~', 3),
    .rangeAtMost(u8, 0x00, 0x1f, 1),
    .rangeAtMost(u8, 0x7f, 0xff, 2), // UTF-8 多字节 / 高位字节
};

/// `%XX` 的 hex 位元（非法字符返回 `null`）。
fn fuzzHexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// 性质：
/// 1. 输出字符集 ⊆ `[0-9A-Za-z\-_.~+%]`；
/// 2. 每个 `%` 之后必然紧跟两位 hex（不存在孤立 `%`，也不会越界读）；
/// 3. percent-decode（`+` 还原成空格）必须逐字节还原出原输入——即转义无损、
///    且 `&` `=` `?` `#` 这些分隔符不会以原形漏进 query。
fn testQueryEscapeProperties(allocator: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &fuzz_byte_weights);
    const input = buf[0..len];

    const escaped = try queryEscape(allocator, input);
    defer allocator.free(escaped);

    var i: usize = 0;
    while (i < escaped.len) {
        const c = escaped[i];
        if (c == '%') {
            try std.testing.expect(i + 2 < escaped.len);
            try std.testing.expect(fuzzHexDigit(escaped[i + 1]) != null);
            try std.testing.expect(fuzzHexDigit(escaped[i + 2]) != null);
            i += 3;
            continue;
        }
        const plain = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '+';
        try std.testing.expect(plain);
        i += 1;
    }

    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    defer decoded.deinit(allocator);
    i = 0;
    while (i < escaped.len) {
        if (escaped[i] == '%') {
            const hi = fuzzHexDigit(escaped[i + 1]).?;
            const lo = fuzzHexDigit(escaped[i + 2]).?;
            try decoded.append(allocator, hi * 16 + lo);
            i += 3;
        } else {
            try decoded.append(allocator, if (escaped[i] == '+') ' ' else escaped[i]);
            i += 1;
        }
    }
    try std.testing.expectEqualSlices(u8, input, decoded.items);
}

test "fuzz: queryEscape 的字符集与 percent 解码可逆" {
    try std.testing.fuzz(std.testing.allocator, testQueryEscapeProperties, .{});
}
