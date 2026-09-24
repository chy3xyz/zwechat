// SPDX-License-Identifier: Apache-2.0
//! officialaccount/material — 素材管理
//!
//! 对应 `_ref/wechat/officialaccount/material/material.go`：永久素材（图文 / 图片 / 语音 / 视频）的 CRUD。
//! 主要 API：AddNews / UpdateNews / DeleteMaterial / GetMaterialCount / BatchGetMaterial / GetNews。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");
const util_json = @import("../../util/json.zig");

pub const PermanentMaterialType = enum {
    image,
    video,
    voice,
    news,
};

/// 下载素材的缺省体积上限（字节）：100 MB。
///
/// 微信侧素材体积口径：图片 10 MB、语音 2 MB、缩略图 64 KB；永久视频素材没有
/// 公开的下载上限。本 SDK 缺省取 100 MB 作为"防爆内存"安全网（视频口径），
/// 需要更严的限制时用 `getMediaWithLimit` / `getMediaToFileWithLimit` 覆盖。
pub const max_media_bytes: usize = 100 * 1024 * 1024;

/// 图片素材推荐上限（微信侧 10 MB）。
pub const max_image_bytes: usize = 10 * 1024 * 1024;

/// 语音素材推荐上限（微信侧 2 MB）。
pub const max_voice_bytes: usize = 2 * 1024 * 1024;

/// 视频素材推荐上限（微信侧视频类素材无公开下载上限，取 100 MB）。
pub const max_video_bytes: usize = 100 * 1024 * 1024;

/// 按素材类型给出推荐的下载上限（可直接传给 `getMediaWithLimit`）。
pub fn maxBytesFor(mtype: PermanentMaterialType) usize {
    return switch (mtype) {
        .image => max_image_bytes,
        .voice => max_voice_bytes,
        .video, .news => max_video_bytes,
    };
}

/// 单篇图文素材。
pub const Article = struct {
    title: []const u8 = "",
    thumb_media_id: []const u8 = "",
    thumb_url: []const u8 = "",
    author: []const u8 = "",
    digest: []const u8 = "",
    show_cover_pic: i64 = 0,
    content: []const u8 = "",
    content_source_url: []const u8 = "",
    url: []const u8 = "",
    down_url: []const u8 = "",
};

/// 素材总数返回。
pub const ResMaterialCount = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    voice_count: i64 = 0,
    video_count: i64 = 0,
    image_count: i64 = 0,
    news_count: i64 = 0,
};

/// 素材列表项。
pub const ArticleListItem = struct {
    media_id: []const u8 = "",
    name: []const u8 = "",
    url: []const u8 = "",
    update_time: i64 = 0,
    content: ArticleListContent = .{},
};

pub const ArticleListContent = struct {
    news_item: []const Article = &.{},
    update_time: i64 = 0,
    create_time: i64 = 0,
};

pub const ArticleList = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total_count: i64 = 0,
    item_count: i64 = 0,
    item: []const ArticleListItem = &.{},
};

/// `getNews` 的响应（`news_item` 为图文文章列表）。
pub const GetNewsResult = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    news_item: []const Article = &.{},
};

/// 永久素材（视频）上传返回（对照 Go `resAddMaterial`）。
pub const AddMaterialResult = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    media_id: []const u8 = "",
    url: []const u8 = "",
};

