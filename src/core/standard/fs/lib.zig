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

fn lua_readFileAsync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const useBuffer = L.Loptboolean(2, false);

    const file: fs.File = switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").OpenFile(fs.cwd(), path, .{
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

fn lua_readFileSync(L: *VM.lua.State) !i32 {
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

fn lua_readDir(L: *VM.lua.State) !i32 {
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

fn lua_writeFileAsync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const data = try L.Zcheckvalue([]const u8, 2, null);

    const file: fs.File = switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").OpenFile(fs.cwd(), path, .{
            .accessMode = std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
            .creationDisposition = std.os.windows.OPEN_ALWAYS,
        }),
        else => try fs.cwd().createFile(path, .{}),
    };
    errdefer file.close();

    return File.AsyncWriteContext.queue(L, file, data, true, 0, .File, null);
}

fn lua_writeFileSync(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const data = try L.Zcheckvalue([]const u8, 2, null);
    try fs.cwd().writeFile(fs.Dir.WriteFileOptions{
        .sub_path = path,
        .data = data,
    });
    return 0;
}

fn lua_writeDir(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    const recursive = L.Loptboolean(2, false);
    const cwd = std.fs.cwd();
    try (if (recursive)
        cwd.makePath(path)
    else
        cwd.makeDir(path));
    return 0;
}

fn lua_removeFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);
    try fs.cwd().deleteFile(path);
    return 0;
}

fn lua_removeDir(L: *VM.lua.State) !i32 {
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

fn lua_isDir(L: *VM.lua.State) i32 {
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

fn lua_metadata(L: *VM.lua.State) !i32 {
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
    } else {
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
    }
    return 1;
}

fn lua_move(L: *VM.lua.State) !i32 {
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
            try fromDir.copyFile(entry.name, toDir, entry.name, .{});
        },
        .directory => {
            toDir.makeDir(entry.name) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            var toEntryDir = try toDir.openDir(entry.name, .{ .access_sub_paths = true, .iterate = true, .no_follow = true });
            defer toEntryDir.close();
            var fromEntryDir = try fromDir.openDir(entry.name, .{ .access_sub_paths = true, .iterate = true, .no_follow = true });
            defer fromEntryDir.close();
            try copyDir(fromEntryDir, toEntryDir, overwrite);
        },
        else => {},
    };
}

fn lua_copy(L: *VM.lua.State) !i32 {
    const fromPath = L.Lcheckstring(1);
    const toPath = L.Lcheckstring(2);
    const override = L.Loptboolean(3, false);
    const cwd = std.fs.cwd();
    if (internal_isDir(cwd, fromPath)) {
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
    } else {
        if (override == false and internal_isFile(cwd, toPath))
            return std.fs.Dir.MakeError.PathAlreadyExists;

        try cwd.copyFile(fromPath, cwd, toPath, fs.Dir.CopyFileOptions{});
    }
    return 0;
}

fn lua_symlink(L: *VM.lua.State) !i32 {
    const fromPath = L.Lcheckstring(1);
    const toPath = L.Lcheckstring(2);
    const cwd = std.fs.cwd();

    const allocator = luau.getallocator(L);

    const fullPath = try cwd.realpathAlloc(allocator, fromPath);
    defer allocator.free(fullPath);

    try cwd.symLink(fullPath, toPath, .{
        // only this applies to windows
        .is_directory = if (comptime builtin.os.tag == .windows)
            internal_isDir(cwd, fromPath)
        else
            false,
    });

    return 0;
}

