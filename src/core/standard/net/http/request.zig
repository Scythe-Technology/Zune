// This code is based on https://github.com/karlseguin/http.zig/blob/c3bf0fca2c224510d0496100178fa6e25bb97473/src/request.zig

const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

const Self = @This();

const Url = @import("url.zig");

const Stream = std.net.Stream;
const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Method = enum {
    GET,
    PUT,
    POST,
    HEAD,
    PATCH,
    DELETE,
    OPTIONS,
    CONNECT,
};

pub const Protocol = enum {
    HTTP10,
    HTTP11,
};

/// converts ascii to unsigned int of appropriate size
pub fn asUint(comptime string: anytype) @Type(std.builtin.Type{
    .int = .{
        .bits = @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
        .signedness = .unsigned,
    },
}) {
    const byteLength = @bitSizeOf(@TypeOf(string.*)) / 8 - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const QueryValue = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const Parser = struct {
    arena: ArenaAllocator,
    buf: ?[]const u8 = null,
    left: ?[]const u8 = null,
    pos: usize = 0,

    stage: enum { method, url, protocol, headers, body } = .method,
    method: Method = .GET,
    protocol: Protocol = .HTTP10,
    headers: std.StringHashMapUnmanaged([]const u8),
    body: ?union(enum) {
        dynamic: []u8,
        static: []const u8,
    } = null,
    url: ?[]const u8 = null,

    max_body_size: usize = 1_048_576,
    max_header_size: usize = 4096,
    max_header_count: usize = 100,

    pub fn init(allocator: Allocator, max_header_count: u32) Parser {
        var headers: std.StringHashMapUnmanaged([]const u8) = .empty;
        headers.ensureTotalCapacity(allocator, max_header_count) catch |err| std.debug.panic("{}\n", .{err});
        return .{
            .arena = .init(allocator),
            .headers = headers,
            .max_header_count = max_header_count,
        };
    }

    pub fn reset(self: *Parser) void {
        self.body = null;
        self.buf = null;
        self.url = null;
        self.method = .GET;
        if (self.left) |_| {
            self.left = null;
        }
        if (!self.arena.reset(.retain_capacity)) {
            _ = self.arena.reset(.free_all);
        }
        self.pos = 0;
        self.stage = .method;
        self.headers.clearRetainingCapacity();
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
        self.headers.deinit(self.arena.child_allocator);
    }

    pub fn canKeepAlive(self: *const Parser) bool {
        return switch (self.protocol) {
            .HTTP11 => {
                if (self.headers.get("connection")) |conn| {
                    return !std.mem.eql(u8, conn, "close");
                }
                return true;
            },
            .HTTP10 => {
                // var iter = self.headers.iterator();
                // std.debug.print("http 10\n", .{});
                return false;
            }, // TODO: support this in the cases where it can be
        };
    }

    pub fn parse(self: *Parser, buf: []const u8) !bool {
        if (buf.len == 0)
            return false;

        const allocator = self.arena.child_allocator;
        const arena_allocator = self.arena.allocator();
        var input = buf;
        var allocated = false;
        if (self.left) |left| {
            input = try std.mem.concat(allocator, u8, &.{ left, buf });
            defer allocator.free(left);
            self.left = null;
            allocated = true;
        }
        defer if (allocated) allocator.free(input);

        const pos = self.pos;
        self.pos = 0;

        sw: switch (self.stage) {
            .method => if (try self.parseMethod(input[self.pos..]))
                continue :sw .url,
            .url => if (try self.parseUrl(arena_allocator, input[self.pos..]))
                continue :sw .protocol,
            .protocol => if (try self.parseProtocol(input[self.pos..]))
                continue :sw .headers,
            .headers => if (try self.parseHeaders(arena_allocator, input[self.pos..], allocated))
                return true,
            .body => {
                if (self.body) |b|
                    switch (b) {
                        .dynamic => |body| {
                            if (self.pos > 0) {
                                return false;
                            }
                            const remaining = body.len - pos;
                            if (buf.len >= remaining) {
                                @memcpy(body[pos..], buf[0..remaining]);
                                self.pos = pos + buf.len;
                                return true;
                            } else {
                                @memcpy(body[pos .. pos + buf.len], buf[0..]);
                                self.pos = pos + buf.len;
                                return false;
                            }
                        },
                        else => {},
                    };
                return true;
            },
        }

        const leftover = input[self.pos..];
        if (leftover.len > 0)
            self.left = try allocator.dupe(u8, leftover);

        return false;
    }

    fn parseMethod(self: *Parser, buf: []const u8) !bool {
        const buf_len = buf.len;

        // Shortest method is only 3 characters (+1 trailing space), so
        // this seems like it should be: if (buf_len < 4)
        // But the longest method, OPTIONS, is 7 characters (+1 trailing space).
        // Now even if we have a short method, like "GET ", we'll eventually expect
        // a URL + protocol. The shorter valid line is: e.g. GET / HTTP/1.1
        // If buf_len < 8, we _might_ have a method, but we still need more data
        // and might as well break early.
        // If buf_len > = 8, then we can safely parse any (valid) method without
        // having to do any other bound-checking.
        if (buf_len < 8) return false;

        // this approach to matching method name comes from zhp
        switch (@as(u32, @bitCast(buf[0..4].*))) {
            asUint("GET ") => {
                self.pos = 4;
                self.method = .GET;
            },
            asUint("PUT ") => {
                self.pos = 4;
                self.method = .PUT;
            },
            asUint("POST") => {
                if (buf[4] != ' ') return error.UnknownMethod;
                self.pos = 5;
                self.method = .POST;
            },
            asUint("HEAD") => {
                if (buf[4] != ' ') return error.UnknownMethod;
                self.pos = 5;
                self.method = .HEAD;
            },
            asUint("PATC") => {
                if (buf[4] != 'H' or buf[5] != ' ') return error.UnknownMethod;
                self.pos = 6;
                self.method = .PATCH;
            },
            asUint("DELE") => {
                if (@as(u32, @bitCast(buf[3..7].*)) != asUint("ETE ")) return error.UnknownMethod;
                self.pos = 7;
                self.method = .DELETE;
            },
            asUint("OPTI") => {
                if (@as(u32, @bitCast(buf[4..8].*)) != asUint("ONS ")) return error.UnknownMethod;
                self.pos = 8;
                self.method = .OPTIONS;
            },
            asUint("CONN") => {
                if (@as(u32, @bitCast(buf[4..8].*)) != asUint("ECT ")) return error.UnknownMethod;
                self.pos = 8;
                self.method = .CONNECT;
            },
            else => return error.UnknownMethod,
        }
        return true;
    }

    fn parseUrl(self: *Parser, arena: Allocator, buf: []const u8) !bool {
        self.stage = .url;
        const buf_len = buf.len;
        if (buf_len == 0) return false;

        var len: usize = 0;
        switch (buf[0]) {
            '/' => {
                const end_index = std.mem.indexOfScalarPos(u8, buf[1..buf_len], 0, ' ') orelse return false;
                // +1 since we skipped the leading / in our indexOfScalar and +1 to consume the space
                len = end_index + 2;
                const url = buf[0 .. end_index + 1];
                if (!Url.isValid(url)) return error.InvalidRequestTarget;
                self.url = try arena.dupe(u8, url);
            },
            '*' => {
                if (buf_len == 1) return false;
                // Read never returns 0, so if we're here, buf.len >= 1
                if (buf[1] != ' ') return error.InvalidRequestTarget;
                len = 2;
                self.url = "*";
            },
            // TODO: Support absolute-form target (e.g. http://....)
            else => return error.InvalidRequestTarget,
        }

        self.pos += len;
        return true;
    }

    fn parseProtocol(self: *Parser, buf: []const u8) !bool {
        self.stage = .protocol;
        if (buf.len < 10) return false;

        if (@as(u32, @bitCast(buf[0..4].*)) != asUint("HTTP")) {
            return error.UnknownProtocol;
        }

        self.protocol = switch (@as(u32, @bitCast(buf[4..8].*))) {
            asUint("/1.1") => .HTTP11,
            asUint("/1.0") => .HTTP10,
            else => return error.UnsupportedProtocol,
        };

        if (buf[8] != '\r' or buf[9] != '\n') {
            return error.UnknownProtocol;
        }

        self.pos += 10;
        return true;
    }

    fn parseHeaders(self: *Parser, arena: Allocator, full: []const u8, allocated: bool) !bool {
        self.stage = .headers;
        var pos: usize = 0;
        var buf = full;
        const max_header_size = self.max_header_size;
        line: while (buf.len > 0) {
            for (buf, 0..) |bn, i| {
                switch (bn) {
                    'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
                    ':' => {
                        const value_start = i + 1; // skip the colon
                        var value, const skip_len = trimLeadingSpaceCount(buf[value_start..]);
                        for (value, 0..) |bv, j| {
                            if (j + i > max_header_size)
                                return error.HeaderTooBig;
                            if (allowedHeaderValueByte[bv] == true) {
                                continue;
                            }

                            // To keep ALLOWED_HEADER_VALUE small, we said \r
                            // was illegal. I mean, it _is_ illegal in a header value
                            // but it isn't part of the header value, it's (probably) the end of line
                            if (bv != '\r') {
                                return error.InvalidHeaderLine;
                            }

                            const next = j + 1;
                            if (next == value.len) {
                                // we don't have any more data, we can't tell
                                self.pos += pos;
                                return false;
                            }

                            if (value[next] != '\n') {
                                // we have a \r followed by something that isn't
                                // a \n. Can't be valid
                                return error.InvalidHeaderLine;
                            }

                            // If we're here, it means our value had valid characters
                            // up until the point of a newline (\r\n), which means
                            // we have a valid value (and name)
                            value = value[0..j];
                            break;
                        } else {
                            // for loop reached the end without finding a \r
                            // we need more data
                            self.pos += pos;
                            return false;
                        }

                        const name = buf[0..i];
                        if (self.headers.size >= self.max_header_count)
                            return error.TooManyHeaders;
                        const name_copy = if (self.headers.getKey(name) == null) blk: {
                            const alloc = try arena.dupe(u8, name);
                            _ = std.ascii.lowerString(alloc, name);
                            break :blk alloc;
                        } else name;
                        const value_copy = try arena.dupe(u8, value);
                        errdefer self.allocator.free(value_copy);
                        const res = self.headers.getOrPutAssumeCapacity(name_copy);
                        if (res.found_existing) {
                            arena.free(res.value_ptr.*);
                            res.value_ptr.* = value_copy;
                        } else res.value_ptr.* = value_copy;
                        // +2 to skip the \r\n
                        const next_line = value_start + skip_len + value.len + 2;
                        pos += next_line;
                        buf = buf[next_line..];
                        continue :line;
                    },
                    '\r' => {
                        if (i != 0) {
                            // We're still parsing the header name, so a
                            // \r should either be at the very start (to indicate the end of our headers)
                            // or not be there at all
                            return error.InvalidHeaderLine;
                        }

                        if (buf.len == 1) {
                            // we don't have any more data, we need more data
                            self.pos += pos;
                            return false;
                        }

                        if (buf[1] == '\n') {
                            // we have \r\n at the start of a line, we're done
                            pos += 2;
                            self.buf = full[pos..];
                            self.pos += pos;
                            return try self.prepareForBody(arena, allocated);
                        }
                        // we have a \r followed by something that isn't a \n, can't be right
                        return error.InvalidHeaderLine;
                    },
                    else => return error.InvalidHeaderLine,
                }
            } else {
                // didn't find a colon or blank line, we need more data
                self.pos += pos;
                return false;
            }
        }
        self.pos += pos;
        return false;
    }

    fn prepareForBody(self: *Parser, arena: Allocator, allocated: bool) !bool {
        self.stage = .body;
        const str = self.headers.get("content-length") orelse return true;
        const cl = atoi(str) orelse return error.InvalidContentLength;

        if (cl == 0)
            return true;

        if (cl > self.max_body_size) {
            return error.BodyTooBig;
        }

        self.pos = 0;
        const buf = self.buf.?;
        const len = buf.len;

        // how much (if any) of the body we've already read
        var read = len;

        if (read > cl)
            read = cl;

        // how much of the body are we missing
        const missing = cl - read;

        if (missing == 0) {
            // we've read the entire body into buf, point to that.
            self.pos += cl;
            if (allocated) {
                self.body = .{ .dynamic = try arena.dupe(u8, buf[0..cl]) };
            } else {
                self.body = .{ .static = buf[0..cl] };
            }
            return true;
        } else {
            // We don't have the [full] body, and our static buffer is too small
            const body_buf = try arena.alloc(u8, cl);
            if (read > 0)
                @memcpy(body_buf[0..read], buf[0..read]);
            self.pos = read;
            self.body = .{ .dynamic = body_buf };
        }
        return false;
    }

    pub fn parseQuery(self: *Parser, query: []const u8, maxQuery: usize) ![]QueryValue {
        const raw = query;
        if (raw.len == 0) {
            return &.{};
        }

        const allocator = self.arena.allocator();
        var count: usize = 1;
        for (raw) |b| {
            if (b == '&') count += 1;
            if (count > maxQuery) {
                return error.MaxQueryExceeded;
            }
        }

        var pos: usize = 0;
        const list = try allocator.alloc(QueryValue, count);

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

        return list;
    }

    pub fn push(self: *Parser, L: *VM.lua.State) !void {
        L.createtable(0, 2);

        L.Zsetfield(-1, "method", @tagName(self.method));

        if (self.url) |url| {
            const parsed = Url.parse(url);
            L.Zsetfield(-1, "path", parsed.path);
            const queries = try self.parseQuery(parsed.query, 24);
            if (queries.len > 0) {
                L.createtable(0, @intCast(queries.len));
                var order: i32 = 1;
                for (queries) |query| {
                    L.pushlstring(query.key);
                    if (query.value) |value| {
                        L.pushlstring(value);
                        L.rawset(-3);
                    } else {
                        L.rawseti(-2, order);
                        order += 1;
                    }
                }
                L.setfield(-2, "query");
            }
        }

        L.createtable(0, @intCast(self.headers.size));
        var iter = self.headers.iterator();
        while (iter.next()) |header| {
            L.pushlstring(header.key_ptr.*);
            L.pushlstring(header.value_ptr.*);
            L.rawset(-3);
        }
        L.setfield(-2, "headers");

        if (self.body) |body|
            switch (body) {
                inline else => |bytes| L.Zsetfield(-1, "body", bytes),
            };
    }
};

const allowedHeaderValueByte = blk: {
    var v = [_]bool{false} ** 256;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_ :;.,/\"'?!(){}[]@<>=-+*#$&`|~^%\t\\") |b| {
        v[b] = true;
    }
    break :blk v;
};

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

