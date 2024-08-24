const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

pub const HTTP_404 = "HTTP/1.1 404 Bad Request\r\n\r\n";
pub const HTTP_413 = "HTTP/1.1 413 Payload Too Large\r\nContent-Type: text/plain\r\nContent-Length: 67\r\n\r\nThe content you provided exceeds the server's maximum allowed size.";
pub const HTTP_500 = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 31\r\n\r\nAn error occurred on the server";

pub const context = switch (builtin.os.tag) {
    .windows => struct {
        pub const POLLIN: i16 = 0x0100;
        pub const POLLERR: i16 = 0x0001;
        pub const POLLHUP: i16 = 0x0002;
        pub const POLLNVAL: i16 = 0x0004;
        pub const INVALID_SOCKET = std.os.windows.ws2_32.INVALID_SOCKET;
    },
    .macos, .linux => struct {
        pub const POLLIN: i16 = 0x0001;
        pub const POLLERR: i16 = 0x0008;
        pub const POLLHUP: i16 = 0x0010;
        pub const POLLNVAL: i16 = 0x0020;
        pub const INVALID_SOCKET = -1;
    },
    else => @compileError("Unsupported OS"),
};

pub fn prepRefType(comptime luaType: luau.LuaType, L: *luau.Luau, ref: i32) bool {
    if (L.rawGetIndex(luau.REGISTRYINDEX, ref) == luaType) {
        return true;
    }
    L.pop(1);
    return false;
}

pub const HeaderTypeError = error{
    InvalidKeyType,
    InvalidValueType,
};

pub fn read_headers(L: *luau.Luau, headers: *std.ArrayList(std.http.Header), idx: i32) !void {
    L.checkType(idx, luau.LuaType.table);
    L.pushValue(idx);
    L.pushNil();

    while (L.next(-2)) {
        const keyType = L.typeOf(-2);
        const valueType = L.typeOf(-1);
        if (keyType != luau.LuaType.string) return HeaderTypeError.InvalidKeyType;
        if (valueType != luau.LuaType.string) return HeaderTypeError.InvalidValueType;
        const key = L.toString(-2) catch return HeaderTypeError.InvalidKeyType;
        const value = L.toString(-1) catch return HeaderTypeError.InvalidValueType;
        try headers.append(.{ .name = key, .value = value });
        L.pop(1);
    }
    L.pop(1);
}
