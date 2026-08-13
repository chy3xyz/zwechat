// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

/// 探测 OpenSSL include 目录（与 setupOpenSSL 相同的优先级），
/// 供 zhttp 依赖的 `-Dopenssl-include` 构建选项使用。
fn resolveOpenSSLInclude(b_builder: *std.Build) []const u8 {
    if (b_builder.graph.environ_map.get("OPENSSL_DIR")) |openssl_dir| {
        return b_builder.pathJoin(&.{ openssl_dir, "include" });
    }
    const search_bases = [_][]const u8{
        "/opt/homebrew/opt/openssl@3",
        "/usr/local/opt/openssl@3",
    };
    for (search_bases) |base| {
        const inc = b_builder.fmt("{s}/include", .{base});
        if (std.Io.Dir.cwd().access(b_builder.graph.io, inc, .{})) |_| {
            return inc;
        } else |_| {}
    }
    // Linux / 其他平台默认系统 include。
    return "/usr/include";
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zhttp（httpz.zig 延续仓库）依赖：v0.6.1，由 zig fetch 从
    // https://github.com/chy3xyz/zhttp 拉取（build.zig.zon 声明 URL + hash）。
    // - 关闭 h3：本项目不需要 HTTP/3，避免构建依赖 nghttp3/ngtcp2 系统库；
    // - openssl-include：按 OPENSSL_DIR → Homebrew → 系统默认 探测后透传，
    //   供上游 translateC 编译 openssl.h 使用。
    const openssl_include = resolveOpenSSLInclude(b);
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
        .h3 = false,
        .@"openssl-include" = openssl_include,
    });
    const httpz_mod = httpz_dep.module("zhttp");

    // 辅助函数：配置 OpenSSL 与 System Library 链接
    const setupOpenSSL = struct {
        fn apply(b_builder: *std.Build, mod: *std.Build.Module) void {
            mod.linkSystemLibrary("ssl", .{});
            mod.linkSystemLibrary("crypto", .{});
            mod.link_libc = true;

            // 1) 优先使用 OPENSSL_DIR 环境变量（跨平台通用，CI 可注入）。
            //    期望布局：<OPENSSL_DIR>/include 与 <OPENSSL_DIR>/lib。
            if (b_builder.graph.environ_map.get("OPENSSL_DIR")) |openssl_dir| {
                mod.addIncludePath(.{ .cwd_relative = b_builder.pathJoin(&.{ openssl_dir, "include" }) });
                mod.addLibraryPath(.{ .cwd_relative = b_builder.pathJoin(&.{ openssl_dir, "lib" }) });
                return;
            }

            // 2) 回退：探测常见 Homebrew OpenSSL 3 路径（macOS）。
            const search_bases = [_][]const u8{
                "/opt/homebrew/opt/openssl@3",
                "/usr/local/opt/openssl@3",
            };

            for (search_bases) |base| {
                const inc = b_builder.fmt("{s}/include", .{base});
                const lib = b_builder.fmt("{s}/lib", .{base});

                if (std.Io.Dir.cwd().access(b_builder.graph.io, inc, .{})) |_| {
                    mod.addIncludePath(.{ .cwd_relative = inc });
                } else |_| {}
                if (std.Io.Dir.cwd().access(b_builder.graph.io, lib, .{})) |_| {
                    mod.addLibraryPath(.{ .cwd_relative = lib });
                } else |_| {}
            }
        }
    }.apply;

    // httpz 模块内部已 linkSystemLibrary("ssl"/"crypto")，但 Windows/macOS 上
    // OpenSSL 库不在 zig 默认搜索路径，需在此补 include/lib 路径。
    setupOpenSSL(b, httpz_mod);

    // 顶层 lib 模块：暴露给下游包使用
    const lib_mod = b.addModule("zwechat", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz_mod },
        },
    });
    setupOpenSSL(b, lib_mod);

    // 主 CLI 示例
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwechat", .module = lib_mod },
            .{ .name = "httpz", .module = httpz_mod },
        },
    });
    setupOpenSSL(b, exe_mod);

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
            .{ .name = "httpz", .module = httpz_mod },
        },
    });
    setupOpenSSL(b, test_mod);

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
    setupOpenSSL(b, bench_mod);
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmark suite");
    bench_step.dependOn(&run_bench.step);

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
        setupOpenSSL(b, example_mod);
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

    // —— 代码格式化检查（zig fmt --check 的封装）——
    const fmt_check = b.addFmt(.{
        .paths = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon"), b.path("examples") },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check code formatting (zig fmt --check)");
    fmt_step.dependOn(&fmt_check.step);
}
