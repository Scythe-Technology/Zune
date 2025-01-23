const std = @import("std");
const yaml = @import("yaml");
const luau = @import("luau");

const VM = luau.VM;

pub fn lua_encode(L: *VM.lua.State) !i32 {
    const string = L.Lcheckstring(1);

    const allocator = luau.getallocator(L);

    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(string.len));
    defer allocator.free(out);

    L.pushlstring(std.base64.standard.Encoder.encode(out, string));

    return 1;
}

pub fn lua_decode(L: *VM.lua.State) !i32 {
    const string = L.Lcheckstring(1);

    const allocator = luau.getallocator(L);

    const out = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(string));
    defer allocator.free(out);

    try std.base64.standard.Decoder.decode(out, string);

    L.pushlstring(out);

    return 1;
}
