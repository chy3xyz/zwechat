// SPDX-License-Identifier: Apache-2.0
//! openplatform/miniprogram/basic — 代小程序基础信息设置
//!
//! 对应 `_ref/wechat/openplatform/miniprogram/basic/basic.go`：
//! 第三方平台代小程序管理帐号基础信息——查询基础信息、检测/设置名称
//! （昵称）、修改功能介绍（签名）、修改头像、查询/修改"是否可被搜索"。
//!
//! 所有接口按 Go 参考走 `authorizer_access_token`（被代运营小程序的 token，
//! 缓存 key `authorizer_access_token_{appid}`），URL query 参数名为
//! `access_token`，与 Go 端 `fmt.Sprintf("%s?access_token=%s", ...)` 逐字一致。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const access_token = @import("../context/access_token.zig");

pub const Error = access_token.Error || error{WriteFailed};

/// 获取小程序基础信息 URL（`{s}` 为 authorizer_access_token）。
const getAccountBasicInfoURL = "https://api.weixin.qq.com/cgi-bin/account/getaccountbasicinfo?access_token={s}";
/// 检测名称是否符合规则 URL。
const checkNickNameURL = "https://api.weixin.qq.com/cgi-bin/wxverify/checkwxverifynickname?access_token={s}";
/// 设置小程序名称 URL。
const setNickNameURL = "https://api.weixin.qq.com/wxa/setnickname?access_token={s}";
/// 修改功能介绍 URL。
const setSignatureURL = "https://api.weixin.qq.com/cgi-bin/account/modifysignature?access_token={s}";
/// 修改头像 URL。
const setHeadImageURL = "https://api.weixin.qq.com/cgi-bin/account/modifyheadimage?access_token={s}";
/// 查询小程序是否可被搜索 URL。
const getSearchStatusURL = "https://api.weixin.qq.com/wxa/getwxasearchstatus?access_token={s}";
/// 修改小程序是否可被搜索 URL。
const setSearchStatusURL = "https://api.weixin.qq.com/wxa/changewxasearchstatus?access_token={s}";

/// 基础信息（Go `AccountBasicInfo`，当前仅承载 errcode/errmsg）。
pub const AccountBasicInfo = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

/// 名称检测结果（Go `CheckNickNameResp`）。
pub const CheckNickNameResp = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 是否命中关键字策略。若命中，可以选填关键字材料。
    hit_condition: bool = false,
    /// 命中关键字的说明描述。
    wording: []const u8 = "",
};

/// 设置名称结果（Go `SetNickNameResp`）。
pub const SetNickNameResp = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 审核单 ID，可用于查询改名审核状态。
    audit_id: i64 = 0,
    /// 材料说明。
    wording: []const u8 = "",
};

/// 设置名称参数（Go `SetNickNameParam`，`omitempty` 字段传 null 即省略）。
pub const SetNickNameParam = struct {
    /// 昵称，不支持包含"小程序"关键字的昵称。
    nick_name: []const u8,
    /// 身份证照片 mediaid（个人号必填）。
    id_card: ?[]const u8 = null,
    /// 组织机构代码证或营业执照 mediaid（组织号必填）。
    license: ?[]const u8 = null,
    /// 其他证明材料 mediaid（选填）。
    naming_other_stuff_1: ?[]const u8 = null,
    /// 其他证明材料 mediaid（选填）。
    naming_other_stuff_2: ?[]const u8 = null,
    /// 其他证明材料 mediaid（选填）。
    naming_other_stuff_3: ?[]const u8 = null,
    /// 其他证明材料 mediaid（选填）。
    naming_other_stuff_4: ?[]const u8 = null,
    /// 其他证明材料 mediaid（选填）。
    naming_other_stuff_5: ?[]const u8 = null,
};

/// 查询小程序是否可被搜索结果（Go `GetSearchStatusResp`）。
///
/// `status`：1 表示不可搜索，0 表示可搜索。
pub const GetSearchStatusResp = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    status: i64 = 0,
};

