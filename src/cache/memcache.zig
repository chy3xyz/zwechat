// SPDX-License-Identifier: Apache-2.0
//! cache/memcache — 最小 Memcache 缓存实现
//!
//! 对应 `_ref/wechat/cache/memcache.go`：通过 Memcache 文本协议与服务器通信，
//! 提供 `Cache` vtable 兼容的 get / set / isExist / delete / deinit。
//!
//! 设计取舍：
//! - **默认单连接，可选连接池**（`Options.max_connections`，默认 `1`）。默认值等价于
//!   历史行为：一条连接由 `std.Io.Mutex`（真阻塞的 futex 锁）串行化整个请求-响应
//!   往返，多线程并发安全，等待者阻塞在内核 futex 上而不空转烧 CPU。设为 `N > 1`
//!   时启用连接池，形状与 `redis.zig` 一致（`max_connections` / `pool_timeout_ms` /
//!   `PoolStats` / `poolStats`）：最多 N 条连接并行服务 N 个并发调用，吞吐不再被
//!   1/RTT 卡住。
//! - **单连接模式的字段与代码路径保持原样**：`max_connections == 1`（默认）时仍然
//!   使用 `stream` / `reader` / `timeout_reader` / `writer` / `mutex` 这组字段与原来
//!   的实现，行为逐字一致；池只在 `max_connections > 1` 时启用。因此 `poolStats()`
//!   在单连接模式下恒为零 —— 那个模式里没有池。
//! - **池锁只保护空闲表与计数器**：建连、请求-响应往返、`close` 全部在池锁之外。
//! - **等待有上界**：池已满时调用方在锁外「短自旋 + 小睡」等待归还，超过
//!   `Options.pool_timeout_ms` 返回 `error.PoolTimeout`（vtable 边界映射为
//!   `CacheError.StorageError`，并计入 `poolStats().timeouts`）。永远不挂死。
//! - **坏连接不进池**：读写失败 / 协议解析失败的连接已经失步，直接关闭丢弃，
//!   下次取连接时重建，绝不会污染后续请求。
//! - `get` 返回的切片借用自当前连接的值缓冲（单连接模式即 `Memcache.last_value`），
//!   调用方应在下一次缓存操作（含其它线程的）之前使用；跨操作持有必须 `dupe`。
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

/// 等待可用连接时的退避参数（与 `redis.zig` 的同名常量取值一致）：先自旋
/// `WaitSpinRounds` 轮（低延迟路径），之后每轮小睡 `WaitSleepNs`（避免烧 CPU）。
const WaitSpinRounds: usize = 512;
const WaitSleepNs: i96 = 200_000;

/// 取连接可能返回的错误（仅池模式）。
const PoolError = error{ PoolTimeout, OutOfMemory, StorageError };

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
    ///   默认单连接模式持锁跨整次往返，所以建连卡住 = 所有调用方一起卡住；
    ///   池模式下建连在池锁之外进行，只卡住本次调用（但它占住的槽位仍不可用）；
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

    /// 连接池上限：同时存活的最大连接数。
    ///
    /// - 默认 `1`，与历史单连接实现完全等价（既有调用点无需改动，内部字段
    ///   `stream` / `reader` / `timeout_reader` / `writer` 与 `mutex` 语义不变）；
    /// - `0` 会被钳制为 `1`（避免出现永远取不到连接的池）；
    /// - `N > 1` 时启用连接池（与 `redis.zig` 同一形状），最多 N 个请求并行；
    ///   超出部分排队等待归还。
    max_connections: usize = 1,

    /// 等待空闲连接的最长时间（毫秒），默认 30000。
    ///
    /// 语义（仅在 `max_connections > 1` 时生效）：
    /// - 池未达上限时直接新建连接返回，**不等待**；
    /// - 池已满时在**不持池锁**的前提下自旋 + 小睡重试，直到有连接归还；
    /// - 超过本时长仍无可用连接则放弃本次操作：`acquire` 返回 `error.PoolTimeout`，
    ///   vtable 边界映射为 `CacheError.StorageError` 并打印 warn 日志，同时
    ///   `Memcache.poolStats().timeouts` 自增 —— 等待一定是**有界**的，不会挂死；
    /// - `0` 表示不等待（池满即刻超时）。
    pool_timeout_ms: u64 = 30_000,
};

/// 连接池运行观测数据（用于监控与测试取证）。
///
/// 形状与 `redis.zig` 的 `PoolStats` 一致，便于两套后端用同一套监控口径。
/// **注意**：`max_connections == 1`（默认单连接模式）没有池，`poolStats()` 返回
/// 全零（详见 `Memcache.poolStats` 的说明）。
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

