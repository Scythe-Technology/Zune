const std = @import("std");

const command = @import("lib.zig");

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    if (args.len < 1) {
        std.debug.print("Usage: build <luau file>\n", .{});
        return;
    }

    const dir = std.fs.cwd();
    const module = args[0];
    _ = module;
    _ = dir;
}

pub const Command = command.Command{ .name = "build", .execute = Execute };
