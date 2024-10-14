// This code is based on https://github.com/oven-sh/bun/blob/1aa35089d64f32b43901e850e34bc18b96c02899/src/http/websocket.zig

const std = @import("std");

const VStream = @import("vstream.zig");

const posix = std.posix;

pub const Opcode = enum(u4) {
    Continue = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Res3 = 0x3,
    Res4 = 0x4,
    Res5 = 0x5,
    Res6 = 0x6,
    Res7 = 0x7,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
    ResB = 0xB,
    ResC = 0xC,
    ResD = 0xD,
    ResE = 0xE,
    ResF = 0xF,

    pub fn isControl(opcode: Opcode) bool {
        return @intFromEnum(opcode) & 0x8 != 0;
    }
};

pub fn acceptHashKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"); // https://www.rfc-editor.org/rfc/rfc6455

    const result = try allocator.alloc(u8, 28);
    _ = std.base64.standard.Encoder.encode(result, &hash.finalResult());

    return result;
}

pub const WebsocketHeader = packed struct {
    len: u7,
    mask: bool,
    opcode: Opcode,
    rsv: u2 = 0, //rsv2 and rsv3
    compressed: bool = false, // rsv1
    final: bool = true,

    pub fn writeHeader(header: WebsocketHeader, writer: anytype, n: usize) anyerror!void {
        // packed structs are sometimes buggy
        // lets check it worked right
        var buf_ = [2]u8{ 0, 0 };
        var stream = std.io.fixedBufferStream(&buf_);
        stream.writer().writeInt(u16, @as(u16, @bitCast(header)), .big) catch unreachable;
        stream.pos = 0;
        const casted = stream.reader().readInt(u16, .big) catch unreachable;
        std.debug.assert(casted == @as(u16, @bitCast(header)));
        std.debug.assert(std.meta.eql(@as(WebsocketHeader, @bitCast(casted)), header));

        try writer.writeInt(u16, @as(u16, @bitCast(header)), .big);
        std.debug.assert(header.len == packLength(n));
    }

    pub fn packLength(length: usize) u7 {
        return switch (length) {
            0...125 => @as(u7, @truncate(length)),
            126...0xFFFF => 126,
            else => 127,
        };
    }

    const mask_length = 4;
    const header_length = 2;

    pub fn lengthByteCount(byte_length: usize) usize {
        return switch (byte_length) {
            0...125 => 0,
            126...0xFFFF => @sizeOf(u16),
            else => @sizeOf(u64),
        };
    }

    pub fn frameSize(byte_length: usize) usize {
        return header_length + byte_length + lengthByteCount(byte_length);
    }

    pub fn frameSizeIncludingMask(byte_length: usize) usize {
        return frameSize(byte_length) + mask_length;
    }

    pub fn slice(self: WebsocketHeader) [2]u8 {
        return @as([2]u8, @bitCast(@byteSwap(@as(u16, @bitCast(self)))));
    }

    pub fn fromSlice(bytes: [2]u8) WebsocketHeader {
        return @as(WebsocketHeader, @bitCast(@byteSwap(@as(u16, @bitCast(bytes)))));
    }
};

pub const WebsocketDataFrame = struct {
    header: WebsocketHeader,
    mask: [4]u8 = undefined,
    data: []const u8,

    pub fn isValid(dataframe: WebsocketDataFrame) bool {
        // Validate control frame
        if (dataframe.header.opcode.isControl()) {
            if (!dataframe.header.final) {
                return false; // Control frames cannot be fragmented
            }
            if (dataframe.data.len > 125) {
                return false; // Control frame payloads cannot exceed 125 bytes
            }
        }

        // Validate header len field
        const expected = switch (dataframe.data.len) {
            0...126 => dataframe.data.len,
            127...0xFFFF => 126,
            else => 127,
        };
        return dataframe.header.len == expected;
    }
};

// Create a buffered writer
// TODO: This will still split packets
pub fn Writer(comptime size: usize, comptime opcode: Opcode) type {
    const WriterType = switch (opcode) {
        .Text => Self.TextFrameWriter,
        .Binary => Self.BinaryFrameWriter,
        else => @compileError("Unsupported writer opcode"),
    };
    return std.io.BufferedWriter(size, WriterType);
}

const ReadStream = std.io.FixedBufferStream([]u8);

pub const WriteError = error{
    InvalidMessage,
    MessageTooLarge,
    EndOfStream,
} || std.fs.File.WriteError;

const Self = @This();

