//! Shared calendar operations for the DATE/DATETIME/TIME/TIMESTAMP families
//! (go-zetasqlite function_date.go DATE_ADD/DATE_SUB/DATE_DIFF/DATE_TRUNC +
//! addMonth/addYear/diffDay, and function.go EXTRACT). Everything works on the
//! civil-micros BrokenTime; callers repackage the result as the right kind.

const std = @import("std");
const tu = @import("time_util.zig");
const bind = @import("bind.zig");
const value_mod = @import("../value.zig");

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

// ----------------------------------------------------------------------
// DATE_BUCKET / DATETIME_BUCKET / TIMESTAMP_BUCKET.
//
// All three answer the same question — which fixed-width bucket, counted from
// an origin, does this instant fall in — and differ only in the width parts
// they accept and how the caller repackages the result. So the arithmetic is
// here once, and the three handlers are wrappers.
// ----------------------------------------------------------------------

/// The default origin: 1950-01-01, midnight, and UTC for TIMESTAMP. Not the
/// epoch, which is the surprise worth stating.
pub fn defaultBucketOrigin() BrokenTime {
    return .{ .civ = tu.compose(1950, 1, 1, 0, 0, 0, 0) };
}

pub const BucketKind = enum {
    date,
    datetime,
    timestamp,

    /// googlesql names the function in every bucket-width diagnostic.
    fn fnName(self: BucketKind) []const u8 {
        return switch (self) {
            .date => "DATE_BUCKET",
            .datetime => "DATETIME_BUCKET",
            .timestamp => "TIMESTAMP_BUCKET",
        };
    }
};

/// A bucket width reduced to the three units googlesql validates on — the same
/// three `fn_interval.zig` bounds. Reducing first is what makes the checks
/// independent of how the literal was spelled: `INTERVAL 1 YEAR` is 12 months
/// and `INTERVAL 90 MINUTE` is 5.4e9 micros.
const Width = struct {
    months: i64,
    days: i64,
    micros: i64,

    fn of(iv: value_mod.Interval) Width {
        return .{
            .months = @as(i64, iv.years) * 12 + iv.months,
            .days = iv.days,
            .micros = @as(i64, iv.hours) * 3_600_000_000 +
                @as(i64, iv.minutes) * 60_000_000 +
                @as(i64, iv.seconds) * 1_000_000 +
                @divTrunc(iv.sub_second_nanos, 1000),
        };
    }

    fn nonZeroParts(self: Width) u8 {
        return @as(u8, @intFromBool(self.months != 0)) +
            @intFromBool(self.days != 0) +
            @intFromBool(self.micros != 0);
    }
};

fn bucketFail(kind: BucketKind, comptime what: []const u8) Error {
    return bind.fail(
        what ++ "; error in {s} expression",
        .{kind.fnName()},
        error.UnsupportedOperation,
    );
}

/// googlesql's own rules, each checked against real BigQuery. The order matters
/// only where a width breaks more than one rule at once, and there BigQuery's
/// choice is not reproduced exactly — every such width is refused either way,
/// just not always with the same sentence.
fn validate(kind: BucketKind, w: Width) Error!void {
    switch (kind) {
        // A part the type has no meaning for outranks the count, so a DATE
        // width of `INTERVAL '1 2:0:0' DAY TO SECOND` is reported as the
        // sub-day part rather than as two parts.
        .date => if (w.micros != 0) {
            return bucketFail(kind, "Only MONTH and DAY parts are allowed in bucket width INTERVAL");
        },
        .timestamp => {
            if (w.months != 0) {
                return bucketFail(kind, "Bucket width INTERVAL with non-zero MONTH part is not allowed");
            }
            if (w.days != 0 and w.micros != 0) {
                return bucketFail(kind, "Bucket width INTERVAL with mixed DAY and subsecond parts is not allowed");
            }
        },
        // DATETIME accepts every part, so the count is the only structural
        // rule, and it is what BigQuery reports for a mixed width here.
        .datetime => {},
    }
    if (w.nonZeroParts() != 1) {
        return bucketFail(kind, "Exactly one non-zero INTERVAL part in bucket width is required");
    }
    if (w.months < 0 or w.days < 0 or w.micros < 0) {
        return bucketFail(kind, "Negative bucket width INTERVAL is not allowed");
    }
}

