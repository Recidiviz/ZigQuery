//! Port of the foundation string functions (Go: function_string.go CONCAT/
//! LENGTH/LEFT/RIGHT/LOWER/UPPER/SUBSTR + their bind* wrappers).
//!
//! Rune semantics: Go converts strings to []rune (invalid UTF-8 bytes count
//! as one rune each); the helpers below reproduce that counting. LOWER/UPPER
//! use ASCII case mapping (Go's strings.ToLower is full Unicode) — the
//! foundation corpus only exercises ASCII.

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = bind.value_mod;
const re = @import("../../regexp_ffi.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

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
    if (args[0] == .null) return null_v;
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

// STRING case mapping is full-Unicode (Go strings.To{Lower,Upper}) via the ICU
// shim; BYTES case mapping stays ASCII-only (residual gap: Go's bytes.To{...}
// is UTF-8-aware, but no corpus case exercises non-ASCII BYTES casing).
fn caseMapErr(err: re.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnsupportedOperation,
    };
}

pub fn lower(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1)
        return bind.fail("LOWER: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .string => |s| return Value{
            .string = re.caseMap(alloc, false, s) catch |e| return caseMapErr(e),
        },
        .bytes => |b| return Value{ .bytes = try asciiMapCase(alloc, b, .lower) },
        else => return bind.fail("LOWER: value type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    }
}

pub fn upper(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1)
        return bind.fail("UPPER: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (args[0] == .null) return null_v;
    switch (args[0]) {
        .string => |s| return Value{
            .string = re.caseMap(alloc, true, s) catch |e| return caseMapErr(e),
        },
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

// ======================================================================
// Additional string/bytes functions (Go function_string.go remainder).
// ======================================================================

// Rune helpers ----------------------------------------------------------

/// Go []rune(string): valid UTF-8 -> codepoint; each invalid byte -> U+FFFD.
fn decodeRunes(alloc: std.mem.Allocator, s: []const u8) Error![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.append(alloc, 0xFFFD);
            i += 1;
            continue;
        };
        if (i + l > s.len) {
            try out.append(alloc, 0xFFFD);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + l]) catch {
            try out.append(alloc, 0xFFFD);
            i += 1;
            continue;
        };
        try out.append(alloc, cp);
        i += l;
    }
    return out.toOwnedSlice(alloc);
}

/// UTF-8 encodes a codepoint (Go string(rune)): invalid/surrogate -> U+FFFD.
fn encodeRune(buf: *[4]u8, cp_in: i64) []const u8 {
    var cp: u21 = 0xFFFD;
    if (cp_in >= 0 and cp_in <= 0x10FFFF and !(cp_in >= 0xD800 and cp_in <= 0xDFFF))
        cp = @intCast(cp_in);
    const n = std.unicode.utf8Encode(cp, buf) catch blk: {
        const m = std.unicode.utf8Encode(0xFFFD, buf) catch unreachable;
        break :blk m;
    };
    return buf[0..n];
}

fn runesToString(alloc: std.mem.Allocator, runes: []const u21) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [4]u8 = undefined;
    for (runes) |cp| try out.appendSlice(alloc, encodeRune(&buf, @intCast(cp)));
    return out.toOwnedSlice(alloc);
}

/// Simple per-code-point case mapping of a single rune, matching Go's
/// unicode.To{Upper,Lower}; ASCII fast path avoids an FFI call.
fn mapRuneCase(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cp: u21,
    to_upper: bool,
) Error!void {
    if (cp < 128) {
        const c: u8 = @intCast(cp);
        try out.append(alloc, if (to_upper) std.ascii.toUpper(c) else std.ascii.toLower(c));
        return;
    }
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(
            alloc,
            buf[0 .. std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable],
        );
        return;
    };
    const mapped = re.caseMap(alloc, to_upper, buf[0..n]) catch |e| return caseMapErr(e);
    try out.appendSlice(alloc, mapped);
}

// ASCII / CHAR / BYTE lengths ------------------------------------------

/// Go ASCII: returns the first byte's value (or 0 for empty; NULL for NULL).
pub fn ascii(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const s = try args[0].toString(alloc);
    if (s.len == 0) return Value{ .int = 0 };
    return Value{ .int = s[0] };
}

/// Go BYTE_LENGTH / OCTET_LENGTH: byte length.
pub fn byteLength(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const b = try args[0].toBytes(alloc);
    return Value{ .int = @intCast(b.len) };
}

/// Go CHAR_LENGTH / CHARACTER_LENGTH: rune count.
pub fn charLength(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const b = try args[0].toBytes(alloc);
    return Value{ .int = @intCast(runeCount(b)) };
}

/// Go CHR: codepoint -> UTF-8 string (0 -> "").
pub fn chr(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const v = try args[0].toInt64();
    if (v == 0) return Value{ .string = "" };
    var buf: [4]u8 = undefined;
    return Value{ .string = try alloc.dupe(u8, encodeRune(&buf, v)) };
}

