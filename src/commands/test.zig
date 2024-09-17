const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const zune = @import("../zune.zig");
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

    const dir = std.fs.cwd();
    const module = args[0];

    const fileModuleName = try Engine.findLuauFile(allocator, dir, module);

    defer allocator.free(fileModuleName);

    const fileContent = try std.fs.cwd().readFileAlloc(allocator, fileModuleName, std.math.maxInt(usize));

    defer allocator.free(fileContent);
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

    Engine.setLuaFileContext(ML, fileModuleName);

    const relativeDirPath = std.fs.path.dirname(fileModuleName) orelse std.debug.panic("FileNotFound", .{});

    const moduleRelativeName = try std.fs.path.relative(allocator, relativeDirPath, fileModuleName);
    defer allocator.free(moduleRelativeName);

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

    try Engine.runAsync(ML, &scheduler);

    _ = zune.corelib.testing.finish_testing(L, start);
}

pub const Command = command.Command{ .name = "test", .execute = Execute };

test "Test" {
    const allocator = std.testing.allocator;
    try Execute(allocator, &.{"test/cli/test"});
}