/// 修改头像参数（Go `SetHeadImageParam`，坐标为 [0,1] 区间字符串）。
pub const SetHeadImageParam = struct {
    /// 头像素材 media_id。
    head_img_media_id: []const u8,
    /// 裁剪框左上角 x 坐标（取值范围：[0, 1]）。
    x1: []const u8,
    /// 裁剪框左上角 y 坐标（取值范围：[0, 1]）。
    y1: []const u8,
    /// 裁剪框右下角 x 坐标（取值范围：[0, 1]）。
    x2: []const u8,
    /// 裁剪框右下角 y 坐标（取值范围：[0, 1]）。
    y2: []const u8,
};

/// 基础信息设置业务入口（Go `basic.Basic`）。
pub const Basic = struct {
    ctx: *Context,
    /// 被代运营的小程序 AppID（取 authorizer_access_token 用）。
    app_id: []const u8,

    const Self = @This();

    /// 构造入口（与 Go 端 `basic.NewBasic(opContext, appID)` 对齐）。
    pub fn init(ctx: *Context, app_id: []const u8) Self {
        return .{ .ctx = ctx, .app_id = app_id };
    }

    /// GET 出口（与 openplatform/context 惯例一致：注入 transport 时走临时 client）。
    fn get(
        self: *Self,
        allocator: std.mem.Allocator,
        uri: []const u8,
    ) Error![]u8 {
        const ctx = self.ctx;
        if (ctx.transport) |t| {
            const tctx = ctx.transport_ctx orelse
                @panic("Context.transport 已设置但 transport_ctx 为空：请同时传入两者");
            var client = util_http.HttpClient.init(allocator);
            defer client.deinit();
            client.setTransport(t, tctx);
            return client.get(uri) catch return util_error.WechatError.NetworkError;
        }
        const client = util_http.getDefaultClient(allocator);
        return client.get(uri) catch return util_error.WechatError.NetworkError;
    }

    /// 统一的 POST JSON 出口。
    fn postJSON(
        self: *Self,
        allocator: std.mem.Allocator,
        uri: []const u8,
        payload: []const u8,
    ) Error![]u8 {
        const ctx = self.ctx;
        if (ctx.transport) |t| {
            const tctx = ctx.transport_ctx orelse
                @panic("Context.transport 已设置但 transport_ctx 为空：请同时传入两者");
            var client = util_http.HttpClient.init(allocator);
            defer client.deinit();
            client.setTransport(t, tctx);
            return client.postJSON(uri, payload) catch return util_error.WechatError.NetworkError;
        }
        const client = util_http.getDefaultClient(allocator);
        return client.postJSON(uri, payload) catch return util_error.WechatError.NetworkError;
    }

    /// 取 authorizer_access_token（被代运营小程序的 token，对照 Go `GetAuthrAccessToken`）。
    ///
    /// 返回的 token 由调用方负责 `allocator.free`。
    fn requireAuthrToken(self: *Self, allocator: std.mem.Allocator) Error![]u8 {
        return access_token.getAuthrAccessToken(self.ctx, allocator, self.app_id);
    }

    /// 解析 JSON 响应：`.allocate = .alloc_always`（Parsed 自持有，body 可立即释放），
    /// errcode 非 0 抛 `WechatError.ApiError`。
    fn parseChecked(
        allocator: std.mem.Allocator,
        comptime T: type,
        resp: []const u8,
    ) Error!std.json.Parsed(T) {
        var parsed = std.json.parseFromSlice(T, allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 仅校验 errcode 的 POST 出口（Go 端返回 CommonError-only 响应体的方法共用）。
    fn postCheckedVoid(
        self: *Self,
        allocator: std.mem.Allocator,
        uri: []const u8,
        payload: []const u8,
    ) Error!void {
        const resp = try self.postJSON(allocator, uri, payload);
        defer allocator.free(resp);
        var parsed = try parseChecked(allocator, CommonResponse, resp);
        defer parsed.deinit();
    }

    /// 获取小程序基础信息（Go `GetAccountBasicInfo`）。
    ///
    /// URL：`GET /cgi-bin/account/getaccountbasicinfo?access_token={s}`。
    /// 返回 `std.json.Parsed(AccountBasicInfo)`，调用方读完 `deinit`。
    pub fn getAccountBasicInfo(
        self: *Self,
        allocator: std.mem.Allocator,
    ) Error!std.json.Parsed(AccountBasicInfo) {
        const authr_token = try self.requireAuthrToken(allocator);
        defer allocator.free(authr_token);

        const uri = try std.fmt.allocPrint(allocator, getAccountBasicInfoURL, .{authr_token});
        defer allocator.free(uri);

        const resp = try self.get(allocator, uri);
        defer allocator.free(resp);

        return parseChecked(allocator, AccountBasicInfo, resp);
    }

    /// 检测微信认证的名称是否符合规则（Go `CheckNickName`）。
    ///
    /// URL：`POST /cgi-bin/wxverify/checkwxverifynickname?access_token={s}`，
    /// body `{"nick_name":"..."}`。
    pub fn checkNickName(
        self: *Self,
        allocator: std.mem.Allocator,
        nickname: []const u8,
    ) Error!std.json.Parsed(CheckNickNameResp) {
        const authr_token = try self.requireAuthrToken(allocator);
        defer allocator.free(authr_token);

        const uri = try std.fmt.allocPrint(allocator, checkNickNameURL, .{authr_token});
        defer allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("nick_name");
        try s.write(nickname);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer allocator.free(body);

        const resp = try self.postJSON(allocator, uri, body);
        defer allocator.free(resp);

        return parseChecked(allocator, CheckNickNameResp, resp);
    }

    /// 设置小程序名称（Go `SetNickName`，仅昵称的便捷封装）。
    pub fn setNickName(
        self: *Self,
        allocator: std.mem.Allocator,
        nickname: []const u8,
    ) Error!std.json.Parsed(SetNickNameResp) {
        return self.setNickNameFull(allocator, .{ .nick_name = nickname });
    }

    /// 设置小程序名称（Go `SetNickNameFull`，可附证明材料）。
    ///
    /// URL：`POST /wxa/setnickname?access_token={s}`；`param` 中 null 的
    /// 可选材料字段按 Go `omitempty` 语义省略。
    pub fn setNickNameFull(
        self: *Self,
        allocator: std.mem.Allocator,
        param: SetNickNameParam,
    ) Error!std.json.Parsed(SetNickNameResp) {
        const authr_token = try self.requireAuthrToken(allocator);
        defer allocator.free(authr_token);

        const uri = try std.fmt.allocPrint(allocator, setNickNameURL, .{authr_token});
        defer allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("nick_name");
        try s.write(param.nick_name);
        try writeOptionalField(&s, "id_card", param.id_card);
        try writeOptionalField(&s, "license", param.license);
        try writeOptionalField(&s, "naming_other_stuff_1", param.naming_other_stuff_1);
        try writeOptionalField(&s, "naming_other_stuff_2", param.naming_other_stuff_2);
        try writeOptionalField(&s, "naming_other_stuff_3", param.naming_other_stuff_3);
        try writeOptionalField(&s, "naming_other_stuff_4", param.naming_other_stuff_4);
        try writeOptionalField(&s, "naming_other_stuff_5", param.naming_other_stuff_5);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer allocator.free(body);

        const resp = try self.postJSON(allocator, uri, body);
        defer allocator.free(resp);

        return parseChecked(allocator, SetNickNameResp, resp);
    }

    /// 修改功能介绍（Go `SetSignature`）。
    ///
    /// URL：`POST /cgi-bin/account/modifysignature?access_token={s}`，
    /// body `{"signature":"..."}`。
    pub fn setSignature(
        self: *Self,
        allocator: std.mem.Allocator,
        signature: []const u8,
    ) Error!void {
        const authr_token = try self.requireAuthrToken(allocator);
        defer allocator.free(authr_token);

        const uri = try std.fmt.allocPrint(allocator, setSignatureURL, .{authr_token});
        defer allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("signature");
        try s.write(signature);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer allocator.free(body);

        try self.postCheckedVoid(allocator, uri, body);
    }

    /// 查询小程序当前是否可被搜索（Go `GetSearchStatus`）。
    ///
    /// URL：`GET /wxa/getwxasearchstatus?access_token={s}`。
    /// `status`：1 表示不可搜索，0 表示可搜索。
    ///
    /// 注：Go 参考的 `GetSearchStatus(signature string)` 形参在函数体内未被
    /// 使用（疑似从 SetSignature 复制残留），Zig 版按真实语义省略。
    pub fn getSearchStatus(
        self: *Self,
        allocator: std.mem.Allocator,
    ) Error!std.json.Parsed(GetSearchStatusResp) {
        const authr_token = try self.requireAuthrToken(allocator);
        defer allocator.free(authr_token);

        const uri = try std.fmt.allocPrint(allocator, getSearchStatusURL, .{authr_token});
        defer allocator.free(uri);

        const resp = try self.get(allocator, uri);
        defer allocator.free(resp);

        return parseChecked(allocator, GetSearchStatusResp, resp);
    }

    /// 修改小程序是否可被搜索（Go `SetSearchStatus`）。
    ///
    /// URL：`POST /wxa/changewxasearchstatus?access_token={s}`，
    /// body `{"status":...}`（1 不可搜索，0 可搜索）。
    pub fn setSearchStatus(
        self: *Self,
        allocator: std.mem.Allocator,
        status: i64,
    ) Error!void {
        const authr_token = try self.requireAuthrToken(allocator);
        defer allocator.free(authr_token);

        const uri = try std.fmt.allocPrint(allocator, setSearchStatusURL, .{authr_token});
        defer allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("status");
        try s.write(status);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer allocator.free(body);

        try self.postCheckedVoid(allocator, uri, body);
    }

    /// 修改小程序头像（Go `SetHeadImage`，默认全图 0,0,1,1 的便捷封装）。
    pub fn setHeadImage(
        self: *Self,
        allocator: std.mem.Allocator,
        img_media_id: []const u8,
    ) Error!void {
        return self.setHeadImageFull(allocator, .{
            .head_img_media_id = img_media_id,
            .x1 = "0",
            .y1 = "0",
            .x2 = "1",
            .y2 = "1",
        });
    }

    /// 修改小程序头像（Go `SetHeadImageFull`，支持裁剪坐标）。
    ///
    /// URL：`POST /cgi-bin/account/modifyheadimage?access_token={s}`。
    pub fn setHeadImageFull(
        self: *Self,
        allocator: std.mem.Allocator,
        param: SetHeadImageParam,
    ) Error!void {
        const authr_token = try self.requireAuthrToken(allocator);
        defer allocator.free(authr_token);

        const uri = try std.fmt.allocPrint(allocator, setHeadImageURL, .{authr_token});
        defer allocator.free(uri);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("head_img_media_id");
        try s.write(param.head_img_media_id);
        try s.objectField("x1");
        try s.write(param.x1);
        try s.objectField("y1");
        try s.write(param.y1);
        try s.objectField("x2");
        try s.write(param.x2);
        try s.objectField("y2");
        try s.write(param.y2);
        try s.endObject();
        const body = try out.toOwnedSlice();
        defer allocator.free(body);

        try self.postCheckedVoid(allocator, uri, body);
    }
};

/// 仅有 errcode/errmsg 的响应体（Go 端 `SetSignatureResp` / `SetSearchStatusResp` /
/// `SetHeadImageResp` 均只嵌入 `util.CommonError`）。
const CommonResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

/// 写可选字段：值为 null 或空串时按 Go `omitempty` 语义跳过。
fn writeOptionalField(s: *std.json.Stringify, name: []const u8, value: ?[]const u8) !void {
    const v = value orelse return;
    if (v.len == 0) return;
    try s.objectField(name);
    try s.write(v);
}

// ──────────────────────────────────────────────────────────────────────────────
// 测试
// ──────────────────────────────────────────────────────────────────────────────

/// 记录 method / uri / payload 的测试 transport（对照 component.zig 惯例）。
const RecordingTransport = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uris: std.ArrayList([]u8) = .empty,
    payloads: std.ArrayList([]u8) = .empty,
    methods: std.ArrayList(std.http.Method) = .empty,

    fn init(allocator: std.mem.Allocator, response: []const u8) RecordingTransport {
        return .{ .allocator = allocator, .response = response };
    }

    fn deinit(self: *RecordingTransport) void {
        for (self.uris.items) |u| self.allocator.free(u);
        for (self.payloads.items) |p| self.allocator.free(p);
        self.uris.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        self.methods.deinit(self.allocator);
    }

    fn dispatch(
        ctx_ptr: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = content_type;
        const self: *RecordingTransport = @ptrCast(@alignCast(ctx_ptr));
        try self.uris.append(self.allocator, try self.allocator.dupe(u8, uri));
        try self.payloads.append(self.allocator, try self.allocator.dupe(u8, payload));
        try self.methods.append(self.allocator, method);
        return allocator.dupe(u8, self.response);
    }
};

/// 构造带内存 cache + 预置 authorizer token 的测试 Context。
fn testCtx(allocator: std.mem.Allocator, memory: *@import("../../cache/memory.zig").Memory) !Context {
    const akey = try std.fmt.allocPrint(allocator, "authorizer_access_token_{s}", .{"wx-mp-1"});
    defer allocator.free(akey);
    try memory.asCache().set(akey, "authr-tok", 7000);
    return .{ .config = .{ .app_id = "wx-op", .app_secret = "sec", .cache = memory.asCache() } };
}

fn createMemory(allocator: std.mem.Allocator) !*@import("../../cache/memory.zig").Memory {
    return @import("../../cache/memory.zig").Memory.create(allocator);
}

test "getAccountBasicInfo mock：GET 正确 URL 并解析响应" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    var info = try basic.getAccountBasicInfo(allocator);
    defer info.deinit();

    try std.testing.expectEqual(@as(i64, 0), info.value.errcode);
    try std.testing.expectEqual(@as(usize, 1), rec.uris.items.len);
    try std.testing.expectEqual(std.http.Method.GET, rec.methods.items[0]);
    try std.testing.expectEqualStrings("", rec.payloads.items[0]);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/account/getaccountbasicinfo?access_token=authr-tok",
        rec.uris.items[0],
    );
}

