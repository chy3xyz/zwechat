//! util/http — HTTP 客户端封装
//!
//! 对应 `_ref/wechat/util/http.go`：提供 `HTTPGet` / `HTTPPost` / `PostJSON` /
//! `PostXML` / `PostMultipartForm` / `PostXMLWithTLS` 六个核心入口。
//!
//! Zig 版基于 std 0.17 的 `std.http.Client.fetch`，把响应体通过
//! `std.Io.Writer.Allocating` 收集到调用方提供的 allocator 上。
//! `io` 实例固定使用 `std.Io.Threaded.global_single_threaded`，适合同步阻塞
//! 场景；如果以后需要并发，可以把 `inner.io` 换成调用方注入的 `Io`。

const std = @import("std");
const httpz = @import("httpz");
const rsa = @import("rsa.zig");

/// multipart/form-data 字段描述（对照 `MultipartFormField`）。
///
/// `is_file = true` 时使用 `file_path` 读取文件内容（按需再扩展为流式读取）；
/// `is_file = false` 时把 `value` 作为字符串体提交。
pub const MultipartField = struct {
    is_file: bool,
    field_name: []const u8,
    filename: []const u8,
    value: []const u8,
    file_path: []const u8,
};

/// URI 修改器（对照 `URIModifier`）：在每个请求前对 URI 做可选改写。
///
/// 例如本机调试时通过它给微信接口统一加 mock 服务器前缀。`null` 表示不过滤。
pub const UriModifier = *const fn (uri: []const u8) []const u8;

/// 当前生效的 URI 修改器，由 `setUriModifier` 设置。
pub var uri_modifier: ?UriModifier = null;

/// 设置 URI 修改器；传入 `null` 表示清除。
pub fn setUriModifier(m: ?UriModifier) void {
    uri_modifier = m;
}

/// 线程局部的默认 `HttpClient`。第一次调用 `getDefaultClient` 时初始化。
threadlocal var default_client: ?HttpClient = null;

/// 返回线程局部的默认 `HttpClient`。同一线程上重复调用得到的是同一份实例；
/// 不同线程各自一份，互不影响。
pub fn getDefaultClient(allocator: std.mem.Allocator) *HttpClient {
    if (default_client == null) {
        default_client = HttpClient.init(allocator);
    }
    return &default_client.?;
}

