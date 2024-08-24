const std = @import("std");
const luau = @import("luau");

const Luau = luau.Luau;

const Url = @import("url.zig");

const Self = @This();

const HeaderKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Protocol = enum {
    HTTP10,
    HTTP11,
};

// this approach to matching method name comes from zhp
const HTTP = @as(u32, @bitCast([4]u8{ 'H', 'T', 'T', 'P' }));
const V1P0 = @as(u32, @bitCast([4]u8{ '/', '1', '.', '0' }));
const V1P1 = @as(u32, @bitCast([4]u8{ '/', '1', '.', '1' }));

const ParseError = error{
    InvalidRequest,
    InvalidProtocol,
    InvalidStatusCode,
    InvalidStatusReason,
    UnsupportedProtocol,
    InvalidHeader,
    TooManyHeaders,
    InvalidContentLength,
    InvalidBody,
    BodyTooLarge,
    InvalidRequestTarget,
    ConnectionClosed,
};

allocator: std.mem.Allocator,
buffer: []u8,
bufferLen: usize = 0,
protocol: ?Protocol = null,
headers: ?[]const HeaderKeyValue = null,
body: ?[]const u8 = null,
bodyAllocated: bool = false,
statusCode: u10 = 0,
statusReason: ?[]const u8 = null,
pos: usize = 0,

pub const Config = struct {
    maxBodySize: usize = 4096,
    maxHeaders: usize = 64,
    ignoreBody: bool = false,
};

pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader, config: Config) !Self {
    var buffer: []u8 = try allocator.alloc(u8, 4096);
    var self = Self{
        .allocator = allocator,
        .buffer = buffer,
    };
    errdefer self.deinit();

    var pos: usize = 0;

    const readLen = try reader.read(buffer[0..]);
    if (readLen == 0) return ParseError.ConnectionClosed;
    self.bufferLen = readLen;

    pos += try self.parseProtocol(buffer[pos..readLen]);
    pos += try self.parseStatusCode(buffer[pos..readLen]);
    pos += try self.parseStatusReason(buffer[pos..readLen]);
    pos += try self.parseHeaders(buffer[pos..readLen], config.maxHeaders);

    if (self.headers != null and config.ignoreBody == false) {
        if (self.getHeader("content-length")) |contentLengthHeader| {
            const contentLength = atoi(contentLengthHeader.value) orelse return ParseError.InvalidContentLength;
            if (contentLength > 0) {
                if (contentLength > config.maxBodySize) return ParseError.BodyTooLarge;
                pos += try self.parseBody(pos, contentLength, reader);
            }
        }
    }

    self.pos = pos;

    return self;
}

fn atoi(str: []const u8) ?usize {
    if (str.len == 0) return null;

    var n: usize = 0;
    for (str) |b| {
        if (b < '0' or b > '9') return null;
        n = std.math.mul(usize, n, 10) catch return null;
        n = std.math.add(usize, n, @intCast(b - '0')) catch return null;
    }
    return n;
}

pub fn getHeader(self: *Self, name: []const u8) ?HeaderKeyValue {
    if (self.headers == null) return null;
    scan: for (self.headers.?) |keyValue| {
        // TODO: https://github.com/ziglang/zig/issues/8689
        const key = keyValue.key;
        if (key.len != name.len) continue;
        for (key, name) |k, n| if (k != n) continue :scan;
        return keyValue;
    }
    return null;
}

pub fn parseProtocol(self: *Self, buf: []u8) !usize {
    const buf_len = buf.len;
    if (buf_len < 8) return ParseError.InvalidProtocol;

    if (@as(u32, @bitCast(buf[0..4].*)) != HTTP) {
        return ParseError.InvalidProtocol;
    }

    self.protocol = switch (@as(u32, @bitCast(buf[4..8].*))) {
        V1P1 => Protocol.HTTP11,
        V1P0 => Protocol.HTTP10,
        else => return ParseError.UnsupportedProtocol,
    };

    return 8;
}

pub fn parseStatusCode(self: *Self, buf: []u8) !usize {
    if (buf.len < 4) return ParseError.InvalidStatusCode;

    const num = atoi(buf[1..4]) orelse return ParseError.InvalidStatusCode;
    // max: 0 - 999, we are reading 3 digits
    self.statusCode = @intCast(num); // limit: 0 - 1024

    return 4;
}

pub fn parseStatusReason(self: *Self, buf: []u8) !usize {
    if (buf.len < 2) return ParseError.InvalidStatusReason;
    if (buf[1] == '\n') return 2; // omitted status
    if (buf[0] != ' ') return ParseError.InvalidStatusReason;
    const len = buf.len;
    for (buf, 0..) |b, i| {
        if (len - i < 2) return ParseError.InvalidStatusReason;
        if (b == '\r' and buf[i + 1] == '\n') {
            if (i == 0) return ParseError.InvalidStatusReason;
            self.statusReason = buf[1..i];
            return i + 2;
        }
    }
    return ParseError.InvalidStatusReason;
}

