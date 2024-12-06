const std = @import("std");
const luau = @import("luau");

const Engine = @import("engine.zig");
const Zune = @import("../../zune.zig");

const Luau = luau.Luau;

pub var SCHEDULERS = std.ArrayList(*Self).init(Zune.DEFAULT_ALLOCATOR);

pub fn KillScheduler(scheduler: *Self, cleanUp: bool) void {
    {
        var i = scheduler.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = scheduler.tasks.items[i];
            task.virtualDtor(task.data, stateFromPair(task.state), scheduler);
            _ = scheduler.tasks.orderedRemove(i);
        }
    }
    {
        var i = scheduler.awaits.items.len;
        while (i > 0) {
            i -= 1;
            const awaiting = scheduler.awaits.items[i];
            awaiting.virtualDtor(awaiting.data, stateFromPair(awaiting.state), scheduler);
            _ = scheduler.awaits.orderedRemove(i);
        }
    }
    if (cleanUp) for (SCHEDULERS.items, 0..) |o, p| if (scheduler == o) {
        _ = SCHEDULERS.orderedRemove(p);
        break;
    };
}

pub fn KillSchedulers() void {
    for (SCHEDULERS.items) |scheduler|
        KillScheduler(scheduler, false);
    SCHEDULERS.deinit();
}

pub const LuauPair = struct { *Luau, ?i32 };

const SleepingThread = struct {
    from: ?*Luau,
    thread: LuauPair,
    wake: f64,
    start: f64,
    args: i32,
    waited: bool,
};

const DeferredThread = struct {
    from: ?*Luau,
    thread: LuauPair,
    args: i32,
};

const Self = @This();

pub const TaskResult = enum {
    Continue,
    ContinueFast,
    Stop,
};

pub const AwaitTaskPriority = enum { Internal, User };

const TaskFn = fn (ctx: *anyopaque, L: *Luau, scheduler: *Self) TaskResult;
const TaskFnDtor = fn (ctx: *anyopaque, L: *Luau, scheduler: *Self) void;
const AwaitedFn = TaskFnDtor; // Similar to TaskFnDtor

pub fn TaskObject(comptime T: type) type {
    return struct {
        data: *T,
        state: LuauPair,
        virtualFn: *const TaskFn,
        virtualDtor: *const TaskFnDtor,
    };
}

pub fn AwaitingObject(comptime T: type) type {
    return struct {
        data: *T,
        state: LuauPair,
        resumeFn: *const AwaitedFn,
        virtualDtor: *const TaskFnDtor,
        priority: AwaitTaskPriority,
    };
}

state: *Luau,
allocator: std.mem.Allocator,
sleeping: std.ArrayList(SleepingThread),
deferred: std.ArrayList(DeferredThread),
tasks: std.ArrayList(TaskObject(anyopaque)),
awaits: std.ArrayList(AwaitingObject(anyopaque)),

pub fn init(allocator: std.mem.Allocator, state: *Luau) Self {
    return .{
        .state = state,
        .allocator = allocator,
        .sleeping = std.ArrayList(SleepingThread).init(allocator),
        .deferred = std.ArrayList(DeferredThread).init(allocator),
        .tasks = std.ArrayList(TaskObject(anyopaque)).init(allocator),
        .awaits = std.ArrayList(AwaitingObject(anyopaque)).init(allocator),
    };
}

pub fn refThread(L: *Luau) LuauPair {
    const GL = L.getMainThread();
    if (GL == L)
        return .{ L, null };
    if (L.pushThread()) {
        L.pop(1);
        return .{ L, null };
    }
    L.xMove(GL, 1);
    const ref = GL.ref(-1) catch std.debug.panic("Tash Scheduler failed to create thread ref\n", .{});
    GL.pop(1);
    return .{ L, ref };
}

pub inline fn stateFromPair(pair: LuauPair) *Luau {
    return pair[0];
}

pub fn derefThread(pair: LuauPair) void {
    const L, const ref = pair;
    if (ref) |r| {
        if (r <= 0)
            return;
        L.getMainThread().unref(r);
    }
}

pub fn spawnThread(self: *Self, thread: *Luau, args: i32) void {
    _ = self;
    _ = resumeState(thread, null, args) catch {};
}

pub fn deferThread(self: *Self, thread: *Luau, from: ?*Luau, args: i32) void {
    self.deferred.append(.{
        .from = from,
        .thread = refThread(thread),
        .args = args,
    }) catch |err| std.debug.panic("Error: {}\n", .{err});
}

