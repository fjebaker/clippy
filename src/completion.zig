const std = @import("std");

const ArgumentInfo = @import("info.zig").ArgumentInfo;
const ArgumentDescriptor = @import("main.zig").ArgumentDescriptor;

pub const CompletionWriter = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) !CompletionWriter {
        return .{
            .allocator = allocator,
            .items = std.ArrayList([]const u8).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *CompletionWriter) void {
        self.items.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn print(
        self: *CompletionWriter,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const next = try std.fmt.allocPrint(
            self.arena.allocator(),
            fmt,
            args,
        );
        try self.items.append(next);
    }

    pub fn finalize(self: *CompletionWriter, name: []const u8) ![]const u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();
        var writer = list.writer();

        // TODO: this is absolutely horrible and needs fixing

        try writer.print("_arguments_{s}() {{\n", .{name});

        try writer.writeAll("    _arguments -C");

        for (self.items.items) |arg| {
            try writer.print(" \\\n        {s}", .{arg});
        }
        try writer.writeAll("\n}\n");

        return try list.toOwnedSlice();
    }
};

pub const Shell = enum {
    Zsh,
};

pub const Opts = struct {
    shell: Shell,
};

pub const CompletionOptions = struct {
    action: ?[]const u8 = null,
    description: ?[]const u8 = null,
    optional: bool = false,
};

pub const ZshCompletionWriter = struct {
    pub fn writeShortLongFlag(
        writer: *CompletionWriter,
        short: []const u8,
        long: []const u8,
        opts: CompletionOptions,
    ) !void {
        try writeLongFlag(writer, long, opts);
        try writeShortFlag(writer, short, opts);
    }

    pub fn writeLongFlag(
        writer: *CompletionWriter,
        long: []const u8,
        opts: CompletionOptions,
    ) !void {
        try writer.print("'--{s}[{s}]:{s}:{s}'", .{
            long,
            opts.description orelse "",
            if (opts.action != null) long else "",
            opts.action orelse "()",
        });
    }

    pub fn writeShortFlag(
        writer: *CompletionWriter,
        short: []const u8,
        opts: CompletionOptions,
    ) !void {
        try writer.print("'-{s}[{s}]:{s}:{s}'", .{
            short,
            opts.description orelse "",
            if (opts.action != null) short else "",
            opts.action orelse "()",
        });
    }

    pub fn writePositional(
        writer: *CompletionWriter,
        name: []const u8,
        opts: CompletionOptions,
    ) !void {
        try writer.print("'{s}{s}:{s}'", .{
            if (opts.optional) "::" else ":",
            name,
            opts.action orelse "()",
        });
    }
};
