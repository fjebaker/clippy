const std = @import("std");
const testing = std.testing;

const utils = @import("utils.zig");
const ArgumentInfo = @import("info.zig").ArgumentInfo;

const wrapper = @import("wrapper.zig");
const ParserWrapper = wrapper.ParserWrapper;
const ParserCommandWrapper = wrapper.ParserCommandWrapper;

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

/// Command descriptor for specifying arguments for subcommands
pub const CommandDescriptor = struct {
    /// Command name
    name: []const u8,

    /// Arguments associated with this subcommand
    args: type,

    fn toUnionField(
        comptime cmd: CommandDescriptor,
        comptime parsed_type: bool,
    ) std.builtin.Type.UnionField {
        if (!utils.allValidPositionalChars(cmd.name))
            @compileError("Invalid command name");

        const T = if (parsed_type) cmd.args.Parsed else cmd.args;
        return .{
            .name = @ptrCast(cmd.name),
            .type = T,
            .alignment = @alignOf(T),
        };
    }
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

pub const CommandsOptions = struct {
    mutual: type = void,
    commands: []const CommandDescriptor,
};

pub fn Commands(comptime opts: CommandsOptions) type {
    // TODO: find some way of enforcing that the args type in the command
    // descriptor is actually the correct arguments type

    comptime var union_fields: []const std.builtin.Type.UnionField = &.{};
    inline for (opts.commands) |cmd| {
        union_fields = union_fields ++ .{cmd.toUnionField(false)};
    }

    comptime var parsed_fields: []const std.builtin.Type.UnionField = &.{};
    inline for (opts.commands) |cmd| {
        parsed_fields = parsed_fields ++ .{cmd.toUnionField(true)};
    }

    comptime var enum_fields: []const std.builtin.Type.EnumField = &.{};
    inline for (opts.commands, 0..) |cmd, i| {
        const field: std.builtin.Type.EnumField = .{
            .name = @ptrCast(cmd.name),
            .value = i,
        };
        enum_fields = enum_fields ++ .{field};
    }

    const tag_enum = @Type(.{ .Enum = .{
        .tag_type = usize,
        .fields = enum_fields,
        .decls = &.{},
        .is_exhaustive = false,
    } });

    const CommandsType = @Type(
        .{ .Union = .{
            .layout = .Auto,
            .tag_type = tag_enum,
            .fields = union_fields,
            .decls = &.{},
        } },
    );

    const InternalType = @Type(
        .{ .Union = .{
            .layout = .Auto,
            .tag_type = tag_enum,
            .fields = parsed_fields,
            .decls = &.{},
        } },
    );

    return ParserCommandWrapper(opts, CommandsType, InternalType);
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

const MoreTestArguments = [_]ArgumentDescriptor{
    .{
        .arg = "item",
        .help = "Positional argument.",
        .required = true,
    },
    .{
        .arg = "-c/--control",
        .help = "Toggleable",
    },
};

const MutualTestArguments = [_]ArgumentDescriptor{
    .{
        .arg = "--interactive",
        .help = "Toggleable",
    },
};

test "commands" {
    const Args1 = Arguments(&TestArguments);
    const Args2 = Arguments(&MoreTestArguments);
    const Mutuals = Arguments(&MutualTestArguments);

    const Cmds = Commands(
        .{ .mutual = Mutuals, .commands = &.{
            .{ .name = "hello", .args = Args1 },
            .{ .name = "world", .args = Args2 },
        } },
    );

    {
        const parsed = try parseArgs(
            Cmds,
            "hello abc --flag",
        );
        try testing.expectEqual(false, parsed.mutual.interactive);
        const c = parsed.commands.hello;
        try testing.expectEqualStrings("abc", c.item);
        try testing.expectEqual(true, c.flag);
    }

    {
        const parsed = try parseArgs(
            Cmds,
            "hello abc --interactive",
        );
        try testing.expectEqual(true, parsed.mutual.interactive);
        const c = parsed.commands.hello;
        try testing.expectEqualStrings("abc", c.item);
    }

    {
        // TODO: need to check for unknown flags too
        const parsed = try parseArgs(
            Cmds,
            "hello abc --control",
        );
        try testing.expectEqual(false, parsed.mutual.interactive);
        const c = parsed.commands.hello;
        try testing.expectEqualStrings("abc", c.item);
        try testing.expectEqual(false, c.flag);
    }
}

test "everything else" {
    _ = @import("utils.zig");
    _ = @import("cli.zig");
    _ = @import("info.zig");
    _ = @import("wrapper.zig");
}
