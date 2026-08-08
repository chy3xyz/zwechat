// SPDX-License-Identifier: Apache-2.0
//! util/template — 编译期微信模板消息/订阅消息 JSON 数据生成器
//!
//! 利用 Zig `comptime` 反射，将任意平铺的 Zig 结构体（如 `.{ .first = "Title", .keyword1 = "Val" }`）
//! 编译期自动转换为微信要求的 `{"first":{"value":"Title"},"keyword1":{"value":"Val"}}` JSON 格式。

const std = @import("std");

/// 将任意结构体实例转化为微信规范的模板消息 `data` JSON 字符串
///
/// `allocator`: 用于分配输出 JSON 字符串的内存（由调用方 `allocator.free`）
/// `data`: 任意包含字段的结构体（字段类型可以是 `[]const u8`、`i64`、`f64` 或 `bool`）
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
                    try buf.print(allocator, "\"{s}\"", .{val});
                } else {
                    try buf.print(allocator, "\"{s}\"", .{val});
                }
            },
            .int, .comptime_int => try buf.print(allocator, "{d}", .{val}),
            .float, .comptime_float => try buf.print(allocator, "{d}", .{val}),
            .bool => try buf.print(allocator, "{}", .{val}),
            else => try buf.print(allocator, "\"{any}\"", .{val}),
        }

        try buf.append(allocator, '}');
    }

    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
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
