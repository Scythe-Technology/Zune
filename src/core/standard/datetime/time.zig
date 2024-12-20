const std = @import("std");
const time = @import("datetime");

const Datetime = time.Datetime;

const Self = @This();

allocator: std.mem.Allocator,
datatime: *time.Datetime,
timezone: ?*time.Timezone,

pub fn deinit(self: *Self) void {
    if (self.timezone) |tz| {
        tz.deinit();
        self.allocator.destroy(tz);
    }
    self.allocator.destroy(self.datatime);
}

pub fn fromTime(allocator: std.mem.Allocator, date: time.Datetime, tz: ?time.Timezone) !Self {
    const datetime_ptr = blk: {
        const ptr = try allocator.create(time.Datetime);
        ptr.* = date;
        break :blk ptr;
    };
    errdefer allocator.destroy(datetime_ptr);
    const tz_ptr = blk: {
        if (tz) |timezone| {
            const ptr = try allocator.create(time.Timezone);
            ptr.* = timezone;
            break :blk ptr;
        }
        break :blk null;
    };
    return Self{
        .allocator = allocator,
        .datatime = datetime_ptr,
        .timezone = tz_ptr,
    };
}
