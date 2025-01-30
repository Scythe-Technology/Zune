const std = @import("std");
const aio = @import("aio");
const luau = @import("luau");
const builtin = @import("builtin");

const tagged = @import("../../../tagged.zig");
const method_map = @import("../../utils/method_map.zig");
const luaHelper = @import("../../utils/luahelper.zig");

const Scheduler = @import("../../runtime/scheduler.zig");

const VM = luau.VM;

const Socket = @This();

socket: std.posix.socket_t,
open: bool = true,

fn closesocket(socket: std.posix.socket_t) void {
    switch (builtin.os.tag) {
        .windows => std.os.windows.closesocket(socket) catch unreachable,
        else => std.posix.close(socket),
    }
}

pub fn __index(L: *VM.lua.State) i32 {
    L.Lchecktype(1, .Userdata);
    const ptr = L.touserdatatagged(Socket, 1, tagged.NET_SOCKET) orelse return 0;
    const index = L.Lcheckstring(2);

    if (std.mem.eql(u8, index, "open")) {
        L.pushboolean(ptr.open);
        return 1;
    }

    return 0;
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

fn IOContentCompletion(error_type: type, comptime buffer: bool) type {
    return struct {
        buffer: []u8,
        used: usize = 0,
        out_err: error_type = error.Unexpected,
        // lua data
        lua_socket: *Socket,
        lua_ref: ?i32,

        const Self = @This();

        pub fn completion(self: *Self, L: *VM.lua.State, _: *Scheduler, failed: bool) void {
            defer self.free(L);
            switch (L.status()) {
                .Ok, .Yield => {},
                else => return,
            }
            if (failed) {
                switch (self.out_err) {
                    error.Unexpected => self.lua_socket.open = false,
                    else => {},
                }
                L.pushlstring(@errorName(self.out_err));
                _ = Scheduler.resumeStateError(L, null) catch {};
                return;
            }

            if (buffer)
                L.Zpushbuffer(self.buffer[0..self.used])
            else
                L.pushunsigned(@intCast(self.used));
            _ = Scheduler.resumeState(L, null, 1) catch {};
        }

        pub fn free(self: *Self, L: *VM.lua.State) void {
            const allocator = luau.getallocator(L);
            defer allocator.destroy(self);
            allocator.free(self.buffer);
            if (self.lua_ref) |ref|
                L.unref(ref);
        }
    };
}

fn IOContentMsgCompletion(error_type: type, comptime recieve: bool) type {
    return struct {
        buffer: []u8,
        msghdr: if (recieve) aio.posix.msghdr else aio.posix.msghdr_const,
        iov: switch (builtin.os.tag) {
            .windows => [1]std.os.windows.ws2_32.WSABUF,
            else => if (recieve) [1]std.posix.iovec else [1]std.posix.iovec_const,
        } = undefined,
        address: std.posix.sockaddr,
        used: usize = 0,
        out_err: error_type = error.Unexpected,
        // lua data
        lua_socket: *Socket,
        lua_ref: ?i32,

        const Self = @This();

        pub fn completion(self: *Self, L: *VM.lua.State, _: *Scheduler, failed: bool) void {
            defer self.free(L);
            switch (L.status()) {
                .Ok, .Yield => {},
                else => return,
            }
            if (failed) {
                switch (self.out_err) {
                    error.Unexpected => self.lua_socket.open = false,
                    else => {},
                }
                L.pushlstring(@errorName(self.out_err));
                _ = Scheduler.resumeStateError(L, null) catch {};
                return;
            }

            const address = std.net.Address{
                .any = self.address,
            };

            if (recieve) {
                L.createtable(0, 3);
                L.Zsetfield(-1, "family", address.any.family);
                L.Zsetfield(-1, "port", address.getPort());
                var buf: [LONGEST_ADDRESS]u8 = undefined;
                L.pushlstring(AddressToString(&buf, address));
                L.setfield(-2, "address");
                L.Zpushbuffer(self.buffer[0..self.used]);
            } else L.pushunsigned(@intCast(self.used));
            _ = Scheduler.resumeState(L, null, if (recieve) 2 else 1) catch {};
        }

        pub fn free(self: *Self, L: *VM.lua.State) void {
            const allocator = luau.getallocator(L);
            defer allocator.destroy(self);
            allocator.free(self.buffer);
            if (self.lua_ref) |ref|
                L.unref(ref);
        }
    };
}

const AcceptContext = struct {
    socket: std.posix.socket_t,
    out_err: aio.Accept.Error = error.Unexpected,
    // lua data
    lua_socket: *Socket,
    lua_ref: ?i32,

    const Self = @This();

    pub fn completion(self: *Self, L: *VM.lua.State, _: *Scheduler, failed: bool) void {
        defer self.free(L);
        switch (L.status()) {
            .Ok, .Yield => {},
            else => return,
        }
        if (failed) {
            switch (self.out_err) {
                error.Unexpected => self.lua_socket.open = false,
                else => {},
            }
            L.pushlstring(@errorName(self.out_err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return;
        }

        push(L, self.socket);
        _ = Scheduler.resumeState(L, null, 1) catch {};
    }
    pub fn free(self: *Self, L: *VM.lua.State) void {
        const allocator = luau.getallocator(L);
        defer allocator.destroy(self);
        if (self.lua_ref) |ref|
            L.unref(ref);
    }
};

const ConnectContext = struct {
    address: std.posix.sockaddr,
    out_err: aio.Connect.Error = error.Unexpected,
    // lua data
    lua_socket: *Socket,
    lua_ref: ?i32,

    const Self = @This();

    pub fn completion(self: *Self, L: *VM.lua.State, _: *Scheduler, failed: bool) void {
        defer self.free(L);
        switch (L.status()) {
            .Ok, .Yield => {},
            else => return,
        }
        if (failed) {
            switch (self.out_err) {
                error.Unexpected => self.lua_socket.open = false,
                else => {},
            }
            L.pushlstring(@errorName(self.out_err));
            _ = Scheduler.resumeStateError(L, null) catch {};
            return;
        }

        _ = Scheduler.resumeState(L, null, 0) catch {};
    }
    pub fn free(self: *Self, L: *VM.lua.State) void {
        const allocator = luau.getallocator(L);
        defer allocator.destroy(self);
        if (self.lua_ref) |ref|
            L.unref(ref);
    }
};

fn sendAsync(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const buf = if (L.typeOf(2) == .Buffer) L.Lcheckbuffer(2) else L.Lcheckstring(2);
    const offset = L.Loptunsigned(3, 0);

    if (offset >= buf.len)
        return L.Zerror("Offset is out of bounds");

    const input = try allocator.dupe(u8, buf[offset..]);
    errdefer allocator.free(input);

    const SendIO = IOContentCompletion(aio.Send.Error, false);
    const ptr = try allocator.create(SendIO);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .buffer = input,
        .lua_socket = self,
        .lua_ref = L.ref(1),
    };

    try scheduler.queueIoCallbackCtx(SendIO, ptr, L, aio.op(.send, .{
        .buffer = buf,
        .socket = self.socket,
        .out_written = &ptr.used,
        .out_error = &ptr.out_err,
    }, .unlinked), SendIO.completion);

    return L.yield(0);
}

fn sendMsgAsync(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const port = L.Lcheckunsigned(2);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");
    const address_str = L.Lcheckstring(3);
    const data = if (L.typeOf(4) == .Buffer) L.Lcheckbuffer(4) else L.Lcheckstring(4);
    const offset = L.Loptunsigned(5, 0);
    if (offset >= data.len)
        return L.Zerror("Offset is out of bounds");

    const buf = try allocator.dupe(u8, data[offset..]);
    errdefer allocator.free(buf);

    const SendMsgIO = IOContentMsgCompletion(aio.SendMsg.Error, false);
    const ptr = try allocator.create(SendMsgIO);
    errdefer allocator.destroy(ptr);

    const address = if (address_str.len <= 15)
        try std.net.Address.parseIp4(address_str, @intCast(port))
    else
        try std.net.Address.parseIp6(address_str, @intCast(port));

    ptr.* = .{
        .buffer = buf,
        .address = address.any,
        .msghdr = switch (builtin.os.tag) {
            .windows => std.os.windows.ws2_32.WSAMSG_const{
                .name = &ptr.address,
                .namelen = @sizeOf(std.posix.sockaddr),
                .lpBuffers = &ptr.iov,
                .dwBufferCount = 1,
                .Control = .{ .buf = undefined, .len = 0 },
                .dwFlags = 0,
            },
            else => aio.posix.msghdr_const{
                .name = &ptr.address,
                .namelen = @sizeOf(std.posix.sockaddr),
                .iov = &ptr.iov,
                .iovlen = 1,
                .flags = 0,
                .control = null,
                .controllen = 0,
            },
        },
        .iov = switch (builtin.os.tag) {
            .windows => [1]std.os.windows.ws2_32.WSABUF{.{ .buf = buf.ptr, .len = data.len }},
            else => [1]std.posix.iovec_const{.{ .base = buf.ptr, .len = data.len }},
        },
        .lua_socket = self,
        .lua_ref = L.ref(1),
    };

    try scheduler.queueIoCallbackCtx(SendMsgIO, ptr, L, aio.op(.send_msg, .{
        .socket = self.socket,
        .msg = &ptr.msghdr,
        .out_written = &ptr.used,
        .out_error = &ptr.out_err,
    }, .unlinked), SendMsgIO.completion);

    return L.yield(0);
}

fn recvAsync(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const size = L.Loptinteger(2, 8192);
    if (size > luaHelper.MAX_LUAU_SIZE)
        return L.Zerror("SizeTooLarge");

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const ReceiveIO = IOContentCompletion(aio.Recv.Error, true);
    const ptr = try allocator.create(ReceiveIO);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .buffer = buf,
        .lua_socket = self,
        .lua_ref = L.ref(1),
    };

    try scheduler.queueIoCallbackCtx(ReceiveIO, ptr, L, aio.op(.recv, .{
        .buffer = buf,
        .socket = self.socket,
        .out_read = &ptr.used,
        .out_error = &ptr.out_err,
    }, .unlinked), ReceiveIO.completion);

    return L.yield(0);
}

fn recvMsgAsync(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);
    const size = L.Loptinteger(2, 8192);
    if (size > luaHelper.MAX_LUAU_SIZE)
        return L.Zerror("SizeTooLarge");

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const ReceiveMsgIO = IOContentMsgCompletion(aio.RecvMsg.Error, true);
    const ptr = try allocator.create(ReceiveMsgIO);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .buffer = buf,
        .address = undefined,
        .msghdr = switch (builtin.os.tag) {
            .windows => std.os.windows.ws2_32.WSAMSG{
                .name = &ptr.address,
                .namelen = @sizeOf(std.posix.sockaddr),
                .lpBuffers = &ptr.iov,
                .dwBufferCount = 1,
                .Control = .{ .buf = undefined, .len = 0 },
                .dwFlags = 0,
            },
            else => aio.posix.msghdr{
                .name = &ptr.address,
                .namelen = @sizeOf(std.posix.sockaddr),
                .iov = &ptr.iov,
                .iovlen = 1,
                .flags = 0,
                .control = null,
                .controllen = 0,
            },
        },
        .iov = switch (builtin.os.tag) {
            .windows => [1]std.os.windows.ws2_32.WSABUF{.{ .buf = buf.ptr, .len = @intCast(size) }},
            else => [1]std.posix.iovec{.{ .base = buf.ptr, .len = @intCast(size) }},
        },
        .lua_socket = self,
        .lua_ref = L.ref(1),
    };

    try scheduler.queueIoCallbackCtx(ReceiveMsgIO, ptr, L, aio.op(.recv_msg, .{
        .socket = self.socket,
        .out_msg = &ptr.msghdr,
        .out_read = &ptr.used,
        .out_error = &ptr.out_err,
    }, .unlinked), ReceiveMsgIO.completion);

    return L.yield(0);
}

