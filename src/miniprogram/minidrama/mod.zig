// SPDX-License-Identifier: Apache-2.0
//! miniprogram/minidrama — 小程序微短剧媒资管理
//!
//! 对应 `_ref/wechat/miniprogram/minidrama/`：媒体上传（单文件/拉取/分片）、
//! 媒体列表/详情/播放链接/删除、剧目审核/列表/详情、CDN 用量与日志。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const credential = @import("../../credential/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_retry = @import("../../util/retry.zig");

pub const SingleFileUploadRequest = struct {
    media_name: []const u8 = "",
    media_type: []const u8 = "",
    media_data: []const u8 = "",
    cover_type: []const u8 = "",
    cover_data: []const u8 = "",
    source_context: []const u8 = "",
};

pub const SingleFileUploadResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    media_id: i64 = 0,
};

pub const PullUploadRequest = struct {
    media_name: []const u8 = "",
    media_url: []const u8 = "",
    cover_url: []const u8 = "",
    source_context: []const u8 = "",
};

pub const PullUploadResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    task_id: i64 = 0,
};

pub const GetTaskRequest = struct {
    task_id: i64 = 0,
};

pub const TaskInfo = struct {
    id: i64 = 0,
    task_type: i64 = 0,
    status: i64 = 0,
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    create_time: i64 = 0,
    finish_time: i64 = 0,
    media_id: i64 = 0,
};

pub const GetTaskResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    task_info: TaskInfo = .{},
};

pub const ApplyUploadRequest = struct {
    media_name: []const u8 = "",
    media_type: []const u8 = "",
    cover_type: []const u8 = "",
    source_context: []const u8 = "",
};

pub const ApplyUploadResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    upload_id: []const u8 = "",
};

pub const UploadPartRequest = struct {
    upload_id: []const u8 = "",
    part_number: i64 = 0,
    resource_type: i64 = 0,
    data: []const u8 = "",
};

pub const UploadPartResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    etag: []const u8 = "",
};

pub const PartInfo = struct {
    part_number: i64 = 0,
    etag: []const u8 = "",
};

pub const CommitUploadRequest = struct {
    upload_id: []const u8 = "",
    media_part_infos: []const PartInfo = &.{},
    cover_part_infos: []const PartInfo = &.{},
};

pub const CommitUploadResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    media_id: i64 = 0,
};

pub const ListMediaRequest = struct {
    drama_id: i64 = 0,
    media_name: []const u8 = "",
    start_time: i64 = 0,
    end_time: i64 = 0,
    limit: i64 = 0,
    offset: i64 = 0,
};

pub const MediaAuditDetail = struct {
    status: i64 = 0,
    create_time: i64 = 0,
    audit_time: i64 = 0,
    reason: []const u8 = "",
    evidence_material_id_list: []const []const u8 = &.{},
};

pub const MediaInfo = struct {
    media_id: i64 = 0,
    create_time: i64 = 0,
    expire_time: i64 = 0,
    drama_id: i64 = 0,
    file_size: i64 = 0,
    duration: i64 = 0,
    name: []const u8 = "",
    description: []const u8 = "",
    cover_url: []const u8 = "",
    original_url: []const u8 = "",
    mp4_url: []const u8 = "",
    hls_url: []const u8 = "",
    audit_detail: ?MediaAuditDetail = null,
};

pub const ListMediaResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    media_info_list: []const MediaInfo = &.{},
};

pub const GetMediaRequest = struct {
    media_id: i64 = 0,
};

pub const GetMediaResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    media_info: MediaInfo = .{},
};

pub const GetMediaLinkRequest = struct {
    media_id: i64 = 0,
    t: i64 = 0,
    us: []const u8 = "",
    expr: i64 = 0,
    rlimit: i64 = 0,
    whref: []const u8 = "",
    bkref: []const u8 = "",
};

pub const MediaPlaybackInfo = struct {
    media_id: i64 = 0,
    duration: i64 = 0,
    name: []const u8 = "",
    description: []const u8 = "",
    cover_url: []const u8 = "",
    mp4_url: []const u8 = "",
    hls_url: []const u8 = "",
};

pub const GetMediaLinkResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    media_info: MediaPlaybackInfo = .{},
};

