// SPDX-License-Identifier: Apache-2.0
//! work/material — 素材管理
//!
//! 对应 `_ref/wechat/work/material/`：实现临时素材（图片 / 语音 / 视频 / 文件）
//! 的 `Upload` 与 `GetTempFile`（下载，跟随 302 到 CDN）。
//!
//! - `Upload` 走 `multipart/form-data`，使用 `util.http.HttpClient.postMultipart`。
//!   当前只支持图片（`media_type = "image"`），对应上游 `UploadTempFile` 的
//!   `type=image` 形态。
//!
//! 注意：`/cgi-bin/material/get_materiallist` 端点在企业微信中**不存在**，
//! 早期版本实现的 `GetMediaList` 已删除。拉取素材列表请使用
//! `work.getKf()` 或官方实际提供的接口。

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

/// 获取临时素材（media/get，302 到 CDN）。
/// 完整 URL：`https://qyapi.weixin.qq.com/cgi-bin/media/get?access_token=...&media_id=...`。
pub const getTempFileURL = "https://qyapi.weixin.qq.com/cgi-bin/media/get";

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
    /// 上传时间戳（秒）。微信返回的是**字符串**（如 `"1380000000"`），
    /// 因此这里用 `[]const u8` 承接（与 Go 参考 `media.go` 的 string 一致）。
    created_at: []const u8 = "",
    /// 媒体类型（image / voice / video / file）。
    type: []const u8 = "",
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
    ) !std.json.Parsed(UploadResponse) {
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

        var parsed = std.json.parseFromSlice(UploadResponse, self.allocator, resp, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }

    /// 获取临时素材（对照 Go `GetTempFile`，`media/get`）。
    ///
    /// 微信会 302 到 CDN，内部走 `HttpClient.getFollowRedirect` 手动跟随。
    /// 若响应是 JSON 错误体（如 media_id 无效）返回 `WechatError.ApiError`；
    /// 返回的字节由调用方负责 `free`。
    pub fn getTempFile(self: *Self, media_id: []const u8) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "{s}?access_token={s}&media_id={s}",
            .{ getTempFileURL, access_token, media_id },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.getFollowRedirect(uri);
        defer self.allocator.free(resp);

        return self.allocator.dupe(u8, try util_error.handleFileResponse(resp, "GetTempFile"));
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

test "UploadResponse 默认值（created_at 为字符串）" {
    const r = UploadResponse{};
    try std.testing.expectEqualStrings("", r.media_id);
    try std.testing.expectEqualStrings("", r.created_at);
    try std.testing.expectEqualStrings("", r.type);
}

test "defaultFilename 正确截取末段" {
    try std.testing.expectEqualStrings("foo.png", defaultFilename("/tmp/foo.png"));
    // 没有 '/' 时整串返回。
    try std.testing.expectEqualStrings("plain.jpg", defaultFilename("plain.jpg"));
    // 含 '/' 时只取最后一段（Windows 风格路径同样适用）。
    try std.testing.expectEqualStrings("b.png", defaultFilename("a/b.png"));
}

// ── Mock transport 测试 ──────────────────────────────────────────────────────

const StubToken = struct {
    fn getToken(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, "token-abc");
    }
};
const token_vtable = @import("../../credential/mod.zig").AccessTokenHandle.VTable{ .getAccessToken = StubToken.getToken };

test "upload 解析字符串 created_at" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    // multipart 需要真实读取文件内容，先用临时文件承载。
    const tmp_path = "zwechat_mat_upload_test.bin";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    }
    try file.writePositionalAll(io, "fake-image-bytes", 0);

    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/media/upload?access_token=token-abc&type=image", .{
        .body = "{\"errcode\":0,\"errmsg\":\"ok\",\"type\":\"image\",\"media_id\":\"MEDIA_ID_123\",\"created_at\":\"1380000000\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx: Context = .{
        .config = .{ .corp_id = "ww-mat" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = Material.init(&ctx, allocator);
    var parsed = try m.upload(.image, tmp_path, "pic.png");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("MEDIA_ID_123", parsed.value.media_id);
    try std.testing.expectEqualStrings("1380000000", parsed.value.created_at);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}

test "getTempFile 经 mock transport 拿到二进制内容" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/media/get?access_token=token-abc&media_id=MEDIA_DL_9", .{
        .body = "\x89PNG\r\n\x1a\nwork-media-bytes",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx: Context = .{
        .config = .{ .corp_id = "ww-mat" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = Material.init(&ctx, allocator);
    const data = try m.getTempFile("MEDIA_DL_9");
    defer allocator.free(data);

    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nwork-media-bytes", data);
    try std.testing.expectEqual(@as(usize, 1), mt.history.items.len);
}

test "getTempFile JSON 错误体返回 ApiError" {
    const allocator = std.testing.allocator;
    var mt = util_http.MockTransport.init(allocator);
    defer mt.deinit();
    try mt.addRoute("https://qyapi.weixin.qq.com/cgi-bin/media/get?access_token=token-abc&media_id=BAD", .{
        .body = "{\"errcode\":40007,\"errmsg\":\"invalid media_id\"}",
    });

    const client = util_http.getDefaultClient(allocator);
    client.setTransport(util_http.MockTransport.dispatch, @ptrCast(&mt));
    defer {
        client.setTransport(null, null);
        util_http.deinitDefaultClient();
    }

    var ctx: Context = .{
        .config = .{ .corp_id = "ww-mat" },
        .access_token_handle = .{ .ptr = undefined, .vtable = &token_vtable },
    };
    var m = Material.init(&ctx, allocator);
    try std.testing.expectError(util_error.WechatError.ApiError, m.getTempFile("BAD"));
}
