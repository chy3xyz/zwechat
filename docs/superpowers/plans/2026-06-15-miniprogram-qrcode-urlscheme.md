# MiniProgram QRCode and URLScheme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add high-value MiniProgram submodules — unlimited QR code (`wxa/getwxacodeunlimit`) and URL scheme (`wxa/generatescheme`) — and expose them through `MiniProgram`.

**Architecture:** Create `src/miniprogram/qrcode/mod.zig` and `src/miniprogram/urlscheme/mod.zig`. Re-use the existing `Context.getAccessToken` and `util_http.getDefaultClient` patterns. Update `src/miniprogram/mod.zig` with lazy-loading factories.

**Tech Stack:** Zig 0.17, existing `src/miniprogram/context/mod.zig`, `src/util/http.zig`, `src/util/error.zig`.

---

## File Structure

- Create: `src/miniprogram/qrcode/mod.zig`
- Create: `src/miniprogram/urlscheme/mod.zig`
- Modify: `src/miniprogram/mod.zig`
- Modify: `src/test_runner.zig` — force import the two new modules.

## Task 1: Create the QRCode module

**Files:**
- Create: `src/miniprogram/qrcode/mod.zig`

- [ ] **Step 1: Write the module**

```zig
//! miniprogram/qrcode — 小程序码（无数量限制）
//!
//! 对应 `_ref/wechat/miniprogram/qrcode/qrcode.go`：
//! `wxa/getwxacodeunlimit` 获取小程序码（永久有效，数量暂无限制）。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");

/// 小程序码模块。
pub const QRCode = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 获取小程序码（无数量限制）。
    ///
    /// - `scene`：最大 32 个可见字符，必填。
    /// - `page`：默认首页；可传 `null`。
    /// - `width`：二维码宽度，默认 430。
    ///
    /// 返回图片二进制切片，调用方负责 `allocator.free`。
    pub fn getUnlimited(
        self: *Self,
        scene: []const u8,
        page: ?[]const u8,
        width: u32,
    ) ![]u8 {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/getwxacodeunlimit?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body_json = if (page) |p|
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"scene\":\"{s}\",\"page\":\"{s}\",\"width\":{d}}}",
                .{ scene, p, width },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{{\"scene\":\"{s}\",\"width\":{d}}}",
                .{ scene, width },
            );
        defer self.allocator.free(body_json);

        const client = util_http.getDefaultClient(self.allocator);
        return client.postJSON(uri, body_json);
    }
};

test "QRCode.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-qr" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const q = QRCode.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-qr", q.ctx.config.app_id);
}
```

- [ ] **Step 2: Build check**

Run: `zig build test`
Expected: PASS (the module is not yet imported by `test_runner`, so add the import in Task 3).

## Task 2: Create the URLScheme module

**Files:**
- Create: `src/miniprogram/urlscheme/mod.zig`

- [ ] **Step 1: Write the module**

```zig
//! miniprogram/urlscheme — 小程序 URL Scheme
//!
//! 对应 `_ref/wechat/miniprogram/urlscheme/urlscheme.go`：
//! `wxa/generatescheme` 生成 URL Scheme。

const std = @import("std");
const Context = @import("../context/mod.zig").Context;
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

/// `wxa/generatescheme` 响应。
pub const GenerateResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    openlink: []const u8 = "",
};

/// URL Scheme 模块。
pub const URLScheme = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) Self {
        return .{ .ctx = ctx, .allocator = allocator };
    }

    /// 生成 URL Scheme。
    ///
    /// `jump_wxa_json` 为 `jump_wxa` 对象的 JSON 字符串，例如：
    /// `{"path":"pages/index","query":"a=1"}`。
    pub fn generate(self: *Self, jump_wxa_json: []const u8) !GenerateResponse {
        const access_token = try self.ctx.getAccessToken(self.allocator);
        defer self.allocator.free(access_token);

        const uri = try std.fmt.allocPrint(
            self.allocator,
            "https://api.weixin.qq.com/wxa/generatescheme?access_token={s}",
            .{access_token},
        );
        defer self.allocator.free(uri);

        const body_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jump_wxa\":{s}}}",
            .{jump_wxa_json},
        );
        defer self.allocator.free(body_json);

        const client = util_http.getDefaultClient(self.allocator);
        const resp = try client.postJSON(uri, body_json);
        defer self.allocator.free(resp);

        var parsed = std.json.parseFromSlice(GenerateResponse, self.allocator, resp, .{}) catch {
            return util_error.WechatError.DecodeError;
        };
        defer parsed.deinit();

        if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
        return parsed.value;
    }
};

test "URLScheme.init 持有 ctx 与 allocator" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-link" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    const u = URLScheme.init(&ctx, std.heap.page_allocator);
    try std.testing.expectEqualStrings("wx-link", u.ctx.config.app_id);
}
```

- [ ] **Step 2: Build check**

Run: `zig build test`
Expected: PASS (module not yet imported).

## Task 3: Expose submodules through `MiniProgram`

**Files:**
- Modify: `src/miniprogram/mod.zig`
- Modify: `src/test_runner.zig`

- [ ] **Step 1: Add imports and expose factories**

At the top of `src/miniprogram/mod.zig`, after the existing `Auth` import:

```zig
pub const qrcode = @import("qrcode/mod.zig");
pub const urlscheme = @import("urlscheme/mod.zig");
```

Inside `pub const MiniProgram = struct { ... }`:

```zig
/// 懒加载 QRCode 子模块。
pub fn getQRCode(self: *Self) qrcode.QRCode {
    return qrcode.QRCode.init(&self.ctx, self.allocator);
}

/// 懒加载 URLScheme 子模块。
pub fn getURLScheme(self: *Self) urlscheme.URLScheme {
    return urlscheme.URLScheme.init(&self.ctx, self.allocator);
}
```

- [ ] **Step 2: Add existence tests**

Append to the tests section of `src/miniprogram/mod.zig`:

```zig
test "MiniProgram 暴露 qrcode / urlscheme 工厂" {
    try std.testing.expect(@hasDecl(MiniProgram, "getQRCode"));
    try std.testing.expect(@hasDecl(MiniProgram, "getURLScheme"));
}
```

- [ ] **Step 3: Force import in `test_runner.zig`**

Add to `src/test_runner.zig` with the other module imports:

```zig
_ = @import("miniprogram/qrcode/mod.zig");
_ = @import("miniprogram/urlscheme/mod.zig");
```

- [ ] **Step 4: Build check**

Run: `zig build test`
Expected: PASS.

## Task 4: Commit

- [ ] **Step 1: Commit**

```bash
git add src/miniprogram/mod.zig src/miniprogram/qrcode/mod.zig src/miniprogram/urlscheme/mod.zig src/test_runner.zig
git commit -m "feat(miniprogram): QRCode and URLScheme modules"
```

## Verification

Run: `zig build test`
Expected: all tests pass, zero leaks.