pub const DeleteMediaRequest = struct {
    media_id: i64 = 0,
};

pub const DeleteMediaResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};

pub const ReplaceInfo = struct {
    old: i64 = 0,
    new: i64 = 0,
};

pub const AuditDramaRequest = struct {
    drama_id: i64 = 0,
    name: []const u8 = "",
    media_count: i64 = 0,
    media_id_list: []const i64 = &.{},
    producer: []const u8 = "",
    description: []const u8 = "",
    cover_material_id: []const u8 = "",
    registration_number: []const u8 = "",
    authorized_material_id: []const u8 = "",
    publish_license: []const u8 = "",
    publish_license_material_id: []const u8 = "",
    expedited: i64 = 0,
    replace_media_list: []const ReplaceInfo = &.{},
};

pub const AuditDramaResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    drama_id: i64 = 0,
};

pub const ListDramasRequest = struct {
    limit: i64 = 0,
    offset: i64 = 0,
};

pub const DramaMediaInfo = struct {
    media_id: i64 = 0,
};

pub const DramaAuditDetail = struct {
    status: i64 = 0,
    create_time: i64 = 0,
    audit_time: i64 = 0,
};

pub const DramaInfo = struct {
    drama_id: i64 = 0,
    create_time: i64 = 0,
    name: []const u8 = "",
    playwright: []const u8 = "",
    producer: []const u8 = "",
    production_license: []const u8 = "",
    cover_url: []const u8 = "",
    media_count: i64 = 0,
    description: []const u8 = "",
    media_list: []const DramaMediaInfo = &.{},
    audit_detail: ?DramaAuditDetail = null,
    expedited: i64 = 0,
};

pub const ListDramasResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    drama_info_list: []const DramaInfo = &.{},
};

pub const GetDramaRequest = struct {
    drama_id: i64 = 0,
};

pub const GetDramaResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    drama_info: DramaInfo = .{},
};

pub const GetCdnUsageDataRequest = struct {
    start_time: i64 = 0,
    end_time: i64 = 0,
    data_interval: i64 = 1440,
};

pub const CdnDataItem = struct {
    time: i64 = 0,
    value: i64 = 0,
};

pub const GetCdnUsageDataResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    data_interval: i64 = 0,
    item_list: []const CdnDataItem = &.{},
};

pub const GetCdnLogsRequest = struct {
    start_time: i64 = 0,
    end_time: i64 = 0,
    limit: i64 = 100,
    offset: i64 = 0,
};

pub const CdnLogInfo = struct {
    date: i64 = 0,
    name: []const u8 = "",
    url: []const u8 = "",
    start_time: i64 = 0,
    end_time: i64 = 0,
};

pub const GetCdnLogsResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total_count: i64 = 0,
    domestic_cdn_logs: []const CdnLogInfo = &.{},
};

