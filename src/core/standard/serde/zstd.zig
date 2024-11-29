const std = @import("std");
const luau = @import("luau");
const zstd = @import("zstd");

const Luau = luau.Luau;

pub fn lua_compress(L: *Luau) !i32 {
    const allocator = L.allocator();

    const is_buffer = L.typeOf(1) == .buffer;

    const string = if (is_buffer) L.checkBuffer(1) else L.checkString(1);
    const options = L.typeOf(2);

    var level: i32 = zstd.DEFAULT_COMPRESSION_LEVEL;

    if (!luau.isNoneOrNil(options)) {
        L.checkType(2, .table);
        const levelType = L.getField(2, "level");
        if (!luau.isNoneOrNil(levelType)) {
            if (levelType != .number)
                return L.Error("Options 'level' field must be a number");
            const num = L.toInteger(-1) catch unreachable;
            if (num < zstd.MIN_COMPRESSION_LEVEL or num > zstd.MAX_COMPRESSION_LEVEL)
                return L.ErrorFmt("Options 'level' must not be over {} or less than {}", .{ zstd.MAX_COMPRESSION_LEVEL, zstd.MIN_COMPRESSION_LEVEL });
            level = num;
        }
        L.pop(1);
    }

    const compressed = try zstd.compressAlloc(allocator, string, level);
    defer allocator.free(compressed);

    if (is_buffer) L.pushBuffer(compressed) else L.pushLString(compressed);

    return 1;
}

pub fn lua_decompress(L: *Luau) !i32 {
    const allocator = L.allocator();

    const is_buffer = L.typeOf(1) == .buffer;

    const string = if (is_buffer) L.checkBuffer(1) else L.checkString(1);

    const decompressed = try zstd.decompressAlloc(allocator, string);
    defer allocator.free(decompressed);

    if (is_buffer) L.pushBuffer(decompressed) else L.pushLString(decompressed);

    return 1;
}
