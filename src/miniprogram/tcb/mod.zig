// SPDX-License-Identifier: Apache-2.0
//! miniprogram/tcb — 云开发（Tencent Cloud Base）
//!
//! 对应 `_ref/wechat/miniprogram/tcb/`：云函数调用、文件上传/下载/删除、数据库导入/
//! 导出/迁移状态/索引/集合/增删改查/统计。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

pub const ConflictMode = enum(i64) {
    insert = 1,
    upsert = 2,
};

pub const FileType = enum(i64) {
    json = 1,
    csv = 2,
};

pub const InvokeCloudFunctionRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    resp_data: []const u8 = "",
};

pub const UploadFileReq = struct {
    env: []const u8 = "",
    path: []const u8 = "",
};

pub const UploadFileRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    url: []const u8 = "",
    token: []const u8 = "",
    authorization: []const u8 = "",
    file_id: []const u8 = "",
    cos_file_id: []const u8 = "",
};

pub const DownloadFile = struct {
    fileid: []const u8 = "",
    max_age: i64 = 0,
};

pub const BatchDownloadFileRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    file_list: []const DownloadedFile = &.{},
};

pub const DownloadedFile = struct {
    file_id: []const u8 = "",
    download_url: []const u8 = "",
    status: i64 = 0,
    errmsg: []const u8 = "",
};

pub const BatchDeleteFileRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    delete_list: []const DeletedFile = &.{},
};

pub const DeletedFile = struct {
    fileid: []const u8 = "",
    status: i64 = 0,
    errmsg: []const u8 = "",
};

pub const DatabaseMigrateExportReq = struct {
    env: []const u8 = "",
    file_path: []const u8 = "",
    file_type: FileType = .json,
    query: []const u8 = "",
};

pub const DatabaseMigrateExportRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    job_id: i64 = 0,
};

pub const DatabaseMigrateImportReq = struct {
    env: []const u8 = "",
    collection_name: []const u8 = "",
    file_path: []const u8 = "",
    file_type: FileType = .json,
    stop_on_error: bool = false,
    conflict_mode: ConflictMode = .insert,
};

pub const DatabaseMigrateImportRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    job_id: i64 = 0,
};

pub const DatabaseMigrateQueryInfoRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    status: []const u8 = "",
    record_success: i64 = 0,
    record_fail: i64 = 0,
    err_msg: []const u8 = "",
    file_url: []const u8 = "",
};

pub const UpdateIndexReq = struct {
    env: []const u8 = "",
    collection_name: []const u8 = "",
    create_indexes: []const CreateIndex = &.{},
    drop_indexes: []const DropIndex = &.{},
};

pub const CreateIndex = struct {
    name: []const u8 = "",
    unique: bool = false,
    keys: []const CreateIndexKey = &.{},
};

pub const CreateIndexKey = struct {
    name: []const u8 = "",
    direction: []const u8 = "",
};

pub const DropIndex = struct {
    name: []const u8 = "",
};

pub const DatabaseCollectionGetRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    pager: Pager = .{},
    collections: []const CollectionInfo = &.{},
};

pub const Pager = struct {
    limit: i64 = 0,
    offset: i64 = 0,
    total: i64 = 0,
};

pub const CollectionInfo = struct {
    name: []const u8 = "",
    count: i64 = 0,
    size: i64 = 0,
    index_count: i64 = 0,
    index_size: i64 = 0,
};

pub const DatabaseAddRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    id_list: []const []const u8 = &.{},
};

pub const DatabaseDeleteRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    deleted: i64 = 0,
};

pub const DatabaseUpdateRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    matched: i64 = 0,
    modified: i64 = 0,
    id: []const u8 = "",
};

pub const DatabaseQueryRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    pager: Pager = .{},
    data: []const []const u8 = &.{},
};

pub const DatabaseCountRes = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    count: i64 = 0,
};

