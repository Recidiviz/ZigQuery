//! INTERVAL builtins: the `INTERVAL n <part>` constructor, MAKE_INTERVAL, and
//! JUSTIFY_DAYS/JUSTIFY_HOURS/JUSTIFY_INTERVAL. interval_functions.md
//!
//! An interval is three independent counts — months, days and microseconds — and not one
//! duration, because a month has no fixed number of days and a day has no fixed number of hours.
//! Every part a caller names reduces to one of those three: a quarter is three months, a week is
//! seven days, and the sub-day parts are microseconds. The JUSTIFY functions are what move a
//! count from one field into the next, under the 30-day month and 24-hour day that normalization
//! defines.
//!
//! Each field has its own bound, so a constructor saturates rather than wrapping (see
//! value.zig's interval_max_*).

const std = @import("std");
const bind = @import("bind.zig");
const fd = @import("fn_date.zig");
const value_mod = @import("../value.zig");

const Value = bind.Value;
const Error = bind.Error;
const Interval = value_mod.Interval;
const null_v = Value.null;

/// `INTERVAL n <part>`.
///
/// The count is an INT64 and stays one until the end. It used to be
/// `@intCast(...toInt64())` into an i32, which is a *panic* rather than an
/// error on anything past 2^31 — `SELECT INTERVAL 3000000000 SECOND` aborted the
/// process, where BigQuery answers 833333:20:0. Microsecond counts make that
/// size ordinary rather than exotic, so the width had to go before MICROSECOND
/// could be added.
///
/// Each part reduces to one of the three units googlesql bounds — months, days,
/// microseconds — which is also the shape the canonical form takes. That is why
/// ten parts need no field of their own: a quarter is three months, a week is
/// seven days, and milliseconds and microseconds are what the sub-day fields are
/// made of.
///
/// **NANOSECOND is refused on purpose.** It is googlesql behaviour, not BigQuery
/// behaviour: the analyzer resolves `INTERVAL 3 NANOSECOND` here and this used
/// to answer `0-0 0 0:0:0.000000003`, while real BigQuery refuses it with
/// "Invalid interval datetime field NANOSECOND" (bq CLI, 2026-08-04). This
/// engine emulates BigQuery, so accepting it meant a query that passes locally
/// and fails in production — the one failure direction an emulator must not
/// have. Same call as the GoogleSQL-only functions in shim/analyzer_shim.cc,
/// for the same reason. It falls through to the refusal below, which gives
/// BigQuery's own message.
///
/// What is refused is the *part*, not the precision, so only the constructor
/// goes and `Interval.sub_second_nanos` stays: BigQuery reads a nanosecond
/// literal quite happily, and `INTERVAL '0-0 0 0:0:1.123456789' YEAR TO SECOND`
/// round-trips identically on both sides.
pub fn interval(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const n = try args[0].toInt64();
    const part = try fd.partStr(args[1]);

    var months: i64 = 0;
    var days: i64 = 0;
    var micros: i64 = 0;
    // The complete set BigQuery accepts, checked part by part against it: it
    // answers "Invalid interval datetime field X" for everything else, ISOYEAR
    // and DAYOFWEEK and PICOSECOND included. They are EXTRACT parts, not
    // interval ones.
    if (std.mem.eql(u8, part, "YEAR")) {
        months = mulOr(n, 12, value_mod.interval_max_months);
    } else if (std.mem.eql(u8, part, "QUARTER")) {
        months = mulOr(n, 3, value_mod.interval_max_months);
    } else if (std.mem.eql(u8, part, "MONTH")) {
        months = n;
    } else if (std.mem.eql(u8, part, "WEEK")) {
        days = mulOr(n, 7, value_mod.interval_max_days);
    } else if (std.mem.eql(u8, part, "DAY")) {
        days = n;
    } else if (std.mem.eql(u8, part, "HOUR")) {
        micros = mulOr(n, 3600 * 1_000_000, value_mod.interval_max_micros);
    } else if (std.mem.eql(u8, part, "MINUTE")) {
        micros = mulOr(n, 60 * 1_000_000, value_mod.interval_max_micros);
    } else if (std.mem.eql(u8, part, "SECOND")) {
        micros = mulOr(n, 1_000_000, value_mod.interval_max_micros);
    } else if (std.mem.eql(u8, part, "MILLISECOND")) {
        micros = mulOr(n, 1_000, value_mod.interval_max_micros);
    } else if (std.mem.eql(u8, part, "MICROSECOND")) {
        micros = n;
    } else {
        // BigQuery's wording. Nothing depended on the old "unexpected interval
        // part", and the parts that land here — ISOYEAR, DAYOFWEEK,
        // PICOSECOND — are ones it names this way.
        return bind.fail(
            "Invalid interval datetime field {s}; error in INTERVAL expression",
            .{part},
            error.UnsupportedOperation,
        );
    }

    // googlesql bounds the canonical fields, not the literal, and names the
    // field it rejected — so `INTERVAL 10001 YEAR` complains about 120012
    // months rather than about 10001.
    if (@abs(months) > value_mod.interval_max_months)
        return outOfRange("months", months, value_mod.interval_max_months);
    if (@abs(days) > value_mod.interval_max_days)
        return outOfRange("days", days, value_mod.interval_max_days);
    if (@abs(micros) > value_mod.interval_max_micros)
        return outOfRange("microseconds", micros, value_mod.interval_max_micros);

    var iv = value_mod.intervalFromMicros(micros);
    iv.months = @intCast(months);
    iv.days = @intCast(days);
    return Value{ .interval = iv };
}

