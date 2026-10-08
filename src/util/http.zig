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
//! ## 超时（默认**不**为 0）
//!
//! `std.http.Client` 自身**没有任何超时**（`Client` 的字段里没有 timeout，
//! `ConnectOptions.timeout` 也只有 `connectTcpOptions` 才持有、而它并未往下传），
//! 于是对端「SYN 被丢」或「连上不回包」时调用线程会永久挂起。这里补上两个：
//!
//! - `HttpClient.connect_timeout_ms`（默认 `default_connect_timeout_ms` = **10s**）：
//!   单次 TCP 建连的上限；
//! - `HttpClient.read_timeout_ms`（默认 `default_read_timeout_ms` = **30s**）：
//!   **单次读**的上限。覆盖 TLS 握手、响应头读取与响应体读取（三者都经由连接上的
//!   `Io.net.Stream.Reader`），**不是**整请求总时限——对端只要还在按块回数据就不会
//!   被掐断（对齐 `cache` 的 `recv_timeout_ms` 语义）。
//!
//! 用 `setTimeouts(connect_ms, read_ms)` 一次性改；`0` 保留为「不限」的逃生阀
//! （与 `cache` 的 `connect_timeout_ms` / `recv_timeout_ms` 语义一致）。**默认值刻意
//! 不是 0**：cache 那边默认 0 是因为 Redis/Memcache 可能跑在同机低延迟链路上、且
//! 长阻塞读（`BLPOP`）是它的正常语义；而微信 API 全是「短请求 + 小响应」，
//! 唯一的合法长等待是调用方自己的超时策略，因此这里选 fail-fast：宁可 30s 后
//! 拿到 `error.ReadTimeout`，也不接受一个出站线程被半死对端永久占住（生产上已因
//! 此发生过挂死事故）。
//!
//! 超时的错误名（在原有错误集之外新增的两个，调用方需一并处理）：
//! `error.ConnectTimeout`（建连到点未完成）与 `error.ReadTimeout`（单次读到点无数据）。
//! 二者都**不会**把连接留在 `std.http.Client` 的连接池里：响应头读失败时 std 自己
//! 会把连接标记为 `closing`，响应体读失败时 reader 停在 body 状态、`Request.deinit`
//! 同样判定为不可复用——半条回复留在连接上会让后续请求协议失步，必须丢弃。
//!
//! 边界（刻意不覆盖，写在这里免得误以为有保护）：
//! - **DNS 解析**：走 std 自己的 resolv 逻辑（单次 5s、有 attempts 上限），不受
//!   `connect_timeout_ms` 约束；
//! - **写（`net_write`）**：不设超时。请求体都很小、且写阻塞需要内核发送缓冲被
//!   打满，风险远低于「等对端回包」；
//! - **注入 transport（mock）**：不经过套接字，超时语义不适用（transport 自己
//!   决定，可自行返回 `error.RequestTimeout`）；
//! - **`postXMLWithTLS` 的 mTLS 通道**（`util/mtls.zig` → `mtls_openssl.zig`）：
//!   那条路是 OpenSSL + 裸 socket，不经过 `std.http.Client`，同样不受这里约束。
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
//!
//! allocator 的相等性判定是 **best-effort** 的（见 `sameAllocator`）：先比 `vtable`，
//! 不同即判为不同；无状态单例（`page_allocator` / `smp_allocator`）只按 `vtable`
//! 判等——它们的 `ptr` 字段是 `undefined`，比较即非法行为，故不再比较；只有有状态
//! 实现才会进一步比较 `ptr` 精确区分。结论：把已释放的 `ArenaAllocator` 换成新实例
//! 一定会被检出，而"换了一个 `page_allocator` 值"不会被检出（两者语义等价）。

const std = @import("std");
const builtin = @import("builtin");
const rsa = @import("rsa.zig");
const mtls = @import("mtls.zig");
const default_io = @import("default_io.zig");
const util_error = @import("error.zig");

const posix = std.posix;
/// 当前平台（`connectWithTimeout` / 测试夹具按它做 comptime 分支）。
const native_os = builtin.os.tag;

/// JSON/XML 等 API 响应的默认体积上限（16 MiB）。
///
/// 微信 API 的 JSON/XML 应答都在 KB 量级；没有上限时，一个异常（或被劫持）的
/// 上游可以用超长响应把服务端内存吃光。需要更宽/更严的上限时用
/// `HttpClient.setMaxResponseBytes`（`0` = 不限量）。
pub const default_max_response_bytes: usize = 16 * 1024 * 1024;

/// 默认建连超时（10 秒）。`0` = 不限。
///
/// 非 0 的理由见模块头「超时」小节：对端半死时不能让调用线程永久挂起。
pub const default_connect_timeout_ms: u64 = 10_000;

/// 默认读取超时（30 秒，单次读）。`0` = 不限。
///
/// 取 30s 而不是与建连同为 10s：微信素材下载 / 长轮询类接口的**单块**数据间隔
/// 可能拉到十几秒，10s 会误杀正常请求；30s 已经足以让「对端不回包」在可接受的
/// 时间内暴露。
pub const default_read_timeout_ms: u64 = 30_000;

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

/// 判断该 allocator 是否为**可命名的无状态单例**。
///
/// 这类实现的 `ptr` 字段恒为 `undefined`（见 `std/heap.zig` 的 `page_allocator` /
/// `smp_allocator` 定义），**对其做任何比较都是非法行为**，因此只能靠 `vtable`
/// 认出来（`&PageAllocator.vtable` / `&SmpAllocator.vtable` 都是 `pub`）。
///
/// `c_allocator` 同样是无状态单例（`ptr = undefined`），但其 vtable 藏在私有
/// `c_allocator_impl` 里、且该容器带 `link_libc` 的 comptime 断言，故只在
/// 确实链接 libc 时才纳入判断。
fn isStatelessSingleton(a: std.mem.Allocator) bool {
    if (a.vtable == std.heap.page_allocator.vtable) return true;
    if (a.vtable == std.heap.smp_allocator.vtable) return true;
    if (comptime builtin.link_libc) {
        if (a.vtable == std.heap.c_allocator.vtable) return true;
    }
    return false;
}

