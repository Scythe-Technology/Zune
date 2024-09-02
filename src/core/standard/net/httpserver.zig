const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Common = @import("common.zig");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");
const Request = @import("http/request.zig");
const WebSocket = @import("http/websocket.zig");

const Luau = luau.Luau;

const context = Common.context;
const prepRefType = Common.prepRefType;

const HTTP_404 = Common.HTTP_404;
const HTTP_413 = Common.HTTP_413;
const HTTP_500 = Common.HTTP_500;

const MAX_SOCKETS = 512;

const Self = @This();

pub const LuaServer = struct {
    ptr: ?*Self,
};

pub const LuaWebSocket = struct {
    ptr: ?*Self,
    id: ?usize,

    pub const Handlers = struct {
        upgrade: ?i32,
        open: ?i32,
        message: ?i32,
        close: ?i32,
    };
};

pub const LuaMeta = struct {
    pub const WEBSOCKET_META = "net_server_ws_instance";
    pub fn websocket__index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const arg = L.checkString(2);

        const data = L.toUserdata(LuaWebSocket, 1) catch return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, arg, "connected")) {
            L.pushBoolean(data.ptr != null);
            return 1;
        }

        return 0;
    }
    pub fn websocket__namecall(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const namecall = L.nameCallAtom() catch return 0;
        const data = L.toUserdata(LuaWebSocket, 1) catch return 0;

        const id = data.id orelse return 0;
        const ctx = data.ptr orelse return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "close")) {
            if (ctx.connections[id]) |connection| {
                const closeCode: u16 = @intCast(L.optInteger(2) orelse 1000);
                var socket = WebSocket.init(L.allocator(), connection.stream);
                defer socket.deinit();
                socket.close(closeCode) catch |err| {
                    std.debug.print("Error writing close: {}\n", .{err});
                };
            }
            ctx.closeConnection(L, id, true);
        } else if (std.mem.eql(u8, namecall, "send")) {
            const message = L.checkString(2);
            if (ctx.websockets[id] != null and ctx.connections[id] != null) {
                const connection = ctx.connections[id] orelse unreachable;
                var socket = WebSocket.init(L.allocator(), connection.stream);
                defer socket.deinit();
                _ = socket.writeText(message) catch |err| L.raiseErrorStr("Failed to write to websocket (%s)", .{@errorName(err).ptr});
            }
        } else L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr});
        return 0;
    }

    pub const SERVER_META = "net_server_instance";
    pub fn server__index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const data = L.toUserdata(LuaServer, 1) catch return 0;

        const arg = L.checkString(2);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, arg, "stopped")) {
            L.pushBoolean(data.ptr == null);
            return 1;
        }
        return 0;
    }

    pub fn server__namecall(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const namecall = L.nameCallAtom() catch return 0;
        const data = L.toUserdata(LuaServer, 1) catch return 0;

        var scheduler = Scheduler.getScheduler(L);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "stop")) {
            const ctx = data.ptr orelse return 0;
            ctx.alive = false;
            data.ptr = null;
            scheduler.deferThread(L, null, 0); // resume on next task
            return L.yield(0);
        } else L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr});
        return 0;
    }
};

pub const NetStreamData = struct {
    stream: ?std.net.Stream,
    owned: ?[]?*NetStreamData,
    id: usize,
};

pub const NetWebSocket = struct {
    ref: ?i32,
};

pub const HandleError = error{
    ShouldEnd,
};

serverRef: i32,
alive: bool = true,
request_lua_function: i32,
websocket_lua_handlers: ?LuaWebSocket.Handlers,
server: *std.net.Server,
connections: []?std.net.Server.Connection,
responses: []?*NetStreamData,
websockets: []?NetWebSocket,
fds: []if (builtin.os.tag == .windows) std.os.windows.ws2_32.pollfd else std.posix.pollfd,

