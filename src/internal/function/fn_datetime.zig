//! Port of go-zetasqlite function_datetime.go bind handlers.

const std = @import("std");
const bind = @import("bind.zig");
const tu = @import("time_util.zig");
const ops = @import("date_ops.zig");
const tp = @import("time_parser.zig");
const fd = @import("fn_date.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

pub fn currentDatetime(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    return tu.datetimeValue(.{ .civ = try fd.nowCiv(args) });
}

/// DATETIME_BUCKET(datetime, width[, origin]). The origin defaults to
/// 1950-01-01 00:00:00, and its time-of-day is kept, not truncated. See
/// `date_ops.bucket`.
pub fn datetimeBucket(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2 and args.len != 3)
        return bind.fail("DATETIME_BUCKET: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const origin = if (args.len == 3)
        try tu.broken(args[2])
    else
        ops.defaultBucketOrigin();
    return tu.datetimeValue(try ops.bucket(
        .datetime,
        try tu.broken(args[0]),
        try fd.intervalOf(args[1]),
        origin,
    ));
}

pub fn datetime(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    if (args.len == 6) {
        const y = try args[0].toInt64();
        const mo = try args[1].toInt64();
        const d = try args[2].toInt64();
        const h = try args[3].toInt64();
        const mi = try args[4].toInt64();
        const s = try args[5].toInt64();
        return .{ .datetime = tu.compose(y, mo, d, h, mi, s, 0) };
    }
    if (args.len != 1 and args.len != 2)
        return bind.fail("DATETIME: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    const inner = if (args[0] == .safe) args[0].safe.* else args[0];
    switch (inner) {
        .date => {
            const bt = try tu.broken(inner);
            if (args.len == 2) {
                // DATE + TIME -> combine.
                const t2 = try tu.broken(args[1]);
                const c = bt.parts();
                const tc = t2.parts();
                return .{ .datetime = tu.compose(
                    c.year,
                    c.month,
                    c.day,
                    tc.hour,
                    tc.minute,
                    tc.second,
                    tc.micro,
                ) };
            }
            return tu.datetimeValue(bt);
        },
        .timestamp => {
            const bt = try tu.broken(inner);
            if (args.len == 2) {
                const off = try tu.zoneOffsetSeconds(try fd.partStr(args[1]), bt.civ);
                return tu.datetimeValue(.{ .civ = bt.civ + off * tu.second_micros });
            }
            return tu.datetimeValue(bt);
        },
        else => return bind.fail("DATETIME: first argument must be DATE or TIMESTAMP type", .{}, error.UnsupportedOperation),
    }
}

const unit_micros = struct {
    fn of(part: []const u8) ?i64 {
        if (std.mem.eql(u8, part, "MICROSECOND")) return 1;
        if (std.mem.eql(u8, part, "MILLISECOND")) return 1000;
        if (std.mem.eql(u8, part, "SECOND")) return tu.second_micros;
        if (std.mem.eql(u8, part, "MINUTE")) return tu.minute_micros;
        if (std.mem.eql(u8, part, "HOUR")) return tu.hour_micros;
        return null;
    }
};

pub fn datetimeAdd(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("DATETIME_ADD: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    const v = try args[1].toInt64();
    const part = try fd.partStr(args[2]);
    if (unit_micros.of(part)) |u| return tu.datetimeValue(bt.add(v * u));
    return tu.datetimeValue(try ops.dateAdd(bt, v, part));
}

pub fn datetimeSub(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("DATETIME_SUB: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    const v = try args[1].toInt64();
    const part = try fd.partStr(args[2]);
    if (unit_micros.of(part)) |u| return tu.datetimeValue(bt.add(-v * u));
    return tu.datetimeValue(try ops.dateSub(bt, v, part));
}

pub fn datetimeDiff(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("DATETIME_DIFF: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const a = try tu.broken(args[0]);
    const b = try tu.broken(args[1]);
    const part = try fd.partStr(args[2]);
    if (unit_micros.of(part)) |u| return .{ .int = @divTrunc(a.civ - b.civ, u) };
    return .{ .int = try ops.dateDiff(a, b, part) };
}

pub fn datetimeTrunc(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2) return bind.fail("DATETIME_TRUNC: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    const part = try fd.partStr(args[1]);
    const c = bt.parts();
    if (std.mem.eql(u8, part, "MICROSECOND")) return tu.datetimeValue(bt);
    if (std.mem.eql(u8, part, "MILLISECOND")) {
        const ms = tu.truncMillis(c.micro);
        return .{ .datetime = tu.compose(c.year, c.month, c.day, c.hour, c.minute, c.second, ms) };
    }
    if (std.mem.eql(u8, part, "SECOND")) {
        return .{ .datetime = tu.compose(c.year, c.month, c.day, c.hour, c.minute, c.second, 0) };
    }
    if (std.mem.eql(u8, part, "MINUTE")) {
        return .{ .datetime = tu.compose(c.year, c.month, c.day, c.hour, c.minute, 0, 0) };
    }
    if (std.mem.eql(u8, part, "HOUR")) {
        return .{ .datetime = tu.compose(c.year, c.month, c.day, c.hour, 0, 0, 0) };
    }
    return tu.datetimeValue(try ops.dateTrunc(bt, part));
}

pub fn formatDatetime(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return bind.fail("FORMAT_DATETIME: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const format = try fd.partStr(args[0]);
    const bt = try tu.broken(args[1]);
    const s = tp.formatTime(alloc, format, bt, 0, .datetime) catch |e| return propagate(e);
    return Value{ .string = s };
}

pub fn parseDatetime(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return bind.fail("PARSE_DATETIME: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const format = try fd.partStr(args[0]);
    const target = try fd.partStr(args[1]);
    const r = tp.parseTimeFormat(alloc, format, target, .datetime) catch |e| return propagate(e);
    return Value{ .datetime = r.civ };
}

fn propagate(e: Error) Error {
    if (tp.message) |m| return bind.failMsg(m, e);
    return e;
}

// ---- tests ----
//
// Only what SQL cannot reach; everything else is asserted against the GoogleSQL
// reference in testdata/specs/zigquery/functions/datetime.

const testing = std.testing;

test "DATETIME rejects an argument type the analyzer would have to admit" {
    // DATETIME(DATETIME) reaches the same branch and has a spec case; a BOOL
    // first argument has no signature at all, so this guard is defensive.
    try testing.expectError(
        error.UnsupportedOperation,
        datetime(testing.allocator, &.{Value{ .bool = true }}),
    );
}

test "propagate prefers the parser's message and falls back to the bare error" {
    tp.message = null;
    try testing.expectEqual(Error.OutOfMemory, propagate(error.OutOfMemory));

    tp.message = "error parsing [x] with format [%c]: could not parse ansic format";
    try testing.expectEqual(Error.InvalidDate, propagate(error.InvalidDate));
    try testing.expectEqualStrings(tp.message.?, bind.message.?);
    tp.message = null;
    bind.clearDiagnostics();
}
