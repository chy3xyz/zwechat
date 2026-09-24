// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 微信支付 v2 的退款/转账/红包走 mTLS（客户端证书）。纯 Zig 的 std TLS 客户端
    // 不支持客户端证书，因此仓库内自建 `src/util/mtls_openssl.zig`：运行时用
    // `std.DynLib` dlopen OpenSSL，**构建期不链接任何 C 库**。
    //
    // - 默认 `-Dmtls=false`：源码用 `src/util/mtls.zig` 的 stub，不设置 link_libc、
    //   不 linkSystemLibrary，产物零 C 依赖（CI 用 ldd/otool 回归证明）；
    // - `-Dmtls=true`：仅为 dlopen 打开 `link_libc`（dlopen 需要 libc）；libssl /
    //   libcrypto 仍在运行时加载，可用 ZWECHAT_SSL_LIB / ZWECHAT_CRYPTO_LIB
    //   指定绝对路径。
    const mtls_enabled = b.option(
        bool,
        "mtls",
        "Enable WeChat Pay v2 mTLS via runtime-dlopen OpenSSL (default: off, zero C deps)",
    ) orelse false;

    const mtls_options = b.addOptions();
    mtls_options.addOption(bool, "enabled", mtls_enabled);
    const mtls_options_mod = mtls_options.createModule();

    // 统一装配各 module：注入 mtls_options 开关；仅在 mTLS 模式下链接 libc。
    const configure = struct {
        fn apply(mod: *std.Build.Module, opts: *std.Build.Module, enabled: bool) void {
            mod.addImport("mtls_options", opts);
            if (enabled) mod.link_libc = true;
        }
    }.apply;

    // 顶层 lib 模块：暴露给下游包使用
    const lib_mod = b.addModule("zwechat", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configure(lib_mod, mtls_options_mod, mtls_enabled);

    // 主 CLI 示例
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwechat", .module = lib_mod },
        },
    });
    configure(exe_mod, mtls_options_mod, mtls_enabled);

    const exe = b.addExecutable(.{
        .name = "zwechat",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the example CLI");
    run_step.dependOn(&run_cmd.step);

    // 测试：把 test_runner 当作测试根文件
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwechat", .module = lib_mod },
        },
    });
    configure(test_mod, mtls_options_mod, mtls_enabled);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_tests.step);

    // —— 基准测试 (Benchmark) ——
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/util/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "zwechat", .module = lib_mod },
        },
    });
    configure(bench_mod, mtls_options_mod, mtls_enabled);
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmark suite");
    bench_step.dependOn(&run_bench.step);

    // —— 可选真实接口探针（live probe）——
    //
    // 与 `zig build run` 同一风格，但**不 install**：默认 `zig build` 与
    // `zig build test` 既不会编译也不会运行它，因此不会在 CI / 日常开发路径上
    // 发出任何真实网络请求。只有显式执行 `zig build live-probe` 才会运行，
    // 且进程内还有 `ZWECHAT_LIVE_PROBE=1` 门控兜底。
    //
    // strict：本工具链的 `zig build <step> -- <args>` 不会把参数转发给被运行的
    // 进程（`std.Build` 已无 `args` 字段，实测被静默忽略），因此改用构建选项
    // `-Dstrict`，由这里补上 `--strict` 传给探针。
    const live_probe_mod = b.createModule(.{
        .root_source_file = b.path("src/live_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwechat", .module = lib_mod },
        },
    });
    configure(live_probe_mod, mtls_options_mod, mtls_enabled);

    const live_probe_exe = b.addExecutable(.{
        .name = "live-probe",
        .root_module = live_probe_mod,
    });
    const run_live_probe = b.addRunArtifact(live_probe_exe);
    if (b.option(bool, "strict", "live-probe: 有 FAIL 时 exit 1（默认只报告，始终 exit 0）") orelse false) {
        run_live_probe.addArg("--strict");
    }
    const live_probe_step = b.step(
        "live-probe",
        "Run optional live probes against real WeChat APIs (needs ZWECHAT_LIVE_PROBE=1 + credentials; consumes quota)",
    );
    live_probe_step.dependOn(&run_live_probe.step);

    // 探针文件内联的单元测试（纯逻辑、零网络）单独跑。
    // 刻意**不**并入 `test` step：探针不该被 `zig build test` 自动执行。
    const live_probe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/live_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwechat", .module = lib_mod },
        },
    });
    configure(live_probe_test_mod, mtls_options_mod, mtls_enabled);

    const live_probe_tests = b.addTest(.{
        .root_module = live_probe_test_mod,
    });
    const run_live_probe_tests = b.addRunArtifact(live_probe_tests);
    const live_probe_test_step = b.step(
        "live-probe-test",
        "Run the offline unit tests inside src/live_probe.zig (no network)",
    );
    live_probe_test_step.dependOn(&run_live_probe_tests.step);

    // —— Examples 示例集合 ——
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "oa-server", .path = "examples/officialaccount_server.zig" },
        .{ .name = "pay-order", .path = "examples/pay_order.zig" },
        .{ .name = "work-robot", .path = "examples/work_robot.zig" },
    };

    for (examples) |ex| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(ex.path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwechat", .module = lib_mod },
            },
        });
        configure(example_mod, mtls_options_mod, mtls_enabled);
        const example_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = example_mod,
        });
        // 安装示例产物（zig build 一并编译，CI 覆盖示例编译路径）。
        b.installArtifact(example_exe);
        const run_example = b.addRunArtifact(example_exe);
        const step_name = b.fmt("run-{s}", .{ex.name});
        const example_step = b.step(step_name, b.fmt("Run example {s}", .{ex.name}));
        example_step.dependOn(&run_example.step);
    }

    // —— 公开 API 面提取（离线工具，不参与默认 `zig build`）——
    //
    // 与 `tools/api_surface_check.sh` 用的是同一个可执行文件（`zig run tools/api_surface.zig`
    // 是脚本的调用方式；这里是给开发者直接看的入口）。它只打印条目，快照的前缀注释、
    // 排序与落盘都由脚本负责；门禁对账逻辑不在 build.zig 里。
    const api_surface_mod = b.createModule(.{
        .root_source_file = b.path("tools/api_surface.zig"),
        .target = target,
        .optimize = optimize,
    });
    const api_surface_exe = b.addExecutable(.{
        .name = "api-surface",
        .root_module = api_surface_mod,
    });
    const run_api_surface = b.addRunArtifact(api_surface_exe);
    // stdio 继承 + 视作有副作用：每次显式调用都真的跑一遍并直接打印到终端
    // （默认的 `.infer_from_args` 会把 stdout 收走，看不到任何东西）。
    run_api_surface.stdio = .inherit;
    run_api_surface.addDirectoryArg(b.path("."));
    const api_surface_step = b.step(
        "api-surface",
        "Print the public API surface of src/ (same extractor as tools/api_surface_check.sh)",
    );
    api_surface_step.dependOn(&run_api_surface.step);

    // —— 代码格式化检查（zig fmt --check 的封装）——
    const fmt_check = b.addFmt(.{
        .paths = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon"), b.path("examples") },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check code formatting (zig fmt --check)");
    fmt_step.dependOn(&fmt_check.step);
}
