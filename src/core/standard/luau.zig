const std = @import("std");
const luau = @import("luau");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");

const Luau = luau.Luau;

pub const LIB_NAME = "luau";

fn luau_compile(L: *Luau) !i32 {
    const source = L.checkString(1);

    var compileOpts = luau.CompileOptions{
        .debug_level = 2,
        .optimization_level = 2,
    };

    if (!L.isNoneOrNil(2)) {
        L.checkType(2, .table);

        if (L.getField(2, "debug_level") == .number) {
            const value: i32 = @intCast(L.toInteger(-1) catch unreachable);
            if (value < 0 or value > 2)
                return L.Error("Invalid debug level");
            compileOpts.debug_level = value;
        }
        L.pop(1);

        if (L.getField(2, "optimization_level") == .number) {
            const value: i32 = @intCast(L.toInteger(-1) catch unreachable);
            if (value < 0 or value > 2)
                return L.Error("Invalid debug level");
            compileOpts.optimization_level = value;
        }
        L.pop(1);

        if (L.getField(2, "coverage_level") == .number) {
            const value: i32 = @intCast(L.toInteger(-1) catch unreachable);
            if (value < 0 or value > 2)
                return L.Error("Invalid debug level");
            compileOpts.coverage_level = value;
        }
        L.pop(1);

        // TODO: Enable after tests are added
        // if (L.getField(2, "vector_ctor") == .string) compileOpts.vector_ctor = L.toString(-1) catch unreachable;
        // L.pop(1);
        // if (L.getField(2, "vector_lib") == .string) compileOpts.vector_lib = L.toString(-1) catch unreachable;
        // L.pop(1);
        // if (L.getField(2, "vector_type") == .string) compileOpts.vector_type = L.toString(-1) catch unreachable;
        // L.pop(1);
    }

    const allocator = L.allocator();
    const bytecode = try luau.compile(allocator, source, compileOpts);
    defer allocator.free(bytecode);

    if (bytecode.len < 2)
        return error.LuauCompileError;

    const version = bytecode[0];
    const success = version != 0;
    if (!success) {
        L.pushLString(bytecode[1..]);
        return error.RaiseLuauError;
    }

    L.pushLString(bytecode);

    return 1;
}

fn luau_load(L: *Luau) !i32 {
    const bytecode = L.checkString(1);

    var useCodeGen = false;
    var chunkName: [:0]const u8 = "(load)";

    const optsExists = L.isNoneOrNil(2);
    if (!optsExists) {
        L.checkType(2, .table);

        if (L.getField(2, "nativeCodeGen") == .boolean)
            useCodeGen = L.toBoolean(-1);
        L.pop(1);

        if (L.getField(2, "chunkName") == .string)
            chunkName = L.toString(-1) catch unreachable;
        L.pop(1);
    }

    try L.loadBytecode(chunkName, bytecode);

    if (L.typeOf(-1) != .function) {
        L.pop(2);
        return L.Error("Luau Error (Bad Load)");
    }

    if (!optsExists) {
        if (L.getField(2, "env") == .table) {
            // TODO: should allow env to have a metatable?
            if (L.getMetatable(-1)) {
                useCodeGen = false; // dynamic env, disable codegen
                L.pop(1); // drop metatable
            }
            if (useCodeGen)
                L.setSafeEnv(-1, true);
            L.setfenv(-2) catch return L.Error("Luau Error (Bad Env)");
        } else L.pop(1);
    }

    if (useCodeGen and luau.CodeGen.Supported() and Engine.JIT_ENABLED)
        luau.CodeGen.Compile(L, -1);

    return 1;
}

pub fn loadLib(L: *Luau) void {
    L.newTable();

    L.setFieldFn(-1, "compile", luau_compile);
    L.setFieldFn(-1, "load", luau_load);

    luaHelper.registerModule(L, LIB_NAME);
}

test "Luau" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"luau.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
