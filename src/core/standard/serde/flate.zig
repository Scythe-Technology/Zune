const std = @import("std");
const luau = @import("luau");

const Luau = luau.Luau;

pub fn lua_compress(L: *Luau) !i32 {
    const allocator = L.allocator();

    const is_buffer = L.typeOf(1) == .buffer;

    const string = if (is_buffer) L.checkBuffer(1) else L.checkString(1);
    const options = L.typeOf(2);

    var level: u4 = 12;

    if (!luau.isNoneOrNil(options)) {
        L.checkType(2, .table);
        const levelType = L.getField(2, "level");
        if (!luau.isNoneOrNil(levelType)) {
            if (levelType != .number)
                return L.Error("Options 'level' field must be a number");
            const num = L.toInteger(-1) catch unreachable;
            if (num < 4 or num > 13)
                return L.Error("Options 'level' must not be over 13 or less than 4 or equal to 10");
            if (num == 10)
                return L.ErrorFmt("Options 'level' cannot be {d}, level does not exist", .{num});
            level = @intCast(num);
        }
        L.pop(1);
    }

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var stream = std.io.fixedBufferStream(string);

    try std.compress.flate.compress(stream.reader(), buf.writer(), .{
        .level = @enumFromInt(level),
    });

    if (is_buffer) L.pushBuffer(buf.items) else L.pushLString(buf.items);

    return 1;
}

pub fn lua_decompress(L: *Luau) !i32 {
    const allocator = L.allocator();

    const is_buffer = L.typeOf(1) == .buffer;

    const string = if (is_buffer) L.checkBuffer(1) else L.checkString(1);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var stream = std.io.fixedBufferStream(string);

    try std.compress.flate.decompress(stream.reader(), buf.writer());

    if (is_buffer) L.pushBuffer(buf.items) else L.pushLString(buf.items);

    return 1;
}
