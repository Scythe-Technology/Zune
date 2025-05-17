const std = @import("std");
const luau = @import("luau");
const json = @import("json");

const VM = luau.VM;

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

const JsonKind = enum {
    JSON,
    JSON5,
};

fn encode(
    L: *VM.lua.State,
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    tracked: *std.ArrayList(*const anyopaque),
    kind: json.JsonIndent,
    depth: u32,
    comptime json_kind: JsonKind,
) !void {
    switch (L.typeOf(-1)) {
        .Nil => try buf.appendSlice("null"),
        .Table => {
            const tablePtr = L.topointer(-1) orelse return error.Failed;

            if (NULL_PTR) |ptr| if (tablePtr == ptr) {
                try buf.appendSlice("null");
                return;
            };

            for (tracked.items) |t|
                if (t == tablePtr) return Error.CircularReference;
            try tracked.append(tablePtr);

            const tableSize = L.objlen(-1);
            L.pushnil();
            const nextKey = L.next(-2);
            if (tableSize > 0 or !nextKey) {
                try buf.append('[');
                if (nextKey) {
                    if (L.typeOf(-2) != .Number)
                        return Error.InvalidKey;
                    try encode(L, allocator, buf, tracked, kind, depth + 1, json_kind);
                    L.pop(1); // drop: value
                    var n: i32 = 1;
                    while (L.next(-2)) {
                        try buf.append(',');
                        if (kind != .NO_LINE)
                            try buf.append(' ');

                        if (L.typeOf(-2) != .Number)
                            return Error.InvalidKey;

                        try encode(L, allocator, buf, tracked, kind, depth + 1, json_kind);
                        L.pop(1); // drop: value
                        n += 1;
                    }
                    if (n != tableSize)
                        return Error.TableSizeMismatch;
                }
                try buf.append(']');
            } else {
                try buf.appendSlice("{");
                if (L.typeOf(-2) != .String)
                    return Error.InvalidKey;

                if (kind != .NO_LINE)
                    try buf.append('\n');
                try writeIndent(buf, kind, depth + 1);

                L.pushvalue(-2); // push key
                try encode(L, allocator, buf, tracked, kind, depth + 1, json_kind);
                try buf.append(':');
                if (kind != .NO_LINE)
                    try buf.append(' ');
                L.pop(1); // drop: key
                try encode(L, allocator, buf, tracked, kind, depth + 1, json_kind);
                L.pop(1); // drop: value

                while (L.next(-2)) {
                    try buf.append(',');
                    if (L.typeOf(-2) != .String)
                        return Error.InvalidKey;

                    if (kind != .NO_LINE)
                        try buf.append('\n');
                    try writeIndent(buf, kind, depth + 1);

                    L.pushvalue(-2); // push key [copy]
                    try encode(L, allocator, buf, tracked, kind, depth + 1, json_kind);
                    try buf.append(':');
                    if (kind != .NO_LINE)
                        try buf.append(' ');
                    L.pop(1); // drop: key [copy]
                    try encode(L, allocator, buf, tracked, kind, depth + 1, json_kind);
                    L.pop(1); // drop: value
                }

                if (kind != .NO_LINE)
                    try buf.append('\n');
                try writeIndent(buf, kind, depth);

                try buf.append('}');
            }
        },
        .Number => {
            const num = L.Lchecknumber(-1);
            switch (json_kind) {
                .JSON => if (std.math.isNan(num) or std.math.isInf(num)) return Error.InvalidNumber,
                .JSON5 => if (std.math.isInf(num)) {
                    if (num > 0)
                        try buf.appendSlice("Infinity")
                    else
                        try buf.appendSlice("-Infinity");
                    return;
                } else if (std.math.isNan(num)) {
                    try buf.appendSlice("NaN");
                    return;
                },
            }

            const str = L.tostring(-1) orelse return error.Fail;
            try buf.appendSlice(str);
        },
        .String => {
            const str = L.tostring(-1) orelse return error.Fail;
            try escape_string(buf, str);
        },
        .Boolean => if (L.toboolean(-1))
            try buf.appendSlice("true")
        else
            try buf.appendSlice("false"),
        else => return Error.UnsupportedType,
    }
}

