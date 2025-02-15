const std = @import("std");
const luau = @import("luau");

const common = @import("common.zig");

const VM = luau.VM;

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub fn lua_aes128_encrypt(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const msg = try L.Zcheckvalue([]const u8, 1, null);
    const key = try L.Zcheckvalue([]const u8, 2, null);

    if (key.len != Aes128Gcm.key_length)
        return L.Zerror("InvalidKeyLength (key length != 16)");

    const nonce = try L.Zcheckvalue([]const u8, 3, null);

    if (nonce.len != Aes128Gcm.nonce_length)
        return L.Zerror("InvalidNonceLength (nonce length != 12)");

    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    const c = try allocator.alloc(u8, msg.len);
    defer allocator.free(c);

    var snonce: [Aes128Gcm.nonce_length]u8 = undefined;
    @memcpy(snonce[0..], nonce[0..12]);
    var skey: [Aes128Gcm.key_length]u8 = undefined;
    @memcpy(skey[0..], key[0..16]);

    Aes128Gcm.encrypt(c, &tag, msg, "", snonce, skey);

    L.Zpushvalue(.{
        .cipher = c,
        .tag = &tag,
    });

    return 1;
}

pub fn lua_aes128_decrypt(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const cipher = try L.Zcheckvalue([]const u8, 1, null);
    const tag = try L.Zcheckvalue([]const u8, 2, null);

    if (tag.len != Aes128Gcm.tag_length)
        return L.Zerror("InvalidTagLength (tag length != 16)");

    const key = try L.Zcheckvalue([]const u8, 3, null);

    if (key.len != Aes128Gcm.key_length)
        return L.Zerror("InvalidKeyLength (key length != 16)");

    const nonce = try L.Zcheckvalue([]const u8, 4, null);

    if (nonce.len != Aes128Gcm.nonce_length)
        return L.Zerror("InvalidNonceLength (nonce length != 12)");

    const msg = try allocator.alloc(u8, cipher.len);
    defer allocator.free(msg);

    var stag: [Aes128Gcm.tag_length]u8 = undefined;
    @memcpy(stag[0..], tag[0..16]);
    var snonce: [Aes128Gcm.nonce_length]u8 = undefined;
    @memcpy(snonce[0..], nonce[0..12]);
    var skey: [Aes128Gcm.key_length]u8 = undefined;
    @memcpy(skey[0..], key[0..16]);

    try Aes128Gcm.decrypt(msg, cipher, stag, "", snonce, skey);

    L.pushlstring(msg);

    return 1;
}

pub fn lua_aes256_encrypt(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const msg = try L.Zcheckvalue([]const u8, 1, null);
    const key = try L.Zcheckvalue([]const u8, 2, null);

    if (key.len != Aes256Gcm.key_length)
        return L.Zerror("InvalidKeyLength (key length != 32)");

    const nonce = try L.Zcheckvalue([]const u8, 3, null);

    if (nonce.len != Aes256Gcm.nonce_length)
        return L.Zerror("InvalidNonceLength (nonce length != 12)");

    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    const c = try allocator.alloc(u8, msg.len);
    defer allocator.free(c);

    var snonce: [Aes256Gcm.nonce_length]u8 = undefined;
    @memcpy(snonce[0..], nonce[0..12]);
    var skey: [Aes256Gcm.key_length]u8 = undefined;
    @memcpy(skey[0..], key[0..32]);

    Aes256Gcm.encrypt(c, &tag, msg, "", snonce, skey);

    L.Zpushvalue(.{
        .cipher = c,
        .tag = &tag,
    });

    return 1;
}

pub fn lua_aes256_decrypt(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const cipher = try L.Zcheckvalue([]const u8, 1, null);
    const tag = try L.Zcheckvalue([]const u8, 2, null);

    if (tag.len != Aes256Gcm.tag_length)
        return L.Zerror("InvalidTagLength (tag length != 16)");

    const key = try L.Zcheckvalue([]const u8, 3, null);

    if (key.len != Aes256Gcm.key_length)
        return L.Zerror("InvalidKeyLength (key length != 32)");

    const nonce = try L.Zcheckvalue([]const u8, 4, null);

    if (nonce.len != Aes256Gcm.nonce_length)
        return L.Zerror("InvalidNonceLength (nonce length != 12)");

    const msg = try allocator.alloc(u8, cipher.len);
    defer allocator.free(msg);

    var stag: [Aes256Gcm.tag_length]u8 = undefined;
    @memcpy(stag[0..], tag[0..16]);
    var snonce: [Aes256Gcm.nonce_length]u8 = undefined;
    @memcpy(snonce[0..], nonce[0..12]);
    var skey: [Aes256Gcm.key_length]u8 = undefined;
    @memcpy(skey[0..], key[0..32]);

    try Aes256Gcm.decrypt(msg, cipher, stag, "", snonce, skey);

    L.pushlstring(msg);

    return 1;
}