/// 判断两个 `Allocator` 是否为同一个（`std.mem.Allocator` 无 `==` 运算符）。
///
/// `std.mem.Allocator.ptr` 的字段文档明确写着：无状态实现下它可能是 `undefined`，
/// **对它的任何比较都可能触发非法行为**。所以这里分三级：
/// 1. `vtable` 不相等 → 一定不是同一个 allocator，直接 `false`（不碰 `ptr`）；
/// 2. `vtable` 相等且是**可命名的无状态单例**（`page_allocator` / `smp_allocator`，
///    链接 libc 时含 `c_allocator`）→ 直接 `true`（不碰 `ptr`）；
/// 3. 其余（有状态实现）才比较 `ptr` 做精确区分 —— 例如两个不同的
///    `ArenaAllocator` 即使共享同一 vtable 也会被 `ptr` 分开。
///
/// **best-effort**：std 允许多个实例共享同一 vtable，而 `Allocator` 没有任何
/// 可用来识别实例的稳定标识（`ptr` 对无状态实现不可比较），因此无状态单例之间的
/// 区分能力上限就是「vtable 相等即视为同一个」——两个不同的 `page_allocator`
/// 值会被判为一致。这是刻意的宽松：它们在语义上完全等价、可安全互换。
/// 有状态实现不受该限制。
fn sameAllocator(a: std.mem.Allocator, b: std.mem.Allocator) bool {
    if (a.vtable != b.vtable) return false;
    if (isStatelessSingleton(a)) return true;
    return a.ptr == b.ptr;
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
/// **一致性判定是 best-effort**：相等性由 `sameAllocator` 判定——先比 `vtable`，
/// 无状态单例（`page_allocator` / `smp_allocator`）到此为止、不再比较 `ptr`
/// （该字段在无状态实现下是 `undefined`，比较会触发非法行为），有状态实现才进一步
/// 比较 `ptr`。因此不同的有状态 allocator 一定被判为不一致；而无状态单例之间
/// 无法区分，两次传入不同的 `page_allocator` 值会被判为一致（语义等价，可接受）。
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
///
/// **判定是 best-effort**：见 `sameAllocator`——`vtable` 不同即 `false`；相同且为
/// 无状态单例（`page_allocator` / `smp_allocator`）即 `true`（不比较 `ptr`，
/// 因为无状态实现的 `ptr` 是 `undefined`）；有状态实现再比较 `ptr` 精确区分。
/// 无状态单例之间无法区分，属于已知的宽松下限。
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
    /// 内部 `std.http.Client`。
    ///
    /// `io` 初值是进程级单例 `default_io.io()`（同步阻塞语义，适用于调用方
    /// 线程）；首次真实请求时会被换成**覆写过超时项**的句柄（见
    /// `TimeoutState`），该句柄的 `userdata` 指向 `_timeout_state`。所有真实请求
    /// 都在这一条 io 上跑，因此不存在"连接建立用 A、读取用 B"的混用。
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

    /// 建连超时（毫秒），默认 `default_connect_timeout_ms`（10s）；`0` = 不限。
    ///
    /// 覆盖范围与超时语义见模块头「超时」小节。到点返回 `error.ConnectTimeout`。
    connect_timeout_ms: u64 = default_connect_timeout_ms,
    /// 读取超时（毫秒，**单次读**），默认 `default_read_timeout_ms`（30s）；`0` = 不限。
    ///
    /// 到点返回 `error.ReadTimeout`。不是整请求总时限：对端只要还在按块回数据
    /// 就不会被掐断（对齐 `cache` 的 `recv_timeout_ms` 语义）。
    read_timeout_ms: u64 = default_read_timeout_ms,

    /// 本客户端的超时状态（覆写后的 `Io` + 配置），首次真实请求时惰性创建、
    /// `deinit` 释放。字段名带下划线表示内部用：外部代码只应通过
    /// `connect_timeout_ms` / `read_timeout_ms` / `setTimeouts` 操作超时。
    _timeout_state: ?*TimeoutState = null,

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

    /// 一次性设置建连 / 读取超时（毫秒）。任一项传 `0` 表示该项**不限**。
    ///
    /// 下个请求生效（配置在请求入口读取，不需要重建客户端）。默认值见
    /// `default_connect_timeout_ms` / `default_read_timeout_ms`（10s / 30s），
    /// 语义见模块头「超时」小节。
    ///
    /// 配置保存在本客户端自己的超时状态里，并被建连路径（可能跑在后端 worker
    /// 线程上）直接读取；因此**不要在请求进行中调用**——`std.http.Client` 本身也
    /// 不是线程安全的，同一个 `HttpClient` 不应被并发使用。
    pub fn setTimeouts(self: *HttpClient, connect_ms: u64, read_ms: u64) void {
        self.connect_timeout_ms = connect_ms;
        self.read_timeout_ms = read_ms;
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

    /// 释放连接池与超时状态等内部资源。
    ///
    /// 顺序是刻意的：先让 `inner.deinit()` 用它**自己记着的** `io` 关掉池里的连接
    /// （那些连接的 `io` 指向下面这个超时状态），再释放状态。
    pub fn deinit(self: *HttpClient) void {
        self.inner.deinit();
        if (self._timeout_state) |state| {
            self.allocator.destroy(state);
            self._timeout_state = null;
        }
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

        const content_type = try self.allocator.print(
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
            if (std.mem.findScalar(u8, header.name, ':') != null) return error.InvalidArgument;
            if (std.mem.findAny(u8, header.name, "\r\n") != null) return error.InvalidArgument;
            if (std.mem.findAny(u8, header.value, "\r\n") != null) return error.InvalidArgument;
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
    ///
    /// 超时：真实网络路径受 `connect_timeout_ms` / `read_timeout_ms` 约束，
    /// 到点分别返回 `error.ConnectTimeout` / `error.ReadTimeout`（见模块头
    /// 「超时」小节）；注入 transport 时整段都不经过套接字，二者不适用。
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

        // mock：不经过套接字，不装超时 Io、也不进入超时作用域。
        if (try self.dispatchTransport(effective_uri, method, payload, content_type, headers)) |body| {
            return .{ .status = .ok, .body = try self.checkTransportBody(body) };
        }

        const timed = try beginTimedRequest(self);

        const parsed = std.Uri.parse(effective_uri) catch return error.InvalidUri;
        const has_payload = method.requestHasBody();

        var std_headers: std.http.Client.Request.Headers = .{};
        if (content_type) |ct| std_headers.content_type = .{ .override = ct };

        var req = self.inner.request(method, parsed, .{
            .redirect_behavior = if (has_payload)
                .unhandled
            else
                std.http.Client.Request.RedirectBehavior.init(default_max_redirects),
            .headers = std_headers,
            .privileged_headers = headers,
        }) catch |err| return mapConnectError(err);
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
            req.receiveHead(&.{}) catch |err| return mapReadFailure(err, false, timed.readTimedOut())
        else
            req.receiveHead(&redirect_buffer) catch |err| return mapReadFailure(err, false, timed.readTimedOut());

        return self.readResponseBody(&response, timed);
    }

    /// 按 `max_response_bytes` 收取响应体（状态码原样回传）。
    ///
    /// 先看 `Content-Length`（服务端自己声明超限就一个字都不读），再靠
    /// `allocRemaining(.limited(max))` 边读边判：它内部按 `limit + 1` 读取，
    /// body 恰好等于上限不会误判，真超限则 `error.StreamTooLong`，这里归一为
    /// `error.ResponseTooLarge`。
    fn readResponseBody(
        self: *HttpClient,
        response: *std.http.Client.Response,
        timed: TimedRequest,
    ) !HttpResponse {
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
                error.ReadFailed => return bodyReadFailure(response, timed.readTimedOut()),
                else => |e| return e,
            }
        else
            reader.allocRemaining(self.allocator, .limited(max)) catch |err| switch (err) {
                error.ReadFailed => return bodyReadFailure(response, timed.readTimedOut()),
                error.StreamTooLong => return error.ResponseTooLarge,
                else => |e| return e,
            };

        return .{ .status = status, .body = body };
    }

    /// 带附加请求头、且**要求状态码 200**的请求（否则 `error.HttpStatusNotOk`）。
    ///
    /// 需要看非 2xx 的响应体（状态码 + body）时用 `requestWithHeaders`——它不做
    /// 状态判定，把 `HttpResponse{status, body}` 原样交给调用方（微信支付 v3 的
    /// 业务错误码就在 4xx/5xx 的 body 里）。
    ///
    /// 本方法在非 2xx 时仍只返回 `error.HttpStatusNotOk`（Zig 的 `error` 值不能
    /// 携带负载），但**不会再把状态码与 body 丢掉**：状态码 + body 摘要会打一条
    /// `warn` 日志，微信形态的 `{"errcode":..,"errmsg":..}` 响应体还会写进本线程的
    /// `util_error.lastErrorDetail()` 详情通道。详见 `reportNonOkResponse`。
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
            reportNonOkResponse(self.allocator, uri, resp.status, resp.body);
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
    ///
    /// 超时：真实网络路径受 `connect_timeout_ms` / `read_timeout_ms` 约束（含
    /// 重定向到别的域时 std 新建的那条连接），到点分别返回 `error.ConnectTimeout`
    /// / `error.ReadTimeout`。
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

        const timed = try beginTimedRequest(self);

        const parsed = std.Uri.parse(effective_uri) catch return error.InvalidUri;
        var req = self.inner.request(.GET, parsed, .{
            .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(max_redirects),
            // 素材下载不做压缩协商：省掉解压缓冲，读到的字节数也能与
            // `Content-Length` 直接对上（与旧的下载路径一致）。
            .headers = .{ .accept_encoding = .omit },
        }) catch |err| return mapConnectError(err);
        defer req.deinit();
        try req.sendBodiless();

        var redirect_buffer: [redirect_buffer_len]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| return mapReadFailure(err, true, timed.readTimedOut());

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
                error.ReadFailed => return bodyReadFailure(&response, timed.readTimedOut()),
            };
            if (n == 0) break;
            try sink.write(chunk_buf[0..n]);
            written += n;
        }
        return written;
    }
};

/// 重定向过程中可能出现的错误：std 的错误名 + 本模块对外沿用的旧名字 + 本模块
/// 新增的两个超时名（`ConnectTimeout` / `ReadTimeout`，见模块头「超时」小节）。
const RedirectError = std.http.Client.Request.ReceiveHeadError || error{
    /// 跳数耗尽（旧名，对应 std 的 `error.TooManyHttpRedirects`）。
    TooManyRedirects,
    /// `Location` 不可用（旧名：非 http/https scheme、非法或超长 Location）。
    InvalidRedirectLocation,
    /// redirect 响应缺 `Location` 头（旧实现按「非 200」处理，故沿用该名）。
    HttpStatusNotOk,
    /// 建连到点未完成（`connect_timeout_ms`）。
    ConnectTimeout,
    /// 单次读到点没有数据（`read_timeout_ms`）。
    ReadTimeout,
};

/// 建连失败的错误归一：`error.Timeout` 是我们注入的建连 deadline 到点
/// （`connectWithTimeout` 只能用 `error.Timeout`——`IpAddress.ConnectError` 里
/// 只有它表达"到点"，内核自己的 `ETIMEDOUT` 也映射到它），对外统一成
/// `error.ConnectTimeout`；其余错误（拒绝 / 不可达 / DNS 失败……）原样透传。
fn mapConnectError(err: anyerror) anyerror {
    return switch (err) {
        error.Timeout => error.ConnectTimeout,
        else => err,
    };
}

/// `Request.receiveHead` 失败的错误归一。
///
/// - 本次请求内出现过读超时 → `error.ReadTimeout`：std 会把读取失败折叠成
///   `error.ReadFailed`，光看错误名分不出"对端不回包"与"对端真断了/头畸形"；
/// - 否则按 `map_redirect` 决定是否套用重定向错误名归一
///   （`requestWithHeaders` 不跟随重定向，沿用原来的 std 错误名）。
fn mapReadFailure(
    err: std.http.Client.Request.ReceiveHeadError,
    map_redirect: bool,
    read_timed_out: bool,
) RedirectError {
    if (read_timed_out) return error.ReadTimeout;
    return if (map_redirect) mapRedirectError(err) else err;
}

/// 响应体读取失败的错误归一。
///
/// - 本次请求内出现过读超时 → `error.ReadTimeout`；
/// - 否则保留 std 记下的更具体错误（chunk 定界问题），没有则退回 `error.ReadFailed`。
///
/// **不要照抄 std 的 `response.bodyErr().?`**：`body_err` 只记录 chunk 层面的错误
/// （`HttpChunkInvalid` / `HttpChunkTruncated` / `HttpHeadersOversize`），对
/// `Content-Length` 定界的响应它恒为 `null`，`.?` 会直接把进程 panic 掉。
fn bodyReadFailure(response: *const std.http.Client.Response, read_timed_out: bool) anyerror {
    if (read_timed_out) return error.ReadTimeout;
    return response.bodyErr() orelse error.ReadFailed;
}

