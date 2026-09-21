// SPDX-License-Identifier: Apache-2.0
//! miniprogram/auth — 小程序登录 / 用户信息
//!
//! 对应 `_ref/wechat/miniprogram/auth/auth.go`：jscode2session / getPhoneNumber / checkSession 等。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// `jscode2session` 返回。
pub const ResCode2Session = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    openid: []const u8 = "",
    session_key: []const u8 = "",
    unionid: []const u8 = "",
};

/// 支付后获取 UnionID 请求（对照 Go `GetPaidUnionIDRequest`）。
///
/// `transaction_id` 与 (`mch_id` + `out_trade_no`) 二选一必填：
/// 传了 `transaction_id` 走微信单号查询，否则走商户单号查询。
pub const GetPaidUnionIDRequest = struct {
    openid: []const u8,
    transaction_id: []const u8 = "",
    mch_id: []const u8 = "",
    out_trade_no: []const u8 = "",
};

/// 支付后获取 UnionID 返回。
pub const GetPaidUnionIDResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    unionid: []const u8 = "",
};

/// 加密数据校验返回。
pub const RspCheckEncryptedData = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 注意：微信官方返回的 key 为 `vaild`（官方笔误，Go 参考
    /// `_ref/wechat/miniprogram/auth/auth.go` 同样按 `vaild` 解析），
    /// 字段名必须与线上响应保持一致。
    vaild: bool = false,
    create_time: i64 = 0,
};

/// 手机号数据水印。
pub const Watermark = struct {
    timestamp: i64 = 0,
    appid: []const u8 = "",
};

/// 手机号信息（字段名与微信返回的 camelCase JSON 一致）。
pub const PhoneInfo = struct {
    phoneNumber: []const u8 = "",
    purePhoneNumber: []const u8 = "",
    countryCode: []const u8 = "",
    watermark: Watermark = .{},
};

/// `getuserphonenumber` 返回。
pub const GetPhoneNumberResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    phone_info: PhoneInfo = .{},
};

