const std = @import("std");
const builtin = @import("builtin");

pub const context = switch (builtin.os.tag) {
    .windows => struct {
        pub const POLLIN: i16 = 0x0100;
        pub const POLLERR: i16 = 0x0001;
        pub const POLLHUP: i16 = 0x0002;
        pub const POLLNVAL: i16 = 0x0004;
        pub const INVALID_SOCKET = std.os.windows.ws2_32.INVALID_SOCKET;
        pub const pollfd = std.os.windows.ws2_32.pollfd;
        pub fn poll(fds: []pollfd, timeout: i32) !usize {
            const rc = std.os.windows.poll(fds.ptr, 1, timeout);
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                switch (std.os.windows.ws2_32.WSAGetLastError()) {
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSANOTINITIALISED => unreachable,
                    else => |err| return std.os.windows.unexpectedWSAError(err),
                }
            } else return @intCast(rc);
        }
    },
    .macos, .linux => struct {
        pub const POLLIN: i16 = 0x0001;
        pub const POLLERR: i16 = 0x0008;
        pub const POLLHUP: i16 = 0x0010;
        pub const POLLNVAL: i16 = 0x0020;
        pub const INVALID_SOCKET = -1;
        pub const pollfd = std.posix.pollfd;
        pub const poll = std.posix.poll;
    },
    else => @compileError("Unsupported OS"),
};