pub fn closeConnection(ctx: *Self, L: *Luau, id: usize, cleanUp: bool) void {
    if (ctx.responses[id]) |responsePtr| {
        responsePtr.stream = null;
        responsePtr.owned = null;
        ctx.responses[id] = null;
    }
    if (ctx.connections[id]) |connection| {
        ctx.fds[id].fd = context.INVALID_SOCKET;

        defer {
            connection.stream.close();
            ctx.connections[id] = null;
        }

        if (ctx.websockets[id]) |ws| {
            defer ctx.websockets[id] = null;
            if (!cleanUp) {
                var socket = WebSocket.init(L.allocator(), connection.stream);
                defer socket.deinit();
                socket.close(1001) catch |err| {
                    std.debug.print("Error writing close: {}\n", .{err});
                };
            }
            if (ws.ref) |wsRef| {
                if (prepRefType(.userdata, L, wsRef)) {
                    const userdata = L.toUserdata(LuaWebSocket, -1) catch unreachable;
                    userdata.ptr = null;
                    userdata.id = null;

                    if (ctx.websocket_lua_handlers) |handlers| {
                        if (handlers.close) |fnRef| {
                            if (prepRefType(.function, L, fnRef)) {
                                const thread = L.newThread();
                                L.xPush(thread, -2); // push: function
                                L.xPush(thread, -3); // push: userdata
                                L.pop(2); // drop thread, function

                                Scheduler.resumeState(thread, L, 1);
                            }
                        }
                    }

                    L.pop(1);
                }
                L.unref(wsRef);
            }
        }
    }
}

pub fn handleWebSocket(ctx: *Self, L: *Luau, scheduler: *Scheduler, i: usize, connection: std.net.Server.Connection) HandleError!void {
    const allocator = L.allocator();
    _ = scheduler;

    var socket = WebSocket.init(allocator, connection.stream);
    defer socket.deinit();

    const handlers = ctx.websocket_lua_handlers orelse return;
    const websocket = ctx.websockets[i] orelse return;

    const frame = socket.read() catch |err| {
        ctx.closeConnection(L, i, true);
        if (err == error.ConnectionClosed) {
            std.debug.print("Connection closed\n", .{});
            return;
        } else {
            std.debug.print("Server error reading from websocket: {}\n", .{err});
            return;
        }
    };

    switch (frame.header.opcode) {
        .Ping => {
            _ = socket.writeMessage(.Pong, frame.data) catch |err| {
                std.debug.print("Error writing pong: {}\n", .{err});
            };
        },
        .Pong => {
            std.debug.print("Pong\n", .{});
        },
        .Close => {
            std.debug.print("Close\n", .{});
            ctx.closeConnection(L, i, true);
        },
        .Text, .Binary => {
            if (handlers.message) |fnRef| {
                if (websocket.ref) |wsRef| {
                    if (!prepRefType(.function, L, fnRef)) {
                        std.debug.print("Function not found\n", .{});
                        return;
                    }
                    if (!prepRefType(.userdata, L, wsRef)) {
                        L.pop(1); // drop function
                        std.debug.print("Userdata not found\n", .{});
                        return;
                    }

                    const thread = L.newThread();
                    L.xPush(thread, -3); // push: function
                    L.xPush(thread, -2); // push: userdata
                    L.pop(3); // drop thread, function & userdata

                    thread.pushLString(frame.data); // push: string

                    Scheduler.resumeState(thread, L, 2);
                }
            }
        },
        else => {
            std.debug.print("Unknown opcode: {}\n", .{frame.header.opcode});
            std.debug.print("data: {s}", .{frame.data});
        },
    }

    return;
}

