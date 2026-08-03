//! Port of go-zetasqlite internal/function_aggregate.go (foundation set):
//! ARRAY, ANY_VALUE, ARRAY_AGG, ARRAY_CONCAT_AGG, AVG, BIT_AND_AGG,
//! BIT_OR_AGG, BIT_XOR_AGG, COUNT, COUNT_STAR, COUNTIF, LOGICAL_AND,
//! LOGICAL_OR, MAX, MIN, STRING_AGG, SUM plus sortAggregatedValues.
//!
//! Each struct merges Go's bindX closure (argument plucking from the
//! filtered arg list) with the corresponding FN.Step/Done methods:
//!   step(self, alloc, values, opt)  — values/opt from parseAggregateOptions
//!   done(self, alloc) -> Value      — the aggregate result
//! aggregate.zig calls done() on a fresh struct when SQLite never stepped, so a
//! zero-initialized struct must produce the empty-group result: NULL for every
//! aggregate here except COUNT/COUNTIF (0) and ARRAY (`[]`, because it backs
//! `ARRAY(SELECT ...)` subqueries rather than ARRAY_AGG).
//!
//! "Nothing accumulated yet" is tracked out of band, by a `seen`/`once`/
//! `initialized` bool set inside step() *after* that impl's own NULL check —
//! which is what makes zero rows and all-NULL rows converge on NULL, as
//! BigQuery does for both. Go instead seeded the accumulator with an in-band
//! sentinel (BIT_OR -1, BIT_XOR 1) and treated a running value equal to it as
//! unset. That leaked the sentinel out of an empty group *and* silently
//! discarded a real input equal to it: BIT_OR([-1, 5]) gave 5 rather than -1,
//! BIT_XOR([1, 2, 3]) gave 1 rather than 0. Both are fixed here, a deliberate
//! divergence from go-zetasqlite.

const std = @import("std");
const bind = @import("bind.zig");
const agg_opt = @import("aggregate_option.zig");

const value_mod = bind.value_mod;
pub const Value = bind.Value;
pub const Error = bind.Error;
pub const AggregatorOption = agg_opt.AggregatorOption;

/// Go OrderedValue.
pub const OrderedValue = struct {
    order_by: []const *agg_opt.AggregateOrderBy = &.{},
    value: Value,
};

/// Go sortAggregatedValues: in-place sort by the per-row ORDER BY keys.
/// Comparison errors are swallowed exactly like Go's `_ =` discards.
///
/// Go uses sort.Slice (pdqsort), which is plain insertion sort for slices
/// shorter than 12 elements. The comparator is intentionally NOT a strict
/// weak order — Go returns isAsc for a nil (NULL) i-key even when the j-key
/// is also nil, so two NULL keys compare "less" in both directions — which
/// violates std.mem.sort's precondition. Insertion sort is well-defined for
/// any comparator and reproduces Go's observable order (e.g.
/// ARRAY_CONCAT_AGG with a NULL ORDER BY key reverses the NULL-keyed run;
/// corpus case "array_concat_agg with null in order by").
pub fn sortAggregatedValues(values: []*OrderedValue, opt: ?*const AggregatorOption) void {
    // Go: if opt != nil && len(opt.OrderBy) == 0 { return values }
    if (opt) |o| {
        if (o.order_by.len == 0) return;
    }
    if (values.len == 0) return;
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        var j: usize = i;
        while (j > 0 and orderedLessThan(values, values[j], values[j - 1])) : (j -= 1) {
            std.mem.swap(*OrderedValue, &values[j], &values[j - 1]);
        }
    }
}

fn orderedLessThan(all: []*OrderedValue, i_val: *OrderedValue, j_val: *OrderedValue) bool {
    // Go indexes values[0].OrderBy for both the loop bound and isAsc — read
    // live through the closed-over slice, so swaps made mid-sort change
    // which element is values[0]. Passing the slice preserves that.
    for (all[0].order_by, 0..) |first_order, k| {
        if (k >= i_val.order_by.len or k >= j_val.order_by.len) break;
        const iv = i_val.order_by[k].value;
        const jv = j_val.order_by[k].value;
        const is_asc = first_order.is_asc;
        // Go: iV == nil => isAsc, jV == nil => !isAsc. NULL-vs-NULL is NOT a
        // tie: ascending sorts call it "less" both ways, which makes the
        // insertion sort bubble NULL-keyed runs into reverse input order.
        if (iv == .null) return is_asc;
        if (jv == .null) return !is_asc;
        if (iv.eq(jv) catch false) continue; // break tie with subsequent fields
        if (is_asc) {
            return iv.lt(jv) catch false;
        } else {
            return iv.gt(jv) catch false;
        }
    }
    return false;
}

