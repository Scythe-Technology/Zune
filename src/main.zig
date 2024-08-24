const std = @import("std");
const builtin = @import("builtin");

const zune = @import("zune.zig");

const Scheduler = @import("core/runtime/scheduler.zig");

const luau = zune.luau;

pub fn main() !void {
    switch (builtin.os.tag) {
        .windows => {
            const handle = struct {
                fn handler(dwCtrlType: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
                    if (dwCtrlType == std.os.windows.CTRL_C_EVENT) {
                        shutdown();
                        return std.os.windows.TRUE;
                    } else return std.os.windows.FALSE;
                }
            }.handler;
            try std.os.windows.SetConsoleCtrlHandler(handle, true);
        },
        .linux, .macos => {
            const handle = struct {
                fn handler(_: c_int) callconv(.C) void {
                    shutdown();
                }
            }.handler;
            try std.posix.sigaction(std.posix.SIG.INT, &.{
                .handler = .{ .handler = handle },
                .mask = std.posix.empty_sigset,
                .flags = 0,
            }, null);
        },
        else => {},
    }

    try zune.cli.start();
}

fn shutdown() void {
    Scheduler.KillSchedulers();
    std.process.exit(0);
}

test {
    std.testing.refAllDecls(@This());
}
