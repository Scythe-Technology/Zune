const std = @import("std");
const luau = @import("luau");
const lz4 = @import("lz4");

const VM = luau.VM;

// Lune compatibility

pub fn lua_frame_compress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);
    const options = L.typeOf(2);

    var level: u32 = 4;

    if (!options.isnoneornil()) {
        try L.Zchecktype(2, .Table);
        const levelType = L.getfield(2, "level");
        if (!levelType.isnoneornil()) {
            if (levelType != .Number)
                return L.Zerror("Options 'level' field must be a number");
            const num = L.tointeger(-1) orelse unreachable;
            if (num < 0)
                return L.Zerror("Options 'level' must not be less than 0");
            level = @intCast(num);
        }
        L.pop(1);
    }

    var encoder = try lz4.Encoder.init(allocator);
    _ = encoder.setLevel(level)
        .setContentChecksum(lz4.Frame.ContentChecksum.Enabled)
        .setBlockMode(lz4.Frame.BlockMode.Independent);
    defer encoder.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try encoder.compressStream(buf.writer().any(), string);

    const out = try allocator.alloc(u8, buf.items.len + 4);
    defer allocator.free(out);

    const header: [4]u8 = @bitCast(@as(u32, @intCast(string.len)));
    @memcpy(out[0..4], header[0..4]);
    @memcpy(out[4..][0..buf.items.len], buf.items[0..]);

    if (is_buffer) L.Zpushbuffer(out) else L.pushlstring(out);

    return 1;
}

pub fn lua_frame_decompress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);

    if (string.len < 4)
        return L.Zerror("InvalidHeader");

    var decoder = try lz4.Decoder.init(allocator);
    defer decoder.deinit();

    const sizeHint = std.mem.bytesAsSlice(u32, string[0..4])[0];

    const decompressed = try decoder.decompress(string[4..], sizeHint);
    defer allocator.free(decompressed);

    if (is_buffer) L.Zpushbuffer(decompressed) else L.pushlstring(decompressed);

    return 1;
}

pub fn lua_compress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;
    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);

    const compressed = try lz4.Standard.compress(allocator, string);
    defer allocator.free(compressed);

    if (is_buffer) L.Zpushbuffer(compressed) else L.pushlstring(compressed);

    return 1;
}

pub fn lua_decompress(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const is_buffer = L.typeOf(1) == .Buffer;

    const string = if (is_buffer) L.Lcheckbuffer(1) else L.Lcheckstring(1);
    const sizeHint = try L.Zcheckvalue(i32, 2, null);

    const decompressed = try lz4.Standard.decompress(allocator, string, @intCast(sizeHint));
    defer allocator.free(decompressed);

    if (is_buffer) L.Zpushbuffer(decompressed) else L.pushlstring(decompressed);

    return 1;
}
