// SPDX-License-Identifier: Apache-2.0
//! util/http — HTTP 客户端封装
//!
//! 对应 `_ref/wechat/util/http.go`：提供 `HTTPGet` / `HTTPPost` / `PostJSON` /
//! `PostXML` / `PostMultipartForm` / `PostXMLWithTLS` 六个核心入口。
//!
//! Zig 版基于 std 0.17 的 `std.http.Client.fetch`，把响应体通过
//! `std.Io.Writer.Allocating` 收集到调用方提供的 allocator 上。
//! `io` 实例固定使用本仓的进程级单例（`util/default_io.zig`），适合同步阻塞
//! 场景；如果以后需要并发，可以把 `inner.io` 换成调用方注入的 `Io`。
//!
//! ## 响应体体积上限
//!
//! - **JSON/XML API 请求**（`get` / `post` / `postJSON` / `postXML` /
//!   `postMultipart` / `sendWithHeaders`）：响应体上限由
//!   `HttpClient.max_response_bytes` 控制，默认 `default_max_response_bytes`
//!   （16 MiB），超限返回 `error.ResponseTooLarge`——服务端用 `Content-Length`
//!   声明超限时连 body 都不读；`0` 表示不限量。
//! - **素材下载**：微信素材（尤其视频）动辄几十 MB，把整个 body 读进内存会让
//!   服务端被单个素材拖爆。需要下载文件时请使用带 `max_bytes` 的入口：
//!   `getFollowRedirectLimited`（限额收内存）与 `getFollowRedirectToFile`
//!   （流式落盘，超限删除不完整文件）；`getFollowRedirect` 保持不限额的旧语义，
//!   仅供既有调用点与测试使用。
//!
//! ## 重定向
//!
//! 重定向交给 `std.http.Client`（`Request.RedirectBehavior.init(n)`）：跳数记账、
//! `Location` 解析（RFC 3986 §5，含 `../`、协议相对 `//host`、纯 query、百分号
//! 编码）、`303` 与 `301/302+POST` 改写为 GET 全部由 std 完成，本模块不再手写
//! 跟随循环。std 接受的目标 scheme 比微信需要的宽（http/ws/https/wss），本模块
//! 在拿到最终 `req.uri` 后把 `ws`/`wss` 收窄掉，保持「只对 http/https 发请求」
//! 的对外承诺（非 http 族 scheme 由 std 在**建连之前**拒绝）。
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
const rsa = @import("rsa.zig");
const mtls = @import("mtls.zig");
const default_io = @import("default_io.zig");

/// JSON/XML 等 API 响应的默认体积上限（16 MiB）。
///
/// 微信 API 的 JSON/XML 应答都在 KB 量级；没有上限时，一个异常（或被劫持）的
/// 上游可以用超长响应把服务端内存吃光。需要更宽/更严的上限时用
/// `HttpClient.setMaxResponseBytes`（`0` = 不限量）。
pub const default_max_response_bytes: usize = 16 * 1024 * 1024;

/// **不带 body** 的请求（GET 等）默认允许跟随的重定向跳数，对齐
/// `std.http.Client` 的默认值。带 body 的请求不跟随重定向（重发 body 有副作用），
/// 3xx 直接算 `error.HttpStatusNotOk`。
pub const default_max_redirects: u16 = 3;

/// 解析重定向 `Location` 用的辅助缓冲大小（RFC 9110 建议 ≥ 8000 字节）。
/// `Location` 超出该缓冲时 std 返回 `error.HttpRedirectLocationOversize`。
const redirect_buffer_len = 8 * 1024;

/// 读取响应体用的中转缓冲（`Response.reader*` 的 `transfer_buffer`）。
const transfer_buffer_len = 64;

