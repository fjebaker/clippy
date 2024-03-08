const clippy = @import("main.zig");

const FooArguments = clippy.Arguments(&.{
    .{
        .arg = "item",
        .help = "Positional argument.",
        .required = true,
    },
});

const BarArguments = clippy.Arguments(&.{
    .{ .arg = "--toggle", .help = "True or false." },
});

const MutualArguments = clippy.Arguments(&.{
    .{
        .arg = "-n/--limit value",
        .help = "",
        .argtype = usize,
    },
});

const SubCommands = clippy.Commands(.{
    .mutual = MutualArguments,
    .commands = .{
        .{ .name = "foo", .args = FooArguments },
        .{ .name = "bar", .args = BarArguments },
    },
});

const Arguments = clippy.Commands(.{
    .commands = .{
        .{ .name = "run", .commands = SubCommands },
        .{ .name = "help" },
    },
});

// {run | help}
//
// run [-n/--limit value] {foo|bar}
//
// run [-n/--limit value] foo item
// run [-n/--limit value] bar [--toggle]
