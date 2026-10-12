// SPDX-License-Identifier: Apache-2.0
//! cache/net — `redis` 与 `memcache` 两个后端共享的网络层
//!
//! 这里收敛两块**语义完全一致**的实现，避免两个后端各持一份导致行为与说明
//! 双双漂移（上一轮为避免跨文件共享刻意重复，现已合并到这一处）：
//!
//! - `SocketReader`：「带可选读超时的 socket 读取器」，支持 `recv_timeout_ms`
//!   语义（见其文档）；
//! - `resolveHost`：主机名 / IP 字面量 → 可连接的 `std.Io.net.IpAddress`；
//! - `findFreePort`：测试用回环端口分配（绑 0 端口让内核分配后读回，见其文档）。
//!
//! 日志 scope 按后端区分（`Backend`）：读超时告警打到 `zwechat_redis` /
//! `zwechat_memcache`，宿主可用 `std_options.log_scope_levels` 单点静音某个
//! 后端，不必整体降 `log_level`。文案逐字保留各后端原有措辞。

const std = @import("std");
const builtin = @import("builtin");
const default_io = @import("../util/default_io.zig");

/// 后端标识：只用于决定日志 scope 与读超时告警文案，不影响任何网络行为。
pub const Backend = enum {
    redis,
    memcache,
};

