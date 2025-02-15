const std = @import("std");
const luau = @import("luau");

const Common = @import("common.zig");

const Scheduler = @import("../../runtime/scheduler.zig");

const VM = luau.VM;

const context = Common.context;
const prepRefType = Common.prepRefType;

const MAX_SOCKETS = 512;

const TCPClient = struct {
    const Self = @This();

    ref: i32,
    stream: std.net.Stream,
    handlers: LuaMeta.Handlers,
    stopped: bool,

    pub const LuaMeta = struct {
        pub const META = "net_tcp_client_instance";
        pub fn __index(L: *VM.lua.State) !i32 {
            try L.Zchecktype(1, .Userdata);
            const self = L.touserdata(Self, 1) orelse unreachable;

            const arg = L.Lcheckstring(2);

            // TODO: prob should switch to static string map
            if (std.mem.eql(u8, arg, "stopped")) {
                L.pushboolean(self.stopped);
                return 1;
            }
            return 0;
        }

        pub fn __namecall(L: *VM.lua.State) !i32 {
            try L.Zchecktype(1, .Userdata);
            const self = L.touserdata(Self, 1) orelse unreachable;

            const namecall = L.namecallstr() orelse return 0;

            // TODO: prob should switch to static string map
            if (std.mem.eql(u8, namecall, "stop")) {
                if (self.stopped)
                    return 0;
                self.stopped = true;
                return 0;
            } else if (std.mem.eql(u8, namecall, "send")) {
                if (self.stopped)
                    return 0;
                const data = try L.Zcheckvalue([]const u8, 2, null);
                self.stream.writeAll(data) catch |err| {
                    self.stopped = true;
                    return err;
                };
                return 0;
            } else return L.Zerrorf("Unknown method: {s}", .{namecall});
            return 0;
        }

        pub const Handlers = struct {
            message: ?i32,
            close: ?i32,
        };
    };

    pub fn update(ctx: *Self, L: *VM.lua.State, _: *Scheduler) Scheduler.TaskResult {
        if (ctx.stopped)
            return .Stop;

        var fds: [1]context.spollfd = .{.{
            .fd = ctx.stream.handle,
            .events = context.POLLIN,
            .revents = 0,
        }};

        const nums = context.spoll(&fds, 1) catch std.debug.panic("Bad poll (1)", .{});
        if (nums == 0)
            return .Continue;
        if (nums < 0)
            std.debug.panic("Bad poll (2)", .{});

        var buf: [8192]u8 = undefined;
        const read = ctx.stream.read(&buf) catch |err| {
            std.debug.print("Tcp Error: {}\n", .{err});
            return .Stop;
        };
        if (read == 0)
            return .Stop;
        const bytes: []const u8 = buf[0..read];
        if (ctx.handlers.message) |fnRef| {
            if (!prepRefType(.Function, L, fnRef))
                return .Stop;
            if (!prepRefType(.Userdata, L, ctx.ref)) {
                L.pop(1);
                return .Stop;
            }

            const thread = L.newthread();
            L.xpush(thread, -3); // push: Function
            L.xpush(thread, -2); // push: Userdata
            thread.pushlstring(bytes);
            L.pop(3); // drop thread, function & userdata

            _ = Scheduler.resumeState(thread, L, 2) catch {};
            return .ContinueFast;
        }
        return .Continue;
    }

    pub fn dtor(ctx: *Self, L: *VM.lua.State, _: *Scheduler) void {
        ctx.stream.close();
        defer L.unref(ctx.ref);
        ctx.stopped = true;
        if (ctx.handlers.close) |ref| jmp: {
            defer L.unref(ref);
            if (!prepRefType(.Function, L, ref))
                break :jmp;
            if (!prepRefType(.Userdata, L, ctx.ref)) {
                L.pop(1);
                break :jmp;
            }

            const thread = L.newthread();
            L.xpush(thread, -3); // push: Function
            L.xpush(thread, -2); // push: Userdata
            L.pop(3); // drop thread, function & userdata

            _ = Scheduler.resumeState(thread, L, 1) catch {};

            ctx.handlers.close = null;
        }
        if (ctx.handlers.message) |ref|
            L.unref(ref);
        ctx.handlers.message = null;
    }
};

