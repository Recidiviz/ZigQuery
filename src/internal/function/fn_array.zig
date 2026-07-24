//! Port of the foundation array/struct functions (Go: function.go
//! ARRAY_IN/STRUCT_FIELD/ARRAY_[SAFE_]OFFSET/ARRAY_[SAFE_]ORDINAL/MAKE_ARRAY/
//! MAKE_STRUCT and function_array.go ARRAY_CONCAT/ARRAY_LENGTH, folded
//! together with their bind* wrappers).

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = bind.value_mod;

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

/// Go bindInArray -> ARRAY_IN -> ArrayValue.Has (element-wise EQ, nil skipped).
pub fn inArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const arr = try args[1].toArray();
    for (arr.values) |elem| {
        if (elem == .@"null") continue;
        if (try elem.eq(args[0])) return Value{ .bool = true };
    }
    return Value{ .bool = false };
}

/// Go bindStructField -> STRUCT_FIELD (index-based field access).
pub fn structField(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    const sv = try args[0].toStruct();
    if (idx < 0 or idx >= @as(i64, @intCast(sv.values.len)))
        return bind.fail(
            "struct field index {d} out of range (struct has {d} fields)",
            .{ idx, sv.values.len },
            error.UnsupportedOperation,
        );
    return sv.values[@intCast(idx)];
}

pub fn arrayAtOffset(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    const arr = try args[0].toArray();
    if (idx < 0 or idx >= @as(i64, @intCast(arr.values.len)))
        return bind.fail("OFFSET({d}) is out of range", .{idx}, error.UnsupportedOperation);
    return arr.values[@intCast(idx)];
}

pub fn safeArrayAtOffset(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    const arr = try args[0].toArray();
    if (idx < 0 or idx >= @as(i64, @intCast(arr.values.len))) return null_v;
    return arr.values[@intCast(idx)];
}

pub fn arrayAtOrdinal(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    const arr = try args[0].toArray();
    if (idx < 1 or idx > @as(i64, @intCast(arr.values.len)))
        return bind.fail("ORDINAL({d}) is out of range", .{idx}, error.UnsupportedOperation);
    return arr.values[@intCast(idx - 1)];
}

pub fn safeArrayAtOrdinal(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const idx = try args[1].toInt64();
    const arr = try args[0].toArray();
    if (idx < 1 or idx > @as(i64, @intCast(arr.values.len))) return null_v;
    return arr.values[@intCast(idx - 1)];
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

/// Go bindMakeStruct -> MAKE_STRUCT: (key, value) pairs; empty keys become
/// "_field_<n>".
pub fn makeStruct(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len % 2 != 0)
        return bind.fail("MAKE_STRUCT: unexpected argument num {d}", .{args.len}, error.UnsupportedOperation);
    const n = args.len / 2;
    const keys = try alloc.alloc([]const u8, n);
    const values = try alloc.alloc(Value, n);
    for (0..n) |i| {
        var k = try args[i * 2].toString(alloc);
        if (k.len == 0) k = try std.fmt.allocPrint(alloc, "_field_{d}", .{i + 1});
        keys[i] = k;
        values[i] = args[i * 2 + 1];
    }
    return value_mod.structValue(alloc, keys, values);
}
