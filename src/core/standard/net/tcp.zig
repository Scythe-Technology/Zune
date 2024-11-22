const std = @import("std");
const luau = @import("luau");

const Common = @import("common.zig");

const Scheduler = @import("../../runtime/scheduler.zig");

const Luau = luau.Luau;

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
        pub fn __index(L: *Luau) i32 {
            L.checkType(1, .userdata);
            const self = L.toUserdata(Self, 1) catch unreachable;

            const arg = L.checkString(2);

            // TODO: prob should switch to static string map
            if (std.mem.eql(u8, arg, "stopped")) {
                L.pushBoolean(self.stopped);
                return 1;
            }
            return 0;
        }

        pub fn __namecall(L: *Luau, _: *Scheduler) !i32 {
            L.checkType(1, .userdata);
            const self = L.toUserdata(Self, 1) catch unreachable;

            const namecall = L.nameCallAtom() catch return 0;

            // TODO: prob should switch to static string map
            if (std.mem.eql(u8, namecall, "stop")) {
                if (self.stopped)
                    return 0;
                self.stopped = true;
                return 0;
            } else if (std.mem.eql(u8, namecall, "send")) {
                if (self.stopped)
                    return 0;
                const data = L.checkString(2);
                self.stream.writeAll(data) catch |err| {
                    self.stopped = true;
                    return err;
                };
                return 0;
            } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
            return 0;
        }

        pub const Handlers = struct {
            message: ?i32,
            close: ?i32,
        };
    };

    pub fn update(ctx: *Self, L: *Luau, _: *Scheduler) Scheduler.TaskResult {
        if (ctx.stopped)
            return .Stop;

        var fds: [1]context.pollfd = .{.{
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
            if (!prepRefType(.function, L, fnRef))
                return .Stop;
            if (!prepRefType(.userdata, L, ctx.ref)) {
                L.pop(1);
                return .Stop;
            }

            const thread = L.newThread();
            L.xPush(thread, -3); // push: Function
            L.xPush(thread, -2); // push: Userdata
            thread.pushLString(bytes);
            L.pop(3); // drop thread, function & userdata

            _ = Scheduler.resumeState(thread, L, 2) catch {};
            return .ContinueFast;
        }
        return .Continue;
    }

    pub fn dtor(ctx: *Self, L: *Luau, _: *Scheduler) void {
        ctx.stream.close();
        defer L.unref(ctx.ref);
        ctx.stopped = true;
        if (ctx.handlers.close) |ref| jmp: {
            defer L.unref(ref);
            if (!prepRefType(.function, L, ref))
                break :jmp;
            if (!prepRefType(.userdata, L, ctx.ref)) {
                L.pop(1);
                break :jmp;
            }

            const thread = L.newThread();
            L.xPush(thread, -3); // push: Function
            L.xPush(thread, -2); // push: Userdata
            L.pop(3); // drop thread, function & userdata

            _ = Scheduler.resumeState(thread, L, 1) catch {};

            ctx.handlers.close = null;
        }
        if (ctx.handlers.message) |ref|
            L.unref(ref);
        ctx.handlers.message = null;
    }
};

