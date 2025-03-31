const std = @import("std");
const luau = @import("luau");

const Zune = @import("../../zune.zig");

const Engine = @import("engine.zig");
const Scheduler = @import("scheduler.zig");

const debug = @import("../../commands/debug.zig");

const Terminal = @import("../../commands/repl/Terminal.zig");

const file = @import("../resolvers/file.zig");
const formatter = @import("../resolvers/fmt.zig");

const VM = luau.VM;

const LuaBreakpoint = struct {
    line: i32,
};

pub var ACTIVE = false;

pub var MODULE_REFERENCES = std.StringHashMap(i32).init(Zune.DEFAULT_ALLOCATOR);
pub var BREAKPOINTS = std.StringHashMap(std.ArrayList(LuaBreakpoint)).init(Zune.DEFAULT_ALLOCATOR);

const DEBUG_TAG = "\x1b[0m(dbg) ";
const DEBUG_RESULT_TAG = "\x1b[0m(dbg): ";

pub fn addReference(allocator: std.mem.Allocator, L: *VM.lua.State, name: []const u8, id: i32) !void {
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);
    try MODULE_REFERENCES.put(key, id);
    if (BREAKPOINTS.getEntry(key)) |entry| {
        const breakpoints = entry.value_ptr;
        for (breakpoints.items) |bp| {
            const target = L.breakpoint(-1, bp.line, true);
            if (target == -1)
                @panic("Debugger no target or closest line found");
            if (target == bp.line)
                continue;
            const exact = getExactBreakpoint(breakpoints, target);
            if (exact == null)
                _ = L.breakpoint(-1, target, false); // remove breakpoint
        }
    }
}

pub fn getExactBreakpoint(breakpoints: *std.ArrayList(LuaBreakpoint), line: i32) ?LuaBreakpoint {
    for (breakpoints.items) |bp| {
        if (bp.line == line)
            return bp;
    }
    return null;
}

const BreakpointResult = union(enum) {
    saved: void,
    exists: void,
    suggested: i32,
};
pub fn addBreakpoint(allocator: std.mem.Allocator, L: *VM.lua.State, path: []const u8, line: i32) !BreakpointResult {
    const key = try allocator.dupe(u8, path);
    errdefer allocator.free(key);
    const breakpoints = list: {
        const entry = BREAKPOINTS.getEntry(key) orelse e: {
            var array = std.ArrayList(LuaBreakpoint).init(allocator);
            errdefer array.deinit();
            try BREAKPOINTS.put(key, array);
            break :e BREAKPOINTS.getEntry(key) orelse unreachable;
        };
        break :list entry.value_ptr;
    };
    const breakpoint: LuaBreakpoint = .{ .line = line };
    var suggested: ?i32 = null;
    if (MODULE_REFERENCES.get(key)) |ref| {
        if (L.rawgeti(VM.lua.REGISTRYINDEX, ref) != .Function)
            @panic("Debugger invalid reference");
        defer L.pop(1);
        const target = L.breakpoint(-1, line, true);
        if (target == -1)
            @panic("Debugger no target or closest line found");
        if (target != line) {
            if (getExactBreakpoint(breakpoints, target) == null) {
                _ = L.breakpoint(-1, target, false); // remove breakpoint
                suggested = target;
            }
        }
    }
    if (getExactBreakpoint(breakpoints, line)) |_|
        return .exists;
    try breakpoints.append(breakpoint);
    if (suggested) |num|
        return .{ .suggested = num };
    return .saved;
}

pub fn removeBreakpoint(L: *VM.lua.State, path: []const u8, line: i32) bool {
    const breakpoints = list: {
        const entry = BREAKPOINTS.getEntry(path) orelse return false;
        break :list entry.value_ptr;
    };
    if (MODULE_REFERENCES.get(path)) |ref| {
        if (L.rawgeti(VM.lua.REGISTRYINDEX, ref) != .Function)
            @panic("Debugger invalid reference");
        defer L.pop(1);
        const target = L.breakpoint(-1, line, false);
        if (target == -1)
            @panic("Debugger no target or closest line found");
        if (target != line) {
            if (getExactBreakpoint(breakpoints, target)) |_|
                _ = L.breakpoint(-1, target, true); // add breakpoint
        }
    }
    for (breakpoints.items, 0..) |bp, id| {
        if (bp.line == line) {
            _ = breakpoints.orderedRemove(id);
            return true;
        }
    }
    return false;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(DEBUG_TAG ++ fmt, args);
}

pub fn printResult(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(DEBUG_RESULT_TAG ++ fmt, args);
}

const COMMAND_MAP = std.StaticStringMap(enum {
    help,
    exit,
    @"break",
    modules,
    line,
    file,
    trace,
    step,
    step_out,
    step_instruction,
    next,
    locals,
    params,
    upvalues,
    globals,
    run,
    restart,
    output_mode,
    exception,
}).initComptime(.{
    .{ "help", .help },
    .{ "exit", .exit },
    .{ "break", .@"break" },
    .{ "modules", .modules },
    .{ "line", .line },
    .{ "file", .file },
    .{ "trace", .trace },

    .{ "s", .step },
    .{ "step", .step },

    .{ "si", .step_instruction },
    .{ "stepi", .step_instruction },
    .{ "stepinsn", .step_instruction },

    .{ "so", .step_out },
    .{ "stepo", .step_out },
    .{ "stepout", .step_out },

    .{ "n", .next },
    .{ "next", .next },

    .{ "run", .run },

    .{ "locals", .locals },
    .{ "params", .params },
    .{ "upvalues", .upvalues },
    .{ "globals", .globals },

    .{ "restart", .restart },
    .{ "output", .output_mode },
    .{ "exception", .exception },
});

const BREAK_COMMAND_MAP = std.StaticStringMap(enum {
    help,
    add,
    remove,
    clear,
    list,
}).initComptime(.{
    .{ "help", .help },
    .{ "+", .add },
    .{ "add", .add },
    .{ "-", .remove },
    .{ "rm", .remove },
    .{ "remove", .remove },
    .{ "clear", .clear },
    .{ "list", .list },
});

