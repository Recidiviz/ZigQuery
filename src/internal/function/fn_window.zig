//! Port of go-zetasqlite internal/function_window.go (foundation set) plus
//! internal/function_window_option.go (WindowFuncAggregatedStatus).
//!
//! Unlike the GROUP BY aggregates in fn_aggregate.zig, window functions defer
//! all framing (PARTITION BY / ORDER BY / ROWS|RANGE|GROUPS frame) to SQLite's
//! real window machinery: each function is registered with the four window
//! callbacks (xStep/xInverse/xValue/xFinal) and only ever sees the *current
//! frame's* buffered values via `WindowFuncAggregatedStatus`. The clever fixed
//! frames the transformer emits for the numbering/navigation functions (see
//! coordinator's window_func_fixed_ranges, mirroring Go's windowFuncFixedRanges)
//! make `agg.values` at value-time hold exactly the set each Done() counts over.
//!
//! Each struct merges Go's bindWindowX closure with the WINDOW_X methods:
//!   done(self, alloc, agg) -> Value            — required (Go Done)
//!   step(self, alloc, values, agg) -> void     — optional (Go Step)
//!   inverse(self, alloc, values, agg) -> void  — optional (Go Inverse)
//!   parseArguments(self, alloc, values) -> void— optional (Go ParseArguments)
//!   pub const window_mode = .single|.no_args   — which generic step/inverse
//!
//! Statistical (corr/covar/stddev/var/variance) and percentile_* functions are
//! registered but Done() raises a clear "unimplemented" error (deferred).

const std = @import("std");
const bind = @import("bind.zig");
const agg_opt = @import("aggregate_option.zig");

const value_mod = bind.value_mod;
pub const Value = bind.Value;
pub const Error = bind.Error;
pub const AggregatorOption = agg_opt.AggregatorOption;

/// How the generic WindowAggregator feeds Step/Inverse (Go: which of
/// newSingleItemWindowAggregator / newWindowAggregatorWithoutArguments built
/// the aggregator).
pub const WindowMode = enum {
    /// newSingleItemWindowAggregator: parseAggregateOptions runs, the generic
    /// step buffers values[0], the generic inverse removes args[0].
    single,
    /// newWindowAggregatorWithoutArguments: no option parsing, the generic step
    /// buffers IntValue(1) and the generic inverse removes IntValue(1).
    no_args,
};

// ----------------------------------------------------------------------
// WindowFuncAggregatedStatus (Go function_window_option.go)
// ----------------------------------------------------------------------

/// Buffers the values SQLite has stepped into the current frame, plus the
/// aggregate option markers parsed off the first row's arguments.
pub const WindowFuncAggregatedStatus = struct {
    values: std.ArrayList(Value) = .empty,
    opt: AggregatorOption = .{},

    /// Go RelevantValues: apply IGNORE NULLS and DISTINCT to the buffered set.
    pub fn relevantValues(s: *WindowFuncAggregatedStatus, alloc: std.mem.Allocator) Error![]Value {
        var filtered: std.ArrayList(Value) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (s.values.items) |v| {
            if (s.opt.ignore_nulls and v == .@"null") continue;
            if (s.opt.distinct) {
                const key = try v.toString(alloc);
                const entry = try seen.getOrPut(alloc, key);
                if (entry.found_existing) continue;
            }
            try filtered.append(alloc, v);
        }
        return filtered.toOwnedSlice(alloc);
    }

    /// Go Step: append a value to the window.
    pub fn step(s: *WindowFuncAggregatedStatus, alloc: std.mem.Allocator, v: Value) Error!void {
        try s.values.append(alloc, v);
    }

    /// Go Inverse: remove the oldest entry equal to `v` (interface-equality
    /// semantics: scalars compare by value, compound types never match — the
    /// same loose match Go's `v == value` performs on window scalars).
    pub fn inverse(s: *WindowFuncAggregatedStatus, v: Value) Error!void {
        for (s.values.items, 0..) |item, i| {
            if (inverseEqual(item, v)) {
                _ = s.values.orderedRemove(i);
                break;
            }
        }
    }
};

fn inverseEqual(a: Value, b: Value) bool {
    return switch (a) {
        .@"null" => b == .@"null",
        .int => |x| b == .int and b.int == x,
        .float => |x| b == .float and b.float == x,
        .bool => |x| b == .bool and b.bool == x,
        .date => |x| b == .date and b.date == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .bytes => |x| b == .bytes and std.mem.eql(u8, x, b.bytes),
        else => false,
    };
}