pub fn sleepThread(
    self: *Self,
    thread: *Luau,
    from: ?*Luau,
    time: f64,
    args: i32,
    waited: bool,
) void {
    const start = luau.clock();
    const wake = start + time;

    self.sleeping.insert(0, .{
        .thread = refThread(thread),
        .from = from,
        .start = start,
        .wake = wake,
        .args = args,
        .waited = waited,
    }) catch |err| std.debug.panic("Error: {}\n", .{err});
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
        .state = refThread(L),
        .virtualFn = virtualFn,
        .virtualDtor = virtualDtor,
    }) catch |err| std.debug.panic("Error: {}\n", .{err});
}

pub fn addSimpleTask(self: *Self, comptime T: type, data: T, L: *Luau, comptime handler: *const fn (ctx: *T, L: *Luau, scheduler: *Self) anyerror!i32) !i32 {
    const allocator = L.allocator();
    const virtualFn = struct {
        fn inner(ctx: *anyopaque, l: *Luau, scheduler: *Self) TaskResult {
            if (l.status() != .yield)
                return .Stop;
            const top = l.getTop();
            if (@call(.always_inline, handler, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler })) |res| {
                if (res < 0) {
                    if (res == -3) {
                        _ = resumeStateError(l, null) catch {};
                        return .Stop;
                    }
                    const top_now = l.getTop();
                    if (top_now > top)
                        l.pop(top_now - top);
                    if (res == -2)
                        return .ContinueFast;
                    return .Continue;
                }
                _ = resumeState(l, null, res) catch {};
                return .Stop;
            } else |err| {
                l.pushString(@errorName(err));
                _ = resumeStateError(l, null) catch {};
                return .Stop;
            }
        }
    }.inner;

    const virtualDtor = struct {
        fn inner(ctx: *anyopaque, l: *Luau, _: *Self) void {
            l.allocator().destroy(@as(*T, @alignCast(@ptrCast(ctx))));
        }
    }.inner;

    const ptr = allocator.create(T) catch |err| std.debug.panic("Error: {}\n", .{err});

    ptr.* = data;

    self.tasks.append(.{
        .data = @ptrCast(ptr),
        .state = refThread(L),
        .virtualFn = virtualFn,
        .virtualDtor = virtualDtor,
    }) catch |err| std.debug.panic("Error: {}\n", .{err});

    return L.yield(0);
}

