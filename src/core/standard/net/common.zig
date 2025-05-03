const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const VM = luau.VM;

pub const context = @import("../../utils/sysfd.zig").context;

pub fn prepRefType(comptime luaType: VM.lua.Type, L: *VM.lua.State, ref: i32) bool {
    if (L.rawgeti(VM.lua.REGISTRYINDEX, ref) == luaType) {
        return true;
    }
    L.pop(1);
    return false;
}

pub const HeaderTypeError = error{
    InvalidKeyType,
    InvalidValueType,
};

pub fn read_headers(L: *VM.lua.State, headers: *std.ArrayList(std.http.Header), idx: i32) !void {
    try L.Zchecktype(idx, .Table);
    L.pushvalue(idx);
    L.pushnil();

    while (L.next(-2)) {
        const keyType = L.typeOf(-2);
        const valueType = L.typeOf(-1);
        if (keyType != .String) return HeaderTypeError.InvalidKeyType;
        if (valueType != .String) return HeaderTypeError.InvalidValueType;
        const key = L.tostring(-2) orelse return HeaderTypeError.InvalidKeyType;
        const value = L.tostring(-1) orelse return HeaderTypeError.InvalidValueType;
        try headers.append(.{ .name = key, .value = value });
        L.pop(1);
    }
    L.pop(1);
}
