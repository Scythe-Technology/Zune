const std = @import("std");
const luau = @import("luau");
const builtin = @import("builtin");

const VM = luau.VM;

pub fn load(L: *VM.lua.State) void {
    @import("../httpserver.zig").lua_load(L);
    @import("../websocket.zig").lua_load(L);
    L.Zpushvalue(.{
        .serve = @import("../httpserver.zig").lua_serve,
        .request = @import("client.zig").lua_request,
        .websocket = @import("../websocket.zig").lua_websocket,
    });
    L.setreadonly(-1, true);
}
