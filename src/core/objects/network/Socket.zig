const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const tagged = @import("../../../tagged.zig");
const MethodMap = @import("../../utils/method_map.zig");
const luaHelper = @import("../../utils/luahelper.zig");

const Scheduler = @import("../../runtime/scheduler.zig");

const VM = luau.VM;

const Socket = @This();

const TAG_NET_SOCKET = tagged.Tags.get("NET_SOCKET").?;
pub fn PlatformSupported() bool {
    return switch (comptime builtin.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
}

const SocketRef = luaHelper.Ref(*Socket);

socket: std.posix.socket_t,
open: bool = true,
list: *Scheduler.CompletionLinkedList,

fn closesocket(socket: std.posix.socket_t) void {
    switch (comptime builtin.os.tag) {
        .windows => std.os.windows.closesocket(socket) catch unreachable,
        else => std.posix.close(socket),
    }
}

pub const LONGEST_ADDRESS = 108;
pub fn AddressToString(buf: []u8, address: std.net.Address) []const u8 {
    switch (address.any.family) {
        std.posix.AF.INET, std.posix.AF.INET6 => {
            const b = std.fmt.bufPrint(buf, "{}", .{address}) catch @panic("OutOfMemory");
            var iter = std.mem.splitBackwardsAny(u8, b, ":");
            _ = iter.first();
            return iter.rest();
        },
        else => {
            return std.fmt.bufPrint(buf, "{}", .{address}) catch @panic("OutOfMemory");
        },
    }
}

const AsyncSendContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .data = .{},
    },
    ref: Scheduler.ThreadRef,
    buffer: []u8,
    list: *Scheduler.CompletionLinkedList,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.WriteBuffer,
        w: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const len = w catch |err| {
            L.pushlstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        L.pushunsigned(@intCast(len));
        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }
};

const AsyncSendMsgContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .data = .{},
    },
    state: xev.UDP.State,
    ref: Scheduler.ThreadRef,
    buffer: []u8,
    list: *Scheduler.CompletionLinkedList,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: *xev.UDP.State,
        _: xev.UDP,
        _: xev.WriteBuffer,
        w: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const len = w catch |err| {
            L.pushlstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        L.pushunsigned(@intCast(len));
        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }
};

const AsyncRecvContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .data = .{},
    },
    ref: Scheduler.ThreadRef,
    buffer: []u8,
    list: *Scheduler.CompletionLinkedList,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const len = r catch |err| {
            L.pushlstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        L.Zpushbuffer(self.buffer[0..len]);

        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }
};

const AsyncRecvMsgContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .data = .{},
    },
    state: xev.UDP.State,
    ref: Scheduler.ThreadRef,
    buffer: []u8,
    list: *Scheduler.CompletionLinkedList,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: *xev.UDP.State,
        address: std.net.Address,
        _: xev.UDP,
        _: xev.ReadBuffer,
        r: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const allocator = luau.getallocator(L);
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer allocator.free(self.buffer);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const len = r catch |err| {
            L.pushlstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        L.createtable(0, 3);
        L.Zsetfield(-1, "family", address.any.family);
        L.Zsetfield(-1, "port", address.getPort());
        var buf: [LONGEST_ADDRESS]u8 = undefined;
        L.pushlstring(AddressToString(&buf, address));
        L.setfield(-2, "address");
        L.Zpushbuffer(self.buffer[0..len]);

        _ = Scheduler.resumeState(L, null, 2) catch {};

        return .disarm;
    }
};

const AsyncAcceptContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .data = .{},
    },
    ref: Scheduler.ThreadRef,
    list: *Scheduler.CompletionLinkedList,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        s: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        const socket = s catch |err| {
            L.pushlstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        push(
            L,
            switch (comptime builtin.os.tag) {
                .windows => @ptrCast(@alignCast(socket.fd)),
                .ios, .macos, .wasi => socket.fd,
                .linux => socket.fd(),
                else => @compileError("Unsupported OS"),
            },
        ) catch |err| {
            L.pushlstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };
        _ = Scheduler.resumeState(L, null, 1) catch {};

        return .disarm;
    }
};

