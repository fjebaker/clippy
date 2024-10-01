const std = @import("std");
const testing = std.testing;

const utils = @import("utils.zig");
const ArgumentInfo = @import("info.zig").ArgumentInfo;

const wrapper = @import("wrapper.zig");

const UnionField = std.builtin.Type.UnionField;
const EnumField = std.builtin.Type.EnumField;

pub const cli = @import("cli.zig");

pub const ComptimeError = utils.ComptimeError;
pub const RuntimeError = utils.RuntimeError;
pub const Error = utils.Error;

pub const WrappingOptions = utils.WrappingOptions;
pub const HelpFormatting = wrapper.HelpFormatting;
pub const comptimeWrap = utils.comptimeWrap;
pub const writeWrapped = utils.writeWrapped;

pub fn ClippyInterface(
    comptime options: cli.ArgumentIteratorOptions,
) type {
    return struct {
        pub const ArgIterator = cli.ArgumentIterator(options);

        pub fn Commands(comptime opts: CommandsOptions) type {
            const Mutual = Arguments(opts.mutual);

            comptime var union_fields: []const UnionField = &.{};
            comptime var parsed_fields: []const UnionField = &.{};
            comptime var enum_fields: []const EnumField = &.{};

            comptime var fallback: bool = false;
            comptime var fallback_completion: ?[]const u8 = null;

            inline for (opts.commands, 0..) |cmd, i| {
                if (!cmd.fallback and cmd.completion != null)
                    @compileError("Can only provide completion for the fallback command");
                if (fallback and cmd.fallback)
                    @compileError("Only one command may be specified as the fallback command");

                if (cmd.fallback) {
                    fallback = true;
                    fallback_completion = cmd.completion;
                }

                const Args = Arguments(cmd.getArgumentDescriptors());

                union_fields = union_fields ++ .{UnionField{
                    .name = @ptrCast(cmd.name),
                    .type = Args,
                    .alignment = @alignOf(Args),
                }};

                parsed_fields = parsed_fields ++ .{UnionField{
                    .name = @ptrCast(cmd.name),
                    .type = Args.Parsed,
                    .alignment = @alignOf(Args.Parsed),
                }};

                const field: EnumField = .{
                    .name = @ptrCast(cmd.name),
                    .value = i,
                };
                enum_fields = enum_fields ++ .{field};
            }

            const tag_enum = @Type(.{ .@"enum" = .{
                .tag_type = usize,
                .fields = enum_fields,
                .decls = &.{},
                .is_exhaustive = false,
            } });

            const CommandsType = @Type(
                .{ .@"union" = .{
                    .layout = .auto,
                    .tag_type = tag_enum,
                    .fields = union_fields,
                    .decls = &.{},
                } },
            );

            const InternalType = @Type(
                .{ .@"union" = .{
                    .layout = .auto,
                    .tag_type = tag_enum,
                    .fields = parsed_fields,
                    .decls = &.{},
                } },
            );

            return wrapper.CommandsWrapper(
                ArgIterator,
                Mutual,
                CommandsType,
                InternalType,
                opts.commands,
                fallback,
            );
        }

        /// Create an Arguments wrapper for parsing arguments for a given set
        /// of argument descriptors.
        ///
        /// The resulting struct has the standard wrapper interface and defined
        /// the following methods:
        /// - `fn generateCompletion(Allocator, Shell, []const u8) ![]const u8`
        /// - `fn writeHelp(writer, HelpFormatting) !void`
        ///
        /// - `fn parseArg(Arg) !bool`
        /// - `fn parseArgForgiving(Arg) bool`
        /// - `fn getParsed(*ArgIterator) !Parsed`
        ///
        /// - `fn parseAll(*ArgIterator) !Parsed`
        /// - `fn parseAllForgiving(*ArgIterator) ?Parsed`
        ///
        /// Most standard usage will only need to use `parseAll`.
        pub fn Arguments(comptime args: []const ArgumentDescriptor) type {
            const infos = parseableInfo(args);

            // create the fields for returning the arguments
            comptime var fields: []const std.builtin.Type.StructField = &.{};
            inline for (infos) |info| {
                fields = fields ++ .{info.toField()};
            }

            const InternalType = @Type(
                .{ .@"struct" = .{
                    .layout = .auto,
                    .is_tuple = false,
                    .fields = fields,
                    .decls = &.{},
                } },
            );

            return wrapper.ArgumentsWrapper(ArgIterator, infos, InternalType);
        }
    };
}

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

    /// Default argument value.
    default: ?[]const u8 = null,

    /// Help string
    help: []const u8,

    /// Should the argument be shown in the help?
    show_help: bool = true,

    /// Is a required argument
    required: bool = false,

    /// Should be parsed by the helper
    parse: bool = true,

    /// Completion function used to generate completion hints
    completion: ?[]const u8 = null,
};

