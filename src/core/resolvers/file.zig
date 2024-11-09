const std = @import("std");

const zune = @import("../../zune.zig");

const fs = std.fs;

const FileError = error{
    NotAbsolute,
};

pub fn doesFileExist(path: []const u8) !bool {
    if (!fs.path.isAbsolute(path)) return FileError.NotAbsolute;
    var buf: [1]u8 = undefined;
    _ = fs.cwd().readFile(path, &buf) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return false,
        else => return err,
    };
    return true;
}

pub const AbsoluteResolveError = error{
    CouldNotGetAbsolutePath,
};
pub fn getAbsolutePathFromCwd(allocator: std.mem.Allocator, path: []const u8) AbsoluteResolveError![]const u8 {
    const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch
        return AbsoluteResolveError.CouldNotGetAbsolutePath;
    defer allocator.free(cwd_path);
    return std.fs.path.resolve(allocator, &.{ cwd_path, path }) catch
        return AbsoluteResolveError.CouldNotGetAbsolutePath;
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
        if (try doesFileExist(result))
            try list.append(allocator.dupe(u8, result) catch continue);
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
        if (try doesFileExist(result))
            try list.append(allocator.dupeZ(u8, result) catch continue);
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
