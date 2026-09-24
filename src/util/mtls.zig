// SPDX-License-Identifier: Apache-2.0
//! util/mtls — 微信支付 v2 所需的 mTLS（客户端证书）自建实现
//!
//! std 的 TLS 客户端（`std.crypto.tls.Client`）**不支持客户端证书**，因此本仓库
//! 自建了一条最小 mTLS 通道：在 `-Dmtls=true` 时由 `mtls_openssl.zig` 运行时
//! `dlopen` 系统 OpenSSL 完成握手与收发，**构建期不链接 libssl / libcrypto**。
//!
//! 开关来自 `build.zig` 生成的 `mtls_options` 模块（`-Dmtls`，默认 false）：
//! - **关闭**（默认）：`postXML` 直接返回 `error.MtlsNotEnabled`，且本模块不引用
//!   任何需要 libc 的符号（`mtls_openssl.zig` 根本不会被分析），产物零 C 依赖；
//! - **开启**：`postXML` 走 `mtls_openssl.zig` 的真实握手（此时才 `link_libc`）。
//!
//! 纯逻辑部分（URI 解析 / 请求组装 / 响应解析）与开关无关，始终可测。
//!
//! 微信支付 v2 的退款 / 转账 / 红包是 mTLS 接口。若不便开启该开关，可改用 v3
//! 接口（`src/pay/v3/refund.zig`、`src/pay/v3/transfer.zig`：RSA 签名，不需要
//! 客户端证书）。

const std = @import("std");

const options = @import("mtls_options");
const default_io = @import("default_io.zig");

/// 编译期开关：是否启用运行时 dlopen OpenSSL 的 mTLS 后端。
pub const enabled = options.enabled;

/// 响应体上限：微信支付 v2 的响应都是几 KB，这里只为兜住异常/恶意服务端。
pub const max_response_bytes: usize = 8 * 1024 * 1024;

/// 关闭开关时 `postXML` 返回的错误：调用方要么用 `-Dmtls=true` 重新构建，
/// 要么改用 v3 接口。
pub const NotEnabledError = error{MtlsNotEnabled};

/// 解析后的 HTTPS 端点。`host` / `path` 均指向传入的 uri 缓冲区。
pub const Endpoint = struct {
    host: []const u8,
    port: u16,
    /// 至少为 `"/"`；含 query。
    path: []const u8,
};

/// 解析 `https://host[:port][/path]`。
///
/// - 只接受 https（微信支付接口不提供明文入口）；
/// - 缺省端口 443；
/// - 支持 `[::1]:443` 形式的 IPv6 字面量；
/// - host / path 均做字符白名单校验，杜绝把 CRLF 之类注进请求行或 Host 头。
pub fn parseHttpsUri(uri: []const u8) !Endpoint {
    const prefix = "https://";
    if (uri.len <= prefix.len or !std.ascii.startsWithIgnoreCase(uri, prefix))
        return error.InvalidUri;

    const rest = uri[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path: []const u8 = if (slash == rest.len) "/" else rest[slash..];
    if (authority.len == 0) return error.InvalidUri;

    var host = authority;
    var port: u16 = 443;

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidUri;
        host = authority[1..close];
        const tail = authority[close + 1 ..];
        if (tail.len > 0) {
            if (tail[0] != ':') return error.InvalidUri;
            port = std.fmt.parseInt(u16, tail[1..], 10) catch return error.InvalidUri;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidUri;
    }

    if (!isValidHost(host)) return error.InvalidUri;
    if (port == 0) return error.InvalidUri;
    for (path) |c| {
        if (c <= ' ' or c == 0x7f) return error.InvalidUri;
    }

    return .{ .host = host, .port = port, .path = path };
}

/// host 白名单：字母数字、`.`/`-`/`_`，以及 IPv6 字面量里的 `:`/`%`（zone id）。
fn isValidHost(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        switch (c) {
            '.', '-', '_', ':', '%' => continue,
            else => return false,
        }
    }
    return true;
}

