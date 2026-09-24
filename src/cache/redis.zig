// SPDX-License-Identifier: Apache-2.0
//! cache/redis — Redis 缓存实现（可选连接池）
//!
//! 对应 `_ref/wechat/cache/redis.go`：通过 RESP 协议与 Redis 通信，提供
//! `Cache` vtable 兼容的 get / set / isExist / delete / deinit。
//!
//! 设计取舍：
//! - **可选连接池**（`Options.max_connections`，默认 1）。默认值等价于历史行为：
//!   池中只有一条 TCP 连接，同一时刻只有一个在途请求（语义与 0.4.4 的单连接串行化
//!   一致，且同样不会交错写 socket）。设为 N > 1 时最多 N 条连接并行服务 N 个并发
//!   调用，吞吐不再被 1/RTT 卡住（串行化修好了协议交错损坏，但代价是把并发压成
//!   单连接；连接池两者兼得）。
//! - **池锁只保护空闲连接表与计数器**：建连、AUTH/SELECT、请求-响应往返、
//!   `close` 全部在池锁之外进行。持池锁做网络 I/O 会让池退化回单连接串行
//!   —— 这是本实现的核心纪律，改动时不要破坏。池锁本身是 `std.Io.Mutex`
//!   （真阻塞的 futex 锁），但临界区极短，等待者几乎不会真的睡下去。
//! - **等待有上界**：池已满时调用方在锁外「短自旋 + 小睡」等待归还，超过
//!   `Options.pool_timeout_ms` 放弃并返回 `error.PoolTimeout`（vtable 边界映射为
//!   `CacheError.StorageError`，同时计入 `Redis.poolStats().timeouts`）。永远不挂死。
//!   注意：这条等待路径**刻意不阻塞在池锁上**（在锁上等就没有超时可言了），
//!   而是短自旋 + 小睡轮询，直到超时或拿到连接。
//! - **坏连接不进池**：读写失败 / 协议解析失败的连接已失步或已断开，直接关闭丢弃，
//!   下次取连接时重建；服务端返回 `-ERR`（回复完整、协议仍同步）的连接照常复用。
//! - **可选读超时**（`Options.recv_timeout_ms`，默认 `0` = 不超时）：配置后每次
//!   socket 读取都受 deadline 约束，服务端 accept 后不回包时调用线程有界返回，
//!   该连接按坏连接丢弃（计入 `discarded`），下次请求重建 —— 池不会被半死的
//!   服务端占死。
//! - **可选建连超时**（`Options.connect_timeout_ms`，默认 `0` = 不超时）：配置后
//!   **TCP 握手本身**也受 deadline 约束 —— 对端 SYN 被静默丢弃（黑洞 / 防火墙
//!   DROP / 对端过载）时不再卡到内核上限（Linux 默认 ≈ 127s、macOS ≈ 75s），
//!   到点直接以 `error.StorageError` 返回，且**不创建连接**（不进池、`created`
//!   不增长）。实现见文件末尾「建连超时」一节：本工具链的 std 没有可用的
//!   connect 超时能力，只能用「非阻塞 connect + poll(deadline)」自己实现。
//! - **主机解析交给 std**：`IpAddress.parse` 认 IPv4 / IPv6 字面量，
//!   `HostName.lookup` 认域名；不再有只支持 IPv4 的手写解析。
//! - **网络层与 memcache 共用**：读超时读取器与主机解析实现在 `net.zig`（两处
//!   设计说明也就只有一处，不会再各自漂移）；日志统一走本文件的
//!   `std.log.scoped(.zwechat_redis)`，宿主可用 `std_options.log_scope_levels`
//!   单独静音 redis 的告警。
//! - `get` 返回的切片借用自**当前连接的复用值缓冲**：任何后续 `get`（含其它线程的
//!   `get`）之后都不保证仍有效，跨操作持有必须 `allocator.dupe`。
//! - 不支持 TLS；如需 TLS，可外部用 stunnel / redis+tls 代理，或后续扩展。

const std = @import("std");
const default_io = @import("../util/default_io.zig");
const posix = std.posix;
const Cache = @import("mod.zig").Cache;
const CacheError = @import("mod.zig").CacheError;
/// 与 `memcache.zig` 共享的网络层（带读超时的 socket 读取器 + 主机解析）。
const net = @import("net.zig");

/// 本文件的日志 scope：宿主可用 `std_options.log_scope_levels` 单独静音 redis
/// 的告警，而不必整体降低 `log.level`（memcache / mtls 同理，各用自己的 scope）。
const log = std.log.scoped(.zwechat_redis);

/// 建连超时路径只在 POSIX 上实现（Windows / WASI 退化为阻塞 connect）。
const native_os = @import("builtin").os.tag;

/// Redis 连接选项。
pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    db: i32 = 0,
    /// 外部传入的 `Io` 句柄。未提供时 `Redis` 会自行创建一个 `std.Io.Threaded`。
    io: ?std.Io = null,

    /// 连接池上限：同时存活的最大连接数。
    ///
    /// - 默认 1，与历史单连接实现完全等价（既有调用点无需改动）。
    /// - `0` 会被钳制为 `1`（避免出现永远取不到连接的池）。
    /// - N > 1 时最多 N 个请求并行；超出部分排队等待归还。
    max_connections: usize = 1,

    /// 等待空闲连接的最长时间（毫秒），默认 30000。
    ///
    /// 语义：
    /// - 池未达上限时直接新建连接返回，**不等待**；
    /// - 池已满时在**不持池锁**的前提下自旋 + 小睡重试，直到有连接归还；
    /// - 超过本时长仍无可用连接则放弃本次操作：`acquire` 返回 `error.PoolTimeout`，
    ///   vtable 边界映射为 `CacheError.StorageError` 并打印 warn 日志，
    ///   同时 `Redis.poolStats().timeouts` 自增 —— 等待一定是**有界**的，不会挂死；
    /// - `0` 表示不等待（池满即刻超时）。
    pool_timeout_ms: u64 = 30_000,

    /// 单次 socket 读取的超时（毫秒），默认 `0` = 不超时。
    ///
    /// - `0`（默认）沿用阻塞读：行为与历史版本完全一致；
    /// - `> 0` 时每次从 socket 读取都套一个不超过本时长的 deadline
    ///   （`Io.operateTimeout`，语义等价 `SO_RCVTIMEO`）。服务端 accept 之后
    ///   不回包（半死 / 过载 / 连接被中间设备静默吞掉）时，调用线程在
    ///   `recv_timeout_ms` 内拿到 `error.StorageError`，而不是永久阻塞把
    ///   池连接占死；
    /// - 超时后连接**一定被丢弃**（计入 `poolStats().discarded`），下次请求重建：
    ///   半条回复留在连接上会让后续请求协议失步，复用比断连危险得多；
    /// - 只约束「单次读取」，不约束一次请求的总时长（多次读取各自计时），
    ///   **也不约束建连**（建连看 `connect_timeout_ms`）。
    recv_timeout_ms: u64 = 0,

    /// 建连（TCP 三次握手）的超时（毫秒），默认 `0` = 不超时（保持历史行为）。
    ///
    /// **与 `recv_timeout_ms` 的分工**：
    /// - 本项管「连上之前」：对端 SYN 被丢弃（黑洞 / 防火墙 DROP / 对端过载）
    ///   时，阻塞 connect 会一直卡到内核上限（Linux 默认 SYN 重传 6 次 ≈ 127s，
    ///   macOS ≈ 75s），期间调用线程与池槽位都被占住；
    /// - `recv_timeout_ms` 管「连上之后」的每一次 socket 读取，**不覆盖建连**；
    /// - 两者可以独立开关：只配 `recv_timeout_ms` 时，半死的对端能在读阶段脱身，
    ///   但连不上的对端仍会卡住；只配本项时，连得上的对端如果 accept 后不回包
    ///   依然会一直等。
    ///
    /// 语义与取舍：
    /// - `0`（默认）沿用阻塞 connect：零额外系统调用，行为与历史版本一致；
    /// - `> 0` 时用「非阻塞 connect + `poll(deadline)`」把建连卡在期限内，
    ///   到点返回 `error.ConnectTimeout`，池边界映射为 `error.StorageError`；
    /// - 超时的 socket **立即关闭**：既不进池也不计入 `created`/`discarded`
    ///   —— 半开的连接没有任何复用价值；
    /// - 只约束建连：握手成功后 socket 恢复成阻塞模式，读写仍由 `recv_timeout_ms`
    ///   决定；
    /// - POSIX（Linux / macOS / BSD）上真实生效；**Windows / WASI 退化为阻塞
    ///   connect**（选项仍可配置，但不生效），需要严格上限的部署别把这当成已受保护。
    connect_timeout_ms: u64 = 0,
};

