const std = @import("std");
const xev = @import("xev").Dynamic;
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

const windowsSupport = struct {
    const windows = std.os.windows;

    const Options = struct {
        accessMode: windows.DWORD,
        shareMode: windows.DWORD = windows.FILE_SHARE_WRITE | windows.FILE_SHARE_READ | windows.FILE_SHARE_DELETE,
        creationDisposition: windows.DWORD,
    };

    fn OpenFile(self: fs.Dir, path: []const u8, opts: Options) fs.File.OpenError!fs.File {
        const path_w = try windows.sliceToPrefixedFileW(self.fd, path);
        const handle = windows.kernel32.CreateFileW(
            path_w.span(),
            opts.accessMode,
            opts.shareMode,
            null,
            opts.creationDisposition,
            windows.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) {
            const err = windows.kernel32.GetLastError();
            return switch (err) {
                .FILE_NOT_FOUND => error.FileNotFound,
                .PATH_NOT_FOUND => error.FileNotFound,
                .INVALID_PARAMETER => unreachable,
                .SHARING_VIOLATION => return error.AccessDenied,
                .ACCESS_DENIED => return error.AccessDenied,
                .PIPE_BUSY => return error.PipeBusy,
                .FILE_EXISTS => return error.PathAlreadyExists,
                .USER_MAPPED_FILE => return error.AccessDenied,
                .INVALID_HANDLE => unreachable,
                .VIRUS_INFECTED, .VIRUS_DELETED => return error.AntivirusInterference,
                else => windows.unexpectedError(err),
            };
        }
        return .{ .handle = handle };
    }
};

fn fs_readFileAsync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const useBuffer = L.Loptboolean(2, false);

    const file: fs.File = switch (comptime builtin.os.tag) {
        .windows => try windowsSupport.OpenFile(fs.cwd(), path, .{
            .accessMode = std.os.windows.GENERIC_READ,
            .creationDisposition = std.os.windows.OPEN_EXISTING,
        }),
        else => try fs.cwd().openFile(path, .{
            .mode = .read_only,
        }),
    };
    errdefer file.close();

    return File.AsyncReadContext.queue(
        L,
        file,
        useBuffer,
        1024,
        luaHelper.MAX_LUAU_SIZE,
        true,
        .File,
        null,
    );
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
    const data = try L.Zcheckvalue([]const u8, 2, null);

    const file: fs.File = switch (comptime builtin.os.tag) {
        .windows => try windowsSupport.OpenFile(fs.cwd(), path, .{
            .accessMode = std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
            .creationDisposition = std.os.windows.OPEN_ALWAYS,
        }),
        else => try fs.cwd().createFile(path, .{}),
    };
    errdefer file.close();

    return File.AsyncWriteContext.queue(L, file, data, true, null);
}

fn fs_writeFileSync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const data = try L.Zcheckvalue([]const u8, 2, null);
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
    L.Zpushvalue(.{
        .createdAt = internal_lossyfloat_time(metadata.created() orelse 0),
        .modifiedAt = internal_lossyfloat_time(metadata.modified()),
        .accessedAt = internal_lossyfloat_time(metadata.accessed()),
        .symlink = isSymlink,
        .size = metadata.size(),
        .kind = @tagName(metadata.kind()),
        .permissions = .{
            .readOnly = metadata.permissions().readOnly(),
        },
    });
}

