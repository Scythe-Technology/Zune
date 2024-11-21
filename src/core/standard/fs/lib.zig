const std = @import("std");
const builtin = @import("builtin");
const luau = @import("luau");

const Scheduler = @import("../../runtime/scheduler.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const Watch = @import("./watch.zig");

const Luau = luau.Luau;

const fs = std.fs;

const BufferError = error{FailedToCreateBuffer};
const HardwareError = error{NotSupported};
const UnhandledError = error{UnknownError};
const OpenError = error{ InvalidMode, BadExclusive };

pub const LIB_NAME = "fs";

fn fs_readFile(L: *Luau) !i32 {
    const allocator = L.allocator();
    const path = L.checkString(1);
    const useBuffer = L.optBoolean(2) orelse false;
    const data = try fs.cwd().readFileAlloc(allocator, path, luaHelper.MAX_LUAU_SIZE);
    defer allocator.free(data);

    if (useBuffer) {
        L.pushBuffer(data) catch return BufferError.FailedToCreateBuffer;
    } else L.pushLString(data);

    return 1;
}

fn fs_readDir(L: *Luau) !i32 {
    const path = L.checkString(1);
    var dir = try fs.cwd().openDir(path, fs.Dir.OpenDirOptions{
        .iterate = true,
    });
    defer dir.close();
    var iter = dir.iterate();
    L.newTable();
    var i: i32 = 1;
    while (try iter.next()) |entry| {
        L.pushInteger(i);
        L.pushLString(entry.name);
        L.setTable(-3);
        i += 1;
    }
    return 1;
}

fn fs_writeFile(L: *Luau) !i32 {
    const path = L.checkString(1);
    const data = if (L.isBuffer(2)) L.checkBuffer(2) else L.checkString(2);
    try fs.cwd().writeFile(fs.Dir.WriteFileOptions{
        .sub_path = path,
        .data = data,
    });
    return 0;
}

fn fs_writeDir(L: *Luau) !i32 {
    const path = L.checkString(1);
    const recursive = L.optBoolean(2) orelse false;
    const cwd = std.fs.cwd();
    try (if (recursive)
        cwd.makePath(path)
    else
        cwd.makeDir(path));
    return 0;
}

fn fs_removeFile(L: *Luau) !i32 {
    const path = L.checkString(1);
    try fs.cwd().deleteFile(path);
    return 0;
}

fn fs_removeDir(L: *Luau) !i32 {
    const path = L.checkString(1);
    const recursive = L.optBoolean(2) orelse false;
    const cwd = std.fs.cwd();
    try (if (recursive)
        cwd.deleteTree(path)
    else
        cwd.deleteDir(path));
    return 0;
}

fn internal_isDir(srcDir: fs.Dir, path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        var dir = srcDir.openDir(path, fs.Dir.OpenDirOptions{
            .iterate = true,
        }) catch return false;
        defer dir.close();
        return true;
    }
    const stat = srcDir.statFile(path) catch return false;
    return stat.kind == .directory;
}

fn internal_isFile(srcDir: fs.Dir, path: []const u8) bool {
    const stat = srcDir.statFile(path) catch return false;
    return stat.kind == .file;
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
    defer allocator.free(buf);
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
        internal_metadata_table(L, metadata, isLink);
    } else return std.fs.File.OpenError.FileNotFound;
    return 1;
}

fn fs_move(L: *Luau) !i32 {
    const fromPath = L.checkString(1);
    const toPath = L.checkString(2);
    const overwrite = L.optBoolean(3) orelse false;
    const cwd = std.fs.cwd();
    if (overwrite == false) {
        if (internal_isFile(cwd, toPath) or internal_isDir(cwd, toPath))
            return std.fs.Dir.MakeError.PathAlreadyExists;
    }
    try cwd.rename(fromPath, toPath);
    return 0;
}