const LOCALS_COMMAND_MAP = std.StaticStringMap(enum {
    help,
    list,
}).initComptime(.{
    .{ "help", .help },
    .{ "list", .list },
});

fn tostring(L: *VM.lua.State, idx: i32) []const u8 {
    switch (L.typeOf(idx)) {
        .Nil => L.pushlstring("nil"),
        .Boolean => L.pushlstring(if (L.toboolean(idx)) "true" else "false"),
        .Number => {
            const number = L.tonumber(idx).?;
            var s: [std.fmt.format_float.bufferSize(.decimal, f64)]u8 = undefined;
            const buf = std.fmt.bufPrint(&s, "{d}", .{number}) catch unreachable; // should be able to fit
            L.pushlstring(buf);
        },
        .Vector => {
            const vec = L.tovector(idx).?;
            var s: [(std.fmt.format_float.bufferSize(.decimal, f64) * VM.lua.config.VECTOR_SIZE) + ((VM.lua.config.VECTOR_SIZE - 1) * 2)]u8 = undefined;
            const buf = if (VM.lua.config.VECTOR_SIZE == 3)
                std.fmt.bufPrint(&s, "{d}, {d}, {d}", .{ vec[0], vec[1], vec[2] }) catch unreachable // should be able to fit
            else
                std.fmt.bufPrint(&s, "{d}, {d}, {d}, {d}", .{ vec[0], vec[1], vec[2], vec[3] }) catch unreachable; // should be able to fit
            L.pushlstring(buf);
        },
        .String => L.pushvalue(idx),
        else => {
            const ptr = L.topointer(idx).?;
            const size = comptime res: {
                var large = 0;
                for (VM.ltm.typenames) |name|
                    large = @max(large, name.len);
                break :res large;
            };
            var s: [20 + size]u8 = undefined; // 16 + 2 + 2(extra) + size
            const buf = std.fmt.bufPrint(&s, "{s}: 0x{x:016}", .{ VM.lapi.typename(L.typeOf(idx)), @intFromPtr(ptr) }) catch unreachable; // should be able to fit
            L.pushlstring(buf);
        },
    }
    return L.tolstring(-1).?;
}

fn getNextArg(buf: []const u8) struct { []const u8, []const u8 } {
    const trimmed = std.mem.trimLeft(u8, buf, " ");
    const idx = std.mem.indexOf(u8, trimmed, " ") orelse trimmed.len;
    return .{ trimmed[0..idx], trimmed[idx..] };
}

fn toBase64(allocator: std.mem.Allocator, input: []const u8) !struct { []u8, []const u8 } {
    const base64_buf = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(input.len));
    return .{ base64_buf, std.base64.standard.Encoder.encode(base64_buf, input) };
}

fn promptOpBreak(L: *VM.lua.State, allocator: std.mem.Allocator, break_args: []const u8) !void {
    if (break_args.len <= 0) {
        printResult("Usage: break <command>\n", .{});
        printResult("  try 'break help'\n", .{});
        return;
    }
    const command_input, const rest = getNextArg(break_args);
    switch (BREAK_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown break command\n", .{});
    }) {
        .help => {
            printResult("Break Commands:\n", .{});
            printResult("  help   - Show sub-commands\n", .{});
            printResult("  add    - Add a breakpoint\n", .{});
            printResult("  remove - Remove a breakpoint\n", .{});
            printResult("  clear  - Clear breakpoints\n", .{});
            printResult("  list   - List breakpoints\n", .{});
        },
        .add, .remove => |k| {
            if (rest.len <= 0)
                return printResult("Usage: break {s} <file>:<line>\n", .{command_input});
            const dir = std.fs.cwd();
            var args = std.mem.splitBackwardsScalar(u8, rest, ':');
            const line_str = std.mem.trim(u8, args.first(), " ");
            const file_str = std.mem.trim(u8, args.rest(), " ");
            if (line_str.len == 0 or file_str.len == 0)
                return printResult("Usage: break {s} <file>:<line>\n", .{command_input});
            const line = std.fmt.parseInt(i32, line_str, 10) catch |err| {
                return printResult("Line Parse Error: {}\n", .{err});
            };
            const file_path = try dir.realpathAlloc(allocator, file_str);
            defer allocator.free(file_path);
            if (k == .remove) {
                if (removeBreakpoint(L, file_path, line)) {
                    if (DEBUG.output == .Readable)
                        printResult("Removed breakpoint, line: {}\n", .{line});
                } else {
                    if (DEBUG.output == .Readable)
                        printResult("Breakpoint does not exist.\n", .{});
                }
                if (DEBUG.output == .Json)
                    printResult("{{\"success\":true}}\n", .{});
            } else {
                const result = try addBreakpoint(allocator, L, file_path, line);
                switch (DEBUG.output) {
                    .Readable => {
                        switch (result) {
                            .suggested => |target| {
                                printResult("Suggested, line: {}.\n", .{target});
                                printResult("- This breakpoint may be ignored.\n", .{});
                                printResult("Added breakpoint, line: {}.\n", .{line});
                            },
                            .saved => printResult("Added breakpoint, line: {}.\n", .{line}),
                            .exists => printResult("Breakpoint already exists, line: {}.\n", .{line}),
                        }
                    },
                    .Json => printResult("{{\"success\":true}}\n", .{}),
                }
            }
        },
        .clear => {
            var iter = BREAKPOINTS.iterator();
            while (iter.next()) |breakpoints| {
                const bps = breakpoints.value_ptr.items;
                var i = bps.len;
                while (i > 0) : (i -= 1)
                    _ = removeBreakpoint(L, breakpoints.key_ptr.*, bps[i - 1].line);
            }
            if (DEBUG.output == .Readable)
                printResult("Cleared all breakpoints.\n", .{})
            else
                printResult("{{\"success\":true}}\n", .{});
        },
        .list => {
            if (DEBUG.output == .Json)
                return;
            if (rest.len <= 0) {
                printResult("Breakpoints:\n", .{});
                var iter = BREAKPOINTS.iterator();
                while (iter.next()) |entry| {
                    const file_str = entry.key_ptr.*;
                    const breakpoints = entry.value_ptr;
                    if (breakpoints.items.len == 0)
                        continue;
                    printResult("  {s}:\n", .{file_str});
                    for (breakpoints.items) |bp| {
                        printResult("    line: {}\n", .{bp.line});
                    }
                }
            } else {
                const file_str = std.mem.trim(u8, rest, " ");
                if (BREAKPOINTS.getEntry(file_str)) |entry| {
                    const breakpoints = entry.value_ptr;
                    printResult("Breakpoints for {s}:\n", .{file_str});
                    for (breakpoints.items) |bp|
                        printResult("  line: {}\n", .{bp.line});
                } else {
                    printResult("No breakpoints for {s}\n", .{file_str});
                }
            }
        },
    }
}

