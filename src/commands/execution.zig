const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const command = @import("lib.zig");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Debugger = Zune.Runtime.Debugger;
const Profiler = Zune.Runtime.Profiler;

const File = Zune.Resolvers.File;

const History = @import("repl/History.zig");
const Terminal = @import("repl/Terminal.zig");

const VM = luau.VM;

fn getFile(allocator: std.mem.Allocator, dir: std.fs.Dir, input: []const u8) !struct { []const u8, []const u8 } {
    var maybeResult: ?File.SearchResult([]const u8) = null;
    defer if (maybeResult) |r| r.deinit();
    var maybeFileName: ?[]const u8 = null;
    errdefer if (maybeFileName) |f| allocator.free(f);
    var maybeFileContent: ?[]const u8 = null;
    errdefer if (maybeFileContent) |c| allocator.free(c);

    if (input.len == 1 and input[0] == '-') {
        maybeFileContent = try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
        maybeFileName = try allocator.dupe(u8, "STDIN");
    } else {
        const path = try File.resolvePath(allocator, Zune.STATE.ENV_MAP, input);
        if (dir.readFileAlloc(allocator, path, std.math.maxInt(usize)) catch null) |content| {
            maybeFileContent = content;
            maybeFileName = path;
        } else {
            defer allocator.free(path);
            const result = try File.findLuauFile(allocator, dir, input);
            maybeResult = result;
            switch (result.result) {
                .exact => |e| maybeFileName = try allocator.dupe(u8, e),
                .results => |results| maybeFileName = try allocator.dupe(u8, results[0]),
                .none => return error.FileNotFound,
            }
            maybeFileContent = try std.fs.cwd().readFileAlloc(allocator, maybeFileName.?, std.math.maxInt(usize));
        }
    }

    return .{ maybeFileName.?, maybeFileContent.? };
}

fn splitArgs(args: []const []const u8) struct { []const []const u8, ?[]const []const u8 } {
    var run_args: []const []const u8 = args;
    var flags: ?[]const []const u8 = null;
    blk: {
        for (args, 0..) |arg, ap| {
            if (arg.len < 1 or arg[0] != '-' or arg.len == 1) {
                if (ap > 0)
                    flags = args[0..ap];
                run_args = args[ap..];
                break :blk;
            }
        }
        flags = args;
        run_args = &[0][]const u8{};
        break :blk;
    }
    return .{ run_args, flags };
}