fn fs_metadata(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    const path = L.Lcheckstring(1);
    const allocator = luau.getallocator(L);
    const buf = try allocator.alloc(u8, 4096);
    defer allocator.free(buf);
    const cwd = std.fs.cwd();
    if (internal_isDir(cwd, path)) {
        var dir = try cwd.openDir(path, fs.Dir.OpenDirOptions{});
        defer dir.close();
        const metadata = try dir.metadata();
        var isLink = builtin.os.tag != .windows;
        if (builtin.os.tag != .windows)
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
        var isLink = builtin.os.tag != .windows;
        if (builtin.os.tag != .windows)
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

    pub fn __index(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        return 0;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
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
                    var count: u32 = 0;
                    var values: [6][]const u8 = undefined;
                    if (item.event.created) {
                        values[count] = "created";
                        count += 1;
                    }
                    if (item.event.modify) {
                        values[count] = "modified";
                        count += 1;
                    }
                    if (item.event.delete) {
                        values[count] = "deleted";
                        count += 1;
                    }
                    if (item.event.rename) {
                        values[count] = "renamed";
                        count += 1;
                    }
                    if (item.event.metadata) {
                        values[count] = "metadata";
                        count += 1;
                    }
                    if (item.event.move_from or item.event.move_to) {
                        values[count] = "moved";
                        count += 1;
                    }
                    thread.createtable(@intCast(count), 0);
                    for (values[0..count], 1..) |value, i| {
                        thread.pushlstring(value);
                        thread.rawseti(-2, @intCast(i));
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
        try L.Zchecktype(2, .Table);
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

    const file: fs.File = switch (comptime builtin.os.tag) {
        .windows => try windowsSupport.OpenFile(fs.cwd(), path, .{
            .accessMode = switch (mode) {
                .read_only => std.os.windows.GENERIC_READ,
                .read_write => std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
                .write_only => std.os.windows.GENERIC_WRITE,
            },
            .creationDisposition = std.os.windows.OPEN_EXISTING,
        }),
        else => try fs.cwd().openFile(path, .{
            .mode = mode,
        }),
    };

    try File.push(L, file, .File, switch (mode) {
        .read_only => .readable,
        .read_write => .readwrite,
        .write_only => .writable,
    });

    return 1;
}

fn fs_createFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);

    var exclusive = false;

    const optsType = L.typeOf(2);
    if (!optsType.isnoneornil()) {
        try L.Zchecktype(2, .Table);
        const modeType = L.getfield(2, "exclusive");
        if (!modeType.isnoneornil()) {
            if (modeType != .Boolean)
                return OpenError.BadExclusive;
            exclusive = L.toboolean(-1);
        }
        L.pop(1);
    }

    const file: fs.File = switch (comptime builtin.os.tag) {
        .windows => try windowsSupport.OpenFile(fs.cwd(), path, .{
            .accessMode = std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
            .creationDisposition = if (exclusive) std.os.windows.CREATE_NEW else std.os.windows.CREATE_ALWAYS,
        }),
        else => try fs.cwd().createFile(path, .{
            .read = true,
            .exclusive = exclusive,
        }),
    };

    try File.push(L, file, .File, .readwrite);

    return 1;
}

fn fs_watch(L: *VM.lua.State) !i32 {
    switch (comptime builtin.os.tag) {
        .windows, .linux, .macos => {},
        else => return error.UnsupportedPlatform,
    }
    const scheduler = Scheduler.getScheduler(L);
    const path = L.Lcheckstring(1);
    try L.Zchecktype(2, .Function);

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

        L.Zsetfieldfn(-1, luau.Metamethods.index, LuaWatch.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaWatch.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    L.createtable(0, 17);

    L.Zsetfieldfn(-1, "createFile", fs_createFile);
    L.Zsetfieldfn(-1, "openFile", fs_openFile);

    L.Zsetfieldfn(-1, "readFile", fs_readFileAsync);
    L.Zsetfieldfn(-1, "readFileSync", fs_readFileSync);
    L.Zsetfieldfn(-1, "readDir", fs_readDir);

    L.Zsetfieldfn(-1, "writeFile", fs_writeFileAsync);
    L.Zsetfieldfn(-1, "writeFileSync", fs_writeFileSync);
    L.Zsetfieldfn(-1, "writeDir", fs_writeDir);

    L.Zsetfieldfn(-1, "removeFile", fs_removeFile);
    L.Zsetfieldfn(-1, "removeDir", fs_removeDir);

    L.Zsetfieldfn(-1, "isFile", fs_isFile);
    L.Zsetfieldfn(-1, "isDir", fs_isDir);

    L.Zsetfieldfn(-1, "metadata", fs_metadata);

    L.Zsetfieldfn(-1, "move", fs_move);

    L.Zsetfieldfn(-1, "copy", fs_copy);

    L.Zsetfieldfn(-1, "symlink", fs_symlink);

    L.Zsetfieldfn(-1, "watch", fs_watch);

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = Watch;
}

test "Filesystem" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/fs.test.luau"),
        &.{},
        true,
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
