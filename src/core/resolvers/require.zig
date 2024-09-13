const std = @import("std");
const luau = @import("luau");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");
const file = @import("file.zig");

const Luau = luau.Luau;

const RequireError = error{
    ModuleNotFound,
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

const safeLuauGPA = std.heap.GeneralPurposeAllocator(.{});

pub fn zune_require(L: *Luau) !i32 {
    const allocator = L.allocator();
    const moduleName = L.checkString(1);
    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    var outErr: ?[]const u8 = null;
    if (moduleName[0] == '@') {
        if (L.getField(-1, moduleName) == .nil) {
            L.remove(-2); // drop: _MODULES
            return RequireError.ModuleNotFound;
        }
    } else jmp: {
        if (L.getField(luau.GLOBALSINDEX, "_FILE") != .string) return finishError(L, "InternalError (_FILE is invalid)");
        const moduleFilePath = L.toString(-1) catch unreachable;
        L.pop(1); // drop: _FILE
        if (!std.fs.path.isAbsolute(moduleFilePath)) return finishError(L, "InternalError (_FILE is not absolute)");

        const relativeDirPath = std.fs.path.dirname(moduleFilePath) orelse return error.FileNotFound;

        const moduleAbsolutePath = Engine.findLuauFileFromPathZ(allocator, relativeDirPath, moduleName) catch return error.FileNotFound;
        defer allocator.free(moduleAbsolutePath);

        const moduleType = L.getField(-1, moduleAbsolutePath);
        if (moduleType != .nil) {
            L.remove(-2); // drop: _MODULES
            return 1;
        }
        L.pop(1); // drop: nil

        var relativeDir = std.fs.openDirAbsolute(relativeDirPath, std.fs.Dir.OpenDirOptions{}) catch |err| switch (err) {
            error.AccessDenied, error.FileNotFound => return err,
            else => {
                std.debug.print("error: {}\n", .{err});
                outErr = "InternalError (Could not open directory)";
                break :jmp;
            },
        };
        defer relativeDir.close();

        const fileContent = file.readFile(allocator, relativeDir, moduleAbsolutePath) catch |err| switch (err) {
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

        const moduleRelativeName = try std.fs.path.relative(allocator, relativeDirPath, moduleAbsolutePath);
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

        const resumeStatus: ?luau.ResumeStatus = ML.resumeThread(L, 0) catch |err| switch (err) {
            error.Runtime, error.MsgHandler => res: {
                if (!ML.isString(-1)) outErr = "Unknown Runtime Error" else outErr = ML.toString(-1) catch "ErrorNotString";
                break :res null;
            },
            error.Memory => res: {
                outErr = "OutOfMemory";
                break :res null;
            },
        };
        if (resumeStatus) |status| {
            if (status == .ok) {
                if (ML.getTop() != 1) outErr = "module must return one value";
            } else if (status == .yield) outErr = "module must not yield";
        }

        if (outErr != null) break :jmp;

        ML.xMove(L, 1);
        L.pushValue(-1);
        L.setField(-4, moduleAbsolutePath); // SET: _MODULES[moduleName] = module
    }

    if (outErr) |err| {
        L.pushLString(err);
        L.raiseError();
    }

    return 1;
}

test "Require" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"require.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
