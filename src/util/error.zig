// SPDX-License-Identifier: Apache-2.0
//! util/error — 通用错误类型与微信接口返回错误解析
//!
//! 对应 `_ref/wechat/util/error.go`：
//! - `CommonError`：微信接口返回的通用错误结构（errcode / errmsg / api_name）。
//! - `DecodeWithCommonError`：把一段 JSON 响应解析成 `CommonError`，仅当 errcode != 0 时返回错误。
//! - `HandleFileResponse`：通用处理——若响应是 JSON 错误则返回错误，否则原样返回字节。
//!
//! Zig 版同样保留 `WechatError` 错误集作为上层统一错误码，并提供
//! `decodeWithCommonError` / `handleFileResponse` 两个解码函数。
//!
//! ## errcode 详情通道（线程局部）
//!
//! Zig 的 `error` 值**不能携带负载**（没有 Go 的 `error` 接口 / `errors.As`），因此
//! `WechatError.ApiError` 只能表达"微信返回了 errcode != 0"，无法区分 40001（token 失效）
//! / 45009（超频）/ 40003（openid 非法）/ 48001（未授权）。为了在不破坏 60 处既有调用点
//! （`if (try decodeWithCommonError(...)) |ce| return WechatError.ApiError;`）的前提下补齐这一
//! 信息，本模块在内部维护一条**线程局部**的详情通道：
//!
//! - `parseCommonError`（即 `decodeWithCommonError` 的实现）在 `errcode != 0` 时、
//!   `handleFileResponse` 在识别出 JSON 错误体时，都会把 `{errcode, errmsg, api_name}`
//!   记录进线程局部缓冲（**零堆分配**，定长数组 + 字节截断）。
//! - 消费方在 catch 分支里用 `lastErrorDetail()` 读取即可，既有调用点零改动：
//!
//! ```zig
//! const body = try util.http.get(...);
//! const ce = util_error.decodeWithCommonError(alloc, body, "Send") catch |err| {
//!     if (util_error.lastErrorDetail()) |d| {
//!         std.log.warn("wechat api failed: {s} errcode={d} errmsg={s}", .{ d.api_name, d.errcode, d.errmsg });
//!     }
//!     return err;
//! };
//! if (ce) |e| { defer e.deinit(); return util_error.WechatError.ApiError; }
//! ```
//!
//! ### 为什么要线程局部
//!
//! 详情通道若做成全局变量，多线程并发调用同一个 SDK 时会互相覆盖对方的 errcode
//! （A 线程的日志里出现 B 线程的 45009），比没有还糟。线程局部则保证"谁记录、谁读取"：
//! 记录与读取都无需加锁（无共享写），也就不会在错误路径上引入自旋锁竞争。
//!
//! ### 线程安全边界
//!
//! - 同一线程内：记录 → 读取是顺序一致的（普通内存读写，不涉及原子/锁）。
//! - 跨线程：**不共享、不传播**。若工作被派发到线程池执行、错误在调用线程上浮现，
//!   调用线程看不到工作线程的详情；此类场景请让工作线程自行读取或改用下面的
//!   `CommonError` 显式回传。
//! - 生命周期：返回的切片指向线程局部缓冲，有效期至**本线程**下一次记录或
//!   `clearErrorDetail()`。需要长期保存/跨线程传递请自行 dupe。
//!
//! ### 与 `CommonError` 的分工
//!
//! | | `CommonError` | `ErrorDetail` |
//! |---|---|---|
//! | 内存 | 拥有 `errmsg` 深拷贝，须 `deinit` | 借用线程局部缓冲，不分配、不释放 |
//! | 获取 | `decodeWithCommonError` 返回值（须显式解引用） | `lastErrorDetail()`，在 catch 分支里随时可取 |
//! | 用途 | 需要结构化错误对象 / `format` 日志 / 跨线程传递 | 兜底诊断：调用点已把 errcode 丢成 `ApiError` 时查证原因 |

const std = @import("std");
const json = std.json;

/// 顶层微信错误集合。所有上层 API 失败时都应回落到该集合的某个变体。
///
/// 该集合刻意保持粗粒度（成员数量与上游 Go 版一致，不随微信 errcode 增长）：
/// Zig 的 `error` 值不能携带负载，具体 errcode 由线程局部通道补充，
/// 在 catch 分支中用 `lastErrorDetail()` 读取。
pub const WechatError = error{
    /// 微信接口返回 errcode != 0。具体 errcode / errmsg 见 `lastErrorDetail()`。
    ApiError,
    /// 网络 / HTTP 失败。
    NetworkError,
    /// JSON / XML 解析失败。
    DecodeError,
    /// access_token 过期。
    AccessTokenExpired,
    /// 配置缺失（app_id / app_secret / token 等）。
    ConfigMissing,
    /// 参数非法。
    InvalidArgument,
};

