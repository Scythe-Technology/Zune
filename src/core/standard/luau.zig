const std = @import("std");
const luau = @import("luau");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");

const VM = luau.VM;

pub const LIB_NAME = "luau";

fn luau_compile(L: *VM.lua.State) !i32 {
    const source = try L.Zcheckvalue([]const u8, 1, null);

    var compileOpts = luau.CompileOptions{
        .debug_level = 2,
        .optimization_level = 2,
    };

    if (!L.isnoneornil(2)) {
        try L.Zchecktype(2, .Table);

        const debug_level = try L.Zcheckfield(?i32, 2, "debug_level") orelse compileOpts.debug_level;
        if (debug_level < 0 or debug_level > 2)
            return L.Zerror("Invalid debug level");
        compileOpts.debug_level = debug_level;
        L.pop(1);

        const optimization_level = try L.Zcheckfield(?i32, 2, "optimization_level") orelse compileOpts.optimization_level;
        if (optimization_level < 0 or optimization_level > 2)
            return L.Zerror("Invalid optimization level");
        compileOpts.optimization_level = optimization_level;
        L.pop(1);

        _ = L.getfield(2, "coverage_level");
        const coverage_level = try L.Zcheckfield(?i32, 2, "coverage_level") orelse compileOpts.coverage_level;
        if (coverage_level < 0 or coverage_level > 2)
            return L.Zerror("Invalid coverage level");
        compileOpts.coverage_level = coverage_level;
        L.pop(1);

        // TODO: Enable after tests are added
        // if (L.getfield(2, "vector_ctor") == .String) compileOpts.vector_ctor = L.tostring(-1) orelse unreachable;
        // L.pop(1);
        // if (L.getfield(2, "vector_lib") == .String) compileOpts.vector_lib = L.tostring(-1) orelse unreachable;
        // L.pop(1);
        // if (L.getfield(2, "vector_type") == .String) compileOpts.vector_type = L.tostring(-1) orelse unreachable;
        // L.pop(1);
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

fn luau_load(L: *VM.lua.State) !i32 {
    const bytecode = try L.Zcheckvalue([]const u8, 1, null);

    var useCodeGen = false;
    var chunkName: [:0]const u8 = "(load)";

    const optsExists = !L.isnoneornil(2);
    if (optsExists) {
        try L.Zchecktype(2, .Table);

        _ = L.getfield(2, "nativeCodeGen");
        useCodeGen = try L.Zcheckfield(?bool, 2, "nativeCodeGen") orelse useCodeGen;

        _ = L.getfield(2, "chunkName");
        chunkName = try L.Zcheckfield(?[:0]const u8, 2, "chunkName") orelse chunkName;
    }

    try L.load(chunkName, bytecode, 0);

    if (L.typeOf(-1) != .Function)
        return L.Zerror("Luau Error (Bad Load)");

    if (optsExists) {
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
    L.createtable(0, 2);

    L.Zsetfieldfn(-1, "compile", luau_compile);
    L.Zsetfieldfn(-1, "load", luau_load);

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "Luau" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/luau.test.luau"),
        &.{},
        true,
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
