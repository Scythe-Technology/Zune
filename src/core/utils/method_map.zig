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
            const ptr = if (comptime tag) |t|
                L.touserdatatagged(T, 1, t) orelse return L.Zerrorf("Bad userdata", .{})
            else
                L.touserdata(T, 1) orelse return L.Zerrorf("Bad userdata", .{});

            const namecall = L.namecallstr() orelse return 0;
            const method = map.get(namecall) orelse return L.Zerrorf("Unknown method: {s}", .{namecall});
            return @call(.auto, method, .{ ptr, L });
        }
    }.inner;
}

pub fn CreateStaticIndexMap(
    comptime T: type,
    comptime tag: ?i32,
    comptime index_map: anytype,
) fn (*VM.lua.State) void {
    return struct {
        fn inner(state: *VM.lua.State) void {
            state.createtable(0, index_map.len);
            inline for (index_map) |kv| {
                state.Zpushfunction(struct {
                    fn inner(L: *VM.lua.State) !i32 {
                        const ptr = if (comptime tag) |t|
                            L.touserdatatagged(T, 1, t) orelse return L.Zerror("Expected ':' calling member function " ++ kv[0])
                        else
                            L.touserdata(T, 1) orelse return L.Zerror("Expected ':' calling member function " ++ kv[0]);
                        return @call(.always_inline, kv[1], .{ ptr, L });
                    }
                }.inner, kv[0]);
                state.setfield(-2, kv[0]);
            }
        }
    }.inner;
}
