//! Shared calendar operations for the DATE/DATETIME/TIME/TIMESTAMP families
//! (go-zetasqlite function_date.go DATE_ADD/DATE_SUB/DATE_DIFF/DATE_TRUNC +
//! addMonth/addYear/diffDay, and function.go EXTRACT). Everything works on the
//! civil-micros BrokenTime; callers repackage the result as the right kind.

const std = @import("std");
const tu = @import("time_util.zig");
const bind = @import("bind.zig");

const Value = tu.Value;
const Error = tu.Error;
const BrokenTime = tu.BrokenTime;

fn unexpectedPart(part: []const u8) Error {
    return bind.fail("unexpected part value {s}", .{part}, error.UnsupportedOperation);
}

// go-zetasqlite WeekPartToOffset.
fn weekPartOffset(part: []const u8) ?i64 {
    const map = [_]struct { name: []const u8, off: i64 }{
        .{ .name = "WEEK", .off = 0 },
        .{ .name = "WEEK_MONDAY", .off = 1 },
        .{ .name = "WEEK_TUESDAY", .off = 2 },
        .{ .name = "WEEK_WEDNESDAY", .off = 3 },
        .{ .name = "WEEK_THURSDAY", .off = 4 },
        .{ .name = "WEEK_FRIDAY", .off = 5 },
        .{ .name = "WEEK_SATURDAY", .off = 6 },
    };
    for (map) |m| if (std.mem.eql(u8, m.name, part)) return m.off;
    return null;
}

/// Go addMonth: shift by m months, clamping the day of month to the target
/// month's last day when it would overflow.
pub fn addMonth(bt: BrokenTime, m: i64) BrokenTime {
    const c = bt.parts();
    const first_civ = tu.compose(c.year, c.month, 1, c.hour, c.minute, c.second, c.micro);
    const first = tu.BrokenTime{ .civ = first_civ };
    const shifted = first.addDate(0, m, 0).parts(); // year/month of target
    const after = tu.decompose(tu.compose(
        shifted.year,
        shifted.month,
        c.day,
        c.hour,
        c.minute,
        c.second,
        c.micro,
    ));
    if (after.month != shifted.month) {
        return first.addDate(0, m + 1, -1);
    }
    return bt.addDate(0, m, 0);
}

/// Go addYear: same clamp behavior across a year shift (Feb 29 -> Feb 28).
pub fn addYear(bt: BrokenTime, y: i64) BrokenTime {
    const c = bt.parts();
    const first_civ = tu.compose(c.year, c.month, 1, c.hour, c.minute, c.second, c.micro);
    const first = tu.BrokenTime{ .civ = first_civ };
    const shifted = first.addDate(y, 0, 0).parts();
    const after = tu.decompose(tu.compose(
        shifted.year,
        shifted.month,
        c.day,
        c.hour,
        c.minute,
        c.second,
        c.micro,
    ));
    if (after.month != shifted.month) {
        return first.addDate(y, 1, -1);
    }
    return bt.addDate(y, 0, 0);
}

/// DATE_ADD: DAY/WEEK/MONTH/YEAR/QUARTER.
pub fn dateAdd(bt: BrokenTime, v: i64, part: []const u8) Error!BrokenTime {
    if (std.mem.eql(u8, part, "DAY")) return bt.addDate(0, 0, v);
    if (std.mem.eql(u8, part, "WEEK")) return bt.addDate(0, 0, v * 7);
    if (std.mem.eql(u8, part, "MONTH")) return addMonth(bt, v);
    if (std.mem.eql(u8, part, "YEAR")) return addYear(bt, v);
    // Go hardcodes +3 months here, ignoring `v`, so INTERVAL 2 QUARTER silently
    // advanced by one. BigQuery honours the interval:
    // DATE_ADD(DATE '2024-01-15', INTERVAL 2 QUARTER) = 2024-07-15.
    if (std.mem.eql(u8, part, "QUARTER")) return addMonth(bt, v * 3);
    return unexpectedPart(part);
}

