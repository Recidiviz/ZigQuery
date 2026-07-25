//! Port of go-zetasqlite's REGEXP_* string functions (function_string.go
//! REGEXP_CONTAINS/EXTRACT/EXTRACT_ALL/INSTR/REPLACE + their bind* wrappers).
//! Matching is delegated to RE2 via the shim (src/regexp_ffi.zig), matching
//! Go's regexp package (RE2 syntax).

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = bind.value_mod;
const re = @import("../../regexp_ffi.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

fn runeCount(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) {
        const l: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(l, s.len - i);
    }
    return n;
}

fn reErr(err: re.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => bind.fail("REGEXP: invalid regular expression", .{}, error.UnsupportedOperation),
    };
}

/// Go REGEXP_CONTAINS(value, expr).
pub fn regexpContains(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const v = try args[0].toString(alloc);
    const expr = try args[1].toString(alloc);
    const r = re.find(alloc, expr, v, 0, 1) catch |e| return reErr(e);
    return Value{ .bool = r.nmatches > 0 };
}

/// Go REGEXP_EXTRACT(value, expr, position=1, occurrence=1): returns the last
/// capture group (or the whole match when there are no groups) of the
/// occurrence-th match, NULL if there are fewer matches than `occurrence`.
pub fn regexpExtract(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    var position: i64 = 1;
    if (args.len > 2) position = try args[2].toInt64();
    var occurrence: i64 = 1;
    if (args.len > 3) occurrence = try args[3].toInt64();
    if (position <= 0)
        return bind.fail("REGEXP_EXTRACT: unexpected position number. position must be positive number", .{}, error.UnsupportedOperation);
    if (occurrence <= 0)
        return bind.fail("REGEXP_EXTRACT: unexpected occurrence number. occurrence must be positive number", .{}, error.UnsupportedOperation);
    const pos: usize = @intCast(position - 1);
    const is_bytes = args[0] == .bytes;
    const subj = if (is_bytes) try args[0].toBytes(alloc) else try args[0].toString(alloc);
    const expr = if (is_bytes) try args[1].toBytes(alloc) else try args[1].toString(alloc);
    const runes = if (is_bytes) subj.len else runeCount(subj);
    if (pos >= runes) return null_v;
    const r = re.find(alloc, expr, subj, pos, @intCast(occurrence)) catch |e| return reErr(e);
    if (r.nmatches < @as(usize, @intCast(occurrence))) return null_v;
    const nsub = r.ngroups + 1;
    const base = (@as(usize, @intCast(occurrence)) - 1) * nsub * 2;
    const last = base + r.ngroups * 2; // start index of the last group's pair
    const captured = groupSlice(subj, r.offsets, last);
    return if (is_bytes) Value{ .bytes = captured } else Value{ .string = captured };
}

/// Go REGEXP_EXTRACT_ALL(value, expr): array of last-capture-group of every
/// match.
pub fn regexpExtractAll(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const is_bytes = args[0] == .bytes;
    const subj = if (is_bytes) try args[0].toBytes(alloc) else try args[0].toString(alloc);
    const expr = if (is_bytes) try args[1].toBytes(alloc) else try args[1].toString(alloc);
    const r = re.find(alloc, expr, subj, 0, subj.len + 1) catch |e| return reErr(e);
    const nsub = r.ngroups + 1;
    var out: std.ArrayList(Value) = .empty;
    for (0..r.nmatches) |m| {
        const base = m * nsub * 2;
        const last = base + r.ngroups * 2;
        const captured = groupSlice(subj, r.offsets, last);
        try out.append(alloc, if (is_bytes) Value{ .bytes = captured } else Value{ .string = captured });
    }
    return value_mod.arrayValue(alloc, out.items);
}

/// Go REGEXP_INSTR(source, expr, position=1, occurrence=1, occurrence_pos=0):
/// 1-based byte position derived from the flat submatch-index array.
pub fn regexpInstr(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    var position: i64 = 1;
    if (args.len > 2) position = try args[2].toInt64();
    var occurrence: i64 = 1;
    if (args.len > 3) occurrence = try args[3].toInt64();
    var occurrence_pos: i64 = 0;
    if (args.len > 4) occurrence_pos = try args[4].toInt64();
    if (position <= 0)
        return bind.fail("REGEXP_INSTR: unexpected position number. position must be positive number", .{}, error.UnsupportedOperation);
    if (occurrence <= 0)
        return bind.fail("REGEXP_INSTR: unexpected occurrence number. occurrence must be positive number", .{}, error.UnsupportedOperation);
    const pos: usize = @intCast(position - 1);
    const is_bytes = args[0] == .bytes;
    const subj = if (is_bytes) try args[0].toBytes(alloc) else try args[0].toString(alloc);
    const expr = if (is_bytes) try args[1].toBytes(alloc) else try args[1].toString(alloc);
    const runes = if (is_bytes) subj.len else runeCount(subj);
    if (pos >= runes) return Value{ .int = 0 };
    const r = re.find(alloc, expr, subj, pos, @intCast(occurrence)) catch |e| return reErr(e);
    if (r.nmatches < @as(usize, @intCast(occurrence))) return Value{ .int = 0 };
    const nsub = r.ngroups + 1;
    const flat = nsub * 2; // ints per match
    const base = (@as(usize, @intCast(occurrence)) - 1) * flat;
    if (occurrence_pos < 0 or @as(usize, @intCast(occurrence_pos)) >= flat)
        return Value{ .int = 0 };
    const off = r.offsets[base + @as(usize, @intCast(occurrence_pos))];
    if (off < 0) return Value{ .int = 0 };
    // Offsets are already absolute into subj; Go returns pos + rel + 1 where
    // rel is relative to subj[pos:], i.e. abs + 1.
    return Value{ .int = @as(i64, off) + 1 };
}

/// Go REGEXP_REPLACE(value, expr, replacement) via RE2::GlobalReplace.
pub fn regexpReplace(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const is_bytes = args[0] == .bytes;
    const subj = if (is_bytes) try args[0].toBytes(alloc) else try args[0].toString(alloc);
    const expr = if (is_bytes) try args[1].toBytes(alloc) else try args[1].toString(alloc);
    const repl = if (is_bytes) try args[2].toBytes(alloc) else try args[2].toString(alloc);
    const result = re.replace(alloc, expr, subj, repl) catch |e| return reErr(e);
    return if (is_bytes) Value{ .bytes = result } else Value{ .string = result };
}

/// Slices out a submatch group (pair at flat index `pair_start`); a
/// non-participating group (-1) yields an empty slice (Go's "").
fn groupSlice(subj: []const u8, offsets: []const i32, pair_start: usize) []const u8 {
    const s = offsets[pair_start];
    const e = offsets[pair_start + 1];
    if (s < 0 or e < 0) return subj[0..0];
    return subj[@intCast(s)..@intCast(e)];
}