pub const Material = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    /// 文件系统操作（错误体回读 / 删除）所用的 `Io` 句柄。
    /// 默认 `global_single_threaded`，宿主可注入自己的 `Io` 实例。
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 新增永久图文素材（POST JSON）。
    ///
    /// 返回微信分配的 media_id，由本结构体的 allocator 分配，
    /// **调用方负责 `free`**。
    pub fn addNews(self: *Self, articles: []const Article) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ addNewsURL, access_token });
        defer self.allocator.free(uri);

        const body = try serializeArticles(self.allocator, articles);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(struct {
            errcode: i64 = 0,
            errmsg: []const u8 = "",
            media_id: []const u8 = "",
        }, self.allocator, resp, .{ .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        const media_id = try self.allocator.dupe(u8, parsed.value.media_id);
        return media_id;
    }

    /// 更新永久图文素材中的单篇文章（`material/update_news`）。
    ///
    /// `index` 为文章在图文消息中的位置，第一篇为 0。
    pub fn updateNews(self: *Self, article: *const Article, media_id: []const u8, index: i64) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ updateNewsURL, access_token });
        defer self.allocator.free(uri);

        const body = try buildUpdateNewsBody(self.allocator, article, media_id, index);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "UpdateNews")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 新增永久视频素材（`material/add_material?type=video`，multipart 上传）。
    ///
    /// `data` 为视频文件字节（内存中，测试友好）；`filename` 为 multipart 文件名；
    /// `title` / `introduction` 会作为 `description` 字段的 JSON 一同提交。
    /// 返回的 `std.json.Parsed(AddMaterialResult)` 由调用方持有并负责 `deinit`。
    pub fn addVideoFromBytes(
        self: *Self,
        data: []const u8,
        filename: []const u8,
        title: []const u8,
        introduction: []const u8,
    ) !std.json.Parsed(AddMaterialResult) {
        return self.postVideo(data, "", filename, title, introduction);
    }

    /// 新增永久视频素材（从文件路径读取视频内容）。
    ///
    /// `file_path` 末段作为 multipart 文件名（对照 Go `path.Base`）。
    pub fn addVideo(
        self: *Self,
        file_path: []const u8,
        title: []const u8,
        introduction: []const u8,
    ) !std.json.Parsed(AddMaterialResult) {
        // multipart 文件名取路径末段（对照 Go `path.Base`）。
        const filename = std.fs.path.basename(file_path);
        return self.postVideo("", file_path, filename, title, introduction);
    }

    /// 视频上传公共实现：`media` 文件字段 + `description` JSON 字段。
    fn postVideo(
        self: *Self,
        data: []const u8,
        file_path: []const u8,
        filename: []const u8,
        title: []const u8,
        introduction: []const u8,
    ) !std.json.Parsed(AddMaterialResult) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}&type=video", .{ addMaterialURL, access_token });
        defer self.allocator.free(uri);

        // description 字段为 JSON：`{"title":"...","introduction":"..."}`，统一走 Stringify 转义。
        var desc_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer desc_buf.deinit();
        {
            var s: std.json.Stringify = .{ .writer = &desc_buf.writer };
            try s.beginObject();
            try s.objectField("title");
            try s.write(title);
            try s.objectField("introduction");
            try s.write(introduction);
            try s.endObject();
        }

        const fields = [_]util_http.MultipartField{
            .{
                .is_file = true,
                .field_name = "media",
                .filename = filename,
                .value = "",
                .file_path = file_path,
                .data = data,
            },
            .{
                .is_file = false,
                .field_name = "description",
                .filename = filename,
                .value = desc_buf.written(),
            },
        };

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postMultipart(uri, &fields);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(AddMaterialResult, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 新增永久图片 / 语音素材（`material/add_material?type=image|voice`，multipart 单 `media` 字段）。
    ///
    /// 对照 Go `AddMaterialFromReader`（Go 用 reader 接口，Zig 用内存 bytes 形态）。
    /// `data` 为文件字节；`filename` 为 multipart 文件名。
    /// 返回的 `std.json.Parsed(AddMaterialResult)`（media_id + url）由调用方持有并负责 `deinit`。
    pub fn addMaterialFromBytes(
        self: *Self,
        mtype: PermanentMaterialType,
        data: []const u8,
        filename: []const u8,
    ) !std.json.Parsed(AddMaterialResult) {
        return self.postMaterial(mtype, data, "", filename);
    }

    /// 新增永久图片 / 语音素材（从文件路径读取内容）。
    ///
    /// `file_path` 末段作为 multipart 文件名（对照 Go `path.Base`）。
    /// 视频素材请使用 `addVideo`（需额外提交 description 字段）。
    pub fn addMaterial(
        self: *Self,
        mtype: PermanentMaterialType,
        file_path: []const u8,
    ) !std.json.Parsed(AddMaterialResult) {
        // multipart 文件名取路径末段（对照 Go `path.Base`）。
        const filename = std.fs.path.basename(file_path);
        return self.postMaterial(mtype, "", file_path, filename);
    }

    /// 图片 / 语音上传公共实现：multipart 仅含 `media` 文件字段（视频另有 description，见 `postVideo`）。
    fn postMaterial(
        self: *Self,
        mtype: PermanentMaterialType,
        data: []const u8,
        file_path: []const u8,
        filename: []const u8,
    ) !std.json.Parsed(AddMaterialResult) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}&type={s}", .{ addMaterialURL, access_token, @tagName(mtype) });
        defer self.allocator.free(uri);

        const fields = [_]util_http.MultipartField{
            .{
                .is_file = true,
                .field_name = "media",
                .filename = filename,
                .value = "",
                .file_path = file_path,
                .data = data,
            },
        };

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postMultipart(uri, &fields);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(AddMaterialResult, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 获取永久图文素材（`material/get_material`）。
    ///
    /// 返回的 `std.json.Parsed(GetNewsResult)` 由调用方持有并负责 `deinit`。
    pub fn getNews(self: *Self, media_id: []const u8) !std.json.Parsed(GetNewsResult) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ getMaterialURL, access_token });
        defer self.allocator.free(uri);

        const body = try util_json.stringFieldObject(self.allocator, "media_id", media_id);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GetNewsResult, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 返回临时素材的下载地址（对照 Go `GetMediaURL`）。
    ///
    /// **注意**：URL 内含 access_token，不可公开，需要立即另存文件。
    /// 返回的字符串由本结构体的 allocator 分配，调用方负责 `free`。
    pub fn getMediaURL(self: *Self, media_id: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        return std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}&media_id={s}",
            .{ mediaGetURL, access_token, media_id },
        );
    }

    /// 下载临时素材（`media/get`；对照 Go 侧自行用 `util.HTTPGet` 拉取的场景）。
    ///
    /// 微信会 302 到 CDN，内部走 `HttpClient.getFollowRedirectLimited` 手动跟随，
    /// 缺省体积上限为 `max_media_bytes`（100 MB，防爆内存的安全网）。
    /// 若响应是 JSON 错误体（如 media_id 无效）返回 `WechatError.ApiError`；
    /// 返回的字节由调用方负责 `free`。
    pub fn getMedia(self: *Self, media_id: []const u8) ![]u8 {
        return self.getMediaWithLimit(media_id, max_media_bytes);
    }

    /// 下载临时素材并限制体积（`media/get`）。
    ///
    /// `max_bytes` 是响应体上限：**边读边累加**，超过则立即中止并返回
    /// `error.ResponseTooLarge`（不会把超限素材整个读进内存）。视频素材建议
    /// 用 `getMediaToFileWithLimit` 流式落盘；按类型取推荐上限见 `maxBytesFor`。
    ///
    /// 若响应是 JSON 错误体（如 media_id 无效）返回 `WechatError.ApiError`；
    /// 返回的字节由调用方负责 `free`。
    pub fn getMediaWithLimit(self: *Self, media_id: []const u8, max_bytes: usize) ![]u8 {
        const media_url = try self.getMediaURL(media_id);
        defer self.allocator.free(media_url);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.getFollowRedirectLimited(media_url, max_bytes);
        defer self.allocator.free(resp);

        return self.allocator.dupe(u8, try util_error.handleFileResponse(resp, "GetMedia"));
    }

    /// 下载临时素材并流式落盘，返回写入字节数（缺省上限 `max_media_bytes`）。
    ///
    /// 适合视频等大素材：响应体不驻留内存。返回的字节数由调用方用于核对文件大小。
    pub fn getMediaToFile(self: *Self, media_id: []const u8, file_path: []const u8) !u64 {
        return self.getMediaToFileWithLimit(media_id, file_path, max_media_bytes);
    }

    /// 下载临时素材并流式落盘（带体积上限），返回写入字节数。
    ///
    /// - 边收边写，不把整个素材读进内存；超过 `max_bytes` 时中止、**删除不完整
    ///   文件**并返回 `error.ResponseTooLarge`；
    /// - 微信返回错误时是体积很小的 JSON 错误体，落盘后会回读判定：识别为错误体
    ///   时删除文件并返回 `WechatError.ApiError`（不会把错误 JSON 当素材留在磁盘上）；
    /// - `file_path` 已存在时会被覆盖。
    pub fn getMediaToFileWithLimit(
        self: *Self,
        media_id: []const u8,
        file_path: []const u8,
        max_bytes: usize,
    ) !u64 {
        const media_url = try self.getMediaURL(media_id);
        defer self.allocator.free(media_url);

        const client = util_http.getDefaultClient(self.allocator);
        const written = try client.getFollowRedirectToFile(media_url, file_path, max_bytes);
        try self.rejectJsonErrorFile(file_path, written, "GetMedia");
        return written;
    }

    /// 微信的错误响应体是体积很小的 JSON（如 `{"errcode":40007,...}`）。落盘路径
    /// 为避免把错误 JSON 当成素材留在磁盘上，对不超过 `peek_bytes` 的小文件回读
    /// 判定：识别为 JSON 错误体时删除文件并返回 `WechatError.ApiError`。
    fn rejectJsonErrorFile(self: *Self, file_path: []const u8, written: u64, api_name: []const u8) !void {
        const peek_bytes: usize = 4096;
        if (written == 0 or written > peek_bytes) return;
        const io = self.io;
        const body = std.Io.Dir.cwd().readFileAlloc(io, file_path, self.allocator, .limited(peek_bytes)) catch return;
        defer self.allocator.free(body);
        _ = util_error.handleFileResponse(body, api_name) catch |err| {
            std.Io.Dir.cwd().deleteFile(io, file_path) catch {};
            return err;
        };
    }

    /// 删除永久素材。
    pub fn deleteMaterial(self: *Self, media_id: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ delMaterialURL, access_token });
        defer self.allocator.free(uri);

        const body = try util_json.stringFieldObject(self.allocator, "media_id", media_id);
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DeleteMaterial")) |ce| {
            defer ce.deinit();
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取素材总数。
    /// 返回的 `std.json.Parsed(ResMaterialCount)` 由调用方持有并负责 `deinit`。
    pub fn getMaterialCount(self: *Self) !std.json.Parsed(ResMaterialCount) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ getMaterialCountURL, access_token });
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResMaterialCount, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 批量获取素材列表。
    /// 返回的 `std.json.Parsed(ArticleList)` 由调用方持有并负责 `deinit`。
    pub fn batchGetMaterial(self: *Self, mtype: PermanentMaterialType, offset: i64, count: i64) !std.json.Parsed(ArticleList) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ batchGetMaterialURL, access_token });
        defer self.allocator.free(uri);

        const type_str = @tagName(mtype);
        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"{s}\",\"offset\":{d},\"count\":{d}}}",
            .{ type_str, offset, count },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(ArticleList, self.allocator, resp, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    fn serializeArticles(allocator: std.mem.Allocator, articles: []const Article) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"articles\":[");
        for (articles, 0..) |a, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeArticleJson(allocator, &buf, &a);
        }
        try buf.append(allocator, ']');
        try buf.append(allocator, '}');
        return buf.toOwnedSlice(allocator);
    }

    fn writeArticleJson(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), a: *const Article) !void {
        try buf.append(allocator, '{');
        var first = true;
        const fields = [_]struct { name: []const u8, value: []const u8 }{
            .{ .name = "title", .value = a.title },
            .{ .name = "thumb_media_id", .value = a.thumb_media_id },
            .{ .name = "author", .value = a.author },
            .{ .name = "digest", .value = a.digest },
            .{ .name = "content", .value = a.content },
            .{ .name = "content_source_url", .value = a.content_source_url },
        };
        for (fields) |f| {
            if (f.value.len == 0) continue;
            if (!first) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, "\":\"");
            try appendJsonString(allocator, buf, f.value);
            try buf.append(allocator, '"');
            first = false;
        }
        // show_cover_pic 必须始终输出（Go 参考对整个结构体序列化，不省略零值），
        // 否则微信侧可能按缺省处理导致封面显示行为与预期不符。
        if (!first) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"show_cover_pic\":");
        var num_buf: [24]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{a.show_cover_pic}) catch unreachable;
        try buf.appendSlice(allocator, num);
        try buf.append(allocator, '}');
    }

    /// JSON 字符串转义（实现收敛到 `util.json.appendEscapedString`；此前漏转义
    /// `c < 0x20` 控制字符，图文素材正文含控制字符时会产出非法 JSON）。
    const appendJsonString = util_json.appendEscapedString;
};