/// 带可选读超时的 socket 读取器（`redis` / `memcache` 共用）。
///
/// 与 `std.Io.net.Stream.Reader` 同形（父结构里的 `interface` 字段 + `stream`），
/// 唯一区别是底层读取走 `Io.operateTimeout`：`recv_timeout_ms > 0` 时服务端
/// accept 之后不回包也不会让调用线程永久阻塞（否则 redis 的池连接 / memcache 的
/// 共享连接会被半死的服务端永久占死）。超时与其它读取失败都表现为
/// `error.ReadFailed`，调用方一律按「连接已失步」处理 —— 丢弃 / 断开，
/// **绝不复用**：半条回复留在连接上会让后续请求协议失步。
///
/// 读缓冲由调用方提供（与 std 的读取器一致），因此这里只覆盖 vtable 的 `stream`
/// 一项；`readVec` / `discard` / `rebase` 沿用 std 默认实现，缓冲语义不变。
///
/// `recv_timeout_ms == 0` 时 `Io.operateTimeout` 直接退化为 `Io.operate`，读数
/// 与 `std.Io.net.Stream.Reader` 完全同路（redis 始终使用本结构，memcache 在
/// `recv_timeout_ms == 0` 时另走 std 的读取器，两条路径语义等价）。
pub fn SocketReader(comptime backend: Backend) type {
    return struct {
        io: std.Io,
        stream: std.Io.net.Stream,
        interface: std.Io.Reader,
        /// 单次读取的超时毫秒数；`0` = 不超时（阻塞读）。
        recv_timeout_ms: u64 = 0,

        const Self = @This();

        pub fn init(io: std.Io, stream: std.Io.net.Stream, buffer: []u8, recv_timeout_ms: u64) Self {
            return .{
                .io = io,
                .stream = stream,
                .recv_timeout_ms = recv_timeout_ms,
                .interface = .{
                    .vtable = &vtable,
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        const vtable: std.Io.Reader.VTable = .{ .stream = streamImpl };

        fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const r: *Self = @alignCast(@fieldParentPtr("interface", io_r));
            const dest = limit.slice(try io_w.writableSliceGreedy(1));
            var data = [1][]u8{dest};
            const result = r.io.operateTimeout(.{ .net_read = .{
                .socket_handle = r.stream.socket.handle,
                .data = &data,
            } }, r.timeout()) catch |err| switch (err) {
                error.Timeout => {
                    if (backend == .redis) {
                        std.log.scoped(.zwechat_redis).warn(
                            "redis socket 读超时（recv_timeout_ms={d}）：丢弃该连接",
                            .{r.recv_timeout_ms},
                        );
                    } else {
                        std.log.scoped(.zwechat_memcache).warn(
                            "memcache socket 读超时（recv_timeout_ms={d}）：断开连接",
                            .{r.recv_timeout_ms},
                        );
                    }
                    return error.ReadFailed;
                },
                else => return error.ReadFailed,
            };
            // 0.17.0 起 `net_read` 的载荷由 `usize` 变为 `Stream.ReadResult`（含 data_len）。
            const res = result.net_read catch return error.ReadFailed;
            const n = res.data_len;
            if (n == 0) return error.EndOfStream; // 对端已关闭，等同于 std 的读取器
            io_w.advance(n);
            return n;
        }

        /// `recv_timeout_ms` → `Io.Timeout`。
        ///
        /// 用 `awake` 时钟：这是一段「最长阻塞多久」的进程内耗时，休眠期间进程本就
        /// 不跑，唤醒后继续用完剩下的额度才是语义正确的（与 memory.zig 里 TTL 的
        /// `boot` 相反）。
        fn timeout(self: *const Self) std.Io.Timeout {
            if (self.recv_timeout_ms == 0) return .none;
            // 配置值来自外部，先钳到 i64 上限再交给 std（`fromMilliseconds` 要求 i64）。
            const ms: i64 = @intCast(@min(self.recv_timeout_ms, std.math.maxInt(i64)));
            return .{ .duration = .{
                .raw = .fromMilliseconds(ms),
                .clock = .awake,
            } };
        }
    };
}

/// 把 `Options.host` 解析成可连接的地址。
///
/// - 字面量（`"127.0.0.1"` / `"::1"`）走 `std.Io.net.IpAddress.parse`：纯函数、
///   IPv4 与 IPv6 通吃（旧的手写实现只认 IPv4 字面量）；
/// - 其余按域名走 `std.Io.net.HostName.lookup`：DNS + `/etc/hosts` + RFC 6761 的
///   `localhost` 全都覆盖。注意 `IpAddress.resolve` **不是** DNS —— 它只是在
///   `parse` 之上多支持 IPv6 的作用域后缀（`fe80::1%en0`），对域名同样报
///   `error.ParseFailed`，所以这里没有用它；
/// - 域名路径依赖宿主 `Io` 的 `netLookup`；未实现时 std 的默认实现返回
///   `error.NetworkDown`（不 panic），字面量路径完全不触达它；
/// - 双栈主机上优先取 A 记录（IPv4），与改动前的纯 IPv4 行为最接近。
pub fn resolveHost(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |addr| return addr else |_| {}

    const name = std.Io.net.HostName.init(host) catch return error.InvalidAddress;
    // 容量 ≥ 16 时 `HostName.lookup` 保证不阻塞（见 std 文档）。
    var results_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results_buf);
    try std.Io.net.HostName.lookup(name, io, &results, .{ .port = port });

    var fallback: ?std.Io.net.IpAddress = null;
    while (results.getOneUncancelable(io)) |result| {
        switch (result) {
            .address => |addr| switch (addr) {
                .ip4 => return addr,
                .ip6 => if (fallback == null) {
                    fallback = addr;
                },
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {}, // 结果产出完毕时 lookup 关闭队列，属正常收尾
    }
    return fallback orelse error.InvalidAddress;
}

/// 取一个当前空闲的本地回环 TCP 端口（`127.0.0.1`，供 redis / memcache 的
/// 进程内 mock server 用例使用；两个后端共用这一份，不再各自复制）。
///
/// 实现是「bind 端口 0 → 内核分配 → `getsockname` 读回 → 关闭」：`std.Io.net`
/// 的 `listen` 在 bind 之后会做 `getsockname`（POSIX 见 `std/Io/Threaded.zig`
/// 的 `netListenIpPosix`，Windows 走 AFD bind 的返回地址），结果就在
/// `server.socket.address` 上（`Socket.address` 的文档写的就是「被请求解析临时
/// 端口时包含解析结果」），这里用 `IpAddress.getPort()` 取回。
///
/// 相比旧的「在 20000..65000 里随机挑端口 → `listen` 探测 → 立刻关闭」：
/// - 内核只会分配**当前确实空闲**的端口，不会把同一个端口同时交给两个调用方，
///   所以「两个测试进程选中同一个随机端口」这类碰撞不再发生；
/// - 旧实现的探测还用了 `reuse_address = true`，它在 POSIX 上同时打开
///   `SO_REUSEPORT`（见 `std/Io/net.zig` 的 `ListenOptions.reuse_address` 文档，
///   AGENTS.md 亦有记载），于是「探测成功」这个信号本身就是错的 —— 别的进程
///   已经绑着同一个端口时探测照样成功，两个进程随后都能绑上同一个端口，内核
///   把连接分摊给它们，某一方的 `accept` 永远等不到请求而挂死。这里用
///   `reuse_address = false`，探测结果不再具有这种双重含义（探测本身也取消了）。
///
/// **残留窗口（如实说明）**：端口是在 `defer server.deinit` 之后才真正让出的，
/// 调用方随后还要自己 `listen` 同一个端口，因此「关闭 → 重新绑定」之间仍有极
/// 小的竞争窗口。要彻底消除只有让调用方直接持用这里返回的 listener（改动全部
/// 调用点的形状），不在本次修复范围内。
pub fn findFreePort() !u16 {
    const io = default_io.io();
    const addr = std.Io.net.IpAddress{
        .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            // 端口 0 = 交给内核在内核临时端口范围里挑一个空闲的。
            .port = 0,
        },
    };
    var server = try addr.listen(io, .{ .reuse_address = false });
    defer server.deinit(io);

    const port = server.socket.address.getPort();
    // 后端若没做 `getsockname`，拿回的就是 0；宁可报错也**不要**把 0 号端口交给
    // 调用方（用它去 connect 只会得到一堆与真实原因无关的失败）。
    if (port == 0) return error.AddressInUse;
    return port;
}

// ============================================================================
// 单元测试：全部离线（回环 socket + 纯函数），不依赖外部服务。
// ============================================================================

test "cache/net resolveHost：IPv4/IPv6 字面量带端口，非法输入报 InvalidAddress" {
    const io = default_io.io();

    // IPv4 字面量（改动前的唯一支持项，语义必须原样保留）。
    const v4 = try resolveHost(io, "127.0.0.1", 6379);
    try std.testing.expect(v4 == .ip4);
    try std.testing.expectEqual(@as(u16, 6379), v4.getPort());
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &v4.ip4.bytes);

    // IPv6 字面量：手写实现完全做不到，现在由 std 一步解析。
    const v6 = try resolveHost(io, "::1", 11211);
    try std.testing.expect(v6 == .ip6);
    try std.testing.expectEqual(@as(u16, 11211), v6.getPort());
    const v6_full = try resolveHost(io, "2001:db8::1", 6380);
    try std.testing.expect(v6_full == .ip6);
    try std.testing.expectEqual(@as(u16, 6380), v6_full.getPort());

    // 非法输入（含空格 / 下划线 → 连主机名都不合法）必须是明确的配置错误，
    // 而不是被当成地址或域名拿去做解析。
    try std.testing.expectError(error.InvalidAddress, resolveHost(io, "not a host", 6379));
    try std.testing.expectError(error.InvalidAddress, resolveHost(io, "bad_host", 6379));
}

test "cache/net findFreePort：内核分配的空闲端口可独占重绑，不被 SO_REUSEPORT 共享" {
    const io = default_io.io();
    const port = try findFreePort();

    // 内核分配的临时端口一定是真的（0 表示后端没回读成功，属实现错误）。
    try std.testing.expect(port != 0);

    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };

    // 交出来的端口必须能立刻被调用方（mock server）以独占方式绑上，且绑回的是
    // 同一个端口号。极小概率下外部进程恰好抢占该端口才会失败 —— 这与生产调用点
    // 承担的残留窗口是同一个，不是本用例引入的新风险。
    var server = try addr.listen(io, .{ .reuse_address = false });
    defer server.deinit(io);
    try std.testing.expectEqual(port, server.socket.address.getPort());

    // 独占语义（本用例的核心）：listener 还活着时，第二个 `reuse_address = false`
    // 的 bind 必须报 `AddressInUse`。旧实现的探测走 `reuse_address = true` ——
    // 那会同时打开 `SO_REUSEPORT`，于是这里会**成功**，两个进程共享同一端口、
    // 内核把连接分摊给它们，某一方的 `accept` 永远等不到请求（测试挂死的成因）。
    //
    // ⚠ 这条断言只在 **POSIX** 上成立：Windows 的 `SO_REUSEADDR` 语义不同（它允许绑到
    // 已被占用的端口，且没有 `SO_REUSEPORT` 的对称概念），所以 Windows 上第二次 listen
    // 会成功。CI 的 windows job 曾经因此变红 —— 这里按平台跳过，别把它当成跨平台不变量。
    if (builtin.os.tag != .windows) {
        try std.testing.expectError(error.AddressInUse, addr.listen(io, .{ .reuse_address = false }));
    }
}