/// 组装 HTTP/1.1 请求（含 body）。
///
/// **为什么请求字节要自己拼（不能用 `std.http.Client`）**：std 的请求写出绑死在
/// `std.http.Client.Connection` 上——那个结构体的读写端是具体的
/// `Io.net.Stream.Writer` / `Io.net.Stream.Reader`，TLS 会话字段
/// （`Connection.Tls`）是**私有类型**，也没有任何「自定义 TLS 后端」入口，因此
/// 没法把 `mtls_openssl.zig` 里那条带客户端证书的 OpenSSL 会话塞进去（客户端证书
/// 恰是 std 自带的 `std.crypto.tls.Client` 不支持的能力）。响应侧不受这个限制
/// （见 `parseResponse`：那里完全复用 std 的公开解析器）。
///
/// 约定：`Content-Type: application/xml;charset=utf-8`（与 v2 接口一致）、
/// `Connection: close`（读到 EOF 即响应结束，便于按无 Content-Length 的响应收尾）。
/// **非 443 端口必须在 Host 头里显式写出**，否则虚拟主机会被路由到默认站点。
pub fn buildRequest(allocator: std.mem.Allocator, ep: Endpoint, body: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "POST ");
    try buf.appendSlice(allocator, ep.path);
    try buf.appendSlice(allocator, " HTTP/1.1\r\nHost: ");
    try buf.appendSlice(allocator, ep.host);
    if (ep.port != 443) try buf.print(allocator, ":{d}", .{ep.port});
    try buf.appendSlice(allocator, "\r\n");
    try buf.appendSlice(
        allocator,
        "Content-Type: application/xml;charset=utf-8\r\n",
    );
    try buf.print(allocator, "Content-Length: {d}\r\n", .{body.len});
    try buf.appendSlice(allocator, "Connection: close\r\n\r\n");
    try buf.appendSlice(allocator, body);

    return buf.toOwnedSlice(allocator);
}

/// 解析后的响应：`body` 由调用方负责 `free`。
pub const Response = struct {
    status: u16,
    body: []u8,
};

/// 非 200 一律视为失败（微信支付 v2 成功响应固定 200 + `return_code`）。
pub fn requireOk(resp: *const Response) !void {
    if (resp.status != 200) return error.HttpStatusNotOk;
}

/// head 上限：微信支付 v2 的响应头只有几百字节，这里只为兜住异常/恶意服务端
/// （超过即拒绝，不再继续解析）。
pub const max_head_bytes: usize = 64 * 1024;

