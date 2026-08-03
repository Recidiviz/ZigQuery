//! Port of googlesql's RANGE functions: the constructor, the two accessors,
//! the three predicates and GENERATE_RANGE_ARRAY.
//!
//! The predicates come from reference_impl/functions/range.cc, whose whole
//! trick is that an absent bound is an infinity rather than a missing value —
//! and *which* infinity depends on which end it sits at. `startLess` and
//! `endLess` below are that asymmetry, transcribed; every predicate is built
//! from them, so the unbounded cases fall out instead of being special-cased
//! per function.
//!
//! There is no go-zetasqlite counterpart to any of this: Go never had RANGE.

const std = @import("std");
const bind = @import("bind.zig");
const ops = @import("date_ops.zig");
const tu = @import("time_util.zig");
const value_mod = @import("../value.zig");

const Value = bind.Value;
const Error = bind.Error;
const Range = value_mod.Range;
const null_v = Value.null;

fn asRange(v: Value) Error!Range {
    const inner = if (v == .safe) v.safe.* else v;
    if (inner != .range)
        return bind.fail("value is not a range", .{}, error.FailedConversion);
    return inner.range;
}

/// Go IsStartLessThan: an absent *start* is -inf, so it is below everything
/// except another absent start.
fn startLess(a: ?i64, b: ?i64) bool {
    if (a == null and b == null) return false;
    if (a == null) return true;
    if (b == null) return false;
    return a.? < b.?;
}

/// Go IsEndLessThan: an absent *end* is +inf, so it is above everything except
/// another absent end. Note this is not `!startLess` with the arguments
/// swapped — the two disagree on exactly the unbounded cases.
fn endLess(a: ?i64, b: ?i64) bool {
    if (a == null and b == null) return false;
    if (a == null) return false;
    if (b == null) return true;
    return a.? < b.?;
}

fn overlaps(a: Range, b: Range) bool {
    const a_starts_before_b_ends = a.startBound() == null or b.endBound() == null or
        a.start < b.end;
    const b_starts_before_a_ends = b.startBound() == null or a.endBound() == null or
        b.start < a.end;
    return a_starts_before_b_ends and b_starts_before_a_ends;
}

// ---------------------------------------------------------------------
// Constructor and accessors
// ---------------------------------------------------------------------

/// RANGE(lower, upper). Either bound may be NULL, meaning UNBOUNDED.
pub fn range(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("RANGE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);

    const lo_kind = value_mod.rangeElementOf(args[0]);
    const hi_kind = value_mod.rangeElementOf(args[1]);
    // Both NULL leaves nothing to read the element type off. The analyzer
    // rejects two NULL *literals* here (builtin_function_range.cc's
    // pre-resolution constraint), so only two NULL columns can reach this, and
    // guessing a kind would be worse than saying so: `Unimplemented` is what
    // the spec runner counts as unsupported rather than as a wrong answer.
    const elem = lo_kind orelse hi_kind orelse {
        if (args[0] == .null and args[1] == .null) return bind.fail(
            "RANGE: cannot determine the element type when both bounds are NULL",
            .{},
            error.Unimplemented,
        );
        return bind.fail("RANGE: arguments must be DATE, DATETIME or TIMESTAMP", .{}, error.FailedConversion);
    };
    if (lo_kind != null and hi_kind != null and lo_kind.? != hi_kind.?)
        return bind.fail("RANGE: both bounds must have the same element type", .{}, error.FailedConversion);

    const lo: ?i64 = if (lo_kind == null) null else try value_mod.rangeElementScalar(args[0]);
    const hi: ?i64 = if (hi_kind == null) null else try value_mod.rangeElementScalar(args[1]);
    // googlesql Value::MakeRange, message verbatim.
    if (lo != null and hi != null and lo.? >= hi.?)
        return bind.fail(
            "Range start element must be smaller than range end element",
            .{},
            error.UnsupportedOperation,
        );
    return value_mod.rangeValue(elem, lo, hi);
}

pub fn rangeStart(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return (try asRange(args[0])).startValue();
}

pub fn rangeEnd(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return (try asRange(args[0])).endValue();
}

pub fn rangeIsStartUnbounded(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = (try asRange(args[0])).startBound() == null };
}

