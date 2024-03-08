const std = @import("std");
const utils = @import("utils.zig");
const testing = std.testing;

const Error = utils.Error;
const ArgumentDescriptor = @import("main.zig").ArgumentDescriptor;

const SplitArgName = struct {
    arg: []const u8,
    value_name: ?[]const u8,
};

fn splitAtFirstSpace(s: []const u8) SplitArgName {
    if (std.mem.indexOfScalar(u8, s, ' ')) |i| {
        return .{ .arg = s[0..i], .value_name = s[i + 1 ..] };
    } else {
        return .{ .arg = s, .value_name = null };
    }
}

fn testSplitArg(s: []const u8, comptime expected: SplitArgName) !void {
    try testing.expectEqualDeep(
        expected,
        splitAtFirstSpace(s),
    );
}

test "split arg name" {
    try testSplitArg(
        "-n/--limit value",
        .{ .arg = "-n/--limit", .value_name = "value" },
    );
    try testSplitArg(
        "value",
        .{ .arg = "value", .value_name = null },
    );
}

fn isValidFlagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

fn isValidPositionalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn allValidFlagChars(s: []const u8) bool {
    for (s) |c| {
        if (!isValidFlagChar(c)) return false;
    }
    return true;
}

fn allValidPositionalChars(s: []const u8) bool {
    for (s) |c| {
        if (!isValidPositionalChar(c)) return false;
    }
    return true;
}

pub const ArgumentInfo = union(enum) {
    Flag: struct {
        descriptor: ArgumentDescriptor,
        name: []const u8,
        short_name: ?[]const u8 = null,
        with_value: bool,
        flag_type: enum { Short, Long, ShortAndLong },
    },
    Positional: struct {
        descriptor: ArgumentDescriptor,
        name: []const u8,
    },

    fn fromFlag(comptime descriptor: ArgumentDescriptor) !ArgumentInfo {
        const split = splitAtFirstSpace(descriptor.arg);
        const arg = split.arg;
        if (arg.len == 2 and std.ascii.isAlphanumeric(arg[1])) {
            return .{
                .Flag = .{
                    .flag_type = .Short,
                    .name = arg[1..],
                    .with_value = split.value_name != null,
                    .descriptor = descriptor,
                },
            };
        } else if (arg.len > 2 and arg[2] == '/') {
            const short = arg[0..2];
            const long = arg[3..];
            if (long[0] == '-' and
                long[1] == '-' and
                allValidFlagChars(long[2..]) and
                allValidFlagChars(short[1..]))
            {
                return .{
                    .Flag = .{
                        .flag_type = .ShortAndLong,
                        .name = long[2..],
                        .short_name = short[1..],
                        .with_value = split.value_name != null,
                        .descriptor = descriptor,
                    },
                };
            }
        } else if (arg[1] == '-' and allValidFlagChars(arg[2..])) {
            return .{
                .Flag = .{
                    .flag_type = .Long,
                    .name = arg[2..],
                    .with_value = split.value_name != null,
                    .descriptor = descriptor,
                },
            };
        }
        return Error.MalformedDescriptor;
    }

    fn fromPositional(comptime descriptor: ArgumentDescriptor) !ArgumentInfo {
        if (allValidPositionalChars(descriptor.arg)) {
            return .{
                .Positional = .{
                    .name = descriptor.arg,
                    .descriptor = descriptor,
                },
            };
        }
        return Error.MalformedDescriptor;
    }

    pub fn fromDescriptor(comptime descriptor: ArgumentDescriptor) !ArgumentInfo {
        const arg = descriptor.arg;
        if (arg.len == 0) return Error.MalformedDescriptor;
        if (arg[0] == '-') {
            return try fromFlag(descriptor);
        } else {
            return try fromPositional(descriptor);
        }
    }

    pub fn isRequired(comptime self: ArgumentInfo) bool {
        return switch (self) {
            inline else => |i| i.descriptor.required,
        };
    }

    pub fn GetType(comptime self: ArgumentInfo) type {
        const T = switch (self) {
            .Flag => |f| if (f.with_value)
                f.descriptor.argtype
            else {
                const T = f.descriptor.argtype;
                if (T != []const u8 and T != bool) {
                    @compileError("TODO: Incompatible types!");
                }
                return bool;
            },
            .Positional => |p| p.descriptor.argtype,
        };

        return if (self.isRequired()) T else ?T;
    }

    pub fn getName(comptime self: ArgumentInfo) []const u8 {
        return switch (self) {
            inline else => |f| f.name,
        };
    }

    pub fn getDefaultValue(comptime self: ArgumentInfo) GetType(self) {
        if (!self.isRequired()) {
            switch (self) {
                .Positional => return null,
                .Flag => |f| return if (f.with_value) null else false,
            }
        }
        const Info = @typeInfo(self.GetType());

        switch (Info) {
            .Optional => return null,
            .Bool => return false,
            .Pointer => |arr| {
                if (arr.child == u8) {
                    return "";
                }
            },
            else => {},
        }
        @compileError("No default value for arg: " ++ self.getName());
    }

    pub fn toField(
        comptime info: ArgumentInfo,
    ) std.builtin.Type.StructField {
        const T = info.GetType();
        const default = info.getDefaultValue();
        return .{
            .name = @ptrCast(info.getName()),
            .type = T,
            .default_value = @ptrCast(&@as(T, default)),
            .is_comptime = false,
            .alignment = @alignOf(T),
        };
    }

    pub fn parseString(comptime info: ArgumentInfo, s: []const u8) !GetType(info) {
        if (s.len == 0) return Error.BadArgument;

        const type_info = @typeInfo(info.GetType());
        const T = if (type_info == .Optional)
            type_info.Optional.child
        else
            info.GetType();

        switch (@typeInfo(T)) {
            .Pointer => |arr| {
                if (arr.child == u8) {
                    return s;
                } else @compileError("No method for parsing slices of this type");
            },
            .Int => {
                return try std.fmt.parseInt(T, s, 10);
            },
            .Float => {
                return try std.fmt.parseFloat(T, s);
            },
            .Enum => {
                return try std.meta.stringToEnum(T, s);
            },
            .Struct => {
                if (@hasDecl(T, "initFromArg")) {
                    return try @field(T, "initFromArg")(s);
                } else {
                    @compileError(
                        "Structs must declare a public `initFromArg` function",
                    );
                }
            },
            else => @compileError("No method for parsing this type"),
        }
    }
};