/// `n * factor`, saturated just past `limit` so the range check below reports it
/// instead of the multiply wrapping into a value that looks legal.
fn mulOr(n: i64, factor: i64, limit: i64) i64 {
    const wide = @mulWithOverflow(n, factor);
    if (wide[1] != 0) return if (n < 0) -(limit + 1) else limit + 1;
    return wide[0];
}

/// googlesql's wording, which names the field and its bounds.
fn outOfRange(field: []const u8, got: i64, limit: i64) Error {
    return bind.fail(
        "Interval field {s} '{d}' is out of range {d} to {d}; error in INTERVAL expression",
        .{ field, got, -limit, limit },
        error.UnsupportedOperation,
    );
}

pub fn makeInterval(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .interval = .{
        .years = @intCast(try args[0].toInt64()),
        .months = @intCast(try args[1].toInt64()),
        .days = @intCast(try args[2].toInt64()),
        .hours = @intCast(try args[3].toInt64()),
        .minutes = @intCast(try args[4].toInt64()),
        .seconds = @intCast(try args[5].toInt64()),
    } };
}

fn asInterval(v: Value) Error!Interval {
    return switch (v) {
        .interval => |iv| iv,
        .safe => |p| asInterval(p.*),
        else => bind.fail("JUSTIFY: unexpected argument type", .{}, error.UnsupportedOperation),
    };
}

fn justifyDays(iv: *Interval) void {
    if (iv.days > 29) {
        iv.months += @divTrunc(iv.days, 30);
        iv.days = @rem(iv.days, 30);
    } else if (iv.days < -29) {
        iv.months += @divTrunc(iv.days, 30);
        iv.days = @rem(iv.days, 30);
    }
    if (iv.months > 11) {
        iv.months -= 12;
        iv.years += 1;
    } else if (iv.months < -11) {
        iv.months += 12;
        iv.years -= 1;
    }
}

fn justifyHours(iv: *Interval) void {
    if (iv.seconds > 59) {
        iv.minutes += @divTrunc(iv.seconds, 60);
        iv.seconds = @rem(iv.seconds, 60);
    } else if (iv.seconds < -59) {
        iv.minutes += @divTrunc(iv.seconds, 60);
        iv.seconds = @rem(iv.seconds, 60);
    }
    if (iv.minutes > 59) {
        iv.hours += @divTrunc(iv.minutes, 60);
        iv.minutes = @rem(iv.minutes, 60);
    } else if (iv.minutes < -59) {
        // Go bug faithfully reproduced: uses Hours/60, not Minutes/60.
        iv.hours += @divTrunc(iv.hours, 60);
        iv.minutes = @rem(iv.minutes, 60);
    }
    if (iv.hours > 23) {
        iv.days += @divTrunc(iv.hours, 24);
        iv.hours = @rem(iv.hours, 24);
    } else if (iv.hours < -23) {
        iv.days += @divTrunc(iv.hours, 24);
        iv.hours = @rem(iv.hours, 24);
    }
}

pub fn justifyDaysFn(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    var iv = try asInterval(args[0]);
    justifyDays(&iv);
    return Value{ .interval = iv };
}

pub fn justifyHoursFn(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    var iv = try asInterval(args[0]);
    justifyHours(&iv);
    return Value{ .interval = iv };
}

pub fn justifyIntervalFn(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    var iv = try asInterval(args[0]);
    justifyHours(&iv);
    justifyDays(&iv);
    return Value{ .interval = iv };
}

// ----------------------------------------------------------------------
// Tests. Every expected string is what real BigQuery returns for the same
// `SELECT CAST(INTERVAL n <part> AS STRING)`.
// ----------------------------------------------------------------------

const testing = std.testing;

/// `INTERVAL n <part>` rendered canonically, the way BigQuery prints it.
fn canonical(buf: []u8, n: i64, part: []const u8) ![]const u8 {
    const v = try interval(testing.allocator, &.{
        .{ .int = n },
        .{ .string = part },
    });
    return value_mod.formatInterval(buf, v.interval);
}

test "INTERVAL WEEK and MICROSECOND reduce to days and to the sub-day fields" {
    var buf: [96]u8 = undefined;
    // Neither part needs a field of its own: a week is seven days, and
    // microseconds are what the sub-day fields are made of.
    try testing.expectEqualStrings("0-0 7 0:0:0", try canonical(&buf, 1, "WEEK"));
    try testing.expectEqualStrings("0-0 21 0:0:0", try canonical(&buf, 3, "WEEK"));
    try testing.expectEqualStrings("0-0 -7 0:0:0", try canonical(&buf, -1, "WEEK"));
    try testing.expectEqualStrings("0-0 0 0:0:0.005", try canonical(&buf, 5_000, "MICROSECOND"));
    try testing.expectEqualStrings("0-0 0 0:0:5", try canonical(&buf, 5_000_000, "MICROSECOND"));
    try testing.expectEqualStrings("0-0 0 0:0:0", try canonical(&buf, 0, "MICROSECOND"));
}