// ----------------------------------------------------------------------
// Aggregate functions (Go WINDOW_* structs)
// ----------------------------------------------------------------------

pub const WINDOW_ANY_VALUE = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_ANY_VALUE, _: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        if (agg.values.items.len == 0) return .@"null";
        return agg.values.items[0];
    }
};

pub const WINDOW_ARRAY_AGG = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_ARRAY_AGG, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        return value_mod.arrayValue(alloc, try agg.relevantValues(alloc));
    }
};

pub const WINDOW_AVG = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_AVG, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        var sum: Value = .@"null";
        var total: i64 = 0;
        for (try agg.relevantValues(alloc)) |v| {
            if (v == .@"null") continue;
            total += 1;
            if (sum == .@"null") {
                sum = .{ .float = try v.toFloat64() };
            } else {
                sum = try sum.add(alloc, v);
            }
        }
        if (sum == .@"null") return .@"null";
        return sum.div(alloc, .{ .float = @floatFromInt(total) });
    }
};

pub const WINDOW_COUNT = struct {
    pub const window_mode: WindowMode = .single;
    /// Go WINDOW_COUNT.Step: only non-NULL values are buffered.
    pub fn step(_: *WINDOW_COUNT, alloc: std.mem.Allocator, values: []const Value, agg: *WindowFuncAggregatedStatus) Error!void {
        if (values.len == 0) return;
        if (values[0] == .@"null") return;
        try agg.step(alloc, values[0]);
    }
    pub fn done(_: *WINDOW_COUNT, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        return .{ .int = @intCast((try agg.relevantValues(alloc)).len) };
    }
};

pub const WINDOW_COUNT_STAR = struct {
    pub const window_mode: WindowMode = .no_args;
    pub fn done(_: *WINDOW_COUNT_STAR, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        return .{ .int = @intCast((try agg.relevantValues(alloc)).len) };
    }
};

pub const WINDOW_COUNTIF = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_COUNTIF, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        var count: i64 = 0;
        for (try agg.relevantValues(alloc)) |v| {
            if (v == .@"null") continue;
            if (try v.toBool()) count += 1;
        }
        return .{ .int = count };
    }
};

pub const WINDOW_MAX = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_MAX, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        var max: Value = .@"null";
        for (try agg.relevantValues(alloc)) |v| {
            if (v == .@"null") continue;
            if (max == .@"null") {
                max = v;
            } else if (try v.gt(max)) {
                max = v;
            }
        }
        return max;
    }
};

pub const WINDOW_MIN = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_MIN, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        var min: Value = .@"null";
        for (try agg.relevantValues(alloc)) |v| {
            if (v == .@"null") continue;
            if (min == .@"null") {
                min = v;
            } else if (try v.lt(min)) {
                min = v;
            }
        }
        return min;
    }
};

pub const WINDOW_STRING_AGG = struct {
    pub const window_mode: WindowMode = .single;
    delim: []const u8 = ",",

    pub fn parseArguments(f: *WINDOW_STRING_AGG, alloc: std.mem.Allocator, args: []const Value) Error!void {
        f.delim = ",";
        if (args.len > 1) f.delim = try args[1].toString(alloc);
    }
    pub fn done(f: *WINDOW_STRING_AGG, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        var out: std.ArrayList(u8) = .empty;
        var wrote = false;
        for (try agg.relevantValues(alloc)) |v| {
            if (v == .@"null") continue;
            if (wrote) try out.appendSlice(alloc, f.delim);
            try out.appendSlice(alloc, try v.toString(alloc));
            wrote = true;
        }
        if (!wrote) return .@"null";
        return .{ .string = try out.toOwnedSlice(alloc) };
    }
};

pub const WINDOW_SUM = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_SUM, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        var sum: Value = .@"null";
        for (try agg.relevantValues(alloc)) |v| {
            if (v == .@"null") continue;
            if (sum == .@"null") {
                sum = v;
            } else {
                sum = try sum.add(alloc, v);
            }
        }
        return sum;
    }
};

pub const WINDOW_LOGICAL_AND = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_LOGICAL_AND, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        for (try agg.relevantValues(alloc)) |v| {
            if (!(try v.toBool())) return .{ .bool = false };
        }
        return .{ .bool = true };
    }
};