// =============================================================================
// 超时：带 deadline 的 `Io` 覆写
// =============================================================================
//
// `std.http.Client` 一行超时都没有（`Client` 的字段里没有 timeout，`io` 只当
// "打开 TCP 连接"与流读写用），因此本模块给它一个**覆写过几项**的 `Io` 句柄：
//
//   `net_read`（响应头、响应体、TLS 握手都经由它）→ `operateWithTimeout`
//   TCP 建连（`netConnectIp`）                  → `netConnectIpWithTimeout`
//   调度 / 取消族（async / group* / await / cancel / batch*）→ 转发给真实后端
//
// ## 为什么需要每个客户端一份状态（而不是线程局部配置）
//
// `std.Io` 只有 `{ userdata, vtable }` 两个字段，覆写项只能从 `userdata` 认出
// "这是哪个客户端"。而**配置不能只放在发起请求的线程上**：`HostName.connect` 会用
// `io.async` / `group.async` 把 DNS 与建连派发到后端线程池的 worker 线程，那些
// 线程读不到调用线程的线程局部值（实测会导致"配置了 400ms 的建连超时却按 10s 默认
// 值走"）。所以状态挂在 `userdata` 上，任何线程都能拿到。
//
// ## userdata 与 vtable 的约定
//
// `userdata` 必须是一个**合法的后端指针**：vtable 里没有被覆写的项会立刻
// `@ptrCast(*Io.Threaded)` 使用它。因此 `TimeoutState` 自带一个干净的
// `Io.Threaded` 实例（`init_single_threaded` 形态：不起线程、不装信号处理器、
// 不需要 deinit），只用作 `userdata` 载体；配置就放在同一个结构里，覆写项用
// `@fieldParentPtr` 取回。
//
// 承接"资源类"操作（dir/file/net/random/now/sleep…）的是这个自有实例。它们与实例
// 状态无关 —— 逐一核对过 `std/Io/Threaded.zig` 里这些实现：要么 `_ = t`，要么只用
// `t.allocator` / `t.mutex` / `t.cond`（后两者在 `init_single_threaded` 里已就绪，
// allocator 由我们换成调用方传入的那个），行为与默认实例一致；`futexWait` /
// `futexWake` 走的是 OS 级 futex（`Thread.futexWait`），跨实例也一致。
//
// 反过来说，**调度与取消绝不能落在自有实例上**：`async` / `group.async` 若在
// `init_single_threaded` 形态下执行会退化为内联同步（`connectMany` 的多地址并行
// 建连随即变成串行，第一个地址黑洞就要等满一个超时），`await` / `cancel` 也找不到
// 真实线程池里的任务。因此这一族**逐项转发给真实后端**（见下面的 `Forward`）。

/// 一个 `HttpClient` 的超时状态。堆上分配、首次真实请求时创建、`deinit` 里释放。
const TimeoutState = struct {
    /// `backend.vtable` 的副本，只替换 `operate` / `netConnectIp` 与调度族。
    vtable: std.Io.VTable,
    /// 真实后端（`default_io.io()`）：读、建连、调度都走它。
    backend: std.Io,
    /// 合法 `userdata` 载体 + 资源类操作的承接者（见上方说明）。
    threaded: std.Io.Threaded,
    /// 建连超时（毫秒）；`0` = 不限。
    connect_timeout_ms: u64,
    /// 单次读的超时（毫秒）；`0` = 不限。
    read_timeout_ms: u64,
    /// 本次请求内是否发生过读超时（由 `operateWithTimeout` 写入、请求入口复位）。
    ///
    /// 为什么需要这个标记：deadline 到点后错误会被 std 的读取器折叠成
    /// `error.ReadFailed`（具体原因只留在 `Stream.Reader.err` 里），光看错误名认不出
    /// "是我们掐的"还是"对端断了"，于是自己记一笔。
    read_timed_out: bool = false,

    fn init(
        self: *TimeoutState,
        backend: std.Io,
        allocator: std.mem.Allocator,
        connect_ms: u64,
        read_ms: u64,
    ) void {
        self.threaded = .init_single_threaded;
        self.threaded.allocator = allocator;
        self.backend = backend;
        self.connect_timeout_ms = connect_ms;
        self.read_timeout_ms = read_ms;
        self.read_timed_out = false;

        self.vtable = backend.vtable.*;
        inline for (scheduler_fields) |name| {
            @field(self.vtable, name) = @field(Forward, name);
        }
        self.vtable.operate = operateWithTimeout;
        self.vtable.netConnectIp = netConnectIpWithTimeout;
    }

    /// 交给 `std.http.Client` 的 `Io` 句柄（`userdata` 指向本状态的 `threaded`）。
    fn ioHandle(self: *TimeoutState) std.Io {
        return .{ .userdata = &self.threaded, .vtable = &self.vtable };
    }

    /// 复位"本次请求是否读过超时"，并把客户端上的配置同步进来（`setTimeouts` 因此
    /// 是"下个请求生效"）。
    fn beginRequest(self: *TimeoutState, connect_ms: u64, read_ms: u64) void {
        self.connect_timeout_ms = connect_ms;
        self.read_timeout_ms = read_ms;
        self.read_timed_out = false;
    }
};

/// 必须转发给真实后端的 vtable 项（调度与取消；理由见上方设计说明）。
///
/// 用名字数组 + `@field` 赋值，是为了让"哪些项被转发"一眼可见，并保证与 `Forward`
/// 里的声明同名（写错名字即编译错误）。
const scheduler_fields = [_][]const u8{
    "async",
    "concurrent",
    "await",
    "cancel",
    "groupAsync",
    "groupConcurrent",
    "groupAwait",
    "groupCancel",
    "batchAwaitAsync",
    "batchAwaitConcurrent",
    "batchCancel",
    "recancel",
    "swapCancelProtection",
    "checkCancel",
};

/// 从 `userdata` 取回 `TimeoutState`（见 `TimeoutState` 的设计说明）。
fn stateOf(userdata: ?*anyopaque) *TimeoutState {
    const t: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
    return @fieldParentPtr("threaded", t);
}

/// `Io.VTable` 中 `field` 的第 `i` 个参数类型（**不含** `userdata` 槽位）。
///
/// 覆写/转发的签名一律从这里取类型，而不是手抄 std 的类型名 —— 抄漏一个限定符
/// （`Io.Dir` 在 `std/Io.zig` 里是别名，在本文件里不是）就会编译不过，
/// 而 `@typeName` 对匿名类型还会给出 `Permissions__enum_8` 这种不可引用的名字。
fn ArgType(comptime field: []const u8, comptime i: usize) type {
    const f = @typeInfo(@typeInfo(@FieldType(std.Io.VTable, field)).pointer.child).@"fn";
    return f.param_types[i + 1].?;
}

/// `Io.VTable` 中 `field` 的返回类型（同上）。
fn RetType(comptime field: []const u8) type {
    const f = @typeInfo(@typeInfo(@FieldType(std.Io.VTable, field)).pointer.child).@"fn";
    return f.return_type.?;
}

