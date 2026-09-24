// SPDX-License-Identifier: Apache-2.0
//! cache/memcache — 最小 Memcache 缓存实现
//!
//! 对应 `_ref/wechat/cache/memcache.go`：通过 Memcache 文本协议与服务器通信，
//! 提供 `Cache` vtable 兼容的 get / set / isExist / delete / deinit。
//!
//! 设计取舍：
//! - 仅实现单连接（无连接池），满足 access_token / js_ticket 共享缓存场景。
//!   单连接由 `std.Io.Mutex`（真阻塞的 futex 锁）串行化整个请求-响应往返，
//!   多线程并发安全；等待者阻塞在内核 futex 上，不再空转烧 CPU。
//! - `get` 返回的切片借用自 `Memcache.last_value`，调用方应在下一次缓存操作前使用。
//! - 连接按需建立，遇到网络错误时下次操作自动重连。
//! - **可选读超时**（`Options.recv_timeout_ms`，默认 `0` = 不超时）：配置后每次
//!   socket 读取都受 deadline 约束，服务端 accept 后不回包也不会把共享的那条
//!   连接（以及等它的线程）永久占死；超时按读失败处理 —— 断开连接、下次操作重连。
//! - **可选建连超时**（`Options.connect_timeout_ms`，默认 `0` = 不超时）：配置后
//!   **TCP 握手本身**也受 deadline 约束 —— 对端 SYN 被静默丢弃（黑洞 / 防火墙
//!   DROP / 对端过载）时不再卡到内核上限（Linux 默认 ≈ 127s、macOS ≈ 75s）。
//!   这条尤其重要：本实现**持锁跨网络 I/O**（共享单连接），建连卡住等于所有
//!   线程一起卡住。超时后连接状态保持干净（`stream` / `reader` / `timeout_reader`
//!   / `writer` 全为 null），下一次操作重新建连。
//! - 服务器地址支持 IPv4 / `[IPv6]` 字面量与域名（std 的 `IpAddress` 与
//!   `HostName.lookup`），不再只认 IPv4。
//! - 网络层与 `redis.zig` 共用：读超时读取器与主机解析实现在 `net.zig`（设计
//!   说明也只有一处）；日志统一走本文件的 `std.log.scoped(.zwechat_memcache)`，
//!   宿主可用 `std_options.log_scope_levels` 单独静音 memcache 的告警。
//! - 不支持 TLS；如需 TLS，可外部用 stunnel / memcache+tls 代理，或后续扩展。

const std = @import("std");
const default_io = @import("../util/default_io.zig");
const posix = std.posix;
const Cache = @import("mod.zig").Cache;
const CacheError = @import("mod.zig").CacheError;
/// 与 `redis.zig` 共享的网络层（带读超时的 socket 读取器 + 主机解析）。
const net = @import("net.zig");

/// 本文件的日志 scope：宿主可用 `std_options.log_scope_levels` 单独静音 memcache
/// 的告警，而不必整体降低 `log.level`（redis / mtls 同理，各用自己的 scope）。
const log = std.log.scoped(.zwechat_memcache);

/// 建连超时路径只在 POSIX 上实现（Windows / WASI 退化为阻塞 connect）。
const native_os = @import("builtin").os.tag;