/// HTTP 客户端（对照 `_ref/wechat/util/http.go` 中的全局 `DefaultHTTPClient`）。
///
/// 内部封装 `std.http.Client`。所有公共方法返回的字节切片均由调用方持有
/// 并通过 `allocator.free` 释放。
///
/// **可注入 transport**：通过 `setTransport` 注入自定义实现，便于单元测试
/// 不发起真实 HTTP 调用。默认 transport 使用 `std.http.Client`。
pub const HttpClient = struct {
    /// 内部 `std.http.Client`。`io` 字段固定为单线程全局实例，
    /// 适用于同步阻塞调用。
    inner: std.http.Client,
    /// 响应体缓冲使用的 allocator（与 `inner.allocator` 一致；显式保留以
    /// 满足 API 表面要求）。
    allocator: std.mem.Allocator,

    /// 自定义 transport（用于 mock）。`null` 时使用默认的 std.http.Client。
    transport: ?Transport = null,
    /// 自定义 transport 的不透明上下文（`transport` 被调用时透传）。
    transport_ctx: ?*anyopaque = null,

    /// Transport 函数签名：负责真正发出请求并返回响应 body。
    ///
    /// `ctx` 是 `HttpClient.transport_ctx` 的值；其余参数同 `fetchWithStatus`。
    pub const Transport = *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8;

    /// 注入自定义 transport + ctx。`t = null` 恢复默认 std.http.Client。
    pub fn setTransport(self: *HttpClient, t: ?Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// 创建客户端；当前固定使用 `std.Io.Threaded.global_single_threaded`，
    /// 即同步阻塞模式。如果将来要支持并发，应在此处允许传入 `std.Io`。
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .inner = .{
                .allocator = allocator,
                .io = std.Io.Threaded.global_single_threaded.io(),
            },
            .allocator = allocator,
        };
    }

    /// 释放连接池等内部资源。
    pub fn deinit(self: *HttpClient) void {
        self.inner.deinit();
    }

    /// GET 请求（对照 `HTTPGet`），返回响应 body，调用方负责 `free`。
    pub fn get(self: *HttpClient, uri: []const u8) ![]u8 {
        return self.fetchWithStatus(uri, .GET, "", null);
    }

    /// POST 请求（对照 `HTTPPost`）。`content_type` 为 `null` 时不设置
    /// Content-Type，由服务端按缺省处理。
    pub fn post(self: *HttpClient, uri: []const u8, body: []const u8, content_type: ?[]const u8) ![]u8 {
        return self.fetchWithStatus(uri, .POST, body, content_type);
    }

    /// POST JSON 请求（对照 `PostJSON`）。自动设置
    /// `Content-Type: application/json;charset=utf-8`。
    pub fn postJSON(self: *HttpClient, uri: []const u8, body: []const u8) ![]u8 {
        return self.fetchWithStatus(uri, .POST, body, "application/json;charset=utf-8");
    }

    /// POST XML 请求（对照 `PostXML`）。自动设置
    /// `Content-Type: application/xml;charset=utf-8`。
    pub fn postXML(self: *HttpClient, uri: []const u8, body: []const u8) ![]u8 {
        return self.fetchWithStatus(uri, .POST, body, "application/xml;charset=utf-8");
    }

    /// POST multipart/form-data（对照 `PostMultipartForm`）。
    ///
    /// 流程：
    /// 1. 生成 24 字节随机 boundary。
    /// 2. 按顺序写入每个字段；文件字段按 `file_path` 读取。
    /// 3. 末尾追加 `--<boundary>--\r\n`。
    /// 4. 以 `Content-Type: multipart/form-data; boundary=<boundary>` 发送。
    pub fn postMultipart(self: *HttpClient, uri: []const u8, fields: []const MultipartField) ![]u8 {
        const effective_uri = applyUriModifier(uri);

        const boundary = try generateBoundary(self.allocator);
        defer self.allocator.free(boundary);

        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        for (fields) |field| {
            try writeMultipartPart(self.allocator, &body_buf, boundary, field);
        }
        // 终止 boundary
        try body_buf.appendSlice(self.allocator, "--");
        try body_buf.appendSlice(self.allocator, boundary);
        try body_buf.appendSlice(self.allocator, "--\r\n");

        const content_type = try std.fmt.allocPrint(
            self.allocator,
            "multipart/form-data; boundary={s}",
            .{boundary},
        );
        defer self.allocator.free(content_type);

        const payload = try body_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(payload);

        return self.fetchWithStatus(effective_uri, .POST, payload, content_type);
    }

    /// POST XML + TLS 客户端证书（对照 `PostXMLWithTLS`，用于微信支付）。
    ///
    /// 流程：
    /// 1. 读取 `p12_path` 文件；
    /// 2. 用 `util.rsa.parseP12` 解出 cert/key PEM；
    /// 3. 使用 httpz + OpenSSL 进行 mTLS 握手；
    /// 4. 发送 `Content-Type: application/xml` POST 请求并返回响应体。
    pub fn postXMLWithTLS(
        self: *HttpClient,
        uri: []const u8,
        body: []const u8,
        p12_path: []const u8,
        p12_password: []const u8,
    ) ![]u8 {
        const effective_uri = applyUriModifier(uri);
        const io = std.Io.Threaded.global_single_threaded.io();

        // 1. 读取 P12 文件
        const p12_bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            p12_path,
            self.allocator,
            .limited(1024 * 1024),
        );
        defer self.allocator.free(p12_bytes);

        // 2. 解析出 cert + key PEM
        const p12 = try rsa.parseP12(self.allocator, p12_bytes, p12_password);
        defer {
            self.allocator.free(p12.cert_pem);
            self.allocator.free(p12.key_pem);
        }

        // 3. 解析 URL
        const parsed = httpz.Client.Url.parse(effective_uri) orelse return error.InvalidUri;

        // 4. 构造 client cert 配置
        const ckp = httpz.tls.config.CertKeyPair{
            .cert_pem = p12.cert_pem,
            .key_pem = p12.key_pem,
            .allocator = self.allocator,
        };
        const tls_cfg = httpz.tls.config.Client{
            .host = parsed.host,
            .disable_h2 = true,
            .cert = &ckp,
        };

        // 5. 使用 httpz 客户端完成 mTLS 请求
        var client = httpz.Client.init(self.allocator, .{
            .host = parsed.host,
            .port = parsed.port,
            .tls_config = tls_cfg,
        });
        defer client.deinit();

        try client.connect(io);

        var headers = httpz.Headers{};
        try headers.append("Content-Type", "application/xml;charset=utf-8");

        var resp = try client.request(io, .POST, parsed.path, headers, body);
        defer resp.deinit(self.allocator);

        if (resp.status.toInt() != 200) {
            return error.HttpStatusNotOk;
        }

        return self.allocator.dupe(u8, resp.body);
    }

    // -------------------------------------------------------------------------
    // 内部辅助
    // -------------------------------------------------------------------------

    /// 实际发送请求并收取响应体；状态码非 200 时返回 `error.HttpStatusNotOk`。
    fn fetchWithStatus(
        self: *HttpClient,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) ![]u8 {
        const effective_uri = applyUriModifier(uri);

        if (self.transport) |t| {
            return t(self.transport_ctx.?, self.allocator, effective_uri, method, payload, content_type);
        }

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();

        var headers: std.http.Client.Request.Headers = .{};
        if (content_type) |ct| {
            headers.content_type = .{ .override = ct };
        }

        const result = self.inner.fetch(.{
            .method = method,
            .location = .{ .url = effective_uri },
            .payload = if (payload.len == 0 and method == .GET) null else payload,
            .response_writer = &body_writer.writer,
            .headers = headers,
        }) catch |err| return err;

        if (result.status != .ok) {
            return error.HttpStatusNotOk;
        }

        var list = body_writer.toArrayList();
        defer list.deinit(self.allocator);
        return list.toOwnedSlice(self.allocator);
    }

    /// 返回 self 自身的指针作为 transport ctx（备用，子类型可扩展）。
    fn getPtr(self: *HttpClient) *anyopaque {
        return @ptrCast(self);
    }
};

