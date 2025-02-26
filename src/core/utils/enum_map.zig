const std = @import("std");

pub fn Gen(comptime Enum: type) std.StaticStringMap(Enum) {
    const enum_data = @typeInfo(Enum).@"enum";
    var list: [enum_data.fields.len]struct { []const u8, Enum } = undefined;

    for (enum_data.fields, 0..) |field, i| {
        list[i] = .{ field.name, @enumFromInt(field.value) };
    }

    return std.StaticStringMap(Enum).initComptime(list);
}
