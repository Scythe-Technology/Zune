const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");
const Formatter = @import("../resolvers/fmt.zig");

const luaHelper = @import("../utils/luahelper.zig");

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
    const color = L.Lcheckstring(1);

    const code = ColorMap.get(color) orelse return L.Zerror("UnknownColor");

    L.pushfstring("\x1b[{d}m", .{code});

    return 1;
}
fn stdio_bgColor(L: *VM.lua.State) !i32 {
    const color = L.Lcheckstring(1);

    const code = ColorMap.get(color) orelse return L.Zerror("UnknownColor");

    L.pushfstring("\x1b[{d}m", .{code + 10});

    return 1;
}

fn stdio_color256(L: *VM.lua.State) !i32 {
    const code = L.Lcheckinteger(1);

    if (code < 0 or code > 255)
        return L.Zerror("Code must be between 0 to 255");

    L.pushfstring("\x1b[38;5;{d}m", .{code});

    return 1;
}
fn stdio_bgColor256(L: *VM.lua.State) !i32 {
    const code = L.Lcheckinteger(1);

    if (code < 0 or code > 255)
        return L.Zerror("Code must be between 0 to 255");

    L.pushfstring("\x1b[48;5;{d}m", .{code});

    return 1;
}

fn stdio_trueColor(L: *VM.lua.State) !i32 {
    const r = L.Lcheckinteger(1);
    const g = L.Lcheckinteger(2);
    const b = L.Lcheckinteger(3);

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
    const r = L.Lcheckinteger(1);
    const g = L.Lcheckinteger(2);
    const b = L.Lcheckinteger(3);

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
    const color = L.Lcheckstring(1);

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
    const action = L.Lcheckstring(1);

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
    const action = L.Lcheckstring(1);

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

const LuaStdIn = struct {
    pub const META = "stdio_stdout_instance";

    // Placeholder
    pub fn __index(L: *VM.lua.State) i32 {
        L.Lchecktype(1, .Userdata);
        return 0;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        const scheduler = Scheduler.getScheduler(L);

        L.Lchecktype(1, .Userdata);
        var file_ptr = L.touserdata(std.fs.File, 1) orelse unreachable;
        const namecall = L.namecallstr() orelse return 0;
        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "read")) {
            var fds = [1]sysfd.context.pollfd{.{ .events = sysfd.context.POLLIN, .fd = file_ptr.handle, .revents = 0 }};

            const poll = try sysfd.context.poll(&fds, 0);
            if (poll < 0)
                std.debug.panic("InternalError (Bad Poll)", .{});
            if (poll == 0)
                return 0;

            const allocator = luau.getallocator(L);
            const maxBytes = L.tounsigned(2) orelse 1;

            var buffer = try allocator.alloc(u8, maxBytes);
            defer allocator.free(buffer);

            const amount = try file_ptr.read(buffer);

            L.pushlstring(buffer[0..amount]);

            return 1;
        } else if (std.mem.eql(u8, namecall, "readAsync")) {
            const maxBytes = L.tounsigned(2) orelse 1;

            const TaskContext = struct { sysfd.context.pollfd, std.fs.File, usize };
            return try scheduler.addSimpleTask(TaskContext, .{
                .{ .events = sysfd.context.POLLIN, .fd = file_ptr.handle, .revents = 0 },
                file_ptr.*,
                maxBytes,
            }, L, struct {
                fn inner(ctx: *TaskContext, l: *VM.lua.State, _: *Scheduler) !i32 {
                    const fd, const file, const max_bytes = ctx.*;
                    var fds_poll = [1]sysfd.context.pollfd{fd};
                    const async_poll = try sysfd.context.poll(&fds_poll, 0);
                    if (async_poll < 0)
                        std.debug.panic("InternalError (Bad Poll)", .{});
                    if (async_poll == 0)
                        return -1;

                    const allocator = luau.getallocator(l);

                    var buffer = try allocator.alloc(u8, max_bytes);
                    defer allocator.free(buffer);

                    const amount = try file.read(buffer);

                    l.pushlstring(buffer[0..amount]);

                    return 1;
                }
            }.inner);
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }
};

