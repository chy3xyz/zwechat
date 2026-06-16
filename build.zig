const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // httpz 依赖模块（带 OpenSSL 客户端证书补丁）
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    const httpz_mod = httpz_dep.module("httpz");

    // 顶层 lib 模块：暴露给下游包使用
    const lib_mod = b.addModule("zwechat", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz_mod },
        },
    });
    lib_mod.linkSystemLibrary("ssl", .{});
    lib_mod.linkSystemLibrary("crypto", .{});
    lib_mod.link_libc = true;

    // 示例可执行
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwechat", .module = lib_mod },
            .{ .name = "httpz", .module = httpz_mod },
        },
    });
    exe_mod.linkSystemLibrary("ssl", .{});
    exe_mod.linkSystemLibrary("crypto", .{});
    exe_mod.link_libc = true;

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
    test_mod.linkSystemLibrary("ssl", .{});
    test_mod.linkSystemLibrary("crypto", .{});
    test_mod.link_libc = true;

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_tests.step);
}