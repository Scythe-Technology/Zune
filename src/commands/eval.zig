const std = @import("std");
const luau = @import("luau");

const command = @import("lib.zig");

const Engine = @import("../core/runtime/engine.zig");
const Scheduler = @import("../core/runtime/scheduler.zig");

const file = @import("../core/resolvers/file.zig");

const Luau = luau.Luau;

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: eval <luau>\n", .{});
        return;
    }

    const dir = std.fs.cwd();
    const fileContent = args[0];

    const fileName: []const u8 = try dir.realpathAlloc(allocator, "./");
    defer allocator.free(fileName);

    if (fileContent.len == 0) {
        std.debug.print("Eval is empty\n", .{});
        return;
    }

    var L = try Luau.init(&allocator);
    defer L.deinit();
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Engine.prepAsync(L, &scheduler, .{
        .args = args,
        .mode = .Run,
    }, .{});

    const ML = L.newThread();

    ML.sandboxThread();

    Engine.setLuaFileContext(ML, fileName);

    const relativeDirPath = std.fs.path.dirname(fileName) orelse std.debug.panic("FileNotFound", .{});

    const moduleRelativeName = try std.fs.path.relative(allocator, relativeDirPath, fileName);
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

    Engine.runAsync(ML, &scheduler) catch return; // Soft exit
}

pub const Command = command.Command{
    .name = "--eval",
    .execute = Execute,
    .aliases = &.{"-e"},
};

test "Eval" {
    const allocator = std.testing.allocator;
    try Execute(allocator, &.{"print(\"Hello!\")"});
}
