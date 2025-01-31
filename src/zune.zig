const std = @import("std");
const luau = @import("luau");
const json = @import("json");

const toml = @import("libraries/toml.zig");

pub const cli = @import("cli.zig");

pub const corelib = @import("core/standard/lib.zig");
pub const objects = @import("core/objects/lib.zig");

pub const DEFAULT_ALLOCATOR = std.heap.c_allocator;

pub const runtime_engine = @import("core/runtime/engine.zig");
pub const resolvers_require = @import("core/resolvers/require.zig");
const resolvers_file = @import("core/resolvers/file.zig");
const resolvers_fmt = @import("core/resolvers/fmt.zig");

pub const Debugger = @import("core/runtime/debugger.zig");

const zune_info = @import("zune-info");

const VM = luau.VM;

pub const RunMode = enum {
    Run,
    Test,
    Debug,
};

pub const Flags = struct {
    mode: RunMode,
    limbo: bool = false,
};

pub var CONFIGURATIONS = .{.format_max_depth};

pub const VERSION = "Zune " ++ zune_info.version ++ "+" ++ std.fmt.comptimePrint("{d}.{d}", .{ luau.LUAU_VERSION.major, luau.LUAU_VERSION.minor });

var EXPERIMENTAL_FFI = false;
var EXPERIMENTAL_SQLITE = false;
var STD_ENABLED = true;

const ConstantConfig = struct {
    loadStd: ?bool = null,
};

pub fn loadConfiguration(comptime config: ConstantConfig) void {
    const allocator = DEFAULT_ALLOCATOR;
    const config_content = std.fs.cwd().readFileAlloc(allocator, "zune.toml", std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return std.debug.print("Failed to read zune.toml: {}\n", .{err}),
    };
    defer allocator.free(config_content);

    var zconfig = toml.parse(allocator, config_content) catch |err| {
        return std.debug.print("Failed to parse zune.toml: {}\n", .{err});
    };
    defer zconfig.deinit(allocator);

    if (toml.checkOptionTable(zconfig, "runtime")) |runtime_config| {
        if (toml.checkOptionTable(runtime_config, "debug")) |debug_config| {
            if (toml.checkOptionBool(debug_config, "detailedError")) |enabled|
                runtime_engine.USE_DETAILED_ERROR = enabled;
        }
    }

    if (toml.checkOptionTable(zconfig, "resolvers")) |resolvers_config| {
        if (toml.checkOptionTable(resolvers_config, "formatter")) |fmt_config| {
            if (toml.checkOptionInteger(fmt_config, "maxDepth")) |depth|
                resolvers_fmt.MAX_DEPTH = @truncate(@as(u64, @bitCast(depth)));
            if (toml.checkOptionBool(fmt_config, "useColor")) |enabled|
                resolvers_fmt.USE_COLOR = enabled;
            if (toml.checkOptionBool(fmt_config, "showTableAddress")) |enabled|
                resolvers_fmt.SHOW_TABLE_ADDRESS = enabled;
            if (toml.checkOptionBool(fmt_config, "showRecursiveTable")) |enabled|
                resolvers_fmt.SHOW_RECURSIVE_TABLE = enabled;
            if (toml.checkOptionInteger(fmt_config, "displayBufferContentsMax")) |max|
                resolvers_fmt.DISPLAY_BUFFER_CONTENTS_MAX = @bitCast(max);
        }

        if (toml.checkOptionTable(resolvers_config, "require")) |require_config| {
            if (toml.checkOptionString(require_config, "mode")) |mode| {
                if (std.mem.eql(u8, mode, "RelativeToProject")) {
                    resolvers_require.MODE = .RelativeToCwd;
                } else if (!std.mem.eql(u8, mode, "RelativeToFile")) {
                    std.debug.print("[zune.toml] 'Mode' must be 'RelativeToProject' or 'RelativeToFile'\n", .{});
                }
            }
            if (toml.checkOptionBool(require_config, "loadStd")) |enabled| {
                STD_ENABLED = enabled;
            }
        }
    }

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
            runtime_engine.DEBUG_LEVEL = @max(0, @min(2, @as(u2, @truncate(@as(u64, @bitCast(debug_level))))));
        if (toml.checkOptionInteger(compiling_config, "optimizationLevel")) |opt_level|
            runtime_engine.OPTIMIZATION_LEVEL = @max(0, @min(2, @as(u2, @truncate(@as(u64, @bitCast(opt_level))))));
        if (toml.checkOptionBool(compiling_config, "nativeCodeGen")) |enabled|
            runtime_engine.CODEGEN = enabled;
    }

    if (toml.checkOptionTable(zconfig, "experimental")) |experimental_config| {
        if (toml.checkOptionBool(experimental_config, "ffi")) |enabled|
            EXPERIMENTAL_FFI = enabled;
        if (toml.checkOptionBool(experimental_config, "sqlite")) |enabled|
            EXPERIMENTAL_SQLITE = enabled;
    }

    if (comptime config.loadStd) |enabled|
        STD_ENABLED = enabled;
}

