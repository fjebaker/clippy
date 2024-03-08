const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const farbe = b.dependency("farbe", .{
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("clippy", .{
        .root_source_file = .{ .path = "src/main.zig" },
        .imports = &.{
            .{
                .name = "farbe",
                .module = farbe.module("farbe"),
            },
        },
    });

    const lib = b.addStaticLibrary(.{
        .name = "clippy",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
