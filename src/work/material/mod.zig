//! work/material — 素材管理
//!
//! 对应 `_ref/wechat/work/material/`：实现临时素材（图片 / 语音 / 视频 / 文件）
//! 的 `Upload` 与永久素材列表的 `GetMediaList`。
//!
//! - `Upload` 走 `multipart/form-data`，使用 `util.http.HttpClient.postMultipart`。
//!   当前只支持图片（`media_type = "image"`），对应上游 `UploadTempFile` 的
//!   `type=image` 形态。
//! - `GetMediaList` 走 `POST /cgi-bin/material/get_materiallist`，对应企业微信
//!   永久素材列表接口；该接口在 Go 参考实现中没有同名方法（仅有上传 / 获取
//!   二进制等），这里按 WeWork 公开文档补齐。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

// ─────────────────────────────────────────────────────────────────────────────
// URL 常量
// ─────────────────────────────────────────────────────────────────────────────

/// 上传临时素材（图片 / 语音 / 视频 / 文件）。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/media/upload?access_token=...&type=...`。
pub const uploadTempFileURL = "https://qyapi.weixin.qq.com/cgi-bin/media/upload";

/// 拉取永久素材列表（POST JSON）。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/material/get_materiallist?access_token=...`。
pub const getMaterialListURL = "https://qyapi.weixin.qq.com/cgi-bin/material/get_materiallist";

// ─────────────────────────────────────────────────────────────────────────────
// 媒体类型
// ─────────────────────────────────────────────────────────────────────────────

/// 临时素材媒体类型（与 `?type=` 参数对应）。
pub const MediaType = enum {
    image,
    voice,
    video,
    file,

    /// 序列化为微信 API 期望的小写字符串。
    pub fn wire(self: MediaType) []const u8 {
        return @tagName(self);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 响应 / 数据结构
// ─────────────────────────────────────────────────────────────────────────────

/// `Upload` 响应。
pub const UploadResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 媒体文件 id。
    media_id: []const u8 = "",
    /// 上传时间戳（秒），微信侧字段名是 `created_at`。
    created_at: i64 = 0,
    /// 媒体类型（image / voice / video / file）。
    type: []const u8 = "",
};

/// `GetMediaList` 请求体。
pub const MediaListRequest = struct {
    /// 素材类型：`image` / `voice` / `video` / `file`。
    media_type: []const u8 = "image",
    /// 分页偏移。
    offset: i64 = 0,
    /// 本次拉取数量。
    count: i64 = 50,
};

/// `GetMediaList` 响应中的单条素材。
pub const MediaListItem = struct {
    media_id: []const u8 = "",
    filename: []const u8 = "",
    update_time: i64 = 0,
    /// 仅图片素材返回。
    url: []const u8 = "",
    /// 仅文件 / 视频素材返回。
    file_key: []const u8 = "",
};

/// `GetMediaList` 响应。
pub const MediaListResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    /// 当前应用素材总数。
    total_count: i64 = 0,
    item_count: i64 = 0,
    item: []MediaListItem = &.{},
};

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 struct
// ─────────────────────────────────────────────────────────────────────────────

/// 素材管理子模块。
pub const Material = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// 通过 `Context` 与 `allocator` 构造实例。
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 上传临时素材（当前仅支持图片）。
    ///
    /// `file_path` 是本地图片路径；`filename`（可选）控制 multipart 中的
    /// `filename=` 字段，缺省时使用路径最后一段。
    pub fn upload(
        self: *Self,
        media_type: MediaType,
        file_path: []const u8,
        filename: ?[]const u8,
    ) !UploadResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}&type={s}",
            .{ uploadTempFileURL, access_token, media_type.wire() },
        );
        defer self.allocator.free(uri);

        const effective_filename = filename orelse defaultFilename(file_path);

        const fields = [_]util_http.MultipartField{
            .{
                .is_file = true,
                .field_name = "media",
                .filename = effective_filename,
                .value = "",
                .file_path = file_path,
            },
        };

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postMultipart(uri, &fields);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(UploadResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 拉取永久素材列表。
    ///
    /// 对应 WeWork `/cgi-bin/material/get_materiallist` 接口。
    /// `req.media_type` 决定列表类型，`req.offset` / `req.count` 控制分页。
    pub fn getMediaList(self: *Self, req: MediaListRequest) !MediaListResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}",
            .{ getMaterialListURL, access_token },
        );
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"type\":\"{s}\",\"offset\":{d},\"count\":{d}}}",
            .{ req.media_type, req.offset, req.count },
        );
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(MediaListResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助
// ─────────────────────────────────────────────────────────────────────────────

/// 从 `file_path` 末段截取默认 filename（如 `/tmp/foo.png` → `foo.png`）。
fn defaultFilename(file_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |idx| {
        return file_path[idx + 1 ..];
    }
    return file_path;
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

test "Material.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .corp_id = "ww-mat" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const m = Material.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("ww-mat", m.ctx.config.corp_id);
}

test "MediaType.wire 序列化为小写字符串" {
    try std.testing.expectEqualStrings("image", MediaType.image.wire());
    try std.testing.expectEqualStrings("voice", MediaType.voice.wire());
    try std.testing.expectEqualStrings("video", MediaType.video.wire());
    try std.testing.expectEqualStrings("file", MediaType.file.wire());
}

test "UploadResponse 默认值" {
    const r = UploadResponse{};
    try std.testing.expectEqualStrings("", r.media_id);
    try std.testing.expectEqual(@as(i64, 0), r.created_at);
    try std.testing.expectEqualStrings("", r.type);
}

test "MediaListRequest 默认值" {
    const r = MediaListRequest{};
    try std.testing.expectEqualStrings("image", r.media_type);
    try std.testing.expectEqual(@as(i64, 0), r.offset);
    try std.testing.expectEqual(@as(i64, 50), r.count);
}

test "MediaListItem 默认值" {
    const i = MediaListItem{};
    try std.testing.expectEqualStrings("", i.media_id);
    try std.testing.expectEqual(@as(i64, 0), i.update_time);
}

test "MediaListResponse 默认值" {
    const r = MediaListResponse{};
    try std.testing.expectEqual(@as(i64, 0), r.total_count);
    try std.testing.expectEqual(@as(usize, 0), r.item.len);
}

test "defaultFilename 正确截取末段" {
    try std.testing.expectEqualStrings("foo.png", defaultFilename("/tmp/foo.png"));
    // 没有 '/' 时整串返回。
    try std.testing.expectEqualStrings("plain.jpg", defaultFilename("plain.jpg"));
    // 含 '/' 时只取最后一段（Windows 风格路径同样适用）。
    try std.testing.expectEqualStrings("b.png", defaultFilename("a/b.png"));
}