/// DATE_SUB: DAY/WEEK/MONTH/YEAR/QUARTER.
pub fn dateSub(bt: BrokenTime, v: i64, part: []const u8) Error!BrokenTime {
    if (std.mem.eql(u8, part, "DAY")) return bt.addDate(0, 0, -v);
    if (std.mem.eql(u8, part, "WEEK")) return bt.addDate(0, 0, -v * 7);
    if (std.mem.eql(u8, part, "MONTH")) return addMonth(bt, -v);
    if (std.mem.eql(u8, part, "YEAR")) return addYear(bt, -v);
    // addMonth already clamps the day of month, which is what BigQuery does:
    // DATE_SUB(DATE '2024-08-31', INTERVAL 1 QUARTER) = 2024-05-31.
    if (std.mem.eql(u8, part, "QUARTER")) return addMonth(bt, -v * 3);
    return unexpectedPart(part);
}

fn diffDay(a: BrokenTime, b: BrokenTime) i64 {
    const diff = a.civ - b.civ; // micros, a >= b
    if (diff < tu.day_micros) {
        if (a.parts().day == b.parts().day) return 0;
        return 1;
    }
    const diff2 = (a.days() * tu.day_micros) - b.civ;
    var dd = @divTrunc(diff2, tu.day_micros);
    if (@rem(diff2, tu.day_micros) > 0) dd += 1;
    return dd;
}

pub fn dateDiff(a: BrokenTime, b: BrokenTime, part: []const u8) Error!i64 {
    const iso_a = a.isoWeek();
    const iso_b = b.isoWeek();

    if (std.mem.startsWith(u8, part, "WEEK")) {
        const boundary = weekPartOffset(part) orelse
            return bind.fail("unsupported week date part: {s}", .{part}, error.UnsupportedOperation);
        var is_negative = false;
        var start = b;
        var end = a;
        if (b.unixSeconds() > a.unixSeconds()) {
            start = a;
            end = b;
            is_negative = true;
        }
        const days = @divTrunc(end.unixSeconds() - start.unixSeconds(), 24 * 60 * 60);
        const full_weeks = @divTrunc(days, 7);
        var remainder = @rem(days, 7);
        var counts = [_]i64{full_weeks} ** 7;
        const starting_day = start.weekday();
        while (remainder > 0) : (remainder -= 1) {
            const idx: usize = @intCast(@mod(starting_day + remainder, 7));
            counts[idx] += 1;
        }
        var result = counts[@intCast(boundary)];
        if (is_negative) result = -result;
        return result;
    }

    if (std.mem.eql(u8, part, "DAY")) {
        if (a.civ > b.civ) return diffDay(a, b);
        return -diffDay(b, a);
    }
    if (std.mem.eql(u8, part, "ISOWEEK"))
        return (a.parts().year - b.parts().year) * 48 + iso_a.week - iso_b.week;
    if (std.mem.eql(u8, part, "MONTH")) {
        const ca = a.parts();
        const cb = b.parts();
        return (ca.year * 12 + ca.month) - (cb.year * 12 + cb.month);
    }
    // Quarter boundaries crossed, signed — the MONTH arm above, bucketed by
    // three. Verified against BigQuery: 2024-04-01 vs 2024-01-01 is 1, the
    // reverse is -1, 2024-03-31 vs 2024-01-01 is 0 (same quarter), and
    // 2025-01-01 vs 2024-02-15 is 4. One arm serves DATE_DIFF, DATETIME_DIFF
    // and TIMESTAMP_DIFF, which all funnel here.
    if (std.mem.eql(u8, part, "QUARTER")) {
        const ca = a.parts();
        const cb = b.parts();
        return @divFloor(ca.year * 12 + ca.month - 1, 3) -
            @divFloor(cb.year * 12 + cb.month - 1, 3);
    }
    if (std.mem.eql(u8, part, "YEAR")) return a.parts().year - b.parts().year;
    if (std.mem.eql(u8, part, "ISOYEAR")) return iso_a.year - iso_b.year;
    return unexpectedPart(part);
}

const quarter_start_months = [_]i64{ 1, 4, 7, 10 };

