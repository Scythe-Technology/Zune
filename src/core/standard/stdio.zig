const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");
const Formatter = @import("../resolvers/fmt.zig");

const luaHelper = @import("../utils/luahelper.zig");
const MethodMap = @import("../utils/method_map.zig");

const File = @import("../objects/filesystem/File.zig");

const Terminal = @import("../../commands/repl/Terminal.zig");
const sysfd = @import("../utils/sysfd.zig");

const VM = luau.VM;

const MAX_LUAU_SIZE = 1073741824; // 1 GB

pub const LIB_NAME = "stdio";

const CursorMoveKind = enum(u4) {
    Home,
    Goto,
    Up,
    Down,
    Left,
    Right,
    Nextline,
    PreviousLine,
    GotoColumn,
};

const EraseKind = enum(u4) {
    UntilEndOf,
    ToStartOf,
    Entire,
    SavedLines,
    ToEndOfLine,
    StartOfLineTo,
    EntireLine,
};

const ColorMap = std.StaticStringMap(u7).initComptime(.{
    .{ "black", 30 },
    .{ "red", 31 },
    .{ "green", 32 },
    .{ "yellow", 33 },
    .{ "blue", 34 },
    .{ "magenta", 35 },
    .{ "cyan", 36 },
    .{ "white", 37 },
    .{ "bblack", 90 },
    .{ "bred", 91 },
    .{ "bgreen", 92 },
    .{ "byellow", 93 },
    .{ "bblue", 94 },
    .{ "bmagenta", 95 },
    .{ "bcyan", 96 },
    .{ "bwhite", 97 },
});

const StyleMap = std.StaticStringMap(u4).initComptime(.{
    .{ "bold", 1 },
    .{ "dim", 2 },
    .{ "italic", 3 },
    .{ "underline", 4 },
    .{ "blinking", 5 },
    .{ "inverse", 7 },
    .{ "hidden", 8 },
    .{ "strikethrough", 9 },
});

const ResetMap = std.StaticStringMap(u6).initComptime(.{
    .{ "weight", 22 },
    .{ "italic", 23 },
    .{ "underline", 24 },
    .{ "blinking", 25 },
    .{ "inverse", 27 },
    .{ "hidden", 28 },
    .{ "strikethrough", 29 },
    .{ "color", 39 },
});

const CursorActionMap = std.StaticStringMap(CursorMoveKind).initComptime(.{
    .{ "home", .Home },
    .{ "goto", .Goto },
    .{ "up", .Up },
    .{ "down", .Down },
    .{ "right", .Right },
    .{ "left", .Left },
    .{ "nextline", .Nextline },
    .{ "prevline", .PreviousLine },
    .{ "gotocol", .GotoColumn },
});

const EraseActionMap = std.StaticStringMap(EraseKind).initComptime(.{
    .{ "endOf", .UntilEndOf },
    .{ "startOf", .ToStartOf },
    .{ "entire", .Entire },
    .{ "savedLines", .SavedLines },
    .{ "endOfLine", .ToEndOfLine },
    .{ "startOfLine", .StartOfLineTo },
    .{ "entireLine", .EntireLine },
});

fn stdio_color(L: *VM.lua.State) !i32 {
    const color = try L.Zcheckvalue([:0]const u8, 1, null);

    const code = ColorMap.get(color) orelse return L.Zerror("UnknownColor");

    L.pushfstring("\x1b[{d}m", .{code});

    return 1;
}
fn stdio_bgColor(L: *VM.lua.State) !i32 {
    const color = try L.Zcheckvalue([:0]const u8, 1, null);

    const code = ColorMap.get(color) orelse return L.Zerror("UnknownColor");

    L.pushfstring("\x1b[{d}m", .{code + 10});

    return 1;
}

