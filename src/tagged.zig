const TagNames: []const []const u8 = &.{
    // FS
    "FS_FILE",
    // NET
    "NET_SOCKET",
    // PROCESS
    "PROCESS_CHILD",
    // REGEX
    "REGEX_COMPILED",
    // FFI
    "FFI_LIBRARY",
    "FFI_POINTER",
    "FFI_DATATYPE",
    // SQLITE
    "SQLITE_DATABASE",
    "SQLITE_STATEMENT",
};

pub const Tags = block_name: {
    const std = @import("std");

    var list: [TagNames.len]struct { []const u8, comptime_int } = undefined;

    for (TagNames, 0..) |name, i| {
        list[i] = .{ name, i + 1 };
    }

    break :block_name std.StaticStringMap(comptime_int).initComptime(list);
};
