const std = @import("std");

const command = @import("lib.zig");

const zune_info = @import("zune-info");

fn Execute(_: std.mem.Allocator, _: []const []const u8) !void {
    std.debug.print("\x1b[1;3;37mZ\x1b[2;3mune\x1b[0m - A luau runtime\n" ++
        "\n" ++
        "\x1b[1mUsage:\x1b[0m zune \x1b[2m<command> [...args]\x1b[0m\n" ++
        "\n" ++
        "\x1b[1mCommands:\x1b[0m\n" ++
        "  \x1b[1;32mrun      \x1b[0;2m./script.luau    \x1b[0mExecute lua/luau file.\n" ++
        "  \x1b[1;32mtest     \x1b[0;2m./test.luau      \x1b[0mRun tests \n" ++
        "  \x1b[1;32msetup    \x1b[0;2m[editor]         \x1b[0mSetup environment for luau-lsp with editor of your choice.\n" ++
        "\n" ++
        "  \x1b[1;34mhelp                      \x1b[0mDisplay help message.\n" ++
        "\n" ++
        "\x1b[1mFlags:\x1b[0m\n" ++
        "  -V, --version             \x1b[0mDisplay version.\n" ++
        "  -h, --help                \x1b[0mDisplay help message.\n" ++
        "", .{});
}

pub const Command = command.Command{
    .name = "help",
    .execute = Execute,
    .aliases = &.{
        "-h", "--help",
    },
};