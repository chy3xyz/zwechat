// SPDX-License-Identifier: Apache-2.0
//! util/mtls_openssl — `util/mtls.zig` 的 OpenSSL 后端
//!
//! **只在本模块被 `mtls.zig` 选中时才编译**（`-Dmtls=true`，此时 build.zig 会
//! 为 dlopen 打开 `link_libc`；默认构建根本不分析本文件，见 `mtls.zig` 的
//! `backend` 选择）。
//!
//! 实现方式：用 `std.DynLib` 在**运行时**加载系统 OpenSSL，手写函数指针类型
//! （opaque 指针，不引入任何 C 头文件 / translateC）；libssl / libcrypto 都不
//! 参与链接，因此构建期零 C 依赖。
//!
//! 平台：POSIX（Linux / macOS）。Windows 的 AFD socket 句柄不是文件描述符，
//! 无法直接喂给 `SSL_set_fd`，且 `std.DynLib` 在 Windows 上是 `@compileError`，
//! 故 `-Dmtls=true` 目前不支持 Windows（默认构建不受影响）。

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// 本文件的日志 scope：宿主可用 `std_options.log_scope_levels` 单独静音 mTLS
/// 后端（OpenSSL 桥）的告警，而不必整体降低 `log.level`。
const log = std.log.scoped(.zwechat_mtls);

/// OpenSSL 的 `long`：LP64 上 8 字节，Windows LLP64 上 4 字节。
const Clong = if (builtin.os.tag == .windows) i32 else if (@sizeOf(usize) == 8) i64 else i32;

/// 平台无关的交换入口：Windows 走 unsupported stub，其余走 POSIX 实现。
///
/// 这里用 comptime 分支选择实现，是为了让 Windows 上**完全不分析** `PosixImpl`
/// （其中的 `std.DynLib` 在 Windows 上是 `@compileError`）。
const Implementation = if (builtin.os.tag == .windows) WindowsUnsupported else PosixImpl;

/// 与 `mtls.zig` 的后端契约一致：返回**原始 HTTP 响应字节**（调用方负责 free），
/// 解析与状态码判定留在 `mtls.zig`（那部分是纯逻辑，可离线测试）。
pub fn exchange(
    allocator: std.mem.Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    request: []const u8,
    cert_pem: []const u8,
    key_pem: []const u8,
    ca_file: ?[]const u8,
    limit: usize,
) ![]u8 {
    return Implementation.exchange(allocator, io, host, port, request, cert_pem, key_pem, ca_file, limit);
}

const WindowsUnsupported = struct {
    fn exchange(
        allocator: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        request: []const u8,
        cert_pem: []const u8,
        key_pem: []const u8,
        ca_file: ?[]const u8,
        limit: usize,
    ) ![]u8 {
        _ = allocator;
        _ = io;
        _ = host;
        _ = port;
        _ = request;
        _ = cert_pem;
        _ = key_pem;
        _ = ca_file;
        _ = limit;
        return error.UnsupportedPlatform;
    }
};