/// Memcache 缓存实现。
///
/// 调用方通过 `create(allocator, opts)` 构造，使用 `asCache()` 获得 vtable 句柄，
/// 最终调用 `deinit()` 再 `allocator.destroy(self)` 释放。
///
/// `max_connections > 1` 时，池中的每条连接就是一个「单连接实例」
/// （`max_connections == 1` 的 `Memcache`）：文本协议与建连，因此**只有一份实现**，
/// 池本身只负责借出 / 归还与计数。
pub const Memcache = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    io: std.Io,
    /// 当 `opts.io` 未提供时，本字段持有自行创建的 `Io` 实例。
    owned_io: ?std.Io.Threaded,
    // ---------------- 单连接模式（`max_connections == 1`）的连接状态 ----------------
    // 池模式下这些字段由各池连接实例自持，外壳的这一份保持 null / 未使用。
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
    /// 单连接互斥（**仅在 `max_connections == 1` 的默认模式下使用**）：共享 TCP
    /// 连接 + 共享 reader/writer/缓冲区，必须串行化整个请求-响应往返，否则多线程
    /// 并发会交错写 socket（协议损坏）。
    ///
    /// **刻意持锁跨网络 I/O**（含 `ensureConnected` + 写 socket + 读完整个回复，
    /// 一整个 RTT）：共享单连接的文本协议无法把一次往返拆成多段临界区。
    /// 这里用真阻塞的 `std.Io.Mutex`，等待者在 futex 上睡眠而不是自旋，
    /// 锁被占满一个 RTT 时不再浪费 CPU（`self.io` 驱动等待 / 唤醒）。
    /// 池模式下（`max_connections > 1`）每条连接由借用方独占，用的是另一个锁
    /// `pool_mutex`（只保护空闲表与计数，不覆盖任何 I/O）。
    mutex: std.Io.Mutex = .init,

    // ---------------- 连接池状态（`max_connections > 1` 时使用） ----------------
    /// 生效的池上限（`opts.max_connections == 0` 时按 1 处理）。
    max_connections: usize,
    /// 池锁。临界区只包含「空闲表操作 + 计数更新」，**绝不包含** connect/close /
    /// 读写 socket 等任何网络 I/O；否则池会退化回单连接串行。真阻塞的
    /// `std.Io.Mutex`（`self.io` 驱动 futex 等待 / 唤醒）。
    pool_mutex: std.Io.Mutex = .init,
    /// 空闲（已建连、可立即复用）连接。容量在 `create` 时预留到 `max_connections`，
    /// 因此池锁内的临界区不会发生堆分配。
    idle: std.ArrayList(*Memcache) = .empty,
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

    pub fn create(allocator: std.mem.Allocator, opts: Options) !*Memcache {
        const self = try allocator.create(Memcache);
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
            .stream = null,
            .read_buffer = undefined,
            .write_buffer = undefined,
            .reader = null,
            .writer = null,
            .last_value = null,
            .max_connections = if (opts.max_connections == 0) 1 else opts.max_connections,
        };
        if (self.owned_io) |*t| {
            self.io = t.io();
        }
        // 空闲表容量一次预留到位：后续 append 不再分配，池锁内的临界区保持「纯内存」。
        try self.idle.ensureTotalCapacity(allocator, self.max_connections);
        return self;
    }

    pub fn deinit(self: *Memcache) void {
        // 池模式：关闭所有空闲连接（close 是系统调用，逐个在池锁之外执行）。
        // 调用方需保证此时没有进行中的操作。
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

        // 单连接模式：断开自持的连接并释放借用缓冲（池模式下这两个字段恒为空）。
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

    /// 连接池运行统计快照（加锁读取，临界区内无 I/O）。
    ///
    /// **`max_connections == 1`（默认单连接模式）没有池，恒返回全零**：该模式走的
    /// 是历史单连接路径（`stream` / `reader` / `mutex` 那组字段），池计数器不参与；
    /// 也刻意不在池锁之外去读连接状态（那是数据竞争）。需要池级可观测性时把
    /// `max_connections` 设为 `> 1`。
    pub fn poolStats(self: *Memcache) PoolStats {
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

    // ---------------- vtable 实现 ----------------
    //
    // 两条路径共用同一份协议实现（`getConn` / `setConn` / `isExistConn` /
    // `deleteConn`，都只依赖连接字段）：
    // - `max_connections == 1`（默认）：锁住 `mutex` 后在自持连接上执行（历史行为）；
    // - `max_connections > 1`：向池借用一条连接（它本身就是一个单连接实例）执行，
    //   出错即标记 `reusable = false`，由 `release` 丢弃，绝不把坏连接放回池中。

    const vtable: Cache.VTable = .{
        .get = getImpl,
        .set = setImpl,
        .isExist = isExistImpl,
        .delete = deleteImpl,
        .deinit = deinitImpl,
        .getOwned = getOwnedImpl,
    };

    fn getImpl(ctx: *anyopaque, key: []const u8) CacheError!?[]const u8 {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        if (!self.pooled()) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.getConn(key);
        }
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);
        const value = conn.getConn(key) catch |err| {
            reusable = false;
            return err;
        };
        return value;
    }

    /// `getOwned` 的实现：拷贝在**本后端自己的互斥区**内完成。
    ///
    /// - 单连接模式（默认）：整个请求-响应往返都在 `mutex` 临界区内，拷贝也在其中，
    ///   因此 `last_value` 不可能被别名（其它线程 / 共享本实例的模块）提前释放；
    /// - 池模式：拷贝发生在**独占借用该连接**的期间，借出方独占该连接的
    ///   `last_value`，拷贝完成才归还。
    fn getOwnedImpl(ctx: *anyopaque, allocator: std.mem.Allocator, key: []const u8) CacheError!?[]u8 {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        if (!self.pooled()) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const value = try self.getConn(key);
            const v = value orelse return null;
            return allocator.dupe(u8, v) catch return error.OutOfMemory;
        }
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);
        const value = conn.getConn(key) catch |err| {
            reusable = false;
            return err;
        };
        const v = value orelse return null;
        return allocator.dupe(u8, v) catch return error.OutOfMemory;
    }

    fn setImpl(ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        if (!self.pooled()) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.setConn(key, val, ttl_seconds);
        }
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);
        conn.setConn(key, val, ttl_seconds) catch |err| {
            reusable = false;
            return err;
        };
    }

    fn isExistImpl(ctx: *anyopaque, key: []const u8) CacheError!bool {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        if (!self.pooled()) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.isExistConn(key);
        }
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);
        return conn.isExistConn(key) catch |err| {
            reusable = false;
            return err;
        };
    }

    fn deleteImpl(ctx: *anyopaque, key: []const u8) CacheError!void {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        if (!self.pooled()) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.deleteConn(key);
        }
        const conn = try self.acquireForOp();
        var reusable = true;
        defer self.release(conn, reusable);
        conn.deleteConn(key) catch |err| {
            reusable = false;
            return err;
        };
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Memcache = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    // -------- 单连接上的协议操作（互斥 / 池的借还与丢弃由调用方负责） --------

    /// 在**一条连接**上执行 GET。调用方保证该连接此刻由自己独占。
    ///
    /// 任何错误都会断开这条连接（`errdefer`）：文本协议无法确认失败后是否留下
    /// 半条回复，复用比断连危险得多。
    fn getConn(self: *Memcache, key: []const u8) CacheError!?[]const u8 {
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

    fn setConn(self: *Memcache, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void {
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        // exptime 是 u32；ttl_seconds 来自外部输入（如微信响应的 expires_in），
        // 超过 u32 上限（如 i64 max）时 @intCast 会在 Debug 下 panic，这里钳制到上限。
        const exp: u32 = if (ttl_seconds > 0)
            @intCast(@min(ttl_seconds, std.math.maxInt(u32)))
        else
            0;
        var header_buf: [256]u8 = undefined;
        const header = std.mem.print(&header_buf, "set {s} 0 {d} {d}\r\n", .{ key, exp, val.len }) catch return error.StorageError;
        self.sendCommandRaw(header, val) catch return error.StorageError;

        const line = self.readLine() catch return error.StorageError;
        if (!std.mem.eql(u8, line, "STORED")) return error.StorageError;
    }

    fn isExistConn(self: *Memcache, key: []const u8) CacheError!bool {
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

    fn deleteConn(self: *Memcache, key: []const u8) CacheError!void {
        errdefer self.disconnect();
        self.ensureConnected() catch return error.StorageError;

        self.sendCommand("delete ", key, null) catch return error.StorageError;
        const line = self.readLine() catch return error.StorageError;
        if (!std.mem.eql(u8, line, "DELETED") and !std.mem.eql(u8, line, "NOT_FOUND")) {
            return error.StorageError;
        }
    }

    // ---------------- 连接池（`max_connections > 1`） ----------------

    /// 是否启用连接池。
    fn pooled(self: *const Memcache) bool {
        return self.max_connections > 1;
    }

    /// 借出一条池连接。**不得**在持有 `pool_mutex` 时调用；内部只在极短的临界区里
    /// 持锁，建连与归还的 `close` 都在锁外。
    ///
    /// - 池中有空闲连接：立即借出；
    /// - 池未达上限：先占槽位（锁内），再在**锁外**建连；
    /// - 池已满：在**锁外**自旋 + 小睡等待归还，超过 `opts.pool_timeout_ms`
    ///   返回 `error.PoolTimeout`（等待有界，不会永久挂死）。
    ///
    /// 借用方用完必须调用 `release` 归还（或标记为不可用以便丢弃）。
    fn acquire(self: *Memcache) PoolError!*Memcache {
        const timeout_ns = self.timeoutNs();
        const start_ns = self.nowNs();
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
            if (timeout_ns == 0 or self.nowNs() - start_ns >= timeout_ns) {
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
    ///
    /// 归还后调用方**不得**再使用自己从该连接上拿到的借用切片（`get` 的返回值）：
    /// 其它线程可能立刻复用它。与 `redis.zig` 的生命周期契约一致。
    fn release(self: *Memcache, conn: *Memcache, reusable: bool) void {
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
    fn discardConn(self: *Memcache, conn: *Memcache) void {
        self.freeConn(conn);
        self.pool_mutex.lockUncancelable(self.io);
        self.live -= 1;
        self.discarded_total += 1;
        self.pool_mutex.unlock(self.io);
    }

    /// 关闭并释放一条连接（不维护 `live` 计数）。不加池锁。
    fn freeConn(self: *Memcache, conn: *Memcache) void {
        conn.deinit();
        self.allocator.destroy(conn);
    }

    /// 更新「借出中」峰值。必须在持有 `pool_mutex` 时调用。
    fn noteBorrowLocked(self: *Memcache) void {
        const in_use = self.live - self.idle.items.len;
        if (in_use > self.peak_in_use) self.peak_in_use = in_use;
    }

    /// `opts.pool_timeout_ms` 换算为纳秒（饱和，避免溢出）。
    fn timeoutNs(self: *Memcache) i64 {
        const ms = self.opts.pool_timeout_ms;
        if (ms == 0) return 0;
        const ns = ms *| std.time.ns_per_ms;
        if (ns > @as(u64, @intCast(std.math.maxInt(i64)))) return std.math.maxInt(i64);
        return @intCast(ns);
    }

    /// 当前单调时钟纳秒时间戳。
    ///
    /// 用 `awake` 时钟（与 `redis.zig` 一致）：它只服务池的**等待耗时**判定
    /// （`pool_timeout_ms`），要的是「进程实际等了多久」；休眠期间进程不跑，不该
    /// 算进等待额度。首尾同源，绝不与 `boot` 混用。用实例自己的 `io` 而非全局
    /// 单例，保证与注入的 Io 一致。
    fn nowNs(self: *Memcache) i64 {
        return @intCast(std.Io.Clock.now(.awake, self.io).nanoseconds);
    }

    /// 创建一条池连接（一个 `max_connections == 1` 的单连接实例）并立即建连。
    /// **不得**在持有 `pool_mutex` 时调用。
    ///
    /// 建连失败的连接既不进池也不计入 `created`（与 `redis.zig` 的池一致）：
    /// 半开的连接没有任何复用价值。
    fn createConn(self: *Memcache) PoolError!*Memcache {
        // 池连接的 opts 与外壳一致，唯一区别是它自己是单连接实例（否则会递归建池），
        // 并复用外壳的 `io`（避免每条连接各起一个运行时）。
        var conn_opts = self.opts;
        conn_opts.max_connections = 1;
        conn_opts.io = self.io;

        const conn = Memcache.create(self.allocator, conn_opts) catch return error.OutOfMemory;
        errdefer {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        conn.ensureConnected() catch return error.StorageError;
        return conn;
    }

    /// 借出连接并把池错误映射到 `CacheError`（`PoolTimeout` 会打印 warn 并计数）。
    fn acquireForOp(self: *Memcache) CacheError!*Memcache {
        return self.acquire() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PoolTimeout => {
                log.warn(
                    "memcache 连接池等待超时：max_connections={d}, pool_timeout_ms={d}，放弃本次操作",
                    .{ self.max_connections, self.opts.pool_timeout_ms },
                );
                return error.StorageError;
            },
            error.StorageError => return error.StorageError,
        };
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
    const colon = std.mem.findScalarLast(u8, server, ':') orelse return error.InvalidAddress;
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
            var server = try addr.listen(io, .{ .reuse_address = false });
            rdy.store(true, .release);
            defer server.deinit(io);

            var store = Store.init(alloc, io);
            defer store.deinit();

            const conn = try server.accept(io);
            defer conn.close(io);
            try serveMemcacheConn(alloc, io, conn, &store, 0, false);
        }
    }.run, .{ allocator, bind_addr, ready });
}

/// mock 服务器共享的 KV。
///
/// 多连接并发访问，因此每个操作都在自己的小锁内（临界区纯内存，不含 socket I/O）；
/// `getCopy` 把值拷进调用方缓冲，让调用方在**不持锁**的情况下写 socket。
const Store = struct {
    /// 单条 value 的拷贝缓冲上限（用例里的值都很短）；超限按未命中处理 —— 这是夹具，
    /// 不为超大值再分配。
    const max_value_bytes = 256;

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    map: std.HashMap([]const u8, []u8, std.hash_map.StringContext, 80),

    fn init(allocator: std.mem.Allocator, io: std.Io) Store {
        return .{ .allocator = allocator, .io = io, .map = .init(allocator) };
    }

    fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// 写入（覆盖旧值）；键与值都由 Store 自己拷一份持有。
    fn set(self: *Store, key: []const u8, val: []const u8) !void {
        // 先拷贝再进锁：锁里不分配，也不会持锁跨越分配失败路径。
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, val);
        errdefer self.allocator.free(v);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.map.put(k, v);
    }

    /// 把命中的值**拷贝**进 `out` 并返回切片；未命中返回 `null`。
    fn getCopy(self: *Store, key: []const u8, out: []u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const val = self.map.get(key) orelse return null;
        if (val.len > out.len) return null;
        @memcpy(out[0..val.len], val);
        return out[0..val.len];
    }

    /// 删除；返回是否命中。
    fn delete(self: *Store, key: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
            return true;
        }
        return false;
    }
};

/// 按文本协议服务一条连接，直到对端断开（或读到非法帧）。
///
/// - `store`：服务器共享的 KV（多连接并发访问；读写都在 `Store` 自己的小锁内）；
/// - `delay_ms > 0`：每条命令处理前先睡一会儿 —— 连接池用例用它把连接占住，
///   制造可观测的并发 / 池耗尽；
/// - `poison_on_first`：第一条命令（含 `set` 的 value 行）之后回一帧非法响应并断开，
///   模拟「连得上、但协议坏掉」的连接。
fn serveMemcacheConn(
    alloc: std.mem.Allocator,
    io: std.Io,
    conn: std.Io.net.Stream,
    store: *Store,
    delay_ms: u64,
    poison_on_first: bool,
) !void {
    var read_buf: [1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var writer = conn.writer(io, &write_buf);

    var first = true;
    while (true) {
        const line = mockReadLine(alloc, &reader) catch break;
        defer alloc.free(line);
        if (line.len == 0) continue;

        if (delay_ms > 0) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
        }

        var it = std.mem.splitScalar(u8, line, ' ');
        const cmd = it.next().?;

        if (std.mem.eql(u8, cmd, "get")) {
            const key = it.next() orelse continue;
            if (first) {
                first = false;
                if (poison_on_first) {
                    poisonReply(&writer);
                    return;
                }
            }
            var val_buf: [Store.max_value_bytes]u8 = undefined;
            if (store.getCopy(key, &val_buf)) |val| {
                try writer.interface.print("VALUE {s} 0 {d}\r\n", .{ key, val.len });
                try writer.interface.writeAll(val);
                try writer.interface.writeAll("\r\n");
            }
            _ = writer.interface.writeAll("END\r\n") catch break;
        } else if (std.mem.eql(u8, cmd, "set")) {
            // 先按协议把命令头与 value 行读干净，再决定回什么：留下未读字节会让
            // 后续交互（以及坏连接用例里的客户端）看到错位的帧。
            const key = it.next() orelse continue;
            _ = it.next(); // flags
            _ = it.next(); // exptime
            const bytes_str = it.next() orelse continue;
            const bytes = std.fmt.parseInt(usize, bytes_str, 10) catch continue;
            const raw = try alloc.alloc(u8, bytes + 2);
            defer alloc.free(raw);
            try reader.interface.readSliceAll(raw);
            if (raw[bytes] != '\r' or raw[bytes + 1] != '\n') continue;

            if (first) {
                first = false;
                if (poison_on_first) {
                    poisonReply(&writer);
                    return;
                }
            }
            try store.set(key, raw[0..bytes]);
            _ = writer.interface.writeAll("STORED\r\n") catch break;
        } else if (std.mem.eql(u8, cmd, "delete")) {
            const key = it.next() orelse continue;
            if (first) {
                first = false;
                if (poison_on_first) {
                    poisonReply(&writer);
                    return;
                }
            }
            // 语义修正：删除成功返回 DELETED，键不存在返回 NOT_FOUND。
            // （旧实现先 fetchRemove 再反查 contains，导致永远返回 DELETED。）
            const resp: []const u8 = if (store.delete(key)) "DELETED\r\n" else "NOT_FOUND\r\n";
            _ = writer.interface.writeAll(resp) catch break;
        }
        try writer.interface.flush();
    }
}

/// 回一帧不符合文本协议的响应（坏连接夹具）；调用方随后立即退出服务循环。
fn poisonReply(writer: *std.Io.net.Stream.Writer) void {
    _ = writer.interface.writeAll("BOGUS\r\n") catch {};
    writer.interface.flush() catch {};
}

/// 多连接 mock 服务器：并发接受连接（每条连接一个服务线程）、共享同一份 KV，
/// 并统计同时打开的连接数峰值与累计连接数，供连接池用例取证。
///
/// `stopAndJoin()` 置位 `stop`、主动连一次唤醒阻塞中的 `accept`，再 `join`。
const MockPoolServer = struct {
    allocator: std.mem.Allocator,
    addr: std.Io.net.IpAddress,
    /// 每条命令处理前的人为延迟（毫秒）：把连接占住，制造可观测的并发 / 池耗尽。
    delay_ms: u64 = 0,
    /// 第 N 条（从 1 起）连接在首个命令后回一帧非法响应并断开（坏连接）。
    poison_conn: ?usize = null,

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

        // 假 server 刻意不用 `reuse_address`：POSIX 上它同时打开 `SO_REUSEPORT`，
        // 会让多个测试进程把同一端口分摊掉（其中一个的 accept 永远等不到请求）。
        var server = try self.addr.listen(io, .{ .reuse_address = false });
        defer server.deinit(io);
        self.ready.store(true, .release);

        var store = Store.init(self.allocator, io);
        defer store.deinit();

        var conn_threads: std.ArrayList(std.Thread) = .empty;
        defer conn_threads.deinit(self.allocator);

        while (!self.stop.load(.acquire)) {
            const conn = server.accept(io) catch break;
            if (self.stop.load(.acquire)) {
                conn.close(io);
                break;
            }
            const index = self.accepted.fetchAdd(1, .monotonic) + 1;
            self.notePeak(self.active.fetchAdd(1, .acq_rel) + 1);

            const t = std.Thread.spawn(.{}, serveOne, .{ self, io, conn, index, &store }) catch {
                _ = self.active.fetchSub(1, .acq_rel);
                conn.close(io);
                continue;
            };
            try conn_threads.append(self.allocator, t);
        }

        for (conn_threads.items) |t| t.join();
    }

    fn serveOne(self: *MockPoolServer, io: std.Io, conn: std.Io.net.Stream, index: usize, store: *Store) void {
        defer _ = self.active.fetchSub(1, .acq_rel);
        defer conn.close(io);
        const poisoned = if (self.poison_conn) |p| p == index else false;
        serveMemcacheConn(self.allocator, io, conn, store, self.delay_ms, poisoned) catch {};
    }

    fn notePeak(self: *MockPoolServer, n: usize) void {
        var cur = self.peak.load(.monotonic);
        while (n > cur) {
            if (self.peak.cmpxchgWeak(cur, n, .monotonic, .monotonic)) |observed| {
                cur = observed;
            } else break;
        }
    }

    fn stopAndJoin(self: *MockPoolServer, thread: std.Thread) void {
        self.stop.store(true, .release);
        const io = default_io.io();
        if (self.addr.connect(io, .{ .mode = .stream })) |wake| {
            wake.close(io);
        } else |_| {}
        thread.join();
    }
};

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
            var server = try addr.listen(io, .{ .reuse_address = false });
            rdy.store(true, .release);
            defer server.deinit(io);

            var handlers: std.ArrayList(std.Thread) = .empty;
            defer handlers.deinit(alloc);

            var store = Store.init(alloc, io);
            defer store.deinit();

            var index: usize = 0;
            while (!stopper.load(.acquire)) {
                const conn = server.accept(io) catch break;
                if (stopper.load(.acquire)) {
                    conn.close(io);
                    break;
                }
                index += 1;
                const t = std.Thread.spawn(.{}, handleConn, .{ alloc, io, conn, index, hold_ms, stopper, &store }) catch {
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
            store: *Store,
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
            serveMemcacheConn(alloc, io, conn, store, 0, false) catch {};
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

// 端口分配夹具已收敛到 `net.findFreePort()`（`net.zig`）：本文件不再持有私有副本 ——
// 旧的「随机挑端口 + `listen(reuse_address = true)` 探测」既会和其它测试进程撞端口，
// 又因 `SO_REUSEPORT` 让探测结果失去意义（详见 `net.findFreePort` 的文档）。

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
        .server = try addr.listen(io, .{ .reuse_address = false, .kernel_backlog = 1 }),
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
    const port = try net.findFreePort();

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
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});

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
    const port = try net.findFreePort();

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
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});

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

