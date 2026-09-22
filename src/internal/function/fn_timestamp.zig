//! TIMESTAMP builtins: the constructor, ADD/SUB/DIFF/TRUNC/BUCKET, the FORMAT/PARSE pair, the
//! epoch conversions in both directions, STRING and GENERATE_TIMESTAMP_ARRAY.
//! timestamp_functions.md
//!
//! A TIMESTAMP is an absolute instant, held as microseconds since the Unix epoch in UTC. That is
//! what separates this family from the other three: a zone argument never changes the instant,
//! only the civil fields read off it, so TIMESTAMP(datetime, zone) shifts on the way in and
//! STRING(timestamp, zone) renders on the way out, while the stored scalar is the same either
//! way.
//!
//! TIMESTAMP_TRUNC is the exception that must resolve a zone in both directions: truncating to a
//! DAY means the midnight an observer sees, which is a different instant in each zone, so the
//! instant is shifted to that wall clock, truncated there, and shifted back. TIMESTAMP_BUCKET
//! takes no zone at all — its arithmetic is on the instant.

const std = @import("std");
const bind = @import("bind.zig");
const tu = @import("time_util.zig");
const ops = @import("date_ops.zig");
const tp = @import("time_parser.zig");
const fd = @import("fn_date.zig");
const value_mod = @import("../value.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

pub fn currentTimestamp(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    return tu.timestampValue(.{ .civ = try fd.nowCiv(args) });
}

/// STRING(JSON): JSON strings only; LAX_STRING is the renderer. (json_functions.md#string_for_json)
fn stringOfJson(alloc: std.mem.Allocator, doc: []const u8) Error!Value {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        doc,
        .{ .parse_numbers = false },
    ) catch return bind.fail("STRING: invalid json", .{}, error.FailedConversion);
    return switch (parsed) {
        .string => |s| Value{ .string = try alloc.dupe(u8, s) },
        else => bind.fail(
            "STRING: the provided JSON input is not a string",
            .{},
            error.FailedConversion,
        ),
    };
}

/// STRING(timestamp[,zone]): wall clock in `zone` (UTC without one) followed by that zone's offset.
/// GoogleSQL renders the offset as `%Ez` and drops a whole-hour ":00"
/// i.e. Amsterdam in winter is "+01" and Kolkata "+05:30" (date_time_util.cc, truncate_tz).
pub fn string(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1 and args.len != 2)
        return bind.fail("STRING: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const inner0 = if (args[0] == .safe) args[0].safe.* else args[0];
    if (inner0 == .json) return stringOfJson(alloc, inner0.json);

    const bt = try tu.broken(args[0]);
    var off: i64 = 0;
    if (args.len == 2) off = try tu.zoneOffsetSeconds(try fd.partStr(args[1]), bt.civ);
    var buf: [48]u8 = undefined;
    const wall = value_mod.formatDatetimeString(&buf, bt.civ + off * tu.second_micros);
    const sign: u8 = if (off < 0) '-' else '+';
    const off_abs: u64 = @abs(off);
    const hours = @divTrunc(off_abs, 3600);
    const minutes = @divTrunc(@rem(off_abs, 3600), 60);
    const s = if (minutes == 0)
        try std.fmt.allocPrint(alloc, "{s}{c}{d:0>2}", .{ wall, sign, hours })
    else
        try std.fmt.allocPrint(alloc, "{s}{c}{d:0>2}:{d:0>2}", .{ wall, sign, hours, minutes });
    return Value{ .string = s };
}

