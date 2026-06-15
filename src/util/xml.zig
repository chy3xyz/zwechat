//! util/xml — 微信消息格式 XML 编解码（极简）
//!
//! 微信推送的 XML 格式：`<xml><key><![CDATA[val]]></key>...</xml>`，层级只有一层。
//! 不追求完整 XML 1.0 兼容性。
//!
//! 数据结构：
//! - `XmlElement`：扁平 `key → value` 映射（CDATA 内容作为 value）。
//! - `XmlDoc`：整个文档，包含 `root_name` 和 `elements`。
//!
//! 适用场景：公众号 server 模块解析收到的 XML、被动回复时构造 XML。
//! 不适用：复杂嵌套 / 命名空间 / 处理指令（微信消息用不到）。

const std = @import("std");

/// 单个 XML 元素（key = tag 名，value = CDATA / 文本）。
pub const XmlElement = struct {
    key: []const u8,
    value: []const u8,
};

/// 完整的 XML 文档。
pub const XmlDoc = struct {
    root_name: []const u8,
    elements: []XmlElement,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *XmlDoc) void {
        self.allocator.free(@constCast(self.elements));
    }

    /// 按 key 查找元素值。找不到返回 `null`。
    pub fn get(self: XmlDoc, key: []const u8) ?[]const u8 {
        for (self.elements) |el| if (std.mem.eql(u8, el.key, key)) return el.value;
        return null;
    }

    pub fn count(self: XmlDoc) usize {
        return self.elements.len;
    }
};

/// 把 XML 字符串解析为 `XmlDoc`。
///
/// 只支持单层结构（root 标签 + 一组子元素）。每个子元素必须有匹配的 `</key>` 结束标签。
/// value 可以是 `<![CDATA[...]]>` 或纯文本。
///
/// 错误集：`Allocator.Error || error{MalformedXml}`。
pub fn parse(allocator: std.mem.Allocator, input: []const u8) (std.mem.Allocator.Error || error{ MalformedXml })!XmlDoc {
    // 跳过前导空白
    var pos: usize = 0;
    skipWs(input, &pos);

    // 跳过可选的 `<?xml ...?>` 声明
    if (pos + 5 <= input.len and std.mem.eql(u8, input[pos .. pos + 5], "<?xml")) {
        const end = std.mem.indexOfScalarPos(u8, input, pos, '>') orelse return error.MalformedXml;
        pos = end + 1;
        skipWs(input, &pos);
    }

    // 解析 root 开始标签
    if (pos >= input.len or input[pos] != '<') return error.MalformedXml;
    pos += 1;
    const root_name = readUntil(input, &pos, &[_]u8{ '>', ' ', '\t', '\n', '\r' }) orelse return error.MalformedXml;
    skipToGt(input, &pos);
    if (pos >= input.len) return error.MalformedXml;
    pos += 1; // consume '>'

    var elements: std.ArrayListUnmanaged(XmlElement) = .empty;
    errdefer elements.deinit(allocator);

    while (pos < input.len) {
        skipWs(input, &pos);
        if (pos >= input.len) break;

        // 结束 root
        if (pos + 1 < input.len and input[pos] == '<' and input[pos + 1] == '/') {
            break;
        }
        if (input[pos] != '<') return error.MalformedXml;
        pos += 1;

        // 子元素开始标签
        const key = readUntil(input, &pos, &[_]u8{ '>', ' ', '\t', '\n', '\r' }) orelse return error.MalformedXml;
        skipToGt(input, &pos);
        if (pos >= input.len) return error.MalformedXml;
        pos += 1; // consume '>'

        // 子元素 value（CDATA 或纯文本）
        const value = readValue(allocator, input, &pos) catch return error.MalformedXml;
        try elements.append(allocator, .{ .key = key, .value = value });

        // 子元素结束标签 `</key>`
        if (pos + 2 >= input.len or input[pos] != '<' or input[pos + 1] != '/') return error.MalformedXml;
        pos += 2;
        const close_key = readUntil(input, &pos, &[_]u8{ '>', ' ', '\t', '\n', '\r' }) orelse return error.MalformedXml;
        skipToGt(input, &pos);
        if (pos >= input.len) return error.MalformedXml;
        pos += 1; // consume '>'

        if (!std.mem.eql(u8, key, close_key)) return error.MalformedXml;
    }

    return .{
        .root_name = root_name,
        .elements = try elements.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// 序列化为 XML 字符串（`<root><key>value</key>...</root>`），value 用 CDATA 包裹。
///
/// 错误集：`Allocator.Error`。
pub fn serialize(allocator: std.mem.Allocator, root_name: []const u8, elements: []const XmlElement) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.print(allocator, "<{s}>", .{root_name});
    for (elements) |el| {
        try buf.print(allocator, "<{s}><![CDATA[{s}]]></{s}>", .{ el.key, el.value, el.key });
    }
    try buf.print(allocator, "</{s}>", .{root_name});
    return buf.toOwnedSlice(allocator);
}

// ──────────────────────────────────────────────────────────────────────────────
// 内部：辅助函数
// ──────────────────────────────────────────────────────────────────────────────

fn skipWs(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and (input[pos.*] == ' ' or input[pos.*] == '\t' or input[pos.*] == '\n' or input[pos.*] == '\r')) {
        pos.* += 1;
    }
}

