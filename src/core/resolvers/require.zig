const std = @import("std");
const luau = @import("luau");

const Zune = @import("zune");

const Engine = Zune.Runtime.Engine;
const Scheduler = Zune.Runtime.Scheduler;
const Debugger = Zune.Runtime.Debugger;

const File = Zune.Resolvers.File;
const Navigator = Zune.Resolvers.Navigator;

const VM = luau.VM;

const RequireError = error{
    ModuleNotFound,
    NoAlias,
};

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

const RequireNavigatorContext = struct {
    pub fn getConfigAlloc(a: std.mem.Allocator, path: []const u8) ![]const u8 {
        const cwd = std.fs.cwd();

        if (Zune.STATE.CONFIG_CACHE.get(path)) |cached|
            return try a.dupe(u8, cached);

        const contents = cwd.readFileAlloc(a, path, std.math.maxInt(usize)) catch |err| switch (err) {
            error.AccessDenied, error.FileNotFound => return error.NotPresent,
            else => return err,
        };
        errdefer a.free(contents);

        const copy = try Zune.DEFAULT_ALLOCATOR.dupe(u8, path);
        errdefer Zune.DEFAULT_ALLOCATOR.free(copy);
        const copy_contents = try Zune.DEFAULT_ALLOCATOR.dupe(u8, contents);
        errdefer Zune.DEFAULT_ALLOCATOR.free(copy_contents);

        try Zune.STATE.CONFIG_CACHE.put(copy, copy_contents);

        return contents;
    }
    pub fn resolvePathAlloc(a: std.mem.Allocator, paths: []const []const u8) ![]u8 {
        return try Zune.Resolvers.File.resolve(a, Zune.STATE.ENV_MAP, paths);
    }
};

pub fn getFilePath(source: ?[]const u8) []const u8 {
    if (source) |src|
        if (src.len > 0 and src[0] == '@') {
            const path = src[1..];
            return path;
        };
    return ".";
}

pub fn zune_require(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const scheduler = Scheduler.getScheduler(L);

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

    const cwd = std.fs.cwd();

    const moduleName = L.Lcheckstring(1);
    _ = L.Lfindtable(VM.lua.REGISTRYINDEX, "_MODULES", 1);
    var outErr: ?[]const u8 = null;
    var moduleRelativePath: [:0]const u8 = undefined;

    var err_msg: ?[]const u8 = null;
    defer if (err_msg) |err| allocator.free(err);
    const script_path = Navigator.navigate(allocator, RequireNavigatorContext, getFilePath(ar.source), moduleName, &err_msg) catch |err| switch (err) {
        error.SyntaxError => return L.Zerrorf("{s}", .{err_msg.?}),
        error.AliasNotFound => return L.Zerrorf("{s}", .{err_msg.?}),
        error.PathUnsupported => return L.Zerror("must have either \"@\", \"./\", or \"../\" prefix"),
        else => return err,
    };
    defer allocator.free(script_path);

    const searchResult = try File.findLuauFile(allocator, cwd, script_path);
    defer searchResult.deinit();

    var moduleFileHandle: std.fs.File = undefined;

    switch (searchResult.result) {
        .results => |results| {
            if (results.len > 1) {
                var buf = std.ArrayList(u8).init(allocator);
                defer buf.deinit();
                try buf.appendSlice("module name conflicted.");
                const len = results.len;
                for (results, 1..) |res, i| {
                    if (len == i)
                        try buf.appendSlice("\n└─ ")
                    else
                        try buf.appendSlice("\n├─ ");
                    try buf.appendSlice(res.name);
                }
                L.pushlstring(buf.items);
                return error.RaiseLuauError;
            }

            const result = results[0];
            moduleRelativePath = result.name;
            moduleFileHandle = result.handle;
        },
        .none => return L.Zerrorf("module not found: \"{s}\"", .{script_path}),
    }

    jmp: {
        const moduleType = L.getfield(-1, moduleRelativePath);
        if (moduleType != .Nil) {
            if (moduleType == .LightUserdata) {
                const ptr = L.topointer(-1) orelse unreachable;
                if (ptr == @as(*const anyopaque, @ptrCast(&ErrorState))) {
                    L.pop(1);
                    outErr = "requested module failed to load";
                    break :jmp;
                } else if (ptr == @as(*const anyopaque, @ptrCast(&WaitingState))) {
                    L.pop(1);
                    const res = REQUIRE_QUEUE_MAP.getEntry(moduleRelativePath) orelse std.debug.panic("zune_require: queue not found", .{});
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

        const fileContent = moduleFileHandle.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| switch (err) {
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

        const sourceNameZ = try std.mem.concatWithSentinel(allocator, u8, &.{ "@", moduleRelativePath }, 0);
        defer allocator.free(sourceNameZ);

        Engine.loadModule(ML, sourceNameZ, fileContent, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                L.pop(1); // drop: thread
                outErr = ML.tostring(-1) orelse "UnknownError";
                break :jmp;
            },
        };

        if (comptime Debugger.PlatformSupported()) {
            switch (Zune.STATE.RUN_MODE) {
                .Debug => {
                    @branchHint(.unlikely);
                    const ref = ML.ref(-1) orelse unreachable;
                    const full_path = try cwd.realpathAlloc(allocator, moduleRelativePath);
                    defer allocator.free(full_path);
                    try Debugger.addReference(allocator, ML, full_path, ref);
                },
                else => {},
            }
        }

        L.pushlightuserdata(@ptrCast(&PreloadedState));
        L.setfield(-3, moduleRelativePath);

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
                L.setfield(-3, moduleRelativePath);

                {
                    const path = try allocator.dupeZ(u8, moduleRelativePath);
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

                try REQUIRE_QUEUE_MAP.put(try allocator.dupe(u8, moduleRelativePath), list);

                return L.yield(0);
            }
        }

        ML.xmove(L, 1);
        L.pushvalue(-1);
        L.setfield(-4, moduleRelativePath); // SET: _MODULES[moduleName] = module
    }

    if (outErr != null) {
        L.pushlightuserdata(@ptrCast(&ErrorState));
        L.setfield(-2, moduleRelativePath);
    }

    if (outErr) |err|
        return L.Zerror(err);

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