/// 微信接口返回的通用错误响应。
///
/// 与上游 Go 版字段一一对应：`errcode` 为错误码（0 表示成功），`errmsg` 为错误描述，
/// `api_name` 是调用方传入的接口名（如 "Send"），便于排错。
///
/// `errmsg` 由 `parseCommonError` 深拷贝而来（拥有），调用方读取完后必须调用
/// `deinit` 释放，否则泄漏。
pub const CommonError = struct {
    api_name: []const u8,
    errcode: i64,
    errmsg: []const u8,

    /// 用于释放 `errmsg` 的 allocator（`api_name` 借用调用方，不释放）。
    _allocator: ?std.mem.Allocator = null,

    /// 格式化为字符串，等价于 Go 的 `fmt.Sprintf("%s Error , errcode=%d , errmsg=%s", ...)`。
    pub fn format(self: CommonError, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s} Error , errcode={d} , errmsg={s}",
            .{ self.api_name, self.errcode, self.errmsg },
        );
    }

    /// 释放 `errmsg` 深拷贝。按值调用，释放后不应再读取 `errmsg`。
    pub fn deinit(self: CommonError) void {
        if (self._allocator) |a| {
            if (self.errmsg.len > 0) a.free(@constCast(self.errmsg));
        }
    }
};

const CommonErrorJson = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

// -----------------------------------------------------------------------------
// errcode 详情通道（线程局部，无堆分配）
// -----------------------------------------------------------------------------

/// 最近一次微信接口失败的详情（`errcode` / `errmsg` / `api_name`）。
///
/// 由 `lastErrorDetail()` 返回，`errmsg` 与 `api_name` 是**指向线程局部缓冲的借用切片**，
/// 不拥有内存、无需释放；有效期至本线程下一次记录错误或调用 `clearErrorDetail()`。
/// 需要跨线程传递或长期保存请自行 `std.mem.Allocator.dupe`。
pub const ErrorDetail = struct {
    /// 微信返回的错误码（非 0）。
    errcode: i64,
    /// 微信返回的错误描述，超过 `ErrorDetailErrMsgCap` 时在 UTF-8 边界处截断。
    errmsg: []const u8,
    /// 调用方传入的接口名，超过 `ErrorDetailApiNameCap` 时在 UTF-8 边界处截断。
    api_name: []const u8,
};

/// `errmsg` 缓冲容量（字节）。取 512 是因为微信 errmsg 绝大多数在 100B 以内，
/// 512B 足以覆盖含参数回显的长文案，同时让线程局部槽位保持在 1KB 以内。
pub const ErrorDetailErrMsgCap: usize = 512;

/// `api_name` 缓冲容量（字节）。
pub const ErrorDetailApiNameCap: usize = 64;

/// 每个线程一份的详情槽位。零初始化（`valid = false`）表示"本线程尚无记录"。
const ErrorDetailSlot = struct {
    valid: bool = false,
    errcode: i64 = 0,
    errmsg_len: usize = 0,
    api_name_len: usize = 0,
    errmsg_buf: [ErrorDetailErrMsgCap]u8 = undefined,
    api_name_buf: [ErrorDetailApiNameCap]u8 = undefined,
};

/// 线程局部详情槽位：线程启动时 `valid = false`，线程退出时由 runtime 回收。
/// 所有字段都是定长数组，读写不碰堆、不加锁。
threadlocal var error_detail: ErrorDetailSlot = .{};

/// 把 `src` 截断到至多 `max` 字节，且不切裂多字节 UTF-8 序列。
///
/// 策略：若被排除的首字节是延续字节（`10xxxxxx`），则向前回退到最近的非延续字节处，
/// 因此结果长度可能略小于 `max`（最多少 3 字节）。**不追加省略号**，保证结果始终是
/// 输入的合法前缀：截断后的 `errmsg.len == ErrorDetailErrMsgCap` 即提示可能已被截断。
fn truncateAtUtf8Boundary(src: []const u8, max: usize) []const u8 {
    if (src.len <= max) return src;
    var end = max;
    while (end > 0 and (src[end] & 0xC0) == 0x80) end -= 1;
    return src[0..end];
}