pub const WINDOW_LOGICAL_OR = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_LOGICAL_OR, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        for (try agg.relevantValues(alloc)) |v| {
            if (try v.toBool()) return .{ .bool = true };
        }
        return .{ .bool = false };
    }
};

// ----------------------------------------------------------------------
// Navigation functions
// ----------------------------------------------------------------------

pub const WINDOW_FIRST_VALUE = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_FIRST_VALUE, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        const values = try agg.relevantValues(alloc);
        if (values.len == 0) return .@"null";
        return values[0];
    }
};

pub const WINDOW_LAST_VALUE = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(_: *WINDOW_LAST_VALUE, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        const values = try agg.relevantValues(alloc);
        if (values.len == 0) return .@"null";
        return values[values.len - 1];
    }
};

pub const WINDOW_NTH_VALUE = struct {
    pub const window_mode: WindowMode = .single;
    n: i64 = 0,

    pub fn parseArguments(f: *WINDOW_NTH_VALUE, _: std.mem.Allocator, args: []const Value) Error!void {
        if (args.len < 2 or args[1] == .@"null") {
            return bind.fail("NTH_VALUE: constant integer expression must be not null value", .{}, error.NullValue);
        }
        f.n = (try args[1].toInt64()) - 1; // ordinal access
    }
    pub fn done(f: *WINDOW_NTH_VALUE, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        const values = try agg.relevantValues(alloc);
        if (@as(i64, @intCast(values.len)) - 1 < f.n) return .@"null";
        return values[@intCast(f.n)];
    }
};

pub const WINDOW_LEAD = struct {
    pub const window_mode: WindowMode = .single;
    offset: i64 = 1,
    default_value: Value = .@"null",

    pub fn parseArguments(f: *WINDOW_LEAD, _: std.mem.Allocator, args: []const Value) Error!void {
        if (args.len > 3) return bind.fail("LEAD: expected at most 3 arguments; got [{d}]", .{args.len}, error.UnsupportedOperation);
        f.offset = 1;
        f.default_value = .@"null";
        if (args.len > 1) {
            if (args[1] == .@"null") return bind.fail("LEAD: constant integer expression must be not null value", .{}, error.NullValue);
            const off = try args[1].toInt64();
            if (off < 0) return bind.fail("LEAD: Argument 2 to LEAD must be at least 0; got {d}", .{off}, error.UnsupportedOperation);
            f.offset = off;
        }
        if (args.len > 2) f.default_value = args[2];
    }
    pub fn done(f: *WINDOW_LEAD, _: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        // Values includes the current row at index 0; LEAD reads offset ahead.
        if (@as(i64, @intCast(agg.values.items.len)) - 1 < f.offset) return f.default_value;
        return agg.values.items[@intCast(f.offset)];
    }
};

pub const WINDOW_LAG = struct {
    pub const window_mode: WindowMode = .single;
    offset: i64 = 1,
    default_value: Value = .@"null",

    pub fn parseArguments(f: *WINDOW_LAG, _: std.mem.Allocator, args: []const Value) Error!void {
        if (args.len > 3) return bind.fail("LEAD: expected at most 3 arguments; got [{d}]", .{args.len}, error.UnsupportedOperation);
        f.offset = 1;
        f.default_value = .@"null";
        if (args.len > 1) {
            if (args[1] == .@"null") return bind.fail("LAG: constant integer expression must be not null value", .{}, error.NullValue);
            const off = try args[1].toInt64();
            if (off < 0) return bind.fail("LAG: Argument 2 to LAG must be at least 0; got {d}", .{off}, error.UnsupportedOperation);
            f.offset = off;
        }
        if (args.len > 2) f.default_value = args[2];
    }
    pub fn done(f: *WINDOW_LAG, _: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        // Values ends at the current row; LAG reads offset back from the end.
        const len: i64 = @intCast(agg.values.items.len);
        if (len - 1 < f.offset) return f.default_value;
        return agg.values.items[@intCast(len - f.offset - 1)];
    }
};

// ----------------------------------------------------------------------
// Numbering functions
// ----------------------------------------------------------------------

/// Deferred to SQLite framing (GROUPS ... CURRENT ROW EXCLUDE TIES): the
/// buffered count is the rank.
pub const WINDOW_RANK = struct {
    pub const window_mode: WindowMode = .no_args;
    pub fn done(_: *WINDOW_RANK, alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        return .{ .int = @intCast((try agg.relevantValues(alloc)).len) };
    }
};

