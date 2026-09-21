// SPDX-License-Identifier: Apache-2.0
//! util/http — HTTP 客户端封装
//!
//! 对应 `_ref/wechat/util/http.go`：提供 `HTTPGet` / `HTTPPost` / `PostJSON` /
//! `PostXML` / `PostMultipartForm` / `PostXMLWithTLS` 六个核心入口。
//!
//! Zig 版基于 std 0.17 的 `std.http.Client.fetch`，把响应体通过
//! `std.Io.Writer.Allocating` 收集到调用方提供的 allocator 上。
//! `io` 实例固定使用 `std.Io.Threaded.global_single_threaded`，适合同步阻塞
//! 场景；如果以后需要并发，可以把 `inner.io` 换成调用方注入的 `Io`。
//!
//! ## 下载体积上限
//!
//! 微信素材（尤其视频）动辄几十 MB，把整个 body 读进内存会让服务端被单个素材
//! 拖爆。需要下载文件时请使用带 `max_bytes` 的入口：
//! `getFollowRedirectLimited`（限额收内存）与 `getFollowRedirectToFile`
//! （流式落盘，超限删除不完整文件）；`getFollowRedirect` 保持不限额的旧语义，
//! 仅供既有调用点与测试使用。
//!
//! ## 默认客户端（线程局部单例）的 allocator 契约
//!
//! `getDefaultClient` 返回**当前线程**的默认 `HttpClient`，实例在使用该线程的
//! 生命周期内一直持有连接池：
//!
//! - **生产代码应在启动期调用 `initDefaultClient(allocator)` 显式初始化**
//!   （严格模式）。此后同线程任何用**不同** allocator 调用 `getDefaultClient`
//!   都会 `@panic`，把"传错/传入已释放的 allocator"从静默的悬垂分配变成立刻
//!   可见的崩溃。
//! - 未显式初始化时按旧行为懒初始化，并**沿用首个调用传入的 allocator**
//!   （后续传入的 allocator 被忽略）——这种宽容语义只为兼容历史调用点，
//!   新代码请一律 `initDefaultClient`；需要显式校验时用
//!   `defaultClientAllocatorMatches`。
//! - `deinitDefaultClient()` 必须在**线程退出前**调用，释放连接池等资源；
//!   实例不会随线程退出自动回收，之后再次 `getDefaultClient` 会以新 allocator
//!   重新初始化。

const std = @import("std");
const httpz = @import("httpz");
const rsa = @import("rsa.zig");

