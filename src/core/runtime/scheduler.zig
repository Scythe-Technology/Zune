const std = @import("std");
const aio = @import("aio");
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
const AsyncCallbackFn = fn (ctx: *anyopaque, L: *Luau, scheduler: *Self, failed: bool) void;
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

const AsyncIoThread = struct {
    data: ?*anyopaque,
    state: LuauPair,
    handlerFn: ?*const AsyncCallbackFn,
};

const FrameKind = enum {
    None,
    Awaiting,
    Task,
    Sleeping,
    AsyncIO,
    Deferred,
};

fn SleepOrder(_: void, a: SleepingThread, b: SleepingThread) std.math.Order {
    const wakeA = a.wake;
    const wakeB = b.wake;
    if (wakeA == wakeB) {
        return .eq;
    } else if (wakeA < wakeB) {
        return .lt;
    } else if (wakeA > wakeB) {
        return .gt;
    } else {
        unreachable;
    }
}

fn DeferredOrder(_: void, a: DeferredThread, b: DeferredThread) std.math.Order {
    const wakeA = a;
    const wakeB = b.wake;
    if (wakeA == wakeB) {
        return .eq;
    } else if (wakeA < wakeB) {
        return .lt;
    } else if (wakeA > wakeB) {
        return .gt;
    } else {
        unreachable;
    }
}

const SleepingQueue = std.PriorityQueue(SleepingThread, void, SleepOrder);
const DeferredLinkedList = std.DoublyLinkedList(DeferredThread);

state: *Luau,
allocator: std.mem.Allocator,
sleeping: SleepingQueue,
deferred: DeferredLinkedList,
tasks: std.ArrayList(TaskObject(anyopaque)),
awaits: std.ArrayList(AwaitingObject(anyopaque)),
dynamic: aio.Dynamic,
async_tasks: usize = 0,

frame: FrameKind = .None,

pub fn init(allocator: std.mem.Allocator, state: *Luau) Self {
    var dyn = aio.Dynamic.init(allocator, 8) catch |err| std.debug.panic("Error: {}\n", .{err});
    dyn.queue_callback = ioQueue;
    dyn.completion_callback = ioCompletion;
    return .{
        .state = state,
        .allocator = allocator,
        .sleeping = SleepingQueue.init(allocator, {}),
        .deferred = DeferredLinkedList{},
        .tasks = std.ArrayList(TaskObject(anyopaque)).init(allocator),
        .awaits = std.ArrayList(AwaitingObject(anyopaque)).init(allocator),
        .dynamic = dyn,
    };
}

fn ioQueue(uop: aio.Dynamic.Uop, id: aio.Id) void {
    _ = uop;
    _ = id;
    // place holder
}

