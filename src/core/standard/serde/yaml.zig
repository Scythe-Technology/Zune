const std = @import("std");
const yaml = @import("yaml");
const luau = @import("luau");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const Luau = luau.Luau;

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

fn encodeValue(L: *Luau, allocator: std.mem.Allocator, tracked: *std.ArrayList(*const anyopaque)) !yaml.Value {
    switch (L.typeOf(-1)) {
        .string => {
            var buf = std.ArrayList(u8).init(allocator);
            errdefer buf.deinit();
            const string = L.checkString(-1);
            try escape_string(&buf, string);
            return yaml.Value{ .string = try buf.toOwnedSlice() };
        },
        .number => {
            const num = L.checkNumber(-1);
            if (std.math.isNan(num) or std.math.isInf(num)) return Error.InvalidNumber;
            return yaml.Value{ .float = num };
        },
        .table => {
            const tablePtr = try L.toPointer(-1);

            for (tracked.items) |t| if (t == tablePtr) return Error.CircularReference;
            try tracked.append(tablePtr);

            const tableSize = L.objLen(-1);
            L.pushNil();
            const nextKey = L.next(-2);
            if (tableSize > 0 or !nextKey) {
                const list = try allocator.alloc(yaml.Value, @intCast(tableSize));
                errdefer allocator.free(list);
                if (nextKey) {
                    var order: usize = 0;
                    if (L.typeOf(-2) != .number) return Error.InvalidKey;
                    list[order] = try encodeValue(L, allocator, tracked);
                    L.pop(1); // drop: value
                    while (L.next(-2)) {
                        if (L.typeOf(-2) != .number) return Error.InvalidKey;
                        order += 1;
                        list[order] = try encodeValue(L, allocator, tracked);
                        L.pop(1); // drop: value
                    }
                    order += 1;
                    if (@as(i32, @intCast(order)) != tableSize) return Error.TableSizeMismatch;
                }
                return yaml.Value{ .list = list };
            } else {
                var map = std.StringArrayHashMap(yaml.Value).init(allocator);
                errdefer map.deinit();
                if (L.typeOf(-2) != .string) return Error.InvalidKey;
                try map.put(L.toString(-2) catch unreachable, try encodeValue(L, allocator, tracked));
                L.pop(1); // drop: value
                while (L.next(-2)) {
                    if (L.typeOf(-2) != .string) return Error.InvalidKey;
                    try map.put(L.toString(-2) catch unreachable, try encodeValue(L, allocator, tracked));
                    L.pop(1); // drop: value
                }
                return yaml.Value{ .map = map };
            }
        },
        else => L.raiseErrorStr("UnsupportedType", .{}),
    }
}

pub fn lua_encode(L: *Luau) i32 {
    const allocator = L.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tracked = std.ArrayList(*const anyopaque).init(allocator);
    defer tracked.deinit();

    const value = encodeValue(L, arena.allocator(), &tracked) catch |err| {
        tracked.deinit();
        arena.deinit();
        L.raiseErrorStr("%s", .{@errorName(err).ptr});
    };

    var buf = std.ArrayList(u8).init(arena.allocator());
    value.stringify(buf.writer(), .{}) catch |err| {
        tracked.deinit();
        arena.deinit();
        L.raiseErrorStr("%s", .{@errorName(err).ptr});
    };

    L.pushLString(buf.items);

    return 1;
}

fn decodeList(L: *Luau, list: yaml.List) void {
    L.newTable();

    if (list.len == 0) return;

    for (list, 0..) |val, key| {
        switch (val) {
            .float => |f| L.pushNumber(f),
            .int => |i| L.pushInteger(@intCast(i)),
            .string => |str| L.pushLString(str),
            .map => |m| decodeMap(L, m),
            .list => |ls| decodeList(L, ls),
            .empty => continue,
        }
        L.rawSetIndex(-2, @intCast(key + 1));
    }
}

fn decodeMap(L: *Luau, map: yaml.Map) void {
    L.newTable();
    const count = map.count();
    if (count == 0) return;

    var iter = map.iterator();
    while (iter.next()) |k| {
        const key = k.key_ptr.*;
        const value = k.value_ptr.*;
        L.pushLString(key);
        switch (value) {
            .float => |f| L.pushNumber(f),
            .int => |i| L.pushInteger(@intCast(i)),
            .string => |str| L.pushLString(str),
            .map => |m| decodeMap(L, m),
            .list => |ls| decodeList(L, ls),
            .empty => continue,
        }
        L.setTable(-3);
    }
}

pub fn lua_decode(L: *Luau) i32 {
    const allocator = L.allocator();
    const string = L.checkString(1);
    if (string.len == 0) {
        L.pushNil();
        return 1;
    }

    var raw = yaml.Yaml.load(allocator, string) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer raw.deinit();

    if (raw.docs.items.len == 0) {
        L.newTable();
        return 1;
    }

    switch (raw.docs.items[0]) {
        .float => |f| L.pushNumber(f),
        .int => |i| L.pushInteger(@intCast(i)),
        .string => |str| L.pushLString(str),
        .map => |m| decodeMap(L, m),
        .list => |ls| decodeList(L, ls),
        .empty => return 0,
    }

    return 1;
}
