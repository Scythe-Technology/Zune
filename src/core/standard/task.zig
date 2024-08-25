const std = @import("std");
const luau = @import("luau");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const Luau = luau.Luau;

fn task_wait(L: *Luau, scheduler: *Scheduler) i32 {
    const time = L.optNumber(1) orelse 0;
    scheduler.sleepThread(L, time, 0, true);
    return L.yield(1);
}

fn task_cancel(L: *Luau, scheduler: *Scheduler) i32 {
    L.checkType(1, .thread);
    const thread = L.toThread(1) catch L.raiseErrorStr("Expected thread", .{});
    scheduler.cancelThread(thread);
    const status = L.statusThread(thread);
    if (status != .finished and status != .err and status != .suspended) L.raiseErrorStr("Cannot close %s coroutine", .{@tagName(status).ptr});
    thread.resetThread();
    return 0;
}

fn task_spawn(L: *Luau, scheduler: *Scheduler) i32 {
    const fnType = L.typeOf(1);
    if (fnType != luau.LuaType.function and fnType != luau.LuaType.thread) L.raiseErrorStr("Expected function or thread", .{});

    const top = L.getTop();
    const args = top - 1;

    const thread = th: {
        if (fnType == luau.LuaType.function) {
            const TL = L.newThread();
            L.xPush(TL, 1);
            break :th TL;
        } else {
            L.pushValue(1);
            break :th L.toThread(-1) catch L.raiseErrorStr("thread failed", .{});
        }
    };

    for (0..@intCast(args)) |i| L.pushValue(@intCast(i + 2));
    L.xMove(thread, args);

    scheduler.spawnThread(thread, args) catch |err| {
        Engine.logError(thread, err);
        return 1;
    };

    return 1;
}

fn task_defer(L: *Luau, scheduler: *Scheduler) i32 {
    const fnType = L.typeOf(1);
    if (fnType != luau.LuaType.function and fnType != luau.LuaType.thread) L.raiseErrorStr("Expected function or thread", .{});

    const top = L.getTop();
    const args = top - 1;

    const thread = th: {
        if (fnType == luau.LuaType.function) {
            const TL = L.newThread();
            L.xPush(TL, 1);
            break :th TL;
        } else {
            L.pushValue(1);
            break :th L.toThread(-1) catch L.raiseErrorStr("thread failed", .{});
        }
    };

    for (0..@intCast(args)) |i| L.pushValue(@intCast(i + 2));
    L.xMove(thread, args);

    scheduler.deferThread(thread, L, args);

    return 1;
}

fn task_delay(L: *Luau, scheduler: *Scheduler) i32 {
    const time = L.checkNumber(1);
    const fnType = L.typeOf(2);
    if (fnType != luau.LuaType.function and fnType != luau.LuaType.thread) L.raiseErrorStr("Expected function or thread", .{});

    const top = L.getTop();
    const args = top - 2;

    const thread = th: {
        if (fnType == luau.LuaType.function) {
            const TL = L.newThread();
            L.xPush(TL, 2);
            break :th TL;
        } else {
            L.pushValue(2);
            break :th L.toThread(-1) catch L.raiseErrorStr("thread failed", .{});
        }
    };

    for (0..@intCast(args)) |i| L.pushValue(@intCast(i + 3));
    L.xMove(thread, args);

    scheduler.sleepThread(thread, time, args, false);

    return 1;
}

fn task_count(L: *Luau, scheduler: *Scheduler) i32 {
    const kind = L.optString(1) orelse {
        var total: usize = 0;
        total += scheduler.sleeping.items.len;
        total += scheduler.deferred.items.len;
        total += scheduler.awaits.items.len;
        total += scheduler.tasks.items.len;
        L.pushInteger(@intCast(total));
        return 1;
    };

    var out: i32 = 0;

    for (kind) |c| {
        if (out > 4) L.raiseErrorStr("Too many kinds", .{});
        switch (c) {
            's' => {
                out += 1;
                L.pushInteger(@intCast(scheduler.sleeping.items.len));
            },
            'd' => {
                out += 1;
                L.pushInteger(@intCast(scheduler.deferred.items.len));
            },
            'w' => {
                out += 1;
                L.pushInteger(@intCast(scheduler.awaits.items.len));
            },
            't' => {
                out += 1;
                L.pushInteger(@intCast(scheduler.tasks.items.len));
            },
            else => L.raiseErrorStr("Invalid kind", .{}),
        }
    }

    return out;
}

pub fn loadLib(L: *Luau) void {
    L.newTable();

    L.setFieldFn(-1, "wait", Scheduler.toSchedulerFn(task_wait));
    L.setFieldFn(-1, "spawn", Scheduler.toSchedulerFn(task_spawn));
    L.setFieldFn(-1, "defer", Scheduler.toSchedulerFn(task_defer));
    L.setFieldFn(-1, "delay", Scheduler.toSchedulerFn(task_delay));
    L.setFieldFn(-1, "cancel", Scheduler.toSchedulerFn(task_cancel));
    L.setFieldFn(-1, "count", Scheduler.toSchedulerFn(task_count));

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, "@zcore/task") != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, "@zcore/task");
    } else L.pop(1);
    L.pop(2);
}

const TestResult = struct {
    failed: i32,
    total: i32,
};

test "Task" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"task.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