/// 解析完整的原始 HTTP 响应（status line + headers + body）。
///
/// 复用 std 的公开解析器，而不是手写扫描：
/// 1. `std.http.Reader.receiveHead`（内部 `http.HeadParser`）定位 head 结束并套用
///    `max_head_bytes` 上限；
/// 2. `std.http.Client.Response.Head.parse` 解析状态行与
///    connection / content-type / transfer-encoding / content-length / content-encoding;
/// 3. `std.http.Reader.bodyReader` 按 `Transfer-Encoding: chunked`（`http.ChunkParser`
///    驱动，含 chunk 扩展与 trailer）、`Content-Length`、两者都无（connection-close，
///    读到 EOF）三种定界读出 body。
///
/// 相比旧的手写解析，这里额外拒绝：超长 head、重复且互相冲突的 `Content-Length`、
/// 重复的 `Transfer-Encoding`、obs-fold 续行头、畸形/溢出的 chunk 尺寸、缺 CRLF
/// 分隔的 chunk 数据、截断的 chunk/trailer。
///
/// 错误映射刻意**保持既有错误集不变**（不新增错误变体）：
/// - head 畸形/超长、chunk 畸形/截断、body 超过 `max_response_bytes`
///   → `error.InvalidResponse`；
/// - `Content-Length` 声明多于实际收到的字节 → `error.TruncatedResponse`。
pub fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) !Response {
    // 整个响应已在内存里，用 `std.Io.Reader.fixed` 把它包成「读到末尾即 EOF」的
    // reader 喂给 std.http.Reader。
    var in: std.Io.Reader = .fixed(raw);
    var reader: std.http.Reader = .{
        .in = &in,
        // `bodyReader` 在本函数用到的两条路径（chunked / content-length）都会覆盖
        // 本字段；只有「无定界、读到 EOF」那条路径不用它（那条路径返回 `reader.in`）。
        .interface = undefined,
        .state = .ready,
        .max_head_len = max_head_bytes,
    };

    const head_bytes = reader.receiveHead() catch return error.InvalidResponse;
    // `receiveHead` 的 `max_head_len` 只在 head 需要分多次喂入时生效；整块缓冲下
    // head 可能被 HeadParser 一次扫完，故这里按实际长度再兜一道。
    if (head_bytes.len > max_head_bytes) return error.InvalidResponse;

    const head = std.http.Client.Response.Head.parse(head_bytes) catch return error.InvalidResponse;

    var transfer_buffer: [4096]u8 = undefined;
    const body_reader = reader.bodyReader(&transfer_buffer, head.transfer_encoding, head.content_length);
    const body = body_reader.allocRemaining(allocator, .limited(max_response_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    errdefer allocator.free(body);

    // content-length 定界下，提前 EOF 对 `contentLengthStream` 而言只是「流结束」，
    // 它会安静地返回短 body，所以短包必须在这里自己判定。
    if (head.content_length) |declared| {
        if (body.len != declared) return error.TruncatedResponse;
    }

    return .{ .status = @backingInt(head.status), .body = body };
}

/// 关闭开关时的后端（**不引用任何 libc 符号**）：编译期保证 `mtls_openssl.zig`
/// 在默认构建里不会被分析，因而产物不依赖 OpenSSL / libc。
const StubBackend = struct {
    fn exchange(
        allocator: std.mem.Allocator,
        io: std.Io,
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
        return error.MtlsNotEnabled;
    }
};

/// 后端选择：`-Dmtls=false` 时选 `StubBackend`（comptime 分支，未选中的分支
/// 不会被分析，因此默认构建不会引入 DynLib / dlopen）。
const backend = if (options.enabled) @import("mtls_openssl.zig") else StubBackend;

/// 用客户端证书（PEM）向微信支付 v2 端点发一个 XML POST 并返回响应体。
///
/// `cert_pem` / `key_pem` 由 `util.rsa.parseP12` 从商户 PKCS#12 证书解出；
/// `ca_file` 为 `null` 时使用系统默认信任库校验服务端证书。
///
/// 关闭 `-Dmtls` 时返回 `error.MtlsNotEnabled`（不会发起任何连接）。
/// 返回的响应体由调用方 `free`。
pub fn postXML(
    allocator: std.mem.Allocator,
    io: std.Io,
    uri: []const u8,
    body: []const u8,
    cert_pem: []const u8,
    key_pem: []const u8,
    ca_file: ?[]const u8,
) ![]u8 {
    if (!options.enabled) return error.MtlsNotEnabled;

    const ep = try parseHttpsUri(uri);
    const request = try buildRequest(allocator, ep, body);
    defer allocator.free(request);

    const raw = try backend.exchange(
        allocator,
        io,
        ep.host,
        ep.port,
        request,
        cert_pem,
        key_pem,
        ca_file,
        max_response_bytes,
    );
    defer allocator.free(raw);

    const resp = try parseResponse(allocator, raw);
    errdefer allocator.free(resp.body);
    try requireOk(&resp);
    return resp.body;
}

// =============================================================================
// 内联测试（纯逻辑，与 OpenSSL / 开关无关）
// =============================================================================

test "parseHttpsUri 解析默认端口与 path" {
    const ep = try parseHttpsUri("https://api.mch.weixin.qq.com/secapi/pay/refund");
    try std.testing.expectEqualStrings("api.mch.weixin.qq.com", ep.host);
    try std.testing.expectEqual(@as(u16, 443), ep.port);
    try std.testing.expectEqualStrings("/secapi/pay/refund", ep.path);
}

test "parseHttpsUri 解析非默认端口与 query" {
    const ep = try parseHttpsUri("https://127.0.0.1:8443/pay?x=1");
    try std.testing.expectEqualStrings("127.0.0.1", ep.host);
    try std.testing.expectEqual(@as(u16, 8443), ep.port);
    try std.testing.expectEqualStrings("/pay?x=1", ep.path);
}

test "parseHttpsUri 无 path 时归一化为 /，支持 IPv6 字面量" {
    const root = try parseHttpsUri("https://api.mch.weixin.qq.com");
    try std.testing.expectEqualStrings("/", root.path);
    try std.testing.expectEqual(@as(u16, 443), root.port);

    const v6 = try parseHttpsUri("https://[::1]:8443/x");
    try std.testing.expectEqualStrings("::1", v6.host);
    try std.testing.expectEqual(@as(u16, 8443), v6.port);
    try std.testing.expectEqualStrings("/x", v6.path);
}

test "parseHttpsUri 拒绝非 https / 注入 / 畸形输入" {
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("http://example.com/x"));
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("ftp://example.com/x"));
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https://"));
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https:///x"));
    // CRLF / 空格注入（Host 头与请求行都必须干净）。
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https://a\r\nX-Evil: 1/x"));
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https://a b/x"));
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https://a.com/x\r\nX-Evil: 1"));
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https://user@a.com/x"));
    // 端口非法 / 为 0。
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https://a.com:0/x"));
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https://a.com:abc/x"));
    try std.testing.expectError(error.InvalidUri, parseHttpsUri("https://a.com:99999/x"));
}

