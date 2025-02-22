const std = @import("std");
const arguments = @import("arguments.zig");

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

pub const Options = struct {
    shell: Shell = .Zsh,
    function_name: []const u8,
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

pub fn generateCompletion(
    allocator: std.mem.Allocator,
    args: []const arguments.Argument,
    opts: Options,
) ![]const u8 {
    var writer = try CompletionWriter.init(allocator);
    defer writer.deinit();
    // TODO: make this dispatch on different shells correctly
    const Comp = ZshCompletionWriter;

    inline for (args) |arg| {
        switch (arg.info) {
            .flag => |f| {
                switch (f.type) {
                    .short_and_long => try Comp.writeShortLongFlag(
                        &writer,
                        f.short_name.?,
                        arg.name,
                        .{
                            .action = arg.desc.completion,
                        },
                    ),
                    .long => try Comp.writeLongFlag(
                        &writer,
                        arg.name,
                        .{
                            .action = arg.desc.completion,
                        },
                    ),
                    .short => try Comp.writeShortFlag(
                        &writer,
                        arg.name,
                        .{
                            .action = arg.desc.completion,
                        },
                    ),
                }
            },
            .positional => try Comp.writePositional(
                &writer,
                arg.name,
                .{
                    .action = arg.desc.completion,
                    .optional = !arg.desc.required,
                },
            ),
        }
    }

    return try writer.finalize(opts.function_name);
}

const TestArguments = [_]arguments.ArgumentDescriptor{
    .{
        .arg = "item",
        .help = "Positional argument.",
        .required = true,
    },
    .{
        .arg = "-n/--limit value",
        .help = "Limit.",
        .argtype = usize,
        .completion = "{compadd $(ls -1)}",
    },
    .{
        .arg = "other",
        .help = "Another positional",
    },
    .{
        .arg = "-f/--flag",
        .help = "Toggleable",
    },
};

test "argument completion" {
    const Args1 = arguments.ArgumentsFromDescriptors(&TestArguments);

    const comp1 = try generateCompletion(std.testing.allocator, Args1, .{ .function_name = "name" });
    defer std.testing.allocator.free(comp1);

    try std.testing.expectEqualStrings(
        \\_arguments_name() {
        \\    _arguments -C \
        \\        ':item:()' \
        \\        '--limit[]:limit:{compadd $(ls -1)}' \
        \\        '-n[]:n:{compadd $(ls -1)}' \
        \\        '::other:()' \
        \\        '--flag[]::()' \
        \\        '-f[]::()'
        \\}
        \\
    , comp1);
}