test "memcache getOwned：单连接与池模式下副本都独立于 last_value" {
    // 回归（OPEN_ITEMS 第 15 条）：Memcache 的 `get` 返回的切片借用自
    // `last_value`，**任何**后续 get 都会 free 并覆盖它。`getOwned` 必须在
    // 本后端的临界区（单连接 = `mutex` 内；池 = 独占借用连接期间）完成拷贝。
    const allocator = std.testing.allocator;

    for ([_]usize{ 1, 2 }) |max_conns| {
        const port = try net.findFreePort();
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
        const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});

        const mc = try Memcache.create(allocator, .{
            .server = server_str,
            .max_connections = max_conns,
            .pool_timeout_ms = 2_000,
        });
        const c = mc.asCache();

        try c.set("tok", "original_token_value", 60);

        const copy = (try c.getOwned(allocator, "tok")) orelse return error.TestUnexpectedResult;
        defer allocator.free(copy);
        try std.testing.expectEqualStrings("original_token_value", copy);

        // 副本不是连接内部的值缓冲。
        const borrowed = (try c.get("tok")).?;
        try std.testing.expect(copy.ptr != borrowed.ptr);

        // 覆盖写、读别的 key（会 free 掉 `last_value`）、删除：副本都必须完好。
        try c.set("tok", "replaced_token_value_longer_than_the_original", 60);
        try std.testing.expectEqualStrings("original_token_value", copy);
        try std.testing.expect((try c.get("unrelated")) == null);
        try std.testing.expectEqualStrings("original_token_value", copy);
        try c.delete("tok");
        try std.testing.expectEqualStrings("original_token_value", copy);

        // 未命中返回 null。
        try std.testing.expect((try c.getOwned(allocator, "tok")) == null);

        mc.deinit();
        allocator.destroy(mc);
        thread.join();
    }
}

