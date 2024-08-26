const std = @import("std");

const command = @import("lib.zig");

const zune_info = @import("zune-info");

fn Execute(_: std.mem.Allocator, _: []const []const u8) !void {
    std.debug.print("zune: {s}\n", .{zune_info.version});
}

pub const Command = command.Command{
    .name = "--version",
    .execute = Execute,
    .aliases = &.{
        "-V",
    },
};
