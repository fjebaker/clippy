const std = @import("std");
const utils = @import("utils.zig");
const cli = @import("cli.zig");
const help = @import("help.zig");
const arguments = @import("arguments.zig");
const completion = @import("completion.zig");

pub const ParseError = error{
    DuplicateArgument,
    InvalidArgument,
    ExpectedPositional,
};

/// The argument parsing interface.
pub fn ArgParser(comptime A: anytype) type {
    const mode: enum { commands, arguments } = switch (@typeInfo(@TypeOf(A))) {
        .pointer => if (std.meta.Child(@TypeOf(A)) == arguments.Argument)
            .arguments
        else
            @compileError(std.fmt.comptimePrint(
                "Child of array must be Arguments (given '{any}')",
                .{std.meta.Child(A)},
            )),
        .type => if (@typeInfo(A) == .@"union")
            .commands
        else
            @compileError(std.fmt.comptimePrint(
                "Must be union type (given '{any}')",
                .{A},
            )),
        else => @compileError(std.fmt.comptimePrint(
            "Invalid argument type to ArgParse: '{any}'",
            .{A},
        )),
    };

    const SubParser = switch (mode) {
        .arguments => std.bit_set.StaticBitSet(A.len),
        .commands => ?A,
    };
    const sub_parser_init: SubParser = switch (mode) {
        .arguments => SubParser.initEmpty(),
        .commands => null,
    };

    return struct {
        const Self = @This();

        /// The generated struct that contains the parsed arguments.
        pub const Parsed = b: switch (mode) {
            .arguments => break :b ParsedType(A),
            .commands => {
                var union_fields: []const std.builtin.Type.UnionField = &.{};
                for (@typeInfo(A).@"union".fields) |field| {
                    union_fields = union_fields ++ .{std.builtin.Type.UnionField{
                        .name = field.name,
                        .type = field.type.Parsed,
                        .alignment = @alignOf(field.type.Parsed),
                    }};
                }

                break :b @Type(
                    .{ .@"union" = .{
                        .layout = .auto,
                        .tag_type = @typeInfo(A).@"union".tag_type,
                        .fields = union_fields,
                        .decls = &.{},
                    } },
                );
            },
        };

        /// Options for controlling the parser.
        pub const ParseOptions = struct {
            /// Do not throw errors but silently ignore them.
            forgiving: bool = false,
        };

        allocator: ?std.mem.Allocator = null,
        _sub_parser: SubParser = sub_parser_init,
        _parsed: Parsed = switch (mode) {
            .arguments => initWithDefaults(Parsed),
            .commands => undefined,
        },
        itt: *cli.ArgumentIterator,
        opts: ParseOptions,

        /// Initialise an argument parser with given options.
        pub fn init(itt: *cli.ArgumentIterator, opts: ParseOptions) Self {
            return .{ .itt = itt, .opts = opts };
        }

        fn commandsParseArg(self: *Self, arg: cli.Arg) !void {
            comptime {
                if (mode != .commands) @compileError("Must be in .commands mode");
            }

            if (self._sub_parser) |*sub_parser| {
                inline for (@typeInfo(A).@"union".fields) |field| {
                    if (std.mem.eql(
                        u8,
                        field.name,
                        @tagName(std.meta.activeTag(sub_parser.*)),
                    )) {
                        const p = &@field(sub_parser, field.name);
                        try p.parseArg(arg);
                        @field(self._parsed, field.name) = p._parsed;
                    }
                }
            } else {
                if (arg.flag) return ParseError.ExpectedPositional;
                inline for (@typeInfo(A).@"union".fields) |field| {
                    if (std.mem.eql(u8, field.name, arg.string)) {
                        self._parsed = @unionInit(
                            Parsed,
                            field.name,
                            initWithDefaults(field.type.Parsed),
                        );
                        const sub_parser_instance = @field(field.type, "init")(
                            self.itt,
                            self.opts,
                        );
                        self._sub_parser = @unionInit(
                            A,
                            field.name,
                            sub_parser_instance,
                        );
                    }
                }
            }
        }

        fn argumentsParseArg(self: *Self, arg: cli.Arg) !void {
            comptime {
                if (mode != .arguments) @compileError("Must be in .arguments mode");
            }
            inline for (A, 0..) |a, i| {
                if (a.matches(arg)) {
                    switch (a.info) {
                        .flag => |f| {
                            if (self._sub_parser.isSet(i))
                                return ParseError.DuplicateArgument;

                            if (f.accepts_value) {
                                const value = try self.itt.getValue();
                                @field(self._parsed, a.name) = try utils.parseStringAs(
                                    a.InnerType(),
                                    value,
                                );
                            } else {
                                @field(self._parsed, a.name) = true;
                            }

                            self._sub_parser.set(i);
                            return;
                        },
                        .positional => {
                            if (!self._sub_parser.isSet(i)) {
                                @field(self._parsed, a.name) = try utils.parseStringAs(
                                    a.InnerType(),
                                    arg.string,
                                );
                                self._sub_parser.set(i);
                                return;
                            }
                        },
                    }
                }
            }
            return ParseError.InvalidArgument;
        }

        fn parseArg(self: *Self, arg: cli.Arg) !void {
            return switch (mode) {
                .arguments => self.argumentsParseArg(arg),
                .commands => self.commandsParseArg(arg),
            };
        }

        /// Generate the shell completion. Caller owns the memory
        pub fn generateCompletion(allocator: std.mem.Allocator, opts: completion.Options) ![]const u8 {
            return switch (mode) {
                .arguments => try completion.generateCompletion(allocator, A, opts),
                .commands => unreachable,
            };
        }

        /// Write the help for this parser into the writer.
        pub fn writeHelp(writer: anytype, comptime opts: help.HelpOptions) !void {
            switch (mode) {
                .arguments => {
                    inline for (A) |arg| {
                        if (arg.desc.show_help) {
                            try help.helpArgument(writer, arg, opts);
                        }
                    }
                },
                .commands => {
                    inline for (@typeInfo(A).@"union".decls) |field| {
                        _ = field;
                    }
                },
            }
        }

        /// Callback functions that may be given to the parser with a specific context.
        pub fn ParseCallbacks(comptime T: type) type {
            return struct {
                /// Called during `InvalidArgument`
                unhandled_arg: *const fn (ctx: T, parser: *Self, arg: cli.Arg) anyerror!void,
            };
        }

        /// Parse all arguments with a context for controlling the callback functions.
        pub fn parseAllCtx(
            self: *Self,
            ctx: anytype,
            callbacks: ParseCallbacks(@TypeOf(ctx)),
        ) !Parsed {
            while (try self.itt.next()) |arg| {
                self.parseArg(arg) catch |err| {
                    switch (err) {
                        ParseError.InvalidArgument => try callbacks.unhandled_arg(ctx, self, arg),
                        else => if (!self.opts.forgiving) return err,
                    }
                };
            }
            return self._parsed;
        }

        /// Parse all arguments, returning the `Parsed` struct.
        pub fn parseAll(self: *Self) !Parsed {
            const Ctx = struct {
                fn unhandled_arg(_: @This(), _: *Self, _: cli.Arg) anyerror!void {
                    return ParseError.InvalidArgument;
                }
            };

            return try self.parseAllCtx(Ctx{}, .{ .unhandled_arg = Ctx.unhandled_arg });
        }
    };
}

fn initWithDefaults(comptime T: type) T {
    var init_parsed: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.default_value) |ptr| {
            const default_value = @as(
                *align(1) const field.type,
                @ptrCast(ptr),
            ).*;
            @field(init_parsed, field.name) = default_value;
        }
    }
    return init_parsed;
}

fn ParsedType(comptime args: []const arguments.Argument) type {
    comptime var fields: []const std.builtin.Type.StructField = &.{};
    inline for (args) |a| {
        fields = fields ++ .{a.makeField()};
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .is_tuple = false,
            .fields = fields,
            .decls = &.{},
        },
    });
}