/// 记录一次失败详情到本线程的槽位（覆盖上一条）。
///
/// `errmsg` / `api_name` 超长时按 UTF-8 边界截断；空切片记录为空串（`len == 0`）。
fn recordErrorDetail(errcode: i64, errmsg: []const u8, api_name: []const u8) void {
    const em = truncateAtUtf8Boundary(errmsg, ErrorDetailErrMsgCap);
    const an = truncateAtUtf8Boundary(api_name, ErrorDetailApiNameCap);
    @memcpy(error_detail.errmsg_buf[0..em.len], em);
    @memcpy(error_detail.api_name_buf[0..an.len], an);
    error_detail.errmsg_len = em.len;
    error_detail.api_name_len = an.len;
    error_detail.errcode = errcode;
    error_detail.valid = true;
}

/// 读取本线程最近一次记录的失败详情；本线程尚无记录时返回 `null`。
///
/// 返回的切片借用线程局部缓冲，**有效期至本线程下一次记录错误或 `clearErrorDetail()`**；
/// 跨线程不可见（其它线程读到的是它们各自的记录）。不分配内存，无需释放，可在 catch
/// 分支或日志路径上安全调用。
pub fn lastErrorDetail() ?ErrorDetail {
    if (!error_detail.valid) return null;
    return .{
        .errcode = error_detail.errcode,
        .errmsg = error_detail.errmsg_buf[0..error_detail.errmsg_len],
        .api_name = error_detail.api_name_buf[0..error_detail.api_name_len],
    };
}

/// 清空本线程的失败详情（`lastErrorDetail()` 随后返回 `null`）。
///
/// 注意：**成功的调用不会自动清空**详情——`parseCommonError` 只在 `errcode != 0` 时记录，
/// `errcode == 0` 直接返回 `null` 而不触碰槽位。这样"先失败、后成功"的序列仍能查到最近一次
/// 失败原因（例如 access_token 强刷重试成功，但你想记录首次 40001 的原因）。
/// 需要"本次调用成功即视为无错误"的语义时，请在调用前显式调用本函数。
pub fn clearErrorDetail() void {
    error_detail.valid = false;
    error_detail.errcode = 0;
    error_detail.errmsg_len = 0;
    error_detail.api_name_len = 0;
}

/// 将一段微信接口的 JSON 响应按 `CommonError` 解析。
///
/// - 当响应可解析为 JSON 且 `errcode != 0` 时，返回 `WechatError.ApiError` 并把详情放在
///   `error.value` 中（通过 `error.Unexpected` 携带是不现实的，因此改用 `error.ApiError`，
///   调用方拿到 `err` 后用 `decodeWithCommonError` 再次解析来获取细节）。
/// - 当响应可解析为 JSON 且 `errcode == 0` 时，返回 `null`。
/// - 当响应无法解析为 JSON 时，返回 `WechatError.DecodeError`。
///
/// 调用方拿到 `null` 即代表成功；若希望直接拿到错误结构，可使用 `parseCommonError`。
///
/// `errcode != 0` 时还会把 `{errcode, errmsg, api_name}` 记录进本线程详情通道
/// （见 `lastErrorDetail()`），因此把结果就地丢成 `WechatError.ApiError` 的调用点
/// 也能在 catch 分支里取回具体错误码，无需再做一次解析。
pub fn decodeWithCommonError(
    allocator: std.mem.Allocator,
    response: []const u8,
    api_name: []const u8,
) WechatErrorDecodeError!?CommonError {
    return parseCommonError(allocator, response, api_name);
}

/// 判断错误码是否属于 access_token 失效/过期类型（如 40001, 40014, 41001, 42001）。
pub fn isTokenInvalidErrCode(errcode: i64) bool {
    return switch (errcode) {
        40001, 40014, 41001, 42001 => true,
        else => false,
    };
}

