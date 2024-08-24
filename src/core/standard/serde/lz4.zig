const std = @import("std");
const luau = @import("luau");
const lz4 = @import("lz4");

const Engine = @import("../../runtime/engine.zig");
const Scheduler = @import("../../runtime/scheduler.zig");

const Luau = luau.Luau;

// Lune compatibility

pub fn lua_compress(L: *Luau) i32 {
    const allocator = L.allocator();

    const string = L.checkString(1);
    const options = L.typeOf(2);

    var level: u32 = 4;

    if (!luau.isNoneOrNil(options)) {
        L.checkType(2, .table);
        const levelType = L.getField(2, "level");
        if (!luau.isNoneOrNil(levelType)) {
            if (levelType != .number) L.raiseErrorStr("Options 'level' field must be a number", .{});
            const num = L.toInteger(-1) catch unreachable;
            if (num < 0) L.raiseErrorStr("Options 'level' must not be less than 0", .{});
            level = @intCast(num);
        }
        L.pop(1);
    }

    var encoder = lz4.Encoder.init(allocator) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    _ = encoder.setLevel(level)
        .setContentChecksum(lz4.Frame.ContentChecksum.Enabled)
        .setBlockMode(lz4.Frame.BlockMode.Independent);
    defer encoder.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    encoder.compressStream(buf.writer().any(), string) catch |err| {
        buf.deinit();
        encoder.deinit();
        L.raiseErrorStr("%s :(", .{@errorName(err).ptr});
    };

    const out = allocator.alloc(u8, buf.items.len + 4) catch |err| {
        buf.deinit();
        encoder.deinit();
        L.raiseErrorStr("%s", .{@errorName(err).ptr});
    };
    defer allocator.free(out);

    const header: [4]u8 = @bitCast(@as(u32, @intCast(string.len)));
    @memcpy(out[0..4], header[0..4]);
    @memcpy(out[4..][0..buf.items.len], buf.items[0..]);

    L.pushLString(out);

    return 1;
}

pub fn lua_decompress(L: *Luau) i32 {
    const allocator = L.allocator();

    const string = L.checkString(1);

    if (string.len < 4) L.raiseErrorStr("InvalidHeader", .{});

    var decoder = lz4.Decoder.init(allocator) catch |err| L.raiseErrorStr("%s", .{@errorName(err).ptr});
    defer decoder.deinit();

    const sizeHint = std.mem.bytesAsSlice(u32, string[0..4])[0];

    const decompressed = decoder.decompress(string[4..], sizeHint) catch |err| {
        decoder.deinit();
        L.raiseErrorStr("%s", .{@errorName(err).ptr});
    };
    defer allocator.free(decompressed);

    L.pushLString(decompressed);

    return 1;
}
