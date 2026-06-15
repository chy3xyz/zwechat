//! cache/redis — 最小 Redis 缓存实现
//!
//! 对应 `_ref/wechat/cache/redis.go`：通过 RESP 协议与 Redis 通信，提供
//! `Cache` vtable 兼容的 get / set / isExist / delete / deinit。
//!
//! 设计取舍：
//! - 仅实现单连接（无连接池），满足 access_token / js_ticket 共享缓存场景。
//! - `get` 返回的切片借用自 `Redis.last_value`，调用方应在下一次缓存操作前使用。
//! - 连接按需建立，遇到网络错误时下次操作自动重连。
//! - 不支持 TLS；如需 TLS，可外部用 stunnel / redis+tls 代理，或后续扩展。

const std = @import("std");
const Cache = @import("mod.zig").Cache;
const CacheError = @import("mod.zig").CacheError;

/// Redis 连接选项。
pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    db: i32 = 0,
    /// 外部传入的 `Io` 句柄。未提供时 `Redis` 会自行创建一个 `std.Io.Threaded`。
    io: ?std.Io = null,
};

/// Redis 缓存实现。
///
/// 调用方通过 `create(allocator, opts)` 构造，使用 `asCache()` 获得 vtable 句柄，
/// 最终调用 `deinit()` 再 `allocator.destroy(self)` 释放。
pub const Redis = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    io: std.Io,
    /// 当 `opts.io` 未提供时，本字段持有自行创建的 `Io` 实例。
    owned_io: ?std.Io.Threaded,
    /// 当前 TCP 连接；`null` 表示未连接或已断开。
    stream: ?std.Io.net.Stream = null,
    read_buffer: [4096]u8,
    write_buffer: [4096]u8,
    reader: ?std.Io.net.Stream.Reader = null,
    writer: ?std.Io.net.Stream.Writer = null,
    /// `get` 返回的切片借用自此缓冲区；下一次操作前有效。
    last_value: ?[]u8 = null,
    /// 读取 RESP 简单字符串/整数字行时使用的临时缓冲区。
    line_buffer: [512]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, opts: Options) !*Redis {
        const self = try allocator.create(Redis);
        errdefer allocator.destroy(self);

        var owned_io: ?std.Io.Threaded = null;
        const io = opts.io orelse io: {
            owned_io = std.Io.Threaded.init(allocator, .{});
            break :io owned_io.?.io();
        };

        self.* = .{
            .allocator = allocator,
            .opts = opts,
            .io = io,
            .owned_io = owned_io,
            .stream = null,
            .read_buffer = undefined,
            .write_buffer = undefined,
            .reader = null,
            .writer = null,
            .last_value = null,
        };
        if (self.owned_io) |*t| {
            self.io = t.io();
        }
        return self;
    }

    pub fn deinit(self: *Redis) void {
        self.disconnect();
        if (self.last_value) |v| {
            self.allocator.free(v);
            self.last_value = null;
        }
        if (self.owned_io) |*t| {
            t.deinit();
            self.owned_io = null;
        }
        self.* = undefined;
    }

    pub fn asCache(self: *Redis) Cache {
        return .{
            .ctx = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    // ---------------- vtable 实现 ----------------

    const vtable: Cache.VTable = .{
        .get = getImpl,
        .set = setImpl,
        .isExist = isExistImpl,
        .delete = deleteImpl,
        .deinit = deinitImpl,
    };

    fn getImpl(ctx: *anyopaque, key: []const u8) CacheError!?[]const u8 {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        self.sendCommand(&.{ "GET", key }) catch return error.StorageError;
        const reply = self.readReply() catch return error.StorageError;
        switch (reply) {
            .null_bulk => return null,
            .bulk_string => |bs| {
                if (self.last_value) |old| self.allocator.free(old);
                self.last_value = @constCast(bs);
                return self.last_value.?;
            },
            .error_msg => |e| {
                std.log.warn("redis GET failed: {s}", .{e});
                return error.StorageError;
            },
            else => return error.StorageError,
        }
    }

    fn setImpl(ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        if (ttl_seconds > 0) {
            const ttl_str = std.fmt.allocPrint(self.allocator, "{d}", .{ttl_seconds}) catch return error.OutOfMemory;
            defer self.allocator.free(ttl_str);
            self.sendCommand(&.{ "SETEX", key, ttl_str, val }) catch return error.StorageError;
        } else {
            self.sendCommand(&.{ "SET", key, val }) catch return error.StorageError;
        }

        const reply = self.readReply() catch return error.StorageError;
        switch (reply) {
            .simple_string => |s| if (!std.mem.eql(u8, s, "OK")) return error.StorageError,
            .error_msg => |e| {
                std.log.warn("redis SET failed: {s}", .{e});
                return error.StorageError;
            },
            else => return error.StorageError,
        }
    }

    fn isExistImpl(ctx: *anyopaque, key: []const u8) CacheError!bool {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        self.sendCommand(&.{ "EXISTS", key }) catch return error.StorageError;
        const reply = self.readReply() catch return error.StorageError;
        switch (reply) {
            .integer => |n| return n > 0,
            .error_msg => |e| {
                std.log.warn("redis EXISTS failed: {s}", .{e});
                return error.StorageError;
            },
            else => return error.StorageError,
        }
    }

    fn deleteImpl(ctx: *anyopaque, key: []const u8) CacheError!void {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        self.sendCommand(&.{ "DEL", key }) catch return error.StorageError;
        _ = self.readReply() catch return error.StorageError;
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    // ---------------- 连接管理 ----------------

    fn ensureConnected(self: *Redis) !void {
        if (self.stream) |_| return;

        const addr = std.Io.net.IpAddress{ .ip4 = .{
            .bytes = try parseIpv4(self.opts.host),
            .port = self.opts.port,
        } };
        self.stream = addr.connect(self.io, .{ .mode = .stream }) catch |err| {
            std.log.warn("redis connect failed: {s}", .{@errorName(err)});
            return error.StorageError;
        };
        self.reader = self.stream.?.reader(self.io, &self.read_buffer);
        self.writer = self.stream.?.writer(self.io, &self.write_buffer);
        errdefer self.disconnect();

        if (self.opts.password) |pwd| {
            try self.sendCommand(&.{ "AUTH", pwd });
            const reply = try self.readReply();
            switch (reply) {
                .simple_string => |s| if (!std.mem.eql(u8, s, "OK")) return error.StorageError,
                .error_msg => return error.StorageError,
                else => return error.StorageError,
            }
        }

        if (self.opts.db != 0) {
            const db_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.opts.db});
            defer self.allocator.free(db_str);
            try self.sendCommand(&.{ "SELECT", db_str });
            const reply = try self.readReply();
            switch (reply) {
                .simple_string => |s| if (!std.mem.eql(u8, s, "OK")) return error.StorageError,
                .error_msg => return error.StorageError,
                else => return error.StorageError,
            }
        }
    }

    fn disconnect(self: *Redis) void {
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
            self.reader = null;
            self.writer = null;
        }
    }

    fn parseIpv4(host: []const u8) ![4]u8 {
        var it = std.mem.splitScalar(u8, host, '.');
        var octets: [4]u8 = undefined;
        for (&octets) |*o| {
            const part = it.next() orelse return error.InvalidAddress;
            const n = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
            o.* = n;
        }
        if (it.next() != null) return error.InvalidAddress;
        return octets;
    }

    // ---------------- RESP 协议 ----------------

    const Reply = union(enum) {
        simple_string: []const u8,
        error_msg: []const u8,
        integer: i64,
        bulk_string: []const u8,
        null_bulk: void,
    };

    fn sendCommand(self: *Redis, args: []const []const u8) !void {
        const w = &self.writer.?.interface;
        try w.print("*{d}\r\n", .{args.len});
        for (args) |arg| {
            try w.print("${d}\r\n", .{arg.len});
            try w.writeAll(arg);
            try w.writeAll("\r\n");
        }
        try w.flush();
    }

    fn readReply(self: *Redis) !Reply {
        const kind = try self.readByte();

        switch (kind) {
            '+' => return .{ .simple_string = try self.readLine() },
            '-' => return .{ .error_msg = try self.readLine() },
            ':' => {
                const line = try self.readLine();
                const n = std.fmt.parseInt(i64, line, 10) catch return error.StorageError;
                return .{ .integer = n };
            },
            '$' => {
                const line = try self.readLine();
                const len = std.fmt.parseInt(i64, line, 10) catch return error.StorageError;
                if (len < 0) return .null_bulk;
                const size: usize = @intCast(len);
                const data = try self.allocator.alloc(u8, size);
                errdefer self.allocator.free(data);
                try self.reader.?.interface.readSliceAll(data);
                var trailing: [2]u8 = undefined;
                try self.reader.?.interface.readSliceAll(&trailing);
                if (trailing[0] != '\r' or trailing[1] != '\n') return error.StorageError;
                return .{ .bulk_string = data };
            },
            '*' => {
                _ = try self.readLine();
                return error.StorageError;
            },
            else => return error.StorageError,
        }
    }

    fn readByte(self: *Redis) !u8 {
        const r = &self.reader.?.interface;
        var byte: [1]u8 = undefined;
        try r.readSliceAll(&byte);
        return byte[0];
    }

    fn readLine(self: *Redis) ![]const u8 {
        var i: usize = 0;
        while (true) {
            const b = try self.readByte();
            if (b == '\r') {
                const lf = try self.readByte();
                if (lf != '\n') return error.StorageError;
                return self.line_buffer[0..i];
            }
            if (i >= self.line_buffer.len) return error.StorageError;
            self.line_buffer[i] = b;
            i += 1;
        }
    }
};

