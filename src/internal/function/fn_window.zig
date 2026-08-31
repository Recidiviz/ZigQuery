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
    /// newTupleItemWindowAggregator (corr/covar_*): requires two arguments,
    /// buffers the pair as a 2-element ArrayValue [x, y] (NULL x or y skipped),
    /// and inverse removes the oldest NULL (never matches a buffered array).
    tuple,
};

// ----------------------------------------------------------------------
// WindowFuncAggregatedStatus (Go function_window_option.go)
// ----------------------------------------------------------------------

/// Buffers the values SQLite has stepped into the current frame, plus the
/// aggregate option markers parsed off the first row's arguments.
pub const WindowFuncAggregatedStatus = struct {
    values: std.ArrayList(Value) = .empty,
    opt: AggregatorOption = .{},
    /// The last `relevantValues` result, held while `values` stands still. SQLite calls xValue
    /// once per row, and a frame that does not move between rows — `OVER ()` and every other
    /// unbounded frame — asks the same question each time.
    relevant: ?[]Value = null,
    /// Allocator for `relevant`, outliving the per-row arena `done()` gets. Set where the Group
    /// is built (window.zig).
    cache_alloc: std.mem.Allocator = undefined,

    /// Go RelevantValues: apply IGNORE NULLS and DISTINCT to the buffered set.
    ///
    /// The result belongs to the aggregator and is shared across the rows of a standing frame.
    /// A caller that reorders or writes to it wants a copy.
    pub fn relevantValues(s: *WindowFuncAggregatedStatus) Error![]Value {
        if (s.relevant) |cached| return cached;

        const a = s.cache_alloc;
        var filtered: std.ArrayList(Value) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(a);
        for (s.values.items) |v| {
            if (s.opt.ignore_nulls and v == .null) continue;
            if (s.opt.distinct) {
                const entry = try seen.getOrPut(a, try agg_opt.groupingKey(a, v));
                if (entry.found_existing) continue;
            }
            try filtered.append(a, v);
        }
        const out = try filtered.toOwnedSlice(a);
        s.relevant = out;
        return out;
    }

    /// Assigns the markers parsed off a row's arguments. IGNORE NULLS and DISTINCT select the
    /// relevant set, so this drops the cache with them.
    pub fn setOption(s: *WindowFuncAggregatedStatus, opt: AggregatorOption) void {
        s.relevant = null;
        s.opt = opt;
    }

    /// Go Step: append a value to the window.
    pub fn step(s: *WindowFuncAggregatedStatus, alloc: std.mem.Allocator, v: Value) Error!void {
        s.relevant = null;
        try s.values.append(alloc, v);
    }

    /// Go Inverse: remove the oldest entry equal to `v` (interface-equality
    /// semantics: scalars compare by value, compound types never match — the
    /// same loose match Go's `v == value` performs on window scalars).
    pub fn inverse(s: *WindowFuncAggregatedStatus, v: Value) Error!void {
        for (s.values.items, 0..) |item, i| {
            if (inverseEqual(item, v)) {
                s.relevant = null;
                _ = s.values.orderedRemove(i);
                break;
            }
        }
    }
};

fn inverseEqual(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .int => |x| b == .int and b.int == x,
        .float => |x| b == .float and b.float == x,
        .bool => |x| b == .bool and b.bool == x,
        // Go's DATE/DATETIME/TIME/TIMESTAMP are `time.Time` — a comparable
        // struct — so `v == value` matches two separate decodes of the same
        // instant. Compare the payload for the same effect.
        .date => |x| b == .date and b.date == x,
        .datetime => |x| b == .datetime and b.datetime == x,
        .time => |x| b == .time and b.time == x,
        .timestamp => |x| b == .timestamp and b.timestamp == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .json => |x| b == .json and std.mem.eql(u8, x, b.json),
        .bytes => |x| b == .bytes and std.mem.eql(u8, x, b.bytes),
        // NUMERIC and INTERVAL reach Go's `==` as *NumericValue/*IntervalValue,
        // so it compares pointers and two decodes of the same number never
        // match: the frame keeps them. Arrays and structs are not comparable in
        // Go at all. Both stay "never equal" here.
        else => false,
    };
}