/// 连接池运行观测数据（用于监控与测试取证）。
pub const PoolStats = struct {
    /// 当前存活连接数（空闲 + 借出）。
    live: usize,
    /// 当前空闲连接数。
    idle: usize,
    /// 当前借出中的连接数（= live - idle）。
    in_use: usize,
    /// 历史并发借出峰值（并发度的直接用证据）。
    peak_in_use: usize,
    /// 累计新建连接数。
    created: usize,
    /// 累计因协议 / IO 错误被丢弃的连接数（不会回到池中）。
    discarded: usize,
    /// 累计等待空闲连接超时次数。
    timeouts: usize,
};

/// RESP 回复。
const Reply = union(enum) {
    /// 借用自 `Conn.line_buffer`。
    simple_string: []const u8,
    /// 借用自 `Conn.line_buffer`。
    error_msg: []const u8,
    integer: i64,
    /// 借用自 `Conn.value_buf`。
    bulk_string: []const u8,
    null_bulk: void,
};

/// 单条 RESP 连接：独占一条 TCP 流、一对读写缓冲区与一个值缓冲。
///
/// 任意时刻至多被一个调用方持有（借出期间不持有池锁），因此连接内部状态无需再加锁，
/// 也不会出现两个线程交错写同一个 socket 的协议损坏。
const Conn = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    read_buffer: [4096]u8 = undefined,
    write_buffer: [4096]u8 = undefined,
    /// 带可选读超时的读取器（共享实现见 `net.zig`；日志归属 redis 的 scope）。
    /// redis 始终用它：`recv_timeout_ms == 0` 时与 std 的读取器完全同路。
    reader: net.SocketReader(.redis),
    writer: std.Io.net.Stream.Writer,
    /// 读取 RESP 简单字符串/整数字行时的临时缓冲区（每条连接独立）。
    line_buffer: [512]u8 = undefined,
    /// bulk string 的宿主缓冲：跨多次 `get` 复用（容量只增不减），
    /// 正常路径上没有「每次 get 一次 malloc + free」的开销，也不会把别的线程
    /// 正在读的缓冲区提前释放掉。`get` 返回的切片借用自此缓冲。
    value_buf: std.ArrayListUnmanaged(u8) = .empty,

    fn close(self: *Conn) void {
        self.stream.close(self.io);
    }

    /// 释放连接自身持有的堆内存（不关闭 socket，由调用方决定时机）。
    fn destroyValueBuf(self: *Conn) void {
        self.value_buf.deinit(self.allocator);
    }

    fn sendCommand(self: *Conn, args: []const []const u8) !void {
        const w = &self.writer.interface;
        try w.print("*{d}\r\n", .{args.len});
        for (args) |arg| {
            try w.print("${d}\r\n", .{arg.len});
            try w.writeAll(arg);
            try w.writeAll("\r\n");
        }
        try w.flush();
    }

    /// 发送命令并要求回复为 `+OK`（用于 AUTH / SELECT）。
    fn expectOk(self: *Conn, args: []const []const u8) !void {
        try self.sendCommand(args);
        const reply = try self.readReply();
        switch (reply) {
            .simple_string => |s| if (!std.mem.eql(u8, s, "OK")) return error.StorageError,
            else => return error.StorageError,
        }
    }

    fn readReply(self: *Conn) !Reply {
        const kind = try self.reader.interface.takeByte();

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
                // 复用 value_buf：仅在需要更大容量时才重新分配。
                self.value_buf.clearRetainingCapacity();
                try self.value_buf.resize(self.allocator, size);
                const r = &self.reader.interface;
                r.readSliceAll(self.value_buf.items) catch return error.StorageError;
                var trailing: [2]u8 = undefined;
                r.readSliceAll(&trailing) catch return error.StorageError;
                if (trailing[0] != '\r' or trailing[1] != '\n') return error.StorageError;
                return .{ .bulk_string = self.value_buf.items };
            },
            '*' => {
                _ = try self.readLine();
                return error.StorageError;
            },
            else => return error.StorageError,
        }
    }

    /// 读一行（不含 `\r\n`），结果拷进 `line_buffer`。
    ///
    /// 用 `takeDelimiterExclusive('\r')` 一次取到分隔符（`std` 内部按缓冲区扫描，
    /// 不再逐字节一次 `readSliceAll`），再吃一个字节确认 `\n`。
    /// 长度上限仍是 `line_buffer.len`（超限返回 `error.StorageError`）。
    ///
    /// 返回的切片借用自 `line_buffer`：**下一次 readLine 之前有效**（`Reply` 的
    /// 借用语义、以及 `Reply` 与 `value_buf` 的独立生命周期都由这次拷贝保证）。
    fn readLine(self: *Conn) ![]const u8 {
        const r = &self.reader.interface;
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

/// 等待可用连接时的退避参数：先自旋 `WaitSpinRounds` 轮（低延迟路径），
/// 之后每轮小睡 `WaitSleepNs`（避免烧 CPU）。
const WaitSpinRounds: usize = 512;
const WaitSleepNs: i96 = 200_000;

/// 取连接可能返回的错误。
const PoolError = error{ PoolTimeout, OutOfMemory, StorageError };

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
    /// 生效的池上限（`opts.max_connections == 0` 时按 1 处理）。
    max_connections: usize,

    // ---------------- 连接池状态：全部由 `pool_mutex` 保护 ----------------
    /// 池锁。临界区只包含「空闲表操作 + 计数更新」，**绝不包含** connect/close/读写
    /// socket 等任何网络 I/O；否则池会退化回单连接串行，本次改造就白做了。
    /// 真阻塞的 `std.Io.Mutex`（`self.io` 驱动 futex 等待 / 唤醒）。
    pool_mutex: std.Io.Mutex = .init,
    /// 空闲（已建好、可立即复用）连接。容量在 `create` 时预留到 `max_connections`，
    /// 因此正常路径上池锁内不会发生堆分配。
    idle: std.ArrayListUnmanaged(*Conn) = .empty,
    /// 当前存活连接数 = `idle.len` + 借出中的连接数。
    live: usize = 0,
    /// 历史并发借出峰值。
    peak_in_use: usize = 0,
    /// 累计新建连接数。
    created_total: usize = 0,
    /// 累计丢弃连接数。
    discarded_total: usize = 0,
    /// 累计等待连接超时次数。
    timeout_total: usize = 0,

    pub fn create(allocator: std.mem.Allocator, opts: Options) !*Redis {
        const self = try allocator.create(Redis);
        errdefer allocator.destroy(self);

        var owned_io: ?std.Io.Threaded = null;
        errdefer if (owned_io) |*t| t.deinit();
        const io = opts.io orelse io: {
            owned_io = std.Io.Threaded.init(allocator, .{});
            break :io owned_io.?.io();
        };

        self.* = .{
            .allocator = allocator,
            .opts = opts,
            .io = io,
            .owned_io = owned_io,
            .max_connections = if (opts.max_connections == 0) 1 else opts.max_connections,
        };
        if (self.owned_io) |*t| {
            self.io = t.io();
        }
        // 空闲表容量一次预留到位：后续 append 不再分配，池锁内的临界区保持「纯内存」。
        try self.idle.ensureTotalCapacity(allocator, self.max_connections);
        return self;
    }

    pub fn deinit(self: *Redis) void {
        // 关闭池内所有空闲连接。调用方需保证此时没有进行中的操作；
        // close 是系统调用，逐个在池锁之外执行。
        while (true) {
            self.pool_mutex.lockUncancelable(self.io);
            const conn = self.idle.pop() orelse {
                self.pool_mutex.unlock(self.io);
                break;
            };
            self.live -= 1;
            self.pool_mutex.unlock(self.io);
            self.freeConn(conn);
        }

        self.pool_mutex.lockUncancelable(self.io);
        self.idle.deinit(self.allocator);
        self.pool_mutex.unlock(self.io);

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

    /// 连接池运行统计快照（加锁读取，临界区内无 I/O）。
    pub fn poolStats(self: *Redis) PoolStats {
        self.pool_mutex.lockUncancelable(self.io);
        defer self.pool_mutex.unlock(self.io);
        return .{
            .live = self.live,
            .idle = self.idle.items.len,
            .in_use = self.live - self.idle.items.len,
            .peak_in_use = self.peak_in_use,
            .created = self.created_total,
            .discarded = self.discarded_total,
            .timeouts = self.timeout_total,
        };
    }

    // ---------------- 连接池 ----------------

    /// 借出一条连接。
    ///
    /// - 池中有空闲连接：立即借出；
    /// - 池未达上限：先占槽位（锁内），再在**锁外**建连（含 AUTH / SELECT 往返）；
    /// - 池已满：在**锁外**自旋 + 小睡等待归还，超过 `opts.pool_timeout_ms` 返回
    ///   `error.PoolTimeout`（等待有上界，不会永久挂死）。
    ///
    /// 借用方用完必须调用 `release` 归还（或标记为不可用以便丢弃）。
    fn acquire(self: *Redis) PoolError!*Conn {
        const timeout_ns = self.timeoutNs();
        const start_ns = nowNanoseconds();
        var spin_rounds: usize = 0;

        while (true) {
            self.pool_mutex.lockUncancelable(self.io);
            if (self.idle.pop()) |conn| {
                self.noteBorrowLocked();
                self.pool_mutex.unlock(self.io);
                return conn;
            }
            if (self.live < self.max_connections) {
                // 先占槽位，防止并发下超建；建连本身放到锁外。
                self.live += 1;
                self.noteBorrowLocked();
                self.pool_mutex.unlock(self.io);

                const conn = self.createConn() catch |err| {
                    self.pool_mutex.lockUncancelable(self.io);
                    self.live -= 1;
                    self.pool_mutex.unlock(self.io);
                    return err;
                };
                self.pool_mutex.lockUncancelable(self.io);
                self.created_total += 1;
                self.pool_mutex.unlock(self.io);
                return conn;
            }
            self.pool_mutex.unlock(self.io);

            // 池已满：锁外等待。短自旋 + 小睡两段式退避（不持锁，归还方能立刻送达）。
            if (timeout_ns == 0 or nowNanoseconds() - start_ns >= timeout_ns) {
                self.pool_mutex.lockUncancelable(self.io);
                self.timeout_total += 1;
                self.pool_mutex.unlock(self.io);
                return error.PoolTimeout;
            }
            if (spin_rounds < WaitSpinRounds) {
                spin_rounds += 1;
                std.atomic.spinLoopHint();
            } else {
                std.Io.sleep(self.io, std.Io.Duration.fromNanoseconds(WaitSleepNs), .awake) catch {};
            }
        }
    }

    /// 归还连接。`reusable == false` 表示这条连接已失步或已断开（协议 / IO 错误），
    /// 直接关闭丢弃，**不**放回池中 —— 否则一个坏连接会污染后续所有请求。
    fn release(self: *Redis, conn: *Conn, reusable: bool) void {
        if (!reusable) {
            self.discardConn(conn);
            return;
        }
        self.pool_mutex.lockUncancelable(self.io);
        self.idle.append(self.allocator, conn) catch {
            self.pool_mutex.unlock(self.io);
            self.discardConn(conn);
            return;
        };
        self.pool_mutex.unlock(self.io);
    }

    /// 丢弃一条不可用连接：先关闭（锁外 I/O），再更新计数，最后释放内存。
    fn discardConn(self: *Redis, conn: *Conn) void {
        self.freeConn(conn);
        self.pool_mutex.lockUncancelable(self.io);
        self.live -= 1;
        self.discarded_total += 1;
        self.pool_mutex.unlock(self.io);
    }

    /// 关闭并释放一条连接（维护 `live` 计数之外的资源）。不加池锁。
    fn freeConn(self: *Redis, conn: *Conn) void {
        conn.close();
        conn.destroyValueBuf();
        self.allocator.destroy(conn);
    }

    /// 更新「借出中」峰值。必须在持有 `pool_mutex` 时调用。
    fn noteBorrowLocked(self: *Redis) void {
        const in_use = self.live - self.idle.items.len;
        if (in_use > self.peak_in_use) self.peak_in_use = in_use;
    }

    /// `opts.pool_timeout_ms` 换算为纳秒（饱和，避免溢出）。
    fn timeoutNs(self: *Redis) i64 {
        const ms = self.opts.pool_timeout_ms;
        if (ms == 0) return 0;
        const ns = ms *| std.time.ns_per_ms;
        if (ns > @as(u64, @intCast(std.math.maxInt(i64)))) return std.math.maxInt(i64);
        return @intCast(ns);
    }

    /// 建立一条新连接（TCP + 可选 AUTH / SELECT）。**不得**在持有 `pool_mutex` 时调用。
    fn createConn(self: *Redis) PoolError!*Conn {
        const addr = net.resolveHost(self.io, self.opts.host, self.opts.port) catch |err| {
            log.warn("redis 主机解析失败：host={s} err={s}", .{ self.opts.host, @errorName(err) });
            return error.StorageError;
        };
        const stream = connectStream(self.io, addr, self.opts.connect_timeout_ms) catch |err| switch (err) {
            error.ConnectTimeout => {
                log.warn(
                    "redis 建连超时（connect_timeout_ms={d}）：放弃本次操作，不创建连接",
                    .{self.opts.connect_timeout_ms},
                );
                return error.StorageError;
            },
            else => {
                log.warn("redis connect failed: {s}", .{@errorName(err)});
                return error.StorageError;
            },
        };
        errdefer stream.close(self.io);

        const conn = self.allocator.create(Conn) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(conn);

        conn.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
        };
        conn.reader = net.SocketReader(.redis).init(self.io, stream, &conn.read_buffer, self.opts.recv_timeout_ms);
        conn.writer = stream.writer(self.io, &conn.write_buffer);

        if (self.opts.password) |pwd| {
            conn.expectOk(&.{ "AUTH", pwd }) catch return error.StorageError;
        }
        if (self.opts.db != 0) {
            const db_str = std.fmt.allocPrint(self.allocator, "{d}", .{self.opts.db}) catch return error.OutOfMemory;
            defer self.allocator.free(db_str);
            conn.expectOk(&.{ "SELECT", db_str }) catch return error.StorageError;
        }
        return conn;
    }

    /// 借出连接并把池错误映射到 `CacheError`（`PoolTimeout` 会打印 warn 并计数）。
    fn acquireForOp(self: *Redis) CacheError!*Conn {
        return self.acquire() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PoolTimeout => {
                log.warn(
                    "redis 连接池等待超时：max_connections={d}, pool_timeout_ms={d}，放弃本次操作",
                    .{ self.max_connections, self.opts.pool_timeout_ms },
                );
                return error.StorageError;
            },
            error.StorageError => return error.StorageError,
        };
    }

    // ---------------- vtable 实现 ----------------
    //
    // 通用约定：`reusable` 默认为 true（服务端完整回复的错误 → 协议仍同步，连接可复用），
    // 只有读写失败 / 协议解析失败 / 非预期回复类型才置为 false，交 `release` 丢弃。

    const vtable: Cache.VTable = .{
        .get = getImpl,
        .set = setImpl,
        .isExist = isExistImpl,
        .delete = deleteImpl,
        .deinit = deinitImpl,
    };

    fn getImpl(ctx: *anyopaque, key: []const u8) CacheError!?[]const u8 {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);

        conn.sendCommand(&.{ "GET", key }) catch {
            reusable = false;
            return error.StorageError;
        };
        const reply = conn.readReply() catch {
            reusable = false;
            return error.StorageError;
        };
        switch (reply) {
            .null_bulk => return null,
            .bulk_string => |bs| return bs,
            .error_msg => |e| {
                log.warn("redis GET failed: {s}", .{e});
                return error.StorageError;
            },
            else => {
                reusable = false;
                return error.StorageError;
            },
        }
    }

    fn setImpl(ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);

        if (ttl_seconds > 0) {
            const ttl_str = std.fmt.allocPrint(self.allocator, "{d}", .{ttl_seconds}) catch return error.OutOfMemory;
            defer self.allocator.free(ttl_str);
            conn.sendCommand(&.{ "SETEX", key, ttl_str, val }) catch {
                reusable = false;
                return error.StorageError;
            };
        } else {
            conn.sendCommand(&.{ "SET", key, val }) catch {
                reusable = false;
                return error.StorageError;
            };
        }

        const reply = conn.readReply() catch {
            reusable = false;
            return error.StorageError;
        };
        switch (reply) {
            .simple_string => |s| if (!std.mem.eql(u8, s, "OK")) {
                log.warn("redis SET 返回非 OK：{s}", .{s});
                return error.StorageError;
            },
            .error_msg => |e| {
                log.warn("redis SET failed: {s}", .{e});
                return error.StorageError;
            },
            else => {
                reusable = false;
                return error.StorageError;
            },
        }
    }

    fn isExistImpl(ctx: *anyopaque, key: []const u8) CacheError!bool {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);

        conn.sendCommand(&.{ "EXISTS", key }) catch {
            reusable = false;
            return error.StorageError;
        };
        const reply = conn.readReply() catch {
            reusable = false;
            return error.StorageError;
        };
        switch (reply) {
            .integer => |n| return n > 0,
            .error_msg => |e| {
                log.warn("redis EXISTS failed: {s}", .{e});
                return error.StorageError;
            },
            else => {
                reusable = false;
                return error.StorageError;
            },
        }
    }

    fn deleteImpl(ctx: *anyopaque, key: []const u8) CacheError!void {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);

        conn.sendCommand(&.{ "DEL", key }) catch {
            reusable = false;
            return error.StorageError;
        };
        _ = conn.readReply() catch {
            reusable = false;
            return error.StorageError;
        };
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Redis = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

