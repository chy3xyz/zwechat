// SPDX-License-Identifier: Apache-2.0
//! miniprogram/ocr — OCR 识别
//!
//! 对应 `_ref/wechat/miniprogram/ocr/ocr.go`：身份证 / 银行卡 / 行驶证 / 驾驶证 /
//! 营业执照 / 通用印刷体 OCR。`img_url` 需为已 URL 编码的图片地址。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Position = struct {
    left_top: Coordinate = .{},
    right_top: Coordinate = .{},
    right_bottom: Coordinate = .{},
    left_bottom: Coordinate = .{},
};

pub const Coordinate = struct {
    x: i64 = 0,
    y: i64 = 0,
};

pub const ImageSize = struct {
    width: i64 = 0,
    height: i64 = 0,
};

pub const ResIDCard = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    type_: []const u8 = "",
    name: []const u8 = "",
    id: []const u8 = "",
    addr: []const u8 = "",
    gender: []const u8 = "",
    nationality: []const u8 = "",
    valid_date: []const u8 = "",
};

pub const ResBankCard = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    number: []const u8 = "",
};

pub const ResDriving = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    plate_num: []const u8 = "",
    vehicle_type: []const u8 = "",
    owner: []const u8 = "",
    addr: []const u8 = "",
    use_character: []const u8 = "",
    model: []const u8 = "",
    vin: []const u8 = "",
    engine_num: []const u8 = "",
    register_date: []const u8 = "",
    issue_date: []const u8 = "",
    plate_num_b: []const u8 = "",
    record: []const u8 = "",
    passengers_num: []const u8 = "",
    total_quality: []const u8 = "",
    prepare_quality: []const u8 = "",
    overall_size: []const u8 = "",
    img_size: ImageSize = .{},
};

pub const ResDrivingLicense = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    id_num: []const u8 = "",
    name: []const u8 = "",
    sex: []const u8 = "",
    nationality: []const u8 = "",
    address: []const u8 = "",
    birth_date: []const u8 = "",
    issue_date: []const u8 = "",
    car_class: []const u8 = "",
    valid_from: []const u8 = "",
    valid_to: []const u8 = "",
    official_seal: []const u8 = "",
};

pub const ResBizLicense = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    reg_num: []const u8 = "",
    serial: []const u8 = "",
    legal_representative: []const u8 = "",
    enterprise_name: []const u8 = "",
    type_of_organization: []const u8 = "",
    address: []const u8 = "",
    type_of_enterprise: []const u8 = "",
    business_scope: []const u8 = "",
    registered_capital: []const u8 = "",
    paid_in_capital: []const u8 = "",
    valid_period: []const u8 = "",
    registered_date: []const u8 = "",
    img_size: ImageSize = .{},
};

pub const CommonItem = struct {
    pos: Position = .{},
    text: []const u8 = "",
};

pub const ResCommon = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    items: []const CommonItem = &.{},
    img_size: ImageSize = .{},
};

/// OCR 识别模块。
pub const OCR = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 身份证 OCR（`img_url` 为已 URL 编码的图片地址）。
    pub fn idCard(self: *Self, img_url: []const u8) !std.json.Parsed(ResIDCard) {
        return self.fetch("idcard", img_url, ResIDCard);
    }

    /// 银行卡 OCR。
    pub fn bankCard(self: *Self, img_url: []const u8) !std.json.Parsed(ResBankCard) {
        return self.fetch("bankcard", img_url, ResBankCard);
    }

    /// 行驶证 OCR。
    pub fn driving(self: *Self, img_url: []const u8) !std.json.Parsed(ResDriving) {
        return self.fetch("driving", img_url, ResDriving);
    }

    /// 驾驶证 OCR。
    pub fn drivingLicense(self: *Self, img_url: []const u8) !std.json.Parsed(ResDrivingLicense) {
        return self.fetch("drivinglicense", img_url, ResDrivingLicense);
    }

    /// 营业执照 OCR。
    pub fn bizLicense(self: *Self, img_url: []const u8) !std.json.Parsed(ResBizLicense) {
        return self.fetch("bizlicense", img_url, ResBizLicense);
    }

    /// 通用印刷体 OCR。
    pub fn common(self: *Self, img_url: []const u8) !std.json.Parsed(ResCommon) {
        return self.fetch("comm", img_url, ResCommon);
    }

    fn fetch(self: *Self, comptime T: type, path: []const u8, img_url: []const u8) !std.json.Parsed(T) {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/cv/ocr/{s}?img_url={s}&access_token={s}",
            .{ path, img_url, access_token },
        );
        defer self.allocator.free(uri);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.post(uri, "", null);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(T, self.allocator, resp, .{ .allocate = .alloc_always }) catch {
            return util_error.WechatError.DecodeError;
        };
        errdefer parsed.deinit();
        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed;
    }
};

test "OCR.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-ocr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const o = OCR.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-ocr", o.ctx.config.app_id);
}

test "ResIDCard 默认值" {
    const r = ResIDCard{};
    try std.testing.expectEqualStrings("", r.name);
    try std.testing.expectEqual(@as(i64, 0), r.errcode);
}
