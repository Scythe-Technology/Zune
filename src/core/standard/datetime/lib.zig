const std = @import("std");
const luau = @import("luau");
const time = @import("datetime");

const parse = @import("parse.zig");

const Time = @import("time.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const VM = luau.VM;

pub const LIB_NAME = "datetime";

const LuaDatetime = struct {
    pub const META = "datetime_instance";

    pub fn __namecall(L: *VM.lua.State) !i32 {
        L.Lchecktype(1, .Userdata);
        const ptr = L.touserdata(Time, 1) orelse unreachable;

        const namecall = L.namecallstr() orelse return 0;

        const allocator = luau.getallocator(L);

        const datetime = ptr.datatime;

        if (std.mem.eql(u8, namecall, "toIsoDate") or std.mem.eql(u8, namecall, "ToIsoDate")) {
            const utc = if (datetime.isAware())
                try datetime.tzLocalize(null)
            else
                datetime.*;

            L.pushfstring("{}Z", .{utc});

            return 1;
        } else if (std.mem.eql(u8, namecall, "toLocalTime") or std.mem.eql(u8, namecall, "ToLocalTime")) {
            var tz = try time.Timezone.tzLocal(allocator);
            defer tz.deinit();
            const date = if (datetime.isNaive())
                try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC })
            else
                datetime.*;
            const local = try date.tzConvert(.{ .tz = &tz });
            L.newtable();

            L.Zsetfield(-1, "year", local.year);
            L.Zsetfield(-1, "month", local.month);
            L.Zsetfield(-1, "day", local.day);
            L.Zsetfield(-1, "hour", local.hour);
            L.Zsetfield(-1, "minute", local.minute);
            L.Zsetfield(-1, "second", local.second);
            L.Zsetfield(-1, "millisecond", @divFloor(local.nanosecond, std.time.ns_per_ms));

            return 1;
        } else if (std.mem.eql(u8, namecall, "toUniversalTime") or std.mem.eql(u8, namecall, "ToUniversalTime")) {
            const utc = if (datetime.isAware())
                try datetime.tzConvert(.{ .tz = &time.Timezone.UTC })
            else
                try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC });
            L.newtable();

            L.Zsetfield(-1, "year", utc.year);
            L.Zsetfield(-1, "month", utc.month);
            L.Zsetfield(-1, "day", utc.day);
            L.Zsetfield(-1, "hour", utc.hour);
            L.Zsetfield(-1, "minute", utc.minute);
            L.Zsetfield(-1, "second", utc.second);
            L.Zsetfield(-1, "millisecond", @divFloor(utc.nanosecond, std.time.ns_per_ms));

            return 1;
        } else if (std.mem.eql(u8, namecall, "formatLocalTime") or std.mem.eql(u8, namecall, "FormatLocalTime")) {
            const format_str = L.Lcheckstring(2);
            var tz = try time.Timezone.tzLocal(allocator);
            defer tz.deinit();
            const date = if (datetime.isNaive())
                try datetime.tzLocalize(.{ .tz = &time.Timezone.UTC })
            else
                datetime.*;
            const local = try date.tzConvert(.{ .tz = &tz });

            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();

            try local.toString(format_str, buf.writer());

            L.pushlstring(buf.items);

            return 1;
        } else if (std.mem.eql(u8, namecall, "formatUniversalTime") or std.mem.eql(u8, namecall, "FormatUniversalTime")) {
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
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn __index(L: *VM.lua.State) i32 {
        L.Lchecktype(1, .Userdata);
        const ptr = L.touserdata(Time, 1) orelse unreachable;

        const index = L.Lcheckstring(2);

        if (std.mem.eql(u8, index, "unixTimestamp") or std.mem.eql(u8, index, "UnixTimestamp")) {
            L.pushnumber(@floatFromInt(ptr.datatime.toUnix(.second)));
            return 1;
        } else if (std.mem.eql(u8, index, "unixTimestampMillis") or std.mem.eql(u8, index, "UnixTimestampMillis")) {
            L.pushnumber(@floatFromInt(ptr.datatime.toUnix(.millisecond)));
            return 1;
        }
        return 0;
    }

    pub fn __dtor(ptr: *Time) void {
        ptr.deinit();
    }
};