/// 当前单调时钟纳秒时间戳（`std.Io.Clock.now`，与 memory.zig 一致）。
///
/// 这里刻意用 `awake`：它只服务连接池的**等待耗时**判定（`pool_timeout_ms`），
/// 要的是「进程实际等了多久」；休眠期间进程不跑，不该算进等待额度。
/// （TTL 语义相反，见 memory.zig 的 `ttlClock`。）
fn nowNanoseconds() i64 {
    const ts = std.Io.Clock.now(.awake, default_io.io());
    return @intCast(ts.nanoseconds);
}

// 主机解析（`Options.host` → 可连接地址）已收敛到 `net.resolveHost`（`net.zig`），
// 与 `memcache.zig` 共用一份实现与一处设计说明。

// ============================================================================
// 建连（含可选超时）
// ============================================================================

/// 建连失败的错误集（`connectStream` 及其超时路径共用）。
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
/// 失败与超时路径都由 `errdefer` 关掉这条 socket，它绝不会被池化。
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
    // 无论成败都要恢复原来的阻塞标志位：池化出去的连接必须还是「阻塞读」语义
    // （读超时另有 `recv_timeout_ms` 管）。
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

/// mock 服务器的 KV 存储；可被多条连接共享（自带互斥）。
///
/// 与生产代码同一套同步原语：`std.Io.Mutex`（真阻塞），`io` 只用来自动 futex
/// 等待 / 唤醒，与 `Threaded` 实例无关，故直接用 `default_io.io()`。
const Store = struct {
    allocator: std.mem.Allocator,
    map: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80),
    io: std.Io = default_io.io(),
    mutex: std.Io.Mutex = .init,

    fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .map = std.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80).init(allocator),
        };
    }

    fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    fn put(self: *Store, key: []const u8, val: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_val = try self.allocator.dupe(u8, val);
        errdefer self.allocator.free(owned_val);

        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.map.put(owned_key, owned_val);
    }

    fn remove(self: *Store, key: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    fn contains(self: *Store, key: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.map.contains(key);
    }

    /// 复制一份值供调用方使用（避免持锁写 socket）。调用方负责 free。
    fn getCopy(self: *Store, key: []const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const val = self.map.get(key) orelse return null;
        return try self.allocator.dupe(u8, val);
    }
};

