const std = @import("std");
const luau = @import("luau");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const Luau = luau.Luau;

const MAX_LUAU_SIZE = 1073741824; // 1 GB

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

const CursorActionMap = std.StaticStringMap(CursorMoveKind).initComptime(.{ .{ "home", .Home }, .{ "goto", .Goto }, .{ "up", .Up }, .{ "down", .Down }, .{ "right", .Right }, .{ "left", .Left }, .{ "nextline", .Nextline }, .{ "prevline", .PreviousLine }, .{ "gotocol", .GotoColumn } });

const EraseActionMap = std.StaticStringMap(EraseKind).initComptime(.{
    .{ "endOf", .UntilEndOf },
    .{ "startOf", .ToStartOf },
    .{ "entire", .Entire },
    .{ "savedLines", .SavedLines },
    .{ "endOfLine", .ToEndOfLine },
    .{ "startOfLine", .StartOfLineTo },
    .{ "entireLine", .EntireLine },
});

fn stdio_color(L: *Luau) i32 {
    const allocator = L.allocator();
    const color = L.checkString(1);

    const code = ColorMap.get(color) orelse L.raiseErrorStr("UnknownColor", .{});

    const buf = std.fmt.allocPrint(allocator, "\x1b[{d}m", .{code}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}
fn stdio_bgColor(L: *Luau) i32 {
    const allocator = L.allocator();
    const color = L.checkString(1);

    const code = ColorMap.get(color) orelse L.raiseErrorStr("UnknownColor", .{});

    const buf = std.fmt.allocPrint(allocator, "\x1b[{d}m", .{code + 10}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}

fn stdio_color256(L: *Luau) i32 {
    const allocator = L.allocator();
    const code = L.checkInteger(1);

    if (code < 0 or code > 255) L.raiseErrorStr("Code must be between 0 to 255", .{});

    const buf = std.fmt.allocPrint(allocator, "\x1b[38;5;{d}m", .{code}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}
fn stdio_bgColor256(L: *Luau) i32 {
    const allocator = L.allocator();
    const code = L.checkInteger(1);

    if (code < 0 or code > 255) L.raiseErrorStr("Code must be between 0 to 255", .{});

    const buf = std.fmt.allocPrint(allocator, "\x1b[48;5;{d}m", .{code}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}

fn stdio_trueColor(L: *Luau) i32 {
    const allocator = L.allocator();
    const r = L.checkInteger(1);
    const g = L.checkInteger(2);
    const b = L.checkInteger(3);

    if (r < 0 or r > 255) L.raiseErrorStr("R must be between 0 to 255", .{});
    if (g < 0 or g > 255) L.raiseErrorStr("G must be between 0 to 255", .{});
    if (b < 0 or b > 255) L.raiseErrorStr("B must be between 0 to 255", .{});

    const buf = std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{
        r, g, b,
    }) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}
fn stdio_bgTrueColor(L: *Luau) i32 {
    const allocator = L.allocator();
    const r = L.checkInteger(1);
    const g = L.checkInteger(2);
    const b = L.checkInteger(3);

    if (r < 0 or r > 255) L.raiseErrorStr("R must be between 0 to 255", .{});
    if (g < 0 or g > 255) L.raiseErrorStr("G must be between 0 to 255", .{});
    if (b < 0 or b > 255) L.raiseErrorStr("B must be between 0 to 255", .{});

    const buf = std.fmt.allocPrint(allocator, "\x1b[48;2;{d};{d};{d}m", .{
        r, g, b,
    }) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}

fn stdio_style(L: *Luau) i32 {
    const allocator = L.allocator();
    const color = L.checkString(1);

    const code = StyleMap.get(color) orelse L.raiseErrorStr("UnknownStyle", .{});

    const buf = std.fmt.allocPrint(allocator, "\x1b[{d}m", .{code}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}

fn stdio_reset(L: *Luau) i32 {
    const allocator = L.allocator();
    const reset = L.optString(1);

    if (reset) |kind| {
        if (ResetMap.get(kind)) |code| {
            const buf = std.fmt.allocPrint(allocator, "\x1b[{d}m", .{code}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
            defer allocator.free(buf);
            L.pushLString(buf);
            return 1;
        }
    }

    L.pushLString("\x1b[0m");

    return 1;
}

fn stdio_cursorMove(L: *Luau) i32 {
    const allocator = L.allocator();
    const action = L.checkString(1);

    const kind = CursorActionMap.get(action) orelse L.raiseErrorStr("UnknownKind", .{});

    const buf = switch (kind) {
        .Home => std.fmt.allocPrint(allocator, "\x1b[H", .{}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        .Goto => std.fmt.allocPrint(allocator, "\x1b[{d};{d}H", .{ L.checkInteger(2), L.checkInteger(3) }) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        .Up => std.fmt.allocPrint(allocator, "\x1b[{d}A", .{L.checkInteger(2)}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        .Down => std.fmt.allocPrint(allocator, "\x1b[{d}B", .{L.checkInteger(2)}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        .Right => std.fmt.allocPrint(allocator, "\x1b[{d}C", .{L.checkInteger(2)}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        .Left => std.fmt.allocPrint(allocator, "\x1b[{d}D", .{L.checkInteger(2)}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        .Nextline => std.fmt.allocPrint(allocator, "\x1b[{d}E", .{L.checkInteger(2)}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        .PreviousLine => std.fmt.allocPrint(allocator, "\x1b[{d}F", .{L.checkInteger(2)}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
        .GotoColumn => std.fmt.allocPrint(allocator, "\x1b[{d}G", .{L.checkInteger(2)}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr}),
    };
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}

fn stdio_erase(L: *Luau) i32 {
    const allocator = L.allocator();
    const action = L.checkString(1);

    const kind = EraseActionMap.get(action) orelse L.raiseErrorStr("UnknownKind", .{});

    const str = switch (kind) {
        .UntilEndOf => "0J",
        .ToStartOf => "1J",
        .Entire => "2J",
        .SavedLines => "3J",
        .ToEndOfLine => "0K",
        .StartOfLineTo => "1K",
        .EntireLine => "2K",
    };

    const buf = std.fmt.allocPrint(allocator, "\x1b[{s}", .{str}) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer allocator.free(buf);

    L.pushLString(buf);

    return 1;
}

fn stdio_writeOut(L: *Luau) i32 {
    const string = L.checkString(1);

    std.io.getStdOut().writeAll(string) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});

    return 0;
}

fn stdio_writeErr(L: *Luau) i32 {
    const string = L.checkString(1);

    std.io.getStdErr().writeAll(string) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});

    return 0;
}

fn stdio_readIn(L: *Luau) i32 {
    const allocator = L.allocator();

    const maxBytes = L.optUnsigned(1) orelse MAX_LUAU_SIZE;

    var buffer = allocator.alloc(u8, maxBytes) catch L.raiseErrorStr("OutOfMemory", .{});
    defer allocator.free(buffer);

    const amount = std.io.getStdIn().readAll(buffer) catch |err| {
        allocator.free(buffer);
        L.raiseErrorStr("%s", .{@errorName(err).ptr});
    };

    L.pushLString(buffer[0..amount]);

    return 0;
}

pub fn loadLib(L: *Luau) void {
    L.newTable();

    L.setFieldFn(-1, "color", stdio_color);
    L.setFieldFn(-1, "style", stdio_style);
    L.setFieldFn(-1, "reset", stdio_reset);
    L.setFieldFn(-1, "erase", stdio_erase);
    L.setFieldFn(-1, "bgcolor", stdio_bgColor);
    L.setFieldFn(-1, "color256", stdio_color256);
    L.setFieldFn(-1, "bgcolor256", stdio_bgColor256);
    L.setFieldFn(-1, "trueColor", stdio_trueColor);
    L.setFieldFn(-1, "bgtrueColor", stdio_bgTrueColor);

    L.setFieldFn(-1, "writeOut", stdio_writeOut);
    L.setFieldFn(-1, "writeErr", stdio_writeErr);
    L.setFieldFn(-1, "readIn", stdio_readIn);

    L.setFieldFn(-1, "cursorMove", stdio_cursorMove);

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, "@zcore/stdio") != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, "@zcore/stdio");
    } else L.pop(1);
    L.pop(2);
}

test "Stdio" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"stdio.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
