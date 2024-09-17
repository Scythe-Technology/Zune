const std = @import("std");
const yaml = @import("yaml");
const luau = @import("luau");

const Luau = luau.Luau;

pub fn lua_encode(L: *Luau) !i32 {
    const string = L.checkString(1);

    const allocator = L.allocator();

    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(string.len));
    defer allocator.free(out);

    L.pushLString(std.base64.standard.Encoder.encode(out, string));

    return 1;
}

pub fn lua_decode(L: *Luau) !i32 {
    const string = L.checkString(1);

    const allocator = L.allocator();

    const out = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(string));
    defer allocator.free(out);

    try std.base64.standard.Decoder.decode(out, string);

    L.pushLString(out);

    return 1;
}
