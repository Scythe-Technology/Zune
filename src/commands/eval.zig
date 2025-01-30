const std = @import("std");
const luau = @import("luau");

const command = @import("lib.zig");

const Zune = @import("../zune.zig");

const Engine = @import("../core/runtime/engine.zig");
const Scheduler = @import("../core/runtime/scheduler.zig");

const file = @import("../core/resolvers/file.zig");

const VM = luau.VM;

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: eval <luau>\n", .{});
        return;
    }

    Zune.loadConfiguration(.{});

    const dir = std.fs.cwd();
    const fileContent = args[0];

    const path: []const u8 = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const virtual_path = try std.fs.path.join(allocator, &.{ path, "EVAL" });
    defer allocator.free(virtual_path);

    if (fileContent.len == 0) {
        std.debug.print("Eval is empty\n", .{});
        return;
    }

    var L = try luau.init(&allocator);
    defer L.deinit();
    var scheduler = Scheduler.init(allocator, L);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Engine.prepAsync(L, &scheduler, .{
        .args = args,
    }, .{
        .mode = .Run,
    });

    L.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const ML = L.newthread();

    ML.Lsandboxthread();

    Zune.resolvers_require.load_require(ML);

    Engine.setLuaFileContext(ML, .{
        .path = virtual_path,
        .name = "EVAL",
        .source = fileContent,
    });

    ML.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const sourceNameZ = try std.mem.joinZ(allocator, "", &.{ "@", virtual_path });
    defer allocator.free(sourceNameZ);

    Engine.loadModule(ML, sourceNameZ, fileContent, null) catch |err| switch (err) {
        error.Syntax => {
            std.debug.print("SyntaxError: {s}\n", .{ML.tostring(-1) orelse "UnknownError"});
            return;
        },
        else => return err,
    };

    Engine.runAsync(ML, &scheduler, .{ .cleanUp = true }) catch return; // Soft exit
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
