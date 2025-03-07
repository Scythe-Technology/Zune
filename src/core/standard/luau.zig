const std = @import("std");
const luau = @import("luau");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");

const VM = luau.VM;

pub const LIB_NAME = "luau";

fn luau_compile(L: *VM.lua.State) !i32 {
    const source = L.Lcheckstring(1);

    var compileOpts = luau.CompileOptions{
        .debug_level = 2,
        .optimization_level = 2,
    };

    if (!L.isnoneornil(2)) {
        L.Lchecktype(2, .Table);

        if (L.getfield(2, "debug_level") == .Number) {
            const value: i32 = @intCast(L.tointeger(-1) orelse unreachable);
            if (value < 0 or value > 2)
                return L.Zerror("Invalid debug level");
            compileOpts.debug_level = value;
        }
        L.pop(1);

        if (L.getfield(2, "optimization_level") == .Number) {
            const value: i32 = @intCast(L.tointeger(-1) orelse unreachable);
            if (value < 0 or value > 2)
                return L.Zerror("Invalid debug level");
            compileOpts.optimization_level = value;
        }
        L.pop(1);

        if (L.getfield(2, "coverage_level") == .Number) {
            const value: i32 = @intCast(L.tointeger(-1) orelse unreachable);
            if (value < 0 or value > 2)
                return L.Zerror("Invalid debug level");
            compileOpts.coverage_level = value;
        }
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
    const bytecode = L.Lcheckstring(1);

    var useCodeGen = false;
    var chunkName: [:0]const u8 = "(load)";

    const optsExists = L.isnoneornil(2);
    if (!optsExists) {
        L.Lchecktype(2, .Table);

        if (L.getfield(2, "nativeCodeGen") == .Boolean)
            useCodeGen = L.toboolean(-1);
        L.pop(1);

        if (L.getfield(2, "chunkName") == .String)
            chunkName = L.tostring(-1) orelse unreachable;
        L.pop(1);
    }

    try L.load(chunkName, bytecode, 0);

    if (L.typeOf(-1) != .Function) {
        L.pop(2);
        return L.Zerror("Luau Error (Bad Load)");
    }

    if (!optsExists) {
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
    L.newtable();

    L.Zsetfieldc(-1, "compile", luau_compile);
    L.Zsetfieldc(-1, "load", luau_load);

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "Luau" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"luau.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
