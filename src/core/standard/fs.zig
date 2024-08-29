const std = @import("std");
const builtin = @import("builtin");
const luau = @import("luau");

const luaHelper = @import("../utils/luahelper.zig");

const Luau = luau.Luau;

const fs = std.fs;

const BufferError = error{FailedToCreateBuffer};
const HardwareError = error{NotSupported};
const UnhandledError = error{UnknownError};

fn fs_readFile(L: *Luau) !i32 {
    const allocator = L.allocator();
    const path = L.checkString(1);
    const useBuffer = L.optBoolean(2) orelse false;
    const data = try fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(data);
    L.pushBoolean(true);
    if (useBuffer) {
        const buf: []u8 = L.newBuffer(data.len) catch return BufferError.FailedToCreateBuffer;
        @memcpy(buf, data);
    } else {
        L.pushLString(data);
    }
    return 2;
}

fn fs_readDir(L: *Luau) !i32 {
    const path = L.checkString(1);
    var dir = try fs.cwd().openDir(path, fs.Dir.OpenDirOptions{
        .iterate = true,
    });
    defer dir.close();
    var iter = dir.iterate();
    L.pushBoolean(true);
    L.newTable();
    var i: i32 = 1;
    while (true) {
        errdefer L.pop(2); // Drop: table, boolean
        const entry = try iter.next();
        if (entry == null) break;
        L.pushInteger(i);
        L.pushLString(entry.?.name);
        L.setTable(-3);
        i += 1;
    }
    return 2;
}

fn fs_writeFile(L: *Luau) !i32 {
    const path = L.checkString(1);
    const data = if (L.isBuffer(2)) L.checkBuffer(2) else L.checkString(2);
    try fs.cwd().writeFile(fs.Dir.WriteFileOptions{
        .sub_path = path,
        .data = data,
    });
    L.pushBoolean(true);
    return 1;
}

fn fs_writeDir(L: *Luau) !i32 {
    const path = L.checkString(1);
    const recursive = L.optBoolean(2) orelse false;
    const cwd = std.fs.cwd();
    try (if (recursive) cwd.makePath(path) else cwd.makeDir(path));
    L.pushBoolean(true);
    return 1;
}

fn fs_removeFile(L: *Luau) !i32 {
    const path = L.checkString(1);
    try fs.cwd().deleteFile(path);
    L.pushBoolean(true);
    return 1;
}

fn fs_removeDir(L: *Luau) !i32 {
    const path = L.checkString(1);
    const recursive = L.optBoolean(2) orelse false;
    const cwd = std.fs.cwd();
    try (if (recursive) cwd.deleteTree(path) else cwd.deleteDir(path));
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

fn fs_metadata(L: *Luau) !i32 {
    const path = L.checkString(1);
    const allocator = L.allocator();
    const buf = try allocator.alloc(u8, 4096);
    const cwd = std.fs.cwd();
    if (internal_isDir(cwd, path)) {
        var dir = try cwd.openDir(path, fs.Dir.OpenDirOptions{});
        defer dir.close();
        const metadata = try dir.metadata();
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
        var file = try cwd.openFile(path, fs.File.OpenFlags{
            .mode = .read_only,
        });
        defer file.close();
        const metadata = try file.metadata();
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

        return std.fs.File.OpenError.FileNotFound;
    }
    return 2;
}

fn fs_move(L: *Luau) !i32 {
    const fromPath = L.checkString(1);
    const toPath = L.checkString(2);
    const overwrite = L.optBoolean(3) orelse false;
    const cwd = std.fs.cwd();
    if (overwrite == false) {
        if (internal_isFile(cwd, toPath) or internal_isDir(cwd, toPath)) return std.fs.Dir.MakeError.PathAlreadyExists;
    }
    try cwd.rename(fromPath, toPath);
    L.pushBoolean(true);
    return 1;
}

fn copyDir(fromDir: fs.Dir, toDir: fs.Dir, overwrite: bool) !void {
    var iter = fromDir.iterate();
    while (try iter.next()) |entry| switch (entry.kind) {
        .file => {
            if (overwrite == false and internal_isFile(toDir, entry.name)) return error.PathAlreadyExists;
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

fn fs_copy(L: *Luau) !i32 {
    const fromPath = L.checkString(1);
    const toPath = L.checkString(2);
    const overrite = L.optBoolean(3) orelse false;
    const cwd = std.fs.cwd();
    if (internal_isFile(cwd, fromPath)) {
        if (overrite == false and internal_isFile(cwd, toPath)) return std.fs.Dir.MakeError.PathAlreadyExists;

        cwd.copyFile(fromPath, cwd, toPath, fs.Dir.CopyFileOptions{}) catch return UnhandledError.UnknownError;
    } else {
        var fromDir = try cwd.openDir(fromPath, fs.Dir.OpenDirOptions{
            .iterate = true,
            .access_sub_paths = true,
            .no_follow = true,
        });
        defer fromDir.close();
        if (overrite == false and internal_isDir(cwd, toPath)) return std.fs.Dir.MakeError.PathAlreadyExists else {
            cwd.makeDir(toPath) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return UnhandledError.UnknownError,
            };
        }
        var toDir = try cwd.openDir(toPath, fs.Dir.OpenDirOptions{
            .iterate = true,
            .access_sub_paths = true,
            .no_follow = true,
        });
        defer toDir.close();
        try copyDir(fromDir, toDir, overrite);
    }
    L.pushBoolean(true);
    return 1;
}

fn fs_symlink(L: *Luau) !i32 {
    if (builtin.os.tag == .windows) return HardwareError.NotSupported;

    const fromPath = L.checkString(1);
    const toPath = L.checkString(2);
    const cwd = std.fs.cwd();

    const isDir = internal_isDir(cwd, fromPath);
    if (!isDir and !internal_isFile(cwd, fromPath)) return error.FileNotFound;

    const allocator = L.allocator();

    const fullPath = try cwd.realpathAlloc(allocator, fromPath);
    defer allocator.free(fullPath);

    try cwd.symLink(fullPath, toPath, fs.Dir.SymLinkFlags{ .is_directory = isDir });
    L.pushBoolean(true);

    return 1;
}

pub fn loadLib(L: *Luau) void {
    L.newTable();

    L.setFieldFn(-1, "readFile", luaHelper.toSafeZigFunction(fs_readFile));
    L.setFieldFn(-1, "readDir", luaHelper.toSafeZigFunction(fs_readDir));

    L.setFieldFn(-1, "writeFile", luaHelper.toSafeZigFunction(fs_writeFile));
    L.setFieldFn(-1, "writeDir", luaHelper.toSafeZigFunction(fs_writeDir));

    L.setFieldFn(-1, "removeFile", luaHelper.toSafeZigFunction(fs_removeFile));
    L.setFieldFn(-1, "removeDir", luaHelper.toSafeZigFunction(fs_removeDir));

    L.setFieldFn(-1, "isFile", fs_isFile);
    L.setFieldFn(-1, "isDir", fs_isDir);

    L.setFieldFn(-1, "metadata", luaHelper.toSafeZigFunction(fs_metadata));

    L.setFieldFn(-1, "move", luaHelper.toSafeZigFunction(fs_move));

    L.setFieldFn(-1, "copy", luaHelper.toSafeZigFunction(fs_copy));

    L.setFieldFn(-1, "symlink", luaHelper.toSafeZigFunction(fs_symlink));

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
