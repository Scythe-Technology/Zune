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
        const data = L.toUserdata(LuaWebSocket, 1) catch unreachable;

        const arg = L.checkString(2);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, arg, "connected")) {
            L.pushBoolean(data.ptr != null);
            return 1;
        }

        return 0;
    }
    pub fn websocket__namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const data = L.toUserdata(LuaWebSocket, 1) catch unreachable;

        const namecall = L.nameCallAtom() catch return 0;

        const id = data.id orelse return 0;
        const ctx = data.ptr orelse return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "close")) {
            if (ctx.connections[id]) |connection| {
                const closeCode: u16 = @intCast(L.optInteger(2) orelse 1000);
                var socket = WebSocket.init(L.allocator(), connection.stream, false);
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
                var socket = WebSocket.init(L.allocator(), connection.stream, false);
                defer socket.deinit();
                _ = socket.writeText(message) catch |err| return L.ErrorFmt("Failed to write to websocket ({s})", .{@errorName(err)});
            }
        } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub const SERVER_META = "net_server_instance";
    pub fn server__index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const self = L.toUserdata(Self, 1) catch unreachable;

        const arg = L.checkString(2);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, arg, "stopped")) {
            L.pushBoolean(self.alive == false);
            return 1;
        }
        return 0;
    }

    pub fn server__namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const self = L.toUserdata(Self, 1) catch unreachable;

        const namecall = L.nameCallAtom() catch return 0;

        var scheduler = Scheduler.getScheduler(L);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "stop")) {
            self.alive = false;
            if (self.ref) |ref|
                L.unref(ref);
            self.ref = null;
            scheduler.deferThread(L, null, 0); // resume on next task
            return L.yield(0);
        } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
        return 0;
    }
};

pub const NetStreamData = struct {
    server: *Self,
    stream: ?std.net.Stream,
    owned: ?[]?*NetStreamData,
    upgrade_response: ?[]const u8 = null,
    id: usize,
};

pub const NetWebSocket = struct {
    ref: ?i32,
};

pub const HandleError = error{
    ShouldEnd,
};

ref: ?i32,
alive: bool = true,
max_body_size: usize = 4096,
request_lua_function: i32,
websocket_lua_handlers: ?LuaWebSocket.Handlers,
server: *std.net.Server,
connections: []?std.net.Server.Connection,
responses: []?*NetStreamData,
websockets: []?NetWebSocket,
fds: []context.spollfd,

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
                var socket = WebSocket.init(L.allocator(), connection.stream, false);
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

                                _ = Scheduler.resumeState(thread, L, 1) catch {};
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

    var socket = WebSocket.init(allocator, connection.stream, false);
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

                    _ = Scheduler.resumeState(thread, L, 2) catch {};
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
        if (responsePtr.owned) |owned|
            owned[responsePtr.id] = null;
    }
    if (responsePtr.owned == null)
        return; // Server dead
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
            const body = if (bodyType == .buffer)
                L.checkBuffer(-1)
            else
                L.checkString(-1);

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

pub fn websocket_acceptUpgrade(L: *Luau, ctx: *Self, id: usize, stream: std.net.Stream, res: []const u8) void {
    stream.writeAll(res) catch |err| {
        std.debug.print("Error writing response: {}\n", .{err});
        return;
    };

    const userdata = L.newUserdata(LuaWebSocket);
    userdata.ptr = ctx;
    userdata.id = id;

    if (L.getMetatableRegistry(LuaMeta.WEBSOCKET_META) == .table) {
        L.setMetatable(-2);
    } else std.debug.panic("InternalError (Server Metatable not initialized)", .{});

    ctx.websockets[id] = .{
        .ref = L.ref(-1) catch |err| {
            std.debug.print("Error creating ref: {}\n", .{err});
            return;
        },
    };

    if (ctx.websocket_lua_handlers) |handlers| {
        if (handlers.open) |fnRef| {
            if (!prepRefType(.function, L, fnRef)) {
                std.debug.print("Function not found\n", .{});
                return;
            }

            const thread = L.newThread();
            L.xPush(thread, -2); // push: function
            L.xPush(thread, -3); // push: Userdata
            L.pop(2); // drop thread, function

            _ = Scheduler.resumeState(thread, L, 1) catch {};
        }
    }
    L.pop(1); // drop userdata
}

pub fn websocket_upgradeResumed(responsePtr: *NetStreamData, L: *Luau, _: *Scheduler) void {
    const allocator = L.allocator();
    defer {
        if (responsePtr.owned) |owned|
            owned[responsePtr.id] = null;
        if (responsePtr.upgrade_response) |buf|
            allocator.free(buf);
    }
    const upgrade = responsePtr.upgrade_response orelse return;
    const ctx = responsePtr.server;
    const id = responsePtr.id;
    if (responsePtr.owned == null)
        return; // Server dead
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
    if (L.typeOf(-1) != .boolean) {
        std.debug.print("Function must return a boolean\n", .{});
        stream.writeAll(HTTP_500) catch |werr| {
            std.debug.print("Error writing response: {}\n", .{werr});
        };
        return;
    }
    const allow = L.toBoolean(-1);
    if (!allow) {
        stream.writeAll(HTTP_404) catch |err| {
            std.debug.print("Error writing response: {}\n", .{err});
        };
        return;
    }

    websocket_acceptUpgrade(L, ctx, id, stream, upgrade);
}