/// 组装 `update_news` 请求体：`{"media_id":"...","index":N,"articles":{...}}`。
/// 纯函数，便于单元测试。
fn buildUpdateNewsBody(allocator: std.mem.Allocator, article: *const Article, media_id: []const u8, index: i64) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"media_id\":\"");
    try util_json.appendEscapedString(allocator, &buf, media_id);
    try buf.appendSlice(allocator, "\",\"index\":");
    var num_buf: [24]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{index}) catch unreachable;
    try buf.appendSlice(allocator, num);
    try buf.appendSlice(allocator, ",\"articles\":");
    try Material.writeArticleJson(allocator, &buf, article);
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

pub const addNewsURL = "https://api.weixin.qq.com/cgi-bin/material/add_news";
pub const updateNewsURL = "https://api.weixin.qq.com/cgi-bin/material/update_news";
pub const addMaterialURL = "https://api.weixin.qq.com/cgi-bin/material/add_material";
pub const delMaterialURL = "https://api.weixin.qq.com/cgi-bin/material/del_material";
pub const getMaterialURL = "https://api.weixin.qq.com/cgi-bin/material/get_material";
pub const getMaterialCountURL = "https://api.weixin.qq.com/cgi-bin/material/get_materialcount";
pub const batchGetMaterialURL = "https://api.weixin.qq.com/cgi-bin/material/batchget_material";
/// 临时素材下载（media/get，302 到 CDN）。
pub const mediaGetURL = "https://api.weixin.qq.com/cgi-bin/media/get";