/// 云开发模块。
pub const Tcb = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 云函数调用。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次。
    pub fn invokeCloudFunction(self: *Self, env: []const u8, name: []const u8, args: []const u8) !std.json.Parsed(InvokeCloudFunctionRes) {
        const Sender = struct {
            allocator: std.mem.Allocator,
            env: []const u8,
            name: []const u8,
            args: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/tcb/invokecloudfunction?access_token={s}&env={s}&name={s}",
                    .{ token, c.env, c.name },
                );
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.allocator);
                return client.post(uri, c.args, null);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "InvokeCloudFunction", Sender{
            .allocator = self.allocator,
            .env = env,
            .name = name,
            .args = args,
        });
        defer self.allocator.free(resp);
        return parseParsed(InvokeCloudFunctionRes, self.allocator, resp);
    }

    /// 上传文件。
    pub fn uploadFile(self: *Self, env: []const u8, path: []const u8) !std.json.Parsed(UploadFileRes) {
        const body = try jsonStringifyEnvPath(self.allocator, env, path);
        defer self.allocator.free(body);
        return self.postParsed("tcb/uploadfile", body, UploadFileRes);
    }

    /// 获取文件下载链接。
    pub fn batchDownloadFile(self: *Self, env: []const u8, file_list: []const DownloadFile) !std.json.Parsed(BatchDownloadFileRes) {
        const body = try jsonStringifyDownload(self.allocator, env, file_list);
        defer self.allocator.free(body);
        return self.postParsed("tcb/batchdownloadfile", body, BatchDownloadFileRes);
    }

    /// 批量删除文件。
    pub fn batchDeleteFile(self: *Self, env: []const u8, file_id_list: []const []const u8) !std.json.Parsed(BatchDeleteFileRes) {
        const body = try jsonStringifyDelete(self.allocator, env, file_id_list);
        defer self.allocator.free(body);
        return self.postParsed("tcb/batchdeletefile", body, BatchDeleteFileRes);
    }

    /// 数据库导入。
    pub fn databaseMigrateImport(self: *Self, req: DatabaseMigrateImportReq) !std.json.Parsed(DatabaseMigrateImportRes) {
        const body = try jsonStringifyMigrateImport(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("tcb/databasemigrateimport", body, DatabaseMigrateImportRes);
    }

    /// 数据库导出。
    pub fn databaseMigrateExport(self: *Self, req: DatabaseMigrateExportReq) !std.json.Parsed(DatabaseMigrateExportRes) {
        const body = try jsonStringifyMigrateExport(self.allocator, req);
        defer self.allocator.free(body);
        return self.postParsed("tcb/databasemigrateexport", body, DatabaseMigrateExportRes);
    }

    /// 数据库迁移状态查询。
    pub fn databaseMigrateQueryInfo(self: *Self, env: []const u8, job_id: i64) !std.json.Parsed(DatabaseMigrateQueryInfoRes) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"env\":\"{s}\",\"job_id\":{d}}}", .{ env, job_id });
        defer self.allocator.free(body);
        return self.postParsed("tcb/databasemigratequeryinfo", body, DatabaseMigrateQueryInfoRes);
    }

    /// 变更数据库索引。
    pub fn updateIndex(self: *Self, req: UpdateIndexReq) !void {
        const body = try jsonStringifyUpdateIndex(self.allocator, req);
        defer self.allocator.free(body);
        try self.postCommon("tcb/updateindex", body, "UpdateIndex");
    }

    /// 新增集合。
    pub fn databaseCollectionAdd(self: *Self, env: []const u8, collection_name: []const u8) !void {
        const body = try jsonStringifyEnvCollection(self.allocator, env, collection_name);
        defer self.allocator.free(body);
        try self.postCommon("tcb/databasecollectionadd", body, "DatabaseCollectionAdd");
    }

    /// 删除集合。
    pub fn databaseCollectionDelete(self: *Self, env: []const u8, collection_name: []const u8) !void {
        const body = try jsonStringifyEnvCollection(self.allocator, env, collection_name);
        defer self.allocator.free(body);
        try self.postCommon("tcb/databasecollectiondelete", body, "DatabaseCollectionDelete");
    }

    /// 获取特定云环境下集合信息。
    pub fn databaseCollectionGet(self: *Self, env: []const u8, limit: i64, offset: i64) !std.json.Parsed(DatabaseCollectionGetRes) {
        const body = try jsonStringifyEnvLimitOffset(self.allocator, env, limit, offset);
        defer self.allocator.free(body);
        return self.postParsed("tcb/databasecollectionget", body, DatabaseCollectionGetRes);
    }

    /// 数据库插入记录。
    pub fn databaseAdd(self: *Self, env: []const u8, query: []const u8) !std.json.Parsed(DatabaseAddRes) {
        return self.databaseReq("tcb/databaseadd", env, query, DatabaseAddRes);
    }

    /// 数据库删除记录。
    pub fn databaseDelete(self: *Self, env: []const u8, query: []const u8) !std.json.Parsed(DatabaseDeleteRes) {
        return self.databaseReq("tcb/databasedelete", env, query, DatabaseDeleteRes);
    }

    /// 数据库更新记录。
    pub fn databaseUpdate(self: *Self, env: []const u8, query: []const u8) !std.json.Parsed(DatabaseUpdateRes) {
        return self.databaseReq("tcb/databaseupdate", env, query, DatabaseUpdateRes);
    }

    /// 数据库查询记录。
    pub fn databaseQuery(self: *Self, env: []const u8, query: []const u8) !std.json.Parsed(DatabaseQueryRes) {
        return self.databaseReq("tcb/databasequery", env, query, DatabaseQueryRes);
    }

    /// 统计集合记录数。
    pub fn databaseCount(self: *Self, env: []const u8, query: []const u8) !std.json.Parsed(DatabaseCountRes) {
        return self.databaseReq("tcb/databasecount", env, query, DatabaseCountRes);
    }

    fn databaseReq(self: *Self, endpoint: []const u8, env: []const u8, query: []const u8, comptime T: type) !std.json.Parsed(T) {
        const body = try jsonStringifyEnvQuery(self.allocator, env, query);
        defer self.allocator.free(body);
        return self.postParsed(endpoint, body, T);
    }

    fn postParsed(self: *Self, endpoint: []const u8, body: []const u8, comptime T: type) !std.json.Parsed(T) {
        const Sender = struct {
            allocator: std.mem.Allocator,
            endpoint: []const u8,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(allocator, "https://api.weixin.qq.com/{s}?access_token={s}", .{ c.endpoint, token });
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, endpoint, Sender{
            .allocator = self.allocator,
            .endpoint = endpoint,
            .body = body,
        });
        defer self.allocator.free(resp);
        return parseParsed(T, self.allocator, resp);
    }

    fn postCommon(self: *Self, endpoint: []const u8, body: []const u8, api_name: []const u8) !void {
        const Sender = struct {
            allocator: std.mem.Allocator,
            endpoint: []const u8,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(allocator, "https://api.weixin.qq.com/{s}?access_token={s}", .{ c.endpoint, token });
                defer allocator.free(uri);
                const client = util_http.getDefaultClient(c.allocator);
                return client.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, api_name, Sender{
            .allocator = self.allocator,
            .endpoint = endpoint,
            .body = body,
        });
        self.allocator.free(resp);
    }
};

