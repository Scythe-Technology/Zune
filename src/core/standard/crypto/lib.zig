const std = @import("std");
const luau = @import("luau");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const luaHelper = @import("../../utils/luahelper.zig");
const tagged = @import("../../../tagged.zig");
const MethodMap = @import("../../utils/method_map.zig");
const EnumMap = @import("../../utils/enum_map.zig");

const common = @import("common.zig");

const VM = luau.VM;

const TAG_CRYPTO_HASHER = tagged.Tags.get("CRYPTO_HASHER").?;

const hash = std.crypto.hash;
const aead = std.crypto.aead;

const random = @import("random.zig");
const password = @import("password.zig");

pub const LIB_NAME = "crypto";

const LuaCryptoHasher = struct {
    state: []u8,
    extra: ?[]u8,
    algorithm: Algorithm,
    used: bool = false,

    pub const Algorithm = enum {
        md5,
        sha1,
        sha224,
        sha256,
        sha384,
        sha512,
        sha3_224,
        sha3_256,
        sha3_384,
        sha3_512,
        blake2b128,
        blake2b160,
        blake2b256,
        blake2b384,
        blake2b512,
        blake2s128,
        blake2s160,
        blake2s224,
        blake2s256,
        blake3,

        pub const LargestBlockLength = len: {
            var largest = 0;
            for (@typeInfo(Algorithm).@"enum".fields) |field| {
                const value: Algorithm = @enumFromInt(field.value);
                largest = @max(largest, value.block_length());
            }
            break :len largest;
        };

        pub fn block_length(self: Algorithm) usize {
            return switch (self) {
                inline else => |algo| @field(algo.hasher(), "block_length"),
            };
        }

        pub fn digest_length(self: Algorithm) usize {
            return switch (self) {
                inline else => |algo| @field(algo.hasher(), "digest_length"),
            };
        }

        pub fn size(self: Algorithm) usize {
            return switch (self) {
                inline else => |algo| @sizeOf(algo.hasher()),
            };
        }

        pub fn quickHash(self: Algorithm, value: []const u8, out: []u8) void {
            switch (self) {
                inline else => |algo| {
                    const Hasher = algo.hasher();
                    Hasher.hash(value, out[0..@field(Hasher, "digest_length")], .{});
                },
            }
        }

        pub fn update(self: Algorithm, state: []u8, value: []const u8) void {
            switch (self) {
                inline else => |algo| {
                    algo.hasher().update(@ptrCast(@alignCast(state.ptr)), value);
                },
            }
        }

        pub fn final(self: Algorithm, state: []u8, buf: []u8) void {
            switch (self) {
                inline else => |algo| {
                    const Hasher = algo.hasher();
                    Hasher.final(@ptrCast(@alignCast(state.ptr)), buf[0..@field(Hasher, "digest_length")]);
                },
            }
        }

        pub fn init(self: Algorithm, state: []u8) void {
            return switch (self) {
                inline else => |algo| {
                    const state_ptr: *algo.hasher() = @ptrCast(@alignCast(state.ptr));
                    state_ptr.* = algo.hasher().init(.{});
                },
            };
        }

        pub fn hasher(comptime algo: Algorithm) type {
            return switch (algo) {
                .md5 => hash.Md5,
                .sha1 => hash.Sha1,
                .sha224 => hash.sha2.Sha224,
                .sha256 => hash.sha2.Sha256,
                .sha384 => hash.sha2.Sha384,
                .sha512 => hash.sha2.Sha512,
                .sha3_224 => hash.sha3.Sha3_224,
                .sha3_256 => hash.sha3.Sha3_256,
                .sha3_384 => hash.sha3.Sha3_384,
                .sha3_512 => hash.sha3.Sha3_512,
                .blake2b128 => hash.blake2.Blake2b128,
                .blake2b160 => hash.blake2.Blake2b160,
                .blake2b256 => hash.blake2.Blake2b256,
                .blake2b384 => hash.blake2.Blake2b384,
                .blake2b512 => hash.blake2.Blake2b512,
                .blake2s128 => hash.blake2.Blake2s128,
                .blake2s160 => hash.blake2.Blake2s160,
                .blake2s224 => hash.blake2.Blake2s224,
                .blake2s256 => hash.blake2.Blake2s256,
                .blake3 => hash.Blake3,
            };
        }
    };

    pub const AlgorithmMap = EnumMap.Gen(Algorithm);

    pub const META = "crypto_hash_instance";

    fn update(self: *LuaCryptoHasher, L: *VM.lua.State) !i32 {
        if (self.extra != null and self.used)
            return L.Zerror("Hasher already used");
        const value = try L.Zcheckvalue([]const u8, 2, null);

        switch (self.algorithm) {
            inline else => |algo| {
                algo.update(self.state, value);
            },
        }

        return 0;
    }

    const DigestEncoding = enum {
        hex,
        base64,
        binary,
    };
    const DigestEncodingMap = EnumMap.Gen(DigestEncoding);
    fn digest(self: *LuaCryptoHasher, L: *VM.lua.State) !i32 {
        if (self.extra != null and self.used)
            return L.Zerror("Hasher already used");
        const encoding_name = try L.Zcheckvalue(?[:0]const u8, 2, null);
        const encoding = if (encoding_name) |name|
            DigestEncodingMap.get(name) orelse return L.Zerrorf("Invalid encoding: {s}", .{name})
        else
            null;
        switch (self.algorithm) {
            inline else => |algo| {
                const Hasher = algo.hasher();
                const digest_length = @field(Hasher, "digest_length");
                const block_length = @field(Hasher, "block_length");
                var buf: [digest_length]u8 = undefined;

                algo.final(self.state, &buf);

                if (self.extra) |e| {
                    var ohash = Hasher.init(.{});
                    ohash.update(e[0..block_length]);
                    ohash.update(&buf);
                    ohash.final(&buf);
                    self.used = true;
                } else {
                    algo.init(self.state);
                }

                if (encoding) |enc| {
                    switch (enc) {
                        .hex => {
                            const hex = std.fmt.bytesToHex(&buf, .lower);
                            L.pushlstring(&hex);
                        },
                        .base64 => {
                            const allocator = luau.getallocator(L);
                            const base64_buf = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(buf.len));
                            defer allocator.free(base64_buf);
                            L.pushlstring(std.base64.standard.Encoder.encode(base64_buf, &buf));
                        },
                        .binary => L.Zpushbuffer(&buf),
                    }
                } else {
                    L.Zpushbuffer(&buf);
                }
            },
        }
        return 1;
    }

    fn copy(self: *LuaCryptoHasher, L: *VM.lua.State) !i32 {
        if (self.extra != null and self.used)
            return L.Zerror("Hasher already used");
        const allocator = luau.getallocator(L);

        const hasher = L.newuserdatataggedwithmetatable(LuaCryptoHasher, TAG_CRYPTO_HASHER);

        const state = try allocator.dupe(u8, self.state);
        errdefer allocator.free(state);

        const extra = if (self.extra) |e| try allocator.dupe(u8, e) else null;
        errdefer if (extra) |e| allocator.free(e);

        hasher.* = .{
            .algorithm = self.algorithm,
            .state = state,
            .extra = extra,
        };

        return 1;
    }

    pub const __namecall = MethodMap.CreateNamecallMap(LuaCryptoHasher, TAG_CRYPTO_HASHER, .{
        .{ "update", update },
        .{ "digest", digest },
        .{ "copy", copy },
    });

    pub fn __dtor(L: *VM.lua.State, self: *LuaCryptoHasher) void {
        const allocator = luau.getallocator(L);

        allocator.free(self.state);
        if (self.extra) |e|
            allocator.free(e);
    }
};