/// 一个可直接使用的 Mock transport：用一张 (uri → response) 映射代替真实网络。
///
/// 测试时构造一个 `MockTransport`，将其函数指针注入 `HttpClient.setTransport`，
/// 所有 HTTP 调用都会被该映射截获并返回预设响应。
pub const MockTransport = struct {
    allocator: std.mem.Allocator,
    /// 内部映射（uri → response body + status）。
    routes: std.HashMap([]const u8, Response, std.hash_map.StringContext, 80),
    /// 调用历史（uri 列表），用于断言。
    history: std.ArrayList([]const u8),

    pub const Response = struct {
        body: []const u8,
        status: u16 = 200,
    };

    pub fn init(allocator: std.mem.Allocator) MockTransport {
        return .{
            .allocator = allocator,
            .routes = .init(allocator),
            .history = .empty,
        };
    }

    pub fn deinit(self: *MockTransport) void {
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
        self.routes.deinit();
    }

    /// 注册一个 URI → 响应的映射。
    pub fn addRoute(self: *MockTransport, uri: []const u8, response: Response) !void {
        try self.routes.put(uri, response);
    }

    /// Transport 函数指针（符合 `HttpClient.Transport` 签名）。
    pub fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = method;
        _ = payload;
        _ = content_type;
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        try self.history.append(self.allocator, try self.allocator.dupe(u8, uri));
        const gop = self.routes.getEntry(uri) orelse return error.MockNoRoute;
        return allocator.dupe(u8, gop.value_ptr.body) catch return error.OutOfMemory;
    }
};

/// 应用 URI 修改器（如未设置则原样返回）。
fn applyUriModifier(uri: []const u8) []const u8 {
    if (uri_modifier) |m| return m(uri);
    return uri;
}

/// 生成 24 字节 hex 形式的 multipart boundary。
///
/// 使用 `std.Io.Threaded.global_single_threaded` 的 random 熵源，
/// 与 HTTP client 共用同一个 Io 实例。
fn generateBoundary(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [12]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    const charset = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 15];
    }
    return out;
}

/// 写入单个 multipart 字段。
fn writeMultipartPart(
    allocator: std.mem.Allocator,
    body_buf: *std.ArrayList(u8),
    boundary: []const u8,
    field: MultipartField,
) !void {
    // 分隔行 + Content-Disposition
    try body_buf.appendSlice(allocator, "--");
    try body_buf.appendSlice(allocator, boundary);
    try body_buf.appendSlice(allocator, "\r\n");
    try body_buf.appendSlice(allocator, "Content-Disposition: form-data; name=\"");
    try body_buf.appendSlice(allocator, field.field_name);
    try body_buf.appendSlice(allocator, "\"; filename=\"");
    try body_buf.appendSlice(allocator, field.filename);
    try body_buf.appendSlice(allocator, "\"\r\n");
    try body_buf.appendSlice(allocator, "Content-Type: application/octet-stream\r\n");
    try body_buf.appendSlice(allocator, "\r\n");

    if (field.is_file) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(
            field.file_path,
            io,
            .{ .mode = .read_only },
        ) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.size > 0) {
            const file_buf = try allocator.alloc(u8, stat.size);
            defer allocator.free(file_buf);
            const read = try file.readPositionalAll(io, file_buf, 0);
            try body_buf.appendSlice(allocator, file_buf[0..read]);
        }
    } else {
        try body_buf.appendSlice(allocator, field.value);
    }

    try body_buf.appendSlice(allocator, "\r\n");
}