/// 同 `decodeWithCommonError`，但在出现 errcode != 0 时直接返回 `WechatError.ApiError` 错误。
///
/// `errcode != 0` 时除了返回 `CommonError`，还会把 `{errcode, errmsg, api_name}` 记录进
/// **本线程**的详情槽位（见 `lastErrorDetail()`），因此所有只管把结果丢成
/// `WechatError.ApiError` 的既有调用点也能零改动拿到 errcode。
pub fn parseCommonError(
    allocator: std.mem.Allocator,
    response: []const u8,
    api_name: []const u8,
) WechatErrorDecodeError!?CommonError {
    const parsed = json.parseFromSlice(
        CommonErrorJson,
        allocator,
        response,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // JSON 结构不符合 CommonError 形态时（如空响应 / 非 JSON），不视为错误，
        // 留给上层用 `handleFileResponse` 之类的逻辑兜底。
        else => return null,
    };
    defer parsed.deinit();
    const v = parsed.value;
    if (v.errcode == 0) return null;
    // 先记录详情：此后即便调用方不读 errmsg 或提前 free，通道里的副本仍然有效。
    recordErrorDetail(v.errcode, v.errmsg, api_name);
    // 深拷贝 errmsg，避免其在 parsed.deinit 后悬垂（UAF）。
    const errmsg_dup = try allocator.dupe(u8, v.errmsg);
    return CommonError{
        .api_name = api_name,
        .errcode = v.errcode,
        .errmsg = errmsg_dup,
        ._allocator = allocator,
    };
}