test "memcache set 超大 TTL 不触发 @intCast panic" {
    // 回归：ttl_seconds 来自外部输入，超过 u32 上限（exptime 字段宽度）时
    // 旧实现 `if (ttl_seconds > 0) @intCast(ttl_seconds)` 在 Debug 下 panic；
    // 修复后钳制到 u32 上限照常写入。
    const allocator = std.testing.allocator;
    const port = try net.findFreePort();

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
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});

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
    const port = try net.findFreePort();

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
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});

    const mc = try Memcache.create(allocator, .{ .server = server_str });
    errdefer allocator.destroy(mc);
    errdefer mc.deinit();

    const THREADS = 8;
    const OPS = 20;

    const Worker = struct {
        /// 同 `redis` 侧：签名必须是 `void` —— `std.Thread.spawn` 对返回 error union 的线程
        /// 函数只打印错误名然后丢弃，`join()` 观察不到失败，因此走原子标志。
        fn run(client: *Memcache, tid: usize, go_flag: *std.atomic.Value(bool), failed: *std.atomic.Value(bool)) void {
            while (!go_flag.load(.acquire)) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < OPS) : (i += 1) {
                var key_buf: [32]u8 = undefined;
                var val_buf: [32]u8 = undefined;
                const key = std.mem.print(&key_buf, "wk_{d}_{d}", .{ tid, i }) catch {
                    failed.store(true, .release);
                    return;
                };
                const val = std.mem.print(&val_buf, "val_{d}_{d}", .{ tid, i }) catch {
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
                // get 返回借用切片，必须在下一次缓存操作前比较。
                if (!std.mem.eql(u8, got, val)) {
                    failed.store(true, .release);
                    return;
                }
            }
        }
    };

    var go = std.atomic.Value(bool).init(false);
    var bad = std.atomic.Value(bool).init(false);
    const threads = try allocator.alloc(std.Thread, THREADS);
    defer allocator.free(threads);
    for (threads, 0..) |*t, tid| t.* = try std.Thread.spawn(.{}, Worker.run, .{ mc, tid, &go, &bad });
    go.store(true, .release);
    for (threads) |t| t.join();

    // 回归：此前 worker 是 `!void`，错误被 spawn 吞掉，本测试**永远不可能失败**
    // （连"并发读到的值对不对"都没验，只验了锁没泄漏）。
    try std.testing.expect(!bad.load(.acquire));

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
    const port = try net.findFreePort();

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
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});

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
    const port = try net.findFreePort();

    // 黑洞目标（本进程内的本地 listener，队列填满后内核丢 SYN）。
    // 造不出来（队列满即 RST 的环境）就跳过 —— 绝不用「可能永久阻塞」的地址硬测。
    var stall = (try makeStalledTarget(io, port)) orelse {
        std.debug.print("[memcache connect timeout] 本环境造不出「SYN 被丢弃」的目标，跳过\n", .{});
        return error.SkipZigTest;
    };
    defer stall.deinit(io);

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});

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

