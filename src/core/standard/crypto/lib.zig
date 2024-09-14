const std = @import("std");
const luau = @import("luau");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const common = @import("common.zig");

const Luau = luau.Luau;

const hash = std.crypto.hash;

const aes = @import("aes.zig");
const random = @import("random.zig");
const password = @import("password.zig");

pub const LIB_NAME = "@zcore/crypto";

pub fn loadLib(L: *Luau) void {
    L.newTable();

    { // hash
        L.newTable();

        // Md5
        L.setFieldFn(-1, "md5", common.lua_genHashFn(hash.Md5));
        // Sha1
        L.setFieldFn(-1, "sha1", common.lua_genHashFn(hash.Sha1));
        // Blake3
        L.setFieldFn(-1, "blake3", common.lua_genHashFn(hash.Blake3));

        { // Sha2
            L.newTable();

            L.setFieldFn(-1, "sha224", common.lua_genHashFn(hash.sha2.Sha224));
            L.setFieldFn(-1, "sha256", common.lua_genHashFn(hash.sha2.Sha256));
            L.setFieldFn(-1, "sha384", common.lua_genHashFn(hash.sha2.Sha384));
            L.setFieldFn(-1, "sha512", common.lua_genHashFn(hash.sha2.Sha512));

            L.setFieldAhead(-1, "sha2");
        }

        { // Sha3
            L.newTable();

            L.setFieldFn(-1, "sha3_224", common.lua_genHashFn(hash.sha3.Sha3_224));
            L.setFieldFn(-1, "sha3_256", common.lua_genHashFn(hash.sha3.Sha3_256));
            L.setFieldFn(-1, "sha3_384", common.lua_genHashFn(hash.sha3.Sha3_384));
            L.setFieldFn(-1, "sha3_512", common.lua_genHashFn(hash.sha3.Sha3_512));

            L.setFieldAhead(-1, "sha3");
        }

        { // Blake2
            L.newTable();

            L.setFieldFn(-1, "b128", common.lua_genHashFn(hash.blake2.Blake2b128));
            L.setFieldFn(-1, "b160", common.lua_genHashFn(hash.blake2.Blake2b160));
            L.setFieldFn(-1, "b256", common.lua_genHashFn(hash.blake2.Blake2b256));
            L.setFieldFn(-1, "b384", common.lua_genHashFn(hash.blake2.Blake2b384));
            L.setFieldFn(-1, "b512", common.lua_genHashFn(hash.blake2.Blake2b512));

            L.setFieldFn(-1, "s128", common.lua_genHashFn(hash.blake2.Blake2s128));
            L.setFieldFn(-1, "s160", common.lua_genHashFn(hash.blake2.Blake2s160));
            L.setFieldFn(-1, "s224", common.lua_genHashFn(hash.blake2.Blake2s224));
            L.setFieldFn(-1, "s256", common.lua_genHashFn(hash.blake2.Blake2s256));

            L.setFieldAhead(-1, "blake2");
        }

        L.setFieldAhead(-1, "hash");
    }

    { // hmac
        L.newTable();

        // Md5
        L.setFieldFn(-1, "md5", common.lua_genHmacFn(hash.Md5));
        // Sha1
        L.setFieldFn(-1, "sha1", common.lua_genHmacFn(hash.Sha1));
        // Blake3
        L.setFieldFn(-1, "blake3", common.lua_genHmacFn(hash.Blake3));

        { // Sha2
            L.newTable();

            L.setFieldFn(-1, "sha224", common.lua_genHmacFn(hash.sha2.Sha224));
            L.setFieldFn(-1, "sha256", common.lua_genHmacFn(hash.sha2.Sha256));
            L.setFieldFn(-1, "sha384", common.lua_genHmacFn(hash.sha2.Sha384));
            L.setFieldFn(-1, "sha512", common.lua_genHmacFn(hash.sha2.Sha512));

            L.setFieldAhead(-1, "sha2");
        }

        { // Sha3
            L.newTable();

            L.setFieldFn(-1, "sha3_224", common.lua_genHmacFn(hash.sha3.Sha3_224));
            L.setFieldFn(-1, "sha3_256", common.lua_genHmacFn(hash.sha3.Sha3_256));
            L.setFieldFn(-1, "sha3_384", common.lua_genHmacFn(hash.sha3.Sha3_384));
            L.setFieldFn(-1, "sha3_512", common.lua_genHmacFn(hash.sha3.Sha3_512));

            L.setFieldAhead(-1, "sha3");
        }

        { // Blake2
            L.newTable();

            L.setFieldFn(-1, "b128", common.lua_genHmacFn(hash.blake2.Blake2b128));
            L.setFieldFn(-1, "b160", common.lua_genHmacFn(hash.blake2.Blake2b160));
            L.setFieldFn(-1, "b256", common.lua_genHmacFn(hash.blake2.Blake2b256));
            L.setFieldFn(-1, "b384", common.lua_genHmacFn(hash.blake2.Blake2b384));
            L.setFieldFn(-1, "b512", common.lua_genHmacFn(hash.blake2.Blake2b512));

            L.setFieldFn(-1, "s128", common.lua_genHmacFn(hash.blake2.Blake2s128));
            L.setFieldFn(-1, "s160", common.lua_genHmacFn(hash.blake2.Blake2s160));
            L.setFieldFn(-1, "s224", common.lua_genHmacFn(hash.blake2.Blake2s224));
            L.setFieldFn(-1, "s256", common.lua_genHmacFn(hash.blake2.Blake2s256));

            L.setFieldAhead(-1, "blake2");
        }

        L.setFieldAhead(-1, "hmac");
    }

    { // password
        L.newTable();

        L.setFieldFn(-1, "hash", password.lua_hash);
        L.setFieldFn(-1, "verify", password.lua_verify);

        L.setFieldAhead(-1, "password");
    }

    { // random
        L.newTable();

        L.setFieldFn(-1, "nextNumber", random.lua_nextnumber);
        L.setFieldFn(-1, "nextInteger", random.lua_nextinteger);
        L.setFieldFn(-1, "nextBoolean", random.lua_boolean);
        L.setFieldFn(-1, "fill", random.lua_fill);

        L.setFieldAhead(-1, "random");
    }

    { // AES
        L.newTable();

        { // aes128
            L.newTable();

            L.setFieldFn(-1, "encrypt", aes.lua_aes128_encrypt);
            L.setFieldFn(-1, "decrypt", aes.lua_aes128_decrypt);

            L.setFieldAhead(-1, "aes128");
        }

        { // aes256
            L.newTable();

            L.setFieldFn(-1, "encrypt", aes.lua_aes256_encrypt);
            L.setFieldFn(-1, "decrypt", aes.lua_aes256_decrypt);

            L.setFieldAhead(-1, "aes256");
        }

        L.setFieldAhead(-1, "aes");
    }

    _ = L.findTable(luau.REGISTRYINDEX, "_MODULES", 1);
    if (L.getField(-1, LIB_NAME) != .table) {
        L.pop(1);
        L.pushValue(-2);
        L.setField(-2, LIB_NAME);
    } else L.pop(1);
    L.pop(2);
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
