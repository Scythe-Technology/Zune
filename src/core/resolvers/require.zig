const std = @import("std");
const luau = @import("luau");

const Zune = @import("../../zune.zig");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");
const Debugger = @import("../runtime/debugger.zig");

const file = @import("file.zig");

const VM = luau.VM;

pub var MODE: RequireMode = .RelativeToFile;

pub var RUN_MODE: Zune.RunMode = .Run;

const RequireMode = enum {
    RelativeToFile,
    RelativeToCwd,
};

const RequireError = error{
    ModuleNotFound,
    NoAlias,
};

pub var ALIASES: std.StringArrayHashMap([]const u8) = std.StringArrayHashMap([]const u8).init(Zune.DEFAULT_ALLOCATOR);

const States = enum {
    Error,
    Waiting,
    Preloaded,
};

var ErrorState = States.Error;
var WaitingState = States.Waiting;
var PreloadedState = States.Preloaded;

const QueueItem = struct {
    state: Scheduler.ThreadRef,
};

var REQUIRE_QUEUE_MAP = std.StringArrayHashMap(std.ArrayList(QueueItem)).init(Zune.DEFAULT_ALLOCATOR);

const RequireContext = struct {
    caller: *VM.lua.State,
    path: [:0]const u8,
};
fn require_finished(ctx: *RequireContext, ML: *VM.lua.State, _: *Scheduler) void {
    var outErr: ?[]const u8 = null;

    const queue = REQUIRE_QUEUE_MAP.getEntry(ctx.path) orelse std.debug.panic("require_finished: queue not found", .{});

    if (ML.status() == .Ok) jmp: {
        const t = ML.gettop();
        if (t > 1 or t < 0) {
            outErr = "module must return one value";
            break :jmp;
        } else if (t == 0)
            ML.pushnil();
    } else outErr = "requested module failed to load";

    _ = ctx.caller.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1);
    if (outErr != null)
        ctx.caller.pushlightuserdata(@ptrCast(&ErrorState))
    else
        ML.xpush(ctx.caller, -1);
    ctx.caller.setfield(-2, ctx.path); // SET: _MODULES[moduleName] = module

    ctx.caller.pop(1); // drop: _MODULES

    for (queue.value_ptr.*.items) |item| {
        const L = item.state.value;
        if (outErr) |msg| {
            L.pushlstring(msg);
            _ = Scheduler.resumeStateError(L, null) catch {};
        } else {
            ML.xpush(L, -1);
            _ = Scheduler.resumeState(L, null, 1) catch {};
        }
    }

    ML.pop(1);
}

fn require_dtor(ctx: *RequireContext, _: *VM.lua.State, _: *Scheduler) void {
    const allocator = luau.getallocator(ctx.caller);
    defer allocator.destroy(ctx);
    defer allocator.free(ctx.path);

    const queue = REQUIRE_QUEUE_MAP.getEntry(ctx.path) orelse return;

    for (queue.value_ptr.items) |*item|
        item.state.deref();
    queue.value_ptr.deinit();
    allocator.free(queue.key_ptr.*);
}

const NonRegularPathSep = if (std.fs.path.sep == std.fs.path.sep_windows) std.fs.path.sep_posix else std.fs.path.sep_windows;
const NonRegularPathSepStr = if (std.fs.path.sep_str == std.fs.path.sep_str_windows) std.fs.path.sep_str_posix else std.fs.path.sep_str_windows;

