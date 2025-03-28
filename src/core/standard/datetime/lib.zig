const std = @import("std");
const luau = @import("luau");
const time = @import("datetime");
const builtin = @import("builtin");

const parse = @import("parse.zig");

const tagged = @import("../../../tagged.zig");

const luaHelper = @import("../../utils/luahelper.zig");
const MethodMap = @import("../../utils/method_map.zig");

const VM = luau.VM;

const TAG_DATETIME = tagged.Tags.get("DATETIME").?;

pub const LIB_NAME = "datetime";
pub fn PlatformSupported() bool {
    switch (comptime builtin.cpu.arch) {
        .x86_64,
        .aarch64,
        .aarch64_be,
        .riscv64,
        .wasm64,
        .powerpc64,
        .powerpc64le,
        .loongarch64,
        .mips64,
        .mips64el,
        .spirv64,
        .sparc64,
        .nvptx64,
        => return true,
        else => return false,
    }
}

pub const LuaDatetime = struct {
    datetime: time.Datetime,
    timezone: ?time.Timezone,

    fn toIsoDate(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const datetime = self.datetime;
        const utc = if (datetime.isAware())
            try datetime.tzLocalize(null)
        else
            datetime;

        L.pushfstring("{}Z", .{utc});

        return 1;
    }

    fn toLocalTime(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const datetime = self.datetime;
        var tz = try time.Timezone.tzLocal(allocator);
        defer tz.deinit();
        const date = if (datetime.isNaive())
            try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC })
        else
            datetime;
        const local = try date.tzConvert(.{ .tz = &tz });

        L.Zpushvalue(.{
            .year = local.year,
            .month = local.month,
            .day = local.day,
            .hour = local.hour,
            .minute = local.minute,
            .second = local.second,
            .millisecond = @divFloor(local.nanosecond, std.time.ns_per_ms),
        });

        return 1;
    }

    fn toUniversalTime(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const datetime = self.datetime;
        const utc = if (datetime.isAware())
            try datetime.tzConvert(.{ .tz = &time.Timezone.UTC })
        else
            try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC });

        L.Zpushvalue(.{
            .year = utc.year,
            .month = utc.month,
            .day = utc.day,
            .hour = utc.hour,
            .minute = utc.minute,
            .second = utc.second,
            .millisecond = @divFloor(utc.nanosecond, std.time.ns_per_ms),
        });

        return 1;
    }

    fn formatLocalTime(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const datetime = self.datetime;
        const format_str = L.Lcheckstring(2);
        var tz = try time.Timezone.tzLocal(allocator);
        defer tz.deinit();
        const date = if (datetime.isNaive())
            try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC })
        else
            datetime;
        const local = try date.tzConvert(.{ .tz = &tz });

        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try local.toString(format_str, buf.writer());

        L.pushlstring(buf.items);

        return 1;
    }

    fn formatUniversalTime(self: *LuaDatetime, L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);

        const datetime = self.datetime;
        const format_str = L.Lcheckstring(2);
        const utc = if (datetime.isAware())
            try datetime.tzConvert(.{ .tz = &time.Timezone.UTC })
        else
            try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC });

        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try utc.toString(format_str, buf.writer());

        L.pushlstring(buf.items);

        return 1;
    }

    pub const __namecall = MethodMap.CreateNamecallMap(LuaDatetime, TAG_DATETIME, .{
        .{ "toIsoDate", toIsoDate },
        .{ "ToIsoDate", toIsoDate },
        .{ "toLocalTime", toLocalTime },
        .{ "ToLocalTime", toLocalTime },
        .{ "toUniversalTime", toUniversalTime },
        .{ "ToUniversalTime", toUniversalTime },
        .{ "formatLocalTime", formatLocalTime },
        .{ "FormatLocalTime", formatLocalTime },
        .{ "formatUniversalTime", formatUniversalTime },
        .{ "FormatUniversalTime", formatUniversalTime },
    });

    pub fn __index(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr = L.touserdata(LuaDatetime, 1) orelse unreachable;

        const index = L.Lcheckstring(2);

        if (std.mem.eql(u8, index, "unixTimestamp") or std.mem.eql(u8, index, "UnixTimestamp")) {
            L.pushnumber(@floatFromInt(ptr.datetime.toUnix(.second)));
            return 1;
        } else if (std.mem.eql(u8, index, "unixTimestampMillis") or std.mem.eql(u8, index, "UnixTimestampMillis")) {
            L.pushnumber(@floatFromInt(ptr.datetime.toUnix(.millisecond)));
            return 1;
        }
        return 0;
    }

    pub fn __dtor(_: *VM.lua.State, self: *LuaDatetime) void {
        if (self.timezone) |*tz| {
            tz.deinit();
            self.timezone = null;
        }
    }
};