inline fn allowedHeaderValueByte(c: u8) bool {
    const mask = 0 | ((1 << (0x7f - 0x21)) - 1) << 0x21 | 1 << 0x20 | 1 << 0x09;

    const mask1 = ~@as(u64, (mask & ((1 << 64) - 1)));
    const mask2 = ~@as(u64, mask >> 64);

    const shl = std.math.shl;
    return ((shl(u64, 1, c) & mask1) | (shl(u64, 1, c -| 64) & mask2)) == 0;
}

inline fn trimLeadingSpaceCount(in: []const u8) struct { []const u8, usize } {
    if (in.len > 1 and in[0] == ' ') {
        // very common case
        const n = in[1];
        if (n != ' ' and n != '\t') {
            return .{ in[1..], 1 };
        }
    }

    for (in, 0..) |b, i| {
        if (b != ' ' and b != '\t') return .{ in[i..], i };
    }
    return .{ "", in.len };
}

fn parseHeaders(self: *Self, full: []u8, maxHeaders: usize) !usize {
    if (full.len == 0) return 0;
    if (full[0] == '\r' and full[1] == '\n') return 2;

    var count: usize = 0;
    for (full, 0..) |b, p| {
        const next = p + 1;
        const last = if (p > 0) p - 1 else 0;
        if (next == full.len) break;
        if (b == '\r' and full[next] == '\n') {
            if (full[last] == '\n') break;
            count += 1;
            if (count > maxHeaders) return ParseError.TooManyHeaders;
        }
    }

    if (count == 0) return 0;

    const list = try self.allocator.alloc(HeaderKeyValue, count);
    var listPos: usize = 0;

    var buf = full;
    var pos: usize = 0;
    line: while (buf.len > 0) {
        for (buf, 0..) |bn, i| {
            switch (bn) {
                'a'...'z', '0'...'9', '-', '_' => {},
                'A'...'Z' => buf[i] = bn + 32, // lowercase
                ':' => {
                    const value_start = i + 1; // skip the colon
                    var value, const skip_len = trimLeadingSpaceCount(buf[value_start..]);
                    for (value, 0..) |bv, j| {
                        if (allowedHeaderValueByte(bv) == true) {
                            continue;
                        }

                        if (bv != '\r') return ParseError.InvalidHeader;
                        const next = j + 1;
                        if (next == value.len) return ParseError.InvalidHeader;
                        if (value[next] != '\n') return ParseError.InvalidHeader;

                        value = value[0..j];
                        break;
                    } else return ParseError.InvalidHeader;

                    const name = buf[0..i];

                    // Should not be possible.
                    if (listPos >= count) return ParseError.TooManyHeaders;

                    list[listPos] = .{
                        .key = name,
                        .value = value,
                    };
                    listPos += 1;

                    // +2 to skip the \r\n
                    const next_line = value_start + skip_len + value.len + 2;
                    pos += next_line;
                    buf = buf[next_line..];
                    continue :line;
                },
                '\r' => {
                    if (i != 0) return ParseError.InvalidHeader;
                    if (buf.len == 1) return ParseError.InvalidHeader;
                    if (buf[1] == '\n') {
                        self.headers = list;
                        return pos + 2;
                    }
                    // we have a \r followed by something that isn't a \n, can't be right
                    return error.InvalidHeaderLine;
                },
                else => return error.InvalidHeaderLine,
            }
        } else return ParseError.InvalidHeader;
    }

    self.headers = list;

    return pos;
}

pub fn parseBody(self: *Self, pos: usize, contentLength: usize, reader: std.io.AnyReader) !usize {
    if (self.bufferLen - pos >= contentLength) {
        self.body = self.buffer[pos .. pos + contentLength];
        return contentLength;
    }
    const missing = contentLength - (self.bufferLen - pos);
    if (missing == 0) {
        self.body = self.buffer[pos .. pos + contentLength];
        return 0;
    }
    var readLen: usize = 0;
    if (missing < self.buffer.len - self.bufferLen) {
        readLen = try reader.read(self.buffer[self.bufferLen..]);
        self.body = self.buffer[pos .. pos + readLen];
        if (readLen == 0) return ParseError.ConnectionClosed;
    } else {
        // reallocate buffer, increasing the size by the content length
        self.bodyAllocated = true;
        const bodyBuffer = try self.allocator.alloc(u8, contentLength);
        const bufferChunk = self.buffer[pos..];
        @memcpy(bodyBuffer[0..bufferChunk.len], bufferChunk);
        if (self.allocator.resize(self.buffer, pos)) self.buffer = self.buffer[0..pos];
        self.body = bodyBuffer;
        readLen = try reader.read(bodyBuffer[bufferChunk.len..]);
        if (readLen == 0) return ParseError.ConnectionClosed;
    }
    self.bufferLen += readLen;
    return readLen;
}

