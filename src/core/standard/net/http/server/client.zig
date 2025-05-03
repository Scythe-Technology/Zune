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

const Request = @import("../request.zig");
const WebSocket = @import("../websocket.zig");

const Server = @import("./lib.zig");
const ClientWebSocket = @import("./websocket.zig");

const VM = luau.VM;

const Self = @This();

pub const HttpStaticResponse = struct {
    status: []const u8 = "200 OK",
    headers: []const []const u8 = &[_][]const u8{},
    body: ?[]const u8 = null,
    close: bool = true,
};

pub fn StaticResponse(comptime res: HttpStaticResponse) []const u8 {
    comptime var part: []const u8 = "HTTP/1.1 " ++ res.status ++ "\r\n";
    comptime for (res.headers) |header| {
        part = part ++ header ++ "\r\n";
    };
    part = part ++ "Server: Zune\r\n";
    comptime if (res.body) |body| jmp: {
        if (body.len == 0)
            break :jmp;
        var count = 0;
        var value = body.len;
        while (value > 0) {
            value = @divFloor(value, 10);
            count += 1;
        }
        var buf: [count]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{body.len}) catch unreachable;
        part = part ++ "Content-Length: " ++ str ++ "\r\n\r\n";
        part = part ++ body;
        if (!res.close)
            @compileError("StaticResponse with body should not have close set to false");
    } else {
        if (res.close)
            part = part ++ "\r\n";
    };

    return part;
}

pub const HTTP_405 = StaticResponse(.{
    .status = "405 Method Not Allowed",
    .headers = &[_][]const u8{"Connection: close"},
});
pub const HTTP_408 = StaticResponse(.{
    .status = "408 Request Timeout",
    .headers = &[_][]const u8{"Connection: close"},
});
pub const HTTP_413 = StaticResponse(.{
    .status = "413 Payload Too Large",
    .headers = &[_][]const u8{ "Connection: close", "Content-Type: text/plain" },
    .body = "The content you provided exceeds the server's maximum allowed size.",
});
pub const HTTP_414 = StaticResponse(.{
    .status = "414 URI Too Long",
    .headers = &[_][]const u8{ "Connection: close", "Content-Type: text/plain" },
    .body = "The URI you provided is too long.",
});
pub const HTTP_431 = StaticResponse(.{
    .status = "431 Request Header Fields Too Large",
    .headers = &[_][]const u8{ "Connection: close", "Content-Type: text/plain" },
    .body = "The headers you provided exceed the server's maximum allowed size.",
});
pub const HTTP_500 = StaticResponse(.{
    .status = "500 Internal Server Error",
    .headers = &[_][]const u8{ "Connection: close", "Content-Type: text/plain" },
    .body = "An error occurred on the server",
});
pub const HTTP_505 = StaticResponse(.{
    .status = "505 HTTP Version Not Supported",
    .headers = &[_][]const u8{"Connection: close"},
});

completion: xev.Completion,
cancel_completion: xev.Completion,
server: *Server,
socket: xev.TCP,
parser: Request.Parser,
node: LinkedList.Node = .{},
state: State = .{},
timeout: f64 = 0,

websocket: WebSocketState = .{},
buffers: Buffers = .{},

pub const WebSocketState = struct {
    active: bool = false,
    ref: luaHelper.Ref(*ClientWebSocket) = .empty,
};

pub const State = packed struct {
    stage: enum(u2) { receiving, writing, closing } = .receiving,
    websocket: bool = false,
};

pub const Buffers = struct {
    in: [8192]u8 = undefined,
    out: Multi = .none,

    pub const Multi = union(enum) {
        none: void,
        static: [8192 / 2]u8,
        dynamic: []u8,
    };
};

pub fn shortestTime(a: *Lists.LinkedNode, b: *Lists.LinkedNode) std.math.Order {
    const context_a: *Self = @fieldParentPtr("node", a);
    const context_b: *Self = @fieldParentPtr("node", b);
    if (context_a.websocket.active or context_b.websocket.active) {
        if (!context_b.websocket.active)
            return .gt
        else if (!context_a.websocket.active)
            return .lt
        else
            return .eq;
    }
    return std.math.order(context_a.timeout, context_b.timeout);
}