fn datetime_now(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const ptr = L.newuserdatadtor(Time, LuaDatetime.__dtor);
    ptr.* = try Time.fromTime(allocator, try time.Datetime.now(null), null);
    if (L.Lgetmetatable(LuaDatetime.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_fromUnixTimestamp(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const timestamp = L.Lchecknumber(1);
    const ptr = L.newuserdatadtor(Time, LuaDatetime.__dtor);
    ptr.* = try Time.fromTime(allocator, try time.Datetime.fromUnix(@intFromFloat(timestamp), .second, null), null);
    if (L.Lgetmetatable(LuaDatetime.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_fromUnixTimestampMillis(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const timestamp = L.Lchecknumber(1);
    const ptr = L.newuserdatadtor(Time, LuaDatetime.__dtor);
    ptr.* = try Time.fromTime(allocator, try time.Datetime.fromUnix(@intFromFloat(timestamp), .millisecond, null), null);
    if (L.Lgetmetatable(LuaDatetime.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
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

    const allocator = luau.getallocator(L);

    const ptr = L.newuserdatadtor(Time, LuaDatetime.__dtor);
    const datetime = try time.Datetime.fromFields(.{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .nanosecond = @intCast(millisecond * std.time.ns_per_ms),
    });
    ptr.* = try Time.fromTime(allocator, datetime, null);
    if (L.Lgetmetatable(LuaDatetime.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
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

    const ptr = L.newuserdatadtor(Time, LuaDatetime.__dtor);
    const local = try time.Timezone.tzLocal(allocator);
    const datetime = try time.Datetime.fromFields(.{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .nanosecond = @intCast(millisecond * std.time.ns_per_ms),
        .tzinfo = local,
    });
    ptr.* = try Time.fromTime(allocator, datetime, local);
    if (L.Lgetmetatable(LuaDatetime.META) == .Table)
        L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_fromIsoDate(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const iso_date = L.Lcheckstring(1);

    const ptr = L.newuserdatadtor(Time, LuaDatetime.__dtor);
    ptr.* = try Time.fromTime(allocator, try time.Datetime.fromISO8601(iso_date), null);
    if (L.Lgetmetatable(LuaDatetime.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_parse(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);
    const date_string = L.Lcheckstring(1);

    const ptr = L.newuserdatadtor(Time, LuaDatetime.__dtor);
    ptr.* = try parse.parse(allocator, date_string);
    if (L.Lgetmetatable(LuaDatetime.META) == .Table)
        _ = L.setmetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Lnewmetatable(LuaDatetime.META);

        L.Zsetfieldc(-1, luau.Metamethods.index, LuaDatetime.__index); // metatable.__index
        L.Zsetfieldc(-1, luau.Metamethods.namecall, LuaDatetime.__namecall); // metatable.__namecall

        L.Zsetfieldc(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    L.newtable();

    L.Zsetfieldc(-1, "now", datetime_now);
    L.Zsetfieldc(-1, "parse", datetime_parse);
    L.Zsetfieldc(-1, "fromIsoDate", datetime_fromIsoDate);
    L.Zsetfieldc(-1, "fromUniversalTime", datetime_fromUniversalTime);
    L.Zsetfieldc(-1, "fromLocalTime", datetime_fromUniversalTime);
    L.Zsetfieldc(-1, "fromUnixTimestamp", datetime_fromUnixTimestamp);
    L.Zsetfieldc(-1, "fromUnixTimestampMillis", datetime_fromUnixTimestampMillis);

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test {
    _ = parse;
}

test "Datetime" {
    const TestRunner = @import("../../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"datetime.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
