const std = @import("std");
const LUAU_VERSION = @import("luau").LUAU_VERSION;

const command = @import("lib.zig");

const zune_info = @import("zune-info");

fn Execute(_: std.mem.Allocator, _: []const []const u8) !void {
    std.debug.print("zune: {s}\n", .{zune_info.version});
    std.debug.print("luau: {d}.{d}\n", .{ LUAU_VERSION.major, LUAU_VERSION.minor });
}

pub const Command = command.Command{
    .name = "--version",
    .execute = Execute,
    .aliases = &.{
        "-V",
    },
};
