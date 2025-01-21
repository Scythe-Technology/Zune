const luau = @import("luau");

const VM = luau.VM;

pub const MAX_LUAU_SIZE = 1073741824; // 1 GB

pub fn pushCloneTable(L: *VM.lua.State, idx: i32, deep: bool) !void {
    L.newtable();
    if (idx == VM.lua.GLOBALSINDEX or idx == VM.lua.REGISTRYINDEX)
        return error.RegistryIndex;
    L.pushvalue(if (idx < 0) idx - 1 else idx);
    L.pushnil();
    while (L.next(-2)) {
        L.pushvalue(-2);
        L.pushvalue(-2);
        if (deep and L.typeOf(-1) == .Table) {
            try pushCloneTable(L, L.gettop(), deep);
            L.remove(-2); // remove table
        }
        L.settable(-6);
        L.pop(1);
    }
    L.pop(1);
}

/// Register a table in the registry.
/// Pops the module from the stack.
pub fn registerModule(L: *VM.lua.State, comptime libName: [:0]const u8) void {
    _ = L.Lfindtable(VM.lua.REGISTRYINDEX, "_LIBS", 1);
    if (L.getfield(-1, libName) != .Table) {
        L.pop(1);
        L.pushvalue(-2);
        L.setfield(-2, libName);
    } else L.pop(1);
    L.pop(2);
}
