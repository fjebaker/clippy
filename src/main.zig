const std = @import("std");
const utils = @import("utils.zig");
const cli = @import("cli.zig");

test "all" {
    _ = cli;
    _ = utils;
}

/// Default argument type, used to infer `[]const u8`.
pub const DefaultType = struct {};

pub const ArgumentDescriptor = struct {
    /// Argument name. Can be either the name itself or a flag Short flags
    /// should just be `-f`, long flags `--flag`, and short and long
    /// `-f/--flag`. If it is a flag, `--flag value` is to mean the flag should
    /// accept a value, otherwise it is treated as a boolean.
    /// To slurp positionals, use `arg_name...`.
    arg: []const u8,

    /// Help string
    help: []const u8,

    /// How the argument should be displayed in the help message.
    display_name: ?[]const u8 = null,

    /// The type the argument should be parsed to.
    argtype: type = DefaultType,

    /// Default argument value.
    default: ?[]const u8 = null,

    /// Should the argument be shown in the help?
    show_help: bool = true,

    /// Is a required argument
    required: bool = false,

    /// Should be parsed by the helper
    parse: bool = true,

    /// Completion function used to generate completion hints
    completion: ?[]const u8 = null,
};

pub const ArgumentError = error{
    /// Argument name is using invalid characters.
    InvalidArgName,
    /// Argument specifier is malformed (e.g. wrong number of `--` in a flag).
    MalformedDescriptor,
};