/// Memcache 连接选项。
pub const Options = struct {
    /// 服务器地址，格式 `host:port`。
    ///
    /// `host` 可以是 IPv4 字面量（`127.0.0.1`）、带方括号的 IPv6 字面量
    /// （`[::1]`，RFC 3986 IP literal 写法）或域名（`memcache.internal`）。
    /// 端口必填。
    server: []const u8 = "127.0.0.1:11211",
    /// 外部传入的 `Io` 句柄。未提供时 `Memcache` 会自行创建一个 `std.Io.Threaded`。
    io: ?std.Io = null,
    /// 单次 socket 读取的超时（毫秒），默认 `0` = 不超时（保持历史行为）。
    ///
    /// - `0`（默认）沿用阻塞读；
    /// - `> 0` 时每次读取都套一个不超过本时长的 deadline（`Io.operateTimeout`，
    ///   语义等价 `SO_RCVTIMEO`）。服务端 accept 之后不回包时，调用在
    ///   `recv_timeout_ms` 内以 `error.StorageError` 返回，而不是永久阻塞；
    /// - 读失败（含超时）一律断开连接（`self.stream = null`），下一次操作重连：
    ///   半条回复留在连接上会让后续请求协议失步；
    /// - 只约束「单次读取」，不约束一次请求的总时长，**也不约束建连**
    ///   （建连看 `connect_timeout_ms`）。
    recv_timeout_ms: u64 = 0,

    /// 建连（TCP 三次握手）的超时（毫秒），默认 `0` = 不超时（保持历史行为）。
    ///
    /// **与 `recv_timeout_ms` 的分工**：
    /// - 本项管「连上之前」：对端 SYN 被丢弃（黑洞 / 防火墙 DROP / 对端过载）时，
    ///   阻塞 connect 会一直卡到内核上限（Linux 默认 ≈ 127s、macOS ≈ 75s）。
    ///   本实现持锁跨整次往返，所以建连卡住 = 所有调用方一起卡住；
    /// - `recv_timeout_ms` 管「连上之后」的每一次 socket 读取，**不覆盖建连**；
    /// - 两者独立：只配 `recv_timeout_ms` 时连不上的对端仍会卡住。
    ///
    /// 语义与取舍：
    /// - `0`（默认）沿用阻塞 connect：零额外系统调用，行为与历史版本一致；
    /// - `> 0` 时用「非阻塞 connect + `poll(deadline)`」把建连卡在期限内，
    ///   到点以 `error.StorageError` 返回（`error.ConnectTimeout` 在 vtable 边界映射）；
    /// - 超时的 socket **立即关闭**：`stream` / `reader` / `timeout_reader` / `writer`
    ///   一律保持 null，下一次操作重新建连，状态绝不残留；
    /// - POSIX（Linux / macOS / BSD）上真实生效；**Windows / WASI 退化为阻塞
    ///   connect**（选项仍可配置，但不生效）。
    connect_timeout_ms: u64 = 0,
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
    /// 默认（`recv_timeout_ms == 0`）路径的读取器：直接用 std 的实现。
    reader: ?std.Io.net.Stream.Reader = null,
    /// 配置了 `recv_timeout_ms` 时改用它（同一 socket、同一 `read_buffer`，
    /// 读取走 `Io.operateTimeout`；共享实现见 `net.zig`）。与 `reader` **二选一**，
    /// 同一时刻最多一个非 null，避免两个读取器各自缓冲同一 socket 的数据。
    timeout_reader: ?net.SocketReader(.memcache) = null,
    writer: ?std.Io.net.Stream.Writer = null,
    /// `get` 返回的切片借用自此缓冲区；下一次操作前有效。
    last_value: ?[]u8 = null,
    /// 读取文本协议响应行时使用的临时缓冲区。
    line_buffer: [1024]u8 = undefined,
    /// 单连接互斥：共享 TCP 连接 + 共享 reader/writer/缓冲区，
    /// 必须串行化整个请求-响应往返，否则多线程并发会交错写 socket（协议损坏）。
    ///
    /// **刻意持锁跨网络 I/O**（含 `ensureConnected` + 写 socket + 读完整个回复，
    /// 一整个 RTT）：共享单连接的文本协议无法把一次往返拆成多段临界区。
    /// 这里用真阻塞的 `std.Io.Mutex`，等待者在 futex 上睡眠而不是自旋，
    /// 锁被占满一个 RTT 时不再浪费 CPU（`self.io` 驱动等待 / 唤醒）。
    mutex: std.Io.Mutex = .init,

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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        // exptime 是 u32；ttl_seconds 来自外部输入（如微信响应的 expires_in），
        // 超过 u32 上限（如 i64 max）时 @intCast 会在 Debug 下 panic，这里钳制到上限。
        const exp: u32 = if (ttl_seconds > 0)
            @intCast(@min(ttl_seconds, std.math.maxInt(u32)))
        else
            0;
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "set {s} 0 {d} {d}\r\n", .{ key, exp, val.len }) catch return error.StorageError;
        self.sendCommandRaw(header, val) catch return error.StorageError;

        const line = self.readLine() catch return error.StorageError;
        if (!std.mem.eql(u8, line, "STORED")) return error.StorageError;
    }

    fn isExistImpl(ctx: *anyopaque, key: []const u8) CacheError!bool {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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

        const addr = try resolveServer(self.io, self.opts.server);
        const stream = connectStream(self.io, addr, self.opts.connect_timeout_ms) catch |err| switch (err) {
            error.ConnectTimeout => {
                log.warn(
                    "memcache 建连超时（connect_timeout_ms={d}）：放弃本次操作，连接状态保持干净",
                    .{self.opts.connect_timeout_ms},
                );
                // 走失败路径返回：`self.stream` / `reader` / `timeout_reader` / `writer`
                // 一个都没被赋值，状态与「从未建连」完全一致。
                return error.StorageError;
            },
            else => {
                log.warn("memcache connect failed: {s}", .{@errorName(err)});
                return error.StorageError;
            },
        };
        self.stream = stream;
        if (self.opts.recv_timeout_ms > 0) {
            self.timeout_reader = net.SocketReader(.memcache).init(self.io, stream, &self.read_buffer, self.opts.recv_timeout_ms);
            self.reader = null;
        } else {
            self.reader = stream.reader(self.io, &self.read_buffer);
            self.timeout_reader = null;
        }
        self.writer = stream.writer(self.io, &self.write_buffer);
    }

    fn disconnect(self: *Memcache) void {
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
            self.reader = null;
            self.timeout_reader = null;
            self.writer = null;
        }
    }

    /// 当前生效的读取器接口（无超时 / 有超时两条路径二选一）。
    fn input(self: *Memcache) *std.Io.Reader {
        if (self.timeout_reader) |*r| return &r.interface;
        return &self.reader.?.interface;
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
        const r = self.input();
        r.readSliceAll(value) catch return error.StorageError;
        var crlf: [2]u8 = undefined;
        r.readSliceAll(&crlf) catch return error.StorageError;
        if (crlf[0] != '\r' or crlf[1] != '\n') return error.StorageError;

        const end_line = try self.readLine();
        if (!std.mem.eql(u8, end_line, "END")) return error.StorageError;

        return .{ .key = key, .flags = flags, .value = value };
    }

    /// 读一行（不含 `\r\n`），结果拷进 `line_buffer`。
    ///
    /// 用 `takeDelimiterExclusive('\r')` 一次取到分隔符（std 内部按缓冲区扫描，
    /// 不再逐字节一次 `readSliceAll`），再消费分隔符并确认 `\n`。
    /// 长度上限仍是 `line_buffer.len`（超限返回 `error.StorageError`）。
    ///
    /// 返回的切片借用自 `line_buffer`：下一次 readLine 之前有效 —— `Item.key`
    /// 能在读完 value 之后继续用，靠的正是这次拷贝。
    fn readLine(self: *Memcache) ![]const u8 {
        const r = self.input();
        const line = r.takeDelimiterExclusive('\r') catch return error.StorageError;
        if (line.len > self.line_buffer.len) return error.StorageError;
        // `Exclusive` 版把 seek 停在分隔符上，分隔符本身还得自己消费；
        // 顺带保持原来的严格性：不是 CRLF 结尾的帧一律拒绝。
        if ((r.takeByte() catch return error.StorageError) != '\r') return error.StorageError;
        if ((r.takeByte() catch return error.StorageError) != '\n') return error.StorageError;
        @memcpy(self.line_buffer[0..line.len], line);
        return self.line_buffer[0..line.len];
    }
};

