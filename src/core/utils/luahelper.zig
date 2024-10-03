const luau = @import("luau");

const Luau = luau.Luau;

pub const MAX_LUAU_SIZE = 1073741824; // 1 GB

fn outputSafeResult(L: *Luau, err_result: [:0]const u8) i32 {
    L.pushBoolean(false);
    L.pushString(err_result);
    return 2;
}

pub fn toSafeZigFunction(comptime f: luau.ZigEFn) luau.ZigFn {
    return struct {
        fn inner(state: *Luau) i32 {
            if (@call(.always_inline, f, .{state})) |res|
                return res
            else |err|
                return outputSafeResult(state, @errorName(err));
        }
    }.inner;
}

/// Register a module in the registry.
/// Pops the module from the stack.
pub fn registerModule(L: *Luau, comptime libName: [:0]const u8) void {
    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, libName) != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, libName);
    } else L.pop(1);
    L.pop(2);
}
