const std = @import("std");
const luau = @import("luau");

const command = @import("lib.zig");

const zune_info = @import("zune-info");

const USAGE = "Usage: luau <list-fflags | version>\n";
fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        return std.debug.print(USAGE, .{});
    }

    if (std.mem.eql(u8, args[0], "list-fflags")) {
        const flags = try luau.Flags.getFlags(allocator);
        defer flags.deinit();

        var long_name: usize = 0;
        for (flags.flags) |flag| long_name = @max(long_name, flag.name.len);

        for (flags.flags) |flag| {
            const pad_size = (long_name - flag.name.len) + 2;

            var padding = try allocator.alloc(u8, pad_size);
            defer allocator.free(padding);

            for (0..pad_size) |i| padding[i] = '.';

            const string_value = switch (flag.type) {
                .boolean => if (try luau.Flags.getBoolean(flag.name)) "\x1b[1;32mtrue\x1b[0m" else "\x1b[1;31mfalse\x1b[0m",
                .integer => try std.fmt.allocPrint(allocator, " \x1b[1;33m{d}\x1b[0m", .{try luau.Flags.getInteger(flag.name)}),
            };

            defer if (flag.type == .integer) allocator.free(string_value);

            std.debug.print("\x1b[1m{s} \x1b[2m{s}\x1b[0m = ({s}) {s}\n", .{
                flag.name,
                padding,
                switch (flag.type) {
                    .boolean => "\x1b[1;33mbool\x1b[0m",
                    .integer => "\x1b[1;96mint\x1b[0m",
                },
                string_value,
            });
        }
    } else if (std.mem.eql(u8, args[0], "version")) {
        std.debug.print("{}.{}", .{ luau.LUAU_VERSION.major, luau.LUAU_VERSION.minor });
    } else {
        return std.debug.print(USAGE, .{});
    }
}

pub const Command = command.Command{
    .name = "luau",
    .execute = Execute,
};