test "Article 默认值" {
    const a = Article{};
    try std.testing.expectEqualStrings("", a.title);
    try std.testing.expectEqual(@as(i64, 0), a.show_cover_pic);
}

test "PermanentMaterialType 枚举" {
    try std.testing.expectEqualStrings("image", @tagName(PermanentMaterialType.image));
    try std.testing.expectEqualStrings("news", @tagName(PermanentMaterialType.news));
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试辅助：假 AccessTokenHandle + capture transport。
// ─────────────────────────────────────────────────────────────────────────────

const credential = @import("../../credential/mod.zig");

const TestTokenState = struct {
    token: []const u8,
};

fn testGetAccessToken(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const state: *const TestTokenState = @ptrCast(@alignCast(ctx));
    return allocator.dupe(u8, state.token);
}

const test_token_vtable = credential.AccessTokenHandle.VTable{
    .getAccessToken = testGetAccessToken,
};

fn makeFakeTokenHandle(state: *TestTokenState) credential.AccessTokenHandle {
    return .{
        .ptr = @ptrCast(state),
        .vtable = &test_token_vtable,
    };
}

const TestCapture = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    status: u16 = 200,
    uri: []u8 = &.{},
    payload: []u8 = &.{},
    ctype: []const u8 = "",

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        _ = method;
        const self: *TestCapture = @ptrCast(@alignCast(ctx));
        self.uri = try allocator.dupe(u8, uri);
        self.payload = try allocator.dupe(u8, payload);
        self.ctype = try allocator.dupe(u8, content_type orelse "");
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

test "serializeArticles 始终输出 show_cover_pic 且转义特殊字符" {
    const allocator = std.testing.allocator;
    // 回归：此前 show_cover_pic 被整体省略，与 Go 参考（全字段序列化）不一致。
    const articles = [_]Article{
        .{
            .title = "标\"题",
            .thumb_media_id = "THUMB1",
            .content = "段\n落",
            .show_cover_pic = 1,
        },
        .{},
    };
    const body = try Material.serializeArticles(allocator, &articles);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"articles\":[" ++
            "{\"title\":\"标\\\"题\",\"thumb_media_id\":\"THUMB1\",\"content\":\"段\\n落\",\"show_cover_pic\":1}," ++
            "{\"show_cover_pic\":0}" ++
            "]}",
        body,
    );
}