pub fn LuaEncoder(comptime json_kind: JsonKind) fn (L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn inner(L: *VM.lua.State) anyerror!i32 {
            const allocator = luau.getallocator(L);

            var kind = json.JsonIndent.NO_LINE;

            const config_type = L.typeOf(2);
            if (!config_type.isnoneornil()) {
                try L.Zchecktype(2, .Table);
                const indent_type = L.getfield(2, "prettyIndent");
                if (!indent_type.isnoneornil()) {
                    try L.Zchecktype(-1, .Number);
                    kind = switch (L.tointeger(-1) orelse unreachable) {
                        0 => json.JsonIndent.NO_LINE,
                        1 => json.JsonIndent.SPACES_2,
                        2 => json.JsonIndent.SPACES_4,
                        3 => json.JsonIndent.TABS,
                        else => |n| return L.Zerrorf("Unsupported indent kind {d}", .{n}),
                    };
                }
                L.pop(1);
            }

            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();

            var tracked = std.ArrayList(*const anyopaque).init(allocator);
            defer tracked.deinit();

            L.pushvalue(1);
            encode(L, allocator, &buf, &tracked, kind, 0, json_kind) catch |err| {
                switch (err) {
                    Error.InvalidNumber => return L.Zerror("InvalidNumber (Cannot be inf or nan)"),
                    Error.UnsupportedType => return L.Zerrorf("Unsupported type {s}", .{(VM.lapi.typename(L.typeOf(-1)))}),
                    else => return L.Zerrorf("{s}", .{@errorName(err)}),
                }
            };
            L.pushlstring(buf.items);

            return 1;
        }
    }.inner;
}

fn decodeArray(L: *VM.lua.State, array: *std.ArrayList(json.JsonValue), preserve_null: bool) !void {
    L.rawcheckstack(2);
    L.createtable(@intCast(array.items.len), 0);

    for (array.items, 1..) |item, i| {
        try decodeValue(L, item, preserve_null);
        L.rawseti(-2, @intCast(i));
    }
}

fn decodeObject(L: *VM.lua.State, object: *std.StringArrayHashMap(json.JsonValue), preserve_null: bool) !void {
    L.rawcheckstack(3);
    L.createtable(0, @intCast(object.count()));

    var iter = object.iterator();
    while (iter.next()) |entry| {
        L.pushlstring(entry.key_ptr.*);
        try decodeValue(L, entry.value_ptr.*, preserve_null);
        L.settable(-3);
    }
}

pub fn decodeValue(L: *VM.lua.State, jsonValue: json.JsonValue, preserve_null: bool) anyerror!void {
    switch (jsonValue) {
        .nil => if (preserve_null) {
            _ = L.getfield(VM.lua.REGISTRYINDEX, "_SERDE_JSON_NULL");
        } else L.pushnil(),
        .boolean => |boolean| L.pushboolean(boolean),
        .integer => |integer| L.pushnumber(@floatFromInt(integer)),
        .float => |float| L.pushnumber(float),
        .string, .static_string => |string| L.pushlstring(string),
        .object => |object| try decodeObject(L, object, preserve_null),
        .array => |array| try decodeArray(L, array, preserve_null),
    }
}

pub fn LuaDecoder(comptime json_kind: JsonKind) fn (L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn inner(L: *VM.lua.State) !i32 {
            const string = L.Lcheckstring(1);
            if (string.len == 0) {
                L.pushnil();
                return 1;
            }

            var preserve_null = false;

            const config_type = L.typeOf(2);
            if (!config_type.isnoneornil()) {
                try L.Zchecktype(2, .Table);
                const preserve_null_type = L.getfield(2, "preserveNull");
                if (!preserve_null_type.isnoneornil()) {
                    try L.Zchecktype(-1, .Boolean);
                    preserve_null = L.toboolean(-1);
                }
                L.pop(1);
            }

            const allocator = luau.getallocator(L);

            var root = try switch (json_kind) {
                .JSON => json.parse(allocator, string),
                .JSON5 => json.parseJson5(allocator, string),
            };
            defer root.deinit();

            try decodeValue(L, root.value, preserve_null);

            return 1;
        }
    }.inner;
}

pub fn lua_setprops(L: *VM.lua.State) void {
    L.createtable(0, 1);

    L.createtable(0, 0);

    { // JsonNull Metatable
        L.Zpushvalue(.{
            .__tostring = struct {
                fn inner(l: *VM.lua.State) i32 {
                    l.pushstring("JsonValue.Null");
                    return 1;
                }
            }.inner,
        });
        L.setreadonly(-1, true);
        _ = L.setmetatable(-2);
    }

    L.setreadonly(-1, true);

    L.pushvalue(-1);
    L.setfield(VM.lua.REGISTRYINDEX, "_SERDE_JSON_NULL");
    NULL_PTR = L.topointer(-1) orelse unreachable;

    L.setfield(-2, "Null");
    L.setfield(-2, "Values");

    L.Zpushvalue(.{
        .None = 0,
        .TwoSpaces = 1,
        .FourSpaces = 2,
        .Tabs = 3,
    });
    L.setreadonly(-1, true);
    L.setfield(-2, "Indents");

    L.setreadonly(-1, true);
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
