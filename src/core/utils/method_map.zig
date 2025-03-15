const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

pub fn WithFn(
    comptime T: type,
    comptime f: anytype,
    comptime before: ?fn (ptr: *T, L: *VM.lua.State) anyerror!void,
) fn (ptr: *T, L: *VM.lua.State) anyerror!i32 {
    return struct {
        fn inner(ptr: *T, L: *VM.lua.State) !i32 {
            if (comptime before) |@"fn"|
                try @call(.always_inline, @"fn", .{ ptr, L });
            return switch (@typeInfo(@TypeOf(f))) {
                .@"fn" => @call(.always_inline, f, .{ ptr, L }),
                else => @compileError("Invalid type for method map"),
            };
        }
    }.inner;
}

pub fn CreateNamecallMap(
    comptime T: type,
    comptime tag: ?i32,
    comptime method_map: anytype,
) fn (L: *VM.lua.State) anyerror!i32 {
    const map = std.StaticStringMap(*const fn (ptr: *T, L: *VM.lua.State) anyerror!i32).initComptime(method_map);

    return struct {
        fn inner(L: *VM.lua.State) !i32 {
            try L.Zchecktype(1, .Userdata);
            const ptr = if (comptime tag) |t|
                L.touserdatatagged(T, 1, t) orelse return L.Zerrorf("Bad userdata", .{})
            else
                L.touserdata(T, 1) orelse unreachable;

            const namecall = L.namecallstr() orelse return 0;
            const method = map.get(namecall) orelse return L.Zerrorf("Unknown method: {s}", .{namecall});
            return @call(.auto, method, .{ ptr, L });
        }
    }.inner;
}
