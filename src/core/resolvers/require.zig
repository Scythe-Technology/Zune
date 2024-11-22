const std = @import("std");
const luau = @import("luau");

const Zune = @import("../../zune.zig");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const file = @import("file.zig");

const Luau = luau.Luau;

pub var MODE: RequireMode = .RelativeToFile;

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
    state: *Luau,
    ref: ?i32,
};

var REQUIRE_QUEUE_MAP = std.StringArrayHashMap(std.ArrayList(QueueItem)).init(Zune.DEFAULT_ALLOCATOR);

const RequireContext = struct {
    caller: *Luau,
    path: [:0]const u8,
};
fn require_finished(ctx: *RequireContext, ML: *Luau, _: *Scheduler) void {
    const allocator = ctx.caller.allocator();
    defer allocator.free(ctx.path);

    var outErr: ?[]const u8 = null;

    const queue = REQUIRE_QUEUE_MAP.getEntry(ctx.path) orelse std.debug.panic("require_finished: queue not found", .{});
    defer {
        for (queue.value_ptr.items) |item|
            Scheduler.derefThread(item.state, item.ref);
        queue.value_ptr.deinit();
        allocator.free(queue.key_ptr.*);
    }

    if (ML.status() == .ok) jmp: {
        const t = ML.getTop();
        if (t > 1 or t < 0) {
            outErr = "module must return one value";
            break :jmp;
        } else if (t == 0)
            ML.pushNil();
    } else outErr = "requested module failed to load";

    _ = ctx.caller.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (outErr != null)
        ctx.caller.pushLightUserdata(@ptrCast(&ErrorState))
    else
        ML.xPush(ctx.caller, -1);
    ctx.caller.setField(-2, ctx.path); // SET: _MODULES[moduleName] = module

    ctx.caller.pop(1); // drop: _MODULES

    for (queue.value_ptr.*.items) |item| {
        const L = item.state;
        if (outErr) |msg| {
            L.pushLString(msg);
            _ = Scheduler.resumeStateError(L, null) catch {};
        } else {
            ML.xPush(L, -1);
            _ = Scheduler.resumeState(L, null, 1) catch {};
        }
    }

    ML.pop(1);
}

pub fn zune_require(L: *Luau, scheduler: *Scheduler) !i32 {
    const allocator = L.allocator();
    const moduleName = L.checkString(1);
    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    var outErr: ?[]const u8 = null;
    var moduleAbsolutePath: [:0]const u8 = undefined;
    var searchResult: ?file.SearchResult([:0]const u8) = null;
    defer if (searchResult) |r| r.deinit();
    if (moduleName.len == 0)
        return L.Error("must have either \"@\", \"./\", or \"../\" prefix");

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
            return L.Error("must have either \"@\", \"./\", or \"../\" prefix");
        if (L.getField(luau.GLOBALSINDEX, "_FILE") != .table)
            return L.Error("InternalError (_FILE is invalid)");
        if (L.getField(-1, "path") != .string)
            return L.Error("InternalError (_FILE.path is not a string)");
        const moduleFilePath = L.toString(-1) catch unreachable;
        L.pop(2); // drop: path, _FILE
        if (!std.fs.path.isAbsolute(moduleFilePath))
            return L.Error("InternalError (_FILE.path is not absolute)");

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
                L.pushLString(buf.items);
                return error.RaiseLuauError;
            }
            moduleAbsolutePath = results[0];
        },
        .none => return error.FileNotFound,
    }

    jmp: {
        const moduleType = L.getField(-1, moduleAbsolutePath);
        if (moduleType != .nil) {
            if (moduleType == .light_userdata) {
                const ptr = L.toPointer(-1) catch unreachable;
                if (ptr == @as(*const anyopaque, @ptrCast(&ErrorState))) {
                    L.pop(1);
                    outErr = "requested module failed to load";
                    break :jmp;
                } else if (ptr == @as(*const anyopaque, @ptrCast(&WaitingState))) {
                    L.pop(1);
                    const res = REQUIRE_QUEUE_MAP.getEntry(moduleAbsolutePath) orelse std.debug.panic("zune_require: queue not found", .{});
                    try res.value_ptr.append(.{
                        .state = L,
                        .ref = Scheduler.refThread(L),
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

        const GL = L.getMainThread();
        const ML = GL.newThread();
        GL.xMove(L, 1);

        ML.sandboxThread();

        const moduleRelativeName = try std.fs.path.relative(allocator, cwdDirPath, moduleAbsolutePath);
        defer allocator.free(moduleRelativeName);

        Engine.setLuaFileContext(ML, .{
            .path = moduleAbsolutePath,
            .name = moduleRelativeName,
            .source = fileContent,
        });

        const moduleRelativeNameZ = try allocator.dupeZ(u8, moduleRelativeName);
        defer allocator.free(moduleRelativeNameZ);

        Engine.loadModule(ML, moduleRelativeNameZ, fileContent, null) catch |err| switch (err) {
            error.Memory, error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                L.pop(1); // drop: thread
                outErr = ML.toString(-1) catch "UnknownError";
                break :jmp;
            },
        };

        L.pushLightUserdata(@ptrCast(&PreloadedState));
        L.setField(-3, moduleAbsolutePath);

        const resumeStatus: ?luau.ResumeStatus = Scheduler.resumeState(ML, L, 0) catch {
            L.pop(1); // drop: thread
            outErr = "requested module failed to load";
            break :jmp;
        };
        if (resumeStatus) |status| {
            if (status == .ok) {
                const t = ML.getTop();
                if (t > 1 or t < 0) {
                    L.pop(1); // drop: thread
                    outErr = "module must return one value";
                    break :jmp;
                } else if (t == 0)
                    ML.pushNil();
            } else if (status == .yield) {
                L.pushLightUserdata(@ptrCast(&WaitingState));
                L.setField(-3, moduleAbsolutePath);

                {
                    const path = try allocator.dupeZ(u8, moduleAbsolutePath);
                    errdefer allocator.free(path);

                    _ = scheduler.awaitResult(RequireContext, .{
                        .path = path,
                        .caller = L,
                    }, ML, require_finished);
                }

                var list = std.ArrayList(QueueItem).init(allocator);
                try list.append(.{
                    .state = L,
                    .ref = Scheduler.refThread(L),
                });

                try REQUIRE_QUEUE_MAP.put(try allocator.dupe(u8, moduleAbsolutePath), list);

                return L.yield(0);
            }
        }

        ML.xMove(L, 1);
        L.pushValue(-1);
        L.setField(-4, moduleAbsolutePath); // SET: _MODULES[moduleName] = module
    }

    if (outErr != null) {
        L.pushLightUserdata(@ptrCast(&ErrorState));
        L.setField(-2, moduleAbsolutePath);
    }

    if (outErr) |err| {
        L.pushLString(err);
        return error.RaiseLuauError;
    }

    return 1;
}

pub fn load_require(L: *Luau) void {
    L.setGlobalFn("require", Scheduler.toSchedulerEFn(zune_require));
}

test "Require" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"require.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
