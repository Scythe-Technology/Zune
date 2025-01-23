const std = @import("std");
const luau = @import("luau");

const Zune = @import("../../zune.zig");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const VM = luau.VM;

const zune_test_files = @import("zune-test-files");

pub fn runTest(allocator: std.mem.Allocator, comptime testFile: zune_test_files.File, args: []const []const u8, comptime stdOutEnabled: bool) !Zune.corelib.testing.TestResult {
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const cwd_dir = try std.fs.cwd().openDir(cwd_path, .{});
    defer cwd_dir.setAsCwd() catch std.debug.panic("Failed to set directory as cwd", .{});

    const path_name = std.fs.path.dirname(testFile.path) orelse return error.Fail;
    var path_dir = try cwd_dir.openDir(path_name, .{});
    defer path_dir.close();

    try path_dir.setAsCwd();

    Zune.loadConfiguration();

    var L = try luau.init(&allocator);
    defer L.deinit();

    if (!stdOutEnabled)
        L.Zsetfieldc(VM.lua.GLOBALSINDEX, "_testing_stdOut", false);

    var scheduler = Scheduler.init(allocator, L);
    defer scheduler.deinit();

    var temporaryDir = std.testing.tmpDir(std.fs.Dir.OpenDirOptions{
        .access_sub_paths = true,
    });
    // FIXME: freezes windows
    // defer temporaryDir.cleanup();

    const tempPath = try std.mem.joinZ(allocator, "/", &.{
        ".zig-cache/tmp",
        &temporaryDir.sub_path,
    });
    defer allocator.free(tempPath);
    L.Zsetglobal("__test_tempdir", tempPath);

    const testFileAbsolute = try cwd_dir.realpathAlloc(allocator, testFile.path);
    defer allocator.free(testFileAbsolute);

    try Engine.prepAsync(L, &scheduler, .{
        .args = args,
    }, .{
        .mode = .Test,
    });

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = L.newthread();

    ML.Lsandboxthread();

    Zune.resolvers_require.load_require(ML);

    Engine.setLuaFileContext(ML, .{
        .path = testFileAbsolute,
        .name = testFile.path,
        .source = testFile.content,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const sourceNameZ = try std.mem.joinZ(allocator, "", &.{ "@", testFileAbsolute });
    defer allocator.free(sourceNameZ);

    Engine.loadModule(ML, sourceNameZ, testFile.content, .{
        .debug_level = 2,
    }) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("Syntax: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
            return err;
        },
        else => return err,
    };

    return Zune.corelib.testing.runTestAsync(ML, &scheduler) catch |err| switch (err) {
        error.MsgHandler, error.Runtime => {
            Engine.logError(L, err, true);
            return err;
        },
        else => return err,
    };
}