const PipedStream = struct {
    any_reader: std.io.AnyReader,
    stream_writer: std.net.Stream.Writer,
};

const VPipedStream = struct {
    any_reader: std.io.AnyReader,
    stream_writer: VStream.Writer,
};

const StreamProvider = union(enum) {
    stream: std.net.Stream,
    vstream: *VStream,
    piped: PipedStream,
    vpiped: VPipedStream,
};

stream: StreamProvider,
allocator: std.mem.Allocator,
is_client: bool = false,
err: ?anyerror = null,
header: [2]u8 = undefined,
length: ?[]u8 = null,
buf: ?[]u8 = null,

pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, client: bool) Self {
    return Self{
        .allocator = allocator,
        .is_client = client,
        .stream = .{ .stream = stream },
    };
}

pub fn initV(allocator: std.mem.Allocator, vstream: *VStream, client: bool) Self {
    return Self{
        .allocator = allocator,
        .is_client = client,
        .stream = .{ .vstream = vstream },
    };
}

pub fn initAny(allocator: std.mem.Allocator, reader: std.io.AnyReader, writer: std.net.Stream.Writer, client: bool) Self {
    return Self{
        .allocator = allocator,
        .is_client = client,
        .stream = .{
            .piped = .{
                .any_reader = reader,
                .stream_writer = writer,
            },
        },
    };
}

pub fn initAnyV(allocator: std.mem.Allocator, reader: std.io.AnyReader, writer: VStream.Writer, client: bool) Self {
    return Self{
        .allocator = allocator,
        .is_client = client,
        .stream = .{
            .vpiped = .{
                .any_reader = reader,
                .stream_writer = writer,
            },
        },
    };
}

pub fn deinit(self: *Self) void {
    if (self.buf) |buf| self.allocator.free(buf);
    if (self.length) |buf| self.allocator.free(buf);
}

// ------------------------------------------------------------------------
// Stream API
// ------------------------------------------------------------------------
pub const TextFrameWriter = std.io.Writer(*Self, WriteError, Self.writeText);
pub const BinaryFrameWriter = std.io.Writer(*Self, anyerror, Self.writeBinary);

// A buffered writer that will buffer up to size bytes before writing out
pub fn newWriter(self: *Self, comptime size: usize, comptime opcode: Opcode) Writer(size, opcode) {
    const BufferedWriter = Writer(size, opcode);
    const frame_writer = switch (opcode) {
        .Text => TextFrameWriter{ .context = self },
        .Binary => BinaryFrameWriter{ .context = self },
        else => @compileError("Unsupported writer type"),
    };
    return BufferedWriter{ .unbuffered_writer = frame_writer };
}

// Close and send the status
pub fn close(self: *Self, code: u16) !void {
    const c = @byteSwap(code);
    const data = @as([2]u8, @bitCast(c));
    _ = try self.writeMessage(.Close, &data);
}

// ------------------------------------------------------------------------
// Low level API
// ------------------------------------------------------------------------

// Flush any buffered data out the underlying stream
pub fn flush(self: *Self) !void {
    try self.io.flush();
}

pub fn writeText(self: *Self, data: []const u8) !usize {
    return self.writeMessage(.Text, data);
}

pub fn writeBinary(self: *Self, data: []const u8) anyerror!usize {
    return self.writeMessage(.Binary, data);
}

// Write a final message packet with the given opcode
pub fn writeMessage(self: *Self, opcode: Opcode, message: []const u8) anyerror!usize {
    return self.writeSplitMessage(opcode, true, message);
}

// Write a message packet with the given opcode and final flag
pub fn writeSplitMessage(self: *Self, opcode: Opcode, final: bool, message: []const u8) anyerror!usize {
    return self.writeDataFrame(WebsocketDataFrame{
        .header = WebsocketHeader{
            .final = final,
            .opcode = opcode,
            .mask = self.is_client,
            .len = WebsocketHeader.packLength(message.len),
        },
        .data = message,
    });
}

// Write a raw data frame
pub fn writeDataFrame(self: *Self, dataframe: WebsocketDataFrame) anyerror!usize {
    switch (self.stream) {
        .stream => |s| return writeDataFrameAny(dataframe, s.writer()),
        .vstream => |s| return writeDataFrameAny(dataframe, s.writer()),
        .piped => |s| return writeDataFrameAny(dataframe, s.stream_writer),
        .vpiped => |s| return writeDataFrameAny(dataframe, s.stream_writer),
    }
}

