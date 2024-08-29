const luau = @import("luau");

const Luau = luau.Luau;

fn outputSafeResult(L: *Luau, err_result: [:0]const u8) i32 {
    L.pushBoolean(false);
    L.pushString(err_result);
    return 2;
}

pub fn toSafeZigFunction(comptime f: luau.ZigEFn) luau.ZigFn {
    return struct {
        fn inner(state: *Luau) i32 {
            if (@call(.always_inline, f, .{state})) |res| return res else |err| return outputSafeResult(state, @errorName(err));
        }
    }.inner;
}
