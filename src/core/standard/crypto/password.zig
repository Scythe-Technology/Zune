const std = @import("std");
const luau = @import("luau");

const common = @import("common.zig");

const VM = luau.VM;

const argon2 = std.crypto.pwhash.argon2;
const bcrypt = std.crypto.pwhash.bcrypt;

const AlgorithmUnion = union(enum) {
    argon2: argon2.Mode,
    bcrypt: void,
};

const DEFAULT_ALGO: AlgorithmUnion = .{ .argon2 = .argon2d };
const AlgorithmMap = std.StaticStringMap(AlgorithmUnion).initComptime(.{
    .{ "argon2d", DEFAULT_ALGO },
    .{ "argon2i", AlgorithmUnion{ .argon2 = .argon2i } },
    .{ "argon2id", AlgorithmUnion{ .argon2 = .argon2id } },
    .{ "bcrypt", .bcrypt },
});

pub fn lua_hash(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const password = L.Lcheckstring(1);

    var algorithm = DEFAULT_ALGO;
    var cost: u32 = 65536;
    var cost2: u32 = 2;
    var threads: u24 = 1;

    switch (L.typeOf(2)) {
        .Table => {
            switch (L.getfield(2, "algorithm")) {
                .String => algorithm = AlgorithmMap.get(L.tolstring(-1) orelse unreachable) orelse return L.Zerror("Invalid Algorithm"),
                .None, .Nil => {},
                else => return L.Zerror("Invalid `algorithm` (String expected)"),
            }
            L.pop(1);
            switch (algorithm) {
                .argon2 => {
                    switch (L.getfield(2, "memoryCost")) {
                        .Number => cost = L.tounsigned(-1) orelse unreachable,
                        .None, .Nil => {},
                        else => return L.Zerror("Invalid 'memoryCost' (Number expected)"),
                    }
                    switch (L.getfield(2, "timeCost")) {
                        .Number => cost2 = L.tounsigned(-1) orelse unreachable,
                        .None, .Nil => {},
                        else => return L.Zerror("Invalid 'timeCost' (Number expected)"),
                    }
                    switch (L.getfield(2, "threads")) {
                        .Number => threads = @truncate(L.tounsigned(-1) orelse unreachable),
                        .None, .Nil => {},
                        else => return L.Zerror("Invalid 'threads' (Number expected)"),
                    }
                    L.pop(3);
                },
                .bcrypt => {
                    cost = 4;
                    switch (L.getfield(2, "cost")) {
                        .Number => {
                            cost = L.tounsigned(-1) orelse unreachable;
                            if (cost < 4 or cost > 31)
                                return L.Zerror("Invalid 'cost' (Must be between 4 to 31)");
                        },
                        .None, .Nil => {},
                        else => return L.Zerror("Invalid 'cost' (Number expected)"),
                    }
                    L.pop(1);
                },
            }
        },
        .None, .Nil => {},
        else => L.Lchecktype(2, .Table),
    }

    var buf: [128]u8 = undefined;
    switch (algorithm) {
        .argon2 => |mode| {
            const hash = try argon2.strHash(password, .{
                .allocator = allocator,
                .params = .{ .m = cost, .t = cost2, .p = threads },
                .mode = mode,
            }, &buf);
            L.pushlstring(hash);
        },
        .bcrypt => {
            const hash = try bcrypt.strHash(password, .{
                .allocator = allocator,
                .params = .{ .rounds_log = @intCast(cost) },
                .encoding = .phc,
            }, &buf);
            L.pushlstring(hash);
        },
    }
    return 1;
}

const TAG_BCRYPT: u32 = @bitCast([4]u8{ '$', 'b', 'c', 'r' });

pub fn lua_verify(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const password = L.Lcheckstring(1);
    const hash = L.Lcheckstring(2);

    if (hash.len < 8)
        return L.Zerror("InvalidHash (Must be PHC encoded)");

    if (@as(u32, @bitCast(hash[0..4].*)) == TAG_BCRYPT)
        L.pushboolean(if (bcrypt.strVerify(
            hash,
            password,
            .{ .allocator = allocator },
        )) true else |_| false)
    else
        L.pushboolean(if (argon2.strVerify(
            hash,
            password,
            .{ .allocator = allocator },
        )) true else |_| false);

    return 1;
}
