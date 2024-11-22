const std = @import("std");
const luau = @import("luau");

const file = @import("file.zig");

const Scheduler = @import("../runtime/scheduler.zig");
const Parser = @import("../utils/parser.zig");

const Luau = luau.Luau;

pub var MAX_DEPTH: u8 = 4;
pub var USE_COLOR: bool = true;
pub var SHOW_TABLE_ADDRESS: bool = true;
pub var SHOW_RECURSIVE_TABLE: bool = false;
pub var DISPLAY_BUFFER_CONTENTS_MAX: usize = 48;

fn finishRequire(L: *Luau) i32 {
    if (L.isString(-1)) L.raiseError();
    return 1;
}

fn finishError(L: *Luau, errMsg: [:0]const u8) i32 {
    L.pushString(errMsg);
    return finishRequire(L);
}

fn fmt_tostring(allocator: std.mem.Allocator, L: *Luau, idx: i32) !?[]const u8 {
    switch (L.typeOf(idx)) {
        else => |t| {
            const ptr: *const anyopaque = L.toPointer(idx) catch return null;
            return std.fmt.allocPrint(allocator, "{s}: 0x{x}", .{ L.typeName(t), @intFromPtr(ptr) }) catch null;
        },
    }
    return null;
}

fn fmt_write_metamethod__tostring(L: *Luau, writer: anytype, idx: i32) !bool {
    L.pushValue(idx);
    defer L.pop(1); // drop: value
    if (L.getMetatable(if (idx < 0) idx - 1 else idx)) {
        const metaType = L.getField(-1, "__tostring");
        defer L.pop(2); // drop: field(or result of function), metatable
        if (!luau.isNoneOrNil(metaType)) {
            if (metaType != .string) {
                L.pushValue(-3);
                L.call(1, 1);
            }
            if (L.typeOf(-1) != .string)
                return L.Error("'__tostring' must return a string");
            const s = L.toString(-1) catch unreachable;
            try writer.print("{s}", .{s});
            return true;
        }
    }
    return false;
}

pub fn fmt_print_value(L: *Luau, writer: anytype, idx: i32, depth: usize, asKey: bool, map: ?*std.AutoArrayHashMap(usize, bool)) anyerror!void {
    const allocator = L.allocator();
    if (depth > MAX_DEPTH) {
        try writer.print("{s}", .{"{...}"});
        return;
    } else {
        switch (L.typeOfObjConsumed(idx) catch @panic("Failed LuaObject")) {
            .nil => try writer.print("nil", .{}),
            .boolean => |b| {
                if (USE_COLOR)
                    try writer.print("\x1b[1;33m{s}\x1b[0m", .{if (b) "true" else "false"})
                else
                    try writer.print("{s}", .{if (b) "true" else "false"});
            },
            .number => |n| {
                if (USE_COLOR)
                    try writer.print("\x1b[96m{d}\x1b[0m", .{n})
                else
                    try writer.print("{d}", .{n});
            },
            .string => |s| {
                if (asKey) {
                    if (Parser.isPlainText(s)) try writer.print("{s}", .{s}) else {
                        if (USE_COLOR)
                            try writer.print("\x1b[2m[\x1b[0m\x1b[32m\"{s}\"\x1b[0m\x1b[2m]\x1b[0m", .{
                                s,
                            })
                        else
                            try writer.print("[\"{s}\"]", .{s});
                        return;
                    }
                } else {
                    if (USE_COLOR)
                        try writer.print("\x1b[32m\"{s}\"\x1b[0m", .{s})
                    else
                        try writer.print("\"{s}\"", .{s});
                }
            },
            .table => {
                if (try fmt_write_metamethod__tostring(L, writer, -1))
                    return;
                if (asKey) {
                    const str = fmt_tostring(allocator, L, idx) catch "!ERR!";
                    if (str) |String| {
                        defer allocator.free(String);
                        if (USE_COLOR)
                            try writer.print("\x1b[95m<{s}>\x1b[0m", .{String})
                        else
                            try writer.print("<{s}>", .{String});
                    } else {
                        if (USE_COLOR)
                            try writer.print("\x1b[95m<table>\x1b[0m", .{})
                        else
                            try writer.print("<table>", .{});
                    }
                    return;
                }
                const ptr = @intFromPtr(L.toPointer(idx) catch std.debug.panic("Failed Table to Ptr Conversion", .{}));
                if (map) |tracked| {
                    if (tracked.get(ptr)) |_| {
                        if (SHOW_TABLE_ADDRESS) {
                            if (USE_COLOR)
                                try writer.print("\x1b[2m<recursive, table: 0x{x}>\x1b[0m", .{ptr})
                            else
                                try writer.print("<recursive, table: 0x{x}>", .{ptr});
                        } else {
                            if (USE_COLOR)
                                try writer.print("\x1b[2m<recursive, table>\x1b[0m", .{})
                            else
                                try writer.print("<recursive, table>", .{});
                        }
                        return;
                    }
                    try tracked.put(ptr, true);
                }
                defer _ = if (map) |tracked| tracked.orderedRemove(ptr);
                if (SHOW_TABLE_ADDRESS) {
                    const tableString = fmt_tostring(allocator, L, idx) catch "!ERR!";
                    if (tableString) |String| {
                        defer allocator.free(String);
                        if (USE_COLOR)
                            try writer.print("\x1b[2m<{s}> {{\x1b[0m\n", .{String})
                        else
                            try writer.print("<{s}> {{\n", .{String});
                    } else {
                        if (USE_COLOR)
                            try writer.print("\x1b[2m<table> {{\x1b[0m\n", .{})
                        else
                            try writer.print("<table> {{\n", .{});
                    }
                } else {
                    if (USE_COLOR)
                        try writer.print("\x1b[2m{{\x1b[0m\n", .{})
                    else
                        try writer.print("{{\n", .{});
                }
                L.pushNil();
                while (L.next(idx)) {
                    for (0..depth + 1) |_| try writer.print("    ", .{});
                    const n = L.getTop();
                    if (L.typeOf(n - 1) == .string) {
                        try fmt_print_value(L, writer, n - 1, depth + 1, true, null);
                        if (USE_COLOR)
                            try writer.print("\x1b[2m = \x1b[0m", .{})
                        else
                            try writer.print(" = ", .{});
                    } else {
                        if (USE_COLOR)
                            try writer.print("\x1b[2m[\x1b[0m", .{})
                        else
                            try writer.print("[", .{});
                        try fmt_print_value(L, writer, n - 1, depth + 1, true, null);
                        if (USE_COLOR)
                            try writer.print("\x1b[2m] = \x1b[0m", .{})
                        else
                            try writer.print("] = ", .{});
                    }
                    try fmt_print_value(L, writer, n, depth + 1, false, map);
                    if (USE_COLOR)
                        try writer.print("\x1b[2m,\x1b[0m \n", .{})
                    else
                        try writer.print(", \n", .{});
                    L.pop(1);
                }
                for (0..depth) |_| try writer.print("    ", .{});
                if (USE_COLOR)
                    try writer.print("\x1b[2m}}\x1b[0m", .{})
                else
                    try writer.print("}}", .{});
            },
            .buffer => |b| {
                const ptr: usize = blk: {
                    break :blk @intFromPtr(L.toPointer(idx) catch break :blk 0);
                };
                if (USE_COLOR)
                    try writer.writeAll("\x1b[95m");
                try writer.writeAll("<buffer ");
                if (b.len > DISPLAY_BUFFER_CONTENTS_MAX) {
                    try writer.print("0x{x} {X}", .{ ptr, b[0..DISPLAY_BUFFER_CONTENTS_MAX] });
                    try writer.print(" ...{d} truncated", .{(b.len - DISPLAY_BUFFER_CONTENTS_MAX)});
                } else {
                    try writer.print("0x{x} {X}", .{ ptr, b });
                }
                try writer.writeAll(">");
                if (USE_COLOR)
                    try writer.writeAll("\x1b[0m");
            },
            else => {
                if (try fmt_write_metamethod__tostring(L, writer, -1))
                    return;
                const str = fmt_tostring(allocator, L, idx) catch "!ERR!";
                if (str) |String| {
                    defer allocator.free(String);
                    if (USE_COLOR)
                        try writer.print("\x1b[95m<{s}>\x1b[0m", .{String})
                    else
                        try writer.print("<{s}>", .{String});
                }
            },
        }
    }
}

