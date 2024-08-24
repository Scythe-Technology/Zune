const std = @import("std");
const luau = @import("luau");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const Parser = @import("../../utils/parser.zig");

const json = @import("json.zig");

const Luau = luau.Luau;

const Error = error{
    InvalidJSON,
    InvalidNumber,
    InvalidString,
    InvalidLiteral,
    InvalidArray,
    InvalidObject,
    CircularReference,
    InvalidKey,
    InvalidValue,
    TableSizeMismatch,
    UnsupportedType,
    TrailingData,
};

const charset = "0123456789abcdef";
fn escape_string(bytes: *std.ArrayList(u8), str: []const u8) !void {
    errdefer bytes.deinit();
    try bytes.append('"');
    for (str) |c| switch (c) {
        0...31, '"', '\\' => {
            switch (c) {
                8 => try bytes.appendSlice("\\b"),
                '\t' => try bytes.appendSlice("\\t"),
                '\n' => try bytes.appendSlice("\\n"),
                12 => try bytes.appendSlice("\\f"),
                '\r' => try bytes.appendSlice("\\r"),
                '"', '\\' => {
                    try bytes.append('\\');
                    try bytes.append(c);
                },
                else => {
                    try bytes.appendSlice("\\u00");
                    try bytes.append(charset[c >> 4]);
                    try bytes.append(charset[c & 15]);
                },
            }
        },
        else => try bytes.append(c),
    };
    try bytes.append('"');
}

fn encode(L: *Luau, allocator: std.mem.Allocator, buf: *std.ArrayList(u8), tracked: *std.ArrayList(*const anyopaque)) !void {
    switch (L.typeOf(-1)) {
        .nil => try buf.appendSlice("null"),
        .table => {
            const tablePtr = try L.toPointer(-1);

            for (tracked.items) |t| if (t == tablePtr) return Error.CircularReference;
            try tracked.append(tablePtr);

            const tableSize = L.objLen(-1);
            L.pushNil();
            const nextKey = L.next(-2);
            if (tableSize > 0 or !nextKey) {
                try buf.append('[');
                if (nextKey) {
                    if (L.typeOf(-2) != .number) return Error.InvalidKey;
                    try encode(L, allocator, buf, tracked);
                    L.pop(1); // drop: value
                    var n: i32 = 1;
                    while (L.next(-2)) {
                        try buf.append(',');
                        if (L.typeOf(-2) != .number) return Error.InvalidKey;
                        try encode(L, allocator, buf, tracked);
                        L.pop(1); // drop: value
                        n += 1;
                    }
                    if (n != tableSize) return Error.TableSizeMismatch;
                }
                try buf.append(']');
            } else {
                try buf.appendSlice("{");
                if (L.typeOf(-2) != .string) return Error.InvalidKey;
                L.pushValue(-2); // push key
                try encode(L, allocator, buf, tracked);
                try buf.append(':');
                L.pop(1); // drop: key
                try encode(L, allocator, buf, tracked);
                L.pop(1); // drop: value
                while (L.next(-2)) {
                    try buf.append(',');
                    if (L.typeOf(-2) != .string) return Error.InvalidKey;
                    L.pushValue(-2); // push key [copy]
                    try encode(L, allocator, buf, tracked);
                    try buf.append(':');
                    L.pop(1); // drop: key [copy]
                    try encode(L, allocator, buf, tracked);
                    L.pop(1); // drop: value
                }
                try buf.append('}');
            }
        },
        .number => {
            const num = L.checkNumber(-1);
            if (std.math.isNan(num) or std.math.isInf(num)) return Error.InvalidNumber;
            const str = try L.toString(-1);
            try buf.appendSlice(str);
        },
        .string => {
            const str = try L.toString(-1);
            try escape_string(buf, str);
        },
        .boolean => if (L.toBoolean(-1)) try buf.appendSlice("true") else try buf.appendSlice("false"),
        else => return Error.UnsupportedType,
    }
}

const WHITESPACE_LINE = [_]u8{ 32, '\t', '\r', '\n' };
const DELIMITER = [_]u8{ 32, '\t', '\r', '\n', '}', ']', ',' };

