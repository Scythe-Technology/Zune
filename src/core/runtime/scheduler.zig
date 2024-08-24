const std = @import("std");
const luau = @import("luau");

const Engine = @import("engine.zig");
const Zune = @import("../../zune.zig");

const Luau = luau.Luau;

pub var SCHEDULERS = std.ArrayList(*Self).init(Zune.DEFAULT_ALLOCATOR);

pub fn KillScheduler(scheduler: *Self, cleanUp: bool) void {
    var i = scheduler.tasks.items.len;
    while (i > 0) {
        i -= 1;
        const task = scheduler.tasks.items[i];
        task.virtualDtor(task.data, task.state, scheduler);
        _ = scheduler.tasks.orderedRemove(i);
    }
    if (cleanUp) for (SCHEDULERS.items, 0..) |o, p| if (scheduler == o) {
        _ = SCHEDULERS.orderedRemove(p);
        break;
    };
}

pub fn KillSchedulers() void {
    for (SCHEDULERS.items) |scheduler| KillScheduler(scheduler, false);
    SCHEDULERS.deinit();
}

const SleepingThread = struct {
    thread: *Luau,
    wake: f64,
    start: f64,
    args: i32,
    waited: bool,
};

const DeferredThread = struct {
    from: ?*Luau,
    thread: *Luau,
    args: i32,
};

const Self = @This();

pub const TaskResult = enum {
    Continue,
    Stop,
};

const TaskFn = fn (ctx: *anyopaque, L: *Luau, scheduler: *Self) TaskResult;
const TaskFnDtor = fn (ctx: *anyopaque, L: *Luau, scheduler: *Self) void;
const AwaitedFn = TaskFnDtor; // Similar to TaskFnDtor

pub fn TaskObject(comptime T: type) type {
    return struct {
        data: *T,
        state: *Luau,
        virtualFn: *const TaskFn,
        virtualDtor: *const TaskFnDtor,
    };
}

pub fn AwaitingObject(comptime T: type) type {
    return struct {
        data: *T,
        state: *Luau,
        resumeFn: *const AwaitedFn,
    };
}

allocator: std.mem.Allocator,
sleeping: std.ArrayList(SleepingThread),
deferred: std.ArrayList(DeferredThread),
tasks: std.ArrayList(TaskObject(anyopaque)),
awaits: std.ArrayList(AwaitingObject(anyopaque)),

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .sleeping = std.ArrayList(SleepingThread).init(allocator),
        .deferred = std.ArrayList(DeferredThread).init(allocator),
        .tasks = std.ArrayList(TaskObject(anyopaque)).init(allocator),
        .awaits = std.ArrayList(AwaitingObject(anyopaque)).init(allocator),
    };
}

pub fn spawnThread(self: *Self, thread: *Luau, args: i32) !void {
    _ = self;
    _ = try thread.resumeThread(null, args);
}

pub fn deferThread(self: *Self, thread: *Luau, from: ?*Luau, args: i32) void {
    self.deferred.insert(0, .{ .from = from, .thread = thread, .args = args }) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        unreachable;
    };
}

pub fn sleepThread(self: *Self, thread: *Luau, time: f64, args: i32, waited: bool) void {
    const start = luau.clock();
    const wake = start + time;
    self.sleeping.insert(0, .{ .thread = thread, .start = start, .wake = wake, .args = args, .waited = waited }) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        unreachable;
    };
}