pub fn loadLuaurc(allocator: std.mem.Allocator, dir: std.fs.Dir) anyerror!void {
    const rcFile = dir.openFile(".luaurc", .{}) catch return;
    defer rcFile.close();

    const rcContents = try rcFile.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(rcContents);

    const rcSafeContent = std.mem.trim(u8, rcContents, " \n\t\r");
    if (rcSafeContent.len == 0)
        return;

    var rcJsonRoot = json.parse(allocator, rcSafeContent) catch |err| {
        std.debug.print("Error: .luaurc must be valid JSON: {}\n", .{err});
        return;
    };
    defer rcJsonRoot.deinit();

    const root = rcJsonRoot.value.objectOrNull() orelse return std.debug.print("Error: .luaurc must be an object\n", .{});
    const aliases = root.get("aliases") orelse return std.debug.print("Error: .luaurc must have an 'aliases' field\n", .{});
    const aliases_obj = aliases.objectOrNull() orelse return std.debug.print("Error: .luaurc 'aliases' field must be an object\n", .{});

    const dir_path = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    for (aliases_obj.keys()) |key| {
        const value = aliases_obj.get(key) orelse continue;
        const valueStr = if (value == .string) value.asString() else {
            std.debug.print("Warning: .luaurc -> aliases '{s}' field must be a string\n", .{key});
            continue;
        };
        const keyCopy = try allocator.dupe(u8, key);
        errdefer allocator.free(keyCopy);
        const valuePath = std.fs.path.resolve(allocator, &.{ dir_path, valueStr }) catch |err| {
            std.debug.print("Warning: .luaurc -> aliases '{s}' field must be a valid path: {}\n", .{ key, err });
            allocator.free(keyCopy);
            continue;
        };
        errdefer allocator.free(valuePath);
        try resolvers_require.ALIASES.put(keyCopy, valuePath);
    }

    for (aliases_obj.keys()) |key| {
        const path = resolvers_require.ALIASES.get(key) orelse continue;
        var sub_dir = dir.openDir(path, .{
            .access_sub_paths = true,
        }) catch continue;
        defer sub_dir.close();
        try loadLuaurc(allocator, sub_dir);
    }
}

pub var EnvironmentMap: std.process.EnvMap = undefined;

fn loadEnv(allocator: std.mem.Allocator) !void {
    const path = EnvironmentMap.get("ZUNE_STD_PATH") orelse path: {
        const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(exe_dir);
        break :path try std.fs.path.resolve(allocator, &.{ exe_dir, "lib/std" });
    };
    try resolvers_require.ALIASES.put("std", path);
    try EnvironmentMap.put("ZUNE_STD_PATH", path);
}

pub fn openZune(L: *VM.lua.State, args: []const []const u8, flags: Flags) !void {
    const allocator = DEFAULT_ALLOCATOR;

    EnvironmentMap = std.process.getEnvMap(allocator) catch std.debug.panic("OutOfMemory", .{});

    L.Lopenlibs();

    objects.load(L);

    L.createtable(0, 0);
    L.createtable(0, 2);
    L.Zsetfieldfn(-1, luau.Metamethods.index, struct {
        fn inner(l: *VM.lua.State) !i32 {
            _ = l.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
            l.pushvalue(2);
            _ = l.gettable(-2);
            return 1;
        }
    }.inner);
    L.Zsetfield(-1, luau.Metamethods.metatable, "This metatable is locked");
    _ = L.setmetatable(-2);
    L.setreadonly(-1, true);
    L.setglobal("zune");

    L.Zpushfunction(resolvers_fmt.fmt_print, "zcore_fmt_print");
    L.setglobal("print");
    L.Zpushfunction(struct {
        fn inner(l: *VM.lua.State) !i32 {
            std.debug.print("\x1b[2m[\x1b[0;33mWARN\x1b[0;2m]\x1b[0m ", .{});
            return try resolvers_fmt.fmt_print(l);
        }
    }.inner, "zcore_fmt_warn");
    L.setglobal("warn");

    L.Zsetglobal("_VERSION", VERSION);

    if (!flags.limbo) {
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

        if (EXPERIMENTAL_FFI)
            corelib.ffi.loadLib(L);
        if (EXPERIMENTAL_SQLITE)
            corelib.sqlite.loadLib(L);

        corelib.testing.loadLib(L, flags.mode == .Test);
    }

    try loadLuaurc(DEFAULT_ALLOCATOR, std.fs.cwd());

    if (STD_ENABLED)
        try loadEnv(allocator);
}

test "Zune" {
    const TestRunner = @import("./core/utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"zune.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
}