pub fn handleRequest(ctx: *Self, L: *Luau, scheduler: *Scheduler, i: usize, connection: std.net.Server.Connection) HandleError!void {
    const allocator = L.allocator();

    const responses = ctx.responses;

    var req = Request.init(allocator, connection.stream.reader().any(), .{
        .maxBodySize = ctx.max_body_size,
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

                    const awaitRes = scheduler.awaitCall(NetStreamData, .{
                        .server = ctx,
                        .stream = connection.stream,
                        .owned = responses,
                        .upgrade_response = response,
                        .id = i,
                    }, thread, 1, websocket_upgradeResumed, L) catch {
                        connection.stream.writeAll(HTTP_500) catch |werr| {
                            std.debug.print("Error writing response: {}\n", .{werr});
                        };
                        return;
                    };
                    if (awaitRes) |ptr|
                        responses[i] = ptr;
                    return;
                } else {
                    std.debug.print("Function not found\n", .{});
                }
            }
            defer allocator.free(response);

            websocket_acceptUpgrade(L, ctx, i, connection.stream, response);
            return;
        }
    }

    if (!prepRefType(.function, L, ctx.request_lua_function)) {
        std.debug.print("Function not found\n", .{});
        return HandleError.ShouldEnd;
    }

    const thread = L.newThread();
    L.xPush(thread, -2); // push: function
    L.pop(2); // drop thread & function

    req.pushToStack(thread) catch |err| {
        std.debug.print("Error pushing request to stack: {}\n", .{err});
        return;
    };

    const awaitRes = scheduler.awaitCall(NetStreamData, .{
        .server = ctx,
        .stream = connection.stream,
        .owned = responses,
        .id = i,
    }, thread, 1, responseResumed, L) catch {
        connection.stream.writeAll(HTTP_500) catch |werr| {
            std.debug.print("Error writing response: {}\n", .{werr});
        };
        return;
    };
    if (awaitRes) |ptr|
        responses[i] = ptr;
}

pub fn update(ctx: *Self, L: *Luau, scheduler: *Scheduler) Scheduler.TaskResult {
    if (!ctx.alive)
        return .Stop;
    var server = ctx.server;
    var fds = ctx.fds;
    const connections = ctx.connections;
    const websockets = ctx.websockets;

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
            return .ContinueFast;
        };
        for (1..MAX_SOCKETS) |i| {
            if (fds[i].fd == context.INVALID_SOCKET) {
                fds[i].fd = client.stream.handle;
                connections[i] = client;
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
    }

    for (0..MAX_SOCKETS) |i| ctx.closeConnection(L, i, false);

    L.unref(ctx.request_lua_function);
    if (ctx.websocket_lua_handlers) |handlers| {
        if (handlers.upgrade) |ref|
            L.unref(ref);
        if (handlers.open) |ref|
            L.unref(ref);
        if (handlers.message) |ref|
            L.unref(ref);
        if (handlers.close) |ref|
            L.unref(ref);
    }

    if (ctx.ref) |ref|
        L.unref(ref);
    ctx.ref = null;
}

pub fn prep(
    allocator: std.mem.Allocator,
    L: *Luau,
    scheduler: *Scheduler,
    addressStr: []const u8,
    port: u16,
    reuseAddress: bool,
    request_fn_ref: i32,
    max_body_size: usize,
    websocketHandlers: ?LuaWebSocket.Handlers,
) !void {
    const server = try allocator.create(std.net.Server);
    errdefer allocator.destroy(server);

    const address = try std.net.Address.parseIp4(addressStr, port);

    server.* = try address.listen(.{
        .reuse_address = reuseAddress,
        .force_nonblocking = true,
    });

    var connections = try allocator.alloc(?std.net.Server.Connection, MAX_SOCKETS);
    errdefer allocator.free(connections);

    var responses = try allocator.alloc(?*NetStreamData, MAX_SOCKETS);
    errdefer allocator.free(responses);

    var websockets = try allocator.alloc(?NetWebSocket, MAX_SOCKETS);
    errdefer allocator.free(websockets);

    var fds = try allocator.alloc(context.spollfd, MAX_SOCKETS);
    errdefer allocator.free(fds);

    for (0..MAX_SOCKETS) |i| {
        fds[i].fd = context.INVALID_SOCKET;
        fds[i].events = context.POLLIN;
        connections[i] = null;
        responses[i] = null;
        websockets[i] = null;
    }
    fds[0].fd = server.*.stream.handle;

    const self = L.newUserdata(Self);

    if (L.getMetatableRegistry(LuaMeta.SERVER_META) == .table) {
        L.setMetatable(-2);
    } else {
        std.debug.panic("InternalError (Server Metatable not initialized)", .{});
    }

    const ref = L.ref(-1) catch unreachable;

    self.* = Self{
        .ref = ref,
        .request_lua_function = request_fn_ref,
        .websocket_lua_handlers = websocketHandlers,
        .max_body_size = max_body_size,
        .server = server,
        .connections = connections,
        .responses = responses,
        .websockets = websockets,
        .fds = fds,
        .alive = true,
    };

    scheduler.addTask(Self, self, L, update, dtor);
}