/// 解析 `Options.server`（`host:port`）为可连接的地址。
///
/// - IPv4 / 带方括号的 IPv6 字面量走 `std.Io.net.IpAddress.parseLiteral`
///   （RFC 3986 的 IP literal 语法，`[::1]:11211` 一次解析出地址与端口）；
/// - 其余按域名走 `net.resolveHost`（DNS / `/etc/hosts` / `localhost`；实现与
///   设计说明都在 `net.zig`，与 `redis.zig` 共用一份）；
/// - 端口必填：`parseLiteral` 对缺端口的字面量给出 0，这里直接判为配置错误
///   （与改动前「没有冒号即非法」的行为一致）。
fn resolveServer(io: std.Io, server: []const u8) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parseLiteral(server)) |addr| {
        if (addr.getPort() == 0) return error.InvalidAddress;
        return addr;
    } else |_| {}

    // 域名不含 ':'，所以最后一段冒号必定是端口分隔符。
    const colon = std.mem.lastIndexOfScalar(u8, server, ':') orelse return error.InvalidAddress;
    const port = std.fmt.parseInt(u16, server[colon + 1 ..], 10) catch return error.InvalidAddress;
    return net.resolveHost(io, server[0..colon], port);
}

// 主机名/字面量解析已收敛到 `net.resolveHost`（`net.zig`），
// 与 `redis.zig` 共用一份实现与一处设计说明。

// ============================================================================
// 建连（含可选超时）
// ============================================================================

/// 建连失败的错误集（`connectStream` 及其超时路径共用）。
///
/// 与 `redis.zig` 里的同名声明仍是两份：建连路径（`ConnectError` /
/// `connectStream` 及其 POSIX 实现）本轮未并入 `net.zig`，两个后端的版本行为
/// 一致、各自独立演进。`SocketReader` 与主机解析已收敛到 `net.zig`。
const ConnectError = error{
    /// 到点仍未建连（我们自己设的 deadline，来自 `Options.connect_timeout_ms`）。
    ConnectTimeout,
    ConnectionRefused,
    HostUnreachable,
    NetworkUnreachable,
    NetworkDown,
    AddressUnavailable,
    AccessDenied,
    /// 其它建连失败（含 socket / `fcntl` / `poll` / `getsockopt` 失败）。
    ConnectFailed,
};

/// `O_NONBLOCK` 的原始标志位。
///
/// `posix.O` 在各平台都是 packed struct（darwin 的 `NONBLOCK` 是 `bool` 字段，
/// 不是常量位），逐平台写死 `0x4` / `0x800` 早晚出错 —— 让编译器自己算。
const o_nonblock: u32 = blk: {
    var o: posix.O = @bitCast(@as(u32, 0));
    o.NONBLOCK = true;
    break :blk @bitCast(o);
};

