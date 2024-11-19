const std = @import("std");

const Zune = @import("zune.zig");

const Commands = @import("commands/lib.zig");

const CommandMap = Commands.initCommands(&.{
    @import("commands/run.zig").Command,
    @import("commands/test.zig").Command,
    @import("commands/eval.zig").Command,
    @import("commands/setup.zig").Command,
    @import("commands/repl/lib.zig").Command,
    @import("commands/init.zig").Command,

    @import("commands/luau.zig").Command,
    @import("commands/help.zig").Command,

    @import("commands/version.zig").Command,
});

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
