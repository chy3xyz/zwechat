# OpenPlatform component access token and account bind/unbind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the OpenPlatform `component_access_token` fetch/cache flow and wire `Account.bind`/`unbind` to the real WeChat endpoints.

**Architecture:** Create `src/openplatform/context/access_token.zig` with the token helper, expose it through `Context.getComponentAccessToken`, and update `Account` to fetch a token via `verify_ticket` before calling `/cgi-bin/open/bind` and `/cgi-bin/open/unbind`.

**Tech Stack:** Zig 0.17, existing `src/cache/mod.zig`, `src/util/http.zig`, `src/util/error.zig`.

---

## File Structure

- Create: `src/openplatform/context/access_token.zig`
- Modify: `src/openplatform/context/mod.zig`
- Modify: `src/openplatform/account/mod.zig`
- Modify: `src/test_runner.zig` — force import the new access_token module.

## Task 1: Create the component access token helper

**Files:**
- Create: `src/openplatform/context/access_token.zig`

- [ ] **Step 1: Write the module**

```zig
//! openplatform/context/access_token — component_access_token 获取与缓存
//!
//! 对应 `_ref/wechat/openplatform/context/accessToken.go`：
//! 用 `component_verify_ticket` 换取 `component_access_token`，并在 cache 中缓存。

const std = @import("std");
const Context = @import("mod.zig").Context;
const cache_mod = @import("../../cache/mod.zig");
const util_http = @import("../../util/http.zig");
const util_error = @import("../../util/error.zig");

pub const Error = error{
    VerifyTicketRequired,
    CacheUnavailable,
} || util_error.WechatError || cache_mod.CacheError || std.json.ParseFromSliceError || std.fmt.AllocPrintError || std.mem.Allocator.Error;

const TokenResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
    component_access_token: []const u8 = "",
    expires_in: i64 = 0,
};

/// 获取 component_access_token。
///
/// 1. 以 `openplatform_component_access_token_{app_id}` 为 key 查缓存。
/// 2. 未命中时调用 `https://api.weixin.qq.com/cgi-bin/component/api_component_token`。
/// 3. 写入缓存 TTL 7000 秒（微信默认 7200 秒，预留 200 秒缓冲）。
///
/// 返回的 token 由调用方负责 `allocator.free`。
pub fn getComponentAccessToken(
    ctx: *Context,
    allocator: std.mem.Allocator,
    verify_ticket: []const u8,
) Error![]u8 {
    if (verify_ticket.len == 0) return error.VerifyTicketRequired;
    const cache_inst = ctx.config.cache orelse return error.CacheUnavailable;

    const cache_key = try std.fmt.allocPrint(
        allocator,
        "openplatform_component_access_token_{s}",
        .{ctx.config.app_id},
    );
    defer allocator.free(cache_key);

    if (try cache_inst.get(cache_key)) |cached| {
        return allocator.dupe(u8, cached);
    }

    const body_json = try std.fmt.allocPrint(
        allocator,
        "{{\"component_appid\":\"{s}\",\"component_appsecret\":\"{s}\",\"component_verify_ticket\":\"{s}\"}}",
        .{ ctx.config.app_id, ctx.config.app_secret, verify_ticket },
    );
    defer allocator.free(body_json);

    const client = util_http.getDefaultClient(allocator);
    const resp = try client.postJSON(
        "https://api.weixin.qq.com/cgi-bin/component/api_component_token",
        body_json,
    );
    defer allocator.free(resp);

    var parsed = std.json.parseFromSlice(TokenResponse, allocator, resp, .{}) catch {
        return util_error.WechatError.DecodeError;
    };
    defer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
    if (parsed.value.component_access_token.len == 0) return util_error.WechatError.ApiError;

    const token = try allocator.dupe(u8, parsed.value.component_access_token);
    errdefer allocator.free(token);
    try cache_inst.set(cache_key, token, 7000);
    return token;
}