/// 建连：`timeout_ms == 0`（默认）走 std 的阻塞 connect，行为与历史版本一致。
///
/// **为什么建连超时要自己实现**（本工具链实测结论，`0.17.0-dev.2151+2ec5523d5`）：
/// - `std.Io.net.IpAddress.ConnectOptions` 确实有 `timeout` 字段
///   （`std/Io/net.zig:341`），但 `Threaded` 后端直接
///   `if (options.timeout != .none) @panic("TODO implement netConnectIpPosix with timeout")`
///   （`std/Io/Threaded.zig:12358`，Windows 版 `:12377` 同样 panic，
///   `std/Io/Kqueue.zig:1035` 也是 `@panic("TODO")`）—— 传 timeout 就是让进程崩；
/// - `std.Io.Operation` 里**没有** `net_connect` 这个 tag（只有 `net_receive` /
///   `net_send` / `net_read` / `net_write` / `file_*`），所以
///   `io.operateTimeout(.{ .net_connect = ... }, t)` 根本无法构造。
///
/// 于是退到 POSIX 自带的能力：socket 仍由 `Io` 后端建（CLOEXEC、SOCK_STREAM 与协议
/// 的跨平台差异交给 std），随后 `O_NONBLOCK` → `connect` 立刻返回 `EINPROGRESS`
/// → `poll(POLLOUT, deadline)` → 读 `SO_ERROR` 判成败 → 恢复原阻塞标志位。
/// 失败与超时路径都由 `errdefer` 关掉这条 socket，`ensureConnected` 的失败路径
/// 因此不会留下任何半成品状态。
fn connectStream(io: std.Io, addr: std.Io.net.IpAddress, timeout_ms: u64) ConnectError!std.Io.net.Stream {
    if (timeout_ms == 0) return blockingConnect(io, addr);
    return if (comptime native_os == .windows or native_os == .wasi)
        // 没有可用的 POSIX poll 路径：退化为阻塞 connect（`Options.connect_timeout_ms`
        // 在这两个平台不生效，Options 文档里已写明）。
        blockingConnect(io, addr)
    else
        connectDeadline(io, addr, timeout_ms);
}

/// std 的阻塞 connect（历史路径），把它的错误集折叠进本文件的错误集，
/// 便于调用点统一打日志。
fn blockingConnect(io: std.Io, addr: std.Io.net.IpAddress) ConnectError!std.Io.net.Stream {
    return addr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.ConnectionRefused => error.ConnectionRefused,
        error.HostUnreachable => error.HostUnreachable,
        error.NetworkUnreachable => error.NetworkUnreachable,
        error.NetworkDown => error.NetworkDown,
        error.AddressUnavailable => error.AddressUnavailable,
        error.AccessDenied => error.AccessDenied,
        // 内核自己判超时才返回这个（极少见）；对调用方来说与我们的 deadline 同义。
        error.Timeout => error.ConnectTimeout,
        else => error.ConnectFailed,
    };
}

/// 带 deadline 的建连（POSIX）：见 `connectStream` 的说明。
fn connectDeadline(io: std.Io, addr: std.Io.net.IpAddress, timeout_ms: u64) ConnectError!std.Io.net.Stream {
    // 先建一条「同族、端口 0」的本地 socket：不 bind 到具体地址，只是借 `Io`
    // 后端拿到一条合法的 SOCK_STREAM fd（含 CLOEXEC 等平台细节）。
    const local: std.Io.net.IpAddress = switch (addr) {
        .ip4 => .{ .ip4 = .{ .bytes = @splat(0), .port = 0 } },
        .ip6 => .{ .ip6 = .{ .bytes = @splat(0), .port = 0 } },
    };
    const sock = local.bind(io, .{ .mode = .stream }) catch return error.ConnectFailed;
    const stream = std.Io.net.Stream{ .socket = sock };
    errdefer stream.close(io);

    const fd = sock.handle;
    const saved_flags = fcntlGetFlags(fd) catch return error.ConnectFailed;
    sysFcntl(fd, posix.F.SETFL, saved_flags | o_nonblock) catch return error.ConnectFailed;
    // 无论成败都要恢复原来的阻塞标志位：连接交回 `ensureConnected` 后必须还是
    // 「阻塞读」语义（读超时另有 `recv_timeout_ms` 管）。
    defer sysFcntl(fd, posix.F.SETFL, saved_flags) catch {};

    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage);
    switch (posix.errno(posix.system.connect(fd, &storage.any, addr_len))) {
        // 非阻塞 socket 上 connect 一般返回 EINPROGRESS；回环等本地场景可能一步到位。
        .SUCCESS => {},
        .INPROGRESS, .AGAIN => {
            var fds = [1]posix.pollfd{.{
                .fd = fd,
                .events = @intCast(posix.POLL.OUT),
                .revents = 0,
            }};
            const deadline_ms: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
            const ready = posix.poll(&fds, deadline_ms) catch return error.ConnectFailed;
            if (ready == 0) return error.ConnectTimeout;
            // poll 说「可写」只代表结果已到：非阻塞 connect 的失败是异步的，
            // 真正的 errno 只在 `SO_ERROR` 里。
            const so_error = getSockError(fd) catch return error.ConnectFailed;
            if (so_error != 0) return connectErrno(@fromBackingInt(@intCast(so_error)));
        },
        else => |e| return connectErrno(e),
    }
    // `Socket.address` 的契约是**本地**地址（std 的 connect 实现也是握手后
    // getsockname 得到的），刚建出来的还是 0.0.0.0:0，这里回填一下；
    // 取不到就退回 `local`（只影响诊断信息，不该因此判建连失败）。
    const bound = std.Io.net.Socket{ .handle = fd, .address = localAddress(fd) orelse local };
    return std.Io.net.Stream{ .socket = bound };
}

