const std = @import("std");
const testing = std.testing;
const mod = @import("ctdiv.zig").mod;

/// The type that holds the current year, i.e. 2016
pub const Year = u16;

pub const epoch_year = 1970;
pub const secs_per_day: u17 = 24 * 60 * 60;

pub fn isLeapYear(year: Year) bool {
    if (mod(year, 4) != 0)
        return false;
    if (mod(year, 100) != 0)
        return true;
    return (0 == mod(year, 400));
}

test "isLeapYear" {
    try testing.expectEqual(false, isLeapYear(2095));
    try testing.expectEqual(true, isLeapYear(2096));
    try testing.expectEqual(false, isLeapYear(2100));
    try testing.expectEqual( true, isLeapYear(2400));
}

pub fn getDaysInYear(year: Year) u9 {
    return if (isLeapYear(year)) 366 else 365;
}

pub const YearLeapKind = enum(u1) {not_leap, leap};

/// Get the number of days in the given month
pub fn getDaysInMonthIndex(leap_year: YearLeapKind, month_index: u4) u5 {
    std.debug.assert(month_index <= 11);
    const table = [2][12]u2 {
        [12]u2 { 3, 0, 3, 2, 3, 2, 3, 3, 2, 3, 2, 3},
        [12]u2 { 3, 1, 3, 2, 3, 2, 3, 3, 2, 3, 2, 3},
    };
    return 28 + @intCast(u5, table[@enumToInt(leap_year)][month_index]);
}

pub const YearAndDay = struct {
    year: Year,
    /// The number of days into the year (0 to 365)
    day: u9,

    pub fn calculateMonthDay(self: YearAndDay) MonthAndDay {
        var month_index: u4 = 0;
        var days_left = self.day;
        const is_leap_year: YearLeapKind = if (isLeapYear(self.year)) .leap else .not_leap;
        while (true) {
            const days_in_month = getDaysInMonthIndex(is_leap_year, month_index);
            if (days_left <= days_in_month)
                break;
            days_left -= days_in_month;
            month_index += 1;
        }
        return .{ .month_index = month_index, .day_index = @intCast(u5, days_left) };
    }
};

pub const MonthAndDay = struct {
    month_index: u4, /// months into the year (0 to 11)
    day_index: u5, // days into the month (0 to 30)
};

// days since epoch Oct 1, 1970
pub const EpochDay = struct {
    day: u47, // u47 = u64 - u17 (because day = sec(u64) / secs_per_day(u17)
    pub fn calculateYearDay(self: EpochDay) YearAndDay {
        var year_day = self.day;
        var year: Year = epoch_year;
        while (true) {
            const year_size = getDaysInYear(year);
            if (year_day < year_size)
                break;
            year_day -= year_size;
            year += 1;
        }
        return .{ .year = year, .day = @intCast(u8, year_day) };
    }
};

/// seconds since start of day
pub const DaySeconds = struct {
    secs: u17, // max is 24*60*60 = 86400

    /// the number of hours past the start of the day (0 to 11)
    pub fn getHoursIntoDay(self: DaySeconds) u5 {
        return @intCast(u5, @divTrunc(self.secs, 3600));
    }
    /// the number of minutes past the hour (0 to 59)
    pub fn getMinutesIntoHour(self: DaySeconds) u6 {
        return @intCast(u6, @divTrunc(mod(self.secs, 3600), 60));
    }
    /// the number of seconds past the start of the minute (0 to 59)
    pub fn getSecondsIntoMinute(self: DaySeconds) u6 {
        return mod(self.secs, 60);
    }
};

/// seconds since epoch Oct 1, 1970 at 12:00 AM
pub const EpochSeconds = struct {
    secs: u64,

    /// Returns the number of days since the epoch as an EpochDay.
    /// Use EpochDay to get information about the day of this time.
    pub fn getEpochDay(self: EpochSeconds) EpochDay {
        return EpochDay {.day = @intCast(u47, @divTrunc(self.secs, secs_per_day)) };
    }

    /// Returns the number of seconds into the day as DaySeconds.
    /// Use DaySeconds to get information about the time.
    pub fn getDaySeconds(self: EpochSeconds) DaySeconds {
        return DaySeconds { .secs = mod(self.secs, secs_per_day) };
    }
};


fn testEpoch(secs: u64, expected_year_day: YearAndDay, expected_month_day: MonthAndDay, expected_day_seconds: struct {
    hours_into_day: u5, /// 0 to 23
    minutes_into_hour: u6, /// 0 to 59
    seconds_into_minute: u6, /// 0 to 59
}) !void {
    const epoch_seconds = EpochSeconds { .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    try testing.expectEqual(expected_year_day, year_day);
    try testing.expectEqual(expected_month_day, year_day.calculateMonthDay());
    try testing.expectEqual(expected_day_seconds.hours_into_day, day_seconds.getHoursIntoDay());
    try testing.expectEqual(expected_day_seconds.minutes_into_hour, day_seconds.getMinutesIntoHour());
    try testing.expectEqual(expected_day_seconds.seconds_into_minute, day_seconds.getSecondsIntoMinute());
}

test {
    try testEpoch(0, .{ .year = 1970, .day = 0 }, .{
        .month_index = 0, .day_index = 0,
    }, .{
        .hours_into_day=0, .minutes_into_hour=0, .seconds_into_minute=0
    });
    try testEpoch(1622924906, .{ .year = 2021, .day = 31+28+31+30+31+4 }, .{
        .month_index = 5, .day_index = 4,
    }, .{
        .hours_into_day=20, .minutes_into_hour=28, .seconds_into_minute=26
    });
}