const AsyncConnectContext = struct {
    completion: Scheduler.CompletionLinkedList.Node = .{
        .data = .{},
    },
    ref: Scheduler.ThreadRef,
    list: *Scheduler.CompletionLinkedList,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        c: xev.ConnectError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;

        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer self.ref.deref();
        defer self.list.remove(&self.completion);

        if (L.status() != .Yield)
            return .disarm;

        c catch |err| {
            L.pushlstring(@errorName(err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return .disarm;
        };

        _ = Scheduler.resumeState(L, null, 0) catch {};

        return .disarm;
    }
};

fn lua_send(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const buf = try L.Zcheckvalue([]const u8, 2, null);
    const offset = L.Loptunsigned(3, 0);

    if (offset >= buf.len)
        return L.Zerror("Offset is out of bounds");

    const input = try allocator.dupe(u8, buf[offset..]);
    errdefer allocator.free(input);

    const ptr = try scheduler.createAsyncCtx(AsyncSendContext);

    ptr.* = .{
        .buffer = input,
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
    };

    const socket = xev.TCP.initFd(self.socket);

    socket.write(
        &scheduler.loop,
        &ptr.completion.data,
        .{ .slice = buf },
        AsyncSendContext,
        ptr,
        AsyncSendContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_sendMsg(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const port = L.Lcheckunsigned(2);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");
    const address_str = try L.Zcheckvalue([:0]const u8, 3, null);
    const data = try L.Zcheckvalue([]const u8, 4, null);
    const offset = L.Loptunsigned(5, 0);
    if (offset >= data.len)
        return L.Zerror("Offset is out of bounds");

    const buf = try allocator.dupe(u8, data[offset..]);
    errdefer allocator.free(buf);

    const address = if (address_str.len <= 15)
        try std.net.Address.parseIp4(address_str, @intCast(port))
    else
        try std.net.Address.parseIp6(address_str, @intCast(port));

    const ptr = try scheduler.createAsyncCtx(AsyncSendMsgContext);

    ptr.* = .{
        .buffer = buf,
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
        .state = undefined,
    };

    const socket = xev.UDP.initFd(self.socket);

    socket.write(
        &scheduler.loop,
        &ptr.completion.data,
        &ptr.state,
        address,
        .{ .slice = buf },
        AsyncSendMsgContext,
        ptr,
        AsyncSendMsgContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_recv(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const size = L.Loptinteger(2, 8192);
    if (size > luaHelper.MAX_LUAU_SIZE)
        return L.Zerror("SizeTooLarge");

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const ptr = try scheduler.createAsyncCtx(AsyncRecvContext);

    ptr.* = .{
        .buffer = buf,
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
    };

    const socket = xev.TCP.initFd(self.socket);

    socket.read(
        &scheduler.loop,
        &ptr.completion.data,
        .{ .slice = buf },
        AsyncRecvContext,
        ptr,
        AsyncRecvContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_recvMsg(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const size = L.Loptinteger(2, 8192);
    if (size > luaHelper.MAX_LUAU_SIZE)
        return L.Zerror("SizeTooLarge");

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const ptr = try scheduler.createAsyncCtx(AsyncRecvMsgContext);

    ptr.* = .{
        .buffer = buf,
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
        .state = undefined,
    };

    const socket = xev.UDP.initFd(self.socket);

    socket.read(
        &scheduler.loop,
        &ptr.completion.data,
        &ptr.state,
        .{ .slice = buf },
        AsyncRecvMsgContext,
        ptr,
        AsyncRecvMsgContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_accept(self: *Socket, L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);

    const ptr = try scheduler.createAsyncCtx(AsyncAcceptContext);

    ptr.* = .{
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
    };

    const socket = xev.TCP.initFd(self.socket);

    socket.accept(
        &scheduler.loop,
        &ptr.completion.data,
        AsyncAcceptContext,
        ptr,
        AsyncAcceptContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_connect(self: *Socket, L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);

    const address_str = try L.Zcheckvalue([:0]const u8, 2, null);
    const port = L.Lcheckunsigned(3);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");

    const address = if (address_str.len <= 15)
        try std.net.Address.parseIp4(address_str, @intCast(port))
    else
        try std.net.Address.parseIp6(address_str, @intCast(port));

    const ptr = try scheduler.createAsyncCtx(AsyncConnectContext);

    const socket = xev.TCP.initFd(self.socket);

    ptr.* = .{
        .ref = Scheduler.ThreadRef.init(L),
        .list = self.list,
    };

    socket.connect(
        &scheduler.loop,
        &ptr.completion.data,
        address,
        AsyncConnectContext,
        ptr,
        AsyncConnectContext.complete,
    );
    self.list.append(&ptr.completion);

    return L.yield(0);
}

fn lua_listen(self: *Socket, L: *VM.lua.State) !i32 {
    const backlog = L.Loptunsigned(2, 128);
    if (backlog > std.math.maxInt(u31))
        return L.Zerror("BacklogTooLarge");
    try std.posix.listen(self.socket, @intCast(backlog));
    return 0;
}

fn lua_bindIp(self: *Socket, L: *VM.lua.State) !i32 {
    const address_ip = try L.Zcheckvalue([:0]const u8, 2, null);
    const port = L.Lcheckunsigned(3);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");
    const address = if (address_ip.len <= 15)
        try std.net.Address.parseIp4(address_ip, @intCast(port))
    else
        try std.net.Address.parseIp6(address_ip, @intCast(port));
    _ = try std.posix.bind(self.socket, &address.any, address.getOsSockLen());
    return 0;
}

fn lua_getName(self: *Socket, L: *VM.lua.State) !i32 {
    var address: std.net.Address = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    try std.posix.getsockname(self.socket, &address.any, &len);
    L.createtable(0, 3);
    L.Zsetfield(-1, "family", address.any.family);
    L.Zsetfield(-1, "port", address.getPort());
    var buf: [LONGEST_ADDRESS]u8 = undefined;
    L.pushlstring(AddressToString(&buf, address));
    L.setfield(-2, "address");
    return 1;
}

fn lua_setOption(self: *Socket, L: *VM.lua.State) !i32 {
    const level = try L.Zcheckvalue(i32, 2, null);
    const optname = try L.Zcheckvalue(u32, 3, null);
    const value = switch (L.typeOf(4)) {
        .Boolean => &std.mem.toBytes(@as(c_int, 1)),
        .Buffer, .String => try L.Zcheckvalue([]const u8, 4, null),
        else => return L.Zerror("Invalid value type"),
    };
    try std.posix.setsockopt(
        self.socket,
        level,
        optname,
        value,
    );
    return 0;
}

pub const AsyncCloseContext = struct {
    completion: xev.Completion = .{},
    ref: Scheduler.ThreadRef,

    const This = @This();

    pub fn complete(
        ud: ?*This,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.TCP,
        _: xev.CloseError!void,
    ) xev.CallbackAction {
        const self = ud orelse unreachable;
        const L = self.ref.value;
        const scheduler = Scheduler.getScheduler(L);

        defer scheduler.completeAsync(self);
        defer self.ref.deref();

        if (L.status() != .Yield)
            return .disarm;

        _ = Scheduler.resumeState(L, null, 0) catch {};
        return .disarm;
    }
};

fn lua_close(self: *Socket, L: *VM.lua.State) !i32 {
    if (self.open) {
        self.open = false;
        const scheduler = Scheduler.getScheduler(L);
        const socket = xev.TCP.initFd(self.socket);

        const ptr = try scheduler.createAsyncCtx(AsyncCloseContext);
        ptr.* = .{
            .ref = Scheduler.ThreadRef.init(L),
        };

        switch (comptime builtin.os.tag) {
            .windows => _ = std.os.windows.kernel32.CancelIoEx(self.socket, null),
            else => {
                var node = self.list.first;
                while (node) |n| {
                    scheduler.cancelAsyncTask(&n.data);
                    node = n.next;
                }
            },
        }

        socket.close(
            &scheduler.loop,
            &ptr.completion,
            AsyncCloseContext,
            ptr,
            AsyncCloseContext.complete,
        );

        return L.yield(0);
    }
    return 0;
}

fn lua_getOpen(self: *Socket, L: *VM.lua.State) !i32 {
    L.pushboolean(self.open);
    return 1;
}

fn before_method(self: *Socket, L: *VM.lua.State) !void {
    if (!self.open)
        return L.Zerror("SocketClosed");
}

const __index = MethodMap.CreateStaticIndexMap(Socket, TAG_NET_SOCKET, .{
    .{ "send", MethodMap.WithFn(Socket, lua_send, before_method) },
    .{ "sendMsg", MethodMap.WithFn(Socket, lua_sendMsg, before_method) },
    .{ "recv", MethodMap.WithFn(Socket, lua_recv, before_method) },
    .{ "recvMsg", MethodMap.WithFn(Socket, lua_recvMsg, before_method) },
    .{ "accept", MethodMap.WithFn(Socket, lua_accept, before_method) },
    .{ "connect", MethodMap.WithFn(Socket, lua_connect, before_method) },
    .{ "listen", MethodMap.WithFn(Socket, lua_listen, before_method) },
    .{ "bindIp", MethodMap.WithFn(Socket, lua_bindIp, before_method) },
    .{ "getName", MethodMap.WithFn(Socket, lua_getName, before_method) },
    .{ "setOption", MethodMap.WithFn(Socket, lua_setOption, before_method) },
    .{ "close", lua_close },
    .{ "isOpen", lua_getOpen },
});

pub fn __dtor(L: *VM.lua.State, self: *Socket) void {
    const allocator = luau.getallocator(L);
    if (self.open)
        closesocket(self.socket);
    allocator.destroy(self.list);
}

pub inline fn load(L: *VM.lua.State) void {
    _ = L.Znewmetatable(@typeName(@This()), .{
        .__metatable = "Metatable is locked",
        .__type = "SocketHandle",
    });
    __index(L, -1);
    L.setreadonly(-1, true);
    L.setuserdatametatable(TAG_NET_SOCKET);
    L.setuserdatadtor(Socket, TAG_NET_SOCKET, __dtor);
}

pub fn push(L: *VM.lua.State, value: std.posix.socket_t) !void {
    const allocator = luau.getallocator(L);
    const self = L.newuserdatataggedwithmetatable(Socket, TAG_NET_SOCKET);
    const list = try allocator.create(Scheduler.CompletionLinkedList);
    list.* = .{};
    self.* = .{
        .socket = value,
        .list = list,
    };
}