/// 读端口的本地地址（`getsockname`）；失败返回 `null`（调用方自行兜底）。
fn localAddress(fd: posix.fd_t) ?std.Io.net.IpAddress {
    var storage: std.Io.Threaded.PosixAddress = undefined;
    var len: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    if (posix.errno(posix.system.getsockname(fd, &storage.any, &len)) != .SUCCESS) return null;
    return std.Io.Threaded.addressFromPosix(&storage);
}

/// 读 `SO_ERROR`（非阻塞 connect 的真实结果）；无错误返回 0。
fn getSockError(fd: posix.fd_t) error{SockOptFailed}!u16 {
    var so_error: i32 = 0;
    var opt_len: posix.socklen_t = @sizeOf(i32);
    // `optval` 的形参类型在 ABI 间不同：libc 是 `?*anyopaque`，Linux 裸系统调用是
    // `[*]u8`。按实际签名分支，别用 `link_libc` 猜。
    const rc = if (@typeInfo(@TypeOf(posix.system.getsockopt)).@"fn".param_types[3].? == [*]u8)
        posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&so_error), &opt_len)
    else
        posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @as(?*anyopaque, @ptrCast(&so_error)), &opt_len);
    if (posix.errno(rc) != .SUCCESS) return error.SockOptFailed;
    if (opt_len != @sizeOf(i32) or so_error <= 0) return 0;
    return @intCast(so_error);
}

/// 读文件的打开标志位（`F_GETFL`）。
fn fcntlGetFlags(fd: posix.fd_t) error{FcntlFailed}!u32 {
    const rc = sysFcntlCall(fd, posix.F.GETFL, 0);
    if (posix.errno(rc) != .SUCCESS) return error.FcntlFailed;
    return @intCast(rc);
}

/// 设置文件的打开标志位（`F_SETFL`）。
fn sysFcntl(fd: posix.fd_t, cmd: i32, arg: u32) error{FcntlFailed}!void {
    if (posix.errno(sysFcntlCall(fd, cmd, arg)) != .SUCCESS) return error.FcntlFailed;
}

/// 跨 ABI 的裸 `fcntl` 调用：libc 版是变参（第三参数按 C 规则传 `c_uint`），
/// Linux 裸系统调用版是 `(i32, i32, usize)`。按实际签名分支。
fn sysFcntlCall(fd: posix.fd_t, cmd: i32, arg: u32) @typeInfo(@TypeOf(posix.system.fcntl)).@"fn".return_type.? {
    const info = @typeInfo(@TypeOf(posix.system.fcntl)).@"fn";
    return if (info.param_types.len >= 3)
        posix.system.fcntl(fd, cmd, @as(info.param_types[2].?, @intCast(arg)))
    else
        posix.system.fcntl(fd, cmd, @as(c_uint, arg));
}

/// 把 `connect` / `SO_ERROR` 报出的 errno 映射进本文件的错误集。
fn connectErrno(e: posix.E) ConnectError {
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .ACCES => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        .TIMEDOUT => error.ConnectTimeout,
        else => error.ConnectFailed,
    };
}

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
            try serveMemcacheConn(alloc, io, conn);
        }
    }.run, .{ allocator, bind_addr, ready });
}

/// 按文本协议服务一条连接，直到对端断开（或读到非法帧）。
fn serveMemcacheConn(alloc: std.mem.Allocator, io: std.Io, conn: std.Io.net.Stream) !void {
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
            // 语义修正：删除成功返回 DELETED，键不存在返回 NOT_FOUND。
            // （旧实现先 fetchRemove 再反查 contains，导致永远返回 DELETED。）
            const resp = if (store.fetchRemove(key)) |old| blk: {
                alloc.free(old.key);
                alloc.free(old.value);
                break :blk "DELETED\r\n";
            } else "NOT_FOUND\r\n";
            _ = writer.interface.writeAll(resp) catch break;
        }
        try writer.interface.flush();
    }
}

