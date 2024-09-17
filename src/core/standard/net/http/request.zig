// This code is based on https://github.com/karlseguin/http.zig/blob/c3bf0fca2c224510d0496100178fa6e25bb97473/src/request.zig

const std = @import("std");
const luau = @import("luau");

const Luau = luau.Luau;

const Url = @import("url.zig");

const Self = @This();

const QueryKeyValue = struct {
    key: []const u8,
    value: ?[]const u8,
};

const HeaderKeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Protocol = enum {
    HTTP10,
    HTTP11,
};

const ParseError = error{
    InvalidRequest,
    InvalidMethod,
    InvalidProtocol,
    UnsupportedProtocol,
    InvalidHeader,
    TooManyHeaders,
    InvalidContentLength,
    InvalidBody,
    BodyTooLarge,
    InvalidRequestTarget,
    ConnectionClosed,
};

// this approach to matching method name comes from zhp
const GET_ = @as(u32, @bitCast([4]u8{ 'G', 'E', 'T', ' ' }));
const PUT_ = @as(u32, @bitCast([4]u8{ 'P', 'U', 'T', ' ' }));
const POST = @as(u32, @bitCast([4]u8{ 'P', 'O', 'S', 'T' }));
const HEAD = @as(u32, @bitCast([4]u8{ 'H', 'E', 'A', 'D' }));
const PATC = @as(u32, @bitCast([4]u8{ 'P', 'A', 'T', 'C' }));
const DELE = @as(u32, @bitCast([4]u8{ 'D', 'E', 'L', 'E' }));
const ETE_ = @as(u32, @bitCast([4]u8{ 'E', 'T', 'E', ' ' }));
const OPTI = @as(u32, @bitCast([4]u8{ 'O', 'P', 'T', 'I' }));
const ONS_ = @as(u32, @bitCast([4]u8{ 'O', 'N', 'S', ' ' }));
const HTTP = @as(u32, @bitCast([4]u8{ 'H', 'T', 'T', 'P' }));
const V1P0 = @as(u32, @bitCast([4]u8{ '/', '1', '.', '0' }));
const V1P1 = @as(u32, @bitCast([4]u8{ '/', '1', '.', '1' }));

allocator: std.mem.Allocator,
buffer: []u8,
bufferLen: usize = 0,
method: ?[]const u8 = null,
url: ?Url = null,
protocol: ?Protocol = null,
headers: ?[]const HeaderKeyValue = null,
query: ?[]const QueryKeyValue = null,
body: ?[]const u8 = null,
bodyAllocated: bool = false,

pub const Config = struct {
    maxBodySize: usize = 4096,
    maxHeaders: usize = 64,
    maxQuery: usize = 64,
};

pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader, config: Config) !Self {
    var buffer: []u8 = try allocator.alloc(u8, 4096);
    var self = Self{
        .allocator = allocator,
        .buffer = buffer,
        .method = null,
        .url = null,
        .protocol = null,
        .body = null,
    };
    errdefer self.deinit();

    var pos: usize = 0;

    const readLen = try reader.read(buffer[0..]);
    if (readLen == 0) return ParseError.ConnectionClosed;
    self.bufferLen = readLen;

    pos += try self.parseMethod(buffer[pos..readLen]);
    pos += try self.parseUri(buffer[pos..readLen]);
    try self.parseQuery(config.maxQuery);
    pos += try self.parseProtocol(buffer[pos..readLen]);
    pos += try self.parseHeaders(buffer[pos..readLen], config.maxHeaders);

    if (self.headers != null) {
        if (self.getHeader("content-length")) |contentLengthHeader| {
            const contentLength = atoi(contentLengthHeader.value) orelse return ParseError.InvalidContentLength;
            if (contentLength > 0) {
                if (contentLength > config.maxBodySize) return ParseError.BodyTooLarge;
                pos += try self.parseBody(pos, contentLength, reader);
            }
        }
    }

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
        // This is largely a reminder to myself that std.mem.eql isn't
        // particularly fast. Here we at least avoid the 1 extra ptr
        // equality check that std.mem.eql does, but we could do better
        // TODO: monitor https://github.com/ziglang/zig/issues/8689
        const key = keyValue.key;
        if (key.len != name.len) continue;
        for (key, name) |k, n| if (k != n) continue :scan;
        return keyValue;
    }
    return null;
}