// 5 stack needed
fn variableJsonDisassemble(allocator: std.mem.Allocator, L: *VM.lua.State, iter: *std.mem.SplitIterator(u8, .scalar), writer: anytype) !bool {
    while (iter.next()) |iter_i| {
        if (L.typeOf(-1) != .Table) {
            printResult("[]\n", .{}); // variable not a table
            return false;
        }
        var order: u32 = 1;
        const id = std.fmt.parseInt(u32, iter_i, 10) catch |err| {
            printResult("Id Parse Error: {}\n", .{err});
            return false;
        };
        out: {
            L.pushnil();
            while (L.next(-2)) {
                order += 1;
                if (order == id)
                    break :out;
                L.pop(1);
            }
            printResult("[]\n", .{}); // leads no where
            return false;
        }
        L.remove(-2); // remove key
        L.remove(-2); // remove old value (local/ref)
    }
    if (L.typeOf(-1) != .Table) {
        printResult("[]\n", .{}); // variable not a table
        return false;
    }
    L.pushnil();
    var first = false;
    var order: u32 = 1;
    while (L.next(-2)) {
        order += 1;
        defer L.pop(1);
        if (first)
            try writer.writeByte(',');
        first = true;
        const key_typename = VM.lapi.typename(L.typeOf(-2));
        const value_typename = VM.lapi.typename(L.typeOf(-1));
        const key_str = tostring(L, -2);
        const value = tostring(L, -2);
        defer L.pop(2);

        const key_base64_buf, const base64_key = try toBase64(allocator, key_str);
        defer allocator.free(key_base64_buf);
        const value_base64_buf, const base64_value = try toBase64(allocator, value);
        defer allocator.free(value_base64_buf);

        try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"{s}\",\"value_type\":\"{s}\"}}", .{
            order,
            base64_key,
            base64_value,
            key_typename,
            value_typename,
        });
    }
    return true;
}

fn promptOpLocals(L: *VM.lua.State, allocator: std.mem.Allocator, locals_args: []const u8) !void {
    if (locals_args.len <= 0) {
        printResult("Usage: locals <command>\n", .{});
        printResult("  try 'locals help'\n", .{});
        return;
    }

    const command_input, const rest = getNextArg(locals_args);
    switch (LOCALS_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown locals command\n", .{});
    }) {
        .help => { // locals help
            printResult("Locals Commands:\n", .{});
            printResult("  help - Show sub-commands\n", .{});
            printResult("  list - List locals and their value (if argument is passed to locals command)\n", .{});
        },
        .list => { // locals list <n> <n>?,<n>?,...
            const level_in, const args_rest = getNextArg(rest);
            var level: i32 = 0;
            if (level_in.len > 0) {
                level = std.fmt.parseInt(i32, level_in, 10) catch |err| {
                    return printResult("Level Parse Error: {}\n", .{err});
                };
            }
            switch (DEBUG.output) {
                .Readable => {
                    if (!L.checkstack(2))
                        return printResult("stack overflow.\n", .{});
                    var i: i32 = 1;
                    var showed: bool = false;
                    while (true) : (i += 1) {
                        if (L.getlocal(level, i)) |name| {
                            defer L.pop(1);
                            showed = true;
                            printResult(" {d} -> {s} ({s})\n", .{ i, name, @tagName(L.typeOf(-1)) });
                            if (level_in.len == 0)
                                continue;

                            var buf = std.ArrayList(u8).init(allocator);
                            defer buf.deinit();

                            const writer = buf.writer();
                            try formatter.fmt_write_idx(allocator, L, writer, @intCast(L.gettop()), formatter.MAX_DEPTH);
                            var iter = std.mem.splitScalar(u8, buf.items, '\n');
                            printResult(" | Value: {s}\n", .{iter.first()});
                            while (iter.next()) |line|
                                printResult(" |  {s}\n", .{line});
                        } else break;
                    }
                    if (!showed)
                        printResult("No locals found.\n", .{});
                },
                .Json => {
                    if (!L.checkstack(6))
                        return printResult("[]\n", .{}); // stack overflow
                    var iter = std.mem.splitScalar(u8, std.mem.trimLeft(u8, args_rest, " "), ',');

                    var buf = std.ArrayList(u8).init(allocator);
                    defer buf.deinit();
                    const writer = buf.writer();

                    try buf.append('[');
                    const first_iter = iter.first();
                    if (first_iter.len > 0) {
                        const initial_idx = std.fmt.parseInt(u32, first_iter, 10) catch |err| {
                            return printResult("Id Parse Error: {}\n", .{err});
                        };
                        _ = L.getlocal(level, @intCast(initial_idx)) orelse {
                            return printResult("[]\n", .{});
                        };
                        defer L.pop(1);
                        if (!try variableJsonDisassemble(allocator, L, &iter, writer))
                            return;
                    } else {
                        var i: i32 = 1;
                        var first = false;
                        while (true) : (i += 1) {
                            if (L.getlocal(level, i)) |name| {
                                defer L.pop(1);
                                if (first)
                                    try buf.append(',');
                                first = true;
                                const typename = VM.lapi.typename(L.typeOf(-1));
                                const value = tostring(L, -1);
                                defer L.pop(1);

                                const value_base64_buf, const base64_value = try toBase64(allocator, value);
                                defer allocator.free(value_base64_buf);
                                try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"literal\",\"value_type\":\"{s}\"}}", .{
                                    i,
                                    name,
                                    base64_value,
                                    typename,
                                });
                            } else break;
                        }
                    }
                    try buf.append(']');
                    printResult("{s}\n", .{buf.items});
                },
            }
        },
    }
}

