// SPDX-License-Identifier: Apache-2.0
//! live_probe — 可选的真实接口探针（只报告，不门禁）
//!
//! ## 为什么需要它
//!
//! 仓库内的近千条单元测试全部走 mock transport（这是刻意的，见 AGENTS.md），
//! 但微信是**外部契约**：`vaild` / `exteranalopenid` 这类官方笔误、以及上游静默
//! 改字段名的行为，只有真实调用才会暴露——mock 里的期望值是我们自己写的，
//! 它只能证明「解析器与我们的假设一致」，不能证明「假设与微信一致」。
//!
//! 本探针对一小批高频**只读**接口发真实请求，断言关键字段非空，从而在发版前
//! 发现契约漂移。
//!
//! ## 门控（重要）
//!
//! **只有**环境变量 `ZWECHAT_LIVE_PROBE` 取显式真值（`1` / `true` / `yes` / `on`，
//! 大小写不敏感、允许两侧空白）时才发请求；未设置或取其他值 → 打印提示后
//! **直接 exit 0**，一个字节都不出网。
//!
//! 本文件不参与默认构建流程：`build.zig` 不为它调用 `installArtifact`，因此
//! `zig build` / `zig build test` 既不会运行它，也不会把它塞进安装产物。
//!
//! ## 凭据（只从环境变量读，不落盘、不写日志）
//!
//! | 分组 | 变量 | 缺失时 |
//! |---|---|---|
//! | 公众号 | `ZWECHAT_OA_APPID` / `ZWECHAT_OA_APPSECRET` | 该组全部 SKIP |
//! | 企业微信 | `ZWECHAT_WORK_CORPID` / `ZWECHAT_WORK_SECRET` | 该组全部 SKIP |
//! | 小程序 | `ZWECHAT_MP_APPID` / `ZWECHAT_MP_SECRET` | 该组全部 SKIP |
//!
//! 任一 key 缺失（或仅含空白）即视为该组「未配置」→ SKIP，不报错。secret 只用于
//! 拼请求 URL，**绝不打印**；记录请求时只保留 path（`?access_token=...` 之后丢弃）。
//!
//! ## 用法
//!
//! ```bash
//! # 未启用：打印提示，exit 0
//! zig build live-probe
//!
//! # 启用（只报告，无论结果始终 exit 0）
//! ZWECHAT_LIVE_PROBE=1 ZWECHAT_OA_APPID=wx.. ZWECHAT_OA_APPSECRET=.. zig build live-probe
//!
//! # 发版前人工跑：有 FAIL 时 exit 1
//! ZWECHAT_LIVE_PROBE=1 ... zig build live-probe -Dstrict
//! ```
//!
//! ⚠️ 本工具链（0.17.0-dev.2151）的 `zig build <step> -- <args>` **不会**把 `--`
//! 之后的参数转发给被运行的进程（`std.Build` 已无 `args` 字段，实测被静默忽略），
//! 因此 strict 用构建选项 `-Dstrict` 传递，由 `build.zig` 补上 `--strict`。
//! 直接运行二进制时仍可用 `./live-probe --strict`，或用 `ZWECHAT_LIVE_PROBE_STRICT=1`。
//!
//! ## 退出码
//!
//! - 未启用 → 0；
//! - 启用但未开 strict → **始终 0**（只报告，适合人工巡检）；
//! - 启用 + strict（`-Dstrict` / `--strict` / `ZWECHAT_LIVE_PROBE_STRICT=1`）
//!   且存在 FAIL → 1。
//!
//! ## 安全 / 配额
//!
//! - 探针**会消耗真实配额**（部分接口有每日上限），请勿在 CI 常驻。
//! - FAIL 时打印原始响应体前 512 字节，便于立刻看出上游是否改了 key；
//!   该片段可能含 openid / 部门名等业务数据，粘贴到公开渠道前请自行判断。
//! - 所有探针均为只读调用，不做任何写操作。
//!
//! ## 单元测试
//!
//! 本文件**不在** `src/test_runner.zig` 的 import 图里，因此下面的 inline test
//! 不会被 `zig build test` 发现——这是刻意的：探针不该被自动跑。它们是纯逻辑
//! 测试、零网络，通过 `build.zig` 单独注册的 step 手动运行：
//!
//! ```bash
//! zig build live-probe-test
//! ```

const std = @import("std");
const zwechat = @import("zwechat");

const cache_mod = zwechat.cache;
const credential = zwechat.credential;
const officialaccount = zwechat.officialaccount;
const miniprogram = zwechat.miniprogram;
const util_error = zwechat.util.error_mod;
const util_http = zwechat.util.http;
const work_mod = zwechat.work;

// ─────────────────────────────────────────────────────────────────────────────
// 环境变量名（唯一定义处，文档与代码同源）
// ─────────────────────────────────────────────────────────────────────────────

/// 总开关：取显式真值才启用探针。
pub const GateEnv = "ZWECHAT_LIVE_PROBE";
/// 追加开关：置真值时等价于 `--strict`。
pub const StrictEnv = "ZWECHAT_LIVE_PROBE_STRICT";

pub const OaAppIdEnv = "ZWECHAT_OA_APPID";
pub const OaAppSecretEnv = "ZWECHAT_OA_APPSECRET";
pub const WorkCorpIdEnv = "ZWECHAT_WORK_CORPID";
pub const WorkSecretEnv = "ZWECHAT_WORK_SECRET";
pub const MpAppIdEnv = "ZWECHAT_MP_APPID";
pub const MpSecretEnv = "ZWECHAT_MP_SECRET";

/// FAIL 时打印的原始响应体字节数上限。
pub const RawPreviewBytes: usize = 512;

// ─────────────────────────────────────────────────────────────────────────────
// 纯逻辑：门控 / env 解析 / 判定（可离线单测）
// ─────────────────────────────────────────────────────────────────────────────