fn decode(L: *Luau, string: []const u8) !usize {
    var pos = Parser.nextNonCharacter(string, &WHITESPACE_LINE);
    switch (string[pos]) {
        '"' => {
            var buf = std.ArrayList(u8).init(L.allocator());
            defer buf.deinit();
            const string_slice = string[pos..];
            var end: usize = 1;
            try buf.ensureUnusedCapacity(string_slice.len);
            const eof = comp: {
                while (end < string_slice.len) {
                    const c = string_slice[end];
                    if (c == '\\') {
                        end += 1;
                        if (end >= string_slice.len) return Error.InvalidString;
                        if (string_slice[end] == 'u') {
                            end += 1;
                            if (end + 4 > string_slice.len) return Error.InvalidString;
                            var b: [4]u8 = undefined;
                            const bytes = try std.fmt.hexToBytes(&b, string_slice[end .. end + 4]);
                            const trimmed = b: {
                                for (bytes, 0..) |byte, p| if (byte != 0) break :b bytes[p..];
                                break :b bytes[bytes.len - 1 ..];
                            };
                            try buf.appendSlice(trimmed);
                            end += 4;
                        } else {
                            switch (string_slice[end]) {
                                'b' => try buf.append(8),
                                't' => try buf.append(9),
                                'n' => try buf.append(10),
                                'f' => try buf.append(12),
                                'r' => try buf.append(13),
                                '"' => try buf.append('"'),
                                '\\' => try buf.append('\\'),
                                else => return Error.InvalidString,
                            }
                            end += 1;
                        }
                        continue;
                    } else if (c < 32) return Error.InvalidString;
                    end += 1;
                    if (c == '"') break :comp true;
                    try buf.append(c);
                }
                break :comp false;
            };
            if (!eof) return Error.InvalidString;
            if (string_slice[end - 1] != '"') return Error.InvalidString else if (end < 2) {
                L.pushLString("");
                return pos + end;
            }
            L.pushLString(buf.items);
            return pos + end;
        },
        '0'...'9', '-' => {
            const slice = string[pos..];
            const end = Parser.nextCharacter(slice, &DELIMITER);
            const num = try std.fmt.parseFloat(f64, slice[0..end]);
            L.pushNumber(num);
            return pos + end;
        },
        't', 'f', 'n' => |code| {
            const slice = string[pos..];
            if (slice.len < 4) return Error.InvalidLiteral;
            switch (code) {
                't' => if (std.mem.eql(u8, slice[0..4], "true")) {
                    L.pushBoolean(true);
                    return pos + 4;
                } else return Error.InvalidLiteral,
                'f' => if (slice.len > 4 and std.mem.eql(u8, slice[0..5], "false")) {
                    L.pushBoolean(false);
                    return pos + 5;
                } else return Error.InvalidLiteral,
                'n' => if (std.mem.eql(u8, slice[0..4], "null")) {
                    L.pushNil();
                    return pos + 4;
                } else return Error.InvalidLiteral,
                else => return Error.InvalidLiteral,
            }
        },
        '[' => {
            L.newTable();
            var count: i32 = 1;
            pos += 1;
            while (true) {
                pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE_LINE);
                if (pos >= string.len) return Error.InvalidObject;
                if (string[pos] == ']') return pos + 1;
                pos += try decode(L, string[pos..]);
                L.rawSetIndex(-2, count);
                count += 1;
                pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE_LINE);
                if (pos >= string.len) return Error.InvalidObject;
                if (string[pos] == ']') return pos + 1;
                if (string[pos] != ',') return Error.InvalidArray;
                pos += 1;
            }
        },
        '{' => {
            L.newTable();
            pos += 1;
            while (true) {
                pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE_LINE);
                if (pos >= string.len) return Error.InvalidObject;
                if (string[pos] == '}') return pos + 1;
                if (string[pos] != '"') return Error.InvalidObject;
                pos += try decode(L, string[pos..]);
                pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE_LINE);
                if (pos >= string.len) return Error.InvalidObject;
                if (string[pos] != ':') return Error.InvalidObject;
                pos += 1;
                pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE_LINE);
                pos += try decode(L, string[pos..]);
                L.setTable(-3);
                pos += Parser.nextNonCharacter(string[pos..], &WHITESPACE_LINE);
                if (pos >= string.len) return Error.InvalidObject;
                if (string[pos] == '}') return pos + 1;
                if (string[pos] != ',') return Error.InvalidObject;
                pos += 1;
            }
        },
        else => return Error.InvalidJSON,
    }
    return 0;
}

pub fn lua_encode(L: *Luau) i32 {
    const allocator = L.allocator();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var tracked = std.ArrayList(*const anyopaque).init(allocator);
    defer tracked.deinit();

    encode(L, allocator, &buf, &tracked) catch |err| {
        buf.deinit();
        tracked.deinit();
        switch (err) {
            Error.InvalidNumber => L.raiseErrorStr("InvalidNumber (Cannot be inf or nan)", .{}),
            Error.UnsupportedType => L.raiseErrorStr("Unsupported type %s", .{@tagName(L.typeOf(-1)).ptr}),
            else => L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        }
    };
    L.pushLString(buf.items);
    return 1;
}

pub fn lua_decode(L: *Luau) i32 {
    const string = L.checkString(1);
    if (string.len == 0) {
        L.pushNil();
        return 1;
    }

    var pos: usize = 0;
    pos += decode(L, string) catch |err| switch (err) {
        Error.InvalidNumber => L.raiseErrorStr("InvalidNumber (Cannot be inf or nan)", .{}),
        Error.UnsupportedType => L.raiseErrorStr("Unsupported type %s", .{@tagName(L.typeOf(-1)).ptr}),
        else => L.raiseErrorStr("%s", .{@errorName(err).ptr}),
    };

    if (string.len != pos + Parser.nextNonCharacter(string[pos..], &WHITESPACE_LINE)) L.raiseErrorStr("TrailingData", .{});
    return 1;
}

test "Escaped Strings" {
    for (0..256) |i| {
        const c: u8 = @intCast(i);

        var buf = std.ArrayList(u8).init(std.testing.allocator);
        defer buf.deinit();

        try escape_string(&buf, &[1]u8{c});

        const res = buf.items;

        switch (c) {
            8 => try std.testing.expectEqualSlices(u8, "\"\\b\"", res),
            9 => try std.testing.expectEqualSlices(u8, "\"\\t\"", res),
            10 => try std.testing.expectEqualSlices(u8, "\"\\n\"", res),
            12 => try std.testing.expectEqualSlices(u8, "\"\\f\"", res),
            13 => try std.testing.expectEqualSlices(u8, "\"\\r\"", res),
            '"' => try std.testing.expectEqualSlices(u8, "\"\\\"\"", res),
            '\\' => try std.testing.expectEqualSlices(u8, "\"\\\\\"", res),
            0...7, 11, 14...31 => try std.testing.expectEqualSlices(u8, &[_]u8{ '"', '\\', 'u', '0', '0', charset[c >> 4], charset[c & 15], '"' }, res),
            else => try std.testing.expectEqualSlices(u8, &[_]u8{ '"', c, '"' }, res),
        }
    }
}