/// 一次性 HTTP 响应：状态码 + 响应体。
///
/// 与「只返回 body」的入口（`get` / `post` 等）的区别：非 2xx 时**仍能拿到
/// body**，供调用方解析服务端自带的业务错误码（微信支付 v3 的 4xx/5xx 应答体
/// 里是 `{"code":...,"message":...}`）。
pub const HttpResponse = struct {
    status: std.http.Status,
    /// 响应体，调用方负责 `free`（或用 `deinit`）。
    body: []u8,

    /// 释放响应体。
    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

/// 带请求头的 transport 函数签名（`Transport` 的 header 感知版本）。
///
/// 仅在测试 / 本地 mock 时使用：`std.http.Client` 的真实路径不再需要注入。
pub const HeaderTransport = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    uri: []const u8,
    method: std.http.Method,
    payload: []const u8,
    content_type: ?[]const u8,
    headers: []const std.http.Header,
) anyerror![]u8;

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
    /// 带请求头的自定义 transport（用于 mock）。设置后优先于 `transport`；
    /// 两者互斥（任一 setter 都会清掉另一个），避免「重置」后旧的 mock 仍生效。
    header_transport: ?HeaderTransport = null,

    /// 响应体硬上限（字节）。超过时返回 `error.ResponseTooLarge`；`0` = 不限量。
    ///
    /// 覆盖 `get` / `post` / `postJSON` / `postXML` / `postMultipart` /
    /// `requestWithHeaders` / `sendWithHeaders` / `postWithHeaders` 这几条
    /// **API 请求**路径；素材下载（`getFollowRedirect*`）另有自己的 `max_bytes`。
    /// 注入 transport（mock）时没有流式能力，只能读完后判定，但语义一致。
    max_response_bytes: usize = default_max_response_bytes,

    /// Transport 函数签名：负责真正发出请求并返回响应 body。
    ///
    /// `ctx` 是 `HttpClient.transport_ctx` 的值；其余参数同 `fetchWithStatus`。
    /// 该签名没有请求头参数（历史原因，且全仓多处 mock 依赖它），需要观察请求头
    /// 的 mock 请用 `HeaderTransport` + `setHeaderTransport`。
    pub const Transport = *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8;

    /// 注入自定义 transport + ctx。`t = null` 恢复默认 std.http.Client。
    ///
    /// 与 `setHeaderTransport` 互斥：本函数会清掉已注入的 `HeaderTransport`
    /// （`setTransport(null, null)` 因此是「彻底恢复真实 HTTP」）。
    pub fn setTransport(self: *HttpClient, t: ?Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.header_transport = null;
        self.transport_ctx = ctx;
    }

    /// 注入**带请求头**的自定义 transport + ctx（`t = null` 仅清除它）。
    ///
    /// 与 `setTransport` 互斥（本函数会清掉 `transport`）。用于断言签名头
    /// （`Authorization` / `Wechatpay-Serial` 等）确实被发出。
    pub fn setHeaderTransport(self: *HttpClient, t: ?HeaderTransport, ctx: ?*anyopaque) void {
        self.header_transport = t;
        self.transport = null;
        self.transport_ctx = ctx;
    }

    /// 设置响应体上限（字节）。`0` = 不限量。
    pub fn setMaxResponseBytes(self: *HttpClient, n: usize) void {
        self.max_response_bytes = n;
    }

    /// 创建客户端；当前固定使用本仓进程级单例 `default_io.io()`，
    /// 即同步阻塞模式。如果将来要支持并发，应在此处允许传入 `std.Io`。
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .inner = .{
                .allocator = allocator,
                .io = default_io.io(),
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

    /// GET 请求并跟随 redirect（用于微信 media/get、素材下载等会 302 到 CDN
    /// 的接口）。
    ///
    /// 语义与安全约束：
    /// - 重定向由 `std.http.Client` 处理：只接受 301/302/303/307/308，
    ///   最多跳 `max_redirect_hops` 次，超出返回 `error.TooManyRedirects`；
    /// - `Location` 按 RFC 3986 §5 解析（`../`、协议相对 `//host`、纯 query、
    ///   百分号编码都对）——这部分过去是本模块手写的，现在交给 std；
    /// - 非 `http`/`https` 的 `Location`（`file:` / `ftp:` / `javascript:` 等）
    ///   返回 `error.InvalidRedirectLocation`。std 的目标 scheme 白名单比我们宽
    ///   （多收 ws/wss），这里在拿到最终 `req.uri` 后收窄回 http/https；
    /// - 跳数耗尽、`Location` 头缺失/不合法、最终状态码非 200 时分别返回
    ///   `error.TooManyRedirects` / `error.HttpStatusNotOk` /
    ///   `error.InvalidRedirectLocation` / `error.HttpStatusNotOk`
    ///   （错误名与手写实现时期保持一致，见 `mapRedirectError`）；
    /// - 注入了 transport（mock）时不做 redirect 处理，直接返回 transport
    ///   的响应（mock 语义与 `get` 保持一致）。
    ///
    /// **不限体积**：素材动辄几十 MB，生产代码应改用带 `max_bytes` 的
    /// `getFollowRedirectLimited`（限额收内存）或 `getFollowRedirectToFile`
    /// （流式落盘）。本方法保留不限额的旧语义，仅为兼容既有调用点与测试。
    ///
    /// 返回的 body 由调用方负责 `free`。
    pub fn getFollowRedirect(self: *HttpClient, uri: []const u8) ![]u8 {
        var sink: MemorySink = .{ .allocator = self.allocator };
        defer sink.deinit();
        _ = try self.followRedirectInto(uri, max_redirect_hops, &sink);
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
        var sink: MemorySink = .{ .allocator = self.allocator, .max_bytes = max_bytes };
        defer sink.deinit();
        _ = try self.followRedirectInto(uri, max_redirect_hops, &sink);
        return sink.take();
    }

    /// 同 `getFollowRedirect`，但把响应体**流式写入** `file_path`，返回写入字节数。
    ///
    /// - 边收边写，响应体不驻留内存（大素材安全）；
    /// - 超过 `max_bytes` 时中止并**删除不完整文件**，返回 `error.ResponseTooLarge`；
    ///   跳数超限、非 200 等其它错误同样不会留下半截文件；
    /// - `file_path` 已存在时会被截断覆盖；
    /// - 注入 transport（mock）时先在内存收完再落盘（mock 无流式能力），超限时
    ///   返回 `error.ResponseTooLarge` 且**不创建**文件。
    ///
    /// 注：这里刻意不经过 `followRedirectInto` 的 mock 分支，以保留
    /// 「超限不创建文件」的既有语义（真实路径则先建文件、失败再删）。
    pub fn getFollowRedirectToFile(
        self: *HttpClient,
        uri: []const u8,
        file_path: []const u8,
        max_bytes: usize,
    ) !u64 {
        const io = default_io.io();

        if (self.hasTransport()) {
            const body = (try self.dispatchTransport(applyUriModifier(uri), .GET, "", null, &.{})).?;
            defer self.allocator.free(body);
            if (body.len > max_bytes) return error.ResponseTooLarge;
            return writeFileAll(io, file_path, body);
        }

        const file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        var sink: FileSink = .{ .io = io, .file = file, .max_bytes = max_bytes };
        const outcome = self.followRedirectInto(uri, max_redirect_hops, &sink);
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
    /// 3. 用仓库内自建的 mTLS 通道（`util.mtls`，运行时 dlopen 系统 OpenSSL）
    ///    完成双向认证握手；
    /// 4. 发送 `Content-Type: application/xml` POST 请求并返回响应体。
    ///
    /// **构建开关**：该通道默认关闭（默认构建零 C 依赖、不链接 OpenSSL）。默认
    /// 构建下本方法在读完并解析完 P12 之后返回 `error.MtlsNotEnabled`——需要它时
    /// 用 `zig build -Dmtls=true` 重新构建。若不想开这个开关，微信支付 v2 的退款/
    /// 转账可改用 v3 接口（`pay/v3/refund.zig`、`pay/v3/transfer.zig`：走
    /// RSA 签名，不需要客户端证书）。
    pub fn postXMLWithTLS(
        self: *HttpClient,
        uri: []const u8,
        body: []const u8,
        p12_path: []const u8,
        p12_password: []const u8,
    ) ![]u8 {
        const effective_uri = applyUriModifier(uri);
        const io = default_io.io();

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

        // 3. 走仓库内自建的 mTLS 通道（默认关闭时返回 error.MtlsNotEnabled）。
        //    `ca_file` 传 null：用系统默认信任库校验服务端证书。
        return mtls.postXML(
            self.allocator,
            io,
            effective_uri,
            body,
            p12.cert_pem,
            p12.key_pem,
            null,
        );
    }

    // -------------------------------------------------------------------------
    // 内部辅助
    // -------------------------------------------------------------------------

    /// 是否注入了任意 mock transport。
    fn hasTransport(self: *const HttpClient) bool {
        return self.transport != null or self.header_transport != null;
    }

    /// 把请求交给注入的 mock transport（`header_transport` 优先），未注入时返回
    /// `null` 让调用方走真实 HTTP。
    ///
    /// **不做体积判定**：`max_response_bytes` 与 sink 的 `max_bytes` 由各自的
    /// 调用方检查——`getFollowRedirect` 承诺「不限体积」，不能被 API 层的响应
    /// 上限改变语义。
    fn dispatchTransport(
        self: *HttpClient,
        effective_uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
        headers: []const std.http.Header,
    ) !?[]u8 {
        if (!self.hasTransport()) return null;
        const tctx = self.transport_ctx orelse
            @panic("HttpClient.transport 已设置但 transport_ctx 为空：请用 setTransport/setHeaderTransport 同时传入两者");
        if (self.header_transport) |t| {
            return try t(tctx, self.allocator, effective_uri, method, payload, content_type, headers);
        }
        return try self.transport.?(tctx, self.allocator, effective_uri, method, payload, content_type);
    }

    /// 校验调用方提供的请求头，拒绝头注入面。
    ///
    /// std 的 `Client.request` 只在 `runtime_safety`（debug）构建下断言
    /// 「头名非空、无 `:`、名字与值都不含 CR/LF」；ReleaseFast 下带 CRLF 的头值
    /// 会被原样写进报文——这就是头注入。这里显式拒绝，让失败模式在两种构建下
    /// 一致（`error.InvalidArgument`）。
    fn validateHeaders(headers: []const std.http.Header) !void {
        for (headers) |header| {
            if (header.name.len == 0) return error.InvalidArgument;
            if (std.mem.indexOfScalar(u8, header.name, ':') != null) return error.InvalidArgument;
            if (std.mem.indexOfAny(u8, header.name, "\r\n") != null) return error.InvalidArgument;
            if (std.mem.indexOfAny(u8, header.value, "\r\n") != null) return error.InvalidArgument;
        }
    }

    /// mock 路径的统一收尾：按 `max_response_bytes` 校验响应体体积。
    ///
    /// transport 没有流式能力，只能读完后判定——**语义**与真实路径一致，但超限时
    /// 内存已经被占用（仅测试注入场景，文档已写明）。
    fn checkTransportBody(self: *HttpClient, body: []u8) ![]u8 {
        if (self.max_response_bytes != 0 and body.len > self.max_response_bytes) {
            self.allocator.free(body);
            return error.ResponseTooLarge;
        }
        return body;
    }

    /// 状态码必须是 200 的便捷路径（对照旧的 `fetch` 语义）。
    fn fetchWithStatus(
        self: *HttpClient,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) ![]u8 {
        return self.sendWithHeaders(method, uri, payload, content_type, &.{});
    }

    /// 通用请求，返回 `HttpResponse`（状态码 + body，**不做状态码判定**）。
    ///
    /// 为什么不直接用 `std.http.Client.fetch`：`fetch` 只回 `status`，既拿不到
    /// head（无法在读取前用 `Content-Length` 判定超限），也拿不到非 2xx 的 body
    /// （微信支付 v3 的业务错误码就在 4xx/5xx 应答体里）。因此这里走
    /// `request` + `receiveHead` + `reader.allocRemaining(.limited(max))`。
    ///
    /// - `headers` 走 std 的 `privileged_headers` 槽位：**跨域重定向时会被剥离**，
    ///   凭据类头（`Authorization` 等）不会泄漏到别的域。`Content-Type` 请用
    ///   `content_type` 传，不要在 `headers` 里重复给（std 会把两者都发出去）；
    /// - 带 body 的方法（POST/PUT/PATCH/QUERY，见 `http.Method.requestHasBody`）
    ///   不跟随重定向（重发 body 有副作用），3xx 原样返回；其余方法最多跟随
    ///   `default_max_redirects` 跳（与 `std.http.Client.fetch` 的默认一致）；
    /// - 响应体超过 `max_response_bytes` 返回 `error.ResponseTooLarge`（服务端用
    ///   `Content-Length` 声明超限时连 body 都不读）；
    /// - `headers` 里的头名/头值含 CRLF（或头名含 `:`、为空）时返回
    ///   `error.InvalidArgument`（防头注入，见 `validateHeaders`）；
    /// - 注入 transport（mock）时返回 `.ok` + transport 的响应体（mock 不建模
    ///   状态码）；`headers` 只在 transport 是 `HeaderTransport` 时才会被传递。
    pub fn requestWithHeaders(
        self: *HttpClient,
        method: std.http.Method,
        uri: []const u8,
        payload: []const u8,
        content_type: ?[]const u8,
        headers: []const std.http.Header,
    ) !HttpResponse {
        const effective_uri = applyUriModifier(uri);
        try validateHeaders(headers);

        if (try self.dispatchTransport(effective_uri, method, payload, content_type, headers)) |body| {
            return .{ .status = .ok, .body = try self.checkTransportBody(body) };
        }

        const parsed = std.Uri.parse(effective_uri) catch return error.InvalidUri;
        const has_payload = method.requestHasBody();

        var std_headers: std.http.Client.Request.Headers = .{};
        if (content_type) |ct| std_headers.content_type = .{ .override = ct };

        var req = try self.inner.request(method, parsed, .{
            .redirect_behavior = if (has_payload)
                .unhandled
            else
                std.http.Client.Request.RedirectBehavior.init(default_max_redirects),
            .headers = std_headers,
            .privileged_headers = headers,
        });
        defer req.deinit();

        if (has_payload) {
            req.transfer_encoding = .{ .content_length = payload.len };
            var body_writer = try req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(payload);
            try body_writer.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        // 跟随重定向时才需要 Location 解析缓冲（std 要求它比 `req.uri` 活得久）。
        var redirect_buffer: [redirect_buffer_len]u8 = undefined;
        var response = if (has_payload)
            try req.receiveHead(&.{})
        else
            try req.receiveHead(&redirect_buffer);

        return self.readResponseBody(&response);
    }

    /// 按 `max_response_bytes` 收取响应体（状态码原样回传）。
    ///
    /// 先看 `Content-Length`（服务端自己声明超限就一个字都不读），再靠
    /// `allocRemaining(.limited(max))` 边读边判：它内部按 `limit + 1` 读取，
    /// body 恰好等于上限不会误判，真超限则 `error.StreamTooLong`，这里归一为
    /// `error.ResponseTooLarge`。
    fn readResponseBody(self: *HttpClient, response: *std.http.Client.Response) !HttpResponse {
        const status = response.head.status;
        const max = self.max_response_bytes;
        if (max != 0) {
            if (response.head.content_length) |len| {
                if (len > max) return error.ResponseTooLarge;
            }
        }

        // 与服务端协商到的压缩需要解压缓冲；只有真协商到压缩时才分配
        // （与 `std.http.Client.fetch` 一致）。
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);

        var transfer_buffer: [transfer_buffer_len]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        const body = if (max == 0)
            reader.allocRemaining(self.allocator, .unlimited) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr().?,
                else => |e| return e,
            }
        else
            reader.allocRemaining(self.allocator, .limited(max)) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr().?,
                error.StreamTooLong => return error.ResponseTooLarge,
                else => |e| return e,
            };

        return .{ .status = status, .body = body };
    }

    /// 带附加请求头、且**要求状态码 200**的请求（否则 `error.HttpStatusNotOk`）。
    ///
    /// 需要看非 2xx 的响应体时用 `requestWithHeaders`（它不做状态判定）。
    pub fn sendWithHeaders(
        self: *HttpClient,
        method: std.http.Method,
        uri: []const u8,
        payload: []const u8,
        content_type: ?[]const u8,
        headers: []const std.http.Header,
    ) ![]u8 {
        var resp = try self.requestWithHeaders(method, uri, payload, content_type, headers);
        if (resp.status != .ok) {
            resp.deinit(self.allocator);
            return error.HttpStatusNotOk;
        }
        return resp.body;
    }

    /// 带附加请求头的 POST（`content_type` 为 `null` 时不设置 `Content-Type`）。
    ///
    /// 微信支付 v3 场景：`headers` 里放 `Authorization`（由 `pay/v3/signer.zig`
    /// 生成）与 `Accept`，`content_type` 传 `"application/json"`。
    pub fn postWithHeaders(
        self: *HttpClient,
        uri: []const u8,
        body: []const u8,
        content_type: ?[]const u8,
        headers: []const std.http.Header,
    ) ![]u8 {
        return self.sendWithHeaders(.POST, uri, body, content_type, headers);
    }

    /// 跟随重定向并把**最终**（200）响应体逐块交给 `sink`（见文件末尾的 sink
    /// 契约），返回写入 sink 的字节数。
    ///
    /// 重定向本身由 std 完成（`RedirectBehavior.init(max_redirects)`）：跳数记账、
    /// `Location` 解析（RFC 3986 §5）、跨主机换连、`303`/`301+POST` 改写为 GET
    /// 都在 `Request.receiveHead` 内部；本函数只负责收最终响应体与错误名归一。
    fn followRedirectInto(self: *HttpClient, uri: []const u8, max_redirects: u16, sink: anytype) !u64 {
        const effective_uri = applyUriModifier(uri);

        // mock：没有重定向、也没有流式能力，整块交给 sink（限额由 sink 判定）。
        if (try self.dispatchTransport(effective_uri, .GET, "", null, &.{})) |body| {
            defer self.allocator.free(body);
            if (sink.maxBytes()) |max| {
                if (body.len > max) return error.ResponseTooLarge;
            }
            try sink.write(body);
            return body.len;
        }

        const parsed = std.Uri.parse(effective_uri) catch return error.InvalidUri;
        var req = try self.inner.request(.GET, parsed, .{
            .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(max_redirects),
            // 素材下载不做压缩协商：省掉解压缓冲，读到的字节数也能与
            // `Content-Length` 直接对上（与旧的下载路径一致）。
            .headers = .{ .accept_encoding = .omit },
        });
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buffer: [redirect_buffer_len]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| return mapRedirectError(err);

        // std 的目标 scheme 白名单是 http/ws/https/wss；这里收窄回 http/https，
        // 兑现「只对 http/https 发请求」的承诺。非 http 族 scheme（file:/ftp:/
        // javascript: 等）由 std 在**建连之前**就拒掉，`ws`/`wss` 是唯一多出来的
        // 两个，且只能在这一步（连接已建立）被发现。
        if (!isHttpScheme(req.uri.scheme)) return error.InvalidRedirectLocation;

        if (response.head.status != .ok) {
            drainResponseBody(&response);
            return error.HttpStatusNotOk;
        }

        try sink.hintLength(response.head.content_length);

        var transfer_buffer: [transfer_buffer_len]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        var written: u64 = 0;
        var chunk_buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&chunk_buf) catch |err| switch (err) {
                error.ReadFailed => return response.bodyErr().?,
            };
            if (n == 0) break;
            try sink.write(chunk_buf[0..n]);
            written += n;
        }
        return written;
    }
};