test "buildUpdateNewsBody 组装 update_news 请求体" {
    const allocator = std.testing.allocator;
    const article = Article{
        .title = "t",
        .thumb_media_id = "M",
        .show_cover_pic = 0,
    };
    const body = try buildUpdateNewsBody(allocator, &article, "MEDIA7", 2);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"media_id\":\"MEDIA7\",\"index\":2,\"articles\":{\"title\":\"t\",\"thumb_media_id\":\"M\",\"show_cover_pic\":0}}",
        body,
    );
}

test "buildUpdateNewsBody 转义 media_id（回归：原先裸 appendSlice）" {
    const allocator = std.testing.allocator;
    const article = Article{ .title = "t", .show_cover_pic = 0 };
    const body = try buildUpdateNewsBody(allocator, &article, "M\"ED\x01", 0);
    defer allocator.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "{\"media_id\":\"M\\\"ED\\u0001\","));

    const reparsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("M\"ED\x01", reparsed.value.object.get("media_id").?.string);
}

test "Material.getNews / deleteMaterial 转义 media_id（回归：allocPrint 裸插值）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // getNews：media_id 含引号与控制字符。
    var cap = TestCapture{ .allocator = alloc, .response = "{\"news_item\":[]}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    var parsed = try m.getNews("M\"E\x01");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("{\"media_id\":\"M\\\"E\\u0001\"}", cap.payload);
    {
        const reparsed = try std.json.parseFromSlice(std.json.Value, alloc, cap.payload, .{});
        defer reparsed.deinit();
        try std.testing.expectEqualStrings("M\"E\x01", reparsed.value.object.get("media_id").?.string);
    }

    // deleteMaterial：同一路径。
    var cap2 = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" };
    setupTestClient(alloc, &cap2);
    defer releaseTestClient();

    try m.deleteMaterial("M\\E");
    try std.testing.expectEqualStrings("{\"media_id\":\"M\\\\E\"}", cap2.payload);
}