/// 读超时用例专用 mock 服务器：第 1 条连接收下命令后**永不回包**（模拟服务端
/// 半死），第 2 条连接正常服务。
///
/// 每条连接独立一个服务线程（单线程 accept 会让第 1 条连接的卡死顺带堵住
/// 第 2 条连接的 accept —— 那样测出来的就不是客户端读超时了）。
///
/// `stop` 置位或超过 `silent_hold_ms` 都会让第 1 条连接断开 —— 这是兜底，
/// 即使客户端读超时失效，用例也只会「断言失败」而不会把测试套件挂死。
fn mockSilentThenHealthyServer(
    allocator: std.mem.Allocator,
    bind_addr: std.Io.net.IpAddress,
    ready: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),
    silent_hold_ms: u64,
) !std.Thread {
    return try std.Thread.spawn(.{}, struct {
        fn run(
            alloc: std.mem.Allocator,
            addr: std.Io.net.IpAddress,
            rdy: *std.atomic.Value(bool),
            stopper: *std.atomic.Value(bool),
            hold_ms: u64,
        ) !void {
            var threaded = std.Io.Threaded.init(alloc, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var server = try addr.listen(io, .{ .reuse_address = true });
            rdy.store(true, .release);
            defer server.deinit(io);

            var handlers: std.ArrayListUnmanaged(std.Thread) = .empty;
            defer handlers.deinit(alloc);

            var index: usize = 0;
            while (!stopper.load(.acquire)) {
                const conn = server.accept(io) catch break;
                if (stopper.load(.acquire)) {
                    conn.close(io);
                    break;
                }
                index += 1;
                const t = std.Thread.spawn(.{}, handleConn, .{ alloc, io, conn, index, hold_ms, stopper }) catch {
                    conn.close(io);
                    continue;
                };
                try handlers.append(alloc, t);
            }
            for (handlers.items) |t| t.join();
        }

        fn handleConn(
            alloc: std.mem.Allocator,
            io: std.Io,
            conn: std.Io.net.Stream,
            index: usize,
            hold_ms: u64,
            stopper: *std.atomic.Value(bool),
        ) void {
            defer conn.close(io);

            if (index == 1) {
                // 收下第一条命令（客户端此刻已经在等回复），然后装作卡死。
                var read_buf: [1024]u8 = undefined;
                var reader = conn.reader(io, &read_buf);
                const line = mockReadLine(alloc, &reader) catch null;
                if (line) |l| alloc.free(l);
                var waited_ms: u64 = 0;
                while (waited_ms < hold_ms and !stopper.load(.acquire)) : (waited_ms += 20) {
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
                }
                return;
            }
            serveMemcacheConn(alloc, io, conn) catch {};
        }
    }.run, .{ allocator, bind_addr, ready, stop, silent_hold_ms });
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
    const io = default_io.io();
    var rng: std.Random.DefaultPrng = .init(@intCast(std.Io.Clock.now(.real, default_io.io()).nanoseconds));
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

/// 有界等待 mock 服务器就绪（最多 2 秒，避免服务器起不来时测试无限挂住）。
///
/// 与 `redis.zig` 里的同名函数仍是两份（纯测试夹具，暂不共享）。
fn waitReady(ready: *std.atomic.Value(bool)) void {
    var i: usize = 0;
    while (!ready.load(.acquire)) : (i += 1) {
        if (i > 400) return;
        std.Io.sleep(default_io.io(), std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
}

/// 建连超时用例的「黑洞」目标：一个 `listen(kernel_backlog = 1)` 且**永不 accept**
/// 的本地 socket，外加几条已经把 accept 队列填满的填充连接。
///
/// 队列满之后内核对新来的 SYN 直接丢弃（Linux / macOS 默认都是
/// `tcp_abort_on_overflow = 0`），客户端 connect 于是停在 SYN-SENT：既不成功也不被
/// 拒绝 —— 正是验证「客户端自己的建连 deadline」所需要的环境，而且完全在本进程内，
/// 不依赖任何外部网络。
///
/// 为什么不用 TEST-NET-1（`192.0.2.1` 这类保留地址）：实测本机与 OrbStack 的 Linux
/// 容器里对它的 connect 都能在 0~8ms 内「成功」（本地代理 / NAT 应答），它既不是
/// 黑洞也不确定，写进用例只会是假绿或假红。
///
/// 与 `redis.zig` 里的同名结构仍是两份（纯测试夹具，暂不共享）。
const StalledTarget = struct {
    /// 填充连接各自的 deadline（毫秒）。只要远小于内核的 SYN 重传上限即可。
    const fill_timeout_ms: u64 = 150;
    /// 填充次数上限：accept 队列容量 = backlog+1（Linux）/ backlog（macOS），
    /// 4 次足够填满；4 次都没出现超时说明 backlog 没按预期生效，用例宁可跳过。
    const max_fills = 4;

    addr: std.Io.net.IpAddress,
    server: std.Io.net.Server,
    listening: bool = true,
    /// 已进 accept 队列的填充连接（对端永不 accept）。用例收尾必须 close。
    fills: [max_fills]?std.Io.net.Stream = @splat(null),

    /// 关掉 listener 腾出端口（幂等）：用例后面要在同一端口上起假 server，
    /// 用「同一个实例连同一个地址」证明超时之后一切照常。
    fn closeListener(self: *StalledTarget, io: std.Io) void {
        if (self.listening) {
            self.server.deinit(io);
            self.listening = false;
        }
    }

    fn deinit(self: *StalledTarget, io: std.Io) void {
        self.closeListener(io);
        for (&self.fills) |*slot| {
            if (slot.*) |s| {
                s.close(io);
                slot.* = null;
            }
        }
    }
};

/// 造一个「SYN 被丢弃」的本地目标。返回 `null` 表示本环境造不出来
/// （内核在队列满时直接 RST），调用方应跳过用例而不是让用例变红。
fn makeStalledTarget(io: std.Io, port: u16) !?StalledTarget {
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
    var target = StalledTarget{
        .addr = addr,
        // 只 listen、**永不 accept**：进来的连接会堆在内核的 accept 队列里。
        .server = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 1 }),
    };
    errdefer target.deinit(io);

    for (&target.fills) |*slot| {
        const stream = connectStream(io, addr, StalledTarget.fill_timeout_ms) catch |err| switch (err) {
            // 队列已满 → 内核开始丢 SYN → 黑洞就绪。
            error.ConnectTimeout => return target,
            // 队列满时内核直接 RST（`tcp_abort_on_overflow = 1` 之类）：造不出确定性
            // 黑洞，交给调用方跳过。
            error.ConnectionRefused => {
                target.deinit(io);
                return null;
            },
            // 其它错误如实上抛：不要用 skip 掩盖真实问题（例如本地回环不可用）。
            else => return err,
        };
        slot.* = stream;
    }
    // 填满 max_fills 条都没超时：不猜原因，交给跳过。
    target.deinit(io);
    return null;
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
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
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
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
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

test "memcache set 超大 TTL 不触发 @intCast panic" {
    // 回归：ttl_seconds 来自外部输入，超过 u32 上限（exptime 字段宽度）时
    // 旧实现 `if (ttl_seconds > 0) @intCast(ttl_seconds)` 在 Debug 下 panic；
    // 修复后钳制到 u32 上限照常写入。
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockMemcacheServer(allocator, addr, &ready);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.fmt.bufPrint(&server_str_buf, "127.0.0.1:{d}", .{port});

    const mc = try Memcache.create(allocator, .{ .server = server_str });

    const c = mc.asCache();
    try c.set("big_ttl", "v", std.math.maxInt(i64));

    const got = try c.get("big_ttl");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);

    mc.deinit();
    allocator.destroy(mc);
    thread.join();
}

test "memcache 多线程并发 set/get 不同 key 全部正确" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockMemcacheServer(allocator, addr, &ready);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.fmt.bufPrint(&server_str_buf, "127.0.0.1:{d}", .{port});

    const mc = try Memcache.create(allocator, .{ .server = server_str });
    errdefer allocator.destroy(mc);
    errdefer mc.deinit();

    const THREADS = 8;
    const OPS = 20;

    const Worker = struct {
        fn run(client: *Memcache, tid: usize) !void {
            var i: usize = 0;
            while (i < OPS) : (i += 1) {
                var key_buf: [32]u8 = undefined;
                var val_buf: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buf, "wk_{d}_{d}", .{ tid, i });
                const val = try std.fmt.bufPrint(&val_buf, "val_{d}_{d}", .{ tid, i });
                const c = client.asCache();
                try c.set(key, val, 60);
                const got = (try c.get(key)).?;
                // get 返回借用切片，必须在下一次缓存操作前比较。
                if (!std.mem.eql(u8, got, val)) return error.ValueMismatch;
            }
        }
    };

    const threads = try allocator.alloc(std.Thread, THREADS);
    defer allocator.free(threads);
    for (threads, 0..) |*t, tid| t.* = try std.Thread.spawn(.{}, Worker.run, .{ mc, tid });
    for (threads) |t| t.join();

    // 每个 RTT 结束时都必须归还锁（`Io.Mutex` 留给下一次；跨 RTT 泄漏锁会让
    // 后续请求全部卡死）。这里顺带证明锁已回到 unlocked 状态。
    try std.testing.expect(mc.mutex.tryLock());
    mc.mutex.unlock(mc.io);

    // 先断开客户端连接（服务器读循环随之退出），再 join 服务器线程。
    mc.deinit();
    allocator.destroy(mc);
    thread.join();
}

