//! Port of go-zetasqlite function_time.go bind handlers.

const std = @import("std");
const bind = @import("bind.zig");
const tu = @import("time_util.zig");
const tp = @import("time_parser.zig");
const fd = @import("fn_date.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

pub fn currentTime(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    return tu.timeValue(.{ .civ = try fd.nowCiv(args) });
}

pub fn time(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    if (args.len == 3) {
        const h = try args[0].toInt64();
        const mi = try args[1].toInt64();
        const s = try args[2].toInt64();
        return tu.timeValue(.{ .civ = tu.compose(0, 1, 1, h, mi, s, 0) });
    }
    if (args.len != 1 and args.len != 2)
        return bind.fail("TIME: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    const inner = if (args[0] == .safe) args[0].safe.* else args[0];
    switch (inner) {
        .timestamp => {
            const bt = try tu.broken(inner);
            if (args.len == 2) {
                const off = try tu.zoneOffsetSeconds(try fd.partStr(args[1]), bt.civ);
                return tu.timeValue(.{ .civ = bt.civ + off * tu.second_micros });
            }
            return tu.timeValue(bt);
        },
        .datetime => return tu.timeValue(try tu.broken(inner)),
        else => return bind.fail("TIME: invalid first argument type", .{}, error.UnsupportedOperation),
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

pub fn timeAdd(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("TIME_ADD: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    const v = try args[1].toInt64();
    const part = try fd.partStr(args[2]);
    const u = unitMicros(part) orelse return bind.fail("TIME_ADD: unexpected part value {s}", .{part}, error.UnsupportedOperation);
    return tu.timeValue(bt.add(v * u));
}

pub fn timeSub(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("TIME_SUB: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    const v = try args[1].toInt64();
    const part = try fd.partStr(args[2]);
    const u = unitMicros(part) orelse return bind.fail("TIME_SUB: unexpected part value {s}", .{part}, error.UnsupportedOperation);
    return tu.timeValue(bt.add(-v * u));
}

pub fn timeDiff(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3) return bind.fail("TIME_DIFF: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const a = try tu.broken(args[0]);
    const b = try tu.broken(args[1]);
    const part = try fd.partStr(args[2]);
    const u = unitMicros(part) orelse return bind.fail("TIME_DIFF: unexpected part value {s}", .{part}, error.UnsupportedOperation);
    return .{ .int = @divTrunc(a.civ - b.civ, u) };
}

pub fn timeTrunc(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2) return bind.fail("TIME_TRUNC: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const bt = try tu.broken(args[0]);
    const part = try fd.partStr(args[1]);
    const c = bt.parts();
    if (std.mem.eql(u8, part, "MICROSECOND")) return tu.timeValue(bt);
    if (std.mem.eql(u8, part, "MILLISECOND")) return tu.timeValue(.{ .civ = tu.compose(c.year, c.month, c.day, c.hour, c.minute, c.second, 0) });
    if (std.mem.eql(u8, part, "SECOND")) return tu.timeValue(.{ .civ = tu.compose(c.year, c.month, c.day, c.hour, c.minute, 0, 0) });
    if (std.mem.eql(u8, part, "MINUTE")) return tu.timeValue(.{ .civ = tu.compose(c.year, c.month, c.day, c.hour, c.minute, 0, 0) });
    if (std.mem.eql(u8, part, "HOUR")) return tu.timeValue(.{ .civ = tu.compose(c.year, c.month, c.day, c.hour, 0, 0, 0) });
    return bind.fail("TIME_TRUNC: unexpected part value {s}", .{part}, error.UnsupportedOperation);
}

pub fn formatTimeFn(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return bind.fail("FORMAT_TIME: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const format = try fd.partStr(args[0]);
    const bt = try tu.broken(args[1]);
    const s = tp.formatTime(alloc, format, bt, 0, .time) catch |e| return propagate(e);
    return Value{ .string = s };
}

pub fn parseTime(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return bind.fail("PARSE_TIME: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const format = try fd.partStr(args[0]);
    const target = try fd.partStr(args[1]);
    const r = tp.parseTimeFormat(alloc, format, target, .time) catch |e| return propagate(e);
    return tu.timeValue(.{ .civ = r.civ });
}

fn propagate(e: Error) Error {
    if (tp.message) |m| return bind.failMsg(m, e);
    return e;
}
