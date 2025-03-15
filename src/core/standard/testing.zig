const std = @import("std");
const luau = @import("luau");

const Zune = @import("../../zune.zig");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const formatter = @import("../resolvers/fmt.zig");

const luaHelper = @import("../utils/luahelper.zig");

const test_lib_gz = @embedFile("../lua/testing_lib.luac.gz");
const test_lib_size = @embedFile("../lua/testing_lib.luac").len;

const VM = luau.VM;

pub const LIB_NAME = "testing";

fn testing_debug(L: *VM.lua.State) i32 {
    const str = L.Lcheckstring(1);
    std.debug.print("{s}\n", .{str});
    return 0;
}

var REF_LEAKED_SOURCE = std.AutoHashMap(usize, struct {
    scope: []const u8,
    value: []const u8,
}).init(Zune.DEFAULT_ALLOCATOR);

fn freeRefTrace(allocator: std.mem.Allocator, index: usize) void {
    if (REF_LEAKED_SOURCE.get(index)) |source| {
        allocator.free(source.scope);
        allocator.free(source.value);
        _ = REF_LEAKED_SOURCE.remove(index);
    }
}

fn stepCheckLeakedReferences(L: *VM.lua.State) void {
    const allocator = luau.getallocator(L);

    L.pushvalue(VM.lua.REGISTRYINDEX);

    const references: usize = @intCast(L.objlen(-1));

    for (1..references) |index| {
        const store_index = index - 1;
        defer L.pop(1);
        if (L.rawgeti(-1, @intCast(index)) == .Number) {
            freeRefTrace(allocator, store_index);
            continue;
        }
    }
}

fn testing_checkLeakedReferences(L: *VM.lua.State) !i32 {
    const scope = L.Lcheckstring(1);
    const allocator = luau.getallocator(L);

    L.pushvalue(VM.lua.REGISTRYINDEX);

    const references: usize = @intCast(L.objlen(-1));

    for (1..references) |index| {
        const store_index = index - 1;
        defer L.pop(1);
        if (L.rawgeti(-1, @intCast(index)) == .Number) {
            freeRefTrace(allocator, store_index);
            continue;
        }

        if (REF_LEAKED_SOURCE.get(store_index) != null)
            continue;

        const scope_copy = try allocator.dupe(u8, scope);

        var buf = std.ArrayList(u8).init(allocator);
        try formatter.fmt_write_idx(allocator, L, buf.writer(), -1, formatter.MAX_DEPTH);

        try REF_LEAKED_SOURCE.put(store_index, .{ .scope = scope_copy, .value = try buf.toOwnedSlice() });
    }
    return 0;
}

fn testing_droptasks(L: *VM.lua.State) i32 {
    const scheduler = Scheduler.getScheduler(L);

    var awaitsSize = scheduler.awaits.items.len;
    while (awaitsSize > 0) {
        awaitsSize -= 1;
        const awaiting = scheduler.awaits.items[awaitsSize];
        if (awaiting.priority == .Internal)
            continue;
        _ = scheduler.awaits.orderedRemove(awaitsSize);
        awaiting.virtualDtor(awaiting.data, awaiting.state.value, scheduler);
    }

    var tasksSize = scheduler.tasks.items.len;
    while (tasksSize > 0) {
        tasksSize -= 1;
        const task = scheduler.tasks.swapRemove(tasksSize);
        task.virtualDtor(task.data, task.state.value, scheduler);
    }

    var sleepingSize = scheduler.sleeping.items.len;
    while (sleepingSize > 0) {
        sleepingSize -= 1;
        const slept = scheduler.sleeping.remove();
        slept.thread.deref();
    }

    while (scheduler.deferred.pop()) |node| {
        const deferred = node.data;
        defer scheduler.allocator.destroy(node);
        deferred.thread.deref();
    }

    return 0;
}

fn testing_declareSafeEnv(L: *VM.lua.State) i32 {
    L.setsafeenv(VM.lua.GLOBALSINDEX, true);
    return 0;
}

fn empty(L: *VM.lua.State) i32 {
    _ = L;
    return 0;
}

pub const TestResult = struct {
    failed: i32,
    total: i32,
};

