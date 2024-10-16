const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");
const zune_info = @import("zune-info");

const Common = @import("common.zig");

const Scheduler = @import("../../runtime/scheduler.zig");
const Response = @import("http/response.zig");
const WebSocket = @import("http/websocket.zig");

const VStream = @import("http/vstream.zig");

const Luau = luau.Luau;

const context = Common.context;
const prepRefType = Common.prepRefType;

const ZUNE_CLIENT_HEADER = "Zune/" ++ zune_info.version;

const Self = @This();

stream: ?*VStream,
establishedLua: ?i32,
connected: bool,
handlers: LuaWebSocketClient.Handlers,
key: []u8,
protocols: std.ArrayList([]const u8),
fds: []context.spollfd,

const LuaWebSocketClient = struct {
    ptr: ?*Self,

    pub const Handlers = struct {
        open: ?i32,
        message: ?i32,
        close: ?i32,
    };
};

pub const LuaMeta = struct {
    pub const WEBSOCKET_META = "net_client_ws_instance";
    pub fn __index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const data = L.toUserdata(LuaWebSocketClient, 1) catch unreachable;

        const arg = L.checkString(2);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, arg, "connected")) {
            L.pushBoolean(data.ptr != null and data.ptr.?.connected);
            return 1;
        }
        return 0;
    }

    pub fn __namecall(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const data = L.toUserdata(LuaWebSocketClient, 1) catch unreachable;

        const namecall = L.nameCallAtom() catch return 0;

        const ctx = data.ptr orelse return 0;
        const stream = ctx.stream orelse return 0;

        if (!ctx.connected) return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "close")) {
            const closeCode: u16 = @intCast(L.optInteger(2) orelse 1000);
            var socket = WebSocket.initV(L.allocator(), stream, true);
            defer socket.deinit();
            socket.close(closeCode) catch |err| {
                std.debug.print("Error writing close: {}\n", .{err});
            };
            ctx.closeConnection(L, true, closeCode);
        } else if (std.mem.eql(u8, namecall, "send")) {
            const message = L.checkString(2);
            var socket = WebSocket.initV(L.allocator(), stream, true);
            defer socket.deinit();
            _ = socket.writeText(message) catch |err| L.raiseErrorStr("Failed to write to websocket (%s)", .{@errorName(err).ptr});
        } else if (std.mem.eql(u8, namecall, "bindOpen")) {
            L.checkType(2, .function);
            const fnRef = L.ref(2) catch return 0;
            ctx.handlers.open = fnRef;
        } else if (std.mem.eql(u8, namecall, "bindMessage")) {
            L.checkType(2, .function);
            const fnRef = L.ref(2) catch return 0;
            ctx.handlers.message = fnRef;
        } else if (std.mem.eql(u8, namecall, "bindClose")) {
            L.checkType(2, .function);
            const fnRef = L.ref(2) catch return 0;
            ctx.handlers.close = fnRef;
        } else L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr});
        return 0;
    }
};

pub fn closeConnection(ctx: *Self, L: *Luau, cleanUp: bool, codeCode: ?u16) void {
    if (ctx.stream) |stream| {
        const allocator = L.allocator();
        defer {
            stream.close();
            ctx.fds[0].fd = context.INVALID_SOCKET;
            allocator.destroy(stream);
            ctx.stream = null;
        }
        if (!cleanUp) {
            // send close frame
            if (ctx.establishedLua != null) {
                var socket = WebSocket.initV(allocator, stream, true);
                defer socket.deinit();
                socket.close(1001) catch |err| {
                    std.debug.print("Error closing websocket: {}\n", .{err});
                };
            }
        }
        if (ctx.handlers.close) |fnRef| {
            if (!prepRefType(.function, L, fnRef)) {
                std.debug.print("Function not found\n", .{});
                return;
            }

            const thread = L.newThread();
            L.xPush(thread, -2); // push: Function
            if (codeCode) |code| thread.pushInteger(@intCast(code)) else thread.pushNil();
            L.pop(2); // drop thread & function

            _ = Scheduler.resumeState(thread, L, 1) catch {};
        }
    }
}