/// 小程序微短剧模块。
pub const MiniDrama = struct {
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

    /// 单文件上传（multipart）。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次（重试会重建 multipart 体）。
    pub fn singleFileUpload(self: *Self, req: SingleFileUploadRequest) !std.json.Parsed(SingleFileUploadResponse) {
        const Sender = struct {
            allocator: std.mem.Allocator,
            req: SingleFileUploadRequest,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/sec/vod/singlefileupload?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);

                var fields = std.ArrayList(util_http.MultipartField).empty;
                defer fields.deinit(c.allocator);
                try fields.append(c.allocator, .{ .is_file = true, .field_name = "media_data", .filename = c.req.media_name, .value = "", .data = c.req.media_data });
                try fields.append(c.allocator, .{ .is_file = false, .field_name = "media_name", .filename = "", .value = c.req.media_name });
                try fields.append(c.allocator, .{ .is_file = false, .field_name = "media_type", .filename = "", .value = c.req.media_type });
                if (c.req.cover_type.len > 0 and c.req.cover_data.len > 0) {
                    try fields.append(c.allocator, .{ .is_file = false, .field_name = "cover_type", .filename = "", .value = c.req.cover_type });
                    try fields.append(c.allocator, .{ .is_file = true, .field_name = "cover_data", .filename = "cover", .value = "", .data = c.req.cover_data });
                }
                if (c.req.source_context.len > 0) {
                    try fields.append(c.allocator, .{ .is_file = false, .field_name = "source_context", .filename = "", .value = c.req.source_context });
                }

                const client = util_http.getDefaultClient(c.allocator);
                return client.postMultipart(uri, fields.items);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "SingleFileUpload", Sender{
            .allocator = self.allocator,
            .req = req,
        });
        defer self.allocator.free(resp);
        return parseParsed(self.allocator, resp, SingleFileUploadResponse);
    }

    /// 拉取上传。
    pub fn pullUpload(self: *Self, req: PullUploadRequest) !std.json.Parsed(PullUploadResponse) {
        return self.postJson("wxa/sec/vod/pullupload", &jsonFieldsPull(req), PullUploadResponse);
    }

    /// 查询任务状态。
    pub fn getTask(self: *Self, req: GetTaskRequest) !std.json.Parsed(GetTaskResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"task_id\":{d}}}", .{req.task_id});
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/gettask", body, GetTaskResponse);
    }

    /// 申请分片上传。
    pub fn applyUpload(self: *Self, req: ApplyUploadRequest) !std.json.Parsed(ApplyUploadResponse) {
        return self.postJson("wxa/sec/vod/applyupload", &jsonFieldsApply(req), ApplyUploadResponse);
    }

    /// 上传分片（multipart）。
    ///
    /// 请求走 `util_retry.callApi`：token 失效码时作废缓存并重试一次（重试会重建 multipart 体）。
    pub fn uploadPart(self: *Self, req: UploadPartRequest) !std.json.Parsed(UploadPartResponse) {
        const Sender = struct {
            allocator: std.mem.Allocator,
            req: UploadPartRequest,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(
                    allocator,
                    "https://api.weixin.qq.com/wxa/sec/vod/uploadpart?access_token={s}",
                    .{token},
                );
                defer allocator.free(uri);

                var fields = std.ArrayList(util_http.MultipartField).empty;
                defer fields.deinit(c.allocator);
                var part_buf: [32]u8 = undefined;
                var res_buf: [32]u8 = undefined;
                const part_str = try std.fmt.bufPrint(&part_buf, "{d}", .{c.req.part_number});
                const res_str = try std.fmt.bufPrint(&res_buf, "{d}", .{c.req.resource_type});
                try fields.append(c.allocator, .{ .is_file = false, .field_name = "upload_id", .filename = "", .value = c.req.upload_id });
                try fields.append(c.allocator, .{ .is_file = false, .field_name = "part_number", .filename = "", .value = part_str });
                try fields.append(c.allocator, .{ .is_file = false, .field_name = "resource_type", .filename = "", .value = res_str });
                try fields.append(c.allocator, .{ .is_file = true, .field_name = "data", .filename = "part", .value = "", .data = c.req.data });

                const client = util_http.getDefaultClient(c.allocator);
                return client.postMultipart(uri, fields.items);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, "UploadPart", Sender{
            .allocator = self.allocator,
            .req = req,
        });
        defer self.allocator.free(resp);
        return parseParsed(self.allocator, resp, UploadPartResponse);
    }

    /// 确认分片上传。
    pub fn commitUpload(self: *Self, req: CommitUploadRequest) !std.json.Parsed(CommitUploadResponse) {
        const body = try jsonStringifyCommit(self.allocator, req);
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/commitupload", body, CommitUploadResponse);
    }

    /// 获取媒体列表。
    pub fn listMedia(self: *Self, req: ListMediaRequest) !std.json.Parsed(ListMediaResponse) {
        return self.postJson("wxa/sec/vod/listmedia", &jsonFieldsListMedia(req), ListMediaResponse);
    }

    /// 获取媒资详情。
    pub fn getMedia(self: *Self, req: GetMediaRequest) !std.json.Parsed(GetMediaResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"media_id\":{d}}}", .{req.media_id});
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/getmedia", body, GetMediaResponse);
    }

    /// 获取媒资播放链接。
    pub fn getMediaLink(self: *Self, req: GetMediaLinkRequest) !std.json.Parsed(GetMediaLinkResponse) {
        return self.postJson("wxa/sec/vod/getmedialink", &jsonFieldsMediaLink(req), GetMediaLinkResponse);
    }

    /// 删除媒体。
    pub fn deleteMedia(self: *Self, req: DeleteMediaRequest) !std.json.Parsed(DeleteMediaResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"media_id\":{d}}}", .{req.media_id});
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/deletemedia", body, DeleteMediaResponse);
    }

    /// 审核剧目。
    pub fn auditDrama(self: *Self, req: AuditDramaRequest) !std.json.Parsed(AuditDramaResponse) {
        const body = try jsonStringifyAudit(self.allocator, req);
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/auditdrama", body, AuditDramaResponse);
    }

    /// 获取剧目列表。
    pub fn listDramas(self: *Self, req: ListDramasRequest) !std.json.Parsed(ListDramasResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"limit\":{d},\"offset\":{d}}}", .{ req.limit, req.offset });
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/listdramas", body, ListDramasResponse);
    }

    /// 获取剧目信息。
    pub fn getDrama(self: *Self, req: GetDramaRequest) !std.json.Parsed(GetDramaResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"drama_id\":{d}}}", .{req.drama_id});
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/getdrama", body, GetDramaResponse);
    }

    /// 查询 CDN 用量数据。
    pub fn getCdnUsageData(self: *Self, req: GetCdnUsageDataRequest) !std.json.Parsed(GetCdnUsageDataResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"start_time\":{d},\"end_time\":{d},\"data_interval\":{d}}}", .{ req.start_time, req.end_time, req.data_interval });
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/getcdnusagedata", body, GetCdnUsageDataResponse);
    }

    /// 查询 CDN 日志。
    pub fn getCdnLogs(self: *Self, req: GetCdnLogsRequest) !std.json.Parsed(GetCdnLogsResponse) {
        const body = try std.fmt.allocPrint(self.allocator, "{{\"start_time\":{d},\"end_time\":{d},\"limit\":{d},\"offset\":{d}}}", .{ req.start_time, req.end_time, req.limit, req.offset });
        defer self.allocator.free(body);
        return self.postBody("wxa/sec/vod/getcdnlogs", body, GetCdnLogsResponse);
    }

    fn postBody(self: *Self, endpoint: []const u8, body: []const u8, comptime T: type) !std.json.Parsed(T) {
        const Sender = struct {
            drama: *Self,
            endpoint: []const u8,
            body: []const u8,

            pub fn send(c: @This(), allocator: std.mem.Allocator, token: []const u8) anyerror![]u8 {
                const uri = try std.fmt.allocPrint(allocator, "https://api.weixin.qq.com/{s}?access_token={s}", .{ c.endpoint, token });
                defer allocator.free(uri);
                return c.drama.postJSON(uri, c.body);
            }
        };

        const resp = try util_retry.callApi(self.ctx, self.allocator, endpoint, Sender{
            .drama = self,
            .endpoint = endpoint,
            .body = body,
        });
        defer self.allocator.free(resp);
        return parseParsed(self.allocator, resp, T);
    }

    fn postJson(self: *Self, endpoint: []const u8, fields: []const JsonField, comptime R: type) !std.json.Parsed(R) {
        const body = try jsonStringifyFields(self.allocator, fields);
        defer self.allocator.free(body);
        return self.postBody(endpoint, body, R);
    }

    /// POST JSON；注入 transport 时使用之，否则走线程默认 client。
    fn postJSON(self: *Self, uri: []const u8, body: []const u8) ![]u8 {
        if (self.transport) |t| {
            var client = util_http.HttpClient.init(self.allocator);
            defer client.deinit();
            client.setTransport(t, self.transport_ctx);
            return client.postJSON(uri, body);
        }
        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body);
    }
};