fn testArgumentInfoParsing(
    comptime descriptor: ArgumentDescriptor,
    comptime expected: ArgumentInfo,
) !void {
    try testing.expectEqualDeep(
        expected,
        try ArgumentInfo.fromDescriptor(descriptor),
    );
}

test "arg descriptor parsing" {
    const d1: ArgumentDescriptor = .{
        .arg = "-n/--limit value",
        .help = "",
    };
    try testArgumentInfoParsing(d1, .{ .Flag = .{
        .descriptor = d1,
        .flag_type = .ShortAndLong,
        .name = "limit",
        .short_name = "n",
        .with_value = true,
    } });

    const d2: ArgumentDescriptor = .{
        .arg = "-n/--limit",
        .help = "",
    };
    try testArgumentInfoParsing(d2, .{ .Flag = .{
        .descriptor = d2,
        .flag_type = .ShortAndLong,
        .name = "limit",
        .short_name = "n",
        .with_value = false,
    } });

    const d3: ArgumentDescriptor = .{
        .arg = "pos",
        .help = "",
    };
    try testArgumentInfoParsing(d3, .{ .Positional = .{
        .descriptor = d3,
        .name = "pos",
    } });

    try testing.expectError(
        Error.MalformedDescriptor,
        ArgumentInfo.fromDescriptor(.{
            .arg = "lim it",
            .help = "",
        }),
    );

    try testing.expectError(
        Error.MalformedDescriptor,
        ArgumentInfo.fromDescriptor(.{
            .arg = "--limit/-n",
            .help = "",
        }),
    );
}