pub fn lua_serve(L: *Luau, scheduler: *Scheduler) !i32 {
    L.checkType(1, .table);

    var addressStr: []const u8 = "127.0.0.1";
    var reuseAddress: bool = false;

    if (L.getField(1, "port") != .number)
        return L.Error("Field 'port' must be a number");
    const port = L.toInteger(-1) catch unreachable;
    if (port < 0 and port > 65535)
        return L.Error("Field 'port' must be between 0 and 65535");
    L.pop(1);

    const max_body_size_type = L.getField(1, "maxBodySize");
    if (!luau.isNoneOrNil(max_body_size_type) and max_body_size_type != .number)
        return L.Error("Field 'maxBodySize' must be a number");
    const body_size = L.optInteger(-1) orelse 4096;
    if (body_size < 0)
        return L.Error("Field 'maxBodySize' cannot be less than 0");
    const max_body_size: usize = @intCast(body_size);
    L.pop(1);

    const addressType = L.getField(1, "address");
    if (!luau.isNoneOrNil(addressType)) {
        if (addressType != .string)
            return L.Error("Expected field 'address' to be a string");
        addressStr = L.toString(-1) catch unreachable;
    }
    L.pop(1);

    const reuseAddressType = L.getField(1, "reuseAddress");
    if (!luau.isNoneOrNil(reuseAddressType)) {
        if (reuseAddressType != .boolean)
            return L.Error("Expected field 'reuseAddress' to be a boolean");
        reuseAddress = L.toBoolean(-1);
    }
    L.pop(1);

    if (L.getField(1, "request") != .function)
        return L.Error("Expected field 'request' to be a function");
    const request_fn_ref = L.ref(-1) catch unreachable;
    errdefer L.unref(request_fn_ref);
    L.pop(1);

    var websocket_upgrade_fn_ref: ?i32 = null;
    errdefer if (websocket_upgrade_fn_ref) |ref| L.unref(ref);
    var websocket_open_fn_ref: ?i32 = null;
    errdefer if (websocket_open_fn_ref) |ref| L.unref(ref);
    var websocket_message_fn_ref: ?i32 = null;
    errdefer if (websocket_message_fn_ref) |ref| L.unref(ref);
    var websocket_close_fn_ref: ?i32 = null;
    errdefer if (websocket_close_fn_ref) |ref| L.unref(ref);
    const websocketType = L.getField(1, "websocket");
    if (!luau.isNoneOrNil(websocketType)) {
        if (websocketType != .table)
            return L.Error("Expected field 'websocket' to be a table");
        const upgradeType = L.getField(-1, "upgrade");
        if (!luau.isNoneOrNil(upgradeType)) {
            if (upgradeType != .function)
                return L.Error("Expected field 'upgrade' to be a function");
            websocket_upgrade_fn_ref = L.ref(-1) catch unreachable;
        }
        L.pop(1);
        const openType = L.getField(-1, "open");
        if (!luau.isNoneOrNil(openType)) {
            if (openType != .function)
                return L.Error("Expected field 'open' to be a function");
            websocket_open_fn_ref = L.ref(-1) catch unreachable;
        }
        L.pop(1);
        const messageType = L.getField(-1, "message");
        if (!luau.isNoneOrNil(messageType)) {
            if (messageType != .function)
                return L.Error("Expected field 'message' to be a function");
            websocket_message_fn_ref = L.ref(-1) catch unreachable;
        }
        L.pop(1);
        const closeType = L.getField(-1, "close");
        if (!luau.isNoneOrNil(closeType)) {
            if (closeType != .function)
                return L.Error("Expected field 'close' to be a function");
            websocket_close_fn_ref = L.ref(-1) catch unreachable;
        }
        L.pop(1);
    }
    L.pop(1);

    const allocator = L.allocator();

    try prep(
        allocator,
        L,
        scheduler,
        addressStr,
        @intCast(port),
        reuseAddress,
        request_fn_ref,
        max_body_size,
        .{
            .upgrade = websocket_upgrade_fn_ref,
            .open = websocket_open_fn_ref,
            .message = websocket_message_fn_ref,
            .close = websocket_close_fn_ref,
        },
    );

    return 1;
}

pub fn lua_load(L: *Luau) void {
    L.newMetatable(LuaMeta.SERVER_META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

    L.setFieldFn(-1, luau.Metamethods.index, LuaMeta.server__index); // metatable.__index
    L.setFieldFn(-1, luau.Metamethods.namecall, LuaMeta.server__namecall); // metatable.__namecall

    L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
    L.pop(1);

    L.newMetatable(LuaMeta.WEBSOCKET_META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

    L.setFieldFn(-1, luau.Metamethods.index, LuaMeta.websocket__index); // metatable.__index
    L.setFieldFn(-1, luau.Metamethods.namecall, LuaMeta.websocket__namecall); // metatable.__namecall

    L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
    L.pop(1);
}