const Argument = struct {
    desc: ArgumentDescriptor,
    info: union(enum) {
        flag: struct {
            short_name: ?[]const u8 = null,
            accepts_value: bool = false,
            type: enum { short, long, short_and_long } = .short,
        },
        positional: struct {
            variadic: bool = false,
        },
    },
    name: []const u8,

    fn matches(self: Argument, arg: cli.Arg) bool {
        return switch (self.info) {
            .flag => |f| arg.flag and switch (f.type) {
                .short => arg.is(self.name[0], null),
                .long, .short_and_long => arg.is(
                    if (f.short_name) |sn| sn[0] else null,
                    self.name,
                ),
            },
            .positional => !arg.flag,
        };
    }

    fn parseAsFlag(desc: ArgumentDescriptor) !Argument {
        std.debug.assert(desc.arg[0] == '-');
        var arg: Argument = .{
            .desc = desc,
            .info = .{ .flag = .{} },
            .name = undefined,
        };

        var name_string = desc.arg;
        if (std.mem.indexOfScalar(u8, name_string, ' ')) |i| {
            name_string = name_string[0..i];
            arg.info.flag.accepts_value = true;
        }

        if (std.mem.indexOfScalar(u8, name_string, '/')) |i| {
            arg.info.flag.short_name = name_string[1..i];

            if (name_string.len > i + 3 and name_string[i + 1] != '-' and name_string[i + 2] != '-')
                return ArgumentError.MalformedDescriptor;

            name_string = name_string[i + 3 ..];

            arg.info.flag.type = .short_and_long;
        } else {
            if (name_string.len > 2 and name_string[1] == '-') {
                arg.info.flag.type = .long;
                name_string = name_string[2..];
            } else {
                name_string = name_string[1..];
            }
        }

        if (!utils.allValidFlagChars(name_string))
            return ArgumentError.InvalidArgName;

        arg.name = name_string;

        return arg;
    }

    fn parseAsPositional(desc: ArgumentDescriptor) !Argument {
        var variadic = false;
        var name = desc.arg;
        if (desc.arg.len >= 3 and std.mem.eql(u8, desc.arg[desc.arg.len - 3 ..], "...")) {
            variadic = true;
            name = desc.arg[0 .. desc.arg.len - 3];
        }

        if (!utils.allValidPositionalChars(name))
            return ArgumentError.InvalidArgName;

        return .{
            .desc = desc,
            .info = .{ .positional = .{ .variadic = variadic } },
            .name = name,
        };
    }

    fn fromDescriptor(desc: ArgumentDescriptor) !Argument {
        if (desc.arg.len == 0) return ArgumentError.MalformedDescriptor;
        const arg = if (desc.arg[0] == '-')
            try parseAsFlag(desc)
        else
            try parseAsPositional(desc);

        return arg;
    }

    fn InnerType(self: Argument) type {
        const T = self.makeField().type;
        if (@typeInfo(T) == .optional) {
            return std.meta.Child(T);
        }
        return T;
    }

    /// Use the Argument information to parse a `std.builtin.Type.StructField`.
    pub fn makeField(comptime arg: Argument) std.builtin.Type.StructField {
        var default: ?*const anyopaque = null;
        const InnerT: type = b: {
            switch (arg.info) {
                .flag => |f| {
                    if (!f.accepts_value) {
                        if (arg.desc.argtype != DefaultType)
                            @compileError("Argtype for flag without value must be DefaultType.");
                        default = @ptrCast(&false);
                        break :b bool;
                    }
                },
                .positional => {},
            }
            if (arg.desc.argtype == DefaultType) break :b []const u8;
            break :b arg.desc.argtype;
        };

        const T = if (arg.desc.required or arg.desc.default != null or default != null)
            InnerT
        else
            ?InnerT;

        if (arg.desc.default) |d| {
            if (InnerT == DefaultType)
                default = parseStringAs(T, d) catch
                    @compileError("Default argument is invalid: '" ++ d ++ "'");
        }

        return .{
            .name = @ptrCast(arg.name),
            .type = T,
            .default_value = default,
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }
};

fn parseStringAs(comptime T: type, s: []const u8) !T {
    switch (@typeInfo(T)) {
        .pointer => |arr| {
            if (arr.child == u8) {
                return s;
            } else {
                // TODO: here's where we'll do multi argument parsing
                @compileError("No method for parsing slices of this type");
            }
        },
        .int => {
            return try std.fmt.parseInt(T, s, 10);
        },
        .float => {
            return try std.fmt.parseFloat(T, s);
        },
        .@"enum" => {
            return try std.meta.stringToEnum(T, s);
        },
        .@"struct" => {
            if (@hasDecl(T, "initFromArg")) {
                return try @field(T, "initFromArg")(s);
            } else {
                @compileError(
                    "Structs must declare a public `initFromArg` function",
                );
            }
        },
        else => @compileError(std.fmt.comptimePrint("No method for parsing type: '{any}'", .{T})),
    }
}
fn testArgumentInfoParsing(
    comptime descriptor: ArgumentDescriptor,
    comptime expected: Argument,
) !void {
    const actual = try Argument.fromDescriptor(descriptor);
    try std.testing.expectEqualDeep(
        expected.info,
        actual.info,
    );
}

test "arg descriptor parsing" {
    const d1: ArgumentDescriptor = .{
        .arg = "-n/--limit value",
        .help = "",
    };
    try testArgumentInfoParsing(
        d1,
        .{
            .desc = d1,
            .name = "limit",
            .info = .{ .flag = .{
                .short_name = "n",
                .accepts_value = true,
                .type = .short_and_long,
            } },
        },
    );

    const d2: ArgumentDescriptor = .{
        .arg = "-n/--limit",
        .help = "",
    };
    try testArgumentInfoParsing(
        d2,
        .{
            .desc = d2,
            .name = "limit",
            .info = .{ .flag = .{
                .short_name = "n",
                .accepts_value = false,
                .type = .short_and_long,
            } },
        },
    );

    const d3: ArgumentDescriptor = .{
        .arg = "pos",
        .help = "",
    };
    try testArgumentInfoParsing(
        d3,
        .{
            .desc = d3,
            .name = "pos",
            .info = .{ .positional = .{} },
        },
    );

    const d4: ArgumentDescriptor = .{
        .arg = "pos",
        .help = "",
        .default = "Hello",
    };
    try testArgumentInfoParsing(
        d4,
        .{
            .desc = d4,
            .name = "pos",
            .info = .{ .positional = .{} },
        },
    );

    const d5: ArgumentDescriptor = .{
        .arg = "pos...",
        .help = "",
    };
    try testArgumentInfoParsing(
        d5,
        .{
            .desc = d5,
            .name = "pos",
            .info = .{ .positional = .{ .variadic = true } },
        },
    );
}

fn ArgumentsFromDescriptors(comptime args: []const ArgumentDescriptor) []const Argument {
    comptime var arguments: []const Argument = &.{};
    inline for (args) |a| {
        const arg = Argument.fromDescriptor(a) catch |err|
            @compileError(
            std.fmt.comptimePrint("Could not parse argument '{s}': Error {any}", .{ a.arg, err }),
        );
        arguments = arguments ++ .{arg};
    }
    return arguments;
}

const ParseError = error{ DuplicateArgument, InvalidArgument };

pub fn ArgParser(comptime arguments: []const Argument) type {
    const ParsedT = ParsedType(arguments);

    comptime var init_parsed: ParsedT = undefined;
    inline for (@typeInfo(ParsedT).@"struct".fields) |field| {
        if (field.default_value) |ptr| {
            const default_value = @as(*align(1) const field.type, @ptrCast(ptr)).*;
            @field(init_parsed, field.name) = default_value;
        }
    }

    const Mask = std.bit_set.StaticBitSet(arguments.len);

    return struct {
        const Self = @This();

        const Status = struct {
            err: ?anyerror = null,
            arg: cli.Arg = null,
        };

        pub const Parsed = ParsedT;

        allocator: ?std.mem.Allocator = null,
        itt: *cli.ArgumentIterator,
        mask: Mask = Mask.initEmpty(),
        _parsed: Parsed = init_parsed,

        pub fn init(itt: *cli.ArgumentIterator) Self {
            return .{ .itt = itt };
        }

        fn parseArg(self: *Self, arg: cli.Arg) !void {
            inline for (arguments, 0..) |a, i| {
                if (a.matches(arg)) {
                    switch (a.info) {
                        .flag => |f| {
                            if (self.mask.isSet(i))
                                return ParseError.DuplicateArgument;

                            if (f.accepts_value) {
                                const value = try self.itt.getValue();
                                @field(self._parsed, a.name) = try parseStringAs(a.InnerType(), value);
                            } else {
                                @field(self._parsed, a.name) = true;
                            }

                            self.mask.set(i);
                            return;
                        },
                        .positional => {
                            if (!self.mask.isSet(i)) {
                                @field(self._parsed, a.name) = try parseStringAs(a.InnerType(), arg.string);
                                self.mask.set(i);
                                return;
                            }
                        },
                    }
                }
            }
            return ParseError.InvalidArgument;
        }

        pub fn parseAll(self: *Self) !Parsed {
            while (try self.itt.next()) |arg| {
                self.parseArg(arg) catch |err| {
                    std.debug.print("Arg Failed: {any}: {s}", .{ arg, arg.string });
                    return err;
                };
            }
            return self._parsed;
        }
    };
}

pub fn ParsedType(comptime arguments: []const Argument) type {
    comptime var fields: []const std.builtin.Type.StructField = &.{};
    inline for (arguments) |a| {
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

pub fn Arguments(comptime args: []const ArgumentDescriptor) type {
    const arguments = ArgumentsFromDescriptors(args);
    return ArgParser(arguments);
}

fn testParseArgs(comptime Parser: type, comptime string: []const u8) !Parser.Parsed {
    const arg_strings = try utils.fromString(
        std.testing.allocator,
        string,
    );
    defer std.testing.allocator.free(arg_strings);
    var argitt = cli.ArgumentIterator.init(arg_strings);

    var parser = Parser.init(&argitt);
    return try parser.parseAll();
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
        // .completion = "{compadd $(ls -1)}",
    },
    .{
        .arg = "other",
        .help = "Another positional",
        // .argtype = struct {
        //     value: []const u8,
        //     pub fn initFromArg(s: []const u8) !@This() {
        //         return .{ .value = s };
        //     }
        // },
    },
    .{
        .arg = "-f/--flag",
        .help = "Toggleable",
    },
};

test "test-parse-1" {
    const Parser = Arguments(&TestArguments);
    {
        const parsed = try testParseArgs(Parser, "hello --limit 12 goodbye -f");
        try std.testing.expectEqual(parsed.limit, 12);
        try std.testing.expectEqualStrings(parsed.item, "hello");
        try std.testing.expectEqualStrings(parsed.other.?, "goodbye");
        try std.testing.expectEqual(true, parsed.flag);
    }
}
