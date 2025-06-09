const std = @import("std");

const fs = std.fs;

pub const SearchResult = struct {
    allocator: std.mem.Allocator,
    result: Result,

    const File = struct {
        name: [:0]const u8,
        handle: std.fs.File,
    };

    const Result = union(enum) {
        results: []const File,
        none: void,
    };

    const Self = @This();

    pub fn deinit(self: Self) void {
        switch (self.result) {
            .results => |r| {
                for (r) |result| {
                    result.handle.close();
                    self.allocator.free(result.name);
                }
                self.allocator.free(r);
            },
            .none => {},
        }
    }
};

pub fn searchForExtensions(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8, extensions: []const []const u8) !SearchResult {
    var list: std.ArrayListUnmanaged(SearchResult.File) = .empty;
    defer list.deinit(allocator);
    errdefer for (list.items) |value| {
        value.handle.close();
        allocator.free(value.name);
    };
    for (extensions) |ext| {
        const result = try std.mem.concatWithSentinel(allocator, u8, &.{ fileName, ext }, 0);
        errdefer allocator.free(result);

        const file = dir.openFile(result, .{ .mode = .read_only }) catch |err| switch (err) {
            else => {
                allocator.free(result);
                continue;
            },
        };
        errdefer file.close();

        const md = try file.metadata();
        if (md.kind() != .file) {
            file.close();
            allocator.free(result);
            continue;
        }

        try list.append(allocator, .{
            .handle = file,
            .name = result,
        });
    }
    if (list.items.len == 0)
        return .{ .allocator = allocator, .result = .none };
    return .{
        .allocator = allocator,
        .result = .{
            .results = try list.toOwnedSlice(allocator),
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

pub fn findLuauFile(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !SearchResult {
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;
    return try searchForExtensions(allocator, dir, fileName, &POSSIBLE_EXTENSIONS);
}

pub fn getHomeDir(envMap: std.process.EnvMap) ?[]const u8 {
    return envMap.get("HOME") orelse envMap.get("USERPROFILE");
}

pub inline fn shouldFetchHomeDir(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "~") and (path.len <= 1 or (path[1] == '/' or path[1] == '\\'));
}

pub fn loadPathAlloc(
    allocator: std.mem.Allocator,
    envMap: std.process.EnvMap,
    path: []const u8,
) ![]u8 {
    if (shouldFetchHomeDir(path)) {
        const homeDir = getHomeDir(envMap) orelse return error.HomeDirNotFound;
        return try fs.path.join(allocator, &.{ homeDir, path[@min(path.len, 2)..] });
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
        resolvedPaths[i] = try loadPathAlloc(allocator, envMap, path);
    }

    return try fs.path.resolve(allocator, resolvedPaths);
}

pub fn resolveZ(
    allocator: std.mem.Allocator,
    envMap: std.process.EnvMap,
    paths: []const []const u8,
) ![:0]u8 {
    const resolved = try resolve(allocator, envMap, paths);
    defer allocator.free(resolved);
    return try allocator.dupeZ(u8, resolved);
}
