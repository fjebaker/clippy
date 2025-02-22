const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("clippy", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const lib = b.addStaticLibrary(.{
        .name = "clippy",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    b.installArtifact(main_tests);

    // various examples
    inline for (&[_][]const u8{"./examples/basic.zig"}) |example| {
        const stem = comptime std.fs.path.stem(example);
        const exe = b.addExecutable(.{
            .name = stem,
            .root_source_file = b.path(example),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("clippy", mod);

        const run_example = b.addRunArtifact(exe);
        const run_step = b.step(stem, "Run example: " ++ stem);
        run_step.dependOn(&run_example.step);

        if (b.args) |args| {
            run_example.addArgs(args);
        }
    }
}
