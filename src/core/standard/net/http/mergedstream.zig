const std = @import("std");

const Self = @This();

stream: std.net.Stream,
buffer: []u8,
buffer_pos: usize,

pub const ReadError = std.posix.ReadError;
pub const WriteError = std.posix.WriteError;

pub const Reader = std.io.Reader(*Self, ReadError, read);

pub fn reader(self: *Self) Reader {
    return .{ .context = self };
}

pub fn init(stream: std.net.Stream, buffer: []u8) Self {
    return Self{
        .stream = stream,
        .buffer = buffer,
        .buffer_pos = 0,
    };
}

pub fn read(self: *Self, dest: []u8) ReadError!usize {
    var totalRead: usize = 0;
    const maxRead: usize = dest.len;
    std.debug.print("maxRead: {d}\n", .{maxRead});
    if (maxRead == 0) return 0;

    // Read from buffer if there's any data left
    const left = (self.buffer.len - self.buffer_pos);
    const toRead = if (left > maxRead) maxRead else left;
    if (toRead > 0) {
        std.debug.print("toRead: {d}\n", .{toRead});
        @memcpy(dest[0..toRead], self.buffer[self.buffer_pos .. self.buffer_pos + toRead]);
        self.buffer_pos += toRead;
        totalRead += toRead;
    }

    // Read the rest from second stream. Net
    if (totalRead < maxRead) {
        std.debug.print("totalRead: {d}\n", .{totalRead});
        const streamRead = try self.stream.read(dest[totalRead..]);
        totalRead += streamRead;
    }

    return totalRead;
}