/// 处理一条命令并写回响应；返回 `false` 表示该连接应关闭。
fn mockHandleCommand(store: *Store, args: []const []const u8, writer: *std.Io.net.Stream.Writer) bool {
    const w = &writer.interface;
    const cmd = args[0];

    if (std.mem.eql(u8, cmd, "PING")) {
        w.writeAll("+PONG\r\n") catch return false;
    } else if (std.mem.eql(u8, cmd, "GET")) {
        if (args.len < 2) return false;
        const maybe_val = store.getCopy(args[1]) catch return false;
        if (maybe_val) |val| {
            defer store.allocator.free(val);
            w.print("${d}\r\n{s}\r\n", .{ val.len, val }) catch return false;
        } else {
            w.writeAll("$-1\r\n") catch return false;
        }
    } else if (std.mem.eql(u8, cmd, "SET")) {
        if (args.len < 3) return false;
        store.put(args[1], args[2]) catch return false;
        w.writeAll("+OK\r\n") catch return false;
    } else if (std.mem.eql(u8, cmd, "SETEX")) {
        if (args.len < 4) return false;
        store.put(args[1], args[3]) catch return false;
        w.writeAll("+OK\r\n") catch return false;
    } else if (std.mem.eql(u8, cmd, "EXISTS")) {
        if (args.len < 2) return false;
        w.writeAll(if (store.contains(args[1])) ":1\r\n" else ":0\r\n") catch return false;
    } else if (std.mem.eql(u8, cmd, "DEL")) {
        if (args.len < 2) return false;
        store.remove(args[1]);
        w.writeAll(":1\r\n") catch return false;
    } else if (std.mem.eql(u8, cmd, "AUTH") or std.mem.eql(u8, cmd, "SELECT")) {
        w.writeAll("+OK\r\n") catch return false;
    } else {
        w.writeAll("-ERR unknown command\r\n") catch return false;
    }

    w.flush() catch return false;
    return true;
}

