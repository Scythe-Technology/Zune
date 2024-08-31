const std = @import("std");
const builtin = @import("builtin");

const Terminal = @This();

const WindowsSettings = struct {
    virtual_terminal_input: bool,
    virtual_terminal_processing: bool,
};

const Modes = enum {
    Virtual,
    Plain,
};

stdin_istty: bool,
stdout_istty: bool,

stdin_file: std.fs.File,
stdout_file: std.fs.File,
stdout_writer: std.fs.File.Writer,
settings: ?if (builtin.os.tag == .windows) WindowsSettings else std.posix.termios = null,
current_settings: if (builtin.os.tag == .windows) WindowsSettings else void = if (builtin.os.tag == .windows) .{
    .virtual_terminal_input = false,
    .virtual_terminal_processing = false,
},

mode: Modes,

pub const NEW_LINE = if (builtin.os.tag == .windows) '\r' else '\n';
pub const C_EXIT = if (builtin.os.tag == .windows) 3 else null;

pub const MoveCursorAction = enum {
    Left,
    Right,
};

pub fn init(stdin_file: std.fs.File, stdout_file: std.fs.File) Terminal {
    return .{
        .stdin_istty = std.posix.isatty(stdin_file.handle),
        .stdout_istty = std.posix.isatty(stdout_file.handle),
        .stdin_file = stdin_file,
        .stdout_file = stdout_file,
        .stdout_writer = stdout_file.writer(),
        .mode = .Plain, // prob best to assume plain text.
    };
}

pub fn validateInteractive(self: *Terminal) !void {
    if (!self.stdin_istty) return std.posix.TIOCError.NotATerminal;
    if (!self.stdout_istty) return std.posix.TIOCError.NotATerminal;
}

pub fn saveSettings(self: *Terminal) !void {
    if (self.settings != null) return;
    if (builtin.os.tag != .windows) {
        self.settings = try std.posix.tcgetattr(self.stdin_file.handle);
    } else {
        var settings = WindowsSettings{
            .virtual_terminal_input = false,
            .virtual_terminal_processing = false,
        };
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        var stdin_mode: std.os.windows.DWORD = 0;
        if (std.os.windows.kernel32.GetConsoleMode(self.stdin_file.handle, &stdin_mode) != std.os.windows.FALSE) {
            if (stdin_mode & 0x0200 != 0) settings.virtual_terminal_input = true;
        } else return error.Fail;
        self.current_settings.virtual_terminal_input = settings.virtual_terminal_input;
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        var stdout_mode: std.os.windows.DWORD = 0;
        if (std.os.windows.kernel32.GetConsoleMode(self.stdout_file.handle, &stdout_mode) != std.os.windows.FALSE) {
            if (stdout_mode & 0x0004 == 0) settings.virtual_terminal_processing = false;
        } else return error.Fail;
        self.current_settings.virtual_terminal_processing = settings.virtual_terminal_processing;

        self.settings = settings;
    }
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

pub fn setRawMode(self: *Terminal) !void {
    try self.validateInteractive();
    try self.saveSettings();
    const settings = self.settings orelse return;
    self.mode = .Virtual;
    errdefer self.mode = .Plain;
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        if (!settings.virtual_terminal_input) {
            if (std.os.windows.kernel32.SetConsoleMode(self.stdin_file.handle, 0x0200) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
            self.current_settings.virtual_terminal_input = true;
        }
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (!settings.virtual_terminal_processing) {
            if (std.os.windows.kernel32.SetConsoleMode(self.stdout_file.handle, 0x0004) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
            self.current_settings.virtual_terminal_processing = true;
        }
    } else {
        var newSettings = try std.posix.tcgetattr(self.stdin_file.handle);
        newSettings.lflag.ICANON = false;
        newSettings.lflag.ECHO = false;
        try std.posix.tcsetattr(self.stdin_file.handle, std.posix.TCSA.NOW, newSettings);
    }
}

pub fn restoreSettings(self: *Terminal) !void {
    try self.validateInteractive();
    const settings = self.settings orelse return;
    if (self.mode == .Plain) return;
    self.mode = .Plain;
    if (builtin.os.tag == .windows) {
        // https://learn.microsoft.com/en-us/windows/console/setconsolemode
        // ENABLE_VIRTUAL_TERMINAL_INPUT
        if (settings.virtual_terminal_input != self.current_settings.virtual_terminal_input) {
            if (std.os.windows.kernel32.SetConsoleMode(self.stdin_file.handle, 0x0200) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
            self.current_settings.virtual_terminal_input = settings.virtual_terminal_input;
        }
        // ENABLE_VIRTUAL_TERMINAL_PROCESSING
        if (!settings.virtual_terminal_processing != self.current_settings.virtual_terminal_processing) {
            if (std.os.windows.kernel32.SetConsoleMode(self.stdout_file.handle, 0x0004) == std.os.windows.FALSE) {
                switch (std.os.windows.kernel32.GetLastError()) {
                    else => |err| return std.os.windows.unexpectedError(err),
                }
            }
            self.current_settings.virtual_terminal_processing = settings.virtual_terminal_processing;
        }
    } else {
        if (self.settings) |old_settings| try std.posix.tcsetattr(self.stdin_file.handle, std.posix.TCSA.NOW, old_settings);
    }
}