pub fn finish_testing(L: *VM.lua.State, rawstart: f64) TestResult {
    const allocator = luau.getallocator(L);
    const end = VM.lperf.clock();

    _ = L.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
    if (L.getfield(-1, LIB_NAME) != .Table)
        std.debug.panic("No test framework loaded", .{});

    const stdOut = if (L.getfield(VM.lua.GLOBALSINDEX, "_testing_stdOut") == .Boolean)
        L.toboolean(-1)
    else
        true;
    L.pop(1);

    const start = if (L.getfield(-1, "_start") == .Number)
        L.tonumber(-1) orelse rawstart
    else
        rawstart;
    L.pop(1);

    const time = end - start;
    const mainTestCount = if (L.getfield(-1, "_count") == .Number)
        L.tointeger(-1) orelse unreachable
    else
        0;
    L.pop(1);
    const mainFailedCount = if (L.getfield(-1, "_failed") == .Number)
        L.tointeger(-1) orelse unreachable
    else
        0;
    L.pop(1);

    stepCheckLeakedReferences(L);

    var header = false;
    if (REF_LEAKED_SOURCE.count() > 0) {
        var iter = REF_LEAKED_SOURCE.iterator();
        while (iter.next()) |entry| {
            const idx = entry.key_ptr.*;
            const source = entry.value_ptr.*;
            const refIdx = idx + 1;
            if (!header) {
                header = true;
                std.debug.print("\n", .{});
                std.debug.print("\x1b[1;34mLEAK\x1b[0m Runtime leaked references (Information may not be accurate)\x1b[0m", .{});
            }
            std.debug.print("\n {s}\x1b[0m", .{source.scope});
            std.debug.print("\n  \x1b[96m{}\x1b[0m \x1b[2m-\x1b[0m {s}", .{ refIdx, source.value });

            freeRefTrace(allocator, idx);
        }
    }
    if (header)
        std.debug.print("\n", .{});

    if (stdOut) {
        std.debug.print("\n", .{});
        if (mainFailedCount > 0) {
            std.debug.print(" \x1b[1mTests\x1b[0m: \x1b[1;31m{} failed\x1b[0m, {} total\n", .{ mainFailedCount, mainTestCount });
        } else {
            std.debug.print(" \x1b[1mTests\x1b[0m: {} total\n", .{mainTestCount});
        }
        std.debug.print(" \x1b[1mTime\x1b[0m:  {d} s\n", .{std.math.ceil(time * 1000) / 1000});
    }
    return .{
        .failed = mainFailedCount,
        .total = mainTestCount,
    };
}

pub fn runTestAsync(L: *VM.lua.State, sched: *Scheduler) !TestResult {
    const start = VM.lperf.clock();

    try Engine.runAsync(L, sched, .{
        .cleanUp = true,
        .mode = .Test,
    });

    return finish_testing(L, start);
}

pub fn loadLib(L: *VM.lua.State, enabled: bool) void {
    const allocator = luau.getallocator(L);
    if (enabled) {
        const GL = L.mainthread();
        const ML = GL.newthread();
        GL.xmove(L, 1);
        ML.Lsandboxthread();

        if (L.getfield(VM.lua.GLOBALSINDEX, "_testing_stdOut") == .Boolean and !L.toboolean(-1)) {
            ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "print", empty);
        } else ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "print", testing_debug);
        L.pop(1);
        ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "declare_safeEnv", testing_declareSafeEnv);
        ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "stepcheck_references", testing_checkLeakedReferences);
        ML.Zsetfieldfn(VM.lua.GLOBALSINDEX, "scheduler_droptasks", testing_droptasks);
        ML.Zsetfield(VM.lua.GLOBALSINDEX, "_FILE", false);

        const bytecode_buf = allocator.alloc(u8, test_lib_size) catch |err| std.debug.panic("Unable to allocate space for testing framework: {}", .{err});
        defer allocator.free(bytecode_buf);
        var bytecode_buf_stream = std.io.fixedBufferStream(bytecode_buf);
        var bytecode_gz_buf_stream = std.io.fixedBufferStream(test_lib_gz);

        std.compress.gzip.decompress(bytecode_gz_buf_stream.reader(), bytecode_buf_stream.writer()) catch |err| std.debug.panic("Failed to decompress testing framework: {}", .{err});

        ML.load("test_framework", bytecode_buf, 0) catch |err|
            std.debug.panic("Error loading test framework: {}\n", .{err});
        _ = ML.pcall(0, 1, 0).check() catch |err| {
            std.debug.print("Error loading test framework (2): {}\n", .{err});
            Engine.logError(ML, err, false);
            std.debug.panic("Test Framework (2)\n", .{});
        };
        ML.xmove(L, 1);

        L.remove(-2);
    } else {
        L.createtable(0, 4);
        L.Zsetfield(-1, "running", false);
        L.Zsetfieldfn(-1, "describe", empty);
        L.Zsetfieldfn(-1, "test", empty);
        L.Zsetfieldfn(-1, "expect", empty);
        L.setreadonly(-1, true);
    }

    luaHelper.registerModule(L, LIB_NAME);
}

test "Test" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/testing.test.luau"),
        &.{},
        false,
    );

    try std.testing.expect(testResult.failed == 3);
    try std.testing.expect(testResult.total == 11);
}
