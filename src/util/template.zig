// SPDX-License-Identifier: Apache-2.0
//! util/template — 编译期微信模板消息/订阅消息 JSON 数据生成器
//!
//! 利用 Zig `comptime` 反射，将任意平铺的 Zig 结构体（如 `.{ .first = "Title", .keyword1 = "Val" }`）
//! 编译期自动转换为微信要求的 `{"first":{"value":"Title"},"keyword1":{"value":"Val"}}` JSON 格式。
//!
//! 字符串值按 JSON 规范转义（引号、反斜杠、控制字符），保证含特殊字符的内容
//! 也能生成合法的 JSON（微信模板消息正文经常包含换行与用户输入）。

const std = @import("std");

/// 追加一段 JSON 字符串字面量（带首尾双引号与转义）。
fn appendJsonString(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: []const u8,
) std.mem.Allocator.Error!void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        // 其余控制字符（< 0x20）必须转义，否则产出非法 JSON。
        else => if (c < 0x20) {
            try buf.print(allocator, "\\u{x:0>4}", .{c});
        } else {
            try buf.append(allocator, c);
        },
    };
    try buf.append(allocator, '"');
}

/// 将任意结构体实例转化为微信规范的模板消息 `data` JSON 字符串
///
/// `allocator`: 用于分配输出 JSON 字符串的内存（由调用方 `allocator.free`）
/// `data`: 任意包含字段的结构体（字段类型可以是字符串（切片 / 数组 / 哨兵数组）、`i64`、`f64` 或 `bool`）
pub fn buildTemplateData(allocator: std.mem.Allocator, data: anytype) ![]u8 {
    const T = @TypeOf(data);
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("buildTemplateData 只接受结构体类型");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '{');

    inline for (comptime std.meta.fieldNames(T), 0..) |field_name, idx| {
        if (idx > 0) try buf.append(allocator, ',');

        const val = @field(data, field_name);
        try buf.print(allocator, "\"{s}\":{{\"value\":", .{field_name});

        switch (@typeInfo(@TypeOf(val))) {
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    try appendJsonString(allocator, &buf, val);
                } else if (p.size == .one and comptime isU8Array(p.child)) {
                    // 字符串字面量的类型是 *const [N:0]u8，迭代前统一转成切片
                    //（哨字节不参与序列化）。
                    try appendJsonString(allocator, &buf, val);
                } else {
                    @compileError("buildTemplateData 只支持字符串切片 / 字符串数组字段，其他指针类型请改传切片");
                }
            },
            .array => |a| {
                if (a.child == u8) {
                    try appendJsonString(allocator, &buf, &val);
                } else {
                    @compileError("buildTemplateData 只支持 u8 数组字段");
                }
            },
            .int, .comptime_int => try buf.print(allocator, "{d}", .{val}),
            .float, .comptime_float => try buf.print(allocator, "{d}", .{val}),
            .bool => try buf.print(allocator, "{}", .{val}),
            else => @compileError("buildTemplateData 不支持的字段类型：" ++ @typeName(@TypeOf(val))),
        }

        try buf.append(allocator, '}');
    }

    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

fn isU8Array(comptime t: type) bool {
    return switch (@typeInfo(t)) {
        .array => |a| a.child == u8,
        else => false,
    };
}

test "buildTemplateData 编译期反射输出规范 JSON" {
    const allocator = std.testing.allocator;
    const msg = .{
        .first = "您的订单已发货",
        .order_id = 20260722,
        .remark = "感谢使用 zwechat",
    };

    const json_str = try buildTemplateData(allocator, msg);
    defer allocator.free(json_str);

    try std.testing.expectEqualStrings(
        "{\"first\":{\"value\":\"您的订单已发货\"},\"order_id\":{\"value\":20260722},\"remark\":{\"value\":\"感谢使用 zwechat\"}}",
        json_str,
    );
}

test "buildTemplateData 对字符串值做 JSON 转义" {
    // 回归：旧实现直接 `"{s}"` 拼接，值中含引号 / 反斜杠 / 换行 /
    // 控制字符时会产出非法 JSON。
    const allocator = std.testing.allocator;
    const msg = .{
        .content = "他说 \"你好\"\\n第二行",
        .ctrl = "a\x01b",
    };

    const json_str = try buildTemplateData(allocator, msg);
    defer allocator.free(json_str);

    try std.testing.expectEqualStrings(
        "{\"content\":{\"value\":\"他说 \\\"你好\\\"\\\\n第二行\"},\"ctrl\":{\"value\":\"a\\u0001b\"}}",
        json_str,
    );
    // 结果必须是合法 JSON：能被标准解析器原样读回。
    const T = struct { content: struct { value: []const u8 }, ctrl: struct { value: []const u8 } };
    var parsed = try std.json.parseFromSlice(T, allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(msg.content, parsed.value.content.value);
    try std.testing.expectEqualStrings(msg.ctrl, parsed.value.ctrl.value);
}
