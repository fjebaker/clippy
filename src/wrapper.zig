const std = @import("std");
const testing = std.testing;

const utils = @import("utils.zig");
const cli = @import("cli.zig");

const Error = utils.Error;
const Arg = cli.Arg;
const ArgIterator = cli.ArgIterator;

const ArgumentInfo = @import("info.zig").ArgumentInfo;

pub fn ParserWrapper(
    comptime infos: []const ArgumentInfo,
    comptime T: type,
) type {
    const Mask = std.bit_set.StaticBitSet(infos.len);

    const ParseArgOutcome = enum {
        ParsedFlag,
        ParsedPositional,
        UnparsedFlag,
        UnparsedPositional,
    };

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
            return switch (try self.parseArgImpl(arg)) {
                .ParsedFlag, .ParsedPositional => true,
                .UnparsedFlag, .UnparsedPositional => false,
            };
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
