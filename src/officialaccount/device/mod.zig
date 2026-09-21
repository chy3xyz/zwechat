// SPDX-License-Identifier: Apache-2.0
//! officialaccount/device — 智能设备

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_json = @import("../../util/json.zig");

pub const Device = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    /// 可选的可注入 transport（测试用，注入 capture/MockTransport 拦截 HTTP）。
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

    /// 主动发送设备消息（transmsg 转发）。
    pub fn transMsg(self: *Self, device_type: []const u8, device_id: []const u8, content: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/device/transmsg?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        // device_type / device_id / content 都可能来自调用方或设备上报，
        // 必须走 JSON 转义（原先 allocPrint 裸插值，含 `"`/控制字符即产出非法 JSON）。
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        try jw.beginObject();
        try jw.objectField("device_type");
        try jw.write(device_type);
        try jw.objectField("device_id");
        try jw.write(device_id);
        try jw.objectField("content");
        try jw.write(content);
        try jw.endObject();
        const body = try out.toOwnedSlice();
        defer self.allocator.free(body);

        const resp = try self.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "TransMsg")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取设备二维码（device_id + device_type → qrcode_ticket）。
    pub fn createQRCode(self: *Self, device_ids: []const []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/device/create_qrcode?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"device_num\":");
        try buf.print(self.allocator, "{d}", .{device_ids.len});
        try buf.appendSlice(self.allocator, ",\"device_id_list\":[");
        for (device_ids, 0..) |id, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try buf.append(self.allocator, '"');
            try util_json.appendEscapedString(self.allocator, &buf, id);
            try buf.append(self.allocator, '"');
        }
        try buf.append(self.allocator, ']');
        try buf.append(self.allocator, '}');
        const body = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);

        const resp = try self.postJSON(uri, body);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "CreateQRCode")) |ce| {
            defer ce.deinit();
            self.allocator.free(resp);
            return util_error.WechatError.ApiError;
        }
        return resp;
    }
};

test "Device.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-d" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const d = Device.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-d", d.ctx.config.app_id);
}

const credential = @import("../../credential/mod.zig");

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 记录 payload 并返回固定响应的 transport。
const Capture = struct {
    payload: []u8 = &.{},
    fn dispatch(ctx: *anyopaque, a: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = uri;
        _ = method;
        _ = content_type;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.payload = try a.dupe(u8, payload);
        return a.dupe(u8, "{\"errcode\":0,\"errmsg\":\"ok\"}");
    }
};

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-d" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "createQRCode 转义 device_id 中的引号与控制字符（回归：手写 JSON 拼接）" {
    const allocator = std.testing.allocator;
    var cap = Capture{};
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx = makeCtx();
    var d = Device.init(&ctx, allocator);
    d.setTransport(Capture.dispatch, &cap);

    const ids = [_][]const u8{ "dev-1", "d\"q\x01" };
    const resp = try d.createQRCode(&ids);
    defer allocator.free(resp);

    try std.testing.expectEqualStrings(
        "{\"device_num\":2,\"device_id_list\":[\"dev-1\",\"d\\\"q\\u0001\"]}",
        cap.payload,
    );
    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, cap.payload, .{});
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("d\"q\x01", reparsed.value.object.get("device_id_list").?.array.items[1].string);
}

test "transMsg 走 std.json.Stringify 转义（回归：allocPrint 裸插值）" {
    const allocator = std.testing.allocator;
    var cap = Capture{};
    defer if (cap.payload.len > 0) allocator.free(cap.payload);

    var ctx = makeCtx();
    var d = Device.init(&ctx, allocator);
    d.setTransport(Capture.dispatch, &cap);

    try d.transMsg("gh_1", "dev\"2", "line1\nline2\x1f");

    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, cap.payload, .{});
    defer reparsed.deinit();
    const obj = reparsed.value.object;
    try std.testing.expectEqualStrings("gh_1", obj.get("device_type").?.string);
    try std.testing.expectEqualStrings("dev\"2", obj.get("device_id").?.string);
    try std.testing.expectEqualStrings("line1\nline2\x1f", obj.get("content").?.string);
}