/// 只读环境变量访问器：`ctx` + 函数指针。
///
/// 与仓库其它抽象（`AccessTokenHandle` / `Cache`）保持同一风格：探针逻辑只依赖
/// 这个 6 字节接口，测试里换成一个 `StringHashMap` 适配器即可完全离线验证。
pub const EnvGet = *const fn (ctx: *anyopaque, key: []const u8) ?[]const u8;

/// 门控判定：**仅显式真值**视为启用。
///
/// 白名单而非黑名单：`ZWECHAT_LIVE_PROBE=0` / `=false` / `=off` / 未设置 / 空白，
/// 以及任何未识别的取值（如 `=maybe`）都判为「未启用」。宁可漏跑，不可误发请求。
pub fn gateEnabled(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const v = std.mem.trim(u8, raw, " \t\r\n");
    const truthy = [_][]const u8{ "1", "true", "yes", "on" };
    for (truthy) |t| {
        if (std.ascii.eqlIgnoreCase(v, t)) return true;
    }
    return false;
}

/// 读取环境变量；缺失或**仅含空白**视为「未提供」（返回 `null`）。
///
/// 空 secret 与缺失 secret 在微信侧都是 40125 invalid appsecret，提前归一化可以
/// 让「设了变量但忘了填值」也落到 SKIP 分支，而不是发一次注定失败的请求。
pub fn readEnv(env: EnvGet, ctx: *anyopaque, key: []const u8) ?[]const u8 {
    const raw = env(ctx, key) orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

/// 一对凭据。
pub const EnvPair = struct {
    a: []const u8,
    b: []const u8,
};

/// 成对读取凭据；任一项缺失即返回 `null`（调用方据此把整组探针判为 SKIP）。
pub fn readEnvPair(env: EnvGet, ctx: *anyopaque, key_a: []const u8, key_b: []const u8) ?EnvPair {
    const a = readEnv(env, ctx, key_a) orelse return null;
    const b = readEnv(env, ctx, key_b) orelse return null;
    return .{ .a = a, .b = b };
}

/// 命令行参数是否等于 `--strict`（也接受短写 `-s`）。
pub fn isStrictFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--strict") or std.mem.eql(u8, arg, "-s");
}

/// 参数列表里是否出现 strict 标志（含 `argv[0]` 也无妨，它不会匹配）。
pub fn hasStrictFlag(args: []const []const u8) bool {
    for (args) |a| {
        if (isStrictFlag(a)) return true;
    }
    return false;
}

/// 单项探针状态。
pub const Status = enum {
    pass,
    fail,
    skip,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .pass => "PASS",
            .fail => "FAIL",
            .skip => "SKIP",
        };
    }
};

/// 字段判定输入（全部来自客观事实，不含启发式打分）。
pub const FieldCheck = struct {
    /// SDK 解析出的关键字段是否非空。
    non_empty: bool,
    /// 原始响应体里是否出现该字段的 JSON key（含引号匹配）——用于区分
    /// 「上游改了字段名」与「账号本来就没数据」。
    key_present: bool,
    /// 该账号可能**合法地**返回空数据。（键在、值为空 → SKIP 而非 FAIL）
    empty_ok: bool,
    /// 该账号**根本没有可供验证的数据**（0 粉丝 / 菜单未开放），
    /// 此时键可能真的不出现在响应里，属于 SKIP 而非 FAIL。
    no_data_available: bool = false,
};

/// 把客观事实映射成 PASS / FAIL / SKIP。判定优先级：
///
/// 1. 字段非空 → PASS；
/// 2. 该账号无数据可验证 → SKIP（无法验证键名，不是失败）；
/// 3. 原始响应里连 key 都没有 → FAIL（字段名变了 / 结构变了）；
/// 4. 键在、值为空且空值可接受 → SKIP；
/// 5. 其余 → FAIL（契约要求非空却拿到空值）。
///
/// 顺序是关键：`no_data_available` 必须早于 `key_present` 判定，否则「0 粉丝」
/// 的公众号会因为 `data.openid` 不出现而被误报为 FAIL。
pub fn judgeField(c: FieldCheck) Status {
    if (c.non_empty) return .pass;
    if (c.no_data_available) return .skip;
    if (!c.key_present) return .fail;
    if (c.empty_ok) return .skip;
    return .fail;
}

/// 原始响应体里是否出现 `"key"`（**带引号**，避免 `"id"` 命中 `"openid"` 这类子串）。
///
/// 这是「上游是否改了字段名」的最低成本判据：SDK 侧 `ignore_unknown_fields = true`
/// 会把改名的字段静默解析成空值，只有回到原始报文才能分辨。
pub fn bodyHasKey(body: []const u8, key: []const u8) bool {
    if (key.len == 0 or key.len + 2 > 64) return false;
    var buf: [64]u8 = undefined;
    buf[0] = '"';
    @memcpy(buf[1 .. 1 + key.len], key);
    buf[1 + key.len] = '"';
    return std.mem.indexOf(u8, body, buf[0 .. key.len + 2]) != null;
}

/// 取前 `max` 字节，且不切裂多字节 UTF-8 序列（与 `util/error.zig` 的截断策略一致）。
pub fn preview(body: []const u8, max: usize) []const u8 {
    if (body.len <= max) return body;
    var end = max;
    while (end > 0 and (body[end] & 0xC0) == 0x80) end -= 1;
    return body[0..end];
}

/// 把控制字符（换行 / 制表 / DEL）替换成空格，避免响应体破坏表格排版。
///
/// 分配失败时原样返回输入（宁可排版难看，也不能因为日志路径 OOM 而丢掉诊断信息）。
pub fn flattenControlChars(allocator: std.mem.Allocator, text: []const u8) []const u8 {
    const out = allocator.dupe(u8, text) catch return text;
    for (out) |*c| {
        if (c.* < 0x20 or c.* == 0x7f) c.* = ' ';
    }
    return out;
}

