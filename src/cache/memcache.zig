//! cache/memcache — 最小 Memcache 缓存实现
//!
//! 对应 `_ref/wechat/cache/memcache.go`：通过 Memcache 文本协议与服务器通信，
//! 提供 `Cache` vtable 兼容的 get / set / isExist / delete / deinit。
//!
//! 设计取舍：
//! - 仅实现单连接（无连接池），满足 access_token / js_ticket 共享缓存场景。
//! - `get` 返回的切片借用自 `Memcache.last_value`，调用方应在下一次缓存操作前使用。
//! - 连接按需建立，遇到网络错误时下次操作自动重连。
//! - 不支持 TLS；如需 TLS，可外部用 stunnel / memcache+tls 代理，或后续扩展。

const std = @import("std");
const Cache = @import("mod.zig").Cache;
const CacheError = @import("mod.zig").CacheError;

/// Memcache 连接选项。
pub const Options = struct {
    /// 服务器地址，格式 `host:port`。
    server: []const u8 = "127.0.0.1:11211",
    /// 外部传入的 `Io` 句柄。未提供时 `Memcache` 会自行创建一个 `std.Io.Threaded`。
    io: ?std.Io = null,
};

/// Memcache 缓存实现。
///
/// 调用方通过 `create(allocator, opts)` 构造，使用 `asCache()` 获得 vtable 句柄，
/// 最终调用 `deinit()` 再 `allocator.destroy(self)` 释放。
pub const Memcache = struct {
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
    /// 读取文本协议响应行时使用的临时缓冲区。
    line_buffer: [1024]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, opts: Options) !*Memcache {
        const self = try allocator.create(Memcache);
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

    pub fn deinit(self: *Memcache) void {
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

    pub fn asCache(self: *Memcache) Cache {
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
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        self.sendCommand("get ", key, null) catch return error.StorageError;
        const item = self.readGetReply() catch return error.StorageError;
        if (item) |it| {
            if (self.last_value) |old| self.allocator.free(old);
            self.last_value = it.value;
            return self.last_value.?;
        }
        return null;
    }

    fn setImpl(ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        const exp: u32 = if (ttl_seconds > 0) @intCast(ttl_seconds) else 0;
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "set {s} 0 {d} {d}\r\n", .{ key, exp, val.len }) catch return error.StorageError;
        self.sendCommandRaw(header, val) catch return error.StorageError;

        const line = self.readLine() catch return error.StorageError;
        if (!std.mem.eql(u8, line, "STORED")) return error.StorageError;
    }

    fn isExistImpl(ctx: *anyopaque, key: []const u8) CacheError!bool {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        self.sendCommand("get ", key, null) catch return error.StorageError;
        const item = self.readGetReply() catch return error.StorageError;
        if (item) |it| {
            self.allocator.free(it.value);
            return true;
        }
        return false;
    }

    fn deleteImpl(ctx: *anyopaque, key: []const u8) CacheError!void {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        self.sendCommand("delete ", key, null) catch return error.StorageError;
        const line = self.readLine() catch return error.StorageError;
        if (!std.mem.eql(u8, line, "DELETED") and !std.mem.eql(u8, line, "NOT_FOUND")) {
            return error.StorageError;
        }
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    // ---------------- 连接管理 ----------------

    fn ensureConnected(self: *Memcache) !void {
        if (self.stream) |_| return;

        const addr = try parseServer(self.opts.server);
        self.stream = addr.connect(self.io, .{ .mode = .stream }) catch |err| {
            std.log.warn("memcache connect failed: {s}", .{@errorName(err)});
            return error.StorageError;
        };
        self.reader = self.stream.?.reader(self.io, &self.read_buffer);
        self.writer = self.stream.?.writer(self.io, &self.write_buffer);
    }

    fn disconnect(self: *Memcache) void {
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
            self.reader = null;
            self.writer = null;
        }
    }

    fn parseServer(server: []const u8) !std.Io.net.IpAddress {
        const colon = std.mem.lastIndexOf(u8, server, ":") orelse return error.InvalidAddress;
        const host = server[0..colon];
        const port = std.fmt.parseInt(u16, server[colon + 1 ..], 10) catch return error.InvalidAddress;
        return .{ .ip4 = .{
            .bytes = try parseIpv4(host),
            .port = port,
        } };
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

    // ---------------- Memcache 文本协议 ----------------

    const Item = struct {
        key: []const u8,
        flags: u32,
        value: []u8,
    };

    fn sendCommand(self: *Memcache, prefix: []const u8, key: []const u8, suffix: ?[]const u8) !void {
        const w = &self.writer.?.interface;
        try w.writeAll(prefix);
        try w.writeAll(key);
        if (suffix) |s| try w.writeAll(s);
        try w.writeAll("\r\n");
        try w.flush();
    }

    fn sendCommandRaw(self: *Memcache, header: []const u8, data: []const u8) !void {
        const w = &self.writer.?.interface;
        try w.writeAll(header);
        try w.writeAll(data);
        try w.writeAll("\r\n");
        try w.flush();
    }

    fn readGetReply(self: *Memcache) !?Item {
        const line = try self.readLine();
        if (std.mem.eql(u8, line, "END")) return null;

        if (!std.mem.startsWith(u8, line, "VALUE ")) return error.StorageError;
        var it = std.mem.splitScalar(u8, line[6..], ' ');
        const key = it.next() orelse return error.StorageError;
        const flags_str = it.next() orelse return error.StorageError;
        const bytes_str = it.next() orelse return error.StorageError;
        const flags = std.fmt.parseInt(u32, flags_str, 10) catch return error.StorageError;
        const bytes = std.fmt.parseInt(usize, bytes_str, 10) catch return error.StorageError;

        const value = try self.allocator.alloc(u8, bytes);
        errdefer self.allocator.free(value);
        try self.reader.?.interface.readSliceAll(value);
        var crlf: [2]u8 = undefined;
        try self.reader.?.interface.readSliceAll(&crlf);
        if (crlf[0] != '\r' or crlf[1] != '\n') return error.StorageError;

        const end_line = try self.readLine();
        if (!std.mem.eql(u8, end_line, "END")) return error.StorageError;

        return .{ .key = key, .flags = flags, .value = value };
    }

    fn readLine(self: *Memcache) ![]const u8 {
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

    fn readByte(self: *Memcache) !u8 {
        const r = &self.reader.?.interface;
        var byte: [1]u8 = undefined;
        try r.readSliceAll(&byte);
        return byte[0];
    }
};

// ============================================================================
// 单元测试：使用本进程 mock Memcache 服务器，避免外部依赖。
// ============================================================================

fn mockMemcacheServer(allocator: std.mem.Allocator, bind_addr: std.Io.net.IpAddress, ready: *std.atomic.Value(bool)) !std.Thread {
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
                const line = mockReadLine(alloc, &reader) catch break;
                defer alloc.free(line);
                if (line.len == 0) continue;

                var it = std.mem.splitScalar(u8, line, ' ');
                const cmd = it.next().?;

                if (std.mem.eql(u8, cmd, "get")) {
                    const key = it.next() orelse continue;
                    if (store.get(key)) |val| {
                        try writer.interface.print("VALUE {s} 0 {d}\r\n", .{ key, val.len });
                        try writer.interface.writeAll(val);
                        try writer.interface.writeAll("\r\n");
                    }
                    _ = writer.interface.writeAll("END\r\n") catch break;
                } else if (std.mem.eql(u8, cmd, "set")) {
                    const key = it.next() orelse continue;
                    _ = it.next(); // flags
                    _ = it.next(); // exptime
                    const bytes_str = it.next() orelse continue;
                    const bytes = std.fmt.parseInt(usize, bytes_str, 10) catch continue;
                    const raw = try alloc.alloc(u8, bytes + 2);
                    defer alloc.free(raw);
                    try reader.interface.readSliceAll(raw);
                    if (raw[bytes] != '\r' or raw[bytes + 1] != '\n') continue;
                    if (store.fetchRemove(key)) |old| {
                        alloc.free(old.key);
                        alloc.free(old.value);
                    }
                    try store.put(try alloc.dupe(u8, key), try alloc.dupe(u8, raw[0..bytes]));
                    _ = writer.interface.writeAll("STORED\r\n") catch break;
                } else if (std.mem.eql(u8, cmd, "delete")) {
                    const key = it.next() orelse continue;
                    if (store.fetchRemove(key)) |old| {
                        alloc.free(old.key);
                        alloc.free(old.value);
                    }
                    const resp = if (store.contains(key)) "NOT_FOUND\r\n" else "DELETED\r\n";
                    _ = writer.interface.writeAll(resp) catch break;
                }
                try writer.interface.flush();
            }
        }
    }.run, .{ allocator, bind_addr, ready });
}

