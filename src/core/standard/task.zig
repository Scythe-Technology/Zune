const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;

const LuaHelper = Zune.Utils.LuaHelper;

const VM = luau.VM;

pub const LIB_NAME = "task";

fn lua_wait(L: *VM.lua.State) i32 {
    const scheduler = Scheduler.getScheduler(L);
    const time = L.tonumber(1) orelse 0;
    scheduler.sleepThread(L, null, time, 0, true);
    return L.yield(0);
}

fn lua_cancel(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    try L.Zchecktype(1, .Thread);
    const thread = L.tothread(1) orelse return L.Zerror("Expected thread");
    scheduler.cancelThread(thread);
    const status = L.costatus(thread);
    if (status != .Finished and status != .FinishedErr and status != .Suspended)
        return L.Zerrorf("Cannot close {s} coroutine", .{@tagName(status)});
    thread.resetthread();
    return 0;
}

fn lua_spawn(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    const fnType = L.typeOf(1);
    if (fnType != .Function and fnType != .Thread)
        return L.Zerror("Expected function or thread");

    const top = L.gettop();
    const args = top - 1;

    const thread = th: {
        if (fnType == .Function) {
            const TL = L.newthread();
            L.xpush(TL, 1);
            break :th TL;
        } else {
            L.pushvalue(1);
            break :th L.tothread(1) orelse return L.Zerror("thread failed");
        }
    };

    if (args > 0) {
        for (0..@intCast(args)) |i|
            L.xpush(thread, @intCast(i + 2));
    }

    scheduler.spawnThread(thread, L, @intCast(args));

    return 1;
}

fn lua_defer(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    const fnType = L.typeOf(1);
    if (fnType != .Function and fnType != .Thread)
        return L.Zerror("Expected function or thread");

    const top = L.gettop();
    const args = top - 1;

    const thread = th: {
        if (fnType == .Function) {
            const TL = L.newthread();
            L.xpush(TL, 1);
            break :th TL;
        } else {
            L.pushvalue(1);
            break :th L.tothread(1) orelse return L.Zerror("thread failed");
        }
    };

    if (args > 0) {
        for (0..@intCast(args)) |i|
            L.xpush(thread, @intCast(i + 2));
    }

    scheduler.deferThread(thread, L, @intCast(args));

    return 1;
}

fn lua_delay(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    const time = L.Lchecknumber(1);
    const fnType = L.typeOf(2);
    if (fnType != .Function and fnType != .Thread)
        return L.Zerror("Expected function or thread");

    const top = L.gettop();
    const args = top - 2;

    const thread = th: {
        if (fnType == .Function) {
            const TL = L.newthread();
            L.xpush(TL, 2);
            break :th TL;
        } else {
            L.pushvalue(2);
            break :th L.tothread(2) orelse return L.Zerror("thread failed");
        }
    };

    if (args > 0) {
        for (0..@intCast(args)) |i|
            L.xpush(thread, @intCast(i + 3));
    }

    scheduler.sleepThread(thread, L, time, @intCast(args), false);

    return 1;
}

fn lua_count(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    const kind = L.tolstring(1) orelse {
        var total: usize = 0;
        total += scheduler.sleeping.items.len;
        total += scheduler.deferred.len;
        for (scheduler.awaits.items) |item| {
            if (item.priority == .User)
                total += 1;
        }
        total += scheduler.tasks.items.len;
        total += scheduler.async_tasks;
        L.pushnumber(@floatFromInt(total));
        return 1;
    };

    var out: i32 = 0;

    for (kind) |c| {
        if (out > 4)
            return L.Zerror("Too many kinds");
        switch (c) {
            's' => {
                out += 1;
                L.pushnumber(@floatFromInt(scheduler.sleeping.items.len));
            },
            'd' => {
                out += 1;
                L.pushnumber(@floatFromInt(scheduler.deferred.len));
            },
            'w' => {
                out += 1;
                var count: usize = 0;
                for (scheduler.awaits.items) |item| {
                    if (item.priority == .User)
                        count += 1;
                }
                L.pushnumber(@floatFromInt(count));
            },
            't' => {
                out += 1;
                L.pushnumber(@floatFromInt(scheduler.tasks.items.len + scheduler.async_tasks));
            },
            else => return L.Zerror("Invalid kind"),
        }
    }

    return out;
}

pub fn loadLib(L: *VM.lua.State) void {
    L.Zpushvalue(.{
        .wait = lua_wait,
        .spawn = lua_spawn,
        .@"defer" = lua_defer,
        .delay = lua_delay,
        .cancel = lua_cancel,
        .count = lua_count,
    });
    L.setreadonly(-1, true);

    LuaHelper.registerModule(L, LIB_NAME);
}

const TestResult = struct {
    failed: i32,
    total: i32,
};

test "task" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/task.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
