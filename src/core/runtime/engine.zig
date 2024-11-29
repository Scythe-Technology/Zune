const std = @import("std");
const luau = @import("luau");

const Zune = @import("../../zune.zig");
const file = @import("../resolvers/file.zig");
const require = @import("../resolvers/require.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const Luau = luau.Luau;

pub var DEBUG_LEVEL: u2 = 2;
pub var OPTIMIZATION_LEVEL: u2 = 1;
pub var CODEGEN: bool = true;
pub var JIT_ENABLED: bool = true;
pub var USE_DETAILED_ERROR: bool = false;

pub const LuauCompileError = error{
    Syntax,
};

pub const LuauRunError = enum {
    Runtime,
};

pub fn compileModule(allocator: std.mem.Allocator, content: []const u8, cOpts: ?luau.CompileOptions) !struct { bool, []const u8 } {
    const compileOptions = cOpts orelse luau.CompileOptions{
        .debug_level = DEBUG_LEVEL,
        .optimization_level = OPTIMIZATION_LEVEL,
    };
    var luau_allocator = luau.Ast.Allocator.Allocator.init();
    defer luau_allocator.deinit();

    var astNameTable = luau.Ast.Lexer.AstNameTable.init(luau_allocator);
    defer astNameTable.deinit();

    var parseResult = luau.Ast.Parser.parse(content, astNameTable, luau_allocator);
    defer parseResult.deinit();

    const hasNativeFunction = parseResult.hasNativeFunction();

    return .{ hasNativeFunction, try luau.Compiler.compileParseResult(allocator, parseResult, astNameTable, compileOptions) };
}

pub fn loadModule(L: *Luau, name: [:0]const u8, content: []const u8, cOpts: ?luau.CompileOptions) !void {
    const allocator = L.allocator();
    const native, const bytecode = try compileModule(allocator, content, cOpts);
    defer allocator.free(bytecode);
    return try loadModuleBytecode(L, name, bytecode, native);
}

pub fn loadModuleBytecode(L: *Luau, moduleName: [:0]const u8, bytecode: []const u8, nativeAttribute: bool) LuauCompileError!void {
    L.loadBytecode(moduleName, bytecode) catch {
        return LuauCompileError.Syntax;
    };
    if (luau.CodeGen.Supported() and CODEGEN and !nativeAttribute and JIT_ENABLED)
        luau.CodeGen.Compile(L, -1);
}

const FileContext = struct {
    path: []const u8,
    name: []const u8,
    source: []const u8,
};

const StackInfo = struct {
    what: luau.DebugInfo.FnType,
    name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    source_line: ?i32 = null,
    current_line: ?i32 = null,
};

pub fn setLuaFileContext(L: *Luau, ctx: FileContext) void {
    L.newTable();
    L.setFieldLString(-1, "name", ctx.name);
    L.setFieldLString(-1, "path", ctx.path);

    // TODO: Only include source when USE_DETAILED_ERROR is true or testing.
    // if (USE_DETAILED_ERROR)
    L.setFieldLString(-1, "source", ctx.source);

    L.setField(luau.GLOBALSINDEX, "_FILE");
}

pub fn printSpacedPadding(padding: []u8) void {
    @memset(padding, ' ');
    std.debug.print("{s}|\n", .{padding});
}

pub fn printPreviewError(padding: []u8, line: i32, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}|\n", .{padding});
    _ = std.fmt.bufPrint(padding, "{d}", .{line}) catch |e| std.debug.panic("{}", .{e});
    std.debug.print("{s}~ \x1b[2mPreviewError: " ++ fmt ++ "\x1b[0m\n", .{padding} ++ args);
    @memset(padding, ' ');
    std.debug.print("{s}|\n", .{padding});
}

