const std = @import("std");
const aio = @import("aio");
const luau = @import("luau");
const builtin = @import("builtin");

const Scheduler = @import("../../runtime/scheduler.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const File = @import("../../objects/filesystem/File.zig");

const Watch = @import("./watch.zig");

const VM = luau.VM;

const fs = std.fs;

const BufferError = error{FailedToCreateBuffer};
const HardwareError = error{NotSupported};
const UnhandledError = error{UnknownError};
const OpenError = error{ InvalidMode, BadExclusive };

pub const LIB_NAME = "fs";

fn fs_readFileAsync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const useBuffer = L.Loptboolean(2, false);

    const file = try fs.cwd().openFile(path, .{
        .mode = .read_only,
    });
    errdefer file.close();

    return File.ReadAsyncContext.queue(L, file, useBuffer, 1024, luaHelper.MAX_LUAU_SIZE, true);
}

fn fs_readFileSync(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const path = L.Lcheckstring(1);
    const useBuffer = L.Loptboolean(2, false);
    const data = try fs.cwd().readFileAlloc(allocator, path, luaHelper.MAX_LUAU_SIZE);
    defer allocator.free(data);

    if (useBuffer)
        L.Zpushbuffer(data)
    else
        L.pushlstring(data);

    return 1;
}

fn fs_readDir(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    var dir = try fs.cwd().openDir(path, fs.Dir.OpenDirOptions{
        .iterate = true,
    });
    defer dir.close();
    var iter = dir.iterate();
    L.newtable();
    var i: i32 = 1;
    while (try iter.next()) |entry| {
        L.pushinteger(i);
        L.pushlstring(entry.name);
        L.settable(-3);
        i += 1;
    }
    return 1;
}

fn fs_writeFileAsync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const data = if (L.isbuffer(2)) L.Lcheckbuffer(2) else L.Lcheckstring(2);

    const file = try fs.cwd().createFile(path, .{});
    errdefer file.close();

    return File.WriteAsyncContext.queue(L, file, data, true, 0);
}

fn fs_writeFileSync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const data = if (L.isbuffer(2)) L.Lcheckbuffer(2) else L.Lcheckstring(2);
    try fs.cwd().writeFile(fs.Dir.WriteFileOptions{
        .sub_path = path,
        .data = data,
    });
    return 0;
}

fn fs_writeDir(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const recursive = L.Loptboolean(2, false);
    const cwd = std.fs.cwd();
    try (if (recursive)
        cwd.makePath(path)
    else
        cwd.makeDir(path));
    return 0;
}

fn fs_removeFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    try fs.cwd().deleteFile(path);
    return 0;
}

