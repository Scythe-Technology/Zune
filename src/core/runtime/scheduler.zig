const std = @import("std");
const aio = @import("aio");
const luau = @import("luau");

const Engine = @import("engine.zig");
const Zune = @import("../../zune.zig");

const VM = luau.VM;

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
    if (cleanUp)
        for (SCHEDULERS.items, 0..) |o, p|
            if (scheduler == o) {
                _ = SCHEDULERS.orderedRemove(p);
                break;
            };
}

pub fn KillSchedulers() void {
    for (SCHEDULERS.items) |scheduler|
        KillScheduler(scheduler, false);
    SCHEDULERS.clearAndFree();
}

pub const LuauPair = struct { *VM.lua.State, ?i32 };

const SleepingThread = struct {
    from: ?*VM.lua.State,
    thread: LuauPair,
    wake: f64,
    start: f64,
    args: i32,
    waited: bool,
};

const DeferredThread = struct {
    from: ?*VM.lua.State,
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

const TaskFn = fn (ctx: *anyopaque, L: *VM.lua.State, scheduler: *Self) TaskResult;
const TaskFnDtor = fn (ctx: *anyopaque, L: *VM.lua.State, scheduler: *Self) void;
const AsyncCallbackFn = fn (ctx: ?*anyopaque, L: *VM.lua.State, scheduler: *Self, failed: bool) void;
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

const SleepingQueue = std.PriorityQueue(SleepingThread, void, SleepOrder);
const DeferredLinkedList = std.DoublyLinkedList(DeferredThread);

state: *VM.lua.State,
allocator: std.mem.Allocator,
sleeping: SleepingQueue,
deferred: DeferredLinkedList = .{},
tasks: std.ArrayList(TaskObject(anyopaque)),
awaits: std.ArrayList(AwaitingObject(anyopaque)),
dynamic: aio.Dynamic,
async_tasks: usize = 0,
active_incr: u32 = 0,

frame: FrameKind = .None,

pub fn init(allocator: std.mem.Allocator, state: *VM.lua.State) Self {
    const dyn = aio.Dynamic.init(allocator, 4096) catch |err| std.debug.panic("Error: {}\n", .{err});
    return Self{
        .state = state,
        .allocator = allocator,
        .sleeping = SleepingQueue.init(allocator, {}),
        .tasks = std.ArrayList(TaskObject(anyopaque)).init(allocator),
        .awaits = std.ArrayList(AwaitingObject(anyopaque)).init(allocator),
        .dynamic = dyn,
    };
}

pub fn aio_queue(_: *Self, id: aio.Id, userdata: usize) void {
    _ = id;
    _ = userdata;
    // place holder
}

pub fn aio_complete(self: *Self, _: aio.Id, userdata: usize, failed: bool) void {
    std.debug.assert(userdata != 0);
    const ctx: *AsyncIoThread = @ptrFromInt(userdata);
    const state = stateFromPair(ctx.state);
    defer self.allocator.destroy(ctx);
    defer derefThread(ctx.state);
    self.async_tasks -= 1;
    if (ctx.handlerFn) |handler|
        handler(ctx.data, state, self, failed);
}

pub fn refThread(L: *VM.lua.State) LuauPair {
    const GL = L.mainthread();
    if (GL == L)
        return .{ L, null };
    if (L.pushthread()) {
        L.pop(1);
        return .{ L, null };
    }
    L.xmove(GL, 1);
    const ref = GL.ref(-1) orelse std.debug.panic("Tash Scheduler failed to create thread ref\n", .{});
    GL.pop(1);
    return .{ L, ref };
}

pub inline fn stateFromPair(pair: LuauPair) *VM.lua.State {
    return pair[0];
}

pub fn derefThread(pair: LuauPair) void {
    const L, const ref = pair;
    if (ref) |r| {
        if (r <= 0)
            return;
        L.mainthread().unref(r);
    }
}

pub fn spawnThread(self: *Self, thread: *VM.lua.State, from: ?*VM.lua.State, args: i32) void {
    _ = self;
    _ = resumeState(thread, from, args) catch {};
}

pub fn deferThread(self: *Self, thread: *VM.lua.State, from: ?*VM.lua.State, args: i32) void {
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
    thread: *VM.lua.State,
    from: ?*VM.lua.State,
    time: f64,
    args: i32,
    waited: bool,
) void {
    const start = VM.lperf.clock();
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

pub fn addTask(self: *Self, comptime T: type, data: *T, L: *VM.lua.State, comptime handler: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Self) TaskResult, comptime destructor: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Self) void) void {
    const virtualFn = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, scheduler: *Self) TaskResult {
            return @call(.always_inline, handler, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
        }
    }.inner;

    const virtualDtor = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, scheduler: *Self) void {
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

pub fn addSimpleTask(self: *Self, comptime T: type, data: T, L: *VM.lua.State, comptime handler: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Self) anyerror!i32) !i32 {
    const allocator = luau.getallocator(L);
    const virtualFn = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, scheduler: *Self) TaskResult {
            if (l.status() != .Yield)
                return .Stop;
            const top = l.gettop();
            if (@call(.always_inline, handler, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler })) |res| {
                if (res < 0) {
                    if (res == -3) {
                        _ = resumeStateError(l, null) catch {};
                        return .Stop;
                    }
                    const top_now = l.gettop();
                    if (top_now > top)
                        l.pop(@intCast(top_now - top));
                    if (res == -2)
                        return .ContinueFast;
                    return .Continue;
                }
                _ = resumeState(l, null, res) catch {};
                return .Stop;
            } else |err| {
                l.pushstring(@errorName(err));
                _ = resumeStateError(l, null) catch {};
                return .Stop;
            }
        }
    }.inner;

    const virtualDtor = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, _: *Self) void {
            luau.getallocator(l).destroy(@as(*T, @alignCast(@ptrCast(ctx))));
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
    L: *VM.lua.State,
    comptime handlerFn: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Self) void,
    comptime dtorFn: ?*const fn (ctx: *T, L: *VM.lua.State, scheduler: *Self) void,
    priority: ?AwaitTaskPriority,
) ?*T {
    const allocator = luau.getallocator(L);

    const ptr = allocator.create(T) catch |err| std.debug.panic("Error: {}\n", .{err});

    ptr.* = data;

    const status = L.status();
    if (status != .Yield) {
        defer allocator.destroy(ptr);
        handlerFn(ptr, L, self);
        if (dtorFn) |dtor|
            dtor(ptr, L, self);
        return null;
    }

    const resumeFn = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, scheduler: *Self) void {
            @call(.always_inline, handlerFn, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
        }
    }.inner;

    const virtualDtor = struct {
        fn inner(ctx: *anyopaque, l: *VM.lua.State, scheduler: *Self) void {
            if (dtorFn) |dtor| {
                @call(.always_inline, dtor, .{ @as(*T, @alignCast(@ptrCast(ctx))), l, scheduler });
            }
            luau.getallocator(l).destroy(@as(*T, @alignCast(@ptrCast(ctx))));
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
    L: *VM.lua.State,
    args: i32,
    comptime handlerFn: *const fn (ctx: *T, L: *VM.lua.State, scheduler: *Self) void,
    comptime dtorFn: ?*const fn (ctx: *T, L: *VM.lua.State, scheduler: *Self) void,
    from: ?*VM.lua.State,
) !?*T {
    _ = try resumeState(L, from, args);
    return awaitResult(self, T, data, L, handlerFn, dtorFn, .User);
}

pub fn asyncIoResumeState(L: *VM.lua.State, _: *Self, failed: bool) void {
    if (failed) {
        L.pushstring("Async IO failed");
        _ = resumeStateError(L, null) catch {};
    } else _ = resumeState(L, null, 0) catch {};
}

pub fn queueIoCallback(
    self: *Self,
    L: *VM.lua.State,
    io: anytype,
    comptime handlerFn: ?*const fn (L: *VM.lua.State, scheduler: *Self, failed: bool) void,
) !void {
    const allocator = self.allocator;

    const async_ptr = try allocator.create(AsyncIoThread);
    errdefer allocator.destroy(async_ptr);

    const handler = struct {
        fn inner(_: ?*anyopaque, l: *VM.lua.State, scheduler: *Self, failed: bool) void {
            @call(.always_inline, handlerFn.?, .{ l, scheduler, failed });
        }
    }.inner;

    async_ptr.* = .{
        .state = refThread(L),
        .data = null,
        .handlerFn = if (handlerFn != null) handler else null,
    };
    errdefer derefThread(async_ptr.state);

    var queueItem = io;

    queueItem.op.userdata = @intFromPtr(async_ptr);

    try self.dynamic.queue(queueItem, self);
    self.async_tasks += 1;
    self.active_incr += 1;
}

pub fn queueIoCallbackCtx(
    self: *Self,
    comptime T: type,
    data: *T,
    L: *VM.lua.State,
    io: anytype,
    comptime handlerFn: ?*const fn (ctx: *T, L: *VM.lua.State, scheduler: *Self, failed: bool) void,
) !void {
    const allocator = self.allocator;

    const async_ptr = try allocator.create(AsyncIoThread);
    errdefer allocator.destroy(async_ptr);

    const handler = struct {
        fn inner(ctx: ?*anyopaque, l: *VM.lua.State, scheduler: *Self, failed: bool) void {
            @call(.always_inline, handlerFn.?, .{ @as(*T, @alignCast(@ptrCast(ctx.?))), l, scheduler, failed });
        }
    }.inner;

    async_ptr.* = .{
        .state = refThread(L),
        .data = data,
        .handlerFn = if (handlerFn != null) handler else null,
    };
    errdefer derefThread(async_ptr.state);

    var queueItem = io;

    queueItem.op.userdata = @intFromPtr(async_ptr);

    try self.dynamic.queue(queueItem, self);
    self.async_tasks += 1;
    self.active_incr += 1;
}

pub fn queueIo(
    self: *Self,
    L: *VM.lua.State,
    io: anytype,
) !void {
    const allocator = self.allocator;

    const async_ptr = try allocator.create(AsyncIoThread);
    errdefer allocator.destroy(async_ptr);

    async_ptr.* = .{
        .state = refThread(L),
        .data = null,
        .handlerFn = null,
    };
    errdefer derefThread(async_ptr.state);

    var queueItem = io;

    queueItem.op.userdata = @intFromPtr(async_ptr);

    try self.dynamic.queue(queueItem, self);
    self.async_tasks += 1;
    self.active_incr += 1;
}

pub fn resumeState(state: *VM.lua.State, from: ?*VM.lua.State, args: i32) !VM.lua.Status {
    const status = state.status();
    if (status != .Yield and status != .Ok)
        return status.check();
    return state.resumethread(from, args).check() catch |err| {
        Engine.logError(state, err, false);
        if (Zune.Debugger.ACTIVE) {
            @branchHint(.unlikely);
            switch (err) {
                error.Runtime => Zune.Debugger.luau_panic(state, -2),
                else => {},
            }
        }
        return err;
    };
}

pub fn resumeStateError(state: *VM.lua.State, from: ?*VM.lua.State) !VM.lua.Status {
    const status = state.status();
    if (status != .Yield and status != .Ok)
        return status.check();
    return state.resumeerror(from).check() catch |err| {
        Engine.logError(state, err, false);
        if (Zune.Debugger.ACTIVE) {
            @branchHint(.unlikely);
            switch (err) {
                error.Runtime => Zune.Debugger.luau_panic(state, -2),
                else => {},
            }
        }
        return err;
    };
}

pub fn cancelThread(self: *Self, thread: *VM.lua.State) void {
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

pub fn run(self: *Self, comptime mode: Zune.RunMode) void {
    var active: usize = 0;
    while ((self.sleeping.items.len > 0 or self.deferred.len > 0 or self.tasks.items.len > 0 or self.awaits.items.len > 0 or self.async_tasks > 0)) {
        const now = VM.lperf.clock();
        if (self.awaits.items.len > 0) {
            self.frame = .Awaiting;
            var i = self.awaits.items.len;
            while (i > 0) {
                i -= 1;
                const awaiting = self.awaits.items[i];
                if (awaiting.state[0].status() != .Yield) {
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
                    if (status != .Ok and status != .Yield) {
                        std.debug.print("Cannot resume thread error status: {}\n", .{status});
                        continue;
                    }
                    if (thread.isthreadreset())
                        continue;
                    if (slept.waited) {
                        thread.pushnumber(now - slept.start);
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
            if (self.async_tasks > 0) {
                const res = self.dynamic.complete(.nonblocking, self) catch |err| {
                    std.debug.print("AsyncIO Error: {}\n", .{err});
                    break :jmp;
                };
                if (res.num_completed > 0) {
                    active += res.num_completed;
                }
            }
            active = self.active_incr;
            self.active_incr = 0;
        }
        if (self.deferred.len > 0) {
            self.frame = .Deferred;
            while (self.deferred.popFirst()) |node| {
                const deferred = node.data;
                defer self.allocator.destroy(node);
                const thread, _ = deferred.thread;
                const status = thread.status();
                defer derefThread(deferred.thread);
                if (status != .Ok and status != .Yield)
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
        if (comptime mode == .Test)
            _ = self.state.gc(.Collect, 0);
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

pub fn getScheduler(L: anytype) *Self {
    if (@TypeOf(L) == *VM.lua.State) {
        const GL = L.mainthread();
        const scheduler = GL.getthreaddata(*Self);
        return scheduler;
    } else if (@TypeOf(L) == LuauPair) {
        const state, _ = L;
        const GL = state.mainthread();
        const scheduler = GL.getthreaddata(*Self);
        return scheduler;
    } else @compileError("Invalid type for getScheduler");
}
