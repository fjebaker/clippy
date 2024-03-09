const std = @import("std");
const testing = std.testing;

pub const Error = RuntimeError || ComptimeError;

pub const RuntimeError = error{
    // runtime errors
    BadArgument,
    CouldNotParse,
    DuplicateFlag,
    FlagAsPositional,
    InvalidFlag,
    TooFewArguments,
    TooManyArguments,
    UnknownFlag,
};

pub const ComptimeError = error{
    // comptime parser errors
    MalformedDescriptor,
    IncompatibleTypes,
};

fn isValidFlagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

fn isValidPositionalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
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
    var list = std.ArrayList([]const u8).init(alloc);
    errdefer list.deinit();
    var itt = std.mem.tokenizeAny(u8, args, " =");

    while (itt.next()) |item| try list.append(item);
    return list.toOwnedSlice();
}
