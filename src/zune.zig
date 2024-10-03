const std = @import("std");
const luau = @import("luau");

const toml = @import("libraries/toml.zig");

pub const cli = @import("cli.zig");

pub const corelib = @import("core/standard/lib.zig");

pub const DEFAULT_ALLOCATOR = std.heap.c_allocator;

pub const runtime_engine = @import("core/runtime/engine.zig");
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

pub var CONFIGURATIONS = .{.format_max_depth};

const VERSION = "Zune " ++ zune_info.version ++ "+" ++ std.fmt.comptimePrint("{d}.{d}", .{ luau.LUAU_VERSION.major, luau.LUAU_VERSION.minor });

pub fn loadConfiguration() void {
    const config_content = std.fs.cwd().readFileAlloc(DEFAULT_ALLOCATOR, "zune.toml", std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return std.debug.print("Failed to read zune.toml: {}\n", .{err}),
    };
    defer DEFAULT_ALLOCATOR.free(config_content);

    var zconfig = toml.parse(DEFAULT_ALLOCATOR, config_content) catch |err| {
        return std.debug.print("Failed to parse zune.toml: {}\n", .{err});
    };
    defer zconfig.deinit(DEFAULT_ALLOCATOR);

    if (toml.checkOptionTable(zconfig, "luau")) |luau_config| {
        if (toml.checkOptionTable(luau_config, "fflags")) |fflags_config| {
            var iter = fflags_config.table.iterator();
            while (iter.next()) |entry| {
                switch (entry.value_ptr.*) {
                    .boolean => luau.Flags.setBoolean(entry.key_ptr.*, entry.value_ptr.*.boolean) catch |err| {
                        std.debug.print("[zune.toml] FFlag ({s}): {}\n", .{ entry.key_ptr.*, err });
                    },
                    .integer => luau.Flags.setInteger(entry.key_ptr.*, @truncate(entry.value_ptr.*.integer)) catch |err| {
                        std.debug.print("[zune.toml] FFlag ({s}): {}\n", .{ entry.key_ptr.*, err });
                    },
                    else => |t| std.debug.print("[zune.toml] Unsupported type for FFlags: {s}\n", .{@tagName(t)}),
                }
            }
        }
    }

    if (toml.checkOptionTable(zconfig, "compiling")) |compiling_config| {
        if (toml.checkOptionInteger(compiling_config, "debugLevel")) |debug_level|
            runtime_engine.DEBUG_LEVEL = @max(0, @min(2, @as(u2, @truncate(@as(u64, @intCast(debug_level))))));
        if (toml.checkOptionInteger(compiling_config, "optimizationLevel")) |opt_level|
            runtime_engine.OPTIMIZATION_LEVEL = @max(0, @min(2, @as(u2, @truncate(@as(u64, @intCast(opt_level))))));
        if (toml.checkOptionBool(compiling_config, "nativeCodeGen")) |codegen|
            runtime_engine.CODEGEN = codegen;
    }

    if (toml.checkOptionTable(zconfig, "resolvers")) |resolvers_config| {
        if (toml.checkOptionTable(resolvers_config, "formatter")) |fmt_config| {
            if (toml.checkOptionInteger(fmt_config, "maxDepth")) |depth|
                resolvers_fmt.MAX_DEPTH = @truncate(@as(u64, @intCast(depth)));
            if (toml.checkOptionBool(fmt_config, "showTableAddress")) |show_addr|
                resolvers_fmt.SHOW_TABLE_ADDRESS = show_addr;
        }

        if (toml.checkOptionTable(resolvers_config, "require")) |require_config| {
            if (toml.checkOptionString(require_config, "mode")) |mode| {
                if (std.mem.eql(u8, mode, "RelativeToProject")) {
                    resolvers_require.MODE = .RelativeToCwd;
                } else if (!std.mem.eql(u8, mode, "RelativeToFile")) {
                    std.debug.print("[zune.toml] 'Mode' must be 'RelativeToProject' or 'RelativeToFile'\n", .{});
                }
            }
        }
    }
}

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

    resolvers_require.load_require(L);

    L.setGlobalLString("_VERSION", VERSION);

    corelib.fs.loadLib(L);
    corelib.task.loadLib(L);
    corelib.luau.loadLib(L);
    corelib.serde.loadLib(L);
    corelib.stdio.loadLib(L);
    corelib.crypto.loadLib(L);
    corelib.regex.loadLib(L);
    corelib.net.loadLib(L);
    corelib.datetime.loadLib(L);
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
            corelib.datetime.LIB_NAME,
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
