// SPDX-License-Identifier: Apache-2.0
//! util/json — JSON 字符串转义
//!
//! 全仓唯一的 JSON 字符串转义实现。此前每个业务模块各自手写一份
//! `appendJsonString` / `appendJsonEscaped`，其中多份漏掉了
//! `c < 0x20` 控制字符（RFC 8259 要求转义），用户输入一旦含控制字符
//! （换行之外的 `\x00-\x1F`，例如剪贴板/OCR 文本）就会产出非法 JSON。
//! 现统一收敛到本模块。
//!
//! 转义规则与 `std.json` 的 `outputSpecialEscape` 逐字一致（短转义
//! `\b` `\f` `\n` `\r` `\t`、`\"` `\\`，其余控制字符 `\u00xx` 小写 hex），
//! 因此这些调用点未来若换成 `std.json.Stringify`，字节序列不会变化。
//!
//! **非法 UTF-8 的处理**：RFC 8259 要求 JSON 文本本身是合法 UTF-8，因此坏字节
//! 不能原样透传（否则拼出的 JSON 连 `std.json` 自己都读不回来）。与 Go
//! `encoding/json` 一致，每个非法字节替换为 `\ufffd`，保证输出永远是合法 JSON
//! 字符串；合法 UTF-8 序列仍逐字节原样透传。

const std = @import("std");

/// 把 `s` 按 JSON 字符串规则转义后追加到 `buf`（**不含**首尾双引号）。
///
/// 覆盖 RFC 8259 要求转义的全部字符：`"`、`\`、`\b`、`\f`、`\n`、`\r`、
/// `\t` 以及其余 `U+0000`–`U+001F`（输出为 `\u00xx`）。
/// 非 ASCII 部分按 UTF-8 序列逐个判断：合法码点原样透传（微信接口接受 UTF-8
/// 原文，不做 `\uXXXX` 化），非法字节替换为 `\ufffd`（与 Go `encoding/json`
/// 的 `utf8.DecodeRune` 分支一致：一个坏字节一个替换字符，既不丢也不并）。
pub fn appendEscapedString(
    allocator: std.mem.Allocator,
    buf: anytype,
    s: []const u8,
) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            i += 1;
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                0x08 => try buf.appendSlice(allocator, "\\b"),
                0x0C => try buf.appendSlice(allocator, "\\f"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                0x00...0x07, 0x0B, 0x0E...0x1F => try buf.print(allocator, "\\u{x:0>4}", .{c}),
                else => try buf.append(allocator, c),
            }
            continue;
        }

        const seq_len: usize = blk: {
            const n: usize = std.unicode.utf8ByteSequenceLength(c) catch break :blk 0;
            if (i + n > s.len or !std.unicode.utf8ValidateSlice(s[i..][0..n])) break :blk 0;
            break :blk n;
        };
        if (seq_len == 0) {
            try buf.appendSlice(allocator, "\\ufffd");
            i += 1;
        } else {
            try buf.appendSlice(allocator, s[i..][0..seq_len]);
            i += seq_len;
        }
    }
}

/// 构造单字段 JSON 对象 `{"<field>":"<value>"}`，`field` 与 `value` 均按
/// JSON 字符串规则转义。
///
/// 用于原先 `std.fmt.allocPrint(alloc, "{{\"k\":\"{s}\"}}", .{v})` 的调用点：
/// 那些位置的值往往直接来自调用方（openid / media_id / 运单号 / action …），
/// 一旦含 `"` 或控制字符就会拼出非法 JSON。
///
/// 返回的切片由 `allocator` 分配，调用方负责 `free`。
/// 错误集：`error{OutOfMemory}`。
pub fn stringFieldObject(
    allocator: std.mem.Allocator,
    field: []const u8,
    value: []const u8,
) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try buf.append(allocator, '"');
    try appendEscapedString(allocator, &buf, field);
    try buf.appendSlice(allocator, "\":\"");
    try appendEscapedString(allocator, &buf, value);
    try buf.appendSlice(allocator, "\"}");
    return buf.toOwnedSlice(allocator);
}

/// `appendEscapedString` 的便捷包装：返回带首尾双引号的 JSON 字符串字面量。
/// 返回的切片由 `allocator` 分配，调用方负责 `free`。
pub fn stringLiteral(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '"');
    try appendEscapedString(allocator, &buf, s);
    try buf.append(allocator, '"');
    return buf.toOwnedSlice(allocator);
}

test "appendEscapedString 转义引号、反斜杠与短转义" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try appendEscapedString(allocator, &buf, "a\"b\\c\nd\re\tf");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\re\\tf", buf.items);
}

test "appendEscapedString 其余控制字符输出 \\u00xx（小写 hex）" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try appendEscapedString(allocator, &buf, "a\x01b\x1fc\x00d\x0be");
    // 与 std.json 的 outputSpecialEscape 一致（std.json 用 lowercase hex）。
    try std.testing.expectEqualStrings("a\\u0001b\\u001fc\\u0000d\\u000be", buf.items);
}

