const std = @import("std");
const luau = @import("luau");

const Zune = @import("../../zune.zig");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const Formatter = @import("../resolvers/fmt.zig");

const luaHelper = @import("../utils/luahelper.zig");

const test_lib_gz = @embedFile("../lua/testing_lib.luac.gz");
const test_lib_size = @embedFile("../lua/testing_lib.luac").len;

const Luau = luau.Luau;

pub const LIB_NAME = "testing";

fn testing_debug(L: *Luau) i32 {
    const str = L.checkString(1);
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

fn stepCheckLeakedReferences(L: *Luau) void {
    const allocator = L.allocator();

    L.pushValue(luau.REGISTRYINDEX);

    const references: usize = @intCast(L.objLen(-1));

    for (1..references) |index| {
        const store_index = index - 1;
        defer L.pop(1);
        if (L.rawGetIndex(-1, @intCast(index)) == .number) {
            freeRefTrace(allocator, store_index);
            continue;
        }
    }
}

fn testing_checkLeakedReferences(L: *Luau) !i32 {
    const scope = L.checkString(1);
    const allocator = L.allocator();

    L.pushValue(luau.REGISTRYINDEX);

    const references: usize = @intCast(L.objLen(-1));

    for (1..references) |index| {
        const store_index = index - 1;
        defer L.pop(1);
        if (L.rawGetIndex(-1, @intCast(index)) == .number) {
            freeRefTrace(allocator, store_index);
            continue;
        }

        if (REF_LEAKED_SOURCE.get(store_index) != null)
            continue;

        const scope_copy = try allocator.dupe(u8, scope);

        var buf = std.ArrayList(u8).init(allocator);
        try Formatter.fmt_write_idx(allocator, L, buf.writer(), -1);

        try REF_LEAKED_SOURCE.put(store_index, .{ .scope = scope_copy, .value = try buf.toOwnedSlice() });
    }
    return 0;
}

fn testing_droptasks(L: *Luau, scheduler: *Scheduler) i32 {
    _ = L;

    var awaitsSize = scheduler.awaits.items.len;
    while (awaitsSize > 0) {
        awaitsSize -= 1;
        const awaiting = scheduler.awaits.items[awaitsSize];
        if (awaiting.priority == .Internal)
            continue;
        _ = scheduler.awaits.orderedRemove(awaitsSize);
        awaiting.virtualDtor(awaiting.data, Scheduler.stateFromPair(awaiting.state), scheduler);
    }

    var tasksSize = scheduler.tasks.items.len;
    while (tasksSize > 0) {
        tasksSize -= 1;
        const task = scheduler.tasks.swapRemove(tasksSize);
        task.virtualDtor(task.data, Scheduler.stateFromPair(task.state), scheduler);
    }

    var sleepingSize = scheduler.sleeping.items.len;
    while (sleepingSize > 0) {
        sleepingSize -= 1;
        const slept = scheduler.sleeping.remove();
        Scheduler.derefThread(slept.thread);
    }

    var deferredSize = scheduler.deferred.items.len;
    while (deferredSize > 0) {
        deferredSize -= 1;
        const deferred = scheduler.deferred.swapRemove(deferredSize);
        Scheduler.derefThread(deferred.thread);
    }

    return 0;
}

fn testing_declareSafeEnv(L: *Luau) i32 {
    L.setSafeEnv(luau.GLOBALSINDEX, true);
    return 0;
}

fn empty(L: *Luau) i32 {
    _ = L;
    return 0;
}

pub const TestResult = struct {
    failed: i32,
    total: i32,
};

pub fn finish_testing(L: *Luau, rawstart: f64) TestResult {
    const allocator = L.allocator();
    const end = luau.clock();

    _ = L.findTable(luau.REGISTRYINDEX, "_LIBS", 1);
    if (L.getField(-1, LIB_NAME) != .table)
        std.debug.panic("No test framework loaded", .{});

    const stdOut = if (L.getField(luau.GLOBALSINDEX, "_testing_stdOut") == .boolean)
        L.toBoolean(-1)
    else
        true;
    L.pop(1);

    const start = if (L.getField(-1, "_start") == .number)
        L.toNumber(-1) catch rawstart
    else
        rawstart;
    L.pop(1);

    const time = end - start;
    const mainTestCount = if (L.getField(-1, "_count") == .number)
        L.toInteger(-1) catch unreachable
    else
        0;
    L.pop(1);
    const mainFailedCount = if (L.getField(-1, "_failed") == .number)
        L.toInteger(-1) catch unreachable
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

pub fn runTestAsync(L: *Luau, sched: *Scheduler) !TestResult {
    const start = luau.clock();

    try Engine.runAsync(L, sched, .{
        .cleanUp = true,
        .testing = true,
    });

    return finish_testing(L, start);
}

pub fn loadLib(L: *Luau, enabled: bool) void {
    const allocator = L.allocator();
    if (enabled) {
        const GL = L.getMainThread();
        const ML = GL.newThread();
        GL.xMove(L, 1);
        ML.sandboxThread();

        if (L.getField(luau.GLOBALSINDEX, "_testing_stdOut") == .boolean and !L.toBoolean(-1)) {
            ML.setFieldFn(luau.GLOBALSINDEX, "print", empty);
        } else ML.setFieldFn(luau.GLOBALSINDEX, "print", testing_debug);
        L.pop(1);
        ML.setFieldFn(luau.GLOBALSINDEX, "declare_safeEnv", testing_declareSafeEnv);
        ML.setFieldFn(luau.GLOBALSINDEX, "stepcheck_references", testing_checkLeakedReferences);
        ML.setFieldFn(luau.GLOBALSINDEX, "scheduler_droptasks", Scheduler.toSchedulerFn(testing_droptasks));
        ML.setFieldBoolean(luau.GLOBALSINDEX, "_FILE", false);

        const bytecode_buf = allocator.alloc(u8, test_lib_size) catch |err| std.debug.panic("Unable to allocate space for testing framework: {}", .{err});
        defer allocator.free(bytecode_buf);
        var bytecode_buf_stream = std.io.fixedBufferStream(bytecode_buf);
        var bytecode_gz_buf_stream = std.io.fixedBufferStream(test_lib_gz);

        std.compress.gzip.decompress(bytecode_gz_buf_stream.reader(), bytecode_buf_stream.writer()) catch |err| std.debug.panic("Failed to decompress testing framework: {}", .{err});

        ML.loadBytecode("test_framework", bytecode_buf) catch |err|
            std.debug.panic("Error loading test framework: {}\n", .{err});
        ML.pcall(0, 1, 0) catch |err| {
            std.debug.print("Error loading test framework (2): {}\n", .{err});
            Engine.logError(ML, err, false);
            std.debug.panic("Test Framework (2)\n", .{});
        };
        ML.xMove(L, 1);

        L.remove(-2);
    } else {
        L.newTable();
        L.setFieldBoolean(-1, "running", false);
        L.setFieldFn(-1, "describe", empty);
        L.setFieldFn(-1, "test", empty);
        L.setFieldFn(-1, "expect", empty);
        L.setReadOnly(-1, true);
    }

    luaHelper.registerModule(L, LIB_NAME);
}

test "Test" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"testing.test", &.{}, false);

    try std.testing.expect(testResult.failed == 3);
    try std.testing.expect(testResult.total == 11);
}