test "memcache 畸形文本帧返回 StorageError 并断开连接（不崩溃）" {
    const allocator = std.testing.allocator;

    // 脚本化服务器：读走客户端命令（`set` 多读一行 value），再回一帧不符合文本协议的
    // 响应（既不是 `VALUE`/`END`，也不是 `STORED`/`DELETED`）。
    const MalformedServer = struct {
        fn run(
            alloc: std.mem.Allocator,
            addr: std.Io.net.IpAddress,
            rdy: *std.atomic.Value(bool),
            conns: usize,
            frame: []const u8,
        ) !void {
            var threaded = std.Io.Threaded.init(alloc, .{});
            defer threaded.deinit();
            const io = threaded.io();
            var server = try addr.listen(io, .{ .reuse_address = false });
            rdy.store(true, .release);
            defer server.deinit(io);

            for (0..conns) |_| {
                const conn = server.accept(io) catch break;
                defer conn.close(io);

                var read_buf: [512]u8 = undefined;
                var write_buf: [64]u8 = undefined;
                var reader = conn.reader(io, &read_buf);
                var writer = conn.writer(io, &write_buf);

                const cmd = mockReadLine(alloc, &reader) catch null;
                if (cmd) |line| {
                    defer alloc.free(line);
                    if (std.mem.startsWith(u8, line, "set ")) {
                        const val = mockReadLine(alloc, &reader) catch null;
                        if (val) |v| alloc.free(v);
                    }
                }

                _ = writer.interface.writeAll(frame) catch break;
                writer.interface.flush() catch break;
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
            }
        }
    };

    const port = try net.findFreePort();
    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, MalformedServer.run, .{
        allocator, addr, &ready, 4, "BOGUS\r\n",
    });
    waitReady(&ready);

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});
    const mc = try Memcache.create(allocator, .{ .server = server_str });
    const c = mc.asCache();

    // `get` / `isExist` 走 readGetReply，`set` 走 readLine，`delete` 走 readLine —— 全部 StorageError。
    try std.testing.expectError(error.StorageError, c.get("k"));
    try std.testing.expectError(error.StorageError, c.isExist("k"));
    try std.testing.expectError(error.StorageError, c.set("k", "v", 60));
    try std.testing.expectError(error.StorageError, c.delete("k"));

    // 每次失败都断开连接，下一次操作重新建连（状态干净，不崩溃）。
    try std.testing.expect(mc.stream == null);

    mc.deinit();
    allocator.destroy(mc);
    thread.join();
}