fn stdio_color256(L: *VM.lua.State) !i32 {
    const code = try L.Zcheckvalue(i32, 1, null);

    if (code < 0 or code > 255)
        return L.Zerror("Code must be between 0 to 255");

    L.pushfstring("\x1b[38;5;{d}m", .{code});

    return 1;
}
fn stdio_bgColor256(L: *VM.lua.State) !i32 {
    const code = try L.Zcheckvalue(i32, 1, null);

    if (code < 0 or code > 255)
        return L.Zerror("Code must be between 0 to 255");

    L.pushfstring("\x1b[48;5;{d}m", .{code});

    return 1;
}

fn stdio_trueColor(L: *VM.lua.State) !i32 {
    const r = try L.Zcheckvalue(i32, 1, null);
    const g = try L.Zcheckvalue(i32, 2, null);
    const b = try L.Zcheckvalue(i32, 3, null);

    if (r < 0 or r > 255)
        return L.Zerror("R must be between 0 to 255");
    if (g < 0 or g > 255)
        return L.Zerror("G must be between 0 to 255");
    if (b < 0 or b > 255)
        return L.Zerror("B must be between 0 to 255");

    L.pushfstring("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });

    return 1;
}
fn stdio_bgTrueColor(L: *VM.lua.State) !i32 {
    const r = try L.Zcheckvalue(i32, 1, null);
    const g = try L.Zcheckvalue(i32, 2, null);
    const b = try L.Zcheckvalue(i32, 3, null);

    if (r < 0 or r > 255)
        return L.Zerror("R must be between 0 to 255");
    if (g < 0 or g > 255)
        return L.Zerror("G must be between 0 to 255");
    if (b < 0 or b > 255)
        return L.Zerror("B must be between 0 to 255");

    L.pushfstring("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });

    return 1;
}

fn stdio_style(L: *VM.lua.State) !i32 {
    const color = try L.Zcheckvalue([:0]const u8, 1, null);

    const code = StyleMap.get(color) orelse return L.Zerror("UnknownStyle");

    L.pushfstring("\x1b[{d}m", .{code});

    return 1;
}

fn stdio_reset(L: *VM.lua.State) !i32 {
    const reset = L.tolstring(1);

    if (reset) |kind| {
        if (ResetMap.get(kind)) |code| {
            L.pushfstring("\x1b[{d}m", .{code});
            return 1;
        }
    }

    L.pushlstring("\x1b[0m");

    return 1;
}

fn stdio_cursorMove(L: *VM.lua.State) !i32 {
    const action = try L.Zcheckvalue([:0]const u8, 1, null);

    const kind = CursorActionMap.get(action) orelse return L.Zerror("UnknownKind");

    switch (kind) {
        .Home => L.pushfstring("\x1b[H", .{}),
        .Goto => L.pushfstring("\x1b[{d};{d}H", .{ L.Lcheckinteger(2), L.Lcheckinteger(3) }),
        .Up => L.pushfstring("\x1b[{d}A", .{L.Lcheckinteger(2)}),
        .Down => L.pushfstring("\x1b[{d}B", .{L.Lcheckinteger(2)}),
        .Right => L.pushfstring("\x1b[{d}C", .{L.Lcheckinteger(2)}),
        .Left => L.pushfstring("\x1b[{d}D", .{L.Lcheckinteger(2)}),
        .Nextline => L.pushfstring("\x1b[{d}E", .{L.Lcheckinteger(2)}),
        .PreviousLine => L.pushfstring("\x1b[{d}F", .{L.Lcheckinteger(2)}),
        .GotoColumn => L.pushfstring("\x1b[{d}G", .{L.Lcheckinteger(2)}),
    }

    return 1;
}

fn stdio_erase(L: *VM.lua.State) !i32 {
    const action = try L.Zcheckvalue([:0]const u8, 1, null);

    const kind = EraseActionMap.get(action) orelse return L.Zerror("UnknownKind");

    const str = switch (kind) {
        .UntilEndOf => "0J",
        .ToStartOf => "1J",
        .Entire => "2J",
        .SavedLines => "3J",
        .ToEndOfLine => "0K",
        .StartOfLineTo => "1K",
        .EntireLine => "2K",
    };

    L.pushfstring("\x1b[{s}", .{str});

    return 1;
}

const LuaTerminal = struct {
    pub fn enableRawMode(L: *VM.lua.State) !i32 {
        const term = &(TERMINAL orelse return L.Zerror("Terminal not initialized"));
        L.pushboolean(if (term.setRawMode()) true else |_| false);
        return 1;
    }

    pub fn restoreMode(L: *VM.lua.State) !i32 {
        const term = &(TERMINAL orelse return L.Zerror("Terminal not initialized"));
        L.pushboolean(if (term.restoreSettings()) true else |_| false);
        return 1;
    }

    pub fn getSize(L: *VM.lua.State) !i32 {
        const term = &(TERMINAL orelse return L.Zerror("Terminal not initialized"));
        const x, const y = term.getSize() catch |err| {
            if (err == error.NotATerminal) return 0;
            return err;
        };
        L.pushinteger(x);
        L.pushinteger(y);
        return 2;
    }

    pub fn getCurrentMode(L: *VM.lua.State) !i32 {
        const term = &(TERMINAL orelse return L.Zerror("Terminal not initialized"));
        switch (term.mode) {
            .Plain => L.pushstring("normal"),
            .Virtual => L.pushstring("raw"),
        }
        return 1;
    }
};

pub var TERMINAL: ?Terminal = null;

pub fn loadLib(L: *VM.lua.State) void {
    L.createtable(0, 16);

    L.Zsetfield(-1, "MAX_READ", MAX_LUAU_SIZE);

    const stdIn = std.io.getStdIn();
    const stdOut = std.io.getStdOut();
    const stdErr = std.io.getStdErr();

    // StdIn
    File.push(L, stdIn, .Tty, .readable) catch |err| std.debug.panic("{}", .{err});
    L.setfield(-2, "stdin");

    // StdOut
    File.push(L, stdOut, .Tty, .writable) catch |err| std.debug.panic("{}", .{err});
    L.setfield(-2, "stdout");

    // StdErr
    File.push(L, stdErr, .Tty, .writable) catch |err| std.debug.panic("{}", .{err});
    L.setfield(-2, "stderr");

    // Terminal
    TERMINAL = Terminal.init(stdIn, stdOut);
    {
        L.newtable();

        L.Zsetfieldfn(-1, "enableRawMode", LuaTerminal.enableRawMode);
        L.Zsetfieldfn(-1, "restoreMode", LuaTerminal.restoreMode);
        L.Zsetfieldfn(-1, "getSize", LuaTerminal.getSize);
        L.Zsetfieldfn(-1, "getCurrentMode", LuaTerminal.getCurrentMode);

        L.Zsetfield(-1, "isTTY", TERMINAL.?.stdin_istty and TERMINAL.?.stdout_istty);

        L.setreadonly(-1, true);
    }
    L.setfield(-2, "terminal");

    TERMINAL.?.setOutputMode() catch std.debug.print("[Win32] Failed to set output codepoint\n", .{});

    L.Zsetfieldfn(-1, "color", stdio_color);
    L.Zsetfieldfn(-1, "style", stdio_style);
    L.Zsetfieldfn(-1, "reset", stdio_reset);
    L.Zsetfieldfn(-1, "erase", stdio_erase);
    L.Zsetfieldfn(-1, "bgcolor", stdio_bgColor);
    L.Zsetfieldfn(-1, "color256", stdio_color256);
    L.Zsetfieldfn(-1, "bgcolor256", stdio_bgColor256);
    L.Zsetfieldfn(-1, "trueColor", stdio_trueColor);
    L.Zsetfieldfn(-1, "bgtrueColor", stdio_bgTrueColor);

    L.Zsetfieldfn(-1, "cursorMove", stdio_cursorMove);
    L.Zsetfieldfn(-1, "format", Formatter.fmt_args);

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "Stdio" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/stdio.test.luau"),
        &.{},
        true,
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
