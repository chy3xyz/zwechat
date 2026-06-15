//! util/signature — 微信 SHA1 签名
//!
//! 对应 `_ref/wechat/util/signature.go` 的 `Signature`：先把入参按字典序升序排序，
//! 再依次拼接（不加分隔符），最后做 SHA1 哈希，以小写 hex 形式返回。
//!
//! 微信 JS-SDK 的签名校验、消息加解密、回调校验都用同样的 sort-then-hash 思路。
//! 注意：本函数不会自动跳 `sign` 键 / 空值——Go 版也是直接全拼，请在上游调用方处理。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;

const hex_lower = "0123456789abcdef";

/// 微信 SHA1 签名：参数排序 → 拼接 → SHA1 → 小写 hex。
///
/// 错误集：`error{OutOfMemory}`。
pub fn signature(allocator: Allocator, params: []const []const u8) Allocator.Error![]u8 {
    // 1. 拷贝并按字典序排序。Go 不会修改入参，所以这里用一份本地副本。
    var owned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer owned.deinit(allocator);
    try owned.ensureTotalCapacity(allocator, params.len);
    for (params) |p| owned.appendAssumeCapacity(p);
    std.sort.block([]const u8, owned.items, {}, lessThanStr);

    // 2. 拼接
    var total: usize = 0;
    for (owned.items) |p| total += p.len;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, total);
    for (owned.items) |p| try buf.appendSlice(allocator, p);

    // 3. SHA1
    var digest: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(buf.items, &digest, .{});

    // 4. 小写 hex
    const hex = try allocator.alloc(u8, digest.len * 2);
    errdefer allocator.free(hex);
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_lower[b >> 4];
        hex[i * 2 + 1] = hex_lower[b & 0x0F];
    }
    return hex;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

test "signature(\"a\",\"b\",\"c\") == sha1(\"abc\")" {
    const allocator = std.testing.allocator;
    const got = try signature(allocator, &[_][]const u8{ "a", "b", "c" });
    defer allocator.free(got);
    try std.testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", got);
}

test "signature 排序后与乱序结果一致" {
    const allocator = std.testing.allocator;
    const a = try signature(allocator, &[_][]const u8{ "c", "a", "b" });
    defer allocator.free(a);
    const b = try signature(allocator, &[_][]const u8{ "b", "c", "a" });
    defer allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", a);
}

test "signature 空参数返回 sha1(\"\")" {
    const allocator = std.testing.allocator;
    // sha1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
    const got = try signature(allocator, &[_][]const u8{});
    defer allocator.free(got);
    try std.testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", got);
}