fn promptOpParams(L: *VM.lua.State, allocator: std.mem.Allocator, params_args: []const u8) !void {
    if (params_args.len <= 0) {
        printResult("Usage: params <command>\n", .{});
        printResult("  try 'params help'\n", .{});
        return;
    }

    const command_input, const rest = getNextArg(params_args);
    switch (LOCALS_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown params command\n", .{});
    }) {
        .help => { // params help
            printResult("Params Commands:\n", .{});
            printResult("  help - Show sub-commands\n", .{});
            printResult("  list - List params and their value (if argument is passed to params command)\n", .{});
        },
        .list => { // params list <n> <n>?,<n>?,...
            const level_in, const args_rest = getNextArg(rest);
            var level: i32 = 0;
            if (level_in.len > 0) {
                level = std.fmt.parseInt(i32, level_in, 10) catch |err| {
                    return printResult("Level Parse Error: {}\n", .{err});
                };
            }
            var ar: VM.lua.Debug = .{ .ssbuf = undefined };
            switch (DEBUG.output) {
                .Readable => {
                    if (!L.checkstack(2))
                        return printResult("stack overflow.\n", .{});
                    if (!L.getinfo(level, "a", &ar))
                        return printResult("no function found.\n", .{}); // nothing
                    var i: i32 = 1;
                    var showed: bool = false;
                    while (true) : (i += 1) {
                        if (L.getargument(level, i)) {
                            defer L.pop(1);
                            showed = true;
                            if (i > ar.nparams)
                                printResult(" {d} -> vararg: ({s})\n", .{ i, @tagName(L.typeOf(-1)) })
                            else
                                printResult(" {d} -> ({s})\n", .{ i, @tagName(L.typeOf(-1)) });
                            if (level_in.len == 0)
                                continue;

                            var buf = std.ArrayList(u8).init(allocator);
                            defer buf.deinit();

                            const writer = buf.writer();
                            try formatter.fmt_write_idx(allocator, L, writer, @intCast(L.gettop()), formatter.MAX_DEPTH);
                            var iter = std.mem.splitScalar(u8, buf.items, '\n');
                            printResult(" | Value: {s}\n", .{iter.first()});
                            while (iter.next()) |line|
                                printResult(" |  {s}\n", .{line});
                        } else break;
                    }
                    if (!showed)
                        printResult("No params found.\n", .{});
                },
                .Json => {
                    if (!L.checkstack(6))
                        return printResult("[]\n", .{}); // stack overflow
                    if (!L.getinfo(level, "a", &ar))
                        return printResult("[]\n", .{}); // nothing
                    var iter = std.mem.splitScalar(u8, std.mem.trimLeft(u8, args_rest, " "), ',');

                    var buf = std.ArrayList(u8).init(allocator);
                    defer buf.deinit();
                    const writer = buf.writer();

                    try buf.append('[');
                    const first_iter = iter.first();
                    if (first_iter.len > 0) {
                        const initial_idx = std.fmt.parseInt(u32, first_iter, 10) catch |err| {
                            return printResult("Id Parse Error: {}\n", .{err});
                        };
                        if (!L.getargument(level, @intCast(initial_idx)))
                            return printResult("[]\n", .{});
                        defer L.pop(1);
                        if (!try variableJsonDisassemble(allocator, L, &iter, writer))
                            return;
                    } else {
                        var i: i32 = 1;
                        var first = false;
                        while (true) : (i += 1) {
                            if (L.getargument(level, i)) {
                                defer L.pop(1);
                                if (first)
                                    try buf.append(',');
                                first = true;
                                const typename = VM.lapi.typename(L.typeOf(-1));
                                const value = tostring(L, -1);
                                defer L.pop(1);

                                const value_base64_buf, const base64_value = try toBase64(allocator, value);
                                defer allocator.free(value_base64_buf);
                                if (i > ar.nparams)
                                    try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"literal\",\"value_type\":\"{s}\"}}", .{
                                        i,
                                        "var",
                                        base64_value,
                                        typename,
                                    })
                                else
                                    try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"literal\",\"value_type\":\"{s}\"}}", .{
                                        i,
                                        "param",
                                        base64_value,
                                        typename,
                                    });
                            } else break;
                        }
                    }
                    try buf.append(']');
                    printResult("{s}\n", .{buf.items});
                },
            }
        },
    }
}