// ============================================================================
// 单元测试：使用本进程 mock Redis 服务器，避免外部依赖。
// ============================================================================

fn mockReadByte(reader: *std.Io.net.Stream.Reader) !u8 {
    var byte: [1]u8 = undefined;
    try reader.interface.readSliceAll(&byte);
    return byte[0];
}

fn mockReadLine(alloc: std.mem.Allocator, reader: *std.Io.net.Stream.Reader) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    while (true) {
        const b = try mockReadByte(reader);
        if (b == '\r') {
            const lf = try mockReadByte(reader);
            if (lf != '\n') return error.InvalidFormat;
            return list.toOwnedSlice(alloc);
        }
        try list.append(alloc, b);
    }
}

fn mockReadCommand(alloc: std.mem.Allocator, reader: *std.Io.net.Stream.Reader) !?std.ArrayList([]u8) {
    const kind = mockReadByte(reader) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    if (kind != '*') return error.InvalidFormat;
    const line = try mockReadLine(alloc, reader);
    defer alloc.free(line);
    const argc = std.fmt.parseInt(usize, line, 10) catch return error.InvalidFormat;
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }
    for (0..argc) |_| {
        const arg_kind = try mockReadByte(reader);
        if (arg_kind != '$') return error.InvalidFormat;
        const len_line = try mockReadLine(alloc, reader);
        defer alloc.free(len_line);
        const arg_len = std.fmt.parseInt(usize, len_line, 10) catch return error.InvalidFormat;
        const raw = try alloc.alloc(u8, arg_len + 2);
        defer alloc.free(raw);
        try reader.interface.readSliceAll(raw);
        if (raw[arg_len] != '\r' or raw[arg_len + 1] != '\n') return error.InvalidFormat;
        const owned = try alloc.dupe(u8, raw[0..arg_len]);
        try args.append(alloc, owned);
    }
    return args;
}

