const std = @import("std");
const builtin = @import("builtin");
const luau = @import("luau");

const Luau = luau.Luau;

const fs = std.fs;

fn outputStatus(L: *Luau, status: [:0]const u8) i32 {
    L.pushBoolean(false);
    L.pushString(status);
    return 2;
}

fn fs_readFile(L: *Luau) i32 {
    const allocator = L.allocator();
    const path = L.checkString(1);
    const useBuffer = L.optBoolean(2) orelse false;
    const data = fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize)) catch |err| return outputStatus(L, @errorName(err));
    defer allocator.free(data);
    L.pushBoolean(true);
    if (useBuffer) {
        const buf: []u8 = L.newBuffer(data.len) catch {
            return outputStatus(L, "FailedToCreateBuffer");
        };
        @memcpy(buf, data);
    } else {
        L.pushLString(data);
    }
    return 2;
}

fn fs_readDir(L: *Luau) i32 {
    const path = L.checkString(1);
    var dir = fs.cwd().openDir(path, fs.Dir.OpenDirOptions{
        .iterate = true,
    }) catch |err| return outputStatus(L, @errorName(err));
    defer dir.close();
    var iter = dir.iterate();
    L.pushBoolean(true);
    L.newTable();
    var i: i32 = 1;
    while (true) {
        const entry = iter.next() catch |err| {
            L.pop(2); // Drop: table, boolean
            return outputStatus(L, @errorName(err));
        };
        if (entry == null) {
            break;
        }
        L.pushInteger(i);
        L.pushLString(entry.?.name);
        L.setTable(-3);
        i += 1;
    }
    return 2;
}

fn fs_writeFile(L: *Luau) i32 {
    const path = L.checkString(1);
    const data = if (L.isBuffer(2)) L.checkBuffer(2) else L.checkString(2);
    fs.cwd().writeFile(fs.Dir.WriteFileOptions{
        .sub_path = path,
        .data = data,
    }) catch |err| return outputStatus(L, @errorName(err));
    L.pushBoolean(true);
    return 1;
}

fn fs_writeDir(L: *Luau) i32 {
    const path = L.checkString(1);
    const recursive = L.optBoolean(2) orelse false;
    const cwd = std.fs.cwd();
    (if (recursive) cwd.makePath(path) else cwd.makeDir(path)) catch |err| return outputStatus(L, @errorName(err));
    L.pushBoolean(true);
    return 1;
}

fn fs_removeFile(L: *Luau) i32 {
    const path = L.checkString(1);
    fs.cwd().deleteFile(path) catch |err| return outputStatus(L, @errorName(err));
    L.pushBoolean(true);
    return 1;
}

fn fs_removeDir(L: *Luau) i32 {
    const path = L.checkString(1);
    const recursive = L.optBoolean(2) orelse false;
    const cwd = std.fs.cwd();
    (if (recursive) cwd.deleteTree(path) else cwd.deleteDir(path)) catch |err| return outputStatus(L, @errorName(err));
    L.pushBoolean(true);
    return 1;
}

fn internal_isDir(srcDir: fs.Dir, path: []const u8) bool {
    var dir = srcDir.openDir(path, fs.Dir.OpenDirOptions{}) catch return false;
    dir.close();
    return true;
}

fn internal_isFile(srcDir: fs.Dir, path: []const u8) bool {
    var file = srcDir.openFile(path, fs.File.OpenFlags{
        .mode = .read_write,
    }) catch return false;
    file.close();
    return true;
}

fn fs_isFile(L: *Luau) i32 {
    const path = L.checkString(1);
    L.pushBoolean(internal_isFile(fs.cwd(), path));
    return 1;
}

fn fs_isDir(L: *Luau) i32 {
    const path = L.checkString(1);
    L.pushBoolean(internal_isDir(fs.cwd(), path));
    return 1;
}

fn internal_lossyfloat_time(n: i128) f64 {
    return @as(f64, @floatFromInt(n)) / 1_000_000_000.0;
}

