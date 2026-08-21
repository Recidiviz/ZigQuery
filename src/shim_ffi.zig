//! FFI over the RE2 + ICU surface added to the GoogleSQL analyzer shim
//! (shim/analyzer_shim.cc). Go's REGEXP_* functions use the RE2-syntax
//! `regexp` package, NORMALIZE/case-mapping use ICU-equivalent Unicode
//! tables, and named-timezone offset resolution uses ICU's bundled IANA
//! tzdata; all three are already linked into the shim dylib.

const std = @import("std");

extern fn GoogleSQL_RegexpFind(
    pat: [*]const u8,
    patlen: c_int,
    subj: [*]const u8,
    subjlen: c_int,
    startpos: c_int,
    max_matches: c_int,
    out_offsets: [*]i32,
    cap: c_int,
    out_nmatches: *c_int,
    out_ngroups: *c_int,
    out_err: *?[*:0]u8,
) c_int;

extern fn GoogleSQL_RegexpReplace(
    pat: [*]const u8,
    patlen: c_int,
    subj: [*]const u8,
    subjlen: c_int,
    rewrite: [*]const u8,
    rwlen: c_int,
    out: *?[*]u8,
    out_len: *c_int,
    out_err: *?[*:0]u8,
) c_int;

extern fn GoogleSQL_Normalize(
    mode: [*:0]const u8,
    in: [*]const u8,
    inlen: c_int,
    out: *?[*]u8,
    out_len: *c_int,
    out_err: *?[*:0]u8,
) c_int;

extern fn GoogleSQL_CaseMap(
    op: c_int,
    in: [*]const u8,
    inlen: c_int,
    out: *?[*]u8,
    out_len: *c_int,
) c_int;

extern fn GoogleSQL_TimeZoneOffsetSeconds(
    zone: [*]const u8,
    zonelen: c_int,
    date_millis: i64,
    out_offset_seconds: *i32,
    out_err: *?[*:0]u8,
) c_int;

extern fn GoogleSQL_Free(p: ?*anyopaque) void;

pub const Error = error{ RegexpCompile, Normalize, InvalidTimeZone, OutOfMemory };

/// One flat match: offsets are [wholeStart, wholeEnd, g1Start, g1End, ...]
/// as absolute byte offsets into the subject; a non-participating group is
/// (-1, -1). `ngroups` is the pattern's capture-group count (offsets has
/// (ngroups+1) pairs).
pub const FindResult = struct {
    offsets: []const i32,
    nmatches: usize,
    ngroups: usize,
};

/// Compiles `pat` and reports its capture-group count (probe: no matching).
pub fn numGroups(pat: []const u8) Error!usize {
    var nmatches: c_int = 0;
    var ngroups: c_int = 0;
    var out_err: ?[*:0]u8 = null;
    var dummy: [1]i32 = undefined;
    const rc = GoogleSQL_RegexpFind(
        emptySafe(pat),
        @intCast(pat.len),
        emptySafe(""),
        0,
        0,
        0,
        &dummy,
        0,
        &nmatches,
        &ngroups,
        &out_err,
    );
    if (out_err) |e| GoogleSQL_Free(e);
    if (rc != 0) return error.RegexpCompile;
    return @intCast(ngroups);
}

/// Finds up to `max_matches` non-overlapping matches of `pat` in `subj`
/// starting at byte `startpos`. Returned slice is arena-allocated.
pub fn find(
    alloc: std.mem.Allocator,
    pat: []const u8,
    subj: []const u8,
    startpos: usize,
    max_matches: usize,
) Error!FindResult {
    const ngroups = try numGroups(pat);
    const nsub = ngroups + 1;
    if (max_matches == 0) return .{ .offsets = &.{}, .nmatches = 0, .ngroups = ngroups };
    const cap = max_matches * nsub * 2;
    const buf = try alloc.alloc(i32, cap);
    var nmatches: c_int = 0;
    var ngroups_out: c_int = 0;
    var out_err: ?[*:0]u8 = null;
    const rc = GoogleSQL_RegexpFind(
        emptySafe(pat),
        @intCast(pat.len),
        emptySafe(subj),
        @intCast(subj.len),
        @intCast(startpos),
        @intCast(max_matches),
        buf.ptr,
        @intCast(cap),
        &nmatches,
        &ngroups_out,
        &out_err,
    );
    if (out_err) |e| GoogleSQL_Free(e);
    if (rc != 0) return error.RegexpCompile;
    const n: usize = @intCast(nmatches);
    return .{ .offsets = buf[0 .. n * nsub * 2], .nmatches = n, .ngroups = ngroups };
}

