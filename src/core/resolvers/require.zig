const std = @import("std");
const luau = @import("luau");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");
const file = @import("file.zig");

const Luau = luau.Luau;

pub const POSSIBLE_EXTENSIONS = [_][]const u8{
    ".luau",
    ".lua",
    "/init.luau",
    "/init.lua",
};

pub fn finishRequire(L: *Luau) i32 {
    if (L.isString(-1)) {
        L.raiseError();
    }
    return 1;
}

pub fn finishError(L: *Luau, errMsg: [:0]const u8) i32 {
    L.pushString(errMsg);
    return finishRequire(L);
}

const safeLuauGPA = std.heap.GeneralPurposeAllocator(.{});

pub fn zune_require(L: *Luau) i32 {
    const allocator = L.allocator();
    const moduleName = L.checkString(1);
    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (moduleName[0] == '@') {
        if (L.getField(-1, moduleName) == .nil) {
            L.remove(-2); // drop: _MODULES
            L.pushString("ModuleNotFound");
        }
    } else {
        if (L.getField(luau.GLOBALSINDEX, "_FILE") != .string) return finishError(L, "InternalError (_FILE is invalid)");
        const moduleFilePath = L.toString(-1) catch unreachable;
        L.pop(1); // drop: _FILE
        if (!std.fs.path.isAbsolute(moduleFilePath)) return finishError(L, "InternalError (_FILE is not absolute)");

        const relativeDirPath = std.fs.path.dirname(moduleFilePath) orelse return finishError(L, "FileNotFound");

        const moduleAbsolutePath = Engine.findLuauFileFromPath(allocator, relativeDirPath, moduleName) catch return finishError(L, "FileNotFound");
        defer allocator.free(moduleAbsolutePath);

        const moduleType = L.getField(-1, moduleAbsolutePath);
        if (moduleType != .nil) {
            L.remove(-2); // drop: _MODULES
            return finishRequire(L);
        }
        L.pop(1); // drop: nil

        var relativeDir = std.fs.openDirAbsolute(relativeDirPath, std.fs.Dir.OpenDirOptions{}) catch |err| switch (err) {
            error.AccessDenied => return finishError(L, "AccessDenied"),
            error.FileNotFound => return finishError(L, "FileNotFound"),
            else => {
                std.debug.print("error: {}\n", .{err});
                return finishError(L, "InternalError (Could not open directory)");
            },
        };
        defer relativeDir.close();

        const fileContent = file.readFile(allocator, relativeDir, moduleAbsolutePath) catch |err| switch (err) {
            error.FileNotFound => return finishError(L, "FileNotFound"),
            error.AccessDenied => return finishError(L, "AccessDenied"),
            else => {
                std.debug.print("error: {}\n", .{err});
                return finishError(L, "InternalError (Could not read file)");
            },
        };
        defer allocator.free(fileContent);

        const GL = L.getMainThread();
        const ML = GL.newThread();
        GL.xMove(L, 1);

        ML.sandboxThread();

        Engine.setLuaFileContext(ML, moduleAbsolutePath);

        const moduleRelativeName = std.fs.path.relative(allocator, relativeDirPath, moduleAbsolutePath) catch return finishError(L, "InternalError (Cannot resolve)");
        defer allocator.free(moduleRelativeName);

        const moduleRelativeNameZ = allocator.dupeZ(u8, moduleRelativeName) catch return finishError(L, "OutOfMemory");
        defer allocator.free(moduleRelativeNameZ);

        Engine.loadModule(ML, moduleRelativeNameZ, fileContent, null) catch |err| switch (err) {
            error.Memory, error.OutOfMemory => return finishError(L, "OutOfMemory"),
            error.Syntax => return finishError(L, ML.toString(-1) catch "UnknownError"),
        };

        const resumeStatus: ?luau.ResumeStatus = ML.resumeThread(L, 0) catch |err| switch (err) {
            error.Runtime, error.MsgHandler => res: {
                if (!ML.isString(-1)) ML.pushString("Unknown Runtime Error");
                break :res null;
            },
            error.Memory => res: {
                ML.pushString("OutOfMemory");
                break :res null;
            },
        };
        if (resumeStatus) |status| {
            if (status == .ok) {
                if (ML.getTop() == 0) {
                    ML.pushString("module must return a value");
                } else if (!ML.isTable(-1) and !ML.isFunction(-1) and !ML.isNil(-1)) {
                    ML.pushString("module must return a table, function or nil");
                } else if (ML.isString(-1)) {
                    ML.pushString("unknown error while running module");
                }
            } else if (status == .yield) {
                ML.pushString("module must not yield");
            }
        }

        ML.xMove(L, 1);
        L.pushValue(-1);
        L.setField(-4, moduleAbsolutePath); // SET: _MODULES[moduleName] = module
    }
    return finishRequire(L);
}

test "Require" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, "test/engine/require.test.luau", &.{});

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
