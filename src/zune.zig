const std = @import("std");
const luau = @import("luau");

pub const cli = @import("cli.zig");

pub const corelib = @import("core/standard/lib.zig");

pub const DEFAULT_ALLOCATOR = std.heap.c_allocator;

const resolvers_require = @import("core/resolvers/require.zig");
const resolvers_fmt = @import("core/resolvers/fmt.zig");

const zune_info = @import("zune-info");

pub const RunMode = enum {
    Run,
    Test,
};

pub const Flags = struct {
    load_as_global: bool = false,
};

const VERSION = "Zune " ++ zune_info.version ++ "+" ++ std.fmt.comptimePrint("{d}.{d}", .{ luau.LUAU_VERSION.major, luau.LUAU_VERSION.minor });

pub fn openZune(L: *luau.Luau, args: []const []const u8, mode: RunMode, flags: Flags) !void {
    L.openLibs();

    L.pushFunction(resolvers_fmt.fmt_print, "zcore_fmt_print");
    L.setGlobal("print");
    L.pushFunction(struct {
        fn inner(l: *luau.Luau) i32 {
            std.debug.print("\x1b[2m[\x1b[0;33mWARN\x1b[0;2m]\x1b[0m ", .{});
            return resolvers_fmt.fmt_print(l);
        }
    }.inner, "zcore_fmt_warn");
    L.setGlobal("warn");

    L.pushFunction(resolvers_require.zune_require, "zcore_require");
    L.setGlobal("require");

    L.setGlobalLString("_VERSION", VERSION);

    corelib.fs.loadLib(L);
    corelib.task.loadLib(L);
    corelib.luau.loadLib(L);
    corelib.serde.loadLib(L);
    corelib.stdio.loadLib(L);
    corelib.crypto.loadLib(L);
    corelib.regex.loadLib(L);
    corelib.net.loadLib(L);
    try corelib.process.loadLib(L, args);

    corelib.testing.loadLib(L, mode == .Test);

    if (flags.load_as_global) {
        _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
        for ([_][:0]const u8{
            corelib.fs.LIB_NAME,
            corelib.task.LIB_NAME,
            corelib.luau.LIB_NAME,
            corelib.serde.LIB_NAME,
            corelib.stdio.LIB_NAME,
            corelib.crypto.LIB_NAME,
            corelib.regex.LIB_NAME,
            corelib.net.LIB_NAME,
            corelib.process.LIB_NAME,
        }) |lib| {
            const t = L.getField(-1, lib);
            defer L.pop(1);
            if (t == .table) {
                const start = (std.mem.indexOfScalar(u8, lib, '/') orelse continue) + 1;
                if (lib.len < start) continue;
                L.pushValue(-1);
                L.setGlobal(lib[start..]);
            }
        }
    }

    try resolvers_require.loadAliases(DEFAULT_ALLOCATOR);
}
