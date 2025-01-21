const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

pub fn lua_genHashFn(comptime hash_algorithm: anytype) VM.zapi.ZigFnErrorSet {
    return struct {
        fn hash(L: *VM.lua.State) !i32 {
            const allocator = luau.getallocator(L);

            var owned = false;
            const data = blk: {
                const args = L.gettop();
                if (args < 2) {
                    break :blk L.Lcheckstring(1);
                } else {
                    var buf = std.ArrayList(u8).init(allocator);
                    defer buf.deinit();
                    const writer = buf.writer();
                    owned = true;

                    for (1..@intCast(args)) |i| {
                        if (i > 1)
                            try buf.append('/');
                        const index: i32 = @intCast(i);
                        switch (L.typeOf(index)) {
                            .String => {
                                const str = L.Lcheckstring(index);
                                try writer.print("\"{s}\"", .{str});
                            },
                            .Number => {
                                const num = L.Lchecknumber(index);
                                try writer.print("{d}", .{num});
                            },
                            .Buffer, .Table, .Userdata, .LightUserdata => {
                                const ptr = L.topointer(index) orelse unreachable;
                                try writer.print("*{d}", .{@intFromPtr(ptr)});
                            },
                            else => return L.Zerror("InvalidArgumentType"),
                        }
                    }

                    break :blk try buf.toOwnedSlice();
                }
            };
            defer if (owned) allocator.free(data);

            var buf: [hash_algorithm.digest_length]u8 = undefined;

            hash_algorithm.hash(data, &buf, .{});

            const hex = std.fmt.bytesToHex(&buf, .lower);

            L.pushlstring(&hex);

            return 1;
        }
    }.hash;
}

pub fn lua_genHmacFn(comptime hash_algorithm: anytype) VM.zapi.ZigFnInt {
    const hmac_algorithm = std.crypto.auth.hmac.Hmac(hash_algorithm);
    return struct {
        fn hash(L: *VM.lua.State) i32 {
            const data = L.Lcheckstring(1);
            const key = L.Lcheckstring(2);

            var buf: [hmac_algorithm.key_length]u8 = undefined;

            hmac_algorithm.create(&buf, data, key);

            const hex = std.fmt.bytesToHex(&buf, .lower);

            L.pushlstring(&hex);

            return 1;
        }
    }.hash;
}