/// 重定向过程中可能出现的错误：std 的错误名 + 本模块对外沿用的旧名字。
const RedirectError = std.http.Client.Request.ReceiveHeadError || error{
    /// 跳数耗尽（旧名，对应 std 的 `error.TooManyHttpRedirects`）。
    TooManyRedirects,
    /// `Location` 不可用（旧名：非 http/https scheme、非法或超长 Location）。
    InvalidRedirectLocation,
    /// redirect 响应缺 `Location` 头（旧实现按「非 200」处理，故沿用该名）。
    HttpStatusNotOk,
};

/// 把 std 的重定向错误归一到本模块既有的公开错误名，**保持调用方兼容**：
/// - `TooManyHttpRedirects` → `TooManyRedirects`
/// - `HttpRedirectLocationMissing` → `HttpStatusNotOk`（旧实现如此）
/// - `HttpRedirectLocationInvalid` / `HttpRedirectLocationOversize` /
///   `UnsupportedUriScheme` → `InvalidRedirectLocation`
fn mapRedirectError(err: std.http.Client.Request.ReceiveHeadError) RedirectError {
    return switch (err) {
        error.TooManyHttpRedirects => error.TooManyRedirects,
        error.HttpRedirectLocationMissing => error.HttpStatusNotOk,
        error.HttpRedirectLocationInvalid,
        error.HttpRedirectLocationOversize,
        error.UnsupportedUriScheme,
        => error.InvalidRedirectLocation,
        else => err,
    };
}