fn parseParsed(comptime T: type, allocator: std.mem.Allocator, resp: []const u8) !std.json.Parsed(T) {
    var parsed = std.json.parseFromSlice(T, allocator, resp, .{ .allocate = .alloc_always }) catch {
        return util_error.WechatError.DecodeError;
    };
    errdefer parsed.deinit();
    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    return parsed;
}

fn jsonStringifyDownload(allocator: std.mem.Allocator, env: []const u8, file_list: []const DownloadFile) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(env);
    try s.objectField("file_list");
    try s.beginArray();
    for (file_list) |f| {
        try s.beginObject();
        try s.objectField("fileid");
        try s.write(f.fileid);
        try s.objectField("max_age");
        try s.write(f.max_age);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyDelete(allocator: std.mem.Allocator, env: []const u8, file_id_list: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(env);
    try s.objectField("fileid_list");
    try s.beginArray();
    for (file_id_list) |id| try s.write(id);
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyMigrateImport(allocator: std.mem.Allocator, req: DatabaseMigrateImportReq) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(req.env);
    try s.objectField("collection_name");
    try s.write(req.collection_name);
    try s.objectField("file_path");
    try s.write(req.file_path);
    try s.objectField("file_type");
    try s.write(@backingInt(req.file_type));
    try s.objectField("stop_on_error");
    try s.write(req.stop_on_error);
    try s.objectField("conflict_mode");
    try s.write(@backingInt(req.conflict_mode));
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyMigrateExport(allocator: std.mem.Allocator, req: DatabaseMigrateExportReq) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(req.env);
    try s.objectField("file_path");
    try s.write(req.file_path);
    try s.objectField("file_type");
    try s.write(@backingInt(req.file_type));
    try s.objectField("query");
    try s.write(req.query);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyUpdateIndex(allocator: std.mem.Allocator, req: UpdateIndexReq) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(req.env);
    try s.objectField("collection_name");
    try s.write(req.collection_name);
    try s.objectField("create_indexes");
    try s.beginArray();
    for (req.create_indexes) |ci| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(ci.name);
        try s.objectField("unique");
        try s.write(ci.unique);
        try s.objectField("keys");
        try s.beginArray();
        for (ci.keys) |k| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(k.name);
            try s.objectField("direction");
            try s.write(k.direction);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("drop_indexes");
    try s.beginArray();
    for (req.drop_indexes) |di| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(di.name);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

/// database* 系列接口的请求体：`env` 与 `query`（query 本身是一段 JSON 文本，
/// 必须作为字符串字段整体转义，不能直接插值进 JSON 字符串）。
fn jsonStringifyEnvQuery(allocator: std.mem.Allocator, env: []const u8, query: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(env);
    try s.objectField("query");
    try s.write(query);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyEnvPath(allocator: std.mem.Allocator, env: []const u8, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(env);
    try s.objectField("path");
    try s.write(path);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyEnvCollection(allocator: std.mem.Allocator, env: []const u8, collection_name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(env);
    try s.objectField("collection_name");
    try s.write(collection_name);
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonStringifyEnvLimitOffset(allocator: std.mem.Allocator, env: []const u8, limit: i64, offset: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("env");
    try s.write(env);
    try s.objectField("limit");
    try s.write(limit);
    try s.objectField("offset");
    try s.write(offset);
    try s.endObject();
    return out.toOwnedSlice();
}

test "Tcb.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-tcb" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const t = Tcb.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-tcb", t.ctx.config.app_id);
}

test "UploadFileRes 默认值" {
    const r = UploadFileRes{};
    try std.testing.expectEqualStrings("", r.url);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：假 AccessTokenHandle + capture transport。
// ─────────────────────────────────────────────────────────────────────────────

const credential = @import("../../credential/mod.zig");

fn testGetAccessToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    _ = ctx;
    return allocator.dupe(u8, "stub-ak");
}

const test_token_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = testGetAccessToken,
};

const TestCapture = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    uri: []u8 = &.{},
    payload: []u8 = &.{},

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = method;
        _ = content_type;
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }
};

fn setupTestClient(alloc: std.mem.Allocator, cap: *TestCapture) void {
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(TestCapture.dispatch, @ptrCast(cap));
}

fn releaseTestClient() void {
    // 不依赖「用别的 allocator 再取一次指针」的宽容语义：直接销毁线程局部实例，
    // 注入的 transport 随实例一起消失（下次 getDefaultClient 会重新初始化）。
    util_http.deinitDefaultClient();
}

test "databaseQuery 请求体为合法 JSON 且 query 含双引号可完整还原" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"pager\":{\"limit\":10,\"offset\":0,\"total\":1},\"data\":[\"{}\"]}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var ctx: Context = .{
        .config = .{ .app_id = "wx-tcb" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &test_token_vtable },
    };
    var t = Tcb.init(&ctx, alloc);
    // query 本身是一段 JSON 文本，含双引号；旧实现直接插值会产生非法 JSON。
    const query = "db.collection(\"test\").where({\"age\":18})";
    var parsed = try t.databaseQuery("env-1", query);
    defer parsed.deinit();

    const body = try std.json.parseFromSlice(struct {
        env: []const u8,
        query: []const u8,
    }, alloc, cap.payload, .{});
    defer body.deinit();
    try std.testing.expectEqualStrings("env-1", body.value.env);
    try std.testing.expectEqualStrings(query, body.value.query);
}

