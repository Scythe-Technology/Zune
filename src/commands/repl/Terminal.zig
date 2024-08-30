const std = @import("std");
const builtin = @import("builtin");

const Terminal = @This();

stdin_file: std.fs.File,
stdout_file: std.fs.File,
stdout_writer: std.fs.File.Writer,
settings: ?if (builtin.os.tag == .windows) void else std.posix.termios = null,

pub const NEW_LINE = if (builtin.os.tag == .windows) '\r' else '\n';
pub const C_EXIT = if (builtin.os.tag == .windows) 3 else null;

pub const MoveCursorAction = enum {
    Left,
    Right,
};

pub fn init(stdin_file: std.fs.File, stdout_file: std.fs.File) !Terminal {
    if (!std.posix.isatty(stdin_file.handle)) return std.posix.TIOCError.NotATerminal;
    if (!std.posix.isatty(stdout_file.handle)) return std.posix.TIOCError.NotATerminal;
    return .{
        .stdin_file = stdin_file,
        .stdout_file = stdout_file,
        .stdout_writer = stdout_file.writer(),
        .settings = if (builtin.os.tag != .windows) try std.posix.tcgetattr(stdin_file.handle),
    };
}

pub fn gen_sequenceWriter(seq: []const u8) fn (self: *Terminal) anyerror!void {
    return struct {
        fn inner(self: *Terminal) !void {
            try self.stdout_writer.writeAll(seq);
        }
    }.inner;
}

pub const newLine = gen_sequenceWriter("\n");
pub const clearLine = gen_sequenceWriter("\x1b[2K\r");
pub const clearStyles = gen_sequenceWriter("\x1b[0m");
pub const clearEndToCursor = gen_sequenceWriter("\x1b[0J");

pub fn writeAllRetainCursor(self: *Terminal, string: []const u8) !void {
    try self.stdout_writer.writeAll(string);
    try self.stdout_writer.print("\x1b[{d}D", .{string.len});
}
pub fn moveCursor(self: *Terminal, action: MoveCursorAction) !void {
    try self.stdout_writer.writeAll("\x1b[" ++ switch (action) {
        .Left => "D",
        .Right => "C",
    });
}

pub fn setNoncanonicalMode(self: *Terminal) !void {
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        var stdin_mode: std.os.windows.DWORD = 0;
        if (std.os.windows.kernel32.GetConsoleMode(self.stdin_file.handle, &stdin_mode) != std.os.windows.FALSE) {
            if (stdin_mode & 0x0200 == 0) if (std.os.windows.kernel32.SetConsoleMode(self.stdin_file.handle, 0x0200) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            };
        } else return error.Fail;
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        var stdout_mode: std.os.windows.DWORD = 0;
        if (std.os.windows.kernel32.GetConsoleMode(self.stdout_file.handle, &stdout_mode) != std.os.windows.FALSE) {
            if (stdout_mode & 0x0004 == 0) if (std.os.windows.kernel32.SetConsoleMode(self.stdout_file.handle, 0x0004) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            };
        } else return error.Fail;
    } else {
        var settings = try std.posix.tcgetattr(self.stdin_file.handle);
        settings.lflag.ICANON = false;
        settings.lflag.ECHO = false;
        try std.posix.tcsetattr(self.stdin_file.handle, std.posix.TCSA.NOW, settings);
    }
}

pub fn restoreSettings(self: *Terminal) !void {
    if (builtin.os.tag == .windows) {
        @panic("Not implemented");
    } else {
        try std.posix.tcsetattr(self.stdin_file.handle, std.posix.TCSA.NOW, self.settings);
    }
}
