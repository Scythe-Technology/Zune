const std = @import("std");

const command = @import("lib.zig");

const INIT_CONFIG_FILE =
    \\# Zune Configuration
    \\
    \\# Require settings for Zune
    \\#  This affects the way Zune loads files.
    \\[Resolvers.Require]
    \\Mode="RelativeToFile"
    \\
    \\# Formatter settings for Zune
    \\#  This affects the output of the formatter while printing.
    \\[Resolvers.Formatter]
    \\MaxDepth=4
    \\ShowTableAddress=true
    \\
    \\# Compiling settings for Zune
    \\#  This affects all required files and the main file.
    \\[Compiling]
    \\DebugLevel=2
    \\OptimizationLevel=1
    \\NativeCodeGen=true
    \\
    \\# FFlag settings for Luau
    \\#  You can use `zune luau list-fflags` to list all available FFlags.
    \\# [Luau.FFlags]
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