/// Command descriptor for specifying arguments for subcommands
pub const CommandDescriptor = struct {
    /// Command name
    name: []const u8,

    /// Help string
    help: []const u8,

    /// Arguments associated with this subcommand
    args: []const ArgumentDescriptor,

    /// Will match any other command string. There can only be one command with
    /// fallback active
    fallback: bool = false,

    /// Only valid for the fallback option. A string used to generate the shell
    /// completion for this argument.
    completion: ?[]const u8 = null,

    fn getArgumentDescriptors(
        comptime cmd: CommandDescriptor,
    ) []const ArgumentDescriptor {
        if (!utils.allValidPositionalChars(cmd.name))
            @compileError("Invalid command name: " ++ cmd.name);

        // TODO: fallback adds an argument
        const args = b: {
            if (cmd.fallback) {
                break :b .{ArgumentDescriptor{
                    .arg = cmd.name,
                    .help = "",
                    .show_help = false,
                    .required = true,
                }} ++ cmd.args;
            } else {
                break :b cmd.args;
            }
        };

        return args;
    }
};

pub const CommandsOptions = struct {
    mutual: []const ArgumentDescriptor = &.{},
    commands: []const CommandDescriptor,
};

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
        .completion = "{compadd $(ls -1)}",
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

const TestClippy = ClippyInterface(.{});

fn parseArgs(comptime T: type, comptime string: []const u8) !T.Parsed {
    const arg_strings = try utils.fromString(
        std.testing.allocator,
        string,
    );
    defer std.testing.allocator.free(arg_strings);
    var argitt = TestClippy.ArgIterator.init(arg_strings);

    var parser = T.init(&argitt);
    while (try argitt.next()) |arg| {
        _ = try parser.parseArg(arg);
    }

    return try parser.getParsed();
}

fn parseArgsForgiving(comptime T: type, comptime string: []const u8) !T.Parsed {
    const arg_strings = try utils.fromString(
        std.testing.allocator,
        string,
    );
    defer std.testing.allocator.free(arg_strings);
    var argitt = TestClippy.ArgIterator.init(arg_strings);

    var parser = T.init(&argitt);
    while (try argitt.next()) |arg| {
        _ = parser.parseArgForgiving(arg);
    }

    return try parser.getParsed();
}