// ----------------------------------------------------------------------
// Aggregate functions (Go WINDOW_* structs)
// ----------------------------------------------------------------------

pub const WINDOW_ANY_VALUE = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_ANY_VALUE,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        if (agg.values.items.len == 0) return .null;
        return agg.values.items[0];
    }
};

pub const WINDOW_ARRAY_AGG = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_ARRAY_AGG,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        return value_mod.arrayValue(alloc, try agg.relevantValues());
    }
};

pub const WINDOW_AVG = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_AVG,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        var sum: Value = .null;
        var total: i64 = 0;
        for (try agg.relevantValues()) |v| {
            if (v == .null) continue;
            total += 1;
            if (sum == .null) {
                sum = .{ .float = try v.toFloat64() };
            } else {
                sum = try sum.add(alloc, v);
            }
        }
        if (sum == .null) return .null;
        return sum.div(alloc, .{ .float = @floatFromInt(total) });
    }
};

pub const WINDOW_COUNT = struct {
    pub const window_mode: WindowMode = .single;
    /// Go WINDOW_COUNT.Step: only non-NULL values are buffered.
    pub fn step(
        _: *WINDOW_COUNT,
        alloc: std.mem.Allocator,
        values: []const Value,
        agg: *WindowFuncAggregatedStatus,
    ) Error!void {
        if (values.len == 0) return;
        if (values[0] == .null) return;
        try agg.step(alloc, values[0]);
    }
    pub fn done(
        _: *WINDOW_COUNT,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        return .{ .int = @intCast((try agg.relevantValues()).len) };
    }
};

pub const WINDOW_COUNT_STAR = struct {
    pub const window_mode: WindowMode = .no_args;
    pub fn done(
        _: *WINDOW_COUNT_STAR,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        return .{ .int = @intCast((try agg.relevantValues()).len) };
    }
};

pub const WINDOW_COUNTIF = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_COUNTIF,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        var count: i64 = 0;
        for (try agg.relevantValues()) |v| {
            if (v == .null) continue;
            if (try v.toBool()) count += 1;
        }
        return .{ .int = count };
    }
};

