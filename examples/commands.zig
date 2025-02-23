const std = @import("std");
const clippy = @import("clippy");

const LoadArguments = clippy.Arguments(&.{
    .{
        .arg = "file",
        .help = "File to load into the system",
        .required = true,
    },
    .{
        .arg = "--limit n",
        .help = "Size limit. A value of `0` means no limit.",
        .default = "1024",
        .argtype = usize,
    },
});

const SaveArguments = clippy.Arguments(&.{
    .{
        .arg = "-o/--output file",
        .help = "Output path.",
        .default = "output.csv",
    },
});

const Commands = clippy.Commands(union(enum) {
    load: LoadArguments,
    save: SaveArguments,
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // miss out the program name, unless you want to parse it
    var itt = clippy.ArgumentIterator.init(args[1..]);
    var parser = Commands.init(&itt, .{});
    const parsed = try parser.parseAll();

    switch (parsed) {
        .load => |p| {
            std.debug.print("Load: file={s} limit={d}\n", .{ p.file, p.limit });
        },
        .save => |p| {
            std.debug.print("Save: output={s}\n", .{p.output});
        },
    }
}
