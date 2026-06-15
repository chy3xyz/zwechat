//! util/asn1 — 最小 ASN.1 DER 解析器
//!
//! 仅支持本项目所需的最小子集：
//! - SEQUENCE / SEQUENCE OF
//! - INTEGER（正数，可带前导 0x00 符号位填充）
//! - BIT STRING（含 unused_bits == 0 检查）
//! - OCTET STRING
//! - OBJECT IDENTIFIER
//! - NULL
//!
//! 用于 RSA PEM 解析与 PKCS#12 解析。

const std = @import("std");

pub const Error = error{
    InvalidDer,
    UnsupportedTag,
    OutOfMemory,
};

pub const Tag = struct {
    class: u2,
    constructed: bool,
    number: u5,
};

pub const Reader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn remaining(self: Reader) usize {
        return self.data.len - self.pos;
    }

    pub fn readTag(self: *Reader) Error!Tag {
        if (self.pos >= self.data.len) return error.InvalidDer;
        const b = self.data[self.pos];
        self.pos += 1;
        return Tag{
            .class = @intCast((b >> 6) & 0x3),
            .constructed = ((b >> 5) & 0x1) != 0,
            .number = @intCast(b & 0x1f),
        };
    }

    pub fn peekTagNumber(self: *Reader) Error!u5 {
        if (self.pos >= self.data.len) return error.InvalidDer;
        return @intCast(self.data[self.pos] & 0x1f);
    }

    pub fn readLength(self: *Reader) Error!usize {
        if (self.pos >= self.data.len) return error.InvalidDer;
        const first = self.data[self.pos];
        self.pos += 1;
        if (first & 0x80 == 0) return first;
        const num_bytes = first & 0x7f;
        if (num_bytes == 0 or num_bytes > 4 or self.pos + num_bytes > self.data.len) return error.InvalidDer;
        var len: usize = 0;
        for (0..num_bytes) |_| {
            len = (len << 8) | self.data[self.pos];
            self.pos += 1;
        }
        return len;
    }

    /// 读取一个 SEQUENCE，返回其内容（不检查 tag/constructed，调用方应先 readTag）。
    pub fn readSequenceContent(self: *Reader, len: usize) Error![]const u8 {
        if (self.pos + len > self.data.len) return error.InvalidDer;
        const seq = self.data[self.pos..self.pos + len];
        self.pos += len;
        return seq;
    }

    /// 读取完整 INTEGER 并返回原始字节（含可能的前导 0x00）。
    pub fn readInteger(self: *Reader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x02) return error.InvalidDer;
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidDer;
        const bytes = self.data[self.pos..self.pos + len];
        self.pos += len;
        return bytes;
    }

    /// 读取 OCTET STRING。
    pub fn readOctetString(self: *Reader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x04) return error.InvalidDer;
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidDer;
        const bytes = self.data[self.pos..self.pos + len];
        self.pos += len;
        return bytes;
    }

    /// 读取 BIT STRING，要求 unused_bits == 0。
    pub fn readBitString(self: *Reader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x03) return error.InvalidDer;
        const len = try self.readLength();
        if (self.pos + len > self.data.len or len < 1) return error.InvalidDer;
        const unused_bits = self.data[self.pos];
        if (unused_bits != 0) return error.InvalidDer;
        const bs = self.data[self.pos + 1 .. self.pos + len];
        self.pos += len;
        return bs;
    }

    /// 读取 OBJECT IDENTIFIER。
    pub fn readObjectIdentifier(self: *Reader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x06) return error.InvalidDer;
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidDer;
        const oid = self.data[self.pos..self.pos + len];
        self.pos += len;
        return oid;
    }

    /// 读取并断言为 NULL。
    pub fn readNull(self: *Reader) Error!void {
        const tag = try self.readTag();
        if (tag.number != 0x05) return error.InvalidDer;
        const len = try self.readLength();
        if (len != 0) return error.InvalidDer;
    }

    /// 读取任意原始值（tag + length + content），返回 content。
    pub fn readRawValue(self: *Reader) Error!struct { tag: Tag, content: []const u8 } {
        const tag = try self.readTag();
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidDer;
        const content = self.data[self.pos..self.pos + len];
        self.pos += len;
        return .{ .tag = tag, .content = content };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────────────────────────────────────

test "Reader 解析 SEQUENCE-INTEGER" {
    // SEQUENCE { INTEGER 0x0102 }
    const der = &[_]u8{ 0x30, 0x04, 0x02, 0x02, 0x01, 0x02 };
    var r = Reader.init(der);

    const tag = try r.readTag();
    try std.testing.expect(tag.constructed);
    try std.testing.expectEqual(@as(u5, 0x10), tag.number);

    const len = try r.readLength();
    try std.testing.expectEqual(@as(usize, 4), len);

    const seq = try r.readSequenceContent(len);
    var inner = Reader.init(seq);
    const int_bytes = try inner.readInteger();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, int_bytes);
}

test "Reader 拒绝非零 unused_bits 的 BIT STRING" {
    const der = &[_]u8{ 0x03, 0x02, 0x05, 0x00 }; // unused_bits = 5
    var r = Reader.init(der);
    const result = r.readBitString();
    try std.testing.expectError(error.InvalidDer, result);
}