/// Shared Done tail for ARRAY_AGG / ARRAY_CONCAT_AGG / STRING_AGG:
/// sort + LIMIT truncation.
fn sortAndLimit(values: *std.ArrayList(*OrderedValue), opt: ?*const AggregatorOption) void {
    sortAggregatedValues(values.items, opt);
    if (opt) |o| {
        if (o.limit) |limit| {
            const min_len = @min(@as(i64, @intCast(values.items.len)), limit);
            values.items.len = @intCast(@max(min_len, 0));
        }
    }
}

// ----------------------------------------------------------------------
// ARRAY (Go type ARRAY; used by ARRAY subqueries): collects every value,
// NULLs included, no ORDER BY/LIMIT handling.
// ----------------------------------------------------------------------

pub const ARRAY = struct {
    values: std.ArrayList(Value) = .empty,

    pub fn step(f: *ARRAY, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = opt;
        if (values.len < 1) return bind.fail("ARRAY: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        try f.values.append(alloc, values[0]);
    }

    pub fn done(f: *ARRAY, alloc: std.mem.Allocator) Error!Value {
        return value_mod.arrayValue(alloc, f.values.items);
    }
};

// ----------------------------------------------------------------------
// ANY_VALUE
// ----------------------------------------------------------------------

pub const ANY_VALUE = struct {
    const Pair = struct { value: Value, having: Value };

    opt_having: ?*agg_opt.AggregateHavingModifier = null,
    once: bool = false,
    value: Value = .null,
    having_values: std.ArrayList(Pair) = .empty,

    pub fn step(f: *ANY_VALUE, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        if (values.len < 1) return bind.fail("ANY_VALUE: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        const v = values[0];
        if (v == .null) return;
        if (!f.once) {
            f.once = true;
            f.opt_having = opt.having_modifier;
        }
        if (opt.having_modifier) |having| {
            try f.having_values.append(alloc, .{ .value = v, .having = having.value });
            return;
        }
        if (f.value == .null) f.value = v;
    }

    pub fn done(f: *ANY_VALUE, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (f.opt_having != null and f.having_values.items.len > 0) {
            const kind = f.opt_having.?.kind;
            // Find the max/min having value.
            var target: Value = .null;
            for (f.having_values.items) |pair| {
                if (pair.having == .null) continue;
                if (target == .null) {
                    target = pair.having;
                    continue;
                }
                const should_update = switch (kind) {
                    .max => try pair.having.gt(target),
                    .min => try pair.having.lt(target),
                };
                if (should_update) target = pair.having;
            }
            // First value whose having value equals the target.
            if (target != .null) {
                for (f.having_values.items) |pair| {
                    if (pair.having == .null) continue;
                    if (try pair.having.eq(target)) return pair.value;
                }
            }
        }
        return f.value;
    }
};

// ----------------------------------------------------------------------
// ARRAY_AGG / ARRAY_CONCAT_AGG
// ----------------------------------------------------------------------

pub const ARRAY_AGG = struct {
    /// Set on the first row that survives the NULL check. Keyed on rather than
    /// `values.items.len` so a group of non-NULL but *empty* arrays still
    /// yields `[]` rather than NULL.
    once: bool = false,
    opt: ?*const AggregatorOption = null,
    values: std.ArrayList(*OrderedValue) = .empty,

    pub fn step(f: *ARRAY_AGG, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        if (values.len < 1) return bind.fail("ARRAY_AGG: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) {
            return bind.fail("ARRAY_AGG: input value must be not null", .{}, error.NullValue);
        }
        f.once = true;
        if (f.opt == null) f.opt = opt;
        const ov = try alloc.create(OrderedValue);
        ov.* = .{ .order_by = opt.order_by, .value = values[0] };
        try f.values.append(alloc, ov);
    }

    pub fn done(f: *ARRAY_AGG, alloc: std.mem.Allocator) Error!Value {
        // Zero rows, or every row NULL: BigQuery returns NULL, not [].
        if (!f.once) return .null;
        sortAndLimit(&f.values, f.opt);
        const out = try alloc.alloc(Value, f.values.items.len);
        for (f.values.items, 0..) |ov, i| out[i] = ov.value;
        return value_mod.arrayValue(alloc, out);
    }
};

pub const ARRAY_CONCAT_AGG = struct {
    /// Set on the first row that survives the NULL check. Keyed on rather than
    /// `values.items.len` so a group of non-NULL but *empty* arrays still
    /// yields `[]` rather than NULL.
    once: bool = false,
    opt: ?*const AggregatorOption = null,
    values: std.ArrayList(*OrderedValue) = .empty,

    pub fn step(f: *ARRAY_CONCAT_AGG, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        if (values.len < 1) return bind.fail("ARRAY_CONCAT_AGG: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        // Go bindArrayConcatAgg: NULL input rows are skipped.
        if (values[0] == .null) return;
        const arr = try values[0].toArray();
        f.once = true;
        if (f.opt == null) f.opt = opt;
        for (arr.values) |vv| {
            const ov = try alloc.create(OrderedValue);
            ov.* = .{ .order_by = opt.order_by, .value = vv };
            try f.values.append(alloc, ov);
        }
    }

    pub fn done(f: *ARRAY_CONCAT_AGG, alloc: std.mem.Allocator) Error!Value {
        // Zero rows, or every row NULL: BigQuery returns NULL, not [].
        if (!f.once) return .null;
        sortAndLimit(&f.values, f.opt);
        const out = try alloc.alloc(Value, f.values.items.len);
        for (f.values.items, 0..) |ov, i| out[i] = ov.value;
        return value_mod.arrayValue(alloc, out);
    }
};

// ----------------------------------------------------------------------
// AVG / SUM
// ----------------------------------------------------------------------

pub const AVG = struct {
    sum: Value = .null,
    num: i64 = 0,

    pub fn step(f: *AVG, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = opt;
        if (values.len < 1) return bind.fail("AVG: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        const v = values[0];
        if (v == .null) return;
        f.sum = if (f.sum == .null) v else try f.sum.add(alloc, v);
        f.num += 1;
    }

    pub fn done(f: *AVG, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (f.sum == .null) return .null;
        const base = try f.sum.toFloat64();
        return .{ .float = base / @as(f64, @floatFromInt(f.num)) };
    }
};

pub const SUM = struct {
    sum: Value = .null,

    pub fn step(f: *SUM, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = opt;
        if (values.len < 1) return bind.fail("SUM: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        const v = values[0];
        if (v == .null) return;
        f.sum = if (f.sum == .null) v else try f.sum.add(alloc, v);
    }

    pub fn done(f: *SUM, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        return f.sum;
    }
};

// ----------------------------------------------------------------------
// BIT_AND_AGG / BIT_OR_AGG / BIT_XOR_AGG (Go sentinel initializers kept
// bug-for-bug: empty groups yield -1 / -1 / 1, and a leading -1 (OR) or
// 1 (XOR) input is treated as "unset").
// ----------------------------------------------------------------------

pub const BIT_AND_AGG = struct {
    seen: bool = false,
    value: i64 = -1, // the AND identity (all bits set)

    pub fn step(f: *BIT_AND_AGG, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = alloc;
        _ = opt;
        if (values.len < 1) return bind.fail("BIT_AND: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) return;
        f.seen = true;
        f.value &= try values[0].toInt64();
    }

    pub fn done(f: *BIT_AND_AGG, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (!f.seen) return .null;
        return .{ .int = f.value };
    }
};

pub const BIT_OR_AGG = struct {
    seen: bool = false,
    value: i64 = 0, // the OR identity, now that "unset" is out of band

    pub fn step(f: *BIT_OR_AGG, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = alloc;
        _ = opt;
        if (values.len < 1) return bind.fail("BIT_OR: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) return;
        f.seen = true;
        f.value |= try values[0].toInt64();
    }

    pub fn done(f: *BIT_OR_AGG, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (!f.seen) return .null;
        return .{ .int = f.value };
    }
};

pub const BIT_XOR_AGG = struct {
    seen: bool = false,
    value: i64 = 0, // the XOR identity

    pub fn step(f: *BIT_XOR_AGG, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = alloc;
        _ = opt;
        if (values.len < 1) return bind.fail("BIT_XOR: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) return;
        f.seen = true;
        f.value ^= try values[0].toInt64();
    }

    pub fn done(f: *BIT_XOR_AGG, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (!f.seen) return .null;
        return .{ .int = f.value };
    }
};

// ----------------------------------------------------------------------
// COUNT / COUNT_STAR / COUNTIF
// ----------------------------------------------------------------------

pub const COUNT = struct {
    count: Value = .null,

    pub fn step(f: *COUNT, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = opt;
        if (values.len < 1) return bind.fail("COUNT: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) return;
        f.count = if (f.count == .null)
            .{ .int = 1 }
        else
            try f.count.add(alloc, .{ .int = 1 });
    }

    pub fn done(f: *COUNT, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (f.count == .null) return .{ .int = 0 };
        return f.count;
    }
};

pub const COUNT_STAR = struct {
    count: i64 = 0,

    pub fn step(f: *COUNT_STAR, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = alloc;
        _ = values;
        _ = opt;
        f.count += 1;
    }

    pub fn done(f: *COUNT_STAR, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        return .{ .int = f.count };
    }
};

pub const COUNTIF = struct {
    count: Value = .null,

    pub fn step(f: *COUNTIF, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = opt;
        if (values.len < 1) return bind.fail("COUNTIF: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) return;
        if (try values[0].toBool()) {
            f.count = if (f.count == .null)
                .{ .int = 1 }
            else
                try f.count.add(alloc, .{ .int = 1 });
        }
    }

    pub fn done(f: *COUNTIF, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (f.count == .null) return .{ .int = 0 };
        return f.count;
    }
};

// ----------------------------------------------------------------------
// LOGICAL_AND / LOGICAL_OR (Go returns the running bool even for empty /
// all-NULL groups: true for AND, false for OR).
// ----------------------------------------------------------------------

pub const LOGICAL_AND = struct {
    seen: bool = false,
    v: bool = true, // the AND identity

    pub fn step(f: *LOGICAL_AND, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = alloc;
        _ = opt;
        if (values.len < 1) return bind.fail("LOGICAL_AND: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) return;
        f.seen = true;
        if (!(try values[0].toBool())) f.v = false;
    }

    pub fn done(f: *LOGICAL_AND, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (!f.seen) return .null;
        return .{ .bool = f.v };
    }
};

pub const LOGICAL_OR = struct {
    seen: bool = false,
    v: bool = false, // the OR identity

    pub fn step(f: *LOGICAL_OR, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = alloc;
        _ = opt;
        if (values.len < 1) return bind.fail("LOGICAL_OR: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) return;
        f.seen = true;
        if (try values[0].toBool()) f.v = true;
    }

    pub fn done(f: *LOGICAL_OR, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        if (!f.seen) return .null;
        return .{ .bool = f.v };
    }
};

// ----------------------------------------------------------------------
// MAX / MIN
// ----------------------------------------------------------------------

pub const MAX = struct {
    initialized: bool = false,
    max: Value = .null,

    pub fn step(f: *MAX, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = alloc;
        _ = opt;
        if (values.len < 1) return bind.fail("MAX: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        const v = values[0];
        if (v == .null) return;
        if (f.initialized) {
            if (try v.gt(f.max)) f.max = v;
        } else {
            f.max = v;
            f.initialized = true;
        }
    }

    pub fn done(f: *MAX, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        return f.max;
    }
};

pub const MIN = struct {
    initialized: bool = false,
    min: Value = .null,

    pub fn step(f: *MIN, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        _ = alloc;
        _ = opt;
        if (values.len < 1) return bind.fail("MIN: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        const v = values[0];
        if (v == .null) return;
        if (f.initialized) {
            if (try v.lt(f.min)) f.min = v;
        } else {
            f.min = v;
            f.initialized = true;
        }
    }

    pub fn done(f: *MIN, alloc: std.mem.Allocator) Error!Value {
        _ = alloc;
        return f.min;
    }
};

// ----------------------------------------------------------------------
// STRING_AGG
// ----------------------------------------------------------------------

pub const STRING_AGG = struct {
    once: bool = false,
    delim: []const u8 = "",
    opt: ?*const AggregatorOption = null,
    values: std.ArrayList(*OrderedValue) = .empty,

    pub fn step(f: *STRING_AGG, alloc: std.mem.Allocator, values: []const Value, opt: *const AggregatorOption) Error!void {
        if (values.len < 1) return bind.fail("STRING_AGG: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        // Go bindStringAgg: 1 arg -> delim "", else delim = args[1].ToString().
        var delim: []const u8 = "";
        if (values.len > 1) delim = try values[1].toString(alloc);
        const v = values[0];
        if (v == .null) return;
        if (!f.once) {
            f.once = true;
            f.delim = if (delim.len == 0) "," else delim;
            f.opt = opt;
        }
        const ov = try alloc.create(OrderedValue);
        ov.* = .{ .order_by = opt.order_by, .value = v };
        try f.values.append(alloc, ov);
    }

    pub fn done(f: *STRING_AGG, alloc: std.mem.Allocator) Error!Value {
        sortAndLimit(&f.values, f.opt);
        if (f.values.items.len == 0) return .null; // Go foundNotNilValue
        var out: std.ArrayList(u8) = .empty;
        for (f.values.items, 0..) |ov, i| {
            if (i > 0) try out.appendSlice(alloc, f.delim);
            try out.appendSlice(alloc, try ov.value.toString(alloc));
        }
        return .{ .string = try out.toOwnedSlice(alloc) };
    }
};

// ----------------------------------------------------------------------
// Statistical aggregates (Go CORR / COVAR / STDDEV / VAR). These mirror the
// gonum/stat maths used by the window variants (see fn_window.zig stat).
// ----------------------------------------------------------------------

fn statMean(x: []const f64) f64 {
    var sum: f64 = 0;
    for (x) |v| sum += v;
    return sum / @as(f64, @floatFromInt(x.len));
}

fn statVariance(x: []const f64, population: bool) f64 {
    const m = statMean(x);
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

fn statCovariance(x: []const f64, y: []const f64) f64 {
    const mx = statMean(x);
    const my = statMean(y);
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

fn statCorrelation(x: []const f64, y: []const f64) f64 {
    const mx = statMean(x);
    const my = statMean(y);
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

/// Shared two-column collector for CORR / COVAR_POP / COVAR_SAMP.
const PairStat = struct {
    x: std.ArrayList(f64) = .empty,
    y: std.ArrayList(f64) = .empty,

    fn stepPair(f: *PairStat, alloc: std.mem.Allocator, values: []const Value) Error!void {
        if (values.len < 2) return bind.fail("statistical aggregate: must provide both x and y values", .{}, error.UnsupportedOperation);
        if (values[0] == .null or values[1] == .null) return;
        try f.x.append(alloc, try values[0].toFloat64());
        try f.y.append(alloc, try values[1].toFloat64());
    }
};

pub const CORR = struct {
    inner: PairStat = .{},
    pub fn step(f: *CORR, alloc: std.mem.Allocator, values: []const Value, _: *const AggregatorOption) Error!void {
        try f.inner.stepPair(alloc, values);
    }
    pub fn done(f: *CORR, _: std.mem.Allocator) Error!Value {
        if (f.inner.x.items.len == 0) return .null;
        return .{ .float = statCorrelation(f.inner.x.items, f.inner.y.items) };
    }
};

pub const COVAR_POP = struct {
    inner: PairStat = .{},
    pub fn step(f: *COVAR_POP, alloc: std.mem.Allocator, values: []const Value, _: *const AggregatorOption) Error!void {
        try f.inner.stepPair(alloc, values);
    }
    pub fn done(f: *COVAR_POP, _: std.mem.Allocator) Error!Value {
        if (f.inner.x.items.len == 0) return .null;
        return .{ .float = statCovariance(f.inner.x.items, f.inner.y.items) };
    }
};

pub const COVAR_SAMP = struct {
    inner: PairStat = .{},
    pub fn step(f: *COVAR_SAMP, alloc: std.mem.Allocator, values: []const Value, _: *const AggregatorOption) Error!void {
        try f.inner.stepPair(alloc, values);
    }
    pub fn done(f: *COVAR_SAMP, _: std.mem.Allocator) Error!Value {
        if (f.inner.x.items.len == 0) return .null;
        return .{ .float = statCovariance(f.inner.x.items, f.inner.y.items) };
    }
};

/// Single-column variance/stddev family. `population` divides by n; otherwise
/// n-1 (Go: STDDEV/VARIANCE alias the *_SAMP variants).
fn VarStat(comptime is_stddev: bool, comptime population: bool) type {
    return struct {
        v: std.ArrayList(f64) = .empty,
        pub fn step(f: *@This(), alloc: std.mem.Allocator, values: []const Value, _: *const AggregatorOption) Error!void {
            if (values.len < 1) return bind.fail("statistical aggregate: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
            if (values[0] == .null) return;
            try f.v.append(alloc, try values[0].toFloat64());
        }
        pub fn done(f: *@This(), _: std.mem.Allocator) Error!Value {
            if (f.v.items.len == 0) return .null;
            const variance = statVariance(f.v.items, population);
            return .{ .float = if (is_stddev) @sqrt(variance) else variance };
        }
    };
}

pub const STDDEV_POP = VarStat(true, true);
pub const STDDEV_SAMP = VarStat(true, false);
pub const STDDEV = STDDEV_SAMP;
pub const VAR_POP = VarStat(false, true);
pub const VAR_SAMP = VarStat(false, false);
pub const VARIANCE = VAR_SAMP;

// ----------------------------------------------------------------------
// Approximate aggregates (Go APPROX_*). These are exact implementations over
// the aggregate framework (not real sketches).
// ----------------------------------------------------------------------

pub const APPROX_COUNT_DISTINCT = struct {
    seen: std.StringHashMapUnmanaged(void) = .empty,

    pub fn step(f: *APPROX_COUNT_DISTINCT, alloc: std.mem.Allocator, values: []const Value, _: *const AggregatorOption) Error!void {
        if (values.len < 1) return bind.fail("APPROX_COUNT_DISTINCT: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (values[0] == .null) return;
        const key = try values[0].toString(alloc);
        _ = try f.seen.getOrPut(alloc, key);
    }
    pub fn done(f: *APPROX_COUNT_DISTINCT, _: std.mem.Allocator) Error!Value {
        return .{ .int = @intCast(f.seen.count()) };
    }
};

pub const APPROX_QUANTILES = struct {
    once: bool = false,
    num: i64 = 0,
    values: std.ArrayList(Value) = .empty,

    pub fn step(f: *APPROX_QUANTILES, alloc: std.mem.Allocator, values: []const Value, _: *const AggregatorOption) Error!void {
        if (values.len < 2) return bind.fail("APPROX_QUANTILES: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (!f.once) {
            f.once = true;
            f.num = try values[1].toInt64();
        }
        try f.values.append(alloc, values[0]);
    }
    pub fn done(f: *APPROX_QUANTILES, alloc: std.mem.Allocator) Error!Value {
        const items = f.values.items;
        if (items.len == 0) return .null;
        if (f.num == 0) return value_mod.arrayValue(alloc, &.{items[0]});
        if (f.num == 1) return value_mod.arrayValue(alloc, &.{ items[0], items[items.len - 1] });

        const ratio = @as(f64, 100) / @as(f64, @floatFromInt(f.num));
        const length: f64 = @floatFromInt(items.len);
        var quantiles: std.ArrayList(Value) = .empty;
        var i: f64 = 0;
        while (i < 100) : (i += ratio) {
            const f_idx = length * (i / 100);
            var idx: i64 = @intFromFloat(f_idx);
            if (@as(f64, @floatFromInt(idx)) < f_idx) idx += 1;
            if (idx > 0) {
                try quantiles.append(alloc, items[@intCast(idx - 1)]);
            } else {
                try quantiles.append(alloc, items[@intCast(idx)]);
            }
        }
        try quantiles.append(alloc, items[items.len - 1]);
        return value_mod.arrayValue(alloc, quantiles.items);
    }
};

/// Shared insertion-ordered value->accumulator map for APPROX_TOP_COUNT/SUM.
const TopEntry = struct { key: Value, acc: Value, idx: usize };

fn topKey(alloc: std.mem.Allocator, v: Value) Error![]const u8 {
    if (v == .null) return "\x00null";
    // Prefix non-null keys so they cannot collide with the null sentinel.
    return std.fmt.allocPrint(alloc, "v{s}", .{try v.toString(alloc)});
}

fn topLessThan(_: void, a: TopEntry, b: TopEntry) bool {
    // Descending by accumulator; NULL accumulators sort last; ties keep
    // insertion order via idx.
    if (a.acc == .null and b.acc == .null) return a.idx < b.idx;
    if (a.acc == .null) return false;
    if (b.acc == .null) return true;
    if (a.acc.gt(b.acc) catch false) return true;
    if (b.acc.gt(a.acc) catch false) return false;
    return a.idx < b.idx;
}

pub const APPROX_TOP_COUNT = struct {
    once: bool = false,
    num: i64 = 0,
    map: std.StringHashMapUnmanaged(usize) = .empty,
    entries: std.ArrayList(TopEntry) = .empty,

    pub fn step(f: *APPROX_TOP_COUNT, alloc: std.mem.Allocator, values: []const Value, _: *const AggregatorOption) Error!void {
        if (values.len < 2) return bind.fail("APPROX_TOP_COUNT: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (!f.once) {
            f.once = true;
            f.num = try values[1].toInt64();
        }
        const key = try topKey(alloc, values[0]);
        const gop = try f.map.getOrPut(alloc, key);
        if (gop.found_existing) {
            const e = &f.entries.items[gop.value_ptr.*];
            e.acc = .{ .int = (try e.acc.toInt64()) + 1 };
        } else {
            gop.value_ptr.* = f.entries.items.len;
            try f.entries.append(alloc, .{ .key = values[0], .acc = .{ .int = 1 }, .idx = f.entries.items.len });
        }
    }
    pub fn done(f: *APPROX_TOP_COUNT, alloc: std.mem.Allocator) Error!Value {
        return topDone(alloc, f.entries.items, f.num, "count", "APPROX_TOP_COUNT");
    }
};

pub const APPROX_TOP_SUM = struct {
    once: bool = false,
    num: i64 = 0,
    map: std.StringHashMapUnmanaged(usize) = .empty,
    entries: std.ArrayList(TopEntry) = .empty,

    pub fn step(f: *APPROX_TOP_SUM, alloc: std.mem.Allocator, values: []const Value, _: *const AggregatorOption) Error!void {
        if (values.len < 3) return bind.fail("APPROX_TOP_SUM: invalid argument num {d}", .{values.len}, error.UnsupportedOperation);
        if (!f.once) {
            f.once = true;
            f.num = try values[2].toInt64();
        }
        const weight = values[1];
        const key = try topKey(alloc, values[0]);
        const gop = try f.map.getOrPut(alloc, key);
        if (gop.found_existing) {
            const e = &f.entries.items[gop.value_ptr.*];
            if (weight != .null) {
                e.acc = if (e.acc == .null) weight else try e.acc.add(alloc, weight);
            }
        } else {
            gop.value_ptr.* = f.entries.items.len;
            try f.entries.append(alloc, .{ .key = values[0], .acc = weight, .idx = f.entries.items.len });
        }
    }
    pub fn done(f: *APPROX_TOP_SUM, alloc: std.mem.Allocator) Error!Value {
        return topDone(alloc, f.entries.items, f.num, "sum", "APPROX_TOP_SUM");
    }
};

fn topDone(alloc: std.mem.Allocator, entries: []TopEntry, num: i64, comptime acc_key: []const u8, comptime name: []const u8) Error!Value {
    if (entries.len == 0) return .null;
    if (@as(i64, @intCast(entries.len)) < num) {
        return bind.fail(name ++ ": required number is larger than number of input values", .{}, error.UnsupportedOperation);
    }
    std.mem.sort(TopEntry, entries, {}, topLessThan);
    const take: usize = @intCast(num);
    const out = try alloc.alloc(Value, take);
    for (entries[0..take], 0..) |e, i| {
        out[i] = try value_mod.structValue(alloc, &.{ "value", acc_key }, &.{ e.key, e.acc });
    }
    return value_mod.arrayValue(alloc, out);
}

// ----------------------------------------------------------------------
// Tests (impl-level; SQL-level coverage lives in aggregate.zig)
// ----------------------------------------------------------------------

const testing = std.testing;

test "sortAggregatedValues orders by per-row keys with NULLs first/last" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const no_opt = AggregatorOption{};
    var with_order = AggregatorOption{};
    const dummy = try alloc.create(agg_opt.AggregateOrderBy);
    dummy.* = .{ .value = .null, .is_asc = true };
    const order_slice = try alloc.alloc(*agg_opt.AggregateOrderBy, 1);
    order_slice[0] = dummy;
    with_order.order_by = order_slice;

    var items: [4]*OrderedValue = undefined;
    const keys = [_]Value{ .{ .int = 2 }, .null, .{ .int = 3 }, .{ .int = 1 } };
    for (keys, 0..) |k, i| {
        const ob = try alloc.create(agg_opt.AggregateOrderBy);
        ob.* = .{ .value = k, .is_asc = true };
        const obs = try alloc.alloc(*agg_opt.AggregateOrderBy, 1);
        obs[0] = ob;
        const ov = try alloc.create(OrderedValue);
        ov.* = .{ .order_by = obs, .value = .{ .int = @intCast(i) } };
        items[i] = ov;
    }

    // With empty opt.order_by the input order is preserved.
    var copy = items;
    sortAggregatedValues(&copy, &no_opt);
    try testing.expectEqual(@as(i64, 0), copy[0].value.int);

    sortAggregatedValues(&items, &with_order);
    // NULL key first for ascending, then 1, 2, 3.
    try testing.expect(items[0].order_by[0].value == .null);
    try testing.expectEqual(@as(i64, 1), items[1].order_by[0].value.int);
    try testing.expectEqual(@as(i64, 2), items[2].order_by[0].value.int);
    try testing.expectEqual(@as(i64, 3), items[3].order_by[0].value.int);
}

test "an empty group is NULL for every aggregate but COUNT and ARRAY" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sum = SUM{};
    try value_mod.expectValueEqual(.null, try sum.done(alloc));
    var avg = AVG{};
    try value_mod.expectValueEqual(.null, try avg.done(alloc));
    var max = MAX{};
    try value_mod.expectValueEqual(.null, try max.done(alloc));
    var min = MIN{};
    try value_mod.expectValueEqual(.null, try min.done(alloc));
    var count = COUNT{};
    try value_mod.expectValueEqual(.{ .int = 0 }, try count.done(alloc));
    var countif = COUNTIF{};
    try value_mod.expectValueEqual(.{ .int = 0 }, try countif.done(alloc));
    var count_star = COUNT_STAR{};
    try value_mod.expectValueEqual(.{ .int = 0 }, try count_star.done(alloc));
    // These six returned Go's sentinels (true/false/-1/-1/1/[]) until the
    // "unset" marker moved out of band; BigQuery returns NULL for all of them.
    var land = LOGICAL_AND{};
    try value_mod.expectValueEqual(.null, try land.done(alloc));
    var lor = LOGICAL_OR{};
    try value_mod.expectValueEqual(.null, try lor.done(alloc));
    var band = BIT_AND_AGG{};
    try value_mod.expectValueEqual(.null, try band.done(alloc));
    var bor = BIT_OR_AGG{};
    try value_mod.expectValueEqual(.null, try bor.done(alloc));
    var bxor = BIT_XOR_AGG{};
    try value_mod.expectValueEqual(.null, try bxor.done(alloc));
    var array_agg = ARRAY_AGG{};
    try value_mod.expectValueEqual(.null, try array_agg.done(alloc));
    var array_concat = ARRAY_CONCAT_AGG{};
    try value_mod.expectValueEqual(.null, try array_concat.done(alloc));
    var string_agg = STRING_AGG{};
    try value_mod.expectValueEqual(.null, try string_agg.done(alloc));
    var any_value = ANY_VALUE{};
    try value_mod.expectValueEqual(.null, try any_value.done(alloc));

    // ARRAY is not ARRAY_AGG: it backs `ARRAY(SELECT ...)`, where zero rows
    // really is an empty array.
    var array = ARRAY{};
    const arr = try array.done(alloc);
    try testing.expectEqual(@as(usize, 0), arr.array.values.len);
}

test "the bit aggregates combine values that used to alias the sentinel" {
    // Go seeded BIT_OR with -1 and BIT_XOR with 1 and treated a running value
    // equal to the seed as "unset", so a real input equal to it was dropped.
    // BigQuery: BIT_OR([-1,5]) = -1, BIT_XOR([1,4]) = 5, BIT_XOR([1,1]) = 0,
    // BIT_XOR([1,2,3]) = 0.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const opt = AggregatorOption{};

    var bor = BIT_OR_AGG{};
    for ([_]i64{ -1, 5 }) |v| try bor.step(alloc, &.{.{ .int = v }}, &opt);
    try value_mod.expectValueEqual(.{ .int = -1 }, try bor.done(alloc));

    var x1 = BIT_XOR_AGG{};
    for ([_]i64{ 1, 4 }) |v| try x1.step(alloc, &.{.{ .int = v }}, &opt);
    try value_mod.expectValueEqual(.{ .int = 5 }, try x1.done(alloc));

    var x2 = BIT_XOR_AGG{};
    for ([_]i64{ 1, 1 }) |v| try x2.step(alloc, &.{.{ .int = v }}, &opt);
    try value_mod.expectValueEqual(.{ .int = 0 }, try x2.done(alloc));

    var x3 = BIT_XOR_AGG{};
    for ([_]i64{ 1, 2, 3 }) |v| try x3.step(alloc, &.{.{ .int = v }}, &opt);
    try value_mod.expectValueEqual(.{ .int = 0 }, try x3.done(alloc));

    // BIT_AND's seed is the genuine identity, so it never had the aliasing bug.
    var band = BIT_AND_AGG{};
    for ([_]i64{ -1, 6 }) |v| try band.step(alloc, &.{.{ .int = v }}, &opt);
    try value_mod.expectValueEqual(.{ .int = 6 }, try band.done(alloc));
}

test "all-NULL input is NULL, and an empty array input is still an empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const opt = AggregatorOption{};

    // Reaches done() by a different route than the empty group: step runs but
    // returns early. BigQuery gives NULL for both.
    var bor = BIT_OR_AGG{};
    try bor.step(alloc, &.{.null}, &opt);
    try bor.step(alloc, &.{.null}, &opt);
    try value_mod.expectValueEqual(.null, try bor.done(alloc));

    var land = LOGICAL_AND{};
    try land.step(alloc, &.{.null}, &opt);
    try value_mod.expectValueEqual(.null, try land.done(alloc));

    // One non-NULL but EMPTY array must still yield [], not NULL — which is why
    // the guard keys on `once` rather than on the collected length.
    var concat = ARRAY_CONCAT_AGG{};
    try concat.step(alloc, &.{try value_mod.arrayValue(alloc, &.{})}, &opt);
    const out = try concat.done(alloc);
    try testing.expectEqual(@as(usize, 0), out.array.values.len);
}

test "SUM keeps int typing; AVG divides as float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const opt = AggregatorOption{};

    var sum = SUM{};
    try sum.step(alloc, &.{.{ .int = 1 }}, &opt);
    try sum.step(alloc, &.{.null}, &opt);
    try sum.step(alloc, &.{.{ .int = 2 }}, &opt);
    try value_mod.expectValueEqual(.{ .int = 3 }, try sum.done(alloc));

    var fsum = SUM{};
    try fsum.step(alloc, &.{.{ .float = 1.5 }}, &opt);
    try fsum.step(alloc, &.{.{ .int = 2 }}, &opt);
    try value_mod.expectValueEqual(.{ .float = 3.5 }, try fsum.done(alloc));

    var avg = AVG{};
    try avg.step(alloc, &.{.{ .int = 1 }}, &opt);
    try avg.step(alloc, &.{.{ .int = 2 }}, &opt);
    try avg.step(alloc, &.{.null}, &opt);
    try value_mod.expectValueEqual(.{ .float = 1.5 }, try avg.done(alloc));
}

test "ANY_VALUE having max/min selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var opt = AggregatorOption{};
    const modifier = try alloc.create(agg_opt.AggregateHavingModifier);
    modifier.* = .{ .kind = .max, .value = .null };
    opt.having_modifier = modifier;

    var f = ANY_VALUE{};
    modifier.value = .{ .int = 10 };
    try f.step(alloc, &.{.{ .string = "ten" }}, &opt);
    modifier.value = .{ .int = 30 };
    try f.step(alloc, &.{.{ .string = "thirty" }}, &opt);
    modifier.value = .{ .int = 20 };
    try f.step(alloc, &.{.{ .string = "twenty" }}, &opt);
    try value_mod.expectValueEqual(.{ .string = "thirty" }, try f.done(alloc));
}