pub fn lua_tcp_client(L: *Luau, scheduler: *Scheduler) !i32 {
    var address_ip: []const u8 = "";
    var port: u16 = 0;

    var open_ref: ?i32 = null;
    defer if (open_ref) |ref| L.unref(ref);
    var data_ref: ?i32 = null;
    errdefer if (data_ref) |ref| L.unref(ref);
    var close_ref: ?i32 = null;
    errdefer if (close_ref) |ref| L.unref(ref);

    L.checkType(1, .table);

    const addressType = L.getField(1, "address");
    if (addressType != .string)
        return L.Error("Field 'address' must be a string");
    address_ip = L.toString(-1) catch unreachable;
    L.pop(1);

    const portType = L.getField(1, "port");
    if (portType != .number)
        return L.Error("Field 'port' must be a number");
    const lport = L.toInteger(-1) catch unreachable;
    if (lport < 0 and lport > 65535)
        return L.Error("Field 'port' must be between 0 and 65535");
    port = @truncate(@as(u32, @intCast(lport)));
    L.pop(1);

    const openType = L.getField(1, "open");
    if (!luau.isNoneOrNil(openType)) {
        if (openType != .function)
            return L.Error("Field 'open' must be a function");
        open_ref = L.ref(-1) catch unreachable;
    }
    L.pop(1);

    const dataType = L.getField(1, "data");
    if (!luau.isNoneOrNil(dataType)) {
        if (dataType != .function)
            return L.Error("Field 'data' must be a function");
        data_ref = L.ref(-1) catch unreachable;
    }
    L.pop(1);

    const closeType = L.getField(1, "close");
    if (!luau.isNoneOrNil(closeType)) {
        if (closeType != .function)
            return L.Error("Field 'close' must be a function");
        close_ref = L.ref(-1) catch unreachable;
    }
    L.pop(1);

    const allocator = L.allocator();

    const stream = std.net.tcpConnectToHost(allocator, address_ip, port) catch |err| {
        std.debug.print("Tcp Error: {}\n", .{err});
        return err;
    };

    const self = L.newUserdata(TCPClient);

    self.* = .{
        .ref = L.ref(-1) catch unreachable,
        .stream = stream,
        .stopped = false,
        .handlers = .{
            .message = data_ref,
            .close = close_ref,
        },
    };

    if (L.getMetatableRegistry(TCPClient.LuaMeta.META) == .table) {
        L.setMetatable(-2);
    } else std.debug.panic("InternalError (UDP Metatable not initialized)", .{});

    scheduler.addTask(TCPClient, self, L, TCPClient.update, TCPClient.dtor);

    if (open_ref) |ref| {
        if (prepRefType(.function, L, ref)) {
            const thread = L.newThread();
            L.xPush(thread, -2); // push: Function
            L.xPush(thread, -3); // push: Userdata
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
            pub fn __namecall(L: *Luau, _: *Scheduler) !i32 {
                L.checkType(1, .userdata);
                const self = L.toUserdata(Connection, 1) catch unreachable;
                if (!self.connected)
                    return 0;

                const namecall = L.nameCallAtom() catch return 0;

                // TODO: prob should switch to static string map
                if (std.mem.eql(u8, namecall, "send")) {
                    self.conn.stream.writeAll(L.checkString(2)) catch |err| {
                        std.debug.print("Error sending data to client: {}\n", .{err});
                        return err;
                    };
                    return 0;
                } else if (std.mem.eql(u8, namecall, "close")) {
                    self.server.closeConnection(L, self.id);
                    return 0;
                } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
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
        pub fn __index(L: *Luau) i32 {
            L.checkType(1, .userdata);
            const self = L.toUserdata(Self, 1) catch unreachable;

            const arg = L.checkString(2);

            // TODO: prob should switch to static string map
            if (std.mem.eql(u8, arg, "stopped")) {
                L.pushBoolean(self.stopped);
                return 1;
            }
            return 0;
        }

        pub fn __namecall(L: *Luau, _: *Scheduler) !i32 {
            L.checkType(1, .userdata);
            const self = L.toUserdata(Self, 1) catch unreachable;

            const namecall = L.nameCallAtom() catch return 0;

            // TODO: prob should switch to static string map
            if (std.mem.eql(u8, namecall, "stop")) {
                if (self.stopped)
                    return 0;
                self.stopped = true;
                return 0;
            } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
            return 0;
        }

        pub const Handlers = struct {
            open: ?i32,
            message: ?i32,
            close: ?i32,
        };
    };

    pub fn closeConnection(ctx: *Self, L: *Luau, id: usize) void {
        if (ctx.connections[id]) |*connection| {
            connection.connected = false;
            defer {
                ctx.fds[connection.id].fd = context.INVALID_SOCKET;
                connection.conn.stream.close();
                L.unref(connection.ref);
                ctx.connections[id] = null;
            }
            if (ctx.handlers.close) |fnRef| {
                if (!prepRefType(.function, L, fnRef))
                    return;
                if (!prepRefType(.userdata, L, connection.ref)) {
                    L.pop(1);
                    return;
                }

                const thread = L.newThread();
                L.xPush(thread, -3); // push: Function
                L.xPush(thread, -2); // push: Userdata
                L.pop(3); // drop thread, function & userdata

                _ = Scheduler.resumeState(thread, L, 1) catch {};
            }
        }
    }

    pub fn update(ctx: *Self, L: *Luau, _: *Scheduler) Scheduler.TaskResult {
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
                        if (!prepRefType(.function, L, fnRef))
                            continue;
                        if (!prepRefType(.userdata, L, connection.ref)) {
                            L.pop(1);
                            continue;
                        }

                        const thread = L.newThread();
                        L.xPush(thread, -3); // push: Function
                        L.xPush(thread, -2); // push: Userdata
                        thread.pushLString(bytes[0..read_len]);
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
                    const ptr = L.newUserdata(Connection);
                    const ref = L.ref(-1) catch unreachable;
                    ptr.* = .{
                        .id = i,
                        .ref = ref,
                        .server = ctx,
                        .conn = client,
                        .connected = true,
                    };
                    connections[i] = ptr.*;
                    if (L.getMetatableRegistry(TCPServer.Connection.LuaMeta.META) == .table) {
                        L.setMetatable(-2);
                    } else std.debug.panic("InternalError (TCPServer Metatable not initialized)", .{});
                    if (ctx.handlers.open) |fnRef| {
                        if (!prepRefType(.function, L, fnRef))
                            continue;

                        const thread = L.newThread();
                        L.xPush(thread, -2); // push: Function
                        L.xPush(thread, -3); // push: Userdata
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

    pub fn dtor(ctx: *Self, L: *Luau, _: *Scheduler) void {
        const allocator = L.allocator();
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

pub fn lua_tcp_server(L: *Luau, scheduler: *Scheduler) !i32 {
    var data_ref: ?i32 = null;
    errdefer if (data_ref) |ref| L.unref(ref);
    var open_ref: ?i32 = null;
    errdefer if (open_ref) |ref| L.unref(ref);
    var close_ref: ?i32 = null;
    errdefer if (close_ref) |ref| L.unref(ref);

    var address_ip: []const u8 = "127.0.0.1";
    var port: u16 = 0;
    var reuseAddress = false;

    L.checkType(1, .table);

    const addressType = L.getField(1, "address");
    if (!luau.isNoneOrNil(addressType)) {
        if (addressType != .string)
            return L.Error("Field 'address' must be a string");
        address_ip = L.toString(-1) catch unreachable;
    }
    L.pop(1);

    const portType = L.getField(1, "port");
    if (!luau.isNoneOrNil(portType)) {
        if (portType != .number)
            return L.Error("Field 'port' must be a number");
        const lport = L.toInteger(-1) catch unreachable;
        if (lport < 0 and lport > 65535)
            return L.Error("Field 'port' must be between 0 and 65535");
        port = @truncate(@as(u32, @intCast(lport)));
    }
    L.pop(1);

    const reuseAddressType = L.getField(1, "reuseAddress");
    if (!luau.isNoneOrNil(reuseAddressType)) {
        if (reuseAddressType != .boolean)
            return L.Error("Field 'reuseAddress' must be a boolean");
        reuseAddress = L.toBoolean(-1);
    }
    L.pop(1);

    const openType = L.getField(1, "open");
    if (!luau.isNoneOrNil(openType)) {
        if (openType != .function)
            return L.Error("Field 'open' must be a function");
        open_ref = L.ref(-1) catch unreachable;
    }
    L.pop(1);

    const dataType = L.getField(1, "data");
    if (!luau.isNoneOrNil(dataType)) {
        if (dataType != .function)
            return L.Error("Field 'data' must be a function");
        data_ref = L.ref(-1) catch unreachable;
    }
    L.pop(1);

    const closeType = L.getField(1, "close");
    if (!luau.isNoneOrNil(closeType)) {
        if (closeType != .function)
            return L.Error("Field 'close' must be a function");
        close_ref = L.ref(-1) catch unreachable;
    }
    L.pop(1);

    const allocator = L.allocator();

    const address = try std.net.Address.parseIp4(address_ip, port);

    const server = try address.listen(.{
        .reuse_address = reuseAddress,
        .force_nonblocking = true,
    });

    const self = L.newUserdata(TCPServer);

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
        .ref = L.ref(-1) catch unreachable,
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

    if (L.getMetatableRegistry(TCPServer.LuaMeta.META) == .table) {
        L.setMetatable(-2);
    } else std.debug.panic("InternalError (TCPServer Metatable not initialized)", .{});

    scheduler.addTask(TCPServer, self, L, TCPServer.update, TCPServer.dtor);

    return 1;
}

pub fn lua_load(L: *Luau) void {
    {
        L.newMetatable(TCPClient.LuaMeta.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, TCPClient.LuaMeta.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, Scheduler.toSchedulerEFn(TCPClient.LuaMeta.__namecall)); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    {
        L.newMetatable(TCPServer.LuaMeta.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, TCPServer.LuaMeta.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, Scheduler.toSchedulerEFn(TCPServer.LuaMeta.__namecall)); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    {
        L.newMetatable(TCPServer.Connection.LuaMeta.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.namecall, Scheduler.toSchedulerEFn(TCPServer.Connection.LuaMeta.__namecall)); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
}
