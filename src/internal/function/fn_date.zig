//! Port of go-zetasqlite function_date.go bind handlers plus EXTRACT and
//! GENERATE_DATE_ARRAY. Date-part arguments arrive as decoded enum strings.

const std = @import("std");
const bind = @import("bind.zig");
const tu = @import("time_util.zig");
const ops = @import("date_ops.zig");
const tp = @import("time_parser.zig");
const value_mod = @import("../value.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

fn brokenOf(v: Value) Error!tu.BrokenTime {
    return tu.broken(v);
}

/// The injected/fallback "now" as civil micros (UTC). The transformer appends
/// an int64 nanos literal when a deterministic time is set; otherwise fall back
/// to the wall clock (Go uses time.Now()).
pub fn nowCiv(args: []const Value) Error!i64 {
    if (args.len >= 1 and args[0] == .int) return @divTrunc(args[0].int, 1000);
    // Fallback wall clock (Go uses time.Now()); the transformer always injects
    // a deterministic time when configured, so this is only for ad-hoc calls.
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * tu.second_micros + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000);
}

pub fn currentDate(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    return tu.dateValue(.{ .civ = try nowCiv(args) });
}

/// DATE(y,m,d) | DATE(timestamp[,zone]) | DATE(ts/datetime/string).
pub fn date(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    if (args.len == 3) {
        const y = try args[0].toInt64();
        const m = try args[1].toInt64();
        const d = try args[2].toInt64();
        // Go: time.Time{}.AddDate(y-1, m-1, d-1) == compose(y, m, d).
        return Value{ .date = @divFloor(tu.compose(y, m, d, 0, 0, 0, 0), tu.day_micros) };
    } else if (args.len == 2) {
        const bt = try brokenOf(args[0]);
        const off = try tu.zoneOffsetSeconds(try partStr(args[1]), bt.civ);
        return tu.dateValue(.{ .civ = bt.civ + off * tu.second_micros });
    }
    return tu.dateValue(try brokenOf(args[0]));
}

