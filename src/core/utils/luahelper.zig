const luau = @import("luau");

const Luau = luau.Luau;

pub const MAX_LUAU_SIZE = 1073741824; // 1 GB

/// Register a table in the registry.
/// Pops the module from the stack.
pub fn registerModule(L: *Luau, comptime libName: [:0]const u8) void {
    _ = L.findTable(luau.REGISTRYINDEX, "_LIBS", 1);
    if (L.getField(-1, libName) != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, libName);
    } else L.pop(1);
    L.pop(2);
}
