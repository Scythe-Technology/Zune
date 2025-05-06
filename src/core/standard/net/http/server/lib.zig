const std = @import("std");
const xev = @import("xev").Dynamic;
const time = @import("datetime");
const luau = @import("luau");
const builtin = @import("builtin");

const Engine = @import("../../../../runtime/engine.zig");
const Scheduler = @import("../../../../runtime/scheduler.zig");

const luaHelper = @import("../../../../utils/luahelper.zig");
const MethodMap = @import("../../../../utils/method_map.zig");
const Lists = @import("../../../../utils/lists.zig");

const VM = luau.VM;

/// The Zune HTTP server backend.
const Self = @This();

const ClientContext = @import("./client.zig");
const ClientWebSocket = @import("./websocket.zig");

pub const State = struct {
    stage: Stage = .idle,
    port: u16,
    client_timeout: usize = 60,
    max_body_size: usize = 1_048_576,
    max_header_count: u32 = 100,
    max_connections: usize = 1024,
    list: Lists.PriorityLinkedList(ClientContext.shortestTime) = .{},
    free: Lists.DoublyLinkedList = .{},

    pub const Stage = enum {
        idle,
        shutdown,
        accepting,
        max_capacity,
        dead,

        pub inline fn isShutdown(self: Stage) bool {
            return self == .shutdown or self == .dead;
        }
    };
};

pub const Timer = struct {
    completion: xev.Completion,
    reset_completion: xev.Completion,
    next_ms: u64 = 0,
    active: bool = false,
};

const FnHandlers = struct {
    request: luaHelper.Ref(void) = .empty,
    ws_upgrade: luaHelper.Ref(void) = .empty,
    ws_open: luaHelper.Ref(void) = .empty,
    ws_message: luaHelper.Ref(void) = .empty,
    ws_close: luaHelper.Ref(void) = .empty,

    pub fn hasWebSocket(self: *FnHandlers) bool {
        return self.ws_upgrade.hasRef() or
            self.ws_open.hasRef() or
            self.ws_message.hasRef() or
            self.ws_close.hasRef();
    }

    pub fn derefAll(self: *FnHandlers, L: *VM.lua.State) void {
        self.request.deref(L);
        self.ws_upgrade.deref(L);
        self.ws_open.deref(L);
        self.ws_message.deref(L);
        self.ws_close.deref(L);
    }
};

completion: xev.Completion,
timer: Timer,
arena: std.heap.ArenaAllocator,
socket: xev.TCP,
state: State,
ref: luaHelper.Ref(void),
handlers: FnHandlers,
scheduler: *Scheduler,

fn __dtor(self: *Self) void {
    const L = self.scheduler.global;
    defer self.arena.deinit();

    self.handlers.derefAll(L);

    self.scheduler.async_tasks -= 1;
}

pub fn onAccept(
    ud: ?*Self,
    loop: *xev.Loop,
    _: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const self = ud orelse unreachable;
    const allocator = self.arena.child_allocator;

    const client_socket = r catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => {
            std.debug.print("Error accepting client: {}\n", .{err});
            return .rearm;
        },
    };
    if (self.state.stage != .accepting)
        return .disarm;

    if (self.state.free.len == 0) {
        self.expandFreeSize(
            if (self.state.max_connections > 0)
                @min(self.state.max_connections - self.state.list.len, 128)
            else
                128,
        ) catch |err| std.debug.panic("Failed to expand client list: {}\n", .{err});
    }

    const node = self.state.free.pop() orelse unreachable;
    const client: *ClientContext = @fieldParentPtr("node", node);
    client.* = .{
        .socket = client_socket,
        .completion = .init(),
        .close_completion = .init(),
        .cancel_completion = .init(),
        .parser = .init(allocator, self.state.max_header_count),
        .server = self,
    };

    client.start(loop, true);

    self.startTimer(loop);

    if (self.state.max_connections > 0 and self.state.list.len >= self.state.max_connections) {
        self.state.stage = .max_capacity;
        return .disarm;
    }
    return .rearm;
}

pub fn reloadNode(self: *Self, comptime direction: enum { front, back }, node: *ClientContext, loop: *xev.Loop) void {
    self.state.list.remove(&node.node);
    switch (direction) {
        .front => self.state.list.add(&node.node),
        .back => self.state.list.addBack(&node.node),
    }
    self.reloadTimer(loop);
}

pub fn onTimerTick(
    ud: ?*Self,
    loop: *xev.Loop,
    _: *xev.Completion,
    run: xev.Timer.RunError!void,
) xev.CallbackAction {
    const self = ud orelse unreachable;

    run catch |err| switch (err) {
        error.Canceled => return .disarm,
        else => {},
    };

    const now = luau.VM.lperf.clock();

    var it: ?*Lists.LinkedNode = self.state.list.first;
    while (it) |n| : (it = n.next) {
        const client: *ClientContext = @fieldParentPtr("node", n);
        if (client.websocket.active)
            break;
        if (client.timeout > now)
            break;
        client.timeout = now + @as(f64, @floatFromInt(self.state.client_timeout));
        if (client.state.stage == .receiving) {
            client.state.stage = .closing;
            loop.cancel(
                &client.completion,
                &client.cancel_completion,
                void,
                null,
                Scheduler.XevNoopCallback(xev.CancelError!void, .disarm),
            );
        }
        self.state.list.remove(&client.node);
        self.state.list.addBack(&client.node);
    }

    self.timer.active = false;

    self.startTimer(loop);

    return .disarm;
}

