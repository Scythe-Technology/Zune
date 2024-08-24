const std = @import("std");
const luau = @import("luau");

pub const cli = @import("cli.zig");

pub const corelib = @import("core/standard/lib.zig");

pub const DEFAULT_ALLOCATOR = std.heap.c_allocator;

const resolvers_require = @import("core/resolvers/require.zig");
const resolvers_fmt = @import("core/resolvers/fmt.zig");

pub const RunMode = enum {
    Run,
    Test,
};

pub fn openZune(L: *luau.Luau, args: []const []const u8, mode: RunMode) !void {
    L.openLibs();

    L.pushFunction(resolvers_fmt.fmt_print, "zcore_fmt_print");
    L.setGlobal("print");

    L.pushFunction(resolvers_require.zune_require, "zcore_require");
    L.setGlobal("require");

    corelib.fs.loadLib(L);
    corelib.task.loadLib(L);
    corelib.luau.loadLib(L);
    corelib.serde.loadLib(L);
    corelib.stdio.loadLib(L);
    try corelib.net.loadLib(L);
    try corelib.process.loadLib(L, args);

    corelib.testing.loadLib(L, mode == .Test);
}