/// multipart/form-data 字段描述（对照 `MultipartFormField`）。
///
/// `is_file = true` 时使用 `file_path` 读取文件内容（按需再扩展为流式读取）；
/// `is_file = false` 时把 `value` 作为字符串体提交。
/// 当 `is_file = true` 且 `data.len > 0` 时，直接以 `data` 字节作为文件内容
/// （用于内存中的二进制数据上传，如小程序微短剧分片）。
pub const MultipartField = struct {
    is_file: bool,
    field_name: []const u8,
    filename: []const u8,
    value: []const u8,
    file_path: []const u8 = "",
    data: []const u8 = "",
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

/// 线程局部默认客户端的初始化记录。
const DefaultClientState = struct {
    client: HttpClient,
    /// 初始化时记录的 allocator，`getDefaultClient` 用它做一致性校验。
    allocator: std.mem.Allocator,
    /// 是否由 `initDefaultClient` 在启动期显式初始化。严格模式下，任何
    /// allocator 不一致的 `getDefaultClient` 都会 `@panic`（fail-closed）。
    strict: bool,
};

/// 线程局部的默认 `HttpClient`。第一次调用 `initDefaultClient` / `getDefaultClient`
/// 时初始化。
threadlocal var default_client: ?DefaultClientState = null;

/// 判断两个 `Allocator` 是否为同一个（`std.mem.Allocator` 无 `==` 运算符）。
fn sameAllocator(a: std.mem.Allocator, b: std.mem.Allocator) bool {
    return a.ptr == b.ptr and a.vtable == b.vtable;
}

/// 启动期显式初始化**当前线程**的默认 `HttpClient`，并记录其 allocator。
///
/// - 首次调用：用 `allocator` 创建实例，并进入**严格模式**；
/// - 重复调用且 allocator 一致：幂等（不改动既有实例，仅确保严格模式）；
/// - 重复调用但 allocator 不一致：返回 `error.AllocatorMismatch`，不改动既有实例。
///
/// 严格模式下，任何用不同 allocator 调用 `getDefaultClient` 的行为都会 `@panic`，
/// 因为实例的分配器在初始化时即固定：拿已释放的 arena 之类的 allocator 调用，
/// 后果是静默的悬垂分配，因此这里选择 fail-closed（崩溃立即可见），而不是返回
/// 一个错误（`getDefaultClient` 的返回类型是 `*HttpClient`，全仓 189 处调用点
/// 依赖这一签名，改成错误联合会破坏兼容）。
///
/// 注意：本函数只影响**当前线程**。多线程程序需要每个线程各自初始化，
/// 或在使用该线程前调用一次。
pub fn initDefaultClient(allocator: std.mem.Allocator) !void {
    if (default_client) |*state| {
        if (!sameAllocator(state.allocator, allocator)) return error.AllocatorMismatch;
        state.strict = true;
        return;
    }
    default_client = .{
        .client = HttpClient.init(allocator),
        .allocator = allocator,
        .strict = true,
    };
}

/// 返回线程局部的默认 `HttpClient`。同一线程上重复调用得到的是同一份实例；
/// 不同线程各自一份，互不影响。
///
/// **allocator 语义**：实例使用的 allocator 由**首次**初始化时传入的参数决定，
/// 之后不可更换：
/// - 若已通过 `initDefaultClient` 显式初始化（严格模式），后续传入不一致的
///   allocator 会 `@panic`——"传错分配器"从静默变成立刻可见；
/// - 若只是懒初始化（历史写法），后续传入的其他 allocator 仍被忽略以保持兼容，
///   但可用 `defaultClientAllocatorMatches` 显式校验，或先调用
///   `deinitDefaultClient()` 再以新 allocator 重新初始化。
///
/// 注意：返回的指针在线程退出后失效；线程结束前应调用 `deinitDefaultClient`
/// 释放内部连接池等资源。
pub fn getDefaultClient(allocator: std.mem.Allocator) *HttpClient {
    if (default_client) |*state| {
        if (!sameAllocator(state.allocator, allocator) and state.strict) {
            @panic("util.http.getDefaultClient: allocator 与 initDefaultClient 记录的不一致。" ++
                "默认客户端是线程局部单例，allocator 在首次初始化时固定，之后不可更换；" ++
                "请始终用同一个 allocator 调用，或先 deinitDefaultClient() 再重新初始化。");
        }
        return &state.client;
    }
    default_client = .{
        .client = HttpClient.init(allocator),
        .allocator = allocator,
        .strict = false,
    };
    return &default_client.?.client;
}

/// 判断 `allocator` 是否与当前线程默认客户端初始化时记录的 allocator 一致。
///
/// 未初始化时返回 `true`（任何 allocator 都可用于首次初始化）。用于懒初始化
/// 场景下显式校验，避免在被释放的 allocator 上分配。
pub fn defaultClientAllocatorMatches(allocator: std.mem.Allocator) bool {
    const state = default_client orelse return true;
    return sameAllocator(state.allocator, allocator);
}

/// 释放线程局部的默认 `HttpClient`（若已初始化），并将该线程的实例置空。
///
/// 应在线程退出前调用，避免 `std.http.Client` 的连接池等资源滞留到进程结束；
/// 之后若再次调用 `getDefaultClient` 会重新初始化一份新实例（可换 allocator）。
pub fn deinitDefaultClient() void {
    if (default_client) |*state| {
        state.client.deinit();
        default_client = null;
    }
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

    /// GET 请求并手动跟随 redirect（用于微信 media/get、素材下载等会
    /// 302 到 CDN 的接口）。
    ///
    /// 语义与安全约束：
    /// - 仅当响应状态为 301/302/303/307/308 且携带 `Location` 头时跳转，
    ///   最多跳 `max_redirect_hops` 次，超出返回 `error.TooManyRedirects`；
    /// - 跳前校验 Location：绝对 URL 仅允许 `http` / `https` scheme
    ///   （拒绝 `file:` / `javascript:` 等开放重定向滥用），以 `/` 开头的
    ///   相对路径基于当前 URL 的 scheme + host 解析成绝对 URL，
    ///   其他形态返回 `error.InvalidRedirectLocation`；
    /// - 跳数耗尽或非 redirect 的最终状态码非 200 时返回
    ///   `error.HttpStatusNotOk`；redirect 响应缺少 `Location` 头同样返回
    ///   `error.HttpStatusNotOk`（与既有非 200 行为一致）；
    /// - 注入了 transport（mock）时不做 redirect 处理，直接返回 transport
    ///   的响应（mock 语义与 `get` 保持一致）。
    ///
    /// **不限体积**：素材动辄几十 MB，生产代码应改用带 `max_bytes` 的
    /// `getFollowRedirectLimited`（限额收内存）或 `getFollowRedirectToFile`
    /// （流式落盘）。本方法保留不限额的旧语义，仅为兼容既有调用点与测试。
    ///
    /// 返回的 body 由调用方负责 `free`。
    pub fn getFollowRedirect(self: *HttpClient, uri: []const u8) ![]u8 {
        if (self.transport != null) return self.get(uri);

        var sink: MemorySink = .{ .allocator = self.allocator };
        defer sink.deinit();
        _ = try self.followRedirectInto(uri, &sink);
        return sink.take();
    }

    /// 同 `getFollowRedirect`，但响应体超过 `max_bytes` 立即失败。
    ///
    /// 实现取舍：
    /// - 未注入 transport 时是**真流式**：先用 `Content-Length` 预判（服务端声明
    ///   的体积就超限时连 body 都不读），随后逐块读入并累加，一旦超限立即中止并
    ///   返回 `error.ResponseTooLarge`——永远不会把超限素材整个读进内存；
    /// - 注入 transport（mock）时底层没有流式能力，只能读完后判定（超限同样返回
    ///   `error.ResponseTooLarge`，但内存已被占用），仅用于测试注入。
    ///
    /// 返回的 body 由调用方负责 `free`。
    pub fn getFollowRedirectLimited(self: *HttpClient, uri: []const u8, max_bytes: usize) ![]u8 {
        if (self.transport != null) {
            const body = try self.get(uri);
            if (body.len > max_bytes) {
                self.allocator.free(body);
                return error.ResponseTooLarge;
            }
            return body;
        }

        var sink: MemorySink = .{ .allocator = self.allocator, .max_bytes = max_bytes };
        defer sink.deinit();
        _ = try self.followRedirectInto(uri, &sink);
        return sink.take();
    }

    /// 同 `getFollowRedirect`，但把响应体**流式写入** `file_path`，返回写入字节数。
    ///
    /// - 边收边写，响应体不驻留内存（大素材安全）；
    /// - 超过 `max_bytes` 时中止并**删除不完整文件**，返回 `error.ResponseTooLarge`；
    ///   跳数超限、非 200 等其它错误同样不会留下半截文件；
    /// - `file_path` 已存在时会被截断覆盖；
    /// - 注入 transport（mock）时先在内存收完再落盘（mock 无流式能力），超限时
    ///   返回 `error.ResponseTooLarge` 且不创建文件。
    pub fn getFollowRedirectToFile(
        self: *HttpClient,
        uri: []const u8,
        file_path: []const u8,
        max_bytes: usize,
    ) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();

        if (self.transport != null) {
            const body = try self.get(uri);
            defer self.allocator.free(body);
            if (body.len > max_bytes) return error.ResponseTooLarge;
            return writeFileAll(io, file_path, body);
        }

        const file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        var sink: FileSink = .{ .io = io, .file = file, .max_bytes = max_bytes };
        const outcome = self.followRedirectInto(uri, &sink);
        // 先关闭句柄再删除：Windows 不允许删除仍处于打开状态的文件。
        file.close(io);
        return outcome catch |err| {
            std.Io.Dir.cwd().deleteFile(io, file_path) catch {};
            return err;
        };
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
        //    （v0.6.0 起 `Client.init` 返回 `error{OutOfMemory}!Client`，需 `try`）
        var client = try httpz.Client.init(self.allocator, .{
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
            const tctx = self.transport_ctx orelse
                @panic("HttpClient.transport 已设置但 transport_ctx 为空：请用 setTransport 同时传入两者");
            return t(tctx, self.allocator, effective_uri, method, payload, content_type);
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

    /// 手动跟随 redirect：最后一次 GET 的结果 + 交给 sink 的字节数。
    ///
    /// 注意：redirect 中间响应的 body 不入 sink（读完即丢），因此 `written` 始终
    /// 只统计最终 200 响应的 body。
    const ManualGetResult = struct {
        status: std.http.Status,
        location: ?[]u8,
        written: u64,
    };

    /// 手动跟随 redirect 并把最终响应体**流式**交给 `sink`（见文件末尾的 sink 契约）。
    ///
    /// 返回写入 sink 的字节数。跳转语义与 `getFollowRedirect` 完全一致：仅跟随
    /// 301/302/303/307/308 且最多 `max_redirect_hops` 跳，非 200 返回
    /// `error.HttpStatusNotOk`，redirect 响应缺 `Location` 头同样返回该错误。
    fn followRedirectInto(self: *HttpClient, uri: []const u8, sink: anytype) !u64 {
        var current: []u8 = try self.allocator.dupe(u8, uri);
        defer self.allocator.free(current);

        var hops: u8 = 0;
        while (true) {
            const result = try self.fetchGetManualInto(current, sink);
            defer if (result.location) |loc| {
                self.allocator.free(loc);
            };

            if (!isRedirectStatus(result.status)) {
                if (result.status != .ok) return error.HttpStatusNotOk;
                return result.written;
            }
            // redirect 状态码：必须有 Location 头。
            const location = result.location orelse return error.HttpStatusNotOk;
            hops += 1;
            if (hops > max_redirect_hops) return error.TooManyRedirects;

            const next = try resolveRedirectUri(self.allocator, current, location);
            defer self.allocator.free(next);
            self.allocator.free(current);
            current = try self.allocator.dupe(u8, next);
        }
    }

    /// 单次 GET：`redirect_behavior = .unhandled`，把 301/302/303/307/308 原样返回
    /// 给调用方解析（`fetch` 默认会自动跟随且无法校验 Location）。
    ///
    /// body **逐块**流给 `sink`：`sink.accepts(status)` 为 false 时读完丢弃；
    /// 为 true 时先做 `Content-Length` 预判，再用 16 KiB 缓冲块边读边交，
    /// sink 可在任意时刻以 `error.ResponseTooLarge` 中止（不会读完整个 body）。
    fn fetchGetManualInto(self: *HttpClient, uri: []const u8, sink: anytype) !ManualGetResult {
        const effective_uri = applyUriModifier(uri);
        const parsed = std.Uri.parse(effective_uri) catch return error.InvalidUri;

        var req = try self.inner.request(.GET, parsed, .{
            .redirect_behavior = .unhandled,
            // 关闭 gzip/deflate 协商，简化手动路径（不需要解压缓冲）。
            .headers = .{ .accept_encoding = .omit },
        });
        defer req.deinit();
        try req.sendBodiless();

        var response = try req.receiveHead(&.{});
        // `head.location` 指向 head buffer，body 流初始化后即失效，必须先拷贝。
        const location: ?[]u8 = if (response.head.location) |loc|
            try self.allocator.dupe(u8, loc)
        else
            null;
        errdefer if (location) |loc| self.allocator.free(loc);

        const status = response.head.status;
        const want_body = sink.accepts(status);
        if (want_body) try sink.hintLength(response.head.content_length);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, &.{});

        var written: u64 = 0;
        var chunk_buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&chunk_buf) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr().?,
            };
            if (n == 0) break;
            if (!want_body) continue;
            try sink.write(chunk_buf[0..n]);
            written += n;
        }

        return .{
            .status = status,
            .location = location,
            .written = written,
        };
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
    ///
    /// **所有权**：`uri` 作为键直接借用（不做拷贝），`response.body` 同样借用；
    /// 二者必须比本 `MockTransport` 活得久（通常用字符串字面量 / 静态数组）。
    /// 响应 body 在 dispatch 时按需拷贝给调用方。
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

/// GET 手动跟随 redirect 允许的最大跳数（微信 media/get 通常 1 跳到 CDN，
/// 留一倍余量，同时限制被恶意链路拖死的暴露面）。
pub const max_redirect_hops = 2;

/// 判断状态码是否为可跟随的 redirect（301/302/303/307/308）。
fn isRedirectStatus(status: std.http.Status) bool {
    return switch (status) {
        .moved_permanently, // 301
        .found, // 302
        .see_other, // 303
        .temporary_redirect, // 307
        .permanent_redirect, // 308
        => true,
        else => false,
    };
}

/// 响应体落点契约（`followRedirectInto` 的 `sink` 参数，编译期鸭子类型）：
/// - `accepts(status) bool`：该状态码的 body 是否需要；false 时 body 仍被读完但丢弃；
/// - `hintLength(?u64) !void`：拿到 `Content-Length` 时的预判机会，可提前失败；
/// - `write(chunk) !void`：接收一段 body 字节，超限时返回 `error.ResponseTooLarge`。
/// 内存落点：把 body 收进 `ArrayList(u8)`；`max_bytes` 非空时边读边累加检查。
const MemorySink = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    /// `null` 表示不限量（`getFollowRedirect` 的既有语义）。
    max_bytes: ?usize = null,

    /// 只关心 200 的 body：非 200 响应的 body 读完即丢（与旧实现一致）。
    fn accepts(self: *MemorySink, status: std.http.Status) bool {
        _ = self;
        return status == .ok;
    }

    fn hintLength(self: *MemorySink, content_length: ?u64) !void {
        const max = self.max_bytes orelse return;
        if (content_length) |len| {
            if (len > @as(u64, max)) return error.ResponseTooLarge;
        }
    }

    fn write(self: *MemorySink, chunk: []const u8) !void {
        if (self.max_bytes) |max| {
            if (self.list.items.len + chunk.len > max) return error.ResponseTooLarge;
        }
        try self.list.appendSlice(self.allocator, chunk);
    }

    fn deinit(self: *MemorySink) void {
        self.list.deinit(self.allocator);
    }

    /// 交出所有权；调用方负责 `free`。
    fn take(self: *MemorySink) ![]u8 {
        return self.list.toOwnedSlice(self.allocator);
    }
};

