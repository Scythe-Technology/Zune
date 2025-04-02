const std = @import("std");
const xev = @import("xev");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("../../zune.zig");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const VM = luau.VM;

const zune_test_files = @import("zune-test-files");

const TestFile = struct {
    path: []const u8,
};

pub fn newTestFile(comptime path: []const u8) TestFile {
    return TestFile{
        .path = "test/" ++ path,
    };
}

const TestOptions = struct {
    std_out: bool = true,
    ref_leak_check: bool = true,
};

pub fn runTest(comptime testFile: TestFile, args: []const []const u8, comptime options: TestOptions) !Zune.corelib.testing.TestResult {
    const allocator = std.testing.allocator;

    switch (comptime builtin.os.tag) {
        .linux => try xev.Dynamic.detect(), // multiple backends
        else => {},
    }

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const cwd_dir = try std.fs.cwd().openDir(cwd_path, .{});
    defer cwd_dir.setAsCwd() catch std.debug.panic("Failed to set directory as cwd", .{});

    const path_name = std.fs.path.dirname(testFile.path) orelse return error.Fail;
    var path_dir = try cwd_dir.openDir(path_name, .{});
    defer path_dir.close();

    try path_dir.setAsCwd();

    Zune.loadConfiguration(.{
        .loadStd = false,
    });

    var L = try luau.init(&allocator);
    defer L.deinit();

    if (!options.std_out)
        L.Zsetfield(VM.lua.GLOBALSINDEX, "_testing_stdOut", false);

    var scheduler = try Scheduler.init(allocator, L);
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

    const content = try cwd_dir.readFileAlloc(allocator, testFileAbsolute, std.math.maxInt(usize));
    defer allocator.free(content);

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
        .source = content,
        .main = true,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const sourceNameZ = try std.mem.joinZ(allocator, "", &.{ "@", testFileAbsolute });
    defer allocator.free(sourceNameZ);

    Engine.loadModule(ML, sourceNameZ, content, .{
        .debug_level = 2,
    }) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("Syntax: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
            return err;
        },
        else => return err,
    };

    Zune.corelib.testing.REF_LEAK_CHECK = options.ref_leak_check;
    return Zune.corelib.testing.runTestAsync(ML, &scheduler) catch |err| return err;
}
