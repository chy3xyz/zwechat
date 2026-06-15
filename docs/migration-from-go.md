# 从 Go SDK 迁移到 Zig

本文档帮助已经有 [`silenceper/wechat`](https://github.com/silenceper/wechat) Go SDK 使用经验的同学把代码迁移到 `zwechat`。

> **`zwechat` 严格遵循 Go 版的 API 形状**：调用方改语言时**不需要**重新设计业务流程，只是把 Go 语法翻译成 Zig 语法。

---

## 1. 速查对照表

### 1.1 基础类型

| Go | Zig | 备注 |
|---|---|---|
| `string` | `[]const u8` | 不带长度，调用方负责 free |
| `int64` | `i64` | 直接对应 |
| `*Config` | `Config` (值类型) | Zig 默认栈分配；如要共享则显式 `*const Config` |
| `*OfficialAccount` | `*OfficialAccount` | Zig 用 `*` 显式指针 |
| `interface{}` | 函数指针 + `*anyopaque` ctx | 见下文 §2 |
| `error` | `error{...}!T` | 显式错误集 |
| `context.Context` | 省略 / `std.Io` runtime | 见 §3 |
| `sync.Mutex` | `SpinMutex`（自实现）| 见 [architecture.md §2.6](architecture.md) |

### 1.2 调用范式

| Go 模式 | Zig 模式 |
|---|---|
| `cfg := config.NewConfig(...)` | `const cfg = Config{ .app_id = "...", ... };` |
| `wc := wechat.NewWechat()` | `var wc = Wechat.init();` |
| `wc.SetCache(cache.NewMemory())` | `wc.setCache(cache.Memory.create(alloc).asCache());` |
| `oa := wc.GetOfficialAccount(cfg)` | `const oa = OfficialAccount.init(ctx);` |
| `tok, err := oa.GetAccessToken()` | `const tok = try oa.getAccessToken(allocator); defer allocator.free(tok);` |
| `resp, err := oa.GetMenu()` | `const resp = try oa.menu.getMenu(); defer allocator.free(resp.menu.button[0].name); ...` |

### 1.3 错误处理

| Go | Zig |
|---|---|
| `if err != nil { return err }` | `try fn();` |
| `v, err := fn(); if err != nil { ... }` | `const v = try fn();` 或 `if (fn()) \|v\| { ... } else \|err\| { ... }` |
| `errors.Is(err, ErrFoo)` | `switch (err) { error.Foo => ..., else => ... }` |
| `panic("oops")` | `@panic("oops");` |

---

## 2. interface → 函数指针 + 不透明 ctx

Go 的核心抽象是 `interface{}`。`zwechat` 全部用**函数指针表**实现：

### 2.1 Go 版（Cache）

```go
type Cache interface {
    Get(key string) (interface{}, error)
    Set(key string, val interface{}, ttl int64) error
    // ...
}

type Memory struct {
    sync.Mutex
    data map[string]interface{}
}

func (m *Memory) Get(key string) (interface{}, error) {
    m.Lock()
    defer m.Unlock()
    return m.data[key], nil
}
```

### 2.2 Zig 版（Cache）

```zig
pub const Cache = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ctx: *anyopaque, key: []const u8) CacheError!?[]const u8,
        set: *const fn (ctx: *anyopaque, key: []const u8, val: []const u8, ttl_seconds: i64) CacheError!void,
        // ...
    };

    pub fn get(self: Cache, key: []const u8) CacheError!?[]const u8 {
        return self.vtable.get(self.ctx, key);
    }
};

// Memory 实现：
pub const Memory = struct {
    data: std.HashMap([]const u8, []const u8, ...),

    pub fn asCache(self: *Memory) Cache {
        return .{ .ctx = @ptrCast(self), .vtable = &memory_vtable };
    }
};

const memory_vtable = Cache.VTable{
    .get = memoryGet,
    .set = memorySet,
    // ...
};

fn memoryGet(ctx: *anyopaque, key: []const u8) CacheError!?[]const u8 {
    const self: *Memory = @ptrCast(@alignCast(ctx));
    // ...
}
```

**好处**：调用方拿到的 `Cache` 值是 **值类型**（两个指针 + vtable 指针），可以自由传递而不用担心生命周期。

---

## 3. context.Context → 省略 / std.Io

Go 的所有 SDK 方法都接受 `context.Context`（带超时、取消、trace ID）。Zig 没有对应的统一抽象。`zwechat` 的处理策略：

### 3.1 普通方法：省略 context 参数

```zig
// Go
func (oa *OfficialAccount) GetMenu() (*MenuResponse, error)

// Zig
pub fn getMenu(self: *Self) !ResMenu {
    // ...
}
```

如果业务需要超时，由调用方在外层用 `std.Io` 或单独的超时包装器处理。

### 3.2 可取消操作：暂时不支持

`zwechat` 当前**不**支持 Go 风格的 `context.WithCancel`。如果需要：

- 用 `std.atomic.Value(bool)` 作为"取消标志位"，handler 定期检查；
- 或在外层 HTTP client 上设置超时。

### 3.3 trace / metric 集成

Go 版通常把 trace / metric 集成到 context 里。Zig 端推荐：

- 用 comptime 参数化 logger 注入；
- 或在 vtable 里加 `trace` 函数指针。

---

## 4. 命名风格迁移

| Go | Zig |
|---|---|
| `AccessToken` | `accessToken` / `AccessToken` |
| `AppID` | `app_id` (snake_case) |
| `OfficialAccount` | `OfficialAccount` (PascalCase) |
| `MessageType` | `MsgType` (enum 简写) |
| `NewConfig()` | `Config{}` (literal init) |

---

## 5. 完整示例对照：创建一个菜单

### Go 版

```go
package main

import (
    "fmt"
    "github.com/silenceper/wechat/v2/cache"
    "github.com/silenceper/wechat/v2/officialaccount"
    "github.com/silenceper/wechat/v2/officialaccount/config"
)

func main() {
    memCache := cache.NewMemory()
    cfg := &config.Config{
        AppID:     "wx_app_id",
        AppSecret: "secret",
        Cache:     memCache,
    }
    wc := officialaccount.NewOfficialAccount(cfg)

    buttons := []*officialaccount.Button{
        {Type: "click", Name: "今日歌曲", Key: "V1001_TODAY_MUSIC"},
        {Type: "view",  Name: "搜索",     URL: "http://www.soso.com/"},
    }
    if err := wc.GetMenu().SetMenu(buttons); err != nil {
        fmt.Println("err:", err)
    }
}
```

### Zig 版

```zig
const std = @import("std");
const zwechat = @import("zwechat");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var mem = try zwechat.cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }

    const cfg = zwechat.officialaccount.Config{
        .app_id = "wx_app_id",
        .app_secret = "secret",
        .cache = mem.asCache(),
    };
    const ctx = zwechat.officialaccount.Context{
        .config = cfg,
        .access_token_handle = zwechat.credential.DefaultAccessToken
            .init(cfg.app_id, cfg.app_secret, zwechat.credential.CacheKeyOfficialAccountPrefix, mem.asCache())
            .asHandle(),
    };
    const oa = zwechat.officialaccount.OfficialAccount.init(ctx);

    const buttons = [_]zwechat.officialaccount.menu.Button{
        zwechat.officialaccount.menu.Button.setClick("今日歌曲", "V1001_TODAY_MUSIC"),
        zwechat.officialaccount.menu.Button.setView("搜索", "http://www.soso.com/"),
    };
    var fbabuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fbabuf);
    const menu = zwechat.officialaccount.menu.Menu.init(oa.getContext(), fba.allocator());
    try menu.setMenu(&buttons);
}
```

### 关键差异

| 项 | Go | Zig |
|---|---|---|
| cache 创建 | `cache.NewMemory()` 返回指针 | `Memory.create(allocator)` 返回堆指针；用 `asCache()` 拿 vtable 句柄 |
| 错误处理 | `if err != nil` | `try` |
| 内存 | GC | 显式 `defer allocator.destroy(mem)` |
| context.Context | 第一参数 | 省略 |
| menu 子模块 | `wc.GetMenu()` | `Menu.init(oa.getContext(), allocator)` |

---

## 6. 测试代码迁移

### Go 版

```go
func TestOfficialAccount_GetMenu(t *testing.T) {
    wc := officialaccount.NewOfficialAccount(cfg)
    menu := wc.GetMenu()
    resp, err := menu.GetMenu()
    if err != nil {
        t.Fatal(err)
    }
    if resp.Menu.Button[0].Name != "今日歌曲" {
        t.Errorf("expected 今日歌曲, got %s", resp.Menu.Button[0].Name)
    }
}
```

### Zig 版（用 MockTransport）

```zig
test "Menu.getMenu 解析响应" {
    const allocator = std.testing.allocator;

    var mock = zwechat.util.http.MockTransport.init(allocator);
    defer mock.deinit();

    try mock.addRoute(
        "https://api.weixin.qq.com/cgi-bin/menu/get?access_token=fake_tok",
        .{ .body = "{\"menu\":{\"button\":[{\"name\":\"今日歌曲\"}]}}" },
    );

    var client = zwechat.util.http.HttpClient.init(allocator);
    defer client.deinit();
    client.setTransport(zwechat.util.http.MockTransport.dispatch, @ptrCast(&mock));

    // 走 cache 命中 fake token，避免真实 HTTP 拉取 access_token
    var mem = try zwechat.cache.Memory.create(allocator);
    defer {
        mem.deinit();
        allocator.destroy(mem);
    }
    try mem.asCache().set("gowechat_officialaccount_access_token_wx_test", "fake_tok", 7000);

    const cfg = zwechat.officialaccount.Config{
        .app_id = "wx_test",
        .app_secret = "sec",
        .cache = mem.asCache(),
    };
    const ctx = zwechat.officialaccount.Context{
        .config = cfg,
        .access_token_handle = zwechat.credential.DefaultAccessToken
            .init(cfg.app_id, cfg.app_secret, zwechat.credential.CacheKeyOfficialAccountPrefix, mem.asCache())
            .asHandle(),
    };
    var fba = std.heap.FixedBufferAllocator.init(&[_]u8{} ** 4096);
    const menu = zwechat.officialaccount.menu.Menu.init(&ctx, fba.allocator());

    const resp = try menu.getMenu();
    try std.testing.expectEqualStrings("今日歌曲", resp.menu.button[0].name);
}
```

**关键**：MockTransport 让测试 100% 离线运行，CI 不依赖任何网络。

---

## 7. 性能取舍

| 维度 | Go | Zig |
|---|---|---|
| 启动时间 | ~30ms | ~5ms |
| 单实例内存 | ~20MB（runtime + GC）| ~1MB |
| 一次请求的 CPU | 中 | 低 |
| 编译产物大小 | ~10MB | ~500KB（静态）|

**结论**：Zig 适合**长跑 + 高并发 + 低内存**的服务端场景。

---

## 8. 不兼容项（已知差异）

1. **context.Context**：Zig 版省略；如需取消语义，需调用方自行包装。
2. **goroutine / channel**：Zig 用 `std.Thread` + `std.atomic` + 自旋锁模拟；无 channel，需要用 MPSC queue 等模式。
3. **defer / recover**：Zig 的 `defer` 不支持 recover（无 panic 恢复），需 `try` + `errdefer` 替代。
4. **reflect / runtime type info**：Zig 有 comptime，但不像 Go 那样支持任意类型的运行时反射；vtable 设计需要预先定义接口。
5. **RSA 签名**：Zig 0.17 标准库暂无 RSA，需 vendor；Ed25519 已可用。

---

## 9. 进一步参考

- [`architecture.md`](architecture.md) — 完整设计模式说明
- [`api-reference.md`](api-reference.md) — 公共 API 索引
- [`_ref/wechat/doc/api/*.md`](../_ref/wechat/doc/api/) — 上游 Go 接口清单（移植时优先对照）