fn copyDir(fromDir: fs.Dir, toDir: fs.Dir, overwrite: bool) !void {
    var iter = fromDir.iterate();
    while (try iter.next()) |entry| switch (entry.kind) {
        .file => {
            if (overwrite == false and internal_isFile(toDir, entry.name))
                return error.PathAlreadyExists;
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
    const override = L.optBoolean(3) orelse false;
    const cwd = std.fs.cwd();
    if (internal_isFile(cwd, fromPath)) {
        if (override == false and internal_isFile(cwd, toPath))
            return std.fs.Dir.MakeError.PathAlreadyExists;

        cwd.copyFile(fromPath, cwd, toPath, fs.Dir.CopyFileOptions{}) catch return UnhandledError.UnknownError;
    } else {
        var fromDir = try cwd.openDir(fromPath, fs.Dir.OpenDirOptions{
            .iterate = true,
            .access_sub_paths = true,
            .no_follow = true,
        });
        defer fromDir.close();
        if (override == false and internal_isDir(cwd, toPath))
            return std.fs.Dir.MakeError.PathAlreadyExists
        else {
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
        try copyDir(fromDir, toDir, override);
    }
    return 0;
}

fn fs_symlink(L: *Luau) !i32 {
    if (builtin.os.tag == .windows)
        return HardwareError.NotSupported;

    const fromPath = L.checkString(1);
    const toPath = L.checkString(2);
    const cwd = std.fs.cwd();

    const isDir = internal_isDir(cwd, fromPath);
    if (!isDir and !internal_isFile(cwd, fromPath))
        return error.FileNotFound;

    const allocator = L.allocator();

    const fullPath = try cwd.realpathAlloc(allocator, fromPath);
    defer allocator.free(fullPath);

    try cwd.symLink(fullPath, toPath, fs.Dir.SymLinkFlags{ .is_directory = isDir });

    return 0;
}

pub fn prepRefType(comptime luaType: luau.LuaType, L: *luau.Luau, ref: i32) bool {
    if (L.rawGetIndex(luau.REGISTRYINDEX, ref) == luaType) {
        return true;
    }
    L.pop(1);
    return false;
}

const WatchObject = struct {
    instance: Watch.FileSystemWatcher,
    active: bool = true,
    callback: ?i32,

    pub const Lua = struct {
        ptr: ?*WatchObject,
    };
};

const LuaWatch = struct {
    pub const META = "fs_watch_instance";

    pub fn __index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        return 0;
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const obj = L.toUserdata(WatchObject.Lua, 1) catch unreachable;

        const namecall = L.nameCallAtom() catch return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "stop")) {
            if (obj.ptr) |ptr|
                ptr.active = false;
            obj.ptr = null;
        } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn update(ctx: *WatchObject, L: *Luau, _: *Scheduler) Scheduler.TaskResult {
        if (!ctx.active) return .Stop;
        const watch = &ctx.instance;

        const callback = ctx.callback orelse return .Stop;

        if (watch.next() catch |err| {
            std.debug.print("LuaWatch error: {}\n", .{err});
            return .Stop;
        }) |info| {
            defer info.deinit();
            for (info.list.items) |item| {
                if (prepRefType(.function, L, callback)) {
                    const thread = L.newThread();
                    L.xPush(thread, -2); // push: function
                    thread.pushLString(item.name);
                    thread.newTable();
                    var i: i32 = 1;
                    if (item.event.created) {
                        thread.pushString("created");
                        thread.rawSetIndex(-2, i);
                        i += 1;
                    }
                    if (item.event.modify) {
                        thread.pushString("modified");
                        thread.rawSetIndex(-2, i);
                        i += 1;
                    }
                    if (item.event.delete) {
                        thread.pushString("deleted");
                        thread.rawSetIndex(-2, i);
                        i += 1;
                    }
                    if (item.event.rename) {
                        thread.pushString("renamed");
                        thread.rawSetIndex(-2, i);
                        i += 1;
                    }
                    if (item.event.metadata) {
                        thread.pushString("metadata");
                        thread.rawSetIndex(-2, i);
                        i += 1;
                    }
                    if (item.event.move_from or item.event.move_to) {
                        thread.pushString("moved");
                        thread.rawSetIndex(-2, i);
                        i += 1;
                    }
                    L.pop(2); // drop thread, function

                    _ = Scheduler.resumeState(thread, L, 2) catch {};
                }
            }
        }

        return .Continue;
    }

    pub fn dtor(ctx: *WatchObject, L: *Luau, _: *Scheduler) void {
        const allocator = L.allocator();

        defer allocator.destroy(ctx);

        ctx.instance.deinit();
        if (ctx.callback) |ref|
            L.unref(ref);
    }
};

const FileObject = struct {
    handle: fs.File,
    open: bool = true,
};

const LuaFile = struct {
    pub const META = "fs_file_instance";

    pub fn __index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        // const index = L.checkString(2);
        // const file_ptr = L.toUserdata(FileObject, 1) catch return 0;

        return 0;
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        var file_ptr = L.toUserdata(FileObject, 1) catch unreachable;

        const namecall = L.nameCallAtom() catch return 0;

        const allocator = L.allocator();

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "write")) {
            const string = if (L.typeOf(2) == .buffer) L.checkBuffer(2) else L.checkString(2);
            try file_ptr.handle.writeAll(string);
        } else if (std.mem.eql(u8, namecall, "append")) {
            const string = if (L.typeOf(2) == .buffer) L.checkBuffer(2) else L.checkString(2);
            try file_ptr.handle.seekFromEnd(0);
            try file_ptr.handle.writeAll(string);
        } else if (std.mem.eql(u8, namecall, "getSeekPosition")) {
            L.pushInteger(@intCast(try file_ptr.handle.getPos()));
            return 1;
        } else if (std.mem.eql(u8, namecall, "getSize")) {
            L.pushInteger(@intCast(try file_ptr.handle.getEndPos()));
            return 1;
        } else if (std.mem.eql(u8, namecall, "seekFromEnd")) {
            try file_ptr.handle.seekFromEnd(@intCast(L.optInteger(2) orelse 0));
        } else if (std.mem.eql(u8, namecall, "seekTo")) {
            try file_ptr.handle.seekTo(@intCast(L.optInteger(2) orelse 0));
        } else if (std.mem.eql(u8, namecall, "seekBy")) {
            try file_ptr.handle.seekFromEnd(@intCast(L.optInteger(2) orelse 1));
        } else if (std.mem.eql(u8, namecall, "read")) {
            const size = L.optInteger(2) orelse luaHelper.MAX_LUAU_SIZE;
            const data = try file_ptr.handle.readToEndAlloc(allocator, @intCast(size));
            defer allocator.free(data);
            if (L.optBoolean(3) orelse false) try L.pushBuffer(data) else L.pushLString(data);
            return 1;
        } else if (std.mem.eql(u8, namecall, "lock")) {
            var lockOpt: fs.File.Lock = .exclusive;
            if (L.typeOf(2) == .string) {
                const lockType = L.toString(2) catch unreachable;
                if (std.mem.eql(u8, lockType, "shared")) {
                    lockOpt = .shared;
                } else if (!std.mem.eql(u8, lockType, "exclusive")) {
                    lockOpt = .exclusive;
                } else if (!std.mem.eql(u8, lockType, "none")) {
                    lockOpt = .none;
                }
            }
            if (builtin.os.tag == .windows) {
                switch (lockOpt) {
                    .none => {},
                    .shared, .exclusive => {
                        var io_status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
                        const range_off: std.os.windows.LARGE_INTEGER = 0;
                        const range_len: std.os.windows.LARGE_INTEGER = 1;
                        std.os.windows.LockFile(
                            file_ptr.handle.handle,
                            null,
                            null,
                            null,
                            &io_status_block,
                            &range_off,
                            &range_len,
                            null,
                            std.os.windows.FALSE, // non-blocking=false
                            @intFromBool(lockOpt == .exclusive),
                        ) catch |err| switch (err) {
                            error.WouldBlock => unreachable, // non-blocking=false
                            else => |e| return e,
                        };
                    },
                }
                L.pushBoolean(true);
            } else L.pushBoolean(try file_ptr.handle.tryLock(lockOpt));
            return 1;
        } else if (std.mem.eql(u8, namecall, "unlock")) {
            file_ptr.handle.unlock();
        } else if (std.mem.eql(u8, namecall, "sync")) {
            try file_ptr.handle.sync();
        } else if (std.mem.eql(u8, namecall, "readonly")) {
            const meta = try file_ptr.handle.metadata();
            var permissions = meta.permissions();
            const enabled = L.optBoolean(2) orelse {
                L.pushBoolean(permissions.readOnly());
                return 1;
            };
            permissions.setReadOnly(enabled);
            try file_ptr.handle.setPermissions(permissions);
        } else if (std.mem.eql(u8, namecall, "close")) {
            if (file_ptr.open) file_ptr.handle.close();
            file_ptr.open = false;
        } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn __dtor(ptr: *FileObject) void {
        if (ptr.open)
            ptr.handle.close();
        ptr.open = false;
    }
};