fn fs_removeDir(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const recursive = L.Loptboolean(2, false);
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

fn fs_isFile(L: *VM.lua.State) i32 {
    const path = L.Lcheckstring(1);
    L.pushboolean(internal_isFile(fs.cwd(), path));
    return 1;
}

fn fs_isDir(L: *VM.lua.State) i32 {
    const path = L.Lcheckstring(1);
    L.pushboolean(internal_isDir(fs.cwd(), path));
    return 1;
}

fn internal_lossyfloat_time(n: i128) f64 {
    return @as(f64, @floatFromInt(n)) / 1_000_000_000.0;
}

fn internal_metadata_table(L: *VM.lua.State, metadata: fs.File.Metadata, isSymlink: bool) void {
    L.newtable();
    L.Zsetfield(-1, "createdAt", internal_lossyfloat_time(metadata.created() orelse 0));
    L.Zsetfield(-1, "modifiedAt", internal_lossyfloat_time(metadata.modified()));
    L.Zsetfield(-1, "accessedAt", internal_lossyfloat_time(metadata.accessed()));
    L.Zsetfield(-1, "symlink", isSymlink);
    L.Zsetfield(-1, "size", metadata.size());
    switch (metadata.kind()) {
        .file => L.Zsetfieldc(-1, "kind", "file"),
        .directory => L.Zsetfieldc(-1, "kind", "dir"),
        .sym_link => L.Zsetfieldc(-1, "kind", "symlink"),
        .door => L.Zsetfieldc(-1, "kind", "door"),
        .character_device => L.Zsetfieldc(-1, "kind", "character_device"),
        .unix_domain_socket => L.Zsetfieldc(-1, "kind", "unix_domain_socket"),
        .block_device => L.Zsetfieldc(-1, "kind", "block_device"),
        .event_port => L.Zsetfieldc(-1, "kind", "event_port"),
        .named_pipe => L.Zsetfieldc(-1, "kind", "named_pipe"),
        .whiteout => L.Zsetfieldc(-1, "kind", "whiteout"),
        .unknown => L.Zsetfieldc(-1, "kind", "unknown"),
    }

    L.newtable();
    const perms = metadata.permissions();
    L.Zsetfield(-1, "readOnly", perms.readOnly());

    L.setfield(-2, "permissions");
}

fn fs_metadata(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const allocator = luau.getallocator(L);
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

fn fs_move(L: *VM.lua.State) !i32 {
    const fromPath = L.Lcheckstring(1);
    const toPath = L.Lcheckstring(2);
    const overwrite = L.Loptboolean(3, false);
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

fn fs_copy(L: *VM.lua.State) !i32 {
    const fromPath = L.Lcheckstring(1);
    const toPath = L.Lcheckstring(2);
    const override = L.Loptboolean(3, false);
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

fn fs_symlink(L: *VM.lua.State) !i32 {
    if (builtin.os.tag == .windows)
        return HardwareError.NotSupported;

    const fromPath = L.Lcheckstring(1);
    const toPath = L.Lcheckstring(2);
    const cwd = std.fs.cwd();

    const isDir = internal_isDir(cwd, fromPath);
    if (!isDir and !internal_isFile(cwd, fromPath))
        return error.FileNotFound;

    const allocator = luau.getallocator(L);

    const fullPath = try cwd.realpathAlloc(allocator, fromPath);
    defer allocator.free(fullPath);

    try cwd.symLink(fullPath, toPath, fs.Dir.SymLinkFlags{ .is_directory = isDir });

    return 0;
}

pub fn prepRefType(comptime luaType: VM.lua.Type, L: *VM.lua.State, ref: i32) bool {
    if (L.rawgeti(VM.lua.REGISTRYINDEX, ref) == luaType) {
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

    pub fn __index(L: *VM.lua.State) i32 {
        L.Lchecktype(1, .Userdata);
        return 0;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        L.Lchecktype(1, .Userdata);
        const obj = L.touserdata(WatchObject.Lua, 1) orelse unreachable;

        const namecall = L.namecallstr() orelse return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "stop")) {
            if (obj.ptr) |ptr|
                ptr.active = false;
            obj.ptr = null;
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn update(ctx: *WatchObject, L: *VM.lua.State, _: *Scheduler) Scheduler.TaskResult {
        if (!ctx.active) return .Stop;
        const watch = &ctx.instance;

        const callback = ctx.callback orelse return .Stop;

        if (watch.next() catch |err| {
            std.debug.print("LuaWatch error: {}\n", .{err});
            return .Stop;
        }) |info| {
            defer info.deinit();
            for (info.list.items) |item| {
                if (prepRefType(.Function, L, callback)) {
                    const thread = L.newthread();
                    L.xpush(thread, -2); // push: function
                    thread.pushlstring(item.name);
                    thread.newtable();
                    var i: i32 = 1;
                    if (item.event.created) {
                        thread.pushstring("created");
                        thread.rawseti(-2, i);
                        i += 1;
                    }
                    if (item.event.modify) {
                        thread.pushstring("modified");
                        thread.rawseti(-2, i);
                        i += 1;
                    }
                    if (item.event.delete) {
                        thread.pushstring("deleted");
                        thread.rawseti(-2, i);
                        i += 1;
                    }
                    if (item.event.rename) {
                        thread.pushstring("renamed");
                        thread.rawseti(-2, i);
                        i += 1;
                    }
                    if (item.event.metadata) {
                        thread.pushstring("metadata");
                        thread.rawseti(-2, i);
                        i += 1;
                    }
                    if (item.event.move_from or item.event.move_to) {
                        thread.pushstring("moved");
                        thread.rawseti(-2, i);
                        i += 1;
                    }
                    L.pop(2); // drop thread, function

                    _ = Scheduler.resumeState(thread, L, 2) catch {};
                }
            }
        }

        return .Continue;
    }

    pub fn dtor(ctx: *WatchObject, L: *VM.lua.State, _: *Scheduler) void {
        const allocator = luau.getallocator(L);

        defer allocator.destroy(ctx);

        ctx.instance.deinit();
        if (ctx.callback) |ref|
            L.unref(ref);
    }
};

fn fs_openFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);

    var mode: fs.File.OpenMode = .read_write;

    const optsType = L.typeOf(2);
    if (!optsType.isnoneornil()) {
        L.Lchecktype(2, .Table);
        const modeType = L.getfield(2, "mode");
        if (!modeType.isnoneornil()) {
            if (modeType != .String) return OpenError.InvalidMode;
            const modeStr = L.tostring(-1) orelse unreachable;

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

    File.pushFile(L, file, .File);

    return 1;
}

fn fs_createFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);

    var exclusive = false;

    const optsType = L.typeOf(2);
    if (!optsType.isnoneornil()) {
        L.Lchecktype(2, .Table);
        const modeType = L.getfield(2, "exclusive");
        if (!modeType.isnoneornil()) {
            if (modeType != .Boolean)
                return OpenError.BadExclusive;
            exclusive = L.toboolean(-1);
        }
        L.pop(1);
    }

    const file = try fs.cwd().createFile(path, .{
        .read = true,
        .exclusive = exclusive,
    });

    File.pushFile(L, file, .File);

    return 1;
}

fn fs_watch(L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);
    const path = L.Lcheckstring(1);
    L.Lchecktype(2, .Function);

    const allocator = luau.getallocator(L);

    const ref = L.ref(2) orelse unreachable;
    errdefer L.unref(ref);

    var dir = fs.cwd().openDir(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.PathNotFound,
    };
    dir.close();

    var watch = Watch.FileSystemWatcher.init(allocator, fs.cwd(), path);
    errdefer watch.deinit();
    try watch.start();

    const data = try allocator.create(WatchObject);
    errdefer allocator.destroy(data);

    const luaObj = L.newuserdata(WatchObject.Lua);
    luaObj.ptr = data;

    if (L.Lgetmetatable(LuaWatch.META) == .Table)
        _ = L.setmetatable(-2)
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

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Lnewmetatable(LuaWatch.META);

        L.Zsetfieldc(-1, luau.Metamethods.index, LuaWatch.__index); // metatable.__index
        L.Zsetfieldc(-1, luau.Metamethods.namecall, LuaWatch.__namecall); // metatable.__namecall

        L.Zsetfieldc(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    L.newtable();

    L.Zsetfieldc(-1, "createFile", fs_createFile);
    L.Zsetfieldc(-1, "openFile", fs_openFile);

    L.Zsetfieldc(-1, "readFile", fs_readFileAsync);
    L.Zsetfieldc(-1, "readFileSync", fs_readFileSync);
    L.Zsetfieldc(-1, "readDir", fs_readDir);

    L.Zsetfieldc(-1, "writeFile", fs_writeFileAsync);
    L.Zsetfieldc(-1, "writeFileSync", fs_writeFileSync);
    L.Zsetfieldc(-1, "writeDir", fs_writeDir);

    L.Zsetfieldc(-1, "removeFile", fs_removeFile);
    L.Zsetfieldc(-1, "removeDir", fs_removeDir);

    L.Zsetfieldc(-1, "isFile", fs_isFile);
    L.Zsetfieldc(-1, "isDir", fs_isDir);

    L.Zsetfieldc(-1, "metadata", fs_metadata);

    L.Zsetfieldc(-1, "move", fs_move);

    L.Zsetfieldc(-1, "copy", fs_copy);

    L.Zsetfieldc(-1, "symlink", fs_symlink);

    L.Zsetfieldc(-1, "watch", fs_watch);

    L.setreadonly(-1, true);
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
