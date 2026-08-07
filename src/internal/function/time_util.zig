//! Shared civil-time machinery for the date/time function families. Mirrors
//! the Go time.Time operations go-zetasqlite relies on (time.Date component
//! normalization, AddDate, ISOWeek, Weekday, YearDay) working on "civil
//! micros": microseconds since 1970-01-01T00:00:00 interpreted as a literal
//! wall clock. The engine is UTC-only; zone offsets are applied explicitly by
//! callers (see zoneOffsetSeconds).

const std = @import("std");
const value = @import("../value.zig");

pub const Value = value.Value;
pub const Error = value.ValueError;

pub const day_micros: i64 = value.day_micros;
pub const hour_micros: i64 = value.hour_micros;
pub const minute_micros: i64 = value.minute_micros;
pub const second_micros: i64 = value.second_micros;

pub const Civil = struct {
    year: i64,
    month: i64, // 1-12
    day: i64, // 1-31
    hour: i64,
    minute: i64,
    second: i64,
    micro: i64,
};

const Norm = struct { hi: i64, lo: i64 };

/// Go time.norm: carry lo into hi so lo lands in [0, base).
fn norm(hi: i64, lo: i64, base: i64) Norm {
    var h = hi;
    var l = lo;
    if (l < 0) {
        const n = @divTrunc(-l - 1, base) + 1;
        h -= n;
        l += n * base;
    }
    if (l >= base) {
        const n = @divTrunc(l, base);
        h += n;
        l -= n * base;
    }
    return .{ .hi = h, .lo = l };
}

/// Breaks civil micros into Y/M/D/H/M/S.micro (floor-based, so negatives work).
pub fn decompose(civ: i64) Civil {
    const days = @divFloor(civ, day_micros);
    var rem = civ - days * day_micros; // [0, day_micros)
    const c = value.civilFromDays(days);
    const hour = @divTrunc(rem, hour_micros);
    rem -= hour * hour_micros;
    const minute = @divTrunc(rem, minute_micros);
    rem -= minute * minute_micros;
    const second = @divTrunc(rem, second_micros);
    rem -= second * second_micros;
    return .{
        .year = c.year,
        .month = c.month,
        .day = c.day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .micro = rem,
    };
}

/// Go time.Date: normalizes out-of-range components then returns civil micros.
pub fn compose(
    year_in: i64,
    month_in: i64,
    day_in: i64,
    hour_in: i64,
    minute_in: i64,
    second_in: i64,
    micro_in: i64,
) i64 {
    var year = year_in;
    var month = month_in;
    var day = day_in;
    var hour = hour_in;
    var minute = minute_in;
    var second = second_in;
    var micro = micro_in;

    var r = norm(year, month - 1, 12);
    year = r.hi;
    month = r.lo + 1;

    r = norm(second, micro, 1_000_000);
    second = r.hi;
    micro = r.lo;
    r = norm(minute, second, 60);
    minute = r.hi;
    second = r.lo;
    r = norm(hour, minute, 60);
    hour = r.hi;
    minute = r.lo;
    r = norm(day, hour, 24);
    day = r.hi;
    hour = r.lo;

    const total_days = value.daysFromCivil(year, month, 1) + (day - 1);
    return total_days * day_micros +
        hour * hour_micros +
        minute * minute_micros +
        second * second_micros +
        micro;
}