test "buildRequest 组装请求行与请求头" {
    const allocator = std.testing.allocator;
    const ep = try parseHttpsUri("https://api.mch.weixin.qq.com/secapi/pay/refund");
    const req = try buildRequest(allocator, ep, "<xml/>");
    defer allocator.free(req);

    const expected = "POST /secapi/pay/refund HTTP/1.1\r\n" ++
        "Host: api.mch.weixin.qq.com\r\n" ++
        "Content-Type: application/xml;charset=utf-8\r\n" ++
        "Content-Length: 6\r\n" ++
        "Connection: close\r\n\r\n" ++
        "<xml/>";
    try std.testing.expectEqualStrings(expected, req);
}

test "buildRequest 非 443 端口在 Host 头里带端口" {
    const allocator = std.testing.allocator;
    const ep = try parseHttpsUri("https://127.0.0.1:8443/pay");
    const req = try buildRequest(allocator, ep, "");
    defer allocator.free(req);
    try std.testing.expect(
        std.mem.startsWith(u8, req, "POST /pay HTTP/1.1\r\nHost: 127.0.0.1:8443\r\n"),
    );
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Length: 0\r\n") != null);
}

test "parseResponse 解析 Content-Length 响应" {
    const allocator = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/xml\r\n" ++
        "Content-Length: 6\r\n" ++
        "Connection: close\r\n\r\n" ++
        "<xml/>XX"; // 尾部多出的字节必须被丢掉（按 Content-Length 截断）
    const resp = try parseResponse(allocator, raw);
    defer allocator.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("<xml/>", resp.body);
}

test "parseResponse 解析 chunked 响应（含 chunk 扩展与 trailer）" {
    const allocator = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Connection: close\r\n\r\n" ++
        "5;foo=bar\r\n<xml/\r\n" ++
        "3\r\n>ab\r\n" ++
        "0\r\n" ++
        "X-Trailer: 1\r\n\r\n";
    const resp = try parseResponse(allocator, raw);
    defer allocator.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("<xml/>ab", resp.body);
}

test "parseResponse 无 Content-Length 时取剩余全部（Connection: close）" {
    const allocator = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n<xml>body</xml>";
    const resp = try parseResponse(allocator, raw);
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("<xml>body</xml>", resp.body);
}

