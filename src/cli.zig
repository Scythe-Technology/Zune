const std = @import("std");

const zune = @import("zune.zig");

const Commands = @import("commands/lib.zig");

const CommandMap = Commands.initCommands(&.{
    @import("commands/run.zig").Command,
    @import("commands/test.zig").Command,
    @import("commands/setup.zig").Command,
    @import("commands/version.zig").Command,
});

pub fn start() !void {
    const args = try std.process.argsAlloc(zune.DEFAULT_ALLOCATOR);
    defer std.process.argsFree(zune.DEFAULT_ALLOCATOR, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <operation>\n", .{args[0]});
        return;
    }

    if (CommandMap.get(args[1])) |command| return command.execute(zune.DEFAULT_ALLOCATOR, args[2..]);

    std.debug.print("Unknown command\n", .{});

    return;
}

test {
    std.testing.refAllDecls(@This());
}