pub fn fmt_write_idx(allocator: std.mem.Allocator, L: *Luau, writer: anytype, idx: i32) !void {
    switch (L.typeOf(idx)) {
        .nil => try writer.print("nil", .{}),
        .string => try writer.print("{s}", .{L.toString(idx) catch @panic("Failed Conversion")}),
        .function, .userdata, .light_userdata, .thread => |t| blk: {
            if (try fmt_write_metamethod__tostring(L, writer, idx))
                break :blk;
            const str = fmt_tostring(allocator, L, idx) catch "!ERR!";
            if (str) |String| {
                defer allocator.free(String);
                if (USE_COLOR)
                    try writer.print("\x1b[95m<{s}>\x1b[0m", .{String})
                else
                    try writer.print("<{s}>", .{String});
            } else {
                if (USE_COLOR)
                    try writer.print("\x1b[95m<{s}>\x1b[0m", .{L.typeName(t)})
                else
                    try writer.print("<{s}>", .{L.typeName(t)});
            }
        },
        else => {
            if (!SHOW_RECURSIVE_TABLE) {
                var map = std.AutoArrayHashMap(usize, bool).init(allocator);
                defer map.deinit();
                try fmt_print_value(L, writer, idx, 0, false, &map);
            } else try fmt_print_value(L, writer, idx, 0, false, null);
        },
    }
}

fn fmt_write_buffer(L: *Luau, allocator: std.mem.Allocator, writer: anytype, top: usize) !void {
    for (1..top + 1) |i| {
        if (i > 1)
            try writer.print("\t", .{});
        const idx: i32 = @intCast(i);
        try fmt_write_idx(allocator, L, writer, idx);
    }
}

pub fn fmt_args(L: *Luau) !i32 {
    const top = L.getTop();
    const allocator = L.allocator();
    if (top == 0) {
        L.pushLString("");
        return 1;
    }
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const writer = buffer.writer();

    try fmt_write_buffer(L, allocator, writer, @intCast(top));

    L.pushLString(buffer.items);

    return 1;
}

pub fn fmt_print(L: *Luau) !i32 {
    const top = L.getTop();
    const allocator = L.allocator();
    if (top == 0) {
        std.debug.print("\n", .{});
        return 0;
    }
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const writer = buffer.writer();

    try fmt_write_buffer(L, allocator, writer, @intCast(top));

    std.debug.print("{s}\n", .{buffer.items});

    return 0;
}