pub const LinkedList = Lists.PriorityLinkedList(shortestTime);

pub fn onClose(
    ud: ?*Self,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.CloseError!void,
) xev.CallbackAction {
    const self = ud orelse unreachable;
    const server = self.server;

    defer self.parser.deinit();

    server.state.list.remove(&self.node);
    server.state.free.append(&self.node);

    const GL = server.scheduler.global;
    if (self.websocket.ref.hasRef()) {
        if (self.server.handlers.ws_close.hasRef()) {
            const L = GL.newthread();
            defer GL.pop(1);

            if (self.server.handlers.ws_close.push(L)) {
                _ = self.websocket.ref.push(L);
                _ = Scheduler.resumeState(L, null, 1) catch {};
            }
        }

        self.websocket.ref.deref(GL);
        self.websocket.active = false;
    }

    if (server.state.stage == .shutdown and server.state.list.len == 0) {
        server.ref.deref(GL);
        server.state.stage = .dead;
    }

    switch (server.state.stage) {
        .max_capacity => {
            server.state.stage = .idle;
            server.startListen(&self.server.scheduler.loop);
        },
        else => {},
    }
    return .disarm;
}

pub fn close(self: *Self) void {
    self.state.stage = .closing;
    self.socket.close(
        &self.server.scheduler.loop,
        &self.completion,
        Self,
        self,
        onClose,
    );
}

// Handles stopping the websocket writer (if active)
// canceling the writer would eventually call `close`.
pub fn ws_close(self: *Self, loop: *xev.Loop) void {
    std.debug.assert(self.websocket.ref.ref != null);
    const websocket = self.websocket.ref.value;
    websocket.closed = true;

    self.state.stage = .closing;
    if (websocket.sending) {
        loop.cancel(
            &websocket.completion,
            &self.completion,
            void,
            null,
            Scheduler.XevNoopCallback(xev.CancelError!void, .disarm),
        );
    } else self.close();
}

pub fn onWrite(
    ud: ?*Self,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    b: xev.WriteBuffer,
    res: xev.WriteError!usize,
) xev.CallbackAction {
    const self = ud orelse unreachable;
    const allocator = self.parser.arena.child_allocator;

    const written = res catch |err| {
        switch (self.buffers.out) {
            .none, .static => {},
            .dynamic => |buf| allocator.free(buf),
        }
        self.buffers.out = .none;
        self.close();
        switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => return .disarm,
            else => {
                std.debug.print("Error writing to client: {}\n", .{err});
                return .disarm;
            },
        }
    };

    const remaining = b.slice[written..];
    if (remaining.len == 0) {
        switch (self.buffers.out) {
            .none, .static => {},
            .dynamic => |buf| allocator.free(buf),
        }
        self.buffers.out = .none;
        if (self.state.stage != .closing) {
            if (self.websocket.active) {
                @branchHint(.cold); // we only get here once, when client upgrades.
                const GL = self.server.scheduler.global;
                const L = GL.newthread();
                defer GL.pop(1);

                const websocket = L.newuserdatadtor(ClientWebSocket, ClientWebSocket.__dtor);
                _ = L.Lgetmetatable(@typeName(ClientWebSocket));
                _ = L.setmetatable(-2);

                websocket.* = .{
                    .client = self,
                    .allocator = allocator,
                    .completion = .init(),
                    .closed = false,
                    .sending = false,
                    .message_queue = .{},
                };

                self.websocket.ref = .init(L, -1, websocket);

                if (self.server.handlers.ws_open.push(L)) {
                    L.pushvalue(-2);
                    _ = Scheduler.resumeState(L, null, 1) catch {};
                }
                self.parser.reset();
                self.start(loop, false);
                return .disarm;
            } else if (self.parser.canKeepAlive()) {
                self.parser.reset();
                self.start(loop, false);
                return .disarm;
            }
        }
        self.close();
    } else {
        socket.write(
            loop,
            completion,
            .{ .slice = remaining },
            Self,
            self,
            onWrite,
        );
    }
    return .disarm;
}