pub fn rangeIsEndUnbounded(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = (try asRange(args[0])).endBound() == null };
}

// ---------------------------------------------------------------------
// Predicates
// ---------------------------------------------------------------------

pub fn rangeOverlaps(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("RANGE_OVERLAPS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = overlaps(try asRange(args[0]), try asRange(args[1])) };
}

/// RANGE_CONTAINS(outer, inner) and RANGE_CONTAINS(range, element).
///
/// The two overloads are told apart by nothing more than `args[1]`'s tag: a
/// range decodes to `.range`, an element to `.date`/`.datetime`/`.timestamp`.
/// They are distinct tags in the Value union and distinct tags on the wire, so
/// the decode has already separated them by the time this runs. The only
/// ambiguous input is NULL, and `existsNull` takes it first — which is the
/// same order googlesql's Eval uses.
pub fn rangeContains(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("RANGE_CONTAINS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const outer = try asRange(args[0]);

    const inner_v = if (args[1] == .safe) args[1].safe.* else args[1];
    if (inner_v == .range) {
        const inner = inner_v.range;
        return Value{ .bool = !startLess(inner.startBound(), outer.startBound()) and
            !endLess(outer.endBound(), inner.endBound()) };
    }

    // Element overload: start <= x < end. The upper test is strict because the
    // range's upper bound is exclusive, which is why this arm uses `endLess`
    // directly where the range arm negates it.
    const x = try value_mod.rangeElementScalar(inner_v);
    return Value{ .bool = !startLess(x, outer.startBound()) and endLess(x, outer.endBound()) };
}

pub fn rangeIntersect(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("RANGE_INTERSECT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const a = try asRange(args[0]);
    const b = try asRange(args[1]);
    if (!overlaps(a, b)) {
        var abuf: [96]u8 = undefined;
        var bbuf: [96]u8 = undefined;
        return bind.fail(
            "Provided RANGE inputs: {s} and {s} do not overlap. " ++
                "Please check RANGE_OVERLAPS before calling RANGE_INTERSECT",
            .{ value_mod.formatRange(&abuf, a), value_mod.formatRange(&bbuf, b) },
            error.UnsupportedOperation,
        );
    }
    // [max(starts), min(ends))
    const start = if (startLess(a.startBound(), b.startBound())) b.startBound() else a.startBound();
    const end = if (endLess(a.endBound(), b.endBound())) a.endBound() else b.endBound();
    return value_mod.rangeValue(a.elem, start, end);
}

// ---------------------------------------------------------------------
// GENERATE_RANGE_ARRAY
// ---------------------------------------------------------------------

/// googlesql's IntervalValue is (months, days, nanos); ours is the seven
/// bigquery components. Fold once, so the per-kind validation below reads like
/// range.cc's.
const Step = struct {
    months: i64,
    days: i64,
    nanos: i128,

    fn of(iv: value_mod.Interval) Step {
        return .{
            .months = @as(i64, iv.years) * 12 + iv.months,
            .days = iv.days,
            .nanos = (@as(i128, (@as(i64, iv.hours) * 60 + iv.minutes) * 60 + iv.seconds)) *
                1_000_000_000 + iv.sub_second_nanos,
        };
    }
};

/// The three per-element-kind rules from range.cc's ValidateStep overloads,
/// messages verbatim. They differ enough that folding them into one check
/// would lose the message the user actually needs.
fn validateStep(elem: Range.ElemKind, s: Step) Error!void {
    switch (elem) {
        .date => {
            if (s.nanos != 0) return bind.fail(
                "step with non-zero (H:M:S[.F]) part is not supported",
                .{},
                error.UnsupportedOperation,
            );
            if (s.months != 0 and s.days != 0) return bind.fail(
                "step should either have the Y-M part or the DAY part",
                .{},
                error.UnsupportedOperation,
            );
            if (s.months < 0 or s.days < 0)
                return bind.fail("step cannot be negative", .{}, error.UnsupportedOperation);
            if (s.months == 0 and s.days == 0)
                return bind.fail("step cannot be 0", .{}, error.UnsupportedOperation);
        },
        .datetime => {
            if (s.months != 0 and (s.days != 0 or s.nanos != 0)) return bind.fail(
                "step should either have the Y-M part or the D (H:M:S[.F]) part",
                .{},
                error.UnsupportedOperation,
            );
            if (s.months < 0 or s.days < 0 or s.nanos < 0)
                return bind.fail("step cannot be negative", .{}, error.UnsupportedOperation);
            if (s.months == 0 and s.days == 0 and s.nanos == 0)
                return bind.fail("step cannot be 0", .{}, error.UnsupportedOperation);
        },
        .timestamp => {
            if (s.months != 0) return bind.fail(
                "step with non-zero MONTH or YEAR part is not supported",
                .{},
                error.UnsupportedOperation,
            );
            if (s.days < 0 or s.nanos < 0)
                return bind.fail("step cannot be negative", .{}, error.UnsupportedOperation);
            if (s.days == 0 and s.nanos == 0)
                return bind.fail("step cannot be 0", .{}, error.UnsupportedOperation);
        },
    }
}

/// `start` advanced by `n` steps, in the units the element kind stores.
///
/// Always computed from the original `start`, never by adding one step to the
/// previous end — that is what makes month arithmetic near the end of a month
/// come out right, and it is why googlesql carries a cumulative `current_step`
/// through its loop rather than an accumulated date.
///
/// A month step goes through `date_ops.dateAdd`, which *clamps* (Jan 31 + 1
/// month is Feb 28), matching googlesql's AddDate. `value.addCalendar` would
/// normalise the same input to Mar 3; it is the wrong helper here even though
/// it is the one the `+` operator uses.
fn advance(elem: Range.ElemKind, start: i64, s: Step, n: i64) Error!i64 {
    const day_micros = value_mod.day_micros;
    // A day is a fixed 24 hours here, exactly as absl::Hours(days) * 24 makes
    // it — the kinds that reach this have already had month steps rejected.
    const duration = s.days * day_micros + @as(i64, @intCast(@divTrunc(s.nanos, 1000)));
    return switch (elem) {
        .date => blk: {
            const bt = tu.BrokenTime{ .civ = start * day_micros };
            const part: []const u8 = if (s.months != 0) "MONTH" else "DAY";
            const amount = if (s.months != 0) s.months else s.days;
            break :blk (try ops.dateAdd(bt, amount * n, part)).days();
        },
        .datetime => blk: {
            if (s.months != 0) {
                const bt = tu.BrokenTime{ .civ = start };
                break :blk (try ops.dateAdd(bt, s.months * n, "MONTH")).civ;
            }
            break :blk start + n * duration;
        },
        // A TIMESTAMP step is a pure duration; months are rejected above.
        .timestamp => start + n * duration,
    };
}

pub fn generateRangeArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2 and args.len != 3) return bind.fail(
        "GENERATE_RANGE_ARRAY: invalid argument num {d}",
        .{args.len},
        error.UnsupportedOperation,
    );
    if (args[0] == .null or args[1] == .null) return null_v;
    const r = try asRange(args[0]);
    const iv = switch (if (args[1] == .safe) args[1].safe.* else args[1]) {
        .interval => |x| x,
        else => return bind.fail("GENERATE_RANGE_ARRAY: step must be an INTERVAL", .{}, error.FailedConversion),
    };
    const last_partial = if (args.len == 3 and args[2] != .null) try args[2].toBool() else true;

    const step = Step.of(iv);
    try validateStep(r.elem, step);
    const start = r.startBound() orelse return bind.fail(
        "input RANGE cannot have UNBOUNDED endpoints",
        .{},
        error.UnsupportedOperation,
    );
    const end = r.endBound() orelse return bind.fail(
        "input RANGE cannot have UNBOUNDED endpoints",
        .{},
        error.UnsupportedOperation,
    );

    var list: std.ArrayList(Value) = .empty;
    var n: i64 = 0;
    var current_end = start;
    while (true) {
        const current_start = current_end;
        n += 1;
        current_end = try advance(r.elem, start, step, n);
        if (current_end >= end) {
            // The final subrange is clipped to the range's own end, and kept
            // only when it lands exactly there or partials were asked for.
            if (current_end == end or last_partial)
                try list.append(alloc, value_mod.rangeValue(r.elem, current_start, end));
            break;
        }
        try list.append(alloc, value_mod.rangeValue(r.elem, current_start, current_end));
    }
    return value_mod.arrayValue(alloc, list.items);
}