fn promptOpUpvalues(L: *VM.lua.State, allocator: std.mem.Allocator, params_args: []const u8) !void {
    if (params_args.len <= 0) {
        printResult("Usage: upvalues <command>\n", .{});
        printResult("  try 'upvalues help'\n", .{});
        return;
    }

    const command_input, const rest = getNextArg(params_args);
    switch (LOCALS_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown upvalues command\n", .{});
    }) {
        .help => { // upvalues help
            printResult("Upvalues Commands:\n", .{});
            printResult("  help - Show sub-commands\n", .{});
            printResult("  list - List upvalues and their value (if argument is passed to upvalues command)\n", .{});
        },
        .list => { // upvalues list <n> <n>?,<n>?,...
            const level_in, const args_rest = getNextArg(rest);
            var level: i32 = 0;
            if (level_in.len > 0) {
                level = std.fmt.parseInt(i32, level_in, 10) catch |err| {
                    return printResult("Level Parse Error: {}\n", .{err});
                };
            }
            var ar: VM.lua.Debug = .{ .ssbuf = undefined };
            switch (DEBUG.output) {
                .Readable => {
                    if (!L.checkstack(3))
                        return printResult("stack overflow.\n", .{});
                    if (!L.getinfo(level, "af", &ar))
                        return printResult("no function found.\n", .{}); // nothing
                    defer L.pop(1); // remove function
                    const fn_idx = L.gettop();
                    var i: i32 = 1;
                    var showed: bool = false;
                    while (true) : (i += 1) {
                        if (L.getupvalue(@intCast(fn_idx), i)) |name| {
                            defer L.pop(1);
                            showed = true;
                            printResult(" {d} -> {s} ({s})\n", .{ i, name, @tagName(L.typeOf(-1)) });
                            if (level_in.len == 0)
                                continue;

                            var buf = std.ArrayList(u8).init(allocator);
                            defer buf.deinit();

                            const writer = buf.writer();
                            try formatter.fmt_write_idx(allocator, L, writer, @intCast(L.gettop()), formatter.MAX_DEPTH);
                            var iter = std.mem.splitScalar(u8, buf.items, '\n');
                            printResult(" | Value: {s}\n", .{iter.first()});
                            while (iter.next()) |line|
                                printResult(" |  {s}\n", .{line});
                        } else break;
                    }
                    if (!showed)
                        printResult("No upvalue found.\n", .{});
                },
                .Json => {
                    if (!L.checkstack(7))
                        return printResult("[]\n", .{}); // stack overflow
                    if (!L.getinfo(level, "af", &ar))
                        return printResult("[]\n", .{}); // nothing
                    defer L.pop(1); // remove function
                    const fn_idx = L.gettop();
                    var iter = std.mem.splitScalar(u8, std.mem.trimLeft(u8, args_rest, " "), ',');

                    var buf = std.ArrayList(u8).init(allocator);
                    defer buf.deinit();
                    const writer = buf.writer();

                    try buf.append('[');
                    const first_iter = iter.first();
                    if (first_iter.len > 0) {
                        const initial_idx = std.fmt.parseInt(u32, first_iter, 10) catch |err| {
                            return printResult("Id Parse Error: {}\n", .{err});
                        };
                        _ = L.getupvalue(@intCast(fn_idx), @intCast(initial_idx)) orelse {
                            return printResult("[]\n", .{});
                        };
                        defer L.pop(1);
                        if (!try variableJsonDisassemble(allocator, L, &iter, writer))
                            return;
                    } else {
                        var i: i32 = 1;
                        var first = false;
                        while (true) : (i += 1) {
                            if (L.getupvalue(@intCast(fn_idx), i)) |name| {
                                defer L.pop(1);
                                if (first)
                                    try buf.append(',');
                                first = true;
                                const typename = VM.lapi.typename(L.typeOf(-1));
                                const value = tostring(L, -1);
                                defer L.pop(1);

                                const value_base64_buf, const base64_value = try toBase64(allocator, value);
                                defer allocator.free(value_base64_buf);
                                try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"literal\",\"value_type\":\"{s}\"}}", .{
                                    i,
                                    name,
                                    base64_value,
                                    typename,
                                });
                            } else break;
                        }
                    }
                    try buf.append(']');
                    printResult("{s}\n", .{buf.items});
                },
            }
        },
    }
}

fn promptOpGlobals(L: *VM.lua.State, allocator: std.mem.Allocator, globals_args: []const u8) !void {
    if (globals_args.len <= 0) {
        printResult("Usage: globals <command>\n", .{});
        printResult("  try 'globals help'\n", .{});
        return;
    }

    const command_input, const rest = getNextArg(globals_args);
    switch (LOCALS_COMMAND_MAP.get(command_input) orelse {
        return printResult("Unknown globals command\n", .{});
    }) {
        .help => { // globals help
            printResult("Globals Commands:\n", .{});
            printResult("  help - Show sub-commands\n", .{});
            printResult("  list - List globals and their value (if argument is passed to globals command)\n", .{});
        },
        .list => { // globals list <n> <n>?,<n>?,...
            const level_in, const args_rest = getNextArg(rest);
            var level: i32 = 0;
            if (level_in.len > 0) {
                level = std.fmt.parseInt(i32, level_in, 10) catch |err| {
                    return printResult("Level Parse Error: {}\n", .{err});
                };
            }
            var ar: VM.lua.Debug = .{ .ssbuf = undefined };
            switch (DEBUG.output) {
                .Readable => {
                    if (!L.checkstack(4))
                        return printResult("stack overflow.\n", .{});
                    if (!L.getinfo(level, "af", &ar))
                        return printResult("no function found.\n", .{}); // nothing
                    L.getfenv(-1);
                    defer L.pop(1); // remove env
                    L.remove(-2); // remove function
                    if (L.typeOf(-1) != .Table)
                        return printResult("global is not a table.\n", .{}); // invalid
                    L.pushnil();
                    var showed: bool = false;
                    while (L.next(-2)) {
                        defer L.pop(1);
                        showed = true;
                        const key = tostring(L, -2);
                        defer L.pop(1);
                        printResult(" {s} -> ({s})\n", .{ key, @tagName(L.typeOf(-1)) });
                        if (level_in.len == 0)
                            continue;
                        var buf = std.ArrayList(u8).init(allocator);
                        defer buf.deinit();

                        const writer = buf.writer();
                        try formatter.fmt_write_idx(allocator, L, writer, @intCast(L.gettop()), formatter.MAX_DEPTH);
                        var iter = std.mem.splitScalar(u8, buf.items, '\n');
                        printResult(" | Value: {s}\n", .{iter.first()});
                        while (iter.next()) |line|
                            printResult(" |  {s}\n", .{line});
                    }
                    if (!showed)
                        printResult("No globals found.\n", .{});
                },
                .Json => {
                    if (!L.checkstack(7))
                        return printResult("[]\n", .{}); // stack overflow
                    if (!L.getinfo(level, "af", &ar))
                        return printResult("[]\n", .{}); // nothing
                    L.getfenv(-1);
                    defer L.pop(1); // remove env
                    L.remove(-2); // remove function
                    if (L.typeOf(-1) != .Table)
                        return printResult("[]\n", .{}); // invalid
                    var iter = std.mem.splitScalar(u8, std.mem.trimLeft(u8, args_rest, " "), ',');

                    var buf = std.ArrayList(u8).init(allocator);
                    defer buf.deinit();
                    const writer = buf.writer();

                    try buf.append('[');
                    const first_iter = iter.first();
                    if (first_iter.len > 0) {
                        iter.reset();
                        if (!try variableJsonDisassemble(allocator, L, &iter, writer))
                            return;
                    } else {
                        var order: u32 = 1;
                        var first = false;
                        L.pushnil();
                        while (L.next(-2)) {
                            defer L.pop(3); // remove str_value, str_key, value
                            order += 1;
                            if (first)
                                try buf.append(',');
                            first = true;
                            const key_typename = VM.lapi.typename(L.typeOf(-2));
                            const value_typename = VM.lapi.typename(L.typeOf(-1));
                            const key = tostring(L, -2);
                            const value = tostring(L, -2);

                            const key_base64_buf, const base64_key = try toBase64(allocator, key);
                            defer allocator.free(key_base64_buf);
                            const value_base64_buf, const base64_value = try toBase64(allocator, value);
                            defer allocator.free(value_base64_buf);
                            try writer.print("{{\"id\":{d},\"key\":\"{s}\",\"value\":\"{s}\",\"key_type\":\"{s}\",\"value_type\":\"{s}\"}}", .{
                                order,
                                base64_key,
                                base64_value,
                                key_typename,
                                value_typename,
                            });
                        }
                    }
                    try buf.append(']');
                    printResult("{s}\n", .{buf.items});
                },
            }
        },
    }
}

