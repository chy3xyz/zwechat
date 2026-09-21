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
    try buf.ensureTotalCapacity(allocator, s.len);
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try buf.append(allocator, c),
            ' ' => try buf.append(allocator, '+'),
            else => {
                buf.appendAssumeCapacity('%');
                buf.appendAssumeCapacity(hex_upper[c >> 4]);
                buf.appendAssumeCapacity(hex_upper[c & 0x0F]);
            },
        }
    }
    return buf.toOwnedSlice(allocator);
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