pub const WINDOW_MAX = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_MAX,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        var max: Value = .null;
        for (try agg.relevantValues()) |v| {
            if (v == .null) continue;
            if (max == .null) {
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
    pub fn done(
        _: *WINDOW_MIN,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        var min: Value = .null;
        for (try agg.relevantValues()) |v| {
            if (v == .null) continue;
            if (min == .null) {
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

    pub fn parseArguments(
        f: *WINDOW_STRING_AGG,
        alloc: std.mem.Allocator,
        args: []const Value,
    ) Error!void {
        f.delim = ",";
        if (args.len > 1) f.delim = try args[1].toString(alloc);
    }
    pub fn done(
        f: *WINDOW_STRING_AGG,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        var out: std.ArrayList(u8) = .empty;
        var wrote = false;
        for (try agg.relevantValues()) |v| {
            if (v == .null) continue;
            if (wrote) try out.appendSlice(alloc, f.delim);
            try out.appendSlice(alloc, try v.toString(alloc));
            wrote = true;
        }
        if (!wrote) return .null;
        return .{ .string = try out.toOwnedSlice(alloc) };
    }
};

pub const WINDOW_SUM = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_SUM,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        var sum: Value = .null;
        for (try agg.relevantValues()) |v| {
            if (v == .null) continue;
            if (sum == .null) {
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
    pub fn done(
        _: *WINDOW_LOGICAL_AND,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        for (try agg.relevantValues()) |v| {
            if (!(try v.toBool())) return .{ .bool = false };
        }
        return .{ .bool = true };
    }
};

pub const WINDOW_LOGICAL_OR = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_LOGICAL_OR,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        for (try agg.relevantValues()) |v| {
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
    pub fn done(
        _: *WINDOW_FIRST_VALUE,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const values = try agg.relevantValues();
        if (values.len == 0) return .null;
        return values[0];
    }
};

pub const WINDOW_LAST_VALUE = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_LAST_VALUE,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const values = try agg.relevantValues();
        if (values.len == 0) return .null;
        return values[values.len - 1];
    }
};

pub const WINDOW_NTH_VALUE = struct {
    pub const window_mode: WindowMode = .single;
    n: i64 = 0,

    pub fn parseArguments(
        f: *WINDOW_NTH_VALUE,
        _: std.mem.Allocator,
        args: []const Value,
    ) Error!void {
        if (args.len < 2 or args[1] == .null) {
            return bind.fail("NTH_VALUE: constant integer expression must be not null value", .{}, error.NullValue);
        }
        f.n = (try args[1].toInt64()) - 1; // ordinal access
    }
    pub fn done(
        f: *WINDOW_NTH_VALUE,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const values = try agg.relevantValues();
        if (@as(i64, @intCast(values.len)) - 1 < f.n) return .null;
        return values[@intCast(f.n)];
    }
};

pub const WINDOW_LEAD = struct {
    pub const window_mode: WindowMode = .single;
    offset: i64 = 1,
    default_value: Value = .null,

    pub fn parseArguments(f: *WINDOW_LEAD, _: std.mem.Allocator, args: []const Value) Error!void {
        if (args.len > 3) return bind.fail("LEAD: expected at most 3 arguments; got [{d}]", .{args.len}, error.UnsupportedOperation);
        f.offset = 1;
        f.default_value = .null;
        if (args.len > 1) {
            if (args[1] == .null) return bind.fail("LEAD: constant integer expression must be not null value", .{}, error.NullValue);
            const off = try args[1].toInt64();
            if (off < 0) return bind.fail("LEAD: Argument 2 to LEAD must be at least 0; got {d}", .{off}, error.UnsupportedOperation);
            f.offset = off;
        }
        if (args.len > 2) f.default_value = args[2];
    }
    pub fn done(
        f: *WINDOW_LEAD,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        // Values includes the current row at index 0; LEAD reads offset ahead.
        if (@as(i64, @intCast(agg.values.items.len)) - 1 < f.offset) return f.default_value;
        return agg.values.items[@intCast(f.offset)];
    }
};

pub const WINDOW_LAG = struct {
    pub const window_mode: WindowMode = .single;
    offset: i64 = 1,
    default_value: Value = .null,

    pub fn parseArguments(f: *WINDOW_LAG, _: std.mem.Allocator, args: []const Value) Error!void {
        if (args.len > 3) return bind.fail("LEAD: expected at most 3 arguments; got [{d}]", .{args.len}, error.UnsupportedOperation);
        f.offset = 1;
        f.default_value = .null;
        if (args.len > 1) {
            if (args[1] == .null) return bind.fail("LAG: constant integer expression must be not null value", .{}, error.NullValue);
            const off = try args[1].toInt64();
            if (off < 0) return bind.fail("LAG: Argument 2 to LAG must be at least 0; got {d}", .{off}, error.UnsupportedOperation);
            f.offset = off;
        }
        if (args.len > 2) f.default_value = args[2];
    }
    pub fn done(
        f: *WINDOW_LAG,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
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
    pub fn done(
        _: *WINDOW_RANK,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        return .{ .int = @intCast((try agg.relevantValues()).len) };
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

    pub fn step(
        f: *WINDOW_DENSE_RANK,
        _: std.mem.Allocator,
        _: []const Value,
        _: *WindowFuncAggregatedStatus,
    ) Error!void {
        f.n_step = 1;
    }
    pub fn done(
        f: *WINDOW_DENSE_RANK,
        _: std.mem.Allocator,
        _: *WindowFuncAggregatedStatus,
    ) Error!Value {
        if (f.n_step != 0) f.n_total += 1;
        return .{ .int = f.n_total };
    }
};

pub const WINDOW_PERCENT_RANK = struct {
    pub const window_mode: WindowMode = .no_args;
    n_step: i64 = 0,
    n_total: i64 = 0,

    pub fn step(
        f: *WINDOW_PERCENT_RANK,
        _: std.mem.Allocator,
        _: []const Value,
        _: *WindowFuncAggregatedStatus,
    ) Error!void {
        f.n_total += 1;
    }
    pub fn inverse(
        f: *WINDOW_PERCENT_RANK,
        _: std.mem.Allocator,
        _: []const Value,
        _: *WindowFuncAggregatedStatus,
    ) Error!void {
        f.n_step += 1;
    }
    pub fn done(
        f: *WINDOW_PERCENT_RANK,
        _: std.mem.Allocator,
        _: *WindowFuncAggregatedStatus,
    ) Error!Value {
        if (f.n_total > 1) {
            const n_step: f64 = @floatFromInt(f.n_step);
            const n_total: f64 = @floatFromInt(f.n_total - 1);
            return .{ .float = n_step / n_total };
        }
        return .{ .float = 0.0 };
    }
};

pub const WINDOW_CUME_DIST = struct {
    pub const window_mode: WindowMode = .no_args;
    n_step: i64 = 0,
    n_total: i64 = 0,

    pub fn step(
        f: *WINDOW_CUME_DIST,
        _: std.mem.Allocator,
        _: []const Value,
        _: *WindowFuncAggregatedStatus,
    ) Error!void {
        f.n_total += 1;
    }
    pub fn inverse(
        f: *WINDOW_CUME_DIST,
        _: std.mem.Allocator,
        _: []const Value,
        _: *WindowFuncAggregatedStatus,
    ) Error!void {
        f.n_step += 1;
    }
    pub fn done(
        f: *WINDOW_CUME_DIST,
        _: std.mem.Allocator,
        _: *WindowFuncAggregatedStatus,
    ) Error!Value {
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
        if (args[0] == .null) return bind.fail("NTILE: constant integer expression must not be null value", .{}, error.NullValue);
        const value = try args[0].toInt64();
        if (value <= 0) return bind.fail("NTILE: constant integer expression must be positive value", .{}, error.UnsupportedOperation);
        f.n_param = value;
    }
    pub fn step(
        f: *WINDOW_NTILE,
        _: std.mem.Allocator,
        _: []const Value,
        _: *WindowFuncAggregatedStatus,
    ) Error!void {
        f.n_total += 1;
    }
    pub fn inverse(
        f: *WINDOW_NTILE,
        _: std.mem.Allocator,
        _: []const Value,
        _: *WindowFuncAggregatedStatus,
    ) Error!void {
        f.i_row += 1;
    }
    pub fn done(
        f: *WINDOW_NTILE,
        _: std.mem.Allocator,
        _: *WindowFuncAggregatedStatus,
    ) Error!Value {
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
    pub fn done(
        _: *WINDOW_ROW_NUMBER,
        _: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        return .{ .int = @intCast(agg.values.items.len) };
    }
};

// ----------------------------------------------------------------------
// Statistical window functions (Go WINDOW_CORR / COVAR / STDDEV / VAR).
//
// The maths mirror gonum/stat (which go-zetasqlite delegates to): a two-pass
// compensated mean/variance/covariance/correlation. All of these require at
// least two buffered values (Go: len(values) < 2 -> NULL).
// ----------------------------------------------------------------------

const stat = struct {
    fn mean(x: []const f64) f64 {
        var sum: f64 = 0;
        for (x) |v| sum += v;
        return sum / @as(f64, @floatFromInt(x.len));
    }

    /// gonum MeanVariance (unweighted, sample): (ss - comp^2/n) / (n-1).
    /// `population` divides by n instead of n-1.
    fn variance(x: []const f64, population: bool) f64 {
        const m = mean(x);
        var ss: f64 = 0;
        var comp: f64 = 0;
        for (x) |v| {
            const d = v - m;
            ss += d * d;
            comp += d;
        }
        const n: f64 = @floatFromInt(x.len);
        const denom: f64 = if (population) n else n - 1;
        return (ss - comp * comp / n) / denom;
    }

    /// gonum Covariance (unweighted, sample): (ss - xcomp*ycomp/n) / (n-1).
    fn covariance(x: []const f64, y: []const f64) f64 {
        const mx = mean(x);
        const my = mean(y);
        var ss: f64 = 0;
        var xcomp: f64 = 0;
        var ycomp: f64 = 0;
        for (x, y) |xv, yv| {
            const xd = xv - mx;
            const yd = yv - my;
            ss += xd * yd;
            xcomp += xd;
            ycomp += yd;
        }
        const n: f64 = @floatFromInt(x.len);
        return (ss - xcomp * ycomp / n) / (n - 1);
    }

    /// gonum Correlation: two-pass compensated Pearson correlation.
    fn correlation(x: []const f64, y: []const f64) f64 {
        const mx = mean(x);
        const my = mean(y);
        var sxx: f64 = 0;
        var syy: f64 = 0;
        var sxy: f64 = 0;
        var xcomp: f64 = 0;
        var ycomp: f64 = 0;
        for (x, y) |xv, yv| {
            const xd = xv - mx;
            const yd = yv - my;
            sxx += xd * xd;
            syy += yd * yd;
            sxy += xd * yd;
            xcomp += xd;
            ycomp += yd;
        }
        const n: f64 = @floatFromInt(x.len);
        sxx -= xcomp * xcomp / n;
        syy -= ycomp * ycomp / n;
        sxy -= xcomp * ycomp / n;
        return sxy / @sqrt(sxx * syy);
    }
};

/// Reads the buffered pairs (each a 2-element array) into two float slices.
/// Returns null-signal via len 0 when fewer than two pairs exist.
fn tupleFloats(
    alloc: std.mem.Allocator,
    agg: *WindowFuncAggregatedStatus,
    comptime what: []const u8,
) Error!?struct { x: []f64, y: []f64 } {
    const values = try agg.relevantValues();
    if (values.len < 2) return null;
    var xs: std.ArrayList(f64) = .empty;
    var ys: std.ArrayList(f64) = .empty;
    for (values) |value| {
        const arr = try value.toArray();
        if (arr.values.len != 2) return bind.fail(
            "invalid " ++ what ++ " arguments",
            .{},
            error.UnsupportedOperation,
        );
        try xs.append(alloc, try arr.values[0].toFloat64());
        try ys.append(alloc, try arr.values[1].toFloat64());
    }
    if (xs.items.len == 0) return null;
    return .{ .x = xs.items, .y = ys.items };
}

/// Reads the buffered scalars into a float slice (>=2 required, Go quirk).
fn scalarFloats(alloc: std.mem.Allocator, agg: *WindowFuncAggregatedStatus) Error!?[]f64 {
    const values = try agg.relevantValues();
    if (values.len < 2) return null;
    var xs: std.ArrayList(f64) = .empty;
    for (values) |value| try xs.append(alloc, try value.toFloat64());
    if (xs.items.len == 0) return null;
    return xs.items;
}

pub const WINDOW_CORR = struct {
    pub const window_mode: WindowMode = .tuple;
    pub fn done(
        _: *WINDOW_CORR,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const pair = (try tupleFloats(alloc, agg, "corr")) orelse return .null;
        return .{ .float = stat.correlation(pair.x, pair.y) };
    }
};

pub const WINDOW_COVAR_POP = struct {
    pub const window_mode: WindowMode = .tuple;
    pub fn done(
        _: *WINDOW_COVAR_POP,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        // Go quirk (goccy/go-zetasqlite#168): uses sample covariance too.
        const pair = (try tupleFloats(alloc, agg, "covar_pop")) orelse return .null;
        return .{ .float = stat.covariance(pair.x, pair.y) };
    }
};

pub const WINDOW_COVAR_SAMP = struct {
    pub const window_mode: WindowMode = .tuple;
    pub fn done(
        _: *WINDOW_COVAR_SAMP,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const pair = (try tupleFloats(alloc, agg, "covar_samp")) orelse return .null;
        return .{ .float = stat.covariance(pair.x, pair.y) };
    }
};

pub const WINDOW_STDDEV_POP = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_STDDEV_POP,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const xs = (try scalarFloats(alloc, agg)) orelse return .null;
        return .{ .float = @sqrt(stat.variance(xs, true)) };
    }
};

pub const WINDOW_STDDEV_SAMP = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_STDDEV_SAMP,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const xs = (try scalarFloats(alloc, agg)) orelse return .null;
        return .{ .float = @sqrt(stat.variance(xs, false)) };
    }
};

/// Go: type WINDOW_STDDEV = WINDOW_STDDEV_SAMP.
pub const WINDOW_STDDEV = WINDOW_STDDEV_SAMP;

pub const WINDOW_VAR_POP = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_VAR_POP,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const xs = (try scalarFloats(alloc, agg)) orelse return .null;
        return .{ .float = stat.variance(xs, true) };
    }
};