pub fn writeAll(self: *Self, message: []const u8) void {
    const allocator = self.parser.arena.child_allocator;
    var slice: []u8 = undefined;
    if (message.len <= @typeInfo(
        @typeInfo(Buffers.Multi).@"union".fields[1].type,
    ).array.len) {
        self.buffers.out = .{ .static = undefined };
        slice = self.buffers.out.static[0..message.len];
        @memcpy(slice, message);
    } else {
        const buffer = allocator.dupe(u8, message) catch return self.close();
        self.buffers.out = .{ .dynamic = buffer };
        slice = buffer;
    }
    self.socket.write(
        &self.server.scheduler.loop,
        &self.completion,
        .{ .slice = slice },
        Self,
        self,
        onWrite,
    );
}

pub fn processResponse(
    self: *Self,
    allocator: std.mem.Allocator,
    L: *VM.lua.State,
) !void {
    switch (L.typeOf(-1)) {
        .Table => {
            if (L.getfield(-1, "statusCode") != .Number) {
                L.pop(1);
                L.pushlstring("Field 'statusCode' must be a number");
                return error.Runtime;
            }
            const statusCode = L.Lcheckinteger(-1);
            if (statusCode < 100 or statusCode > 599) {
                L.pop(1);
                L.pushlstring("Status code must be between 100 and 599");
                return error.Runtime;
            }

            var response: std.ArrayListUnmanaged(u8) = try .initCapacity(allocator, 1024 * 2);
            defer response.deinit(allocator);

            const writer = response.writer(allocator);

            try writer.print("HTTP/1.1 {d} {s}\r\n", .{
                statusCode,
                std.http.Status.phrase(@enumFromInt(statusCode)).?,
            });

            var written_headers: packed struct {
                content_type: bool = false,
                content_length: bool = false,
                date: bool = false,
                server: bool = false,
            } = .{};

            const headersType = L.getfield(-2, "headers");
            if (!headersType.isnoneornil()) {
                if (headersType != .Table) {
                    L.pop(1);
                    L.pushlstring("invalid field 'headers' (expected table)");
                    return error.Runtime;
                }
                if (!L.rawgetfield(-1, "Content-Type").isnoneornil()) {
                    written_headers.content_type = true;
                }
                L.pop(1);
                if (!L.rawgetfield(-1, "Content-Length").isnoneornil()) {
                    written_headers.content_length = true;
                }
                L.pop(1);
                if (!L.rawgetfield(-1, "Date").isnoneornil()) {
                    written_headers.date = true;
                }
                L.pop(1);
                if (!L.rawgetfield(-1, "Server").isnoneornil()) {
                    written_headers.server = true;
                }
                L.pop(1);
                var i: i32 = L.rawiter(-1, 0);
                while (i >= 0) : (i = L.rawiter(-1, i)) {
                    if (L.typeOf(-2) != .String) {
                        L.pop(1);
                        L.pushlstring("invalid header key (expected string)");
                        return error.Runtime;
                    }
                    if (L.typeOf(-1) != .String) {
                        L.pop(1);
                        L.pushlstring("invalid header value (expected string)");
                        return error.Runtime;
                    }
                    const header_value = L.tostring(-1).?;
                    if (header_value.len > 0)
                        try writer.print("{s}: {s}\r\n", .{
                            L.tostring(-2).?,
                            header_value,
                        });

                    L.pop(2);
                }
            }

            if (!written_headers.content_type) {
                try response.appendSlice(allocator, "Content-Type: text/plain\r\n");
            }
            if (!written_headers.date) {
                try response.appendSlice(allocator, "Date: ");
                try time.Datetime.nowUTC().toString("%:a, %d %:b %Y %H:%M:%S GMT", writer);
                try response.appendSlice(allocator, "\r\n");
            }
            if (!written_headers.server) {
                try response.appendSlice(allocator, "Server: Zune\r\n");
            }

            const body: ?[]const u8 = switch (L.getfield(-3, "body")) {
                .String => L.Lcheckstring(-1),
                .Buffer => L.Lcheckbuffer(-1),
                .Nil => null,
                else => {
                    L.pop(1);
                    L.pushlstring("invalid field 'body' must be a string or buffer");
                    return error.Runtime;
                },
            };

            if (body) |b| {
                if (!written_headers.content_length)
                    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ b.len, b })
                else
                    try writer.print("\r\n{s}", .{b});
            } else {
                try response.appendSlice(allocator, "\r\n");
            }

            self.writeAll(response.items);
        },
        .String, .Buffer => |t| {
            const content = if (t == .Buffer) L.Lcheckbuffer(-1) else L.Lcheckstring(-1);
            var buf: [48]u8 = undefined;

            var stream = std.io.fixedBufferStream(&buf);
            const writer = stream.writer();

            try writer.writeAll("Date: ");
            try time.Datetime.nowUTC().toString("%:a, %d %:b %Y %H:%M:%S GMT", writer);

            const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n{s}\r\nServer: Zune\r\nContent-Length: {d}\r\n\r\n{s}", .{ stream.getWritten(), content.len, content });
            defer allocator.free(response);
            self.writeAll(response);
        },
        else => {
            L.pop(1);
            L.pushlstring("Serve response must be a table, string or buffer");
            return error.Runtime;
        },
    }
}

