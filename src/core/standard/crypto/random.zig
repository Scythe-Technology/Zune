const std = @import("std");
const luau = @import("luau");

const common = @import("common.zig");

const Luau = luau.Luau;

pub fn lua_boolean(L: *Luau) i32 {
    L.pushBoolean(std.crypto.random.boolean());
    return 1;
}

pub fn lua_nextinteger(L: *Luau) !i32 {
    const min = L.optInteger(1) orelse {
        L.pushInteger(std.crypto.random.int(i32));
        return 1;
    };
    const max = L.checkInteger(2);
    if (min > max)
        return L.Error("InvalidRange (min > max)");
    L.pushInteger(std.crypto.random.intRangeAtMost(i32, min, max));
    return 1;
}

pub fn lua_nextnumber(L: *Luau) !i32 {
    const min = L.optNumber(1) orelse {
        L.pushNumber(std.crypto.random.float(f64));
        return 1;
    };
    const max = L.checkNumber(2);
    if (min > max)
        return L.Error("InvalidRange (min > max)");
    const v = std.crypto.random.float(f64);
    L.pushNumber(min + (v * (max - min)));
    return 1;
}

pub fn lua_fill(L: *Luau) !i32 {
    const buffer = L.checkBuffer(1);
    const offset = L.checkInteger(2);
    const length = L.checkInteger(3);

    if (offset < 0)
        return L.Error("InvalidOffset (offset < 0)");
    if (length < 0)
        return L.Error("InvalidLength (length < 0)");
    if (offset + length > buffer.len)
        return L.Error("InvalidLength (offset + length > buffer size)");

    std.crypto.random.bytes(buffer[@intCast(offset)..][0..@intCast(length)]);

    return 0;
}