/// A civil instant plus the operations Go's time.Time offers.
pub const BrokenTime = struct {
    civ: i64,

    pub fn parts(self: BrokenTime) Civil {
        return decompose(self.civ);
    }
    pub fn days(self: BrokenTime) i64 {
        return @divFloor(self.civ, day_micros);
    }
    /// Go Weekday: Sunday=0 .. Saturday=6. 1970-01-01 was a Thursday (4).
    pub fn weekday(self: BrokenTime) i64 {
        return @mod(self.days() + 4, 7);
    }
    /// Go Unix(): floor(micros / 1e6).
    pub fn unixSeconds(self: BrokenTime) i64 {
        return @divFloor(self.civ, second_micros);
    }
    /// Go YearDay: 1-based day within the year.
    pub fn yearDay(self: BrokenTime) i64 {
        const c = decompose(self.civ);
        return self.days() - value.daysFromCivil(c.year, 1, 1) + 1;
    }
    /// Go ISOWeek: ISO-8601 year and week (Thursday rule).
    pub fn isoWeek(self: BrokenTime) struct { year: i64, week: i64 } {
        const d = self.days();
        const wd = @mod(d + 3, 7) + 1; // Mon=1 .. Sun=7
        const thursday = d + (4 - wd);
        const iso_year = value.civilFromDays(thursday).year;
        const jan1 = value.daysFromCivil(iso_year, 1, 1);
        const week = @divFloor(thursday - jan1, 7) + 1;
        return .{ .year = iso_year, .week = week };
    }

    /// The `%U` / `%W` week number: 00-53, counting from the first `first_day`
    /// of the calendar year. Days before that first occurrence are week 00.
    ///
    /// Deliberately not `isoWeek().week`, which is a different quantity — ISO
    /// weeks belong to the ISO year, so 2023-01-01 (a Sunday) is ISO week 52 of
    /// *2022* while `%U` calls it week 01 of 2023 and `%W` calls it week 00.
    /// Conflating the two is what this replaced.
    pub fn weekOfYear(self: BrokenTime, first_day: Weekday) i64 {
        const c = decompose(self.civ);
        const jan1 = value.daysFromCivil(c.year, 1, 1);
        // Days from Jan 1 forward to the year's first `first_day`.
        const jan1_wd = @mod(jan1 + 4, 7); // Sun=0 .. Sat=6
        const lead = @mod(@intFromEnum(first_day) - jan1_wd + 7, 7);
        const day_of_year = self.days() - jan1; // 0-based
        if (day_of_year < lead) return 0;
        return @divFloor(day_of_year - lead, 7) + 1;
    }

    /// The `%Q` quarter, 1-4. From the month, not from `yearDay()`: fixed
    /// day-of-year thresholds put 2024-03-30 in Q2, because a leap year shifts
    /// every boundary after February.
    pub fn quarter(self: BrokenTime) i64 {
        return @divTrunc(decompose(self.civ).month - 1, 3) + 1;
    }

    /// The `%u` (Mon=1..7) and `%w` (Sun=0..6) weekday numbers. `weekday()`
    /// above is Go's Sunday=0 form, which `%w` wants directly.
    pub fn isoWeekday(self: BrokenTime) i64 {
        const wd = self.weekday(); // Sun=0 .. Sat=6
        return if (wd == 0) 7 else wd;
    }

    pub fn addDate(self: BrokenTime, y: i64, mo: i64, d: i64) BrokenTime {
        const c = decompose(self.civ);
        return .{ .civ = compose(
            c.year + y,
            c.month + mo,
            c.day + d,
            c.hour,
            c.minute,
            c.second,
            c.micro,
        ) };
    }
    pub fn add(self: BrokenTime, micros: i64) BrokenTime {
        return .{ .civ = self.civ + micros };
    }
};

/// Which day a week starts on, for `BrokenTime.weekOfYear`. Values match the
/// Sunday=0 numbering `BrokenTime.weekday` returns.
pub const Weekday = enum(i64) { sunday = 0, monday = 1 };

/// The microsecond field truncated to whole milliseconds, for the MILLISECOND
/// arm of TIME_TRUNC / DATETIME_TRUNC / TIMESTAMP_TRUNC. Named because all
/// three had zeroed the field outright, which made MILLISECOND a synonym for
/// SECOND in every one of them.
pub fn truncMillis(micro: i64) i64 {
    return @divTrunc(micro, 1000) * 1000;
}

/// Projects a time-shaped Value onto civil micros for the Go algorithms. DATE
/// lands at midnight; DATETIME/TIMESTAMP use their stored micros (UTC); TIME is
/// anchored at 1970-01-01 (only the time-of-day is observable); strings parse.
pub fn broken(v: Value) Error!BrokenTime {
    return switch (v) {
        .date => |d| .{ .civ = d * day_micros },
        .datetime => |m| .{ .civ = m },
        .time => |m| .{ .civ = m },
        .timestamp => |m| .{ .civ = m },
        .string, .bytes => .{ .civ = try value.toUnixMicros(v) },
        .safe => |p| broken(p.*),
        else => error.FailedConversion,
    };
}

// Result packaging (Go DateValue/DatetimeValue/TimeValue/TimestampValue).

