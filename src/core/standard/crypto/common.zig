const std = @import("std");
const luau = @import("luau");

const Luau = luau.Luau;

pub fn lua_genHashFn(comptime hash_algorithm: anytype) luau.ZigFnInt {
    return struct {
        fn hash(L: *Luau) i32 {
            const data = L.checkString(1);

            var buf: [hash_algorithm.digest_length]u8 = undefined;

            hash_algorithm.hash(data, &buf, .{});

            const hex = std.fmt.bytesToHex(&buf, .lower);

            L.pushLString(&hex);

            return 1;
        }
    }.hash;
}

pub fn lua_genHmacFn(comptime hash_algorithm: anytype) luau.ZigFnInt {
    const hmac_algorithm = std.crypto.auth.hmac.Hmac(hash_algorithm);
    return struct {
        fn hash(L: *Luau) i32 {
            const data = L.checkString(1);
            const key = L.checkString(2);

            var buf: [hmac_algorithm.key_length]u8 = undefined;

            hmac_algorithm.create(&buf, data, key);

            const hex = std.fmt.bytesToHex(&buf, .lower);

            L.pushLString(&hex);

            return 1;
        }
    }.hash;
}
