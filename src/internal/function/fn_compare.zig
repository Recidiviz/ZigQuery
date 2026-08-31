//! Port of the comparison / logical / conditional functions
//! (Go: function.go EQ/NOT_EQ/GT/GTE/LT/LTE/LIKE/BETWEEN/IN/IS_*/NOT/AND/OR/
//! COALESCE/IF/IFNULL/NULLIF/IS_[NOT_]DISTINCT_FROM plus their bind* wrappers).

const std = @import("std");
const bind = @import("bind.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

pub fn equal(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = try args[0].eq(args[1]) };
}

/// Go GREATEST: max via GT; any NULL argument yields NULL.
pub fn greatest(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    var max = args[0];
    for (args[1..]) |arg| {
        if (try arg.gt(max)) max = arg;
    }
    return max;
}

/// Go LEAST: min via LT; any NULL argument yields NULL.
pub fn least(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    var min = args[0];
    for (args[1..]) |arg| {
        if (try arg.lt(min)) min = arg;
    }
    return min;
}

pub fn notEqual(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = !try args[0].eq(args[1]) };
}

pub fn greater(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = try args[0].gt(args[1]) };
}

pub fn greaterOrEqual(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = try args[0].gte(args[1]) };
}

pub fn less(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = try args[0].lt(args[1]) };
}

pub fn lessOrEqual(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = try args[0].lte(args[1]) };
}

/// Go IS_DISTINCT_FROM: NULLs compare as equal to each other only.
pub fn isDistinctFrom(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args[0] == .null or args[1] == .null) {
        const both_null = args[0] == .null and args[1] == .null;
        return Value{ .bool = !both_null };
    }
    return Value{ .bool = !try args[0].eq(args[1]) };
}

pub fn isNotDistinctFrom(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args[0] == .null or args[1] == .null) {
        return Value{ .bool = args[0] == .null and args[1] == .null };
    }
    return Value{ .bool = try args[0].eq(args[1]) };
}

// ---------------------------------------------------------------------
// LIKE. Go builds ^QuoteMeta(pattern)$ with "%" -> ".*": only '%' is a
// wildcard ('_' is literal!). Hand-rolled greedy segment matching is
// equivalent to the anchored ".*" regex.
// ---------------------------------------------------------------------

pub fn like(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const va = try args[0].toString(alloc);
    const vb = try args[1].toString(alloc);
    return Value{ .bool = try likeMatch(alloc, va, vb) };
}

fn likeMatch(alloc: std.mem.Allocator, s: []const u8, pattern: []const u8) Error!bool {
    if (std.mem.indexOfScalar(u8, pattern, '%') == null)
        return std.mem.eql(u8, s, pattern);

    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(alloc);
    var it = std.mem.splitScalar(u8, pattern, '%');
    while (it.next()) |seg| try segs.append(alloc, seg);

    const first = segs.items[0];
    const last = segs.items[segs.items.len - 1];
    if (!std.mem.startsWith(u8, s, first)) return false;
    if (!std.mem.endsWith(u8, s, last)) return false;

    var pos: usize = first.len;
    for (segs.items[1 .. segs.items.len - 1]) |seg| {
        const idx = std.mem.indexOfPos(u8, s, pos, seg) orelse return false;
        pos = idx + seg.len;
    }
    // The suffix segment must not overlap what earlier segments consumed.
    return s.len - last.len >= pos;
}

// ---------------------------------------------------------------------
// BETWEEN / IN
// ---------------------------------------------------------------------

/// `x BETWEEN lo AND hi` is `x >= lo AND x <= hi` under three-valued logic: a
/// FALSE from either bound wins over a NULL from the other.
/// operators.md#comparison_operators
pub fn between(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args[0] == .null) return null_v;
    const ge_start: ?bool = if (args[1] == .null) null else try args[0].gte(args[1]);
    const le_end: ?bool = if (args[2] == .null) null else try args[0].lte(args[2]);
    if (ge_start == false or le_end == false) return Value{ .bool = false };
    if (ge_start == null or le_end == null) return null_v;
    return Value{ .bool = true };
}

/// A NULL list element is an unknown value: it blocks a FALSE but never a TRUE.
/// operators.md#in_operators
pub fn in(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args[0] == .null) return null_v;
    var saw_null = false;
    for (args[1..]) |v| {
        if (v == .null) {
            saw_null = true;
            continue;
        }
        if (try args[0].eq(v)) return Value{ .bool = true };
    }
    if (saw_null) return null_v;
    return Value{ .bool = false };
}

// ---------------------------------------------------------------------
// IS NULL / IS TRUE / IS FALSE / NOT / AND / OR
// ---------------------------------------------------------------------

pub fn isNull(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    return Value{ .bool = args[0] == .null };
}

// IS TRUE / IS FALSE are null-safe: unlike a plain comparison, NULL never propagates through them.
// `NULL IS TRUE` and `NULL IS FALSE` are both false, not NULL.
pub fn isTrue(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args[0] == .null) return Value{ .bool = false };
    return Value{ .bool = try args[0].toBool() };
}

pub fn isFalse(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args[0] == .null) return Value{ .bool = false };
    return Value{ .bool = !try args[0].toBool() };
}

/// Go NOT coerces through ToInt64, not ToBool.
pub fn not(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = (try args[0].toInt64()) == 0 };
}

/// Go AND: false wins over NULL; all-true only when no NULL present.
pub fn @"and"(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    for (args) |v| {
        if (v == .null) continue;
        if (!try v.toBool()) return Value{ .bool = false };
    }
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = true };
}

/// Go OR: true wins over NULL; all-false only when no NULL present.
pub fn @"or"(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    for (args) |v| {
        if (v == .null) continue;
        if (try v.toBool()) return Value{ .bool = true };
    }
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = false };
}

// ---------------------------------------------------------------------
// COALESCE / IF / IFNULL / NULLIF
// ---------------------------------------------------------------------

pub fn coalesce(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len == 0)
        return bind.fail("COALESCE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    for (args) |arg| {
        if (arg == .null) continue;
        return arg;
    }
    return null_v;
}

/// Go IF: NULL condition selects the false branch.
pub fn @"if"(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 3)
        return bind.fail("IF: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (args[0] == .null) return args[2];
    return if (try args[0].toBool()) args[1] else args[2];
}

pub fn ifnull(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("IFNULL: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (args[0] == .null) return args[1];
    return args[0];
}

pub fn nullif(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("NULLIF: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (args[0] == .null) return null_v;
    if (try args[0].eq(args[1])) return null_v;
    return args[0];
}