pub fn parseMethod(self: *Self, buf: []const u8) !usize {
    switch (@as(u32, @bitCast(buf[0..4].*))) {
        GET_ => {
            self.method = buf[0..3];
            return 4;
        },
        PUT_ => {
            self.method = buf[0..3];
            return 4;
        },
        POST => {
            if (buf[4] != ' ') return ParseError.InvalidMethod;
            self.method = buf[0..4];
            return 5;
        },
        HEAD => {
            if (buf[4] != ' ') return ParseError.InvalidMethod;
            self.method = buf[0..4];
            return 5;
        },
        PATC => {
            if (buf[4] != 'H' or buf[5] != ' ') return ParseError.InvalidMethod;
            self.method = buf[0..5];
            return 6;
        },
        DELE => {
            if (@as(u32, @bitCast(buf[3..7].*)) != ETE_) return ParseError.InvalidMethod;
            self.method = buf[0..6];
            return 7;
        },
        OPTI => {
            if (@as(u32, @bitCast(buf[4..8].*)) != ONS_) return ParseError.InvalidMethod;
            self.method = buf[0..7];
            return 8;
        },
        else => return ParseError.InvalidMethod,
    }
}

pub fn parseUri(self: *Self, buf: []const u8) !usize {
    const buf_len = buf.len;
    if (buf_len == 0) return error.InvalidRequestTarget;

    var len: usize = 0;
    var uri: []const u8 = undefined;
    switch (buf[0]) {
        '/' => {
            const end_index = std.mem.indexOfScalarPos(u8, buf[1..buf_len], 0, ' ') orelse return ParseError.InvalidRequestTarget;
            // +1 since we skipped the leading / in our indexOfScalar and +1 to consume the space
            len = end_index + 2;
            const url = buf[0 .. end_index + 1];
            if (!Url.isValid(url)) return ParseError.InvalidRequestTarget;
            uri = url;
        },
        '*' => {
            if (buf_len == 1) return ParseError.InvalidRequestTarget;
            // Read never returns 0, so if we're here, buf.len >= 1
            if (buf[1] != ' ') return ParseError.InvalidRequestTarget;
            len = 2;
            uri = buf[0..1];
        },
        // TODO: Support absolute-form target (e.g. http://....)
        else => return ParseError.InvalidRequestTarget,
    }

    self.url = Url.parse(uri);

    return len;
}

fn parseQuery(self: *Self, maxQuery: usize) !void {
    if (self.url == null) return;
    const raw = self.url.?.query;
    if (raw.len == 0) {
        return;
    }

    const allocator = self.allocator;
    var count: usize = 1;
    for (raw) |b| {
        if (b == '&') count += 1;
        if (count > maxQuery) {
            return;
        }
    }

    var pos: usize = 0;
    const list = try self.allocator.alloc(QueryKeyValue, count);

    var it = std.mem.splitScalar(u8, raw, '&');
    while (it.next()) |pair| {
        if (std.mem.indexOfScalarPos(u8, pair, 0, '=')) |sep| {
            list[pos] = .{
                .key = try Url.unescape(allocator, pair[0..sep]),
                .value = try Url.unescape(allocator, pair[sep + 1 ..]),
            };
            pos += 1;
        } else {
            list[pos] = .{
                .key = try Url.unescape(allocator, pair),
                .value = null,
            };
            pos += 1;
        }
    }

    self.query = list;

    return;
}

pub fn parseProtocol(self: *Self, buf: []u8) !usize {
    const buf_len = buf.len;
    if (buf_len < 10) return ParseError.InvalidProtocol;

    if (@as(u32, @bitCast(buf[0..4].*)) != HTTP) {
        return ParseError.InvalidProtocol;
    }

    self.protocol = switch (@as(u32, @bitCast(buf[4..8].*))) {
        V1P1 => Protocol.HTTP11,
        V1P0 => Protocol.HTTP10,
        else => return ParseError.UnsupportedProtocol,
    };

    if (buf[8] != '\r' or buf[9] != '\n') {
        return ParseError.InvalidProtocol;
    }

    return 10;
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

                        // To keep ALLOWED_HEADER_VALUE small, we said \r
                        // was illegal. I mean, it _is_ illegal in a header value
                        // but it isn't part of the header value, it's (probably) the end of line
                        if (bv != '\r') return ParseError.InvalidHeader;
                        const next = j + 1;
                        if (next == value.len) return ParseError.InvalidHeader;
                        if (value[next] != '\n') return ParseError.InvalidHeader;
                        // If we're here, it means our value had valid characters
                        // up until the point of a newline (\r\n), which means
                        // we have a valid value (and name)

                        value = value[0..j];
                        break;
                    } else {
                        // for loop reached the end without finding a \r
                        // we need more data
                        return ParseError.InvalidHeader;
                    }

                    const name = buf[0..i];

                    if (listPos >= count) return ParseError.TooManyHeaders; // Should not have happened? somehow it did.

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
        } else {
            // didn't find a colon or blank line, we need more data
            return ParseError.InvalidHeader;
        }
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

