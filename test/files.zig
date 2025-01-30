pub const File = struct {
    path: []const u8,
    content: []const u8,
};

fn newFile(comptime path: []const u8) File {
    return .{
        .path = "test/" ++ path,
        .content = @embedFile(path),
    };
}

pub const @"zune.test" = newFile("zune.test.luau");
pub const @"require.test" = newFile("engine/require.test.luau");

pub const @"fs.test" = newFile("standard/fs.test.luau");
pub const @"net.test" = newFile("standard/net.test.luau");
pub const @"luau.test" = newFile("standard/luau.test.luau");
pub const @"task.test" = newFile("standard/task.test.luau");
pub const @"stdio.test" = newFile("standard/stdio.test.luau");
pub const @"regex.test" = newFile("standard/regex.test.luau");
pub const @"sqlite.test" = newFile("standard/sqlite/init.test.luau");
pub const @"process.test" = newFile("standard/process.test.luau");
pub const @"testing.test" = newFile("standard/testing.test.luau");
pub const @"serde.test" = newFile("standard/serde/init.test.luau");
pub const @"datetime.test" = newFile("standard/datetime.test.luau");
pub const @"crypto.test" = newFile("standard/crypto/init.test.luau");
pub const @"ffi.test" = newFile("standard/ffi/init.test.luau");

pub const @"lib.std.test" = newFile("lib/std.test.luau");