/// 「该账号本来就不适用」类错误码：命中时判 SKIP（无法验证键名），而不是 FAIL。
///
/// 只收确实表示「不是契约问题」的码；未知码一律按 FAIL 处理——漏报比误报更危险。
pub fn isNotApplicableErrCode(errcode: i64) bool {
    return switch (errcode) {
        46003 => true, // 菜单不存在（公众号未配置自定义菜单）
        48001 => true, // api unauthorized（接口权限未开通）
        else => false,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// 请求录制：拦截默认客户端 transport，拿到「原始响应体」
// ─────────────────────────────────────────────────────────────────────────────

/// 把当前线程默认 `HttpClient` 的 transport 换成它：转发到真实网络，同时留存
/// **最近一次**响应体副本，供 FAIL 时打印前 N 字节。
///
/// 为什么挂在默认客户端上而不是各模块的 `setTransport`：`work/addresslist` 等模块
/// 没有实例级注入点（sender 直接调 `util.http.getDefaultClient`），默认客户端是唯一
/// 能覆盖全部探针的钩子。默认客户端是**线程局部**的，因此本进程的注入不会影响他人。
const Recorder = struct {
    allocator: std.mem.Allocator,
    /// 最近一次响应体副本（**含 openid 等业务数据，仅用于诊断打印**）。
    body: std.ArrayListUnmanaged(u8) = .empty,
    /// 最近一次请求 URL 的 path 部分——`?access_token=...` 之后一律丢弃，绝不落 secret。
    path: std.ArrayListUnmanaged(u8) = .empty,
    /// 已发出的 HTTP 请求数（0 说明连 token 都没取到，便于定位失败阶段）。
    calls: usize = 0,

    fn dispatch(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        uri: []const u8,
        method: std.http.Method,
        payload: []const u8,
        content_type: ?[]const u8,
    ) anyerror![]u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.recordPath(uri);
        self.calls += 1;

        // 另起一个 HttpClient 发真实请求：它没有注入 transport，不会递归回本函数。
        var client = util_http.HttpClient.init(allocator);
        defer client.deinit();

        const body = switch (method) {
            .GET => try client.get(uri),
            .POST => try client.post(uri, payload, content_type),
            else => try client.get(uri),
        };

        self.body.clearRetainingCapacity();
        // 录制失败不影响探针本身的结论：预览缺失而已。
        self.body.appendSlice(self.allocator, body) catch {};
        return body;
    }

    /// 只保留 path（丢弃 query，避免 access_token / secret 进入内存快照被打印）。
    fn recordPath(self: *Recorder, uri: []const u8) void {
        const q = std.mem.indexOfScalar(u8, uri, '?') orelse uri.len;
        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.allocator, uri[0..q]) catch {};
    }

    fn begin(self: *Recorder) void {
        self.calls = 0;
        self.body.clearRetainingCapacity();
        self.path.clearRetainingCapacity();
    }

    fn bodySlice(self: *const Recorder) []const u8 {
        return self.body.items;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 探针定义与执行
// ─────────────────────────────────────────────────────────────────────────────

/// 探针函数的返回值。
const Attempt = struct {
    /// 关键字段是否解析到非空值。
    non_empty: bool,
    /// 该账号没有可供验证的数据（探测函数自行判断，如 total == 0）。
    no_data_available: bool = false,
    /// 附加说明（命中判定时展示）。
    note: []const u8 = "",
};

const ProbeCtx = struct {
    alloc: std.mem.Allocator,
    rec: *Recorder,
    /// 具体实例指针（公众号 / 企业微信 / 小程序），由探针函数按组 `@ptrCast`。
    handle: *anyopaque,
};

const ProbeFn = *const fn (p: ProbeCtx) anyerror!Attempt;

const ProbeSpec = struct {
    /// 短名（表格列，ASCII，便于对齐）。
    name: []const u8,
    /// 接口 path（展示用）。
    endpoint: []const u8,
    /// 期望出现在原始响应体里的 JSON key（不含引号）。
    expected_key: []const u8,
    /// 该账号可能合法地返回空数组。
    empty_ok: bool,
    run_fn: ProbeFn,
};

// —— 公众号 ——

fn probeOaToken(p: ProbeCtx) anyerror!Attempt {
    const oa: *officialaccount.OfficialAccount = @ptrCast(@alignCast(p.handle));
    const token = try oa.getAccessToken(p.alloc);
    defer p.alloc.free(token);
    // access_token 字段被上游改名时，SDK 不报错而是返回空串——所以这里必须验长度。
    return .{ .non_empty = token.len > 0, .note = "access_token 非空（凭据链路可用）" };
}

fn probeOaCallbackIp(p: ProbeCtx) anyerror!Attempt {
    const oa: *officialaccount.OfficialAccount = @ptrCast(@alignCast(p.handle));
    var basic = oa.getBasic(p.alloc);
    var list = try basic.getCallbackIP();
    defer list.deinit(p.alloc);

    const first: []const u8 = if (list.items.len > 0) list.items[0] else "-";
    const note = std.fmt.allocPrint(p.alloc, "ip_list={d} 条（首条 {s}）", .{ list.items.len, first }) catch "";
    // 任何有效公众号都有 callback IP，空数组即视为契约漂移。
    return .{ .non_empty = list.items.len > 0, .note = note };
}

fn probeOaUserGet(p: ProbeCtx) anyerror!Attempt {
    const oa: *officialaccount.OfficialAccount = @ptrCast(@alignCast(p.handle));
    var user = oa.getUser(p.alloc);
    var parsed = try user.getOpenidList("");
    defer parsed.deinit();

    const total = parsed.value.total;
    const openids = parsed.value.data.openid;
    const note = std.fmt.allocPrint(
        p.alloc,
        "total={d} count={d} data.openid={d} 条",
        .{ total, parsed.value.count, openids.len },
    ) catch "";
    return .{
        .non_empty = openids.len > 0,
        // total == 0：账号确无粉丝，data.openid 缺失是合法的，无法验证键名 → SKIP。
        // total > 0 却解析不出 openid：正是 `OpenidList.data.openid` 那类结构漂移 → FAIL。
        .no_data_available = total == 0,
        .note = note,
    };
}

fn probeOaSelfMenu(p: ProbeCtx) anyerror!Attempt {
    const oa: *officialaccount.OfficialAccount = @ptrCast(@alignCast(p.handle));
    var menu = oa.getMenu(p.alloc);
    var parsed = try menu.getCurrentSelfMenuInfo();
    defer parsed.deinit();

    const is_open = parsed.value.is_menu_open;
    const buttons = parsed.value.selfmenu_info.button;
    const note = std.fmt.allocPrint(
        p.alloc,
        "is_menu_open={d} selfmenu_info.button={d} 项",
        .{ is_open, buttons.len },
    ) catch "";
    return .{
        .non_empty = buttons.len > 0,
        // 菜单未开放（is_menu_open=0）时没有按钮是正常的。注意**不能**把
        // 「buttons 为空」也算作无数据：那样会漏掉 `selfmenu_info` 被改名的情形。
        .no_data_available = is_open == 0,
        .note = note,
    };
}

const oa_specs = [_]ProbeSpec{
    .{
        .name = "oa.gettoken",
        .endpoint = "/cgi-bin/token",
        .expected_key = "access_token",
        .empty_ok = false,
        .run_fn = probeOaToken,
    },
    .{
        .name = "oa.getcallbackip",
        .endpoint = "/cgi-bin/getcallbackip",
        .expected_key = "ip_list",
        .empty_ok = false,
        .run_fn = probeOaCallbackIp,
    },
    .{
        .name = "oa.user.get",
        .endpoint = "/cgi-bin/user/get",
        .expected_key = "openid",
        .empty_ok = false,
        .run_fn = probeOaUserGet,
    },
    .{
        .name = "oa.selfmenuinfo",
        .endpoint = "/cgi-bin/get_current_selfmenu_info",
        .expected_key = "selfmenu_info",
        .empty_ok = false,
        .run_fn = probeOaSelfMenu,
    },
};
const oa_skip_reason = "缺少 " ++ OaAppIdEnv ++ " / " ++ OaAppSecretEnv;

// —— 企业微信 ——

fn probeWorkToken(p: ProbeCtx) anyerror!Attempt {
    const w: *work_mod.Work = @ptrCast(@alignCast(p.handle));
    const token = try w.getAccessToken(p.alloc);
    defer p.alloc.free(token);
    return .{ .non_empty = token.len > 0, .note = "gettoken 返回非空 access_token" };
}

fn probeWorkDepartmentList(p: ProbeCtx) anyerror!Attempt {
    const w: *work_mod.Work = @ptrCast(@alignCast(p.handle));
    var al = w.getAddressList(p.alloc);
    var parsed = try al.getDepartmentList();
    defer parsed.deinit();

    const depts = parsed.value.department;
    var unnamed: usize = 0;
    for (depts) |d| {
        if (d.name.len == 0) unnamed += 1;
    }
    const note = std.fmt.allocPrint(
        p.alloc,
        "department={d} 个（name 为空 {d} 个）",
        .{ depts.len, unnamed },
    ) catch "";
    // 任何企业都至少有根部门（id=1），空数组即视为契约漂移。
    return .{ .non_empty = depts.len > 0 and unnamed == 0, .note = note };
}

fn probeWorkUserSimpleList(p: ProbeCtx) anyerror!Attempt {
    const w: *work_mod.Work = @ptrCast(@alignCast(p.handle));
    var al = w.getAddressList(p.alloc);
    // department_id=1 + fetch_child=1：把整棵组织树的成员一次性拉出来，
    // 最大化「有成员可验证」的概率。
    var parsed = try al.getDepartmentUsers(1, 1);
    defer parsed.deinit();

    const users = parsed.value.userlist;
    var no_userid: usize = 0;
    for (users) |u| {
        if (u.userid.len == 0) no_userid += 1;
    }
    const note = std.fmt.allocPrint(
        p.alloc,
        "userlist={d} 条（userid 为空 {d} 条）",
        .{ users.len, no_userid },
    ) catch "";
    return .{
        .non_empty = users.len > 0 and no_userid == 0,
        .no_data_available = users.len == 0,
        .note = note,
    };
}

const work_specs = [_]ProbeSpec{
    .{
        .name = "work.gettoken",
        .endpoint = "/cgi-bin/gettoken",
        .expected_key = "access_token",
        .empty_ok = false,
        .run_fn = probeWorkToken,
    },
    .{
        .name = "work.department.list",
        .endpoint = "/cgi-bin/department/list",
        .expected_key = "department",
        .empty_ok = false,
        .run_fn = probeWorkDepartmentList,
    },
    .{
        .name = "work.user.simplelist",
        .endpoint = "/cgi-bin/user/simplelist",
        .expected_key = "userlist",
        .empty_ok = false,
        .run_fn = probeWorkUserSimpleList,
    },
};
const work_skip_reason = "缺少 " ++ WorkCorpIdEnv ++ " / " ++ WorkSecretEnv;

// —— 小程序 ——

fn probeMpToken(p: ProbeCtx) anyerror!Attempt {
    const mp: *miniprogram.MiniProgram = @ptrCast(@alignCast(p.handle));
    const token = try mp.getContext().getAccessToken(p.alloc);
    defer p.alloc.free(token);
    return .{ .non_empty = token.len > 0, .note = "access_token 非空（凭据链路可用）" };
}

fn probeMpSceneList(p: ProbeCtx) anyerror!Attempt {
    const mp: *miniprogram.MiniProgram = @ptrCast(@alignCast(p.handle));
    var op = mp.getOperation();
    var parsed = try op.getSceneList();
    defer parsed.deinit();

    const scenes = parsed.value.scene;
    var nameless: usize = 0;
    for (scenes) |s| {
        if (s.name.len == 0 and s.value.len == 0) nameless += 1;
    }
    const note = std.fmt.allocPrint(
        p.alloc,
        "scene={d} 条（name/value 全空 {d} 条）",
        .{ scenes.len, nameless },
    ) catch "";
    return .{
        .non_empty = scenes.len > 0 and nameless == 0,
        // 未发布 / 无访问数据的账号会返回空 scene 数组，属合法空值。
        .no_data_available = scenes.len == 0,
        .note = note,
    };
}

const mp_specs = [_]ProbeSpec{
    .{
        .name = "mp.gettoken",
        .endpoint = "/cgi-bin/token",
        .expected_key = "access_token",
        .empty_ok = false,
        .run_fn = probeMpToken,
    },
    .{
        .name = "mp.operation.scene",
        .endpoint = "/wxaapi/log/get_scene",
        .expected_key = "scene",
        .empty_ok = true,
        .run_fn = probeMpSceneList,
    },
};
const mp_skip_reason = "缺少 " ++ MpAppIdEnv ++ " / " ++ MpSecretEnv;

// ─────────────────────────────────────────────────────────────────────────────
// 报告
// ─────────────────────────────────────────────────────────────────────────────

const Row = struct {
    name: []const u8,
    endpoint: []const u8,
    status: Status,
    elapsed_ms: u64,
    note: []const u8,
};

const Report = struct {
    alloc: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    passes: usize = 0,
    fails: usize = 0,
    skips: usize = 0,
    total_ms: u64 = 0,

    fn add(self: *Report, row: Row) void {
        self.rows.append(self.alloc, row) catch return;
        self.total_ms += row.elapsed_ms;
        switch (row.status) {
            .pass => self.passes += 1,
            .fail => self.fails += 1,
            .skip => self.skips += 1,
        }
    }

    /// 整组 SKIP（缺凭据）。
    fn skipAll(self: *Report, specs: []const ProbeSpec, reason: []const u8) void {
        for (specs) |spec| {
            self.add(.{
                .name = spec.name,
                .endpoint = spec.endpoint,
                .status = .skip,
                .elapsed_ms = 0,
                .note = reason,
            });
        }
    }

    /// 整组 FAIL（实例构造失败等本地错误）。
    fn failAll(self: *Report, specs: []const ProbeSpec, err: anyerror) void {
        for (specs) |spec| {
            const note = std.fmt.allocPrint(self.alloc, "本地初始化失败: {s}", .{@errorName(err)}) catch "";
            self.add(.{
                .name = spec.name,
                .endpoint = spec.endpoint,
                .status = .fail,
                .elapsed_ms = 0,
                .note = note,
            });
        }
    }

    fn print(self: *const Report, strict: bool) void {
        std.debug.print("\n", .{});
        std.debug.print("===========================================================================\n", .{});
        std.debug.print("  zwechat live probe — 真实接口契约探针（只报告，不门禁）\n", .{});
        std.debug.print("===========================================================================\n", .{});
        std.debug.print("  {s:<6} {s:>9}  {s:<26} {s}\n", .{ "STATUS", "TIME(ms)", "PROBE", "ENDPOINT" });
        std.debug.print("  -----------------------------------------------------------------------\n", .{});
        for (self.rows.items) |row| {
            std.debug.print(
                "  {s:<6} {d:>9}  {s:<26} {s}\n",
                .{ row.status.label(), row.elapsed_ms, row.name, row.endpoint },
            );
            if (row.note.len > 0) {
                std.debug.print("         └ {s}\n", .{row.note});
            }
        }
        std.debug.print("  -----------------------------------------------------------------------\n", .{});
        std.debug.print(
            "  PASS={d}  FAIL={d}  SKIP={d}   累计耗时 {d} ms\n",
            .{ self.passes, self.fails, self.skips, self.total_ms },
        );
        if (strict) {
            std.debug.print("  退出码：strict 模式——FAIL 时 exit 1（本次 {s}）\n", .{
                if (self.fails > 0) "有 FAIL" else "无 FAIL",
            });
        } else {
            std.debug.print("  退出码：只报告模式——无论结果均为 exit 0（加 -Dstrict 可让 FAIL 变为 1）\n", .{});
        }
        std.debug.print("\n  ⚠ 探针会消耗真实配额（部分接口有每日上限），勿在 CI 常驻；\n", .{});
        std.debug.print("    仅建议在发版前 / 怀疑上游改了字段名时手动运行。\n", .{});
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 执行
// ─────────────────────────────────────────────────────────────────────────────

fn nowNs() i96 {
    return std.Io.Clock.now(.real, std.Options.debug_io).toNanoseconds();
}

fn msSince(start_ns: i96) u64 {
    const diff = nowNs() - start_ns;
    if (diff <= 0) return 0;
    const ms = @divTrunc(diff, 1_000_000);
    return @intCast(ms);
}

/// 判定依据的一句话说明（用于 SKIP / FAIL 行）。
fn why(status: Status, key_present: bool, no_data_available: bool) []const u8 {
    if (status == .skip) {
        return if (no_data_available)
            "该账号无数据可验证（键名未被验证，非契约问题）"
        else
            "关键字段为空（空值在该接口上属正常）";
    }
    return if (key_present)
        "键存在但解析为空"
    else
        "原始响应中找不到该键（上游可能改名 / 改结构）";
}

fn runProbe(p: *ProbeCtx, rep: *Report, spec: ProbeSpec) void {
    p.rec.begin();
    util_error.clearErrorDetail();

    const start = nowNs();
    const outcome = spec.run_fn(p.*);
    const elapsed_ms = msSince(start);

    if (outcome) |attempt| {
        const body = p.rec.bodySlice();
        const key_present = bodyHasKey(body, spec.expected_key);
        const status = judgeField(.{
            .non_empty = attempt.non_empty,
            .key_present = key_present,
            .empty_ok = spec.empty_ok,
            .no_data_available = attempt.no_data_available,
        });
        rep.add(.{
            .name = spec.name,
            .endpoint = spec.endpoint,
            .status = status,
            .elapsed_ms = elapsed_ms,
            .note = attemptNote(p, spec, attempt, status, key_present),
        });
        return;
    } else |err| {
        recordFailure(p, rep, spec, err, elapsed_ms);
    }
}

/// 探针抛错时的判定与落表。
///
/// 微信把「字段名解析不到」也表现为 errcode 非 0（SDK 直接抛 `ApiError`），因此这里
/// 必须把线程局部的 `lastErrorDetail()` 取回来区分「该账号不适用」（SKIP）与
/// 「真的失败了」（FAIL），并附上原始响应体前 512 字节。
fn recordFailure(p: *ProbeCtx, rep: *Report, spec: ProbeSpec, err: anyerror, elapsed_ms: u64) void {
    const detail = util_error.lastErrorDetail();
    const raw = flattenControlChars(p.alloc, preview(p.rec.bodySlice(), RawPreviewBytes));

    var status: Status = .fail;
    var note: []const u8 = "";
    if (detail) |d| {
        if (isNotApplicableErrCode(d.errcode)) {
            status = .skip;
            note = std.fmt.allocPrint(
                p.alloc,
                "errcode={d} {s}（该账号不适用，跳过）| raw: {s}",
                .{ d.errcode, d.errmsg, raw },
            ) catch "";
        } else {
            note = std.fmt.allocPrint(
                p.alloc,
                "errcode={d} {s} | raw: {s}",
                .{ d.errcode, d.errmsg, raw },
            ) catch "";
        }
    } else {
        note = std.fmt.allocPrint(
            p.alloc,
            "调用失败 {s} | raw: {s}",
            .{ @errorName(err), raw },
        ) catch "";
    }
    if (p.rec.calls == 0) {
        note = std.fmt.allocPrint(p.alloc, "{s}（未发出任何 HTTP 请求）", .{note}) catch note;
    }
    if (detail == null and raw.len == 0) {
        note = std.fmt.allocPrint(p.alloc, "{s}（响应体为空）", .{note}) catch note;
    }

    rep.add(.{
        .name = spec.name,
        .endpoint = spec.endpoint,
        .status = status,
        .elapsed_ms = elapsed_ms,
        .note = note,
    });
}

fn attemptNote(
    p: *ProbeCtx,
    spec: ProbeSpec,
    attempt: Attempt,
    status: Status,
    key_present: bool,
) []const u8 {
    if (status == .pass) return attempt.note;

    const body = p.rec.bodySlice();
    const raw = flattenControlChars(p.alloc, preview(body, RawPreviewBytes));
    const reason = why(status, key_present, attempt.no_data_available);
    if (attempt.note.len == 0) {
        return std.fmt.allocPrint(
            p.alloc,
            "{s} | 字段 `{s}` | raw: {s}",
            .{ reason, spec.expected_key, raw },
        ) catch reason;
    }
    return std.fmt.allocPrint(
        p.alloc,
        "{s}（{s}）| 字段 `{s}` | raw: {s}",
        .{ attempt.note, reason, spec.expected_key, raw },
    ) catch reason;
}

// ─────────────────────────────────────────────────────────────────────────────
// 分组装配
// ─────────────────────────────────────────────────────────────────────────────

fn buildOa(alloc: std.mem.Allocator, app_id: []const u8, app_secret: []const u8) !*officialaccount.OfficialAccount {
    const mem = try cache_mod.Memory.create(alloc);
    // DefaultAccessToken 实例必须活到 OfficialAccount 生命周期结束 → 放到分配器内存上。
    const handle_impl = try alloc.create(credential.DefaultAccessToken);
    handle_impl.* = credential.DefaultAccessToken.init(
        app_id,
        app_secret,
        credential.CacheKeyOfficialAccountPrefix,
        mem.asCache(),
    );

    const oa = try alloc.create(officialaccount.OfficialAccount);
    oa.* = officialaccount.OfficialAccount.newOfficialAccount(.{
        .app_id = app_id,
        .app_secret = app_secret,
        .cache = mem.asCache(),
    }, handle_impl.asHandle());
    return oa;
}

fn buildWork(alloc: std.mem.Allocator, corp_id: []const u8, corp_secret: []const u8) !*work_mod.Work {
    const mem = try cache_mod.Memory.create(alloc);
    // Work 内部派生的子模块持有 `&self.ctx`，实例地址必须稳定 → 放堆上，不按值传递。
    const w = try alloc.create(work_mod.Work);
    w.* = try work_mod.Work.newDefaultWork(.{
        .corp_id = corp_id,
        .corp_secret = corp_secret,
        .cache = mem.asCache(),
    }, alloc);
    return w;
}

fn buildMp(alloc: std.mem.Allocator, app_id: []const u8, app_secret: []const u8) !*miniprogram.MiniProgram {
    const mem = try cache_mod.Memory.create(alloc);
    const handle_impl = try alloc.create(credential.DefaultAccessToken);
    handle_impl.* = credential.DefaultAccessToken.init(
        app_id,
        app_secret,
        credential.CacheKeyMiniProgramPrefix,
        mem.asCache(),
    );

    const mp = try alloc.create(miniprogram.MiniProgram);
    mp.* = miniprogram.MiniProgram.init(alloc, .{
        .app_id = app_id,
        .app_secret = app_secret,
        .cache = mem.asCache(),
    }, handle_impl.asHandle());
    return mp;
}

fn runOaGroup(p: *ProbeCtx, rep: *Report, env: EnvGet, env_ctx: *anyopaque) void {
    const creds = readEnvPair(env, env_ctx, OaAppIdEnv, OaAppSecretEnv) orelse {
        rep.skipAll(&oa_specs, oa_skip_reason);
        return;
    };
    const oa = buildOa(p.alloc, creds.a, creds.b) catch |err| {
        rep.failAll(&oa_specs, err);
        return;
    };
    var ctx = ProbeCtx{ .alloc = p.alloc, .rec = p.rec, .handle = @ptrCast(oa) };
    for (&oa_specs) |spec| runProbe(&ctx, rep, spec);
}

fn runWorkGroup(p: *ProbeCtx, rep: *Report, env: EnvGet, env_ctx: *anyopaque) void {
    const creds = readEnvPair(env, env_ctx, WorkCorpIdEnv, WorkSecretEnv) orelse {
        rep.skipAll(&work_specs, work_skip_reason);
        return;
    };
    const w = buildWork(p.alloc, creds.a, creds.b) catch |err| {
        rep.failAll(&work_specs, err);
        return;
    };
    var ctx = ProbeCtx{ .alloc = p.alloc, .rec = p.rec, .handle = @ptrCast(w) };
    for (&work_specs) |spec| runProbe(&ctx, rep, spec);
}

fn runMpGroup(p: *ProbeCtx, rep: *Report, env: EnvGet, env_ctx: *anyopaque) void {
    const creds = readEnvPair(env, env_ctx, MpAppIdEnv, MpSecretEnv) orelse {
        rep.skipAll(&mp_specs, mp_skip_reason);
        return;
    };
    const mp = buildMp(p.alloc, creds.a, creds.b) catch |err| {
        rep.failAll(&mp_specs, err);
        return;
    };
    var ctx = ProbeCtx{ .alloc = p.alloc, .rec = p.rec, .handle = @ptrCast(mp) };
    for (&mp_specs) |spec| runProbe(&ctx, rep, spec);
}

// ─────────────────────────────────────────────────────────────────────────────
// 真实 env 适配器
// ─────────────────────────────────────────────────────────────────────────────

const ProcessEnv = struct {
    map: *std.process.Environ.Map,

    fn get(ctx: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *ProcessEnv = @ptrCast(@alignCast(ctx));
        return self.map.get(key);
    }
};

fn printDisabled() void {
    std.debug.print(
        \\[zwechat live-probe] 未启用（设置 ZWECHAT_LIVE_PROBE=1 与凭据以启用）
        \\
        \\  凭据环境变量：
        \\    公众号  ZWECHAT_OA_APPID / ZWECHAT_OA_APPSECRET
        \\    企业微信 ZWECHAT_WORK_CORPID / ZWECHAT_WORK_SECRET
        \\    小程序  ZWECHAT_MP_APPID / ZWECHAT_MP_SECRET
        \\
        \\  见 src/live_probe.zig 顶部文档；探针会消耗真实配额，勿在 CI 常驻。
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    // 探针只在人工显式启用时运行，全程单线程、一次性生命周期，
    // 因此统一用 arena 管理临时分配（含 HTTP 客户端与缓存）。
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // strict 的三个来源：`-Dstrict`（由 build.zig 转成 `--strict`）/ 直接运行传参 / env。
    var strict = false;
    {
        var args_iter = init.minimal.args.iterate();
        while (args_iter.next()) |arg| {
            if (isStrictFlag(arg)) strict = true;
        }
    }
    if (gateEnabled(init.environ_map.get(StrictEnv))) strict = true;

    // —— 门控：未启用 → 发请求之前就退出，exit 0 ——
    if (!gateEnabled(init.environ_map.get(GateEnv))) {
        printDisabled();
        return;
    }

    var env_source = ProcessEnv{ .map = init.environ_map };
    const env: EnvGet = ProcessEnv.get;
    const env_ctx: *anyopaque = @ptrCast(&env_source);

    // 严格模式：任何用不同 allocator 取默认客户端的地方立刻 panic，把误用暴露在本进程。
    try util_http.initDefaultClient(alloc);
    defer util_http.deinitDefaultClient();

    var rec = Recorder{ .allocator = alloc };
    const client = util_http.getDefaultClient(alloc);
    client.setTransport(Recorder.dispatch, @ptrCast(&rec));
    defer client.setTransport(null, null);

    var report = Report{ .alloc = alloc };
    var p = ProbeCtx{ .alloc = alloc, .rec = &rec, .handle = @ptrCast(&rec) };

    std.debug.print("[zwechat live-probe] 已启用：将对真实微信接口发出只读请求（会消耗配额）\n", .{});
    runOaGroup(&p, &report, env, env_ctx);
    runWorkGroup(&p, &report, env, env_ctx);
    runMpGroup(&p, &report, env, env_ctx);
    report.print(strict);

    if (strict and report.fails > 0) {
        // 只报告模式下绝不走到这里；strict 是人工在发版前开的门禁。
        std.process.exit(1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 单元测试（纯逻辑、零网络）
//
// ⚠️ 本文件不在 `src/test_runner.zig` 的 import 图里，所以下面这些 test 不会被
// `zig build test` 收集——这是刻意的：探针不该被自动跑。手动运行：
//     zig build live-probe-test
// ─────────────────────────────────────────────────────────────────────────────

/// 测试用 env 适配器：把 `StringHashMap` 包成 `EnvGet`。
const FakeEnv = struct {
    map: *std.StringHashMap([]const u8),

    fn get(ctx: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(ctx));
        return self.map.get(key);
    }
};

test "门控：只有显式真值才启用，未设置 / 假值 / 无法识别一律不启用" {
    // 未设置
    try std.testing.expect(!gateEnabled(null));
    // 显式真值（大小写不敏感、允许两侧空白）
    try std.testing.expect(gateEnabled("1"));
    try std.testing.expect(gateEnabled("true"));
    try std.testing.expect(gateEnabled("TRUE"));
    try std.testing.expect(gateEnabled("Yes"));
    try std.testing.expect(gateEnabled("on"));
    try std.testing.expect(gateEnabled("  1 \n"));
    // 假值 / 空白 / 无法识别 → 绝不发请求（白名单而非「非空即真」）
    try std.testing.expect(!gateEnabled(""));
    try std.testing.expect(!gateEnabled("   "));
    try std.testing.expect(!gateEnabled("0"));
    try std.testing.expect(!gateEnabled("false"));
    try std.testing.expect(!gateEnabled("off"));
    try std.testing.expect(!gateEnabled("maybe"));
}

test "env 读取：缺失 / 纯空白视为未提供；凭据需成对齐全" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(allocator);
    defer map.deinit();
    try map.put("ID", "wx-id");
    try map.put("BLANK", "  \t ");
    try map.put("SECRET", "s3cr3t");
    var fake = FakeEnv{ .map = &map };
    const ctx: *anyopaque = @ptrCast(&fake);

    try std.testing.expectEqualStrings("wx-id", readEnv(FakeEnv.get, ctx, "ID").?);
    try std.testing.expect(readEnv(FakeEnv.get, ctx, "MISSING") == null);
    try std.testing.expect(readEnv(FakeEnv.get, ctx, "BLANK") == null);

    // 成对齐全 → 命中
    const pair = readEnvPair(FakeEnv.get, ctx, "ID", "SECRET").?;
    try std.testing.expectEqualStrings("wx-id", pair.a);
    try std.testing.expectEqualStrings("s3cr3t", pair.b);

    // 任一项缺失 / 为空白 → null（调用方据此整组 SKIP，而不是报错）
    try std.testing.expect(readEnvPair(FakeEnv.get, ctx, "ID", "MISSING") == null);
    try std.testing.expect(readEnvPair(FakeEnv.get, ctx, "MISSING", "SECRET") == null);
    try std.testing.expect(readEnvPair(FakeEnv.get, ctx, "ID", "BLANK") == null);
}

test "字段判定：非空 PASS / 无数据 SKIP / 键缺失 FAIL / 键在值空按契约判定" {
    // 1) 字段非空 → PASS（其余条件无关）
    try std.testing.expectEqual(Status.pass, judgeField(.{
        .non_empty = true,
        .key_present = false,
        .empty_ok = false,
    }));

    // 2) 账号无数据可验证 → SKIP，即便原始响应里没有该键（0 粉丝的 data.openid）
    try std.testing.expectEqual(Status.skip, judgeField(.{
        .non_empty = false,
        .key_present = false,
        .empty_ok = false,
        .no_data_available = true,
    }));

    // 3) 有数据却解析不出、原始响应也没有该键 → FAIL（上游改名）
    try std.testing.expectEqual(Status.fail, judgeField(.{
        .non_empty = false,
        .key_present = false,
        .empty_ok = true,
        .no_data_available = false,
    }));

    // 4) 键在、值为空、空值可接受 → SKIP
    try std.testing.expectEqual(Status.skip, judgeField(.{
        .non_empty = false,
        .key_present = true,
        .empty_ok = true,
    }));

    // 5) 键在、值为空、契约要求非空 → FAIL
    try std.testing.expectEqual(Status.fail, judgeField(.{
        .non_empty = false,
        .key_present = true,
        .empty_ok = false,
    }));
}

test "bodyHasKey 精确匹配带引号的键，不误命中子串" {
    const body = "{\"total\":2,\"data\":{\"openid\":[\"o1\"]},\"next_openid\":\"o1\"}";
    try std.testing.expect(bodyHasKey(body, "openid"));
    try std.testing.expect(bodyHasKey(body, "data"));
    try std.testing.expect(bodyHasKey(body, "total"));
    // `"next_openid"` 不包含 `"openid"` 子串，因此改名检测不会被子串欺骗
    try std.testing.expect(!bodyHasKey(body, "openids"));
    try std.testing.expect(!bodyHasKey(body, "missing"));
    // 空 key / 超长 key 直接返回 false，不分配、不越界
    try std.testing.expect(!bodyHasKey(body, ""));
    var long_key: [70]u8 = @splat('x');
    try std.testing.expect(!bodyHasKey(body, &long_key));
}

test "preview 按 UTF-8 边界截断且不越界" {
    const short = "{\"ip_list\":[]}";
    try std.testing.expectEqualStrings(short, preview(short, 512));

    // 3 字节汉字刚好跨过截断点：回退到完整字符边界
    const text = "ab" ++ "错" ++ "def";
    const cut = preview(text, 3);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings("ab", cut);

    // 纯 ASCII 长串精确截断
    var ascii: [600]u8 = @splat('a');
    try std.testing.expectEqual(@as(usize, 100), preview(&ascii, 100).len);
}

test "flattenControlChars 把换行 / 制表符替换为空格，保持表格单行" {
    const allocator = std.testing.allocator;
    const raw = "{\n  \"a\":\t1\r\n}";
    const flat = flattenControlChars(allocator, raw);
    defer if (flat.ptr != raw.ptr) allocator.free(flat);
    try std.testing.expectEqualStrings("{   \"a\": 1  }", flat);
}

test "strict 标志解析：--strict / -s 命中，其余不命中" {
    try std.testing.expect(isStrictFlag("--strict"));
    try std.testing.expect(isStrictFlag("-s"));
    try std.testing.expect(!isStrictFlag("strict"));
    try std.testing.expect(!isStrictFlag("--stricter"));
    try std.testing.expect(hasStrictFlag(&.{ "/path/to/live-probe", "--strict" }));
    try std.testing.expect(!hasStrictFlag(&.{"live-probe"}));
    try std.testing.expect(!hasStrictFlag(&.{ "/path/to/live-probe", "--verbose" }));
}

test "不适用错误码 → SKIP；未知错误码按 FAIL 处理" {
    try std.testing.expect(isNotApplicableErrCode(46003)); // 菜单不存在
    try std.testing.expect(isNotApplicableErrCode(48001)); // 接口未授权
    try std.testing.expect(!isNotApplicableErrCode(0));
    try std.testing.expect(!isNotApplicableErrCode(40001)); // token 失效：契约问题，必须 FAIL
    try std.testing.expect(!isNotApplicableErrCode(45009)); // 超频：必须 FAIL（提示配额问题）
}