pub fn dateValue(bt: BrokenTime) Value {
    return .{ .date = @divFloor(bt.civ, day_micros) };
}
pub fn datetimeValue(bt: BrokenTime) Value {
    return .{ .datetime = bt.civ };
}
pub fn timeValue(bt: BrokenTime) Value {
    return .{ .time = @mod(bt.civ, day_micros) };
}
/// TIMESTAMP built from a UTC instant (civ == unix micros).
pub fn timestampValue(bt: BrokenTime) Value {
    return .{ .timestamp = bt.civ };
}

// ----------------------------------------------------------------------
// Timezone offset resolution. UTC-only engine: fixed offsets are honored
// exactly; a few named zones the corpus needs are hardcoded with their DST
// rules. Unknown named zones error (caller reports expected-fail).
// ----------------------------------------------------------------------

/// day-of-month of the nth (1-based) given weekday in a month. weekday: 0=Sun.
fn nthWeekday(year: i64, month: i64, wday: i64, n: i64) i64 {
    const first_days = value.daysFromCivil(year, month, 1);
    const first_wd = @mod(first_days + 4, 7); // weekday of the 1st
    const first_match = 1 + @mod(wday - first_wd + 7, 7);
    return first_match + (n - 1) * 7;
}

fn lastWeekday(year: i64, month: i64, wday: i64) i64 {
    const dim = daysInMonth(year, month);
    const last_days = value.daysFromCivil(year, month, dim);
    const last_wd = @mod(last_days + 4, 7);
    return dim - @mod(last_wd - wday + 7, 7);
}

fn daysInMonth(y: i64, m: i64) i64 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if ((@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0) @as(i64, 29) else 28,
        else => 30,
    };
}

/// US Pacific DST: 2nd Sunday of March 02:00 .. 1st Sunday of November 02:00.
fn usPacificIsDst(year: i64, month: i64, day: i64) bool {
    if (month < 3 or month > 11) return false;
    if (month > 3 and month < 11) return true;
    if (month == 3) return day >= nthWeekday(year, 3, 0, 2);
    return day < nthWeekday(year, 11, 0, 1); // November
}

/// NZ Auckland DST: last Sunday of September .. first Sunday of April.
fn nzIsDst(year: i64, month: i64, day: i64) bool {
    if (month > 4 and month < 9) return false; // May-Aug (winter)
    if (month < 4 or month > 9) return true; // Oct-Mar (summer)
    if (month == 4) return day < nthWeekday(year, 4, 0, 1);
    return day >= lastWeekday(year, 9, 0); // September
}

/// Offset (seconds east of UTC) for `zone` at the given civil micros. The civil
/// value is used to pick DST; for corpus instants (never near a transition)
/// this matches Go's zoneinfo lookup regardless of parse/format direction.
pub fn zoneOffsetSeconds(zone: []const u8, civ: i64) Error!i64 {
    if (zone.len == 0) return 0;
    if (std.mem.eql(u8, zone, "UTC") or std.mem.eql(u8, zone, "Z")) return 0;

    // Fixed numeric offset: [+-]HH[:MM].
    if (zone[0] == '+' or zone[0] == '-') {
        const sign: i64 = if (zone[0] == '-') -1 else 1;
        const rest = zone[1..];
        var h: i64 = 0;
        var m: i64 = 0;
        if (rest.len >= 2 and std.ascii.isDigit(rest[0]) and std.ascii.isDigit(rest[1])) {
            h = @as(i64, rest[0] - '0') * 10 + (rest[1] - '0');
            if (rest.len >= 5 and rest[2] == ':') {
                m = @as(i64, rest[3] - '0') * 10 + (rest[4] - '0');
            }
        } else return error.FailedConversion;
        return sign * (h * 3600 + m * 60);
    }

    const c = decompose(civ);
    if (std.mem.eql(u8, zone, "Asia/Tokyo")) return 9 * 3600;
    if (std.mem.eql(u8, zone, "America/Los_Angeles")) {
        return if (usPacificIsDst(c.year, c.month, c.day)) -7 * 3600 else -8 * 3600;
    }
    if (std.mem.eql(u8, zone, "America/New_York")) {
        return if (usPacificIsDst(c.year, c.month, c.day)) -4 * 3600 else -5 * 3600;
    }
    if (std.mem.eql(u8, zone, "Pacific/Auckland")) {
        return if (nzIsDst(c.year, c.month, c.day)) 13 * 3600 else 12 * 3600;
    }
    return error.FailedConversion; // unsupported named zone
}

