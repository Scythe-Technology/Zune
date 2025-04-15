const std = @import("std");
const luau = @import("luau");

const Zune = @import("../../zune.zig");
const file = @import("../resolvers/file.zig");
const require = @import("../resolvers/require.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const VM = luau.VM;

pub var DEBUG_LEVEL: u2 = 2;
pub var OPTIMIZATION_LEVEL: u2 = 1;
pub var CODEGEN: bool = true;
pub var JIT_ENABLED: bool = true;
pub var USE_DETAILED_ERROR: bool = true;

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

    return .{ hasNativeFunction, try luau.Compiler.Compiler.compileParseResult(allocator, parseResult, astNameTable, compileOptions) };
}

pub fn loadModule(L: *VM.lua.State, name: [:0]const u8, content: []const u8, cOpts: ?luau.CompileOptions) !void {
    const allocator = luau.getallocator(L);
    var script = content;
    if (std.mem.startsWith(u8, content, "#!")) {
        const pos = std.mem.indexOf(u8, content, "\n") orelse content.len;
        script = content[pos..];
    }
    const native, const bytecode = try compileModule(allocator, script, cOpts);
    defer allocator.free(bytecode);
    return try loadModuleBytecode(L, name, bytecode, native);
}

pub fn loadModuleBytecode(L: *VM.lua.State, moduleName: [:0]const u8, bytecode: []const u8, nativeAttribute: bool) LuauCompileError!void {
    L.load(moduleName, bytecode, 0) catch {
        return LuauCompileError.Syntax;
    };
    if (luau.CodeGen.Supported() and CODEGEN and !nativeAttribute and JIT_ENABLED)
        luau.CodeGen.Compile(L, -1);
}

const FileContext = struct {
    path: []const u8,
    name: []const u8,
    source: []const u8,
    main: bool = false,
};

const StackInfo = struct {
    what: VM.lua.Debug.Context,
    name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    source_line: ?u32 = null,
    current_line: ?u32 = null,
};

pub fn setLuaFileContext(L: *VM.lua.State, ctx: FileContext) void {
    L.Zpushvalue(.{
        .name = ctx.name,
        .path = ctx.path,
        .source = ctx.source,
        .main = ctx.main,
    });

    // TODO: Only include source when USE_DETAILED_ERROR is true or testing.
    // if (USE_DETAILED_ERROR)
    // L.Zsetfield(-1, "source", ctx.source);

    L.setfield(VM.lua.GLOBALSINDEX, "_FILE");
}

pub fn printSpacedPadding(padding: []u8) void {
    @memset(padding, ' ');
    std.debug.print("{s}|\n", .{padding});
}

pub fn printPreviewError(padding: []u8, line: u32, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}|\n", .{padding});
    _ = std.fmt.bufPrint(padding, "{d}", .{line}) catch |e| std.debug.panic("{}", .{e});
    std.debug.print("{s}~ \x1b[2mPreviewError: " ++ fmt ++ "\x1b[0m\n", .{padding} ++ args);
    @memset(padding, ' ');
    std.debug.print("{s}|\n", .{padding});
}