const UpgradeError = error{
    MissingHeaders,
    InvalidUpgrade,
    InvalidConnection,
    InvalidWebSocketVersion,
};

const UpgradeInfo = struct {
    key: []const u8,
    version: []const u8,
    protocols: ?[]const u8,
};

pub fn canUpgradeWebSocket(self: *Self) !?UpgradeInfo {
    if (self.headers) |headers| {
        var upgrade = false;
        var websocket = false;
        var version: ?[]const u8 = null;
        var key: ?[]const u8 = null;
        var protocols: ?[]const u8 = null;
        for (headers) |header| {
            // TODO: prob should switch to static string map (performance improvement?)
            if (std.mem.eql(u8, header.key, "upgrade")) {
                websocket = std.ascii.eqlIgnoreCase(header.value, "websocket");
            } else if (std.mem.eql(u8, header.key, "connection")) {
                upgrade = std.ascii.eqlIgnoreCase(header.value, "upgrade");
            } else if (std.mem.eql(u8, header.key, "sec-websocket-version")) {
                version = header.value;
            } else if (std.mem.eql(u8, header.key, "sec-websocket-key")) {
                key = header.value;
            } else if (std.mem.eql(u8, header.key, "sec-websocket-protocol")) {
                protocols = header.value;
            }
        }
        if (version == null and !upgrade and !websocket) return null; // not trying to connect as WebSocket
        if (!upgrade) return UpgradeError.InvalidUpgrade;
        if (!websocket) return UpgradeError.InvalidConnection;
        if (version == null or !std.mem.eql(u8, version.?, "13")) return UpgradeError.InvalidWebSocketVersion;
        if (key == null) return UpgradeError.MissingHeaders;
        return .{
            .key = key.?,
            .version = version.?,
            .protocols = protocols,
        };
    }
    return null;
}

pub fn pushToStack(self: *Self, L: *Luau) !void {
    const allocator = L.allocator();
    L.newTable();
    errdefer L.pop(1);

    if (self.method) |method| {
        L.setFieldLString(-1, "method", method);
    }

    if (self.url) |url| {
        L.setFieldLString(-1, "path", url.path);
    }

    L.newTable();
    if (self.query) |queries| {
        errdefer L.pop(1);
        var order: i32 = 1;
        for (queries) |query| {
            const zkey = try allocator.dupeZ(u8, query.key);
            defer allocator.free(zkey);
            L.pushString(zkey);
            if (query.value) |value| {
                const valuez = try allocator.dupeZ(u8, value);
                defer allocator.free(valuez);
                L.pushString(valuez);
                L.rawSetTable(-3);
            } else {
                L.rawSetIndex(-2, order);
                order += 1;
            }
        }
    }
    L.setField(-2, "query");

    L.newTable();
    if (self.headers) |headers| {
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
    }
    L.setField(-2, "headers");

    if (self.body) |body| {
        L.setFieldLString(-1, "body", body);
    }
}

pub fn deinit(self: *Self) void {
    if (self.headers) |headers| self.allocator.free(headers);
    if (self.query) |queries| {
        for (queries) |query| {
            self.allocator.free(query.key);
            if (query.value) |value| self.allocator.free(value);
        }
        self.allocator.free(queries);
    }
    if (self.bodyAllocated) {
        self.allocator.free(self.body.?);
    }
    self.allocator.free(self.buffer);
}

fn expectHeaderKeyValue(kv: HeaderKeyValue, key: []const u8, value: []const u8) !void {
    try std.testing.expectEqualSlices(u8, key, kv.key);
    try std.testing.expectEqualSlices(u8, value, kv.value);
}

fn expectQueryKeyValue(kv: QueryKeyValue, key: []const u8, value: ?[]const u8) !void {
    try std.testing.expectEqualSlices(u8, key, kv.key);
    if (value != null and kv.value == null or value == null and kv.value != null) return std.testing.expect(false);
    if (value) |v| try std.testing.expectEqualSlices(u8, v, kv.value.?);
}

