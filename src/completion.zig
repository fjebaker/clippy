const std = @import("std");
const utils = @import("utils.zig");
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

pub fn generateCommandCompletion(
    allocator: std.mem.Allocator,
    comptime Commands: type,
    opts: Options,
) ![]const u8 {
    var writer = std.ArrayList(u8).init(allocator);
    defer writer.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // write the completion functions for each sub command
    inline for (@typeInfo(Commands).@"union".fields) |field| {
        const full_name = try std.mem.join(
            alloc,
            "_",
            &.{ opts.function_name, "sub", field.name },
        );

        var sub_opts = opts;
        sub_opts.function_name = full_name;
        const c = try field.type.generateCompletion(alloc, sub_opts);

        try writer.appendSlice(c);
    }

    var case_body = std.ArrayList(u8).init(alloc);
    try case_body.appendSlice("    case $line[1] in\n");

    try writer.writer().print(
        \\_arguments_{s}() {{
        \\    local line state subcmds
        \\    subcmds=(
        \\
    , .{opts.function_name});
    inline for (@typeInfo(Commands).@"union".fields) |field| {
        try writer.writer().print(
            \\        '{s}:{s}'
            \\
        , .{ field.name, field.name });

        try case_body.writer().print(
            \\        {s})
            \\            _arguments_{s}_sub_{s}
            \\        ;;
            \\
        , .{ field.name, opts.function_name, field.name });
    }
    try case_body.appendSlice("    esac\n");

    try writer.appendSlice(
        \\    )
        \\    _arguments \
        \\        '1: :{_describe 'command' subcmds}' \
        \\        '*:: :->args'
        \\
    );
    try writer.appendSlice(case_body.items);
    try writer.appendSlice("}\n");

    return writer.toOwnedSlice();
}

test "command completion" {
    const main = @import("main.zig");
    const Command = main.Commands(union(enum) {
        hello: main.Arguments(&.{
            .{
                .arg = "item",
                .help = "Positional argument.",
                .required = true,
            },
            .{
                .arg = "-c/--control",
                .help = "Toggleable",
            },
        }),
        world: main.Arguments(&TestArguments),
    });

    const comp = try Command.generateCompletion(std.testing.allocator, .{ .function_name = "test" });
    defer std.testing.allocator.free(comp);

    try std.testing.expectEqualStrings(
        \\_arguments_test_sub_hello() {
        \\    _arguments -C \
        \\        ':item:()' \
        \\        '--control[]::()' \
        \\        '-c[]::()'
        \\}
        \\_arguments_test_sub_world() {
        \\    _arguments -C \
        \\        ':item:()' \
        \\        '--limit[]:limit:{compadd $(ls -1)}' \
        \\        '-n[]:n:{compadd $(ls -1)}' \
        \\        '::other:()' \
        \\        '--flag[]::()' \
        \\        '-f[]::()'
        \\}
        \\_arguments_test() {
        \\    local line state subcmds
        \\    subcmds=(
        \\        'hello:hello'
        \\        'world:world'
        \\    )
        \\    _arguments \
        \\        '1: :{_describe 'command' subcmds}' \
        \\        '*:: :->args'
        \\    case $line[1] in
        \\        hello)
        \\            _arguments_test_sub_hello
        \\        ;;
        \\        world)
        \\            _arguments_test_sub_world
        \\        ;;
        \\    esac
        \\}
        \\
    ,
        comp,
    );
}