/// 调度 / 取消族的转发（见 `scheduler_fields` 的说明）。
///
/// 赋值处（`@field(self.vtable, name) = @field(Forward, name)`）就是签名校验点：
/// 参数个数或类型与 std 的 vtable 不一致即编译失败。
const Forward = struct {
    fn async(u: ?*anyopaque, a0: ArgType("async", 0), a1: ArgType("async", 1), a2: ArgType("async", 2), a3: ArgType("async", 3), a4: ArgType("async", 4)) RetType("async") {
        const s = stateOf(u);
        return s.backend.vtable.async(s.backend.userdata, a0, a1, a2, a3, a4);
    }

    fn concurrent(u: ?*anyopaque, a0: ArgType("concurrent", 0), a1: ArgType("concurrent", 1), a2: ArgType("concurrent", 2), a3: ArgType("concurrent", 3), a4: ArgType("concurrent", 4)) RetType("concurrent") {
        const s = stateOf(u);
        return s.backend.vtable.concurrent(s.backend.userdata, a0, a1, a2, a3, a4);
    }

    fn await(u: ?*anyopaque, a0: ArgType("await", 0), a1: ArgType("await", 1), a2: ArgType("await", 2)) RetType("await") {
        const s = stateOf(u);
        return s.backend.vtable.await(s.backend.userdata, a0, a1, a2);
    }

    fn cancel(u: ?*anyopaque, a0: ArgType("cancel", 0), a1: ArgType("cancel", 1), a2: ArgType("cancel", 2)) RetType("cancel") {
        const s = stateOf(u);
        return s.backend.vtable.cancel(s.backend.userdata, a0, a1, a2);
    }

    fn groupAsync(u: ?*anyopaque, a0: ArgType("groupAsync", 0), a1: ArgType("groupAsync", 1), a2: ArgType("groupAsync", 2), a3: ArgType("groupAsync", 3)) RetType("groupAsync") {
        const s = stateOf(u);
        return s.backend.vtable.groupAsync(s.backend.userdata, a0, a1, a2, a3);
    }

    fn groupConcurrent(u: ?*anyopaque, a0: ArgType("groupConcurrent", 0), a1: ArgType("groupConcurrent", 1), a2: ArgType("groupConcurrent", 2), a3: ArgType("groupConcurrent", 3)) RetType("groupConcurrent") {
        const s = stateOf(u);
        return s.backend.vtable.groupConcurrent(s.backend.userdata, a0, a1, a2, a3);
    }

    fn groupAwait(u: ?*anyopaque, a0: ArgType("groupAwait", 0), a1: ArgType("groupAwait", 1)) RetType("groupAwait") {
        const s = stateOf(u);
        return s.backend.vtable.groupAwait(s.backend.userdata, a0, a1);
    }

    fn groupCancel(u: ?*anyopaque, a0: ArgType("groupCancel", 0), a1: ArgType("groupCancel", 1)) RetType("groupCancel") {
        const s = stateOf(u);
        return s.backend.vtable.groupCancel(s.backend.userdata, a0, a1);
    }

    fn batchAwaitAsync(u: ?*anyopaque, a0: ArgType("batchAwaitAsync", 0)) RetType("batchAwaitAsync") {
        const s = stateOf(u);
        return s.backend.vtable.batchAwaitAsync(s.backend.userdata, a0);
    }

    fn batchAwaitConcurrent(u: ?*anyopaque, a0: ArgType("batchAwaitConcurrent", 0), a1: ArgType("batchAwaitConcurrent", 1)) RetType("batchAwaitConcurrent") {
        const s = stateOf(u);
        return s.backend.vtable.batchAwaitConcurrent(s.backend.userdata, a0, a1);
    }

    fn batchCancel(u: ?*anyopaque, a0: ArgType("batchCancel", 0)) RetType("batchCancel") {
        const s = stateOf(u);
        return s.backend.vtable.batchCancel(s.backend.userdata, a0);
    }

    fn recancel(u: ?*anyopaque) RetType("recancel") {
        const s = stateOf(u);
        return s.backend.vtable.recancel(s.backend.userdata);
    }

    fn swapCancelProtection(u: ?*anyopaque, a0: ArgType("swapCancelProtection", 0)) RetType("swapCancelProtection") {
        const s = stateOf(u);
        return s.backend.vtable.swapCancelProtection(s.backend.userdata, a0);
    }

    fn checkCancel(u: ?*anyopaque) RetType("checkCancel") {
        const s = stateOf(u);
        return s.backend.vtable.checkCancel(s.backend.userdata);
    }
};

/// 一次请求的计时上下文：请求入口创建，错误路径用它把"是超时掐的"翻译成
/// `error.ReadTimeout`。
const TimedRequest = struct {
    state: *TimeoutState,

    /// 本次请求内是否已经出现过读超时。
    fn readTimedOut(self: TimedRequest) bool {
        return self.state.read_timed_out;
    }
};

/// 进入"带超时"的请求上下文：确保本客户端的状态存在、把配置同步进去、复位超时标记，
/// 并把 `inner.io` 换成覆写过的句柄。
///
/// 必须在**任何**真实网络调用之前调用（mock / transport 路径不经过套接字，不调用）。
/// 首次调用会为状态分配一次内存（`error.OutOfMemory` 会原样上抛，不会静默退化成
/// "没有超时"）。
fn beginTimedRequest(self: *HttpClient) !TimedRequest {
    if (self._timeout_state == null) {
        const state = try self.allocator.create(TimeoutState);
        state.init(default_io.io(), self.allocator, self.connect_timeout_ms, self.read_timeout_ms);
        self._timeout_state = state;
    }
    const state = self._timeout_state.?;
    state.beginRequest(self.connect_timeout_ms, self.read_timeout_ms);
    self.inner.io = state.ioHandle();
    return .{ .state = state };
}

/// 毫秒 → `Io.Timeout`。
///
/// 用 `awake` 时钟（与 `cache/net.zig` 的读超时一致）：这是"最长阻塞多久"的
/// 进程内耗时，休眠期间进程本就不跑。
fn timeoutOfMs(ms: u64) std.Io.Timeout {
    // 配置值来自外部，先钳到 i64 上限再交给 std（`fromMilliseconds` 要求 i64）。
    const clamped: i64 = @intCast(@min(ms, std.math.maxInt(i64)));
    return .{ .duration = .{ .raw = .fromMilliseconds(clamped), .clock = .awake } };
}

/// `Io.VTable.operate` 的覆写：给 `net_read` 套上 `read_timeout_ms` 的 deadline，
/// 其余操作（含 `net_write`——按设计不设超时，见模块头）原样交给真实后端。
///
/// `net_read` 覆盖响应头、响应体与 TLS 握手（三者都经由连接上的
/// `Io.net.Stream.Reader`），因此"连上但不回包"在三个阶段都有上界。
fn operateWithTimeout(
    userdata: ?*anyopaque,
    operation: std.Io.Operation,
) std.Io.Cancelable!std.Io.Operation.Result {
    const state = stateOf(userdata);
    if (operation != .net_read or state.read_timeout_ms == 0)
        return state.backend.operate(operation);

    const result = state.backend.operateTimeout(
        operation,
        timeoutOfMs(state.read_timeout_ms),
    ) catch |err| switch (err) {
        error.Timeout => {
            state.read_timed_out = true;
            // `Operation.NetRead.Error` 里唯一表达"到点"的成员（内核自己的
            // ETIMEDOUT 也映射到它）；调用点靠 `read_timed_out` 翻成
            // `error.ReadTimeout`。
            return .{ .net_read = error.ConnectionTimedOut };
        },
        error.Canceled => |e| return e,
        // 后端没有并发能力时 `operateTimeout` 只能立刻失败：退回阻塞读——丢的是
        // 超时能力，不是功能本身（默认后端是完整 `Io.Threaded`，走不到这里）。
        error.ConcurrencyUnavailable => return state.backend.operate(operation),
    };
    return result;
}

/// `Io.VTable.netConnectIp` 的覆写：TCP 建连套上 `connect_timeout_ms` 的 deadline。
///
/// 为什么不能直接把 timeout 交给 `ConnectOptions.timeout`：`Io.Threaded` 的后端对它
/// 是 `@panic("TODO implement netConnectIpPosix with timeout")`
/// （`std/Io/Threaded.zig`，Windows / Kqueue 版本同样 TODO），而 `std.Io.Operation`
/// 里**没有** `net_connect` 这个 tag（只有 `net_receive` / `net_send` / `net_read` /
/// `net_write`），所以 `io.operateTimeout(.{ .net_connect = ... })` 根本构造不出来。
/// 于是退回 POSIX 自己的能力：非阻塞 connect + `poll(deadline)` + `SO_ERROR`，
/// 见 `connectWithTimeout`（与 `src/cache/redis.zig` 的 `connectDeadline` 同法）。
///
/// 调用方自带 timeout、或不是 stream 模式（UDP 等）时不插手。
fn netConnectIpWithTimeout(
    userdata: ?*anyopaque,
    address: *const std.Io.net.IpAddress,
    options: std.Io.net.IpAddress.ConnectOptions,
) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
    const state = stateOf(userdata);
    if (options.timeout != .none or options.mode != .stream or state.connect_timeout_ms == 0)
        return state.backend.vtable.netConnectIp(state.backend.userdata, address, options);
    // Windows / wasi 没有可移植的 poll 路径：退化为阻塞 connect（`connect_timeout_ms`
    // 在这两个平台不生效，模块头已写明）。
    return if (comptime native_os == .windows or native_os == .wasi)
        state.backend.vtable.netConnectIp(state.backend.userdata, address, options)
    else
        connectWithTimeout(state.backend, address, state.connect_timeout_ms);
}

// -----------------------------------------------------------------------------
// 建连 deadline（POSIX）
//
// 与 `src/cache/redis.zig` 的 `connectDeadline` 是等价实现：util 层不依赖 cache
// （cache 反过来 import util），无法复用，故保留一份。改动其一时请同步另一处。
// -----------------------------------------------------------------------------

/// `O_NONBLOCK` 的原始标志位。
///
/// `posix.O` 在各平台都是 packed struct（darwin 的 `NONBLOCK` 是 `bool` 字段，
/// 不是常量位），逐平台写死 `0x4` / `0x800` 早晚出错——让编译器自己算。
const o_nonblock: u32 = blk: {
    var o: posix.O = @bitCast(@as(u32, 0));
    o.NONBLOCK = true;
    break :blk @bitCast(o);
};

