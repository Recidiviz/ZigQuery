//! Port of the foundation string functions (Go: function_string.go CONCAT/
//! LENGTH/LEFT/RIGHT/LOWER/UPPER/SUBSTR + their bind* wrappers).
//!
//! Rune semantics: Go converts strings to []rune (invalid UTF-8 bytes count
//! as one rune each); the helpers below reproduce that counting. LOWER/UPPER
//! use ASCII case mapping (Go's strings.ToLower is full Unicode) — the
//! foundation corpus only exercises ASCII.

const std = @import("std");
const bind = @import("bind.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

// Rune helpers -----------------------------------------------------------

fn runeCount(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) {
        const l: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(l, s.len - i);
    }
    return n;
}

/// Byte index just past `rune_idx` runes.
fn byteIndexOfRune(s: []const u8, rune_idx: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < rune_idx) : (n += 1) {
        const l: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(l, s.len - i);
    }
    return i;
}

// CONCAT -----------------------------------------------------------------

pub fn concat(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len < 1)
        return bind.fail("CONCAT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    var out: std.ArrayList(u8) = .empty;
    for (args) |v| {
        const b = try v.toBytes(alloc);
        try out.appendSlice(alloc, b);
    }
    return switch (args[0]) {
        .string => Value{ .string = try out.toOwnedSlice(alloc) },
        .bytes => Value{ .bytes = try out.toOwnedSlice(alloc) },
        else => bind.fail("CONCAT: argument type must be STRING or BYTES", .{}, error.UnsupportedOperation),
    };
}

// LENGTH -----------------------------------------------------------------

pub fn length(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1)
        return bind.fail("LENGTH: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (args[0] == .@"null") return null_v;
    return switch (args[0]) {
        .string => |s| Value{ .int = @intCast(runeCount(s)) },
        .bytes => |b| Value{ .int = @intCast(b.len) },
        else => bind.fail("LENGTH: value type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    };
}

// LEFT / RIGHT -----------------------------------------------------------

pub fn left(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("LEFT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const len = try args[1].toInt64();
    if (len < 0)
        return bind.fail("LEFT: unexpected length value. length must be positive number", .{}, error.UnsupportedOperation);
    switch (args[0]) {
        .string => |s| {
            if (@as(i64, @intCast(runeCount(s))) <= len) return args[0];
            return Value{ .string = s[0..byteIndexOfRune(s, @intCast(len))] };
        },
        .bytes => |b| {
            if (@as(i64, @intCast(b.len)) <= len) return args[0];
            return Value{ .bytes = b[0..@intCast(len)] };
        },
        else => return bind.fail("LEFT: value type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    }
}

pub fn right(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const len = try args[1].toInt64();
    if (len < 0)
        return bind.fail("RIGHT: unexpected length value. length must be positive number", .{}, error.UnsupportedOperation);
    switch (args[0]) {
        .string => |s| {
            const n = runeCount(s);
            if (@as(i64, @intCast(n)) <= len) return args[0];
            return Value{ .string = s[byteIndexOfRune(s, n - @as(usize, @intCast(len)))..] };
        },
        .bytes => |b| {
            if (@as(i64, @intCast(b.len)) <= len) return args[0];
            return Value{ .bytes = b[b.len - @as(usize, @intCast(len)) ..] };
        },
        else => return bind.fail("RIGHT: value must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

// LOWER / UPPER ----------------------------------------------------------

pub fn lower(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1)
        return bind.fail("LOWER: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .string => |s| return Value{ .string = try asciiMapCase(alloc, s, .lower) },
        .bytes => |b| return Value{ .bytes = try asciiMapCase(alloc, b, .lower) },
        else => return bind.fail("LOWER: value type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    }
}

pub fn upper(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1)
        return bind.fail("UPPER: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (args[0] == .@"null") return null_v;
    switch (args[0]) {
        .string => |s| return Value{ .string = try asciiMapCase(alloc, s, .upper) },
        .bytes => |b| return Value{ .bytes = try asciiMapCase(alloc, b, .upper) },
        else => return bind.fail("UPPER: value type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    }
}

fn asciiMapCase(alloc: std.mem.Allocator, s: []const u8, mode: enum { lower, upper }) Error![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*ch| {
        ch.* = switch (mode) {
            .lower => std.ascii.toLower(ch.*),
            .upper => std.ascii.toUpper(ch.*),
        };
    }
    return out;
}

// SUBSTR -----------------------------------------------------------------

/// Go SUBSTR computes rune-based positions but slices the *byte* string with
/// them for STRING inputs (a Go bug that is observable behavior); mirrored.
pub fn substr(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2 and args.len != 3)
        return bind.fail("SUBSTR: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const pos = try args[1].toInt64();
    var len: ?i64 = null;
    if (args.len == 3) len = try args[2].toInt64();
    switch (args[0]) {
        .string => |v| {
            const runes_len: i64 = @intCast(runeCount(v));
            const actual_pos = substrPos(pos, runes_len);
            const actual_len = try substrLen(len, runes_len);
            var end = actual_pos + actual_len;
            if (end > runes_len) end = runes_len;
            return Value{ .string = v[@intCast(actual_pos)..@intCast(end)] };
        },
        .bytes => |v| {
            const v_len: i64 = @intCast(v.len);
            const actual_pos = substrPos(pos, v_len);
            const actual_len = try substrLen(len, v_len);
            var end = actual_pos + actual_len;
            if (end > v_len) end = v_len;
            return Value{ .bytes = v[@intCast(actual_pos)..@intCast(end)] };
        },
        // Go's SUBSTR reuses the STRPOS message here (mirrored).
        else => return bind.fail("STRPOS: argument type must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

fn substrPos(pos: i64, strlen: i64) i64 {
    if (pos == 0 or pos < -strlen) return 0;
    if (pos > strlen) return strlen;
    if (pos > 0) return pos - 1;
    return strlen + pos; // negative pos counts from the end
}

fn substrLen(len: ?i64, strlen: i64) Error!i64 {
    const l = len orelse return strlen;
    if (l < 0) return bind.fail("SUBSTR: length must be positive number", .{}, error.UnsupportedOperation);
    if (l > strlen) return strlen;
    return l;
}
