const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

pub fn lua_genEncryptFn(comptime algorithm: anytype) VM.zapi.LuaZigFn(anyerror!i32) {
    return struct {
        fn encrypt(L: *VM.lua.State) !i32 {
            const allocator = luau.getallocator(L);

            const msg = try L.Zcheckvalue([]const u8, 1, null);
            const key = try L.Zcheckvalue([]const u8, 2, null);

            if (key.len != algorithm.key_length)
                return L.Zerror("InvalidKeyLength (key length != 16)");

            const nonce = try L.Zcheckvalue([]const u8, 3, null);

            if (nonce.len != algorithm.nonce_length)
                return L.Zerror("InvalidNonceLength (nonce length != 12)");

            const ad = try L.Zcheckvalue(?[]const u8, 4, null) orelse "";

            var tag: [algorithm.tag_length]u8 = undefined;
            const c = try allocator.alloc(u8, msg.len);
            defer allocator.free(c);

            var snonce: [algorithm.nonce_length]u8 = undefined;
            @memcpy(snonce[0..], nonce[0..algorithm.nonce_length]);
            var skey: [algorithm.key_length]u8 = undefined;
            @memcpy(skey[0..], key[0..algorithm.key_length]);

            algorithm.encrypt(c, &tag, msg, ad, snonce, skey);

            L.createtable(0, 2);

            L.Zpushbuffer(c);
            L.setfield(-2, "cipher");

            L.Zpushbuffer(&tag);
            L.setfield(-2, "tag");

            return 1;
        }
    }.encrypt;
}

pub fn lua_genDecryptFn(comptime algorithm: anytype) VM.zapi.LuaZigFn(anyerror!i32) {
    return struct {
        fn decrypt(L: *VM.lua.State) !i32 {
            const allocator = luau.getallocator(L);

            const cipher = try L.Zcheckvalue([]const u8, 1, null);
            const tag = try L.Zcheckvalue([]const u8, 2, null);

            if (tag.len != algorithm.tag_length)
                return L.Zerrorf("InvalidTagLength (tag length != {})", .{algorithm.tag_length});

            const key = try L.Zcheckvalue([]const u8, 3, null);

            if (key.len != algorithm.key_length)
                return L.Zerrorf("InvalidKeyLength (key length != {})", .{algorithm.key_length});

            const nonce = try L.Zcheckvalue([]const u8, 4, null);

            if (nonce.len != algorithm.nonce_length)
                return L.Zerrorf("InvalidNonceLength (nonce length != {})", .{algorithm.nonce_length});

            const ad = try L.Zcheckvalue(?[]const u8, 5, null) orelse "";

            const msg = try allocator.alloc(u8, cipher.len);
            defer allocator.free(msg);

            var stag: [algorithm.tag_length]u8 = undefined;
            @memcpy(stag[0..], tag[0..algorithm.tag_length]);
            var snonce: [algorithm.nonce_length]u8 = undefined;
            @memcpy(snonce[0..], nonce[0..algorithm.nonce_length]);
            var skey: [algorithm.key_length]u8 = undefined;
            @memcpy(skey[0..], key[0..algorithm.key_length]);

            try algorithm.decrypt(msg, cipher, stag, ad, snonce, skey);

            L.pushlstring(msg);

            return 1;
        }
    }.decrypt;
}