test "parseResponse 空 body 与非 200 状态" {
    const allocator = std.testing.allocator;
    const empty = try parseResponse(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(empty.body);
    try std.testing.expectEqual(@as(usize, 0), empty.body.len);

    const err_resp = try parseResponse(
        allocator,
        "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 2\r\nConnection: close\r\n\r\nno",
    );
    defer allocator.free(err_resp.body);
    try std.testing.expectEqual(@as(u16, 502), err_resp.status);
    try std.testing.expectError(error.HttpStatusNotOk, requireOk(&err_resp));
    try std.testing.expectEqualStrings("no", err_resp.body);
}

test "parseResponse 拒绝畸形响应与截断的 Content-Length" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidResponse, parseResponse(allocator, "garbage"));
    try std.testing.expectError(error.InvalidResponse, parseResponse(allocator, "HTTP/1.1 OK\r\n\r\n"));
    try std.testing.expectError(
        error.TruncatedResponse,
        parseResponse(allocator, "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nshort"),
    );
    try std.testing.expectError(
        error.InvalidResponse,
        parseResponse(allocator, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"),
    );
}

test "parseResponse 拒绝超过 max_head_bytes 的 head" {
    const allocator = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    try raw.appendSlice(allocator, "HTTP/1.1 200 OK\r\nX-Pad: ");
    try raw.appendNTimes(allocator, 'a', max_head_bytes);
    try raw.appendSlice(allocator, "\r\n\r\n<xml/>");
    try std.testing.expectError(error.InvalidResponse, parseResponse(allocator, raw.items));
}

test "parseResponse 拒绝畸形 chunk（数据后缺 CRLF / 尺寸溢出）" {
    const allocator = std.testing.allocator;
    // chunk 数据之后必须是 CRLF：这里放的是 `X\r`。
    try std.testing.expectError(
        error.InvalidResponse,
        parseResponse(
            allocator,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n<xml/X\r\n0\r\n\r\n",
        ),
    );
    // 旧的手写解析用 parseInt(usize, …, 16)，这里由 ChunkParser 判溢出。
    try std.testing.expectError(
        error.InvalidResponse,
        parseResponse(
            allocator,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nffffffffffffffffff\r\n",
        ),
    );
}

test "parseResponse 截断的 chunked body 返回 InvalidResponse" {
    const allocator = std.testing.allocator;
    // 声明 5 字节只给了 3 字节就 EOF。
    try std.testing.expectError(
        error.InvalidResponse,
        parseResponse(allocator, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n<x"),
    );
    // trailer 段没写完。
    try std.testing.expectError(
        error.InvalidResponse,
        parseResponse(
            allocator,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Trailer: 1",
        ),
    );
}

test "parseResponse 拒绝相互冲突的 Content-Length 与 obs-fold 续行头" {
    const allocator = std.testing.allocator;
    // 冲突的 Content-Length（响应拆分 / 走私的经典素材）。
    try std.testing.expectError(
        error.InvalidResponse,
        parseResponse(
            allocator,
            "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nContent-Length: 7\r\n\r\n<xml/>X",
        ),
    );
    // obs-fold 续行头（RFC 7230 已废弃）。
    try std.testing.expectError(
        error.InvalidResponse,
        parseResponse(
            allocator,
            "HTTP/1.1 200 OK\r\nX-Fold: a\r\n b\r\nContent-Length: 6\r\n\r\n<xml/>",
        ),
    );
    // 同一个 transfer-encoding 头出现两次。
    try std.testing.expectError(
        error.InvalidResponse,
        parseResponse(
            allocator,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        ),
    );
}

test "mtls 开关默认关闭时 postXML 返回 MtlsNotEnabled" {
    if (!options.enabled) {
        const io = default_io.io();
        const result = postXML(
            std.testing.allocator,
            io,
            "https://api.mch.weixin.qq.com/secapi/pay/refund",
            "<xml/>",
            "-----BEGIN CERTIFICATE-----\n",
            "-----BEGIN PRIVATE KEY-----\n",
            null,
        );
        try std.testing.expectError(error.MtlsNotEnabled, result);
    } else {
        // 开启 mTLS 的构建里，这里会真的去连微信服务器——跳过（不该在单测里联网）。
        return error.SkipZigTest;
    }
}