/// 把任意 JSON 响应解析到 `obj` 中，再判断 `obj` 是否内嵌了 `CommonError`：
/// 若是且 `errcode != 0`，返回对应的 `CommonError`。
///
/// `T` 必须是一个结构体，且（如果需要错误检测）其字段中有名为 `common_error` 的嵌套
/// `CommonError` 字段。Go 版使用反射，Zig 版显式走模板。
///
/// 返回的 `std.json.Parsed(T)` 由调用方持有并负责 `deinit`，避免内部切片
/// 在返回前被释放导致 use-after-free。
///
/// 注意：当前实现只做 JSON 解码，**不检查** `obj` 内嵌的 errcode（`api_name` 暂未使用），
/// 因此也不会写入详情通道。需要 errcode 时请额外调用 `decodeWithCommonError`，
/// 或直接使用 `lastErrorDetail()` 读取由它记录的详情。
pub fn decodeWithError(
    comptime T: type,
    allocator: std.mem.Allocator,
    response: []const u8,
    api_name: []const u8,
) WechatErrorDecodeError!std.json.Parsed(T) {
    _ = api_name; // reserved for future use (CommonError checking)
    return json.parseFromSlice(
        T,
        allocator,
        response,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch |err| switch (err) {
        // 分配失败必须原样向上传播，不能吞成 DecodeError（调用方可能重试）。
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.DecodeError,
    };
}

/// 错误集合：仅在 JSON 解析失败（无法解析为 CommonError 形态）时返回。
pub const WechatErrorDecodeError = WechatError || error{OutOfMemory};

/// 通用处理微信等接口的返回：响应可能是 JSON 错误，也可能是普通文件/字节流。
///
/// - 响应可解析为 JSON 且 `errcode != 0`：返回 `error.ApiError`。
/// - 其他情况：返回 `response` 本身（不复制）。
///
/// 识别出 JSON 错误体时会把 `{errcode, errmsg, api_name}` 记录进本线程详情槽位
/// （见 `lastErrorDetail()`）。内部 `decodeWithCommonError` 已经记录过一次，此处的显式
/// 记录是**幂等**的（同样的值再写一遍），目的是让 `handleFileResponse` 作为独立入口时
/// 契约明确，即便将来其实现不再走 `parseCommonError`。
pub fn handleFileResponse(response: []const u8, api_name: []const u8) WechatErrorDecodeError![]const u8 {
    if (try decodeWithCommonError(std.heap.page_allocator, response, api_name)) |ce| {
        defer ce.deinit();
        recordErrorDetail(ce.errcode, ce.errmsg, api_name);
        return error.ApiError;
    }
    return response;
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

/// 测试辅助：构造 `n` 个重复字节的定长缓冲。
/// （本工具链移除了 `**` 数组重复运算符，无法写 `"e" ** 700`。）
fn repeatByte(comptime n: usize, byte: u8) [n]u8 {
    var out: [n]u8 = undefined;
    @memset(&out, byte);
    return out;
}

test "CommonError.format 输出符合上游格式" {
    const allocator = std.testing.allocator;
    const err = CommonError{
        .api_name = "Send",
        .errcode = 43101,
        .errmsg = "user refuse to accept the msg",
    };
    const msg = try err.format(allocator);
    defer allocator.free(msg);
    try std.testing.expectEqualStrings(
        "Send Error , errcode=43101 , errmsg=user refuse to accept the msg",
        msg,
    );
}

test "decodeWithCommonError 对 errcode=40013 返回错误" {
    const allocator = std.testing.allocator;
    const body =
        \\{"errcode":40013,"errmsg":"invalid appid"}
    ;
    const result = try decodeWithCommonError(allocator, body, "GetAccessToken");
    try std.testing.expect(result != null);
    var ce = result.?;
    defer ce.deinit();
    try std.testing.expectEqualStrings("GetAccessToken", ce.api_name);
    try std.testing.expectEqual(@as(i64, 40013), ce.errcode);
    try std.testing.expectEqualStrings("invalid appid", ce.errmsg);
}

test "decodeWithCommonError 对 errcode=0 返回 null" {
    const allocator = std.testing.allocator;
    const body = "{\"errcode\":0,\"errmsg\":\"ok\"}";
    const result = try decodeWithCommonError(allocator, body, "Send");
    try std.testing.expect(result == null);
}

test "decodeWithCommonError 对非 JSON 返回 null（不当作 DecodeError）" {
    const allocator = std.testing.allocator;
    const body = "<xml>not a json</xml>";
    const result = try decodeWithCommonError(allocator, body, "X");
    try std.testing.expect(result == null);
}

test "handleFileResponse 把 JSON 错误转换为 error.ApiError" {
    const body = "{\"errcode\":40013,\"errmsg\":\"invalid appid\"}";
    // 期望返回 ApiError。handleFileResponse 用 page_allocator，仅用于测试不写内存，
    // 实际不会分配。
    const result = handleFileResponse(body, "X");
    try std.testing.expectError(error.ApiError, result);
}

test "handleFileResponse 对普通响应原样返回" {
    const body = "<xml>ok</xml>";
    const result = try handleFileResponse(body, "X");
    try std.testing.expectEqualSlices(u8, body, result);
}

test "isTokenInvalidErrCode 准确识别 Token 过期错误码" {
    try std.testing.expect(isTokenInvalidErrCode(40001));
    try std.testing.expect(isTokenInvalidErrCode(40014));
    try std.testing.expect(isTokenInvalidErrCode(41001));
    try std.testing.expect(isTokenInvalidErrCode(42001));
    try std.testing.expect(!isTokenInvalidErrCode(40013));
    try std.testing.expect(!isTokenInvalidErrCode(0));
}

test "decodeWithError 对 JSON 语法错误返回 DecodeError" {
    const T = struct { a: i64 = 0 };
    const parsed = decodeWithError(T, std.testing.allocator, "{bad json", "T");
    try std.testing.expectError(error.DecodeError, parsed);
}

test "decodeWithError 传播 OutOfMemory 而非吞成 DecodeError" {
    // 回归：旧实现 `catch return error.DecodeError` 会把分配失败误报为解码错误，
    // 调用方无法区分「响应 malformed」与「内存不足」。
    const FailingAlloc = struct {
        fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            return null; // 永远分配失败
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
    };
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = FailingAlloc.alloc,
        .resize = FailingAlloc.resize,
        .remap = FailingAlloc.remap,
        .free = FailingAlloc.free,
    };
    const failing: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };

    const T = struct { a: i64 = 0 };
    const parsed = decodeWithError(T, failing, "{\"a\":1}", "T");
    try std.testing.expectError(error.OutOfMemory, parsed);
}

test "lastErrorDetail 在 40001 响应后给出 errcode/errmsg/api_name" {
    const allocator = std.testing.allocator;
    clearErrorDetail();
    defer clearErrorDetail();
    try std.testing.expect(lastErrorDetail() == null);

    const body = "{\"errcode\":40001,\"errmsg\":\"invalid credential, access_token is invalid or not latest\"}";
    const result = try decodeWithCommonError(allocator, body, "GetUserInfo");
    try std.testing.expect(result != null);
    var ce = result.?;
    defer ce.deinit();
    try std.testing.expectEqual(@as(i64, 40001), ce.errcode);

    // 既有调用点即使把 ce 丢成 ApiError，也能从通道里取回 errcode。
    const d = lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 40001), d.errcode);
    try std.testing.expectEqualStrings("invalid credential, access_token is invalid or not latest", d.errmsg);
    try std.testing.expectEqualStrings("GetUserInfo", d.api_name);

    // 通道借用线程局部缓冲，切片与 ce 的堆副本互不影响。
    try std.testing.expect(d.errmsg.ptr != ce.errmsg.ptr);
    try std.testing.expect(d.api_name.ptr != ce.api_name.ptr);

    // clearErrorDetail 后回到"无记录"。
    clearErrorDetail();
    try std.testing.expect(lastErrorDetail() == null);
}