test "memcache 连接池：默认上限为 1、显式 0 也按 1 处理，单连接模式池统计恒为零" {
    const allocator = std.testing.allocator;

    const defaults: Options = .{};
    try std.testing.expectEqual(@as(usize, 1), defaults.max_connections);
    try std.testing.expectEqual(@as(u64, 30_000), defaults.pool_timeout_ms);

    const port = try net.findFreePort();
    const addr = std.Io.net.IpAddress{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var ready = std.atomic.Value(bool).init(false);
    const thread = try mockMemcacheServer(allocator, addr, &ready);
    waitReady(&ready);

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});

    // 显式 0 会被钳制为 1：这一档走的是历史单连接路径（`stream` / `mutex` 那组字段，
    // 既有断言原样成立）。
    const mc = try Memcache.create(allocator, .{ .server = server_str, .max_connections = 0 });
    errdefer allocator.destroy(mc);
    errdefer mc.deinit();
    try std.testing.expectEqual(@as(usize, 1), mc.max_connections);

    const c = mc.asCache();
    try c.set("clamp", "v", 60);
    const got = try c.get("clamp");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);

    // 连接由实例自持（历史字段语义），池里没有连接，池统计恒为零。
    try std.testing.expect(mc.stream != null);
    const stats = mc.poolStats();
    try std.testing.expectEqual(@as(usize, 0), stats.live);
    try std.testing.expectEqual(@as(usize, 0), stats.idle);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
    try std.testing.expectEqual(@as(usize, 0), stats.peak_in_use);
    try std.testing.expectEqual(@as(usize, 0), stats.created);
    try std.testing.expectEqual(@as(usize, 0), stats.discarded);
    try std.testing.expectEqual(@as(usize, 0), stats.timeouts);

    mc.deinit();
    allocator.destroy(mc);
    thread.join();
}