const StepMode = enum {
    Step,
    Run,
};

const OutputMode = enum {
    Readable,
    Json,
};

const BreakKind = enum {
    None,
    Breakpoint,
    Stepped,
    HandledException,
    UnhandledException,
};

const DebugState = struct {
    depth: ?usize = null,
    line: ?usize = null,
    step: StepMode = .Step,
    output: OutputMode = .Readable,
    dead: bool = false,
    handled_exception: bool = false,
    unhandled_exception: bool = false,
};
pub var DEBUG: DebugState = .{};

pub fn prompt(L: *VM.lua.State, comptime kind: BreakKind, debug_info: ?*VM.lua.c.lua_Debug) !void {
    const allocator = luau.getallocator(L);

    var stdin = std.io.getStdIn();
    var in_reader = stdin.reader();

    const terminal = &(Zune.corelib.io.TERMINAL orelse std.debug.panic("Terminal not initialized", .{}));
    const history = debug.HISTORY orelse std.debug.panic("History not initialized", .{});

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var position: usize = 0;

    try terminal.setRawMode();
    try terminal.setOutputMode();

    if (DEBUG.output == .Readable) {
        switch (kind) {
            .None => {},
            .Breakpoint, .Stepped => |k| {
                const ar = debug_info orelse std.debug.panic(DEBUG_RESULT_TAG ++ "Debugger crashed, missing debug info for breakpoint", .{});
                if (k == .Breakpoint)
                    printResult("break at line: {d}\n", .{ar.currentline})
                else
                    printResult("step at line: {d}\n", .{ar.currentline});
            },
            .HandledException => printResult("break on handled exception\n", .{}),
            .UnhandledException => printResult("break on unhandled exception\n", .{}),
        }
    } else {
        switch (kind) {
            .None => {},
            .Breakpoint, .Stepped => |k| {
                const ar = debug_info orelse std.debug.panic(DEBUG_RESULT_TAG ++ "Debugger crashed, missing debug info for breakpoint", .{});
                printResult("{{\"break\":{d},\"line\":{d}}}\n", .{ @intFromEnum(k), ar.currentline });
            },
            .HandledException, .UnhandledException => printResult("{{\"break\":{d},\"line\":null}}\n", .{@intFromEnum(kind)}),
        }
    }
    std.debug.print(DEBUG_TAG, .{});

    while (true) {
        const byte = try in_reader.readByte();
        if (byte == 0x1B) {
            if (try in_reader.readByte() != '[') continue;
            switch (try in_reader.readByte()) {
                'A' => { // Up Arrow
                    if (history.size() == 0)
                        continue;
                    if (history.isLatest())
                        history.saveTemp(buffer.items);
                    if (history.previous()) |line| {
                        buffer.clearRetainingCapacity();
                        try buffer.appendSlice(line);
                        position = line.len;

                        try terminal.clearLine();
                        print("{s}", .{buffer.items});
                    }
                },
                'B' => { // Down Arrow
                    if (history.next()) |line| {
                        buffer.clearRetainingCapacity();
                        try buffer.appendSlice(line);
                        position = line.len;

                        try terminal.clearLine();
                        print("{s}", .{buffer.items});
                    }
                    if (history.isLatest())
                        history.clearTemp();
                },
                'C' => { // Right Arrow
                    if (position < buffer.items.len) {
                        try terminal.moveCursor(.Right);
                        position += 1;
                    }
                },
                'D' => { // Left Arrow
                    if (position > 0) {
                        try terminal.moveCursor(.Left);
                        position -= 1;
                    }
                },
                else => {},
            }
        } else if (byte == Terminal.NEW_LINE) {
            std.debug.print("\n", .{});
            out: {
                defer position = 0;
                defer buffer.clearAndFree();

                defer history.reset();

                history.save(buffer.items);

                if (buffer.items.len == 0)
                    break :out;
                const command_input, const rest = getNextArg(buffer.items);
                switch (COMMAND_MAP.get(command_input) orelse {
                    break :out printResult("Unknown command\n", .{});
                }) {
                    .help => {
                        printResult("Commands:\n", .{});
                        printResult("  help      - Display this message\n", .{});
                        printResult("  exit      - Terminate debugger\n", .{});
                        printResult("  break     - modify Breakpoint\n", .{});
                        printResult("  modules   - Loaded modules\n", .{});
                        printResult("  line      - Show current line\n", .{});
                        printResult("  file      - Show current file\n", .{});
                        printResult("  trace     - Show stack trace\n", .{});
                        printResult("  step      - Step into\n", .{});
                        printResult("  stepi     - Step instruction\n", .{});
                        printResult("  stepo     - Step out\n", .{});
                        printResult("  next      - Step over\n", .{});
                        printResult("  run       - Continue execution\n", .{});
                        printResult("  locals    - Local variables\n", .{});
                        printResult("  params    - Parameters\n", .{});
                        printResult("  upvalues  - Upvalues\n", .{});
                        printResult("  globals   - Global variables\n", .{});
                        printResult("  restart   - Restart execution\n", .{});
                        printResult("  exception - Show current error\n", .{});
                    },
                    .exit => {
                        debug.DebuggerExit();
                        std.process.exit(0);
                    },
                    .line => {
                        if (debug_info) |ar| {
                            if (ar.currentline > 0)
                                printResult("current line: {d}\n", .{ar.currentline})
                            else
                                printResult("unknown line (C call)\n", .{});
                            break :out;
                        }
                        printResult("No debug info available\n", .{});
                    },
                    .file => {
                        defer L.pop(1);
                        if (!L.checkstack(2)) {
                            if (DEBUG.output == .Readable)
                                printResult("stack overflow.\n", .{})
                            else
                                printResult("null\n", .{});
                            break :out;
                        }
                        if (L.getglobal("_FILE") != .Table) {
                            if (DEBUG.output == .Readable)
                                printResult("file info not available.\n", .{})
                            else
                                printResult("null\n", .{});
                            break :out;
                        }
                        defer L.pop(1);
                        if (L.getfield(-1, "path") != .String) {
                            if (DEBUG.output == .Readable)
                                printResult("file info invalid.\n", .{})
                            else
                                printResult("null\n", .{});
                            break :out;
                        }
                        const path = L.tostring(-1).?;
                        if (DEBUG.output == .Readable)
                            printResult("current file: {s}\n", .{path})
                        else
                            printResult("\"{s}\"\n", .{path});
                    },
                    .trace => {
                        const args = std.mem.trimLeft(u8, rest, " ");
                        const levels_index = std.mem.indexOf(u8, args, " ") orelse args.len;
                        var levels: u32 = 0;
                        if (levels_index > 0) {
                            levels = std.fmt.parseInt(u32, args[0..levels_index], 10) catch |err| {
                                break :out printResult("Levels Parse Error: {}\n", .{err});
                            };
                        }
                        var level_depth: u32 = 0;
                        var ar: VM.lua.Debug = .{ .ssbuf = undefined };
                        switch (DEBUG.output) {
                            .Readable => {
                                while (L.getinfo(@intCast(level_depth), "sln", &ar)) : (level_depth += 1) {
                                    if (level_depth > levels and levels != 0)
                                        break;
                                    if (level_depth == 0) {
                                        if (ar.name) |fn_name| {
                                            printResult("from {s} in {s} (line {d})\n", .{
                                                fn_name,
                                                ar.short_src.?,
                                                ar.currentline orelse ar.linedefined orelse 0,
                                            });
                                        } else {
                                            printResult("in {s} (line {d})\n", .{
                                                ar.short_src.?,
                                                ar.currentline orelse ar.linedefined orelse 0,
                                            });
                                        }
                                    } else {
                                        if (ar.name) |fn_name| {
                                            printResult("- {d}: {s} in {s} (line {d})\n", .{
                                                level_depth,
                                                fn_name,
                                                ar.short_src.?,
                                                ar.currentline orelse ar.linedefined orelse 0,
                                            });
                                        } else {
                                            printResult("- {d}: {s} (line {d})\n", .{
                                                level_depth,
                                                ar.short_src.?,
                                                ar.currentline orelse ar.linedefined orelse 0,
                                            });
                                        }
                                    }
                                }
                            },
                            .Json => {
                                var buf = std.ArrayList(u8).init(allocator);
                                defer buf.deinit();
                                const writer = buf.writer();
                                try buf.append('[');
                                while (L.getinfo(@intCast(level_depth), "sln", &ar)) : (level_depth += 1) {
                                    if (level_depth > levels and levels != 0)
                                        break;
                                    if (level_depth > 0)
                                        try buf.append(',');
                                    const src_base64_buf, const base64_src = try toBase64(allocator, ar.short_src.?);
                                    defer allocator.free(src_base64_buf);
                                    if (ar.name) |fn_name|
                                        try writer.print("{{\"name\":\"{s}\",\"src\":\"{s}\",\"line\":{d},\"context\":{d}}}", .{
                                            fn_name,
                                            base64_src,
                                            ar.currentline orelse ar.linedefined orelse 0,
                                            @intFromEnum(ar.what),
                                        })
                                    else
                                        try writer.print("{{\"name\":null,\"src\":\"{s}\",\"line\":{d},\"context\":{d}}}", .{
                                            base64_src,
                                            ar.currentline orelse ar.linedefined orelse 0,
                                            @intFromEnum(ar.what),
                                        });
                                }
                                try buf.append(']');
                                printResult("{s}\n", .{buf.items});
                            },
                        }
                    },
                    .@"break" => try promptOpBreak(L, allocator, rest),
                    .modules => {
                        switch (DEBUG.output) {
                            .Readable => {
                                printResult("Modules ({d}):\n", .{MODULE_REFERENCES.count()});
                                var iter = MODULE_REFERENCES.iterator();
                                while (iter.next()) |entry|
                                    printResult("  {s} -> id: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                                break :out;
                            },
                            .Json => {
                                var buf = std.ArrayList(u8).init(allocator);
                                defer buf.deinit();
                                const writer = buf.writer();

                                try buf.append('{');
                                var first = false;
                                var iter = MODULE_REFERENCES.iterator();
                                while (iter.next()) |entry| {
                                    if (first)
                                        try buf.append(',');
                                    try writer.print("\"{s}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* });
                                    first = true;
                                }
                                try buf.append('}');
                                printResult("{s}\n", .{buf.items});
                            },
                        }
                    },
                    .step => {
                        DEBUG.step = .Step;
                        if (debug_info) |ar|
                            if (ar.currentline > 0) {
                                DEBUG.line = @intCast(ar.currentline);
                            };

                        try terminal.setNormalMode();
                        break;
                    },
                    .step_out => {
                        DEBUG.step = .Step;
                        const depth = L.stackdepth();
                        if (depth > 0) {
                            DEBUG.depth = depth - 1;
                            try terminal.setNormalMode();
                        }
                        break;
                    },
                    .step_instruction => {
                        DEBUG.step = .Step;
                        try terminal.setNormalMode();
                        break;
                    },
                    .next => {
                        DEBUG.step = .Step;
                        DEBUG.depth = L.stackdepth();
                        if (debug_info) |ar|
                            if (ar.currentline > 0) {
                                DEBUG.line = @intCast(ar.currentline);
                            };
                        try terminal.setNormalMode();
                        break;
                    },
                    .locals => try promptOpLocals(L, allocator, rest),
                    .params => try promptOpParams(L, allocator, rest),
                    .upvalues => try promptOpUpvalues(L, allocator, rest),
                    .globals => try promptOpGlobals(L, allocator, rest),
                    .run => {
                        DEBUG.step = .Run;
                        try terminal.setNormalMode();
                        break;
                    },
                    .restart => {
                        // force a break, ignoring yield status
                        L.curr_status = @intFromEnum(VM.lua.Status.Break);
                        DEBUG.dead = true;
                        Scheduler.KillSchedulers();
                        return;
                    },
                    .output_mode => {
                        const option = std.mem.trimLeft(u8, rest, " ");
                        if (std.mem.eql(u8, option, "json")) {
                            DEBUG.output = .Json;
                            printResult("{{\"mode\":\"json\"}}\n", .{});
                        } else {
                            DEBUG.output = .Readable;
                            printResult("Output mode set to readable\n", .{});
                        }
                    },
                    .exception => {
                        const option, const args_rest = getNextArg(rest);
                        const enabled = std.mem.eql(u8, std.mem.trimLeft(u8, args_rest, " "), "true");
                        if (std.mem.eql(u8, option, "UnhandledError")) {
                            DEBUG.unhandled_exception = enabled;
                            switch (DEBUG.output) {
                                .Readable => printResult("UnhandledError set to {}\n", .{DEBUG.unhandled_exception}),
                                .Json => printResult("{{\"success\":true,\"state\":{}}}\n", .{DEBUG.unhandled_exception}),
                            }
                        } else if (std.mem.eql(u8, option, "HandledError")) {
                            DEBUG.handled_exception = enabled;
                            switch (DEBUG.output) {
                                .Readable => printResult("HandledError set to {}\n", .{DEBUG.handled_exception}),
                                .Json => printResult("{{\"success\":true,\"state\":{}}}\n", .{DEBUG.handled_exception}),
                            }
                        } else {
                            switch (DEBUG.output) {
                                .Readable => {
                                    if (kind == .UnhandledException or kind == .HandledException) {
                                        if (L.gettop() > 0) {
                                            if (!L.checkstack(1))
                                                break :out printResult("stack overflow.\n", .{}); // stack overflow
                                            const err = tostring(L, -1);
                                            defer L.pop(1);
                                            break :out printResult("Error: {s}\n", .{err});
                                        }
                                    }
                                    printResult("No errors found.\n", .{});
                                },
                                .Json => {
                                    if (kind == .UnhandledException or kind == .HandledException) {
                                        if (L.gettop() > 0) {
                                            if (!L.checkstack(1))
                                                break :out printResult("{{\"reason\":null,\"type\":null,\"kind\":{d}}}\n", .{@intFromEnum(kind)}); // stack overflow
                                            const typename = VM.lapi.typename(L.typeOf(-1));
                                            const err = tostring(L, -1);
                                            defer L.pop(1);
                                            const err_base64_buf, const base64_err = try toBase64(allocator, err);
                                            defer allocator.free(err_base64_buf);
                                            break :out printResult("{{\"reason\":\"{s}\",\"type\":\"{s}\",\"kind\":{d}}}\n", .{ base64_err, typename, @intFromEnum(kind) });
                                        }
                                    }
                                    printResult("{{\"reason\":null,\"type\":null,\"kind\":{d}}}\n", .{@intFromEnum(kind)});
                                },
                            }
                        }
                    },
                }
            }
            try terminal.clearStyles();
            print("", .{});
        } else if (byte == 127) {
            if (position > 0) {
                const append = position < buffer.items.len;
                std.debug.print("{c}", .{127});
                try terminal.moveCursor(.Left);
                position -= 1;
                _ = buffer.orderedRemove(position);
                try terminal.clearEndToCursor();
                if (append)
                    try terminal.writeAllRetainCursor(buffer.items[position..]);
            }
        } else if (byte == 3 or byte == 4) {
            terminal.restoreSettings() catch {};
            terminal.restoreOutputMode() catch {};
            std.process.exit(0);
        } else {
            if (buffer.items.len > 256)
                @panic("Buffer Maximized");
            switch (byte) {
                22...31 => continue,
                else => {},
            }
            const append = position < buffer.items.len;
            try buffer.insert(position, byte);
            std.debug.print("{c}", .{byte});
            position += 1;
            if (append)
                try terminal.writeAllRetainCursor(buffer.items[position..]);
        }
    }
}

pub fn debugstep(L: *VM.lua.State, ar: *VM.lua.c.lua_Debug) callconv(.C) void {
    if (DEBUG.step == .Run or DEBUG.dead)
        return;
    if (DEBUG.line) |line| {
        if (ar.currentline < 0 or @as(usize, @intCast(ar.currentline)) == line)
            return;
        DEBUG.line = null;
    }
    if (DEBUG.depth) |depth| {
        if (L.stackdepth() > depth)
            return;
        DEBUG.depth = null;
    }
    prompt(L, .Stepped, ar) catch |err| {
        std.debug.panic("Error: {}\n", .{err});
    };
}

pub fn debugbreak(L: *VM.lua.State, ar: *VM.lua.c.lua_Debug) callconv(.C) void {
    if (DEBUG.dead)
        return;
    prompt(L, .Breakpoint, ar) catch |err| {
        std.debug.panic("Error: {}\n", .{err});
    };
}

pub fn luau_panic(L: *VM.lua.State, errcode: i32) void {
    if (DEBUG.dead or !DEBUG.unhandled_exception)
        return;
    _ = errcode;
    prompt(L, .UnhandledException, null) catch |err| {
        std.debug.panic("Error: {}\n", .{err});
    };
}

pub fn debugprotectederror(L: *VM.lua.State) callconv(.C) void {
    if (DEBUG.dead or !DEBUG.handled_exception)
        return;
    prompt(L, .HandledException, null) catch |err| {
        std.debug.panic("Error: {}\n", .{err});
    };
}
