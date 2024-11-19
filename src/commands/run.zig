const std = @import("std");
const luau = @import("luau");

const command = @import("lib.zig");

const Zune = @import("../zune.zig");

const Engine = @import("../core/runtime/engine.zig");
const Profiler = @import("../core/runtime/profiler.zig");
const Scheduler = @import("../core/runtime/scheduler.zig");

const file = @import("../core/resolvers/file.zig");

const Luau = luau.Luau;

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var run_args: []const []const u8 = args;
    var flags: ?[]const []const u8 = null;
    blk: {
        for (args, 0..) |arg, ap|
            if (arg.len < 2 or !std.mem.eql(u8, arg[0..2], "--")) {
                if (ap > 0)
                    flags = args[0..ap];
                run_args = args[ap..];
                break :blk;
            };
        flags = args;
        run_args = &[0][]const u8{};
        break :blk;
    }

    if (run_args.len < 1) {
        std.debug.print("Usage: run [OPTIONS] <luau file>\n", .{});
        return;
    }

    Zune.loadConfiguration();

    var PROFILER: ?u64 = null;
    if (flags) |f| for (f) |flag| {
        if (flag.len >= 9 and std.mem.eql(u8, flag[0..9], "--profile")) {
            PROFILER = 10000;
            if (flag.len > 10 and flag[9] == '=') {
                const level = try std.fmt.parseInt(u64, flag[10..], 10);
                PROFILER = level;
            }
        }
    };

    const dir = std.fs.cwd();
    const module = run_args[0];

    var maybeResult: ?file.SearchResult([]const u8) = null;
    defer if (maybeResult) |r| r.deinit();
    var maybeFileName: ?[]const u8 = null;
    defer if (maybeResult == null) if (maybeFileName) |f| allocator.free(f);
    var maybeFileContent: ?[]const u8 = null;
    defer if (maybeFileContent) |c| allocator.free(c);

    if (module.len == 1 and module[0] == '-') {
        maybeFileContent = try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
        maybeFileName = try dir.realpathAlloc(allocator, "./");
    } else if (dir.readFileAlloc(allocator, module, std.math.maxInt(usize)) catch null) |content| {
        maybeFileContent = content;
        maybeFileName = try dir.realpathAlloc(allocator, module);
    } else {
        const result = try Engine.findLuauFile(allocator, dir, module);
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
        std.debug.print("File is empty: {s}\n", .{run_args[0]});
        return;
    }

    var L = try Luau.init(&allocator);
    defer L.deinit();
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Engine.prepAsync(L, &scheduler, .{
        .args = run_args,
    }, .{
        .mode = .Run,
    });

    const ML = L.newThread();

    ML.sandboxThread();

    const cwdDirPath = dir.realpathAlloc(allocator, ".") catch return error.FileNotFound;
    defer allocator.free(cwdDirPath);

    const moduleRelativeName = try std.fs.path.relative(allocator, cwdDirPath, fileName);
    defer allocator.free(moduleRelativeName);

    Engine.setLuaFileContext(ML, .{
        .path = fileName,
        .name = moduleRelativeName,
        .source = fileContent,
    });

    const moduleRelativeNameZ = try allocator.dupeZ(u8, moduleRelativeName);
    defer allocator.free(moduleRelativeNameZ);

    Engine.loadModule(ML, moduleRelativeNameZ, fileContent, null) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("SyntaxError: {s}\n", .{ML.toString(-1) catch "UnknownError"});
            return;
        },
        else => return err,
    };

    if (PROFILER) |freq|
        try Profiler.start(L, freq);
    defer if (PROFILER != null) {
        Profiler.end();
        Profiler.dump("profile.out");
    };
    Engine.runAsync(ML, &scheduler, true) catch return; // Soft exit
}

pub const Command = command.Command{ .name = "run", .execute = Execute };

test "Run" {
    const allocator = std.testing.allocator;
    try Execute(allocator, &.{"test/cli/run"});
}