// =============================================================================
// 内联测试
// =============================================================================

test "HttpClient.init/deinit 无泄漏" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();
    try std.testing.expectEqual(allocator, client.allocator);
}

test "setUriModifier 工作（设置/清除后行为正确）" {
    // 初始：未设置，原样返回。
    try std.testing.expect(uri_modifier == null);
    try std.testing.expectEqualStrings("https://example.com", applyUriModifier("https://example.com"));

    // 自定义 modifier：返回一个常量字符串前缀（测试断言 modifier 被实际调用）。
    const StaticMod = struct {
        fn m(_: []const u8) []const u8 {
            return "https://proxy.example.com/";
        }
    };
    setUriModifier(StaticMod.m);
    defer setUriModifier(null);
    try std.testing.expectEqualStrings("https://proxy.example.com/", applyUriModifier("https://example.com"));

    // 清除后恢复。
    setUriModifier(null);
    try std.testing.expect(uri_modifier == null);
    try std.testing.expectEqualStrings("https://example.com", applyUriModifier("https://example.com"));
}

test "generateBoundary 输出 24 字符 hex" {
    const a = try generateBoundary(std.testing.allocator);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(@as(usize, 24), a.len);
    for (a) |c| try std.testing.expect(std.ascii.isHex(c));
}

test "MultipartField 结构体字段类型可见" {
    const f = MultipartField{
        .is_file = false,
        .field_name = "name",
        .filename = "file.txt",
        .value = "hello",
        .file_path = "",
    };
    try std.testing.expectEqualStrings("name", f.field_name);
    try std.testing.expectEqualStrings("hello", f.value);
    try std.testing.expect(!f.is_file);
}

test "postXMLWithTLS 缺少 P12 文件返回 FileNotFound" {
    var client = HttpClient.init(std.testing.allocator);
    defer client.deinit();
    const result = client.postXMLWithTLS(
        "https://api.mch.weixin.qq.com/secapi/pay/refund",
        "<xml/>",
        "/tmp/dummy_zwechat_not_exist.p12",
        "pwd",
    );
    try std.testing.expectError(error.FileNotFound, result);
}

test "postXMLWithTLS 非法 P12 文件返回 InvalidP12File" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp_path = "/tmp/zwechat_bad_p12_test.p12";

    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    }
    try file.writePositionalAll(io, "not a p12", 0);

    var client = HttpClient.init(allocator);
    defer client.deinit();
    const result = client.postXMLWithTLS(
        "https://api.mch.weixin.qq.com/secapi/pay/refund",
        "<xml/>",
        tmp_path,
        "pwd",
    );
    try std.testing.expectError(error.InvalidP12File, result);
}

test "模块公共 API 全部导出" {
    _ = HttpClient.init;
    _ = HttpClient.deinit;
    _ = getDefaultClient;
    _ = setUriModifier;
    _ = applyUriModifier;
}

test "MockTransport 截获 URI 并返回预设响应" {
    const allocator = std.testing.allocator;
    var mock = MockTransport.init(allocator);
    defer mock.deinit();

    try mock.addRoute("https://example.com/api/test", .{ .body = "{\"ok\":true}", .status = 200 });

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setTransport(MockTransport.dispatch, @ptrCast(&mock));

    const resp = try client.get("https://example.com/api/test");
    defer allocator.free(resp);
    try std.testing.expectEqualStrings("{\"ok\":true}", resp);
    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);
}

test "MockTransport 未注册 URI 返回 MockNoRoute" {
    const allocator = std.testing.allocator;
    var mock = MockTransport.init(allocator);
    defer mock.deinit();

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setTransport(MockTransport.dispatch, @ptrCast(&mock));

    const result = client.get("https://example.com/unknown");
    try std.testing.expectError(error.MockNoRoute, result);
}

test "setTransport(null) 恢复默认 transport" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setTransport(null, null);
    try std.testing.expect(client.transport == null);
}