pub const Auth = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 MockTransport 拦截 HTTP）。
    transport: ?util_http.HttpClient.Transport = null,
    transport_ctx: ?*anyopaque = null,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 注入自定义 transport（`null` 恢复真实 HTTP）。
    pub fn setTransport(self: *Self, t: ?util_http.HttpClient.Transport, ctx: ?*anyopaque) void {
        self.transport = t;
        self.transport_ctx = ctx;
    }

    /// `jscode2session` — 小程序登录凭证校验。
    /// 返回的 `std.json.Parsed(ResCode2Session)` 由调用方持有并负责 `deinit`。
    pub fn code2Session(self: *Self, js_code: []const u8) !std.json.Parsed(ResCode2Session) {
        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/sns/jscode2session?appid={s}&secret={s}&js_code={s}&grant_type=authorization_code",
            .{ self.ctx.config.app_id, self.ctx.config.app_secret, js_code },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResCode2Session, self.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// `getuserphonenumber` — 通过 code 获取用户手机号。
    /// 返回的 `std.json.Parsed(GetPhoneNumberResponse)` 由调用方持有并负责 `deinit`。
    ///
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次。
    pub fn getPhoneNumber(self: *Self, code: []const u8) !std.json.Parsed(GetPhoneNumberResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"code\":\"{s}\"}}", .{code});
        defer self.allocator.free(body);

        const Sender = struct {
            auth: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                return c.auth.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "GetPhoneNumber", Sender{
            .auth = self,
            .body = body,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetPhoneNumberResponse, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// `checkencryptedmsg` — 检查加密信息是否由微信生成。
    /// 返回的 `std.json.Parsed(RspCheckEncryptedData)` 由调用方持有并负责 `deinit`。
    ///
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次。
    pub fn checkEncryptedData(self: *Self, encrypted_msg_hash: []const u8) !std.json.Parsed(RspCheckEncryptedData) {
        const body = try encodeCheckEncryptedDataBody(self.allocator, encrypted_msg_hash);
        defer self.allocator.free(body);

        const Sender = struct {
            auth: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/business/checkencryptedmsg?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);
                return c.auth.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "CheckEncryptedData", Sender{
            .auth = self,
            .body = body,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(RspCheckEncryptedData, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// `checksession` — 检验登录态。
    ///
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次。
    pub fn checkSession(self: *Self, signature: []const u8, open_id: []const u8) !void {
        const Sender = struct {
            auth: *Self,
            signature: []const u8,
            open_id: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/checksession?access_token={s}&signature={s}&openid={s}&sig_method=hmac_sha256",
                    .{ token, c.signature, c.open_id },
                );
                defer allocator.free(uri);
                return c.auth.httpGet(uri);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "CheckSession", Sender{
            .auth = self,
            .signature = signature,
            .open_id = open_id,
        });
        self.allocator.free(resp);
    }

    /// `getpaidunionid` — 用户支付完成后获取该用户的 UnionID，无需用户授权
    /// （对照 Go `GetPaidUnionID`；注意微信参数名为 `openid`）。
    ///
    /// 返回的 unionid 字符串由本结构体的 allocator 分配，调用方负责 `free`；
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次。
    pub fn getPaidUnionID(self: *Self, req: GetPaidUnionIDRequest) ![]u8 {
        const Sender = struct {
            auth: *Self,
            req: GetPaidUnionIDRequest,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = if (c.req.transaction_id.len > 0)
                    try std.fmt.allocPrint(
                        allocator,
                        "https://api.weixin.qq.com/wxa/getpaidunionid?access_token={s}&openid={s}&transaction_id={s}",
                        .{ token, c.req.openid, c.req.transaction_id },
                    )
                else
                    try std.fmt.allocPrint(
                        allocator,
                        "https://api.weixin.qq.com/wxa/getpaidunionid?access_token={s}&openid={s}&mch_id={s}&out_trade_no={s}",
                        .{ token, c.req.openid, c.req.mch_id, c.req.out_trade_no },
                    );
                defer allocator.free(uri);
                return c.auth.httpGet(uri);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "GetPaidUnionID", Sender{
            .auth = self,
            .req = req,
        });
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetPaidUnionIDResponse, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.unionid);
    }

    fn httpGet(self: *Self, uri: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.get(uri);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.get(uri);
    }

    fn postJSON(self: *Self, uri: []const u8, payload: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, payload);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, payload);
    }
};

/// 构造 `checkencryptedmsg` 的 JSON 请求体 `{"encrypted_msg_hash":"..."}`。
fn encodeCheckEncryptedDataBody(allocator: std.mem.Allocator, encrypted_msg_hash: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("encrypted_msg_hash");
    try s.write(encrypted_msg_hash);
    try s.endObject();
    return out.toOwnedSlice();
}

test "Auth.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-mp", .app_secret = "sec" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const a = Auth.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-mp", a.ctx.config.app_id);
}

test "ResCode2Session 默认值" {
    const r = ResCode2Session{};
    try std.testing.expectEqualStrings("", r.openid);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}

test "PhoneInfo 默认值" {
    const p = PhoneInfo{};
    try std.testing.expectEqualStrings("", p.phoneNumber);
    try std.testing.expectEqual(@as(i64, 0), p.watermark.timestamp);
}

// —— mock 测试 ——

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-mp", .app_secret = "sec" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

/// 捕获请求 payload 并返回预设响应的 transport，用于请求体断言。
const Capture = struct {
    response: []const u8,
    payload: []u8 = &.{},

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = content_type;
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (self.payload.len > 0) allocator.free(self.payload);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }
};

test "checkEncryptedData 解析微信 vaild 笔误字段" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/business/checkencryptedmsg?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"vaild\":true,\"create_time\":1629121902}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try a.checkEncryptedData("abc123");
    defer parsed.deinit();
    try std.testing.expect(parsed.value.vaild);
    try std.testing.expectEqual(@as(i64, 1629121902), parsed.value.create_time);
}