fn internal_metadata_table(L: *Luau, metadata: fs.File.Metadata, isSymlink: bool) void {
    L.newTable();
    L.setFieldNumber(-1, "createdAt", internal_lossyfloat_time(metadata.created() orelse 0));
    L.setFieldNumber(-1, "modifiedAt", internal_lossyfloat_time(metadata.modified()));
    L.setFieldNumber(-1, "accessedAt", internal_lossyfloat_time(metadata.accessed()));
    L.setFieldBoolean(-1, "symlink", isSymlink);
    L.setFieldUnsigned(-1, "size", @intCast(metadata.size()));
    switch (metadata.kind()) {
        .file => L.setFieldString(-1, "kind", "file"),
        .directory => L.setFieldString(-1, "kind", "dir"),
        .sym_link => L.setFieldString(-1, "kind", "symlink"),
        .door => L.setFieldString(-1, "kind", "door"),
        .character_device => L.setFieldString(-1, "kind", "character_device"),
        .unix_domain_socket => L.setFieldString(-1, "kind", "unix_domain_socket"),
        .block_device => L.setFieldString(-1, "kind", "block_device"),
        .event_port => L.setFieldString(-1, "kind", "event_port"),
        .named_pipe => L.setFieldString(-1, "kind", "named_pipe"),
        .whiteout => L.setFieldString(-1, "kind", "whiteout"),
        .unknown => L.setFieldString(-1, "kind", "unknown"),
    }

    L.newTable();
    const perms = metadata.permissions();
    L.setFieldBoolean(-1, "readOnly", perms.readOnly());

    L.setField(-2, "permissions");
}

fn fs_metadata(L: *Luau) i32 {
    const path = L.checkString(1);
    const allocator = L.allocator();
    const buf = allocator.alloc(u8, 4096) catch |err| switch (err) {
        error.OutOfMemory => return outputStatus(L, "OutOfMemory"),
    };
    const cwd = std.fs.cwd();
    if (internal_isDir(cwd, path)) {
        var dir = cwd.openDir(path, fs.Dir.OpenDirOptions{}) catch |err| return outputStatus(L, @errorName(err));
        defer dir.close();
        const metadata = dir.metadata() catch |err| return outputStatus(L, @errorName(err));
        var isLink = true;
        _ = cwd.readLink(path, buf) catch |err| switch (err) {
            else => {
                isLink = false;
            },
        };
        allocator.free(buf);
        L.pushBoolean(true);
        internal_metadata_table(L, metadata, isLink);
    } else if (internal_isFile(cwd, path)) {
        var file = cwd.openFile(path, fs.File.OpenFlags{
            .mode = .read_only,
        }) catch |err| return outputStatus(L, @errorName(err));
        defer file.close();
        const metadata = file.metadata() catch |err| return outputStatus(L, @errorName(err));
        var isLink = true;
        _ = cwd.readLink(path, buf) catch |err| switch (err) {
            else => {
                isLink = false;
            },
        };
        allocator.free(buf);
        L.pushBoolean(true);
        internal_metadata_table(L, metadata, isLink);
    } else {
        allocator.free(buf);
        return outputStatus(L, "FileNotFound");
    }
    return 2;
}

fn fs_move(L: *Luau) i32 {
    const fromPath = L.checkString(1);
    const toPath = L.checkString(2);
    const overwrite = L.optBoolean(3) orelse false;
    const cwd = std.fs.cwd();
    if (overwrite == false) {
        if (internal_isFile(cwd, toPath) or internal_isDir(cwd, toPath)) {
            return outputStatus(L, "PathAlreadyExists");
        }
    }
    cwd.rename(fromPath, toPath) catch |err| return outputStatus(L, @errorName(err));
    L.pushBoolean(true);
    return 1;
}