pub fn writeDataFrameAny(dataframe: WebsocketDataFrame, stream: anytype) anyerror!usize {
    if (!dataframe.isValid())
        return error.InvalidMessage;

    try stream.writeInt(u16, @as(u16, @bitCast(dataframe.header)), .big);

    // Write extended length if needed
    const n = dataframe.data.len;
    switch (n) {
        0...126 => {}, // Included in header
        127...0xFFFF => try stream.writeInt(u16, @as(u16, @truncate(n)), .big),
        else => try stream.writeInt(u64, n, .big),
    }

    // TODO: Handle compression
    if (dataframe.header.compressed) return error.InvalidMessage;

    if (dataframe.header.mask) {
        const mask = &dataframe.mask;
        try stream.writeAll(mask);

        // Encode
        for (dataframe.data, 0..) |c, i| {
            try stream.writeByte(c ^ mask[i % 4]);
        }
    } else {
        try stream.writeAll(dataframe.data);
    }

    // try self.io.flush();

    return dataframe.data.len;
}

pub fn read(self: *Self) !WebsocketDataFrame {
    @memset(&self.header, 0);
    // Read and retry if we hit the end of the stream buffer
    const start = switch (self.stream) {
        .stream => |s| try s.read(&self.header),
        .vstream => |s| try s.read(&self.header),
        .piped => |s| try s.any_reader.read(&self.header),
        .vpiped => |s| try s.any_reader.read(&self.header),
    };
    if (start == 0) {
        return error.ConnectionClosed;
    }

    return try self.readDataFrameInBuffer();
}

// Read assuming everything can fit before the stream hits the end of
// it's buffer
pub fn readDataFrameInBuffer(
    self: *Self,
) !WebsocketDataFrame {
    const header_bytes = self.header[0..2];
    var header = std.mem.zeroes(WebsocketHeader);
    header.final = header_bytes[0] & 0x80 == 0x80;
    // header.rsv1 = header_bytes[0] & 0x40 == 0x40;
    // header.rsv2 = header_bytes[0] & 0x20;
    // header.rsv3 = header_bytes[0] & 0x10;
    header.opcode = @as(Opcode, @enumFromInt(@as(u4, @truncate(header_bytes[0]))));
    header.mask = header_bytes[1] & 0x80 == 0x80;
    header.len = @as(u7, @truncate(header_bytes[1]));

    // Decode length
    var length: u64 = header.len;
    switch (header.len) {
        126 => {
            const lengthBuf = try self.allocator.alloc(u8, 2);
            self.length = lengthBuf;
            const size = switch (self.stream) {
                .stream => |s| try s.read(lengthBuf),
                .vstream => |s| try s.read(lengthBuf),
                .piped => |s| try s.any_reader.read(lengthBuf),
                .vpiped => |s| try s.any_reader.read(lengthBuf),
            };
            if (size == 0 or size != 2) return error.ConnectionClosed;
            length = std.mem.readInt(u16, lengthBuf[0..2], .big);
        },
        127 => {
            const lengthBuf = try self.allocator.alloc(u8, 8);
            self.length = lengthBuf;
            const size = switch (self.stream) {
                .stream => |s| try s.read(lengthBuf),
                .vstream => |s| try s.read(lengthBuf),
                .piped => |s| try s.any_reader.read(lengthBuf),
                .vpiped => |s| try s.any_reader.read(lengthBuf),
            };
            if (size == 0 or size != 8) return error.ConnectionClosed;
            length = std.mem.readInt(u64, lengthBuf[0..8], .big);
            // Most significant bit must be 0
            if (length >> 63 == 1) return error.InvalidMessage;
        },
        else => {},
    }

    const buf = try self.allocator.alloc(u8, length);
    self.buf = buf;

    const start: usize = if (header.mask) 4 else 0;

    const end = start + length;

    const extend_length = switch (self.stream) {
        .stream => |s| try s.read(buf),
        .vstream => |s| try s.read(buf),
        .piped => |s| try s.any_reader.read(buf),
        .vpiped => |s| try s.any_reader.read(buf),
    };
    if (extend_length != length) {
        return error.InvalidMessage;
    }

    var data = buf[start..end];

    if (header.mask) {
        const mask = buf[0..4];
        // Decode data in place
        for (data, 0..) |_, i| {
            data[i] ^= mask[i % 4];
        }
    }

    return WebsocketDataFrame{
        .header = header,
        .mask = if (header.mask) buf[0..4].* else undefined,
        .data = data,
    };
}