fn mockRedisServer(allocator: std.mem.Allocator, bind_addr: std.Io.net.IpAddress, ready: *std.atomic.Value(bool)) !std.Thread {
    return try std.Thread.spawn(.{}, struct {
        fn run(alloc: std.mem.Allocator, addr: std.Io.net.IpAddress, rdy: *std.atomic.Value(bool)) !void {
            var threaded = std.Io.Threaded.init(alloc, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var server = try addr.listen(io, .{ .reuse_address = true });
            rdy.store(true, .release);
            defer server.deinit(io);

            const conn = try server.accept(io);
            defer conn.close(io);

            var store: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80) = .init(alloc);
            defer {
                var it = store.iterator();
                while (it.next()) |entry| {
                    alloc.free(entry.key_ptr.*);
                    alloc.free(entry.value_ptr.*);
                }
                store.deinit();
            }

            var read_buf: [1024]u8 = undefined;
            var write_buf: [1024]u8 = undefined;
            var reader = conn.reader(io, &read_buf);
            var writer = conn.writer(io, &write_buf);

            while (true) {
                const args = mockReadCommand(alloc, &reader) catch break;
                var args_list = args orelse break;
                defer {
                    for (args_list.items) |a| alloc.free(a);
                    args_list.deinit(alloc);
                }
                if (args_list.items.len == 0) continue;
                const cmd = args_list.items[0];

                if (std.mem.eql(u8, cmd, "PING")) {
                    _ = writer.interface.writeAll("+PONG\r\n") catch break;
                } else if (std.mem.eql(u8, cmd, "GET")) {
                    const key = args_list.items[1];
                    if (store.get(key)) |val| {
                        try writer.interface.print("${d}\r\n{s}\r\n", .{ val.len, val });
                    } else {
                        _ = writer.interface.writeAll("$-1\r\n") catch break;
                    }
                } else if (std.mem.eql(u8, cmd, "SET")) {
                    const key = args_list.items[1];
                    const val = args_list.items[2];
                    if (store.fetchRemove(key)) |old| {
                        alloc.free(old.key);
                        alloc.free(old.value);
                    }
                    try store.put(try alloc.dupe(u8, key), try alloc.dupe(u8, val));
                    _ = writer.interface.writeAll("+OK\r\n") catch break;
                } else if (std.mem.eql(u8, cmd, "SETEX")) {
                    const key = args_list.items[1];
                    const val = args_list.items[3];
                    if (store.fetchRemove(key)) |old| {
                        alloc.free(old.key);
                        alloc.free(old.value);
                    }
                    try store.put(try alloc.dupe(u8, key), try alloc.dupe(u8, val));
                    _ = writer.interface.writeAll("+OK\r\n") catch break;
                } else if (std.mem.eql(u8, cmd, "EXISTS")) {
                    const key = args_list.items[1];
                    if (store.contains(key)) {
                        _ = writer.interface.writeAll(":1\r\n") catch break;
                    } else {
                        _ = writer.interface.writeAll(":0\r\n") catch break;
                    }
                } else if (std.mem.eql(u8, cmd, "DEL")) {
                    const key = args_list.items[1];
                    if (store.fetchRemove(key)) |old| {
                        alloc.free(old.key);
                        alloc.free(old.value);
                    }
                    _ = writer.interface.writeAll(":1\r\n") catch break;
                } else if (std.mem.eql(u8, cmd, "AUTH")) {
                    _ = writer.interface.writeAll("+OK\r\n") catch break;
                } else if (std.mem.eql(u8, cmd, "SELECT")) {
                    _ = writer.interface.writeAll("+OK\r\n") catch break;
                }
                try writer.interface.flush();
            }
        }
    }.run, .{ allocator, bind_addr, ready });
}