test "memcache 连接池：max_connections>1 时多线程真并发（服务端观测峰值 > 1）" {
    const allocator = std.testing.allocator;
    const port = try net.findFreePort();

    var srv: MockPoolServer = .{
        .allocator = allocator,
        .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        // 每条命令延迟 40ms：单连接串行时 4 个线程无法重叠，连接池下必然重叠。
        .delay_ms = 40,
    };
    const server_thread = try srv.start();
    waitReady(&srv.ready);
    try std.testing.expect(srv.ready.load(.acquire));

    const MAX_CONNS: usize = 4;
    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});
    const mc = try Memcache.create(allocator, .{
        .server = server_str,
        .max_connections = MAX_CONNS,
        .pool_timeout_ms = 5_000,
    });
    errdefer allocator.destroy(mc);
    errdefer mc.deinit();

    const THREADS = MAX_CONNS;
    const OPS = 3;

    var go = std.atomic.Value(bool).init(false);
    var bad = std.atomic.Value(bool).init(false);

    const Worker = struct {
        /// 签名必须是 `void` —— `std.Thread.spawn` 对返回 error union 的线程函数只
        /// 打印错误名然后丢弃，`join()` 观察不到失败，因此走原子标志。
        fn run(client: *Memcache, tid: usize, go_flag: *std.atomic.Value(bool), failed: *std.atomic.Value(bool)) void {
            while (!go_flag.load(.acquire)) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < OPS) : (i += 1) {
                var key_buf: [32]u8 = undefined;
                var val_buf: [32]u8 = undefined;
                const key = std.mem.print(&key_buf, "pk_{d}_{d}", .{ tid, i }) catch {
                    failed.store(true, .release);
                    return;
                };
                const val = std.mem.print(&val_buf, "pv_{d}_{d}", .{ tid, i }) catch {
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
                // get 返回借用切片，必须在下一次缓存操作前比较。
                if (!std.mem.eql(u8, got, val)) {
                    failed.store(true, .release);
                    return;
                }
            }
        }
    };

    const threads = try allocator.alloc(std.Thread, THREADS);
    defer allocator.free(threads);
    for (threads, 0..) |*t, tid| t.* = try std.Thread.spawn(.{}, Worker.run, .{ mc, tid, &go, &bad });
    go.store(true, .release);
    for (threads) |t| t.join();

    try std.testing.expect(!bad.load(.acquire));

    const stats = mc.poolStats();
    const server_peak = srv.peak.load(.acquire);
    std.debug.print(
        "[memcache pool] max_connections={d} server_peak_conns={d} client_peak_in_use={d} accepted={d}\n",
        .{ MAX_CONNS, server_peak, stats.peak_in_use, srv.accepted.load(.acquire) },
    );

    try std.testing.expect(server_peak > 1);
    try std.testing.expect(server_peak <= MAX_CONNS);
    try std.testing.expect(stats.peak_in_use > 1);
    try std.testing.expect(stats.peak_in_use <= MAX_CONNS);
    try std.testing.expectEqual(@as(usize, 0), stats.timeouts);
    // 空闲连接都还留在池里，全程没丢连接。
    try std.testing.expectEqual(stats.live, stats.idle);
    try std.testing.expectEqual(@as(usize, 0), stats.discarded);

    mc.deinit();
    allocator.destroy(mc);
    srv.stopAndJoin(server_thread);
}