/// 单连接 mock 服务器：接受一条连接并服务到客户端断开（供既有用例使用）。
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

            var store = Store.init(alloc);
            defer store.deinit();

            var read_buf: [1024]u8 = undefined;
            var write_buf: [1024]u8 = undefined;
            var reader = conn.reader(io, &read_buf);
            var writer = conn.writer(io, &write_buf);

            while (true) {
                const args_opt = mockReadCommand(alloc, &reader) catch break;
                var args = args_opt orelse break;
                defer {
                    for (args.items) |a| alloc.free(a);
                    args.deinit(alloc);
                }
                if (args.items.len == 0) continue;
                if (!mockHandleCommand(&store, args.items, &writer)) break;
            }
        }
    }.run, .{ allocator, bind_addr, ready });
}

/// 多连接 mock 服务器：并发接受连接（每条连接一个服务线程）、共享同一份 KV，
/// 并统计同时打开的连接数峰值与累计连接数，供连接池测试取证。
const MockPoolServer = struct {
    allocator: std.mem.Allocator,
    addr: std.Io.net.IpAddress,
    /// 每条命令处理前的人为延迟（毫秒）。用于把连接占住，制造可观测的并发 / 池耗尽。
    delay_ms: u64 = 0,
    /// 第 N 条（从 1 起）连接在首个命令后回一个非法 RESP 帧并断开，模拟坏连接。
    poison_conn: ?usize = null,
    /// 第 N 条（从 1 起）连接在读到首个命令后**永不回包**（模拟 accept 之后卡死 /
    /// 被中间设备静默吞掉的服务端）。读超时用例专用。
    ///
    /// 兜底：即使客户端读超时失效，该连接也最多挂 `silent_hold_ms` 就主动断开
    /// （`stop` 置位时立即退出），因此用例只会「失败」而不会永久挂住。
    silent_conn: ?usize = null,
    silent_hold_ms: u64 = 3000,

    ready: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    /// 当前打开的连接数。
    active: std.atomic.Value(usize) = .init(0),
    /// 同时打开的最大连接数（并发峰值）。
    peak: std.atomic.Value(usize) = .init(0),
    /// 累计 accept 的连接数。
    accepted: std.atomic.Value(usize) = .init(0),

    fn start(self: *MockPoolServer) !std.Thread {
        return std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *MockPoolServer) !void {
        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var server = try self.addr.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        self.ready.store(true, .release);

        var store = Store.init(self.allocator);
        defer store.deinit();

        var conn_threads: std.ArrayListUnmanaged(std.Thread) = .empty;
        defer conn_threads.deinit(self.allocator);

        while (!self.stop.load(.acquire)) {
            const conn = server.accept(io) catch break;
            if (self.stop.load(.acquire)) {
                conn.close(io);
                break;
            }
            const index = self.accepted.fetchAdd(1, .monotonic) + 1;
            const now_active = self.active.fetchAdd(1, .acq_rel) + 1;
            self.notePeak(now_active);

            const t = std.Thread.spawn(.{}, serveConn, .{ self, io, conn, index, &store }) catch {
                _ = self.active.fetchSub(1, .acq_rel);
                conn.close(io);
                continue;
            };
            try conn_threads.append(self.allocator, t);
        }

        for (conn_threads.items) |t| t.join();
    }

    fn notePeak(self: *MockPoolServer, n: usize) void {
        var cur = self.peak.load(.monotonic);
        while (n > cur) {
            if (self.peak.cmpxchgWeak(cur, n, .monotonic, .monotonic)) |observed| {
                cur = observed;
            } else break;
        }
    }

    fn serveConn(self: *MockPoolServer, io: std.Io, conn: std.Io.net.Stream, conn_index: usize, store: *Store) void {
        defer _ = self.active.fetchSub(1, .acq_rel);
        defer conn.close(io);

        var read_buf: [1024]u8 = undefined;
        var write_buf: [1024]u8 = undefined;
        var reader = conn.reader(io, &read_buf);
        var writer = conn.writer(io, &write_buf);

        var first_command = true;
        while (true) {
            const args_opt = mockReadCommand(self.allocator, &reader) catch break;
            var args = args_opt orelse break;
            defer {
                for (args.items) |a| self.allocator.free(a);
                args.deinit(self.allocator);
            }
            if (args.items.len == 0) continue;

            if (self.delay_ms > 0) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(self.delay_ms)), .awake) catch {};
            }
            if (first_command) {
                first_command = false;
                if (self.poison_conn) |poisoned| {
                    if (poisoned == conn_index) {
                        // 非法 RESP 帧 + 立即断开：客户端必须识别为协议错误并丢弃该连接。
                        _ = writer.interface.writeAll("!not-a-resp-frame\r\n") catch {};
                        _ = writer.interface.flush() catch {};
                        return;
                    }
                }
                if (self.silent_conn) |silent| {
                    if (silent == conn_index) {
                        // 命令收下了，但**永不回包**：模拟服务端半死。
                        // 客户端必须靠读超时脱身；这里的等待只是兜底（见字段注释）。
                        var waited_ms: u64 = 0;
                        while (waited_ms < self.silent_hold_ms and !self.stop.load(.acquire)) : (waited_ms += 20) {
                            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
                        }
                        return;
                    }
                }
            }
            if (!mockHandleCommand(store, args.items, &writer)) break;
        }
    }
};