/// 文件落点：把 body 逐块流式写入已打开的 `file`，返回写入字节数。
///
/// 定位写（`writePositionalAll`）而非追加，便于调用方在 `deinitDefaultClient`
/// 之类的极端场景下复用同一句柄语义；文件由调用方创建 / 关闭 / 清理。
const FileSink = struct {
    io: std.Io,
    file: std.Io.File,
    max_bytes: usize,
    written: u64 = 0,

    fn accepts(self: *FileSink, status: std.http.Status) bool {
        _ = self;
        return status == .ok;
    }

    fn hintLength(self: *FileSink, content_length: ?u64) !void {
        if (content_length) |len| {
            if (len > @as(u64, self.max_bytes)) return error.ResponseTooLarge;
        }
    }

    fn write(self: *FileSink, chunk: []const u8) !void {
        const total = self.written + chunk.len;
        if (total > @as(u64, self.max_bytes)) return error.ResponseTooLarge;
        try self.file.writePositionalAll(self.io, chunk, self.written);
        self.written = total;
    }
};

/// 一次性把 `bytes` 写入（创建或截断）`file_path`；写失败时删除不完整文件，
/// 返回写入字节数。
fn writeFileAll(io: std.Io, file_path: []const u8, bytes: []const u8) !u64 {
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    var ok = false;
    defer if (!ok) std.Io.Dir.cwd().deleteFile(io, file_path) catch {};
    file.writePositionalAll(io, bytes, 0) catch |err| {
        file.close(io);
        return err;
    };
    file.close(io);
    ok = true;
    return bytes.len;
}

