const std = @import("std");

const utils = @import("utils.zig");
const farbe = @import("farbe");

const ListIterator = utils.ListIterator;
const Error = utils.Error;

fn errorString(err: Error) []const u8 {
    inline for (@typeInfo(Error).ErrorSet.?) |e| {
        const same_name = err == @field(anyerror, e.name);
        if (same_name) {
            return e.name;
        }
    }
    unreachable;
}

/// Wrapper for returning errors with helpful messages printed to `stderr`
pub fn throwError(err: anyerror, comptime fmt: []const u8, args: anytype) !void {
    var stderr = std.io.getStdErr();
    var writer = stderr.writer();

    const err_string = @errorName(err);

    // do we use color?
    if (stderr.isTty()) {
        const f = farbe.ComptimeFarbe.init().fgRgb(255, 0, 0).bold();
        try f.write(writer, "{s}: ", .{err_string});
    } else {
        try writer.print("{s}: ", .{err_string});
    }
    try writer.print(fmt ++ "\n", args);

    // let the OS clean up
    std.process.exit(1);
}

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
    pub fn as(self: *const Arg, comptime T: type) Error!T {
        if (self.flag) return Error.FlagAsPositional;
        const info = @typeInfo(T);
        const parsed: T = switch (info) {
            .Int => std.fmt.parseInt(T, self.string, 10),
            .Float => std.fmt.parseFloat(T, self.string),
            else => @compileError("Could not parse type given."),
        } catch {
            return Error.CouldNotParse;
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
            return Error.BadArgument;
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

pub const ArgIterator = struct {
    args: ListIterator([]const u8),
    previous: ?Arg = null,
    current: []const u8 = "",
    current_type: ArgumentType = .Positional,
    index: usize = 0,
    counter: usize = 0,

    /// Create a copy of the argument interator with all state reset.
    pub fn copy(self: *const ArgIterator) ArgIterator {
        return ArgIterator.init(self.args.data);
    }

    /// Rewind the current index by one, allowing the same argument to be
    /// parsed twice.
    pub fn rewind(self: *ArgIterator) void {
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

    pub fn init(args: []const []const u8) ArgIterator {
        return .{ .args = ListIterator([]const u8).init(args) };
    }

    /// Get the next argument as the argument to a flag. Raises
    /// `FlagAsPositional` if the next argument is a flag.
    /// Differs from `nextPositional` is that it does not increment the
    /// positional index.
    pub fn getValue(self: *ArgIterator) Error!Arg {
        var arg = (try self.next()) orelse return Error.TooFewArguments;
        if (arg.flag) return Error.FlagAsPositional;
        // decrement counter as we don't actually want to count as positional
        self.counter -= 1;
        arg.index = null;
        return arg;
    }

    /// Get the next argument as the argument as a positional. Raises
    /// `FlagAsPositional` if the next argument is a flag.
    pub fn nextPositional(self: *ArgIterator) Error!?Arg {
        const arg = (try self.next()) orelse return null;
        if (arg.flag) return Error.FlagAsPositional;
        return arg;
    }

    /// Get the next argument as an `Arg`
    pub fn next(self: *ArgIterator) Error!?Arg {
        const arg = try self.nextImpl();
        self.previous = arg;
        return arg;
    }

    fn nextImpl(self: *ArgIterator) Error!?Arg {
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

    fn resetArgState(self: *ArgIterator) void {
        self.current_type = .Positional;
        self.current = "";
        self.index = 0;
    }

    fn isAny(self: *ArgIterator, short: ?u8, long: []const u8) !bool {
        var nested = ArgIterator.init(self.args.data);
        while (try nested.next()) |arg| {
            if (arg.is(short, long)) return true;
        }
        return false;
    }

    pub fn throwUnknownFlag(self: *const ArgIterator) !void {
        const arg: Arg = self.previous.?;
        if (arg.isShortFlag()) {
            try throwError(Error.UnknownFlag, "-{s}", .{arg.string});
        } else {
            try throwError(Error.UnknownFlag, "--{s}", .{arg.string});
        }
    }

    pub fn throwBadArgument(
        self: *const ArgIterator,
        comptime msg: []const u8,
    ) !void {
        const arg: Arg = self.previous.?;
        try throwError(Error.BadArgument, msg ++ ": '{s}'", .{arg.string});
    }

    pub fn throwTooManyArguments(self: *const ArgIterator) !void {
        const arg = self.previous.?;
        try throwError(
            Error.TooManyArguments,
            "argument '{s}' is too much",
            .{arg.string},
        );
    }

    pub fn throwTooFewArguments(
        _: *const ArgIterator,
        missing_arg_name: []const u8,
    ) !void {
        try throwError(
            Error.TooFewArguments,
            "missing argument '{s}'",
            .{missing_arg_name},
        );
    }

    /// Throw a general unknown argument error. To be used when it doesn't
    /// matter what the argument was, it was just unwanted.  Throw `UnknownFlag`
    /// if the last argument was a flag, else throw a `BadArgument` error.
    pub fn throwUnknown(self: *const ArgIterator) !void {
        const arg: Arg = self.previous.?;
        if (arg.flag) {
            try self.throwUnknownFlag();
        } else {
            try self.throwBadArgument("unknown argument");
        }
    }

    pub fn assertNoArguments(self: *ArgIterator) !void {
        if (try self.next()) |arg| {
            if (arg.flag) {
                return try self.throwUnknownFlag();
            } else return try self.throwTooManyArguments();
        }
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
    var argitt = ArgIterator.init(args);
    try std.testing.expect(try argitt.isAny(null, "thing"));
    try std.testing.expect((try argitt.isAny(null, "thinhjhhg")) == false);
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "t" });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "f" });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "k" });
    try argIs(try argitt.getValue(), .{ .flag = false, .string = "hello" });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "thing" });
    try argIs(try argitt.getValue(), .{ .flag = false, .string = "that" });
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "1", .index = 1 });
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "2", .index = 2 });
    try argIs((try argitt.next()).?, .{ .flag = false, .string = "5.0", .index = 3 });
    try argIs((try argitt.next()).?, .{ .flag = true, .string = "q" });
}