const PosixImpl = struct {
    // ── OpenSSL 常量（宏在导出符号里不存在，一律走 ctrl 变体）───────────────
    /// `SSL_CTRL_SET_TLSEXT_HOSTNAME`
    const ssl_ctrl_set_tlsext_hostname = 55;
    /// `TLSEXT_NAMETYPE_host_name`
    const tlsext_nametype_host_name = 0;
    /// `SSL_CTRL_SET_MIN_PROTO_VERSION`
    const ssl_ctrl_set_min_proto_version = 123;
    /// `TLS1_2_VERSION`
    const tls1_2_version = 0x0303;

    /// `SSL_VERIFY_PEER`：校验服务端证书链。
    const ssl_verify_peer = 1;

    // ── 符号表（字段名 == 导出符号名，加载时按名字查找）─────────────────────
    const Ssl = struct {
        TLS_client_method: *const fn () callconv(.c) ?*anyopaque,
        SSL_CTX_new: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
        SSL_CTX_free: *const fn (?*anyopaque) callconv(.c) void,
        SSL_CTX_use_certificate: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int,
        SSL_CTX_use_PrivateKey: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int,
        SSL_CTX_check_private_key: *const fn (?*anyopaque) callconv(.c) c_int,
        SSL_CTX_set_default_verify_paths: *const fn (?*anyopaque) callconv(.c) c_int,
        SSL_CTX_load_verify_locations: *const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
        SSL_CTX_set_verify: *const fn (?*anyopaque, c_int, ?*anyopaque) callconv(.c) void,
        SSL_CTX_ctrl: *const fn (?*anyopaque, c_int, Clong, ?*anyopaque) callconv(.c) Clong,
        SSL_new: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
        SSL_free: *const fn (?*anyopaque) callconv(.c) void,
        SSL_set_fd: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
        SSL_ctrl: *const fn (?*anyopaque, c_int, Clong, ?*anyopaque) callconv(.c) Clong,
        SSL_connect: *const fn (?*anyopaque) callconv(.c) c_int,
        SSL_get_verify_result: *const fn (?*anyopaque) callconv(.c) Clong,
        SSL_write: *const fn (?*anyopaque, [*]const u8, c_int) callconv(.c) c_int,
        SSL_read: *const fn (?*anyopaque, [*]u8, c_int) callconv(.c) c_int,
        SSL_get_error: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
        SSL_shutdown: *const fn (?*anyopaque) callconv(.c) c_int,
        /// 可选（OpenSSL >= 1.1.0）：把期望的主机名绑进校验参数，使
        /// `SSL_get_verify_result` 之外还做主机名匹配。LibreSSL / 老版本缺失时
        /// 跳过并告警（不因此拒绝服务）。
        SSL_set1_host: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) c_int,
    };

    const Crypto = struct {
        BIO_new_mem_buf: *const fn (?*const anyopaque, c_int) callconv(.c) ?*anyopaque,
        BIO_free: *const fn (?*anyopaque) callconv(.c) c_int,
        PEM_read_bio_X509: *const fn (?*anyopaque, ?*?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque,
        PEM_read_bio_PrivateKey: *const fn (?*anyopaque, ?*?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque,
        X509_free: *const fn (?*anyopaque) callconv(.c) void,
        EVP_PKEY_free: *const fn (?*anyopaque) callconv(.c) void,
        ERR_get_error: *const fn () callconv(.c) c_ulong,
        ERR_error_string_n: *const fn (c_ulong, [*]u8, usize) callconv(.c) void,
        ERR_clear_error: *const fn () callconv(.c) void,
    };

    /// 按字段名查符号；任一**必填**符号缺失即返回 null（由调用方转
    /// `error.OpenSslNotAvailable`，绝不 panic）。
    ///
    /// 字段类型声明为 optional 的符号是**可选**的：查不到就留 null（用于
    /// `SSL_set1_host` 这类老版本 / LibreSSL 可能缺失的符号），不因此拒绝服务。
    fn lookupRequired(comptime T: type, lib: *std.DynLib) ?T {
        var out: T = undefined;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, Ty| {
            if (@typeInfo(Ty) == .optional) {
                @field(out, name) = lib.lookup(@typeInfo(Ty).optional.child, name);
            } else {
                @field(out, name) = lib.lookup(Ty, name) orelse return null;
            }
        }
        return out;
    }

    /// 动态库候选名：环境变量显式路径优先，其次各平台默认名。
    ///
    /// Linux 走 soname（交给 ld.so 的缓存/搜索路径）；macOS 上系统
    /// `/usr/lib/libssl.dylib` 是 LibreSSL，因此把 Homebrew OpenSSL 3 的绝对路径
    /// 排在前面。
    const ssl_names = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => [_][]const u8{
            "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
            "/usr/local/opt/openssl@3/lib/libssl.3.dylib",
            "libssl.3.dylib",
            "libssl.dylib",
        },
        else => [_][]const u8{ "libssl.so.3", "libssl.so" },
    };

    const crypto_names = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => [_][]const u8{
            "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
            "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib",
            "libcrypto.3.dylib",
            "libcrypto.dylib",
        },
        else => [_][]const u8{ "libcrypto.so.3", "libcrypto.so" },
    };

    fn openLib(names: []const []const u8, env_name: [*:0]const u8) ?std.DynLib {
        if (std.c.getenv(env_name)) |raw| {
            const path = std.mem.span(raw);
            if (path.len > 0) {
                if (std.DynLib.open(path)) |lib| return lib else |_| {}
            }
        }
        for (names) |name| {
            if (std.DynLib.open(name)) |lib| return lib else |_| {}
        }
        return null;
    }

    /// 把 OpenSSL 错误队列里最后一条可读原因写进日志（徽标码便于检索）。
    /// `ERR_error_string_n` 只描述失败原因，**不含**证书/私钥内容。
    fn logErrors(c: *const Crypto) void {
        var code = c.ERR_get_error();
        if (code == 0) return;
        var buf: [256]u8 = undefined;
        c.ERR_error_string_n(code, &buf, buf.len);
        const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
        log.warn("mtls: OpenSSL 失败: {s}", .{buf[0..len]});
        code = c.ERR_get_error();
        while (code != 0) code = c.ERR_get_error();
        c.ERR_clear_error();
    }

    /// 装载客户端证书与私钥（PEM，由 `util.rsa.parseP12` 解出）。
    fn loadCertKey(
        s: *const Ssl,
        c: *const Crypto,
        ctx: ?*anyopaque,
        cert_pem: []const u8,
        key_pem: []const u8,
    ) !void {
        const cert_bio = c.BIO_new_mem_buf(@ptrCast(cert_pem.ptr), @intCast(cert_pem.len)) orelse
            return error.OpenSslError;
        defer {
            _ = c.BIO_free(cert_bio);
        }
        const cert = c.PEM_read_bio_X509(cert_bio, null, null, null) orelse return error.TlsCertLoadFailed;
        defer c.X509_free(cert);
        if (s.SSL_CTX_use_certificate(ctx, cert) != 1) return error.TlsCertLoadFailed;

        const key_bio = c.BIO_new_mem_buf(@ptrCast(key_pem.ptr), @intCast(key_pem.len)) orelse
            return error.OpenSslError;
        defer {
            _ = c.BIO_free(key_bio);
        }
        const key = c.PEM_read_bio_PrivateKey(key_bio, null, null, null) orelse
            return error.TlsKeyLoadFailed;
        defer c.EVP_PKEY_free(key);
        if (s.SSL_CTX_use_PrivateKey(ctx, key) != 1) return error.TlsKeyLoadFailed;
        if (s.SSL_CTX_check_private_key(ctx) != 1) return error.TlsKeyMismatch;
    }

    /// 通过 SSL 发送完整请求体。
    fn writeAll(s: *const Ssl, ssl: ?*anyopaque, request: []const u8) !void {
        var written: usize = 0;
        while (written < request.len) {
            const n = s.SSL_write(ssl, request.ptr + written, @intCast(request.len - written));
            if (n <= 0) return error.TlsWriteFailed;
            written += @intCast(n);
        }
    }

    /// 读满整条响应直到对端关闭（我们发 `Connection: close`）。
    ///
    /// socket 由 std 的 connect 建出，是**阻塞**模式（`openSocketPosix` 只设
    /// SOCK_STREAM|CLOEXEC，不设 O_NONBLOCK），因此 `SSL_read` 只会阻塞到有数据或
    /// 连接结束；任何非正返回都按 EOF 收尾，免得在自旋里烧 CPU。
    fn readAll(
        s: *const Ssl,
        c: *const Crypto,
        allocator: std.mem.Allocator,
        ssl: ?*anyopaque,
        limit: usize,
    ) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = s.SSL_read(ssl, &buf, buf.len);
            if (n <= 0) {
                // 5 = SSL_ERROR_SYSCALL（对端直接关连接，`Connection: close` 的正常
                // 收尾）／6 = SSL_ERROR_ZERO_RETURN（对端发了 close_notify 再关）：
                // 这两种是预期内的结束，其余才值得把 OpenSSL 原因写进日志。
                const err_code = s.SSL_get_error(ssl, n);
                if (err_code != 5 and err_code != 6) logErrors(c);
                break;
            }
            const chunk = buf[0..@intCast(n)];
            if (out.items.len + chunk.len > limit) return error.ResponseTooLarge;
            try out.appendSlice(allocator, chunk);
        }
        return out.toOwnedSlice(allocator);
    }

    fn exchange(
        allocator: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        request: []const u8,
        cert_pem: []const u8,
        key_pem: []const u8,
        ca_file: ?[]const u8,
        limit: usize,
    ) ![]u8 {
        var ssl_lib = openLib(&ssl_names, "ZWECHAT_SSL_LIB") orelse return error.OpenSslNotAvailable;
        defer ssl_lib.close();
        var crypto_lib = openLib(&crypto_names, "ZWECHAT_CRYPTO_LIB") orelse return error.OpenSslNotAvailable;
        defer crypto_lib.close();

        const s = lookupRequired(Ssl, &ssl_lib) orelse return error.OpenSslNotAvailable;
        const c = lookupRequired(Crypto, &crypto_lib) orelse return error.OpenSslNotAvailable;

        const ctx = s.SSL_CTX_new(s.TLS_client_method()) orelse return error.OpenSslError;
        // defer 顺序（后注册先执行）：SSL_free → socket 关闭 → SSL_CTX_free。
        defer s.SSL_CTX_free(ctx);

        if (s.SSL_CTX_ctrl(ctx, ssl_ctrl_set_min_proto_version, tls1_2_version, null) != 1)
            return error.OpenSslError;
        try loadCertKey(&s, &c, ctx, cert_pem, key_pem);

        if (ca_file) |path| {
            const ca_z = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(ca_z);
            if (s.SSL_CTX_load_verify_locations(ctx, ca_z.ptr, null) != 1) {
                logErrors(&c);
                return error.TlsCaLoadFailed;
            }
        } else if (s.SSL_CTX_set_default_verify_paths(ctx) != 1) {
            logErrors(&c);
            return error.TlsCaLoadFailed;
        }
        s.SSL_CTX_set_verify(ctx, ssl_verify_peer, null);

        const address = try std.Io.net.IpAddress.resolve(io, host, port);
        var stream = try address.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        const ssl = s.SSL_new(ctx) orelse return error.OpenSslError;
        defer s.SSL_free(ssl);

        if (s.SSL_set_fd(ssl, @intCast(stream.socket.handle)) != 1) return error.OpenSslError;

        // SNI：`SSL_set_tlsext_host_name` 是宏，只能走 `SSL_ctrl`。
        const host_z = try allocator.dupeSentinel(u8, host, 0);
        defer allocator.free(host_z);
        if (s.SSL_ctrl(ssl, ssl_ctrl_set_tlsext_hostname, tlsext_nametype_host_name, @ptrCast(host_z.ptr)) != 1)
            return error.OpenSslError;

        if (s.SSL_set1_host) |set1_host| {
            if (set1_host(ssl, host_z.ptr) != 1) return error.OpenSslError;
        } else {
            log.warn("mtls: 当前 OpenSSL 无 SSL_set1_host，仅校验证书链，不做主机名匹配", .{});
        }

        if (s.SSL_connect(ssl) != 1) {
            logErrors(&c);
            return error.TlsHandshakeFailed;
        }
        // 链校验（SSL_VERIFY_PEER 已开）：非 0 即服务端证书不可信。
        if (s.SSL_get_verify_result(ssl) != 0) {
            _ = s.SSL_shutdown(ssl);
            return error.TlsCertificateNotVerified;
        }

        try writeAll(&s, ssl, request);
        const raw = try readAll(&s, &c, allocator, ssl, limit);
        _ = s.SSL_shutdown(ssl);
        return raw;
    }
};