/// 解析 redirect 的 `Location` 头为下一步要请求的绝对 URL。
///
/// - 绝对 URL：仅允许 `http` / `https` scheme，其他（`file:` /
///   `javascript:` / `ftp:` 等）返回 `error.InvalidRedirectLocation`；
/// - 以 `/` 开头的相对路径：基于 `base_uri` 的 scheme + host 拼成绝对 URL；
/// - 其他形态（空、协议相对 `//host` 等）一律拒绝。
fn resolveRedirectUri(
    allocator: std.mem.Allocator,
    base_uri: []const u8,
    location: []const u8,
) ![]u8 {
    if (std.ascii.startsWithIgnoreCase(location, "http://") or
        std.ascii.startsWithIgnoreCase(location, "https://"))
    {
        return allocator.dupe(u8, location);
    }
    // 协议相对 URL（`//host/path`）不在此解析（避免把 authority 误当 path）。
    if (location.len < 2 or location[0] != '/' or location[1] == '/')
        return error.InvalidRedirectLocation;
    const base = std.Uri.parse(base_uri) catch return error.InvalidRedirectLocation;
    const host = base.host orelse return error.InvalidRedirectLocation;
    if (base.scheme.len == 0) return error.InvalidRedirectLocation;
    var host_buf: [1024]u8 = undefined;
    const host_raw = host.toRaw(&host_buf) catch return error.InvalidRedirectLocation;
    // 注意保留端口：std.Uri 的 host 不含 port，丢端口会打到默认 80/443。
    if (base.port) |port| {
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ base.scheme, host_raw, port, location });
    }
    return std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ base.scheme, host_raw, location });
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
        if (field.data.len > 0) {
            // 直接使用内存中的二进制数据。
            try body_buf.appendSlice(allocator, field.data);
        } else {
            const io = std.Io.Threaded.global_single_threaded.io();
            const file = std.Io.Dir.cwd().openFile(
                io,
                field.file_path,
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

test "getDefaultClient/deinitDefaultClient 生命周期闭环" {
    const allocator = std.testing.allocator;
    const first = getDefaultClient(allocator);
    const second = getDefaultClient(allocator);
    // 同线程重复调用得到同一份实例（threadlocal 地址固定）。
    try std.testing.expect(first == second);
    // 释放后可再次安全调用（不 double-free、不崩溃），
    // 再次初始化仍可用；整体循环在 testing allocator 下无泄漏。
    deinitDefaultClient();
    _ = getDefaultClient(allocator);
    deinitDefaultClient();
    deinitDefaultClient(); // 幂等：未初始化时调用是 no-op
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
        "zwechat_test_not_exist.p12",
        "pwd",
    );
    try std.testing.expectError(error.FileNotFound, result);
}

test "postXMLWithTLS 非法 P12 文件返回 InvalidP12File" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // 相对路径：不依赖平台 /tmp 语义（Windows 上无统一 /tmp）。
    const tmp_path = "zwechat_test_bad_p12.p12";

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

// ─────────────────────────────────────────────────────────────────────────────
// 假 HTTP server：验证 getFollowRedirect 的 redirect 手动跟随语义。
// 约定与 redis/memcache 的 mock server 一致：127.0.0.1 + std.Io.net.Server。
// ─────────────────────────────────────────────────────────────────────────────

/// 假 HTTP server 线程状态：按顺序为每个连接回一份预设的原始 HTTP 响应，
/// 并把每个请求的请求行追加到 `capture`（用于断言最终请求了哪个 URL）。
const FakeServerState = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    /// 每个连接要返回的原始 HTTP 响应字节（按顺序消费，消费完线程退出）。
    responses: []const []const u8,
    hits: *std.atomic.Value(u32),
    /// 请求行捕获缓冲（形如 "GET /final HTTP/1.1;"）。
    capture: []u8,
    capture_len: *usize,

    fn run(self: *const FakeServerState) void {
        for (self.responses) |resp| {
            var stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);

            // 读完请求头（直到空行），避免对端 RST 干扰响应写入。
            var header_buf: [8192]u8 = undefined;
            var filled: usize = 0;
            while (std.mem.indexOf(u8, header_buf[0..filled], "\r\n\r\n") == null) {
                if (filled >= header_buf.len) return;
                var chunk: [1][]u8 = .{header_buf[filled..]};
                const n = stream.read(self.io, &chunk) catch return;
                if (n == 0) return;
                filled += n;
            }
            // 捕获请求行（第一个 \r\n 之前）。
            if (std.mem.indexOf(u8, header_buf[0..filled], "\r\n")) |eol| {
                const line = header_buf[0..eol];
                if (self.capture_len.* + line.len + 1 <= self.capture.len) {
                    @memcpy(self.capture[self.capture_len.*..][0..line.len], line);
                    self.capture[self.capture_len.* + line.len] = ';';
                    self.capture_len.* += line.len + 1;
                }
            }
            _ = self.hits.fetchAdd(1, .seq_cst);

            var write_buf: [4096]u8 = undefined;
            var w = stream.writer(self.io, &write_buf);
            w.interface.writeAll(resp) catch return;
            w.interface.flush() catch return;
        }
    }
};

