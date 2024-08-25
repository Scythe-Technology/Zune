const std = @import("std");
const luau = @import("luau");

const zune = @import("../../zune.zig");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const Luau = luau.Luau;

const zune_test_files = @import("zune-test-files");

pub fn runTest(allocator: std.mem.Allocator, comptime testFile: zune_test_files.File, args: []const []const u8, comptime stdOutEnabled: bool) !zune.corelib.testing.TestResult {
    var L = try Luau.init(&allocator);
    defer L.deinit();

    if (!stdOutEnabled) L.setFieldBoolean(luau.GLOBALSINDEX, "_testing_stdOut", false);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const temporaryDir = std.testing.tmpDir(std.fs.Dir.OpenDirOptions{
        .access_sub_paths = true,
    });

    const tempPath = try std.mem.joinZ(allocator, "/", &.{
        ".zig-cache/tmp",
        &temporaryDir.sub_path,
    });
    defer allocator.free(tempPath);
    L.setGlobalString("__test_tempdir", tempPath);

    const testFileAbsolute = try std.fs.cwd().realpathAlloc(allocator, testFile.path);
    defer allocator.free(testFileAbsolute);

    try Engine.prepAsync(L, &scheduler, .{
        .args = args,
        .mode = .Test,
    });

    const ML = L.newThread();

    ML.sandboxThread();

    Engine.setLuaFileContext(ML, testFileAbsolute);

    const zbasename = try allocator.dupeZ(u8, std.fs.path.basename(testFile.path));
    defer allocator.free(zbasename);

    Engine.loadModule(ML, zbasename, testFile.content, .{
        .debug_level = 2,
    }) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("Syntax: {s}\n", .{ML.toString(-1) catch "UnknownError"});
            return err;
        },
        else => return err,
    };

    return zune.corelib.testing.runTestAsync(ML, &scheduler) catch |err| switch (err) {
        error.MsgHandler, error.Runtime => {
            Engine.logError(L, err);
            return err;
        },
        else => return err,
    };
}