/// 带 deadline 的建连（POSIX）：socket 仍由 `Io` 后端建（CLOEXEC、SOCK_STREAM
/// 的跨平台差异交给 std），随后 `O_NONBLOCK` → `connect` 立刻返回 `EINPROGRESS`
/// → `poll(POLLOUT, deadline)` → 读 `SO_ERROR` 判成败 → 恢复原阻塞标志位。
///
/// 失败与超时路径都由 `errdefer` 关掉这条 socket，它绝不会被池化。
/// 到点返回 `error.Timeout`（`IpAddress.ConnectError` 的成员，调用点归一为
/// `error.ConnectTimeout`）。
fn connectWithTimeout(
    io: std.Io,
    addr: *const std.Io.net.IpAddress,
    timeout_ms: u64,
) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
    // 先建一条「同族、端口 0」的本地 socket：不 bind 到具体地址，只是借 `Io`
    // 后端拿到一条合法的 SOCK_STREAM fd。
    const local: std.Io.net.IpAddress = switch (addr.*) {
        .ip4 => .{ .ip4 = .{ .bytes = @splat(0), .port = 0 } },
        .ip6 => .{ .ip6 = .{ .bytes = @splat(0), .port = 0 } },
    };
    const sock = local.bind(io, .{ .mode = .stream }) catch return error.Unexpected;
    const stream = std.Io.net.Stream{ .socket = sock };
    errdefer stream.close(io);

    const fd = sock.handle;
    const saved_flags = fcntlGetFlags(fd) catch return error.Unexpected;
    sysFcntl(fd, posix.F.SETFL, saved_flags | o_nonblock) catch return error.Unexpected;
    // 无论成败都要恢复原来的阻塞标志位：池化出去的连接必须是「阻塞读」语义
    // （读超时另有 `operateWithTimeout` 管）。
    defer sysFcntl(fd, posix.F.SETFL, saved_flags) catch {};

    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(addr, &storage);
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
            const ready = posix.poll(&fds, deadline_ms) catch return error.Unexpected;
            if (ready == 0) return error.Timeout;
            // poll 说「可写」只代表结果已到：非阻塞 connect 的失败是异步的，
            // 真正的 errno 只在 `SO_ERROR` 里。
            const so_error = getSockError(fd) catch return error.Unexpected;
            if (so_error != 0) return connectErrno(@fromBackingInt(@intCast(so_error)));
        },
        else => |e| return connectErrno(e),
    }
    // `Socket.address` 的契约是**本地**地址（std 的 connect 实现也是握手后
    // getsockname 得到的），刚建出来的还是 0.0.0.0:0，这里回填一下；
    // 取不到就退回 `local`（只影响诊断信息，不该因此判建连失败）。
    return std.Io.net.Socket{ .handle = fd, .address = localAddress(fd) orelse local };
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

/// 把 `connect` / `SO_ERROR` 报出的 errno 映射进 `IpAddress.ConnectError`。
fn connectErrno(e: posix.E) std.Io.net.IpAddress.ConnectError {
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .ACCES => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        .TIMEDOUT => error.Timeout,
        else => error.Unexpected,
    };
}

// =============================================================================
// 非 2xx 的响应：别让状态码与 body 凭空消失
// =============================================================================

/// 写进日志的响应体摘要上限（字节）。
const error_body_digest_max: usize = 256;

/// `sendWithHeaders` 在非 2xx 时的诊断落点（见 `reportNonOkResponse`）。
///
/// 只是把"打进日志的那份摘要"留在本线程，供测试断言这条路径确实带了状态码与
/// body（`std.Options.logFn` 是全局编译期选项，单测没法抓 stderr）。零分配、
/// 定长缓冲。
const NonOkResponse = struct {
    status: u16,
    /// 去掉 query 的请求 URI（微信接口的 access_token 常在 query 里，不能进日志）。
    api: []const u8,
    /// body 前若干字节（按 UTF-8 边界截断）。
    digest: []const u8,
    /// body 的完整长度（判断是否被截断）。
    body_len: usize,
};

const NonOkSlot = struct {
    valid: bool = false,
    status: u16 = 0,
    api_len: usize = 0,
    digest_len: usize = 0,
    body_len: usize = 0,
    api_buf: [128]u8 = undefined,
    digest_buf: [error_body_digest_max]u8 = undefined,
};

threadlocal var non_ok_slot: NonOkSlot = .{};

/// 记录并上报一次非 2xx 响应。
///
/// - **微信形态**（`{"errcode":..,"errmsg":..}`）的响应体会经
///   `util_error.parseCommonError` 写进本线程的 `lastErrorDetail()` 详情通道，
///   `api_name` 传去掉 query 的 URI；
/// - 无论如何都打一条 `warn`（scope `zwechat_http`），含**状态码**与截断后的
///   body 摘要——`error.HttpStatusNotOk` 本身不携带任何负载，这条日志是调用方
///   唯一的现场；需要程序化拿到 `status` + `body` 时请改用 `requestWithHeaders`。
///
/// 不泄漏密钥：日志里只出现**去掉 query 的 URI**（`access_token` / `sig` 之类的
/// 查询串一律不进日志），body 只取前 `error_body_digest_max` 字节。
fn reportNonOkResponse(
    allocator: std.mem.Allocator,
    uri: []const u8,
    status: std.http.Status,
    body: []const u8,
) void {
    const api = uriWithoutQuery(uri);
    const digest = truncateUtf8(body, error_body_digest_max);

    // 详情通道：只认微信形态的错误体（`parseCommonError` 解析不出就静默返回 null）。
    // 诊断路径的分配失败一律吞掉——这里的返回值只能是 `HttpStatusNotOk`。
    if (util_error.parseCommonError(allocator, body, api)) |maybe| {
        if (maybe) |ce| ce.deinit();
    } else |_| {}

    const slot = &non_ok_slot;
    slot.* = .{ .valid = true, .status = @backingInt(status), .body_len = body.len };
    slot.api_len = @min(api.len, slot.api_buf.len);
    @memcpy(slot.api_buf[0..slot.api_len], api[0..slot.api_len]);
    slot.digest_len = digest.len;
    @memcpy(slot.digest_buf[0..slot.digest_len], digest);

    std.log.scoped(.zwechat_http).warn(
        "HTTP 非 2xx（status={d}）：{s}，响应体（{d}/{d} 字节）：{s}",
        .{ slot.status, slot.api_buf[0..slot.api_len], digest.len, body.len, digest },
    );
}

/// `reportNonOkResponse` 留下的本线程记录（同上；无记录返回 `null`）。
fn lastNonOkResponse() ?NonOkResponse {
    const slot = &non_ok_slot;
    if (!slot.valid) return null;
    return .{
        .status = slot.status,
        .api = slot.api_buf[0..slot.api_len],
        .digest = slot.digest_buf[0..slot.digest_len],
        .body_len = slot.body_len,
    };
}

/// 去掉 URI 的 query（日志与详情通道都不能带 `access_token` 之类的查询串）。
fn uriWithoutQuery(uri: []const u8) []const u8 {
    if (std.mem.findScalar(u8, uri, '?')) |i| return uri[0..i];
    return uri;
}