pub fn timestamp(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1 and args.len != 2)
        return bind.fail("TIMESTAMP: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    var zone: []const u8 = "";
    if (args.len == 2) zone = try fd.partStr(args[1]);
    const inner = if (args[0] == .safe) args[0].safe.* else args[0];
    switch (inner) {
        .string, .bytes => {
            const p = try value_mod.parseTimestampParts(try fd.partStr(inner));
            // A zone written in the string wins over the argument, which the docs say
            // not to pass alongside one. (timestamp_functions.md#timestamp)
            const off = try tu.zoneOffsetSeconds(if (p.zone.len != 0) p.zone else zone, p.civ);
            return Value{ .timestamp = p.civ - off * tu.second_micros };
        },
        .date, .datetime => {
            const bt = try tu.broken(inner);
            const off = try tu.zoneOffsetSeconds(zone, bt.civ);
            return Value{ .timestamp = bt.civ - off * tu.second_micros };
        },
        // Identity form; an instant has no wall clock for a zone to reinterpret.
        // (timestamp_functions.md#timestamp)
        .timestamp => return inner,
        else => return bind.fail("TIMESTAMP: invalid first argument type", .{}, error.UnsupportedOperation),
    }
}

/// Fixed-length parts of an instant. DAY is 24 hours here (timestamp_functions.md#timestamp_diff),
/// whereas DATETIME's is a calendar day.
fn unitMicros(part: []const u8) ?i64 {
    if (std.mem.eql(u8, part, "DAY")) return tu.day_micros;
    if (std.mem.eql(u8, part, "MICROSECOND")) return 1;
    if (std.mem.eql(u8, part, "MILLISECOND")) return 1000;
    if (std.mem.eql(u8, part, "SECOND")) return tu.second_micros;
    if (std.mem.eql(u8, part, "MINUTE")) return tu.minute_micros;
    if (std.mem.eql(u8, part, "HOUR")) return tu.hour_micros;
    return null;
}