/// Go WINDOW_DENSE_RANK: nStep is set to 1 on Step and *never reset* — Done
/// increments nTotal on every call once any Step has run. Under the fixed
/// RANGE UNBOUNDED PRECEDING..CURRENT ROW frame, SQLite invokes value once per
/// peer group, so nTotal counts distinct peer groups (bug-for-bug preserved).
pub const WINDOW_DENSE_RANK = struct {
    pub const window_mode: WindowMode = .no_args;
    n_step: i64 = 0,
    n_total: i64 = 0,

    pub fn step(f: *WINDOW_DENSE_RANK, _: std.mem.Allocator, _: []const Value, _: *WindowFuncAggregatedStatus) Error!void {
        f.n_step = 1;
    }
    pub fn done(f: *WINDOW_DENSE_RANK, _: std.mem.Allocator, _: *WindowFuncAggregatedStatus) Error!Value {
        if (f.n_step != 0) f.n_total += 1;
        return .{ .int = f.n_total };
    }
};

pub const WINDOW_PERCENT_RANK = struct {
    pub const window_mode: WindowMode = .no_args;
    n_step: i64 = 0,
    n_total: i64 = 0,

    pub fn step(f: *WINDOW_PERCENT_RANK, _: std.mem.Allocator, _: []const Value, _: *WindowFuncAggregatedStatus) Error!void {
        f.n_total += 1;
    }
    pub fn inverse(f: *WINDOW_PERCENT_RANK, _: std.mem.Allocator, _: []const Value, _: *WindowFuncAggregatedStatus) Error!void {
        f.n_step += 1;
    }
    pub fn done(f: *WINDOW_PERCENT_RANK, _: std.mem.Allocator, _: *WindowFuncAggregatedStatus) Error!Value {
        if (f.n_total > 1) {
            return .{ .float = @as(f64, @floatFromInt(f.n_step)) / @as(f64, @floatFromInt(f.n_total - 1)) };
        }
        return .{ .float = 0.0 };
    }
};

pub const WINDOW_CUME_DIST = struct {
    pub const window_mode: WindowMode = .no_args;
    n_step: i64 = 0,
    n_total: i64 = 0,

    pub fn step(f: *WINDOW_CUME_DIST, _: std.mem.Allocator, _: []const Value, _: *WindowFuncAggregatedStatus) Error!void {
        f.n_total += 1;
    }
    pub fn inverse(f: *WINDOW_CUME_DIST, _: std.mem.Allocator, _: []const Value, _: *WindowFuncAggregatedStatus) Error!void {
        f.n_step += 1;
    }
    pub fn done(f: *WINDOW_CUME_DIST, _: std.mem.Allocator, _: *WindowFuncAggregatedStatus) Error!Value {
        return .{ .float = @as(f64, @floatFromInt(f.n_step)) / @as(f64, @floatFromInt(f.n_total)) };
    }
};

pub const WINDOW_NTILE = struct {
    pub const window_mode: WindowMode = .single;
    n_param: i64 = 0,
    n_total: i64 = 0,
    i_row: i64 = 0,

    pub fn parseArguments(f: *WINDOW_NTILE, _: std.mem.Allocator, args: []const Value) Error!void {
        if (args.len < 1) return bind.fail("NTILE: must provide one argument", .{}, error.UnsupportedOperation);
        if (args[0] == .@"null") return bind.fail("NTILE: constant integer expression must not be null value", .{}, error.NullValue);
        const value = try args[0].toInt64();
        if (value <= 0) return bind.fail("NTILE: constant integer expression must be positive value", .{}, error.UnsupportedOperation);
        f.n_param = value;
    }
    pub fn step(f: *WINDOW_NTILE, _: std.mem.Allocator, _: []const Value, _: *WindowFuncAggregatedStatus) Error!void {
        f.n_total += 1;
    }
    pub fn inverse(f: *WINDOW_NTILE, _: std.mem.Allocator, _: []const Value, _: *WindowFuncAggregatedStatus) Error!void {
        f.i_row += 1;
    }
    pub fn done(f: *WINDOW_NTILE, _: std.mem.Allocator, _: *WindowFuncAggregatedStatus) Error!Value {
        const n_size = @divTrunc(f.n_total, f.n_param);
        if (n_size == 0) {
            return .{ .int = f.i_row + 1 };
        }
        const n_large = f.n_total - f.n_param * n_size;
        const i_small = n_large * (n_size + 1);
        if ((n_large * (n_size + 1) + (f.n_param - n_large) * n_size) != f.n_total) {
            return bind.fail("assertion failed", .{}, error.UnsupportedOperation);
        }
        if (f.i_row < i_small) {
            return .{ .int = 1 + @divTrunc(f.i_row, n_size + 1) };
        }
        return .{ .int = 1 + n_large + @divTrunc(f.i_row - i_small, n_size) };
    }
};