pub fn handleSocket(ctx: *Self, L: *Luau, socket: *WebSocket) Scheduler.TaskResult {
    const frame = socket.read() catch |err| {
        std.debug.print("Error reading from websocket: {}\n", .{err});

        ctx.closeConnection(L, true, 1006);
        if (err == error.ConnectionClosed) {
            std.debug.print("Connection closed\n", .{});
        }
        return .Stop;
    };

    switch (frame.header.opcode) {
        .Ping => {
            _ = socket.writeMessage(.Pong, frame.data) catch |err| {
                std.debug.print("Error writing pong: {}\n", .{err});
            };
        },
        .Pong => {
            // Do nothing
        },
        .Close => {
            if (frame.data.len < 2) {
                std.debug.print("Close frame received with no data\n", .{});
                ctx.closeConnection(L, true, 1006);
                return .Stop;
            }
            const code: u16 = @byteSwap(@as(u16, @bitCast(frame.data[0..2].*)));
            ctx.closeConnection(L, true, code);
            return .Stop;
        },
        .Text, .Binary => {
            if (ctx.handlers.message) |fnRef| {
                if (!prepRefType(.function, L, fnRef)) {
                    std.debug.print("Function not found\n", .{});
                    return .Stop;
                }

                const thread = L.newThread();
                L.xPush(thread, -2); // push: Function
                L.pop(2); // drop thread & function

                thread.pushLString(frame.data); // push: string

                _ = Scheduler.resumeState(thread, L, 1) catch {};
            }
        },
        else => {
            std.debug.print("Unknown opcode: {}\n", .{frame.header.opcode});
            std.debug.print("data: {s}", .{frame.data});
        },
    }
    return .Continue;
}

pub fn update(ctx: *Self, L: *Luau, scheduler: *Scheduler) Scheduler.TaskResult {
    const allocator = L.allocator();

    const fds = ctx.fds;
    const stream = ctx.stream orelse return .Stop;

    const nums = context.spoll(fds, 1) catch std.debug.panic("Bad poll (1)", .{});
    if (nums == 0)
        return .Continue;
    if (nums < 0)
        std.debug.panic("Bad poll (2)", .{});

    const sockfd = fds[0];
    if (sockfd.revents & (context.POLLIN) != 0) {
        if (ctx.establishedLua == null) {
            var response = Response.init(allocator, stream, .{}) catch |err| {
                std.debug.print("Error: {}\n", .{err});
                return .Stop;
            };
            defer response.deinit();

            if (response.getHeader("sec-websocket-accept")) |header| {
                if (!std.mem.eql(u8, header.value, ctx.key)) {
                    std.debug.print("Websocket Error (Bad Accept)\n", .{});
                    return .Stop;
                }
            } else return .Stop;

            L.pushBoolean(true);
            const data = L.newUserdata(LuaWebSocketClient);
            data.ptr = ctx;

            if (L.getMetatableRegistry(LuaMeta.WEBSOCKET_META) == .table) {
                L.setMetatable(-2);
            } else {
                std.debug.panic("InternalError (WebSocketClient not initialized)", .{});
            }

            ctx.connected = response.statusCode == 101;
            ctx.establishedLua = L.ref(-1) catch std.debug.panic("InternalError (WebSocketClient bad ref)", .{});

            _ = Scheduler.resumeState(L, null, 2) catch {};

            if (response.statusCode != 101) {
                ctx.closeConnection(L, false, null);
                return .Stop;
            } else {
                if (ctx.handlers.open) |fnRef| {
                    if (!prepRefType(.function, L, fnRef)) {
                        std.debug.print("Function not found\n", .{});
                        return .Stop;
                    }

                    const thread = L.newThread();
                    L.xPush(thread, -2); // push: Function
                    L.pop(2); // drop: thread & function

                    _ = Scheduler.resumeState(thread, L, 0) catch {};
                    _ = scheduler;
                }

                const leftOver = response.buffer[response.pos..response.bufferLen];
                if (leftOver.len == 0)
                    return .ContinueFast;
                // TODO: Handle huge buffers
                // using MergedStream to handle data over the stream buffer
                // currently stream.read BLOCKS if no data is available.
                if (leftOver.len + response.pos == response.buffer.len)
                    return .ContinueFast;

                var leftOverStream = std.io.FixedBufferStream([]u8){
                    .buffer = leftOver,
                    .pos = 0,
                };

                var socket = WebSocket.initAnyV(allocator, leftOverStream.reader().any(), stream.writer(), true);
                defer socket.deinit();

                return ctx.handleSocket(L, &socket);
            }
        } else {
            var socket = WebSocket.initV(allocator, stream, true);
            defer socket.deinit();

            return ctx.handleSocket(L, &socket);
        }
    } else if (sockfd.revents & (context.POLLNVAL | context.POLLERR | context.POLLHUP) != 0) return .Stop;

    return .ContinueFast;
}

