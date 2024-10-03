const std = @import("std");
const luau = @import("luau");
const json = @import("json");

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

pub fn finishError(L: *Luau, errMsg: [:0]const u8) noreturn {
    L.pushString(errMsg);
    L.raiseError();
}

pub var ALIASES: ?std.StringArrayHashMap([]const u8) = null;

const safeLuauGPA = std.heap.GeneralPurposeAllocator(.{});

pub fn loadAliases(allocator: std.mem.Allocator) !void {
    // load .luaurc
    const rcFile = std.fs.cwd().openFile(".luaurc", .{}) catch return;
    defer rcFile.close();

    const rcContents = try rcFile.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(rcContents);

    const rcSafeContent = std.mem.trim(u8, rcContents, " \n\t\r");
    if (rcSafeContent.len == 0) return;

    var rcJsonRoot = json.parse(allocator, rcSafeContent) catch |err| {
        std.debug.print("Error: .luaurc must be valid JSON: {}\n", .{err});
        return;
    };
    defer rcJsonRoot.deinit();

    const root = rcJsonRoot.value.objectOrNull() orelse return std.debug.print("Error: .luaurc must be an object\n", .{});

    const aliases = root.get("aliases") orelse return std.debug.print("Error: .luaurc must have an 'aliases' field\n", .{});

    const aliasesObj = aliases.objectOrNull() orelse return std.debug.print("Error: .luaurc 'aliases' field must be an object\n", .{});

    ALIASES = std.StringArrayHashMap([]const u8).init(allocator);

    for (aliasesObj.keys()) |key| {
        const value = aliasesObj.get(key) orelse continue;
        const valueStr = if (value == .string) value.asString() else {
            std.debug.print("Warning: .luaurc -> aliases '{s}' field must be a string\n", .{key});
            continue;
        };
        const keyCopy = try allocator.dupe(u8, key);
        errdefer allocator.free(keyCopy);
        const valueCopy = try allocator.dupe(u8, valueStr);
        errdefer allocator.free(valueCopy);
        try ALIASES.?.put(keyCopy, valueCopy);
    }
}

pub fn freeAliases() void {
    var aliases = ALIASES orelse return;
    var iter = aliases.iterator();
    while (iter.next()) |entry| {
        aliases.allocator.free(entry.key_ptr.*);
        aliases.allocator.free(entry.value_ptr.*);
    }
    aliases.deinit();
}

const States = enum {
    Error,
    Loading,
};

var ErrorState = States.Error;
var LoadingState = States.Loading;

var RequireQueueMap = std.StringArrayHashMap(std.ArrayList(*Luau)).init(Zune.DEFAULT_ALLOCATOR);