pub fn responseResumed(responsePtr: *NetStreamData, L: *Luau, scheduler: *Scheduler) void {
    _ = scheduler;
    const allocator = L.allocator();
    defer {
        if (responsePtr.owned) |owned| owned[responsePtr.id] = null;
        allocator.destroy(responsePtr);
    }
    if (responsePtr.owned == null) return; // Server dead
    const stream = responsePtr.stream orelse {
        std.debug.print("Stream is null, connection closed", .{});
        return;
    };
    if (L.status() != .ok) {
        stream.writeAll(HTTP_500) catch |err| {
            std.debug.print("Error writing response: {}\n", .{err});
        };
        return;
    }

    switch (L.typeOf(-1)) {
        .table => {
            if (L.getField(-1, "statusCode") != .number) {
                L.pop(1);
                std.debug.print("Field 'statusCode' must be a number", .{});
                stream.writeAll(HTTP_500) catch return;
                return;
            }
            const statusCode = L.checkInteger(-1);
            if (statusCode < 100 or statusCode > 599) {
                std.debug.print("Status code must be between 100 and 599", .{});
                stream.writeAll(HTTP_500) catch return;
                return;
            }

            const headersType = L.getField(-2, "headers");
            var headersString = std.ArrayList(u8).init(allocator);
            defer headersString.deinit();
            if (!luau.isNoneOrNil(headersType) and headersType != .table) {
                std.debug.print("Field 'headers' must be a table", .{});
                stream.writeAll(HTTP_500) catch return;
                return;
            } else if (headersType == .table) {
                var headers = std.ArrayList(std.http.Header).init(allocator);
                defer headers.deinit();

                Common.read_headers(L, &headers, -1) catch |err| switch (err) {
                    error.InvalidKeyType => {
                        L.pop(1);
                        std.debug.print("Header key must be a string", .{});
                        return;
                    },
                    error.InvalidValueType => {
                        L.pop(1);
                        std.debug.print("Header value must be a string", .{});
                        return;
                    },
                    else => {
                        L.pop(1);
                        std.debug.print("Unknown error", .{});
                        return;
                    },
                };

                for (headers.items) |header| {
                    headersString.appendSlice(header.name) catch |err| {
                        std.debug.print("Error appending header name: {}\n", .{err});
                        stream.writeAll(HTTP_500) catch return;
                        return;
                    };
                    headersString.appendSlice(": ") catch |err| {
                        std.debug.print("Error appending header separator: {}\n", .{err});
                        stream.writeAll(HTTP_500) catch return;
                        return;
                    };
                    headersString.appendSlice(header.value) catch |err| {
                        std.debug.print("Error appending header value: {}\n", .{err});
                        stream.writeAll(HTTP_500) catch return;
                        return;
                    };
                    headersString.appendSlice("\r\n") catch |err| {
                        std.debug.print("Error appending header separator: {}\n", .{err});
                        stream.writeAll(HTTP_500) catch return;
                        return;
                    };
                }
            }

            const bodyType = L.getField(-3, "body");
            if (bodyType != .string and bodyType != .buffer) {
                std.debug.print("Field 'body' must be a string", .{});
                stream.writeAll(HTTP_500) catch return;
                return;
            }
            const body = if (bodyType == .buffer) L.checkBuffer(-1) else L.checkString(-1);

            const response = if (headersString.items.len > 0)
                std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{
                    statusCode,
                    std.http.Status.phrase(@enumFromInt(statusCode)).?,
                    headersString.items,
                    body.len,
                    body,
                }) catch |err| {
                    std.debug.print("Error formatting response: {}\n", .{err});
                    return;
                }
            else
                std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{
                    statusCode,
                    std.http.Status.phrase(@enumFromInt(statusCode)).?,
                    body.len,
                    body,
                }) catch |err| {
                    std.debug.print("Error formatting response: {}\n", .{err});
                    return;
                };
            defer allocator.free(response);

            stream.writeAll(response) catch |err| {
                std.debug.print("Error writing response: {}\n", .{err});
                return;
            };
        },
        .string, .buffer => |t| {
            const content = if (t == .buffer) L.checkBuffer(-1) else L.checkString(-1);
            const response = std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ content.len, content }) catch |err| {
                std.debug.print("Error formatting response: {}\n", .{err});
                return;
            };
            defer allocator.free(response);
            stream.writeAll(response) catch |err| {
                std.debug.print("Error writing response: {}\n", .{err});
                return;
            };
        },
        else => {
            L.pop(1);
            std.debug.print("Serve response must be a table or string", .{});
            stream.writeAll(HTTP_500) catch return;
            return;
        },
    }
}

