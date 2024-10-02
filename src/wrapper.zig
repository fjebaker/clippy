const std = @import("std");
const testing = std.testing;

const utils = @import("utils.zig");
const cli = @import("cli.zig");
const completion = @import("completion.zig");

const Error = utils.Error;
const Arg = cli.Arg;

const ArgumentInfo = @import("info.zig").ArgumentInfo;
const CommandDescriptor = @import("main.zig").CommandDescriptor;

const ParseArgOutcome = enum {
    ParsedFlag,
    ParsedPositional,
    ParsedCommand,
    UnparsedFlag,
    UnparsedPositional,

    fn isParsed(o: ParseArgOutcome) bool {
        return switch (o) {
            .ParsedFlag,
            .ParsedPositional,
            .ParsedCommand,
            => true,
            else => false,
        };
    }
};

pub const HelpFormatting = struct {
    left_pad: usize = 4,
    help_len: usize = 48,
    centre_padding: usize = 26,
    indent: usize = 2,
};

fn WrapperInterface(
    comptime ArgIterator: type,
    comptime T: type,
    comptime P: type,
    comptime MethodTable: struct {
        initImpl: fn (*ArgIterator) T,
        parseArgImpl: fn (*T, Arg) anyerror!ParseArgOutcome,
        getParsedImpl: fn (*const T) anyerror!P,
        generateCompletionImpl: fn (std.mem.Allocator, completion.Opts, []const u8) anyerror![]const u8,
        writeHelpImpl: fn (anytype, comptime HelpFormatting) anyerror!void,
    },
) type {
    return struct {
        pub const Parsed = P;
        const Methods = MethodTable;
        const Self = @This();

        t: T,

        fn parseArgImpl(self: *Self, arg: Arg) anyerror!ParseArgOutcome {
            return try Methods.parseArgImpl(&self.t, arg);
        }

        fn generateCompletionImpl(
            allocator: std.mem.Allocator,
            shell: completion.Shell,
            name: []const u8,
        ) ![]const u8 {
            return try Methods.generateCompletionImpl(
                allocator,
                .{ .shell = shell },
                name,
            );
        }

        pub fn init(itt: *ArgIterator) Self {
            return .{ .t = Methods.initImpl(itt) };
        }

        /// Write the shell completion script for a given `Shell`
        pub fn generateCompletion(
            allocator: std.mem.Allocator,
            shell: completion.Shell,
            name: []const u8,
        ) ![]const u8 {
            return try generateCompletionImpl(allocator, shell, name);
        }

        /// Parse the arguments from the argument iterator. This method is to
        /// be fed one argument at a time. Returns `false` if the argument was
        /// not used, allowing other parsing code to be used in tandem.
        pub fn parseArg(self: *Self, arg: Arg) !bool {
            const outcome = try self.parseArgImpl(arg);
            return outcome.isParsed();
        }

        /// Parse the arguments from the argument iterator. This method is to
        /// be fed one argument at a time. Returns `false` if the argument was
        /// not used, allowing other parsing code to be used in tandem. Will
        /// not raise any errors if the argument parsing is invalid.
        pub fn parseArgForgiving(self: *Self, arg: Arg) bool {
            const outcome = self.parseArgImpl(arg) catch
                return false;
            return outcome.isParsed();
        }

        /// Parses all arguments and exhausts the `ArgIterator`. Returns a
        /// structure containing all the arguments.
        pub fn parseAll(itt: *ArgIterator) !Parsed {
            var self = Self.init(itt);
            while (try itt.next()) |arg| {
                switch (try self.parseArgImpl(arg)) {
                    .UnparsedFlag => try itt.throwUnknownFlag(),
                    .UnparsedPositional => try itt.throwTooManyArguments(),
                    else => {},
                }
            }
            return self.getParsed();
        }

        pub const ParsedPositional = struct {
            parsed: Parsed,
            positional: []const Arg,
        };

        /// Parses all arguments and exhausts the `ArgIterator`. Returns a
        /// structure containing all the arguments and the unparsed positional
        /// arguments. Called must call `deinit`.
        pub fn parseAllKeepPositional(
            allocator: std.mem.Allocator,
            itt: *ArgIterator,
        ) !ParsedPositional {
            var list = std.ArrayList(Arg).init(allocator);
            defer list.deinit();

            var self = Self.init(itt);
            while (try itt.next()) |arg| {
                switch (try self.parseArgImpl(arg)) {
                    .UnparsedFlag => try itt.throwUnknownFlag(),
                    .UnparsedPositional => {
                        try list.append(arg);
                    },
                    else => {},
                }
            }
            return .{
                .parsed = try self.getParsed(),
                .positional = try list.toOwnedSlice(),
            };
        }

        /// Parses all arguments and exhausts the `ArgIterator`. Returns a
        /// structure containing all the arguments.  Will not raise any errors
        /// if the argument parsing is invalid.
        pub fn parseAllForgiving(itt: *ArgIterator) ?Parsed {
            var self = Self.init(itt);
            while (itt.next() catch return null) |arg| {
                _ = self.parseArgImpl(arg) catch return null;
            }
            return self.getParsed() catch return null;
        }

        /// Get the parsed argument structure and validate that all required
        /// fields have values.
        pub fn getParsed(self: *const Self) !Parsed {
            return try Methods.getParsedImpl(&self.t);
        }

        /// Write the help string for the arguments
        pub fn writeHelp(writer: anytype, comptime opts: HelpFormatting) !void {
            return try Methods.writeHelpImpl(writer, opts);
        }
    };
}