test "checkEncryptedData errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/business/checkencryptedmsg?access_token=token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    try std.testing.expectError(util_error.WechatError.ApiError, a.checkEncryptedData("abc123"));
}

test "checkEncryptedData 请求体为 JSON 且字段转义" {
    const allocator = std.testing.allocator;
    var cap = Capture{ .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"vaild\":true}" };
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(Capture.dispatch, &cap);

    var parsed = try a.checkEncryptedData("hash\"with\\quote");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("{\"encrypted_msg_hash\":\"hash\\\"with\\\\quote\"}", cap.payload);
}

test "getPhoneNumber 解析 camelCase 字段与 watermark" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token=token-abc", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"phone_info\":{\"phoneNumber\":\"13800001111\",\"purePhoneNumber\":\"13800001111\",\"countryCode\":\"86\",\"watermark\":{\"timestamp\":1629121902,\"appid\":\"wx-mp\"}}}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try a.getPhoneNumber("code-xyz");
    defer parsed.deinit();
    const info = parsed.value.phone_info;
    try std.testing.expectEqualStrings("13800001111", info.phoneNumber);
    try std.testing.expectEqualStrings("13800001111", info.purePhoneNumber);
    try std.testing.expectEqualStrings("86", info.countryCode);
    try std.testing.expectEqualStrings("wx-mp", info.watermark.appid);
    try std.testing.expectEqual(@as(i64, 1629121902), info.watermark.timestamp);
}

test "getPaidUnionID transaction_id 分支解析 unionid" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/getpaidunionid?access_token=token-abc&openid=oABC&transaction_id=TX_998", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"unionid\":\"UNION_123\"}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    const unionid = try a.getPaidUnionID(.{
        .openid = "oABC",
        .transaction_id = "TX_998",
    });
    defer allocator.free(unionid);
    try std.testing.expectEqualStrings("UNION_123", unionid);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}

test "getPaidUnionID mch_id 分支 URL 拼装正确" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/getpaidunionid?access_token=token-abc&openid=oABC&mch_id=MCH_1&out_trade_no=NO_2", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"unionid\":\"UNION_456\"}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    const unionid = try a.getPaidUnionID(.{
        .openid = "oABC",
        .mch_id = "MCH_1",
        .out_trade_no = "NO_2",
    });
    defer allocator.free(unionid);
    try std.testing.expectEqualStrings("UNION_456", unionid);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/wxa/getpaidunionid?access_token=token-abc&openid=oABC&mch_id=MCH_1&out_trade_no=NO_2",
        mt.history.items[0],
    );
}

test "getPaidUnionID errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/getpaidunionid?access_token=token-abc&openid=oABC&transaction_id=TX_BAD", .{
        .body = "{\"errcode\":40099,\"errmsg\":\"invalid transaction id\"}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    const result = a.getPaidUnionID(.{ .openid = "oABC", .transaction_id = "TX_BAD" });
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "getPhoneNumber token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token=token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential, access_token is invalid or not latest\"}",
    });
    try mt.addRoute("https://api.weixin.qq.com/wxa/business/getuserphonenumber?access_token=token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"phone_info\":{\"phoneNumber\":\"13800001111\"}}",
    });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-mp", .app_secret = "sec" },
        .access_token_handle = stub.asHandle(),
    };
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try a.getPhoneNumber("code-xyz");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("13800001111", parsed.value.phone_info.phoneNumber);

    // 作废恰好一次，且第二次请求确实带了换发后的新 token。
    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}

test "checkSession 非 token 类 errcode 不重试也不作废" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/wxa/checksession?access_token=token-abc&signature=sig&openid=oABC&sig_method=hmac_sha256", .{
        .body = "{\"errcode\":45009,\"errmsg\":\"reach max api daily quota limit\"}",
    });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-mp", .app_secret = "sec" },
        .access_token_handle = stub.asHandle(),
    };
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    try std.testing.expectError(util_error.WechatError.ApiError, a.checkSession("sig", "oABC"));
    try std.testing.expectEqual(@as(usize, 0), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}