test "INTERVAL QUARTER and MILLISECOND reduce to months and microseconds" {
    var buf: [96]u8 = undefined;
    // A quarter is three months and a millisecond is a thousand microseconds,
    // so neither needs a field either — and both canonicalize onward, 5
    // quarters becoming a year and three months.
    try testing.expectEqualStrings("0-9 0 0:0:0", try canonical(&buf, 3, "QUARTER"));
    try testing.expectEqualStrings("1-3 0 0:0:0", try canonical(&buf, 5, "QUARTER"));
    try testing.expectEqualStrings("-0-6 0 0:0:0", try canonical(&buf, -2, "QUARTER"));
    try testing.expectEqualStrings("0-0 0 0:0:0.003", try canonical(&buf, 3, "MILLISECOND"));
    try testing.expectEqualStrings("0-0 0 0:0:5", try canonical(&buf, 5_000, "MILLISECOND"));
}

test "INTERVAL takes the ten parts BigQuery takes, and no others" {
    var buf: [96]u8 = undefined;
    for ([_][]const u8{
        "YEAR", "QUARTER", "MONTH",  "WEEK",        "DAY",
        "HOUR", "MINUTE",  "SECOND", "MILLISECOND", "MICROSECOND",
    }) |part| {
        _ = canonical(&buf, 1, part) catch |err| {
            std.debug.print("part {s} rejected: {s}\n", .{ part, @errorName(err) });
            return err;
        };
    }
    // Everything else is an EXTRACT part rather than an interval one, and
    // BigQuery says so: "Invalid interval datetime field ISOYEAR".
    //
    // NANOSECOND is in this list for a different reason: the analyzer resolves
    // it and this engine used to answer it, but BigQuery refuses it, so it is
    // refused here too. See the note on `interval`.
    for ([_][]const u8{
        "NANOSECOND", "ISOYEAR", "ISOWEEK", "DAYOFWEEK", "DAYOFYEAR", "PICOSECOND",
    }) |part| {
        try testing.expectError(error.UnsupportedOperation, canonical(&buf, 1, part));
    }
}

test "INTERVAL counts past i32 are values, not crashes" {
    var buf: [96]u8 = undefined;
    // Regression: the count was `@intCast(...toInt64())` into an i32, which
    // panics rather than erroring — `SELECT INTERVAL 3000000000 SECOND` aborted
    // the process. Microsecond counts make this size ordinary: BigQuery's own
    // reference uses 90061000000, 42x past i32.
    try testing.expectEqualStrings(
        "0-0 0 25:1:1",
        try canonical(&buf, 90_061_000_000, "MICROSECOND"),
    );
    try testing.expectEqualStrings(
        "0-0 0 833333:20:0",
        try canonical(&buf, 3_000_000_000, "SECOND"),
    );
    // The sign rides on the leading field only, which is how BigQuery prints it.
    try testing.expectEqualStrings(
        "0-0 0 -833333:20:0",
        try canonical(&buf, -3_000_000_000, "SECOND"),
    );
}

test "INTERVAL bounds the canonical field, and names it" {
    var buf: [96]u8 = undefined;
    const cases = [_]struct { n: i64, part: []const u8, msg: []const u8 }{
        .{ .n = 200_000, .part = "MONTH", .msg = "months '200000' is out of range -120000 to 120000" },
        // Reported in months, not years: it is the canonical field that is out
        // of range, which is what BigQuery says too.
        .{ .n = 10_001, .part = "YEAR", .msg = "months '120012' is out of range" },
        .{ .n = 3_660_001, .part = "DAY", .msg = "days '3660001' is out of range -3660000 to 3660000" },
        .{ .n = 400_000_000, .part = "WEEK", .msg = "days '2800000000' is out of range" },
        .{
            .n = std.math.maxInt(i64),
            .part = "MICROSECOND",
            .msg = "microseconds '9223372036854775807' is out of range",
        },
    };
    for (cases) |c| {
        bind.clearDiagnostics();
        try testing.expectError(error.UnsupportedOperation, canonical(&buf, c.n, c.part));
        try testing.expect(std.mem.indexOf(u8, bind.message.?, c.msg) != null);
    }
}

test "INTERVAL names the part it refuses, the way BigQuery does" {
    var buf: [96]u8 = undefined;
    bind.clearDiagnostics();
    try testing.expectError(error.UnsupportedOperation, canonical(&buf, 1, "ISOYEAR"));
    try testing.expect(
        std.mem.indexOf(u8, bind.message.?, "Invalid interval datetime field ISOYEAR") != null,
    );
}