test "compose/decompose round trip and normalization" {
    // Jan 31 + component overflow (Go time.Date rolls forward).
    const civ = compose(2024, 1, 32, 0, 0, 0, 0); // -> Feb 1
    const c = decompose(civ);
    try std.testing.expectEqual(@as(i64, 2024), c.year);
    try std.testing.expectEqual(@as(i64, 2), c.month);
    try std.testing.expectEqual(@as(i64, 1), c.day);
}

test "weekday, yearDay, isoWeek" {
    const days = value.daysFromCivil(2015, 12, 23);
    const bt = BrokenTime{ .civ = days * day_micros };
    try std.testing.expectEqual(@as(i64, 3), bt.weekday()); // Wednesday
    const iso = bt.isoWeek();
    try std.testing.expectEqual(@as(i64, 2015), iso.year);
    try std.testing.expectEqual(@as(i64, 52), iso.week);
    try std.testing.expectEqual(@as(i64, 357), bt.yearDay());
}

test "zone offsets" {
    try std.testing.expectEqual(@as(i64, 0), try zoneOffsetSeconds("UTC", 0));
    try std.testing.expectEqual(@as(i64, 9 * 3600), try zoneOffsetSeconds("+09:00", 0));
    try std.testing.expectEqual(@as(i64, -7 * 3600), try zoneOffsetSeconds("-07", 0));
    // LA in December (PST) vs August (PDT).
    const dec = compose(2008, 12, 25, 0, 0, 0, 0);
    const aug = compose(2022, 8, 1, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, -8 * 3600), try zoneOffsetSeconds("America/Los_Angeles", dec));
    try std.testing.expectEqual(@as(i64, -7 * 3600), try zoneOffsetSeconds("America/Los_Angeles", aug));
}

test "weekOfYear, quarter and isoWeekday are each their own quantity" {
    // 2023-01-01 is a Sunday belonging to ISO week 52 of 2022 — the one date
    // where all four of these disagree, which is why %U %W %V %u %w sharing
    // isoWeek() went unnoticed. Values from
    // third_party/googlesql/docs/format-elements.md.
    const sun = BrokenTime{ .civ = compose(2023, 1, 1, 0, 0, 0, 0) };
    try std.testing.expectEqual(@as(i64, 1), sun.weekOfYear(.sunday));
    try std.testing.expectEqual(@as(i64, 0), sun.weekOfYear(.monday));
    try std.testing.expectEqual(@as(i64, 52), sun.isoWeek().week);
    try std.testing.expectEqual(@as(i64, 2022), sun.isoWeek().year);
    try std.testing.expectEqual(@as(i64, 7), sun.isoWeekday());
    try std.testing.expectEqual(@as(i64, 0), sun.weekday());

    // 2024-12-30 is a Monday in ISO week 1 of 2025, and 2024 opened on a
    // Monday — so the Monday count reaches 53 while the Sunday count is 52.
    const mon = BrokenTime{ .civ = compose(2024, 12, 30, 0, 0, 0, 0) };
    try std.testing.expectEqual(@as(i64, 52), mon.weekOfYear(.sunday));
    try std.testing.expectEqual(@as(i64, 53), mon.weekOfYear(.monday));
    try std.testing.expectEqual(@as(i64, 1), mon.isoWeek().week);
    try std.testing.expectEqual(@as(i64, 1), mon.isoWeekday());

    // The quarter comes from the month. Taken from the day of the year against
    // fixed thresholds, a leap day pushed 2024-03-30 into Q2.
    const month_quarter = [_][2]i64{
        .{ 1, 1 }, .{ 3, 1 }, .{ 4, 2 },  .{ 6, 2 },
        .{ 7, 3 }, .{ 9, 3 }, .{ 10, 4 }, .{ 12, 4 },
    };
    for (month_quarter) |c| {
        const bt = BrokenTime{ .civ = compose(2024, c[0], 30, 0, 0, 0, 0) };
        try std.testing.expectEqual(c[1], bt.quarter());
    }
}

test "truncMillis keeps whole milliseconds" {
    // The three _TRUNC handlers all zeroed the field outright, which made
    // MILLISECOND a synonym for SECOND in every one of them.
    try std.testing.expectEqual(@as(i64, 123000), truncMillis(123456));
    try std.testing.expectEqual(@as(i64, 123000), truncMillis(123999));
    try std.testing.expectEqual(@as(i64, 0), truncMillis(999));
    try std.testing.expectEqual(@as(i64, 0), truncMillis(0));
}
