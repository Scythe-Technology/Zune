const std = @import("std");
const luau = @import("luau");
const lz4 = @import("lz4");

const Luau = luau.Luau;

// Lune compatibility

pub fn lua_frame_compress(L: *Luau) !i32 {
    const allocator = L.allocator();

    const is_buffer = L.typeOf(1) == .buffer;

    const string = if (is_buffer) L.checkBuffer(1) else L.checkString(1);
    const options = L.typeOf(2);

    var level: u32 = 4;

    if (!luau.isNoneOrNil(options)) {
        L.checkType(2, .table);
        const levelType = L.getField(2, "level");
        if (!luau.isNoneOrNil(levelType)) {
            if (levelType != .number)
                return L.Error("Options 'level' field must be a number");
            const num = L.toInteger(-1) catch unreachable;
            if (num < 0)
                return L.Error("Options 'level' must not be less than 0");
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

    if (is_buffer)
        L.pushBuffer(out)
    else
        L.pushLString(out);

    return 1;
}

pub fn lua_frame_decompress(L: *Luau) !i32 {
    const allocator = L.allocator();

    const is_buffer = L.typeOf(1) == .buffer;

    const string = if (is_buffer) L.checkBuffer(1) else L.checkString(1);

    if (string.len < 4)
        return L.Error("InvalidHeader");

    var decoder = try lz4.Decoder.init(allocator);
    defer decoder.deinit();

    const sizeHint = std.mem.bytesAsSlice(u32, string[0..4])[0];

    const decompressed = try decoder.decompress(string[4..], sizeHint);
    defer allocator.free(decompressed);

    if (is_buffer)
        L.pushBuffer(decompressed)
    else
        L.pushLString(decompressed);

    return 1;
}

pub fn lua_compress(L: *Luau) !i32 {
    const allocator = L.allocator();

    const is_buffer = L.typeOf(1) == .buffer;
    const string = if (is_buffer) L.checkBuffer(1) else L.checkString(1);

    const compressed = try lz4.Standard.compress(allocator, string);
    defer allocator.free(compressed);

    if (is_buffer)
        L.pushBuffer(compressed)
    else
        L.pushLString(compressed);

    return 1;
}

pub fn lua_decompress(L: *Luau) !i32 {
    const allocator = L.allocator();

    const is_buffer = L.typeOf(1) == .buffer;

    const string = if (is_buffer) L.checkBuffer(1) else L.checkString(1);
    const sizeHint = L.checkInteger(2);

    const decompressed = try lz4.Standard.decompress(allocator, string, @intCast(sizeHint));
    defer allocator.free(decompressed);

    if (is_buffer)
        L.pushBuffer(decompressed)
    else
        L.pushLString(decompressed);

    return 1;
}