pub fn handleRequest(ctx: *Self, L: *Luau, scheduler: *Scheduler, i: usize, connection: std.net.Server.Connection) HandleError!void {
    const allocator = L.allocator();

    const responses = ctx.responses;

    var req = Request.init(allocator, connection.stream.reader().any(), .{
        .maxBodySize = 128,
    }) catch |err| {
        if (err == error.BodyTooLarge) {
            connection.stream.writeAll(HTTP_413) catch |writeErr| {
                std.debug.print("Error writing response: {}\n", .{writeErr});
            };
        } else if (err == error.InvalidMethod) {
            // Likely with SSL, not supported yet
        }
        ctx.closeConnection(L, i, false);
        return;
    };
    defer req.deinit();

    if (ctx.websocket_lua_handlers) |handlers| {
        const upgradeInfo = req.canUpgradeWebSocket() catch |err| {
            std.debug.print("Error checking for websocket upgrade: {}\n", .{err});
            return;
        };
        if (upgradeInfo) |info| {
            var allow = true;
            if (handlers.upgrade) |fnRef| {
                if (prepRefType(.function, L, fnRef)) {
                    const thread = L.newThread();
                    L.xPush(thread, -2);
                    L.pop(2); // drop thread & function

                    req.pushToStack(thread) catch |err| {
                        std.debug.print("Error pushing request to stack: {}\n", .{err});
                        connection.stream.writeAll(HTTP_500) catch |werr| {
                            std.debug.print("Error writing response: {}\n", .{werr});
                        };
                        return;
                    };

                    thread.pcall(1, 1, 0) catch |err| {
                        Engine.logError(thread, err);
                        connection.stream.writeAll(HTTP_500) catch |werr| {
                            std.debug.print("Error writing response: {}\n", .{werr});
                        };
                        return;
                    };

                    if (thread.typeOf(-1) != .boolean) {
                        std.debug.print("Function must return a boolean\n", .{});
                        thread.pop(1);
                        connection.stream.writeAll(HTTP_500) catch |werr| {
                            std.debug.print("Error writing response: {}\n", .{werr});
                        };
                        return;
                    }

                    allow = thread.toBoolean(-1);
                } else {
                    std.debug.print("Function not found\n", .{});
                }
            }
            if (!allow) {
                connection.stream.writeAll(HTTP_404) catch |err| {
                    std.debug.print("Error writing response: {}\n", .{err});
                };
                return;
            }

            const accept_key = WebSocket.acceptHashKey(allocator, info.key) catch |err| {
                std.debug.print("Error creating accept hash key: {}\n", .{err});
                return;
            };
            defer allocator.free(accept_key);

            const response = std.mem.concat(allocator, u8, &.{
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Accept: ",
                accept_key,
                if (info.protocols != null) "\r\nSec-WebSocket-Protocol: " else "",
                if (info.protocols) |protocols| protocols else "",
                "\r\n\r\n",
            }) catch |err| {
                std.debug.print("Error creating response: {}\n", .{err});
                return;
            };
            defer allocator.free(response);

            connection.stream.writeAll(response) catch |err| {
                std.debug.print("Error writing response: {}\n", .{err});
                return;
            };

            const userdata = L.newUserdata(LuaWebSocket);
            userdata.ptr = ctx;
            userdata.id = i;

            if (L.getMetatableRegistry(LuaMeta.WEBSOCKET_META) == .table) {
                L.setMetatable(-2);
            } else {
                L.pop(2); //drop table & metatable
                return;
            }

            ctx.websockets[i] = .{
                .ref = L.ref(-1) catch |err| {
                    std.debug.print("Error creating ref: {}\n", .{err});
                    return;
                },
            };

            if (handlers.open) |fnRef| {
                if (!prepRefType(.function, L, fnRef)) {
                    std.debug.print("Function not found\n", .{});
                    return;
                }

                const thread = L.newThread();
                L.xPush(thread, -2); // push: function
                L.xPush(thread, -3); // push: Table
                L.pop(3); // drop thread, function & userdata

                Scheduler.resumeState(thread, L, 1);
            }
            return;
        }
    }

    const responsePtr = allocator.create(NetStreamData) catch |err| {
        std.debug.print("Error creating stream: {}\n", .{err});
        return;
    };
    responsePtr.* = .{
        .stream = connection.stream,
        .owned = responses,
        .id = i,
    };
    if (!prepRefType(.function, L, ctx.request_lua_function)) {
        std.debug.print("Function not found\n", .{});
        return HandleError.ShouldEnd;
    }

    const thread = L.newThread();
    L.xPush(thread, -2); // push: function
    L.pop(2); // drop thread & function

    req.pushToStack(thread) catch |err| {
        std.debug.print("Error pushing request to stack: {}\n", .{err});
        allocator.destroy(responsePtr);
        return;
    };

    responses[i] = responsePtr;

    scheduler.awaitCall(NetStreamData, responsePtr, thread, 1, responseResumed, L) catch |err| {
        Engine.logError(thread, err);
        connection.stream.writeAll(HTTP_500) catch |werr| {
            std.debug.print("Error writing response: {}\n", .{werr});
        };
        responses[i] = null;
        allocator.destroy(responsePtr);
        return;
    };
}

