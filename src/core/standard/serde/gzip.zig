const std = @import("std");
const luau = @import("luau");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const Luau = luau.Luau;

pub fn lua_compress(L: *Luau) i32 {
    const allocator = L.allocator();

    const string = L.checkString(1);
    const options = L.typeOf(2);

    var level: u4 = 12;

    if (!luau.isNoneOrNil(options)) {
        L.checkType(2, .table);
        const levelType = L.getField(2, "level");
        if (!luau.isNoneOrNil(levelType)) {
            if (levelType != .number) L.raiseErrorStr("Options 'level' field must be a number", .{});
            const num = L.toInteger(-1) catch unreachable;
            if (num < 4 or num > 13) L.raiseErrorStr("Options 'level' must not be over 13 or less than 4 or equal to 10", .{});
            if (num == 10) L.raiseErrorStr("Options 'level' cannot be %d, level does not exist", .{num});
            level = @intCast(num);
        }
        L.pop(1);
    }

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var stream = std.io.fixedBufferStream(string);

    std.compress.gzip.compress(stream.reader(), buf.writer(), .{
        .level = @enumFromInt(level),
    }) catch |err| {
        buf.deinit();
        L.raiseErrorStr("%s", .{@errorName(err).ptr});
    };

    L.pushLString(buf.items);

    return 1;
}

pub fn lua_decompress(L: *Luau) i32 {
    const allocator = L.allocator();

    const string = L.checkString(1);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var stream = std.io.fixedBufferStream(string);

    std.compress.gzip.decompress(stream.reader(), buf.writer()) catch |err| {
        buf.deinit();
        L.raiseErrorStr("%s", .{@errorName(err).ptr});
    };

    L.pushLString(buf.items);

    return 1;
}