fn ioCompletion(uop: aio.Dynamic.Uop, _: aio.Id, failed: bool) void {
    switch (uop) {
        inline else => |*op| {
            std.debug.assert(op.userdata != 0);
            const ctx: *AsyncIoThread = @ptrFromInt(op.userdata);
            const state = stateFromPair(ctx.state);
            const scheduler = getScheduler(state);
            defer scheduler.allocator.destroy(ctx);
            defer derefThread(ctx.state);
            scheduler.async_tasks -= 1;
            if (ctx.handlerFn) |handler|
                handler(ctx.data.?, state, scheduler, failed);
        },
    }
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

pub fn spawnThread(self: *Self, thread: *Luau, from: ?*Luau, args: i32) void {
    _ = self;
    _ = resumeState(thread, from, args) catch {};
}

pub fn deferThread(self: *Self, thread: *Luau, from: ?*Luau, args: i32) void {
    const ptr = self.allocator.create(DeferredLinkedList.Node) catch |err| std.debug.panic("Error: {}\n", .{err});
    ptr.* = .{
        .data = .{
            .from = from,
            .thread = refThread(thread),
            .args = args,
        },
    };
    self.deferred.append(ptr);
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
    const wake = start + time + if (time == 0 and self.frame == .Sleeping) @as(f64, 0.0001) else @as(f64, 0);

    self.sleeping.add(.{
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

pub fn queueIoCallback(
    self: *Self,
    comptime T: type,
    data: *T,
    L: *Luau,
    io: anytype,
    comptime handlerFn: ?*const fn (ctx: *T, L: *Luau, scheduler: *Self, failed: bool) void,
) !void {
    const allocator = self.allocator;

    const async_ptr = try allocator.create(AsyncIoThread);
    errdefer allocator.destroy(async_ptr);

    const handler = struct {
        fn inner(ctx: *anyopaque, l: *Luau, scheduler: *Self, failed: bool) void {
            @call(.always_inline, handlerFn.?, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler, failed });
        }
    }.inner;

    async_ptr.* = .{
        .state = refThread(L),
        .data = data,
        .handlerFn = if (handlerFn != null) handler else null,
    };
    errdefer derefThread(async_ptr.state);

    var queueItem = io;

    queueItem.userdata = @intFromPtr(async_ptr);

    try self.dynamic.queue(queueItem);
    self.async_tasks += 1;
}

pub fn queueIo(
    self: *Self,
    L: *Luau,
    io: anytype,
) !void {
    const allocator = self.allocator;

    const async_ptr = try allocator.create(AsyncIoThread);
    errdefer allocator.destroy(async_ptr);

    async_ptr.* = .{
        .state = refThread(L),
        .data = null,
        .handlerFn = null,
        .virtualDtor = null,
    };
    errdefer derefThread(async_ptr.state);

    var queueItem = io;

    queueItem.userdata = @intFromPtr(async_ptr);

    try self.dynamic.queue(queueItem);
    self.async_tasks += 1;
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
            const slept = self.sleeping.removeIndex(i);
            derefThread(slept.thread);
            return;
        }
    }
    var node = self.deferred.first;
    while (node) |dnode| {
        const deferred = dnode.data;
        if (stateFromPair(deferred.thread) == thread) {
            derefThread(deferred.thread);
            self.deferred.remove(dnode);
            self.allocator.destroy(dnode);
            break;
        }
        node = dnode.next;
    }
}

pub fn run(self: *Self, comptime testing: bool) void {
    var active: usize = 0;
    while ((self.sleeping.items.len > 0 or self.deferred.len > 0 or self.tasks.items.len > 0 or self.awaits.items.len > 0 or self.async_tasks > 0)) {
        const now = luau.clock();
        if (self.awaits.items.len > 0) {
            self.frame = .Awaiting;
            var i = self.awaits.items.len;
            while (i > 0) {
                i -= 1;
                const awaiting = self.awaits.items[i];
                if (awaiting.state[0].status() != .yield) {
                    defer derefThread(awaiting.state);
                    _ = self.awaits.orderedRemove(i);
                    const state, _ = awaiting.state;
                    const data = awaiting.data;
                    awaiting.resumeFn(data, state, self);
                    awaiting.virtualDtor(data, state, self);
                    active += 1;
                }
            }
        }
        if (self.tasks.items.len > 0) {
            self.frame = .Task;
            var i = self.tasks.items.len;
            while (i > 0) {
                i -= 1;
                const task = self.tasks.items[i];
                switch (task.virtualFn(task.data, stateFromPair(task.state), self)) {
                    .Continue => {},
                    .ContinueFast => active += 1,
                    .Stop => {
                        defer derefThread(task.state);
                        _ = self.tasks.orderedRemove(i);
                        task.virtualDtor(task.data, stateFromPair(task.state), self);
                        active += 1;
                    },
                }
            }
        }
        if (self.sleeping.items.len > 0) {
            self.frame = .Sleeping;
            while (self.sleeping.peek()) |current| {
                if (current.wake <= now) {
                    const slept = self.sleeping.remove();
                    var args = slept.args;
                    const thread, _ = slept.thread;
                    const status = thread.status();
                    defer derefThread(slept.thread);
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
                } else break;
            }
        }
        jmp: {
            self.frame = .AsyncIO;
            const res = self.dynamic.complete(.nonblocking) catch |err| {
                std.debug.print("AsyncIO Error: {}\n", .{err});
                break :jmp;
            };
            if (res.num_completed > 0) {
                std.debug.print("completed async task: {}\n", .{res.num_completed});
                active += res.num_completed;
            }
            if (res.num_errors > 0) {
                std.debug.print("errors: {}\n", .{res.num_errors});
            }
        }
        if (self.deferred.len > 0) {
            self.frame = .Deferred;
            while (self.deferred.popFirst()) |node| {
                const deferred = node.data;
                defer self.allocator.destroy(node);
                const thread, _ = deferred.thread;
                const status = thread.status();
                defer derefThread(deferred.thread);
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
        self.frame = .None;
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
    {
        while (self.deferred.pop()) |node|
            self.allocator.destroy(node);
    }
    self.tasks.deinit();
    self.awaits.deinit();
    self.dynamic.deinit(self.allocator);
}

pub fn getScheduler(L: *Luau) *Self {
    const GL = L.getMainThread();
    const scheduler = GL.getThreadData(Self) catch L.raiseErrorStr("InternalError (Scheduler not found)", .{});
    return scheduler;
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