/// 结束多连接 mock 服务器：置位 stop，并主动连一次唤醒阻塞中的 accept，再 join。
fn stopPoolServer(srv: *MockPoolServer, thread: std.Thread) void {
    srv.stop.store(true, .release);
    const io = default_io.io();
    const conn = srv.addr.connect(io, .{ .mode = .stream }) catch {
        thread.join();
        return;
    };
    conn.close(io);
    thread.join();
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

/// 有界等待 mock 服务器就绪（最多 2 秒，避免服务器起不来时测试无限挂住）。
fn waitReady(ready: *std.atomic.Value(bool)) void {
    var i: usize = 0;
    while (!ready.load(.acquire)) : (i += 1) {
        if (i > 400) return;
        std.Io.sleep(default_io.io(), std.Io.Duration.fromMilliseconds(5), .awake) catch {};
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
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
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
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
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
    _ = Redis.poolStats;
    _ = Options;
    _ = PoolStats;
}

test "redis 多线程并发 set/get 不同 key 全部正确" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockRedisServer(allocator, addr, &ready);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
    });
    errdefer allocator.destroy(redis);
    errdefer redis.deinit();

    const THREADS = 8;
    const OPS = 20;

    const Worker = struct {
        fn run(client: *Redis, tid: usize) !void {
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
    for (threads, 0..) |*t, tid| t.* = try std.Thread.spawn(.{}, Worker.run, .{ redis, tid });
    for (threads) |t| t.join();

    // 先断开客户端连接（服务器读循环随之退出），再 join 服务器线程。
    redis.deinit();
    allocator.destroy(redis);
    thread.join();
}

test "redis 连接池：默认上限为 1，显式 0 也按 1 处理（兼容既有单连接行为）" {
    const allocator = std.testing.allocator;

    const defaults: Options = .{};
    try std.testing.expectEqual(@as(usize, 1), defaults.max_connections);
    try std.testing.expectEqual(@as(u64, 30_000), defaults.pool_timeout_ms);

    const port = try findFreePort();
    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockRedisServer(allocator, addr, &ready);
    while (!ready.load(.acquire)) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .max_connections = 0,
    });
    const c = redis.asCache();

    try c.set("clamp", "v", 60);
    const got = try c.get("clamp");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);

    const stats = redis.poolStats();
    try std.testing.expectEqual(@as(usize, 1), stats.live);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
    try std.testing.expectEqual(@as(usize, 1), stats.created);

    redis.deinit();
    allocator.destroy(redis);
    thread.join();
}

test "redis 连接池：max_connections>1 时多线程真并发（服务端观测峰值 > 1）" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    var srv: MockPoolServer = .{
        .allocator = allocator,
        .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        // 每条命令延迟 40ms：单连接串行时 4 线程无法重叠，连接池下必然重叠。
        .delay_ms = 40,
    };
    const server_thread = try srv.start();
    waitReady(&srv.ready);

    const MAX_CONNS: usize = 4;
    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .max_connections = MAX_CONNS,
        .pool_timeout_ms = 5_000,
    });
    errdefer allocator.destroy(redis);
    errdefer redis.deinit();

    const THREADS = MAX_CONNS;
    const OPS = 3;

    var go = std.atomic.Value(bool).init(false);
    var bad = std.atomic.Value(bool).init(false);

    const Worker = struct {
        fn run(client: *Redis, go_flag: *std.atomic.Value(bool), failed: *std.atomic.Value(bool), tid: usize) void {
            while (!go_flag.load(.acquire)) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < OPS) : (i += 1) {
                var key_buf: [32]u8 = undefined;
                var val_buf: [32]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "pk_{d}_{d}", .{ tid, i }) catch {
                    failed.store(true, .release);
                    return;
                };
                const val = std.fmt.bufPrint(&val_buf, "pv_{d}_{d}", .{ tid, i }) catch {
                    failed.store(true, .release);
                    return;
                };
                const c = client.asCache();
                c.set(key, val, 60) catch {
                    failed.store(true, .release);
                    return;
                };
                const got_opt = c.get(key) catch {
                    failed.store(true, .release);
                    return;
                };
                const got = got_opt orelse {
                    failed.store(true, .release);
                    return;
                };
                if (!std.mem.eql(u8, got, val)) {
                    failed.store(true, .release);
                    return;
                }
            }
        }
    };

    const threads = try allocator.alloc(std.Thread, THREADS);
    defer allocator.free(threads);
    for (threads, 0..) |*t, tid| t.* = try std.Thread.spawn(.{}, Worker.run, .{ redis, &go, &bad, tid });
    go.store(true, .release);
    for (threads) |t| t.join();

    try std.testing.expect(!bad.load(.acquire));

    const stats = redis.poolStats();
    const server_peak = srv.peak.load(.acquire);
    std.debug.print(
        "[redis pool] max_connections={d} server_peak_conns={d} client_peak_in_use={d} accepted={d}\n",
        .{ MAX_CONNS, server_peak, stats.peak_in_use, srv.accepted.load(.acquire) },
    );

    try std.testing.expect(server_peak > 1);
    try std.testing.expect(server_peak <= MAX_CONNS);
    try std.testing.expect(stats.peak_in_use > 1);
    try std.testing.expect(stats.peak_in_use <= MAX_CONNS);
    try std.testing.expectEqual(@as(usize, 0), stats.timeouts);

    redis.deinit();
    allocator.destroy(redis);
    stopPoolServer(&srv, server_thread);
}