pub fn ws_upgradeResumed(self: *Self, L: *VM.lua.State, _: *Scheduler) void {
    if (L.status() != .Ok) {
        self.state.stage = .closing;
        self.writeAll(HTTP_500);
        return;
    }

    const top = L.gettop();
    std.debug.assert(top >= 2);
    if (top < 3) { // only a lua function could have less than 3 on top
        @branchHint(.unlikely);
        L.pushlstring("Upgrade must return a boolean");
        Engine.logFnDef(L, -2);
        self.state.stage = .closing;
        self.writeAll(HTTP_500);
        return;
    } else if (top > 3) {
        @branchHint(.unlikely);
        L.pop(@intCast(top - 2));
        L.pushlstring("Upgrade returned too many values");
        Engine.logFnDef(L, -2);
        self.state.stage = .closing;
        self.writeAll(HTTP_500);
        return;
    }

    const upgrade = switch (L.typeOf(-1)) {
        .Boolean => L.toboolean(-1),
        else => {
            L.pop(1);
            L.pushlstring("Upgrade must return a boolean");
            Engine.logFnDef(L, -2);
            self.state.stage = .closing;
            self.writeAll(HTTP_500);
            return;
        },
    };

    if (!upgrade) {
        self.state.stage = .closing;
        self.writeAll(StaticResponse(.{
            .status = "403 Forbidden",
            .headers = &[_][]const u8{ "Connection: close", "Content-Type: text/plain" },
            .body = "WebSocket upgrade rejected",
        }));
        return;
    }

    const upgrade_response = L.tostring(1).?;

    self.websocket.active = true;
    self.writeAll(upgrade_response);
}

const WebSocketFrameState = struct {
    info: u8 = 0,
    written: usize = 0,
    allocated: ?[]u8 = null,
};