/// DATE_TRUNC: returns midnight of the truncated civil date.
pub fn dateTrunc(bt: BrokenTime, part: []const u8) Error!BrokenTime {
    const c = bt.parts();
    const iso = bt.isoWeek();

    if (std.mem.startsWith(u8, part, "WEEK")) {
        const start_of_week = weekPartOffset(part) orelse
            return bind.fail("unknown week part: {s}", .{part}, error.UnsupportedOperation);
        var t = bt;
        while (t.weekday() != start_of_week) t = t.addDate(0, 0, -1);
        return midnight(t);
    }
    if (std.mem.eql(u8, part, "DAY")) return midnight(bt);
    if (std.mem.eql(u8, part, "ISOWEEK"))
        return .{ .civ = tu.compose(iso.year, 0, 7 * iso.week, 0, 0, 0, 0) };
    if (std.mem.eql(u8, part, "MONTH"))
        return .{ .civ = tu.compose(c.year, c.month, 1, 0, 0, 0, 0) };
    if (std.mem.eql(u8, part, "QUARTER")) {
        const qm = quarter_start_months[@intCast(@divTrunc(c.month - 1, 3))];
        return .{ .civ = tu.compose(c.year, qm, 1, 0, 0, 0, 0) };
    }
    if (std.mem.eql(u8, part, "YEAR"))
        return .{ .civ = tu.compose(c.year, 1, 1, 0, 0, 0, 0) };
    if (std.mem.eql(u8, part, "ISOYEAR")) {
        const first_day = tu.BrokenTime{ .civ = tu.compose(iso.year, 1, 1, 0, 0, 0, 0) };
        return first_day.addDate(0, 0, 1 - first_day.weekday());
    }
    return unexpectedPart(part);
}

fn midnight(bt: BrokenTime) BrokenTime {
    return .{ .civ = bt.days() * tu.day_micros };
}

/// Go EXTRACT for DATE/DATETIME/TIME/TIMESTAMP (interval handled by caller).
/// `civ` is the (zone-adjusted) civil micros of the source value.
pub fn extractPart(bt: BrokenTime, part: []const u8) Error!Value {
    const c = bt.parts();
    if (std.mem.eql(u8, part, "ISOYEAR")) return .{ .int = bt.isoWeek().year };
    if (std.mem.eql(u8, part, "YEAR")) return .{ .int = c.year };
    if (std.mem.eql(u8, part, "MONTH")) return .{ .int = c.month };
    if (std.mem.eql(u8, part, "ISOWEEK")) return .{ .int = bt.isoWeek().week };
    if (std.mem.eql(u8, part, "WEEK")) {
        const shifted = bt.addDate(0, 0, -bt.weekday());
        return .{ .int = shifted.isoWeek().week };
    }
    if (std.mem.eql(u8, part, "DAY")) return .{ .int = c.day };
    if (std.mem.eql(u8, part, "DAYOFYEAR")) return .{ .int = bt.yearDay() };
    if (std.mem.eql(u8, part, "DAYOFWEEK")) return .{ .int = bt.weekday() + 1 };
    // From the month, not the day of year: the old day-of-year thresholds
    // (91/182/273) cannot hold for both leap and common years, and were wrong
    // on the first day of Q2 and Q3 in a common year (2023-04-01 gave 1,
    // 2023-07-01 gave 2) and on 2024-09-30 (gave 4).
    if (std.mem.eql(u8, part, "QUARTER")) return .{ .int = @divTrunc(c.month - 1, 3) + 1 };
    if (std.mem.eql(u8, part, "HOUR")) return .{ .int = c.hour };
    if (std.mem.eql(u8, part, "MINUTE")) return .{ .int = c.minute };
    if (std.mem.eql(u8, part, "SECOND")) return .{ .int = c.second };
    if (std.mem.eql(u8, part, "MILLISECOND")) return .{ .int = @divTrunc(c.micro, 1000) };
    if (std.mem.eql(u8, part, "MICROSECOND")) return .{ .int = c.micro };
    if (std.mem.eql(u8, part, "DATE")) return tu.dateValue(bt);
    if (std.mem.eql(u8, part, "DATETIME")) return tu.datetimeValue(bt);
    if (std.mem.eql(u8, part, "TIME")) return tu.timeValue(bt);
    return bind.fail("EXTRACT: unexpected part {s} for data/datetime/time/timestamp", .{part}, error.UnsupportedOperation);
}

