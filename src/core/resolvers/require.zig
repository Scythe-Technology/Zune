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

pub const POSSIBLE_EXTENSIONS = [_][]const u8{
    ".luau",
    ".lua",
    "/init.luau",
    "/init.lua",
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
    state: Scheduler.LuauPair,
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
        const L, _ = item.state;
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
    defer allocator.free(ctx.path);

    const queue = REQUIRE_QUEUE_MAP.getEntry(ctx.path) orelse return;

    for (queue.value_ptr.items) |item|
        Scheduler.derefThread(item.state);
    queue.value_ptr.deinit();
    allocator.free(queue.key_ptr.*);
}

pub fn zune_require(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

    const moduleName = L.Lcheckstring(1);
    _ = L.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1);
    var outErr: ?[]const u8 = null;
    var moduleAbsolutePath: [:0]const u8 = undefined;
    var searchResult: ?file.SearchResult([:0]const u8) = null;
    defer if (searchResult) |r| r.deinit();
    if (moduleName.len == 0)
        return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix");

    const absPath = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(absPath);

    if (moduleName.len > 2 and moduleName[0] == '@') {
        const delimiter = std.mem.indexOfScalar(u8, moduleName, '/') orelse moduleName.len;
        const alias = moduleName[1..delimiter];
        const path = ALIASES.get(alias) orelse return RequireError.NoAlias;
        const modulePath = if (moduleName.len - delimiter > 1)
            try std.fs.path.join(allocator, &.{ path, moduleName[delimiter + 1 ..] })
        else
            try allocator.dupe(u8, path);
        defer allocator.free(modulePath);

        searchResult = try Engine.findLuauFileFromPathZ(allocator, absPath, modulePath);
    } else {
        if ((moduleName.len < 2 or !std.mem.eql(u8, moduleName[0..2], "./")) and (moduleName.len < 3 or !std.mem.eql(u8, moduleName[0..3], "../")))
            return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix");
        if (L.getfield(VM.lua.upvalueindex(1), "_FILE") != .Table)
            return L.Zerror("InternalError (_FILE is invalid)");
        if (L.getfield(-1, "path") != .String)
            return L.Zerror("InternalError (_FILE.path is not a string)");
        const moduleFilePath = L.tostring(-1) orelse unreachable;
        L.pop(2); // drop: path, _FILE
        if (!std.fs.path.isAbsolute(moduleFilePath))
            return L.Zerror("InternalError (_FILE.path is not absolute)");

        switch (MODE) {
            .RelativeToFile => {
                const relativeDirPath = std.fs.path.dirname(moduleFilePath) orelse return error.FileNotFound;

                searchResult = try Engine.findLuauFileFromPathZ(allocator, relativeDirPath, moduleName);
            },
            .RelativeToCwd => searchResult = try Engine.findLuauFileFromPathZ(allocator, absPath, moduleName),
        }
    }

    switch (searchResult.?.result) {
        .exact => |e| moduleAbsolutePath = e,
        .results => |results| {
            if (results.len > 1) {
                var buf = std.ArrayList(u8).init(allocator);
                defer buf.deinit();
                try buf.appendSlice("module name conflicted.\n");
                for (results) |res| {
                    const relative = try std.fs.path.relative(allocator, absPath, res);
                    defer allocator.free(relative);
                    try buf.appendSlice("\n- ");
                    try buf.appendSlice(relative);
                }
                L.pushlstring(buf.items);
                return error.RaiseLuauError;
            }
            moduleAbsolutePath = results[0];
        },
        .none => return error.FileNotFound,
    }

    jmp: {
        const moduleType = L.getfield(-1, moduleAbsolutePath);
        if (moduleType != .Nil) {
            if (moduleType == .LightUserdata) {
                const ptr = L.topointer(-1) orelse unreachable;
                if (ptr == @as(*const anyopaque, @ptrCast(&ErrorState))) {
                    L.pop(1);
                    outErr = "requested module failed to load";
                    break :jmp;
                } else if (ptr == @as(*const anyopaque, @ptrCast(&WaitingState))) {
                    L.pop(1);
                    const res = REQUIRE_QUEUE_MAP.getEntry(moduleAbsolutePath) orelse std.debug.panic("zune_require: queue not found", .{});
                    try res.value_ptr.append(.{
                        .state = Scheduler.refThread(L),
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

        const cwdDirPath = std.fs.cwd().realpathAlloc(allocator, ".") catch return error.FileNotFound;
        defer allocator.free(cwdDirPath);

        const relativeDirPath = std.fs.path.dirname(moduleAbsolutePath) orelse return error.FileNotFound;

        var relativeDir = std.fs.openDirAbsolute(relativeDirPath, std.fs.Dir.OpenDirOptions{}) catch |err| switch (err) {
            error.AccessDenied, error.FileNotFound => return err,
            else => {
                std.debug.print("error: {}\n", .{err});
                outErr = "InternalError (Could not open directory)";
                break :jmp;
            },
        };
        defer relativeDir.close();

        const fileContent = relativeDir.readFileAlloc(allocator, moduleAbsolutePath, std.math.maxInt(usize)) catch |err| switch (err) {
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

        load_require(ML);

        ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

        const moduleRelativeName = try std.fs.path.relative(allocator, cwdDirPath, moduleAbsolutePath);
        defer allocator.free(moduleRelativeName);

        Engine.setLuaFileContext(ML, .{
            .path = moduleAbsolutePath,
            .name = moduleRelativeName,
            .source = fileContent,
        });

        const sourceNameZ = try std.mem.joinZ(allocator, "", &.{ "@", moduleAbsolutePath });
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
                try Debugger.addReference(allocator, ML, moduleAbsolutePath, ref);
            },
            else => {},
        }

        L.pushlightuserdata(@ptrCast(&PreloadedState));
        L.setfield(-3, moduleAbsolutePath);

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
                L.setfield(-3, moduleAbsolutePath);

                {
                    const path = try allocator.dupeZ(u8, moduleAbsolutePath);
                    errdefer allocator.free(path);

                    _ = scheduler.awaitResult(RequireContext, .{
                        .path = path,
                        .caller = L,
                    }, ML, require_finished, require_dtor, .Internal);
                }

                var list = std.ArrayList(QueueItem).init(allocator);
                try list.append(.{
                    .state = Scheduler.refThread(L),
                });

                try REQUIRE_QUEUE_MAP.put(try allocator.dupe(u8, moduleAbsolutePath), list);

                return L.yield(0);
            }
        }

        ML.xmove(L, 1);
        L.pushvalue(-1);
        L.setfield(-4, moduleAbsolutePath); // SET: _MODULES[moduleName] = module
    }

    if (outErr != null) {
        L.pushlightuserdata(@ptrCast(&ErrorState));
        L.setfield(-2, moduleAbsolutePath);
    }

    if (outErr) |err| {
        L.pushlstring(err);
        return error.RaiseLuauError;
    }

    return 1;
}

pub fn load_require(L: *VM.lua.State) void {
    L.pushvalue(VM.lua.GLOBALSINDEX);
    L.pushcclosure(VM.zapi.toCFn(zune_require), "require", 1);
    L.setglobal("require");
}

test "Require" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"require.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
