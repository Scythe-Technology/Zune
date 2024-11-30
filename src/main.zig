const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune.zig");

const Scheduler = @import("core/runtime/scheduler.zig");

const Repl = @import("commands/repl/lib.zig");

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
            std.posix.sigaction(std.posix.SIG.INT, &.{
                .handler = .{ .handler = handle },
                .mask = std.posix.empty_sigset,
                .flags = 0,
            }, null);
        },
        else => {},
    }

    try Zune.cli.start();
}

fn shutdown() void {
    if (Repl.REPL_STATE > 0) {
        if (Repl.SigInt())
            return;
    } else if (Zune.corelib.process.SIGINT_LUA) |handler| {
        const L = handler.state;
        if (L.rawGetIndex(luau.REGISTRYINDEX, handler.ref) == .function) {
            const ML = L.newThread();
            L.xPush(ML, -2);
            if (ML.pcall(0, 0, 0)) {
                L.pop(2); // drop: thread, function
                return; // User will handle process close.
            } else |err| Zune.runtime_engine.logError(ML, err, false);
            L.pop(1); // drop: thread
        }
        L.pop(1); // drop: ?function
    }
    Scheduler.KillSchedulers();
    Zune.runtime_engine.stateCleanUp();
    std.process.exit(0);
}

test {
    std.testing.refAllDecls(@This());
}