pub fn CommandsWrapper(
    comptime ArgIterator: type,
    comptime Mutual: type,
    comptime CommandsT: type,
    // this is the arguments container
    comptime CommandsParsed: type,
    comptime CommandDescriptors: []const CommandDescriptor,
    comptime fallback: bool,
) type {
    const has_mutual = @typeInfo(Mutual) != .void;
    const MutualParsed = if (has_mutual)
        Mutual.Parsed
    else
        void;

    const CommandTFields = @typeInfo(CommandsT).@"union".fields;
    const fallback_index = CommandTFields.len - 1;

    const Parsed = struct {
        mutual: MutualParsed,
        commands: CommandsParsed,
    };

    const InnerType = struct {
        const InnerType = @This();
        itt: *ArgIterator,
        mutual: Mutual,
        commands: ?CommandsT = null,

        fn initImpl(itt: *ArgIterator) InnerType {
            return .{
                .mutual = if (has_mutual) Mutual.init(itt) else {},
                .itt = itt,
            };
        }

        fn writeHelpImpl(writer: anytype, comptime help_opts: HelpFormatting) !void {
            if (has_mutual) {
                try writer.writeAll("General arguments:\n\n");
                try Mutual.writeHelp(writer, help_opts);
                try writer.writeAll("\n");
            }

            try writer.writeAll("Commands:\n");
            inline for (CommandTFields, 0..) |field, index| {
                if (fallback and fallback_index == index) {
                    try writer.print("\n <{s}>\n", .{field.name});
                } else {
                    try writer.print("\n {s}\n", .{field.name});
                }
                try field.type.writeHelp(writer, help_opts);
            }
        }

        fn getCommandsParsed(self: *const InnerType) !CommandsParsed {
            const cmds = self.commands orelse return Error.MissingCommand;
            inline for (CommandTFields) |field| {
                if (std.mem.eql(u8, @tagName(cmds), field.name)) {
                    var active = @field(cmds, field.name);
                    return @unionInit(
                        CommandsParsed,
                        field.name,
                        try active.getParsed(),
                    );
                }
            }
            return Error.MissingCommand;
        }

        fn getParsedImpl(self: *const InnerType) anyerror!Parsed {
            return .{
                .mutual = if (has_mutual) try self.mutual.getParsed() else {},
                .commands = try self.getCommandsParsed(),
            };
        }

        fn parseCommandString(self: *InnerType, s: []const u8) bool {
            inline for (CommandTFields, 0..) |field, index| {
                const is_fallback = fallback and (index == fallback_index);
                const name_matches = std.mem.eql(u8, s, field.name);
                if (is_fallback or name_matches) {
                    const instance = @field(field.type, "init")(
                        self.itt,
                    );
                    self.commands = @unionInit(
                        CommandsT,
                        field.name,
                        instance,
                    );
                    if (is_fallback) {
                        _ = @field(self.commands.?, field.name).parseArgImpl(
                            .{ .flag = false, .string = s },
                        ) catch unreachable;
                    }
                    return true;
                }
            }
            return false;
        }

        fn parseArgImpl(self: *InnerType, arg: Arg) anyerror!ParseArgOutcome {
            if (self.commands) |*commands| {
                switch (commands.*) {
                    inline else => |*c| {
                        const ret = try c.parseArgImpl(arg);
                        if (ret.isParsed()) return ret;
                    },
                }
            } else if (!arg.flag) {
                if (self.parseCommandString(arg.string)) {
                    return .ParsedCommand;
                }
            }

            if (has_mutual) {
                return try self.mutual.parseArgImpl(arg);
            } else {
                if (arg.flag) {
                    return .UnparsedFlag;
                } else {
                    return .UnparsedPositional;
                }
            }
        }

        /// TODO: not implemented yet
        fn generateCompletionImpl(
            allocator: std.mem.Allocator,
            opts: completion.Opts,
            name: []const u8,
        ) ![]const u8 {
            var writer = std.ArrayList(u8).init(allocator);
            defer writer.deinit();

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // write the completion functions for each sub command
            inline for (CommandTFields) |field| {
                const T = utils.TagType(CommandsT, field.name);

                const full_name = try std.mem.join(
                    alloc,
                    "_",
                    &.{ name, "sub", field.name },
                );
                const c = try T.generateCompletion(
                    alloc,
                    opts.shell,
                    full_name,
                );

                try writer.appendSlice(c);
            }

            var case_body = std.ArrayList(u8).init(alloc);
            try case_body.appendSlice("    case $line[1] in\n");

            try writer.writer().print(
                \\_arguments_{s}() {{
                \\    local line state subcmds
                \\    subcmds=(
                \\
            , .{name});
            inline for (CommandDescriptors) |cd| {
                try writer.writer().print(
                    \\        '{s}:{s}'
                    \\
                , .{ cd.name, cd.help });

                const match = if (cd.fallback)
                    "*"
                else
                    cd.name;

                try case_body.writer().print(
                    \\        {s})
                    \\            _arguments_{s}_sub_{s}
                    \\        ;;
                    \\
                , .{ match, name, cd.name });
            }
            try case_body.appendSlice("    esac\n");

            try writer.appendSlice(
                \\    )
                \\    _arguments \
                \\        '1: :{_describe 'command' subcmds}' \
                \\        '*:: :->args'
                \\
            );
            try writer.appendSlice(case_body.items);
            try writer.appendSlice("}\n");

            return writer.toOwnedSlice();
        }
    };

    return WrapperInterface(
        ArgIterator,
        InnerType,
        Parsed,
        .{
            .initImpl = InnerType.initImpl,
            .parseArgImpl = InnerType.parseArgImpl,
            .getParsedImpl = InnerType.getParsedImpl,
            .generateCompletionImpl = InnerType.generateCompletionImpl,
            .writeHelpImpl = InnerType.writeHelpImpl,
        },
    );
}

pub fn ArgumentsWrapper(
    comptime ArgIterator: type,
    comptime infos: []const ArgumentInfo,
    comptime T: type,
) type {
    const Mask = std.bit_set.StaticBitSet(infos.len);
    const Parsed = T;

    const InnerType = struct {
        const InnerType = @This();
        itt: *ArgIterator,
        parsed: Parsed = .{},
        mask: Mask,

        fn initImpl(itt: *ArgIterator) InnerType {
            return .{
                .itt = itt,
                .mask = Mask.initEmpty(),
            };
        }

        fn writeHelpImpl(writer: anytype, comptime help_opts: HelpFormatting) !void {
            inline for (infos) |info| {

                // skip those that are not to be shown in the help
                if (info.getDescriptor().show_help == false) continue;

                try writer.writeByteNTimes(' ', help_opts.left_pad);
                // print the argument itself
                const name = switch (info) {
                    inline else => |i| i.descriptor.arg,
                };

                if (info.isRequired()) {
                    try writer.print("<{s}>", .{name});
                } else {
                    try writer.print("[{s}]", .{name});
                }
                try writer.writeByteNTimes(
                    ' ',
                    help_opts.centre_padding -| (name.len + 2),
                );

                comptime var help_string = info.getHelp();
                if (info.getDescriptor().default) |d| {
                    help_string = help_string ++ std.fmt.comptimePrint(" (default: {s}).", .{d});
                }
                try utils.writeWrapped(writer, help_string, .{
                    .left_pad = help_opts.left_pad + help_opts.centre_padding,
                    .continuation_indent = help_opts.indent,
                    .column_limit = help_opts.help_len,
                });

                try writer.writeByte('\n');
            }
        }

        fn parseArgImpl(self: *InnerType, arg: Arg) anyerror!ParseArgOutcome {
            return try parseInto(
                &self.parsed,
                &self.mask,
                arg,
                self.itt,
            );
        }

        fn getParsedImpl(self: *const InnerType) !Parsed {
            if (checkUnsetRequireds(self.mask)) |unset_name| {
                return ArgIterator.throwError(
                    Error.MissingArgument,
                    "missing argument '{s}'",
                    .{unset_name},
                );
            }
            return self.parsed;
        }

        fn checkUnsetRequireds(
            mask: Mask,
        ) ?[]const u8 {
            inline for (infos, 0..) |info, i| {
                if (info.isRequired() and !mask.isSet(i)) {
                    return info.getName();
                }
            }
            return null;
        }

        fn parseInto(
            args: *T,
            mask: *Mask,
            arg: Arg,
            itt: *ArgIterator,
        ) !ParseArgOutcome {
            inline for (infos, 0..) |info, i| {
                const arg_name = comptime info.getName();
                switch (info) {
                    .Flag => |f| {
                        const match = switch (f.flag_type) {
                            .Short => arg.is(f.name[0], null),
                            .Long => arg.is(null, f.name),
                            .ShortAndLong => arg.is(f.short_name.?[0], f.name),
                        };
                        if (match) {
                            if (mask.isSet(i)) return Error.DuplicateFlag;
                            if (f.with_value) {
                                const next = try itt.getValue();
                                errdefer itt.rewind();
                                @field(args, arg_name) = try info.parseString(
                                    next.string,
                                );
                            } else {
                                @field(args, arg_name) = true;
                            }
                            mask.set(i);
                            return .ParsedFlag;
                        }
                    },
                    .Positional => {
                        if (!arg.flag and !mask.isSet(i)) {
                            @field(args, arg_name) = try info.parseString(
                                arg.string,
                            );
                            mask.set(i);
                            return .ParsedPositional;
                        }
                    },
                }
            }

            if (arg.flag) {
                return .UnparsedFlag;
            } else {
                return .UnparsedPositional;
            }
        }

        fn generateCompletionImpl(
            allocator: std.mem.Allocator,
            shell: completion.Opts,
            name: []const u8,
        ) anyerror![]const u8 {
            // TODO: make this dispatch on different shells correctly
            _ = shell;

            var writer = try completion.CompletionWriter.init(allocator);
            defer writer.deinit();
            const Comp = completion.ZshCompletionWriter;

            inline for (infos) |info| {
                switch (info) {
                    .Flag => |f| {
                        switch (f.flag_type) {
                            .ShortAndLong => try Comp.writeShortLongFlag(
                                &writer,
                                f.short_name.?,
                                f.name,
                                .{
                                    .action = f.descriptor.completion,
                                },
                            ),
                            .Long => try Comp.writeLongFlag(
                                &writer,
                                f.name,
                                .{
                                    .action = f.descriptor.completion,
                                },
                            ),
                            .Short => try Comp.writeShortFlag(
                                &writer,
                                f.name,
                                .{
                                    .action = f.descriptor.completion,
                                },
                            ),
                        }
                    },
                    .Positional => |p| try Comp.writePositional(
                        &writer,
                        p.name,
                        .{
                            .action = p.descriptor.completion,
                            .optional = !p.descriptor.required,
                        },
                    ),
                }
            }

            return try writer.finalize(name);
        }
    };

    return WrapperInterface(
        ArgIterator,
        InnerType,
        Parsed,
        .{
            .initImpl = InnerType.initImpl,
            .parseArgImpl = InnerType.parseArgImpl,
            .getParsedImpl = InnerType.getParsedImpl,
            .generateCompletionImpl = InnerType.generateCompletionImpl,
            .writeHelpImpl = InnerType.writeHelpImpl,
        },
    );
}
