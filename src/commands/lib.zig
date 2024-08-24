pub const Command = struct {
    name: []const u8,
    execute: *const fn (allocator: @import("std").mem.Allocator, args: []const []const u8) anyerror!void,
};
