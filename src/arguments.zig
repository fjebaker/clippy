const std = @import("std");
const utils = @import("utils.zig");
const cli = @import("cli.zig");

pub const ArgumentError = error{
    /// Argument name is using invalid characters.
    InvalidArgName,
    /// Argument specifier is malformed (e.g. wrong number of `--` in a flag).
    MalformedDescriptor,
};

/// Default argument type, used to infer `[]const u8`.
pub const DefaultType = struct {};

pub const ArgumentDescriptor = struct {
    /// Argument name. Can be either the name itself or a flag Short flags
    /// should just be `-f`, long flags `--flag`, and short and long
    /// `-f/--flag`. If it is a flag, `--flag value` is to mean the flag should
    /// accept a value, otherwise it is treated as a boolean.
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

pub const Argument = struct {
    desc: ArgumentDescriptor,
    info: union(enum) {
        flag: struct {
            short_name: ?[]const u8 = null,
            accepts_value: bool = false,
            type: enum { short, long, short_and_long } = .short,
        },
        positional: struct {},
    },
    name: []const u8,

    /// Does an `Arg` match this `Argument`?
    pub fn matches(self: Argument, arg: cli.Arg) bool {
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

    fn interpretAsFlag(desc: ArgumentDescriptor) !Argument {
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

    fn interpretAsPositional(desc: ArgumentDescriptor) !Argument {
        if (!utils.allValidPositionalChars(desc.arg))
            return ArgumentError.InvalidArgName;

        return .{
            .desc = desc,
            .info = .{ .positional = .{} },
            .name = desc.arg,
        };
    }

    /// Parse an `Argument` from an `ArgumentDescriptor`
    pub fn fromDescriptor(desc: ArgumentDescriptor) !Argument {
        if (desc.arg.len == 0) return ArgumentError.MalformedDescriptor;
        const arg = if (desc.arg[0] == '-')
            try interpretAsFlag(desc)
        else
            try interpretAsPositional(desc);

        return arg;
    }

    /// Get the type of this argument (stripping optionals).
    pub fn InnerType(self: Argument) type {
        const T = self.makeField().type;
        if (@typeInfo(T) == .optional) {
            return std.meta.Child(T);
        }
        return T;
    }

    /// Use the Argument information to parse a `std.builtin.Type.StructField`.
    pub fn makeField(comptime arg: Argument) std.builtin.Type.StructField {
        comptime var default: ?*const anyopaque = null;
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

        comptime {
            if (arg.desc.default) |d| {
                if (arg.desc.argtype == DefaultType) {
                    default = @ptrCast(&d);
                } else {
                    const v = utils.parseStringAs(InnerT, d) catch
                        @compileError("Default argument is invalid: '" ++ d ++ "'");
                    default = @ptrCast(&v);
                }
            } else if (!arg.desc.required and @typeInfo(T) == .optional) {
                const v: T = null;
                default = @ptrCast(&v);
            }
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

/// Parse a slice of `ArgumentDescriptor` into a slice of `Argument`
pub fn ArgumentsFromDescriptors(comptime arg_descs: []const ArgumentDescriptor) []const Argument {
    comptime var args: []const Argument = &.{};
    inline for (arg_descs) |a| {
        const arg = Argument.fromDescriptor(a) catch |err|
            @compileError(
            std.fmt.comptimePrint("Could not parse argument '{s}': Error {any}", .{ a.arg, err }),
        );
        args = args ++ .{arg};
    }
    return args;
}