test "getAccountBasicInfo errcode 非 0 抛 ApiError" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    const result = basic.getAccountBasicInfo(allocator);
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "checkNickName mock：POST 正确 URL/body 并解析命中结果" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\",\"hit_condition\":true,\"wording\":\"命中关键字\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    var resp = try basic.checkNickName(allocator, "我的\"小店\"");
    defer resp.deinit();

    try std.testing.expectEqual(std.http.Method.POST, rec.methods.items[0]);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/wxverify/checkwxverifynickname?access_token=authr-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqualStrings("{\"nick_name\":\"我的\\\"小店\\\"\"}", rec.payloads.items[0]);
    try std.testing.expectEqual(true, resp.value.hit_condition);
    try std.testing.expectEqualStrings("命中关键字", resp.value.wording);
}

test "setNickName 便捷方法 mock：仅提交 nick_name" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\",\"audit_id\":123456,\"wording\":\"材料说明\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    var resp = try basic.setNickName(allocator, "新昵称");
    defer resp.deinit();

    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/wxa/setnickname?access_token=authr-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqualStrings("{\"nick_name\":\"新昵称\"}", rec.payloads.items[0]);
    try std.testing.expectEqual(@as(i64, 123456), resp.value.audit_id);
    try std.testing.expectEqualStrings("材料说明", resp.value.wording);
}

