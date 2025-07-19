const std = @import("std");
const utils = @import("utils.zig");
const arguments = @import("arguments.zig");

pub const HelpOptions = struct {
    left_pad: usize = 4,
    help_len: usize = 48,
    centre_padding: usize = 26,
    indent: usize = 2,
};

pub fn helpArgument(writer: anytype, arg: arguments.Argument, opts: HelpOptions) !void {
    _ = try writer.splatByte(' ', opts.left_pad);

    const name = arg.desc.display_name orelse arg.desc.arg;

    if (arg.desc.required) {
        try writer.print("<{s}>", .{name});
    } else {
        try writer.print("[{s}]", .{name});
    }

    _ = try writer.splatByte(
        ' ',
        opts.centre_padding -| (name.len + 2),
    );

    comptime var help_string = arg.desc.help;
    if (arg.desc.default) |d| {
        help_string = help_string ++ std.fmt.comptimePrint(" (default: {s}).", .{d});
    }
    try utils.writeWrapped(writer, help_string, .{
        .left_pad = opts.left_pad + opts.centre_padding,
        .continuation_indent = opts.indent,
        .column_limit = opts.help_len,
    });

    try writer.writeByte('\n');
}

const TestArguments = [_]arguments.ArgumentDescriptor{
    .{
        .arg = "item",
        .help = "Positional argument.",
        .required = true,
    },
    .{
        .arg = "-n/--limit value",
        .help = "Limit.",
        .argtype = usize,
    },
    .{
        .arg = "other",
        .help = "Another positional",
    },
    .{
        .arg = "-f/--flag",
        .help = "Toggleable",
    },
};

test "argument help" {
    const Arguments = @import("main.zig").Arguments;
    const Args1 = Arguments(&TestArguments);

    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const writer = list.writer();
    try Args1.writeHelp(writer, .{});

    try std.testing.expectEqualStrings(
        \\    <item>                    Positional argument.
        \\    [-n/--limit value]        Limit.
        \\    [other]                   Another positional
        \\    [-f/--flag]               Toggleable
        \\
    , list.items);
}