test "memcache 服务器地址解析：IPv4/IPv6 字面量、域名与非法输入" {
    const io = default_io.io();

    // IPv4 字面量 + 端口（改动前的唯一支持项，语义必须原样保留）。
    const v4 = try resolveServer(io, "127.0.0.1:11211");
    try std.testing.expect(v4 == .ip4);
    try std.testing.expectEqual(@as(u16, 11211), v4.getPort());
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &v4.ip4.bytes);

    // IPv6 字面量：RFC 3986 的 `[addr]:port` 写法，手写实现做不到。
    const v6 = try resolveServer(io, "[::1]:11211");
    try std.testing.expect(v6 == .ip6);
    try std.testing.expectEqual(@as(u16, 11211), v6.getPort());
    const v6_full = try resolveServer(io, "[2001:db8::1]:11212");
    try std.testing.expect(v6_full == .ip6);
    try std.testing.expectEqual(@as(u16, 11212), v6_full.getPort());

    // 端口必填（`parseLiteral` 对缺端口的字面量给 0，这里必须判非法），
    // 且不再接受「地址 + 非法端口」这类半残配置。
    try std.testing.expectError(error.InvalidAddress, resolveServer(io, "127.0.0.1"));
    try std.testing.expectError(error.InvalidAddress, resolveServer(io, "127.0.0.1:notaport"));
    try std.testing.expectError(error.InvalidAddress, resolveServer(io, "bad_host:11211"));

    // 域名：`localhost:11211` 走 std 的 HostName.lookup。名字解析依赖运行环境，
    // 离线容器里跳过，不让环境噪声污染用例。
    const by_name = resolveServer(io, "localhost:11211") catch |err| switch (err) {
        error.UnknownHostName,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.ResolvConfParseFailed,
        error.DetectingNetworkConfigurationFailed,
        error.NetworkDown,
        => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(@as(u16, 11211), by_name.getPort());
}

