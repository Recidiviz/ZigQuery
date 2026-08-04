//! Port of the foundation array/struct functions (Go: function.go
//! ARRAY_IN/STRUCT_FIELD/ARRAY_[SAFE_]OFFSET/ARRAY_[SAFE_]ORDINAL/MAKE_ARRAY/
//! MAKE_STRUCT and function_array.go ARRAY_CONCAT/ARRAY_LENGTH, folded
//! together with their bind* wrappers).

const std = @import("std");
const bind = @import("bind.zig");
const codec = @import("../codec_binary.zig");
const encoder = @import("../encoder.zig");
const value_mod = bind.value_mod;

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

// ----------------------------------------------------------------------
// Reading one entry out of a composite.
//
// These three functions are marked `raw_args` in bind.zig, so argument 0
// arrives as the encoded bytes rather than a decoded Value and only the entry
// asked for is materialized. Everything else here still takes decoded values:
// ARRAY_CONCAT and ARRAY_LENGTH and friends read the whole composite anyway.
// ----------------------------------------------------------------------

/// The composite argument as a `CompositeRef`, or null when these bytes are not
/// one — which is not this layer's error to report. `raw_args` promises only
/// that a BLOB arrives verbatim: an INTEGER argument is still an `.int`, and a
/// BYTES value is a BLOB that is not a composite at all. Both fall through to
/// `slowValue` below, which reproduces exactly what the old path said.
fn compositeArg(v: Value, kind: codec.CompositeRef.Kind) ?codec.CompositeRef {
    const raw = switch (v) {
        .bytes => |b| b,
        else => return null,
    };
    const ref = codec.CompositeRef.init(raw) catch return null;
    return if (ref.kind == kind) ref else null;
}

/// The raw argument decoded the way it would have been without `raw_args`, for
/// the paths that fall back. Only reached when the value is not the composite
/// it was supposed to be, i.e. on the way to an error.
fn slowValue(alloc: std.mem.Allocator, v: Value) Error!Value {
    return switch (v) {
        .bytes => |b| encoder.DecodeValueBorrowing(alloc, .{ .blob = b }),
        else => v,
    };
}

/// Go bindInArray -> ARRAY_IN -> ArrayValue.Has (element-wise EQ, nil skipped).
pub fn inArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const arr = try args[1].toArray();
    for (arr.values) |elem| {
        if (elem == .null) continue;
        if (try elem.eq(args[0])) return Value{ .bool = true };
    }
    return Value{ .bool = false };
}

/// Go bindStructField -> STRUCT_FIELD (index-based field access).
///
/// The analyzer has already turned the field *name* into this index, and the
/// generated SQL emits one of these per referenced field per row — so decoding
/// the struct here cost every field on every reference. Only the field asked
/// for is decoded now; the walk to it allocates nothing.
pub fn structField(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    const st = compositeArg(args[0], .struct_) orelse {
        // Not a struct. Decode it and let toStruct say so, in the words it
        // always used.
        const sv = try (try slowValue(alloc, args[0])).toStruct();
        return outOfStructRange(idx, sv.values.len);
    };
    if (idx >= 0) {
        if (try st.at(alloc, @intCast(idx))) |v| return v;
    }
    return outOfStructRange(idx, st.count);
}

fn outOfStructRange(idx: i64, count: usize) Error!Value {
    return bind.fail(
        "struct field index {d} out of range (struct has {d} fields)",
        .{ idx, count },
        error.UnsupportedOperation,
    );
}

/// The `idx`-th element (0-based), or null when there is no such element —
/// including when argument 0 is not an array at all, which `toArray` is left to
/// report.
fn elementAt(alloc: std.mem.Allocator, arg: Value, idx: i64) Error!?Value {
    const arr = compositeArg(arg, .array) orelse {
        const a = try (try slowValue(alloc, arg)).toArray();
        if (idx < 0 or idx >= @as(i64, @intCast(a.values.len))) return null;
        return a.values[@intCast(idx)];
    };
    if (idx < 0) return null;
    return arr.at(alloc, @intCast(idx));
}

pub fn arrayAtOffset(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    return (try elementAt(alloc, args[0], idx)) orelse
        bind.fail("OFFSET({d}) is out of range", .{idx}, error.UnsupportedOperation);
}

pub fn safeArrayAtOffset(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    return (try elementAt(alloc, args[0], idx)) orelse null_v;
}