pub fn timestampAdd(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("TIMESTAMP_ADD: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    const v = try args[1].toInt64();
    const part = try fd.partStr(args[2]);
    if (unitMicros(part)) |u| return tu.timestampValue(bt.add(v * u));
    if (std.mem.eql(u8, part, "DAY")) return tu.timestampValue(bt.addDate(0, 0, v));
    return bind.fail("TIMESTAMP_ADD: unexpected part value {s}", .{part}, error.UnsupportedOperation);
}

pub fn timestampSub(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("TIMESTAMP_SUB: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    const v = try args[1].toInt64();
    const part = try fd.partStr(args[2]);
    if (unitMicros(part)) |u| return tu.timestampValue(bt.add(-v * u));
    if (std.mem.eql(u8, part, "DAY")) return tu.timestampValue(bt.addDate(0, 0, -v));
    return bind.fail("TIMESTAMP_SUB: unexpected part value {s}", .{part}, error.UnsupportedOperation);
}

pub fn timestampDiff(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("TIMESTAMP_DIFF: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const a = try tu.broken(args[0]);
    const b = try tu.broken(args[1]);
    const part = try fd.partStr(args[2]);
    if (unitMicros(part)) |u| return .{ .int = @divTrunc(a.civ - b.civ, u) };
    return .{ .int = try ops.dateDiff(a, b, part) };
}

/// TIMESTAMP_BUCKET(timestamp, width[, origin]). The origin defaults to
/// 1950-01-01 00:00:00 UTC. No timezone argument: BigQuery's signature has
/// none, and the arithmetic is on the instant. See `date_ops.bucket`.
pub fn timestampBucket(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2 and args.len != 3)
        return bind.fail("TIMESTAMP_BUCKET: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const origin = if (args.len == 3)
        try tu.broken(args[2])
    else
        ops.defaultBucketOrigin();
    return tu.timestampValue(try ops.bucket(
        .timestamp,
        try tu.broken(args[0]),
        try fd.intervalOf(args[1]),
        origin,
    ));
}

pub fn timestampTrunc(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2 and args.len != 3)
        return bind.fail("TIMESTAMP_TRUNC: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const base = try tu.broken(args[0]);
    const part = try fd.partStr(args[1]);
    var zone: []const u8 = "";
    if (args.len == 3) zone = try fd.partStr(args[2]);
    const off = try tu.zoneOffsetSeconds(zone, base.civ);
    const local = tu.BrokenTime{ .civ = base.civ + off * tu.second_micros };
    const c = local.parts();

    var truncated_local: i64 = undefined;
    if (std.mem.eql(u8, part, "MICROSECOND")) {
        truncated_local = local.civ;
    } else if (std.mem.eql(u8, part, "MILLISECOND")) {
        const ms = tu.truncMillis(c.micro);
        truncated_local = tu.compose(c.year, c.month, c.day, c.hour, c.minute, c.second, ms);
    } else if (std.mem.eql(u8, part, "SECOND")) {
        truncated_local = tu.compose(c.year, c.month, c.day, c.hour, c.minute, c.second, 0);
    } else if (std.mem.eql(u8, part, "MINUTE")) {
        truncated_local = tu.compose(c.year, c.month, c.day, c.hour, c.minute, 0, 0);
    } else if (std.mem.eql(u8, part, "HOUR")) {
        truncated_local = tu.compose(c.year, c.month, c.day, c.hour, 0, 0, 0);
    } else {
        // Default: midnight of the date-truncated local day.
        const d = try ops.dateTrunc(local, part);
        truncated_local = d.days() * tu.day_micros;
    }
    // Convert the truncated local wall clock back to a UTC instant.
    const back_off = try tu.zoneOffsetSeconds(zone, truncated_local);
    return Value{ .timestamp = truncated_local - back_off * tu.second_micros };
}

pub fn formatTimestamp(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2 and args.len != 3)
        return bind.fail("FORMAT_TIMESTAMP: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const format = try fd.partStr(args[0]);
    const bt = try tu.broken(args[1]);
    var zone: []const u8 = "";
    if (args.len == 3) zone = try fd.partStr(args[2]);
    const off = try tu.zoneOffsetSeconds(zone, bt.civ);
    const local = tu.BrokenTime{ .civ = bt.civ + off * tu.second_micros };
    const s = tp.formatTime(alloc, format, local, off, .timestamp) catch |e| return propagate(e);
    return Value{ .string = s };
}

pub fn parseTimestamp(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const format = try fd.partStr(args[0]);
    const target = try fd.partStr(args[1]);
    const r = tp.parseTimeFormat(alloc, format, target, .timestamp) catch |e| return propagate(e);
    if (args.len == 2) {
        return Value{ .timestamp = r.civ - r.offset_sec * tu.second_micros };
    }
    // 3-arg: reinterpret the wall clock in the given zone (ignoring %z).
    const zone = try fd.partStr(args[2]);
    const off = try tu.zoneOffsetSeconds(zone, r.civ);
    return Value{ .timestamp = r.civ - off * tu.second_micros };
}

pub fn timestampSeconds(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("TIMESTAMP_SECONDS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .timestamp = (try args[0].toInt64()) * tu.second_micros };
}

pub fn timestampMillis(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("TIMESTAMP_MILLIS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .timestamp = (try args[0].toInt64()) * 1000 };
}

pub fn timestampMicros(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("TIMESTAMP_MICROS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .timestamp = try args[0].toInt64() };
}

pub fn unixSeconds(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("UNIX_SECONDS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = (try tu.broken(args[0])).unixSeconds() };
}

pub fn unixMillis(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("UNIX_MILLIS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = @divFloor((try tu.broken(args[0])).civ, 1000) };
}

pub fn unixMicros(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("UNIX_MICROS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = (try tu.broken(args[0])).civ };
}

pub fn generateTimestampArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 4)
        return bind.fail("GENERATE_TIMESTAMP_ARRAY: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (args[0] == .null or args[1] == .null)
        return value_mod.arrayValue(alloc, &.{});
    var cur = (try tu.broken(args[0])).civ;
    const end = (try tu.broken(args[1])).civ;
    const step = try args[2].toInt64();
    const part = try fd.partStr(args[3]);
    const u = unitMicros(part) orelse
        if (std.mem.eql(u8, part, "DAY")) tu.day_micros else return bind.fail(
            "GENERATE_TIMESTAMP_ARRAY: unexpected part {s}",
            .{part},
            error.UnsupportedOperation,
        );
    if (step == 0) return bind.fail(
        "GENERATE_TIMESTAMP_ARRAY: step size cannot be 0",
        .{},
        error.UnsupportedOperation,
    );

    var list: std.ArrayList(Value) = .empty;
    const ascending = step > 0;
    while (true) {
        if (ascending and cur > end) break;
        if (!ascending and cur < end) break;
        try list.append(alloc, Value{ .timestamp = cur });
        cur += step * u;
    }
    return value_mod.arrayValue(alloc, list.items);
}

fn propagate(e: Error) Error {
    if (tp.message) |m| return bind.failMsg(m, e);
    return e;
}

// ---- tests ----
//
// Only what SQL cannot reach; everything else is asserted against the GoogleSQL
// reference in testdata/specs/zigquery/functions/timestamp.

const testing = std.testing;

test "TIMESTAMP rejects an argument type the analyzer would have to admit" {
    try testing.expectError(
        error.UnsupportedOperation,
        timestamp(testing.allocator, &.{Value{ .bool = true }}),
    );
}

test "STRING refuses a JSON payload that does not parse" {
    // Unreachable through SQL: a JSON literal is validated by the analyzer, and
    // every other `.json` cell was produced by this engine's own writer or by
    // fn_json's parser under the same options. The branch guards against those
    // two ever disagreeing.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.FailedConversion, string(
        arena.allocator(),
        &.{Value{ .json = "{not json" }},
    ));
}

test "STRING ends with the zone's own offset" {
    // 2014-02-28 10:20:30 UTC, the instant timezones.test renders in each zone.
    const ts = Value{ .timestamp = 1393582830_000000 };
    const cases = [_]struct { zone: []const u8, want: []const u8 }{
        .{ .zone = "UTC", .want = "2014-02-28 10:20:30+00" },
        .{ .zone = "Europe/Amsterdam", .want = "2014-02-28 11:20:30+01" },
        .{ .zone = "Asia/Kolkata", .want = "2014-02-28 15:50:30+05:30" },
        .{ .zone = "America/Vancouver", .want = "2014-02-28 02:20:30-08" },
        .{ .zone = "UTC+1234", .want = "2014-02-28 22:54:30+12:34" },
        .{ .zone = "-03:30", .want = "2014-02-28 06:50:30-03:30" },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (cases) |c| {
        const got = try string(arena.allocator(), &.{ ts, Value{ .string = c.zone } });
        try testing.expectEqualStrings(c.want, got.string);
    }
    // Without a zone the instant renders in UTC.
    const no_zone = try string(arena.allocator(), &.{ts});
    try testing.expectEqualStrings("2014-02-28 10:20:30+00", no_zone.string);
}

test "the arity guards the analyzer makes unreachable still hold" {
    // STRING's widest signature is (TIMESTAMP, STRING); FORMAT_TIMESTAMP's is
    // (STRING, TIMESTAMP, STRING); GENERATE_TIMESTAMP_ARRAY takes exactly four,
    // all required. Each is also declared with a min_args the trampoline
    // enforces, so under-supply never arrives either.
    const alloc = testing.allocator;
    const ts = Value{ .timestamp = 0 };
    try testing.expectError(
        error.UnsupportedOperation,
        string(alloc, &.{ ts, Value{ .string = "UTC" }, Value{ .string = "extra" } }),
    );
    try testing.expectError(
        error.UnsupportedOperation,
        formatTimestamp(alloc, &.{Value{ .string = "%Y" }}),
    );
    try testing.expectError(
        error.UnsupportedOperation,
        generateTimestampArray(alloc, &.{ ts, ts }),
    );
}

test "propagate prefers the parser's message and falls back to the bare error" {
    tp.message = null;
    try testing.expectEqual(Error.OutOfMemory, propagate(error.OutOfMemory));

    tp.message = "error parsing [x] with format [%s]: unexpected unixtime length";
    try testing.expectEqual(Error.InvalidDate, propagate(error.InvalidDate));
    try testing.expectEqualStrings(tp.message.?, bind.message.?);
    tp.message = null;
    bind.clearDiagnostics();
}