fn testFakeStream(buffer: []const u8) std.io.FixedBufferStream([]const u8) {
    return std.io.FixedBufferStream([]const u8){
        .buffer = buffer,
        .pos = 0,
    };
}

test "Parse Request (1)" {
    const allocator = std.testing.allocator;
    var stream = testFakeStream("GET / HTTP/1.1\r\n\r\n");
    var request = try Self.init(allocator, stream.reader().any(), .{});
    defer request.deinit();

    try std.testing.expect(request.method != null);
    try std.testing.expect(request.url != null);
    try std.testing.expect(request.query == null);
    try std.testing.expect(request.protocol != null);
    try std.testing.expect(request.headers == null);
    try std.testing.expect(request.body == null);
    try std.testing.expectEqualSlices(u8, "GET", request.method.?);
    try std.testing.expectEqualSlices(u8, "/", request.url.?.path);
    try std.testing.expectEqualSlices(u8, "/", request.url.?.raw);
    try std.testing.expectEqual(Protocol.HTTP11, request.protocol.?);
}

test "Parse Request (2)" {
    const allocator = std.testing.allocator;
    var stream = testFakeStream("GET /info/book?id=9 HTTP/1.1\r\nHost: somehost.com\r\n\r\n");
    var request = try Self.init(allocator, stream.reader().any(), .{});
    defer request.deinit();

    try std.testing.expect(request.method != null);
    try std.testing.expect(request.url != null);
    try std.testing.expect(request.query != null);
    try std.testing.expect(request.query.?.len == 1);
    try std.testing.expect(request.protocol != null);
    try std.testing.expect(request.headers != null);
    try std.testing.expect(request.headers.?.len == 1);
    try std.testing.expect(request.body == null);

    try expectQueryKeyValue(request.query.?[0], "id", "9");
    try expectHeaderKeyValue(request.headers.?[0], "host", "somehost.com");

    try std.testing.expectEqualSlices(u8, "GET", request.method.?);
    try std.testing.expectEqualSlices(u8, "/info/book", request.url.?.path);
    try std.testing.expectEqualSlices(u8, "/info/book?id=9", request.url.?.raw);
    try std.testing.expectEqual(Protocol.HTTP11, request.protocol.?);
}

test "Parse Request (3)" {
    const allocator = std.testing.allocator;
    var stream = testFakeStream("GET /info/book HTTP/1.1\r\nTest: false\r\nHost: somehost.com\r\n\r\n");
    var request = try Self.init(allocator, stream.reader().any(), .{});
    defer request.deinit();

    try std.testing.expect(request.method != null);
    try std.testing.expect(request.url != null);
    try std.testing.expect(request.query == null);
    try std.testing.expect(request.protocol != null);
    try std.testing.expect(request.headers != null);
    try std.testing.expect(request.headers.?.len == 2);
    try std.testing.expect(request.body == null);

    try expectHeaderKeyValue(request.headers.?[0], "test", "false");
    try expectHeaderKeyValue(request.headers.?[1], "host", "somehost.com");

    try std.testing.expectEqualSlices(u8, "GET", request.method.?);
    try std.testing.expectEqualSlices(u8, "/info/book", request.url.?.path);
    try std.testing.expectEqualSlices(u8, "/info/book", request.url.?.raw);
    try std.testing.expectEqual(Protocol.HTTP11, request.protocol.?);
}

test "Parse Request (4)" {
    const allocator = std.testing.allocator;
    var stream = testFakeStream("POST /?id=2 HTTP/1.1\r\nContent-Length: 4\r\n\r\ntest");
    var request = try Self.init(allocator, stream.reader().any(), .{});
    defer request.deinit();

    try std.testing.expect(request.method != null);
    try std.testing.expect(request.url != null);
    try std.testing.expect(request.query != null);
    try std.testing.expect(request.query.?.len == 1);
    try std.testing.expect(request.protocol != null);
    try std.testing.expect(request.headers != null);
    try std.testing.expect(request.headers.?.len == 1);
    try std.testing.expect(request.body != null);

    try expectQueryKeyValue(request.query.?[0], "id", "2");
    try expectHeaderKeyValue(request.headers.?[0], "content-length", "4");

    try std.testing.expectEqualSlices(u8, "POST", request.method.?);
    try std.testing.expectEqualSlices(u8, "/", request.url.?.path);
    try std.testing.expectEqualSlices(u8, "/?id=2", request.url.?.raw);
    try std.testing.expectEqual(Protocol.HTTP11, request.protocol.?);
    try std.testing.expectEqualSlices(u8, "test", request.body.?);
}

