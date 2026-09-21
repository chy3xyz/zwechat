// SPDX-License-Identifier: Apache-2.0
//! officialaccount/customerservice — 客服管理

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

/// 客服基本信息（对齐 Go manager.go KeFuInfo）。
pub const KeFuInfo = struct {
    kf_account: []const u8 = "",
    nickname: []const u8 = "",
    password: []const u8 = "",
    headimgurl: []const u8 = "",
};

/// 客服列表响应。内嵌 errcode/errmsg 以便 SDK 自行检查失败响应。
const KfListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    kf_list: []KeFuInfo = &.{},
};

/// 客服在线信息（对照 Go `KeFuOnlineInfo`）。
pub const KeFuOnlineInfo = struct {
    kf_account: []const u8 = "",
    status: i64 = 0,
    kf_id: i64 = 0,
    accepted_case: i64 = 0,
};

/// 在线客服列表响应。内嵌 errcode/errmsg 以便 SDK 自行检查失败响应。
const KfOnlineListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    kf_online_list: []KeFuOnlineInfo = &.{},
};

pub const customerServiceOnlineListURL = "https://api.weixin.qq.com/cgi-bin/customservice/getonlinekflist";
pub const customerServiceUpdateURL = "https://api.weixin.qq.com/customservice/kfaccount/update";
pub const customerServiceDeleteURL = "https://api.weixin.qq.com/customservice/kfaccount/del";
pub const customerServiceInviteURL = "https://api.weixin.qq.com/customservice/kfaccount/inviteworker";
pub const customerServiceUploadHeadImgURL = "https://api.weixin.qq.com/customservice/kfaccount/uploadheadimg";

