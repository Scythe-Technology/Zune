const std = @import("std");
const luau = @import("luau");
const zune = @import("../../zune.zig");
const file = @import("../resolvers/file.zig");
const require = @import("../resolvers/require.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const Luau = luau.Luau;

pub const LuauCompileError = error{
    Syntax,
};

pub const LuauRunError = enum {
    Runtime,
};

pub fn compileModule(allocator: std.mem.Allocator, content: []const u8, cOpts: ?luau.CompileOptions) ![]const u8 {
    const compileOptions = cOpts orelse luau.CompileOptions{
        .debug_level = 2,
        .optimization_level = 2,
    };
    return try luau.compile(allocator, content, compileOptions);
}

pub fn loadModuleBytecode(L: *Luau, moduleName: [:0]const u8, bytecode: []const u8) LuauCompileError!void {
    L.loadBytecode(moduleName, bytecode) catch {
        return LuauCompileError.Syntax;
    };
    if (luau.CodeGen.Supported()) luau.CodeGen.Compile(L, -1);
}

pub fn loadModule(L: *Luau, name: [:0]const u8, content: []const u8, cOpts: ?luau.CompileOptions) !void {
    const allocator = L.allocator();
    const bytecode = try compileModule(allocator, content, cOpts);
    defer allocator.free(bytecode);
    return try loadModuleBytecode(L, name, bytecode);
}

pub fn setLuaFileContext(L: *Luau, absPath: []const u8) void {
    L.setFieldLString(luau.GLOBALSINDEX, "_FILE", absPath);
}

pub fn logError(L: *Luau, err: anyerror) void {
    switch (err) {
        error.Runtime => {
            std.debug.print("{s}\n", .{L.toString(-1) catch "UnknownError"});
            std.debug.print("{s}\n", .{L.debugTrace()});
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
    mode: zune.RunMode,
};

pub fn prep(L: *Luau, pOpts: PrepOptions) !void {
    if (luau.CodeGen.Supported()) luau.CodeGen.Create(L);

    L.openLibs();
    try zune.openZune(L, pOpts.args, pOpts.mode);
}

pub fn prepAsync(L: *Luau, sched: *Scheduler, pOpts: PrepOptions) !void {
    try prep(L, pOpts);

    L.pushLightUserdata(sched);
    L.setField(luau.REGISTRYINDEX, "_SCHEDULER");
}

pub fn findLuauFile(allocator: std.mem.Allocator, dir: std.fs.Dir, fileName: []const u8) ![:0]const u8 {
    const absPath = try dir.realpathAlloc(allocator, ".");
    defer allocator.free(absPath);
    return findLuauFileFromPath(allocator, absPath, fileName);
}

pub fn findLuauFileFromPath(allocator: std.mem.Allocator, absPath: []const u8, fileName: []const u8) ![:0]const u8 {
    const absF = try std.fs.path.resolve(allocator, &.{ absPath, fileName });
    defer allocator.free(absF);
    return try file.searchForExtensions(allocator, absF, &require.POSSIBLE_EXTENSIONS);
}

pub fn runAsync(L: *Luau, sched: *Scheduler) !void {
    sched.deferThread(L, null, 0);
    sched.run();
    _ = try checkStatus(L);
}

pub fn run(L: *Luau) !void {
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