/// 只有 `http` / `https` 算「微信接口地址」。
fn isHttpScheme(scheme: []const u8) bool {
    return std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https");
}

/// 读完并丢弃响应体：让连接能回到池子里，而不是因半读状态被强制关闭
/// （丢弃失败不影响调用方看到的结果）。
fn drainResponseBody(response: *std.http.Client.Response) void {
    const reader = response.reader(&.{});
    _ = reader.discardRemaining() catch {};
}

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

/// GET 跟随 redirect 允许的最大跳数（微信 media/get 通常 1 跳到 CDN，
/// 留一倍余量，同时限制被恶意链路拖死的暴露面）。跳数由
/// `std.http.Client.Request.RedirectBehavior.init(max_redirect_hops)` 记账。
pub const max_redirect_hops = 2;

/// 响应体落点契约（`followRedirectInto` 的 `sink` 参数，编译期鸭子类型）：
/// - `maxBytes() ?usize`：本落点的字节上限（`null` = 不限量），仅供 mock 路径判定；
/// - `hintLength(?u64) !void`：拿到 `Content-Length` 时的预判机会，可提前失败；
/// - `write(chunk) !void`：接收一段 body 字节，超限时返回 `error.ResponseTooLarge`。
///
/// 重定向中间响应的 body 由 std 读完即丢，因此 sink 只会收到最终 200 响应的 body。
/// 内存落点：把 body 收进 `ArrayList(u8)`；`max_bytes` 非空时边读边累加检查。
const MemorySink = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    /// `null` 表示不限量（`getFollowRedirect` 的既有语义）。
    max_bytes: ?usize = null,

    fn maxBytes(self: *const MemorySink) ?usize {
        return self.max_bytes;
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
/// 定位写（`writePositionalAll`）而非缓冲写：上游本就是 16 KiB 分块喂进来，
/// 每块一次定位写与「缓冲 + flush」的 syscall 次数相当，但不必关心 flush 失败
/// 时已写字节数；文件由调用方创建 / 关闭 / 清理。
const FileSink = struct {
    io: std.Io,
    file: std.Io.File,
    max_bytes: usize,
    written: u64 = 0,

    fn maxBytes(self: *const FileSink) ?usize {
        return self.max_bytes;
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

/// 生成 24 字节 hex 形式的 multipart boundary。
///
/// 使用 `default_io.io()` 的 random 熵源，与 HTTP client 共用同一个 Io 实例。
fn generateBoundary(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [12]u8 = undefined;
    default_io.io().random(&bytes);
    return allocator.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

/// 写入单个 multipart 字段。
///
/// `field_name` / `filename` 会被写进 `Content-Disposition` 头：
/// - `"` 与 `\` 按 RFC 9110 `quoted-string` 规则转义（`\"` / `\\`）；
/// - 其余控制字符（含 `\r` / `\n`，即 CRLF 头注入的载体）一律拒绝并返回
///   `error.InvalidArgument`——这两个值来自调用方，静默改写或透传都可能把
///   「一个字段名」变成「两个头」。
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
    try appendQuotedHeaderValue(allocator, body_buf, field.field_name);
    try body_buf.appendSlice(allocator, "\"; filename=\"");
    try appendQuotedHeaderValue(allocator, body_buf, field.filename);
    try body_buf.appendSlice(allocator, "\"\r\n");
    try body_buf.appendSlice(allocator, "Content-Type: application/octet-stream\r\n");
    try body_buf.appendSlice(allocator, "\r\n");

    if (field.is_file) {
        if (field.data.len > 0) {
            // 直接使用内存中的二进制数据。
            try body_buf.appendSlice(allocator, field.data);
        } else {
            const io = default_io.io();
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

/// 把 `value` 作为 `quoted-string` 写入头部：转义 `"` 与 `\`，拒绝控制字符。
///
/// 拒绝（而非剥离）控制字符是刻意的：`\r\n` 能让一个头变成两个头，而调用方传进来的
/// 大概率是文件名/字段名——静默改写会掩盖调用方的 bug。
fn appendQuotedHeaderValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            0...0x1f, 0x7f => return error.InvalidArgument,
            else => try out.append(allocator, c),
        }
    }
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
    const io = default_io.io();
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
        // 注意：**不能**用 `reuse_address = true`——POSIX 上它同时打开 SO_REUSEPORT，
        // 会让同一端口被**多个测试进程**同时绑定，内核把连接分摊给它们，导致某个
        // 假服务器的 accept 永远等不到请求、`join` 永久挂住（实测挂死 14 分钟）。
        if (std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = false })) |server| {
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
    // server 线程使用独立 Io（`Io.Threaded` 实例不可跨线程共享）。
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
    const io = default_io.io();
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
    const io = default_io.io();
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

// ─────────────────────────────────────────────────────────────────────────────
// 重定向解析：旧实现手写 Location 解析（只认绝对 URL 与 `/` 开头且非 `//` 的
// 相对路径），现在整段交给 `std.Uri.resolveInPlace`（RFC 3986 §5）。
// 下面用真实假 server 覆盖旧实现拒绝、std 接受的两种形态，作为能力等价证据。
// ─────────────────────────────────────────────────────────────────────────────

test "getFollowRedirect 由 std 解析 Location：../ 相对路径与协议相对 URL" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    // 第 1 跳：`sub/../final?q=1`——不带前导 `/` 的相对路径 + dot segment + query，
    // 旧实现直接判 InvalidRedirectLocation。
    // 第 2 跳：`//127.0.0.1:port/abs`——协议相对 URL（保留原 scheme 与端口），
    // 旧实现同样拒绝。
    var resp_b_buf: [256]u8 = undefined;
    const resp_b = try std.fmt.bufPrint(
        &resp_b_buf,
        "HTTP/1.1 302 Found\r\nLocation: //127.0.0.1:{d}/abs\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{bound.port},
    );
    const responses = [_][]const u8{
        "HTTP/1.1 302 Found\r\nLocation: sub/../final?q=1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        resp_b,
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
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
    try std.testing.expectEqualStrings("ok", body);
    try std.testing.expectEqual(@as(u32, 3), hits.load(.seq_cst));

    const seen = capture[0..capture_len];
    // 相对路径按 RFC 3986 §5.3 合并到 base 的目录再去掉 dot segment，query 保留。
    try std.testing.expect(std.mem.indexOf(u8, seen, "GET /final?q=1 HTTP/1.1") != null);
    // 协议相对 URL 解析成 http://127.0.0.1:port/abs（端口不能丢，否则打到 80）。
    try std.testing.expect(std.mem.indexOf(u8, seen, "GET /abs HTTP/1.1") != null);
}

test "getFollowRedirect 跳数超限仍归一为 TooManyRedirects（std 的 TooManyHttpRedirects 被映射）" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    // 每次都回 `Location: /loop`：max_redirect_hops = 2，第 3 次响应时跳数耗尽。
    const loop_resp = "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    const responses = [_][]const u8{ loop_resp, loop_resp, loop_resp };
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
    client.setMaxResponseBytes(1024);

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(error.TooManyRedirects, client.getFollowRedirectLimited(uri, 1024));
    unblockAccept(sio, bound.port);
    try std.testing.expectEqual(@as(u32, 3), hits.load(.seq_cst));
}

// ─────────────────────────────────────────────────────────────────────────────
// 响应体硬上限（API 请求路径）
// ─────────────────────────────────────────────────────────────────────────────

test "default_max_response_bytes 为 16 MiB" {
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), default_max_response_bytes);
    var client = HttpClient.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqual(default_max_response_bytes, client.max_response_bytes);
}

