const std = @import("std");
const xev = @import("xev").Dynamic;
const time = @import("datetime");
const luau = @import("luau");
const builtin = @import("builtin");

const Engine = @import("../../../../runtime/engine.zig");
const Scheduler = @import("../../../../runtime/scheduler.zig");

const WebSocket = @import("../websocket.zig");

const MethodMap = @import("../../../../utils/method_map.zig");
const Lists = @import("../../../../utils/lists.zig");

const VM = luau.VM;

const ClientContext = @import("client.zig");

/// Zune server WebSocket client
const Self = @This();

completion: xev.Completion,
client: *ClientContext,
closed: bool = false,
sending: bool = false,
close_code: u16 = 1000,
message_queue: Lists.DoublyLinkedList = .{},
allocator: std.mem.Allocator,

pub const Message = struct {
    node: Lists.DoublyLinkedList.Node = .{},
    opcode: WebSocket.Opcode = .Text,
    data: []u8,

    fn create(allocator: std.mem.Allocator, size: usize) !*Message {
        const struct_size = @sizeOf(Message);
        const total_size = struct_size + size;

        const raw_ptr = try allocator.alignedAlloc(u8, @alignOf(Message), total_size);
        const message_ptr: *Message = @ptrCast(raw_ptr);

        message_ptr.* = .{
            .node = .{},
            .data = raw_ptr[struct_size .. struct_size + size],
        };

        return message_ptr;
    }

    fn destroy(self: *Message, allocator: std.mem.Allocator) void {
        const raw_ptr: [*]u8 = @ptrCast(self);
        const total_size = @sizeOf(Message) + self.data.len;
        const slice = raw_ptr[0..total_size];
        allocator.rawFree(slice, .fromByteUnits(@alignOf(Message)), @returnAddress());
    }
};

pub fn onWrite(
    ud: ?*Self,
    loop: *xev.Loop,
    completion: *xev.Completion,
    socket: xev.TCP,
    b: xev.WriteBuffer,
    res: xev.WriteError!usize,
) xev.CallbackAction {
    const self = ud orelse unreachable;

    if (self.client.state.stage == .closing) {
        self.client.close();
        return .disarm;
    }

    const written = res catch return .disarm;

    const remaining = b.slice[written..];
    if (remaining.len == 0) {
        self.sending = false;
        const node = self.message_queue.popFirst() orelse unreachable;
        const message: *Message = @fieldParentPtr("node", node);
        defer message.destroy(self.allocator);

        if (message.opcode == .Close) {
            std.debug.assert(self.message_queue.len == 0);

            self.client.websocket.active = false;
            self.client.timeout = VM.lperf.clock() + @as(f64, 3);

            self.client.server.reloadNode(.front, self.client, loop);
            return .disarm;
        }

        self.flushMessages(loop);
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

pub fn flushMessages(self: *Self, loop: *xev.Loop) void {
    if (self.sending)
        return;
    if (self.message_queue.len == 0)
        return;
    self.sending = true;
    const node = self.message_queue.first orelse unreachable;
    const message: *Message = @fieldParentPtr("node", node);
    self.client.socket.write(
        loop,
        &self.completion,
        .{ .slice = message.data },
        Self,
        self,
        onWrite,
    );
}

pub fn sendFrame(self: *Self, loop: *xev.Loop, dataframe: WebSocket.WebsocketDataFrame) !void {
    if (self.closed)
        return;
    const web_message = try Message.create(self.allocator, WebSocket.calcWriteSize(dataframe.data.len, false));
    errdefer web_message.destroy(self.allocator);

    web_message.opcode = dataframe.header.opcode;
    try WebSocket.writeDataFrameBuf(web_message.data, dataframe);

    self.message_queue.append(&web_message.node);

    self.flushMessages(loop);
}

pub fn lua_send(self: *Self, L: *VM.lua.State) !i32 {
    if (self.closed)
        return error.WebSocketClosed;
    const scheduler = Scheduler.getScheduler(L);

    const message = try L.Zcheckvalue([]const u8, 2, null);

    try self.sendFrame(&scheduler.loop, .{
        .header = .{
            .final = true,
            .opcode = switch (L.typeOf(2)) {
                .Buffer => .Binary,
                .String => .Text,
                else => unreachable,
            },
            .mask = false,
            .len = WebSocket.WebsocketHeader.packLength(message.len),
        },
        .data = message,
    });

    return 0;
}

pub fn sendPongFrame(self: *Self, loop: *xev.Loop) !void {
    try self.sendFrame(loop, .{
        .header = .{
            .final = true,
            .opcode = .Pong,
            .mask = false,
            .len = WebSocket.WebsocketHeader.packLength(0),
        },
        .data = &.{},
    });
}

pub fn sendCloseFrame(self: *Self, loop: *xev.Loop, code: u16) !void {
    if (self.closed)
        return;

    defer self.closed = true;
    self.close_code = code;

    const c = @byteSwap(code);
    const data = @as([2]u8, @bitCast(c));

    try self.sendFrame(loop, .{
        .header = .{
            .final = true,
            .opcode = .Close,
            .mask = false,
            .len = WebSocket.WebsocketHeader.packLength(2),
        },
        .data = &data,
    });
}

pub fn lua_close(self: *Self, L: *VM.lua.State) !i32 {
    if (self.closed)
        return 0;

    const code = try L.Zcheckvalue(?u16, 2, null) orelse 1000;

    const scheduler = Scheduler.getScheduler(L);

    try self.sendCloseFrame(&scheduler.loop, code);

    return 0;
}

pub const __namecall = MethodMap.CreateNamecallMap(Self, null, .{
    .{ "send", lua_send },
    .{ "close", lua_close },
});

pub fn __dtor(self: *Self) void {
    self.closed = true;
    var it: ?*Lists.DoublyLinkedList.Node = self.message_queue.first;
    while (it) |node| : (it = node.next) {
        const message: *Message = @fieldParentPtr("node", node);
        message.destroy(self.allocator);
    }
}
