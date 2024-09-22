const std = @import("std");
const luau = @import("luau");
const json = @import("json");

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

fn decodeArray(L: *Luau, array: *std.ArrayList(json.JsonValue)) !void {
    L.newTable();

    for (array.items, 0..) |item, i| {
        try decodeValue(L, item);
        L.rawSetIndex(-2, @intCast(i + 1));
    }
}

fn decodeObject(L: *Luau, object: *std.StringArrayHashMap(json.JsonValue)) !void {
    L.newTable();

    var iter = object.iterator();
    while (iter.next()) |entry| {
        L.pushLString(entry.key_ptr.*);
        try decodeValue(L, entry.value_ptr.*);
        L.setTable(-3);
    }
}

fn decodeValue(L: *Luau, jsonValue: json.JsonValue) anyerror!void {
    switch (jsonValue) {
        .nil => L.pushNil(),
        .boolean => |boolean| L.pushBoolean(boolean),
        .integer => |integer| L.pushInteger(@intCast(integer)),
        .float => |float| L.pushNumber(float),
        .string, .static_string => |string| L.pushLString(string),
        .object => |object| try decodeObject(L, object),
        .array => |array| try decodeArray(L, array),
    }
}

pub fn lua_decode(L: *Luau) !i32 {
    const string = L.checkString(1);
    if (string.len == 0) {
        L.pushNil();
        return 1;
    }

    const allocator = L.allocator();

    var root = try json.parse(allocator, string);
    defer root.deinit();

    try decodeValue(L, root.value);

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