inline fn trimLeadingSpace(in: []const u8) []const u8 {
    const out, _ = trimLeadingSpaceCount(in);
    return out;
}

fn atoi(str: []const u8) ?usize {
    if (str.len == 0) {
        return null;
    }

    var n: usize = 0;
    for (str) |b| {
        if (b < '0' or b > '9') {
            return null;
        }
        n = std.math.mul(usize, n, 10) catch return null;
        n = std.math.add(usize, n, @intCast(b - '0')) catch return null;
    }
    return n;
}

const testing = std.testing;

test "atoi" {
    var buf: [5]u8 = undefined;
    for (0..99999) |i| {
        const n = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
        try testing.expectEqual(i, atoi(buf[0..n]).?);
    }

    try testing.expectEqual(null, atoi(""));
    try testing.expectEqual(null, atoi("392a"));
    try testing.expectEqual(null, atoi("b392"));
    try testing.expectEqual(null, atoi("3c92"));
}

test "allowedHeaderValueByte" {
    var all = std.mem.zeroes([255]bool);
    for ('a'..('z' + 1)) |b| all[b] = true;
    for ('A'..('Z' + 1)) |b| all[b] = true;
    for ('0'..('9' + 1)) |b| all[b] = true;
    for ([_]u8{ '_', ' ', ',', ':', ';', '.', ',', '\\', '/', '"', '\'', '?', '!', '(', ')', '{', '}', '[', ']', '@', '<', '>', '=', '-', '+', '*', '#', '$', '&', '`', '|', '~', '^', '%', '\t' }) |b| {
        all[b] = true;
    }
    for (128..255) |b| all[b] = false;

    for (all, 0..) |allowed, b| {
        try testing.expectEqual(allowed, allowedHeaderValueByte[@intCast(b)]);
    }
}