pub fn addTask(self: *Self, comptime T: type, data: *T, L: *Luau, comptime handler: *const fn (ctx: *T, L: *Luau, scheduler: *Self) TaskResult, comptime destructor: *const fn (ctx: *T, L: *Luau, scheduler: *Self) void) void {
    const virtualFn = struct {
        fn inner(ctx: *anyopaque, l: *Luau, scheduler: *Self) TaskResult {
            return @call(.always_inline, handler, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
        }
    }.inner;
    const virtualDtor = struct {
        fn inner(ctx: *anyopaque, l: *Luau, scheduler: *Self) void {
            return @call(.always_inline, destructor, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
        }
    }.inner;
    self.tasks.append(.{
        .data = @ptrCast(data),
        .state = L,
        .virtualFn = virtualFn,
        .virtualDtor = virtualDtor,
    }) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        unreachable;
    };
}

pub fn awaitCall(self: *Self, comptime T: type, data: *T, L: *Luau, args: i32, comptime handler: *const fn (ctx: *T, L: *Luau, scheduler: *Self) void, from: ?*Luau) !void {
    const status = try L.resumeThread(from, args);
    if (status != .yield) {
        handler(data, L, self);
        return;
    }

    const resumeFn = struct {
        fn inner(ctx: *anyopaque, l: *Luau, scheduler: *Self) void {
            @call(.always_inline, handler, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
        }
    }.inner;

    self.awaits.append(.{
        .data = @ptrCast(data),
        .state = L,
        .resumeFn = resumeFn,
    }) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        unreachable;
    };
}

pub fn resumeState(state: *Luau, from: ?*Luau, args: i32) void {
    _ = state.resumeThread(from, args) catch |err| {
        Engine.logError(state, err);
        return;
    };
}

pub fn cancelThread(self: *Self, thread: *Luau) void {
    const sleeping_items = self.sleeping.items;
    for (sleeping_items, 0..) |item, i| {
        if (item.thread == thread) {
            _ = self.sleeping.orderedRemove(i);
            return;
        }
    }
    const deferred_items = self.deferred.items;
    for (deferred_items, 0..) |item, i| {
        if (item.thread == thread) {
            _ = self.deferred.orderedRemove(i);
            return;
        }
    }
}

pub fn run(self: *Self) void {
    while ((self.sleeping.items.len > 0 or self.deferred.items.len > 0 or self.tasks.items.len > 0 or self.awaits.items.len > 0)) {
        const now = luau.clock();
        {
            var i = self.awaits.items.len;
            while (i > 0) {
                i -= 1;
                const awaiting = self.awaits.items[i];
                if (awaiting.state.status() != .yield) {
                    _ = self.awaits.orderedRemove(i);
                    awaiting.resumeFn(awaiting.data, awaiting.state, self);
                }
            }
        }
        {
            var i = self.tasks.items.len;
            while (i > 0) {
                i -= 1;
                const task = self.tasks.items[i];
                const result = task.virtualFn(task.data, task.state, self);
                if (result == .Stop) {
                    _ = self.tasks.orderedRemove(i);
                    task.virtualDtor(task.data, task.state, self);
                }
            }
        }
        {
            var i = self.sleeping.items.len;
            while (i > 0) {
                i -= 1;
                if (self.sleeping.items[i].wake <= now) {
                    const slept = self.sleeping.orderedRemove(i);
                    var args = slept.args;
                    var thread = slept.thread;
                    const status = thread.status();
                    if (status != .ok and status != .yield) {
                        std.debug.print("Cannot resume thread error status: {}\n", .{status});
                        unreachable;
                    }
                    if (slept.waited) {
                        thread.pushNumber(now - slept.start);
                        args += 1;
                    }
                    resumeState(thread, null, args);
                }
            }
        }
        {
            var deferredArray = self.deferred.clone() catch |err| {
                std.debug.print("Error: {}\n", .{err});
                unreachable;
            };
            defer deferredArray.deinit();
            self.deferred.clearAndFree();
            var i = deferredArray.items.len;
            while (i > 0) {
                i -= 1;
                const deferred = deferredArray.swapRemove(i);
                var thread = deferred.thread;
                const status = thread.status();
                if (status != .ok and status != .yield) continue;
                resumeState(thread, deferred.from, deferred.args);
            }
        }
    }
}

pub fn deinit(self: *Self) void {
    KillScheduler(self, true);
    self.sleeping.deinit();
    self.deferred.deinit();
    self.tasks.deinit();
    self.awaits.deinit();
}

pub fn getScheduler(L: *Luau) *Self {
    if (L.getField(luau.REGISTRYINDEX, "_SCHEDULER") != .light_userdata) L.raiseErrorStr("InternalError (Scheduler not found)", .{});
    const luau_scheduler = L.toUserdata(Self, -1) catch L.raiseErrorStr("InternalError (Scheduler failed)", .{});
    L.pop(1); // drop: Scheduler
    return luau_scheduler;
}

pub fn toSchedulerFn(comptime f: *const fn (state: *Luau, scheduler: *Self) i32) luau.ZigFn {
    return struct {
        fn inner(L: *Luau) i32 {
            return @call(.always_inline, f, .{ L, getScheduler(L) });
        }
    }.inner;
}
