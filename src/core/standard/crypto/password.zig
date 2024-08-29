const std = @import("std");
const luau = @import("luau");

const common = @import("common.zig");

const Luau = luau.Luau;

const argon2 = std.crypto.pwhash.argon2;
const bcrypt = std.crypto.pwhash.bcrypt;

const Algorithm = enum {
    argon2d,
    argon2i,
    argon2id,
    bcrypt,
};

const AlgorithmUnion = union(Algorithm) {
    argon2d: argon2.Mode,
    argon2i: argon2.Mode,
    argon2id: argon2.Mode,
    bcrypt: void,
};

const DEFAULT_ALGO: AlgorithmUnion = .{ .argon2d = .argon2d };
const AlgorithmMap = std.StaticStringMap(AlgorithmUnion).initComptime(.{
    .{ "argon2d", DEFAULT_ALGO },
    .{ "argon2i", .{ .argon2i = .argon2i } },
    .{ "argon2id", .{ .argon2id = .argon2id } },
    .{ "bcrypt", .{ .bcrypt = @as(void, undefined) } },
});

pub fn lua_hash(L: *Luau) !i32 {
    const allocator = L.allocator();
    const password = L.checkString(1);

    var algorithm = DEFAULT_ALGO;
    var cost: u32 = 65536;
    var cost2: u32 = 2;

    switch (try L.typeOfObjConsumed(2)) {
        .table => {
            switch (try L.getFieldObjConsumed(2, "algorithm")) {
                .string => |s| algorithm = AlgorithmMap.get(s) orelse L.raiseErrorStr("Invalid Algorithm", .{}),
                .none, .nil => {},
                else => return L.raiseErrorStr("Invalid `algorithm` (String expected)", .{}),
            }
            switch (algorithm) {
                .argon2d, .argon2i, .argon2id => {
                    switch (try L.getFieldObjConsumed(2, "memoryCost")) {
                        .number => |n| cost = @intFromFloat(n),
                        .none, .nil => {},
                        else => L.raiseErrorStr("Invalid 'memoryCost' (Number expected)", .{}),
                    }
                    switch (try L.getFieldObjConsumed(2, "timeCost")) {
                        .number => |n| cost2 = @intFromFloat(n),
                        .none, .nil => {},
                        else => L.raiseErrorStr("Invalid 'timeCost' (Number expected)", .{}),
                    }
                },
                .bcrypt => {
                    cost = 4;
                    switch (try L.getFieldObjConsumed(2, "cost")) {
                        .number => |n| {
                            cost = @intFromFloat(n);
                            if (cost < 4 or cost > 31) L.raiseErrorStr("Invalid 'cost' (Must be between 4 to 31)", .{});
                        },
                        .none, .nil => {},
                        else => L.raiseErrorStr("Invalid 'cost' (Number expected)", .{}),
                    }
                },
            }
        },
        .none, .nil => {},
        else => L.checkType(2, .table),
    }

    var buf: [128]u8 = undefined;
    switch (algorithm) {
        .argon2d, .argon2i, .argon2id => |mode| {
            const hash = try argon2.strHash(password, .{
                .allocator = allocator,
                .params = .{ .m = cost, .t = cost2, .p = 1 },
                .mode = mode,
            }, &buf);
            L.pushLString(hash);
        },
        .bcrypt => {
            const hash = try bcrypt.strHash(password, .{
                .allocator = allocator,
                .params = .{ .rounds_log = @intCast(cost) },
                .encoding = .phc,
            }, &buf);
            L.pushLString(hash);
        },
    }
    return 1;
}

const TAG_BCRYPT: u32 = @bitCast([4]u8{ '$', 'b', 'c', 'r' });

pub fn lua_verify(L: *Luau) i32 {
    const allocator = L.allocator();
    const password = L.checkString(1);
    const hash = L.checkString(2);

    if (hash.len < 8) L.raiseErrorStr("InvalidHash (Must be PHC encoded)", .{});

    if (@as(u32, @bitCast(hash[0..4].*)) == TAG_BCRYPT) L.pushBoolean(if (bcrypt.strVerify(
        hash,
        password,
        .{ .allocator = allocator },
    )) true else |_| false) else L.pushBoolean(if (argon2.strVerify(
        hash,
        password,
        .{ .allocator = allocator },
    )) true else |_| false);

    return 1;
}