const RequireContext = struct {
    caller: *Luau,
    path: [:0]const u8,
};
fn require_finished(ctx: *RequireContext, ML: *Luau, _: *Scheduler) void {
    const allocator = ctx.caller.allocator();
    defer allocator.destroy(ctx);
    defer allocator.free(ctx.path);

    var outErr: ?[]const u8 = null;

    const queue = RequireQueueMap.getEntry(ctx.path) orelse std.debug.panic("require_finished: queue not found", .{});
    defer {
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

    for (queue.value_ptr.*.items) |L| {
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
    if (moduleName.len > 6 and std.mem.eql(u8, moduleName[0..6], "@zcore")) {
        if (L.getField(-1, moduleName) == .nil) {
            L.remove(-2); // drop: _MODULES
            return RequireError.ModuleNotFound;
        }
    } else {
        var moduleAbsolutePath: [:0]const u8 = undefined;
        if (moduleName.len > 2 and moduleName[0] == '@') {
            const aliases = ALIASES orelse return RequireError.NoAlias;
            const delimiter = std.mem.indexOfScalar(u8, moduleName, '/') orelse moduleName.len;
            const alias = moduleName[1..delimiter];
            const path = aliases.get(alias) orelse return RequireError.NoAlias;
            const modulePath = if (moduleName.len - delimiter > 1)
                try std.fs.path.join(allocator, &.{ path, moduleName[delimiter + 1 ..] })
            else
                try allocator.dupe(u8, path);
            defer allocator.free(modulePath);

            const absPath = try std.fs.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(absPath);

            moduleAbsolutePath = Engine.findLuauFileFromPathZ(allocator, absPath, modulePath) catch return error.FileNotFound;
        } else {
            if (L.getField(luau.GLOBALSINDEX, "_FILE") != .string)
                return finishError(L, "InternalError (_FILE is invalid)");
            const moduleFilePath = L.toString(-1) catch unreachable;
            L.pop(1); // drop: _FILE
            if (!std.fs.path.isAbsolute(moduleFilePath))
                return finishError(L, "InternalError (_FILE is not absolute)");

            if (MODE == .RelativeToFile) {
                const relativeDirPath = std.fs.path.dirname(moduleFilePath) orelse return error.FileNotFound;

                moduleAbsolutePath = Engine.findLuauFileFromPathZ(allocator, relativeDirPath, moduleName) catch return error.FileNotFound;
            } else {
                const absPath = try std.fs.cwd().realpathAlloc(allocator, ".");
                defer allocator.free(absPath);

                moduleAbsolutePath = Engine.findLuauFileFromPathZ(allocator, absPath, moduleName) catch return error.FileNotFound;
            }
        }
        defer allocator.free(moduleAbsolutePath);

        jmp: {
            const moduleType = L.getField(-1, moduleAbsolutePath);
            if (moduleType != .nil) {
                if (moduleType == .light_userdata) {
                    const ptr = L.toPointer(-1) catch unreachable;
                    if (ptr == @as(*const anyopaque, @ptrCast(&ErrorState))) {
                        L.pop(1);
                        outErr = "requested module failed to load";
                        break :jmp;
                    } else if (ptr == @as(*const anyopaque, @ptrCast(&LoadingState))) {
                        L.pop(1);
                        const res = RequireQueueMap.getEntry(moduleAbsolutePath) orelse std.debug.panic("zune_require: queue not found", .{});
                        try res.value_ptr.append(L);
                        return L.yield(0);
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

            Engine.setLuaFileContext(ML, moduleAbsolutePath);

            const moduleRelativeName = try std.fs.path.relative(allocator, cwdDirPath, moduleAbsolutePath);
            defer allocator.free(moduleRelativeName);

            const moduleRelativeNameZ = try allocator.dupeZ(u8, moduleRelativeName);
            defer allocator.free(moduleRelativeNameZ);

            Engine.loadModule(ML, moduleRelativeNameZ, fileContent, null) catch |err| switch (err) {
                error.Memory, error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => {
                    outErr = ML.toString(-1) catch "UnknownError";
                    break :jmp;
                },
            };

            const resumeStatus: ?luau.ResumeStatus = Scheduler.resumeState(ML, L, 0) catch {
                outErr = "requested module failed to load";
                break :jmp;
            };
            if (resumeStatus) |status| {
                if (status == .ok) {
                    const t = ML.getTop();
                    if (t > 1 or t < 0) {
                        outErr = "module must return one value";
                        break :jmp;
                    } else if (t == 0)
                        ML.pushNil();
                } else if (status == .yield) {
                    L.pushLightUserdata(@ptrCast(&LoadingState));
                    L.setField(-3, moduleAbsolutePath);

                    const ptr = try allocator.create(RequireContext);
                    ptr.* = .{
                        .path = try allocator.dupeZ(u8, moduleAbsolutePath),
                        .caller = L,
                    };
                    try scheduler.awaitResult(RequireContext, ptr, ML, require_finished);

                    var list = std.ArrayList(*Luau).init(allocator);
                    try list.append(L);

                    try RequireQueueMap.put(try allocator.dupe(u8, moduleAbsolutePath), list);

                    return L.yield(0);
                }
            }

            ML.xMove(L, 1);
            L.pushValue(-1);
            L.setField(-4, moduleAbsolutePath); // SET: _MODULES[moduleName] = module
        }

        if (outErr != null) {
            L.pushLightUserdata(@ptrCast(&ErrorState));
            L.setField(-3, moduleAbsolutePath);
        }
    }

    if (outErr) |err| {
        L.pushLString(err);
        L.raiseError();
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
