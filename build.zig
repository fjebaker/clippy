const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("clippy", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    b.installArtifact(main_tests);

    // various examples
    inline for (&[_][]const u8{
        "./examples/basic.zig",
        "./examples/commands.zig",
    }) |example| {
        const stem = comptime std.fs.path.stem(example);
        const exe = b.addExecutable(.{
            .name = stem,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "clippy", .module = mod },
                },
            }),
        });

        const run_example = b.addRunArtifact(exe);
        const run_step = b.step(stem, "Run example: " ++ stem);
        run_step.dependOn(&run_example.step);

        if (b.args) |args| {
            run_example.addArgs(args);
        }
    }
}
