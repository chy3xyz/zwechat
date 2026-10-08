// SPDX-License-Identifier: Apache-2.0
//! miniprogram/auth — 小程序登录 / 用户信息
//!
//! 对应 `_ref/wechat/miniprogram/auth/auth.go`：jscode2session / getPhoneNumber / checkSession 等。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");
const util_json = @import("../../util/json.zig");
const util_uri = @import("../../util/uri.zig");

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
    ///
    /// 本接口用 `appid` + `secret` 换 `openid` / `session_key`，**不需要 access_token**，
    /// 因此不走 `util_retry.callApi`（那条链路服务的是需要 token 的接口）。
    /// `app_secret` 只出现在请求 URL 里，绝不进入错误值 / 错误详情 / 日志——
    /// 失败一律返回无载荷的 `WechatError.ApiError`，具体 errcode 见
    /// `util_error.lastErrorDetail()`。
    pub fn code2Session(self: *Self, js_code: []const u8) !std.json.Parsed(ResCode2Session) {
        // `js_code` 来自客户端 `wx.login`，属外部输入：进 query 前必须按 Go
        // `url.QueryEscape` 语义转义，否则其中的 `&` / `=` / `#` 会把 query 截断
        // 甚至凭空注入参数（`js_code=a&appid=别的app`）。
        const encoded_code = try util_uri.queryEscape(self.allocator, js_code);
        defer self.allocator.free(encoded_code);

        const uri = try self.allocator.print(
            "https://api.weixin.qq.com/sns/jscode2session?appid={s}&secret={s}&js_code={s}&grant_type=authorization_code",
            .{ self.ctx.config.app_id, self.ctx.config.app_secret, encoded_code },
        );
        defer self.allocator.free(uri);

        // 走 `httpGet` 而非直接取默认客户端：前者在注入了 transport 时使用注入实现，
        // 否则回落默认客户端——生产和测试都只有这一条路径。
        const body = try self.httpGet(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResCode2Session, self.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) {
            // 40029 invalid code / 40125 invalid appsecret / 45011 频率限制 这些码只有
            // 线程局部详情通道里才看得到；错误集保持粗粒度不变（调用方读
            // `lastErrorDetail()`）。`errmsg` 是微信原文，不含我们传入的 secret。
            if (try util_error.parseCommonError(self.allocator, body, "Code2Session")) |ce| ce.deinit();
            return util_error.WechatError.ApiError;
        }
        return parsed;
    }

    /// `getuserphonenumber` — 通过 code 获取用户手机号。
    /// 返回的 `std.json.Parsed(GetPhoneNumberResponse)` 由调用方持有并负责 `deinit`。
    ///
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次。
    pub fn getPhoneNumber(self: *Self, code: []const u8) !std.json.Parsed(GetPhoneNumberResponse) {
        const body = try util_json.stringFieldObject(self.allocator, "code", code);
        defer self.allocator.free(body);

        const Sender = struct {
            auth: *Self,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try allocator.print(
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
                const uri = try allocator.print(
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
        // `signature`（客户端 `wx.checkSession` 算出的 hmac）与 `open_id` 都来自客户端，
        // 属外部输入 → 进 query 前按 Go `url.QueryEscape` 语义转义。
        const encoded_signature = try util_uri.queryEscape(self.allocator, signature);
        defer self.allocator.free(encoded_signature);
        const encoded_open_id = try util_uri.queryEscape(self.allocator, open_id);
        defer self.allocator.free(encoded_open_id);

        const Sender = struct {
            auth: *Self,
            signature: []const u8,
            open_id: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try allocator.print(
                    "https://api.weixin.qq.com/wxa/checksession?access_token={s}&signature={s}&openid={s}&sig_method=hmac_sha256",
                    .{ token, c.signature, c.open_id },
                );
                defer allocator.free(uri);
                return c.auth.httpGet(uri);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "CheckSession", Sender{
            .auth = self,
            .signature = encoded_signature,
            .open_id = encoded_open_id,
        });
        self.allocator.free(resp);
    }

    /// `getpaidunionid` — 用户支付完成后获取该用户的 UnionID，无需用户授权
    /// （对照 Go `GetPaidUnionID`；注意微信参数名为 `openid`）。
    ///
    /// 返回的 unionid 字符串由本结构体的 allocator 分配，调用方负责 `free`；
    /// 请求走 `util_retry.callApi`：errcode 为 token 失效码时作废缓存并重试一次。
    pub fn getPaidUnionID(self: *Self, req: GetPaidUnionIDRequest) ![]u8 {
        // `openid` 来自客户端/落库数据，`transaction_id` / `out_trade_no` 来自支付侧，
        // 都属业务数据 → 进 query 前按 Go `url.QueryEscape` 语义转义（`mch_id` 是配置，
        // 但同批处理，多一次恒等转义换统一规则）。
        const encoded_openid = try util_uri.queryEscape(self.allocator, req.openid);
        defer self.allocator.free(encoded_openid);
        const encoded_transaction_id = try util_uri.queryEscape(self.allocator, req.transaction_id);
        defer self.allocator.free(encoded_transaction_id);
        const encoded_mch_id = try util_uri.queryEscape(self.allocator, req.mch_id);
        defer self.allocator.free(encoded_mch_id);
        const encoded_out_trade_no = try util_uri.queryEscape(self.allocator, req.out_trade_no);
        defer self.allocator.free(encoded_out_trade_no);

        const Sender = struct {
            auth: *Self,
            req: GetPaidUnionIDRequest,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = if (c.req.transaction_id.len > 0)
                    try allocator.print(
                        "https://api.weixin.qq.com/wxa/getpaidunionid?access_token={s}&openid={s}&transaction_id={s}",
                        .{ token, c.req.openid, c.req.transaction_id },
                    )
                else
                    try allocator.print(
                        "https://api.weixin.qq.com/wxa/getpaidunionid?access_token={s}&openid={s}&mch_id={s}&out_trade_no={s}",
                        .{ token, c.req.openid, c.req.mch_id, c.req.out_trade_no },
                    );
                defer allocator.free(uri);
                return c.auth.httpGet(uri);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "GetPaidUnionID", Sender{
            .auth = self,
            .req = .{
                .openid = encoded_openid,
                .transaction_id = encoded_transaction_id,
                .mch_id = encoded_mch_id,
                .out_trade_no = encoded_out_trade_no,
            },
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

// ── code2Session（C 端登录最关键路径，不走 access_token）────────────────────
//
// 本接口**不需要 access_token**，用 `appid` + `secret` 直接换 `openid` /
// `session_key`，所以既不走 `util_retry.callApi`、也不会触发 token 自愈；
// 它唯一的外部输入是客户端 `wx.login` 拿到的 `js_code`。

const code2session_ok_uri =
    "https://api.weixin.qq.com/sns/jscode2session?appid=wx-mp&secret=sec&js_code=CODE-1&grant_type=authorization_code";

test "code2Session 正常响应解析 openid/session_key/unionid" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute(code2session_ok_uri, .{
        .body = "{\"openid\":\"oOpen\",\"session_key\":\"skKey\",\"unionid\":\"uUnion\",\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);
    util_error.clearErrorDetail();

    var parsed = try a.code2Session("CODE-1");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("oOpen", parsed.value.openid);
    try std.testing.expectEqualStrings("skKey", parsed.value.session_key);
    try std.testing.expectEqualStrings("uUnion", parsed.value.unionid);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.errcode);
    try std.testing.expectEqualStrings("ok", parsed.value.errmsg);
    // 成功路径既不写详情通道，也不重试：只有一次请求。
    try std.testing.expect(util_error.lastErrorDetail() == null);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
    // appid / secret 的注入方式：出现在 query（唯一注入通道），顺序固定。
    try std.testing.expectEqualStrings(code2session_ok_uri, mt.history.items[0]);
    try std.testing.expect(std.mem.find(u8, mt.history.items[0], "secret=sec") != null);
}

test "code2Session js_code 含 & = # 空格与中文时按 Go QueryEscape 转义" {
    const allocator = std.testing.allocator;
    // 未转义的话 uri 会变成 `...&js_code=a&b=c#d e中&grant_type=...`：
    // `&` 截断 js_code 并注入新参数、`#` 之后整段被当 fragment 丢弃。
    const escaped_uri =
        "https://api.weixin.qq.com/sns/jscode2session?appid=wx-mp&secret=sec&js_code=a%26b%3Dc%23d+e%E4%B8%AD&grant_type=authorization_code";

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    // 路由按**精确 URI** 匹配：没转义就匹配不上 → error.MockNoRoute，用例失败。
    try mt.addRoute(escaped_uri, .{
        .body = "{\"openid\":\"o2\",\"session_key\":\"k2\",\"errcode\":0,\"errmsg\":\"ok\"}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try a.code2Session("a&b=c#d e中");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("o2", parsed.value.openid);
    try std.testing.expectEqualStrings(escaped_uri, mt.history.items[0]);
}

test "code2Session errcode 40029 invalid code → ApiError 且 errcode 落到详情通道" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://api.weixin.qq.com/sns/jscode2session?appid=wx-mp&secret=sec&js_code=BADCODE&grant_type=authorization_code", .{
        .body = "{\"errcode\":40029,\"errmsg\":\"invalid code\"}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);
    util_error.clearErrorDetail();

    try std.testing.expectError(util_error.WechatError.ApiError, a.code2Session("BADCODE"));

    // 错误集保持粗粒度（无载荷 `ApiError`），具体码从线程局部详情通道取。
    const detail = util_error.lastErrorDetail().?;
    try std.testing.expectEqual(@as(i64, 40029), detail.errcode);
    try std.testing.expectEqualStrings("invalid code", detail.errmsg);
    try std.testing.expectEqualStrings("Code2Session", detail.api_name);
}

test "code2Session 非 JSON 响应 → DecodeError（且不写详情通道）" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute(code2session_ok_uri, .{ .body = "<html>500</html>" });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);
    util_error.clearErrorDetail();

    try std.testing.expectError(util_error.WechatError.DecodeError, a.code2Session("CODE-1"));
    try std.testing.expect(util_error.lastErrorDetail() == null);
}

test "code2Session 错误路径不泄漏 app_secret" {
    const allocator = std.testing.allocator;
    // 用一个足够独特、绝不可能被微信 errmsg 回显的 secret。
    const secret = "SUPER-SECRET-abc123XYZ";
    const uri = "https://api.weixin.qq.com/sns/jscode2session?appid=wx-mp&secret=SUPER-SECRET-abc123XYZ&js_code=CODE-1&grant_type=authorization_code";

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute(uri, .{ .body = "{\"errcode\":40125,\"errmsg\":\"invalid appsecret\"}" });

    var ctx: Context = .{
        .config = .{ .app_id = "wx-mp", .app_secret = secret },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);
    util_error.clearErrorDetail();

    if (a.code2Session("CODE-1")) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        // 错误值是**无载荷枚举**：没有任何字段可以承载 secret，`@errorName` 也不含它。
        try std.testing.expectEqual(util_error.WechatError.ApiError, err);
        try std.testing.expect(std.mem.find(u8, @errorName(err), secret) == null);
    }

    // secret 的唯一去向是请求 URI（微信要求的 query 参数，无法避免）；错误面只多出
    // errcode / errmsg / api_name 三项，都不含 secret。
    try std.testing.expectEqualStrings(uri, mt.history.items[0]);
    const detail = util_error.lastErrorDetail().?;
    try std.testing.expect(std.mem.find(u8, detail.errmsg, secret) == null);
    try std.testing.expect(std.mem.find(u8, detail.api_name, secret) == null);
}

test "checkSession 客户端签名与 openid 进 query 前转义" {
    const allocator = std.testing.allocator;
    const escaped_uri =
        "https://api.weixin.qq.com/wxa/checksession?access_token=token-abc&signature=sig%26x%3D1&openid=o+AB&sig_method=hmac_sha256";

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute(escaped_uri, .{ .body = "{\"errcode\":0,\"errmsg\":\"ok\"}" });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    try a.checkSession("sig&x=1", "o AB");
    try std.testing.expectEqualStrings(escaped_uri, mt.history.items[0]);
}

test "getPaidUnionID 单号含 & 时转义（正常输入下 URI 与改造前逐字节一致）" {
    const allocator = std.testing.allocator;
    const escaped_uri =
        "https://api.weixin.qq.com/wxa/getpaidunionid?access_token=token-abc&openid=o%261&transaction_id=TX%3D2";

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute(escaped_uri, .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"unionid\":\"U1\"}",
    });

    var ctx = makeCtx();
    var a = Auth.init(&ctx, allocator);
    a.setTransport(util_http.MockTransport.dispatch, &mt);

    const unionid = try a.getPaidUnionID(.{ .openid = "o&1", .transaction_id = "TX=2" });
    defer allocator.free(unionid);
    try std.testing.expectEqualStrings("U1", unionid);
    try std.testing.expectEqualStrings(escaped_uri, mt.history.items[0]);
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