fn cmdRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const run_args, const flags = splitArgs(args);

    if (run_args.len < 1) {
        std.debug.print("Usage: run [OPTIONS] <luau file>\n", .{});
        return;
    }

    Zune.loadConfiguration(std.fs.cwd());

    var LOAD_FLAGS: Zune.Flags = .{
        .mode = .Run,
    };
    var PROFILER: ?u64 = null;
    if (flags) |f| for (f) |flag| {
        if (std.mem.startsWith(u8, flag[0..9], "--profile")) {
            PROFILER = 10000;
            if (flag.len > 10 and flag[9] == '=') {
                const level = try std.fmt.parseInt(u64, flag[10..], 10);
                PROFILER = level;
            }
        } else if (std.mem.startsWith(u8, flag[0..2], "-O")) {
            if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                const level: u2 = switch (flag[2]) {
                    '0' => 0,
                    '1' => 1,
                    '2' => 2,
                    else => unreachable,
                };
                Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL = level;
            } else {
                std.debug.print("Flag: -O, Invalid Optimization level, usage: -O<N>\n", .{});
                return;
            }
        } else if (std.mem.startsWith(u8, flag[0..2], "-g")) {
            if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                const level: u2 = switch (flag[2]) {
                    '0' => 0,
                    '1' => 1,
                    '2' => 2,
                    else => unreachable,
                };
                Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL = level;
            } else {
                std.debug.print("Flag: -g, Invalid Debug level, usage: -g<N>\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, flag, "--native")) {
            Zune.STATE.LUAU_OPTIONS.CODEGEN = true;
        } else if (std.mem.eql(u8, flag, "--no-native")) {
            Zune.STATE.LUAU_OPTIONS.CODEGEN = false;
        } else if (std.mem.eql(u8, flag, "--no-jit")) {
            Zune.STATE.LUAU_OPTIONS.JIT_ENABLED = false;
        } else if (std.mem.eql(u8, flag, "--limbo")) {
            LOAD_FLAGS.limbo = true;
        }
    };

    const dir = std.fs.cwd();
    const module = run_args[0];

    const filePath, const fileContent = try getFile(allocator, dir, module);
    defer allocator.free(filePath);
    defer allocator.free(fileContent);

    if (fileContent.len == 0) {
        std.debug.print("File is empty: {s}\n", .{run_args[0]});
        return;
    }

    var L = try luau.init(&allocator);
    defer L.deinit();
    var scheduler = try Scheduler.init(allocator, L);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Zune.loadLuaurc(Zune.DEFAULT_ALLOCATOR, std.fs.cwd(), null);
    try Engine.prepAsync(L, &scheduler);
    try Zune.openZune(L, run_args, LOAD_FLAGS);

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = L.newthread();

    ML.Lsandboxthread();

    Engine.setLuaFileContext(ML, .{
        .source = fileContent,
        .main = true,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const sourceNameZ = try std.mem.concatWithSentinel(allocator, u8, &.{ "@", filePath }, 0);
    defer allocator.free(sourceNameZ);

    Engine.loadModule(ML, sourceNameZ, fileContent, null) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("SyntaxError: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
            return;
        },
        else => return err,
    };

    if (PROFILER) |freq|
        try Profiler.start(L, freq);
    defer if (PROFILER != null) {
        Profiler.end();
        Profiler.dump("profile.out");
    };
    Engine.runAsync(ML, &scheduler, .{ .cleanUp = true }) catch return; // Soft exit
}