pub const WINDOW_ROW_NUMBER = struct {
    pub const window_mode: WindowMode = .no_args;
    pub fn done(_: *WINDOW_ROW_NUMBER, _: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!Value {
        return .{ .int = @intCast(agg.values.items.len) };
    }
};

// ----------------------------------------------------------------------
// Deferred: statistical + percentile functions. Registered so the names
// resolve, but Done() raises a clear unimplemented error.
// ----------------------------------------------------------------------

fn Unimplemented(comptime name: []const u8) type {
    return struct {
        pub const window_mode: WindowMode = .single;
        pub fn done(_: *@This(), _: std.mem.Allocator, _: *WindowFuncAggregatedStatus) Error!Value {
            return bind.fail("zetasqlite_window_" ++ name ++ ": unimplemented", .{}, error.Unimplemented);
        }
    };
}

pub const WINDOW_CORR = Unimplemented("corr");
pub const WINDOW_COVAR_POP = Unimplemented("covar_pop");
pub const WINDOW_COVAR_SAMP = Unimplemented("covar_samp");
pub const WINDOW_STDDEV_POP = Unimplemented("stddev_pop");
pub const WINDOW_STDDEV_SAMP = Unimplemented("stddev_samp");
pub const WINDOW_STDDEV = Unimplemented("stddev");
pub const WINDOW_VAR_POP = Unimplemented("var_pop");
pub const WINDOW_VAR_SAMP = Unimplemented("var_samp");
pub const WINDOW_VARIANCE = Unimplemented("variance");
pub const WINDOW_PERCENTILE_CONT = Unimplemented("percentile_cont");
pub const WINDOW_PERCENTILE_DISC = Unimplemented("percentile_disc");

// ----------------------------------------------------------------------
// Impl-level tests (SQL-level coverage lives in window.zig)
// ----------------------------------------------------------------------

const testing = std.testing;

test "relevantValues honors ignore_nulls and distinct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var agg = WindowFuncAggregatedStatus{};
    try agg.step(alloc, .{ .int = 1 });
    try agg.step(alloc, .@"null");
    try agg.step(alloc, .{ .int = 1 });
    try agg.step(alloc, .{ .int = 2 });

    // Default: everything, including the NULL and the duplicate.
    try testing.expectEqual(@as(usize, 4), (try agg.relevantValues(alloc)).len);

    agg.opt.ignore_nulls = true;
    try testing.expectEqual(@as(usize, 3), (try agg.relevantValues(alloc)).len);

    agg.opt.distinct = true;
    // ignore_nulls + distinct -> {1, 2}
    try testing.expectEqual(@as(usize, 2), (try agg.relevantValues(alloc)).len);
}

test "inverse removes the oldest matching scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var agg = WindowFuncAggregatedStatus{};
    try agg.step(alloc, .{ .int = 10 });
    try agg.step(alloc, .{ .int = 20 });
    try agg.step(alloc, .{ .int = 10 });
    try agg.inverse(.{ .int = 10 });
    try testing.expectEqual(@as(usize, 2), agg.values.items.len);
    try testing.expectEqual(@as(i64, 20), agg.values.items[0].int);
    try testing.expectEqual(@as(i64, 10), agg.values.items[1].int);
}

test "dense_rank counter never resets nStep (Go quirk)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var agg = WindowFuncAggregatedStatus{};
    var f = WINDOW_DENSE_RANK{};
    // Before any step, nStep==0 -> Done does not advance.
    try value_mod.expectValueEqual(.{ .int = 0 }, try f.done(alloc, &agg));
    // After a step, every Done advances (once per peer group under the frame).
    try f.step(alloc, &.{}, &agg);
    try value_mod.expectValueEqual(.{ .int = 1 }, try f.done(alloc, &agg));
    try value_mod.expectValueEqual(.{ .int = 2 }, try f.done(alloc, &agg));
}