test "component token helper 需要 verify_ticket" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    const result = getComponentAccessToken(&ctx, std.testing.allocator, "");
    try std.testing.expectError(error.VerifyTicketRequired, result);
}
```

- [ ] **Step 2: Build check**

Run: `zig build test`
Expected: PASS (module not yet imported).

## Task 2: Expose `getComponentAccessToken` on `Context`

**Files:**
- Modify: `src/openplatform/context/mod.zig`

- [ ] **Step 1: Add the method**

Inside `pub const Context = struct { ... }`:

```zig
/// 获取或刷新 component_access_token。
///
/// `verify_ticket` 是微信第三方平台推送的「票据」，每次换取 token 时必填。
/// 结果会写入 `config.cache`；命中缓存时直接返回。
pub fn getComponentAccessToken(
    self: *Context,
    allocator: std.mem.Allocator,
    verify_ticket: []const u8,
) ![]u8 {
    return @import("access_token.zig").getComponentAccessToken(self, allocator, verify_ticket);
}
```

- [ ] **Step 2: Add test**

Append to the tests section:

```zig
test "Context.getComponentAccessToken 需要 cache" {
    var ctx = Context{
        .config = .{ .app_id = "wx-op", .app_secret = "s" },
    };
    const result = ctx.getComponentAccessToken(std.testing.allocator, "ticket");
    try std.testing.expectError(error.CacheUnavailable, result);
}
```

- [ ] **Step 3: Build check**

Run: `zig build test`
Expected: PASS (access_token module still not imported by `test_runner`).

## Task 3: Implement `Account.bind`/`unbind`

**Files:**
- Modify: `src/openplatform/account/mod.zig`

- [ ] **Step 1: Add `CommonResponse` and update signatures**

Add after `OpenAccountResponse`:

```zig
const CommonResponse = struct {
    errcode: i64 = 0,
    errmsg: []const u8 = "",
};
```

Update `bind` and `unbind` signatures:

```zig
/// 将公众号 / 小程序绑定到开放平台账号。
///
/// `verify_ticket` 用于换取 component_access_token。
pub fn bind(
    self: *Self,
    app_id: []const u8,
    open_app_id: []const u8,
    verify_ticket: []const u8,
) !void {
    const token = try self.ctx.getComponentAccessToken(self.allocator, verify_ticket);
    defer self.allocator.free(token);

    const uri = try std.fmt.allocPrint(
        self.allocator,
        "https://api.weixin.qq.com/cgi-bin/open/bind?component_access_token={s}",
        .{token},
    );
    defer self.allocator.free(uri);

    const body_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"appid\":\"{s}\",\"open_appid\":\"{s}\"}}",
        .{ app_id, open_app_id },
    );
    defer self.allocator.free(body_json);

    const client = util_http.getDefaultClient(self.allocator);
    const resp = try client.postJSON(uri, body_json);
    defer self.allocator.free(resp);

    var parsed = std.json.parseFromSlice(CommonResponse, self.allocator, resp, .{}) catch {
        return util_error.WechatError.DecodeError;
    };
    defer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
}

/// 将公众号 / 小程序从开放平台账号解绑。
pub fn unbind(
    self: *Self,
    app_id: []const u8,
    open_app_id: []const u8,
    verify_ticket: []const u8,
) !void {
    const token = try self.ctx.getComponentAccessToken(self.allocator, verify_ticket);
    defer self.allocator.free(token);

    const uri = try std.fmt.allocPrint(
        self.allocator,
        "https://api.weixin.qq.com/cgi-bin/open/unbind?component_access_token={s}",
        .{token},
    );
    defer self.allocator.free(uri);

    const body_json = try std.fmt.allocPrint(
        self.allocator,
        "{{\"appid\":\"{s}\",\"open_appid\":\"{s}\"}}",
        .{ app_id, open_app_id },
    );
    defer self.allocator.free(body_json);

    const client = util_http.getDefaultClient(self.allocator);
    const resp = try client.postJSON(uri, body_json);
    defer self.allocator.free(resp);

    var parsed = std.json.parseFromSlice(CommonResponse, self.allocator, resp, .{}) catch {
        return util_error.WechatError.DecodeError;
    };
    defer parsed.deinit();

    if (parsed.value.errcode != 0) return util_error.WechatError.ApiError;
}
```

- [ ] **Step 2: Update the skeleton-behavior test**

The existing test `bind / unbind 维持骨架语义（返回 ApiError）` will now fail because `bind`/`unbind` no longer return `ApiError` immediately. Replace it with:

```zig
test "bind / unbind 无 cache 返回 CacheUnavailable" {
    var ctx: Context = .{ .config = .{ .app_id = "wx-op" } };
    var a = Account.init(&ctx, std.heap.page_allocator);
    try std.testing.expectError(error.CacheUnavailable, a.bind("wx-target", "wx-open", "ticket"));
    try std.testing.expectError(error.CacheUnavailable, a.unbind("wx-target", "wx-open", "ticket"));
}
```

- [ ] **Step 3: Build check**

Run: `zig build test`
Expected: PASS.

## Task 4: Force import and commit

**Files:**
- Modify: `src/test_runner.zig`

- [ ] **Step 1: Add import**

Add with the other module imports:

```zig
_ = @import("openplatform/context/access_token.zig");
```

- [ ] **Step 2: Build check**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/openplatform/context/mod.zig src/openplatform/context/access_token.zig src/openplatform/account/mod.zig src/test_runner.zig
git commit -m "feat(openplatform): component access token + account bind/unbind"
```

## Verification

Run: `zig build test`
Expected: all tests pass, zero leaks.