test "appendEscapedString 对 \\b \\f 用短转义（与 std.json 一致）" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try appendEscapedString(allocator, &buf, "\x08\x0c");
    try std.testing.expectEqualStrings("\\b\\f", buf.items);
}

test "appendEscapedString 非 ASCII 与 UTF-8 原样透传" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try appendEscapedString(allocator, &buf, "中文/emoji 🙂");
    try std.testing.expectEqualStrings("中文/emoji 🙂", buf.items);
}

test "appendEscapedString 非法 UTF-8 字节替换为 \\ufffd（与 Go encoding/json 一致）" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    // \xff 非法首字节、\xc3 被截断的 2 字节序列、\xc0\x80 是 overlong 编码，
    // 中间的 \xc3\xa9（é）是合法序列，必须原样留下。
    try appendEscapedString(allocator, &buf, "\xffa\xc3\xc0\x80\xc3\xa9");
    try std.testing.expectEqualStrings("\\ufffda\\ufffd\\ufffd\\ufffd\xc3\xa9", buf.items);

    // 输出必须能被 std.json 读回（旧实现会把坏字节原样写进去，产出非法 JSON）。
    const lit = try stringLiteral(allocator, "\xff\xfe");
    defer allocator.free(lit);
    const parsed = try std.json.parseFromSlice([]const u8, allocator, lit, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}", parsed.value);
}

test "appendEscapedString 输出可被 std.json 解析（控制字符回归）" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const raw = "line1\nline2\t\"quoted\"\x01\x1f end";
    try buf.append(allocator, '"');
    try appendEscapedString(allocator, &buf, raw);
    try buf.append(allocator, '"');

    const parsed = try std.json.parseFromSlice([]const u8, allocator, buf.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(raw, parsed.value);
}

test "stringFieldObject 转义值中的引号与控制字符" {
    const allocator = std.testing.allocator;
    const body = try stringFieldObject(allocator, "user_id", "o\"ABC\x01");
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"user_id\":\"o\\\"ABC\\u0001\"}", body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("o\"ABC\x01", parsed.value.object.get("user_id").?.string);
}

test "stringFieldObject 安全输入与旧 allocPrint 字节一致" {
    const allocator = std.testing.allocator;
    const body = try stringFieldObject(allocator, "media_id", "MEdiaID_123");
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"media_id\":\"MEdiaID_123\"}", body);
}

test "stringLiteral 与 stringFieldObject 的转义一致" {
    const allocator = std.testing.allocator;
    const lit = try stringLiteral(allocator, "a\x1fb\"c");
    defer allocator.free(lit);
    try std.testing.expectEqualStrings("\"a\\u001fb\\\"c\"", lit);
}

// ──────────────────────────────────────────────────────────────────────────────
// fuzz（`zig build test --fuzz=<N>` 才真正变异；普通 `zig build test` 只跑空输入冒烟）
// ──────────────────────────────────────────────────────────────────────────────

/// 码点计数：非法 UTF-8 字节各算一个（与 Go `utf8.DecodeRune` 的兜底一致），
/// 用于校验坏字节是「逐个替换」——既不静默丢字节，也不把坏字节并成一个。
fn fuzzRuneCount(bytes: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < bytes.len) : (count += 1) {
        const n: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            continue;
        };
        if (i + n > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i..][0..n])) {
            i += 1;
            continue;
        }
        i += n;
    }
    return count;
}

/// 黄金性质：`'"' ++ appendEscapedString(s) ++ '"'` 必须能被 `std.json` 读回来
/// ——任意字节输入都必须是合法 JSON 字符串；输入是合法 UTF-8 时逐字节等于原串。
fn testJsonEscapeGoldenProperty(allocator: std.mem.Allocator, smith: *std.testing.Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const weights = [_]std.testing.Smith.Weight{
        .value(u8, '"', 8),
        .value(u8, '\\', 8),
        .value(u8, 0x00, 4),
        .value(u8, 0x1f, 4),
        .value(u8, '\n', 4),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .rangeAtMost(u8, 0x80, 0xbf, 2), // 孤立的续字节
        .rangeAtMost(u8, 0xc0, 0xff, 2), // 首字节 / overlong / 截断序列
    };
    const len = smith.sliceWeightedBytes(&buf, &weights);
    const input = buf[0..len];

    const literal = try stringLiteral(allocator, input);
    defer allocator.free(literal);

    const parsed = std.json.parseFromSlice([]const u8, allocator, literal, .{}) catch
        return error.EscapedStringIsNotValidJson;
    defer parsed.deinit();

    if (std.unicode.utf8ValidateSlice(input)) {
        try std.testing.expectEqualSlices(u8, input, parsed.value);
    } else {
        try std.testing.expectEqual(fuzzRuneCount(input), fuzzRuneCount(parsed.value));
    }
}

test "fuzz: appendEscapedString 的输出是合法 JSON 且能读回原串" {
    try std.testing.fuzz(std.testing.allocator, testJsonEscapeGoldenProperty, .{});
}
