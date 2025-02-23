const std = @import("std");
const utils = @import("utils.zig");
const cli = @import("cli.zig");

const parser = @import("parser.zig");
const arguments = @import("arguments.zig");

pub const ArgumentDescriptor = arguments.ArgumentDescriptor;
pub const ArgParser = parser.ArgParser;
pub const Arg = cli.Arg;
pub const ArgumentIterator = cli.ArgumentIterator;
pub const Options = parser.Options;

pub const ParseError = parser.ParseError;

test "all" {
    _ = cli;
    _ = utils;
    _ = parser;
    _ = arguments;
    _ = @import("help.zig");
    _ = @import("completion.zig");
}

fn testArgumentInfoParsing(
    comptime descriptor: ArgumentDescriptor,
    comptime expected: arguments.Argument,
) !void {
    const actual = try arguments.Argument.fromDescriptor(descriptor);
    try std.testing.expectEqualDeep(
        expected.info,
        actual.info,
    );
}

test "arg descriptor parsing" {
    const d1: ArgumentDescriptor = .{ .arg = "-n/--limit value", .help = "" };
    try testArgumentInfoParsing(d1, .{
        .desc = d1,
        .name = "limit",
        .info = .{ .flag = .{
            .short_name = "n",
            .accepts_value = true,
            .type = .short_and_long,
        } },
    });

    const d2: ArgumentDescriptor = .{ .arg = "-n/--limit", .help = "" };
    try testArgumentInfoParsing(d2, .{
        .desc = d2,
        .name = "limit",
        .info = .{ .flag = .{
            .short_name = "n",
            .accepts_value = false,
            .type = .short_and_long,
        } },
    });

    const d3: ArgumentDescriptor = .{ .arg = "pos", .help = "" };
    try testArgumentInfoParsing(d3, .{
        .desc = d3,
        .name = "pos",
        .info = .{ .positional = .{} },
    });

    const d4: ArgumentDescriptor = .{ .arg = "pos", .help = "", .default = "Hello" };
    try testArgumentInfoParsing(d4, .{
        .desc = d4,
        .name = "pos",
        .info = .{ .positional = .{} },
    });
}

pub fn Arguments(comptime arg_descs: []const ArgumentDescriptor) type {
    const args = arguments.ArgumentsFromDescriptors(arg_descs);
    return ArgParser(args);
}

pub fn Commands(comptime U: type) type {
    if (@typeInfo(U) != .@"union")
        @compileError("Commands must be given a union type");
    return ArgParser(U);
}

fn testParseArgs(comptime Parser: type, comptime string: []const u8) !Parser.Parsed {
    const arg_strings = try utils.fromString(
        std.testing.allocator,
        string,
    );
    defer std.testing.allocator.free(arg_strings);
    var argitt = cli.ArgumentIterator.init(arg_strings);
    var p = Parser.init(&argitt, .{ .forgiving = true });
    return try p.parseAll();
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

test "test-parse-1" {
    const Parser = Arguments(&TestArguments);
    {
        const parsed = try testParseArgs(Parser, "hello --limit 12 goodbye -f");
        try std.testing.expectEqual(parsed.limit, 12);
        try std.testing.expectEqualStrings(parsed.item, "hello");
        try std.testing.expectEqualStrings(parsed.other.?, "goodbye");
        try std.testing.expectEqual(true, parsed.flag);
    }

    {
        const parsed = try testParseArgs(Parser, "hello --limit 12 --flag");
        try std.testing.expectEqual(parsed.limit, 12);
        try std.testing.expectEqualStrings(parsed.item, "hello");
        try std.testing.expectEqual(parsed.other, null);
        try std.testing.expectEqual(true, parsed.flag);
    }

    {
        const parsed = try testParseArgs(Parser, "hello --flag --limit");
        try std.testing.expectEqual(parsed.limit, null);
        try std.testing.expectEqualStrings(parsed.item, "hello");
        try std.testing.expectEqual(parsed.other, null);
        try std.testing.expectEqual(true, parsed.flag);
    }
}

test "test-parse-2" {
    const Parser = Arguments(&.{
        .{
            .arg = "command",
            .help = "Subcommand to print extended help for.",
        },
    });
    {
        const parsed = try testParseArgs(Parser, "");
        try std.testing.expectEqual(parsed.command, null);
    }
}

const MoreTestArguments = [_]ArgumentDescriptor{
    .{
        .arg = "item",
        .help = "Positional argument.",
        .required = true,
    },
    .{
        .arg = "-c/--control",
        .help = "Toggleable",
    },
};

const MutualTestArguments = [_]ArgumentDescriptor{
    .{
        .arg = "--interactive",
        .help = "Toggleable",
    },
};

const TestCommands = union(enum) {
    hello: Arguments(&TestArguments),
    world: Arguments(&MutualTestArguments),
};

test "commands-1" {
    const Parser = Commands(TestCommands);
    {
        const parsed = try testParseArgs(Parser, "hello abc --flag");
        const c = parsed.hello;
        try std.testing.expectEqualStrings("abc", c.item);
        try std.testing.expectEqual(true, c.flag);
    }
}
