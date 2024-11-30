const std = @import("std");
const luau = @import("luau");
const time = @import("datetime");

const parse = @import("parse.zig");

const luaHelper = @import("../../utils/luahelper.zig");

const Luau = luau.Luau;

const Datetime = time.Datetime;

pub const LIB_NAME = "datetime";

const LuaDatetime = struct {
    pub const META = "datetime_instance";

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const datetime_ptr = L.toUserdata(Datetime, 1) catch unreachable;

        const namecall = L.nameCallAtom() catch return 0;

        const allocator = L.allocator();

        if (std.mem.eql(u8, namecall, "toIsoDate") or std.mem.eql(u8, namecall, "ToIsoDate")) {
            const utc = if (datetime_ptr.isAware())
                try datetime_ptr.tzLocalize(null)
            else
                datetime_ptr.*;

            try L.pushFmtString("{}Z", .{utc});

            return 1;
        } else if (std.mem.eql(u8, namecall, "toLocalTime") or std.mem.eql(u8, namecall, "ToLocalTime")) {
            var tz = try time.Timezone.tzLocal(allocator);
            defer tz.deinit();
            const date = if (datetime_ptr.isNaive())
                try datetime_ptr.tzLocalize(time.Timezone.UTC)
            else
                datetime_ptr.*;
            const local = try date.tzConvert(tz);
            L.newTable();

            L.setFieldInteger(-1, "year", @intCast(local.year));
            L.setFieldInteger(-1, "month", @intCast(local.month));
            L.setFieldInteger(-1, "day", @intCast(local.day));
            L.setFieldInteger(-1, "hour", @intCast(local.hour));
            L.setFieldInteger(-1, "minute", @intCast(local.minute));
            L.setFieldInteger(-1, "second", @intCast(local.second));
            L.setFieldInteger(-1, "millisecond", @intCast(@divFloor(local.nanosecond, std.time.ns_per_ms)));

            return 1;
        } else if (std.mem.eql(u8, namecall, "toUniversalTime") or std.mem.eql(u8, namecall, "ToUniversalTime")) {
            const utc = if (datetime_ptr.isAware())
                try datetime_ptr.tzConvert(time.Timezone.UTC)
            else
                try datetime_ptr.tzLocalize(time.Timezone.UTC);
            L.newTable();

            L.setFieldInteger(-1, "year", @intCast(utc.year));
            L.setFieldInteger(-1, "month", @intCast(utc.month));
            L.setFieldInteger(-1, "day", @intCast(utc.day));
            L.setFieldInteger(-1, "hour", @intCast(utc.hour));
            L.setFieldInteger(-1, "minute", @intCast(utc.minute));
            L.setFieldInteger(-1, "second", @intCast(utc.second));
            L.setFieldInteger(-1, "millisecond", @intCast(@divFloor(utc.nanosecond, std.time.ns_per_ms)));

            return 1;
        } else if (std.mem.eql(u8, namecall, "formatLocalTime") or std.mem.eql(u8, namecall, "FormatLocalTime")) {
            const format_str = L.checkString(2);
            var tz = try time.Timezone.tzLocal(allocator);
            defer tz.deinit();
            const date = if (datetime_ptr.isNaive())
                try datetime_ptr.tzLocalize(time.Timezone.UTC)
            else
                datetime_ptr.*;
            const local = try date.tzConvert(tz);

            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();

            try time.formatToString(buf.writer(), format_str, local);

            L.pushLString(buf.items);

            return 1;
        } else if (std.mem.eql(u8, namecall, "formatUniversalTime") or std.mem.eql(u8, namecall, "FormatUniversalTime")) {
            const format_str = L.checkString(2);
            const utc = if (datetime_ptr.isAware())
                try datetime_ptr.tzConvert(time.Timezone.UTC)
            else
                try datetime_ptr.tzLocalize(time.Timezone.UTC);

            var buf = std.ArrayList(u8).init(allocator);
            defer buf.deinit();

            try time.formatToString(buf.writer(), format_str, utc);

            L.pushLString(buf.items);

            return 1;
        } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn __index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const datetime_ptr = L.toUserdata(Datetime, 1) catch unreachable;

        const index = L.checkString(2);

        if (std.mem.eql(u8, index, "unixTimestamp") or std.mem.eql(u8, index, "UnixTimestamp")) {
            L.pushNumber(@floatFromInt(datetime_ptr.toUnix(.second)));
            return 1;
        } else if (std.mem.eql(u8, index, "unixTimestampMillis") or std.mem.eql(u8, index, "UnixTimestampMillis")) {
            L.pushNumber(@floatFromInt(datetime_ptr.toUnix(.millisecond)));
            return 1;
        }
        return 0;
    }

    pub fn __dtor(datetime_ptr: *Datetime) void {
        if (datetime_ptr.tzinfo) |*tz|
            tz.deinit();
    }
};