test "memcache 连接池：池满等待超时返回 PoolTimeout 而非挂死" {
    const allocator = std.testing.allocator;
    const port = try net.findFreePort();

    var srv: MockPoolServer = .{
        .allocator = allocator,
        .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        // 单条命令 2000ms，远大于下面的等待超时（余量刻意放大：并发负载下线程调度
        // 可能延迟数百毫秒，不能让断言依赖紧边界）。
        .delay_ms = 2_000,
    };
    const server_thread = try srv.start();
    waitReady(&srv.ready);
    try std.testing.expect(srv.ready.load(.acquire));

    const MAX_CONNS: usize = 2;
    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});
    const mc = try Memcache.create(allocator, .{
        .server = server_str,
        .max_connections = MAX_CONNS,
        .pool_timeout_ms = 150,
    });
    errdefer allocator.destroy(mc);
    errdefer mc.deinit();

    // 两个 holder 各占住一条连接（每条都要等 2000ms 的命令延迟才归还）。
    var holders_done = std.atomic.Value(bool).init(false);
    var holder_ok = std.atomic.Value(bool).init(true);
    const Holder = struct {
        fn run(client: *Memcache, done: *std.atomic.Value(bool), ok: *std.atomic.Value(bool)) void {
            const c = client.asCache();
            c.set("holder", "v", 60) catch ok.store(false, .release);
            done.store(true, .release);
        }
    };
    const holders = try allocator.alloc(std.Thread, MAX_CONNS);
    defer allocator.free(holders);
    for (holders) |*h| h.* = try std.Thread.spawn(.{}, Holder.run, .{ mc, &holders_done, &holder_ok });

    // 等两条连接都被占住：`live` 在池锁内先占槽位，因此占住后立刻为 MAX_CONNS。
    // 上界给足 5s：并发负载下 holder 线程可能迟迟排不上 CPU。
    var waited: usize = 0;
    while (mc.poolStats().live < MAX_CONNS) {
        if (waited > 1000) break;
        waited += 1;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, MAX_CONNS), mc.poolStats().live);

    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    const c = mc.asCache();
    try std.testing.expectError(error.StorageError, c.get("holder"));
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);

    // 超时是有界的：既真的等了（≥ 100ms，容调度误差），又没有等到 holder 跑完（2000ms）。
    try std.testing.expect(elapsed_ms >= 100);
    try std.testing.expect(elapsed_ms < 1500);
    try std.testing.expect(!holders_done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), mc.poolStats().timeouts);

    for (holders) |h| h.join();
    try std.testing.expect(holder_ok.load(.acquire));

    // 连接归还后可继续复用。
    const got = try c.get("holder");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?);
    const stats = mc.poolStats();
    try std.testing.expectEqual(@as(usize, MAX_CONNS), stats.live);
    try std.testing.expectEqual(@as(usize, 0), stats.discarded);

    mc.deinit();
    allocator.destroy(mc);
    srv.stopAndJoin(server_thread);
}

test "memcache 连接池：坏连接丢弃不进池，后续请求重建连接" {
    const allocator = std.testing.allocator;
    const port = try net.findFreePort();

    var srv: MockPoolServer = .{
        .allocator = allocator,
        .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        // 第 1 条连接在首个命令后回一帧非法文本协议响应：连得上、但协议坏掉。
        .poison_conn = 1,
    };
    const server_thread = try srv.start();
    waitReady(&srv.ready);
    try std.testing.expect(srv.ready.load(.acquire));

    var server_str_buf: [32]u8 = undefined;
    const server_str = try std.mem.print(&server_str_buf, "127.0.0.1:{d}", .{port});
    const mc = try Memcache.create(allocator, .{
        .server = server_str,
        .max_connections = 2,
        .pool_timeout_ms = 2_000,
    });
    errdefer allocator.destroy(mc);
    errdefer mc.deinit();

    const c = mc.asCache();

    // 首个请求撞上坏连接：必须失败，且该连接不能留在池中。
    try std.testing.expectError(error.StorageError, c.set("poisoned", "v", 60));
    const after_bad = mc.poolStats();
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
    try std.testing.expectEqual(@as(usize, 1), mc.poolStats().live);

    mc.deinit();
    allocator.destroy(mc);
    srv.stopAndJoin(server_thread);
}