pub fn update(ctx: *Self, L: *Luau, scheduler: *Scheduler) Scheduler.TaskResult {
    if (!ctx.alive) return .Stop;
    var server = ctx.server.*;
    var fds = ctx.fds;
    const connections = ctx.connections;
    const websockets = ctx.websockets;

    var nums = if (builtin.os.tag == .windows) std.os.windows.poll(fds.ptr, MAX_SOCKETS, 0) else std.posix.poll(fds, 0) catch std.debug.panic("Bad poll (1)", .{});
    if (nums == 0) return .Continue;
    if (nums < 0) std.debug.panic("Bad poll (2)", .{});

    for (1..MAX_SOCKETS) |i| {
        if (nums == 0) {
            break;
        }
        const sockfd = fds[i];
        if (sockfd.fd == context.INVALID_SOCKET) continue;
        defer if (sockfd.revents != 0) {
            nums -= 1;
        };
        if (sockfd.revents & (context.POLLIN) != 0) {
            const c = connections[i];
            if (c) |connection| {
                if (websockets[i] != null) handleWebSocket(ctx, L, scheduler, i, connection) catch |err| {
                    std.debug.print("Error handling request: {}\n", .{err});
                    if (err == HandleError.ShouldEnd) {
                        ctx.alive = false;
                        return .Stop;
                    }
                } else handleRequest(ctx, L, scheduler, i, connection) catch |err| {
                    std.debug.print("Error handling request: {}\n", .{err});
                    if (err == HandleError.ShouldEnd) {
                        ctx.alive = false;
                        return .Stop;
                    }
                };
            }
        } else if (sockfd.revents & (context.POLLNVAL | context.POLLERR | context.POLLHUP) != 0) {
            ctx.closeConnection(L, i, true);
        }
    }
    if (fds[0].revents & context.POLLIN != 0 and nums > 0) {
        const client = server.accept() catch |err| {
            std.debug.print("Error accepting client: {}\n", .{err});
            return .Continue;
        };
        for (1..MAX_SOCKETS) |i| {
            if (fds[i].fd == context.INVALID_SOCKET) {
                fds[i].fd = client.stream.handle;
                connections[i] = client;
                break;
            }
            if (i == MAX_SOCKETS - 1) {
                std.debug.panic("Too many clients", .{});
            }
        }
    }
    return .Continue;
}

