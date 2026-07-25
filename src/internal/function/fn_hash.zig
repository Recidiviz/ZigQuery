//! Port of go-zetasqlite internal/function_hash.go and
//! internal/function_security.go (SESSION_USER).
//!
//! MD5/SHA1/SHA256/SHA512 hash the argument's byte form and return BYTES
//! (Go: BytesValue). FARM_FINGERPRINT returns the farmhash64 fingerprint as a
//! signed INT64 (Go: IntValue(farm.Fingerprint64(v)), a uint64->int64 cast).
//! SESSION_USER returns the fixed string "dummy" (Go function_security.go).

const std = @import("std");
const bind = @import("bind.zig");

const value_mod = bind.value_mod;
const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

// ----------------------------------------------------------------------
// Cryptographic hashes (Go crypto/md5, crypto/sha1, crypto/sha256, crypto/sha512)
// ----------------------------------------------------------------------

fn hashBytes(comptime H: type, alloc: std.mem.Allocator, comptime name: []const u8, args: []const Value) Error!Value {
    if (args.len != 1) return bind.fail(name ++ ": invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const v = try args[0].toBytes(alloc);
    var out: [H.digest_length]u8 = undefined;
    H.hash(v, &out, .{});
    return Value{ .bytes = try alloc.dupe(u8, &out) };
}

pub fn md5(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return hashBytes(std.crypto.hash.Md5, alloc, "MD5", args);
}

pub fn sha1(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return hashBytes(std.crypto.hash.Sha1, alloc, "SHA1", args);
}

pub fn sha256(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return hashBytes(std.crypto.hash.sha2.Sha256, alloc, "SHA256", args);
}

pub fn sha512(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return hashBytes(std.crypto.hash.sha2.Sha512, alloc, "SHA512", args);
}

// ----------------------------------------------------------------------
// FARM_FINGERPRINT (Go: github.com/dgryski/go-farm Fingerprint64 == naHash64)
// ----------------------------------------------------------------------

pub fn farmFingerprint(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return bind.fail("FARM_FINGERPRINT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const v = try args[0].toBytes(alloc);
    // Go: IntValue(farm.Fingerprint64(v)) — the uint64 is reinterpreted as int64.
    return Value{ .int = @bitCast(fingerprint64(v)) };
}

// ----------------------------------------------------------------------
// SESSION_USER (Go function_security.go)
// ----------------------------------------------------------------------

pub fn sessionUser(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = args;
    return Value{ .string = try alloc.dupe(u8, "dummy") };
}

// ======================================================================
// farmhash Fingerprint64 (port of dgryski/go-farm naHash64 + helpers).
// ======================================================================

const k0: u64 = 0xc3a5c85c97cb3127;
const k1: u64 = 0xb492b66fbe98f273;
const k2: u64 = 0x9ae16a3b2f90404f;

inline fn rol(x: u64, comptime shift: u6) u64 {
    // Go bits.RotateLeft64(x, -shift) is a right rotation by `shift`.
    return std.math.rotr(u64, x, shift);
}

inline fn load64(s: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, s[off..][0..8], .little);
}

inline fn load32(s: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, s[off..][0..4], .little);
}

inline fn shiftMix(val: u64) u64 {
    return val ^ (val >> 47);
}

inline fn hash128to64(lo: u64, hi: u64) u64 {
    const mul: u64 = 0x9ddfea08eb382d69;
    var a = (lo ^ hi) *% mul;
    a ^= (a >> 47);
    var b = (hi ^ a) *% mul;
    b ^= (b >> 47);
    b *%= mul;
    return b;
}

inline fn hashLen16(u: u64, v: u64) u64 {
    return hash128to64(u, v);
}

inline fn hashLen16Mul(u: u64, v: u64, mul: u64) u64 {
    var a = (u ^ v) *% mul;
    a ^= (a >> 47);
    var b = (v ^ a) *% mul;
    b ^= (b >> 47);
    b *%= mul;
    return b;
}

fn hashLen0to16(s: []const u8) u64 {
    const slen: u64 = s.len;
    if (slen >= 8) {
        const mul = k2 +% slen *% 2;
        const a = load64(s, 0) +% k2;
        const b = load64(s, s.len - 8);
        const c = rol(b, 37) *% mul +% a;
        const d = (rol(a, 25) +% b) *% mul;
        return hashLen16Mul(c, d, mul);
    }
    if (slen >= 4) {
        const mul = k2 +% slen *% 2;
        const a: u64 = load32(s, 0);
        return hashLen16Mul(slen +% (a << 3), load32(s, s.len - 4), mul);
    }
    if (slen > 0) {
        const a: u32 = s[0];
        const b: u32 = s[s.len >> 1];
        const c: u32 = s[s.len - 1];
        const y: u32 = a +% (b << 8);
        const z: u32 = @as(u32, @intCast(slen)) +% (c << 2);
        return shiftMix(@as(u64, y) *% k2 ^ @as(u64, z) *% k0) *% k2;
    }
    return k2;
}

fn hashLen17to32(s: []const u8) u64 {
    const slen = s.len;
    const mul = k2 +% @as(u64, slen) *% 2;
    const a = load64(s, 0) *% k1;
    const b = load64(s, 8);
    const c = load64(s, slen - 8) *% mul;
    const d = load64(s, slen - 16) *% k2;
    return hashLen16Mul(rol(a +% b, 43) +% rol(c, 30) +% d, a +% rol(b +% k2, 18) +% c, mul);
}

const WeakHash = struct { lo: u64, hi: u64 };