pub const CustomerService = struct {
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

    fn get(self: *Self, uri: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.get(uri);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.get(uri);
    }

    /// 同 `get`，但走 POST JSON（注入 transport 优先）。
    fn postJson(self: *Self, uri: []const u8, body: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, body);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body);
    }

    /// 同 `get`，但走 POST multipart（注入 transport 优先）。
    fn postMultipart(self: *Self, uri: []const u8, fields: []const util_http.MultipartField) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postMultipart(uri, fields);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postMultipart(uri, fields);
    }

    /// 添加客服账号。
    pub fn addAccount(self: *Self, account: []const u8, nickname: []const u8) !void {
        const payload = try encodeKfAccountBody(self.allocator, account, nickname, null);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "AddAccount", TokenReq{
            .cs = self,
            .url = "https://api.weixin.qq.com/customservice/kfaccount/add",
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 修改客服账号（`kfaccount/update`）。
    pub fn updateAccount(self: *Self, account: []const u8, nickname: []const u8) !void {
        const payload = try encodeKfAccountBody(self.allocator, account, nickname, null);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "UpdateAccount", TokenReq{
            .cs = self,
            .url = customerServiceUpdateURL,
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 删除客服帐号（`kfaccount/del`）。
    pub fn deleteAccount(self: *Self, account: []const u8) !void {
        const payload = try encodeKfAccountBody(self.allocator, account, "", null);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "DeleteAccount", TokenReq{
            .cs = self,
            .url = customerServiceDeleteURL,
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 邀请绑定客服帐号和微信号（`kfaccount/inviteworker`）。
    pub fn inviteBind(self: *Self, account: []const u8, invite_wx: []const u8) !void {
        const payload = try encodeKfAccountBody(self.allocator, account, "", invite_wx);
        defer self.allocator.free(payload);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "InviteBind", TokenReq{
            .cs = self,
            .url = customerServiceInviteURL,
            .payload = payload,
        });
        defer self.allocator.free(resp);
    }

    /// 获取在线客服列表（`getonlinekflist`）。
    ///
    /// 返回的 `std.json.Parsed(KfOnlineListResponse)` 由调用方持有并负责 `deinit`，
    /// 在线客服列表在 `.value.kf_online_list`。响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn onlineList(self: *Self) !std.json.Parsed(KfOnlineListResponse) {
        const body = try util_retry.callApi(self.ctx, self.allocator, "OnlineList", TokenReq{
            .cs = self,
            .url = customerServiceOnlineListURL,
        });
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(KfOnlineListResponse, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return parsed;
    }

    /// 上传客服头像（`kfaccount/uploadheadimg`，multipart 单文件字段 `media`）。
    ///
    /// `file_path` 末段作为文件名；文件内容由 HTTP 层读取。
    pub fn uploadHeadImg(self: *Self, account: []const u8, file_path: []const u8) !void {
        const fields = [_]util_http.MultipartField{
            .{
                .is_file = true,
                .field_name = "media",
                .filename = std.fs.path.basename(file_path),
                .value = "",
                .file_path = file_path,
            },
        };
        const query_suffix = try std.fmt.allocPrint(self.allocator, "&kf_account={s}", .{account});
        defer self.allocator.free(query_suffix);

        const resp = try util_retry.callApi(self.ctx, self.allocator, "UploadHeadImg", TokenReq{
            .cs = self,
            .url = customerServiceUploadHeadImgURL,
            .fields = &fields,
            .query_suffix = query_suffix,
        });
        defer self.allocator.free(resp);
    }

    /// 获取所有客服账号列表。
    ///
    /// 返回的 `std.json.Parsed(KfListResponse)` 由调用方持有并负责 `deinit`，
    /// 客服列表在 `.value.kf_list`。响应 errcode 非 0 时返回 `WechatError.ApiError`。
    pub fn listAccounts(self: *Self) !std.json.Parsed(KfListResponse) {
        const body = try util_retry.callApi(self.ctx, self.allocator, "ListAccounts", TokenReq{
            .cs = self,
            .url = "https://api.weixin.qq.com/cgi-bin/customservice/getkflist",
        });
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(KfListResponse, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        // errcode 检查已由 util_retry.callApi 完成（失败即抛 ApiError），此处不再重复。
        return parsed;
    }
};

/// 单次带 token 调用的请求构造器：交给 `util/retry.callApi` 复用模块自己的
/// transport 注入逻辑。三者互斥优先级：`fields`（multipart）> `payload`（POST JSON）
/// > 都没有（GET）。`query_suffix` 用于在 `access_token` 之后追加固定查询参数。
/// `send` 必须 `pub`（跨文件调用）。
const TokenReq = struct {
    cs: *CustomerService,
    url: []const u8,
    payload: ?[]const u8 = null,
    fields: ?[]const util_http.MultipartField = null,
    query_suffix: []const u8 = "",

    pub fn send(self: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
        const uri = try std.fmt.allocPrint(allocator, "{s}?access_token={s}{s}", .{ self.url, token, self.query_suffix });
        defer allocator.free(uri);
        if (self.fields) |f| return self.cs.postMultipart(uri, f);
        if (self.payload) |p| return self.cs.postJson(uri, p);
        return self.cs.get(uri);
    }
};

/// 组装客服账号管理请求体：`{"kf_account":"...","nickname":"...","invite_wx":"..."}`。
/// `nickname` 非空才输出，`invite_wx` 非 null 才输出；统一走 `std.json.Stringify` 转义。
fn encodeKfAccountBody(
    allocator: std.mem.Allocator,
    account: []const u8,
    nickname: []const u8,
    invite_wx: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("kf_account");
    try s.write(account);
    if (nickname.len > 0) {
        try s.objectField("nickname");
        try s.write(nickname);
    }
    if (invite_wx) |wx| {
        try s.objectField("invite_wx");
        try s.write(wx);
    }
    try s.endObject();
    return out.toOwnedSlice();
}

test "CustomerService.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const cs = CustomerService.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-cs", cs.ctx.config.app_id);
}

// —— mock 测试 ——

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 返回预设响应的 transport。
const StaticResp = struct {
    response: []const u8,

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = payload;
        _ = content_type;
        const self: *StaticResp = @ptrCast(@alignCast(ctx));
        return allocator.dupe(u8, self.response);
    }
};

test "listAccounts 正常响应解析 kf_list" {
    const allocator = std.testing.allocator;
    var stub = StaticResp{
        .response =
        \\{"kf_list":[{"kf_account":"kf1@test","nickname":"客服一","password":"pwd","headimgurl":"http://a/1.png"}]}
        ,
    };

    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var cs = CustomerService.init(&ctx, allocator);
    cs.setTransport(StaticResp.dispatch, &stub);

    const parsed = try cs.listAccounts();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.kf_list.len);
    const kf = parsed.value.kf_list[0];
    try std.testing.expectEqualStrings("kf1@test", kf.kf_account);
    try std.testing.expectEqualStrings("客服一", kf.nickname);
    try std.testing.expectEqualStrings("pwd", kf.password);
    try std.testing.expectEqualStrings("http://a/1.png", kf.headimgurl);
}

test "listAccounts errcode 非 0 返回 ApiError" {
    const allocator = std.testing.allocator;
    var stub = StaticResp{ .response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}" };

    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var cs = CustomerService.init(&ctx, allocator);
    cs.setTransport(StaticResp.dispatch, &stub);

    const result = cs.listAccounts();
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

/// 记录请求 uri / payload / content_type 的 transport。
const CaptureResp = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uri: []u8 = &.{},
    payload: []u8 = &.{},
    ctype: []const u8 = "",

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = method;
        const self: *CaptureResp = @ptrCast(@alignCast(ctx));
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        self.ctype = try allocator.dupe(u8, content_type orelse "");
        return allocator.dupe(u8, self.response);
    }
};

