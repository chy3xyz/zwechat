# Contributing to zwechat

感谢你愿意为 `zwechat` 做贡献！本文档说明开发流程、命名约定、测试规范与提交规范。

## 开发环境

| 工具 | 版本要求 |
|---|---|
| Zig | ≥ 0.17.0（项目在 `0.17.0-dev.813+2153f8143` 上构建通过）|
| Git | 任意版本 |
| 编辑器 | 任意；推荐 VSCode + Zig Language Server，或 `zls` |

```bash
# 检查 Zig 版本
zig version

# 克隆仓库
git clone https://github.com/your-org/zwechat.git
cd zwechat

# 验证构建 + 测试都通过
zig build && zig build test
# 期望：260/260 tests passed, 0 leaks
```

## 项目布局

```
src/                                # Zig 实现（勿手动 chmod +x）
├── <business>/<sub>/mod.zig        # 每个子模块对应 `_ref/wechat/<...>/<...>.go`
├── test_runner.zig                 # 测试编译门：所有新模块必须在 `@import` 列表中追加
└── integration_test.zig            # 端到端集成测试

_ref/wechat/                        # 上游 Go 参考（**只读，不要修改**）
docs/                               # 用户文档
AGENTS.md                           # AI Agent 项目导引
```

## 命名约定

| 构造 | 约定 | 示例 |
|---|---|---|
| 源文件 | `snake_case.zig` | `access_token.zig` |
| 结构体 / 枚举 / 联合 | `PascalCase` | `OfficialAccount`, `MenuType` |
| 函数 / 方法 | `camelCase` | `getAccessToken`, `postJSON` |
| 模块级常量 | `PascalCase` 或缩写 `UPPERCASE` | `CacheKeyOfficialAccountPrefix` |
| 局部变量 / 参数 | `snake_case` | `app_id`, `access_token` |
| 错误集 | `PascalCase` 以 `Error` 结尾 | `WechatError`, `CacheError` |
| 测试名 | 中文 `test "场景描述"` | `test "Menu.init 持有 ctx"` |

### `pub` vs `pub const`

- 用 `pub` 暴露**类型 / 函数 / 字段**，调用方直接使用（如 `pub fn getAccessToken`）。
- 用 `pub const` 暴露**模块内部的子模块、类型别名、常量**（如 `pub const Menu = @import("menu/mod.zig").Menu`）。
- 子模块的 `mod.zig` 文件统一以 `pub const` 形式 re-export 业务类型。

### 命名冲突

- Zig 中 `type` 是关键字，所以 Go 版 `Button.type` 在 Zig 中改为 `type_`（下划线后缀）。
- 字段顺序：**字段先声明 → 内部类型后声明 → 方法最后**。
- 避免在字段之间插入 `const` / `fn` 等声明（Zig 0.17-dev 要求字段连续）。

## 模块依赖规则

1. **横向依赖**：`work/` 不可 `import` `officialaccount/`；反之亦然。两者都依赖 `cache/` + `credential/` + `util/`。
2. **`test_runner.zig` 编译门**：每加一个新模块，必须在 `src/test_runner.zig` 的 `@import` 列表中追加一行，并在测试体的 `_ = ...` 列表中追加一行。否则 `zig build test` 不会发现该模块的 inline test。
3. **`root.zig` barrel**：在 `src/root.zig` 中以 `pub const xxx = @import(...)` 暴露给外部使用者。

## 内存管理

- **显式 Allocator**：所有 public API 接受 `std.mem.Allocator` 参数（由调用方负责生命周期）。
- **长期对象**（`Cache`、`Context`、`OfficialAccount`）必须提供 `deinit` / `destroy` 方法释放其持有的全部资源。
- **`errdefer` 链**：每个 `try X.init()` 之前的所有已分配资源必须有 `errdefer` 清理。
- **返回 slice**：当 API 返回 `[]u8` / `[]const u8` 时，文档必须明确说明所有权（调用方 `free` vs 静态借用）。

```zig
// GOOD: 调用方 free
pub fn getAccessToken(self: *Work, allocator: std.mem.Allocator) ![]u8;

// GOOD: 静态借用
pub fn getCorpId(self: *const Work) []const u8 {
    return self.ctx.config.corp_id;
}
```

## 错误处理

- 每个 public 函数声明**最窄的错误集**（`error{OutOfMemory}![]u8` 比 `anyerror![]u8` 更好）。
- 模块之间通过 `error_set_a || error_set_b` 组合。
- **不要吞错误**：`try` 不能用 `catch |_| ...` 静默失败，除非真的可以恢复。
- 提供 `deinit` 的对象在失败路径上也要保证完全释放（`errdefer`）。

## 测试规范

### 内联测试

每个模块自带 `test "..."` 块：

```zig
test "Menu.init 持有 ctx" {
    var ctx: Context = .{
        .config = .{ .app_id = "wx-test" },
        .access_token_handle = .{ .ptr = undefined, .vtable = undefined },
    };
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const m = Menu.init(&ctx, fba.allocator());
    try std.testing.expectEqualStrings("wx-test", m.ctx.config.app_id);
}
```