test "setNickNameFull mock：可选材料字段按 omitempty 省略" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\",\"audit_id\":7}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    var resp = try basic.setNickNameFull(allocator, .{
        .nick_name = "组织号昵称",
        .license = "license_media_id",
        .naming_other_stuff_2 = "stuff2",
        .naming_other_stuff_5 = "stuff5",
    });
    defer resp.deinit();

    try std.testing.expectEqualStrings(
        "{\"nick_name\":\"组织号昵称\",\"license\":\"license_media_id\",\"naming_other_stuff_2\":\"stuff2\",\"naming_other_stuff_5\":\"stuff5\"}",
        rec.payloads.items[0],
    );
    try std.testing.expectEqual(@as(i64, 7), resp.value.audit_id);
}

test "setSignature mock：POST 正确 URL/body" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    try basic.setSignature(allocator, "这是一个\"功能介绍\"");

    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/account/modifysignature?access_token=authr-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqualStrings("{\"signature\":\"这是一个\\\"功能介绍\\\"\"}", rec.payloads.items[0]);
}

test "getSearchStatus mock：GET 正确 URL 并解析 status" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\",\"status\":1}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    var resp = try basic.getSearchStatus(allocator);
    defer resp.deinit();

    try std.testing.expectEqual(std.http.Method.GET, rec.methods.items[0]);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/wxa/getwxasearchstatus?access_token=authr-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqual(@as(i64, 1), resp.value.status);
}

