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

const std = @import("std");
const json = std.json;

/// 顶层微信错误集合。所有上层 API 失败时都应回落到该集合的某个变体。
pub const WechatError = error{
    /// 微信接口返回 errcode != 0。
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

/// 将一段微信接口的 JSON 响应按 `CommonError` 解析。
///
/// - 当响应可解析为 JSON 且 `errcode != 0` 时，返回 `WechatError.ApiError` 并把详情放在
///   `error.value` 中（通过 `error.Unexpected` 携带是不现实的，因此改用 `error.ApiError`，
///   调用方拿到 `err` 后用 `decodeWithCommonError` 再次解析来获取细节）。
/// - 当响应可解析为 JSON 且 `errcode == 0` 时，返回 `null`。
/// - 当响应无法解析为 JSON 时，返回 `WechatError.DecodeError`。
///
/// 调用方拿到 `null` 即代表成功；若希望直接拿到错误结构，可使用 `parseCommonError`。
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
pub fn handleFileResponse(response: []const u8, api_name: []const u8) WechatErrorDecodeError![]const u8 {
    if (try decodeWithCommonError(std.heap.page_allocator, response, api_name)) |ce| {
        defer ce.deinit();
        return error.ApiError;
    }
    return response;
}

// -----------------------------------------------------------------------------
// tests
// -----------------------------------------------------------------------------

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
