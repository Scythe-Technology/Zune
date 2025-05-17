const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("../zune.zig");
const command = @import("lib.zig");

const Engine = @import("../core/runtime/engine.zig");
const Scheduler = @import("../core/runtime/scheduler.zig");

const file = @import("../core/resolvers/file.zig");
const require = @import("../core/resolvers/require.zig");

const VM = luau.VM;

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: test <luau file>\n", .{});
        return;
    }

    Zune.loadConfiguration(std.fs.cwd());

    const dir = std.fs.cwd();
    const module = args[0];

    var maybeResult: ?file.SearchResult([]const u8) = null;
    defer if (maybeResult) |r| r.deinit();
    var maybeFileName: ?[]const u8 = null;
    var maybeFileContent: ?[]const u8 = null;
    defer if (maybeFileContent) |c| allocator.free(c);

    if (module.len == 1 and module[0] == '-') {
        maybeFileContent = try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
        maybeFileName = "STDIN";
    } else if (dir.readFileAlloc(allocator, module, std.math.maxInt(usize)) catch null) |content| {
        maybeFileContent = content;
        maybeFileName = module;
    } else {
        const result = try file.findLuauFile(allocator, dir, module);
        maybeResult = result;
        switch (result.result) {
            .exact => |e| maybeFileName = e,
            .results => |results| maybeFileName = results[0],
            .none => return error.FileNotFound,
        }
        maybeFileContent = try std.fs.cwd().readFileAlloc(allocator, maybeFileName.?, std.math.maxInt(usize));
    }

    const fileContent = maybeFileContent orelse std.debug.panic("FileNotFound", .{});
    const fileName = maybeFileName orelse std.debug.panic("FileNotFound", .{});

    if (fileContent.len == 0) {
        std.debug.print("File is empty: {s}\n", .{args[0]});
        return;
    }

    var gpa = std.heap.DebugAllocator(.{
        .safety = true,
        .stack_trace_frames = 8,
    }){};
    defer {
        const result = gpa.deinit();
        if (result == .leak) {
            std.debug.print(" \x1b[1;31m[Memory leaks detected]\x1b[0m\n", .{});
            std.debug.print(" This is likely a zune bug, report it on the zune repository.\n", .{});
            std.debug.print(" \x1b[4mhttps://github.com/Scythe-Technology/Zune\x1b[0m\n\n", .{});
        }
    }

    const gpa_allocator = gpa.allocator();

    var L = try luau.init(&gpa_allocator);
    defer L.deinit();
    var scheduler = try Scheduler.init(gpa_allocator, L);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Zune.loadLuaurc(Zune.DEFAULT_ALLOCATOR, std.fs.cwd(), null);
    try Engine.prepAsync(L, &scheduler);
    try Zune.openZune(L, args, .{ .mode = .Test });

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = L.newthread();

    ML.Lsandboxthread();

    Engine.setLuaFileContext(ML, .{
        .source = fileContent,
        .main = true,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const sourceNameZ = try std.mem.joinZ(gpa_allocator, "", &.{ "@", fileName });
    defer gpa_allocator.free(sourceNameZ);

    Engine.loadModule(ML, sourceNameZ, fileContent, null) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("SyntaxError: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
            return;
        },
        else => return err,
    };

    const start = VM.lperf.clock();

    Engine.runAsync(ML, &scheduler, .{ .cleanUp = true }) catch {};

    const reuslt = Zune.corelib.testing.finish_testing(L, start);

    if (reuslt.failed > 0) {
        std.process.exit(1);
    }
}

pub const Command = command.Command{ .name = "test", .execute = Execute };

test "Test" {
    const allocator = std.testing.allocator;
    try Execute(allocator, &.{"test/cli/test"});
}