pub fn ws_onRecv(
    ud: ?*Self,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.ReadBuffer,
    res: xev.ReadError!usize,
) xev.CallbackAction {
    const self = ud orelse unreachable;

    const websocket = self.websocket.ref.value;

    const read = res catch |err| switch (err) {
        error.Canceled => {
            self.ws_close(loop);
            return .disarm;
        },
        error.EOF, error.ConnectionResetByPeer => {
            self.ws_close(loop);
            return .disarm;
        },
        else => {
            std.debug.print("Error reading from client: {}\n", .{err});
            self.ws_close(loop);
            return .disarm;
        },
    };

    const allocator = self.parser.arena.allocator();
    const static = &self.buffers.out.static;
    const frame_state: *WebSocketFrameState = @ptrCast(@alignCast(static[0..@sizeOf(WebSocketFrameState)]));
    const frame_buffer = static[@sizeOf(WebSocketFrameState)..];

    var pos: usize = 0;
    var stream = std.io.fixedBufferStream(self.buffers.in[0..read]);
    const reader = stream.reader();

    while (true) {
        const header: WebSocket.WebsocketHeader = blk: {
            const stored = frame_state.info;
            if (stored >= 2)
                break :blk @bitCast(std.mem.readVarInt(u16, frame_buffer[0..2], .big));
            const needed = 2 - stored;
            const amount = reader.read(frame_buffer[stored .. stored + needed]) catch unreachable;
            frame_state.info += @intCast(amount);
            if (amount < needed) {
                return .rearm;
            }
            break :blk @bitCast(std.mem.readVarInt(u16, frame_buffer[0..2], .big));
        };

        if (!header.mask) {
            if (websocket.closed)
                continue;
            static[0] = 0;
            websocket.sendCloseFrame(loop, 1002) catch |err| {
                std.debug.print("Failed to send close frame: {}\n", .{err});
                self.ws_close(loop);
                return .disarm;
            };
        }

        pos = 2;

        var payload: []u8 = undefined;
        const written: usize = frame_state.written;

        const length: usize = switch (header.len) {
            126 => blk: {
                const stored = frame_state.info - 2;
                if (stored >= 2) {
                    break :blk @as(usize, @intCast(std.mem.readVarInt(u16, frame_buffer[pos .. pos + 2], .big)));
                }
                const needed = 2 - stored;
                const amount = reader.read(frame_buffer[pos + stored .. pos + stored + needed]) catch unreachable;
                frame_state.info += @intCast(amount);
                if (amount < needed) {
                    return .rearm;
                }
                defer pos += 2;
                break :blk @as(usize, @intCast(std.mem.readVarInt(u16, frame_buffer[pos .. pos + 2], .big)));
            },
            127 => blk: {
                const stored = frame_state.info - 2;
                if (stored >= 8) {
                    break :blk @as(usize, @intCast(std.mem.readVarInt(u64, frame_buffer[pos .. pos + 8], .big)));
                }
                const needed = 8 - stored;
                const amount = reader.read(frame_buffer[pos + stored .. pos + stored + needed]) catch unreachable;
                frame_state.info += @intCast(amount);
                if (amount < needed) {
                    return .rearm;
                }
                defer pos += 8;
                break :blk @as(usize, @bitCast(std.mem.readVarInt(u64, frame_buffer[pos .. pos + 8], .big)));
            },
            else => header.len,
        } + 4; // 4 (masked)

        if (length > luaHelper.MAX_LUAU_SIZE) {
            websocket.sendCloseFrame(loop, 1009) catch |err| {
                std.debug.print("Failed to send close frame: {}\n", .{err});
                self.ws_close(loop);
                return .disarm;
            };
            continue;
        }

        if (length > frame_buffer.len - pos) {
            const new_buf = frame_state.allocated orelse allocator.alloc(u8, length) catch |err| {
                std.debug.print("Failed to allocate websocket frame buffer: {}\n", .{err});
                self.ws_close(loop);
                return .disarm;
            };
            payload = new_buf;
            frame_state.allocated = new_buf;
        } else {
            payload = frame_buffer[pos .. pos + length];
        }

        if (written < length) {
            const needed = length - written;
            const amount = reader.read(payload[written .. written + needed]) catch unreachable;
            frame_state.written += @intCast(amount);
            if (amount < needed) {
                return .rearm;
            }
        }

        const data = payload[4..];
        const mask = payload[0..4];
        // Decode data in place
        for (data, 0..) |_, i| {
            data[i] ^= mask[i % 4];
        }

        defer frame_state.info = 0;
        defer frame_state.written = 0;
        defer if (frame_state.allocated) |b| {
            allocator.free(b);
            frame_state.allocated = null;
        };

        const scheduler = self.server.scheduler;

        switch (header.opcode) {
            .Binary, .Text => {},
            .Ping => {
                websocket.sendPongFrame(loop) catch |err| {
                    std.debug.print("Failed to send pong frame: {}\n", .{err});
                    self.ws_close(loop);
                    return .disarm;
                };
                continue;
            },
            .Pong => continue,
            .Close => {
                if (!websocket.closed) jmp: {
                    websocket.closed = true;
                    const code = if (data.len >= 2) std.mem.readVarInt(u16, data[0..2], .big) else 1000;
                    // we received a close frame, we should send a close frame back.
                    // its possible we might have messages in queue
                    websocket.sendCloseFrame(loop, code) catch |err| {
                        std.debug.print("Failed to send close frame: {}\n", .{err});
                        break :jmp;
                    };
                    return .rearm;
                }
                self.ws_close(loop);
                return .disarm;
            },
            .Continue => continue,
            else => {
                std.debug.print("Unknown opcode: {}\n", .{header.opcode});
                self.ws_close(loop);
                return .disarm;
            },
        }

        if (self.server.handlers.ws_message.hasRef()) {
            const GL = scheduler.global;
            const L = GL.newthread();
            defer GL.pop(1);

            if (self.server.handlers.ws_message.push(L)) {
                _ = self.websocket.ref.push(L);
                switch (header.opcode) {
                    .Binary => L.Zpushbuffer(data),
                    .Text => L.pushlstring(data),
                    else => unreachable,
                }
                _ = Scheduler.resumeState(L, null, 2) catch {};
            } else unreachable;
        }
    }
}