test "get 响应体超限：Content-Length 预判直接失败（不读 body）" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    // 声明 999999 字节却只发 8 字节：若没做预判，会先撞上 body 读取错误
    // （Content-Length 不符）而不是 ResponseTooLarge。
    const responses = [_][]const u8{
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
    client.setMaxResponseBytes(64);

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(error.ResponseTooLarge, client.get(uri));
    unblockAccept(sio, bound.port);
    try std.testing.expectEqual(@as(u32, 1), hits.load(.seq_cst));
}

test "get 响应体超限：无 Content-Length 时边读边判（StreamTooLong 归一）" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    // chunked（无 Content-Length）→ 只能靠 allocRemaining 的 limit 判定超限。
    const responses = [_][]const u8{
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
    // 上限 31 < 32：恰好差一个字节也必须失败。
    client.setMaxResponseBytes(31);

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(error.ResponseTooLarge, client.get(uri));
    unblockAccept(sio, bound.port);
    try std.testing.expectEqual(@as(u32, 1), hits.load(.seq_cst));
}

test "get 响应体恰好等于上限时正常返回（StreamTooLong 不误判）" {
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
    client.setMaxResponseBytes(chunked_payload_32.len);

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/api", .{bound.port});
    defer allocator.free(uri);

    const body = try client.get(uri);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(chunked_payload_32, body);
}