test "cache/net SocketReader：recv_timeout_ms=0 时与 std 的 Stream.Reader 逐字节等价" {
    const allocator = std.testing.allocator;
    const io = default_io.io();
    const port = try findFreePort();
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };

    const payload = "value-for-socket-reader-equivalence-check";
    // 三条连接：redis 实例化、std 的读取器、memcache 实例化（只差日志 scope）。
    var ready = std.atomic.Value(bool).init(false);
    const thread = try servePayloadOnce(allocator, addr, payload, 3, &ready);
    waitReady(&ready);

    {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var read_buf: [64]u8 = undefined;
        var reader = SocketReader(.redis).init(io, stream, &read_buf, 0);
        try readAndCheck(&reader.interface, payload);
    }
    {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var read_buf: [64]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        try readAndCheck(&reader.interface, payload);
    }
    {
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var read_buf: [64]u8 = undefined;
        var reader = SocketReader(.memcache).init(io, stream, &read_buf, 0);
        try readAndCheck(&reader.interface, payload);
    }

    thread.join();
}

/// 读满 `expect.len` 字节并比对，随后再读一次要求与 std 的读取器同款收尾错误
/// （对端关闭 → `error.EndOfStream`，不是 `error.ReadFailed`）。
fn readAndCheck(interface: *std.Io.Reader, expect: []const u8) !void {
    var got_buf: [512]u8 = undefined;
    const got = got_buf[0..expect.len];
    try interface.readSliceAll(got);
    try std.testing.expectEqualStrings(expect, got);

    var extra: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, interface.readSliceAll(&extra));
}