pub fn dateAdd(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("DATE_ADD: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try brokenOf(args[0]);
    const v = try args[1].toInt64();
    const part = try partStr(args[2]);
    return tu.dateValue(try ops.dateAdd(bt, v, part));
}

pub fn dateSub(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("DATE_SUB: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try brokenOf(args[0]);
    const v = try args[1].toInt64();
    const part = try partStr(args[2]);
    return tu.dateValue(try ops.dateSub(bt, v, part));
}

pub fn dateDiff(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("DATE_DIFF: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const a = try brokenOf(args[0]);
    const b = try brokenOf(args[1]);
    const part = try partStr(args[2]);
    return Value{ .int = try ops.dateDiff(a, b, part) };
}

pub fn dateTrunc(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2) return bind.fail("DATE_TRUNC: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try brokenOf(args[0]);
    const part = try partStr(args[1]);
    return tu.dateValue(try ops.dateTrunc(bt, part));
}

pub fn dateFromUnixDate(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("DATE_FROM_UNIX_DATE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const unixdate = try args[0].toInt64();
    return Value{ .date = unixdate };
}

pub fn formatDate(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return bind.fail("FORMAT_DATE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const format = try args[0].toString(alloc);
    const bt = try brokenOf(args[1]);
    const s = tp.formatTime(alloc, format, bt, 0, .date) catch |e| return propagate(e);
    return Value{ .string = s };
}

pub fn lastDay(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1 and args.len != 2)
        return bind.fail("LAST_DAY: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try brokenOf(args[0]);
    var part: []const u8 = "MONTH";
    if (args.len == 2) part = try partStr(args[1]);
    const c = bt.parts();
    const wd = bt.weekday();
    if (std.mem.eql(u8, part, "YEAR") or std.mem.eql(u8, part, "ISOYEAR"))
        return tu.dateValue(.{ .civ = tu.compose(c.year + 1, 1, 0, 0, 0, 0, 0) });
    if (std.mem.eql(u8, part, "MONTH"))
        return tu.dateValue(bt.addDate(0, 1, -c.day));
    if (std.mem.eql(u8, part, "WEEK") or std.mem.eql(u8, part, "ISOWEEK"))
        return tu.dateValue(bt.addDate(0, 0, 6 - wd));
    if (std.mem.eql(u8, part, "WEEK_MONDAY")) return tu.dateValue(bt.addDate(0, 0, 7 - wd));
    if (std.mem.eql(u8, part, "WEEK_TUESDAY")) return tu.dateValue(bt.addDate(0, 0, 8 - wd));
    if (std.mem.eql(u8, part, "WEEK_WEDNESDAY")) return tu.dateValue(bt.addDate(0, 0, 9 - wd));
    if (std.mem.eql(u8, part, "WEEK_THURSDAY")) return tu.dateValue(bt.addDate(0, 0, 10 - wd));
    if (std.mem.eql(u8, part, "WEEK_FRIDAY")) return tu.dateValue(bt.addDate(0, 0, 11 - wd));
    if (std.mem.eql(u8, part, "WEEK_SATURDAY")) return tu.dateValue(bt.addDate(0, 0, 12 - wd));
    if (std.mem.eql(u8, part, "QUARTER")) {
        // Same shape as the MONTH arm above, over the quarter's start month:
        // step to the first of the following quarter, then back one day.
        // LAST_DAY(DATE '2024-02-15', QUARTER) = 2024-03-31.
        const qm = @divTrunc(c.month - 1, 3) * 3 + 1;
        const q_start = tu.BrokenTime{ .civ = tu.compose(c.year, qm, 1, 0, 0, 0, 0) };
        return tu.dateValue(q_start.addDate(0, 3, -1));
    }
    return bind.fail("LAST_DAY: unexpected part {s}", .{part}, error.UnsupportedOperation);
}

pub fn parseDate(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return bind.fail("PARSE_DATE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const format = try args[0].toString(alloc);
    const target = try args[1].toString(alloc);
    const r = tp.parseTimeFormat(alloc, format, target, .date) catch |e| return propagate(e);
    return Value{ .date = @divFloor(r.civ, tu.day_micros) };
}

pub fn unixDate(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("UNIX_DATE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try brokenOf(args[0]);
    return Value{ .int = @divFloor(bt.unixSeconds(), 24 * 60 * 60) };
}

// ---------------------------------------------------------------------
// EXTRACT
// ---------------------------------------------------------------------

pub fn extract(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const part = try partStr(args[1]);
    var zone: []const u8 = "UTC";
    if (args.len == 3) zone = try partStr(args[2]);

    const inner = if (args[0] == .safe) args[0].safe.* else args[0];
    if (inner == .interval) return extractInterval(inner.interval, part);

    var bt = try brokenOf(inner);
    if (inner == .timestamp) {
        const off = try tu.zoneOffsetSeconds(zone, bt.civ);
        bt = .{ .civ = bt.civ + off * tu.second_micros };
    }
    return ops.extractPart(bt, part);
}

pub fn extractDate(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    var zone: []const u8 = "UTC";
    if (args.len == 2) zone = try partStr(args[1]);
    const inner = if (args[0] == .safe) args[0].safe.* else args[0];
    var bt = try brokenOf(inner);
    if (inner == .timestamp) {
        const off = try tu.zoneOffsetSeconds(zone, bt.civ);
        bt = .{ .civ = bt.civ + off * tu.second_micros };
    }
    return ops.extractPart(bt, "DATE");
}

fn extractInterval(iv: value_mod.Interval, part: []const u8) Error!Value {
    if (std.mem.eql(u8, part, "YEAR")) return .{ .int = iv.years };
    if (std.mem.eql(u8, part, "MONTH")) return .{ .int = iv.months };
    if (std.mem.eql(u8, part, "DAY")) return .{ .int = iv.days };
    if (std.mem.eql(u8, part, "HOUR")) return .{ .int = iv.hours };
    if (std.mem.eql(u8, part, "MINUTE")) return .{ .int = iv.minutes };
    if (std.mem.eql(u8, part, "SECOND")) return .{ .int = iv.seconds };
    if (std.mem.eql(u8, part, "MILLISECOND")) return .{ .int = @divTrunc(iv.sub_second_nanos, 1_000_000) };
    if (std.mem.eql(u8, part, "MICROSECOND")) return .{ .int = @divTrunc(iv.sub_second_nanos, 1000) };
    return bind.fail("EXTRACT: unexpected part {s} for interval", .{part}, error.UnsupportedOperation);
}

// ---------------------------------------------------------------------
// GENERATE_DATE_ARRAY(start, end [, INTERVAL step part])
// ---------------------------------------------------------------------

pub fn generateDateArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2 and args.len != 4)
        return bind.fail("GENERATE_DATE_ARRAY: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    // NULL start/end -> empty array (Go returns &ArrayValue{}).
    if (args[0] == .null or args[1] == .null)
        return value_mod.arrayValue(alloc, &.{});
    var start = try brokenOf(args[0]);
    const end = try brokenOf(args[1]);
    var step: i64 = 1;
    var part: []const u8 = "DAY";
    if (args.len == 4) {
        step = try args[2].toInt64();
        part = try partStr(args[3]);
    }
    if (step == 0) return bind.fail("GENERATE_DATE_ARRAY: step size cannot be 0", .{}, error.UnsupportedOperation);

    var list: std.ArrayList(Value) = .empty;
    const ascending = step > 0;
    while (true) {
        if (ascending and start.civ > end.civ) break;
        if (!ascending and start.civ < end.civ) break;
        try list.append(alloc, tu.dateValue(start));
        start = try ops.dateAdd(start, step, part);
    }
    return value_mod.arrayValue(alloc, list.items);
}

// ---------------------------------------------------------------------

/// The underlying text of a date-part / zone argument (always a StringValue).
pub fn partStr(v: Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        .bytes => |b| b,
        .safe => |p| partStr(p.*),
        else => error.FailedConversion,
    };
}

fn propagate(e: Error) Error {
    if (tp.message) |m| return bind.failMsg(m, e);
    return e;
}