test "Material.addNews 返回 media_id 且由调用方释放" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"media_id\":\"MEDIA_NEW\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    const articles = [_]Article{.{ .title = "t", .thumb_media_id = "THUMB" }};
    const media_id = try m.addNews(&articles);
    defer alloc.free(media_id);
    try std.testing.expectEqualStrings("MEDIA_NEW", media_id);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/material/add_news?access_token=stub-ak",
        cap.uri,
    );
}

test "Material.getNews 解析 news_item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"news_item\":[{\"title\":\"t1\",\"show_cover_pic\":1},{\"title\":\"t2\"}]}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    var parsed = try m.getNews("MEDIA9");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.news_item.len);
    try std.testing.expectEqualStrings("t1", parsed.value.news_item[0].title);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.news_item[0].show_cover_pic);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/material/get_material?access_token=stub-ak",
        cap.uri,
    );
    try std.testing.expectEqualStrings("{\"media_id\":\"MEDIA9\"}", cap.payload);
}

test "Material.updateNews errcode 非 0 返回 ApiError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":40007,\"errmsg\":\"invalid media_id\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    const article = Article{ .title = "t", .thumb_media_id = "THUMB" };
    try std.testing.expectError(util_error.WechatError.ApiError, m.updateNews(&article, "BAD", 0));
}