test "updateAccount 请求 kfaccount/update 且 JSON 转义" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = CaptureResp{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var cs = CustomerService.init(&ctx, alloc);
    cs.setTransport(CaptureResp.dispatch, &cap);

    try cs.updateAccount("kf1@test", "新\"昵\n称");
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/customservice/kfaccount/update?access_token=token-abc",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"kf_account\":\"kf1@test\",\"nickname\":\"新\\\"昵\\n称\"}",
        cap.payload,
    );
}

test "deleteAccount 请求 kfaccount/del 仅含 kf_account" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = CaptureResp{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var cs = CustomerService.init(&ctx, alloc);
    cs.setTransport(CaptureResp.dispatch, &cap);

    try cs.deleteAccount("kf1@test");
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/customservice/kfaccount/del?access_token=token-abc",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"kf_account\":\"kf1@test\"}", cap.payload);

    cap.response = "{\"errcode\":65400,\"errmsg\":\"please delete the kf account\"}";
    try std.testing.expectError(util_error.WechatError.ApiError, cs.deleteAccount("kf1@test"));
}

test "inviteBind 请求 kfaccount/inviteworker 含 invite_wx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = CaptureResp{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var cs = CustomerService.init(&ctx, alloc);
    cs.setTransport(CaptureResp.dispatch, &cap);

    try cs.inviteBind("kf1@test", "oWx_widget");
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/customservice/kfaccount/inviteworker?access_token=token-abc",
        cap.uri,
    );
    try std.testing.expectEqualStrings(
        "{\"kf_account\":\"kf1@test\",\"invite_wx\":\"oWx_widget\"}",
        cap.payload,
    );

    cap.response = "{\"errcode\":65413,\"errmsg\":\"invitee is binded by other kf\"}";
    try std.testing.expectError(util_error.WechatError.ApiError, cs.inviteBind("kf1@test", "wx2"));
}

test "onlineList 解析 kf_online_list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = CaptureResp{
        .allocator = alloc,
        .response = "{\"kf_online_list\":[{\"kf_account\":\"kf1@test\",\"status\":1,\"kf_id\":100,\"accepted_case\":5}]}",
    };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var cs = CustomerService.init(&ctx, alloc);
    cs.setTransport(CaptureResp.dispatch, &cap);

    const parsed = try cs.onlineList();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.kf_online_list.len);
    const kf = parsed.value.kf_online_list[0];
    try std.testing.expectEqualStrings("kf1@test", kf.kf_account);
    try std.testing.expectEqual(@as(i64, 1), kf.status);
    try std.testing.expectEqual(@as(i64, 100), kf.kf_id);
    try std.testing.expectEqual(@as(i64, 5), kf.accepted_case);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/customservice/getonlinekflist?access_token=token-abc",
        cap.uri,
    );

    cap.response = "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}";
    try std.testing.expectError(util_error.WechatError.ApiError, cs.onlineList());
}

test "uploadHeadImg multipart 上传头像文件" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp_path = "zwechat_oa_cs_headimg_test.png";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    }
    try file.writePositionalAll(io, "fake-headimg-bytes", 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = CaptureResp{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    var ctx: Context = .{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var cs = CustomerService.init(&ctx, alloc);
    cs.setTransport(CaptureResp.dispatch, &cap);

    try cs.uploadHeadImg("kf1@test", tmp_path);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/customservice/kfaccount/uploadheadimg?access_token=token-abc&kf_account=kf1@test",
        cap.uri,
    );
    try std.testing.expect(std.mem.startsWith(u8, cap.ctype, "multipart/form-data; boundary="));
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "name=\"media\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "filename=\"zwechat_oa_cs_headimg_test.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "fake-headimg-bytes") != null);

    cap.response = "{\"errcode\":40005,\"errmsg\":\"invalid file type\"}";
    try std.testing.expectError(util_error.WechatError.ApiError, cs.uploadHeadImg("kf1@test", tmp_path));
}

test "encodeKfAccountBody 字段省略与转义" {
    const allocator = std.testing.allocator;
    const body = try encodeKfAccountBody(allocator, "kf\"1", "", null);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"kf_account\":\"kf\\\"1\"}", body);
}

