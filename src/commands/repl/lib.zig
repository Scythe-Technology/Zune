const std = @import("std");
const luau = @import("luau");

const command = @import("../lib.zig");

const Engine = @import("../../core/runtime/engine.zig");
const Scheduler = @import("../../core/runtime/scheduler.zig");

const History = @import("Hsitory.zig");
const Terminal = @import("Terminal.zig");

const Luau = luau.Luau;

pub var REPL_STATE: u2 = 0;

var HISTORY: ?*History = null;

pub fn SigInt() bool {
    if (REPL_STATE == 1) {
        REPL_STATE += 1;
        std.debug.print("\n^C again to exit.\n> ", .{});
        return true;
    }
    std.debug.print("\n", .{});
    if (HISTORY) |history| history.deinit();
    return false;
}

fn Execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    REPL_STATE = 1;

    var history = try History.init(allocator);
    errdefer history.deinit();

    HISTORY = &history;

    var L = try Luau.init(&allocator);
    defer L.deinit();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try Scheduler.SCHEDULERS.append(&scheduler);

    try Engine.prepAsync(L, &scheduler, .{
        .args = args,
        .mode = .Run,
    });

    const path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(path);

    Engine.setLuaFileContext(L, path);

    var stdin = std.io.getStdIn();
    var in_reader = stdin.reader();
    const stdout = std.io.getStdOut();

    var terminal = Terminal.init(stdin, stdout);
    try terminal.validateInteractive();

    try terminal.saveSettings();

    const out = terminal.stdout_writer;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var position: usize = 0;

    try terminal.setRawMode();

    switch (try L.getGlobalObjConsumed("_VERSION")) {
        .string => |s| try out.print("{s}\n", .{s}),
        else => try out.writeAll("Unknown Zune version\n"),
    }
    try out.writeAll("> ");
    while (true) {
        const byte = try in_reader.readByte();
        if (byte != 3 and REPL_STATE == 2) {
            buffer.clearAndFree();
            position = 0;
            REPL_STATE = 1;
        }
        if (byte == 0x1B) {
            if (try in_reader.readByte() != '[') continue;
            switch (try in_reader.readByte()) {
                'A' => {
                    if (history.size() == 0) continue;
                    if (history.isLatest()) history.saveTemp(buffer.items);
                    if (history.previous()) |line| {
                        buffer.clearRetainingCapacity();
                        try buffer.appendSlice(line);
                        position = line.len;

                        try terminal.clearLine();
                        try out.print("> {s}", .{line});
                    }
                },
                'B' => {
                    if (history.next()) |line| {
                        buffer.clearRetainingCapacity();
                        try buffer.appendSlice(line);
                        position = line.len;

                        try terminal.clearLine();
                        try out.print("> {s}", .{buffer.items});
                    }
                    if (history.isLatest()) history.clearTemp();
                },
                'C' => {
                    if (position < buffer.items.len) {
                        try terminal.moveCursor(.Right);
                        position += 1;
                    }
                },
                'D' => {
                    if (position > 0) {
                        try terminal.moveCursor(.Left);
                        position -= 1;
                    }
                },
                else => {},
            }
        } else if (byte == Terminal.NEW_LINE) {
            try terminal.newLine();

            history.save(buffer.items);

            const ML = L.newThread();

            if (Engine.loadModule(ML, "CLI", buffer.items, null)) {
                try terminal.restoreSettings();

                Engine.runAsync(ML, &scheduler) catch ML.pop(1);

                try terminal.setRawMode();
            } else |err| switch (err) {
                error.Syntax => {
                    try out.print("SyntaxError: {s}\n", .{ML.toString(-1) catch "UnknownError"});
                    ML.pop(1);
                },
                else => return err,
            }

            L.pop(1); // drop: thread

            history.reset();

            buffer.clearAndFree();
            position = 0;

            try terminal.clearStyles();
            try out.writeAll("> ");
        } else if (byte == 127) {
            if (position > 0) {
                const append = position < buffer.items.len;
                try out.writeByte(127);
                try terminal.moveCursor(.Left);
                position -= 1;
                _ = buffer.orderedRemove(position);
                try terminal.clearEndToCursor();
                if (append) try terminal.writeAllRetainCursor(buffer.items[position..]);
            }
        } else if (byte == 3 or byte == 4) {
            if (REPL_STATE > 0 and SigInt()) continue;
            break;
        } else {
            if (buffer.items.len > 256) @panic("Buffer Maximized");
            const append = position < buffer.items.len;
            try buffer.insert(position, byte);
            try out.writeByte(byte);
            position += 1;
            if (append) try terminal.writeAllRetainCursor(buffer.items[position..]);
        }
    }
}

pub const Command = command.Command{
    .name = "repl",
    .execute = Execute,
};