fn acceptAsync(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    const ptr = try allocator.create(AcceptContext);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .socket = undefined,
        .lua_socket = self,
        .lua_ref = L.ref(1),
    };

    try scheduler.queueIoCallbackCtx(AcceptContext, ptr, L, aio.op(.accept, .{
        .socket = self.socket,
        .out_socket = &ptr.socket,
        .out_error = &ptr.out_err,
    }, .unlinked), AcceptContext.completion);

    return L.yield(0);
}

fn connectAsync(self: *Socket, L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    const address_str = L.Lcheckstring(2);
    const port = L.Lcheckunsigned(3);
    if (port > std.math.maxInt(u16))
        return L.Zerror("PortOutOfRange");

    const address = if (address_str.len <= 15)
        try std.net.Address.parseIp4(address_str, @intCast(port))
    else
        try std.net.Address.parseIp6(address_str, @intCast(port));

    const ptr = try allocator.create(ConnectContext);
    errdefer allocator.destroy(ptr);

    ptr.* = .{
        .address = address.any,
        .lua_socket = self,
        .lua_ref = L.ref(1),
    };

    try scheduler.queueIoCallbackCtx(ConnectContext, ptr, L, aio.op(.connect, .{
        .socket = self.socket,
        .addr = &ptr.address,
        .addrlen = @sizeOf(std.posix.sockaddr),
        .out_error = &ptr.out_err,
    }, .unlinked), ConnectContext.completion);

    return L.yield(0);
}