pub fn lua_tcp_client(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    var address_ip: []const u8 = "";
    var port: u16 = 0;

    var open_ref: ?i32 = null;
    defer if (open_ref) |ref| L.unref(ref);
    var data_ref: ?i32 = null;
    errdefer if (data_ref) |ref| L.unref(ref);
    var close_ref: ?i32 = null;
    errdefer if (close_ref) |ref| L.unref(ref);

    try L.Zchecktype(1, .Table);

    const addressType = L.getfield(1, "address");
    if (addressType != .String)
        return L.Zerror("Field 'address' must be a string");
    address_ip = L.tostring(-1) orelse unreachable;
    L.pop(1);

    const portType = L.getfield(1, "port");
    if (portType != .Number)
        return L.Zerror("Field 'port' must be a number");
    const lport = L.tointeger(-1) orelse unreachable;
    if (lport < 0 and lport > 65535)
        return L.Zerror("Field 'port' must be between 0 and 65535");
    port = @truncate(@as(u32, @intCast(lport)));
    L.pop(1);

    const openType = L.getfield(1, "open");
    if (!openType.isnoneornil()) {
        if (openType != .Function)
            return L.Zerror("Field 'open' must be a function");
        open_ref = L.ref(-1) orelse unreachable;
    }
    L.pop(1);

    const dataType = L.getfield(1, "data");
    if (!dataType.isnoneornil()) {
        if (dataType != .Function)
            return L.Zerror("Field 'data' must be a function");
        data_ref = L.ref(-1) orelse unreachable;
    }
    L.pop(1);

    const closeType = L.getfield(1, "close");
    if (!closeType.isnoneornil()) {
        if (closeType != .Function)
            return L.Zerror("Field 'close' must be a function");
        close_ref = L.ref(-1) orelse unreachable;
    }
    L.pop(1);

    const allocator = luau.getallocator(L);

    const stream = std.net.tcpConnectToHost(allocator, address_ip, port) catch |err| {
        std.debug.print("Tcp Error: {}\n", .{err});
        return err;
    };

    const self = L.newuserdata(TCPClient);

    self.* = .{
        .ref = L.ref(-1) orelse unreachable,
        .stream = stream,
        .stopped = false,
        .handlers = .{
            .message = data_ref,
            .close = close_ref,
        },
    };

    if (L.Lgetmetatable(TCPClient.LuaMeta.META) == .Table) {
        _ = L.setmetatable(-2);
    } else std.debug.panic("InternalError (UDP Metatable not initialized)", .{});

    scheduler.addTask(TCPClient, self, L, TCPClient.update, TCPClient.dtor);

    if (open_ref) |ref| {
        if (prepRefType(.Function, L, ref)) {
            const thread = L.newthread();
            L.xpush(thread, -2); // push: Function
            L.xpush(thread, -3); // push: Userdata
            L.pop(2); // drop thread, function
            scheduler.deferThread(thread, L, 1);
        }
    }

    return 1;
}