// —— token 失效自愈 / 非 token 错误不重试 ——

/// 可作废的假凭据：作废前发 `token-abc`，作废后发 `token-new`（模拟微信换发新 token）。
const HealToken = struct {
    cached: []const u8 = "token-abc",
    invalidates: usize = 0,

    fn getToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.cached);
    }

    fn invalidate(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *HealToken = @ptrCast(@alignCast(ptr));
        self.invalidates += 1;
        self.cached = "token-new";
    }

    const vtable = credential.AccessTokenHandle.VTable{
        .getAccessToken = getToken,
        .invalidate = invalidate,
    };
};

/// 按调用次序返回响应、并记录每次请求 URI 的 transport。
const SeqResp = struct {
    responses: []const []const u8,
    calls: usize = 0,
    uris: [4][160]u8 = @splat(@splat(0)),
    uri_lens: [4]usize = @splat(0),

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = method;
        _ = payload;
        _ = content_type;
        const self: *SeqResp = @ptrCast(@alignCast(ctx));
        if (self.calls < self.uris.len and uri.len <= self.uris[0].len) {
            @memcpy(self.uris[self.calls][0..uri.len], uri);
            self.uri_lens[self.calls] = uri.len;
        }
        const idx = @min(self.calls, self.responses.len - 1);
        self.calls += 1;
        return allocator.dupe(u8, self.responses[idx]);
    }

    fn uriAt(self: *const SeqResp, idx: usize) []const u8 {
        return self.uris[idx][0..self.uri_lens[idx]];
    }
};

fn newHealCs(ctx: *Context, alloc: std.mem.Allocator, stub: *SeqResp) CustomerService {
    var cs = CustomerService.init(ctx, alloc);
    cs.setTransport(SeqResp.dispatch, stub);
    return cs;
}

test "listAccounts 40001 自愈：作废缓存 → 换新 token 重试一次并成功" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"kf_list\":[{\"kf_account\":\"kf1@test\",\"nickname\":\"客服一\"}]}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var cs = newHealCs(&ctx, allocator, &stub);

    const parsed = try cs.listAccounts();
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.kf_list.len);
    try std.testing.expectEqualStrings("kf1@test", parsed.value.kf_list[0].kf_account);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/customservice/getkflist?access_token=token-abc",
        stub.uriAt(0),
    );
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/customservice/getkflist?access_token=token-new",
        stub.uriAt(1),
    );
}

test "uploadHeadImg 40001 自愈：重试后成功且第二次请求带新 token" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp_path = "zwechat_oa_cs_heal_headimg_test.png";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    }
    try file.writePositionalAll(io, "fake-headimg-bytes", 0);

    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"errcode\":0,\"errmsg\":\"ok\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var cs = newHealCs(&ctx, allocator, &stub);

    try cs.uploadHeadImg("kf1@test", tmp_path);

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/customservice/kfaccount/uploadheadimg?access_token=token-new&kf_account=kf1@test",
        stub.uriAt(1),
    );
}

test "updateAccount 40001 自愈：重试后成功且第二次请求带新 token" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"errcode\":0,\"errmsg\":\"ok\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var cs = newHealCs(&ctx, allocator, &stub);

    try cs.updateAccount("kf1@test", "新昵称");

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/customservice/kfaccount/update?access_token=token-new",
        stub.uriAt(1),
    );
}

test "onlineList 40001 自愈：重试后解析出新 token 请求的响应" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
        "{\"kf_online_list\":[{\"kf_account\":\"kf1@test\",\"status\":1}]}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var cs = newHealCs(&ctx, allocator, &stub);

    const parsed = try cs.onlineList();
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 2), stub.calls);
    try std.testing.expectEqualStrings("kf1@test", parsed.value.kf_online_list[0].kf_account);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/customservice/getonlinekflist?access_token=token-new",
        stub.uriAt(1),
    );
}

test "deleteAccount 非 token 错误（65400）不重试也不作废" {
    const allocator = std.testing.allocator;
    var stub = SeqResp{ .responses = &.{
        "{\"errcode\":65400,\"errmsg\":\"please delete the kf account\"}",
    } };
    var tk = HealToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-cs" },
        .access_token_handle = .{ .ptr = @ptrCast(&tk), .vtable = &HealToken.vtable },
    };
    var cs = newHealCs(&ctx, allocator, &stub);

    try std.testing.expectError(util_error.WechatError.ApiError, cs.deleteAccount("kf1@test"));

    try std.testing.expectEqual(@as(usize, 0), tk.invalidates);
    try std.testing.expectEqual(@as(usize, 1), stub.calls);
}