fn testParseProcedural(input: []const u8, max: u32) !Parser {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, max);
    errdefer parser.deinit();

    var tiny_buf: [1]u8 = undefined;
    for (input) |b| {
        tiny_buf[0] = b;
        if (try parser.parse(tiny_buf[0..1]))
            return parser;
    }

    return error.Incomplete;
}

fn testParseFull(comptime input: []const u8, max: u32) !Parser {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, max);
    errdefer parser.deinit();

    if (try parser.parse(input)) {
        return parser;
    }

    return error.Incomplete;
}

test "parser: basic (procedural)" {
    var parser = try testParseProcedural("GET / HTTP/1.1\r\n\r\n", 0);
    defer parser.deinit();

    try testing.expectEqual(.GET, parser.method);
    try testing.expectEqualStrings("/", parser.url.?);
    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(2, parser.pos);
    try testing.expectEqual(0, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: bad (procedural)" {
    try testing.expectError(error.UnknownMethod, testParseProcedural("FOO / HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.UnknownProtocol, testParseProcedural("GET / HTTP/1.0__\r\n\r\n", 0));
    try testing.expectError(error.UnsupportedProtocol, testParseProcedural("GET / HTTP/3.0\r\n\r\n", 0));
    try testing.expectError(error.UnknownProtocol, testParseProcedural("GET /  HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.InvalidRequestTarget, testParseProcedural("GET  / HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.InvalidHeaderLine, testParseProcedural("GET / HTTP/1.1\r\n  ", 0));
}

test "parser: many headers (procedural)" {
    var parser = try testParseProcedural("GET / HTTP/1.1\r\nHost: foo.bar\r\nAccept: text/html\r\nUser-Agent: curl/7.64.1\r\nAccept-Language: en-US,en;q=0.5\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\nUpgrade-Insecure-Requests: 1\r\nCache-Control: max-age=0\r\n\r\n", 100);
    defer parser.deinit();

    try testing.expectEqual(.GET, parser.method);
    try testing.expectEqualStrings("/", parser.url.?);
    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(2, parser.pos);
    try testing.expectEqual(8, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: too many headers (procedural)" {
    try testing.expectEqual(error.TooManyHeaders, testParseProcedural("GET / HTTP/1.1\r\nHost: foo.bar\r\nAccept: text/html\r\nUser-Agent: curl/7.64.1\r\nAccept-Language: en-US,en;q=0.5", 1));
}

test "parser: large headers (procedural)" {
    try testing.expectEqual(error.HeaderTooBig, testParseProcedural("GET / HTTP/1.1\r\nHost: " ++ ("foobar" ** 690), 100));
}

test "parser: many kinds (procedural)" {
    {
        var parser = try testParseProcedural("GET / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();
        try testing.expectEqual(.GET, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseProcedural("PUT / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();
        try testing.expectEqual(.PUT, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseProcedural("POST / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();
        try testing.expectEqual(.POST, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseProcedural("HEAD / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();
        try testing.expectEqual(.HEAD, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseProcedural("PATCH / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();
        try testing.expectEqual(.PATCH, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseProcedural("DELETE / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();
        try testing.expectEqual(.DELETE, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseProcedural("OPTIONS / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();
        try testing.expectEqual(.OPTIONS, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseProcedural("CONNECT / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();
        try testing.expectEqual(.CONNECT, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
}

test "parser: url (procedural)" {
    var parser = try testParseProcedural("GET /foo/bar/baz?a=b HTTP/1.1\r\n\r\n", 0);
    defer parser.deinit();

    try testing.expectEqual(.GET, parser.method);
    try testing.expectEqualStrings("/foo/bar/baz?a=b", parser.url.?);
    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(2, parser.pos);
    try testing.expectEqual(0, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);

    const url = Url.parse(parser.url.?);
    const query = try parser.parseQuery(url.query, 1);
    try testing.expectEqual(1, query.len);
    try testing.expectEqualStrings("a", query[0].key);
    try testing.expectEqualStrings("b", query[0].value.?);
}

test "parser: bad url (procedural)" {
    try testing.expectError(error.InvalidRequestTarget, testParseProcedural("GET . HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.InvalidRequestTarget, testParseProcedural("GET ** HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.InvalidRequestTarget, testParseProcedural("GET /" ++ [_]u8{0} ++ " HTTP/1.1\r\n\r\n", 0));
}

test "parser: body (procedural)" {
    var parser = try testParseProcedural("GET / HTTP/1.1\r\nHost: foo.bar\r\nContent-Length: 5\r\n\r\nhello", 2);
    defer parser.deinit();

    try testing.expectEqual(.GET, parser.method);
    try testing.expectEqualStrings("/", parser.url.?);
    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(5, parser.pos);
    try testing.expectEqual(2, parser.headers.size);
    try testing.expect(parser.body.? == .dynamic);
    try testing.expectEqual(.body, parser.stage);
    try testing.expectEqualStrings("hello", parser.body.?.dynamic);
}

test "parser: basic (full)" {
    var parser = try testParseFull("GET / HTTP/1.1\r\n\r\n", 0);
    defer parser.deinit();

    try testing.expectEqual(.GET, parser.method);
    try testing.expectEqualStrings("/", parser.url.?);
    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(18, parser.pos);
    try testing.expectEqual(0, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: bad (full)" {
    try testing.expectError(error.UnknownMethod, testParseFull("FOO / HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.UnknownProtocol, testParseFull("GET / HTTP/1.0__\r\n\r\n", 0));
    try testing.expectError(error.UnsupportedProtocol, testParseFull("GET / HTTP/3.0\r\n\r\n", 0));
    try testing.expectError(error.UnknownProtocol, testParseFull("GET /  HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.InvalidRequestTarget, testParseFull("GET  / HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.InvalidHeaderLine, testParseFull("GET / HTTP/1.1\r\n  ", 0));
}

test "parser: many headers (full)" {
    var parser = try testParseFull("GET / HTTP/1.1\r\nHost: foo.bar\r\nAccept: text/html\r\nUser-Agent: curl/7.64.1\r\nAccept-Language: en-US,en;q=0.5\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\nUpgrade-Insecure-Requests: 1\r\nCache-Control: max-age=0\r\n\r\n", 100);
    defer parser.deinit();

    try testing.expectEqual(.GET, parser.method);
    try testing.expectEqualStrings("/", parser.url.?);
    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(222, parser.pos);
    try testing.expectEqual(8, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);
}

test "parser: too many headers (full)" {
    try testing.expectEqual(error.TooManyHeaders, testParseFull("GET / HTTP/1.1\r\nHost: foo.bar\r\nAccept: text/html\r\nUser-Agent: curl/7.64.1\r\nAccept-Language: en-US,en;q=0.5", 1));
}

test "parser: large headers (full)" {
    try testing.expectEqual(error.HeaderTooBig, testParseFull("GET / HTTP/1.1\r\nHost: " ++ ("foobar" ** 690) ++ "\r\n\r\n", 100));
}

test "parser: many kinds (full)" {
    {
        var parser = try testParseFull("GET / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();

        try testing.expectEqual(.GET, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseFull("PUT / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();

        try testing.expectEqual(.PUT, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseFull("POST / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();

        try testing.expectEqual(.POST, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseFull("HEAD / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();

        try testing.expectEqual(.HEAD, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseFull("PATCH / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();

        try testing.expectEqual(.PATCH, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseFull("DELETE / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();

        try testing.expectEqual(.DELETE, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseFull("OPTIONS / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();

        try testing.expectEqual(.OPTIONS, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
    {
        var parser = try testParseFull("CONNECT / HTTP/1.1\r\n\r\n", 0);
        defer parser.deinit();

        try testing.expectEqual(.CONNECT, parser.method);
        try testing.expectEqualStrings("/", parser.url.?);
        try testing.expectEqual(.HTTP11, parser.protocol);
    }
}

test "parser: url (full)" {
    var parser = try testParseFull("GET /foo/bar/baz?a=b HTTP/1.1\r\n\r\n", 0);
    defer parser.deinit();

    try testing.expectEqual(.GET, parser.method);
    try testing.expectEqualStrings("/foo/bar/baz?a=b", parser.url.?);
    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(33, parser.pos);
    try testing.expectEqual(0, parser.headers.size);
    try testing.expectEqual(.body, parser.stage);
    try testing.expect(parser.body == null);
    try testing.expect(parser.buf != null);
    try testing.expect(parser.left == null);

    const url = Url.parse(parser.url.?);
    const query = try parser.parseQuery(url.query, 1);
    try testing.expectEqual(1, query.len);
    try testing.expectEqualStrings("a", query[0].key);
    try testing.expectEqualStrings("b", query[0].value.?);
}

test "parser: bad url (full)" {
    try testing.expectError(error.InvalidRequestTarget, testParseFull("GET . HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.InvalidRequestTarget, testParseFull("GET ** HTTP/1.1\r\n\r\n", 0));
    try testing.expectError(error.InvalidRequestTarget, testParseFull("GET /" ++ [_]u8{0} ++ " HTTP/1.1\r\n\r\n", 0));
}

test "parser: body (full)" {
    const input = "GET / HTTP/1.1\r\nHost: foo.bar\r\nContent-Length: 5\r\n\r\nhello";
    var parser = try testParseFull(input, 2);
    defer parser.deinit();

    try testing.expectEqual(.GET, parser.method);
    try testing.expectEqualStrings("/", parser.url.?);
    try testing.expectEqual(.HTTP11, parser.protocol);
    try testing.expectEqual(5, parser.pos);
    try testing.expectEqual(2, parser.headers.size);
    try testing.expect(parser.body.? == .static);
    try testing.expectEqual(.body, parser.stage);
    try testing.expectEqualStrings("hello", parser.body.?.static);
}

// test "request: header too big" {
//     try expectParseError(error.HeaderTooBig, "GET / HTTP/1.1\r\n\r\n", .{ .buffer_size = 17 });
//     try expectParseError(error.HeaderTooBig, "GET / HTTP/1.1\r\nH: v\r\n\r\n", .{ .buffer_size = 23 });
// }

// test "request: parse method" {
//     defer t.reset();
//     {
//         try expectParseError(error.UnknownMethod, " PUT / HTTP/1.1", .{});
//         try expectParseError(error.UnknownMethod, "GET/HTTP/1.1", .{});
//         try expectParseError(error.UnknownMethod, "PUT/HTTP/1.1", .{});

//         try expectParseError(error.UnknownMethod, "get / HTTP/1.1", .{}); // lowecase
//         try expectParseError(error.UnknownMethod, "Other / HTTP/1.1", .{}); // lowercase
//     }

//     {
//         const r = try testParse("GET / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Method.GET, r.method);
//         try t.expectString("", r.method_string);
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Method.PUT, r.method);
//         try t.expectString("", r.method_string);
//     }

//     {
//         const r = try testParse("POST / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Method.POST, r.method);
//         try t.expectString("", r.method_string);
//     }

//     {
//         const r = try testParse("HEAD / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Method.HEAD, r.method);
//         try t.expectString("", r.method_string);
//     }

//     {
//         const r = try testParse("PATCH / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Method.PATCH, r.method);
//         try t.expectString("", r.method_string);
//     }

//     {
//         const r = try testParse("DELETE / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Method.DELETE, r.method);
//         try t.expectString("", r.method_string);
//     }

//     {
//         const r = try testParse("OPTIONS / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Method.OPTIONS, r.method);
//         try t.expectString("", r.method_string);
//     }

//     {
//         const r = try testParse("TEA / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Method.OTHER, r.method);
//         try t.expectString("TEA", r.method_string);
//     }
// }

// test "request: parse request target" {
//     defer t.reset();
//     {
//         try expectParseError(error.InvalidRequestTarget, "GET NOPE", .{});
//         try expectParseError(error.InvalidRequestTarget, "GET nope ", .{});
//         try expectParseError(error.InvalidRequestTarget, "GET http://www.pondzpondz.com/test ", .{}); // this should be valid
//         try expectParseError(error.InvalidRequestTarget, "PUT hello ", .{});
//         try expectParseError(error.InvalidRequestTarget, "POST  /hello ", .{});
//         try expectParseError(error.InvalidRequestTarget, "POST *hello ", .{});
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
//         try t.expectString("/", r.url.raw);
//     }

//     {
//         const r = try testParse("PUT /api/v2 HTTP/1.1\r\n\r\n", .{});
//         try t.expectString("/api/v2", r.url.raw);
//     }

//     {
//         const r = try testParse("DELETE /API/v2?hack=true&over=9000%20!! HTTP/1.1\r\n\r\n", .{});
//         try t.expectString("/API/v2?hack=true&over=9000%20!!", r.url.raw);
//     }

//     {
//         const r = try testParse("PUT * HTTP/1.1\r\n\r\n", .{});
//         try t.expectString("*", r.url.raw);
//     }
// }

// test "request: parse protocol" {
//     defer t.reset();
//     {
//         try expectParseError(error.UnknownProtocol, "GET / http/1.1\r\n", .{});
//         try expectParseError(error.UnsupportedProtocol, "GET / HTTP/2.0\r\n", .{});
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.0\r\n\r\n", .{});
//         try t.expectEqual(http.Protocol.HTTP10, r.protocol);
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(http.Protocol.HTTP11, r.protocol);
//     }
// }

// test "request: parse headers" {
//     defer t.reset();
//     {
//         try expectParseError(error.InvalidHeaderLine, "GET / HTTP/1.1\r\nHost\r\n", .{});
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.0\r\n\r\n", .{});
//         try t.expectEqual(0, r.headers.len);
//     }

//     {
//         var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\n\r\n", .{});

//         try t.expectEqual(1, r.headers.len);
//         try t.expectString("pondzpondz.com", r.headers.get("host").?);
//     }

//     {
//         var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nMisc:  Some-Value\r\nAuthorization:none\r\n\r\n", .{});
//         try t.expectEqual(3, r.headers.len);
//         try t.expectString("pondzpondz.com", r.header("host").?);
//         try t.expectString("Some-Value", r.header("misc").?);
//         try t.expectString("none", r.header("authorization").?);
//     }
// }

// test "request: canKeepAlive" {
//     defer t.reset();
//     {
//         // implicitly keepalive for 1.1
//         var r = try testParse("GET / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(true, r.canKeepAlive());
//     }

//     {
//         // explicitly keepalive for 1.1
//         var r = try testParse("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n", .{});
//         try t.expectEqual(true, r.canKeepAlive());
//     }

//     {
//         // explicitly not keepalive for 1.1
//         var r = try testParse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", .{});
//         try t.expectEqual(false, r.canKeepAlive());
//     }
// }

// test "request: query" {
//     defer t.reset();
//     {
//         // none
//         var r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(0, (try r.query()).len);
//     }

//     {
//         // none with path
//         var r = try testParse("PUT /why/would/this/matter HTTP/1.1\r\n\r\n", .{});
//         try t.expectEqual(0, (try r.query()).len);
//     }

//     {
//         // value-less
//         var r = try testParse("PUT /?a HTTP/1.1\r\n\r\n", .{});
//         const query = try r.query();
//         try t.expectEqual(1, query.len);
//         try t.expectString("", query.get("a").?);
//         try t.expectEqual(null, query.get("b"));
//     }

//     {
//         // single
//         var r = try testParse("PUT /?a=1 HTTP/1.1\r\n\r\n", .{});
//         const query = try r.query();
//         try t.expectEqual(1, query.len);
//         try t.expectString("1", query.get("a").?);
//         try t.expectEqual(null, query.get("b"));
//     }

//     {
//         // multiple
//         var r = try testParse("PUT /path?Teg=Tea&it%20%20IS=over%209000%24&ha%09ck HTTP/1.1\r\n\r\n", .{});
//         const query = try r.query();
//         try t.expectEqual(3, query.len);
//         try t.expectString("Tea", query.get("Teg").?);
//         try t.expectString("over 9000$", query.get("it  IS").?);
//         try t.expectString("", query.get("ha\tck").?);
//     }
// }

// test "request: body content-length" {
//     defer t.reset();
//     {
//         // too big
//         try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{ .max_body_size = 9 });
//     }

//     {
//         // no body
//         var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
//         try t.expectEqual(null, r.body());
//         try t.expectEqual(null, r.body());
//     }

//     {
//         // fits into static buffer
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
//         try t.expectString("Over 9000!", r.body().?);
//         try t.expectString("Over 9000!", r.body().?);
//     }

//     {
//         // Requires dynamic buffer
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 11\r\n\r\nOver 9001!!", .{ .buffer_size = 40 });
//         try t.expectString("Over 9001!!", r.body().?);
//         try t.expectString("Over 9001!!", r.body().?);
//     }
// }

// // the query and body both (can) occupy space in our static buffer
// test "request: query & body" {
//     defer t.reset();

//     // query then body
//     var r = try testParse("POST /?search=keemun%20tea HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
//     try t.expectString("keemun tea", (try r.query()).get("search").?);
//     try t.expectString("Over 9000!", r.body().?);

//     // results should be cached internally, but let's double check
//     try t.expectString("keemun tea", (try r.query()).get("search").?);
// }

// test "request: invalid content-length" {
//     defer t.reset();
//     try expectParseError(error.InvalidContentLength, "GET / HTTP/1.0\r\nContent-Length: 1\r\n\r\nabc", .{});
// }

// test "body: json" {
//     defer t.reset();
//     const Tea = struct {
//         type: []const u8,
//     };

//     {
//         // too big
//         try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{ .max_body_size = 16 });
//     }

//     {
//         // no body
//         var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
//         try t.expectEqual(null, try r.json(Tea));
//         try t.expectEqual(null, try r.json(Tea));
//     }

//     {
//         // parses json
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
//         try t.expectString("keemun", (try r.json(Tea)).?.type);
//         try t.expectString("keemun", (try r.json(Tea)).?.type);
//     }
// }

// test "body: jsonValue" {
//     defer t.reset();
//     {
//         // too big
//         try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{ .max_body_size = 16 });
//     }

//     {
//         // no body
//         var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
//         try t.expectEqual(null, try r.jsonValue());
//         try t.expectEqual(null, try r.jsonValue());
//     }

//     {
//         // parses json
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
//         try t.expectString("keemun", (try r.jsonValue()).?.object.get("type").?.string);
//         try t.expectString("keemun", (try r.jsonValue()).?.object.get("type").?.string);
//     }
// }

// test "body: jsonObject" {
//     defer t.reset();
//     {
//         // too big
//         try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{ .max_body_size = 16 });
//     }

//     {
//         // no body
//         var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
//         try t.expectEqual(null, try r.jsonObject());
//         try t.expectEqual(null, try r.jsonObject());
//     }

//     {
//         // not an object
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 7\r\n\r\n\"hello\"", .{});
//         try t.expectEqual(null, try r.jsonObject());
//         try t.expectEqual(null, try r.jsonObject());
//     }

//     {
//         // parses json
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
//         try t.expectString("keemun", (try r.jsonObject()).?.get("type").?.string);
//         try t.expectString("keemun", (try r.jsonObject()).?.get("type").?.string);
//     }
// }

// test "body: formData" {
//     defer t.reset();
//     {
//         // too big
//         try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 22\r\n\r\nname=test", .{ .max_body_size = 21 });
//     }

//     {
//         // no body
//         var r = try testParse("POST / HTTP/1.0\r\n\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
//         const formData = try r.formData();
//         try t.expectEqual(null, formData.get("name"));
//         try t.expectEqual(null, formData.get("name"));
//     }

//     {
//         // parses formData
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 9\r\n\r\nname=test", .{ .max_form_count = 2 });
//         const formData = try r.formData();
//         try t.expectString("test", formData.get("name").?);
//         try t.expectString("test", formData.get("name").?);
//     }

//     {
//         // multiple inputs
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 25\r\n\r\nname=test1&password=test2", .{ .max_form_count = 2 });

//         const formData = try r.formData();
//         try t.expectString("test1", formData.get("name").?);
//         try t.expectString("test1", formData.get("name").?);

//         try t.expectString("test2", formData.get("password").?);
//         try t.expectString("test2", formData.get("password").?);
//     }

//     {
//         // test decoding
//         var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 44\r\n\r\ntest=%21%40%23%24%25%5E%26*%29%28-%3D%2B%7C+", .{ .max_form_count = 2 });

//         const formData = try r.formData();
//         try t.expectString("!@#$%^&*)(-=+| ", formData.get("test").?);
//         try t.expectString("!@#$%^&*)(-=+| ", formData.get("test").?);
//     }
// }

// test "body: multiFormData valid" {
//     defer t.reset();

//     {
//         // no body
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=BX1" }, &.{}), .{ .max_multiform_count = 5 });
//         const formData = try r.multiFormData();
//         try t.expectEqual(0, formData.len);
//         try t.expectString("multipart/form-data; boundary=BX1", r.header("content-type").?);
//     }

//     {
//         // parses single field
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=-90x" }, &.{ "---90x\r\n", "Content-Disposition: form-data; name=\"description\"\r\n\r\n", "the-desc\r\n", "---90x--\r\n" }), .{ .max_multiform_count = 5 });

//         const formData = try r.multiFormData();
//         try t.expectString("the-desc", formData.get("description").?.value);
//         try t.expectString("the-desc", formData.get("description").?.value);
//     }

//     {
//         // parses single field with filename
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=-90x" }, &.{ "---90x\r\n", "Content-Disposition: form-data; filename=\"file1.zig\"; name=file\r\n\r\n", "some binary data\r\n", "---90x--\r\n" }), .{ .max_multiform_count = 5 });

//         const formData = try r.multiFormData();
//         const field = formData.get("file").?;
//         try t.expectString("some binary data", field.value);
//         try t.expectString("file1.zig", field.filename.?);
//     }

//     {
//         // quoted boundary
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=\"-90x\"" }, &.{ "---90x\r\n", "Content-Disposition: form-data; name=\"description\"\r\n\r\n", "the-desc\r\n", "---90x--\r\n" }), .{ .max_multiform_count = 5 });

//         const formData = try r.multiFormData();
//         const field = formData.get("description").?;
//         try t.expectEqual(null, field.filename);
//         try t.expectString("the-desc", field.value);
//     }

//     {
//         // multiple fields
//         var r = try testParse(buildRequest(&.{ "GET /something HTTP/1.1", "Content-Type: multipart/form-data; boundary=----99900AB" }, &.{ "------99900AB\r\n", "content-type: text/plain; charset=utf-8\r\n", "content-disposition: form-data; name=\"fie\\\" \\?l\\d\"\r\n\r\n", "Value - 1\r\n", "------99900AB\r\n", "Content-Disposition: form-data; filename=another.zip; name=field2\r\n\r\n", "Value - 2\r\n", "------99900AB--\r\n" }), .{ .max_multiform_count = 5 });

//         const formData = try r.multiFormData();
//         try t.expectEqual(2, formData.len);

//         const field1 = formData.get("fie\" ?l\\d").?;
//         try t.expectEqual(null, field1.filename);
//         try t.expectString("Value - 1", field1.value);

//         const field2 = formData.get("field2").?;
//         try t.expectString("Value - 2", field2.value);
//         try t.expectString("another.zip", field2.filename.?);
//     }

//     {
//         // enforce limit
//         var r = try testParse(buildRequest(&.{ "GET /something HTTP/1.1", "Content-Type: multipart/form-data; boundary=----99900AB" }, &.{ "------99900AB\r\n", "Content-Type: text/plain; charset=utf-8\r\n", "Content-Disposition: form-data; name=\"fie\\\" \\?l\\d\"\r\n\r\n", "Value - 1\r\n", "------99900AB\r\n", "Content-Disposition: form-data; filename=another; name=field2\r\n\r\n", "Value - 2\r\n", "------99900AB--\r\n" }), .{ .max_multiform_count = 1 });

//         defer t.reset();
//         const formData = try r.multiFormData();
//         try t.expectEqual(1, formData.len);
//         try t.expectString("Value - 1", formData.get("fie\" ?l\\d").?.value);
//     }
// }

// test "body: multiFormData invalid" {
//     defer t.reset();
//     {
//         // large boundary
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=12345678901234567890123456789012345678901234567890123456789012345678901" }, &.{"garbage"}), .{});
//         try t.expectError(error.InvalidMultiPartFormDataHeader, r.multiFormData());
//     }

//     {
//         // no closing quote
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=\"123" }, &.{"garbage"}), .{});
//         try t.expectError(error.InvalidMultiPartFormDataHeader, r.multiFormData());
//     }

//     {
//         // no content-dispotion field header
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=-90x" }, &.{ "---90x\r\n", "the-desc\r\n", "---90x--\r\n" }), .{ .max_multiform_count = 5 });
//         try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
//     }

//     {
//         // no content dispotion naem
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=-90x" }, &.{ "---90x\r\n", "Content-Disposition: form-data; x=a", "the-desc\r\n", "---90x--\r\n" }), .{ .max_multiform_count = 5 });
//         try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
//     }

//     {
//         // missing name end quote
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=-90x" }, &.{ "---90x\r\n", "Content-Disposition: form-data; name=\"hello\r\n\r\n", "the-desc\r\n", "---90x--\r\n" }), .{ .max_multiform_count = 5 });
//         try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
//     }

//     {
//         // missing missing newline
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=-90x" }, &.{ "---90x\r\n", "Content-Disposition: form-data; name=hello\r\n", "the-desc\r\n", "---90x--\r\n" }), .{ .max_multiform_count = 5 });
//         try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
//     }

//     {
//         // missing missing newline x2
//         var r = try testParse(buildRequest(&.{ "POST / HTTP/1.0", "Content-Type: multipart/form-data; boundary=-90x" }, &.{ "---90x\r\n", "Content-Disposition: form-data; name=hello", "the-desc\r\n", "---90x--\r\n" }), .{ .max_multiform_count = 5 });
//         try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
//     }
// }

// test "request: fuzz" {
//     // We have a bunch of data to allocate for testing, like header names and
//     // values. Easier to use this arena and reset it after each test run.
//     const aa = t.arena.allocator();
//     defer t.reset();

//     var r = t.getRandom();
//     const random = r.random();
//     for (0..1000) |_| {
//         // important to test with different buffer sizes, since there's a lot of
//         // special handling for different cases (e.g the buffer is full and has
//         // some of the body in it, so we need to copy that to a dynamically allocated
//         // buffer)
//         const buffer_size = random.uintAtMost(u16, 1024) + 1024;

//         var ctx = t.Context.init(.{
//             .request = .{ .buffer_size = buffer_size },
//         });

//         // enable fake mode, we don't go through a real socket, instead we go
//         // through a fake one, that can simulate having data spread across multiple
//         // calls to read()
//         ctx.fake = true;
//         defer ctx.deinit();

//         // how many requests should we make on this 1 individual socket (simulating
//         // keepalive AND the request pool)
//         const number_of_requests = random.uintAtMost(u8, 10) + 1;

//         for (0..number_of_requests) |_| {
//             defer ctx.conn.requestDone(4096, true) catch unreachable;
//             const method = randomMethod(random);
//             const url = t.randomString(random, aa, 20);

//             ctx.write(method);
//             ctx.write(" /");
//             ctx.write(url);

//             const number_of_qs = random.uintAtMost(u8, 4);
//             if (number_of_qs != 0) {
//                 ctx.write("?");
//             }

//             var query = std.StringHashMap([]const u8).init(aa);
//             for (0..number_of_qs) |_| {
//                 const key = t.randomString(random, aa, 20);
//                 const value = t.randomString(random, aa, 20);
//                 if (!query.contains(key)) {
//                     // TODO: figure out how we want to handle duplicate query values
//                     // (the spec doesn't specify what to do)
//                     query.put(key, value) catch unreachable;
//                     ctx.write(key);
//                     ctx.write("=");
//                     ctx.write(value);
//                     ctx.write("&");
//                 }
//             }

//             ctx.write(" HTTP/1.1\r\n");

//             var headers = std.StringHashMap([]const u8).init(aa);
//             for (0..random.uintAtMost(u8, 4)) |_| {
//                 const name = t.randomString(random, aa, 20);
//                 const value = t.randomString(random, aa, 20);
//                 if (!headers.contains(name)) {
//                     // TODO: figure out how we want to handle duplicate query values
//                     // Note, the spec says we should merge these!
//                     headers.put(name, value) catch unreachable;
//                     ctx.write(name);
//                     ctx.write(": ");
//                     ctx.write(value);
//                     ctx.write("\r\n");
//                 }
//             }

//             var body: ?[]u8 = null;
//             if (random.uintAtMost(u8, 4) == 0) {
//                 ctx.write("\r\n"); // no body
//             } else {
//                 body = t.randomString(random, aa, 8000);
//                 const cl = std.fmt.allocPrint(aa, "{d}", .{body.?.len}) catch unreachable;
//                 headers.put("content-length", cl) catch unreachable;
//                 ctx.write("content-length: ");
//                 ctx.write(cl);
//                 ctx.write("\r\n\r\n");
//                 ctx.write(body.?);
//             }

//             var conn = ctx.conn;
//             var fake_reader = ctx.fakeReader();
//             while (true) {
//                 const done = try conn.req_state.parse(conn.req_arena.allocator(), &fake_reader);
//                 if (done) break;
//             }

//             var request = Request.init(conn.req_arena.allocator(), conn);

//             // assert the headers
//             var it = headers.iterator();
//             while (it.next()) |entry| {
//                 try t.expectString(entry.value_ptr.*, request.header(entry.key_ptr.*).?);
//             }

//             // assert the querystring
//             var actualQuery = request.query() catch unreachable;
//             it = query.iterator();
//             while (it.next()) |entry| {
//                 try t.expectString(entry.value_ptr.*, actualQuery.get(entry.key_ptr.*).?);
//             }

//             const actual_body = request.body();
//             if (body) |b| {
//                 try t.expectString(b, actual_body.?);
//             } else {
//                 try t.expectEqual(null, actual_body);
//             }
//         }
//     }
// }

// test "request: cookie" {
//     defer t.reset();
//     {
//         const r = try testParse("PUT / HTTP/1.0\r\n\r\n", .{});
//         const cookies = r.cookies();
//         try t.expectEqual(null, cookies.get(""));
//         try t.expectEqual(null, cookies.get("auth"));
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.0\r\nCookie: \r\n\r\n", .{});
//         const cookies = r.cookies();
//         try t.expectEqual(null, cookies.get(""));
//         try t.expectEqual(null, cookies.get("auth"));
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.0\r\nCookie: auth=hello\r\n\r\n", .{});
//         const cookies = r.cookies();
//         try t.expectEqual(null, cookies.get(""));
//         try t.expectString("hello", cookies.get("auth").?);
//         try t.expectEqual(null, cookies.get("world"));
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.0\r\nCookie: Name=leto; power=9000\r\n\r\n", .{});
//         const cookies = r.cookies();
//         try t.expectEqual(null, cookies.get(""));
//         try t.expectEqual(null, cookies.get("name"));
//         try t.expectString("leto", cookies.get("Name").?);
//         try t.expectString("9000", cookies.get("power").?);
//     }

//     {
//         const r = try testParse("PUT / HTTP/1.0\r\nCookie: Name=Ghanima;id=Name\r\n\r\n", .{});
//         const cookies = r.cookies();
//         try t.expectEqual(null, cookies.get(""));
//         try t.expectEqual(null, cookies.get("name"));
//         try t.expectString("Ghanima", cookies.get("Name").?);
//         try t.expectString("Name", cookies.get("id").?);
//     }
// }

// fn testParse(input: []const u8, config: Config) !Request {
//     var ctx = t.Context.allocInit(t.arena.allocator(), .{ .request = config });
//     ctx.write(input);
//     while (true) {
//         const done = try ctx.conn.req_state.parse(ctx.conn.req_arena.allocator(), ctx.stream);
//         if (done) break;
//     }
//     return Request.init(ctx.conn.req_arena.allocator(), ctx.conn);
// }

// fn expectParseError(expected: anyerror, input: []const u8, config: Config) !void {
//     var ctx = t.Context.init(.{ .request = config });
//     defer ctx.deinit();

//     ctx.write(input);
//     try t.expectError(expected, ctx.conn.req_state.parse(ctx.conn.req_arena.allocator(), ctx.stream));
// }

// fn randomMethod(random: std.Random) []const u8 {
//     return switch (random.uintAtMost(usize, 6)) {
//         0 => "GET",
//         1 => "PUT",
//         2 => "POST",
//         3 => "PATCH",
//         4 => "DELETE",
//         5 => "OPTIONS",
//         6 => "HEAD",
//         else => unreachable,
//     };
// }

// fn buildRequest(header: []const []const u8, body: []const []const u8) []const u8 {
//     var header_len: usize = 0;
//     for (header) |h| {
//         header_len += h.len;
//     }

//     var body_len: usize = 0;
//     for (body) |b| {
//         body_len += b.len;
//     }

//     var arr = std.ArrayList(u8).init(t.arena.allocator());
//     // 100 for the Content-Length that we'll add and all the \r\n
//     arr.ensureTotalCapacity(header_len + body_len + 100) catch unreachable;

//     for (header) |h| {
//         arr.appendSlice(h) catch unreachable;
//         arr.appendSlice("\r\n") catch unreachable;
//     }
//     arr.appendSlice("Content-Length: ") catch unreachable;
//     std.fmt.formatInt(body_len, 10, .lower, .{}, arr.writer()) catch unreachable;
//     arr.appendSlice("\r\n\r\n") catch unreachable;

//     for (body) |b| {
//         arr.appendSlice(b) catch unreachable;
//     }

//     return arr.items;
// }