const JsonField = struct {
    key: []const u8,
    str: []const u8 = "",
    num: i64 = 0,
    is_num: bool = false,
};

fn parseParsed(allocator: std.mem.Allocator, resp: []const u8, comptime T: type) !std.json.Parsed(T) {
    var parsed = std.json.parseFromSlice(T, allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        return util_error.WechatError.DecodeError;
    };
    errdefer parsed.deinit();
    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    return parsed;
}

fn jsonStringifyFields(allocator: std.mem.Allocator, fields: []const JsonField) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    for (fields) |f| {
        try s.objectField(f.key);
        if (f.is_num) try s.write(f.num) else try s.write(f.str);
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn jsonFieldsPull(req: PullUploadRequest) [4]JsonField {
    return .{
        .{ .key = "media_name", .str = req.media_name },
        .{ .key = "media_url", .str = req.media_url },
        .{ .key = "cover_url", .str = req.cover_url },
        .{ .key = "source_context", .str = req.source_context },
    };
}

fn jsonFieldsApply(req: ApplyUploadRequest) [4]JsonField {
    return .{
        .{ .key = "media_name", .str = req.media_name },
        .{ .key = "media_type", .str = req.media_type },
        .{ .key = "cover_type", .str = req.cover_type },
        .{ .key = "source_context", .str = req.source_context },
    };
}

fn jsonFieldsListMedia(req: ListMediaRequest) [6]JsonField {
    return .{
        .{ .key = "drama_id", .num = req.drama_id, .is_num = true },
        .{ .key = "media_name", .str = req.media_name },
        .{ .key = "start_time", .num = req.start_time, .is_num = true },
        .{ .key = "end_time", .num = req.end_time, .is_num = true },
        .{ .key = "limit", .num = req.limit, .is_num = true },
        .{ .key = "offset", .num = req.offset, .is_num = true },
    };
}

fn jsonFieldsMediaLink(req: GetMediaLinkRequest) [7]JsonField {
    return .{
        .{ .key = "media_id", .num = req.media_id, .is_num = true },
        .{ .key = "t", .num = req.t, .is_num = true },
        .{ .key = "us", .str = req.us },
        .{ .key = "expr", .num = req.expr, .is_num = true },
        .{ .key = "rlimit", .num = req.rlimit, .is_num = true },
        .{ .key = "whref", .str = req.whref },
        .{ .key = "bkref", .str = req.bkref },
    };
}

fn jsonStringifyCommit(allocator: std.mem.Allocator, req: CommitUploadRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("upload_id");
    try s.write(req.upload_id);
    try s.objectField("media_part_infos");
    try writePartInfos(&s, req.media_part_infos);
    if (req.cover_part_infos.len > 0) {
        try s.objectField("cover_part_infos");
        try writePartInfos(&s, req.cover_part_infos);
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn writePartInfos(s: *std.json.Stringify, infos: []const PartInfo) !void {
    try s.beginArray();
    for (infos) |p| {
        try s.beginObject();
        try s.objectField("part_number");
        try s.write(p.part_number);
        try s.objectField("etag");
        try s.write(p.etag);
        try s.endObject();
    }
    try s.endArray();
}

fn jsonStringifyAudit(allocator: std.mem.Allocator, req: AuditDramaRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    if (req.drama_id != 0) {
        try s.objectField("drama_id");
        try s.write(req.drama_id);
    }
    if (req.name.len > 0) {
        try s.objectField("name");
        try s.write(req.name);
    }
    if (req.media_count != 0) {
        try s.objectField("media_count");
        try s.write(req.media_count);
    }
    if (req.media_id_list.len > 0) {
        try s.objectField("media_id_list");
        try s.beginArray();
        for (req.media_id_list) |id| try s.write(id);
        try s.endArray();
    }
    if (req.producer.len > 0) {
        try s.objectField("producer");
        try s.write(req.producer);
    }
    if (req.description.len > 0) {
        try s.objectField("description");
        try s.write(req.description);
    }
    if (req.cover_material_id.len > 0) {
        try s.objectField("cover_material_id");
        try s.write(req.cover_material_id);
    }
    if (req.registration_number.len > 0) {
        try s.objectField("registration_number");
        try s.write(req.registration_number);
    }
    if (req.authorized_material_id.len > 0) {
        try s.objectField("authorized_material_id");
        try s.write(req.authorized_material_id);
    }
    if (req.publish_license.len > 0) {
        try s.objectField("publish_license");
        try s.write(req.publish_license);
    }
    if (req.publish_license_material_id.len > 0) {
        try s.objectField("publish_license_material_id");
        try s.write(req.publish_license_material_id);
    }
    if (req.expedited != 0) {
        try s.objectField("expedited");
        try s.write(req.expedited);
    }
    if (req.replace_media_list.len > 0) {
        try s.objectField("replace_media_list");
        try s.beginArray();
        for (req.replace_media_list) |r| {
            try s.beginObject();
            try s.objectField("old");
            try s.write(r.old);
            try s.objectField("new");
            try s.write(r.new);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
    return out.toOwnedSlice();
}

test "MiniDrama.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-md" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const m = MiniDrama.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-md", m.ctx.config.app_id);
}

test "PullUploadResponse 默认值" {
    const r = PullUploadResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.task_id);
}

// ── 可注入 transport 测试 ────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = credential.AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

/// 记录 method / uri / payload 并返回预设响应的 transport。
const CapturingTransport = struct {
    method: std.http.Method = .GET,
    uri: []const u8 = "",
    payload: []const u8 = "",
    response: []const u8 = "",

    fn dispatch(ctx: *anyopaque, allocator: std.mem.Allocator, uri: []const u8, method: std.http.Method, payload: []const u8, content_type: ?[]const u8) anyerror![]u8 {
        _ = content_type;
        const self: *CapturingTransport = @ptrCast(@alignCast(ctx));
        self.method = method;
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        return allocator.dupe(u8, self.response);
    }

    fn deinit(self: *CapturingTransport, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.payload);
    }
};

fn makeCtx() Context {
    return .{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
}

test "getTask POST 查询任务并解析（回归：泛型 T 参数错位）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"task_info\":{\"id\":123,\"task_type\":1,\"status\":2,\"media_id\":456}}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var m = MiniDrama.init(&ctx, allocator);
    m.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try m.getTask(.{ .task_id = 123 });
    defer parsed.deinit();

    try std.testing.expectEqual(std.http.Method.POST, tt.method);
    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/sec/vod/gettask?access_token=token-abc", tt.uri);
    try std.testing.expectEqualStrings("{\"task_id\":123}", tt.payload);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.task_info.status);
    try std.testing.expectEqual(@as(i64, 456), parsed.value.task_info.media_id);
}

test "pullUpload POST 拉取上传并解析（回归：postJson→postBody 泛型错位）" {
    const allocator = std.testing.allocator;
    var tt = CapturingTransport{ .response = "{\"task_id\":789}" };
    defer tt.deinit(allocator);

    var ctx = makeCtx();
    var m = MiniDrama.init(&ctx, allocator);
    m.setTransport(CapturingTransport.dispatch, &tt);

    var parsed = try m.pullUpload(.{
        .media_name = "drama-ep1",
        .media_url = "https://cdn.example.com/ep1.mp4",
        .cover_url = "https://cdn.example.com/cover.jpg",
        .source_context = "ctx-1",
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("https://api.weixin.qq.com/wxa/sec/vod/pullupload?access_token=token-abc", tt.uri);
    try std.testing.expect(std.mem.indexOf(u8, tt.payload, "\"media_name\":\"drama-ep1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tt.payload, "\"media_url\":\"https://cdn.example.com/ep1.mp4\"") != null);
    try std.testing.expectEqual(@as(i64, 789), parsed.value.task_id);
}

// ── token 失效自愈（util_retry.callApi）──────────────────────────────────────

const retry_testing = @import("../retry_testing.zig");

test "getTask token 失效自愈：作废缓存后用新 token 重试成功" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    const base = "https://api.weixin.qq.com/wxa/sec/vod/gettask?access_token=";
    try mt.addRoute(base ++ "token-abc", .{
        .body = "{\"errcode\":40001,\"errmsg\":\"invalid credential\"}",
    });
    try mt.addRoute(base ++ "token-new", .{
        .body = "{\"task_info\":{\"id\":123,\"status\":2}}",
    });

    var stub = retry_testing.RotatingToken{};
    var ctx = Context{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = stub.asHandle(),
    };
    var m = MiniDrama.init(&ctx, allocator);
    m.setTransport(util_http.MockTransport.dispatch, &mt);

    var parsed = try m.getTask(.{ .task_id = 123 });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed.value.task_info.status);

    try std.testing.expectEqual(@as(usize, 1), stub.invalidates);
    try std.testing.expectEqual(@as(usize, 2), mt.history.items.len);
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[0], "access_token=token-abc"));
    try std.testing.expect(std.mem.endsWith(u8, mt.history.items[1], "access_token=token-new"));
}