test "uploadFile 与 databaseCollectionAdd 字符串字段经 JSON 转义" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\"}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var ctx: Context = .{
        .config = .{ .app_id = "wx-tcb" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &test_token_vtable },
    };
    var t = Tcb.init(&ctx, alloc);

    var up = try t.uploadFile("env\"x", "p\"ath");
    defer up.deinit();
    const body1 = try std.json.parseFromSlice(struct {
        env: []const u8,
        path: []const u8,
    }, alloc, cap.payload, .{});
    defer body1.deinit();
    try std.testing.expectEqualStrings("env\"x", body1.value.env);
    try std.testing.expectEqualStrings("p\"ath", body1.value.path);

    try t.databaseCollectionAdd("env-1", "col\"1");
    const body2 = try std.json.parseFromSlice(struct {
        env: []const u8,
        collection_name: []const u8,
    }, alloc, cap.payload, .{});
    defer body2.deinit();
    try std.testing.expectEqualStrings("env-1", body2.value.env);
    try std.testing.expectEqualStrings("col\"1", body2.value.collection_name);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "databaseQuery token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/tcb/databasequery?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"pager\":{\"limit\":10,\"offset\":0,\"total\":1},\"data\":[\"{}\"]}",
    });

    // MockTransport 直接挂在默认 client 上（token 变化反映在 URI 上，需按 URI 路由）。
    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var stub = retry_testing.RotatingToken{};
    var ctx: Context = .{
        .config = .{ .app_id = "wx-tcb" },
        .access_token_handle = stub.asHandle(),
    };
    var t = Tcb.init(&ctx, allocator);

    var parsed = try t.databaseQuery("env-1", "{}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.pager.total);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
