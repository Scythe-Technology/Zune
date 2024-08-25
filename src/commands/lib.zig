const std = @import("std");

pub const Command = struct {
    name: []const u8,
    execute: *const fn (allocator: @import("std").mem.Allocator, args: []const []const u8) anyerror!void,
    aliases: ?[]const []const u8 = null,
};

pub fn initCommands(comptime commands: []const Command) std.StaticStringMap(Command) {
    var count = 0;

    for (commands) |command| {
        if (command.aliases) |aliases| count += aliases.len;
        count += 1;
    }

    var list: [count]struct { []const u8, Command } = undefined;

    var i = 0;
    for (commands) |command| {
        list[i] = .{ command.name, command };
        i += 1;
        if (command.aliases) |aliases| for (aliases) |alias| {
            list[i] = .{ alias, command };
            i += 1;
        };
    }

    return std.StaticStringMap(Command).initComptime(list);
}