pub fn reloadTimer(self: *Self, loop: *xev.Loop) void {
    if (!self.timer.active)
        return self.startTimer(loop);
    var timer: xev.Timer = xev.Timer.init() catch unreachable;
    const now = luau.VM.lperf.clock();
    const lowest: *ClientContext = @fieldParentPtr("node", self.state.list.first orelse unreachable);
    if (lowest.websocket.active)
        return;
    const next_ms: u64 = @intFromFloat(@max(lowest.timeout - now, 0) * std.time.ms_per_s);
    if (next_ms >= self.timer.next_ms)
        return;
    self.timer.next_ms = next_ms;
    timer.reset(
        loop,
        &self.timer.completion,
        &self.timer.reset_completion,
        next_ms,
        Self,
        self,
        onTimerTick,
    );
}

pub fn startTimer(self: *Self, loop: *xev.Loop) void {
    if (self.timer.active or self.state.stage.isShutdown())
        return;
    if (self.state.list.len == 0)
        return;
    self.timer.active = true;
    var timer: xev.Timer = xev.Timer.init() catch unreachable;
    const now = luau.VM.lperf.clock();
    const lowest: *ClientContext = @fieldParentPtr("node", self.state.list.first orelse unreachable);
    if (lowest.websocket.active)
        return;
    const next_ms: u64 = @intFromFloat(@max(lowest.timeout - now, 0) * std.time.ms_per_s);
    self.timer.next_ms = next_ms;
    timer.run(
        loop,
        &self.timer.completion,
        next_ms,
        Self,
        self,
        onTimerTick,
    );
}

pub fn startListen(self: *Self, loop: *xev.Loop) void {
    std.debug.assert(self.state.stage == .idle);

    self.state.stage = .accepting;
    self.socket.accept(
        loop,
        &self.completion,
        Self,
        self,
        onAccept,
    );
}

pub fn expandFreeSize(self: *Self, amount: usize) !void {
    if (self.state.free.len >= amount)
        return;
    const allocator = self.arena.allocator();
    for (0..amount) |_| {
        const client = try allocator.create(ClientContext);
        self.state.free.append(&client.node);
    }
}

pub fn lua_serve(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    const serve_info = try L.Zcheckvalue(struct {
        port: u16,
        address: ?[:0]const u8,
        reuseAddress: ?bool,
        backlog: ?u31,
        maxBodySize: ?u32,
        clientTimeout: ?u32,
        maxConnections: ?u32,
    }, 1, null);
    var handlers: FnHandlers = .{};
    errdefer handlers.derefAll(L);

    if (L.getfield(1, "request") != .Function)
        return L.Zerror("invalid field 'request' (expected function)");
    handlers.request = .init(L, -1, undefined);
    L.pop(1);

    const websocket_type = L.getfield(1, "websocket");
    if (!websocket_type.isnoneornil()) {
        if (websocket_type != .Table)
            return L.Zerror("Expected field 'websocket' to be a table");
        const upgrade_type = L.getfield(-1, "upgrade");
        if (!upgrade_type.isnoneornil()) {
            if (upgrade_type != .Function)
                return L.Zerror("Expected field 'upgrade' to be a function");
            handlers.ws_upgrade = .init(L, -1, undefined);
        }
        L.pop(1);
        const open_type = L.getfield(-1, "open");
        if (!open_type.isnoneornil()) {
            if (open_type != .Function)
                return L.Zerror("Expected field 'open' to be a function");
            handlers.ws_open = .init(L, -1, undefined);
        }
        L.pop(1);
        const message_type = L.getfield(-1, "message");
        if (!message_type.isnoneornil()) {
            if (message_type != .Function)
                return L.Zerror("Expected field 'message' to be a function");
            handlers.ws_message = .init(L, -1, undefined);
        }
        L.pop(1);
        const close_type = L.getfield(-1, "close");
        if (!close_type.isnoneornil()) {
            if (close_type != .Function)
                return L.Zerror("Expected field 'close' to be a function");
            handlers.ws_close = .init(L, -1, undefined);
        }
        L.pop(1);
    }
    L.pop(1);

    const self = L.newuserdatadtor(Self, __dtor);
    _ = L.Lgetmetatable(@typeName(Self));
    _ = L.setmetatable(-2);

    scheduler.async_tasks += 1;

    const address_str = serve_info.address orelse "127.0.0.1";

    var address = try std.net.Address.parseIp4(address_str, serve_info.port);

    const socket = try @import("../../lib.zig").createSocket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        std.posix.IPPROTO.TCP,
    );
    errdefer std.posix.close(socket);

    if (serve_info.reuseAddress orelse false) {
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );
        if (@hasDecl(std.posix.SO, "REUSEPORT") and address.any.family != std.posix.AF.UNIX) {
            try std.posix.setsockopt(
                socket,
                std.posix.SOL.SOCKET,
                std.posix.SO.REUSEPORT,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }
    }
    var socklen = address.getOsSockLen();
    try std.posix.bind(socket, &address.any, socklen);
    try std.posix.listen(socket, serve_info.backlog orelse 128);
    try std.posix.getsockname(socket, &address.any, &socklen);

    const final_port = address.getPort();

    self.* = .{
        .arena = .init(allocator),
        .completion = .init(),
        .ref = .init(L, -1, undefined),
        .scheduler = scheduler,
        .socket = .initFd(socket),
        .handlers = handlers,
        .timer = .{
            .completion = .init(),
            .reset_completion = .init(),
        },
        .state = .{
            .port = final_port,
            .client_timeout = serve_info.clientTimeout orelse 10,
            .max_body_size = @min(serve_info.maxBodySize orelse 1_048_576, luaHelper.MAX_LUAU_SIZE),
            .max_connections = serve_info.maxConnections orelse 1024,
        },
    };

    try self.expandFreeSize(@min(
        if (self.state.max_connections > 0) self.state.max_connections else 128,
        128,
    ));

    self.startListen(&scheduler.loop);

    return 1;
}