fn weakHashLen32WithSeedsWords(w: u64, x: u64, y: u64, z: u64, a_in: u64, b_in: u64) WeakHash {
    var a = a_in;
    var b = b_in;
    a +%= w;
    b = rol(b +% a +% z, 21);
    const c = a;
    a +%= x;
    a +%= y;
    b +%= rol(a, 44);
    return .{ .lo = a +% z, .hi = b +% c };
}

fn weakHashLen32WithSeeds(s: []const u8, a: u64, b: u64) WeakHash {
    return weakHashLen32WithSeedsWords(load64(s, 0), load64(s, 8), load64(s, 16), load64(s, 24), a, b);
}

fn hashLen33to64(s: []const u8) u64 {
    const slen = s.len;
    const mul = k2 +% @as(u64, slen) *% 2;
    const a = load64(s, 0) *% k2;
    const b = load64(s, 8);
    const c = load64(s, slen - 8) *% mul;
    const d = load64(s, slen - 16) *% k2;
    const y = rol(a +% b, 43) +% rol(c, 30) +% d;
    const z = hashLen16Mul(y, a +% rol(b +% k2, 18) +% c, mul);
    const e = load64(s, 16) *% mul;
    const f = load64(s, 24);
    const g = (y +% load64(s, slen - 32)) *% mul;
    const h = (z +% load64(s, slen - 24)) *% mul;
    return hashLen16Mul(rol(e +% f, 43) +% rol(g, 30) +% h, e +% rol(f +% a, 18) +% g, mul);
}

/// dgryski/go-farm Fingerprint64 == naHash64.
pub fn fingerprint64(input: []const u8) u64 {
    var s = input;
    const slen = s.len;
    const seed: u64 = 81;
    if (slen <= 32) {
        if (slen <= 16) return hashLen0to16(s);
        return hashLen17to32(s);
    }
    if (slen <= 64) return hashLen33to64(s);

    // For strings over 64 bytes we loop over 64-byte chunks.
    var v = WeakHash{ .lo = 0, .hi = 0 };
    var w = WeakHash{ .lo = 0, .hi = 0 };
    var x = seed *% k2 +% load64(s, 0);
    var y = seed *% k1 +% 113;
    var z = shiftMix(y *% k2 +% 113) *% k2;
    const end_idx = ((slen - 1) / 64) * 64;
    const last64_idx = end_idx + ((slen - 1) & 63) - 63;
    const last64 = input[last64_idx..];

    while (s.len > 64) {
        x = rol(x +% y +% v.lo +% load64(s, 8), 37) *% k1;
        y = rol(y +% v.hi +% load64(s, 48), 42) *% k1;
        x ^= w.hi;
        y +%= v.lo +% load64(s, 40);
        z = rol(z +% w.lo, 33) *% k1;
        v = weakHashLen32WithSeeds(s, v.hi *% k1, x +% w.lo);
        w = weakHashLen32WithSeeds(s[32..], z +% w.hi, y +% load64(s, 16));
        const tmp = x;
        x = z;
        z = tmp;
        s = s[64..];
    }
    const mul = k1 +% ((z & 0xff) << 1);
    s = last64;
    w.lo +%= (@as(u64, slen - 1) & 63);
    v.lo +%= w.lo;
    w.lo +%= v.lo;
    x = rol(x +% y +% v.lo +% load64(s, 8), 37) *% mul;
    y = rol(y +% v.hi +% load64(s, 48), 42) *% mul;
    x ^= w.hi *% 9;
    y +%= v.lo *% 9 +% load64(s, 40);
    z = rol(z +% w.lo, 33) *% mul;
    v = weakHashLen32WithSeeds(s, v.hi *% mul, x +% w.lo);
    w = weakHashLen32WithSeeds(s[32..], z +% w.hi, y +% load64(s, 16));
    const tmp = x;
    x = z;
    z = tmp;
    return hashLen16Mul(hashLen16Mul(v.lo, w.lo, mul) +% shiftMix(y) *% k0 +% z, hashLen16Mul(v.hi, w.hi, mul) +% x, mul);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "farm_fingerprint matches go-farm test vectors" {
    // Vectors from the corpus (Go farm.Fingerprint64 reinterpreted as int64).
    try testing.expectEqual(@as(i64, -1541654101129638711), @as(i64, @bitCast(fingerprint64("1footrue"))));
    try testing.expectEqual(@as(i64, 2794438866806483259), @as(i64, @bitCast(fingerprint64("2applefalse"))));
    try testing.expectEqual(@as(i64, -4880158226897771312), @as(i64, @bitCast(fingerprint64("3true"))));
}

test "farm_fingerprint empty and known" {
    // go-farm Fingerprint64("") == k2.
    try testing.expectEqual(@as(u64, 0x9ae16a3b2f90404f), fingerprint64(""));
}

test "md5/sha hashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const md5v = try md5(alloc, &.{.{ .string = "Hello World" }});
    // MD5("Hello World") = b10a8db164e0754105b7a99be72e3fe5
    const md5_expected = [_]u8{ 0xb1, 0x0a, 0x8d, 0xb1, 0x64, 0xe0, 0x75, 0x41, 0x05, 0xb7, 0xa9, 0x9b, 0xe7, 0x2e, 0x3f, 0xe5 };
    try testing.expectEqualSlices(u8, &md5_expected, md5v.bytes);

    const s256 = try sha256(alloc, &.{.{ .string = "Hello World" }});
    try testing.expectEqual(@as(usize, 32), s256.bytes.len);

    // NULL argument yields NULL.
    try testing.expect((try md5(alloc, &.{null_v})) == .@"null");
}

test "session_user returns dummy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const v = try sessionUser(alloc, &.{});
    try testing.expectEqualStrings("dummy", v.string);
}