pub fn awaitResult(
    self: *Self,
    comptime T: type,
    data: T,
    L: *Luau,
    comptime handlerFn: *const fn (ctx: *T, L: *Luau, scheduler: *Self) void,
    comptime dtorFn: ?*const fn (ctx: *T, L: *Luau, scheduler: *Self) void,
    priority: ?AwaitTaskPriority,
) ?*T {
    const allocator = L.allocator();

    const ptr = allocator.create(T) catch |err| std.debug.panic("Error: {}\n", .{err});

    ptr.* = data;

    const status = L.status();
    if (status != .yield) {
        defer allocator.destroy(ptr);
        handlerFn(ptr, L, self);
        if (dtorFn) |dtor|
            dtor(ptr, L, self);
        return null;
    }

    const resumeFn = struct {
        fn inner(ctx: *anyopaque, l: *Luau, scheduler: *Self) void {
            @call(.always_inline, handlerFn, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
        }
    }.inner;

    const virtualDtor = struct {
        fn inner(ctx: *anyopaque, l: *Luau, scheduler: *Self) void {
            if (dtorFn) |dtor| {
                @call(.always_inline, dtor, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
            }
            l.allocator().destroy(@as(*T, @alignCast(@ptrCast(ctx))));
        }
    }.inner;

    self.awaits.append(.{
        .data = @ptrCast(ptr),
        .state = refThread(L),
        .resumeFn = resumeFn,
        .virtualDtor = virtualDtor,
        .priority = priority orelse .User,
    }) catch |err| std.debug.panic("Error: {}\n", .{err});

    return ptr;
}

pub fn awaitCall(
    self: *Self,
    comptime T: type,
    data: T,
    L: *Luau,
    args: i32,
    comptime handlerFn: *const fn (ctx: *T, L: *Luau, scheduler: *Self) void,
    comptime dtorFn: ?*const fn (ctx: *T, L: *Luau, scheduler: *Self) void,
    from: ?*Luau,
) !?*T {
    _ = try resumeState(L, from, args);
    return awaitResult(self, T, data, L, handlerFn, dtorFn, .User);
}

pub fn resumeState(state: *Luau, from: ?*Luau, args: i32) !luau.ResumeStatus {
    return state.resumeThread(from, args) catch |err| {
        Engine.logError(state, err, false);
        return err;
    };
}

pub fn resumeStateError(state: *Luau, from: ?*Luau) !luau.ResumeStatus {
    return state.resumeThreadError(from) catch |err| {
        Engine.logError(state, err, false);
        return err;
    };
}

pub fn resumeStateErrorFmt(state: *Luau, from: ?*Luau, comptime fmt: []const u8, args: anytype) !luau.ResumeStatus {
    return state.resumeThreadErrorFmt(from, fmt, args) catch |err| {
        Engine.logError(state, err, false);
        return err;
    };
}

pub fn cancelThread(self: *Self, thread: *Luau) void {
    const sleeping_items = self.sleeping.items;
    for (sleeping_items, 0..) |item, i| {
        if (stateFromPair(item.thread) == thread) {
            const slept = self.sleeping.orderedRemove(i);
            derefThread(slept.thread);
            return;
        }
    }
    const deferred_items = self.deferred.items;
    for (deferred_items, 0..) |item, i| {
        if (stateFromPair(item.thread) == thread) {
            const deferred = self.deferred.orderedRemove(i);
            derefThread(deferred.thread);
            return;
        }
    }
}

pub fn run(self: *Self, comptime testing: bool) void {
    var active: usize = 0;
    while ((self.sleeping.items.len > 0 or self.deferred.items.len > 0 or self.tasks.items.len > 0 or self.awaits.items.len > 0)) {
        const now = luau.clock();
        {
            var i = self.awaits.items.len;
            while (i > 0) {
                i -= 1;
                const awaiting = self.awaits.items[i];
                if (awaiting.state[0].status() != .yield) {
                    _ = self.awaits.orderedRemove(i);
                    const state, _ = awaiting.state;
                    const data = awaiting.data;
                    awaiting.resumeFn(data, state, self);
                    awaiting.virtualDtor(data, state, self);
                    derefThread(awaiting.state);
                    active += 1;
                }
            }
        }
        {
            var i = self.tasks.items.len;
            while (i > 0) {
                i -= 1;
                const task = self.tasks.items[i];
                switch (task.virtualFn(task.data, stateFromPair(task.state), self)) {
                    .Continue => {},
                    .ContinueFast => active += 1,
                    .Stop => {
                        _ = self.tasks.orderedRemove(i);
                        task.virtualDtor(task.data, stateFromPair(task.state), self);
                        derefThread(task.state);
                        active += 1;
                    },
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
                    const thread, _ = slept.thread;
                    const status = thread.status();
                    derefThread(slept.thread);
                    if (status != .ok and status != .yield) {
                        std.debug.print("Cannot resume thread error status: {}\n", .{status});
                        continue;
                    }
                    if (thread.isThreadReset())
                        continue;
                    if (slept.waited) {
                        thread.pushNumber(now - slept.start);
                        args += 1;
                    }
                    _ = resumeState(
                        thread,
                        slept.from,
                        args,
                    ) catch {};
                    active += 1;
                }
            }
        }
        if (self.deferred.items.len > 0) {
            var deferredArray = self.deferred.clone() catch |err|
                std.debug.panic("Error: {}\n", .{err});
            defer deferredArray.deinit();
            self.deferred.clearAndFree();
            for (deferredArray.items) |deferred| {
                const thread, _ = deferred.thread;
                const status = thread.status();
                derefThread(deferred.thread);
                if (status != .ok and status != .yield)
                    continue;
                _ = resumeState(
                    thread,
                    deferred.from,
                    deferred.args,
                ) catch {};
                active += 1;
            }
        }
        if (active >= 5000)
            active = 5000;
        if (active == 0) {
            std.time.sleep(std.time.ns_per_ms * 2);
        } else active -= 1;
        if (comptime testing)
            self.state.gcCollect();
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
    const luau_scheduler = L.toUserdata(Self, -1) catch unreachable;
    L.pop(1); // drop: Scheduler
    return luau_scheduler;
}

pub fn toSchedulerFn(comptime f: *const fn (state: *Luau, scheduler: *Self) i32) luau.ZigFnInt {
    return struct {
        fn inner(L: *Luau) i32 {
            return @call(.always_inline, f, .{ L, getScheduler(L) });
        }
    }.inner;
}

pub fn toSchedulerEFn(comptime f: *const fn (state: *Luau, scheduler: *Self) anyerror!i32) luau.ZigFnErrorSet {
    return struct {
        fn inner(L: *Luau) anyerror!i32 {
            return @call(.always_inline, f, .{ L, getScheduler(L) });
        }
    }.inner;
}