/// 在 127.0.0.1 上从 18081 起探测一个可绑定的端口并监听。
fn listenLocal(io: std.Io) !struct { server: std.Io.net.Server, port: u16 } {
    var port: u16 = 18081;
    while (true) {
        const addr: std.Io.net.IpAddress = .{ .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = port,
        } };
        if (std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true })) |server| {
            return .{ .server = server, .port = port };
        } else |err| switch (err) {
            error.AddressInUse => {
                port += 1;
                if (port > 19000) return err;
                continue;
            },
            else => return err,
        }
    }
}

/// 连上目标端口后立即关闭：用于让阻塞在 accept 的假服务器线程退出，
/// 使 `join` 不会死锁（负面用例中客户端可能提前失败、少发请求）。
fn unblockAccept(io: std.Io, port: u16) void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = port,
    } };
    var stream = addr.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

test "getFollowRedirect 跟随 302 拿到最终内容且请求了第二个 URL" {
    const allocator = std.testing.allocator;
    // server 线程使用独立 Io（global_single_threaded 非线程安全，禁止跨线程共享）。
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    var resp_first_buf: [256]u8 = undefined;
    const resp_first = try std.fmt.bufPrint(
        &resp_first_buf,
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{bound.port},
    );
    const responses = [_][]const u8{
        resp_first,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 16\r\nConnection: close\r\n\r\nfake-media-bytes",
    };
    const state = FakeServerState{
        .io = sio,
        .server = &server,
        .responses = &responses,
        .hits = &hits,
        .capture = &capture,
        .capture_len = &capture_len,
    };
    const t = try std.Thread.spawn(.{}, FakeServerState.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    const body = try client.getFollowRedirect(uri);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("fake-media-bytes", body);
    // 共请求 2 次：第一次 302，第二次 /final 拿内容。
    try std.testing.expectEqual(@as(u32, 2), hits.load(.seq_cst));
    try std.testing.expect(std.mem.indexOf(u8, capture[0..capture_len], "GET /final HTTP/1.1") != null);
}

test "getFollowRedirect 拒绝非 http/https 的 Location" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    const responses = [_][]const u8{
        "HTTP/1.1 302 Found\r\nLocation: ftp://evil.example/x.bin\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    };
    const state = FakeServerState{
        .io = sio,
        .server = &server,
        .responses = &responses,
        .hits = &hits,
        .capture = &capture,
        .capture_len = &capture_len,
    };
    const t = try std.Thread.spawn(.{}, FakeServerState.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(error.InvalidRedirectLocation, client.getFollowRedirect(uri));
    unblockAccept(sio, bound.port);
    try std.testing.expectEqual(@as(u32, 1), hits.load(.seq_cst));
}

test "getFollowRedirect 跳数超限返回 TooManyRedirects" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    // 3 次请求：第 3 次响应时跳数超限（max_redirect_hops = 2）。
    const responses = [_][]const u8{
        "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    };
    const state = FakeServerState{
        .io = sio,
        .server = &server,
        .responses = &responses,
        .hits = &hits,
        .capture = &capture,
        .capture_len = &capture_len,
    };
    const t = try std.Thread.spawn(.{}, FakeServerState.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(error.TooManyRedirects, client.getFollowRedirect(uri));
    // 客户端提前失败后，服务器线程仍阻塞在 accept：补一个空连接让其退出再 join。
    unblockAccept(sio, bound.port);
    try std.testing.expectEqual(@as(u32, 3), hits.load(.seq_cst));
}

// ─────────────────────────────────────────────────────────────────────────────
// 默认客户端的 allocator 契约
// ─────────────────────────────────────────────────────────────────────────────

test "initDefaultClient 幂等，allocator 不一致返回 AllocatorMismatch" {
    const a = std.heap.page_allocator;
    const b = std.testing.allocator;
    defer deinitDefaultClient();
    // 测试共享同一线程的 threadlocal：先清空，保证从"未初始化"开始。
    deinitDefaultClient();

    try initDefaultClient(a);
    const first = getDefaultClient(a);
    try std.testing.expect(first == getDefaultClient(a));
    try std.testing.expect(defaultClientAllocatorMatches(a));
    try std.testing.expect(!defaultClientAllocatorMatches(b));

    // 重复 init 同一 allocator：幂等。
    try initDefaultClient(a);

    // 已初始化后换 allocator：显式失败，既有实例不受影响。
    try std.testing.expectError(error.AllocatorMismatch, initDefaultClient(b));
    try std.testing.expect(first == getDefaultClient(a));
    try std.testing.expect(!defaultClientAllocatorMatches(b));

    // 释放后可换 allocator 重新初始化（线程退出前的正常更替路径）。
    deinitDefaultClient();
    try initDefaultClient(b);
    try std.testing.expect(defaultClientAllocatorMatches(b));
}

test "getDefaultClient 懒初始化沿用首个 allocator，可用校验函数发现不一致" {
    const a = std.heap.page_allocator;
    const b = std.testing.allocator;
    defer deinitDefaultClient();
    deinitDefaultClient();

    const first = getDefaultClient(a);
    // 历史宽容语义：懒初始化（未经 initDefaultClient）后传别的 allocator 不 panic，
    // 仍返回同一实例（分配继续走首个 allocator）。
    const second = getDefaultClient(b);
    try std.testing.expect(first == second);
    // 但通过校验函数可以立刻发现"传错 allocator"。
    try std.testing.expect(defaultClientAllocatorMatches(a));
    try std.testing.expect(!defaultClientAllocatorMatches(b));
}

// ─────────────────────────────────────────────────────────────────────────────
// 限额下载
// ─────────────────────────────────────────────────────────────────────────────

/// 32 字节 payload：chunked 响应（无 Content-Length）用，强制走"边读边累加"路径。
const chunked_payload_32 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
comptime {
    if (chunked_payload_32.len != 32) @compileError("chunked 响应的分片长度声明必须与 payload 一致");
}

test "getFollowRedirectLimited 限额内跟随 302 正常返回" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    var resp_first_buf: [256]u8 = undefined;
    const resp_first = try std.fmt.bufPrint(
        &resp_first_buf,
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{bound.port},
    );
    const responses = [_][]const u8{
        resp_first,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 16\r\nConnection: close\r\n\r\nfake-media-bytes",
    };
    const state = FakeServerState{
        .io = sio,
        .server = &server,
        .responses = &responses,
        .hits = &hits,
        .capture = &capture,
        .capture_len = &capture_len,
    };
    const t = try std.Thread.spawn(.{}, FakeServerState.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    const body = try client.getFollowRedirectLimited(uri, 1024);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("fake-media-bytes", body);
    try std.testing.expectEqual(@as(u32, 2), hits.load(.seq_cst));
}

test "getFollowRedirectLimited 流式累加超限返回 ResponseTooLarge" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    var resp_first_buf: [256]u8 = undefined;
    const resp_first = try std.fmt.bufPrint(
        &resp_first_buf,
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/big\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{bound.port},
    );
    // chunked（无 Content-Length）→ 只能靠边读边累加发现超限。
    const responses = [_][]const u8{
        resp_first,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
            "20\r\n" ++ chunked_payload_32 ++ "\r\n0\r\n\r\n",
    };
    const state = FakeServerState{
        .io = sio,
        .server = &server,
        .responses = &responses,
        .hits = &hits,
        .capture = &capture,
        .capture_len = &capture_len,
    };
    const t = try std.Thread.spawn(.{}, FakeServerState.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(error.ResponseTooLarge, client.getFollowRedirectLimited(uri, 8));
    unblockAccept(sio, bound.port);
    try std.testing.expectEqual(@as(u32, 2), hits.load(.seq_cst));
}

test "getFollowRedirectLimited 用 Content-Length 预判提前失败（不读 body）" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    var resp_first_buf: [256]u8 = undefined;
    const resp_first = try std.fmt.bufPrint(
        &resp_first_buf,
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/huge\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{bound.port},
    );
    // 声明 999999 字节却只发 8 字节：若没做预判，会先撞上 body 读取错误
    // （Content-Length 不符），这里必须直接得到 ResponseTooLarge。
    const responses = [_][]const u8{
        resp_first,
        "HTTP/1.1 200 OK\r\nContent-Length: 999999\r\nConnection: close\r\n\r\n12345678",
    };
    const state = FakeServerState{
        .io = sio,
        .server = &server,
        .responses = &responses,
        .hits = &hits,
        .capture = &capture,
        .capture_len = &capture_len,
    };
    const t = try std.Thread.spawn(.{}, FakeServerState.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(error.ResponseTooLarge, client.getFollowRedirectLimited(uri, 1024));
    unblockAccept(sio, bound.port);
}

test "getFollowRedirectToFile 流式落盘并返回写入字节数" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file_path = "zwechat_http_followredirect_tofile_test.bin";
    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    var resp_first_buf: [256]u8 = undefined;
    const resp_first = try std.fmt.bufPrint(
        &resp_first_buf,
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{bound.port},
    );
    const responses = [_][]const u8{
        resp_first,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 16\r\nConnection: close\r\n\r\nfake-media-bytes",
    };
    const state = FakeServerState{
        .io = sio,
        .server = &server,
        .responses = &responses,
        .hits = &hits,
        .capture = &capture,
        .capture_len = &capture_len,
    };
    const t = try std.Thread.spawn(.{}, FakeServerState.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    const written = try client.getFollowRedirectToFile(uri, file_path, 1024);
    try std.testing.expectEqual(@as(u64, 16), written);

    const got = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(64));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("fake-media-bytes", got);
}

test "getFollowRedirectToFile 超限删除不完整文件" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file_path = "zwechat_http_followredirect_tofile_over_test.bin";
    defer std.Io.Dir.cwd().deleteFile(io, file_path) catch {};

    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    var resp_first_buf: [256]u8 = undefined;
    const resp_first = try std.fmt.bufPrint(
        &resp_first_buf,
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{d}/big\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{bound.port},
    );
    // chunked：让"边写边累加"的检查触发（而非 Content-Length 预判）。
    const responses = [_][]const u8{
        resp_first,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ++
            "20\r\n" ++ chunked_payload_32 ++ "\r\n0\r\n\r\n",
    };
    const state = FakeServerState{
        .io = sio,
        .server = &server,
        .responses = &responses,
        .hits = &hits,
        .capture = &capture,
        .capture_len = &capture_len,
    };
    const t = try std.Thread.spawn(.{}, FakeServerState.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(
        error.ResponseTooLarge,
        client.getFollowRedirectToFile(uri, file_path, 8),
    );
    // 超限时文件已创建（本轮写了部分字节），必须被清理掉。
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, file_path, .{}));
    unblockAccept(sio, bound.port);
}

test "resolveRedirectUri 绝对/相对/非法 Location 语义" {
    const allocator = std.testing.allocator;

    const abs = try resolveRedirectUri(allocator, "http://a.example/x", "https://cdn.example/f.bin");
    defer allocator.free(abs);
    try std.testing.expectEqualStrings("https://cdn.example/f.bin", abs);

    const rel = try resolveRedirectUri(allocator, "http://a.example:8080/x", "/final?q=1");
    defer allocator.free(rel);
    try std.testing.expectEqualStrings("http://a.example:8080/final?q=1", rel);

    try std.testing.expectError(error.InvalidRedirectLocation, resolveRedirectUri(allocator, "http://a.example/x", "ftp://evil.example/x"));
    try std.testing.expectError(error.InvalidRedirectLocation, resolveRedirectUri(allocator, "http://a.example/x", "javascript:alert(1)"));
    try std.testing.expectError(error.InvalidRedirectLocation, resolveRedirectUri(allocator, "http://a.example/x", ""));
    try std.testing.expectError(error.InvalidRedirectLocation, resolveRedirectUri(allocator, "http://a.example/x", "//other.example/y"));
}