pub fn dtor(ctx: *Self, L: *Luau, scheduler: *Scheduler) void {
    _ = scheduler;
    const allocator = L.allocator();

    defer {
        ctx.closeConnection(L, true, null);

        allocator.free(ctx.fds);
        allocator.free(ctx.key);
        if (ctx.stream) |ptr|
            allocator.destroy(ptr);
        allocator.destroy(ctx);
    }

    if (ctx.handlers.close) |function| L.unref(function);
    if (ctx.handlers.message) |function| L.unref(function);
    if (ctx.handlers.open) |function| L.unref(function);

    ctx.protocols.deinit();

    if (ctx.establishedLua) |wsRef| {
        if (prepRefType(.userdata, L, wsRef)) {
            const data = L.toUserdata(LuaWebSocketClient, -1) catch unreachable;
            data.ptr = null;
            L.pop(1);
        }
        L.unref(wsRef);
        ctx.establishedLua = null;
    } else {
        L.pushBoolean(false);
        L.pushString("Websocket not established");
        _ = Scheduler.resumeState(L, null, 2) catch {};
    }
}

// based on std.http.Client.validateUri
pub fn validateUri(uri: std.Uri, arena: std.mem.Allocator) !struct { std.http.Client.Connection.Protocol, std.Uri } {
    const protocol_map = std.StaticStringMap(std.http.Client.Connection.Protocol).initComptime(.{
        .{ "ws", .plain },
        .{ "wss", .tls },
    });
    const protocol = protocol_map.get(uri.scheme) orelse return error.UnsupportedUriScheme;
    var valid_uri = uri;
    valid_uri.host = .{
        .raw = try (uri.host orelse return error.UriMissingHost).toRawMaybeAlloc(arena),
    };
    return .{ protocol, valid_uri };
}

pub fn generateKey(encoded: []u8) void {
    var key: [16]u8 = undefined;
    std.crypto.random.bytes(&key);
    _ = std.base64.standard.Encoder.encode(encoded, &key);
}

