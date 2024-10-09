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

var NULL_PTR: ?*const anyopaque = null;

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

fn writeIndent(buf: *std.ArrayList(u8), kind: json.JsonIndent, depth: u32) !void {
    const indent = switch (kind) {
        .NO_LINE => return,
        .SPACES_2 => "  ",
        .SPACES_4 => "    ",
        .TABS => "\t",
    };
    for (0..depth) |_| {
        try buf.appendSlice(indent);
    }
}

fn encode(
    L: *Luau,
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    tracked: *std.ArrayList(*const anyopaque),
    kind: json.JsonIndent,
    depth: u32,
) !void {
    switch (L.typeOf(-1)) {
        .nil => try buf.appendSlice("null"),
        .table => {
            const tablePtr = try L.toPointer(-1);

            if (NULL_PTR) |ptr| if (tablePtr == ptr) {
                try buf.appendSlice("null");
                return;
            };

            for (tracked.items) |t| if (t == tablePtr) return Error.CircularReference;
            try tracked.append(tablePtr);

            const tableSize = L.objLen(-1);
            L.pushNil();
            const nextKey = L.next(-2);
            if (tableSize > 0 or !nextKey) {
                try buf.append('[');
                if (nextKey) {
                    if (L.typeOf(-2) != .number)
                        return Error.InvalidKey;
                    try encode(L, allocator, buf, tracked, kind, depth + 1);
                    L.pop(1); // drop: value
                    var n: i32 = 1;
                    while (L.next(-2)) {
                        try buf.append(',');
                        if (kind != .NO_LINE)
                            try buf.append(' ');

                        if (L.typeOf(-2) != .number)
                            return Error.InvalidKey;

                        try encode(L, allocator, buf, tracked, kind, depth + 1);
                        L.pop(1); // drop: value
                        n += 1;
                    }
                    if (n != tableSize)
                        return Error.TableSizeMismatch;
                }
                try buf.append(']');
            } else {
                try buf.appendSlice("{");
                if (L.typeOf(-2) != .string)
                    return Error.InvalidKey;

                if (kind != .NO_LINE)
                    try buf.append('\n');
                try writeIndent(buf, kind, depth + 1);

                L.pushValue(-2); // push key
                try encode(L, allocator, buf, tracked, kind, depth + 1);
                try buf.append(':');
                if (kind != .NO_LINE)
                    try buf.append(' ');
                L.pop(1); // drop: key
                try encode(L, allocator, buf, tracked, kind, depth + 1);
                L.pop(1); // drop: value

                while (L.next(-2)) {
                    try buf.append(',');
                    if (L.typeOf(-2) != .string)
                        return Error.InvalidKey;

                    if (kind != .NO_LINE)
                        try buf.append('\n');
                    try writeIndent(buf, kind, depth + 1);

                    L.pushValue(-2); // push key [copy]
                    try encode(L, allocator, buf, tracked, kind, depth + 1);
                    try buf.append(':');
                    if (kind != .NO_LINE)
                        try buf.append(' ');
                    L.pop(1); // drop: key [copy]
                    try encode(L, allocator, buf, tracked, kind, depth + 1);
                    L.pop(1); // drop: value
                }

                if (kind != .NO_LINE)
                    try buf.append('\n');
                try writeIndent(buf, kind, depth);

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
        .boolean => if (L.toBoolean(-1))
            try buf.appendSlice("true")
        else
            try buf.appendSlice("false"),
        else => return Error.UnsupportedType,
    }
}

pub fn lua_encode(L: *Luau) i32 {
    const allocator = L.allocator();

    var kind = json.JsonIndent.NO_LINE;

    const config_type = L.typeOf(2);
    if (!luau.isNoneOrNil(config_type)) {
        L.checkType(2, .table);
        const indent_type = L.getField(2, "prettyIndent");
        if (!luau.isNoneOrNil(indent_type)) {
            L.checkType(-1, .number);
            kind = switch (L.toInteger(-1) catch unreachable) {
                0 => json.JsonIndent.NO_LINE,
                1 => json.JsonIndent.SPACES_2,
                2 => json.JsonIndent.SPACES_4,
                3 => json.JsonIndent.TABS,
                else => |n| L.raiseErrorStr("Unsupported indent kind %d", .{n}),
            };
        }
        L.pop(1);
    }

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var tracked = std.ArrayList(*const anyopaque).init(allocator);
    defer tracked.deinit();

    L.pushValue(1);
    encode(L, allocator, &buf, &tracked, kind, 0) catch |err| {
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

fn decodeArray(L: *Luau, array: *std.ArrayList(json.JsonValue), preserve_null: bool) !void {
    L.newTable();

    for (array.items, 1..) |item, i| {
        try decodeValue(L, item, preserve_null);
        L.rawSetIndex(-2, @intCast(i));
    }
}

fn decodeObject(L: *Luau, object: *std.StringArrayHashMap(json.JsonValue), preserve_null: bool) !void {
    L.newTable();

    var iter = object.iterator();
    while (iter.next()) |entry| {
        L.pushLString(entry.key_ptr.*);
        try decodeValue(L, entry.value_ptr.*, preserve_null);
        L.setTable(-3);
    }
}

fn decodeValue(L: *Luau, jsonValue: json.JsonValue, preserve_null: bool) anyerror!void {
    switch (jsonValue) {
        .nil => if (preserve_null) {
            _ = L.getField(luau.REGISTRYINDEX, "_SERDE_JSON_NULL");
        } else L.pushNil(),
        .boolean => |boolean| L.pushBoolean(boolean),
        .integer => |integer| L.pushInteger(@intCast(integer)),
        .float => |float| L.pushNumber(float),
        .string, .static_string => |string| L.pushLString(string),
        .object => |object| try decodeObject(L, object, preserve_null),
        .array => |array| try decodeArray(L, array, preserve_null),
    }
}

pub fn lua_decode(L: *Luau) !i32 {
    const string = L.checkString(1);
    if (string.len == 0) {
        L.pushNil();
        return 1;
    }

    var preserve_null = false;

    const config_type = L.typeOf(2);
    if (!luau.isNoneOrNil(config_type)) {
        L.checkType(2, .table);
        const preserve_null_type = L.getField(2, "preserveNull");
        if (!luau.isNoneOrNil(preserve_null_type)) {
            L.checkType(-1, .boolean);
            preserve_null = L.toBoolean(-1);
        }
        L.pop(1);
    }

    const allocator = L.allocator();

    var root = try json.parse(allocator, string);
    defer root.deinit();

    try decodeValue(L, root.value, preserve_null);

    return 1;
}

pub fn lua_decode5(L: *Luau) !i32 {
    const string = L.checkString(1);
    if (string.len == 0) {
        L.pushNil();
        return 1;
    }

    var preserve_null = false;

    const config_type = L.typeOf(2);
    if (!luau.isNoneOrNil(config_type)) {
        L.checkType(2, .table);
        const preserve_null_type = L.getField(2, "preserveNull");
        if (!luau.isNoneOrNil(preserve_null_type)) {
            L.checkType(-1, .boolean);
            preserve_null = L.toBoolean(-1);
        }
        L.pop(1);
    }

    const allocator = L.allocator();

    var root = try json.parseJson5(allocator, string);
    defer root.deinit();

    try decodeValue(L, root.value, preserve_null);

    return 1;
}

pub fn lua_setprops(L: *Luau) void {
    L.newTable();

    L.newTable();

    { // JsonNull Metatable
        L.newTable();

        L.setFieldFn(-1, luau.Metamethods.tostring, struct {
            fn inner(l: *Luau) i32 {
                l.pushString("JsonValue.Null");
                return 1;
            }
        }.inner);

        L.setMetatable(-2);
    }

    L.setReadOnly(-1, true);

    L.pushValue(-1);
    L.setField(luau.REGISTRYINDEX, "_SERDE_JSON_NULL");
    NULL_PTR = L.toPointer(-1) catch unreachable;

    L.setField(-2, "Null");
    L.setField(-2, "Values");

    L.newTable();
    L.setFieldInteger(-1, "None", 0);
    L.setFieldInteger(-1, "TwoSpaces", 1);
    L.setFieldInteger(-1, "FourSpaces", 2);
    L.setFieldInteger(-1, "Tabs", 3);
    L.setField(-2, "Indents");
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
