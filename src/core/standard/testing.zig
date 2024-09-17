const std = @import("std");
const luau = @import("luau");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const test_lib_gz = @embedFile("../lua/testing_lib.luac.gz");
const test_lib_size = @embedFile("../lua/testing_lib.luac").len;

const Luau = luau.Luau;

pub const LIB_NAME = "@zcore/testing";

fn testing_debug(L: *Luau) i32 {
    const str = L.checkString(1);
    std.debug.print("{s}\n", .{str});
    return 0;
}

fn testing_droptasks(L: *Luau, scheduler: *Scheduler) i32 {
    _ = L;

    var awaitsSize = scheduler.awaits.items.len;
    while (awaitsSize > 0) {
        awaitsSize -= 1;
        _ = scheduler.awaits.swapRemove(awaitsSize);
    }

    var tasksSize = scheduler.tasks.items.len;
    while (tasksSize > 0) {
        tasksSize -= 1;
        const task = scheduler.tasks.swapRemove(tasksSize);
        task.virtualDtor(task.data, task.state, scheduler);
    }

    var sleepingSize = scheduler.sleeping.items.len;
    while (sleepingSize > 0) {
        sleepingSize -= 1;
        _ = scheduler.sleeping.swapRemove(sleepingSize);
    }

    var deferredSize = scheduler.deferred.items.len;
    while (deferredSize > 0) {
        deferredSize -= 1;
        _ = scheduler.deferred.swapRemove(deferredSize);
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
        ML.setFieldFn(luau.GLOBALSINDEX, "scheduler_droptasks", Scheduler.toSchedulerFn(testing_droptasks));
        ML.setFieldBoolean(luau.GLOBALSINDEX, "_FILE", false);

        const bytecode_buf = allocator.alloc(u8, test_lib_size) catch |err| std.debug.panic("Unable to allocate space for testing framework: {}", .{err});
        defer allocator.free(bytecode_buf);
        var bytecode_buf_stream = std.io.fixedBufferStream(bytecode_buf);
        var bytecode_gz_buf_stream = std.io.fixedBufferStream(test_lib_gz);

        std.compress.gzip.decompress(bytecode_gz_buf_stream.reader(), bytecode_buf_stream.writer()) catch |err| std.debug.panic("Failed to decompress testing framework: {}", .{err});

        ML.loadBytecode("test_framework", bytecode_buf) catch |err| std.debug.panic("Error loading test framework: {}\n", .{err});
        ML.pcall(0, 1, 0) catch |err| {
            std.debug.print("Error loading test framework (2): {}\n", .{err});
            Engine.logError(ML, err);
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
    }

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, LIB_NAME) != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, LIB_NAME);
    } else L.pop(1);
    L.pop(2);
}

pub const TestResult = struct {
    failed: i32,
    total: i32,
};

pub fn finish_testing(L: *Luau, rawstart: f64) TestResult {
    const end = luau.clock();

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, "@zcore/testing") != .table) std.debug.panic("No test framework loaded", .{});

    const stdOut = if (L.getField(luau.GLOBALSINDEX, "_testing_stdOut") == .boolean) L.toBoolean(-1) else true;
    L.pop(1);

    const start = if (L.getField(luau.REGISTRYINDEX, "_START") == .number) L.toNumber(-1) catch rawstart else rawstart;
    const time = end - start;
    L.pop(1);
    const mainTestCount = if (L.getField(-1, "_COUNT") == .number) L.toInteger(-1) catch 0 else 0;
    L.pop(1);
    const mainFailedCount = if (L.getField(-1, "_FAILED") == .number) L.toInteger(-1) catch 0 else 0;
    L.pop(1);

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

    try Engine.runAsync(L, sched);

    return finish_testing(L, start);
}

test "Test" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"testing.test", &.{}, false);

    try std.testing.expect(testResult.failed == 3);
    try std.testing.expect(testResult.total == 11);
}