fn safeStatusCast(int: u10) ?std.http.Status {
    return switch (int) {
        100...103, 200...208, 226, 300...308, 400...418, 421...426, 428...429, 431, 451, 500...508, 510...511 => @enumFromInt(int),
        else => null,
    };
}

pub fn pushToStack(self: *Self, L: *Luau, customBody: ?[]const u8) !void {
    const allocator = L.allocator();
    L.newTable();
    errdefer L.pop(1);

    L.setFieldBoolean(-1, "ok", self.statusCode >= 200 and self.statusCode < 300);
    L.setFieldInteger(-1, "statusCode", @intCast(self.statusCode));

    if (self.statusReason) |reason| {
        const zreason = try allocator.dupeZ(u8, reason);
        defer allocator.free(zreason);
        L.setFieldString(-1, "statusReason", zreason);
    } else if (safeStatusCast(self.statusCode)) |status| {
        if (status.phrase()) |reason| {
            const zreason = try allocator.dupeZ(u8, reason);
            defer allocator.free(zreason);
            L.setFieldString(-1, "statusReason", zreason);
        }
    }

    if (self.headers) |headers| {
        L.newTable();
        errdefer L.pop(1);
        for (headers) |header| {
            const zkey = try allocator.dupeZ(u8, header.key);
            defer allocator.free(zkey);

            const zvalue = try allocator.dupeZ(u8, header.value);
            defer allocator.free(zvalue);

            L.pushString(zkey);
            L.pushString(zvalue);
            L.rawSetTable(-3);
        }
        L.setField(-2, "headers");
    }

    if (customBody orelse self.body) |body| {
        const zbody = try allocator.dupeZ(u8, body);
        defer allocator.free(zbody);
        L.setFieldString(-1, "body", zbody);
    }
}

pub fn deinit(self: *Self) void {
    if (self.headers) |headers| self.allocator.free(headers);
    if (self.bodyAllocated) {
        self.allocator.free(self.body.?);
    }
    self.allocator.free(self.buffer);
}

fn expectHeaderKeyValue(kv: HeaderKeyValue, key: []const u8, value: []const u8) !void {
    try std.testing.expectEqualSlices(u8, key, kv.key);
    try std.testing.expectEqualSlices(u8, value, kv.value);
}

fn testFakeStream(buffer: []const u8) std.io.FixedBufferStream([]const u8) {
    return std.io.FixedBufferStream([]const u8){
        .buffer = buffer,
        .pos = 0,
    };
}

test "Parse Response (1)" {
    const allocator = std.testing.allocator;
    var stream = testFakeStream("HTTP/1.1 200 OK\r\n\r\n");
    var response = try Self.init(allocator, stream.reader().any(), .{});
    defer response.deinit();

    try std.testing.expect(response.protocol != null);
    try std.testing.expectEqual(Protocol.HTTP11, response.protocol.?);
    try std.testing.expectEqual(200, response.statusCode);
    try std.testing.expect(response.statusReason != null);
    try std.testing.expect(response.headers == null);
    try std.testing.expect(response.body == null);
    try std.testing.expectEqualSlices(u8, "OK", response.statusReason.?);
}

test "Parse Response (2)" {
    const allocator = std.testing.allocator;
    var stream = testFakeStream("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\n\r\n");
    var response = try Self.init(allocator, stream.reader().any(), .{});
    defer response.deinit();

    try std.testing.expect(response.protocol != null);
    try std.testing.expectEqual(Protocol.HTTP11, response.protocol.?);
    try std.testing.expectEqual(200, response.statusCode);
    try std.testing.expect(response.statusReason != null);
    try std.testing.expect(response.headers != null);
    try std.testing.expect(response.body == null);

    try expectHeaderKeyValue(response.headers.?[0], "test", "false");
    try expectHeaderKeyValue(response.headers.?[1], "host", "somehost.com");

    try std.testing.expectEqualSlices(u8, "OK", response.statusReason.?);
}

test "Parse Response (3)" {
    const allocator = std.testing.allocator;
    var stream = testFakeStream("HTTP/1.1 200 OK\r\nTest: false\r\nHost: somehost.com\r\nContent-Length: 5\r\n\r\ntest\n");
    var response = try Self.init(allocator, stream.reader().any(), .{});
    defer response.deinit();

    try std.testing.expect(response.protocol != null);
    try std.testing.expectEqual(Protocol.HTTP11, response.protocol.?);
    try std.testing.expectEqual(200, response.statusCode);
    try std.testing.expect(response.statusReason != null);
    try std.testing.expect(response.headers != null);
    try std.testing.expect(response.body != null);

    try expectHeaderKeyValue(response.headers.?[0], "test", "false");
    try expectHeaderKeyValue(response.headers.?[1], "host", "somehost.com");
    try expectHeaderKeyValue(response.headers.?[2], "content-length", "5");

    try std.testing.expectEqualSlices(u8, "OK", response.statusReason.?);
    try std.testing.expectEqualSlices(u8, "test\n", response.body.?);
}
