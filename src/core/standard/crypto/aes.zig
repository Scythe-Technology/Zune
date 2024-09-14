const std = @import("std");
const luau = @import("luau");

const common = @import("common.zig");

const Luau = luau.Luau;

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub fn lua_aes128_encrypt(L: *Luau) !i32 {
    const allocator = L.allocator();

    const msg = if (L.typeOf(1) == .buffer) L.checkBuffer(1) else L.checkString(1);
    const key = if (L.typeOf(2) == .buffer) L.checkBuffer(2) else L.checkString(2);
    if (key.len != Aes128Gcm.key_length) L.raiseErrorStr("InvalidKeyLength (key length != 16)", .{});
    const nonce = if (L.typeOf(3) == .buffer) L.checkBuffer(3) else L.checkString(3);
    if (nonce.len != Aes128Gcm.nonce_length) L.raiseErrorStr("InvalidNonceLength (nonce length != 12)", .{});

    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    const c = try allocator.alloc(u8, msg.len);
    defer allocator.free(c);

    var snonce: [Aes128Gcm.nonce_length]u8 = undefined;
    @memcpy(snonce[0..], nonce[0..12]);
    var skey: [Aes128Gcm.key_length]u8 = undefined;
    @memcpy(skey[0..], key[0..16]);

    Aes128Gcm.encrypt(c, &tag, msg, "", snonce, skey);

    L.newTable();

    L.setFieldLString(-1, "cipher", c);
    L.setFieldLString(-1, "tag", &tag);

    return 1;
}

pub fn lua_aes128_decrypt(L: *Luau) !i32 {
    const allocator = L.allocator();

    const cipher = if (L.typeOf(1) == .buffer) L.checkBuffer(1) else L.checkString(1);
    const tag = if (L.typeOf(2) == .buffer) L.checkBuffer(2) else L.checkString(2);
    if (tag.len != Aes128Gcm.tag_length) L.raiseErrorStr("InvalidTagLength (tag length != 16)", .{});
    const key = if (L.typeOf(3) == .buffer) L.checkBuffer(3) else L.checkString(3);
    if (key.len != Aes128Gcm.key_length) L.raiseErrorStr("InvalidKeyLength (key length != 16)", .{});
    const nonce = if (L.typeOf(4) == .buffer) L.checkBuffer(4) else L.checkString(4);
    if (nonce.len != Aes128Gcm.nonce_length) L.raiseErrorStr("InvalidNonceLength (nonce length != 12)", .{});

    const msg = try allocator.alloc(u8, cipher.len);
    defer allocator.free(msg);

    var stag: [Aes128Gcm.tag_length]u8 = undefined;
    @memcpy(stag[0..], tag[0..16]);
    var snonce: [Aes128Gcm.nonce_length]u8 = undefined;
    @memcpy(snonce[0..], nonce[0..12]);
    var skey: [Aes128Gcm.key_length]u8 = undefined;
    @memcpy(skey[0..], key[0..16]);

    try Aes128Gcm.decrypt(msg, cipher, stag, "", snonce, skey);

    L.pushLString(msg);

    return 1;
}

pub fn lua_aes256_encrypt(L: *Luau) !i32 {
    const allocator = L.allocator();

    const msg = if (L.typeOf(1) == .buffer) L.checkBuffer(1) else L.checkString(1);
    const key = if (L.typeOf(2) == .buffer) L.checkBuffer(2) else L.checkString(2);
    if (key.len != Aes256Gcm.key_length) L.raiseErrorStr("InvalidKeyLength (key length != 32)", .{});
    const nonce = if (L.typeOf(3) == .buffer) L.checkBuffer(3) else L.checkString(3);
    if (nonce.len != Aes256Gcm.nonce_length) L.raiseErrorStr("InvalidNonceLength (nonce length != 12)", .{});

    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    const c = try allocator.alloc(u8, msg.len);
    defer allocator.free(c);

    var snonce: [Aes256Gcm.nonce_length]u8 = undefined;
    @memcpy(snonce[0..], nonce[0..12]);
    var skey: [Aes256Gcm.key_length]u8 = undefined;
    @memcpy(skey[0..], key[0..32]);

    Aes256Gcm.encrypt(c, &tag, msg, "", snonce, skey);

    L.newTable();

    L.setFieldLString(-1, "cipher", c);
    L.setFieldLString(-1, "tag", &tag);

    return 1;
}

pub fn lua_aes256_decrypt(L: *Luau) !i32 {
    const allocator = L.allocator();

    const cipher = if (L.typeOf(1) == .buffer) L.checkBuffer(1) else L.checkString(1);
    const tag = if (L.typeOf(2) == .buffer) L.checkBuffer(2) else L.checkString(2);
    if (tag.len != Aes256Gcm.tag_length) L.raiseErrorStr("InvalidTagLength (tag length != 16)", .{});
    const key = if (L.typeOf(3) == .buffer) L.checkBuffer(3) else L.checkString(3);
    if (key.len != Aes256Gcm.key_length) L.raiseErrorStr("InvalidKeyLength (key length != 32)", .{});
    const nonce = if (L.typeOf(4) == .buffer) L.checkBuffer(4) else L.checkString(4);
    if (nonce.len != Aes256Gcm.nonce_length) L.raiseErrorStr("InvalidNonceLength (nonce length != 12)", .{});

    const msg = try allocator.alloc(u8, cipher.len);
    defer allocator.free(msg);

    var stag: [Aes256Gcm.tag_length]u8 = undefined;
    @memcpy(stag[0..], tag[0..16]);
    var snonce: [Aes256Gcm.nonce_length]u8 = undefined;
    @memcpy(snonce[0..], nonce[0..12]);
    var skey: [Aes256Gcm.key_length]u8 = undefined;
    @memcpy(skey[0..], key[0..32]);

    try Aes256Gcm.decrypt(msg, cipher, stag, "", snonce, skey);

    L.pushLString(msg);

    return 1;
}
