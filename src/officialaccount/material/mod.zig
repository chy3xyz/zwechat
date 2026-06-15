//! officialaccount/material — 素材管理
//!
//! 对应 `_ref/wechat/officialaccount/material/material.go`：永久素材（图文 / 图片 / 语音 / 视频）的 CRUD。
//! 主要 API：AddNews / UpdateNews / DeleteMaterial / GetMaterialCount / BatchGetMaterial / GetNews。

const std = @import("std");
const Context = @import("../context.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const PermanentMaterialType = enum {
    image,
    video,
    voice,
    news,
};

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
    news_item: []Article = &.{},
    update_time: i64 = 0,
    create_time: i64 = 0,
};

pub const ArticleList = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    total_count: i64 = 0,
    item_count: i64 = 0,
    item: []ArticleListItem = &.{},
};

pub const Material = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 新增永久图文素材（POST JSON）。返回微信分配的 media_id。
    pub fn addNews(self: *Self, articles: []const Article) ![]const u8 {
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
        }, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return self.allocator.dupe(u8, parsed.value.media_id);
    }

    /// 删除永久素材。
    pub fn deleteMaterial(self: *Self, media_id: []const u8) !void {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ delMaterialURL, access_token });
        defer self.allocator.free(uri);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"media_id\":\"{s}\"}}", .{media_id});
        defer self.allocator.free(body);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body);
        defer self.allocator.free(resp);

        if (try util_error.decodeWithCommonError(self.allocator, resp, "DeleteMaterial")) |_| {
            return util_error.WechatError.ApiError;
        }
    }

    /// 获取素材总数。
    pub fn getMaterialCount(self: *Self) !ResMaterialCount {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(self.allocator, "{s}?access_token={s}", .{ getMaterialCountURL, access_token });
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const body = try client.get(uri);
        defer self.allocator.free(body);

        var parsed = std.json.parseFromSlice(ResMaterialCount, self.allocator, body, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }

    /// 批量获取素材列表。
    pub fn batchGetMaterial(self: *Self, mtype: PermanentMaterialType, offset: i64, count: i64) !ArticleList {
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

        var parsed = std.json.parseFromSlice(ArticleList, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
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
        inline for (.{
            .{ "title", &a.title },
            .{ "thumb_media_id", &a.thumb_media_id },
            .{ "author", &a.author },
            .{ "digest", &a.digest },
            .{ "content", &a.content },
            .{ "content_source_url", &a.content_source_url },
        }) |pair| {
            const k: []const u8 = pair[0];
            const v: *const []const u8 = pair[1];
            if (v.len == 0) continue;
            if (!first) try buf.append(allocator, ',');
            try buf.writer.print("\"{s}\":\"", .{k});
            try appendJsonString(allocator, buf, v.*);
            try buf.append(allocator, '"');
            first = false;
        }
        try buf.append(allocator, '}');
    }

    fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => try buf.append(allocator, c),
            }
        }
    }
};

pub const addNewsURL = "https://api.weixin.qq.com/cgi-bin/material/add_news";
pub const updateNewsURL = "https://api.weixin.qq.com/cgi-bin/material/update_news";
pub const addMaterialURL = "https://api.weixin.qq.com/cgi-bin/material/add_material";
pub const delMaterialURL = "https://api.weixin.qq.com/cgi-bin/material/del_material";
pub const getMaterialURL = "https://api.weixin.qq.com/cgi-bin/material/get_material";
pub const getMaterialCountURL = "https://api.weixin.qq.com/cgi-bin/material/get_materialcount";
pub const batchGetMaterialURL = "https://api.weixin.qq.com/cgi-bin/material/batchget_material";

test "Article 默认值" {
    const a = Article{};
    try std.testing.expectEqualStrings("", a.title);
    try std.testing.expectEqual(@as(i64, 0), a.show_cover_pic);
}

test "PermanentMaterialType 枚举" {
    try std.testing.expectEqualStrings("image", @tagName(PermanentMaterialType.image));
    try std.testing.expectEqualStrings("news", @tagName(PermanentMaterialType.news));
}