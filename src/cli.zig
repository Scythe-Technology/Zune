const std = @import("std");

const Zune = @import("zune.zig");

const Commands = @import("commands/lib.zig");

const CommandMap = Commands.CommandMap;

pub fn start() !void {
    const args = try std.process.argsAlloc(Zune.DEFAULT_ALLOCATOR);
    defer std.process.argsFree(Zune.DEFAULT_ALLOCATOR, args);

    if (args.len < 2) {
        const command = CommandMap.get("help") orelse @panic("Help command missing.");
        return command.execute(Zune.DEFAULT_ALLOCATOR, &.{});
    }

    if (CommandMap.get(args[1])) |command|
        return command.execute(Zune.DEFAULT_ALLOCATOR, args[2..]);

    std.debug.print("Unknown command, try 'help' or '-h'\n", .{});

    return;
}

test {
    std.testing.refAllDecls(@This());
}