### 使用 `std.testing.allocator`

```zig
test "JSON parse round-trip" {
    const allocator = std.testing.allocator;  // 自动检测泄漏
    const result = try doSomething(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("...", result);
}
```

### MockTransport（HTTP 模块）

不要在测试中发起真实网络请求。使用 `util/http.zig.MockTransport` 注入预设响应：

```zig
var mock = util_http.MockTransport.init(allocator);
defer mock.deinit();
try mock.addRoute("https://api.weixin.qq.com/cgi-bin/gettoken", .{
    .body = "{\"access_token\":\"xxx\"}",
});

var client = util_http.HttpClient.init(allocator);
defer client.deinit();
client.setTransport(MockTransport.dispatch, @ptrCast(&mock));

const body = try client.get("https://api.weixin.qq.com/cgi-bin/gettoken");
defer allocator.free(body);
```

### 真实测试向量

涉及加密 / 签名 / 编码的模块，**必须**用真实测试向量（如 RFC 8032 §7.1、RSA PKCS#1 官方样例、微信支付文档示例）来验证算法实现。

```zig
test "Ed25519 用公开 RFC 8032 测试向量" {
    // RFC 8032 §7.1 Test 1
    const seed_bytes = [_]u8{ 0x9d, 0x61, ... };
    const expected_pk = [_]u8{ 0xd7, 0x5a, ... };
    ...
}
```

## 提交规范

### Commit message

```
<scope>: <subject>

<body>

<footer>
```

- `scope` 建议：模块名（`cache` / `credential` / `pay` / `work` ...），或 `build` / `ci` / `docs`
- subject 中文 / 英文均可，**不超过 50 字符**
- body 解释**为什么**，不解释**是什么**（diff 已经说明是什么）

示例：

```
pay: 修复 verifyPaidNotify 函数签名缺少 allocator 参数

原 cfg.allocator_from_caller 不存在于 Config struct，导致编译失败。
现改为显式传入 allocator，符合 zig 内存管理约定。
```

### PR checklist

- [ ] `zig build` 通过
- [ ] `zig build test` 通过（**260/260 tests, 0 leaks**）
- [ ] 新增模块已在 `src/test_runner.zig` 追加 `@import`
- [ ] 新增公共 API 都有 `///` 中文 doc 注释
- [ ] 涉及加密 / 签名 / 编解码的模块附真实测试向量
- [ ] AGENTS.md 的"目录与模块划分"小节已同步更新

## 移植规范（与上游 Go 对照）

每个 Zig 子模块**必须**对应 `_ref/wechat/` 中的某个 Go 子目录：

| Zig 路径 | Go 参考路径 |
|---|---|
| `src/officialaccount/menu/mod.zig` | `_ref/wechat/officialaccount/menu/menu.go` + `button.go` |
| `src/pay/order/mod.zig` | `_ref/wechat/pay/order/pay.go` |
| `src/work/message/mod.zig` | `_ref/wechat/work/message/*.go` |

### 翻译原则

1. **API 形态优先**：保持 Go 的 API 形状（参数顺序、可选参数、返回类型），便于跨语言用户切换。
2. **错误集显式**：Go 的 `error` 转为 Zig 的具名 error set，**不**用 `anyerror`。
3. **大写首字母 = pub**：Go 的导出符号在 Zig 中都是 `pub`。
4. **`context.Context` 参数化**：Go 的 context 参数（带取消、超时）在 Zig 中通常省略，调用方用 `std.Io` runtime 处理。如有必要，提供带可选 allocator 的变体函数。
5. **惯用结构体 vs vtable**：Go 的 `interface{}` 在 Zig 中转为函数指针 + 不透明 ctx 的 vtable struct（参见 `Cache`、`AccessTokenHandle`）。
6. **XML 编解码**：微信消息格式非常规整，参见 `util/xml.zig` 的扁平实现；不要引入完整 XML 解析器。

### 不要做

- ❌ 不要修改 `_ref/wechat/`（只读参考）。
- ❌ 不要 commit `mod.o` / `root.o` 等调试残留（已在 `.gitignore`）。
- ❌ 不要 commit `.zig-cache/` / `zig-out/` / `.codegraph/`（已在 `.gitignore`）。
- ❌ 不要写 `anyerror!T` 风格的函数签名——优先用具体 error set。
- ❌ 不要在测试中发起真实 HTTP——必须用 `MockTransport`。

## 发布流程

1. 更新 `CHANGELOG.md`：在该版本块下罗列所有新增 / 修改 / 废弃条目。
2. 更新 `build.zig.zon` 的 `.version` 字段。
3. `git tag -a vX.Y.Z -m "release notes"` 并推送。
4. 在 GitHub Releases 上创建 release，粘贴 CHANGELOG 内容。

## 联系方式

- 问题 / 建议：开 GitHub Issue
- 安全漏洞：邮件 `security@zwechat.dev`（PGP key 在仓库 `.well-known/` 下）
- 中文社区：微信群 / Discord（详见 README）

---

**Happy hacking!**