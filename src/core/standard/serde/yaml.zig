const std = @import("std");
const yaml = @import("yaml");
const luau = @import("luau");

const VM = luau.VM;

const Error = error{
    InvalidKey,
    InvalidNumber,
    TableSizeMismatch,
    CircularReference,
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

fn encodeValue(L: *VM.lua.State, allocator: std.mem.Allocator, tracked: *std.ArrayList(*const anyopaque)) !yaml.Yaml.Value {
    switch (L.typeOf(-1)) {
        .String => {
            var buf = std.ArrayList(u8).init(allocator);
            errdefer buf.deinit();
            const string = L.Lcheckstring(-1);
            try escape_string(&buf, string);
            return yaml.Yaml.Value{ .string = try buf.toOwnedSlice() };
        },
        .Number => {
            const num = L.Lchecknumber(-1);
            if (std.math.isNan(num) or std.math.isInf(num)) return Error.InvalidNumber;
            return yaml.Yaml.Value{ .float = num };
        },
        .Table => {
            const tablePtr = L.topointer(-1) orelse return error.Failed;

            for (tracked.items) |t| if (t == tablePtr) return Error.CircularReference;
            try tracked.append(tablePtr);

            const tableSize = L.objlen(-1);

            L.pushnil();
            const nextKey = L.next(-2);
            if (tableSize > 0 or !nextKey) {
                const list = try allocator.alloc(yaml.Yaml.Value, @intCast(tableSize));
                errdefer allocator.free(list);
                if (nextKey) {
                    var order: usize = 0;

                    if (L.typeOf(-2) != .Number)
                        return Error.InvalidKey;

                    list[order] = try encodeValue(L, allocator, tracked);
                    L.pop(1); // drop: value
                    while (L.next(-2)) {
                        if (L.typeOf(-2) != .Number)
                            return Error.InvalidKey;

                        order += 1;
                        list[order] = try encodeValue(L, allocator, tracked);
                        L.pop(1); // drop: value
                    }
                    order += 1;

                    if (@as(i32, @intCast(order)) != tableSize)
                        return Error.TableSizeMismatch;
                }
                return yaml.Yaml.Value{ .list = list };
            } else {
                var map = std.StringArrayHashMapUnmanaged(yaml.Yaml.Value){};
                errdefer map.deinit(allocator);

                if (L.typeOf(-2) != .String)
                    return Error.InvalidKey;

                try map.put(allocator, L.tostring(-2) orelse unreachable, try encodeValue(L, allocator, tracked));
                L.pop(1); // drop: value
                while (L.next(-2)) {
                    if (L.typeOf(-2) != .String)
                        return Error.InvalidKey;

                    try map.put(allocator, L.tostring(-2) orelse unreachable, try encodeValue(L, allocator, tracked));
                    L.pop(1); // drop: value
                }
                return yaml.Yaml.Value{ .map = map };
            }
        },
        else => return L.Zerror("UnsupportedType"),
    }
}

pub fn lua_encode(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tracked = std.ArrayList(*const anyopaque).init(allocator);
    defer tracked.deinit();

    const value = try encodeValue(L, arena.allocator(), &tracked);

    var buf = std.ArrayList(u8).init(arena.allocator());
    try value.stringify(buf.writer(), .{});

    L.pushlstring(buf.items);

    return 1;
}

fn decodeList(L: *VM.lua.State, list: yaml.Yaml.List) void {
    L.createtable(@intCast(list.len), 0);

    if (list.len == 0)
        return;

    for (list, 1..) |val, key| {
        switch (val) {
            .boolean => |b| L.pushboolean(b),
            .float => |f| L.pushnumber(f),
            .int => |i| L.pushnumber(@floatFromInt(i)),
            .string => |str| L.pushlstring(str),
            .map => |m| decodeMap(L, m),
            .list => |ls| decodeList(L, ls),
            .empty => continue,
        }
        L.rawseti(-2, @intCast(key));
    }
}

fn decodeMap(L: *VM.lua.State, map: yaml.Yaml.Map) void {
    const count = map.count();
    L.createtable(0, @intCast(count));
    if (count == 0)
        return;

    var iter = map.iterator();
    while (iter.next()) |k| {
        const key = k.key_ptr.*;
        const value = k.value_ptr.*;
        L.pushlstring(key);
        switch (value) {
            .boolean => |b| L.pushboolean(b),
            .float => |f| L.pushnumber(f),
            .int => |i| L.pushnumber(@floatFromInt(i)),
            .string => |str| L.pushlstring(str),
            .map => |m| decodeMap(L, m),
            .list => |ls| decodeList(L, ls),
            .empty => continue,
        }
        L.settable(-3);
    }
}

pub fn lua_decode(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const string = try L.Zcheckvalue([]const u8, 1, null);
    if (string.len == 0) {
        L.pushnil();
        return 1;
    }

    var raw: yaml.Yaml = .{ .source = string };
    try raw.load(allocator);
    defer raw.deinit(allocator);

    if (raw.docs.items.len == 0) {
        L.createtable(0, 0);
        return 1;
    }

    switch (raw.docs.items[0]) {
        .boolean => |b| L.pushboolean(b),
        .float => |f| L.pushnumber(f),
        .int => |i| L.pushnumber(@floatFromInt(i)),
        .string => |str| L.pushlstring(str),
        .map => |m| decodeMap(L, m),
        .list => |ls| decodeList(L, ls),
        .empty => return 0,
    }

    return 1;
}
