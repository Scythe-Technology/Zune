const std = @import("std");
const builtin = @import("builtin");

const Terminal = @This();

handle: i32,
stdin_file: std.fs.File,
stdout_file: std.fs.File,
settings: ?std.posix.termios = null,

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
        .handle = stdin_file.handle,
        .settings = if (builtin.os.tag != .windows) try std.posix.tcgetattr(stdin_file.handle),
    };
}

pub fn gen_sequenceWriter(seq: []const u8) fn (self: *Terminal) anyerror!void {
    return struct {
        fn inner(self: *Terminal) !void {
            try self.stdout_file.writeAll(seq);
        }
    }.inner;
}

pub const clearLine = gen_sequenceWriter("\x1b[2K\r");
pub const clearStyles = gen_sequenceWriter("\x1b[0m");
pub const clearEndToCursor = gen_sequenceWriter("\x1b[J");

pub fn writeAllRetainCursor(self: *Terminal, string: []const u8) !void {
    const writer = self.stdout_file.writer();
    try writer.writeAll(string);
    try writer.print("\x1b[{d}D", .{string.len});
}
pub fn moveCursor(self: *Terminal, action: MoveCursorAction) !void {
    try self.stdout_file.writeAll("\x1b[" ++ switch (action) {
        .Left => "D",
        .Right => "C",
    });
}

pub fn setNoncanonicalMode(self: *Terminal) !void {
    if (builtin.os.tag == .windows) @panic("Windows not supported yet") else {
        var settings = try std.posix.tcgetattr(self.handle);
        settings.lflag.ICANON = false;
        settings.lflag.ECHO = false;
        try std.posix.tcsetattr(self.handle, std.posix.TCSA.NOW, settings);
    }
}

pub fn restoreSettings(self: *Terminal) !void {
    if (builtin.os.tag == .windows) @panic("Windows not supported yet") else {
        try std.posix.tcsetattr(self.handle, std.posix.TCSA.NOW, self.settings);
    }
}