test "memcache 读超时：服务端不回包 → 有界失败、连接被丢弃、下次请求重建" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    var stop = std.atomic.Value(bool).init(false);
    // 第 1 条连接永不回包，第 2 条正常服务；兜底 8000ms 后自断（见函数注释）。
    // 兜底刻意远于下面 5s 的判定上界，好让判定只反映「客户端超时是否生效」。
    const thread = try mockSilentThenHealthyServer(allocator, addr, &ready, &stop, 8000);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.fmt.bufPrint(&server_str_buf, "127.0.0.1:{d}", .{port});

    const mc = try Memcache.create(allocator, .{ .server = server_str, .recv_timeout_ms = 200 });
    const c = mc.asCache();

    // (a) 有界失败：必须在远早于服务端兜底断开（8000ms）之前报错，而不是挂死。
    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    try std.testing.expectError(error.StorageError, c.get("silent"));
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    std.debug.print("[memcache recv timeout] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms >= 100); // 确实等过（不是被别的错误短路）
    try std.testing.expect(elapsed_ms < 5000); // 是客户端超时在起作用，不是服务端断开

    // (b) 超时连接被丢弃：socket 与两条读取器都已释放，下一次操作会重连。
    try std.testing.expect(mc.stream == null);
    try std.testing.expect(mc.reader == null);
    try std.testing.expect(mc.timeout_reader == null);

    // (c) 下一次请求重建连接并成功（第 2 条连接被服务端正常服务）。
    try c.set("after_timeout", "v", 60);
    const got = try c.get("after_timeout");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    try std.testing.expect(try c.isExist("after_timeout"));
    try std.testing.expect(mc.stream != null);

    // 先断开客户端连接（服务器读循环随之退出），再置位 stop 并唤醒阻塞中的 accept，
    // 最后 join —— 顺序反了会把套件挂死。
    mc.deinit();
    allocator.destroy(mc);
    stop.store(true, .release);
    {
        const io = default_io.io();
        if (addr.connect(io, .{ .mode = .stream })) |wake| {
            wake.close(io);
        } else |_| {}
    }
    thread.join();
}

test "memcache 建连超时：SYN 被丢弃 → 有界失败、状态干净、同实例随后连正常地址成功" {
    const allocator = std.testing.allocator;
    const io = default_io.io();
    const port = try findFreePort();

    // 黑洞目标（本进程内的本地 listener，队列填满后内核丢 SYN）。
    // 造不出来（队列满即 RST 的环境）就跳过 —— 绝不用「可能永久阻塞」的地址硬测。
    var stall = (try makeStalledTarget(io, port)) orelse {
        std.debug.print("[memcache connect timeout] 本环境造不出「SYN 被丢弃」的目标，跳过\n", .{});
        return error.SkipZigTest;
    };
    defer stall.deinit(io);

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.fmt.bufPrint(&server_str_buf, "127.0.0.1:{d}", .{port});

    const mc = try Memcache.create(allocator, .{
        .server = server_str,
        .connect_timeout_ms = 300,
    });
    errdefer allocator.destroy(mc);
    errdefer mc.deinit();

    const c = mc.asCache();

    // (a) 有界失败：必须在 [100ms, 5000ms) 内返回，而不是等内核的 SYN 重传兜底
    //     （Linux 默认 ≈ 127s、macOS ≈ 75s）。
    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    try std.testing.expectError(error.StorageError, c.get("never"));
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    std.debug.print("[memcache connect timeout] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms >= 100); // 确实等到了 deadline，不是被别的错误短路
    try std.testing.expect(elapsed_ms < 5000); // 是客户端 deadline 在起作用，不是内核兜底

    // (b) 超时后连接状态干净：socket 与两条读取器、写入器一个都没留下。
    try std.testing.expect(mc.stream == null);
    try std.testing.expect(mc.reader == null);
    try std.testing.expect(mc.timeout_reader == null);
    try std.testing.expect(mc.writer == null);

    // (c) 同一个实例、同一个地址：黑洞下线（端口腾出来）后换成正常服务端，
    //     下一次操作必须建连成功并正常工作。
    stall.closeListener(io);
    var ready = std.atomic.Value(bool).init(false);
    const server_thread = try mockMemcacheServer(allocator, stall.addr, &ready);
    waitReady(&ready);
    // 端口没抢回来时这里立刻失败（否则会以「连接被拒」的形式误导排查方向）。
    try std.testing.expect(ready.load(.acquire));

    try c.set("after_connect_timeout", "v", 60);
    const got = try c.get("after_connect_timeout");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    try std.testing.expect(try c.isExist("after_connect_timeout"));
    try std.testing.expect(mc.stream != null);

    // 先断开客户端连接（服务器读循环随之退出），再 join 服务端线程。
    mc.deinit();
    allocator.destroy(mc);
    server_thread.join();
}