pub fn requestResumed(self: *Self, L: *VM.lua.State, _: *Scheduler) void {
    const allocator = self.parser.arena.child_allocator;

    if (L.status() != .Ok) {
        self.state.stage = .closing;
        self.writeAll(HTTP_500);
        return;
    }

    const top = L.gettop();
    std.debug.assert(top >= 1);
    if (top > 2) {
        @branchHint(.unlikely);
        L.pop(@intCast(top - 1));
        L.pushlstring("Request returned too many values");
        Engine.logFnDef(L, -2);
        self.state.stage = .closing;
        self.writeAll(HTTP_500);
        return;
    }

    self.processResponse(allocator, L) catch |err| {
        if (err == error.Runtime)
            Engine.logFnDef(L, -2);
        self.state.stage = .closing;
        self.writeAll(HTTP_500);
        return;
    };
}

pub fn onRecv(
    ud: ?*Self,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.ReadBuffer,
    res: xev.ReadError!usize,
) xev.CallbackAction {
    const self = ud orelse unreachable;

    const read = res catch |err| switch (err) {
        error.Canceled => {
            self.close();
            return .disarm;
        },
        error.EOF, error.ConnectionResetByPeer => {
            self.close();
            return .disarm;
        },
        else => {
            std.debug.print("Error reading from client: {}\n", .{err});
            self.close();
            return .disarm;
        },
    };

    switch (self.server.state.stage) {
        .dead, .shutdown => {
            self.close();
            return .disarm;
        },
        else => {},
    }

    if (self.parser.parse(self.buffers.in[0..read]) catch |err| {
        self.state.stage = .closing;
        switch (err) {
            error.InvalidContentLength => self.writeAll(HTTP_413),
            error.UnknownMethod => self.writeAll(HTTP_405),
            error.UnknownProtocol => self.writeAll(HTTP_431),
            error.InvalidRequestTarget => self.writeAll(HTTP_414),
            error.TooManyHeaders => self.writeAll(HTTP_431),
            error.UnsupportedProtocol => self.writeAll(HTTP_505),
            else => {},
        }
        return .disarm;
    }) {
        @branchHint(.likely);
        self.state.stage = .writing;
        const scheduler = self.server.scheduler;
        const GL = scheduler.global;
        const L = GL.newthread();
        defer GL.pop(1);
        const luau_handlers = &self.server.handlers;
        if (self.parser.method == .GET) {
            if (self.parser.headers.get("connection")) |connection| jmp: {
                @branchHint(.unlikely);
                if (!luau_handlers.hasWebSocket())
                    break :jmp; // user did not supply websocket handlers
                if (!std.ascii.eqlIgnoreCase(connection, "upgrade"))
                    break :jmp;
                if (self.parser.headers.get("upgrade")) |upgrade| {
                    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket"))
                        break :jmp;
                }
                const version = self.parser.headers.get("sec-websocket-version") orelse break :jmp;
                if (version.len < 2 or version[0] != '1' or version[1] != '3') {
                    self.state.stage = .closing;
                    self.writeAll(StaticResponse(.{
                        .status = "426 Upgrade Required",
                        .headers = &[_][]const u8{ "Connection: close", "Sec-WebSocket-Version: 13", "Content-Type: text/plain" },
                        .body = "Unsupported WebSocket version. Use 13.",
                    }));
                    return .disarm;
                }
                const key = self.parser.headers.get("sec-websocket-key") orelse break :jmp;
                if (key.len != 24) {
                    self.state.stage = .closing;
                    self.writeAll(StaticResponse(.{
                        .status = "400 Bad Request",
                        .headers = &[_][]const u8{ "Connection: close", "Content-Type: text/plain" },
                        .body = "Invalid WebSocket key.",
                    }));
                    return .disarm;
                }
                const protocols = self.parser.headers.get("sec-websocket-protocol");
                var accept_key: [28]u8 = undefined;

                var hash = std.crypto.hash.Sha1.init(.{});
                hash.update(key);
                hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"); // https://www.rfc-editor.org/rfc/rfc6455

                _ = std.base64.standard.Encoder.encode(&accept_key, &hash.finalResult());

                const base_response = StaticResponse(.{
                    .status = "101 Switching Protocols",
                    .headers = &[_][]const u8{
                        "Upgrade: websocket",
                        "Connection: Upgrade",
                    },
                    .close = false,
                });
                const allocator = self.parser.arena.child_allocator;
                const accept_response = std.mem.concat(allocator, u8, &.{
                    base_response,
                    "Sec-WebSocket-Accept: ",
                    accept_key[0..28],
                    if (protocols != null) "\r\nSec-WebSocket-Protocol: " else "",
                    if (protocols) |p| p else "",
                    "\r\n\r\n",
                }) catch |err| {
                    std.debug.print("Failed to allocate websocket accept response: {}\n", .{err});
                    self.state.stage = .closing;
                    self.writeAll(HTTP_500);
                    return .disarm;
                };
                defer allocator.free(accept_response);
                L.pushlstring(accept_response);
                if (luau_handlers.ws_upgrade.push(L)) {
                    L.pushvalue(-1);
                    self.parser.push(L) catch |err| switch (err) {
                        error.MaxQueryExceeded => {
                            self.state.stage = .closing;
                            self.writeAll(HTTP_414);
                            return .disarm;
                        },
                        else => std.debug.panic("{}\n", .{err}), // OOM
                    };
                    scheduler.awaitCall(Self, self, L, null, 1, ws_upgradeResumed, null);
                } else {
                    L.pushnil();
                    L.pushboolean(true);
                    ws_upgradeResumed(self, L, scheduler);
                }
                return .disarm;
            }
        }
        if (luau_handlers.request.push(L)) {
            @branchHint(.likely);
            L.pushvalue(-1);
            self.parser.push(L) catch |err| switch (err) {
                error.MaxQueryExceeded => {
                    self.state.stage = .closing;
                    self.writeAll(HTTP_414);
                    return .disarm;
                },
                else => std.debug.panic("{}\n", .{err}), // OOM
            };
            scheduler.awaitCall(Self, self, L, null, 1, requestResumed, null);
        } else {
            std.debug.panic("unreachable", .{});
        }
        return .disarm;
    } else {
        // TODO: optimize body, when dynamic body is present, and parsing body, use entire body buffer
        // switch (self.parser.stage) {
        //     .body => {
        //         socket.read(
        //             loop,
        //             completion,
        //             .{ .slice = self.parser.body.?[self.] },
        //             Self,
        //             self,
        //             onRecv,
        //         );
        //     },
        //     else => {},
        // }
        return .rearm;
    }
}

pub fn start(
    self: *Self,
    loop: *xev.Loop,
    comptime first: bool,
) void {
    self.state.stage = .receiving;
    self.timeout = VM.lperf.clock() + @as(f64, @floatFromInt(self.server.state.client_timeout));
    if (!first)
        self.server.state.list.remove(&self.node);
    self.server.state.list.addBack(&self.node);
    self.server.reloadTimer(loop);
    if (self.websocket.ref.hasRef()) {
        // write buffer wouldn't be used anymore
        // so we can use it for parsing websocket frames
        self.buffers.out = .{ .static = undefined };
        const state: *WebSocketFrameState = @ptrCast(@alignCast(self.buffers.out.static[0..@sizeOf(WebSocketFrameState)]));
        state.* = .{
            .info = 0,
            .written = 0,
            .allocated = null,
        };
        self.socket.read(
            loop,
            &self.completion,
            .{ .slice = &self.buffers.in },
            Self,
            self,
            ws_onRecv,
        );
    } else {
        self.socket.read(
            loop,
            &self.completion,
            .{ .slice = &self.buffers.in },
            Self,
            self,
            onRecv,
        );
    }
}
