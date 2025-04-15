const std = @import("std");

const fs = std.fs;

const FileError = error{
    NotAbsolute,
};

pub fn doesFileExist(path: []const u8) !bool {
    if (!fs.path.isAbsolute(path))
        return FileError.NotAbsolute;
    var dir = fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.NotDir => return true,
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close();
    return false;
}

pub fn SearchResult(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        result: Result,

        const Result = union(enum) {
            exact: T,
            results: []const T,
            none: void,
        };

        const Self = @This();

        pub fn deinit(self: Self) void {
            switch (self.result) {
                .exact => |e| self.allocator.free(e),
                .results => |r| {
                    for (r) |result| self.allocator.free(result);
                    self.allocator.free(r);
                },
                .none => {},
            }
        }
    };
}

pub fn searchForExtensions(allocator: std.mem.Allocator, fileName: []const u8, extensions: []const []const u8) !SearchResult([]const u8) {
    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();
    errdefer for (list.items) |value| allocator.free(value);
    for (extensions) |ext| {
        const result = std.mem.join(allocator, "", &.{ fileName, ext }) catch continue;
        defer allocator.free(result);
        if (try doesFileExist(result)) {
            const copy = try allocator.dupe(u8, result);
            errdefer allocator.free(copy);
            try list.append(copy);
        }
    }
    if (list.items.len == 0)
        return .{ .allocator = allocator, .result = .none };
    return .{
        .allocator = allocator,
        .result = .{
            .results = try list.toOwnedSlice(),
        },
    };
}

pub fn searchForExtensionsZ(allocator: std.mem.Allocator, fileName: []const u8, extensions: []const []const u8) !SearchResult([:0]const u8) {
    var list = std.ArrayList([:0]const u8).init(allocator);
    defer list.deinit();
    errdefer for (list.items) |value| allocator.free(value);
    for (extensions) |ext| {
        const result = std.mem.join(allocator, "", &.{ fileName, ext }) catch continue;
        defer allocator.free(result);
        if (try doesFileExist(result)) {
            const copy = try allocator.dupeZ(u8, result);
            errdefer allocator.free(copy);
            try list.append(copy);
        }
    }
    if (list.items.len == 0)
        return .{ .allocator = allocator, .result = .none };
    return .{
        .allocator = allocator,
        .result = .{
            .results = try list.toOwnedSlice(),
        },
    };
}

const LuaFileType = enum {
    Lua,
    Luau,
};

pub const POSSIBLE_EXTENSIONS = [_][]const u8{
    ".luau",
    ".lua",
    "/init.luau",
    "/init.lua",
};

pub fn getLuaFileType(path: []const u8) ?LuaFileType {
    if (std.mem.endsWith(u8, path, ".lua"))
        return .Lua;
    if (std.mem.endsWith(u8, path, ".luau"))
        return .Luau;
    return null;
}

pub fn findLuauFile(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !SearchResult([]const u8) {
    const absPath = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(absPath);
    return findLuauFileFromPath(allocator, absPath, fileName);
}

pub fn findLuauFileZ(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !SearchResult([:0]const u8) {
    const absPath = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(absPath);
    return findLuauFileFromPathZ(allocator, absPath, fileName);
}

pub fn findLuauFileFromPath(allocator: std.mem.Allocator, absPath: []const u8, fileName: []const u8) !SearchResult([]const u8) {
    const absF = try std.fs.path.resolve(allocator, &.{ absPath, fileName });
    defer allocator.free(absF);
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;
    return try searchForExtensions(allocator, absF, &POSSIBLE_EXTENSIONS);
}

pub fn findLuauFileFromPathZ(allocator: std.mem.Allocator, absPath: []const u8, fileName: []const u8) !SearchResult([:0]const u8) {
    const absF = try std.fs.path.resolve(allocator, &.{ absPath, fileName });
    defer allocator.free(absF);
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;
    return try searchForExtensionsZ(allocator, absF, &POSSIBLE_EXTENSIONS);
}