const TCPServer = struct {
    const Self = @This();

    ref: i32,
    server: std.net.Server,
    handlers: LuaMeta.Handlers,
    stopped: bool,

    connections: []?Connection,
    fds: []context.spollfd,

    pub const Connection = struct {
        id: usize,
        ref: i32,
        server: *Self,
        conn: std.net.Server.Connection,
        connected: bool,

        pub const LuaMeta = struct {
            pub const META = "net_tcp_server_connection_instance";
            pub fn __namecall(L: *VM.lua.State) !i32 {
                try L.Zchecktype(1, .Userdata);
                const self = L.touserdata(Connection, 1) orelse unreachable;
                if (!self.connected)
                    return 0;

                const namecall = L.namecallstr() orelse return 0;

                // TODO: prob should switch to static string map
                if (std.mem.eql(u8, namecall, "send")) {
                    const data = try L.Zcheckvalue([]const u8, 2, null);
                    self.conn.stream.writeAll(data) catch |err| {
                        std.debug.print("Error sending data to client: {}\n", .{err});
                        return err;
                    };
                    return 0;
                } else if (std.mem.eql(u8, namecall, "stop")) {
                    self.server.closeConnection(L, self.id);
                    return 0;
                } else return L.Zerrorf("Unknown method: {s}", .{namecall});
                return 0;
            }

            pub const Handlers = struct {
                open: ?i32,
                message: ?i32,
                close: ?i32,
            };
        };
    };

    pub const LuaMeta = struct {
        pub const META = "net_tcp_server_instance";
        pub fn __index(L: *VM.lua.State) !i32 {
            try L.Zchecktype(1, .Userdata);
            const self = L.touserdata(Self, 1) orelse unreachable;

            const arg = L.Lcheckstring(2);

            // TODO: prob should switch to static string map
            if (std.mem.eql(u8, arg, "stopped")) {
                L.pushboolean(self.stopped);
                return 1;
            }
            return 0;
        }

        pub fn __namecall(L: *VM.lua.State) !i32 {
            try L.Zchecktype(1, .Userdata);
            const self = L.touserdata(Self, 1) orelse unreachable;

            const namecall = L.namecallstr() orelse return 0;

            // TODO: prob should switch to static string map
            if (std.mem.eql(u8, namecall, "stop")) {
                if (self.stopped)
                    return 0;
                self.stopped = true;
                return 0;
            } else return L.Zerrorf("Unknown method: {s}", .{namecall});
            return 0;
        }

        pub const Handlers = struct {
            open: ?i32,
            message: ?i32,
            close: ?i32,
        };
    };

    pub fn closeConnection(ctx: *Self, L: *VM.lua.State, id: usize) void {
        if (ctx.connections[id]) |*connection| {
            connection.connected = false;
            defer {
                ctx.fds[connection.id].fd = context.INVALID_SOCKET;
                connection.conn.stream.close();
                L.unref(connection.ref);
                ctx.connections[id] = null;
            }
            if (ctx.handlers.close) |fnRef| {
                if (!prepRefType(.Function, L, fnRef))
                    return;
                if (!prepRefType(.Userdata, L, connection.ref)) {
                    L.pop(1);
                    return;
                }

                const thread = L.newthread();
                L.xpush(thread, -3); // push: Function
                L.xpush(thread, -2); // push: Userdata
                L.pop(3); // drop thread, function & userdata

                _ = Scheduler.resumeState(thread, L, 1) catch {};
            }
        }
    }

    pub fn update(ctx: *Self, L: *VM.lua.State, _: *Scheduler) Scheduler.TaskResult {
        if (ctx.stopped)
            return .Stop;

        const server = &ctx.server;
        var fds = ctx.fds;
        const connections = ctx.connections;

        var nums = context.spoll(fds, 1) catch std.debug.panic("Bad poll (1)", .{});
        if (nums == 0)
            return .Continue;
        if (nums < 0)
            std.debug.panic("Bad poll (2)", .{});

        for (1..MAX_SOCKETS) |i| {
            if (nums == 0)
                break;
            const sockfd = fds[i];
            if (sockfd.fd == context.INVALID_SOCKET)
                continue;
            defer if (sockfd.revents != 0) {
                nums -= 1;
            };
            if (sockfd.revents & (context.POLLIN) != 0) {
                if (connections[i]) |connection| {
                    var bytes: [8192]u8 = undefined;
                    const read_len = connection.conn.stream.read(&bytes) catch |err| {
                        std.debug.print("Error reading from client: {}\n", .{err});
                        ctx.closeConnection(L, i);
                        continue;
                    };
                    if (read_len == 0) {
                        ctx.closeConnection(L, i);
                        continue;
                    }
                    if (ctx.handlers.message) |fnRef| {
                        if (!prepRefType(.Function, L, fnRef))
                            continue;
                        if (!prepRefType(.Userdata, L, connection.ref)) {
                            L.pop(1);
                            continue;
                        }

                        const thread = L.newthread();
                        L.xpush(thread, -3); // push: Function
                        L.xpush(thread, -2); // push: Userdata
                        thread.pushlstring(bytes[0..read_len]);
                        L.pop(3); // drop thread, function & userdata

                        _ = Scheduler.resumeState(thread, L, 2) catch {};
                    }
                }
            } else if (sockfd.revents & (context.POLLNVAL | context.POLLERR | context.POLLHUP) != 0) {
                ctx.closeConnection(L, i);
            }
        }
        if (fds[0].revents & context.POLLIN != 0 and nums > 0) {
            const client = server.accept() catch |err| {
                std.debug.print("Error accepting client: {}\n", .{err});
                return .ContinueFast;
            };
            for (1..MAX_SOCKETS) |i| {
                if (fds[i].fd == context.INVALID_SOCKET) {
                    fds[i].fd = client.stream.handle;
                    const ptr = L.newuserdata(Connection);
                    const ref = L.ref(-1) orelse unreachable;
                    ptr.* = .{
                        .id = i,
                        .ref = ref,
                        .server = ctx,
                        .conn = client,
                        .connected = true,
                    };
                    connections[i] = ptr.*;
                    if (L.Lgetmetatable(TCPServer.Connection.LuaMeta.META) == .Table) {
                        _ = L.setmetatable(-2);
                    } else std.debug.panic("InternalError (TCPServer Metatable not initialized)", .{});
                    if (ctx.handlers.open) |fnRef| {
                        if (!prepRefType(.Function, L, fnRef))
                            continue;

                        const thread = L.newthread();
                        L.xpush(thread, -2); // push: Function
                        L.xpush(thread, -3); // push: Userdata
                        L.pop(2); // drop thread, function

                        _ = Scheduler.resumeState(thread, L, 1) catch {};
                    }
                    L.pop(1);
                    break;
                }
                if (i == MAX_SOCKETS - 1) {
                    client.stream.close(); // Close the client
                    // std.debug.panic("Too many clients", .{});
                }
            }
        }
        return .ContinueFast;
    }

    pub fn dtor(ctx: *Self, L: *VM.lua.State, _: *Scheduler) void {
        const allocator = luau.getallocator(L);
        defer {
            allocator.free(ctx.connections);
            allocator.free(ctx.fds);
            ctx.server.deinit();
        }
        ctx.stopped = true;
        for (ctx.connections) |connection| {
            if (connection) |conn|
                ctx.closeConnection(L, conn.id);
        }
        L.unref(ctx.ref);
        if (ctx.handlers.open) |ref|
            L.unref(ref);
        ctx.handlers.open = null;
        if (ctx.handlers.message) |ref|
            L.unref(ref);
        ctx.handlers.message = null;
        if (ctx.handlers.close) |ref|
            L.unref(ref);
        ctx.handlers.close = null;
    }
};