fn cmdTest(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const run_args, const flags = splitArgs(args);

    if (run_args.len < 1) {
        std.debug.print("Usage: test <luau file>\n", .{});
        return;
    }

    Zune.loadConfiguration(std.fs.cwd());

    var LOAD_FLAGS: Zune.Flags = .{
        .mode = .Test,
    };
    if (flags) |f| for (f) |flag| {
        if (std.mem.startsWith(u8, flag[0..2], "-O")) {
            if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                const level: u2 = switch (flag[2]) {
                    '0' => 0,
                    '1' => 1,
                    '2' => 2,
                    else => unreachable,
                };
                Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL = level;
            } else {
                std.debug.print("Flag: -O, Invalid Optimization level, usage: -O<N>\n", .{});
                return;
            }
        } else if (std.mem.startsWith(u8, flag[0..2], "-g")) {
            if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                const level: u2 = switch (flag[2]) {
                    '0' => 0,
                    '1' => 1,
                    '2' => 2,
                    else => unreachable,
                };
                Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL = level;
            } else {
                std.debug.print("Flag: -g, Invalid Debug level, usage: -g<N>\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, flag, "--native")) {
            Zune.STATE.LUAU_OPTIONS.CODEGEN = true;
        } else if (std.mem.eql(u8, flag, "--no-native")) {
            Zune.STATE.LUAU_OPTIONS.CODEGEN = false;
        } else if (std.mem.eql(u8, flag, "--no-jit")) {
            Zune.STATE.LUAU_OPTIONS.JIT_ENABLED = false;
        } else if (std.mem.eql(u8, flag, "--limbo")) {
            LOAD_FLAGS.limbo = true;
        }
    };

    const dir = std.fs.cwd();
    const module = args[0];

    const filePath, const fileContent = try getFile(allocator, dir, module);
    defer allocator.free(filePath);
    defer allocator.free(fileContent);

    if (fileContent.len == 0) {
        std.debug.print("File is empty: {s}\n", .{args[0]});
        return;
    }

    var gpa = std.heap.DebugAllocator(.{
        .safety = true,
        .stack_trace_frames = 8,
    }){};
    defer {
        const result = gpa.deinit();
        if (result == .leak) {
            std.debug.print(" \x1b[1;31m[Memory leaks detected]\x1b[0m\n", .{});
            std.debug.print(" This is likely a zune bug, report it on the zune repository.\n", .{});
            std.debug.print(" \x1b[4mhttps://github.com/Scythe-Technology/Zune\x1b[0m\n\n", .{});
        }
    }

    const gpa_allocator = gpa.allocator();

    var L = try luau.init(&gpa_allocator);
    defer L.deinit();
    var scheduler = try Scheduler.init(gpa_allocator, L);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Zune.loadLuaurc(Zune.DEFAULT_ALLOCATOR, std.fs.cwd(), null);
    try Engine.prepAsync(L, &scheduler);
    try Zune.openZune(L, args, LOAD_FLAGS);

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = L.newthread();

    ML.Lsandboxthread();

    Engine.setLuaFileContext(ML, .{
        .source = fileContent,
        .main = true,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const sourceNameZ = try std.mem.concatWithSentinel(allocator, u8, &.{ "@", filePath }, 0);
    defer allocator.free(sourceNameZ);

    Engine.loadModule(ML, sourceNameZ, fileContent, null) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("SyntaxError: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
            return;
        },
        else => return err,
    };

    const start = VM.lperf.clock();

    Engine.runAsync(ML, &scheduler, .{ .cleanUp = true }) catch {};

    const reuslt = Zune.corelib.testing.finish_testing(L, start);

    if (reuslt.failed > 0) {
        std.process.exit(1);
    }
}

fn cmdEval(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: eval <luau>\n", .{});
        return;
    }

    Zune.loadConfiguration(std.fs.cwd());

    const fileContent = args[0];

    if (fileContent.len == 0) {
        std.debug.print("Eval is empty\n", .{});
        return;
    }

    var L = try luau.init(&allocator);
    defer L.deinit();
    var scheduler = try Scheduler.init(allocator, L);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Zune.loadLuaurc(Zune.DEFAULT_ALLOCATOR, std.fs.cwd(), null);
    try Engine.prepAsync(L, &scheduler);
    try Zune.openZune(L, args, .{ .mode = .Run });

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = L.newthread();

    ML.Lsandboxthread();

    Engine.setLuaFileContext(ML, .{
        .source = fileContent,
        .main = true,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    Engine.loadModule(ML, "@EVAL", fileContent, null) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("SyntaxError: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
            return;
        },
        else => return err,
    };

    Engine.runAsync(ML, &scheduler, .{ .cleanUp = true }) catch return; // Soft exit
}

fn cmdDebug(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (comptime !Debugger.PlatformSupported())
        return error.PlatformNotSupported;
    var history = try History.init(allocator, ".zune/.debug_history");
    errdefer history.deinit();

    Debugger.HISTORY = &history;
    Debugger.ACTIVE = true;

    const run_args, const flags = splitArgs(args);

    if (run_args.len < 1) {
        std.debug.print("Usage: run [OPTIONS] <luau file>\n", .{});
        return;
    }

    Zune.loadConfiguration(std.fs.cwd());

    var LOAD_FLAGS: Zune.Flags = .{
        .mode = .Debug,
    };
    var ALWAYS_DEBUG = true;

    if (flags) |f| for (f) |flag| {
        if (std.mem.startsWith(u8, flag, "-O")) {
            if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                const level: u2 = switch (flag[2]) {
                    '0' => 0,
                    '1' => 1,
                    '2' => 2,
                    else => unreachable,
                };
                Zune.STATE.LUAU_OPTIONS.OPTIMIZATION_LEVEL = level;
            } else {
                std.debug.print("Flag: -O, Invalid Optimization level, usage: -O<N>\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, flag, "--once")) {
            ALWAYS_DEBUG = false;
        } else if (std.mem.eql(u8, flag, "--limbo")) {
            LOAD_FLAGS.limbo = true;
        }
    };

    Zune.STATE.LUAU_OPTIONS.DEBUG_LEVEL = 2;
    Zune.STATE.LUAU_OPTIONS.CODEGEN = false;
    Zune.STATE.LUAU_OPTIONS.JIT_ENABLED = false;

    Zune.STATE.RUN_MODE = .Debug;

    const dir = std.fs.cwd();
    const module = run_args[0];

    const filePath, const fileContent = try getFile(allocator, dir, module);
    defer allocator.free(filePath);
    defer allocator.free(fileContent);

    if (fileContent.len == 0) {
        std.debug.print("File is empty: {s}\n", .{run_args[0]});
        return;
    }

    while (true) {
        defer Debugger.DEBUG.dead = false;
        Debugger.MODULE_REFERENCES.clearAndFree();

        var L = try luau.init(&allocator);
        defer L.deinit();

        L.singlestep(true);

        var scheduler = try Scheduler.init(allocator, L);
        defer scheduler.deinit();

        try Scheduler.SCHEDULERS.append(&scheduler);

        const callbacks = L.callbacks();

        callbacks.*.debugbreak = Debugger.debugbreak;
        callbacks.*.debugstep = Debugger.debugstep;
        callbacks.*.debugprotectederror = Debugger.debugprotectederror;

        try Zune.loadLuaurc(allocator, std.fs.cwd(), null);
        try Engine.prepAsync(L, &scheduler);
        try Zune.openZune(L, run_args, LOAD_FLAGS);

        L.setsafeenv(VM.lua.GLOBALSINDEX, true);

        const terminal = &(Zune.corelib.io.TERMINAL orelse std.debug.panic("Terminal not initialized", .{}));
        errdefer terminal.restoreSettings() catch {};
        errdefer terminal.restoreOutputMode() catch {};

        if (!terminal.stdin_istty)
            history.enabled = false;

        try terminal.saveSettings();

        const ML = L.newthread();

        ML.Lsandboxthread();

        Engine.setLuaFileContext(ML, .{
            .source = fileContent,
            .main = true,
        });

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        const sourceNameZ = try std.mem.concatWithSentinel(allocator, u8, &.{ "@", filePath }, 0);
        defer allocator.free(sourceNameZ);

        Engine.loadModule(ML, sourceNameZ, fileContent, null) catch |err| switch (err) {
            error.Syntax => {
                std.debug.print("SyntaxError: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
                return;
            },
            else => return err,
        };
        const ref = ML.ref(-1).?;
        try Debugger.addReference(allocator, ML, filePath, ref);

        try Debugger.prompt(ML, .None, null);
        Engine.runAsync(ML, &scheduler, .{ .cleanUp = true, .mode = .Debug }) catch {}; // Soft continue

        Debugger.printResult("execution finished\n", .{});
        if (!ALWAYS_DEBUG)
            break;
    }

    Debugger.DebuggerExit();
}

pub const RunCmd = command.Command{ .name = "run", .execute = cmdRun };
pub const TestCmd = command.Command{ .name = "test", .execute = cmdTest };
pub const EvalCmd = command.Command{ .name = "--eval", .execute = cmdEval, .aliases = &.{"-e"} };
pub const DebugCmd = command.Command{ .name = "debug", .execute = cmdDebug };

test cmdRun {
    const allocator = std.testing.allocator;
    try cmdRun(allocator, &.{"test/cli/run"});
}

test cmdTest {
    const allocator = std.testing.allocator;
    try cmdTest(allocator, &.{"test/cli/test"});
}

test cmdEval {
    const allocator = std.testing.allocator;
    try cmdEval(allocator, &.{"print(\"Hello!\")"});
}
