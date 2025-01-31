const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

pub fn lua_genHashFn(comptime hash_algorithm: anytype) VM.zapi.LuaZigFn(i32) {
    return struct {
        fn hash(L: *VM.lua.State) i32 {
            const data = L.Ztolstringk(1);

            var buf: [hash_algorithm.digest_length]u8 = undefined;

            hash_algorithm.hash(data, &buf, .{});

            const hex = std.fmt.bytesToHex(&buf, .lower);

            L.pop(2); // drop: data

            L.pushlstring(&hex);

            return 1;
        }
    }.hash;
}

pub fn lua_genHmacFn(comptime hash_algorithm: anytype) VM.zapi.LuaZigFn(i32) {
    const hmac_algorithm = std.crypto.auth.hmac.Hmac(hash_algorithm);
    return struct {
        fn hash(L: *VM.lua.State) i32 {
            const data = L.Ztolstringk(1);
            const key = L.Ztolstringk(2);

            var buf: [hmac_algorithm.key_length]u8 = undefined;

            hmac_algorithm.create(&buf, data, key);

            const hex = std.fmt.bytesToHex(&buf, .lower);

            L.pop(2); // drop: data, key

            L.pushlstring(&hex);

            return 1;
        }
    }.hash;
}
