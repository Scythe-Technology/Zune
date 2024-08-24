const std = @import("std");
const luau = @import("luau");

const zune = @import("../../zune.zig");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const Luau = luau.Luau;

pub fn runTest(allocator: std.mem.Allocator, testFile: []const u8, args: []const []const u8) !zune.corelib.testing.TestResult {
    var L = try Luau.init(&allocator);
    defer L.deinit();

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

    const testFileAbsolute = try std.fs.cwd().realpathAlloc(allocator, testFile);
    defer allocator.free(testFileAbsolute);

    try Engine.prepAsync(L, &scheduler, .{
        .args = args,
        .mode = .Test,
    });

    const ML = L.newThread();

    ML.sandboxThread();

    Engine.setLuaFileContext(ML, testFileAbsolute);

    const testSource = try std.fs.cwd().readFileAlloc(allocator, testFile, std.math.maxInt(usize));
    defer allocator.free(testSource);

    const zbasename = try allocator.dupeZ(u8, std.fs.path.basename(testFile));
    defer allocator.free(zbasename);

    Engine.loadModule(ML, zbasename, testSource, .{
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