const AsyncStopContext = struct {
    completion: xev.Completion,
    server: *Self,
    ref: Scheduler.ThreadRef,

    pub fn cancelComplete(
        ud: ?*AsyncStopContext,
        loop: *xev.Loop,
        c: *xev.Completion,
        _: xev.CancelError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        if (self.server.timer.active) {
            var timer: xev.Timer = xev.Timer.init() catch unreachable;
            timer.cancel(loop, &self.server.timer.completion, c, AsyncStopContext, self, timerCancelComplete);
        } else self.server.socket.close(loop, c, AsyncStopContext, self, complete);
        var node = self.server.state.list.first;
        while (node) |n| {
            const client: *ClientContext = @fieldParentPtr("node", n);

            switch (client.state.stage) {
                .receiving => jmp: {
                    if (client.websocket.ref.hasRef()) blk: {
                        client.websocket.ref.value.sendCloseFrame(loop, 1001) catch {
                            // failed to send close frame
                            break :blk;
                        };
                        break :jmp;
                    }
                    client.state.stage = .closing;
                    loop.cancel(
                        &client.completion,
                        &client.cancel_completion,
                        void,
                        null,
                        Scheduler.XevNoopCallback(xev.CancelError!void, .disarm),
                    );
                },
                .writing => client.state.stage = .closing,
                else => {},
            }

            node = n.next;
        }
        return .disarm;
    }

    pub fn timerCancelComplete(
        ud: ?*AsyncStopContext,
        loop: *xev.Loop,
        c: *xev.Completion,
        _: xev.CancelError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        self.server.socket.close(loop, c, AsyncStopContext, self, complete);
        return .disarm;
    }

    pub fn complete(
        ud: ?*AsyncStopContext,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const server = self.server;
        const L = self.ref.value;

        defer server.scheduler.completeAsync(self);
        defer self.ref.deref();

        if (server.state.stage == .shutdown and server.state.list.len == 0) {
            server.ref.deref(server.scheduler.global);
            server.state.stage = .dead;
        }

        _ = Scheduler.resumeState(L, null, 0) catch {};

        return .disarm;
    }
};

fn lua_stop(self: *Self, L: *VM.lua.State) !i32 {
    if (!self.state.stage.isShutdown()) {
        if (!L.isyieldable())
            return L.Zyielderror();
        const ptr = try self.scheduler.createAsyncCtx(AsyncStopContext);
        ptr.* = .{
            .completion = .init(),
            .server = self,
            .ref = .init(L),
        };
        self.scheduler.loop.cancel(
            &self.completion,
            &ptr.completion,
            AsyncStopContext,
            ptr,
            AsyncStopContext.cancelComplete,
        );
        self.state.stage = .shutdown;

        return L.yield(0);
    }
    return 0;
}

fn lua_getPort(self: *Self, L: *VM.lua.State) !i32 {
    L.pushinteger(self.state.port);
    return 1;
}

fn lua_isRunning(self: *Self, L: *VM.lua.State) !i32 {
    L.pushboolean(switch (self.state.stage) {
        .shutdown, .dead => false,
        else => true,
    });
    return 1;
}

pub const __namecall = MethodMap.CreateNamecallMap(Self, null, .{
    .{ "stop", lua_stop },
    .{ "getPort", lua_getPort },
    .{ "isRunning", lua_isRunning },
});

pub fn lua_load(L: *VM.lua.State) void {
    _ = L.Znewmetatable(@typeName(Self), .{
        .__namecall = __namecall,
        .__metatable = "Metatable is locked",
    });
    L.setreadonly(-1, true);
    L.pop(1);

    _ = L.Znewmetatable(@typeName(ClientWebSocket), .{
        .__namecall = ClientWebSocket.__namecall,
        .__metatable = "Metatable is locked",
    });
    L.setreadonly(-1, true);
    L.pop(1);
}