// ---- tests ----
//
// Every expectation below was taken from real BigQuery
// (recidiviz-bigquery-sandbox), not derived from this implementation — QUARTER
// had three silent bugs precisely because this module had no tests and the
// only coverage was a handful of corpus cases that all used an interval of 1.

const testing = std.testing;

fn at(year: i64, month: i64, day: i64) BrokenTime {
    return .{ .civ = tu.compose(year, month, day, 0, 0, 0, 0) };
}

fn ymd(bt: BrokenTime) struct { y: i64, m: i64, d: i64 } {
    const c = bt.parts();
    return .{ .y = c.year, .m = c.month, .d = c.day };
}

test "DATE_DIFF by QUARTER counts boundaries crossed, signed" {
    try testing.expectEqual(@as(i64, 1), try dateDiff(at(2024, 4, 1), at(2024, 1, 1), "QUARTER"));
    try testing.expectEqual(@as(i64, -1), try dateDiff(at(2024, 1, 1), at(2024, 4, 1), "QUARTER"));
    // Same quarter, 90 days apart: still zero boundaries.
    try testing.expectEqual(@as(i64, 0), try dateDiff(at(2024, 3, 31), at(2024, 1, 1), "QUARTER"));
    try testing.expectEqual(@as(i64, 4), try dateDiff(at(2025, 1, 1), at(2024, 2, 15), "QUARTER"));
}

test "DATE_ADD and DATE_SUB by QUARTER honour the interval" {
    // Go hardcoded +3 months and ignored the interval, so this returned
    // 2024-04-15.
    const added = ymd(try dateAdd(at(2024, 1, 15), 2, "QUARTER"));
    try testing.expectEqual(@as(i64, 2024), added.y);
    try testing.expectEqual(@as(i64, 7), added.m);
    try testing.expectEqual(@as(i64, 15), added.d);

    const subbed = ymd(try dateSub(at(2024, 8, 31), 1, "QUARTER"));
    try testing.expectEqual(@as(i64, 2024), subbed.y);
    try testing.expectEqual(@as(i64, 5), subbed.m);
    try testing.expectEqual(@as(i64, 31), subbed.d);

    // Clamps the day of month when the target quarter is shorter:
    // 2024-05-31 back one quarter lands in February.
    const clamped = ymd(try dateSub(at(2024, 5, 31), 1, "QUARTER"));
    try testing.expectEqual(@as(i64, 2), clamped.m);
    try testing.expectEqual(@as(i64, 29), clamped.d); // 2024 is a leap year
}

test "EXTRACT QUARTER is derived from the month, not the day of year" {
    // The three the old day-of-year thresholds got wrong.
    try testing.expectEqual(@as(i64, 2), (try extractPart(at(2023, 4, 1), "QUARTER")).int);
    try testing.expectEqual(@as(i64, 3), (try extractPart(at(2023, 7, 1), "QUARTER")).int);
    try testing.expectEqual(@as(i64, 3), (try extractPart(at(2024, 9, 30), "QUARTER")).int);
    // And the boundaries either side of every quarter.
    try testing.expectEqual(@as(i64, 1), (try extractPart(at(2024, 1, 1), "QUARTER")).int);
    try testing.expectEqual(@as(i64, 1), (try extractPart(at(2024, 3, 31), "QUARTER")).int);
    try testing.expectEqual(@as(i64, 4), (try extractPart(at(2024, 10, 1), "QUARTER")).int);
    try testing.expectEqual(@as(i64, 4), (try extractPart(at(2024, 12, 31), "QUARTER")).int);
}

test "DATE_TRUNC by QUARTER lands on the quarter start" {
    for ([_][3]i64{
        .{ 2024, 2, 1 }, .{ 2024, 5, 4 }, .{ 2024, 8, 7 }, .{ 2024, 11, 10 },
    }) |c| {
        const got = ymd(try dateTrunc(at(c[0], c[1], 15), "QUARTER"));
        try testing.expectEqual(c[0], got.y);
        try testing.expectEqual(c[2], got.m);
        try testing.expectEqual(@as(i64, 1), got.d);
    }
}