fn crypto_createHash(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const name = try L.Zcheckvalue([:0]const u8, 1, null);
    const secret = try L.Zcheckvalue(?[:0]const u8, 2, null);
    const algo = LuaCryptoHasher.AlgorithmMap.get(name) orelse return L.Zerrorf("Invalid algorithm: {s}", .{name});

    const block_length = algo.block_length();
    const digest_length = algo.digest_length();

    const ptr = L.newuserdatataggedwithmetatable(LuaCryptoHasher, TAG_CRYPTO_HASHER);

    const state = try allocator.alloc(u8, algo.size());
    errdefer allocator.free(state);

    const extra = if (secret != null) try allocator.alloc(u8, block_length) else null;

    algo.init(state);

    if (secret) |s| {
        // from std.crypto.auth.hmac
        const op_block_len = LuaCryptoHasher.Algorithm.LargestBlockLength;
        var scratch: [op_block_len]u8 = undefined;
        var i_key_pad: [op_block_len]u8 = undefined;

        if (s.len > block_length) {
            algo.quickHash(s, scratch[0..digest_length]);
            @memset(scratch[digest_length..block_length], 0);
        } else if (s.len < block_length) {
            @memcpy(scratch[0..s.len], s);
            @memset(scratch[s.len..block_length], 0);
        } else {
            @memcpy(&scratch, s);
        }
        // Normalize key length to block size of hash
        for (extra.?, 0..) |*b, i| {
            b.* = scratch[i] ^ 0x5c;
        }

        for (i_key_pad[0..block_length], 0..) |*b, i| {
            b.* = scratch[i] ^ 0x36;
        }

        algo.update(state, i_key_pad[0..block_length]);
    }

    ptr.* = .{
        .algorithm = algo,
        .state = state,
        .extra = extra,
    };

    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Znewmetatable(LuaCryptoHasher.META, .{
            .__namecall = LuaCryptoHasher.__namecall,
            .__metatable = "Metatable is locked",
        });
        L.setreadonly(-1, true);
        L.setuserdatadtor(LuaCryptoHasher, TAG_CRYPTO_HASHER, LuaCryptoHasher.__dtor);
        L.setuserdatametatable(TAG_CRYPTO_HASHER);
    }

    L.createtable(0, 5);

    L.Zsetfieldfn(-1, "createHash", crypto_createHash);

    { // password
        L.Zpushvalue(.{
            .hash = password.lua_hash,
            .verify = password.lua_verify,
        });
        L.setreadonly(-1, true);
        L.setfield(-2, "password");
    }

    { // random
        L.Zpushvalue(.{
            .nextNumber = random.lua_nextnumber,
            .nextInteger = random.lua_nextinteger,
            .nextBoolean = random.lua_boolean,
            .fill = random.lua_fill,
        });
        L.setreadonly(-1, true);
        L.setfield(-2, "random");
    }

    { // aes_gcm
        L.createtable(0, 2);

        { // aes128
            L.Zpushvalue(.{
                .encrypt = common.lua_genEncryptFn(aead.aes_gcm.Aes128Gcm),
                .decrypt = common.lua_genDecryptFn(aead.aes_gcm.Aes128Gcm),
            });
            L.setreadonly(-1, true);
            L.setfield(-2, "aes128");
        }

        { // aes256
            L.Zpushvalue(.{
                .encrypt = common.lua_genEncryptFn(aead.aes_gcm.Aes256Gcm),
                .decrypt = common.lua_genDecryptFn(aead.aes_gcm.Aes256Gcm),
            });
            L.setreadonly(-1, true);
            L.setfield(-2, "aes256");
        }

        L.setreadonly(-1, true);
        L.setfield(-2, "aes_gcm");
    }

    { // aes_ocb
        L.createtable(0, 2);

        { // aes128
            L.Zpushvalue(.{
                .encrypt = common.lua_genEncryptFn(aead.aes_ocb.Aes128Ocb),
                .decrypt = common.lua_genDecryptFn(aead.aes_ocb.Aes128Ocb),
            });
            L.setreadonly(-1, true);
            L.setfield(-2, "aes128");
        }

        { // aes256
            L.Zpushvalue(.{
                .encrypt = common.lua_genEncryptFn(aead.aes_ocb.Aes256Ocb),
                .decrypt = common.lua_genDecryptFn(aead.aes_ocb.Aes256Ocb),
            });
            L.setreadonly(-1, true);
            L.setfield(-2, "aes256");
        }

        L.setreadonly(-1, true);
        L.setfield(-2, "aes_ocb");
    }

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test {
    std.testing.refAllDecls(@This());
}

test "Crypto" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/crypto/init.test.luau"),
        &.{},
        true,
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