/// RE2::GlobalReplace with \1-style rewrites. Result is arena-allocated.
pub fn replace(
    alloc: std.mem.Allocator,
    pat: []const u8,
    subj: []const u8,
    rewrite: []const u8,
) Error![]u8 {
    var out: ?[*]u8 = null;
    var out_len: c_int = 0;
    var out_err: ?[*:0]u8 = null;
    const rc = GoogleSQL_RegexpReplace(
        emptySafe(pat),
        @intCast(pat.len),
        emptySafe(subj),
        @intCast(subj.len),
        emptySafe(rewrite),
        @intCast(rewrite.len),
        &out,
        &out_len,
        &out_err,
    );
    if (rc != 0) {
        if (out_err) |e| GoogleSQL_Free(e);
        return error.RegexpCompile;
    }
    defer if (out) |p| GoogleSQL_Free(p);
    const src = (out orelse return error.RegexpCompile)[0..@intCast(out_len)];
    return alloc.dupe(u8, src);
}

pub const NormalizeMode = enum { nfc, nfd, nfkc, nfkd };

/// ICU Unicode normalization (UTF-8 in/out). Result is arena-allocated.
pub fn normalize(alloc: std.mem.Allocator, mode: NormalizeMode, in: []const u8) Error![]u8 {
    const mode_str: [*:0]const u8 = switch (mode) {
        .nfc => "NFC",
        .nfd => "NFD",
        .nfkc => "NFKC",
        .nfkd => "NFKD",
    };
    var out: ?[*]u8 = null;
    var out_len: c_int = 0;
    var out_err: ?[*:0]u8 = null;
    const rc = GoogleSQL_Normalize(
        mode_str,
        emptySafe(in),
        @intCast(in.len),
        &out,
        &out_len,
        &out_err,
    );
    if (rc != 0) {
        if (out_err) |e| GoogleSQL_Free(e);
        return error.Normalize;
    }
    defer if (out) |p| GoogleSQL_Free(p);
    const src = (out orelse return error.Normalize)[0..@intCast(out_len)];
    return alloc.dupe(u8, src);
}

/// Simple (per-code-point) Unicode case mapping matching Go's
/// strings.To{Upper,Lower}. Result is arena-allocated.
pub fn caseMap(alloc: std.mem.Allocator, upper: bool, in: []const u8) Error![]u8 {
    var out: ?[*]u8 = null;
    var out_len: c_int = 0;
    const rc = GoogleSQL_CaseMap(
        if (upper) 0 else 1,
        emptySafe(in),
        @intCast(in.len),
        &out,
        &out_len,
    );
    if (rc != 0) {
        if (out) |p| GoogleSQL_Free(p);
        return error.Normalize;
    }
    defer if (out) |p| GoogleSQL_Free(p);
    const src = (out orelse return error.Normalize)[0..@intCast(out_len)];
    return alloc.dupe(u8, src);
}

/// Offset (seconds east of UTC, raw+DST) for `zone` at `date_millis` (a UTC
/// instant, milliseconds since epoch), resolved against ICU's IANA tzdata.
/// `zone` is an IANA/Olson ID ("America/Chicago") or an ICU custom ID.
pub fn timeZoneOffsetSeconds(zone: []const u8, date_millis: i64) Error!i32 {
    var out_offset: i32 = 0;
    var out_err: ?[*:0]u8 = null;
    const rc = GoogleSQL_TimeZoneOffsetSeconds(
        emptySafe(zone),
        @intCast(zone.len),
        date_millis,
        &out_offset,
        &out_err,
    );
    if (out_err) |e| GoogleSQL_Free(e);
    if (rc != 0) return error.InvalidTimeZone;
    return out_offset;
}

/// A [*]const u8 that is safe to pass for a zero-length slice (whose .ptr may
/// be undefined); the C side reads 0 bytes.
fn emptySafe(s: []const u8) [*]const u8 {
    if (s.len == 0) return @ptrCast(&dummy_byte);
    return s.ptr;
}
var dummy_byte: u8 = 0;