test "Material.addVideoFromBytes multipart 含 media 与 description 字段" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"media_id\":\"VIDEO_MEDIA\",\"url\":\"https://mmbiz.qpic.cn/v1\"}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    var parsed = try m.addVideoFromBytes("fake-video-bytes", "clip.mp4", "标\"题", "介\n绍");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("VIDEO_MEDIA", parsed.value.media_id);
    try std.testing.expectEqualStrings("https://mmbiz.qpic.cn/v1", parsed.value.url);

    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/material/add_material?access_token=stub-ak&type=video",
        cap.uri,
    );
    try std.testing.expect(std.mem.startsWith(u8, cap.ctype, "multipart/form-data; boundary="));
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "name=\"media\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "filename=\"clip.mp4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "fake-video-bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "name=\"description\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "{\"title\":\"标\\\"题\",\"introduction\":\"介\\n绍\"}") != null);

    // errcode 非 0 → ApiError。
    cap.response = "{\"errcode\":40009,\"errmsg\":\"invalid image size\"}";
    try std.testing.expectError(
        util_error.WechatError.ApiError,
        m.addVideoFromBytes("x", "a.mp4", "t", "i"),
    );
}

test "Material.addVideo 从临时文件读取视频内容" {
    const io = std.testing.io;
    const tmp_path = "zwechat_oa_material_addvideo_test.bin";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    }
    try file.writePositionalAll(io, "tmp-video-content", 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"media_id\":\"VIDEO_TMP\",\"url\":\"\"}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    var parsed = try m.addVideo(tmp_path, "标题", "介绍");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("VIDEO_TMP", parsed.value.media_id);
    // 文件名取路径末段，文件内容进入 media 字段。
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "tmp-video-content") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "filename=\"zwechat_oa_material_addvideo_test.bin\"") != null);
}

test "Material.getMediaURL 拼接含 access_token 的下载地址" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    const url = try m.getMediaURL("MEDIA_DL_1");
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/media/get?access_token=stub-ak&media_id=MEDIA_DL_1",
        url,
    );
}

test "Material.getMediaWithLimit 超限返回 ResponseTooLarge、限内正常" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const big = try alloc.alloc(u8, 4096);
    @memset(big, 'A');

    var cap = TestCapture{ .allocator = alloc, .response = big };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    try std.testing.expectError(error.ResponseTooLarge, m.getMediaWithLimit("BIG", 1024));

    const data = try m.getMediaWithLimit("BIG", 4096);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 4096), data.len);

    // 缺省入口按 `max_media_bytes`（100 MB）放行。
    const via_default = try m.getMedia("BIG");
    defer alloc.free(via_default);
    try std.testing.expectEqual(@as(usize, 4096), via_default.len);

    // 按类型的推荐上限：图片 10 MB、语音 2 MB、视频 100 MB。
    try std.testing.expectEqual(@as(usize, 10 * 1024 * 1024), maxBytesFor(.image));
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), maxBytesFor(.voice));
    try std.testing.expectEqual(max_media_bytes, maxBytesFor(.video));
}