test "setSearchStatus mock：POST 正确 URL/body" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    try basic.setSearchStatus(allocator, 1);

    try std.testing.expectEqual(std.http.Method.POST, rec.methods.items[0]);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/wxa/changewxasearchstatus?access_token=authr-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqualStrings("{\"status\":1}", rec.payloads.items[0]);
}

test "setSearchStatus errcode 非 0 抛 ApiError" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":48001,\"errmsg\":\"api unauthorized\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    const result = basic.setSearchStatus(allocator, 0);
    try std.testing.expectError(util_error.WechatError.ApiError, result);
}

test "setHeadImage 便捷方法 mock：默认全图坐标 0,0,1,1" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    try basic.setHeadImage(allocator, "head_media_id");

    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/account/modifyheadimage?access_token=authr-tok",
        rec.uris.items[0],
    );
    try std.testing.expectEqualStrings(
        "{\"head_img_media_id\":\"head_media_id\",\"x1\":\"0\",\"y1\":\"0\",\"x2\":\"1\",\"y2\":\"1\"}",
        rec.payloads.items[0],
    );
}

test "setHeadImageFull mock：自定义裁剪坐标" {
    const allocator = std.testing.allocator;

    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }

    var rec = RecordingTransport.init(allocator, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    defer rec.deinit();
    var ctx = try testCtx(allocator, memory);
    ctx.transport = RecordingTransport.dispatch;
    ctx.transport_ctx = @ptrCast(&rec);

    var basic = Basic.init(&ctx, "wx-mp-1");
    try basic.setHeadImageFull(allocator, .{
        .head_img_media_id = "head_media_id",
        .x1 = "0.1",
        .y1 = "0.2",
        .x2 = "0.9",
        .y2 = "0.8",
    });

    try std.testing.expectEqualStrings(
        "{\"head_img_media_id\":\"head_media_id\",\"x1\":\"0.1\",\"y1\":\"0.2\",\"x2\":\"0.9\",\"y2\":\"0.8\"}",
        rec.payloads.items[0],
    );
}

test "basic 方法 authorizer token 缓存未命中返回 RefreshTokenRequired" {
    const allocator = std.testing.allocator;
    const memory = try createMemory(allocator);
    defer {
        memory.deinit();
        allocator.destroy(memory);
    }
    var ctx: Context = .{ .config = .{ .app_id = "wx-op", .cache = memory.asCache() } };
    var basic = Basic.init(&ctx, "wx-mp-1");
    const result = basic.getSearchStatus(allocator);
    try std.testing.expectError(error.RefreshTokenRequired, result);
}