pub fn zune_require(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    var sourceConst: ?[]const u8 = null;
    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    {
        var level: i32 = 1;
        while (true) : (level += 1) {
            if (!L.getinfo(level, "s", &ar))
                return L.Zerror("could not get source");
            if (ar.what == .lua)
                break;
        }
    }
    sourceConst = ar.source;
    var source: ?[]u8 = null;
    defer if (source) |r| allocator.free(r);

    // normalize source to use unix path seps
    if (sourceConst != null) {
        source = try allocator.alloc(u8, sourceConst.?.len);
        @memcpy(source.?, sourceConst.?);
        _ = std.mem.replace(u8, source.?, "\\", "/", source.?);
    }

    const cwd = std.fs.cwd();

    const moduleName = L.Lcheckstring(1);
    _ = L.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1);
    var outErr: ?[]const u8 = null;
    var moduleRelativePath: [:0]const u8 = undefined;
    var searchResult: ?file.SearchResult([:0]const u8) = null;
    if (moduleName.len == 0)
        return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix");

    // a lot of `.?`. is there a better way to do this?
    const isInit = blk: {
        if (source == null) {
            break :blk false;
        }
        const lastDelimIdxOpt = std.mem.lastIndexOfScalar(u8, source.?, '/');
        if (lastDelimIdxOpt == null) {
            break :blk false;
        }
        const lastDelimIdx = lastDelimIdxOpt.?;
        const fileName = source.?[lastDelimIdx + 1 ..];
        const dotDelimIdxOpt = std.mem.indexOfScalar(u8, fileName, '.');
        if (dotDelimIdxOpt == null) {
            break :blk false;
        }
        const dotDelimIdx = dotDelimIdxOpt.?;
        const sourceName: ?[]const u8 = fileName[0..dotDelimIdx];
        if (sourceName == null) {
            break :blk false;
        }
        break :blk std.mem.eql(u8, sourceName.?, "init");
    };

    var dir_path: []const u8 = "./";
    var opened_dir = false;
    var dir = blk: {
        if (MODE == .RelativeToCwd or (moduleName[0] == '@' and !isInit))
            break :blk cwd;
        if (source) |s| jmp: {
            if (s.len <= 1 or s[0] != '@')
                break :jmp;
            const path = s[1..];
            const dirname = std.fs.path.dirname(path) orelse break :jmp;
            opened_dir = true;
            dir_path = dirname;
            break :blk cwd.openDir(dirname, .{}) catch std.debug.panic("could not open directory: {s}\n  require can not continue", .{dirname});
        }
        break :blk cwd;
    };
    defer if (opened_dir) dir.close();

    var resolvedPath: ?[]u8 = null;

    if (moduleName.len > 2 and moduleName[0] == '@') {
        const delimiter = std.mem.indexOfScalar(u8, moduleName, '/') orelse moduleName.len;
        const alias = moduleName[1..delimiter];

        if (isInit and std.mem.eql(u8, alias, "self")) {
            const actualName = moduleName[delimiter + 1 ..];
            resolvedPath = try std.mem.concat(allocator, u8, &.{ "./", actualName });
        } else {
            const path = ALIASES.get(alias) orelse return RequireError.NoAlias;
            resolvedPath = if (moduleName.len - delimiter > 1)
                try std.fs.path.join(allocator, &.{ path, moduleName[delimiter + 1 ..] })
            else
                try allocator.dupe(u8, path);
        }
    } else {
        const is_sibling = std.mem.startsWith(u8, moduleName, "./");
        const is_parent_sibling = std.mem.startsWith(u8, moduleName, "../");
        if (!is_sibling and !is_parent_sibling)
            return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix");

        if (isInit) {
            const delimiter = std.mem.indexOfScalar(u8, moduleName, '/') orelse moduleName.len;
            const actualName = moduleName[delimiter + 1 ..];

            if (is_sibling) {
                resolvedPath = try std.fs.path.join(allocator, &.{ "..", actualName });
            } else {
                resolvedPath = try std.fs.path.join(allocator, &.{ "..", "..", actualName });
            }
        } else {
            resolvedPath = try std.fs.path.join(allocator, &.{moduleName});
        }
    }

    std.mem.replaceScalar(u8, resolvedPath.?, NonRegularPathSep, std.fs.path.sep);
    searchResult = try file.findLuauFileFromPathZ(allocator, dir, resolvedPath orelse unreachable);

    if (resolvedPath != null and searchResult != null and searchResult.?.result == .none) {
        const directoryInit = try std.fs.path.join(allocator, &.{ resolvedPath.?, "init" });
        const initSearchResult = try file.findLuauFileFromPathZ(allocator, dir, directoryInit);
        if (initSearchResult.result != .none) {
            allocator.free(resolvedPath.?);
            resolvedPath = directoryInit;
            searchResult.?.deinit();
            searchResult = initSearchResult;
        } else {
            allocator.free(directoryInit);
            initSearchResult.deinit();
        }
    }
    defer if (resolvedPath) |r| allocator.free(r);
    defer if (searchResult) |r| r.deinit();

    switch (searchResult.?.result) {
        .exact => |e| moduleRelativePath = e,
        .results => |results| {
            if (results.len > 1) {
                var buf = std.ArrayList(u8).init(allocator);
                defer buf.deinit();
                try buf.appendSlice("module name conflicted.\n");
                for (results) |res| {
                    try buf.appendSlice("\n- ");
                    try buf.appendSlice(res);
                }
                L.pushlstring(buf.items);
                return error.RaiseLuauError;
            }

            moduleRelativePath = results[0];
        },
        .none => return L.Zerrorf("FileNotFound ({s})", .{resolvedPath orelse moduleName}),
    }

    const resolvedModuleRelativePath = try std.fs.path.resolve(allocator, &.{ dir_path, moduleRelativePath });
    defer allocator.free(resolvedModuleRelativePath);

    const resolvedModuleRelativePathZ = try allocator.dupeZ(u8, resolvedModuleRelativePath);
    defer allocator.free(resolvedModuleRelativePathZ);

    jmp: {
        const moduleType = L.getfield(-1, resolvedModuleRelativePathZ);
        if (moduleType != .Nil) {
            if (moduleType == .LightUserdata) {
                const ptr = L.topointer(-1) orelse unreachable;
                if (ptr == @as(*const anyopaque, @ptrCast(&ErrorState))) {
                    L.pop(1);
                    outErr = "requested module failed to load";
                    break :jmp;
                } else if (ptr == @as(*const anyopaque, @ptrCast(&WaitingState))) {
                    L.pop(1);
                    const res = REQUIRE_QUEUE_MAP.getEntry(resolvedModuleRelativePathZ) orelse std.debug.panic("zune_require: queue not found", .{});
                    try res.value_ptr.append(.{
                        .state = Scheduler.ThreadRef.init(L),
                    });
                    return L.yield(0);
                } else if (ptr == @as(*const anyopaque, @ptrCast(&PreloadedState))) {
                    L.pop(1);
                    outErr = "Cyclic dependency detected";
                    break :jmp;
                }
            }
            L.remove(-2); // drop: _MODULES
            return 1;
        }
        L.pop(1); // drop: nil

        const fileContent = dir.readFileAlloc(allocator, moduleRelativePath, std.math.maxInt(usize)) catch |err| switch (err) {
            error.AccessDenied, error.FileNotFound => return err,
            else => {
                std.debug.print("error: {}\n", .{err});
                outErr = "InternalError (Could not read file)";
                break :jmp;
            },
        };
        defer allocator.free(fileContent);

        const GL = L.mainthread();
        const ML = GL.newthread();
        GL.xmove(L, 1);

        ML.Lsandboxthread();

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        Engine.setLuaFileContext(ML, .{
            .source = fileContent,
            .main = true,
        });

        const sourceNameZ = try std.mem.concatWithSentinel(allocator, u8, &.{ "@", resolvedModuleRelativePathZ }, 0);
        defer allocator.free(sourceNameZ);

        Engine.loadModule(ML, sourceNameZ, fileContent, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                L.pop(1); // drop: thread
                outErr = ML.tostring(-1) orelse "UnknownError";
                break :jmp;
            },
        };

        switch (RUN_MODE) {
            .Debug => {
                const ref = ML.ref(-1) orelse unreachable;
                try Debugger.addReference(allocator, ML, resolvedModuleRelativePathZ, ref);
            },
            else => {},
        }

        L.pushlightuserdata(@ptrCast(&PreloadedState));
        L.setfield(-3, resolvedModuleRelativePathZ);

        const resumeStatus: ?VM.lua.Status = Scheduler.resumeState(ML, L, 0) catch {
            L.pop(1); // drop: thread
            outErr = "requested module failed to load";
            break :jmp;
        };
        if (resumeStatus) |status| {
            if (status == .Ok) {
                const t = ML.gettop();
                if (t > 1 or t < 0) {
                    L.pop(1); // drop: thread
                    outErr = "module must return one value";
                    break :jmp;
                } else if (t == 0)
                    ML.pushnil();
            } else if (status == .Yield) {
                L.pushlightuserdata(@ptrCast(&WaitingState));
                L.setfield(-3, resolvedModuleRelativePathZ);

                {
                    const path = try allocator.dupeZ(u8, resolvedModuleRelativePathZ);
                    errdefer allocator.free(path);

                    const ptr = try allocator.create(RequireContext);

                    ptr.* = .{
                        .caller = L,
                        .path = path,
                    };

                    scheduler.awaitResult(RequireContext, ptr, ML, require_finished, require_dtor, .Internal);
                }

                var list = std.ArrayList(QueueItem).init(allocator);
                try list.append(.{
                    .state = Scheduler.ThreadRef.init(L),
                });

                try REQUIRE_QUEUE_MAP.put(try allocator.dupe(u8, resolvedModuleRelativePathZ), list);

                return L.yield(0);
            }
        }

        ML.xmove(L, 1);
        L.pushvalue(-1);
        L.setfield(-4, resolvedModuleRelativePathZ); // SET: _MODULES[moduleName] = module
    }

    if (outErr != null) {
        L.pushlightuserdata(@ptrCast(&ErrorState));
        L.setfield(-2, resolvedModuleRelativePathZ);
    }

    if (outErr) |err| {
        L.pushlstring(err);
        return error.RaiseLuauError;
    }

    return 1;
}

test "require" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("engine/require.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
