const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

pub fn CreateNamecallMap(comptime T: type, comptime method_map: anytype) fn (L: *VM.lua.State) anyerror!i32 {
    const map = std.StaticStringMap(*const fn (ptr: *T, L: *VM.lua.State) anyerror!i32).initComptime(method_map);

    return struct {
        fn inner(L: *VM.lua.State) !i32 {
            L.Lchecktype(1, .Userdata);
            const ptr = L.touserdata(T, 1) orelse unreachable;
            const namecall = L.namecallstr() orelse return 0;
            const method = map.get(namecall) orelse return L.Zerrorf("Unknown method: {s}", .{namecall});
            return @call(.auto, method, .{ ptr, L });
        }
    }.inner;
}
