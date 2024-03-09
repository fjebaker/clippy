const std = @import("std");
const testing = std.testing;

const utils = @import("utils.zig");
const cli = @import("cli.zig");

const Error = utils.Error;
const Arg = cli.Arg;
const ArgIterator = cli.ArgIterator;

const ArgumentInfo = @import("info.zig").ArgumentInfo;
const CommandsOptions = @import("main.zig").CommandsOptions;

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

pub fn ParserCommandWrapper(
    comptime opts: CommandsOptions,
    comptime CommandsT: type,
    comptime CommandsParsed: type,
) type {
    const MutualParsed = opts.mutual.Parsed;

    return struct {
        const Self = @This();

        itt: *ArgIterator,
        mutual: opts.mutual,
        commands: ?CommandsT = null,

        pub const Parsed = struct {
            mutual: MutualParsed,
            commands: CommandsParsed,
        };

        pub fn init(itt: *ArgIterator) Self {
            return .{
                .mutual = opts.mutual.init(itt),
                .itt = itt,
            };
        }

        /// Parse the arguments from the argument iterator. This method is to
        /// be fed one argument at a time. Returns `false` if the argument was
        /// not used, allowing other parsing code to be used in tandem.
        pub fn parseArg(self: *Self, arg: Arg) !bool {
            const outcome = try self.parseArgImpl(arg);
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

        fn getCommandsParsed(self: *Self) !CommandsParsed {
            const cmds = self.commands orelse unreachable; // TODO: error
            inline for (@typeInfo(CommandsT).Union.fields) |field| {
                if (std.mem.eql(u8, @tagName(cmds), field.name)) {
                    var active = @field(cmds, field.name);
                    return @unionInit(
                        CommandsParsed,
                        field.name,
                        try active.getParsed(),
                    );
                }
            }
            // TODO: error
            unreachable;
        }

        pub fn getParsed(self: *Self) !Parsed {
            return .{
                .mutual = try self.mutual.getParsed(),
                .commands = try self.getCommandsParsed(),
            };
        }

        fn instanceCommand(self: *Self, s: []const u8) bool {
            inline for (@typeInfo(CommandsT).Union.fields) |field| {
                if (std.mem.eql(u8, s, field.name)) {
                    const instance = @field(field.type, "init")(
                        self.itt,
                    );
                    self.commands = @unionInit(
                        CommandsT,
                        field.name,
                        instance,
                    );
                    return true;
                }
            }
            return false;
        }

        fn parseArgImpl(self: *Self, arg: Arg) !ParseArgOutcome {
            if (self.commands) |*commands| {
                switch (commands.*) {
                    inline else => |*c| {
                        const ret = try c.parseArgImpl(arg);
                        if (ret.isParsed()) return ret;
                    },
                }
            } else if (!arg.flag) {
                if (self.instanceCommand(arg.string)) {
                    return .ParsedCommand;
                }
            }

            return try self.mutual.parseArgImpl(arg);
        }
    };
}

pub fn ParserWrapper(
    comptime infos: []const ArgumentInfo,
    comptime T: type,
) type {
    const Mask = std.bit_set.StaticBitSet(infos.len);

    const Methods = struct {
        pub fn checkUnsetRequireds(
            mask: Mask,
        ) ?[]const u8 {
            inline for (infos, 0..) |info, i| {
                if (info.isRequired() and !mask.isSet(i)) {
                    return info.getName();
                }
            }
            return null;
        }

        pub fn parseInto(
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
    };

    return struct {
        const Self = @This();
        const InternalMethods = Methods;
        pub const Parsed = T;

        itt: *ArgIterator,
        parsed: Parsed = .{},
        mask: Mask,

        pub fn init(itt: *ArgIterator) Self {
            return .{
                .itt = itt,
                .mask = Mask.initEmpty(),
            };
        }

        /// Parse the arguments from the argument iterator. This method is to
        /// be fed one argument at a time. Returns `false` if the argument was
        /// not used, allowing other parsing code to be used in tandem.
        pub fn parseArg(self: *Self, arg: Arg) !bool {
            const outcome = try self.parseArgImpl(arg);
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

        /// Get the parsed argument structure and validate that all required
        /// fields have values.
        pub fn getParsed(self: *const Self) !Parsed {
            if (Methods.checkUnsetRequireds(self.mask)) |name| {
                _ = name;
            }
            return self.parsed;
        }

        fn parseArgImpl(self: *Self, arg: Arg) !ParseArgOutcome {
            return try Methods.parseInto(
                &self.parsed,
                &self.mask,
                arg,
                self.itt,
            );
        }
    };
}