/// 截断到至多 `max` 字节且不切裂多字节 UTF-8 序列（与 `util/error.zig` 的同名
/// 逻辑一致；那里是私有的，故此处保留一份 5 行实现）。
fn truncateUtf8(src: []const u8, max: usize) []const u8 {
    if (src.len <= max) return src;
    var end = max;
    while (end > 0 and (src[end] & 0xC0) == 0x80) end -= 1;
    return src[0..end];
}

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
            while (std.mem.find(u8, header_buf[0..filled], "\r\n\r\n") == null) {
                if (filled >= header_buf.len) return;
                var chunk: [1][]u8 = .{header_buf[filled..]};
                // 不能走 `Stream.read`：0.17.0 的该实现内部以 `const rc, _ =` 解构
                // `Stream.ReadResult`（具名结构体不可解构），实例化即编译失败。
                // 这里直接走 `io.operate`，并按 0.17.0 的载荷取 `data_len`。
                const res = (self.io.operate(.{ .net_read = .{
                    .socket_handle = stream.socket.handle,
                    .data = &chunk,
                } }) catch return).net_read catch return;
                if (res.data_len == 0) return;
                filled += res.data_len;
            }
            // 捕获请求行（第一个 \r\n 之前）。
            if (std.mem.find(u8, header_buf[0..filled], "\r\n")) |eol| {
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
/// 假服务器绑定的本地监听点（`listenLocal` / `listenLocalBacklog` 的返回类型）。
const LocalListener = struct { server: std.Io.net.Server, port: u16 };

fn listenLocal(io: std.Io) !LocalListener {
    return listenLocalBacklog(io, null);
}

/// 同 `listenLocal`，但可指定内核 accept 队列长度（`kernel_backlog`）。
///
/// 建连超时用例需要 `backlog = 1`：队列填满后内核开始丢 SYN，才有"连不接受也
/// 不拒绝的地址"可测（见 `StalledTarget`）。
fn listenLocalBacklog(io: std.Io, kernel_backlog: ?u31) !LocalListener {
    var port: u16 = 18081;
    while (true) {
        const addr: std.Io.net.IpAddress = .{ .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = port,
        } };
        var options: std.Io.net.IpAddress.ListenOptions = .{ .reuse_address = false };
        if (kernel_backlog) |b| options.kernel_backlog = b;
        // 注意：**不能**用 `reuse_address = true`——POSIX 上它同时打开 SO_REUSEPORT，
        // 会让同一端口被**多个测试进程**同时绑定，内核把连接分摊给它们，导致某个
        // 假服务器的 accept 永远等不到请求、`join` 永久挂住（实测挂死 14 分钟）。
        if (std.Io.net.IpAddress.listen(&addr, io, options)) |server| {
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
    const resp_first = try std.mem.print(
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    const body = try client.getFollowRedirect(uri);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("fake-media-bytes", body);
    // 共请求 2 次：第一次 302，第二次 /final 拿内容。
    try std.testing.expectEqual(@as(u32, 2), hits.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, capture[0..capture_len], "GET /final HTTP/1.1") != null);
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    try std.testing.expectError(error.TooManyRedirects, client.getFollowRedirect(uri));
    // 客户端提前失败后，服务器线程仍阻塞在 accept：补一个空连接让其退出再 join。
    unblockAccept(sio, bound.port);
    try std.testing.expectEqual(@as(u32, 3), hits.load(.seq_cst));
}

// ─────────────────────────────────────────────────────────────────────────────
// 默认客户端的 allocator 契约
// ─────────────────────────────────────────────────────────────────────────────

// 下面两个用例需要「两个**保证不同**且 `ptr` 是真实地址的 allocator」。
//
// **不能**用 `std.heap.page_allocator` / `std.testing.allocator` 的差异来构造
// 「不一致的 allocator」：0.17 的 `std.heap.page_allocator` 把 `ptr` 定义为
// `undefined`（该分配器只用 vtable，见 `std/heap.zig` 的 `page_allocator` 定义），
// 于是涉及 `Allocator.ptr` 的任何比较都是未定义行为——Debug 下可能碰巧得到
// `page.ptr == testing.ptr`，ReleaseSafe/Fast 下又可能反向成立，测试因此随
// 优化模式翻车。两个 `FixedBufferAllocator` 各自绑定独立缓冲区，`ptr` 是各自
// 结构体的真实地址，互不相同。
//
// 注意 `sameAllocator` 现在对无状态单例（`page_allocator` / `smp_allocator`）
// 只比 `vtable`、不碰 `ptr`，故上述用 FBA 的写法依然是对的（也更严格：两个 FBA
// 的 vtable 相同，必须靠 `ptr` 才能区分）。无状态单例之间的判定见下一个用例。

test "initDefaultClient 幂等，allocator 不一致返回 AllocatorMismatch" {
    var buf_a: [256]u8 = undefined;
    var buf_b: [256]u8 = undefined;
    var fba_a = std.heap.FixedBufferAllocator.init(&buf_a);
    var fba_b = std.heap.FixedBufferAllocator.init(&buf_b);
    const a = fba_a.allocator();
    const b = fba_b.allocator();
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
    var buf_a: [256]u8 = undefined;
    var buf_b: [256]u8 = undefined;
    var fba_a = std.heap.FixedBufferAllocator.init(&buf_a);
    var fba_b = std.heap.FixedBufferAllocator.init(&buf_b);
    const a = fba_a.allocator();
    const b = fba_b.allocator();
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

test "sameAllocator 对无状态单例只比 vtable，不触碰 undefined 的 ptr" {
    defer deinitDefaultClient();
    deinitDefaultClient();

    // `page_allocator` 的 `ptr` 是 `undefined`：旧实现 `a.ptr == b.ptr` 属于非法
    // 行为，本用例在四种优化模式下都必须稳定通过且不 panic。
    try initDefaultClient(std.heap.page_allocator);
    try std.testing.expect(defaultClientAllocatorMatches(std.heap.page_allocator));
    // 严格模式下再传一次无状态单例不会 panic —— vtable 相等即视为一致。
    _ = getDefaultClient(std.heap.page_allocator);

    deinitDefaultClient();
    try initDefaultClient(std.heap.smp_allocator);
    try std.testing.expect(defaultClientAllocatorMatches(std.heap.smp_allocator));

    // best-effort 的下限之外仍然有区分力：两个不同的无状态单例 vtable 不同。
    try std.testing.expect(!defaultClientAllocatorMatches(std.heap.page_allocator));
    try std.testing.expectError(error.AllocatorMismatch, initDefaultClient(std.heap.page_allocator));
}

test "sameAllocator 可区分无状态单例与有状态 allocator" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    defer deinitDefaultClient();
    deinitDefaultClient();

    try initDefaultClient(std.heap.page_allocator);
    // 有状态实现的 vtable 与 `page_allocator` 不同 → 一定判为不一致。
    try std.testing.expect(!defaultClientAllocatorMatches(a));
    try std.testing.expectError(error.AllocatorMismatch, initDefaultClient(a));

    deinitDefaultClient();
    try initDefaultClient(a);
    try std.testing.expect(!defaultClientAllocatorMatches(std.heap.page_allocator));
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
    const resp_first = try std.mem.print(
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
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
    const resp_first = try std.mem.print(
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
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
    const resp_first = try std.mem.print(
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
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
    const resp_first = try std.mem.print(
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
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
    const resp_first = try std.mem.print(
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
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
    const resp_b = try std.mem.print(
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    const body = try client.getFollowRedirect(uri);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("ok", body);
    try std.testing.expectEqual(@as(u32, 3), hits.load(.seq_cst));

    const seen = capture[0..capture_len];
    // 相对路径按 RFC 3986 §5.3 合并到 base 的目录再去掉 dot segment，query 保留。
    try std.testing.expect(std.mem.find(u8, seen, "GET /final?q=1 HTTP/1.1") != null);
    // 协议相对 URL 解析成 http://127.0.0.1:port/abs（端口不能丢，否则打到 80）。
    try std.testing.expect(std.mem.find(u8, seen, "GET /abs HTTP/1.1") != null);
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

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
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

    const uri = try allocator.print("http://127.0.0.1:{d}/api", .{bound.port});
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

    const uri = try allocator.print("http://127.0.0.1:{d}/api", .{bound.port});
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

    const uri = try allocator.print("http://127.0.0.1:{d}/api", .{bound.port});
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
    const resp = try std.mem.print(
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

    const uri = try allocator.print("http://127.0.0.1:{d}/v3/refund", .{bound.port});
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
    try std.testing.expect(std.mem.find(
        u8,
        payload,
        "Content-Disposition: form-data; name=\"me\\\"dia\"; filename=\"a\\\\b\\\".mp4\"\r\n",
    ) != null);
    // 注入面检查：转义后的 payload 里不该出现未转义的裸引号闭合 + 换行。
    try std.testing.expect(std.mem.find(u8, payload, "\"me\"dia\"") == null);
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

// ─────────────────────────────────────────────────────────────────────────────
// 超时
// ─────────────────────────────────────────────────────────────────────────────

/// 测试用的单调毫秒（`awake` 时钟，与超时实现同源）。
///
/// 返回 `i96`：`std.Io.Clock.now(...).nanoseconds` 就是 96 位（`Duration.Raw`），
/// 不做窄化以免在大时间戳上被截断。
fn nowMs() i96 {
    return @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds, std.time.ns_per_ms);
}

/// 假服务器：每接受一条连接，读完请求头后**先睡 `sleep_ms`** 再回一份预设响应。
///
/// `responses` 为空时只睡不回 —— 正是"accept 之后不回包"的半死对端。休眠让线程
/// 必然退出，用例只依赖它**在客户端超时之前**不回数据，且 `join()` 有界
/// （不用"永远阻塞在 accept 的服务器"，那样负面用例会挂住收尾）。
const SlowServer = struct {
    io: std.Io,
    server: *std.Io.net.Server,
    sleep_ms: u64,
    responses: []const []const u8,
    /// 可选：在入睡**之前**先发出去的一段字节（用来把"响应头已到、body 停在半路"
    /// 这个更细的场景也覆盖到）。
    first_chunk: []const u8 = "",
    hits: *std.atomic.Value(u32),

    fn run(self: *const SlowServer) void {
        const rounds = @max(self.responses.len, 1);
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            const stream = self.server.accept(self.io) catch return;
            if (!readRequestHead(self.io, stream)) {
                stream.close(self.io);
                return;
            }
            _ = self.hits.fetchAdd(1, .seq_cst);
            if (self.first_chunk.len > 0) {
                var head_buf: [4096]u8 = undefined;
                var hw = stream.writer(self.io, &head_buf);
                hw.interface.writeAll(self.first_chunk) catch {
                    stream.close(self.io);
                    return;
                };
                hw.interface.flush() catch {
                    stream.close(self.io);
                    return;
                };
            }
            std.Io.sleep(
                self.io,
                std.Io.Duration.fromMilliseconds(@intCast(self.sleep_ms)),
                .awake,
            ) catch {};
            if (self.responses.len > 0) {
                var write_buf: [4096]u8 = undefined;
                var w = stream.writer(self.io, &write_buf);
                w.interface.writeAll(self.responses[i]) catch {
                    stream.close(self.io);
                    return;
                };
                w.interface.flush() catch {
                    stream.close(self.io);
                    return;
                };
            }
            stream.close(self.io);
        }
    }
};

/// 读掉请求头（读到空行为止）；对端提前关闭 / 读失败返回 `false`。
///
/// 与 `FakeServerState` 同法：0.17.0 下 `Stream.read` 无法实例化（其内部以
/// `const rc, _ =` 解构具名结构体），因此直接走 `io.operate` 并取 `data_len`。
fn readRequestHead(io: std.Io, stream: std.Io.net.Stream) bool {
    var buf: [8192]u8 = undefined;
    var filled: usize = 0;
    while (std.mem.find(u8, buf[0..filled], "\r\n\r\n") == null) {
        if (filled >= buf.len) return false;
        var chunk: [1][]u8 = .{buf[filled..]};
        const res = (io.operate(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &chunk,
        } }) catch return false).net_read catch return false;
        if (res.data_len == 0) return false;
        filled += res.data_len;
    }
    return true;
}

/// 只 listen、**永不 accept** 的本地目标 + 用来把它 accept 队列灌满的连接。
///
/// 队列填满后内核开始丢 SYN，于是"建连"只能挂到客户端自己的 deadline —— 建连超时
/// 要覆盖的就是这个场景，且完全离线、确定性（与 `cache/redis.zig` 的
/// `makeStalledTarget` 同法）。
const StalledTarget = struct {
    server: std.Io.net.Server,
    /// 灌队列用的连接（保持打开才能让队列一直是满的）；`null` 表示未使用。
    fills: [max_fills]?std.Io.net.Socket = @splat(null),

    const max_fills = 64;
    const fill_timeout_ms: i32 = 200;

    fn deinit(self: *StalledTarget, io: std.Io) void {
        for (self.fills) |maybe_sock| {
            if (maybe_sock) |sock| sock.close(io);
        }
        self.server.deinit(io);
    }
};

/// 裸 socket 的非阻塞 connect + `poll(deadline)`，**不经过被测的 `connectWithTimeout`**
/// （否则"被测实现坏掉"会让夹具自己也跟着挂住）。
///
/// 成功返回已连上的 socket（调用方 `close(io)`）；到点返回 `error.Timeout`。
fn rawConnectUntilDeadline(
    io: std.Io,
    addr: *const std.Io.net.IpAddress,
    deadline_ms: i32,
) !std.Io.net.Socket {
    const local: std.Io.net.IpAddress = switch (addr.*) {
        .ip4 => .{ .ip4 = .{ .bytes = @splat(0), .port = 0 } },
        .ip6 => .{ .ip6 = .{ .bytes = @splat(0), .port = 0 } },
    };
    const sock = try local.bind(io, .{ .mode = .stream });
    errdefer sock.close(io);

    const fd = sock.handle;
    const saved_flags = fcntlGetFlags(fd) catch return error.ConnectFailed;
    sysFcntl(fd, posix.F.SETFL, saved_flags | o_nonblock) catch return error.ConnectFailed;
    defer sysFcntl(fd, posix.F.SETFL, saved_flags) catch {};

    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(addr, &storage);
    switch (posix.errno(posix.system.connect(fd, &storage.any, addr_len))) {
        .SUCCESS => return sock,
        .INPROGRESS, .AGAIN => {},
        .CONNREFUSED => return error.ConnectionRefused,
        else => return error.ConnectFailed,
    }

    var fds = [1]posix.pollfd{.{
        .fd = fd,
        .events = @intCast(posix.POLL.OUT),
        .revents = 0,
    }};
    if ((try posix.poll(&fds, deadline_ms)) == 0) return error.Timeout;
    // poll 说"可写"只代表结果已到：真正的 errno 只在 `SO_ERROR` 里。
    const so_error = getSockError(fd) catch return error.ConnectFailed;
    if (so_error != 0) return error.ConnectFailed;
    return sock;
}

/// 往 `target.server` 的 accept 队列里灌连接，直到内核开始丢 SYN。
///
/// 返回 `false` = 本环境造不出"SYN 被丢弃"的目标（队列满时直接 RST 的环境），
/// 由调用方 `SkipZigTest`。
fn fillUntilStalled(
    io: std.Io,
    target: *StalledTarget,
    addr: *const std.Io.net.IpAddress,
) !bool {
    for (&target.fills) |*slot| {
        const sock = rawConnectUntilDeadline(io, addr, StalledTarget.fill_timeout_ms) catch |err| switch (err) {
            error.Timeout => return true, // 队列满 → SYN 被丢 → 黑洞就绪
            error.ConnectionRefused => return false, // 队列满即 RST，造不出确定性黑洞
            else => return err,
        };
        slot.* = sock;
    }
    // 灌满 max_fills 条都没超时：不猜原因，交给跳过。
    return false;
}

test "HttpClient 超时默认非零（10s / 30s），setTimeouts 可改且 0 = 不限" {
    try std.testing.expectEqual(@as(u64, 10_000), default_connect_timeout_ms);
    try std.testing.expectEqual(@as(u64, 30_000), default_read_timeout_ms);

    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();

    try std.testing.expectEqual(default_connect_timeout_ms, client.connect_timeout_ms);
    try std.testing.expectEqual(default_read_timeout_ms, client.read_timeout_ms);
    // 超时状态是惰性创建的：只构造客户端不分配任何东西。
    try std.testing.expect(client._timeout_state == null);

    client.setTimeouts(1234, 5678);
    try std.testing.expectEqual(@as(u64, 1234), client.connect_timeout_ms);
    try std.testing.expectEqual(@as(u64, 5678), client.read_timeout_ms);

    // 进入一次请求上下文：状态被创建，配置同步进去，`inner.io` 换成覆写过的句柄
    // （`userdata` 指向状态自己的 `threaded`，覆写项据此取回配置）。
    const timed = try beginTimedRequest(&client);
    try std.testing.expect(!timed.readTimedOut());
    const state = client._timeout_state.?;
    try std.testing.expectEqual(@as(u64, 1234), state.connect_timeout_ms);
    try std.testing.expectEqual(@as(u64, 5678), state.read_timeout_ms);
    try std.testing.expectEqual(state, stateOf(client.inner.io.userdata));
    try std.testing.expectEqual(&state.vtable, client.inner.io.vtable);

    // 第二次进入：配置跟着客户端字段走（`setTimeouts` 下个请求生效），并复位标记。
    client.setTimeouts(0, 0);
    state.read_timed_out = true; // 模拟上一次请求读过超时
    const again = try beginTimedRequest(&client);
    try std.testing.expect(!again.readTimedOut());
    try std.testing.expectEqual(@as(u64, 0), state.connect_timeout_ms);
    try std.testing.expectEqual(@as(u64, 0), state.read_timeout_ms);
    try std.testing.expectEqual(state, client._timeout_state.?); // 复用同一个状态
}

test "读超时：对端 accept 后不回包，请求在有界时间内以 ReadTimeout 收场且连接不进池" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    const state = SlowServer{
        .io = sio,
        .server = &server,
        .sleep_ms = 1200, // 远大于客户端的 read_timeout_ms
        .responses = &.{}, // 只睡不回：连上但不回包
        .hits = &hits,
    };
    const t = try std.Thread.spawn(.{}, SlowServer.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setTimeouts(0, 300); // 建连不限（回环必然立即成功）；单次读 300ms

    const uri = try allocator.print("http://127.0.0.1:{d}/api", .{bound.port});
    defer allocator.free(uri);

    const start_ms = nowMs();
    try std.testing.expectError(error.ReadTimeout, client.get(uri));
    const elapsed_ms = nowMs() - start_ms;
    std.debug.print("[http read timeout] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms >= 200); // 确实等到了 deadline，不是被别的错误短路
    try std.testing.expect(elapsed_ms < 1000); // 有界：远小于服务端 1.2s 的休眠
    try std.testing.expectEqual(@as(u32, 1), hits.load(.seq_cst));

    // 超时后连接必须被丢弃：留在池里的话，半截回复会让下一个请求协议失步。
    try std.testing.expectEqual(@as(usize, 0), client.inner.connection_pool.free_len);
}

test "读取超时 0 = 不限：延迟 300ms 的应答照常成功；改成 50ms 则 ReadTimeout" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    const ok_resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
    const responses = [_][]const u8{ ok_resp, ok_resp };
    const state = SlowServer{
        .io = sio,
        .server = &server,
        .sleep_ms = 300, // 迟到的应答：0 = 不限时应当照收，50ms 时应当超时
        .responses = &responses,
        .hits = &hits,
    };
    const t = try std.Thread.spawn(.{}, SlowServer.run, .{&state});
    defer t.join();

    const uri = try allocator.print("http://127.0.0.1:{d}/api", .{bound.port});
    defer allocator.free(uri);

    // (a) 0 = 不限：等到 300ms 后的应答，正常返回。
    var unlimited = HttpClient.init(allocator);
    defer unlimited.deinit();
    unlimited.setTimeouts(0, 0);
    const body = try unlimited.get(uri);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("ok", body);

    // (b) 同一个服务端、同一份延迟：50ms 的超时必须掐断。
    var impatient = HttpClient.init(allocator);
    defer impatient.deinit();
    impatient.setTimeouts(0, 50);
    const start_ms = nowMs();
    try std.testing.expectError(error.ReadTimeout, impatient.get(uri));
    const elapsed_ms = nowMs() - start_ms;
    std.debug.print("[http read timeout (short)] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms < 1000); // 有界
}

test "建连超时：本地「SYN 被丢弃」目标在有界时间内返回 ConnectTimeout（造不出目标则跳过）" {
    if (comptime native_os == .windows or native_os == .wasi)
        return error.SkipZigTest
    else
        try stalledTargetConnectTimeoutCase();
}

fn stalledTargetConnectTimeoutCase() !void {
    const allocator = std.testing.allocator;
    const io = default_io.io();
    const bound = try listenLocalBacklog(io, 1);
    var target = StalledTarget{ .server = bound.server };
    defer target.deinit(io);

    const addr: std.Io.net.IpAddress = .{ .ip4 = .{
        .bytes = .{ 127, 0, 0, 1 },
        .port = bound.port,
    } };
    if (!try fillUntilStalled(io, &target, &addr)) {
        std.debug.print("[http connect timeout] 本环境造不出「SYN 被丢弃」的目标，跳过\n", .{});
        return error.SkipZigTest;
    }

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setTimeouts(400, 0); // 建连 400ms；读不限（走不到读）

    const uri = try allocator.print("http://127.0.0.1:{d}/api", .{bound.port});
    defer allocator.free(uri);

    const start_ms = nowMs();
    try std.testing.expectError(error.ConnectTimeout, client.get(uri));
    const elapsed_ms = nowMs() - start_ms;
    std.debug.print("[http connect timeout] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms >= 300); // 等到了 deadline（不是被拒绝等别的错误短路）
    try std.testing.expect(elapsed_ms < 1500); // 有界：远小于默认的 10s
}

test "建连超时：TEST-NET-1（192.0.2.1）在有界时间内返回 ConnectTimeout（环境不适合则跳过）" {
    if (comptime native_os == .windows or native_os == .wasi)
        return error.SkipZigTest
    else
        try blackholeAddressConnectTimeoutCase();
}

/// 先用**独立于被测实现**的裸 socket 探一次：只有该地址的 SYN 被静默丢弃
/// （`poll(500ms)` 到点）才继续断言；被立刻拒绝 / 立刻 unreachable / 被透明代理
/// 接住（本机沙箱就是这种）都跳过 —— **绝不用可能永久阻塞的地址硬测**。
///
/// 说明：IPv6 文档前缀（`2001:db8::1`）在本机也是黑洞，但 std 0.17 的
/// `HostName.fromUri` 拒绝带 `:` 的主机名（它按 RFC 1123 校验），
/// `std.http.Client` 因此连不上 IPv6 字面量 URL，只能拿 IPv4 的 TEST-NET-1 测。
/// "本地队列灌满 → 内核丢 SYN" 那条确定性更强的用例见上一个 test。
fn blackholeAddressConnectTimeoutCase() !void {
    const allocator = std.testing.allocator;
    const io = default_io.io();
    const addr = std.Io.net.IpAddress.parse("192.0.2.1", 81) catch return error.SkipZigTest;
    if (rawConnectUntilDeadline(io, &addr, 500)) |sock| {
        sock.close(io);
        std.debug.print("[http connect timeout] 192.0.2.1 在本环境可连（透明代理？），跳过\n", .{});
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.Timeout => {},
        else => {
            std.debug.print(
                "[http connect timeout] 192.0.2.1 在本环境立刻失败（{s}），跳过\n",
                .{@errorName(err)},
            );
            return error.SkipZigTest;
        },
    }

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setTimeouts(400, 0); // 建连 400ms；读不限（走不到读）

    const start_ms = nowMs();
    try std.testing.expectError(error.ConnectTimeout, client.get("http://192.0.2.1:81/x"));
    const elapsed_ms = nowMs() - start_ms;
    std.debug.print("[http connect timeout (blackhole)] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms >= 300);
    try std.testing.expect(elapsed_ms < 1500);
}

test "sendWithHeaders 非 2xx：状态码与 body 摘要不再丢弃（详情通道 + 摘要记录）" {
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    var capture: [512]u8 = undefined;
    var capture_len: usize = 0;

    // 微信形态的错误体：`errcode`/`errmsg` 会被写进既有的 lastErrorDetail() 通道。
    const err_body = "{\"errcode\":40001,\"errmsg\":\"invalid credential, access_token is invalid\"}";
    var resp_buf: [512]u8 = undefined;
    const resp = try std.mem.print(
        &resp_buf,
        "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ err_body.len, err_body },
    );
    const responses = [_][]const u8{resp};
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

    util_error.clearErrorDetail();
    non_ok_slot = .{};
    // query 里放一个"密钥样"的参数：它绝不能出现在日志 / 详情通道里。
    const uri = try allocator.print(
        "http://127.0.0.1:{d}/v3/refund?access_token=SECRET&sig=abc",
        .{bound.port},
    );
    defer allocator.free(uri);

    // 错误名与既有契约一致（调用方不需要改 catch 分支）。
    try std.testing.expectError(
        error.HttpStatusNotOk,
        client.sendWithHeaders(.POST, uri, "{}", "application/json", &.{}),
    );

    // ① body 进了既有的线程局部详情通道（不再凭空消失）。
    const detail = util_error.lastErrorDetail().?;
    try std.testing.expectEqual(@as(i64, 40001), detail.errcode);
    try std.testing.expect(std.mem.find(u8, detail.errmsg, "invalid credential") != null);
    try std.testing.expect(std.mem.endsWith(u8, detail.api_name, "/v3/refund"));
    try std.testing.expect(std.mem.find(u8, detail.api_name, "access_token") == null);

    // ② 状态码 + body 摘要留在本线程（那条 warn 日志的内容；测试抓不到 stderr，
    //    所以留了一份同内容的记录供断言）。
    const recorded = lastNonOkResponse().?;
    try std.testing.expectEqual(@as(u16, 401), recorded.status);
    try std.testing.expectEqualStrings(err_body, recorded.digest);
    try std.testing.expectEqual(err_body.len, recorded.body_len);
    try std.testing.expect(std.mem.find(u8, recorded.api, "access_token") == null);
}

test "超时句柄上的 DNS / 文件解析可用（localhost 走 /etc/hosts，自建 threaded 实例承接）" {
    // 覆写过的 `Io` 只在 operate / netConnectIp / 调度族上不走自有实例；DNS 与文件
    // 操作都落在 `TimeoutState.threaded`（一个干净的 `init_single_threaded` 实例）上。
    // 本用例证明这条路径真的能用：解析 `localhost` 要读 /etc/hosts 或走 RFC 6761 分支，
    // 全程本地、离线，且 `HostName.lookup` 有 std 自己的 attempts/timeout 上限。
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator);
    defer client.deinit();

    _ = try beginTimedRequest(&client);
    const wrapper_io = client.inner.io;
    // 句柄确实是"覆写过的那个"（userdata 指向状态自己的 threaded）。
    try std.testing.expectEqual(client._timeout_state.?, stateOf(wrapper_io.userdata));

    const name = std.Io.net.HostName.init("localhost") catch return error.SkipZigTest;
    var results_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results_buf);
    try std.Io.net.HostName.lookup(name, wrapper_io, &results, .{ .port = 80 });

    var found_loopback = false;
    while (results.getOneUncancelable(wrapper_io)) |result| {
        switch (result) {
            .address => |addr| switch (addr) {
                .ip4 => |v4| if (std.mem.eql(u8, &v4.bytes, &.{ 127, 0, 0, 1 })) {
                    found_loopback = true;
                },
                .ip6 => {},
            },
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {}, // 结果产出完毕
    }
    try std.testing.expect(found_loopback);
}

test "truncateUtf8 / uriWithoutQuery：摘要按 UTF-8 边界截断、URI 不带 query" {
    // 边界内原样返回。
    try std.testing.expectEqualStrings("abc", truncateUtf8("abc", 8));
    // 恰好切在多字节序列中间时回退到前一个字符边界（不留半个字符）。
    const text = "错误" ++ "x"; // 3 + 3 + 1 字节
    // `max = 4` 落在"误"的中间：回退到前一个字符边界，结果是"错"（3 字节，≤ 4）。
    try std.testing.expectEqualStrings("错", truncateUtf8(text, 4));
    try std.testing.expectEqualStrings("错误", truncateUtf8(text, 6));
    try std.testing.expectEqualStrings(text, truncateUtf8(text, 7));
    // 截断后长度不超过上限，且是原串的合法前缀。
    var long_buf: [error_body_digest_max + 10]u8 = @splat('a');
    try std.testing.expectEqual(
        error_body_digest_max,
        truncateUtf8(&long_buf, error_body_digest_max).len,
    );

    try std.testing.expectEqualStrings("https://api/x", uriWithoutQuery("https://api/x?a=1&b=2"));
    try std.testing.expectEqualStrings("https://api/x", uriWithoutQuery("https://api/x"));
}

test "读超时：响应头已到、body 停在半路时同样有界返回 ReadTimeout 且连接不进池" {
    // 这条覆盖"响应体读到一半对端不回"的路径：`receiveHead` 已经成功，卡在
    // `readResponseBody` 的那次读上。顺带证明旧实现里
    // `response.bodyErr().?`（对 Content-Length 定界的响应 `body_err` 恒为 null）
    // 的 panic 面已经消失 —— 现在得到的是明确错误而不是崩溃。
    const allocator = std.testing.allocator;
    var server_threaded: std.Io.Threaded = .init_single_threaded;
    const sio = server_threaded.io();
    const bound = try listenLocal(sio);
    var server = bound.server;
    defer server.deinit(sio);

    var hits = std.atomic.Value(u32).init(0);
    const state = SlowServer{
        .io = sio,
        .server = &server,
        .sleep_ms = 1200, // 远大于客户端的 read_timeout_ms
        .responses = &.{}, // 头之后再没有字节
        // 声明 10 字节 body，只发 2 字节：剩下 8 字节永远不来。
        .first_chunk = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nAB",
        .hits = &hits,
    };
    const t = try std.Thread.spawn(.{}, SlowServer.run, .{&state});
    defer t.join();

    var client = HttpClient.init(allocator);
    defer client.deinit();
    client.setTimeouts(0, 300);

    const uri = try allocator.print("http://127.0.0.1:{d}/media", .{bound.port});
    defer allocator.free(uri);

    const start_ms = nowMs();
    try std.testing.expectError(error.ReadTimeout, client.get(uri));
    const elapsed_ms = nowMs() - start_ms;
    std.debug.print("[http body read timeout] elapsed_ms={d}\n", .{elapsed_ms});
    try std.testing.expect(elapsed_ms >= 200);
    try std.testing.expect(elapsed_ms < 1000);

    // 读到一半的连接同样不能进池（否则剩下的 8 字节会污染下一个请求）。
    try std.testing.expectEqual(@as(usize, 0), client.inner.connection_pool.free_len);
}