test "mock transport 路径同样受 max_response_bytes 约束（0 = 不限量）" {
    const allocator = std.testing.allocator;
    var mock = MockTransport.init(allocator);
    defer mock.deinit();
    const big = "0123456789abcdef";
    try mock.addRoute("https://example.com/api/big", .{ .body = big });

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setTransport(MockTransport.dispatch, @ptrCast(&mock));

    // 上限小于响应体：mock 没有流式能力，只能读完后判定，但语义一致。
    client.setMaxResponseBytes(8);
    try std.testing.expectError(error.ResponseTooLarge, client.get("https://example.com/api/big"));

    // 恰好等于上限：不误判。
    client.setMaxResponseBytes(big.len);
    const ok = try client.get("https://example.com/api/big");
    defer allocator.free(ok);
    try std.testing.expectEqualStrings(big, ok);

    // 0 = 不限量（转义阀）。
    client.setMaxResponseBytes(0);
    const unlimited = try client.get("https://example.com/api/big");
    defer allocator.free(unlimited);
    try std.testing.expectEqualStrings(big, unlimited);
}

test "requestWithHeaders 不做状态码判定：非 2xx 也能拿到 body" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    const err_body = "{\"code\":\"NOT_ENOUGH\",\"message\":\"余额不足\"}";
    var resp_buf: [256]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &resp_buf,
        "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ err_body.len, err_body },
    );
    // 两次请求（requestWithHeaders + sendWithHeaders），服务器各回一份。
    const responses = [_][]const u8{ resp, resp };
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

    const uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v3/refund", .{bound.port});
    defer allocator.free(uri);

    // 这是微信支付 v3 依赖的能力：4xx 应答体里有业务错误码，不能被状态码吃掉。
    var resp_raw = try client.requestWithHeaders(.POST, uri, "{}", "application/json", &.{});
    defer resp_raw.deinit(allocator);
    try std.testing.expectEqual(std.http.Status.bad_request, resp_raw.status);
    try std.testing.expectEqualStrings(err_body, resp_raw.body);

    // 同一路径经 sendWithHeaders（要求 200）时以 HttpStatusNotOk 收场。
    try std.testing.expectError(
        error.HttpStatusNotOk,
        client.sendWithHeaders(.POST, uri, "{}", "application/json", &.{}),
    );
    try std.testing.expectEqual(@as(u32, 2), hits.load(.seq_cst));
}