fn mockReadLine(alloc: std.mem.Allocator, reader: *std.Io.net.Stream.Reader) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    while (true) {
        var byte: [1]u8 = undefined;
        try reader.interface.readSliceAll(&byte);
        if (byte[0] == '\r') {
            var lf: [1]u8 = undefined;
            try reader.interface.readSliceAll(&lf);
            if (lf[0] != '\n') return error.InvalidFormat;
            return list.toOwnedSlice(alloc);
        }
        try list.append(alloc, byte[0]);
    }
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

test "memcache 基本 set/get/exists/delete 往返" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockMemcacheServer(allocator, addr, &ready);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.fmt.bufPrint(&server_str_buf, "127.0.0.1:{d}", .{port});

    const mc = try Memcache.create(allocator, .{ .server = server_str });

    const c = mc.asCache();
    try c.set("name", "alice", 60);

    const got = try c.get("name");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("alice", got.?);

    try std.testing.expect(try c.isExist("name"));
    try c.delete("name");
    try std.testing.expect(!(try c.isExist("name")));

    mc.deinit();
    allocator.destroy(mc);
    thread.join();
}

test "memcache get 不存在的 key 返回 null" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockMemcacheServer(allocator, addr, &ready);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.fmt.bufPrint(&server_str_buf, "127.0.0.1:{d}", .{port});

    const mc = try Memcache.create(allocator, .{ .server = server_str });

    const c = mc.asCache();
    const got = try c.get("missing");
    try std.testing.expect(got == null);

    mc.deinit();
    allocator.destroy(mc);
    thread.join();
}

test "memcache 接口公共 API 全部导出" {
    _ = Memcache.create;
    _ = Memcache.deinit;
    _ = Memcache.asCache;
    _ = Options;
}