test "lastErrorDetail 成功响应不记录、也不清除上一次失败详情" {
    const allocator = std.testing.allocator;
    clearErrorDetail();
    defer clearErrorDetail();

    // 先用 45009 失败
    var fail_body = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}";
    const fail_res = try decodeWithCommonError(allocator, fail_body, "Send");
    try std.testing.expect(fail_res != null);
    var ce = fail_res.?;
    defer ce.deinit();
    try std.testing.expectEqual(@as(i64, 45009), lastErrorDetail().?.errcode);

    // 再来一次成功响应：不记录（保持 45009），不清除
    const ok = try decodeWithCommonError(allocator, "{\"errcode\":0,\"errmsg\":\"ok\"}", "Send");
    try std.testing.expect(ok == null);
    const d = lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 45009), d.errcode);
    try std.testing.expectEqualStrings("Send", d.api_name);

    // 非 JSON 响应同样不触碰通道
    const non_json = try decodeWithCommonError(allocator, "<xml>ok</xml>", "Send");
    try std.testing.expect(non_json == null);
    try std.testing.expectEqual(@as(i64, 45009), lastErrorDetail().?.errcode);

    // 显式清除
    clearErrorDetail();
    try std.testing.expect(lastErrorDetail() == null);
    _ = &fail_body;
}

test "lastErrorDetail 长 errmsg 截断到 512B 且不越界" {
    const allocator = std.testing.allocator;
    clearErrorDetail();
    defer clearErrorDetail();

    // 700B 的纯 ASCII errmsg（远超 512B 容量）
    const long_msg = repeatByte(700, 'e');
    const body = try std.fmt.allocPrint(allocator, "{{\"errcode\":45009,\"errmsg\":\"{s}\"}}", .{long_msg[0..]});
    defer allocator.free(body);

    const result = try decodeWithCommonError(allocator, body, "Send");
    try std.testing.expect(result != null);
    var ce = result.?;
    defer ce.deinit();

    // 返回的 CommonError 仍是完整的 700B（堆副本不受通道容量影响）
    try std.testing.expectEqual(@as(usize, 700), ce.errmsg.len);

    const d = lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ErrorDetailErrMsgCap, d.errmsg.len);
    try std.testing.expectEqual(@as(usize, 512), d.errmsg.len);
    for (d.errmsg) |c| try std.testing.expectEqual(@as(u8, 'e'), c);
}

test "lastErrorDetail 在 UTF-8 边界截断，不切裂多字节字符" {
    const allocator = std.testing.allocator;
    clearErrorDetail();
    defer clearErrorDetail();

    // 511 个 ASCII + 一个 3 字节汉字（"错" = E9 94 99），容量 512 会正好切在汉字中间。
    const prefix = repeatByte(511, 'a');
    const body = try std.fmt.allocPrint(allocator, "{{\"errcode\":45009,\"errmsg\":\"{s}错\"}}", .{prefix[0..]});
    defer allocator.free(body);

    const result = try decodeWithCommonError(allocator, body, "Send");
    try std.testing.expect(result != null);
    var ce = result.?;
    defer ce.deinit();

    const d = lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 511), d.errmsg.len); // 回退掉整个汉字
    try std.testing.expect(std.unicode.utf8ValidateSlice(d.errmsg));
    try std.testing.expectEqual(@as(usize, 512), ErrorDetailErrMsgCap);
}

test "lastErrorDetail 长 api_name 截断到 64B" {
    const allocator = std.testing.allocator;
    clearErrorDetail();
    defer clearErrorDetail();

    const long_api = repeatByte(100, 'A');
    const result = try decodeWithCommonError(allocator, "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}", long_api[0..]);
    try std.testing.expect(result != null);
    var ce = result.?;
    defer ce.deinit();

    // CommonError 仍借用调用方的完整 api_name
    try std.testing.expectEqual(@as(usize, 100), ce.api_name.len);

    const d = lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 40003), d.errcode);
    try std.testing.expectEqual(ErrorDetailApiNameCap, d.api_name.len);
    try std.testing.expectEqual(@as(usize, 64), d.api_name.len);
    for (d.api_name) |c| try std.testing.expectEqual(@as(u8, 'A'), c);
}