fn datetime_now(L: *VM.lua.State) !i32 {
    const self = L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.now(null),
        .timezone = null,
    };
    return 1;
}

fn datetime_fromUnixTimestamp(L: *VM.lua.State) !i32 {
    const timestamp = L.Lchecknumber(1);

    const self = L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.fromUnix(@intFromFloat(timestamp), .second, null),
        .timezone = null,
    };
    return 1;
}

fn datetime_fromUnixTimestampMillis(L: *VM.lua.State) !i32 {
    const timestamp = L.Lchecknumber(1);

    const self = L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.fromUnix(@intFromFloat(timestamp), .millisecond, null),
        .timezone = null,
    };
    return 1;
}

fn datetime_fromUniversalTime(L: *VM.lua.State) !i32 {
    const year = L.Loptinteger(1, 1970);
    const month = L.Loptinteger(2, 1);
    const day = L.Loptinteger(3, 1);
    const hour = L.Loptinteger(4, 0);
    const minute = L.Loptinteger(5, 0);
    const second = L.Loptinteger(6, 0);
    const millisecond = L.Loptinteger(7, 0);

    const self = L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.fromFields(.{
            .year = @intCast(year),
            .month = @intCast(month),
            .day = @intCast(day),
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .second = @intCast(second),
            .nanosecond = @intCast(millisecond * std.time.ns_per_ms),
        }),
        .timezone = null,
    };
    return 1;
}

fn datetime_fromLocalTime(L: *VM.lua.State) !i32 {
    const year = L.Loptinteger(1, 1970);
    const month = L.Loptinteger(2, 1);
    const day = L.Loptinteger(3, 1);
    const hour = L.Loptinteger(4, 0);
    const minute = L.Loptinteger(5, 0);
    const second = L.Loptinteger(6, 0);
    const millisecond = L.Loptinteger(7, 0);

    const allocator = luau.getallocator(L);

    const self = L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.timezone = try time.Timezone.tzLocal(allocator);
    errdefer {
        self.timezone.?.deinit();
        self.timezone = null;
    }
    self.datetime = try time.Datetime.fromFields(.{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .nanosecond = @intCast(millisecond * std.time.ns_per_ms),
        .tz_options = if (self.timezone) |*tz| .{ .tz = tz } else null,
    });
    return 1;
}

fn datetime_fromIsoDate(L: *VM.lua.State) !i32 {
    const iso_date = L.Lcheckstring(1);

    const self = L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    self.* = .{
        .datetime = try time.Datetime.fromISO8601(iso_date),
        .timezone = null,
    };
    return 1;
}

fn datetime_parse(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const date_string = L.Lcheckstring(1);

    const self = L.newuserdatataggedwithmetatable(LuaDatetime, TAG_DATETIME);
    try parse.parse(self, allocator, date_string);

    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Znewmetatable(@typeName(LuaDatetime), .{
            .__index = LuaDatetime.__index,
            .__namecall = LuaDatetime.__namecall,
            .__metatable = "Metatable is locked",
        });
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_DATETIME);
        L.setuserdatadtor(LuaDatetime, TAG_DATETIME, LuaDatetime.__dtor);
    }

    L.Zpushvalue(.{
        .now = datetime_now,
        .parse = datetime_parse,
        .fromIsoDate = datetime_fromIsoDate,
        .fromUniversalTime = datetime_fromUniversalTime,
        .fromLocalTime = datetime_fromLocalTime,
        .fromUnixTimestamp = datetime_fromUnixTimestamp,
        .fromUnixTimestampMillis = datetime_fromUnixTimestampMillis,
    });
    L.setreadonly(-1, true);

    luaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = parse;
}

test "Datetime" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/datetime.test.luau"),
        &.{},
        true,
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