// ─────────────────────────────────────────────────────────────────────────────
// 请求头注入入口（HeaderTransport）
// ─────────────────────────────────────────────────────────────────────────────

/// 测试用 transport：记录方法 / URI / body / 请求头，返回固定响应。
///
/// 记录时会拷贝字符串，因此调用结束后仍可读（`HttpClient` 只保证 slice 在调用
/// 期间有效）。
const HeaderCapture = struct {
    allocator: std.mem.Allocator,
    response: []const u8 = "{}",
    method: std.http.Method = .GET,
    uri: []u8 = &.{},
    payload: []u8 = &.{},
    content_type: []u8 = &.{},
    headers: std.ArrayList(std.http.Header) = .empty,

    fn init(allocator: std.mem.Allocator, response: []const u8) HeaderCapture {
        return .{ .allocator = allocator, .response = response };
    }

    fn deinit(self: *HeaderCapture) void {
        self.allocator.free(self.uri);
        self.allocator.free(self.payload);
        self.allocator.free(self.content_type);
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit(self.allocator);
    }

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
        headers: []const std.http.Header,
    ) anyerror![]u8 {
        const self: *HeaderCapture = @ptrCast(@alignCast(ctx));
        self.method = method;
        self.allocator.free(self.uri);
        self.allocator.free(self.payload);
        self.allocator.free(self.content_type);
        self.uri = try self.allocator.dupe(u8, uri);
        self.payload = try self.allocator.dupe(u8, payload);
        self.content_type = try self.allocator.dupe(u8, content_type orelse "");
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.clearRetainingCapacity();
        for (headers) |h| {
            try self.headers.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, h.name),
                .value = try self.allocator.dupe(u8, h.value),
            });
        }
        return allocator.dupe(u8, self.response);
    }

    fn headerValue(self: *const HeaderCapture, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

test "postWithHeaders 把请求头交给 HeaderTransport（Authorization / Accept / 自定义头）" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture.init(allocator, "{\"ok\":true}");
    defer cap.deinit();

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));

    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = "WECHATPAY2-SHA256-RSA2048 mchid=\"1900000109\"" },
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Wechatpay-Serial", .value = "PUB_KEY_ID_3000000001" },
    };
    const resp = try client.postWithHeaders(
        "https://api.mch.weixin.qq.com/v3/refund/domestic/refunds",
        "{\"out_refund_no\":\"R1\"}",
        "application/json",
        &headers,
    );
    defer allocator.free(resp);

    try std.testing.expectEqual(std.http.Method.POST, cap.method);
    try std.testing.expectEqualStrings("application/json", cap.content_type);
    try std.testing.expectEqualStrings("{\"out_refund_no\":\"R1\"}", cap.payload);
    try std.testing.expectEqual(@as(usize, 3), cap.headers.items.len);
    try std.testing.expectEqualStrings(
        "WECHATPAY2-SHA256-RSA2048 mchid=\"1900000109\"",
        cap.headerValue("Authorization").?,
    );
    try std.testing.expectEqualStrings("application/json", cap.headerValue("accept").?);
    try std.testing.expectEqualStrings("PUB_KEY_ID_3000000001", cap.headerValue("Wechatpay-Serial").?);
}

test "sendWithHeaders(.GET) 走 HeaderTransport，旧 Transport 仍收到不带头的请求" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture.init(allocator, "{\"status\":\"SUCCESS\"}");
    defer cap.deinit();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    // 新入口：GET 也能带 Authorization（v3 查询/撤销接口）。
    client.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));
    const got = try client.sendWithHeaders(.GET, "https://api.mch.weixin.qq.com/v3/query", "", null, &.{
        .{ .name = "Authorization", .value = "sig" },
    });
    defer allocator.free(got);
    try std.testing.expectEqual(std.http.Method.GET, cap.method);
    try std.testing.expectEqualStrings("sig", cap.headerValue("Authorization").?);

    // 旧 Transport 签名没有 header 参数：注入它时请求照发，头被丢弃（历史行为）。
    var mock = MockTransport.init(allocator);
    defer mock.deinit();
    try mock.addRoute("https://api.mch.weixin.qq.com/v3/query", .{ .body = "{\"status\":\"SUCCESS\"}" });
    client.setTransport(MockTransport.dispatch, @ptrCast(&mock));
    try std.testing.expect(client.header_transport == null);

    const via_mock = try client.sendWithHeaders(.GET, "https://api.mch.weixin.qq.com/v3/query", "", null, &.{
        .{ .name = "Authorization", .value = "sig" },
    });
    defer allocator.free(via_mock);
    try std.testing.expectEqual(@as(usize, 1), mock.history.items.len);
}