test "lastErrorDetail 线程隔离：各线程只读到自己记录的详情" {
    const allocator = std.testing.allocator;
    clearErrorDetail();
    defer clearErrorDetail();

    // 确定性交错：子线程先记录 45009 → 主线程再记录 40003 → 两边各自回读。
    // 若详情槽位是全局变量，则子线程会读到 40003、主线程会读到 45009，两个断言都会失败。
    const Ctx = struct {
        child_recorded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        main_recorded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        child_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        child_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            defer self.child_done.store(true, .release);
            const body = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}";
            const res = parseCommonError(std.heap.page_allocator, body, "ThreadQuota") catch return;
            if (res) |ce| {
                defer ce.deinit();
                self.child_recorded.store(true, .release);
                while (!self.main_recorded.load(.acquire)) std.atomic.spinLoopHint();
                if (lastErrorDetail()) |d| {
                    self.child_ok.store(
                        d.errcode == 45009 and std.mem.eql(u8, d.api_name, "ThreadQuota"),
                        .release,
                    );
                }
            }
        }
    };
    var ctx = Ctx{};

    const t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    defer t.join();

    // 等子线程完成记录（或提前退出），再让主线程写入自己的 40003
    while (!ctx.child_recorded.load(.acquire) and !ctx.child_done.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    // 无条件放行子线程：即使下面的断言失败，defer t.join() 也不会死等。
    ctx.main_recorded.store(true, .release);

    const res = try decodeWithCommonError(allocator, "{\"errcode\":40003,\"errmsg\":\"invalid openid\"}", "MainOpenid");
    try std.testing.expect(res != null);
    var ce = res.?;
    defer ce.deinit();

    // 主线程读回自己的 40003（子线程同时记录的是 45009）
    const d = lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 40003), d.errcode);
    try std.testing.expectEqualStrings("invalid openid", d.errmsg);
    try std.testing.expectEqualStrings("MainOpenid", d.api_name);

    try std.testing.expect(ctx.child_recorded.load(.acquire));
    while (!ctx.child_done.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expect(ctx.child_ok.load(.acquire));
    // 子线程结束后主线程的记录仍不受影响
    try std.testing.expectEqual(@as(i64, 40003), lastErrorDetail().?.errcode);
}

test "handleFileResponse 对 JSON 错误体记录详情" {
    clearErrorDetail();
    defer clearErrorDetail();

    const body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}";
    const result = handleFileResponse(body, "GetMedia");
    try std.testing.expectError(error.ApiError, result);

    const d = lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 40001), d.errcode);
    try std.testing.expectEqualStrings("invalid credential", d.errmsg);
    try std.testing.expectEqualStrings("GetMedia", d.api_name);

    // 普通（非 JSON 错误）响应不记录、也不清除已有详情
    const ok = try handleFileResponse("<xml>data</xml>", "GetMedia");
    try std.testing.expectEqualSlices(u8, "<xml>data</xml>", ok);
    try std.testing.expectEqual(@as(i64, 40001), lastErrorDetail().?.errcode);
}

test "lastErrorDetail 是通道内的独立副本（CommonError.deinit 后依然可读）" {
    // 通道不借用调用方的 CommonError 内存：即使调用方立刻释放 ce（含堆上的 errmsg 深拷贝），
    // 通道里的副本仍然有效，不会 UAF。
    const allocator = std.testing.allocator;
    clearErrorDetail();
    defer clearErrorDetail();

    const long_msg = repeatByte(2000, 'z');
    const body = try std.fmt.allocPrint(allocator, "{{\"errcode\":45009,\"errmsg\":\"{s}\"}}", .{long_msg[0..]});
    defer allocator.free(body);

    {
        const res = try decodeWithCommonError(allocator, body, "SendAll");
        var ce = res.?;
        defer ce.deinit(); // 释放堆上的完整 2000B errmsg
    }

    const d = lastErrorDetail() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 45009), d.errcode);
    try std.testing.expectEqualStrings("SendAll", d.api_name);
    // 截断后的副本仍全部可读且内容正确（无越界、无悬挂）
    try std.testing.expectEqual(ErrorDetailErrMsgCap, d.errmsg.len);
    for (d.errmsg) |c| try std.testing.expectEqual(@as(u8, 'z'), c);
}
