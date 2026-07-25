//! Port of go-zetasqlite function_timestamp.go bind handlers plus STRING and
//! GENERATE_TIMESTAMP_ARRAY.

const std = @import("std");
const bind = @import("bind.zig");
const tu = @import("time_util.zig");
const ops = @import("date_ops.zig");
const tp = @import("time_parser.zig");
const fd = @import("fn_date.zig");
const value_mod = @import("../value.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

pub fn currentTimestamp(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    return tu.timestampValue(.{ .civ = try fd.nowCiv(args) });
}

/// STRING(timestamp[,zone]): local wall clock rendered with a literal "+00".
pub fn string(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1 and args.len != 2)
        return bind.fail("STRING: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    var off: i64 = 0;
    if (args.len == 2) off = try tu.zoneOffsetSeconds(try fd.partStr(args[1]), bt.civ);
    var buf: [48]u8 = undefined;
    const s = value_mod.formatTimestampString(&buf, bt.civ + off * tu.second_micros);
    return Value{ .string = try alloc.dupe(u8, s) };
}

fn hasExplicitZone(s: []const u8) bool {
    if (s.len <= 19) return false;
    for (s[19..]) |c| {
        if (c == 'Z' or c == '+' or c == '-' or std.ascii.isAlphabetic(c)) return true;
    }
    return false;
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
            const s = try fd.partStr(inner);
            const utc = try value_mod.parseTimestampMicros(s);
            if (hasExplicitZone(s)) return Value{ .timestamp = utc };
            const off = try tu.zoneOffsetSeconds(zone, utc);
            return Value{ .timestamp = utc - off * tu.second_micros };
        },
        .date, .datetime => {
            const bt = try tu.broken(inner);
            const off = try tu.zoneOffsetSeconds(zone, bt.civ);
            return Value{ .timestamp = bt.civ - off * tu.second_micros };
        },
        else => return bind.fail("TIMESTAMP: invalid first argument type", .{}, error.UnsupportedOperation),
    }
}

fn unitMicros(part: []const u8) ?i64 {
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
        truncated_local = tu.compose(c.year, c.month, c.day, c.hour, c.minute, c.second, 0);
    } else if (std.mem.eql(u8, part, "SECOND")) {
        truncated_local = tu.compose(c.year, c.month, c.day, c.hour, c.minute, 0, 0);
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
    if (args[0] == .@"null" or args[1] == .@"null")
        return value_mod.arrayValue(alloc, &.{});
    var cur = (try tu.broken(args[0])).civ;
    const end = (try tu.broken(args[1])).civ;
    const step = try args[2].toInt64();
    const part = try fd.partStr(args[3]);
    const u = unitMicros(part) orelse if (std.mem.eql(u8, part, "DAY")) tu.day_micros else return bind.fail("GENERATE_TIMESTAMP_ARRAY: unexpected part {s}", .{part}, error.UnsupportedOperation);
    if (step == 0) return bind.fail("GENERATE_TIMESTAMP_ARRAY: step size cannot be 0", .{}, error.UnsupportedOperation);

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