const LuaStdOut = struct {
    pub const META = "stdio_stdin_instance";

    // Placeholder
    pub fn __index(L: *VM.lua.State) i32 {
        L.Lchecktype(1, .Userdata);
        return 0;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        L.Lchecktype(1, .Userdata);
        var file_ptr = L.touserdata(std.fs.File, 1) orelse unreachable;

        const namecall = L.namecallstr() orelse return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "write")) {
            const string = if (L.typeOf(2) == .Buffer) L.Lcheckbuffer(2) else L.Lcheckstring(2);

            try file_ptr.writeAll(string);
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }
};

const LuaTerminal = struct {
    pub const META = "stdio_terminal_instance";

    pub fn __index(L: *VM.lua.State) i32 {
        L.Lchecktype(1, .LightUserdata);
        const data = L.touserdata(Terminal, 1) orelse unreachable;
        const arg = L.Lcheckstring(2);

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, arg, "isTTY")) {
            L.pushboolean(data.stdin_istty and data.stdout_istty);
            return 1;
        }

        return 0;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        L.Lchecktype(1, .LightUserdata);
        const ud_term = L.touserdata(?Terminal, 1) orelse unreachable;
        const term_ptr = &(ud_term.* orelse return L.Zerror("Terminal not initialized"));

        const namecall = L.namecallstr() orelse return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "enableRawMode")) {
            L.pushboolean(if (term_ptr.setRawMode()) true else |_| false);
            return 1;
        } else if (std.mem.eql(u8, namecall, "restoreMode")) {
            L.pushboolean(if (term_ptr.restoreSettings()) true else |_| false);
            return 1;
        } else if (std.mem.eql(u8, namecall, "getSize")) {
            const x, const y = term_ptr.getSize() catch |err| {
                if (err == error.NotATerminal) return 0;
                return err;
            };
            L.pushinteger(x);
            L.pushinteger(y);
            return 2;
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }
};

pub var TERMINAL: ?Terminal = null;

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Lnewmetatable(LuaTerminal.META);

        L.Zsetfieldfn(-1, luau.Metamethods.index, LuaTerminal.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaTerminal.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    {
        _ = L.Lnewmetatable(LuaStdIn.META);

        L.Zsetfieldfn(-1, luau.Metamethods.index, LuaStdIn.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaStdIn.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    {
        _ = L.Lnewmetatable(LuaStdOut.META);

        L.Zsetfieldfn(-1, luau.Metamethods.index, LuaStdOut.__index); // metatable.__index
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaStdOut.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    L.createtable(0, 16);

    L.Zsetfield(-1, "MAX_READ", MAX_LUAU_SIZE);

    const stdIn = std.io.getStdIn();
    const stdOut = std.io.getStdOut();
    const stdErr = std.io.getStdErr();

    // StdIn
    const stdin_ptr = L.newuserdata(std.fs.File);
    stdin_ptr.* = stdIn;
    if (L.Lgetmetatable(LuaStdIn.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Stdin Metatable not initialized)", .{});
    L.setfield(-2, "stdin");

    // StdOut
    const stdout_ptr = L.newuserdata(std.fs.File);
    stdout_ptr.* = stdOut;
    if (L.Lgetmetatable(LuaStdOut.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (StdOut Metatable not initialized)", .{});
    L.setfield(-2, "stdout");

    // StdErr
    const stderr_ptr = L.newuserdata(std.fs.File);
    stderr_ptr.* = stdErr;
    if (L.Lgetmetatable(LuaStdOut.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (StdOut Metatable not initialized)", .{});
    L.setfield(-2, "stderr");

    // Terminal
    TERMINAL = Terminal.init(stdIn, stdOut);
    L.pushlightuserdata(&TERMINAL);
    if (L.Lgetmetatable(LuaTerminal.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Terminal Metatable not initialized)", .{});
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

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"stdio.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