pub fn dtor(ctx: *Self, L: *Luau, scheduler: *Scheduler) void {
    _ = scheduler;
    const allocator = L.allocator();

    defer {
        allocator.free(ctx.connections);
        allocator.free(ctx.fds);
        allocator.free(ctx.responses);
        allocator.free(ctx.websockets);

        ctx.server.deinit();

        allocator.destroy(ctx.server);
        allocator.destroy(ctx);
    }

    for (0..MAX_SOCKETS) |i| ctx.closeConnection(L, i, false);

    L.unref(ctx.request_lua_function);
    if (ctx.websocket_lua_handlers) |handlers| {
        if (handlers.upgrade) |function| L.unref(function);
        if (handlers.open) |function| L.unref(function);
        if (handlers.message) |function| L.unref(function);
        if (handlers.close) |function| L.unref(function);
    }

    if (prepRefType(.userdata, L, ctx.serverRef)) {
        const server = L.toUserdata(LuaServer, -1) catch unreachable;
        server.ptr = null;
        L.pop(1);
    }
    L.unref(ctx.serverRef);
}

pub fn prep(
    allocator: std.mem.Allocator,
    L: *Luau,
    scheduler: *Scheduler,
    addressStr: []const u8,
    port: u16,
    reuseAddress: bool,
    requestFunctionRef: i32,
    websocketHandlers: ?LuaWebSocket.Handlers,
) !void {
    const serverPtr = try allocator.create(std.net.Server);
    errdefer allocator.destroy(serverPtr);

    const address = try std.net.Address.parseIp4(addressStr, port);

    serverPtr.* = try address.listen(.{
        .reuse_address = reuseAddress,
        .force_nonblocking = true,
    });

    const data = try allocator.create(Self);
    errdefer allocator.destroy(data);

    var connections = try allocator.alloc(?std.net.Server.Connection, MAX_SOCKETS);
    errdefer allocator.free(connections);

    var responses = try allocator.alloc(?*NetStreamData, MAX_SOCKETS);
    errdefer allocator.free(responses);

    var websockets = try allocator.alloc(?NetWebSocket, MAX_SOCKETS);
    errdefer allocator.free(websockets);

    var fds = try allocator.alloc(if (builtin.os.tag == .windows) std.os.windows.ws2_32.pollfd else std.posix.pollfd, MAX_SOCKETS);
    errdefer allocator.free(fds);

    for (0..MAX_SOCKETS) |i| {
        fds[i].fd = context.INVALID_SOCKET;
        fds[i].events = context.POLLIN;
        connections[i] = null;
        responses[i] = null;
        websockets[i] = null;
    }

    fds[0].fd = serverPtr.*.stream.handle;

    const server = L.newUserdata(LuaServer);
    server.ptr = data;

    if (L.getMetatableRegistry(LuaMeta.SERVER_META) == .table) {
        L.setMetatable(-2);
    } else {
        std.debug.panic("InternalError (Server Metatable not initialized)", .{});
    }

    const serverRef = try L.ref(-1);

    data.* = Self{
        .serverRef = serverRef,
        .request_lua_function = requestFunctionRef,
        .websocket_lua_handlers = websocketHandlers,
        .server = serverPtr,
        .connections = connections,
        .responses = responses,
        .websockets = websockets,
        .fds = fds,
        .alive = true,
    };

    scheduler.addTask(Self, data, L, update, dtor);
}