/// Go CODE_POINTS_TO_BYTES: array of int64 -> bytes (each truncated to byte).
pub fn codePointsToBytes(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const arr = try args[0].toArray();
    const out = try alloc.alloc(u8, arr.values.len);
    for (arr.values, out) |v, *o| o.* = @truncate(@as(u64, @bitCast(try v.toInt64())));
    return Value{ .bytes = out };
}

/// Go CODE_POINTS_TO_STRING: array of int64 -> UTF-8 string (0 skipped, NULL
/// element -> NULL result).
pub fn codePointsToString(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const arr = try args[0].toArray();
    var out: std.ArrayList(u8) = .empty;
    var buf: [4]u8 = undefined;
    for (arr.values) |v| {
        if (v == .null) return null_v;
        const i = try v.toInt64();
        if (i == 0) continue;
        try out.appendSlice(alloc, encodeRune(&buf, i));
    }
    return Value{ .string = try out.toOwnedSlice(alloc) };
}

/// Go TO_CODE_POINTS: STRING -> array of rune codepoints; BYTES -> array of
/// byte values.
pub fn toCodePoints(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return value_mod.arrayValue(alloc, &.{});
    switch (args[0]) {
        .string => |s| {
            const runes = try decodeRunes(alloc, s);
            const vals = try alloc.alloc(Value, runes.len);
            for (runes, vals) |cp, *o| o.* = Value{ .int = @intCast(cp) };
            return value_mod.arrayValue(alloc, vals);
        },
        .bytes => |b| {
            const vals = try alloc.alloc(Value, b.len);
            for (b, vals) |byte, *o| o.* = Value{ .int = byte };
            return value_mod.arrayValue(alloc, vals);
        },
        else => return bind.fail("TO_CODE_POINTS: value type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    }
}

// STARTS_WITH / ENDS_WITH / STRPOS -------------------------------------

pub fn startsWith(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2)
        return bind.fail("STARTS_WITH: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .string, .bytes => {
            const v = try args[0].toBytes(alloc);
            const p = try args[1].toBytes(alloc);
            return Value{ .bool = std.mem.startsWith(u8, v, p) };
        },
        else => return bind.fail("ENDS_WITH: argument type must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

pub fn endsWith(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .string, .bytes => {
            const v = try args[0].toBytes(alloc);
            const s = try args[1].toBytes(alloc);
            return Value{ .bool = std.mem.endsWith(u8, v, s) };
        },
        else => return bind.fail("ENDS_WITH: argument type must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

pub fn strpos(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2)
        return bind.fail("STRPOS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .string, .bytes => {
            const v = try args[0].toBytes(alloc);
            const s = try args[1].toBytes(alloc);
            const idx = std.mem.indexOf(u8, v, s);
            return Value{ .int = if (idx) |i| @as(i64, @intCast(i)) + 1 else 0 };
        },
        else => return bind.fail("STRPOS: argument type must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

// INSTR -----------------------------------------------------------------

/// INSTR(value, subvalue[, position[, occurrence]]): the 1-based position of an
/// occurrence of `subvalue` in `value` (string_functions.md#instr).
///
/// Positions count characters for STRING and bytes for BYTES, so
/// INSTR('h\u{e9}llo', 'l') is 3 while the same value as BYTES gives 4. Go works in
/// bytes for both.
pub fn instr(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len < 2 or args.len > 4)
        return bind.fail("INSTR: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;

    // Both optional arguments default to "from the beginning, the first one".
    // Defaulting position to 0 instead tripped the check below, so the
    // two-argument form — the common one — failed outright.
    var position: i64 = 1;
    var occurrence: i64 = 1;
    if (args.len >= 3) position = try args[2].toInt64();
    if (args.len == 4) occurrence = try args[3].toInt64();
    if (position == 0)
        return bind.fail("INSTR: invalid position number. position is must be large than zero value", .{}, error.UnsupportedOperation);
    if (occurrence <= 0)
        return bind.fail("INSTR: invalid occurrence number. occurrence is must be large than zero value. but specified {d}", .{occurrence}, error.UnsupportedOperation);

    const same_type = switch (args[0]) {
        .string => args[1] == .string,
        .bytes => args[1] == .bytes,
        else => return bind.fail("INSTR: source and search type are must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    };
    if (!same_type)
        return bind.fail("INSTR: source and search are must be same type", .{}, error.UnsupportedOperation);

    const by_char = args[0] == .string;
    const full = try args[0].toBytes(alloc);
    const search = try args[1].toBytes(alloc);
    const units: i64 = if (by_char) @intCast(runeCount(full)) else @intCast(full.len);

    // The window a match may start in. A positive position is a floor and the
    // search runs forward from it; a negative one is a ceiling counted back
    // from the end, with -1 the last unit, and the search runs backward. Note
    // it bounds where a match *starts*: the docs give INSTR('banana', 'an', -3)
    // as 4, and that match runs past unit 4. Out of range is 0 rather than an
    // error — "position is greater than the length of value" is listed under
    // "Returns 0".
    var lo: i64 = 1;
    var hi: i64 = units;
    if (position > 0) {
        if (position > units) return Value{ .int = 0 };
        lo = position;
    } else {
        if (-position > units) return Value{ .int = 0 };
        hi = units + position + 1;
    }

    // Every occurrence in the window, ascending. Occurrences may overlap:
    // INSTR('helloooo', 'oo', 1, 2) is 6, not 7.
    var matches: std.ArrayList(i64) = .empty;
    var off: usize = 0;
    var scanned: usize = 0;
    var unit_pos: i64 = 1;
    while (off <= full.len) {
        const idx = std.mem.indexOfPos(u8, full, off, search) orelse break;
        while (scanned < idx) : (unit_pos += 1) {
            const step: usize = if (by_char)
                (std.unicode.utf8ByteSequenceLength(full[scanned]) catch 1)
            else
                1;
            scanned += @min(step, idx - scanned);
        }
        if (unit_pos >= lo and unit_pos <= hi) try matches.append(alloc, unit_pos);
        off = idx + 1;
    }

    // `occurrence` counts in the direction of the search.
    const want: usize = @intCast(occurrence);
    if (want > matches.items.len) return Value{ .int = 0 };
    return Value{
        .int = if (position > 0)
            matches.items[want - 1]
        else
            matches.items[matches.items.len - want],
    };
}

// REPLACE / REPEAT / REVERSE -------------------------------------------

pub fn replace(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .string, .bytes => {
            const is_bytes = args[0] == .bytes;
            const v = try args[0].toBytes(alloc);
            const from = try args[1].toBytes(alloc);
            const to = try args[2].toBytes(alloc);
            const out = try replaceAll(alloc, v, from, to);
            return if (is_bytes) Value{ .bytes = out } else Value{ .string = out };
        },
        else => return bind.fail("REPLACE: originalValue must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

/// strings.ReplaceAll: empty `from` inserts `to` between every byte and at the
/// ends (Go semantics), otherwise non-overlapping replacement.
fn replaceAll(
    alloc: std.mem.Allocator,
    v: []const u8,
    from: []const u8,
    to: []const u8,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (from.len == 0) {
        try out.appendSlice(alloc, to);
        for (v) |b| {
            try out.append(alloc, b);
            try out.appendSlice(alloc, to);
        }
        return out.toOwnedSlice(alloc);
    }
    var i: usize = 0;
    while (i < v.len) {
        if (std.mem.startsWith(u8, v[i..], from)) {
            try out.appendSlice(alloc, to);
            i += from.len;
        } else {
            try out.append(alloc, v[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn repeat(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const n = try args[1].toInt64();
    switch (args[0]) {
        .string, .bytes => {
            const is_bytes = args[0] == .bytes;
            const v = try args[0].toBytes(alloc);
            if (n < 0)
                return bind.fail("REPEAT: negative repetitions", .{}, error.UnsupportedOperation);
            const out = try alloc.alloc(u8, v.len * @as(usize, @intCast(n)));
            var k: usize = 0;
            while (k < @as(usize, @intCast(n))) : (k += 1) @memcpy(out[k * v.len ..][0..v.len], v);
            return if (is_bytes) Value{ .bytes = out } else Value{ .string = out };
        },
        else => return bind.fail("REPEAT: originalValue must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

pub fn reverse(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .string => |s| {
            const runes = try decodeRunes(alloc, s);
            std.mem.reverse(u21, runes);
            return Value{ .string = try runesToString(alloc, runes) };
        },
        .bytes => |b| {
            const out = try alloc.dupe(u8, b);
            std.mem.reverse(u8, out);
            return Value{ .bytes = out };
        },
        else => return bind.fail("REVERSE: value must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

// TRIM family -----------------------------------------------------------

const TrimSide = enum { left, right, both };

fn trimImpl(
    alloc: std.mem.Allocator,
    args: []const Value,
    side: TrimSide,
    name: []const u8,
) Error!Value {
    _ = name;
    if (args.len != 1 and args.len != 2)
        return bind.fail("TRIM: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const has_cutset = args.len == 2;
    switch (args[0]) {
        .string => |s| {
            if (!has_cutset) return Value{ .string = trimSpaceUnicode(s, side) };
            const cutset = try args[1].toBytes(alloc);
            return Value{ .string = trimCutset(alloc, s, cutset, side) catch |e| return e };
        },
        .bytes => |b| {
            if (!has_cutset)
                return bind.fail("TRIM: must set_of_characters_to_remove when trimming bytes", .{}, error.UnsupportedOperation);
            const cutset = try args[1].toBytes(alloc);
            return Value{ .bytes = trimBytesCutset(b, cutset, side) };
        },
        else => return bind.fail("TRIM: expression type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    }
}

pub fn trim(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return trimImpl(alloc, args, .both, "TRIM");
}
pub fn ltrim(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return trimImpl(alloc, args, .left, "LTRIM");
}
pub fn rtrim(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return trimImpl(alloc, args, .right, "RTRIM");
}

fn isSpaceRune(cp: u21) bool {
    // Go unicode.IsSpace set.
    return switch (cp) {
        '\t', '\n', 0x0B, 0x0C, '\r', ' ', 0x85, 0xA0 => true,
        0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => cp >= 0x2000 and cp <= 0x200A,
    };
}

/// strings.Trim{Left,Right,Space}Func(unicode.IsSpace): rune-aware whitespace
/// trimming, aliasing the input.
fn trimSpaceUnicode(s: []const u8, side: TrimSide) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    if (side == .left or side == .both) {
        var i: usize = 0;
        while (i < end) {
            const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const cp = if (i + l <= s.len)
                (std.unicode.utf8Decode(s[i .. i + l]) catch @as(u21, s[i]))
            else
                @as(u21, s[i]);
            if (!isSpaceRune(cp)) break;
            i += @max(l, 1);
        }
        start = i;
    }
    if (side == .right or side == .both) {
        var i: usize = end;
        while (i > start) {
            // step back one rune
            var j = i - 1;
            while (j > start and (s[j] & 0xC0) == 0x80) j -= 1;
            const l = std.unicode.utf8ByteSequenceLength(s[j]) catch 1;
            const cp = if (j + l <= s.len)
                (std.unicode.utf8Decode(s[j .. j + l]) catch @as(u21, s[j]))
            else
                @as(u21, s[j]);
            if (!isSpaceRune(cp)) break;
            i = j;
        }
        end = i;
    }
    return s[start..end];
}

/// strings.Trim{,Left,Right}(s, cutset): trims runes contained in cutset.
fn trimCutset(
    alloc: std.mem.Allocator,
    s: []const u8,
    cutset: []const u8,
    side: TrimSide,
) Error![]const u8 {
    const set = try decodeRunes(alloc, cutset);
    var start: usize = 0;
    var end: usize = s.len;
    if (side == .left or side == .both) {
        var i: usize = 0;
        while (i < end) {
            const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const cp = if (i + l <= s.len)
                (std.unicode.utf8Decode(s[i .. i + l]) catch @as(u21, s[i]))
            else
                @as(u21, s[i]);
            if (!runeInSet(cp, set)) break;
            i += @max(l, 1);
        }
        start = i;
    }
    if (side == .right or side == .both) {
        var i: usize = end;
        while (i > start) {
            var j = i - 1;
            while (j > start and (s[j] & 0xC0) == 0x80) j -= 1;
            const l = std.unicode.utf8ByteSequenceLength(s[j]) catch 1;
            const cp = if (j + l <= s.len)
                (std.unicode.utf8Decode(s[j .. j + l]) catch @as(u21, s[j]))
            else
                @as(u21, s[j]);
            if (!runeInSet(cp, set)) break;
            i = j;
        }
        end = i;
    }
    return s[start..end];
}

fn runeInSet(cp: u21, set: []const u21) bool {
    for (set) |c| if (c == cp) return true;
    return false;
}

/// bytes.Trim{,Left,Right}: byte-set trimming.
fn trimBytesCutset(b: []const u8, cutset: []const u8, side: TrimSide) []const u8 {
    var start: usize = 0;
    var end: usize = b.len;
    if (side == .left or side == .both)
        while (start < end and std.mem.indexOfScalar(u8, cutset, b[start]) != null) {
            start += 1;
        };
    if (side == .right or side == .both)
        while (end > start and std.mem.indexOfScalar(u8, cutset, b[end - 1]) != null) {
            end -= 1;
        };
    return b[start..end];
}

// LPAD / RPAD -----------------------------------------------------------

const PadSide = enum { left, right };

fn padImpl(alloc: std.mem.Allocator, args: []const Value, side: PadSide) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const return_length = try args[1].toInt64();
    const has_pat = args.len > 2 and args[2] != .null;
    switch (args[0]) {
        .string => {
            if (return_length < 0)
                return bind.fail("RPAD: unexpected returnLength value. returnLength must be positive number", .{}, error.UnsupportedOperation);
            const runes = try decodeRunes(alloc, try args[0].toString(alloc));
            const rl: usize = @intCast(return_length);
            if (runes.len >= rl) return Value{ .string = try runesToString(alloc, runes[0..rl]) };
            const remain = rl - runes.len;
            var pat: []u21 = undefined;
            if (has_pat) {
                pat = try decodeRunes(alloc, try args[2].toString(alloc));
                if (pat.len == 0) return bind.fail("PAD: pattern is empty", .{}, error.UnsupportedOperation);
                if (remain > pat.len) {
                    const repeat_num = ((remain - pat.len) / pat.len) + 2;
                    pat = try repeatRunes(alloc, pat, repeat_num);
                }
            } else {
                pat = try alloc.alloc(u21, remain);
                for (pat) |*p| p.* = ' ';
            }
            const padding = pat[0..remain];
            var out: std.ArrayList(u21) = .empty;
            if (side == .left) {
                try out.appendSlice(alloc, padding);
                try out.appendSlice(alloc, runes);
            } else {
                try out.appendSlice(alloc, runes);
                try out.appendSlice(alloc, padding);
            }
            return Value{ .string = try runesToString(alloc, out.items) };
        },
        .bytes => {
            if (return_length < 0)
                return bind.fail("RPAD: unexpected returnLength value. returnLength must be positive number", .{}, error.UnsupportedOperation);
            const b = try args[0].toBytes(alloc);
            const rl: usize = @intCast(return_length);
            if (b.len >= rl) return Value{ .bytes = b[0..rl] };
            const remain = rl - b.len;
            var pat: []const u8 = undefined;
            if (has_pat) {
                const p = try args[2].toBytes(alloc);
                if (p.len == 0) return bind.fail("PAD: pattern is empty", .{}, error.UnsupportedOperation);
                if (remain > p.len) {
                    const repeat_num = ((remain - p.len) / p.len) + 2;
                    pat = try repeatBytes(alloc, p, repeat_num);
                } else {
                    pat = p;
                }
            } else {
                const sp = try alloc.alloc(u8, remain);
                for (sp) |*x| x.* = ' ';
                pat = sp;
            }
            const padding = pat[0..remain];
            var out: std.ArrayList(u8) = .empty;
            if (side == .left) {
                try out.appendSlice(alloc, padding);
                try out.appendSlice(alloc, b);
            } else {
                try out.appendSlice(alloc, b);
                try out.appendSlice(alloc, padding);
            }
            return Value{ .bytes = try out.toOwnedSlice(alloc) };
        },
        else => return bind.fail("PAD: original value type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    }
}

pub fn lpad(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return padImpl(alloc, args, .left);
}
pub fn rpad(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return padImpl(alloc, args, .right);
}

fn repeatRunes(alloc: std.mem.Allocator, r: []const u21, n: usize) Error![]u21 {
    const out = try alloc.alloc(u21, r.len * n);
    var k: usize = 0;
    while (k < n) : (k += 1) @memcpy(out[k * r.len ..][0..r.len], r);
    return out;
}
fn repeatBytes(alloc: std.mem.Allocator, b: []const u8, n: usize) Error![]u8 {
    const out = try alloc.alloc(u8, b.len * n);
    var k: usize = 0;
    while (k < n) : (k += 1) @memcpy(out[k * b.len ..][0..b.len], b);
    return out;
}

// SPLIT -----------------------------------------------------------------

pub fn split(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    // Go bindSplit: any NULL argument yields an empty array.
    if (bind.existsNull(args)) return value_mod.arrayValue(alloc, &.{});
    switch (args[0]) {
        .string => {
            const v = try args[0].toString(alloc);
            const delim = if (args.len > 1) try args[1].toString(alloc) else ",";
            var out: std.ArrayList(Value) = .empty;
            try splitInto(alloc, &out, v, delim, false);
            return value_mod.arrayValue(alloc, out.items);
        },
        .bytes => {
            const v = try args[0].toBytes(alloc);
            if (args.len <= 1)
                return bind.fail("SPLIT: delimiter must be specified for bytes value", .{}, error.UnsupportedOperation);
            const delim = try args[1].toBytes(alloc);
            var out: std.ArrayList(Value) = .empty;
            try splitInto(alloc, &out, v, delim, true);
            return value_mod.arrayValue(alloc, out.items);
        },
        else => return bind.fail("SPLIT: value must be STRING or BYTES", .{}, error.UnsupportedOperation),
    }
}

/// strings.Split / bytes.Split semantics: empty delimiter splits into runes
/// (strings) or bytes; otherwise splits on each non-overlapping occurrence.
fn splitInto(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Value),
    v: []const u8,
    delim: []const u8,
    is_bytes: bool,
) Error!void {
    if (delim.len == 0) {
        if (is_bytes) {
            for (v) |b| try out.append(alloc, Value{ .bytes = try alloc.dupe(u8, &.{b}) });
        } else {
            var i: usize = 0;
            while (i < v.len) {
                const l = @min(std.unicode.utf8ByteSequenceLength(v[i]) catch 1, v.len - i);
                try out.append(alloc, Value{ .string = v[i .. i + l] });
                i += l;
            }
        }
        return;
    }
    var rest = v;
    while (true) {
        if (std.mem.indexOf(u8, rest, delim)) |idx| {
            const piece = rest[0..idx];
            try out.append(
                alloc,
                if (is_bytes) Value{ .bytes = piece } else Value{ .string = piece },
            );
            rest = rest[idx + delim.len ..];
        } else {
            try out.append(
                alloc,
                if (is_bytes) Value{ .bytes = rest } else Value{ .string = rest },
            );
            break;
        }
    }
}

// INITCAP ---------------------------------------------------------------

const default_initcap_delims = [_]u21{
    ' ', '[', ']', '(', ')', '{', '}', '/', '|', '\\',
    '<', '>', '!', '?', '@', '"', '^', '#', '$', '&',
    '~', '_', ',', '.', ':', ';', '*', '%', '+', '-',
};

pub fn initcap(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1 and args.len != 2)
        return bind.fail("INITCAP: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    var delims: []const u21 = &default_initcap_delims;
    if (args.len == 2) delims = try decodeRunes(alloc, try args[1].toString(alloc));
    const src = try decodeRunes(alloc, try args[0].toString(alloc));
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const r = src[i];
        const is_cur_delim = runeInSet(r, delims);
        if (i == 0) {
            try mapRuneCase(alloc, &out, r, true);
        } else if (is_cur_delim) {
            var buf: [4]u8 = undefined;
            try out.appendSlice(alloc, encodeRune(&buf, @intCast(r)));
        } else {
            try mapRuneCase(alloc, &out, r, false);
        }
        if (i + 1 == src.len) continue;
        if (runeInSet(src[i + 1], delims)) continue;
        if (is_cur_delim) {
            try mapRuneCase(alloc, &out, src[i + 1], true);
            i += 1;
        }
    }
    return Value{ .string = try out.toOwnedSlice(alloc) };
}

// TRANSLATE -------------------------------------------------------------

pub fn translate(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 3)
        return bind.fail("TRANSLATE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .string => {
            if (args[1] != .string)
                return bind.fail("TRANSLATE: source characters must be STRING type", .{}, error.UnsupportedOperation);
            if (args[2] != .string)
                return bind.fail("TRANSLATE: target characters must be STRING type", .{}, error.UnsupportedOperation);
            var expr = try decodeRunes(alloc, try args[0].toString(alloc));
            const source = try decodeRunes(alloc, try args[1].toString(alloc));
            const target = try decodeRunes(alloc, try args[2].toString(alloc));
            var seen: std.ArrayList(u21) = .empty;
            for (source, 0..) |sr, idx| {
                if (runeInSet(sr, seen.items)) {
                    var buf: [4]u8 = undefined;
                    return bind.fail(
                        "TRANSLATE: found duplicated source character: {s}",
                        .{encodeRune(&buf, @intCast(sr))},
                        error.UnsupportedOperation,
                    );
                }
                const repl: ?u21 = if (idx < target.len) target[idx] else null;
                expr = try translateReplaceRunes(alloc, expr, sr, repl);
                try seen.append(alloc, sr);
            }
            return Value{ .string = try runesToString(alloc, expr) };
        },
        .bytes => {
            if (args[1] != .bytes)
                return bind.fail("TRANSLATE: source characters must be BYTES type", .{}, error.UnsupportedOperation);
            if (args[2] != .bytes)
                return bind.fail("TRANSLATE: target characters must be BYTES type", .{}, error.UnsupportedOperation);
            var expr: []const u8 = try args[0].toBytes(alloc);
            const source = try args[1].toBytes(alloc);
            const target = try args[2].toBytes(alloc);
            var seen: std.ArrayList(u8) = .empty;
            for (source, 0..) |sb, idx| {
                if (std.mem.indexOfScalar(u8, seen.items, sb) != null)
                    return bind.fail("TRANSLATE: found duplicated source character: {c}", .{sb}, error.UnsupportedOperation);
                const repl: ?u8 = if (idx < target.len) target[idx] else null;
                expr = try translateReplaceBytes(alloc, expr, sb, repl);
                try seen.append(alloc, sb);
            }
            return Value{ .bytes = expr };
        },
        else => return bind.fail("TRANSLATE: expression type is must be STRING or BYTES type", .{}, error.UnsupportedOperation),
    }
}

fn translateReplaceRunes(
    alloc: std.mem.Allocator,
    expr: []const u21,
    from: u21,
    to: ?u21,
) Error![]u21 {
    var out: std.ArrayList(u21) = .empty;
    for (expr) |cp| {
        if (cp == from) {
            if (to) |t| try out.append(alloc, t);
        } else try out.append(alloc, cp);
    }
    return out.toOwnedSlice(alloc);
}

fn translateReplaceBytes(alloc: std.mem.Allocator, expr: []const u8, from: u8, to: ?u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (expr) |b| {
        if (b == from) {
            if (to) |t| try out.append(alloc, t);
        } else try out.append(alloc, b);
    }
    return out.toOwnedSlice(alloc);
}

// UNICODE ---------------------------------------------------------------

pub fn unicode(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const runes = try decodeRunes(alloc, try args[0].toString(alloc));
    if (runes.len == 0) return Value{ .int = 0 };
    return Value{ .int = @intCast(runes[0]) };
}

// SOUNDEX ---------------------------------------------------------------

fn soundexCode(c: u8) u8 {
    return switch (std.ascii.toUpper(c)) {
        'B', 'F', 'P', 'V' => '1',
        'C', 'G', 'J', 'K', 'Q', 'S', 'X', 'Z' => '2',
        'D', 'T' => '3',
        'L' => '4',
        'M', 'N' => '5',
        'R' => '6',
        else => '0', // A E I O U H W Y
    };
}

pub fn soundex(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const runes = try decodeRunes(alloc, try args[0].toString(alloc));
    var out = [4]u8{ ' ', '0', '0', '0' };
    var prev_code: u8 = 0;
    var point: usize = 0;
    for (runes) |cp| {
        if (cp >= 128 or !std.ascii.isAlphabetic(@intCast(cp))) continue;
        const c: u8 = @intCast(cp);
        const code = soundexCode(c);
        if (point == 0) {
            out[point] = c;
            prev_code = code;
            point += 1;
            continue;
        }
        if (code == prev_code or code == '0') continue;
        out[point] = code;
        prev_code = code;
        point += 1;
        if (point == 4) break;
    }
    if (point == 0) return Value{ .string = "" };
    return Value{ .string = try alloc.dupe(u8, &out) };
}

// SAFE_CONVERT_BYTES_TO_STRING -----------------------------------------

pub fn safeConvertBytesToString(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const b = try args[0].toBytes(alloc);
    // utf8.DecodeRune replaces invalid sequences with U+FFFD (advancing 1 byte).
    var out: std.ArrayList(u8) = .empty;
    var buf: [4]u8 = undefined;
    var i: usize = 0;
    while (i < b.len) {
        const l = std.unicode.utf8ByteSequenceLength(b[i]) catch {
            try out.appendSlice(alloc, encodeRune(&buf, 0xFFFD));
            i += 1;
            continue;
        };
        if (i + l > b.len) {
            try out.appendSlice(alloc, encodeRune(&buf, 0xFFFD));
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(b[i .. i + l]) catch {
            try out.appendSlice(alloc, encodeRune(&buf, 0xFFFD));
            i += 1;
            continue;
        };
        try out.appendSlice(alloc, encodeRune(&buf, @intCast(cp)));
        i += l;
    }
    return Value{ .string = try out.toOwnedSlice(alloc) };
}

// NORMALIZE -------------------------------------------------------------

fn normalizeMode(s: []const u8) ?re.NormalizeMode {
    if (std.mem.eql(u8, s, "NFC")) return .nfc;
    if (std.mem.eql(u8, s, "NFD")) return .nfd;
    if (std.mem.eql(u8, s, "NFKC")) return .nfkc;
    if (std.mem.eql(u8, s, "NFKD")) return .nfkd;
    return null;
}

pub fn normalize(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1 and args.len != 2)
        return bind.fail("NORMALIZE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    var mode: []const u8 = "NFC";
    if (args.len == 2) mode = try args[1].toString(alloc);
    const m = normalizeMode(mode) orelse
        return bind.fail("unexpected normalize mode {s}", .{mode}, error.UnsupportedOperation);
    const v = try args[0].toString(alloc);
    const out = re.normalize(alloc, m, v) catch |e| return caseMapErr(e);
    return Value{ .string = out };
}

pub fn normalizeAndCasefold(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1 and args.len != 2)
        return bind.fail("NORMALIZE_AND_CASEFOLD: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    var mode: []const u8 = "NFC";
    if (args.len == 2) mode = try args[1].toString(alloc);
    const m = normalizeMode(mode) orelse
        return bind.fail("unexpected normalize mode {s}", .{mode}, error.UnsupportedOperation);
    // Go NORMALIZE_AND_CASEFOLD lowercases (strings.ToLower) then normalizes.
    const lowered = re.caseMap(alloc, false, try args[0].toString(alloc)) catch |e|
        return caseMapErr(e);
    const out = re.normalize(alloc, m, lowered) catch |e| return caseMapErr(e);
    return Value{ .string = out };
}

/// Go function_string.go CONTAINS_SUBSTR(value, search): NFKC-normalize and
/// casefold both operands, then test containment.
fn containsSubstrScalar(
    alloc: std.mem.Allocator,
    value: []const u8,
    search: []const u8,
) Error!Value {
    const nv = try normalizeAndCasefold(
        alloc,
        &.{ Value{ .string = value }, Value{ .string = "NFKC" } },
    );
    const ns = try normalizeAndCasefold(
        alloc,
        &.{ Value{ .string = search }, Value{ .string = "NFKC" } },
    );
    const norm_value = try nv.toString(alloc);
    const norm_search = try ns.toString(alloc);
    return Value{ .bool = std.mem.indexOf(u8, norm_value, norm_search) != null };
}

/// Go function_bind.go bindContainsSubstr: tri-state NULL semantics plus
/// struct field-by-field recursion (true if any field contains the substr,
/// null if a field is null and none matched, otherwise false).
pub fn containsSubstr(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    // A null search literal is an error (distinct from a null expression,
    // which yields NULL below).
    if (args[1] == .null) {
        return bind.failMsg("CONTAINS_SUBSTR: search literal must be not null", error.UnsupportedOperation);
    }
    if (bind.existsNull(args)) return null_v;

    if (args[0] == .struct_) {
        var null_exists = false;
        for (args[0].struct_.values) |field| {
            if (field == .null) {
                null_exists = true;
                continue;
            }
            const result = try containsSubstr(alloc, &.{ field, args[1] });
            if (result == .bool and result.bool) return Value{ .bool = true };
        }
        if (null_exists) return null_v;
        return Value{ .bool = false };
    }

    const value = try args[0].toString(alloc);
    const search = try args[1].toString(alloc);
    return containsSubstrScalar(alloc, value, search);
}

// Base32 / Base64 / Hex encodings --------------------------------------

const base32_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

pub fn toBase32(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const b = try args[0].toBytes(alloc);
    return Value{ .string = try base32Encode(alloc, b) };
}

pub fn fromBase32(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const s = try args[0].toString(alloc);
    return Value{ .bytes = base32Decode(alloc, s) catch
        return bind.fail("FROM_BASE32: invalid base32 input", .{}, error.FailedConversion) };
}

pub fn toBase64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const b = try args[0].toBytes(alloc);
    const enc = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, enc.calcSize(b.len));
    return Value{ .string = enc.encode(out, b) };
}

pub fn fromBase64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const s = try args[0].toString(alloc);
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch
        return bind.fail("FROM_BASE64: invalid base64 input", .{}, error.FailedConversion);
    const out = try alloc.alloc(u8, n);
    dec.decode(out, s) catch
        return bind.fail("FROM_BASE64: invalid base64 input", .{}, error.FailedConversion);
    return Value{ .bytes = out };
}

pub fn toHex(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const b = try args[0].toBytes(alloc);
    const out = try alloc.alloc(u8, b.len * 2);
    const hex_chars = "0123456789abcdef";
    for (b, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return Value{ .string = out };
}

pub fn fromHex(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    var s = try args[0].toString(alloc);
    if (s.len % 2 != 0) {
        const padded = try alloc.alloc(u8, s.len + 1);
        padded[0] = '0';
        @memcpy(padded[1..], s);
        s = padded;
    }
    const out = try alloc.alloc(u8, s.len / 2);
    _ = std.fmt.hexToBytes(out, s) catch
        return bind.fail("FROM_HEX: invalid hex input", .{}, error.FailedConversion);
    return Value{ .bytes = out };
}

/// RFC 4648 base32 with '=' padding (Go base32.StdEncoding).
fn base32Encode(alloc: std.mem.Allocator, data: []const u8) Error![]u8 {
    if (data.len == 0) return alloc.alloc(u8, 0);
    const out_len = ((data.len + 4) / 5) * 8;
    const out = try alloc.alloc(u8, out_len);
    var oi: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 5) {
        var buf = [_]u8{0} ** 5;
        const n = @min(@as(usize, 5), data.len - i);
        @memcpy(buf[0..n], data[i .. i + n]);
        // 5 bytes -> 8 groups of 5 bits.
        const bits: u64 = (@as(u64, buf[0]) << 32) | (@as(u64, buf[1]) << 24) |
            (@as(u64, buf[2]) << 16) | (@as(u64, buf[3]) << 8) | @as(u64, buf[4]);
        var g: usize = 0;
        while (g < 8) : (g += 1) {
            const shift: u6 = @intCast(35 - g * 5);
            out[oi] = base32_alphabet[@intCast((bits >> shift) & 0x1F)];
            oi += 1;
        }
        // Apply padding for the final partial group.
        const valid_groups: usize = switch (n) {
            1 => 2,
            2 => 4,
            3 => 5,
            4 => 7,
            else => 8,
        };
        if (n < 5) {
            var p = oi - 8 + valid_groups;
            while (p < oi) : (p += 1) out[p] = '=';
        }
    }
    return out;
}

fn base32DecodeVal(c: u8) ?u8 {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= '2' and c <= '7') return c - '2' + 26;
    return null;
}

fn base32Decode(alloc: std.mem.Allocator, s: []const u8) Error![]u8 {
    // Strip padding.
    var end = s.len;
    while (end > 0 and s[end - 1] == '=') end -= 1;
    const in = s[0..end];
    var out: std.ArrayList(u8) = .empty;
    var bits: u64 = 0;
    var nbits: u6 = 0;
    for (in) |c| {
        const v = base32DecodeVal(c) orelse return error.FailedConversion;
        bits = (bits << 5) | v;
        nbits += 5;
        if (nbits >= 8) {
            nbits -= 8;
            try out.append(alloc, @intCast((bits >> nbits) & 0xFF));
        }
    }
    return out.toOwnedSlice(alloc);
}
