//! Port of go-zetasqlite function_interval.go: INTERVAL, MAKE_INTERVAL, and
//! JUSTIFY_DAYS/HOURS/INTERVAL.

const std = @import("std");
const bind = @import("bind.zig");
const fd = @import("fn_date.zig");
const value_mod = @import("../value.zig");

const Value = bind.Value;
const Error = bind.Error;
const Interval = value_mod.Interval;
const null_v = Value.null;

pub fn interval(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const v: i32 = @intCast(try args[0].toInt64());
    const part = try fd.partStr(args[1]);
    var iv = Interval{};
    if (std.mem.eql(u8, part, "YEAR")) {
        iv.years = v;
    } else if (std.mem.eql(u8, part, "MONTH")) {
        iv.months = v;
    } else if (std.mem.eql(u8, part, "DAY")) {
        iv.days = v;
    } else if (std.mem.eql(u8, part, "HOUR")) {
        iv.hours = v;
    } else if (std.mem.eql(u8, part, "MINUTE")) {
        iv.minutes = v;
    } else if (std.mem.eql(u8, part, "SECOND")) {
        iv.seconds = v;
    } else if (std.mem.eql(u8, part, "NANOSECOND")) {
        iv.sub_second_nanos = v;
    } else {
        return bind.fail("unexpected interval part: {s}", .{part}, error.UnsupportedOperation);
    }
    return Value{ .interval = iv };
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