fn datetime_now(L: *Luau) !i32 {
    const datetime_ptr = L.newUserdata(Datetime);
    datetime_ptr.* = Datetime.now(null);
    if (L.getMetatableRegistry(LuaDatetime.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_fromUnixTimestamp(L: *Luau) !i32 {
    const timestamp = L.checkNumber(1);
    const datetime_ptr = L.newUserdata(Datetime);
    datetime_ptr.* = try Datetime.fromUnix(@intFromFloat(timestamp), .second, null);
    if (L.getMetatableRegistry(LuaDatetime.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_fromUnixTimestampMillis(L: *Luau) !i32 {
    const timestamp = L.checkNumber(1);
    const datetime_ptr = L.newUserdata(Datetime);
    datetime_ptr.* = try Datetime.fromUnix(@intFromFloat(timestamp), .millisecond, null);
    if (L.getMetatableRegistry(LuaDatetime.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_fromUniversalTime(L: *Luau) !i32 {
    const year = L.optInteger(1) orelse 1970;
    const month = L.optInteger(2) orelse 1;
    const day = L.optInteger(3) orelse 1;
    const hour = L.optInteger(4) orelse 0;
    const minute = L.optInteger(5) orelse 0;
    const second = L.optInteger(6) orelse 0;
    const millisecond = L.optInteger(7) orelse 0;

    const datetime_ptr = L.newUserdata(Datetime);
    datetime_ptr.* = try Datetime.fromFields(.{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .nanosecond = @intCast(millisecond * std.time.ns_per_ms),
    });
    if (L.getMetatableRegistry(LuaDatetime.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_fromLocalTime(L: *Luau) !i32 {
    const year = L.optInteger(1) orelse 1970;
    const month = L.optInteger(2) orelse 1;
    const day = L.optInteger(3) orelse 1;
    const hour = L.optInteger(4) orelse 0;
    const minute = L.optInteger(5) orelse 0;
    const second = L.optInteger(6) orelse 0;
    const millisecond = L.optInteger(7) orelse 0;

    const allocator = L.allocator();

    const datetime_ptr = L.newUserdataDtor(Datetime, LuaDatetime.__dtor);
    datetime_ptr.* = try Datetime.fromFields(.{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .nanosecond = @intCast(millisecond * std.time.ns_per_ms),
        .tzinfo = try time.Timezone.tzLocal(allocator),
    });
    if (L.getMetatableRegistry(LuaDatetime.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_fromIsoDate(L: *Luau) !i32 {
    const iso_date = L.checkString(1);

    const datetime_ptr = L.newUserdataDtor(Datetime, LuaDatetime.__dtor);
    datetime_ptr.* = try time.parseISO8601(iso_date);
    if (L.getMetatableRegistry(LuaDatetime.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

fn datetime_parse(L: *Luau) !i32 {
    const allocator = L.allocator();
    const date_string = L.checkString(1);

    const datetime_ptr = L.newUserdataDtor(Datetime, LuaDatetime.__dtor);
    datetime_ptr.* = try parse.parse(allocator, date_string);
    if (L.getMetatableRegistry(LuaDatetime.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (Datetime Metatable not initialized)", .{});
    return 1;
}

pub fn loadLib(L: *Luau) void {
    {
        L.newMetatable(LuaDatetime.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, LuaDatetime.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaDatetime.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    L.newTable();

    L.setFieldFn(-1, "now", datetime_now);
    L.setFieldFn(-1, "parse", datetime_parse);
    L.setFieldFn(-1, "fromIsoDate", datetime_fromIsoDate);
    L.setFieldFn(-1, "fromUniversalTime", datetime_fromUniversalTime);
    L.setFieldFn(-1, "fromLocalTime", datetime_fromUniversalTime);
    L.setFieldFn(-1, "fromUnixTimestamp", datetime_fromUnixTimestamp);
    L.setFieldFn(-1, "fromUnixTimestampMillis", datetime_fromUnixTimestampMillis);

    L.setReadOnly(-1, true);
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