pub fn logDetailedError(L: *VM.lua.State) !void {
    const allocator = luau.getallocator(L);

    var list = std.ArrayList(StackInfo).init(allocator);
    defer list.deinit();
    defer for (list.items) |item| {
        if (item.name) |name|
            allocator.free(name);
        if (item.source) |source|
            allocator.free(source);
    };

    var level: i32 = 0;
    var ar: VM.lua.Debug = .{ .ssbuf = undefined };
    while (L.getinfo(level, "sln", &ar)) : (level += 1) {
        var info: StackInfo = .{
            .what = ar.what,
        };
        if (ar.name) |name|
            info.name = try allocator.dupe(u8, name);
        if (ar.linedefined) |line|
            info.source_line = line;
        if (ar.currentline) |line|
            info.current_line = line;
        info.source = try allocator.dupe(u8, ar.source.?);

        try list.append(info);
    }

    var dynamic: bool = false;
    var err_msg: []const u8 = undefined;
    defer if (dynamic) allocator.free(err_msg);
    switch (L.typeOf(-1)) {
        .String, .Number => err_msg = L.tostring(-1).?,
        else => jmp: {
            if (!L.checkstack(2)) {
                err_msg = "StackOverflow";
                break :jmp;
            }
            const TL = L.newthread();
            defer L.pop(1); // drop: thread
            defer TL.resetthread();
            L.xpush(TL, -2);
            err_msg = try allocator.dupe(u8, TL.Ztolstring(1) catch |e| str: {
                switch (e) {
                    error.BadReturnType => break :str TL.Ztolstringk(1),
                    error.Runtime => break :str TL.Ztolstringk(1),
                    else => std.debug.panic("{}\n", .{e}),
                }
                return;
            });
            dynamic = true;
        },
    }

    if (list.items.len < 1) {
        std.debug.print("\x1b[32merror\x1b[0m: {s}\n", .{err_msg});
        std.debug.print("{s}\n", .{L.debugtrace()});
        return;
    }

    if (!L.checkstack(5)) {
        std.debug.print("Failed to show detailed error: StackOverflow\n", .{});
        std.debug.print("\x1b[32merror\x1b[0m: {s}\n", .{err_msg});
        std.debug.print("{s}\n", .{L.debugtrace()});
        return;
    }

    var reference_level: ?usize = null;
    jmp: {
        const item = blk: {
            for (list.items, 0..) |item, lvl|
                if (item.what == .lua) {
                    reference_level = lvl;
                    break :blk item;
                };
            break :blk list.items[0];
        };
        const source = item.source orelse break :jmp;
        const currentline = item.current_line orelse break :jmp;
        if (source.len < 1 and source[0] != '@')
            break :jmp;
        const strip = try std.fmt.allocPrint(allocator, "{s}:{d}: ", .{
            source[1..],
            currentline,
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
        if (info.current_line == null)
            continue;
        if (info.what != .lua)
            continue;
        if (info.source) |src| blk: {
            const current_line = info.current_line.?;

            std.debug.print("\x1b[1;4m{s}:{d}\x1b[0m\n", .{
                if (src.len > 1 and src[0] == '@') src[1..] else src,
                current_line,
            });

            if (!L.getinfo(@intCast(lvl), "f", &ar)) {
                printPreviewError(padded_string, current_line, "Failed to get function info", .{});
                continue;
            }

            if (L.typeOf(-1) != .Function)
                return error.InternalError;
            L.getfenv(-1);
            defer L.pop(2); // drop: env, func
            if (L.typeOf(-1) != .Table) {
                printPreviewError(padded_string, current_line, "Failed to get function environment", .{});
                continue;
            }
            defer L.pop(1); // drop: _FILE
            if (L.getfield(-1, "_FILE") != .Table) {
                printPreviewError(padded_string, current_line, "Failed to get file context", .{});
                continue;
            }
            defer L.pop(1); // drop: source
            if (L.getfield(-1, "source") != .String) {
                printPreviewError(padded_string, current_line, "Failed to get file source", .{});
                continue;
            }
            const content = L.tostring(-1) orelse unreachable;

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

pub fn logError(L: *VM.lua.State, err: anyerror, forceDetailed: bool) void {
    switch (err) {
        error.Runtime => {
            if (USE_DETAILED_ERROR or forceDetailed) {
                logDetailedError(L) catch |e| std.debug.panic("{}", .{e});
            } else {
                switch (L.typeOf(-1)) {
                    .String, .Number => std.debug.print("{s}\n", .{L.tostring(-1).?}),
                    else => jmp: {
                        if (!L.checkstack(2)) {
                            std.debug.print("StackOverflow\n", .{});
                        }
                        const TL = L.newthread();
                        defer L.pop(1); // drop: thread
                        defer TL.resetthread();
                        L.xpush(TL, -2);
                        const str = TL.Ztolstring(1) catch |e| str: {
                            switch (e) {
                                error.BadReturnType => break :str TL.Ztolstringk(1),
                                error.Runtime => break :str TL.Ztolstringk(1),
                                else => std.debug.panic("{}\n", .{e}),
                            }
                            break :jmp;
                        };
                        std.debug.print("{s}\n", .{str});
                    },
                }
                std.debug.print("{s}\n", .{L.debugtrace()});
            }
        },
        else => {
            std.debug.print("Error: {}\n", .{err});
        },
    }
}

pub fn checkStatus(L: *VM.lua.State) !VM.lua.Status {
    const status = L.status();
    switch (status) {
        .Ok, .Yield, .Break => return status,
        .ErrSyntax, .ErrRun => return error.Runtime,
        .ErrMem => return error.Memory,
        .ErrErr => return error.MsgHandler,
    }
}

const PrepOptions = struct {
    args: []const []const u8,
};

pub fn prep(L: *VM.lua.State, pOpts: PrepOptions, flags: Zune.Flags) !void {
    if (luau.CodeGen.Supported() and JIT_ENABLED)
        luau.CodeGen.Create(L);

    L.Lopenlibs();
    try Zune.openZune(L, pOpts.args, flags);
}

pub fn prepAsync(L: *VM.lua.State, sched: *Scheduler, pOpts: PrepOptions, flags: Zune.Flags) !void {
    const GL = L.mainthread();

    GL.setthreaddata(*Scheduler, sched);

    try prep(L, pOpts, flags);
}

pub fn stateCleanUp() void {
    if (Zune.corelib.io.TERMINAL) |*terminal| {
        if (terminal.stdout_istty and terminal.stdin_istty) {
            terminal.restoreSettings() catch std.debug.print("[Zune] Failed to restore terminal settings\n", .{});
            terminal.restoreOutputMode() catch std.debug.print("[Zune] Failed to restore terminal output mode\n", .{});
        }
    }
}

const RunOptions = struct {
    cleanUp: bool,
    mode: Zune.RunMode = .Run,
};

pub fn runAsync(L: *VM.lua.State, sched: *Scheduler, comptime options: RunOptions) !void {
    defer if (options.cleanUp) stateCleanUp();
    sched.deferThread(L, null, 0);
    sched.run(options.mode);
    _ = try checkStatus(L);
}

pub fn run(L: *VM.lua.State) !void {
    defer stateCleanUp();
    _ = try L.pcall(0, 0, 0).check();
}

test "Run Basic" {
    const allocator = std.testing.allocator;
    const L = try luau.init(&allocator);
    defer L.deinit();
    if (luau.CodeGen.Supported())
        luau.CodeGen.Create(L);
    L.Lopenlibs();
    try loadModule(L, "test", "tostring(\"Hello, World!\")\n", null);
    try run(L);
}

test "Run Basic Syntax Error" {
    const allocator = std.testing.allocator;
    const L = try luau.init(&allocator);
    defer L.deinit();
    if (luau.CodeGen.Supported())
        luau.CodeGen.Create(L);
    L.Lopenlibs();
    try std.testing.expectError(LuauCompileError.Syntax, loadModule(L, "test", "print('Hello, World!'\n", null));
    try std.testing.expectEqualStrings("[string \"test\"]:2: Expected ')' (to close '(' at line 1), got <eof>", L.tostring(-1) orelse "UnknownError");
}

test {
    std.testing.refAllDecls(@This());
}