test "redis 连接池：坏连接丢弃不进池，后续请求重建连接" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    var srv: MockPoolServer = .{
        .allocator = allocator,
        .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .poison_conn = 1,
    };
    const server_thread = try srv.start();
    waitReady(&srv.ready);

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .max_connections = 1,
        .pool_timeout_ms = 2_000,
    });
    errdefer allocator.destroy(redis);
    errdefer redis.deinit();

    const c = redis.asCache();

    // 首个请求撞上坏连接：必须失败，且该连接不能留在池中。
    try std.testing.expectError(error.StorageError, c.set("poisoned", "v", 60));
    const after_bad = redis.poolStats();
    try std.testing.expectEqual(@as(usize, 1), after_bad.discarded);
    try std.testing.expectEqual(@as(usize, 0), after_bad.idle);
    try std.testing.expectEqual(@as(usize, 0), after_bad.live);

    // 后续请求自动重建连接并成功（坏连接若被复用，这里会再次失败）。
    try c.set("poisoned", "v", 60);
    const got = try c.get("poisoned");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    try std.testing.expect(try c.isExist("poisoned"));

    // 全程只应建立 2 条连接：坏的那条 + 之后一直复用的那条。
    try std.testing.expectEqual(@as(usize, 2), srv.accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), redis.poolStats().live);

    redis.deinit();
    allocator.destroy(redis);
    stopPoolServer(&srv, server_thread);
}

test "redis 连接池：顺序请求复用连接，连接数不增长" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    var srv: MockPoolServer = .{
        .allocator = allocator,
        .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
    };
    const server_thread = try srv.start();
    waitReady(&srv.ready);

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .max_connections = 4,
        .pool_timeout_ms = 2_000,
    });
    errdefer allocator.destroy(redis);
    errdefer redis.deinit();

    const c = redis.asCache();
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "rk_{d}", .{i});
        try c.set(key, "v", 60);
        const got = try c.get(key);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("v", got.?);
        try std.testing.expect(try c.isExist(key));
    }

    const stats = redis.poolStats();
    try std.testing.expectEqual(@as(usize, 1), stats.created);
    try std.testing.expectEqual(@as(usize, 1), stats.live);
    try std.testing.expectEqual(@as(usize, 1), stats.idle);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
    try std.testing.expectEqual(@as(usize, 1), stats.peak_in_use);
    try std.testing.expectEqual(@as(usize, 0), stats.discarded);
    try std.testing.expectEqual(@as(usize, 1), srv.accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), srv.peak.load(.acquire));

    redis.deinit();
    allocator.destroy(redis);
    stopPoolServer(&srv, server_thread);
}

test "redis 连接池：池满等待超时返回 PoolTimeout 而非挂死" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    var srv: MockPoolServer = .{
        .allocator = allocator,
        .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        // 单条命令 2000ms，远大于下面的等待超时（余量刻意放大：
        // 并发负载下线程调度可能延迟数百毫秒，不能让断言依赖紧边界）。
        .delay_ms = 2000,
    };
    const server_thread = try srv.start();
    waitReady(&srv.ready);

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .max_connections = 1,
        .pool_timeout_ms = 150,
    });
    errdefer allocator.destroy(redis);
    errdefer redis.deinit();

    var holder_done = std.atomic.Value(bool).init(false);
    var holder_ok = std.atomic.Value(bool).init(true);

    const Holder = struct {
        fn run(client: *Redis, done: *std.atomic.Value(bool), ok: *std.atomic.Value(bool)) void {
            const c = client.asCache();
            c.set("holder", "v", 60) catch {
                ok.store(false, .release);
            };
            done.store(true, .release);
        }
    };
    const holder = try std.Thread.spawn(.{}, Holder.run, .{ redis, &holder_done, &holder_ok });

    // 等 holder 把唯一连接占住（占住后 `live` 立刻为 1）。
    // 上界给足 5s：并发负载下 holder 线程可能迟迟排不上 CPU。
    var waited: usize = 0;
    while (redis.poolStats().live == 0) {
        if (waited > 1000) break;
        waited += 1;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), redis.poolStats().live);

    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    const c = redis.asCache();
    try std.testing.expectError(error.StorageError, c.get("holder"));
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);

    // 超时是有界的：既真的等了（≥ 100ms，容调度误差），又没有等到 holder 跑完（2000ms）。
    try std.testing.expect(elapsed_ms >= 100);
    try std.testing.expect(elapsed_ms < 1500);
    try std.testing.expect(!holder_done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), redis.poolStats().timeouts);

    holder.join();
    try std.testing.expect(holder_ok.load(.acquire));

    // 连接归还后可继续复用。
    const got = try c.get("holder");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    const stats = redis.poolStats();
    try std.testing.expectEqual(@as(usize, 1), stats.live);
    try std.testing.expectEqual(@as(usize, 0), stats.discarded);

    redis.deinit();
    allocator.destroy(redis);
    stopPoolServer(&srv, server_thread);
}

test "redis 主机解析：IPv4/IPv6 字面量、域名与非法输入" {
    const io = default_io.io();

    // 走的是与 memcache 共用的 `net.resolveHost`（`net.zig` 另有直接单测）；
    // 这里额外证明本后端的接线（`Options.host` 这条路径用的就是它）。
    //
    // IPv4 字面量（改动前的唯一支持项，语义必须原样保留）。
    const v4 = try net.resolveHost(io, "127.0.0.1", 6379);
    try std.testing.expect(v4 == .ip4);
    try std.testing.expectEqual(@as(u16, 6379), v4.getPort());
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &v4.ip4.bytes);

    // IPv6 字面量：手写实现完全做不到，现在由 std 一步解析。
    const v6 = try net.resolveHost(io, "::1", 6379);
    try std.testing.expect(v6 == .ip6);
    try std.testing.expectEqual(@as(u16, 6379), v6.getPort());
    const v6_full = try net.resolveHost(io, "2001:db8::1", 6380);
    try std.testing.expect(v6_full == .ip6);
    try std.testing.expectEqual(@as(u16, 6380), v6_full.getPort());

    // 非法输入（含空格 / 下划线 → 连主机名都不合法）必须是明确的配置错误，
    // 而不是被当成地址或域名拿去做解析。
    try std.testing.expectError(error.InvalidAddress, net.resolveHost(io, "not a host", 6379));
    try std.testing.expectError(error.InvalidAddress, net.resolveHost(io, "bad_host", 6379));

    // 域名：走 std 的 HostName.lookup（DNS + /etc/hosts + RFC 6761 的 localhost）。
    // 名字解析依赖运行环境，离线容器里跳过，不让环境噪声污染用例。
    const by_name = net.resolveHost(io, "localhost", 6379) catch |err| switch (err) {
        error.UnknownHostName,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.ResolvConfParseFailed,
        error.DetectingNetworkConfigurationFailed,
        error.NetworkDown,
        => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(@as(u16, 6379), by_name.getPort());
}