test "Material.getMediaToFile 落盘、超限清文件、JSON 错误体清文件" {
    const io = std.testing.io;
    const tmp_path = "zwechat_oa_material_getmedia_tofile_test.bin";
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const big = try alloc.alloc(u8, 4096);
    @memset(big, 'B');

    var cap = TestCapture{ .allocator = alloc, .response = "fake-media-payload" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);
    // 注入宿主 `Io`：错误体回读 / 删除落盘文件都走这个句柄（默认值是同一实例的兜底）。
    m.io = io;

    const written = try m.getMediaToFile("MEDIA_DL_1", tmp_path);
    try std.testing.expectEqual(@as(u64, 18), written);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, tmp_path, alloc, .limited(64));
    try std.testing.expectEqualStrings("fake-media-payload", got);

    // 超限：中止并删除不完整文件（先清掉上一次的产物）。
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    cap.response = big;
    try std.testing.expectError(
        error.ResponseTooLarge,
        m.getMediaToFileWithLimit("MEDIA_DL_1", tmp_path, 128),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, tmp_path, .{}));

    // JSON 错误体：删除文件并返回 ApiError，不把错误 JSON 当素材留下。
    cap.response = "{\"errcode\":40007,\"errmsg\":\"invalid media_id\"}";
    try std.testing.expectError(
        util_error.WechatError.ApiError,
        m.getMediaToFile("MEDIA_DL_1", tmp_path),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, tmp_path, .{}));
}

test "Material.getMedia 经 transport 拿到二进制内容" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "\x89PNG\r\n\x1a\nfake-image-bytes" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    const data = try m.getMedia("MEDIA_DL_1");
    defer alloc.free(data);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nfake-image-bytes", data);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/media/get?access_token=stub-ak&media_id=MEDIA_DL_1",
        cap.uri,
    );
}

test "Material.getMedia JSON 错误体返回 ApiError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{ .allocator = alloc, .response = "{\"errcode\":40007,\"errmsg\":\"invalid media_id\"}" };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    try std.testing.expectError(util_error.WechatError.ApiError, m.getMedia("BAD"));
}

test "Material.addMaterialFromBytes 图片上传：URL type=image 且 multipart 仅含 media 字段" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"media_id\":\"IMG_MEDIA\",\"url\":\"https://mmbiz.qpic.cn/img1\"}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    var parsed = try m.addMaterialFromBytes(.image, "fake-png-bytes", "cover.png");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("IMG_MEDIA", parsed.value.media_id);
    try std.testing.expectEqualStrings("https://mmbiz.qpic.cn/img1", parsed.value.url);

    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/material/add_material?access_token=stub-ak&type=image",
        cap.uri,
    );
    try std.testing.expect(std.mem.startsWith(u8, cap.ctype, "multipart/form-data; boundary="));
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "name=\"media\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "filename=\"cover.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "fake-png-bytes") != null);
    // 图片 / 语音上传不提交 description 字段。
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "name=\"description\"") == null);

    // errcode 非 0 → ApiError。
    cap.response = "{\"errcode\":40009,\"errmsg\":\"invalid image size\"}";
    try std.testing.expectError(
        util_error.WechatError.ApiError,
        m.addMaterialFromBytes(.image, "x", "a.png"),
    );
}

test "Material.addMaterial 语音素材：type=voice、文件名取路径末段" {
    const io = std.testing.io;
    const tmp_path = "zwechat_oa_material_addvoice_test.bin";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    }
    try file.writePositionalAll(io, "tmp-audio-content", 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cap = TestCapture{
        .allocator = alloc,
        .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"media_id\":\"VOICE_MEDIA\",\"url\":\"\"}",
    };
    setupTestClient(alloc, &cap);
    defer releaseTestClient();

    var state = TestTokenState{ .token = "stub-ak" };
    var ctx = Context{ .config = .{}, .access_token_handle = makeFakeTokenHandle(&state) };
    var m = Material.init(&ctx, alloc);

    var parsed = try m.addMaterial(.voice, tmp_path);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("VOICE_MEDIA", parsed.value.media_id);
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/material/add_material?access_token=stub-ak&type=voice",
        cap.uri,
    );
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "tmp-audio-content") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.payload, "filename=\"zwechat_oa_material_addvoice_test.bin\"") != null);
}
