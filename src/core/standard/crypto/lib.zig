const std = @import("std");
const luau = @import("luau");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const common = @import("common.zig");

const VM = luau.VM;

const hash = std.crypto.hash;

const aes = @import("aes.zig");
const random = @import("random.zig");
const password = @import("password.zig");

pub const LIB_NAME = "crypto";

pub fn loadLib(L: *VM.lua.State) void {
    L.newtable();

    { // hash
        L.newtable();

        // Md5
        L.Zsetfieldfn(-1, "md5", comptime common.lua_genHashFn(hash.Md5));
        // Sha1
        L.Zsetfieldfn(-1, "sha1", common.lua_genHashFn(hash.Sha1));
        // Blake3
        L.Zsetfieldfn(-1, "blake3", common.lua_genHashFn(hash.Blake3));

        { // Sha2
            L.newtable();

            L.Zsetfieldfn(-1, "sha224", common.lua_genHashFn(hash.sha2.Sha224));
            L.Zsetfieldfn(-1, "sha256", common.lua_genHashFn(hash.sha2.Sha256));
            L.Zsetfieldfn(-1, "sha384", common.lua_genHashFn(hash.sha2.Sha384));
            L.Zsetfieldfn(-1, "sha512", common.lua_genHashFn(hash.sha2.Sha512));

            L.setreadonly(-1, true);
            L.setfield(-2, "sha2");
        }

        { // Sha3
            L.newtable();

            L.Zsetfieldfn(-1, "sha3_224", common.lua_genHashFn(hash.sha3.Sha3_224));
            L.Zsetfieldfn(-1, "sha3_256", common.lua_genHashFn(hash.sha3.Sha3_256));
            L.Zsetfieldfn(-1, "sha3_384", common.lua_genHashFn(hash.sha3.Sha3_384));
            L.Zsetfieldfn(-1, "sha3_512", common.lua_genHashFn(hash.sha3.Sha3_512));

            L.setreadonly(-1, true);
            L.setfield(-2, "sha3");
        }

        { // Blake2
            L.newtable();

            L.Zsetfieldfn(-1, "b128", common.lua_genHashFn(hash.blake2.Blake2b128));
            L.Zsetfieldfn(-1, "b160", common.lua_genHashFn(hash.blake2.Blake2b160));
            L.Zsetfieldfn(-1, "b256", common.lua_genHashFn(hash.blake2.Blake2b256));
            L.Zsetfieldfn(-1, "b384", common.lua_genHashFn(hash.blake2.Blake2b384));
            L.Zsetfieldfn(-1, "b512", common.lua_genHashFn(hash.blake2.Blake2b512));

            L.Zsetfieldfn(-1, "s128", common.lua_genHashFn(hash.blake2.Blake2s128));
            L.Zsetfieldfn(-1, "s160", common.lua_genHashFn(hash.blake2.Blake2s160));
            L.Zsetfieldfn(-1, "s224", common.lua_genHashFn(hash.blake2.Blake2s224));
            L.Zsetfieldfn(-1, "s256", common.lua_genHashFn(hash.blake2.Blake2s256));

            L.setreadonly(-1, true);
            L.setfield(-2, "blake2");
        }

        L.setreadonly(-1, true);
        L.setfield(-2, "hash");
    }

    { // hmac
        L.newtable();

        // Md5
        L.Zsetfieldfn(-1, "md5", common.lua_genHmacFn(hash.Md5));
        // Sha1
        L.Zsetfieldfn(-1, "sha1", common.lua_genHmacFn(hash.Sha1));
        // Blake3
        L.Zsetfieldfn(-1, "blake3", common.lua_genHmacFn(hash.Blake3));

        { // Sha2
            L.newtable();

            L.Zsetfieldfn(-1, "sha224", common.lua_genHmacFn(hash.sha2.Sha224));
            L.Zsetfieldfn(-1, "sha256", common.lua_genHmacFn(hash.sha2.Sha256));
            L.Zsetfieldfn(-1, "sha384", common.lua_genHmacFn(hash.sha2.Sha384));
            L.Zsetfieldfn(-1, "sha512", common.lua_genHmacFn(hash.sha2.Sha512));

            L.setreadonly(-1, true);
            L.setfield(-2, "sha2");
        }

        { // Sha3
            L.newtable();

            L.Zsetfieldfn(-1, "sha3_224", common.lua_genHmacFn(hash.sha3.Sha3_224));
            L.Zsetfieldfn(-1, "sha3_256", common.lua_genHmacFn(hash.sha3.Sha3_256));
            L.Zsetfieldfn(-1, "sha3_384", common.lua_genHmacFn(hash.sha3.Sha3_384));
            L.Zsetfieldfn(-1, "sha3_512", common.lua_genHmacFn(hash.sha3.Sha3_512));

            L.setreadonly(-1, true);
            L.setfield(-2, "sha3");
        }

        { // Blake2
            L.newtable();

            L.Zsetfieldfn(-1, "b128", common.lua_genHmacFn(hash.blake2.Blake2b128));
            L.Zsetfieldfn(-1, "b160", common.lua_genHmacFn(hash.blake2.Blake2b160));
            L.Zsetfieldfn(-1, "b256", common.lua_genHmacFn(hash.blake2.Blake2b256));
            L.Zsetfieldfn(-1, "b384", common.lua_genHmacFn(hash.blake2.Blake2b384));
            L.Zsetfieldfn(-1, "b512", common.lua_genHmacFn(hash.blake2.Blake2b512));

            L.Zsetfieldfn(-1, "s128", common.lua_genHmacFn(hash.blake2.Blake2s128));
            L.Zsetfieldfn(-1, "s160", common.lua_genHmacFn(hash.blake2.Blake2s160));
            L.Zsetfieldfn(-1, "s224", common.lua_genHmacFn(hash.blake2.Blake2s224));
            L.Zsetfieldfn(-1, "s256", common.lua_genHmacFn(hash.blake2.Blake2s256));

            L.setreadonly(-1, true);
            L.setfield(-2, "blake2");
        }

        L.setreadonly(-1, true);
        L.setfield(-2, "hmac");
    }

    { // password
        L.newtable();

        L.Zsetfieldfn(-1, "hash", password.lua_hash);
        L.Zsetfieldfn(-1, "verify", password.lua_verify);

        L.setreadonly(-1, true);
        L.setfield(-2, "password");
    }

    { // random
        L.newtable();

        L.Zsetfieldfn(-1, "nextNumber", random.lua_nextnumber);
        L.Zsetfieldfn(-1, "nextInteger", random.lua_nextinteger);
        L.Zsetfieldfn(-1, "nextBoolean", random.lua_boolean);
        L.Zsetfieldfn(-1, "fill", random.lua_fill);

        L.setreadonly(-1, true);
        L.setfield(-2, "random");
    }

    { // AES
        L.newtable();

        { // aes128
            L.newtable();

            L.Zsetfieldfn(-1, "encrypt", aes.lua_aes128_encrypt);
            L.Zsetfieldfn(-1, "decrypt", aes.lua_aes128_decrypt);

            L.setreadonly(-1, true);
            L.setfield(-2, "aes128");
        }

        { // aes256
            L.newtable();

            L.Zsetfieldfn(-1, "encrypt", aes.lua_aes256_encrypt);
            L.Zsetfieldfn(-1, "decrypt", aes.lua_aes256_decrypt);

            L.setreadonly(-1, true);
            L.setfield(-2, "aes256");
        }

        L.setreadonly(-1, true);
        L.setfield(-2, "aes");
    }

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test {
    std.testing.refAllDecls(@This());
}

test "Crypto" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"crypto.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