test "Parse Request (5)" {
    const allocator = std.testing.allocator;
    var stream = testFakeStream("POST /?id=4&sort=false HTTP/1.1\r\nHeaders-Length: none\r\nContent-Length: 4\r\n\r\nsomelongtest");
    var request = try Self.init(allocator, stream.reader().any(), .{});
    defer request.deinit();

    const someHeader = request.getHeader("headers-length") orelse return std.testing.expect(false);
    try std.testing.expectEqualSlices(u8, "headers-length", someHeader.key);
    try std.testing.expectEqualSlices(u8, "none", someHeader.value);

    const contentHeader = request.getHeader("content-length") orelse return std.testing.expect(false);
    try std.testing.expectEqualSlices(u8, "content-length", contentHeader.key);
    try std.testing.expectEqualSlices(u8, "4", contentHeader.value);

    try std.testing.expect(request.method != null);
    try std.testing.expect(request.url != null);
    try std.testing.expect(request.query != null);
    try std.testing.expect(request.query.?.len == 2);
    try std.testing.expect(request.protocol != null);
    try std.testing.expect(request.headers != null);
    try std.testing.expect(request.headers.?.len == 2);
    try std.testing.expect(request.body != null);

    try expectQueryKeyValue(request.query.?[0], "id", "4");
    try expectQueryKeyValue(request.query.?[1], "sort", "false");
    try expectHeaderKeyValue(request.headers.?[0], "headers-length", "none");
    try expectHeaderKeyValue(request.headers.?[1], "content-length", "4");

    try std.testing.expectEqualSlices(u8, "POST", request.method.?);
    try std.testing.expectEqualSlices(u8, "/", request.url.?.path);
    try std.testing.expectEqualSlices(u8, "/?id=4&sort=false", request.url.?.raw);
    try std.testing.expectEqual(Protocol.HTTP11, request.protocol.?);
    try std.testing.expectEqualSlices(u8, "some", request.body.?);
}

test "Parse Request (6)" {
    const allocator = std.testing.allocator;
    const body = ("abc" ** 2000);
    var stream = testFakeStream("POST / HTTP/1.1\r\nContent-Length: 6000\r\n\r\n" ++ body);
    var request = try Self.init(allocator, stream.reader().any(), .{
        .maxBodySize = 6000,
    });
    defer request.deinit();

    try std.testing.expect(request.method != null);
    try std.testing.expect(request.url != null);
    try std.testing.expect(request.query == null);
    try std.testing.expect(request.protocol != null);
    try std.testing.expect(request.headers != null);
    try std.testing.expect(request.headers.?.len == 1);
    try std.testing.expect(request.body != null);

    try expectHeaderKeyValue(request.headers.?[0], "content-length", "6000");

    try std.testing.expectEqualSlices(u8, "POST", request.method.?);
    try std.testing.expectEqualSlices(u8, "/", request.url.?.path);
    try std.testing.expectEqualSlices(u8, "/", request.url.?.raw);
    try std.testing.expectEqual(Protocol.HTTP11, request.protocol.?);
    try std.testing.expectEqualSlices(u8, body, request.body.?);
}

test "Parse Request Error" {
    const allocator = std.testing.allocator;

    var stream1 = testFakeStream("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\ntest");
    try std.testing.expectError(ParseError.ConnectionClosed, Self.init(allocator, stream1.reader().any(), .{}));
    var stream2 = testFakeStream("POST / HTTP/1.1\r\nContent-Length: \r\n\r\ntest");
    try std.testing.expectError(ParseError.InvalidContentLength, Self.init(allocator, stream2.reader().any(), .{}));
    var stream3 = testFakeStream("POST / HTTP/1.1\r\nContent-Length: 9999999999\r\n\r\nverylargebody");
    try std.testing.expectError(ParseError.BodyTooLarge, Self.init(allocator, stream3.reader().any(), .{
        .maxBodySize = 4,
    }));
    var stream4 = testFakeStream("POST / HTTP/1.1\r\nContent-Length: 6000\r\n\r\n" ++ ("abc" ** 2000));
    try std.testing.expectError(ParseError.BodyTooLarge, Self.init(allocator, stream4.reader().any(), .{}));
}

test {
    _ = Url;
}