fn fs_openFile(L: *Luau) !i32 {
    const path = L.checkString(1);

    var mode: fs.File.OpenMode = .read_write;

    const optsType = L.typeOf(2);
    if (!luau.isNoneOrNil(optsType)) {
        L.checkType(2, .table);
        const modeType = L.getField(2, "mode");
        if (!luau.isNoneOrNil(modeType)) {
            if (modeType != .string) return OpenError.InvalidMode;
            const modeStr = L.toString(-1) catch unreachable;

            const has_read = std.mem.indexOfScalar(u8, modeStr, 'r');
            const has_write = std.mem.indexOfScalar(u8, modeStr, 'w');

            if (has_read != null and has_write != null) {
                mode = .read_write;
            } else if (has_read != null) {
                mode = .read_only;
            } else if (has_write != null) {
                mode = .write_only;
            } else return OpenError.InvalidMode;
        }
        L.pop(1);
    }

    const file = try fs.cwd().openFile(path, .{
        .mode = mode,
    });

    const filePtr = L.newUserdataDtor(FileObject, LuaFile.__dtor);

    filePtr.* = .{
        .handle = file,
        .open = true,
    };

    if (L.getMetatableRegistry(LuaFile.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (File Metatable not initialized)", .{});

    return 1;
}

fn fs_createFile(L: *Luau) !i32 {
    const path = L.checkString(1);

    var exclusive = false;

    const optsType = L.typeOf(2);
    if (!luau.isNoneOrNil(optsType)) {
        L.checkType(2, .table);
        const modeType = L.getField(2, "exclusive");
        if (!luau.isNoneOrNil(modeType)) {
            if (modeType != .boolean)
                return OpenError.BadExclusive;
            exclusive = L.toBoolean(-1);
        }
        L.pop(1);
    }

    const file = try fs.cwd().createFile(path, .{
        .read = true,
        .exclusive = exclusive,
    });

    const filePtr = L.newUserdataDtor(FileObject, LuaFile.__dtor);

    filePtr.* = .{
        .handle = file,
        .open = true,
    };

    if (L.getMetatableRegistry(LuaFile.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (File Metatable not initialized)", .{});

    return 1;
}

fn fs_watch(L: *Luau, scheduler: *Scheduler) !i32 {
    const path = L.checkString(1);
    L.checkType(2, .function);

    const allocator = L.allocator();

    const ref = L.ref(2) catch unreachable;
    errdefer L.unref(ref);

    var dir = fs.cwd().openDir(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.PathNotFound,
    };
    dir.close();

    var watch = Watch.FileSystemWatcher.init(allocator, path);
    errdefer watch.deinit();
    try watch.start();

    const data = try allocator.create(WatchObject);
    errdefer allocator.destroy(data);

    const luaObj = L.newUserdata(WatchObject.Lua);
    luaObj.ptr = data;

    if (L.getMetatableRegistry(LuaWatch.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (Watch Metatable not initialized)", .{});

    data.* = .{
        .instance = watch,
        .active = true,
        .callback = ref,
    };

    scheduler.addTask(WatchObject, data, L, LuaWatch.update, LuaWatch.dtor);

    return 1;
}

pub fn loadLib(L: *Luau) void {
    {
        L.newMetatable(LuaFile.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, LuaFile.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaFile.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    {
        L.newMetatable(LuaWatch.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, LuaWatch.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaWatch.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    L.newTable();

    L.setFieldFn(-1, "createFile", fs_createFile);
    L.setFieldFn(-1, "openFile", fs_openFile);

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

    L.setFieldFn(-1, "watch", Scheduler.toSchedulerEFn(fs_watch));

    luaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = Watch;
}

test "Filesystem" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"fs.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