fn listen(self: *Socket, L: *VM.lua.State) !i32 {
    if (!self.open)
        return L.Zerror("SocketClosed");
    const backlog = L.Loptunsigned(2, 128);
    if (backlog > std.math.maxInt(u31))
        return L.Zerror("BacklogTooLarge");
    try std.posix.listen(self.socket, @intCast(backlog));
    return 0;
}

fn bindIp(self: *Socket, L: *VM.lua.State) !i32 {
    if (!self.open)
        return L.Zerror("SocketClosed");
    const address_ip = L.Lcheckstring(2);
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

fn getName(self: *Socket, L: *VM.lua.State) !i32 {
    if (!self.open)
        return L.Zerror("SocketClosed");
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

fn setOption(self: *Socket, L: *VM.lua.State) !i32 {
    if (!self.open)
        return L.Zerror("SocketClosed");
    const level = L.Lcheckinteger(2);
    const optname = L.Lcheckunsigned(3);
    const value = switch (L.typeOf(4)) {
        .Boolean => &std.mem.toBytes(@as(c_int, 1)),
        .Buffer => L.Lcheckbuffer(4),
        .String => L.Lcheckstring(4),
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

fn close(self: *Socket, L: *VM.lua.State) !i32 {
    if (self.open) {
        self.open = false;
        const scheduler = Scheduler.getScheduler(L);
        try scheduler.queueIoCallback(L, aio.op(.close_socket, .{
            .socket = self.socket,
        }, .unlinked), Scheduler.asyncIoResumeState);
        return L.yield(0);
    }
    return 0;
}

fn before_method(self: *Socket, L: *VM.lua.State) !void {
    if (!self.open)
        return L.Zerror("SocketClosed");
}

const __namecall = method_map.CreateNamecallMap(Socket, before_method, .{
    .{ "sendAsync", sendAsync },
    .{ "sendMsgAsync", sendMsgAsync },
    .{ "recvAsync", recvAsync },
    .{ "recvMsgAsync", recvMsgAsync },
    .{ "acceptAsync", acceptAsync },
    .{ "connectAsync", connectAsync },
    .{ "listen", listen },
    .{ "bindIp", bindIp },
    .{ "getName", getName },
    .{ "setOption", setOption },
    .{ "close", close },
});

pub fn __dtor(L: *VM.lua.State, ptr: *Socket) void {
    _ = L;
    if (ptr.open)
        closesocket(ptr.socket);
}

pub inline fn load(L: *VM.lua.State) void {
    _ = L.Lnewmetatable(@typeName(@This()));

    L.Zsetfieldfn(-1, luau.Metamethods.index, __index); // metatable.__index
    L.Zsetfieldfn(-1, luau.Metamethods.namecall, __namecall); // metatable.__namecall

    L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");

    L.setuserdatametatable(tagged.NET_SOCKET, -1);
    L.setuserdatadtor(Socket, tagged.NET_SOCKET, __dtor);
}

pub fn push(L: *VM.lua.State, value: std.posix.socket_t) void {
    const ptr = L.newuserdatataggedwithmetatable(Socket, tagged.NET_SOCKET);
    ptr.* = .{
        .socket = value,
    };
}