/// The start of the bucket holding `v`, counting from `origin` in steps of
/// `width`.
pub fn bucket(
    kind: BucketKind,
    v: BrokenTime,
    width: value_mod.Interval,
    origin: BrokenTime,
) Error!BrokenTime {
    const w = Width.of(width);
    try validate(kind, w);

    if (w.months != 0) {
        // Months are not a duration, so this counts in months and then asks
        // the calendar. The month index ignores day and time, which can put it
        // one bucket high — never low, since a later day only moves the answer
        // forward — so one step back is exact.
        const c = v.parts();
        const oc = origin.parts();
        const m = (c.year - oc.year) * 12 + (c.month - oc.month);
        const n = @divFloor(m, w.months) * w.months;
        const candidate = addMonth(origin, n);
        if (candidate.civ > v.civ) return addMonth(origin, n - w.months);
        return candidate;
    }

    // Days and sub-day widths are both uniform, so both are one floor-divide in
    // civil micros — a DATE is midnight-aligned, which keeps day widths exact.
    //
    // @divFloor, never @divTrunc: that difference *is* the behaviour before the
    // origin, where truncation would round toward it and land a bucket late.
    const step = if (w.days != 0) w.days * tu.day_micros else w.micros;
    const n = @divFloor(v.civ - origin.civ, step);
    return .{ .civ = origin.civ + n * step };
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

/// Named rather than anonymous so helpers can hand it back to each other —
/// two anonymous structs with the same fields are still two types.
const Ymd = struct { y: i64, m: i64, d: i64 };

fn ymd(bt: BrokenTime) Ymd {
    const c = bt.parts();
    return .{ .y = c.year, .m = c.month, .d = c.day };
}

// ---- bucketing ----

fn dayWidth(n: i32) value_mod.Interval {
    return .{ .days = n };
}

/// `bucket` over DATEs, as y/m/d.
fn dateBucketAt(
    y: i64,
    m: i64,
    d: i64,
    width: value_mod.Interval,
    origin: BrokenTime,
) !Ymd {
    return ymd(try bucket(.date, at(y, m, d), width, origin));
}

test "bucketing floors toward -infinity, so it holds before the origin" {
    // The whole reason this is @divFloor and not @divTrunc. Truncation rounds
    // toward the origin, which lands a bucket late on everything before it:
    // 1949-12-29 would come back 1949-12-30. Values from BigQuery.
    const origin = defaultBucketOrigin();
    const cases = [_][6]i64{
        // in            expected
        .{ 1949, 12, 29, 1949, 12, 28 },
        .{ 1949, 12, 31, 1949, 12, 30 },
        .{ 1950, 1, 1, 1950, 1, 1 },
        .{ 1950, 1, 3, 1950, 1, 3 },
    };
    for (cases) |c| {
        const got = try dateBucketAt(c[0], c[1], c[2], dayWidth(2), origin);
        try testing.expectEqual(c[3], got.y);
        try testing.expectEqual(c[4], got.m);
        try testing.expectEqual(c[5], got.d);
    }
}

test "a month width lands on the origin's day of month, clamped short" {
    // The origin is the 31st, so every bucket starts on its month's last day
    // when the month is shorter — the same clamp DATE_ADD uses, which is why
    // addMonth does this rather than a second implementation.
    const origin = at(2000, 1, 31);
    const month = value_mod.Interval{ .months = 1 };
    const cases = [_][6]i64{
        .{ 2024, 3, 14, 2024, 2, 29 }, // February, leap
        .{ 2024, 2, 29, 2024, 2, 29 }, // exactly on a bucket start
        .{ 1900, 3, 14, 1900, 2, 28 }, // 1900 is not a leap year
    };
    for (cases) |c| {
        const got = try dateBucketAt(c[0], c[1], c[2], month, origin);
        try testing.expectEqual(c[3], got.y);
        try testing.expectEqual(c[4], got.m);
        try testing.expectEqual(c[5], got.d);
    }

    // With a mid-month origin the bucket turns over on that day, not on the
    // 1st — so the 14th still belongs to the bucket that opened last month.
    const mid = at(2000, 1, 15);
    const before = try dateBucketAt(2024, 3, 14, month, mid);
    try testing.expectEqual(@as(i64, 2), before.m);
    try testing.expectEqual(@as(i64, 15), before.d);
    const after = try dateBucketAt(2024, 3, 16, month, mid);
    try testing.expectEqual(@as(i64, 3), after.m);
    try testing.expectEqual(@as(i64, 15), after.d);
}

test "a multi-month width counts from the origin, not from January" {
    // 1950-01 to 2024-03 is 890 months, and 890 is divisible by 5.
    const got = try dateBucketAt(2024, 3, 14, .{ .months = 5 }, defaultBucketOrigin());
    try testing.expectEqual(@as(i64, 2024), got.y);
    try testing.expectEqual(@as(i64, 3), got.m);
    try testing.expectEqual(@as(i64, 1), got.d);
}

test "sub-day widths keep the origin's time of day" {
    // Origin 06:07 with 90-minute buckets: 07:35 belongs to the one that
    // opened at 06:07, not to an aligned 07:30.
    const origin = BrokenTime{ .civ = tu.compose(2000, 1, 15, 6, 7, 0, 0) };
    const got = try bucket(
        .timestamp,
        .{ .civ = tu.compose(2024, 3, 14, 7, 35, 0, 0) },
        .{ .minutes = 90 },
        origin,
    );
    const c = got.parts();
    try testing.expectEqual(@as(i64, 6), c.hour);
    try testing.expectEqual(@as(i64, 7), c.minute);
    try testing.expectEqual(@as(i64, 14), c.day);
}

test "each type refuses the widths BigQuery refuses, in its own words" {
    const v = at(2024, 3, 14);
    const o = defaultBucketOrigin();
    const hour = value_mod.Interval{ .hours = 1 };
    const month = value_mod.Interval{ .months = 1 };
    const mixed = value_mod.Interval{ .days = 1, .hours = 2 };

    const cases = [_]struct { kind: BucketKind, w: value_mod.Interval, msg: []const u8 }{
        .{ .kind = .date, .w = hour, .msg = "Only MONTH and DAY parts are allowed" },
        .{ .kind = .date, .w = dayWidth(0), .msg = "Exactly one non-zero INTERVAL part" },
        .{ .kind = .date, .w = dayWidth(-2), .msg = "Negative bucket width INTERVAL is not allowed" },
        .{ .kind = .timestamp, .w = month, .msg = "non-zero MONTH part is not allowed" },
        .{ .kind = .timestamp, .w = mixed, .msg = "mixed DAY and subsecond parts" },
        // The same mixed width reads differently for DATETIME, which takes
        // every part and so has only the count to complain about. BigQuery
        // makes the same distinction.
        .{ .kind = .datetime, .w = mixed, .msg = "Exactly one non-zero INTERVAL part" },
    };
    for (cases) |c| {
        bind.clearDiagnostics();
        try testing.expectError(error.UnsupportedOperation, bucket(c.kind, v, c.w, o));
        try testing.expect(std.mem.indexOf(u8, bind.message.?, c.msg) != null);
        // Every one names the function it came from.
        try testing.expect(std.mem.indexOf(u8, bind.message.?, c.kind.fnName()) != null);
    }
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