fn findFreePort() !u16 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var rng: std.Random.DefaultPrng = .init(@intCast(std.Io.Clock.now(.real, std.Options.debug_io).nanoseconds));
    for (0..20) |_| {
        const port: u16 = @intCast(20000 + rng.random().int(u16) % 45000);
        const addr = std.Io.net.IpAddress{ .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = port,
        } };
        if (addr.listen(io, .{ .reuse_address = true })) |server| {
            var s = server;
            s.deinit(io);
            return port;
        } else |err| {
            if (err != error.AddressInUse) return err;
        }
    }
    return error.AddressInUse;
}

test "redis 基本 set/get/exists/delete 往返" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockRedisServer(allocator, addr, &ready);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
    });

    const c = redis.asCache();
    try c.set("name", "alice", 60);

    const got = try c.get("name");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("alice", got.?);

    try std.testing.expect(try c.isExist("name"));
    try c.delete("name");
    try std.testing.expect(!(try c.isExist("name")));

    redis.deinit();
    allocator.destroy(redis);
    thread.join();
}

test "redis get 不存在的 key 返回 null" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockRedisServer(allocator, addr, &ready);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
    });

    const c = redis.asCache();
    const got = try c.get("missing");
    try std.testing.expect(got == null);

    redis.deinit();
    allocator.destroy(redis);
    thread.join();
}

test "redis 接口公共 API 全部导出" {
    _ = Redis.create;
    _ = Redis.deinit;
    _ = Redis.asCache;
    _ = Options;
}
