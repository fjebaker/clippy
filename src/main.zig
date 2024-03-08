const std = @import("std");
const testing = std.testing;

const utils = @import("utils.zig");
const ArgumentInfo = @import("info.zig").ArgumentInfo;
const ParserWrapper = @import("wrapper.zig").ParserWrapper;

pub const cli = @import("cli.zig");

/// Argument wrapper for generating help strings and parsing
pub const ArgumentDescriptor = struct {
    /// Argument name. Can be either the name itself or a flag Short flags
    /// should just be `-f`, long flags `--flag`, and short and long
    /// `-f/--flag`
    arg: []const u8,

    /// How the argument should be displayed in the help message.
    display_name: ?[]const u8 = null,

    /// The type the argument should be parsed to.
    argtype: type = []const u8,

    /// Help string
    help: []const u8,

    /// Is a required argument
    required: bool = false,

    /// Should be parsed by the helper
    parse: bool = true,
};

pub fn Arguments(comptime args: []const ArgumentDescriptor) type {
    const infos = parseableInfo(args);

    // create the fields for returning the arguments
    comptime var fields: []const std.builtin.Type.StructField = &.{};
    inline for (infos) |info| {
        fields = fields ++ .{info.toField()};
    }

    const InternalType = @Type(
        .{ .Struct = .{
            .layout = .Auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &.{},
        } },
    );

    return ParserWrapper(infos, InternalType);
}

/// Filter only those arguments with `parse` set to `true`, and initialize the
/// argument info structure
fn parseableInfo(
    comptime args: []const ArgumentDescriptor,
) []const ArgumentInfo {
    comptime var parseable: []const ArgumentInfo = &.{};
    inline for (args) |arg| {
        if (arg.parse) {
            const info = ArgumentInfo.fromDescriptor(arg) catch |err|
                @compileError(
                "Could not extract info for " ++ arg.arg ++
                    " (" ++ @errorName(err) ++ ")",
            );
            parseable = parseable ++ .{info};
        }
    }
    return parseable;
}

const TestArguments = [_]ArgumentDescriptor{
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
        .argtype = struct {
            value: []const u8,
            pub fn initFromArg(s: []const u8) !@This() {
                return .{ .value = s };
            }
        },
    },
    .{
        .arg = "-f/--flag",
        .help = "Toggleable",
    },
};

fn parseArgs(comptime T: type, comptime string: []const u8) !T.Parsed {
    const arg_strings = try utils.fromString(
        std.testing.allocator,
        string,
    );
    defer std.testing.allocator.free(arg_strings);
    var argitt = cli.ArgIterator.init(arg_strings);

    var parser = T.init(&argitt);
    while (try argitt.next()) |arg| {
        _ = try parser.parseArg(arg);
    }

    return try parser.getParsed();
}

test "example arguments" {
    const Args = Arguments(&TestArguments);
    const fields = @typeInfo(Args.Parsed).Struct.fields;
    _ = fields;

    {
        const parsed = try parseArgs(
            Args,
            "hello --limit 12 goodbye -f",
        );
        try testing.expectEqual(parsed.limit, 12);
        try testing.expectEqualStrings(parsed.item, "hello");
        try testing.expectEqualStrings(parsed.other.?.value, "goodbye");
        try testing.expectEqual(true, parsed.flag);
    }

    {
        const parsed = try parseArgs(
            Args,
            "hello --limit 12 --flag",
        );
        try testing.expectEqual(parsed.limit, 12);
        try testing.expectEqualStrings(parsed.item, "hello");
        try testing.expectEqual(parsed.other, null);
        try testing.expectEqual(true, parsed.flag);
    }
}

test "everything else" {
    _ = @import("utils.zig");
    _ = @import("cli.zig");
    _ = @import("info.zig");
    _ = @import("wrapper.zig");
}
