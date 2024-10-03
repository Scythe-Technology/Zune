const std = @import("std");
const toml = @import("toml");

pub const parse = toml.parse;

pub fn checkOptionTable(table: toml.Table, comptime key: []const u8) ?toml.Table {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .table) {
        std.debug.print("[zune.toml] '{s}' must be a table\n", .{key});
        return null;
    }
    return item.table;
}

pub fn checkOptionInteger(table: toml.Table, comptime key: []const u8) ?i64 {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .integer) {
        std.debug.print("[zune.toml] '{s}' must be a integer\n", .{key});
        return null;
    }
    return item.integer;
}

pub fn checkOptionBool(table: toml.Table, comptime key: []const u8) ?bool {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .boolean) {
        std.debug.print("[zune.toml] '{s}' must be a boolean\n", .{key});
        return null;
    }
    return item.boolean;
}

pub fn checkOptionString(table: toml.Table, comptime key: []const u8) ?[]const u8 {
    if (!table.contains(key)) return null;
    const item = table.table.get(key) orelse unreachable;
    if (item != .string) {
        std.debug.print("[zune.toml] '{s}' must be a string\n", .{key});
        return null;
    }
    return item.string;
}
