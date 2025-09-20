const std = @import("std");
const testing = std.testing;

pub const ComptimeError = error{
    // comptime parser errors
    IncompatibleTypes,
};

fn isValidFlagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn isValidPositionalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn allValidFlagChars(s: []const u8) bool {
    for (s) |c| {
        if (!isValidFlagChar(c)) return false;
    }
    return true;
}

pub fn allValidPositionalChars(s: []const u8) bool {
    for (s) |c| {
        if (!isValidPositionalChar(c)) return false;
    }
    return true;
}

/// A helper for creating iterable slices
pub fn ListIterator(comptime T: type) type {
    return struct {
        data: []const T,
        index: usize = 0,
        pub fn init(items: []const T) @This() {
            return .{ .data = items };
        }

        /// Get the next item in the slice. Returns `null` if no items left.
        pub fn next(self: *@This()) ?T {
            if (self.index < self.data.len) {
                const v = self.data[self.index];
                self.index += 1;
                return v;
            }
            return null;
        }
    };
}

/// For tests only
pub fn fromString(alloc: std.mem.Allocator, args: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(alloc);
    var itt = std.mem.tokenizeAny(u8, args, " =");

    while (itt.next()) |item| try list.append(alloc, item);
    return list.toOwnedSlice(alloc);
}

pub const WrappingOptions = struct {
    left_pad: usize = 0,
    continuation_indent: usize = 0,
    column_limit: usize = 70,
};

/// Wrap a string over a number of lines in a comptime context. See also
/// `writeWrapped` for a runtime version.
pub fn comptimeWrap(comptime text: []const u8, comptime opts: WrappingOptions) []const u8 {
    @setEvalBranchQuota(10000);
    comptime var out: []const u8 = "";
    comptime var line_len: usize = 0;
    comptime var itt = std.mem.splitAny(u8, text, " \n");

    // so we can reinsert the spaces correctly we do the first word first
    if (itt.next()) |first_word| {
        out = out ++ first_word;
        line_len += first_word.len;
    }
    // followed by all others words
    inline while (itt.next()) |word| {
        out = out ++ " ";
        line_len += word.len;
        if (line_len > opts.column_limit) {
            out = out ++
                "\n" ++
                " " ** (opts.left_pad + opts.continuation_indent);
            line_len = opts.continuation_indent;
        }
        out = out ++ word;
    }

    return out;
}

/// Wrap a string over a number of lines in a comptime context.
pub fn writeWrapped(writer: anytype, text: []const u8, opts: WrappingOptions) !void {
    var line_len: usize = 0;
    var itt = std.mem.splitAny(u8, text, " \n");
    if (itt.next()) |first| {
        try writer.writeAll(first);
        line_len += first.len;
    }

    while (itt.next()) |word| {
        try writer.writeByte(' ');
        line_len += word.len;
        if (line_len > opts.column_limit) {
            try writer.writeByte('\n');
            _ = try writer.splatByte(' ', opts.left_pad + opts.continuation_indent);
            line_len = opts.continuation_indent;
        }
        try writer.writeAll(word);
    }
}

/// Get the type of a tag struct in a union
pub fn TagType(comptime T: type, comptime name: []const u8) type {
    const fields = @typeInfo(T).@"union".fields;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("No field named " ++ name);
}

/// Parse a string into a given type using a custom function in structs if
/// neccessary.
pub fn parseStringAs(comptime T: type, s: []const u8) !T {
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
