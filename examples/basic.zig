const std = @import("std");
const clippy = @import("clippy");

const Arguments = clippy.Arguments(&.{
    .{
        .arg = "file",
        .help = "Path to file.",
        .required = true,
    },
    .{
        .arg = "-v",
        .help = "Verbose.",
    },
    .{
        .arg = "-a/--algorithm alg",
        .help = "Which algorithm to use (by index).",
        .argtype = usize,
        .default = "2",
    },
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // miss out the program name, unless you want to parse it
    var itt = clippy.ArgumentIterator.init(args[1..]);
    var parser = Arguments.init(&itt, .{});
    const parsed = try parser.parseAll();

    std.debug.print("File    : {s}\n", .{parsed.file});
    std.debug.print("Verbose : {any}\n", .{parsed.v});
    std.debug.print("Alg     : {d}\n", .{parsed.algorithm});
}
