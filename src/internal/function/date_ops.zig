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
    const first = tu.BrokenTime{ .civ = tu.compose(c.year, c.month, 1, c.hour, c.minute, c.second, c.micro) };
    const shifted = first.addDate(0, m, 0).parts(); // year/month of target
    const after = tu.decompose(tu.compose(shifted.year, shifted.month, c.day, c.hour, c.minute, c.second, c.micro));
    if (after.month != shifted.month) {
        return first.addDate(0, m + 1, -1);
    }
    return bt.addDate(0, m, 0);
}

/// Go addYear: same clamp behavior across a year shift (Feb 29 -> Feb 28).
pub fn addYear(bt: BrokenTime, y: i64) BrokenTime {
    const c = bt.parts();
    const first = tu.BrokenTime{ .civ = tu.compose(c.year, c.month, 1, c.hour, c.minute, c.second, c.micro) };
    const shifted = first.addDate(y, 0, 0).parts();
    const after = tu.decompose(tu.compose(shifted.year, shifted.month, c.day, c.hour, c.minute, c.second, c.micro));
    if (after.month != shifted.month) {
        return first.addDate(y, 1, -1);
    }
    return bt.addDate(y, 0, 0);
}

/// DATE_ADD: DAY/WEEK/MONTH/YEAR/QUARTER (QUARTER always +3 months, per Go).
pub fn dateAdd(bt: BrokenTime, v: i64, part: []const u8) Error!BrokenTime {
    if (std.mem.eql(u8, part, "DAY")) return bt.addDate(0, 0, v);
    if (std.mem.eql(u8, part, "WEEK")) return bt.addDate(0, 0, v * 7);
    if (std.mem.eql(u8, part, "MONTH")) return addMonth(bt, v);
    if (std.mem.eql(u8, part, "YEAR")) return addYear(bt, v);
    if (std.mem.eql(u8, part, "QUARTER")) return addMonth(bt, 3); // Go ignores v
    return unexpectedPart(part);
}

/// DATE_SUB: DAY/WEEK/MONTH/YEAR (no QUARTER, per Go).
pub fn dateSub(bt: BrokenTime, v: i64, part: []const u8) Error!BrokenTime {
    if (std.mem.eql(u8, part, "DAY")) return bt.addDate(0, 0, -v);
    if (std.mem.eql(u8, part, "WEEK")) return bt.addDate(0, 0, -v * 7);
    if (std.mem.eql(u8, part, "MONTH")) return addMonth(bt, -v);
    if (std.mem.eql(u8, part, "YEAR")) return addYear(bt, -v);
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
    if (std.mem.eql(u8, part, "YEAR")) return a.parts().year - b.parts().year;
    if (std.mem.eql(u8, part, "ISOYEAR")) return iso_a.year - iso_b.year;
    return unexpectedPart(part);
}

var quarter_start_months = [_]i64{ 1, 4, 7, 10 };

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
    if (std.mem.eql(u8, part, "QUARTER")) {
        const day = bt.yearDay();
        const q: i64 = if (day <= 91) 1 else if (day <= 182) 2 else if (day <= 273) 3 else 4;
        return .{ .int = q };
    }
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