pub fn arrayAtOrdinal(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    // ORDINAL is 1-based, and ORDINAL(0) is out of range rather than the last
    // element — so the subtraction has to happen after the bound check.
    if (idx < 1) {
        return bind.fail("ORDINAL({d}) is out of range", .{idx}, error.UnsupportedOperation);
    }
    return (try elementAt(alloc, args[0], idx - 1)) orelse
        bind.fail("ORDINAL({d}) is out of range", .{idx}, error.UnsupportedOperation);
}

pub fn safeArrayAtOrdinal(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    if (idx < 1) return null_v;
    return (try elementAt(alloc, args[0], idx - 1)) orelse null_v;
}

/// Go bindArrayConcat: no args is an error, any NULL argument yields NULL.
pub fn arrayConcat(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len == 0)
        return bind.fail("ARRAY_CONCAT: required arguments", .{}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    var out: std.ArrayList(Value) = .empty;
    for (args) |arg| {
        const sub = try arg.toArray();
        try out.appendSlice(alloc, sub.values);
    }
    return value_mod.arrayValue(alloc, out.items);
}

pub fn arrayLength(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1)
        return bind.fail("ARRAY_LENGTH: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const arr = try args[0].toArray();
    return Value{ .int = @intCast(arr.values.len) };
}

/// Go bindMakeArray -> MAKE_ARRAY: keeps NULL elements as elements.
pub fn makeArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return value_mod.arrayValue(alloc, args);
}

/// Go ARRAY_TO_STRING(array, delimiter[, null_text]): joins elements' %t
/// rendering; NULL elements are dropped unless null_text is supplied.
pub fn arrayToString(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len < 2)
        return bind.fail("ARRAY_TO_STRING: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const arr = try args[0].toArray();
    const delim = try args[1].toString(alloc);
    const null_text: ?[]const u8 = if (args.len == 3) try args[2].toString(alloc) else null;
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    for (arr.values) |v| {
        const piece: []const u8 = if (v == .null) (null_text orelse continue) else try v.format(
            't',
            alloc,
        );
        if (!first) try out.appendSlice(alloc, delim);
        try out.appendSlice(alloc, piece);
        first = false;
    }
    return Value{ .string = try out.toOwnedSlice(alloc) };
}

/// Go ARRAY_REVERSE.
pub fn arrayReverse(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1)
        return bind.fail("ARRAY_REVERSE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const arr = try args[0].toArray();
    const out = try alloc.alloc(Value, arr.values.len);
    for (arr.values, 0..) |v, i| out[arr.values.len - 1 - i] = v;
    return value_mod.arrayValue(alloc, out);
}

/// Go GENERATE_ARRAY(start, end[, step=1]). Any NULL argument yields an empty
/// array (Go bindGenerateArray).
pub fn generateArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2 and args.len != 3)
        return bind.fail("GENERATE_ARRAY: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return value_mod.arrayValue(alloc, &.{});
    const start = args[0];
    const end = args[1];
    const step: Value = if (args.len == 3) args[2] else Value{ .int = 1 };
    const is_lt = try start.lte(end);
    const is_positive_step = try step.gt(Value{ .int = 0 });
    var out: std.ArrayList(Value) = .empty;
    if ((is_lt and !is_positive_step) or (!is_lt and is_positive_step))
        return value_mod.arrayValue(alloc, out.items);
    var cur = start;
    while (true) {
        try out.append(alloc, cur);
        const after = try cur.add(alloc, step);
        const cond = if (is_lt) try after.lte(end) else try after.gte(end);
        if (!cond) break;
        cur = after;
    }
    return value_mod.arrayValue(alloc, out.items);
}

/// Go bindMakeStruct -> MAKE_STRUCT: (key, value) pairs; empty keys become
/// "_field_<n>".
pub fn makeStruct(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len % 2 != 0)
        return bind.fail("MAKE_STRUCT: unexpected argument num {d}", .{args.len}, error.UnsupportedOperation);
    const n = args.len / 2;
    const keys = try alloc.alloc([]const u8, n);
    const values = try alloc.alloc(Value, n);
    for (0..n) |i| {
        // An anonymous field keeps the empty name the analyzer gave it. Go
        // substitutes "_field_<n>" because its StructValue is a map and needs a
        // distinct key; ours is an ordered pair of slices. Inventing the name
        // here also made the same construct render two ways, since a struct the
        // analyzer constant-folds never passes through this function:
        // `SELECT STRUCT(3)` kept the empty name, `SELECT STRUCT(2*v)` did not.
        keys[i] = try args[i * 2].toString(alloc);
        values[i] = args[i * 2 + 1];
    }
    return value_mod.structValue(alloc, keys, values);
}