pub fn logDetailedError(L: *Luau) !void {
    const allocator = L.allocator();

    var list = std.ArrayList(StackInfo).init(allocator);
    defer list.deinit();
    defer for (list.items) |item| {
        if (item.name) |name|
            allocator.free(name);
        if (item.source) |source|
            allocator.free(source);
    };

    var ar: luau.DebugInfo = undefined;
    var level: i32 = 0;
    while (L.getInfo(level, .{ .s = true, .l = true, .n = true }, &ar)) : (level += 1) {
        var info: StackInfo = .{
            .what = ar.what,
        };
        if (ar.name) |name|
            info.name = try allocator.dupe(u8, name);
        if (ar.line_defined) |line|
            info.source_line = line;
        if (ar.current_line) |line|
            info.current_line = line;

        info.source = try allocator.dupe(u8, ar.source);

        try list.append(info);
    }

    var err_msg = L.toString(-1) catch "UnknownError";

    if (list.items.len < 1) {
        std.debug.print("\x1b[32merror\x1b[0m: {s}\n", .{err_msg});
        std.debug.print("{s}\n", .{L.debugTrace()});
        return;
    }

    Luau.sys.luaD_checkstack(L, 5);
    Luau.sys.luaD_expandstacklimit(L, 5);

    var reference_level: ?usize = null;
    jmp: {
        const item = blk: {
            for (list.items, 0..) |item, lvl|
                if (item.what == .luau) {
                    reference_level = lvl;
                    break :blk item;
                };
            break :blk list.items[0];
        };
        if (item.source == null or item.current_line == null)
            break :jmp;
        const strip = try std.fmt.allocPrint(allocator, "[string \"{s}\"]:{d}: ", .{
            item.source.?,
            item.current_line.?,
        });
        defer allocator.free(strip);

        const pos = std.mem.indexOfPosLinear(u8, err_msg, 0, strip);
        if (pos) |p|
            err_msg = err_msg[p + strip.len ..];
    }

    var largest_line: usize = 0;
    for (list.items) |info| {
        if (info.current_line) |line|
            largest_line = @max(largest_line, @as(usize, @intCast(line)));
        if (info.source_line) |line| {
            if (line > 0)
                largest_line = @max(largest_line, @as(usize, @intCast(line)));
        }
    }
    const padding = std.math.log10(largest_line) + 1;

    std.debug.print("\x1b[31merror\x1b[0m: {s}\n", .{err_msg});

    const padded_string = try allocator.alloc(u8, padding + 1);
    defer allocator.free(padded_string);
    @memset(padded_string, ' ');

    for (list.items, 0..) |info, lvl| {
        if (info.current_line == null or info.current_line.? < 0)
            continue;
        if (info.source) |src| blk: {
            const current_line = info.current_line.?;

            std.debug.print("\x1b[1;4m{s}:{d}\x1b[0m\n", .{ src, current_line });

            if (!L.getInfo(@intCast(lvl), .{ .f = true }, &ar)) {
                printPreviewError(padded_string, current_line, "Failed to get function info", .{});
                continue;
            }

            if (L.typeOf(-1) != .function)
                return error.InternalError;
            L.getFenv(-1);
            defer L.pop(2); // drop: env, func
            if (L.typeOf(-1) != .table) {
                printPreviewError(padded_string, current_line, "Failed to get function environment", .{});
                continue;
            }
            defer L.pop(1); // drop: _FILE
            if (L.getField(-1, "_FILE") != .table) {
                printPreviewError(padded_string, current_line, "Failed to get file context", .{});
                continue;
            }
            defer L.pop(1); // drop: source
            if (L.getField(-1, "source") != .string) {
                printPreviewError(padded_string, current_line, "Failed to get file source", .{});
                continue;
            }
            const content = L.toString(-1) catch unreachable;

            var stream = std.io.fixedBufferStream(content);
            const reader = stream.reader();
            if (current_line > 1) for (0..@intCast(current_line - 1)) |_| {
                const buf = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize)) catch |e| {
                    printPreviewError(padded_string, current_line, "Failed to read line: {}", .{e});
                    continue;
                };
                defer if (buf) |b| allocator.free(b);
                if (buf == null) {
                    printPreviewError(padded_string, current_line, "Failed to read line, ended too early", .{});
                    break :blk;
                }
            };

            const line_content = reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize)) catch |e| {
                printPreviewError(padded_string, current_line, "Failed to read line: {}", .{e});
                continue;
            } orelse {
                printPreviewError(padded_string, current_line, "Failed to read line, ended too early", .{});
                break :blk;
            };
            defer allocator.free(line_content);

            std.debug.print("{s}|\n", .{padded_string});
            _ = std.fmt.bufPrint(padded_string, "{d}", .{current_line}) catch |e| std.debug.panic("{}", .{e});
            std.debug.print("{s}| {s}\n", .{ padded_string, line_content });
            @memset(padded_string, ' ');

            if (reference_level != null and reference_level.? == lvl) {
                const front_pos = std.mem.indexOfNonePos(u8, line_content, 0, " \t") orelse 0;
                const end_pos = std.mem.lastIndexOfNone(u8, line_content, " \t\r") orelse front_pos;
                const len = (end_pos - front_pos) + 1;

                const space_slice = line_content[0..front_pos];

                const buf = allocator.alloc(u8, len) catch |e| std.debug.panic("{}", .{e});
                defer allocator.free(buf);

                @memset(buf, '^');

                std.debug.print("{s}| {s}\x1b[31m{s}\x1b[0m\n", .{ padded_string, space_slice, buf });
            } else {
                std.debug.print("{s}|\n", .{padded_string});
            }
        }
    }
}

