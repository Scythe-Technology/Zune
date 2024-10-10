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

pub const FileSearchError = error{
    NoFileNameFound,
};
pub fn searchForExtensions(allocator: std.mem.Allocator, fileName: []const u8, extensions: []const []const u8) ![]const u8 {
    const fileExists = try doesFileExist(fileName);
    if (!fileExists) {
        for (extensions) |ext| {
            const result = std.mem.join(allocator, "", &.{ fileName, ext }) catch continue;
            defer allocator.free(result);
            if (try doesFileExist(result))
                return allocator.dupe(u8, result) catch continue;
        }
        return FileSearchError.NoFileNameFound;
    }
    return allocator.dupe(u8, fileName) catch return FileSearchError.NoFileNameFound;
}

pub fn searchForExtensionsZ(allocator: std.mem.Allocator, fileName: []const u8, extensions: []const []const u8) ![:0]const u8 {
    const fileExists = try doesFileExist(fileName);
    if (!fileExists) {
        for (extensions) |ext| {
            const result = std.mem.join(allocator, "", &.{ fileName, ext }) catch continue;
            defer allocator.free(result);
            if (try doesFileExist(result))
                return allocator.dupeZ(u8, result) catch continue;
        }
        return FileSearchError.NoFileNameFound;
    }
    return allocator.dupeZ(u8, fileName) catch return FileSearchError.NoFileNameFound;
}
