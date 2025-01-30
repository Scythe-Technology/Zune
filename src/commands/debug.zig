const std = @import("std");
const luau = @import("luau");

const command = @import("lib.zig");

const Zune = @import("../zune.zig");

const Engine = @import("../core/runtime/engine.zig");
const Scheduler = @import("../core/runtime/scheduler.zig");
const Debugger = @import("../core/runtime/debugger.zig");

const file = @import("../core/resolvers/file.zig");

const History = @import("repl/History.zig");
const Terminal = @import("repl/Terminal.zig");

const VM = luau.VM;

pub var HISTORY: ?*History = null;

pub fn SigInt() void {
    if (HISTORY) |history|
        history.deinit();
}

pub fn DebuggerExit() void {
    SigInt();
}

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var history = try History.init(allocator, ".zune/.debug_history");
    errdefer history.deinit();

    HISTORY = &history;
    Debugger.ACTIVE = true;

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

    if (run_args.len < 1) {
        std.debug.print("Usage: run [OPTIONS] <luau file>\n", .{});
        return;
    }

    Zune.loadConfiguration(.{});

    var LOAD_FLAGS: Zune.Flags = .{
        .mode = .Debug,
    };
    var ALWAYS_DEBUG = true;

    if (flags) |f| for (f) |flag| {
        if (flag.len >= 2 and std.mem.eql(u8, flag[0..2], "-O")) {
            if (flag.len == 3 and flag[2] >= '0' and flag[2] <= '2') {
                const level: u2 = switch (flag[2]) {
                    '0' => 0,
                    '1' => 1,
                    '2' => 2,
                    else => unreachable,
                };
                Engine.OPTIMIZATION_LEVEL = level;
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

    Engine.DEBUG_LEVEL = 2;
    Engine.CODEGEN = false;
    Engine.JIT_ENABLED = false;

    Zune.resolvers_require.RUN_MODE = .Debug;

    const dir = std.fs.cwd();
    const module = run_args[0];

    var maybeResult: ?file.SearchResult([]const u8) = null;
    defer if (maybeResult) |r| r.deinit();
    var maybeFileName: ?[]const u8 = null;
    defer if (maybeResult == null) if (maybeFileName) |f| allocator.free(f);
    var maybeFileContent: ?[]const u8 = null;
    defer if (maybeFileContent) |c| allocator.free(c);

    if (module.len == 1 and module[0] == '-') {
        maybeFileContent = try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
        maybeFileName = try dir.realpathAlloc(allocator, "./");
    } else if (dir.readFileAlloc(allocator, module, std.math.maxInt(usize)) catch null) |content| {
        maybeFileContent = content;
        maybeFileName = try dir.realpathAlloc(allocator, module);
    } else {
        const result = try Engine.findLuauFile(allocator, dir, module);
        maybeResult = result;
        switch (result.result) {
            .exact => |e| maybeFileName = e,
            .results => |results| maybeFileName = results[0],
            .none => return error.FileNotFound,
        }
        maybeFileContent = try std.fs.cwd().readFileAlloc(allocator, maybeFileName.?, std.math.maxInt(usize));
    }

    const fileContent = maybeFileContent orelse std.debug.panic("FileNotFound", .{});
    const fileName = maybeFileName orelse std.debug.panic("FileNotFound", .{});

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

        var scheduler = Scheduler.init(allocator, L);
        defer scheduler.deinit();

        try Scheduler.SCHEDULERS.append(&scheduler);

        const callbacks = L.callbacks();

        callbacks.*.debugbreak = Debugger.debugbreak;
        callbacks.*.debugstep = Debugger.debugstep;
        callbacks.*.debugprotectederror = Debugger.debugprotectederror;

        try Engine.prepAsync(L, &scheduler, .{
            .args = run_args,
        }, LOAD_FLAGS);

        L.setsafeenv(VM.lua.GLOBALSINDEX, true);

        const terminal = &(Zune.corelib.stdio.TERMINAL orelse std.debug.panic("Terminal not initialized", .{}));
        errdefer terminal.restoreSettings() catch {};
        errdefer terminal.restoreOutputMode() catch {};

        if (!terminal.stdin_istty)
            history.enabled = false;

        try terminal.saveSettings();

        const ML = L.newthread();

        ML.Lsandboxthread();

        Zune.resolvers_require.load_require(ML);

        const cwdDirPath = dir.realpathAlloc(allocator, ".") catch return error.FileNotFound;
        defer allocator.free(cwdDirPath);

        const moduleRelativeName = try std.fs.path.relative(allocator, cwdDirPath, fileName);
        defer allocator.free(moduleRelativeName);

        Engine.setLuaFileContext(ML, .{
            .path = fileName,
            .name = moduleRelativeName,
            .source = fileContent,
        });

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        const sourceNameZ = try std.mem.joinZ(allocator, "", &.{ "@", fileName });
        defer allocator.free(sourceNameZ);

        Engine.loadModule(ML, sourceNameZ, fileContent, null) catch |err| switch (err) {
            error.Syntax => {
                std.debug.print("SyntaxError: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
                return;
            },
            else => return err,
        };
        const ref = ML.ref(-1).?;
        try Debugger.addReference(allocator, ML, fileName, ref);

        try Debugger.prompt(ML, .None, null);
        Engine.runAsync(ML, &scheduler, .{ .cleanUp = true, .mode = .Debug }) catch {}; // Soft continue

        Debugger.printResult("execution finished\n", .{});
        if (!ALWAYS_DEBUG)
            break;
    }

    SigInt();
}

pub const Command = command.Command{
    .name = "debug",
    .execute = Execute,
};