fn copyDir(fromDir: fs.Dir, toDir: fs.Dir, overwrite: bool) !void {
    var iter = fromDir.iterate();
    while (try iter.next()) |entry| switch (entry.kind) {
        .file => {
            if (overwrite == false) {
                if (internal_isFile(toDir, entry.name)) {
                    return error.PathAlreadyExists;
                }
            }
            try fromDir.copyFile(entry.name, toDir, entry.name, fs.Dir.CopyFileOptions{});
        },
        .directory => {
            toDir.makeDir(entry.name) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            var toEntryDir = try toDir.openDir(entry.name, fs.Dir.OpenDirOptions{ .access_sub_paths = true, .iterate = true, .no_follow = true });
            defer toEntryDir.close();
            var fromEntryDir = try fromDir.openDir(entry.name, fs.Dir.OpenDirOptions{ .access_sub_paths = true, .iterate = true, .no_follow = true });
            defer fromEntryDir.close();
            try copyDir(fromEntryDir, toEntryDir, overwrite);
        },
        else => {},
    };
}

fn fs_copy(L: *Luau) i32 {
    const fromPath = L.checkString(1);
    const toPath = L.checkString(2);
    const overrite = L.optBoolean(3) orelse false;
    const cwd = std.fs.cwd();
    if (internal_isFile(cwd, fromPath)) {
        if (overrite == false) {
            if (internal_isFile(cwd, toPath)) {
                return outputStatus(L, "PathAlreadyExists");
            }
        }
        cwd.copyFile(fromPath, cwd, toPath, fs.Dir.CopyFileOptions{}) catch |err| switch (err) {
            else => return outputStatus(L, "UnknownError"),
        };
    } else {
        var fromDir = cwd.openDir(fromPath, fs.Dir.OpenDirOptions{
            .iterate = true,
            .access_sub_paths = true,
            .no_follow = true,
        }) catch |err| return outputStatus(L, @errorName(err));
        defer fromDir.close();
        if (overrite == false and internal_isDir(cwd, toPath)) {
            return outputStatus(L, "PathAlreadyExists");
        } else {
            cwd.makeDir(toPath) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return outputStatus(L, "UnknownError"),
            };
        }
        var toDir = cwd.openDir(toPath, fs.Dir.OpenDirOptions{
            .iterate = true,
            .access_sub_paths = true,
            .no_follow = true,
        }) catch |err| return outputStatus(L, @errorName(err));
        defer toDir.close();
        copyDir(fromDir, toDir, overrite) catch |err| return outputStatus(L, @errorName(err));
    }
    L.pushBoolean(true);
    return 1;
}

fn fs_symlink(L: *Luau) i32 {
    if (builtin.os.tag == .windows) {
        return outputStatus(L, "NotSupported");
    }
    const fromPath = L.checkString(1);
    const toPath = L.checkString(2);
    const cwd = std.fs.cwd();
    const isDir = internal_isDir(cwd, fromPath);
    if (!isDir and !internal_isFile(cwd, fromPath)) {
        return outputStatus(L, "FileNotFound");
    }
    const allocator = L.allocator();
    const fullPath = cwd.realpathAlloc(allocator, fromPath) catch |err| return outputStatus(L, @errorName(err));
    defer allocator.free(fullPath);
    cwd.symLink(fullPath, toPath, fs.Dir.SymLinkFlags{ .is_directory = isDir }) catch |err| return outputStatus(L, @errorName(err));
    L.pushBoolean(true);
    return 1;
}

pub fn loadLib(L: *Luau) void {
    L.newTable();

    L.setFieldFn(-1, "readFile", fs_readFile);
    L.setFieldFn(-1, "readDir", fs_readDir);

    L.setFieldFn(-1, "writeFile", fs_writeFile);
    L.setFieldFn(-1, "writeDir", fs_writeDir);

    L.setFieldFn(-1, "removeFile", fs_removeFile);
    L.setFieldFn(-1, "removeDir", fs_removeDir);

    L.setFieldFn(-1, "isFile", fs_isFile);
    L.setFieldFn(-1, "isDir", fs_isDir);

    L.setFieldFn(-1, "metadata", fs_metadata);

    L.setFieldFn(-1, "move", fs_move);

    L.setFieldFn(-1, "copy", fs_copy);

    L.setFieldFn(-1, "symlink", fs_symlink);

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, "@zcore/fs") != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, "@zcore/fs");
    } else L.pop(1);
    L.pop(2);
}

test "Filesystem" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"fs.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