pub fn lua_serve(L: *Luau, scheduler: *Scheduler) i32 {
    L.checkType(1, .table);

    var addressStr: []const u8 = "127.0.0.1";
    var reuseAddress: bool = false;

    if (L.getField(1, "port") != .number) L.raiseErrorStr("Expected field 'port' to be a number", .{});
    const port = L.toInteger(-1) catch unreachable;
    if (port < 0 and port > 65535) L.raiseErrorStr("port must be between 0 and 65535", .{});
    L.pop(1);

    const addressType = L.getField(1, "address");
    if (!luau.isNoneOrNil(addressType)) {
        if (addressType != .string) L.raiseErrorStr("Expected field 'address' to be a string", .{});
        addressStr = L.toString(-1) catch unreachable;
    }
    L.pop(1);

    const reuseAddressType = L.getField(1, "reuseAddress");
    if (!luau.isNoneOrNil(reuseAddressType)) {
        if (addressType != .boolean) L.raiseErrorStr("Expected field 'reuseAddress' to be a boolean", .{});
        reuseAddress = L.toBoolean(-1);
    }
    L.pop(1);

    if (L.getField(1, "request") != .function) L.raiseErrorStr("Expected field 'request' to be a function", .{});
    const requestFunctionRef = L.ref(-1) catch L.raiseErrorStr("InternalError (Failed to create reference)", .{});
    L.pop(1);

    var websocketUpgradeFunctionRef: ?i32 = null;
    var websocketOpenFunctionRef: ?i32 = null;
    var websocketMessageFunctionRef: ?i32 = null;
    var websocketCloseFunctionRef: ?i32 = null;
    const websocketType = L.getField(1, "websocket");
    if (!luau.isNoneOrNil(websocketType)) {
        if (websocketType != .table) L.raiseErrorStr("Expected field 'websocket' to be a table", .{});
        const upgradeType = L.getField(-1, "upgrade");
        if (!luau.isNoneOrNil(upgradeType)) {
            if (upgradeType != .function) L.raiseErrorStr("Expected field 'upgrade' to be a function", .{});
            websocketUpgradeFunctionRef = L.ref(-1) catch L.raiseErrorStr("InternalError (Failed to create reference)", .{});
        }
        L.pop(1);
        const openType = L.getField(-1, "open");
        if (!luau.isNoneOrNil(openType)) {
            if (openType != .function) L.raiseErrorStr("Expected field 'open' to be a function", .{});
            websocketOpenFunctionRef = L.ref(-1) catch L.raiseErrorStr("InternalError (Failed to create reference)", .{});
        }
        L.pop(1);
        const messageType = L.getField(-1, "message");
        if (!luau.isNoneOrNil(messageType)) {
            if (messageType != .function) L.raiseErrorStr("Expected field 'message' to be a function", .{});
            websocketMessageFunctionRef = L.ref(-1) catch L.raiseErrorStr("InternalError (Failed to create reference)", .{});
        }
        L.pop(1);
        const closeType = L.getField(-1, "close");
        if (!luau.isNoneOrNil(closeType)) {
            if (closeType != .function) L.raiseErrorStr("Expected field 'close' to be a function", .{});
            websocketCloseFunctionRef = L.ref(-1) catch L.raiseErrorStr("InternalError (Failed to create reference)", .{});
        }
        L.pop(1);
    }
    L.pop(1);

    const allocator = L.allocator();

    L.pushBoolean(true);

    prep(allocator, L, scheduler, addressStr, @intCast(port), reuseAddress, requestFunctionRef, .{
        .upgrade = websocketUpgradeFunctionRef,
        .open = websocketOpenFunctionRef,
        .message = websocketMessageFunctionRef,
        .close = websocketCloseFunctionRef,
    }) catch |err| {
        L.pop(1); // drop true
        L.pushBoolean(false);
        L.pushString(@errorName(err));
        return 2;
    };

    return 2;
}

pub fn lua_load(L: *Luau) !void {
    try L.newMetatable(LuaMeta.SERVER_META);

    L.setFieldFn(-1, luau.Metamethods.index, LuaMeta.server__index); // metatable.__index
    L.setFieldFn(-1, luau.Metamethods.namecall, LuaMeta.server__namecall); // metatable.__namecall

    L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
    L.pop(1);

    try L.newMetatable(LuaMeta.WEBSOCKET_META);

    L.setFieldFn(-1, luau.Metamethods.index, LuaMeta.websocket__index); // metatable.__index
    L.setFieldFn(-1, luau.Metamethods.namecall, LuaMeta.websocket__namecall); // metatable.__namecall

    L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
    L.pop(1);
}
