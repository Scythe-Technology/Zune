const std = @import("std");
const luau = @import("luau");

const Luau = luau.Luau;

pub fn CreateNamecallMap(comptime T: type, comptime method_map: anytype) fn (L: *Luau) anyerror!i32 {
    const map = std.StaticStringMap(*const fn (ptr: *T, L: *Luau) anyerror!i32).initComptime(method_map);

    return struct {
        fn inner(L: *Luau) !i32 {
            L.checkType(1, .userdata);
            const ptr = L.toUserdata(T, 1) catch unreachable;
            const namecall = L.nameCallAtom() catch return 0;
            const method = map.get(namecall) orelse return L.ErrorFmt("Unknown method: {s}", .{namecall});
            return @call(.auto, method, .{ ptr, L });
        }
    }.inner;
}