pub fn logError(L: *Luau, err: anyerror) void {
    switch (err) {
        error.Runtime => {
            if (USE_DETAILED_ERROR) {
                logDetailedError(L) catch |e| std.debug.panic("{}", .{e});
            } else {
                std.debug.print("{s}\n", .{L.toString(-1) catch "UnknownError"});
                std.debug.print("{s}\n", .{L.debugTrace()});
            }
        },
        else => {
            std.debug.print("Error: {}\n", .{err});
        },
    }
}

pub fn checkStatus(L: *Luau) !luau.Status {
    const status = L.status();
    switch (status) {
        .ok, .yield => return status,
        .err_syntax, .err_runtime => return error.Runtime,
        .err_memory => return error.Memory,
        .err_error => return error.MsgHandler,
    }
}

const PrepOptions = struct {
    args: []const []const u8,
};

pub fn prep(L: *Luau, pOpts: PrepOptions, flags: Zune.Flags) !void {
    if (luau.CodeGen.Supported() and JIT_ENABLED)
        luau.CodeGen.Create(L);

    L.openLibs();
    try Zune.openZune(L, pOpts.args, flags);
}

pub fn prepAsync(L: *Luau, sched: *Scheduler, pOpts: PrepOptions, flags: Zune.Flags) !void {
    L.pushLightUserdata(sched);
    L.setField(luau.REGISTRYINDEX, "_SCHEDULER");

    try prep(L, pOpts, flags);
}

const LuaFileType = enum {
    Lua,
    Luau,
};

pub fn getLuaFileType(path: []const u8) ?LuaFileType {
    if (path.len >= 4 and std.mem.eql(u8, path[path.len - 4 ..], ".lua"))
        return .Lua;
    if (path.len >= 5 and std.mem.eql(u8, path[path.len - 5 ..], ".luau"))
        return .Luau;
    return null;
}

pub fn findLuauFile(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !file.SearchResult([]const u8) {
    const absPath = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(absPath);
    return findLuauFileFromPath(allocator, absPath, fileName);
}

pub fn findLuauFileZ(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) !file.SearchResult([:0]const u8) {
    const absPath = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(absPath);
    return findLuauFileFromPathZ(allocator, absPath, fileName);
}

pub fn findLuauFileFromPath(allocator: std.mem.Allocator, absPath: []const u8, fileName: []const u8) !file.SearchResult([]const u8) {
    const absF = try std.fs.path.resolve(allocator, &.{ absPath, fileName });
    defer allocator.free(absF);
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;
    return try file.searchForExtensions(allocator, absF, &require.POSSIBLE_EXTENSIONS);
}

pub fn findLuauFileFromPathZ(allocator: std.mem.Allocator, absPath: []const u8, fileName: []const u8) !file.SearchResult([:0]const u8) {
    const absF = try std.fs.path.resolve(allocator, &.{ absPath, fileName });
    defer allocator.free(absF);
    if (getLuaFileType(fileName)) |_|
        return error.RedundantFileExtension;
    return try file.searchForExtensionsZ(allocator, absF, &require.POSSIBLE_EXTENSIONS);
}

pub fn stateCleanUp() void {
    if (Zune.corelib.stdio.TERMINAL) |*terminal| {
        if (terminal.stdout_istty and terminal.stdin_istty) {
            terminal.restoreSettings() catch std.debug.print("[Zune] Failed to restore terminal settings\n", .{});
            terminal.restoreOutputMode() catch std.debug.print("[Zune] Failed to restore terminal output mode\n", .{});
        }
    }
}

const RunOptions = struct {
    cleanUp: bool,
    testing: bool = false,
};

pub fn runAsync(L: *Luau, sched: *Scheduler, comptime options: RunOptions) !void {
    defer if (options.cleanUp) stateCleanUp();
    sched.deferThread(L, null, 0);
    sched.run(options.testing);
    _ = try checkStatus(L);
}

pub fn run(L: *Luau) !void {
    defer stateCleanUp();
    try L.pcall(0, 0, 0);
}

test "Run Basic" {
    const allocator = std.testing.allocator;
    const L = try Luau.init(&allocator);
    defer L.deinit();
    if (luau.CodeGen.Supported()) luau.CodeGen.Create(L);
    L.openLibs();
    try loadModule(L, "test", "tostring(\"Hello, World!\")\n", null);
    try run(L);
}

test "Run Basic Syntax Error" {
    const allocator = std.testing.allocator;
    const L = try Luau.init(&allocator);
    defer L.deinit();
    if (luau.CodeGen.Supported()) luau.CodeGen.Create(L);
    L.openLibs();
    try std.testing.expectError(LuauCompileError.Syntax, loadModule(L, "test", "print('Hello, World!'\n", null));
    try std.testing.expectEqualStrings("[string \"test\"]:2: Expected ')' (to close '(' at line 1), got <eof>", L.toString(-1) catch "UnknownError");
}

test {
    std.testing.refAllDecls(@This());
}
