const std = @import("std");

const fs = std.fs;

pub fn doesFileExist(dir: std.fs.Dir, path: []const u8) !bool {
    var d = dir.openDir(path, .{}) catch |err| switch (err) {
        error.NotDir => return true,
        error.FileNotFound => return false,
        else => return err,
    };
    defer d.close();
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

pub fn searchForExtensions(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8, extensions: []const []const u8) !SearchResult([]const u8) {
    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();
    errdefer for (list.items) |value| allocator.free(value);
    for (extensions) |ext| {
        const result = std.mem.join(allocator, "", &.{ fileName, ext }) catch continue;
        defer allocator.free(result);
        if (try doesFileExist(dir, result)) {
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

pub fn searchForExtensionsZ(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8, extensions: []const []const u8) !SearchResult([:0]const u8) {
    var list = std.ArrayList([:0]const u8).init(allocator);
    defer list.deinit();
    errdefer for (list.items) |value| allocator.free(value);
    for (extensions) |ext| {
        const result = std.mem.join(allocator, "", &.{ fileName, ext }) catch continue;
        defer allocator.free(result);
        if (try doesFileExist(dir, result)) {
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
    return findLuauFileFromPath(allocator, dir, fileName);
}

pub fn findLuauFileZ(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !SearchResult([:0]const u8) {
    return findLuauFileFromPathZ(allocator, dir, fileName);
}

pub fn findLuauFileFromPath(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !SearchResult([]const u8) {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;
    return try searchForExtensions(allocator, dir, fileName, &POSSIBLE_EXTENSIONS);
}

pub fn findLuauFileFromPathZ(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !SearchResult([:0]const u8) {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;
    return try searchForExtensionsZ(allocator, dir, fileName, &POSSIBLE_EXTENSIONS);
}

pub fn getHomeDir(envMap: std.process.EnvMap) ?[]const u8 {
    return envMap.get("HOME") orelse envMap.get("USERPROFILE");
}

pub fn resolvePath(
    allocator: std.mem.Allocator,
    envMap: std.process.EnvMap,
    path: []const u8,
) ![]u8 {
    if (path.len > 0 and path[0] == '~' and (path.len == 1 or path[1] == '/' or path[1] == '\\')) {
        const homeDir = getHomeDir(envMap) orelse return error.HomeDirNotFound;
        return try std.mem.join(allocator, std.fs.path.sep_str, &.{ homeDir, path[@min(path.len, 2)..] });
    }
    return try allocator.dupe(u8, path);
}

pub fn resolve(
    allocator: std.mem.Allocator,
    envMap: std.process.EnvMap,
    paths: []const []const u8,
) ![]u8 {
    var resolvedPaths = try allocator.alloc([]u8, paths.len);
    defer allocator.free(resolvedPaths);
    defer for (resolvedPaths) |path| allocator.free(path);

    for (paths, 0..) |path, i| {
        resolvedPaths[i] = try resolvePath(allocator, envMap, path);
    }

    return try std.fs.path.resolve(allocator, resolvedPaths);
}