test "setTransport(null, null) 与 setHeaderTransport(null, null) 互相清空对方" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture.init(allocator, "{}");
    defer cap.deinit();
    var mock = MockTransport.init(allocator);
    defer mock.deinit();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    client.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));
    try std.testing.expect(client.header_transport != null);

    // setTransport 会清掉 header transport：`setTransport(null, null)` 因此是
    // 「彻底恢复真实 HTTP」，不会残留一个 mock。
    client.setTransport(MockTransport.dispatch, @ptrCast(&mock));
    try std.testing.expect(client.header_transport == null);
    try std.testing.expect(client.transport != null);
    client.setTransport(null, null);
    try std.testing.expect(!client.hasTransport());

    client.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));
    try std.testing.expect(client.transport == null);
    client.setHeaderTransport(null, null);
    try std.testing.expect(!client.hasTransport());
}

test "注入 transport 但 transport_ctx 为空时 panic 提示（既有契约未变）" {
    // 只断言字段默认值：panic 路径需要 catch panic，代价大于价值。
    var client = HttpClient.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expect(client.transport_ctx == null);
    try std.testing.expect(client.transport == null);
    try std.testing.expect(client.header_transport == null);
}

// ─────────────────────────────────────────────────────────────────────────────
// multipart 头部转义
// ─────────────────────────────────────────────────────────────────────────────

test "appendQuotedHeaderValue 转义 \" 与 \\ 并拒绝控制字符" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try appendQuotedHeaderValue(allocator, &out, "a\"b\\c.txt");
    try std.testing.expectEqualStrings("a\\\"b\\\\c.txt", out.items);

    // CRLF 是头注入的载体：必须拒绝，不能静默剥离。
    try std.testing.expectError(
        error.InvalidArgument,
        appendQuotedHeaderValue(allocator, &out, "x\r\nX-Injected: 1"),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        appendQuotedHeaderValue(allocator, &out, "x\nY"),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        appendQuotedHeaderValue(allocator, &out, "x\x7f"),
    );
}

test "postMultipart 转义字段名/文件名里的引号，不留头注入空间" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture.init(allocator, "{\"ok\":true}");
    defer cap.deinit();

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));

    const fields = [_]MultipartField{
        .{
            .is_file = true,
            .field_name = "me\"dia",
            .filename = "a\\b\".mp4",
            .value = "",
            .data = "BYTES",
        },
    };
    const resp = try client.postMultipart("https://api.weixin.qq.com/cgi-bin/media/upload", &fields);
    defer allocator.free(resp);

    const payload = cap.payload;
    try std.testing.expect(std.mem.indexOf(
        u8,
        payload,
        "Content-Disposition: form-data; name=\"me\\\"dia\"; filename=\"a\\\\b\\\".mp4\"\r\n",
    ) != null);
    // 注入面检查：转义后的 payload 里不该出现未转义的裸引号闭合 + 换行。
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"me\"dia\"") == null);
    try std.testing.expect(std.mem.endsWith(u8, payload, "\r\n"));
}

test "postMultipart 字段名/文件名含 CRLF 时返回 InvalidArgument" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture.init(allocator, "{}");
    defer cap.deinit();

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));

    const bad_name = [_]MultipartField{.{
        .is_file = false,
        .field_name = "media\r\nX-Injected: 1",
        .filename = "a.txt",
        .value = "v",
    }};
    try std.testing.expectError(
        error.InvalidArgument,
        client.postMultipart("https://api.weixin.qq.com/upload", &bad_name),
    );

    const bad_filename = [_]MultipartField{.{
        .is_file = false,
        .field_name = "media",
        .filename = "a\nb.txt",
        .value = "v",
    }};
    try std.testing.expectError(
        error.InvalidArgument,
        client.postMultipart("https://api.weixin.qq.com/upload", &bad_filename),
    );

    // 被拒绝的请求不该真的发出去。
    try std.testing.expectEqual(@as(usize, 0), cap.headers.items.len);
}

test "requestWithHeaders 拒绝含 CRLF 的请求头（头注入），mock 路径同样拦截" {
    const allocator = std.testing.allocator;
    var cap = HeaderCapture.init(allocator, "{}");
    defer cap.deinit();

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setHeaderTransport(HeaderCapture.dispatch, @ptrCast(&cap));

    // 头值里的 CRLF 会把「一个头」变成「两个头」：std 只在 debug 下断言，
    // ReleaseFast 会原样发出，因此这里必须显式拒绝。
    try std.testing.expectError(
        error.InvalidArgument,
        client.postWithHeaders("https://example.com/x", "{}", "application/json", &.{
            .{ .name = "X-Trace", .value = "abc\r\nX-Injected: 1" },
        }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        client.postWithHeaders("https://example.com/x", "{}", "application/json", &.{
            .{ .name = "X-Bad\nName", .value = "v" },
        }),
    );
    // 头名里带 ':' 会伪造出第二个头。
    try std.testing.expectError(
        error.InvalidArgument,
        client.postWithHeaders("https://example.com/x", "{}", "application/json", &.{
            .{ .name = "X-Fake: X-Injected", .value = "v" },
        }),
    );
    try std.testing.expectError(
        error.InvalidArgument,
        client.postWithHeaders("https://example.com/x", "{}", "application/json", &.{
            .{ .name = "", .value = "v" },
        }),
    );

    // 被拒绝的请求不该到达 transport。
    try std.testing.expectEqual(@as(usize, 0), cap.headers.items.len);

    // 干净的头照常放行。
    const ok = try client.postWithHeaders("https://example.com/x", "{}", "application/json", &.{
        .{ .name = "Authorization", .value = "sig" },
    });
    defer allocator.free(ok);
    try std.testing.expectEqualStrings("sig", cap.headerValue("Authorization").?);
}