const LuaWatch = struct {
    instance: Watch.FileSystemWatcher,
    active: bool = true,
    callback: luaHelper.Ref(void),
    ref: luaHelper.Ref(void),

    pub fn __index(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        return 0;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const obj = L.touserdata(LuaWatch, 1) orelse unreachable;

        const namecall = L.namecallstr() orelse return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "stop")) {
            obj.active = false;
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn update(ctx: *LuaWatch, L: *VM.lua.State, _: *Scheduler) Scheduler.TaskResult {
        if (!ctx.active)
            return .Stop;
        const watch = &ctx.instance;

        if (ctx.callback.ref == null)
            return .Stop;

        if (watch.next() catch |err| {
            std.debug.print("LuaWatch error: {}\n", .{err});
            return .Stop;
        }) |info| {
            defer info.deinit();
            for (info.list.items) |item| {
                if (ctx.callback.push(L)) {
                    if (L.typeOf(-1) != .Function) {
                        L.pop(1); // drop callback
                        return .Stop;
                    }
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

    pub fn dtor(ctx: *LuaWatch, L: *VM.lua.State, _: *Scheduler) void {
        ctx.callback.deref(L);
        ctx.ref.deref(L);
        ctx.instance.deinit();
    }
};

fn lua_openFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);

    var mode: fs.File.OpenMode = .read_write;

    const Options = struct {
        mode: ?[:0]const u8 = null,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 2, null) orelse .{};
    if (opts.mode) |m| {
        const has_read = std.mem.indexOfScalar(u8, m, 'r');
        const has_write = std.mem.indexOfScalar(u8, m, 'w');
        if (has_read != null and has_write != null) {
            mode = .read_write;
        } else if (has_read != null) {
            mode = .read_only;
        } else if (has_write != null) {
            mode = .write_only;
        } else return OpenError.InvalidMode;
    }

    const file: fs.File = switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").OpenFile(fs.cwd(), path, .{
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
        .read_only => .readable(.seek_close),
        .read_write => .readwrite(.seek_close),
        .write_only => .writable(.seek_close),
    });

    return 1;
}

fn lua_createFile(L: *VM.lua.State) !i32 {
    const path = L.Lcheckstring(1);

    const Options = struct {
        exclusive: bool = false,
    };
    const opts: Options = try L.Zcheckvalue(?Options, 2, null) orelse .{};

    const file: fs.File = switch (comptime builtin.os.tag) {
        .windows => try @import("../../utils/os/windows.zig").OpenFile(fs.cwd(), path, .{
            .accessMode = std.os.windows.GENERIC_READ | std.os.windows.GENERIC_WRITE,
            .creationDisposition = if (opts.exclusive) std.os.windows.CREATE_NEW else std.os.windows.CREATE_ALWAYS,
        }),
        else => try fs.cwd().createFile(path, .{
            .read = true,
            .exclusive = opts.exclusive,
        }),
    };

    try File.push(L, file, .File, .readwrite(.seek_close));

    return 1;
}

fn lua_watch(L: *VM.lua.State) !i32 {
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

    const ptr = L.newuserdata(LuaWatch);

    if (L.Lgetmetatable(@typeName(LuaWatch)) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Watch Metatable not initialized)", .{});

    ptr.* = .{
        .instance = watch,
        .active = true,
        .callback = .{ .ref = .{ .registry = ref }, .value = undefined },
        .ref = .init(L, -1, undefined),
    };

    scheduler.addTask(LuaWatch, ptr, L, LuaWatch.update, LuaWatch.dtor);

    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Znewmetatable(@typeName(LuaWatch), .{
            .__index = LuaWatch.__index,
            .__namecall = LuaWatch.__namecall,
            .__metatable = "Metatable is locked",
        });
        L.setreadonly(-1, true);
        L.pop(1);
    }

    L.Zpushvalue(.{
        .createFile = lua_createFile,
        .openFile = lua_openFile,
        .readFile = lua_readFileAsync,
        .readFileSync = lua_readFileSync,
        .readDir = lua_readDir,
        .writeFile = lua_writeFileAsync,
        .writeFileSync = lua_writeFileSync,
        .writeDir = lua_writeDir,
        .removeFile = lua_removeFile,
        .removeDir = lua_removeDir,
        .isDir = lua_isDir,
        .metadata = lua_metadata,
        .move = lua_move,
        .copy = lua_copy,
        .symlink = lua_symlink,
        .watch = lua_watch,
    });
    L.setreadonly(-1, true);

    luaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = Watch;
}

test "fs" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/fs.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
