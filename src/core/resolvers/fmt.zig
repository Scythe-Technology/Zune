const std = @import("std");
const luau = @import("luau");

const file = @import("file.zig");

const Scheduler = @import("../runtime/scheduler.zig");
const Parser = @import("../utils/parser.zig");

const Luau = luau.Luau;

pub var MAX_DEPTH: u8 = 4;

pub fn finishRequire(L: *Luau) i32 {
    if (L.isString(-1)) L.raiseError();
    return 1;
}

pub fn finishError(L: *Luau, errMsg: [:0]const u8) i32 {
    L.pushString(errMsg);
    return finishRequire(L);
}

pub fn fmt_tostring(allocator: std.mem.Allocator, L: *Luau, idx: i32) !?[]const u8 {
    switch (L.typeOf(idx)) {
        else => |t| {
            const ptr: *const anyopaque = L.toPointer(idx) catch return null;
            return std.fmt.allocPrint(allocator, "{s}: 0x{x}", .{ L.typeName(t), @intFromPtr(ptr) }) catch null;
        },
    }
    return null;
}

pub fn fmt_print_value(L: *Luau, idx: i32, depth: usize, asKey: bool) void {
    const allocator = L.allocator();
    if (depth > MAX_DEPTH) {
        std.debug.print("{s}", .{"{...}"});
        return;
    } else {
        switch (L.typeOfObjConsumed(idx) catch @panic("Failed LuaObject")) {
            .nil => std.debug.print("nil", .{}),
            .boolean => |b| std.debug.print("\x1b[1;33m{s}\x1b[0m", .{if (b) "true" else "false"}),
            .number => |n| std.debug.print("\x1b[96m{d}\x1b[0m", .{n}),
            .string => |s| {
                if (asKey) {
                    if (Parser.isPlainText(s)) std.debug.print("{s}", .{s}) else {
                        std.debug.print("\x1b[2m[\x1b[0m\x1b[32m\"{s}\"\x1b[0m\x1b[2m]\x1b[0m", .{s});
                        return;
                    }
                } else std.debug.print("\x1b[32m\"{s}\"\x1b[0m", .{s});
            },
            .table => {
                if (L.getMetatable(-1)) {
                    const metaType = L.getField(-1, "__tostring");
                    if (!luau.isNoneOrNil(metaType)) {
                        if (metaType != .string) {
                            L.pushValue(idx);
                            L.call(1, 1);
                        }
                        if (L.typeOf(-1) != .string) L.raiseErrorStr("'__tostring' must return a string", .{});
                        const s = L.toString(-1) catch "";
                        if (depth == 0 and Parser.isPlainText(s)) {
                            std.debug.print("{s}", .{s});
                        } else fmt_print_value(L, -1, 0, false);
                        L.pop(2); // drop string, metatable
                        return;
                    }
                }
                if (asKey) {
                    const str = fmt_tostring(allocator, L, idx) catch "!ERR!";
                    if (str) |String| {
                        defer allocator.free(String);
                        std.debug.print("\x1b[95m<{s}>\x1b[0m", .{String});
                    } else std.debug.print("\x1b[95m<table>\x1b[0m", .{});
                    return;
                }
                {
                    const tableString = fmt_tostring(allocator, L, idx) catch "!ERR!";
                    if (tableString) |String| {
                        defer allocator.free(String);
                        std.debug.print("\x1b[2m<{s}> {s}\x1b[0m\n", .{ String, "{" });
                    } else std.debug.print("\x1b[2m<table> {s}\x1b[0m\n", .{"{"});
                }
                L.pushNil();
                while (L.next(idx)) {
                    for (0..depth + 1) |_| std.debug.print("    ", .{});
                    const n = L.getTop();
                    if (L.typeOf(n - 1) == .string) {
                        fmt_print_value(L, n - 1, depth + 1, true);
                        std.debug.print("\x1b[2m = \x1b[0m", .{});
                    } else {
                        std.debug.print("\x1b[2m[\x1b[0m", .{});
                        fmt_print_value(L, n - 1, depth + 1, true);
                        std.debug.print("\x1b[2m] = \x1b[0m", .{});
                    }
                    fmt_print_value(L, n, depth + 1, false);
                    std.debug.print("\x1b[2m,\x1b[0m \n", .{});
                    L.pop(1);
                }
                for (0..depth) |_| std.debug.print("    ", .{});
                std.debug.print("\x1b[2m{s}\x1b[0m", .{"}"});
            },
            else => {
                const str = fmt_tostring(allocator, L, idx) catch "!ERR!";
                if (str) |String| {
                    defer allocator.free(String);
                    std.debug.print("\x1b[95m<{s}>\x1b[0m", .{String});
                }
            },
        }
    }
}

pub fn fmt_print(L: *Luau) i32 {
    const top = L.getTop();
    const allocator = L.allocator();
    if (top == 0) {
        std.debug.print("\n", .{});
        return 0;
    }
    for (1..@intCast(top + 1)) |i| {
        if (i > 1) {
            std.debug.print("\t", .{});
        }
        const idx: i32 = @intCast(i);
        switch (L.typeOf(idx)) {
            .nil => std.debug.print("nil", .{}),
            .string => std.debug.print("{s}", .{L.toString(idx) catch @panic("Failed Conversion")}),
            .function, .userdata, .thread => |t| {
                const str = fmt_tostring(allocator, L, idx) catch "!ERR!";
                if (str) |String| {
                    defer allocator.free(String);
                    std.debug.print("\x1b[95m<{s}>\x1b[0m", .{String});
                } else std.debug.print("\x1b[95m<{s}>\x1b[0m", .{L.typeName(t)});
            },
            else => fmt_print_value(L, idx, 0, false),
        }
    }
    std.debug.print("\n", .{});
    return 0;
}
