// SPDX-License-Identifier: Apache-2.0
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
        const seq = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return seq;
    }

    /// 读取完整 INTEGER 并返回原始字节（含可能的前导 0x00）。
    pub fn readInteger(self: *Reader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x02) return error.InvalidDer;
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidDer;
        const bytes = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return bytes;
    }

    /// 读取 OCTET STRING。
    pub fn readOctetString(self: *Reader) Error![]const u8 {
        const tag = try self.readTag();
        if (tag.number != 0x04) return error.InvalidDer;
        const len = try self.readLength();
        if (self.pos + len > self.data.len) return error.InvalidDer;
        const bytes = self.data[self.pos .. self.pos + len];
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
        const oid = self.data[self.pos .. self.pos + len];
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
        const content = self.data[self.pos .. self.pos + len];
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

// ──────────────────────────────────────────────────────────────────────────────
// fuzz（`zig build test --fuzz=<N>` 才真正变异；普通 `zig build test` 只跑空输入冒烟）
// ──────────────────────────────────────────────────────────────────────────────

const FuzzOp = enum {
    read_tag,
    read_length,
    read_sequence,
    read_integer,
    read_octet_string,
    read_bit_string,
    read_oid,
    read_null,
    read_raw_value,
};

const fuzz_byte_weights = [_]std.testing.Smith.Weight{
    .rangeAtMost(u8, 0x00, 0x0f, 4), // 常见 tag 号
    .value(u8, 0x30, 4), // SEQUENCE
    .value(u8, 0x02, 4), // INTEGER
    .value(u8, 0x04, 4), // OCTET STRING
    .value(u8, 0x03, 3), // BIT STRING
    .value(u8, 0x06, 3), // OBJECT IDENTIFIER
    .value(u8, 0x05, 3), // NULL
    .rangeAtMost(u8, 0x20, 0x2f, 3), // constructed 位
    .rangeAtMost(u8, 0x80, 0x87, 4), // 长格式长度（num_bytes = 1..8）
    .value(u8, 0xff, 2),
    .rangeAtMost(u8, 0x00, 0xff, 2),
};

/// 性质（`readLength` 的 `num_bytes <= 4` 边界是本模块最关键的检查）：
/// 1. 任意字节序列驱动任意操作序列都不 panic、不越界：
///    `pos` 永不越过 `data.len`，返回的切片始终落在输入内；
/// 2. 成功的 `readLength` 结果必然装得进 u32（长格式只接受 1..4 字节）；
/// 3. 循环有界收敛（每个成功操作至少吃掉 1 字节，失败操作不卡死调用方）。
fn testAsn1ReaderInvariants(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &fuzz_byte_weights);
    const data = buf[0..len];
    var r = Reader.init(data);

    for (0..64) |_| {
        if (r.remaining() == 0) break;
        const op = smith.value(FuzzOp);
        const arg = smith.value(u32);
        var got: ?[]const u8 = null;

        switch (op) {
            .read_tag => {
                const tag = r.readTag() catch continue;
                try std.testing.expect(tag.number <= 0x1f);
            },
            .read_length => {
                const l = r.readLength() catch continue;
                try std.testing.expect(l <= std.math.maxInt(u32));
            },
            .read_sequence => {
                // 直接给长度：包含 usize 上界，专打越界检查这条分支。
                const l: usize = if (arg == 0) std.math.maxInt(usize) else arg;
                got = r.readSequenceContent(l) catch null;
            },
            .read_integer => got = r.readInteger() catch null,
            .read_octet_string => got = r.readOctetString() catch null,
            .read_bit_string => got = r.readBitString() catch null,
            .read_oid => got = r.readObjectIdentifier() catch null,
            .read_null => r.readNull() catch continue,
            .read_raw_value => {
                const v = r.readRawValue() catch continue;
                got = v.content;
            },
        }

        try std.testing.expect(r.pos <= data.len);
        try std.testing.expectEqual(data.len - r.pos, r.remaining());
        if (got) |slice| {
            const base = @intFromPtr(data.ptr);
            const p = @intFromPtr(slice.ptr);
            try std.testing.expect(p >= base and p + slice.len <= base + data.len);
        }
    }
}

test "fuzz: Reader 的任意操作序列不越界（含长格式长度边界）" {
    try std.testing.fuzz({}, testAsn1ReaderInvariants, .{});
}