pub const WINDOW_VAR_SAMP = struct {
    pub const window_mode: WindowMode = .single;
    pub fn done(
        _: *WINDOW_VAR_SAMP,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        const xs = (try scalarFloats(alloc, agg)) orelse return .null;
        return .{ .float = stat.variance(xs, false) };
    }
};

/// Go: type WINDOW_VARIANCE = WINDOW_VAR_SAMP.
pub const WINDOW_VARIANCE = WINDOW_VAR_SAMP;

// ----------------------------------------------------------------------
// PERCENTILE_CONT / PERCENTILE_DISC (Go WINDOW_PERCENTILE_*).
// ----------------------------------------------------------------------

pub const WINDOW_PERCENTILE_CONT = struct {
    pub const window_mode: WindowMode = .single;
    percentile: Value = .null,

    pub fn parseArguments(
        f: *WINDOW_PERCENTILE_CONT,
        _: std.mem.Allocator,
        args: []const Value,
    ) Error!void {
        if (args.len < 2) return bind.fail("PERCENTILE_CONT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
        f.percentile = args[1];
    }

    pub fn done(
        f: *WINDOW_PERCENTILE_CONT,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        if (try f.percentile.lt(.{ .int = 0 })) {
            return bind.fail("PERCENTILE_CONT: percentile value must be greater than zero", .{}, error.UnsupportedOperation);
        }
        if (try f.percentile.gt(.{ .int = 1 })) {
            return bind.fail("PERCENTILE_CONT: percentile value must be less than one", .{}, error.UnsupportedOperation);
        }
        const values = try agg.relevantValues();
        if (values.len == 0) return .null;

        var non_null: std.ArrayList(i64) = .empty;
        var filtered: std.ArrayList(Value) = .empty;
        for (values) |value| {
            if (value == .null) continue;
            try non_null.append(alloc, try value.toInt64());
            try filtered.append(alloc, value);
        }
        if (filtered.items.len == 0) return .null;

        const percentile = try f.percentile.toFloat64();
        std.mem.sort(i64, non_null.items, {}, std.sort.asc(i64));

        const len_f: f64 = @floatFromInt(non_null.items.len);
        const row_number = 1 + percentile * (len_f - 1);
        const floor_row = @floor(row_number);
        const ceil_row = @ceil(row_number);
        const floor_value: f64 = @floatFromInt(non_null.items[@intFromFloat(floor_row - 1)]);
        const ceil_value: f64 = @floatFromInt(non_null.items[@intFromFloat(ceil_row - 1)]);

        // Compute max/min of the filtered set (Go loops; NULLs already gone).
        var max_value = filtered.items[0];
        var min_value = filtered.items[0];
        for (filtered.items) |value| {
            if (try value.gt(max_value)) max_value = value;
            if (try value.lt(min_value)) min_value = value;
        }
        if (try max_value.eq(.{ .int = 0 })) return .{ .float = 0 };

        if (ceil_row == floor_row and ceil_row == row_number) {
            return .{ .float = floor_value };
        }
        // ceil * (row - floor) + floor * (ceil - row)
        const lo = ceil_value * (row_number - floor_row);
        const hi = floor_value * (ceil_row - row_number);
        return .{ .float = lo + hi };
    }
};

pub const WINDOW_PERCENTILE_DISC = struct {
    pub const window_mode: WindowMode = .single;
    percentile: Value = .null,

    pub fn parseArguments(
        f: *WINDOW_PERCENTILE_DISC,
        _: std.mem.Allocator,
        args: []const Value,
    ) Error!void {
        if (args.len < 2) return bind.fail("PERCENTILE_DISC: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
        f.percentile = args[1];
    }

    pub fn done(
        f: *WINDOW_PERCENTILE_DISC,
        alloc: std.mem.Allocator,
        agg: *WindowFuncAggregatedStatus,
    ) Error!Value {
        if (try f.percentile.lt(.{ .int = 0 })) {
            return bind.fail("PERCENTILE_DISC: percentile value must be greater than zero", .{}, error.UnsupportedOperation);
        }
        if (try f.percentile.gt(.{ .int = 1 })) {
            return bind.fail("PERCENTILE_DISC: percentile value must be less than one", .{}, error.UnsupportedOperation);
        }
        const relevant = try agg.relevantValues();
        if (relevant.len == 0) return .null;

        // NULLs first, then ascending. Sorted through a copy: the frame's relevant set belongs
        // to the aggregator and is shared across rows.
        const values = try alloc.dupe(Value, relevant);
        std.mem.sort(Value, values, {}, discLessThan);

        // 0 and 1 are exact, common boundaries (min/max); take them directly
        // rather than through the float ceiling below, which a percentile
        // converted from NUMERIC/BIGNUMERIC can round a hair past 1.0 and
        // walk the index one past the end of values.
        if (try f.percentile.eq(.{ .int = 0 })) return values[0];
        if (try f.percentile.eq(.{ .int = 1 })) return values[values.len - 1];

        const len: i64 = @intCast(values.len);
        const pick_point = try f.percentile.mul(alloc, .{ .int = len });
        const f_idx = try pick_point.toFloat64();
        var idx: i64 = @intFromFloat(f_idx);
        if (@as(f64, @floatFromInt(idx)) < f_idx) idx += 1;
        idx -= 1;
        const clamped: usize = @intCast(std.math.clamp(idx, 0, len - 1));
        return values[clamped];
    }
};

fn discLessThan(_: void, a: Value, b: Value) bool {
    if (a == .null) return true;
    if (b == .null) return false;
    return a.lt(b) catch false;
}

// ----------------------------------------------------------------------
// Impl-level tests (SQL-level coverage lives in window.zig)
// ----------------------------------------------------------------------

const testing = std.testing;

test "relevantValues honors ignore_nulls and distinct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var agg = WindowFuncAggregatedStatus{ .cache_alloc = alloc };
    try agg.step(alloc, .{ .int = 1 });
    try agg.step(alloc, .null);
    try agg.step(alloc, .{ .int = 1 });
    try agg.step(alloc, .{ .int = 2 });

    // Default: everything, including the NULL and the duplicate.
    try testing.expectEqual(@as(usize, 4), (try agg.relevantValues()).len);

    var opt = agg.opt;
    opt.ignore_nulls = true;
    agg.setOption(opt);
    try testing.expectEqual(@as(usize, 3), (try agg.relevantValues()).len);

    opt.distinct = true;
    agg.setOption(opt);
    // ignore_nulls + distinct -> {1, 2}
    try testing.expectEqual(@as(usize, 2), (try agg.relevantValues()).len);

    // DISTINCT alone keeps the NULL, as one group of its own.
    opt.ignore_nulls = false;
    agg.setOption(opt);
    try testing.expectEqual(@as(usize, 3), (try agg.relevantValues()).len);
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