pub fn prep(allocator: std.mem.Allocator, L: *Luau, scheduler: *Scheduler, uri: []const u8, protocols: std.ArrayList([]const u8)) !bool {
    errdefer protocols.deinit();
    var uri_buffer: [1024]u8 = undefined;
    var fixedBuffer = std.heap.FixedBufferAllocator.init(&uri_buffer);

    const protocol, const valid_uri = try validateUri(try std.Uri.parse(uri), fixedBuffer.allocator());

    const host = valid_uri.host.?.raw;

    const stream = try std.net.tcpConnectToHost(allocator, host, valid_uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    });

    var tls: ?std.crypto.tls.Client = null;
    if (protocol == .tls) {
        var bundle = std.crypto.Certificate.Bundle{};
        try bundle.rescan(allocator);
        defer bundle.deinit(allocator);
        tls = try std.crypto.tls.Client.init(stream, bundle, host);
    }

    var vstream = VStream.init(stream, tls);

    const joined_protocols = try std.mem.join(allocator, ", ", protocols.items);
    defer allocator.free(joined_protocols);

    const encoded_key = try allocator.alloc(u8, 24);
    defer allocator.free(encoded_key);

    generateKey(encoded_key);

    const accept_key = try WebSocket.acceptHashKey(allocator, encoded_key);
    errdefer allocator.free(accept_key);

    const request = std.mem.concat(allocator, u8, &.{
        "GET ",
        if (valid_uri.path.percent_encoded.len > 0) valid_uri.path.percent_encoded else "/",
        if (valid_uri.query != null) "?" else "",
        if (valid_uri.query) |query| query.percent_encoded else "",
        " HTTP/1.1",
        "\r\nHost: ",
        host,
        "\r\nContent-Length: 0\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
        encoded_key,
        if (joined_protocols.len > 0) "\r\nSec-WebSocket-Protocol: " else "",
        if (joined_protocols.len > 0) joined_protocols else "",
        "\r\nUser-Agent: ",
        ZUNE_CLIENT_HEADER,
        "\r\n\r\n",
    }) catch |err| {
        std.debug.print("Error creating response: {}\n", .{err});
        return err;
    };
    defer allocator.free(request);

    try vstream.writeAll(request);

    const streamPtr = try allocator.create(VStream);
    errdefer allocator.destroy(streamPtr);
    streamPtr.* = vstream;

    const webSocketPtr = try allocator.create(Self);
    errdefer allocator.destroy(webSocketPtr);

    var fds = try allocator.alloc(context.spollfd, 1);
    fds[0].fd = stream.handle;
    fds[0].events = context.POLLIN;

    webSocketPtr.* = .{
        .fds = fds,
        .key = accept_key,
        .establishedLua = null,
        .connected = false,
        .stream = streamPtr,
        .protocols = protocols,
        .handlers = .{
            .open = null,
            .message = null,
            .close = null,
        },
    };

    scheduler.addTask(Self, webSocketPtr, L, update, dtor);

    return true;
}

pub fn lua_websocket(L: *Luau, scheduler: *Scheduler) i32 {
    const uriString = L.checkString(1);
    const allocator = L.allocator();

    var protocols = std.ArrayList([]const u8).init(allocator);

    const protocolsType = L.typeOf(2);
    if (protocolsType != .nil and protocolsType != .none) {
        L.checkType(2, .table);
        L.pushNil(); // Key starts as nil
        var order: c_int = 1;
        while (L.next(2)) {
            const keyType = L.typeOf(-2);
            const valueType = L.typeOf(-1);
            if (keyType != luau.LuaType.number) L.raiseErrorStr("Table is not an array", .{});
            if (L.toInteger(-2) catch unreachable != order) L.raiseErrorStr("Table is not an array", .{});
            if (valueType != luau.LuaType.string) L.raiseErrorStr("Value must be a string", .{});
            const value = L.toString(-1) catch unreachable;
            protocols.append(value) catch L.raiseErrorStr("OutOfMemory", .{});
            order += 1;
            L.pop(1);
        }
    }

    const created = prep(allocator, L, scheduler, uriString, protocols) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        L.pushBoolean(false);
        L.pushString(@errorName(err));
        return 2;
    };

    if (created) return L.yield(0);

    L.pushBoolean(false);
    L.pushString("Failed to create websocket");

    return 2;
}

pub fn lua_load(L: *Luau) void {
    L.newMetatable(LuaMeta.WEBSOCKET_META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

    L.setFieldFn(-1, luau.Metamethods.index, LuaMeta.__index); // metatable.__index
    L.setFieldFn(-1, luau.Metamethods.namecall, LuaMeta.__namecall); // metatable.__namecall

    L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
    L.pop(1);
}
