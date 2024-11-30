const std = @import("std");
const luau = @import("luau");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");

const Luau = luau.Luau;

pub const LIB_NAME = "task";

fn task_wait(L: *Luau, scheduler: *Scheduler) i32 {
    const time = L.optNumber(1) orelse 0;
    scheduler.sleepThread(L, time, 0, true);
    return L.yield(0);
}

fn task_cancel(L: *Luau, scheduler: *Scheduler) !i32 {
    L.checkType(1, .thread);
    const thread = L.toThread(1) catch return L.Error("Expected thread");
    scheduler.cancelThread(thread);
    const status = L.statusThread(thread);
    if (status != .finished and status != .err and status != .suspended)
        return L.ErrorFmt("Cannot close {s} coroutine", .{@tagName(status)});
    thread.resetThread();
    return 0;
}

fn task_spawn(L: *Luau, scheduler: *Scheduler) !i32 {
    const fnType = L.typeOf(1);
    if (fnType != luau.LuaType.function and fnType != luau.LuaType.thread)
        return L.Error("Expected function or thread");

    const top = L.getTop();
    const args = top - 1;

    const thread = th: {
        if (fnType == luau.LuaType.function) {
            const TL = L.newThread();
            L.xPush(TL, 1);
            break :th TL;
        } else {
            L.pushValue(1);
            break :th L.toThread(-1) catch return L.Error("thread failed");
        }
    };

    for (0..@intCast(args)) |i| L.pushValue(@intCast(i + 2));
    L.xMove(thread, args);

    scheduler.spawnThread(thread, args);

    return 1;
}

fn task_defer(L: *Luau, scheduler: *Scheduler) !i32 {
    const fnType = L.typeOf(1);
    if (fnType != luau.LuaType.function and fnType != luau.LuaType.thread)
        return L.Error("Expected function or thread");

    const top = L.getTop();
    const args = top - 1;

    const thread = th: {
        if (fnType == luau.LuaType.function) {
            const TL = L.newThread();
            L.xPush(TL, 1);
            break :th TL;
        } else {
            L.pushValue(1);
            break :th L.toThread(-1) catch return L.Error("thread failed");
        }
    };

    for (0..@intCast(args)) |i| L.pushValue(@intCast(i + 2));
    L.xMove(thread, args);

    scheduler.deferThread(thread, L, args);

    return 1;
}

fn task_delay(L: *Luau, scheduler: *Scheduler) !i32 {
    const time = L.checkNumber(1);
    const fnType = L.typeOf(2);
    if (fnType != luau.LuaType.function and fnType != luau.LuaType.thread)
        return L.Error("Expected function or thread");

    const top = L.getTop();
    const args = top - 2;

    const thread = th: {
        if (fnType == luau.LuaType.function) {
            const TL = L.newThread();
            L.xPush(TL, 2);
            break :th TL;
        } else {
            L.pushValue(2);
            break :th L.toThread(-1) catch return L.Error("thread failed");
        }
    };

    for (0..@intCast(args)) |i| L.pushValue(@intCast(i + 3));
    L.xMove(thread, args);

    scheduler.sleepThread(thread, time, args, false);

    return 1;
}

fn task_count(L: *Luau, scheduler: *Scheduler) !i32 {
    const kind = L.optString(1) orelse {
        var total: usize = 0;
        total += scheduler.sleeping.items.len;
        total += scheduler.deferred.items.len;
        for (scheduler.awaits.items) |item| {
            if (item.priority == .User)
                total += 1;
        }
        total += scheduler.tasks.items.len;
        L.pushNumber(@floatFromInt(total));
        return 1;
    };

    var out: i32 = 0;

    for (kind) |c| {
        if (out > 4)
            return L.Error("Too many kinds");
        switch (c) {
            's' => {
                out += 1;
                L.pushNumber(@floatFromInt(scheduler.sleeping.items.len));
            },
            'd' => {
                out += 1;
                L.pushNumber(@floatFromInt(scheduler.deferred.items.len));
            },
            'w' => {
                out += 1;
                var count: usize = 0;
                for (scheduler.awaits.items) |item| {
                    if (item.priority == .User)
                        count += 1;
                }
                L.pushNumber(@floatFromInt(count));
            },
            't' => {
                out += 1;
                L.pushNumber(@floatFromInt(scheduler.tasks.items.len));
            },
            else => return L.Error("Invalid kind"),
        }
    }

    return out;
}

pub fn loadLib(L: *Luau) void {
    L.newTable();

    L.setFieldFn(-1, "wait", Scheduler.toSchedulerFn(task_wait));
    L.setFieldFn(-1, "spawn", Scheduler.toSchedulerEFn(task_spawn));
    L.setFieldFn(-1, "defer", Scheduler.toSchedulerEFn(task_defer));
    L.setFieldFn(-1, "delay", Scheduler.toSchedulerEFn(task_delay));
    L.setFieldFn(-1, "cancel", Scheduler.toSchedulerEFn(task_cancel));
    L.setFieldFn(-1, "count", Scheduler.toSchedulerEFn(task_count));

    L.setReadOnly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
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
