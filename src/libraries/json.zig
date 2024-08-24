const std = @import("std");
const json = @import("json");
const luau = @import("luau");

const Luau = luau.Luau;

pub const INDENTS = enum {
    NO_LINE,
    SPACES_2,
    SPACES_4,
    TABS,
};

pub fn parse(allocator: std.mem.Allocator, str: []const u8) !*json.JsonValue {
    return json.parse(str, allocator);
}

fn stringConcat(buffer: *std.ArrayList(u8), value: []const u8) void {
    buffer.appendSlice(value) catch |err| std.debug.panic("{}", .{err});
}

fn serializerWriteIndent(buffer: *std.ArrayList(u8), indents: INDENTS, depth: usize) void {
    const keyIndents = switch (indents) {
        .NO_LINE => "",
        .SPACES_2 => "  ",
        .SPACES_4 => "    ",
        .TABS => "\t",
    };
    const size = keyIndents.len * depth;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        stringConcat(buffer, keyIndents);
    }
}

fn serializeObject(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), jsonObject: *json.JsonObject, indents: INDENTS, depth: usize) void {
    stringConcat(buffer, "{");
    if (indents != INDENTS.NO_LINE) {
        stringConcat(buffer, "\n");
    }
    for (jsonObject.map.keys(), 0..) |key, index| {
        serializerWriteIndent(buffer, indents, depth + 1);
        stringConcat(buffer, "\"");
        stringConcat(buffer, key);
        stringConcat(buffer, "\":");
        if (indents != INDENTS.NO_LINE) {
            stringConcat(buffer, " ");
        }
        const value = jsonObject.map.get(key);
        if (value) |jValue| {
            serializeValue(allocator, buffer, jValue, indents, depth + 1) catch |err| {
                std.debug.panic("json internal failed to serialize ({})", .{err});
            };
        } else {
            std.debug.panic("json internal value not found", .{});
        }
        if (index < jsonObject.map.count() - 1) {
            stringConcat(buffer, ",");
        }
        if (indents != INDENTS.NO_LINE) {
            stringConcat(buffer, "\n");
        }
    }
    serializerWriteIndent(buffer, indents, depth);
    stringConcat(buffer, "}");
}

fn serializeArray(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), jsonArray: *json.JsonArray, indents: INDENTS, depth: usize) void {
    stringConcat(buffer, "[");
    if (indents != INDENTS.NO_LINE) {
        stringConcat(buffer, "\n");
    }
    for (jsonArray.array.items, 0..) |value, index| {
        serializerWriteIndent(buffer, indents, depth + 1);
        serializeValue(allocator, buffer, value, indents, depth + 1) catch |err| {
            std.debug.panic("json internal failed to serialize ({})", .{err});
        };
        if (index < jsonArray.array.items.len - 1) {
            stringConcat(buffer, ",");
        }
        if (indents != INDENTS.NO_LINE) {
            stringConcat(buffer, "\n");
        }
    }
    serializerWriteIndent(buffer, indents, depth);
    stringConcat(buffer, "]");
}

fn serializeValue(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), jsonValue: *json.JsonValue, indents: INDENTS, depth: usize) !void {
    switch (jsonValue.type) {
        .integer => stringConcat(buffer, try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{jsonValue.integer()},
        )),
        .float => stringConcat(buffer, try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{jsonValue.float()},
        )),
        .string => stringConcat(buffer, try std.fmt.allocPrint(
            allocator,
            "\"{s}\"",
            .{jsonValue.string()},
        )),
        .boolean => stringConcat(buffer, try std.fmt.allocPrint(
            allocator,
            "{any}",
            .{jsonValue.boolean()},
        )),
        .nil => stringConcat(buffer, "null"),
        .object => serializeObject(allocator, buffer, jsonValue.object(), indents, depth),
        .array => serializeArray(allocator, buffer, jsonValue.array(), indents, depth),
    }
}

pub fn serializePretty(allocator: std.mem.Allocator, jsonValue: *json.JsonValue, indents: INDENTS) ![]const u8 {
    var str = std.ArrayList(u8).init(allocator);
    defer str.deinit();
    try serializeValue(allocator, &str, jsonValue, indents, 0);
    return try str.toOwnedSlice();
}

pub fn newObject(allocator: std.mem.Allocator) !*json.JsonValue {
    const jsonObject = try allocator.create(json.JsonObject);
    errdefer jsonObject.deinit(allocator);

    jsonObject.map = std.StringArrayHashMap(*json.JsonValue).init(allocator);

    const jsonValue = try allocator.create(json.JsonValue);
    errdefer jsonValue.deinit(allocator);

    jsonValue.type = json.JsonType.object;
    jsonValue.value = .{ .object = jsonObject };

    return jsonValue;
}

pub fn newArray(allocator: std.mem.Allocator) !*json.JsonValue {
    const jsonArray = try allocator.create(json.JsonArray);
    errdefer jsonArray.deinit(allocator);

    jsonArray.array = std.ArrayList(*json.JsonValue).init(allocator);

    const jsonValue = try allocator.create(json.JsonValue);
    errdefer jsonValue.deinit(allocator);

    jsonValue.type = json.JsonType.array;
    jsonValue.value = .{ .array = jsonArray };

    return jsonValue;
}

pub fn newString(allocator: std.mem.Allocator, value: []const u8) !*json.JsonValue {
    const jsonValue = try allocator.create(json.JsonValue);
    errdefer jsonValue.deinit(allocator);

    const copy = try allocator.dupe(u8, value);
    errdefer allocator.free(copy);

    jsonValue.type = json.JsonType.string;
    jsonValue.value = .{ .string = copy };
    jsonValue.stringPtr = copy;

    return jsonValue;
}

pub fn appendArray(jsonArray: *json.JsonArray, value: *json.JsonValue) !void {
    try jsonArray.array.append(value);
}

pub fn setObject(jsonObject: *json.JsonObject, key: []const u8, value: *json.JsonValue) !?*json.JsonValue {
    var oldValue: ?*json.JsonValue = null;
    if (jsonObject.getOrNull(key)) |existing| {
        if (existing != value) {
            oldValue = existing;
        }
    }
    const allocatedKey = try jsonObject.map.allocator.dupe(u8, key);
    try jsonObject.map.put(allocatedKey, value);
    return oldValue;
}