test "example arguments" {
    const Args = TestClippy.Arguments(&TestArguments);
    const fields = @typeInfo(Args.Parsed).@"struct".fields;
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

    {
        const parsed = try parseArgsForgiving(
            Args,
            "hello --flag --limit",
        );
        try testing.expectEqual(parsed.limit, null);
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
    const Args1 = &TestArguments;
    const Args2 = &MoreTestArguments;
    const Mutuals = &MutualTestArguments;

    const Cmds = TestClippy.Commands(
        .{ .mutual = Mutuals, .commands = &.{
            .{ .name = "hello", .args = Args1, .help = "Hello command" },
            .{ .name = "world", .args = Args2, .help = "world command" },
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

    const CmdsNoMutual = TestClippy.Commands(
        .{ .commands = &.{
            .{ .name = "hello", .args = Args1, .help = "hello command" },
            .{ .name = "world", .args = Args2, .help = "world command" },
        } },
    );

    {
        const parsed = try parseArgs(
            CmdsNoMutual,
            "world abc",
        );
        const c = parsed.commands.world;
        try testing.expectEqualStrings("abc", c.item);
    }
}

test "commands-fallback" {
    const Args1 = &TestArguments;
    const Args2 = &MoreTestArguments;
    const Mutuals = &MutualTestArguments;

    const CmdsWildcard = TestClippy.Commands(
        .{ .mutual = Mutuals, .commands = &.{
            .{ .name = "hello", .args = Args1, .help = "hello command" },
            .{ .name = "world", .args = Args2, .help = "world command" },
            .{
                .name = "other",
                .args = Args2,
                .fallback = true,
                .help = "other command",
            },
        } },
    );

    {
        const parsed = try parseArgs(
            CmdsWildcard,
            "hello abc --flag",
        );
        try testing.expectEqual(false, parsed.mutual.interactive);
        const c = parsed.commands.hello;
        try testing.expectEqualStrings("abc", c.item);
        try testing.expectEqual(true, c.flag);
    }

    {
        const parsed = try parseArgs(
            CmdsWildcard,
            "big other -c",
        );
        try testing.expectEqual(false, parsed.mutual.interactive);
        const c = parsed.commands.other;
        try testing.expectEqualStrings("big", c.other);
        try testing.expectEqualStrings("other", c.item);
        try testing.expectEqual(true, c.control);
    }

    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const writer = list.writer();

    try CmdsWildcard.writeHelp(writer, .{});

    try testing.expectEqualStrings(
        \\General arguments:
        \\
        \\    [--interactive]           Toggleable
        \\
        \\Commands:
        \\
        \\ hello
        \\    <item>                    Positional argument.
        \\    [-n/--limit value]        Limit.
        \\    [other]                   Another positional
        \\    [-f/--flag]               Toggleable
        \\
        \\ world
        \\    <item>                    Positional argument.
        \\    [-c/--control]            Toggleable
        \\
        \\ <other>
        \\    <item>                    Positional argument.
        \\    [-c/--control]            Toggleable
        \\
    , list.items);

    const comp1 = try CmdsWildcard.generateCompletion(testing.allocator, .Zsh, "name");
    defer testing.allocator.free(comp1);

    try testing.expectEqualStrings(
        \\_arguments_name_sub_hello() {
        \\    _arguments -C \
        \\        ':item:()' \
        \\        '--limit[]:limit:{compadd $(ls -1)}' \
        \\        '-n[]:n:{compadd $(ls -1)}' \
        \\        '::other:()' \
        \\        '--flag[]::()' \
        \\        '-f[]::()'
        \\}
        \\_arguments_name_sub_world() {
        \\    _arguments -C \
        \\        ':item:()' \
        \\        '--control[]::()' \
        \\        '-c[]::()'
        \\}
        \\_arguments_name_sub_other() {
        \\    _arguments -C \
        \\        ':other:()' \
        \\        ':item:()' \
        \\        '--control[]::()' \
        \\        '-c[]::()'
        \\}
        \\_arguments_name() {
        \\    local line state subcmds
        \\    subcmds=(
        \\        'hello:hello command'
        \\        'world:world command'
        \\        'other:other command'
        \\    )
        \\    _arguments \
        \\        '1:command:subcmds' \
        \\        '*::arg:->args'
        \\    case $line[1] in
        \\        hello)
        \\            _arguments_name_sub_hello
        \\        ;;
        \\        world)
        \\            _arguments_name_sub_world
        \\        ;;
        \\        *)
        \\            _arguments_name_sub_other
        \\        ;;
        \\    esac
        \\}
        \\
    , comp1);
}

test "everything else" {
    _ = @import("utils.zig");
    _ = @import("cli.zig");
    _ = @import("info.zig");
    _ = @import("wrapper.zig");
}

test "argument completion" {
    const Args1 = TestClippy.Arguments(&TestArguments);
    const comp1 = try Args1.generateCompletion(testing.allocator, .Zsh, "name");
    defer testing.allocator.free(comp1);

    try testing.expectEqualStrings(
        \\_arguments_name() {
        \\    _arguments -C \
        \\        ':item:()' \
        \\        '--limit[]:limit:{compadd $(ls -1)}' \
        \\        '-n[]:n:{compadd $(ls -1)}' \
        \\        '::other:()' \
        \\        '--flag[]::()' \
        \\        '-f[]::()'
        \\}
        \\
    , comp1);
}

test "argument help" {
    const Args1 = TestClippy.Arguments(&TestArguments);

    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const writer = list.writer();
    try Args1.writeHelp(writer, .{});

    try testing.expectEqualStrings(
        \\    <item>                    Positional argument.
        \\    [-n/--limit value]        Limit.
        \\    [other]                   Another positional
        \\    [-f/--flag]               Toggleable
        \\
    , list.items);
}

test "commands help" {
    const Args1 = &TestArguments;
    const Args2 = &MoreTestArguments;
    const Mutuals = &MutualTestArguments;

    const Cmds = TestClippy.Commands(
        .{ .mutual = Mutuals, .commands = &.{
            .{ .name = "hello", .args = Args1, .help = "hello command" },
            .{ .name = "world", .args = Args2, .help = "world command" },
        } },
    );

    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const writer = list.writer();
    try Cmds.writeHelp(writer, .{});

    try testing.expectEqualStrings(
        \\General arguments:
        \\
        \\    [--interactive]           Toggleable
        \\
        \\Commands:
        \\
        \\ hello
        \\    <item>                    Positional argument.
        \\    [-n/--limit value]        Limit.
        \\    [other]                   Another positional
        \\    [-f/--flag]               Toggleable
        \\
        \\ world
        \\    <item>                    Positional argument.
        \\    [-c/--control]            Toggleable
        \\
    , list.items);
}

const TestArgumentsDefault = [_]ArgumentDescriptor{
    .{
        .arg = "default_item",
        .help = "Positional argument",
        .default = "hello",
    },
    .{
        .arg = "default_thing",
        .help = "Positional argument",
        .argtype = usize,
        .default = "88",
    },
};

test "default values arguments" {
    const Args = TestClippy.Arguments(&TestArgumentsDefault);

    const parsed = try parseArgs(
        Args,
        "",
    );
    try testing.expectEqualStrings(parsed.default_item, "hello");
    try testing.expectEqual(parsed.default_thing, 88);

    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const writer = list.writer();
    try Args.writeHelp(writer, .{});

    try testing.expectEqualStrings(
        \\    [default_item]            Positional argument (default: hello).
        \\    [default_thing]           Positional argument (default: 88).
        \\
    , list.items);
}
