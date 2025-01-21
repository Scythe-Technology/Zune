const std = @import("std");
const luau = @import("luau");

const common = @import("common.zig");

const VM = luau.VM;

pub fn lua_boolean(L: *VM.lua.State) i32 {
    L.pushboolean(std.crypto.random.boolean());
    return 1;
}

pub fn lua_nextinteger(L: *VM.lua.State) !i32 {
    const min = L.tointeger(1) orelse {
        L.pushinteger(std.crypto.random.int(i32));
        return 1;
    };
    const max = L.Lcheckinteger(2);
    if (min > max)
        return L.Zerror("InvalidRange (min > max)");
    L.pushinteger(std.crypto.random.intRangeAtMost(i32, min, max));
    return 1;
}

pub fn lua_nextnumber(L: *VM.lua.State) !i32 {
    const min = L.tonumber(1) orelse {
        L.pushnumber(std.crypto.random.float(f64));
        return 1;
    };
    const max = L.Lchecknumber(2);
    if (min > max)
        return L.Zerror("InvalidRange (min > max)");
    const v = std.crypto.random.float(f64);
    L.pushnumber(min + (v * (max - min)));
    return 1;
}

pub fn lua_fill(L: *VM.lua.State) !i32 {
    const buffer = L.Lcheckbuffer(1);
    const offset = L.Lcheckinteger(2);
    const length = L.Lcheckinteger(3);

    if (offset < 0)
        return L.Zerror("InvalidOffset (offset < 0)");
    if (length < 0)
        return L.Zerror("InvalidLength (length < 0)");
    if (offset + length > buffer.len)
        return L.Zerror("InvalidLength (offset + length > buffer size)");

    std.crypto.random.bytes(buffer[@intCast(offset)..][0..@intCast(length)]);

    return 0;
}
