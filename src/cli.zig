const std = @import("std");

const utils = @import("utils.zig");

const ListIterator = utils.ListIterator;

pub const IteratorError = error{
    /// Could not parse into either a positional or flag's type.
    CouldNotParse,
    /// Trying to use a flag in a function that is only defined for
    /// positionals.
    FlagAsPositional,
    /// Flag takes a value but none was provided.
    MissingFlagValue,
};

/// Argument abstraction
pub const Arg = struct {
    string: []const u8,

    flag: bool = false,
    index: ?usize = null,

    /// Convenience method for checking if a flag argument is either a `-s`
    /// (short) or `--long`. Returns true if either is matched, else false.
    /// Returns false if the argument is positional.
    pub fn is(self: *const Arg, short: ?u8, long: ?[]const u8) bool {
        if (!self.flag) return false;
        if (short) |s| {
            if (self.string.len == 1 and s == self.string[0]) {
                return true;
            }
        }
        if (long) |l| {
            if (std.mem.eql(u8, l, self.string)) {
                return true;
            }
        }
        return false;
    }

    /// Convert the argument string to a given type. Raises
    /// `FlagAsPositional` if attempting to call on a flag argument.
    pub fn as(self: *const Arg, comptime T: type) IteratorError!T {
        if (self.flag) return IteratorError.FlagAsPositional;
        const info = @typeInfo(T);
        const parsed: T = switch (info) {
            .Int => std.fmt.parseInt(T, self.string, 10),
            .Float => std.fmt.parseFloat(T, self.string),
            else => @compileError("Could not parse type given."),
        } catch {
            return IteratorError.CouldNotParse;
        };

        return parsed;
    }

    fn isShortFlag(self: *const Arg) bool {
        return self.flag and self.string.len == 1;
    }
};

const ArgumentType = enum {
    ShortFlag,
    LongFlag,
    Seperator,
    Positional,
    pub fn from(arg: []const u8) !ArgumentType {
        if (arg[0] == '-') {
            if (arg.len > 1) {
                if (arg.len > 2 and arg[1] == '-') return .LongFlag;
                if (std.mem.eql(u8, arg, "--")) return .Seperator;
                return .ShortFlag;
            }
            return IteratorError.CouldNotParse;
        }
        return .Positional;
    }
};

/// Splits argument string into tokenized arguments. Called owns memory.
pub fn splitArgs(allocator: std.mem.Allocator, args: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    var itt = std.mem.tokenize(u8, args, " ");
    while (itt.next()) |arg| {
        try list.append(arg);
    }
    return list.toOwnedSlice();
}

pub const ArgumentIterator = struct {
    args: ListIterator([]const u8),
    previous: ?Arg = null,
    current: []const u8 = "",
    current_type: ArgumentType = .Positional,
    index: usize = 0,
    counter: usize = 0,

    /// Get the total number of arguments in the argument buffer
    pub fn argCount(self: *const ArgumentIterator) usize {
        return self.args.data.len;
    }

    /// Create a copy of the argument interator with all state reset.
    pub fn copy(self: *const ArgumentIterator) ArgumentIterator {
        return ArgumentIterator.init(self.args.data);
    }

    /// Rewind the current index by one, allowing the same argument to be
    /// parsed twice.
    pub fn rewind(self: *ArgumentIterator) void {
        switch (self.current_type) {
            .Positional, .LongFlag, .Seperator => self.args.index -= 1,
            .ShortFlag => {
                if (self.index == 2) {
                    // only one flag read, so need to rewind the argument too
                    self.args.index -= 1;
                    self.index = self.current.len;
                } else {
                    self.index -= 1;
                }
            },
        }
    }

    pub fn init(args: []const []const u8) ArgumentIterator {
        return .{ .args = ListIterator([]const u8).init(args) };
    }

    /// Get the next argument string as the argument to a flag. Raises
    /// `FlagAsPositional` if the next argument is a flag.  Differs from
    /// `nextPositional` is that it does not increment the positional index.
    pub fn getValue(self: *ArgumentIterator) IteratorError![]const u8 {
        var arg = (try self.next()) orelse return IteratorError.MissingFlagValue;
        if (arg.flag) return IteratorError.FlagAsPositional;
        // decrement counter as we don't actually want to count as positional
        self.counter -= 1;
        arg.index = null;
        return arg.string;
    }

    /// Get the next argument as the argument as a positional. Raises
    /// `FlagAsPositional` if the next argument is a flag.
    pub fn nextPositional(self: *ArgumentIterator) IteratorError!?Arg {
        const arg = (try self.next()) orelse return null;
        if (arg.flag) return IteratorError.FlagAsPositional;
        return arg;
    }

    /// Get the next argument as an `Arg`
    pub fn next(self: *ArgumentIterator) IteratorError!?Arg {
        const arg = try self.nextImpl();
        self.previous = arg;
        return arg;
    }

    fn nextImpl(self: *ArgumentIterator) IteratorError!?Arg {
        // check if we need the next argument
        if (self.index >= self.current.len) {
            self.resetArgState();
            // get next argument
            const next_arg = self.args.next() orelse return null;
            self.current_type = try ArgumentType.from(next_arg);
            self.current = next_arg;
        }

        switch (self.current_type) {
            // TODO: handle seperators better
            .Seperator => return self.next(),
            .ShortFlag => {
                // skip the leading minus
                if (self.index == 0) self.index = 1;
                // read the next character
                self.index += 1;
                return .{
                    .string = self.current[self.index - 1 .. self.index],
                    .flag = true,
                };
            },
            .LongFlag => {
                self.index = self.current.len;
                return .{
                    .string = self.current[2..],
                    .flag = true,
                };
            },
            .Positional => {
                self.index = self.current.len;
                self.counter += 1;
                return .{
                    .flag = false,
                    .string = self.current,
                    .index = self.counter,
                };
            },
        }
    }

    fn resetArgState(self: *ArgumentIterator) void {
        self.current_type = .Positional;
        self.current = "";
        self.index = 0;
    }

    fn isAny(self: *ArgumentIterator, short: ?u8, long: []const u8) !bool {
        var nested = ArgumentIterator.init(self.args.data);
        while (try nested.next()) |arg| {
            if (arg.is(short, long)) return true;
        }
        return false;
    }
};

fn argIs(arg: Arg, comptime expected: Arg) !void {
    try std.testing.expectEqual(expected.flag, arg.flag);
    try std.testing.expectEqual(expected.index, arg.index);
    try std.testing.expectEqualStrings(expected.string, arg.string);
}

test "argument iteration" {
    const args = try utils.fromString(
        std.testing.allocator,
        "-tf -k hello --thing=that 1 2 5.0 -q",
    );

    defer std.testing.allocator.free(args);
    var argitt = ArgumentIterator.init(args);

    try std.testing.expectEqual(argitt.argCount(), 9);
    try std.testing.expect(try argitt.isAny(null, "thing"));
    try std.testing.expect((try argitt.isAny(null, "thinhjhhg")) == false);
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "t" });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "f" });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "k" });
    try std.testing.expectEqualStrings(try argitt.getValue(), "hello");
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "thing" });
    try std.testing.expectEqualStrings(try argitt.getValue(), "that");
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "1", .index = 1 });
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "2", .index = 2 });
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "5.0", .index = 3 });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "q" });
}
