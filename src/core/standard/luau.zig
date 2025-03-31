const std = @import("std");
const luau = @import("luau");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");

const VM = luau.VM;

pub const LIB_NAME = "luau";

fn lua_compile(L: *VM.lua.State) !i32 {
    const source = try L.Zcheckvalue([]const u8, 1, null);

    var compileOpts = luau.CompileOptions{
        .debug_level = Engine.DEBUG_LEVEL,
        .optimization_level = Engine.OPTIMIZATION_LEVEL,
    };

    if (try L.Zcheckvalue(?struct {
        debug_level: ?i32,
        optimization_level: ?i32,
        coverage_level: ?i32,
        // vector_ctor: ?[:0]const u8,
        // vector_lib: ?[:0]const u8,
        // vector_type: ?[:0]const u8,
    }, 2, null)) |opts| {
        compileOpts.debug_level = opts.debug_level orelse compileOpts.debug_level;
        if (compileOpts.debug_level < 0 or compileOpts.debug_level > 2)
            return L.Zerror("Invalid debug level");

        compileOpts.optimization_level = opts.optimization_level orelse compileOpts.optimization_level;
        if (compileOpts.optimization_level < 0 or compileOpts.optimization_level > 3)
            return L.Zerror("Invalid optimization level");

        compileOpts.coverage_level = opts.coverage_level orelse compileOpts.coverage_level;
        if (compileOpts.coverage_level < 0 or compileOpts.coverage_level > 2)
            return L.Zerror("Invalid coverage level");

        // TODO: Enable after tests are added
        // compileOpts.vector_ctor = opts.vector_ctor orelse compileOpts.vector_ctor;
        // compileOpts.vector_lib = opts.vector_lib orelse compileOpts.vector_lib;
        // compileOpts.vector_type = opts.vector_type orelse compileOpts.vector_type;
    }

    const allocator = luau.getallocator(L);
    const bytecode = try luau.compile(allocator, source, compileOpts);
    defer allocator.free(bytecode);

    if (bytecode.len < 2)
        return error.LuauCompileError;

    const version = bytecode[0];
    const success = version != 0;
    if (!success) {
        L.pushlstring(bytecode[1..]);
        return error.RaiseLuauError;
    }

    L.pushlstring(bytecode);

    return 1;
}

fn lua_load(L: *VM.lua.State) !i32 {
    const bytecode = try L.Zcheckvalue([]const u8, 1, null);

    const Options = struct {
        nativeCodeGen: bool = false,
        chunkName: [:0]const u8 = "(load)",
    };
    const opts: Options = try L.Zcheckvalue(?Options, 2, null) orelse .{};

    var useCodeGen = opts.nativeCodeGen;
    const chunkName = opts.chunkName;

    try L.load(chunkName, bytecode, 0);

    if (L.typeOf(-1) != .Function)
        return L.Zerror("Luau Error (Bad Load)");

    if (L.typeOf(2) == .Table) {
        if (L.getfield(2, "env") == .Table) {
            // TODO: should allow env to have a metatable?
            if (L.getmetatable(-1)) {
                useCodeGen = false; // dynamic env, disable codegen
                L.pop(1); // drop metatable
            }
            if (useCodeGen)
                L.setsafeenv(-1, true);
            if (!L.setfenv(-2))
                return L.Zerror("Luau Error (Bad Env)");
        } else L.pop(1);
    }

    if (useCodeGen and luau.CodeGen.Supported() and Engine.JIT_ENABLED)
        luau.CodeGen.Compile(L, -1);

    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    L.Zpushvalue(.{
        .compile = lua_compile,
        .load = lua_load,
    });
    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "luau" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/luau.test.luau"),
        &.{},
        true,
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
