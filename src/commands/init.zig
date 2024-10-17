const std = @import("std");

const command = @import("lib.zig");

const INIT_CONFIG_FILE =
    \\# Zune Configuration
    \\
    \\# Debug settings
    \\#  This affects the way Zune handles errors and debug information.
    \\[runtime.debug]
    \\detailedError=false
    \\
    \\# Require settings
    \\#  This affects the way Zune loads files.
    \\[resolvers.require]
    \\mode="RelativeToFile"
    \\
    \\# Formatter settings
    \\#  This affects the output of the formatter while printing.
    \\[resolvers.formatter]
    \\maxDepth=4
    \\useColor=true
    \\showTableAddress=true
    \\showRecursiveTable=false
    \\displayBufferContentsMax=48
    \\
    \\# Compiling settings
    \\#  This affects all required files and the main file.
    \\[compiling]
    \\debugLevel=2
    \\optimizationLevel=1
    \\nativeCodeGen=true
    \\
    \\# FFlag settings for Luau
    \\#  You can use `zune luau list-fflags` to list all available FFlags.
    \\# [luau.fflags]
    \\# DebugCodegenOptSize=false
;

fn Execute(_: std.mem.Allocator, _: []const []const u8) !void {
    const config_file = try std.fs.cwd().createFile("zune.toml", .{
        .exclusive = true,
    });
    defer config_file.close();

    try config_file.writeAll(INIT_CONFIG_FILE);
}

pub const Command = command.Command{
    .name = "init",
    .execute = Execute,
};