test "redis 读超时：服务端不回包 → 有界失败、连接被丢弃、下次请求重建" {
    const allocator = std.testing.allocator;
    const port = try findFreePort();

    var srv: MockPoolServer = .{
        .allocator = allocator,
        .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        // 第 1 条连接读到命令后永不回包（服务端半死）；第 2 条正常服务。
        .silent_conn = 1,
        // 兜底：即使客户端读超时失效，服务端也会在这之后断开 —— 用例只会失败，
        // 不会把套件挂死。刻意放得远（8s）于下面 1.5s 的判定上界，好让判定
        // 只反映「客户端超时是否生效」，不受 CI 调度抖动影响。
        .silent_hold_ms = 8000,
    };
    const server_thread = try srv.start();
    waitReady(&srv.ready);

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .max_connections = 1,
        .pool_timeout_ms = 2_000,
        .recv_timeout_ms = 200,
    });
    errdefer allocator.destroy(redis);
    errdefer redis.deinit();

    const c = redis.asCache();

    // (a) 有界失败：必须在远早于服务端兜底断开（8000ms）之前报错，而不是挂死。
    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    try std.testing.expectError(error.StorageError, c.get("silent"));
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    std.debug.print("[redis recv timeout] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms >= 100); // 确实等过（不是被别的错误短路）
    try std.testing.expect(elapsed_ms < 5000); // 是客户端超时在起作用，不是服务端断开

    // (b) 超时连接被丢弃、不进池。
    const after = redis.poolStats();
    try std.testing.expectEqual(@as(usize, 1), after.discarded);
    try std.testing.expectEqual(@as(usize, 0), after.idle);
    try std.testing.expectEqual(@as(usize, 0), after.live);
    try std.testing.expectEqual(@as(usize, 0), after.timeouts); // 池等待没超时，是 socket 读超时

    // (c) 下一次请求重建连接并成功（若坏连接被复用，这里必然再次失败）。
    try c.set("after_timeout", "v", 60);
    const got = try c.get("after_timeout");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    try std.testing.expect(try c.isExist("after_timeout"));

    const stats = redis.poolStats();
    try std.testing.expectEqual(@as(usize, 2), stats.created); // 卡死的那条 + 重建的那条
    try std.testing.expectEqual(@as(usize, 1), stats.live);
    // 服务端只见过两条连接：卡死的那条 + c) 里重建的那条（坏连接没有被复用）。
    try std.testing.expectEqual(@as(usize, 2), srv.accepted.load(.acquire));

    redis.deinit();
    allocator.destroy(redis);
    stopPoolServer(&srv, server_thread);
}

test "redis 建连超时：SYN 被丢弃 → 有界失败、不建连接、同实例随后连正常地址成功" {
    const allocator = std.testing.allocator;
    const io = default_io.io();
    const port = try findFreePort();

    // 黑洞目标（本进程内的本地 listener，队列填满后内核丢 SYN）。
    // 造不出来（队列满即 RST 的环境）就跳过 —— 绝不用「可能永久阻塞」的地址硬测。
    var stall = (try makeStalledTarget(io, port)) orelse {
        std.debug.print("[redis connect timeout] 本环境造不出「SYN 被丢弃」的目标，跳过\n", .{});
        return error.SkipZigTest;
    };
    defer stall.deinit(io);

    const redis = try Redis.create(allocator, .{
        .host = "127.0.0.1",
        .port = port,
        .max_connections = 1,
        .pool_timeout_ms = 2_000,
        .connect_timeout_ms = 300,
    });
    errdefer allocator.destroy(redis);
    errdefer redis.deinit();

    const c = redis.asCache();

    // (a) 有界失败：必须在 [100ms, 5000ms) 内返回，而不是等内核的 SYN 重传兜底
    //     （Linux 默认 ≈ 127s、macOS ≈ 75s）。
    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    try std.testing.expectError(error.StorageError, c.get("never"));
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    std.debug.print("[redis connect timeout] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms >= 100); // 确实等到了 deadline，不是被别的错误短路
    try std.testing.expect(elapsed_ms < 5000); // 是客户端 deadline 在起作用，不是内核兜底

    // (b) 超时的连接**没有被创建**，自然也没有进池。
    const after = redis.poolStats();
    try std.testing.expectEqual(@as(usize, 0), after.created);
    try std.testing.expectEqual(@as(usize, 0), after.live);
    try std.testing.expectEqual(@as(usize, 0), after.idle);
    try std.testing.expectEqual(@as(usize, 0), after.in_use);
    try std.testing.expectEqual(@as(usize, 0), after.discarded);
    try std.testing.expectEqual(@as(usize, 0), after.timeouts); // 池等待没超时，是建连超时

    // (c) 同一个实例、同一个地址：黑洞下线（端口腾出来）后换成正常服务端，
    //     下一次请求必须建连成功并正常工作。
    stall.closeListener(io);
    var ready = std.atomic.Value(bool).init(false);
    const server_thread = try mockRedisServer(allocator, stall.addr, &ready);
    waitReady(&ready);
    // 端口没抢回来时这里立刻失败（否则会以「连接被拒」的形式误导排查方向）。
    try std.testing.expect(ready.load(.acquire));

    try c.set("after_connect_timeout", "v", 60);
    const got = try c.get("after_connect_timeout");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    try std.testing.expect(try c.isExist("after_connect_timeout"));

    // 全程只成功建立了一条连接：超时那条根本没被创建（`created` 就是证据）。
    const stats = redis.poolStats();
    try std.testing.expectEqual(@as(usize, 1), stats.created);
    try std.testing.expectEqual(@as(usize, 1), stats.live);
    try std.testing.expectEqual(@as(usize, 1), stats.idle);
    try std.testing.expectEqual(@as(usize, 0), stats.discarded);

    redis.deinit();
    allocator.destroy(redis);
    server_thread.join();
}