pub fn lua_tcp_server(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    var data_ref: ?i32 = null;
    errdefer if (data_ref) |ref| L.unref(ref);
    var open_ref: ?i32 = null;
    errdefer if (open_ref) |ref| L.unref(ref);
    var close_ref: ?i32 = null;
    errdefer if (close_ref) |ref| L.unref(ref);

    try L.Zchecktype(1, .Table);

    const address_ip = try L.Zcheckfield(?[]const u8, 1, "address") orelse "127.0.0.1";

    const port = try L.Zcheckfield(?u16, 1, "port") orelse 0;
    L.pop(1);

    const reuseAddress = try L.Zcheckfield(?bool, 1, "reuseAddress") orelse false;
    L.pop(1);

    const openType = L.getfield(1, "open");
    if (!openType.isnoneornil()) {
        if (openType != .Function)
            return L.Zerror("Field 'open' must be a function");
        open_ref = L.ref(-1) orelse unreachable;
    }
    L.pop(1);

    const dataType = L.getfield(1, "data");
    if (!dataType.isnoneornil()) {
        if (dataType != .Function)
            return L.Zerror("Field 'data' must be a function");
        data_ref = L.ref(-1) orelse unreachable;
    }
    L.pop(1);

    const closeType = L.getfield(1, "close");
    if (!closeType.isnoneornil()) {
        if (closeType != .Function)
            return L.Zerror("Field 'close' must be a function");
        close_ref = L.ref(-1) orelse unreachable;
    }
    L.pop(1);

    const allocator = luau.getallocator(L);

    const address = try std.net.Address.parseIp4(address_ip, port);

    // TODO: non-blocking async io server
    const server = try address.listen(.{
        .reuse_address = reuseAddress,
        .force_nonblocking = false,
    });

    const self = L.newuserdata(TCPServer);

    const connections = try allocator.alloc(?TCPServer.Connection, MAX_SOCKETS);
    errdefer allocator.free(connections);

    const fds = try allocator.alloc(context.spollfd, MAX_SOCKETS);
    errdefer allocator.free(fds);

    for (0..MAX_SOCKETS) |i| {
        fds[i].fd = context.INVALID_SOCKET;
        fds[i].events = context.POLLIN;
        connections[i] = null;
    }
    fds[0].fd = server.stream.handle;

    self.* = .{
        .ref = L.ref(-1) orelse unreachable,
        .server = server,
        .stopped = false,
        .fds = fds,
        .connections = connections,
        .handlers = .{
            .open = open_ref,
            .message = data_ref,
            .close = close_ref,
        },
    };

    if (L.Lgetmetatable(TCPServer.LuaMeta.META) == .Table) {
        _ = L.setmetatable(-2);
    } else std.debug.panic("InternalError (TCPServer Metatable not initialized)", .{});

    scheduler.addTask(TCPServer, self, L, TCPServer.update, TCPServer.dtor);

    return 1;
}

pub fn lua_load(L: *VM.lua.State) void {
    {
        _ = L.Lnewmetatable(TCPClient.LuaMeta.META);

        L.Zsetfieldfn(-1, luau.Metamethods.index, TCPClient.LuaMeta.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, TCPClient.LuaMeta.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    {
        _ = L.Lnewmetatable(TCPServer.LuaMeta.META);

        L.Zsetfieldfn(-1, luau.Metamethods.index, TCPServer.LuaMeta.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, TCPServer.LuaMeta.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    {
        _ = L.Lnewmetatable(TCPServer.Connection.LuaMeta.META);

        L.Zsetfieldfn(-1, luau.Metamethods.namecall, TCPServer.Connection.LuaMeta.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
}