/// 测试夹具：顺序接受 `count` 条连接，各写一遍 `payload` 后立刻关闭。
fn servePayloadOnce(
    allocator: std.mem.Allocator,
    bind_addr: std.Io.net.IpAddress,
    payload: []const u8,
    count: usize,
    ready: *std.atomic.Value(bool),
) !std.Thread {
    return try std.Thread.spawn(.{}, struct {
        fn run(
            alloc: std.mem.Allocator,
            addr: std.Io.net.IpAddress,
            data: []const u8,
            n: usize,
            rdy: *std.atomic.Value(bool),
        ) !void {
            var threaded = std.Io.Threaded.init(alloc, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var server = try addr.listen(io, .{ .reuse_address = false });
            rdy.store(true, .release);
            defer server.deinit(io);

            var i: usize = 0;
            while (i < n) : (i += 1) {
                const conn = try server.accept(io);
                defer conn.close(io);
                var write_buf: [256]u8 = undefined;
                var writer = conn.writer(io, &write_buf);
                try writer.interface.writeAll(data);
                try writer.interface.flush();
            }
        }
    }.run, .{ allocator, bind_addr, payload, count, ready });
}

/// 有界等待夹具服务器就绪（最多 2 秒，避免服务器起不来时用例无限挂住）。
fn waitReady(ready: *std.atomic.Value(bool)) void {
    var i: usize = 0;
    while (!ready.load(.acquire)) : (i += 1) {
        if (i > 400) return;
        std.Io.sleep(default_io.io(), std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
}

// 端口分配夹具 `findFreePort` 已上移为公开实现（`pub fn findFreePort`），
// 与 `resolveHost` 一样由 redis / memcache 共用一份。