fn skipToGt(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and input[pos.*] != '>') : (pos.* += 1) {}
}

fn readUntil(input: []const u8, pos: *usize, terminators: []const u8) ?[]const u8 {
    const start = pos.*;
    while (pos.* < input.len) {
        for (terminators) |t| {
            if (input[pos.*] == t) return input[start..pos.*];
        }
        pos.* += 1;
    }
    return null;
}

/// 在 pos 处读取一个元素 value（CDATA 或纯文本），pos 推进到 value 末尾之后。
/// 返回的 slice 指向 input 内部，无需分配。
fn readValue(allocator: std.mem.Allocator, input: []const u8, pos: *usize) ![]const u8 {
    _ = allocator;
    // CDATA 模式
    if (pos.* + 9 <= input.len and std.mem.eql(u8, input[pos.* .. pos.* + 9], "<![CDATA[")) {
        pos.* += 9;
        const start = pos.*;
        const end = std.mem.indexOfPos(u8, input, start, "]]>") orelse return error.MalformedXml;
        pos.* = end + 3;
        return input[start..end];
    }
    // 普通文本模式：读到下一个 `</`
    const start = pos.*;
    const next_close = std.mem.indexOfPos(u8, input, start, "</") orelse return error.MalformedXml;
    pos.* = next_close;
    return input[start..next_close];
}

test "parse + get 微信格式 XML" {
    const allocator = std.testing.allocator;
    const xml =
        \\<xml>
        \\  <ToUserName><![CDATA[gh_abc]]></ToUserName>
        \\  <FromUserName><![CDATA[user123]]></FromUserName>
        \\  <CreateTime>1700000000</CreateTime>
        \\  <MsgType><![CDATA[text]]></MsgType>
        \\  <Content><![CDATA[hello]]></Content>
        \\</xml>
    ;
    var doc = try parse(allocator, xml);
    defer doc.deinit();
    try std.testing.expectEqualStrings("xml", doc.root_name);
    try std.testing.expectEqualStrings("gh_abc", doc.get("ToUserName").?);
    try std.testing.expectEqualStrings("hello", doc.get("Content").?);
    try std.testing.expectEqualStrings("text", doc.get("MsgType").?);
    try std.testing.expectEqualStrings("1700000000", doc.get("CreateTime").?);
    try std.testing.expectEqual(@as(usize, 5), doc.count());
}

test "parse 无 XML 声明" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "<xml><A>1</A></xml>");
    defer doc.deinit();
    try std.testing.expectEqualStrings("1", doc.get("A").?);
    try std.testing.expectEqualStrings("xml", doc.root_name);
}

test "serialize round-trip" {
    const allocator = std.testing.allocator;
    const elems = [_]XmlElement{
        .{ .key = "ToUserName", .value = "abc" },
        .{ .key = "Content", .value = "<b>hello</b>" },
    };
    const out = try serialize(allocator, "xml", &elems);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<![CDATA[<b>hello</b>]]>") != null);
}

test "get 不存在的 key 返回 null" {
    const allocator = std.testing.allocator;
    const xml = "<xml><A>1</A></xml>";
    var doc = try parse(allocator, xml);
    defer doc.deinit();
    try std.testing.expect(doc.get("B") == null);
}