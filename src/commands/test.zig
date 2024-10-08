const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("../zune.zig");
const command = @import("lib.zig");

const Engine = @import("../core/runtime/engine.zig");
const Scheduler = @import("../core/runtime/scheduler.zig");

const file = @import("../core/resolvers/file.zig");
const require = @import("../core/resolvers/require.zig");

const Luau = luau.Luau;

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: test <luau file>\n", .{});
        return;
    }

    Zune.loadConfiguration();

    const dir = std.fs.cwd();
    const module = args[0];

    var maybeFileName: ?[]const u8 = null;
    defer if (maybeFileName) |f| allocator.free(f);
    var maybeFileContent: ?[]const u8 = null;
    defer if (maybeFileContent) |c| allocator.free(c);

    if (module.len == 1 and module[0] == '-') {
        maybeFileContent = try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
        maybeFileName = try dir.realpathAlloc(allocator, "./");
    } else if (dir.readFileAlloc(allocator, module, std.math.maxInt(usize)) catch null) |content| {
        maybeFileContent = content;
        maybeFileName = try dir.realpathAlloc(allocator, module);
    } else {
        maybeFileName = try Engine.findLuauFile(allocator, dir, module);
        maybeFileContent = try std.fs.cwd().readFileAlloc(allocator, maybeFileName.?, std.math.maxInt(usize));
    }

    const fileContent = maybeFileContent orelse std.debug.panic("FileNotFound", .{});
    const fileName = maybeFileName orelse std.debug.panic("FileNotFound", .{});

    if (fileContent.len == 0) {
        std.debug.print("File is empty: {s}\n", .{args[0]});
        return;
    }

    var L = try Luau.init(&allocator);
    defer L.deinit();
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Engine.prepAsync(L, &scheduler, .{
        .args = args,
        .mode = .Test,
    }, .{});

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

    const start = luau.clock();

    try Engine.runAsync(ML, &scheduler, true);

    _ = Zune.corelib.testing.finish_testing(L, start);
}

pub const Command = command.Command{ .name = "test", .execute = Execute };

test "Test" {
    const allocator = std.testing.allocator;
    try Execute(allocator, &.{"test/cli/test"});
}
