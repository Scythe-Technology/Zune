const std = @import("std");
const luau = @import("luau");
const time = @import("datetime");

const Time = @import("time.zig");

const Month = enum {
    Jan,
    Feb,
    Mar,
    Apr,
    May,
    Jun,
    Jul,
    Aug,
    Sep,
    Oct,
    Nov,
    Dec,
};

const MonthMap = std.StaticStringMap(Month).initComptime(.{
    .{ "jan", Month.Jan },
    .{ "feb", Month.Feb },
    .{ "mar", Month.Mar },
    .{ "apr", Month.Apr },
    .{ "may", Month.May },
    .{ "jun", Month.Jun },
    .{ "jul", Month.Jul },
    .{ "aug", Month.Aug },
    .{ "sep", Month.Sep },
    .{ "oct", Month.Oct },
    .{ "nov", Month.Nov },
    .{ "dec", Month.Dec },
});

// in the format "<day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT"
// eg, "Wed, 21 Oct 2015 07:28:00 GMT"
pub fn parseModified(allocator: std.mem.Allocator, timestring: []const u8) !Time {
    const value = std.mem.trim(u8, timestring, " ");
    if (value.len < 29)
        return error.InvalidFormat;

    const day = std.fmt.parseInt(u8, value[5..7], 10) catch return error.InvalidFormat;

    const lower_month = try std.ascii.allocLowerString(allocator, value[8..11]);
    defer allocator.free(lower_month);

    const month = @intFromEnum(MonthMap.get(lower_month) orelse return error.InvalidFormat) + 1;
    const year = std.fmt.parseInt(u16, value[12..16], 10) catch return error.InvalidFormat;
    const hour = std.fmt.parseInt(u8, value[17..19], 10) catch return error.InvalidFormat;
    const minute = std.fmt.parseInt(u8, value[20..22], 10) catch return error.InvalidFormat;
    const second = std.fmt.parseInt(u8, value[23..25], 10) catch return error.InvalidFormat;

    const tz = std.mem.trim(u8, value[26..], " ");
    if (tz.len != 3)
        return error.InvalidFormat;

    var tzinfo = try time.Timezone.fromTzdata(tz, allocator);
    errdefer tzinfo.deinit();
    const datetime = try time.Datetime.fromFields(.{
        .day = day,
        .month = month,
        .year = year,
        .hour = hour,
        .minute = minute,
        .second = second,
        .tz_options = .{
            .tz = &tzinfo,
        },
    });
    return Time.fromTime(allocator, datetime, tzinfo);
}

// in the format "<day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT"
// eg, "21 Oct 2015 07:28:00 GMT"
pub fn parseModifiedShort(allocator: std.mem.Allocator, timestring: []const u8) !Time {
    const value = std.mem.trim(u8, timestring, " ");
    if (value.len < 24)
        return error.InvalidFormat;

    const day = std.fmt.parseInt(u8, value[0..2], 10) catch return error.InvalidFormat;

    const lower_month = try std.ascii.allocLowerString(allocator, value[3..6]);
    defer allocator.free(lower_month);

    const month = @intFromEnum(MonthMap.get(lower_month) orelse return error.InvalidFormat) + 1;
    const year = std.fmt.parseInt(u16, value[7..11], 10) catch return error.InvalidFormat;
    const hour = std.fmt.parseInt(u8, value[12..14], 10) catch return error.InvalidFormat;
    const minute = std.fmt.parseInt(u8, value[15..17], 10) catch return error.InvalidFormat;
    const second = std.fmt.parseInt(u8, value[18..20], 10) catch return error.InvalidFormat;

    const tz = std.mem.trim(u8, value[21..], " ");
    if (tz.len != 3)
        return error.InvalidFormat;

    var tzinfo = try time.Timezone.fromTzdata(tz, allocator);
    errdefer tzinfo.deinit();
    const datetime = try time.Datetime.fromFields(.{
        .day = day,
        .month = month,
        .year = year,
        .hour = hour,
        .minute = minute,
        .second = second,
        .tz_options = .{
            .tz = &tzinfo,
        },
    });
    return Time.fromTime(allocator, datetime, tzinfo);
}

pub fn parse(allocator: std.mem.Allocator, str: []const u8) !Time {
    const trimmed = std.mem.trimLeft(u8, std.mem.trimRight(u8, str, " "), " ");
    if (std.mem.indexOfScalar(u8, trimmed, '-') == null) {
        if (str.len < 29)
            return parseModifiedShort(allocator, trimmed);
        return parseModified(allocator, trimmed);
    } else {
        const datetime = try time.Datetime.fromISO8601(trimmed);
        return Time.fromTime(allocator, datetime, if (datetime.tz) |tz| tz.* else null);
    }
}

const testing = std.testing;
test "Timeparse" {
    {
        var result = try parse(testing.allocator, "Wed, 21 Oct 2015 07:28:00 GMT");
        defer result.deinit();
        const datetime = result.datatime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("GMT", result.timezone.?.name());
    }
    {
        var result = try parse(testing.allocator, "Wed, 21 Oct 2015 07:28:00 UTC");
        defer result.deinit();
        const datetime = result.datatime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("UTC", result.timezone.?.name());
    }
    {
        try testing.expectError(error.DayOutOfRange, parse(testing.allocator, "Wed, 33 Oct 2015 07:28:00 GMT"));
        try testing.expectError(error.InvalidFormat, parse(testing.allocator, "Wed, 21 Abc 2015 07:28:00 GMT"));
    }

    {
        var result = try parse(testing.allocator, "21 Oct 2015 07:28:00 GMT");
        defer result.deinit();
        const datetime = result.datatime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("GMT", result.timezone.?.name());
    }
    {
        var result = try parse(testing.allocator, "21 Oct 2015 07:28:00 UTC");
        defer result.deinit();
        const datetime = result.datatime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("UTC", result.timezone.?.name());
    }

    {
        try testing.expectError(error.DayOutOfRange, parse(testing.allocator, "33 Oct 2015 07:28:00 GMT"));
        try testing.expectError(error.InvalidFormat, parse(testing.allocator, "21 Abc 2015 07:28:00 GMT"));
    }

    {
        var result = try parse(testing.allocator, "2015-10-21T07:28:00Z");
        defer result.deinit();
        const datetime = result.datatime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone != null);
        try testing.expect(datetime.tz != null);
        try testing.expectEqualStrings("UTC", result.timezone.?.name());
    }
    {
        var result = try parse(testing.allocator, "2015-10-21T07:28:00");
        defer result.deinit();
        const datetime = result.datatime;
        try testing.expectEqual(2015, datetime.year);
        try testing.expectEqual(10, datetime.month);
        try testing.expectEqual(21, datetime.day);
        try testing.expectEqual(7, datetime.hour);
        try testing.expectEqual(28, datetime.minute);
        try testing.expectEqual(0, datetime.second);
        try testing.expect(result.timezone == null);
        try testing.expect(datetime.tz == null);
    }
    {
        try testing.expectError(error.InvalidFormat, parse(testing.allocator, "2015-10-21T07:28:00B"));
        try testing.expectError(error.InvalidFormat, parse(testing.allocator, "2015-10-21T"));
    }
}
