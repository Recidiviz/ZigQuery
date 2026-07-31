//! Faithful port of go-zetasqlite internal/value.go.
//!
//! All value kinds are ported: Null, Int, Float, Bool, String, Bytes, Json,
//! Date, Datetime, Time, Timestamp, Interval, Numeric/BigNumeric, Array,
//! Struct, and the SafeValue wrapper.
//!
//! Go represents SQL NULL as a nil Value interface; here it is the `.null`
//! variant. Where Go would panic on a nil method call, we return
//! error.NullValue.
//!
//! Memory: methods that build new values/strings take an allocator; decode
//! trees are expected to live in an arena (no per-value deinit is provided).

const std = @import("std");

pub const ValueError = error{
    NullValue,
    FailedConversion,
    UnsupportedOperation,
    DivideByZero,
    InvalidDate,
    CorruptData,
    Unimplemented,
    /// A NUMERIC/BIGNUMERIC outside the range its declared precision allows.
    /// Distinct from FailedConversion because the value converted fine — it is
    /// the magnitude that the type cannot hold.
    NumericOutOfRange,
    OutOfMemory,
};

/// Optional diagnostic for the most recent error on this thread. Either a
/// static string or a slice of `diag_buf` below. Mirrors the Go messages.
pub threadlocal var diagnostic: ?[]const u8 = null;

/// Backing store for diagnostics that interpolate runtime values (Go's
/// fmt.Errorf with a %v/%s verb), e.g. StringValue.ToTime's
/// "failed to convert %s to time.Time type". Same approach as bind.zig's
/// message buffer: threadlocal and overwritten by each failure.
threadlocal var diag_buf: [256]u8 = undefined;

fn fail(comptime msg: []const u8, err: ValueError) ValueError {
    diagnostic = msg;
    return err;
}

/// fail() for messages carrying runtime values; falls back to the format
/// string itself if the rendering would overflow the buffer.
fn failFmt(comptime fmt: []const u8, args: anytype, err: ValueError) ValueError {
    diagnostic = std.fmt.bufPrint(&diag_buf, fmt, args) catch fmt;
    return err;
}

pub const ArrayValue = struct {
    values: []Value,
};

/// Faithful port of cloud.google.com/go/bigquery.IntervalValue, the payload
/// go-zetasqlite's *IntervalValue wraps. Stored inline (Go heap-allocates it).
pub const Interval = struct {
    years: i32 = 0,
    months: i32 = 0,
    days: i32 = 0,
    hours: i32 = 0,
    minutes: i32 = 0,
    seconds: i32 = 0,
    sub_second_nanos: i32 = 0,
};

// Microsecond scale factors and the civil-time constants shared by the
// timestamp / datetime / time value kinds (all UTC; Go uses time.Time with
// locations, the corpus pins TZ=UTC — see module docs).
pub const day_micros: i64 = 86_400_000_000;
pub const hour_micros: i64 = 3_600_000_000;
pub const minute_micros: i64 = 60_000_000;
pub const second_micros: i64 = 1_000_000;
/// time.Date(0, 0, 0, 0, 0, 0, 0, time.UTC).UnixMicro(): the Go "zero" civil
/// date that TimeValue is anchored to (time-of-day micros are added on top).
pub const time_base_micros: i64 = -62_169_984_000_000_000;

pub const StructValue = struct {
    keys: [][]const u8,
    values: []Value,

    /// Linear lookup (key counts are small; Go keeps a map, we do not).
    /// Returns the first field with the given name, like Go's map would
    /// return the (deduplicated) entry.
    pub fn fieldByName(self: *const StructValue, name: []const u8) ?Value {
        for (self.keys, self.values) |k, v| {
            if (std.mem.eql(u8, k, name)) return v;
        }
        return null;
    }
};

// Shared zero-value results used by the SafeValue error-swallowing paths
// (Go returns &ArrayValue{} / &StructValue{} there).
var empty_array_storage = ArrayValue{ .values = &[0]Value{} };
var empty_struct_storage = StructValue{ .keys = &[0][]const u8{}, .values = &[0]Value{} };

// ----------------------------------------------------------------------
// NUMERIC / BIGNUMERIC (Go NumericValue: {*big.Rat, isBigNumeric}).
// Zig 0.16 has no std.math.big.Rational, so Rat reimplements the math/big.Rat
// subset go-zetasqlite exercises on top of std.math.big.int.Managed.
// ----------------------------------------------------------------------

const big_int = std.math.big.int;

/// Arbitrary-precision rational mirroring Go's big.Rat invariants: the
/// denominator is always positive and the fraction is kept gcd-reduced
/// (zero is 0/1). Operations are non-mutating and allocate from `alloc`;
/// like the rest of the value tree they are arena-friendly (temporary
/// big-int limbs are not individually freed).
pub const Rat = struct {
    num: big_int.Managed,
    den: big_int.Managed,

    pub fn initInt(alloc: std.mem.Allocator, v: i64) ValueError!Rat {
        return .{
            .num = big_int.Managed.initSet(alloc, v) catch return error.OutOfMemory,
            .den = big_int.Managed.initSet(alloc, 1) catch return error.OutOfMemory,
        };
    }

    /// Go big.Rat.SetString subset: "[+-]digits[.digits][eE[+-]digits]" or
    /// the fraction form "[+-]digits/digits". The whole string must match.
    pub fn setString(alloc: std.mem.Allocator, s: []const u8) ValueError!Rat {
        if (s.len == 0) return error.FailedConversion;
        if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
            const num_part = s[0..slash];
            const den_part = s[slash + 1 ..];
            var r = Rat{
                .num = try signedIntFromDecimal(alloc, num_part),
                .den = try unsignedIntFromDecimal(alloc, den_part),
            };
            if (r.den.eqlZero()) return error.FailedConversion; // Go: SetString fails on /0
            try r.normalize(alloc);
            return r;
        }
        var rest = s;
        var negative = false;
        if (rest[0] == '+' or rest[0] == '-') {
            negative = rest[0] == '-';
            rest = rest[1..];
        }
        // Mantissa: digits with at most one '.', at least one digit total.
        var digits_buf: std.ArrayList(u8) = .empty;
        defer digits_buf.deinit(alloc);
        var frac_digits: usize = 0;
        var seen_dot = false;
        var seen_digit = false;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const c = rest[i];
            if (c == '.') {
                if (seen_dot) return error.FailedConversion;
                seen_dot = true;
            } else if (std.ascii.isDigit(c)) {
                seen_digit = true;
                digits_buf.append(alloc, c) catch return error.OutOfMemory;
                if (seen_dot) frac_digits += 1;
            } else if (c == 'e' or c == 'E') {
                break;
            } else {
                return error.FailedConversion;
            }
        }
        if (!seen_digit) return error.FailedConversion;
        var exp10: i64 = 0;
        if (i < rest.len) {
            // Exponent part ("e" is at rest[i]).
            exp10 = std.fmt.parseInt(i64, rest[i + 1 ..], 10) catch
                return error.FailedConversion;
            if (exp10 > 1 << 20 or exp10 < -(1 << 20)) return error.FailedConversion;
        }
        var num = try mustManaged(alloc);
        if (digits_buf.items.len > 0) {
            num.setString(10, digits_buf.items) catch return error.FailedConversion;
        }
        if (negative and !num.eqlZero()) num.negate();
        const scale: i64 = exp10 - @as(i64, @intCast(frac_digits));
        var r = Rat{ .num = num, .den = try powTen(alloc, 0) };
        if (scale > 0) {
            const p = try powTen(alloc, @intCast(scale));
            var scaled = try mustManaged(alloc);
            scaled.mul(&r.num, &p) catch return error.OutOfMemory;
            r.num = scaled;
        } else if (scale < 0) {
            r.den = try powTen(alloc, @intCast(-scale));
        }
        try r.normalize(alloc);
        return r;
    }

    /// Go big.Rat.SetFloat64: the exact binary expansion of a finite f64.
    pub fn setFloat64(alloc: std.mem.Allocator, f: f64) ValueError!Rat {
        if (!std.math.isFinite(f)) return error.FailedConversion; // Go returns nil
        const bits: u64 = @bitCast(f);
        const negative = (bits >> 63) != 0;
        const biased: i32 = @intCast((bits >> 52) & 0x7FF);
        const frac: u64 = bits & ((@as(u64, 1) << 52) - 1);
        var mant: u64 = undefined;
        var exp2: i32 = undefined;
        if (biased == 0) {
            mant = frac; // subnormal
            exp2 = -1074;
        } else {
            mant = frac | (@as(u64, 1) << 52);
            exp2 = biased - 1075;
        }
        if (mant == 0) return initInt(alloc, 0);
        var num = big_int.Managed.initSet(alloc, mant) catch return error.OutOfMemory;
        var den = big_int.Managed.initSet(alloc, 1) catch return error.OutOfMemory;
        if (exp2 >= 0) {
            num.shiftLeft(&num, @intCast(exp2)) catch return error.OutOfMemory;
        } else {
            den.shiftLeft(&den, @intCast(-exp2)) catch return error.OutOfMemory;
        }
        if (negative) num.negate();
        var r = Rat{ .num = num, .den = den };
        try r.normalize(alloc);
        return r;
    }

    /// Rat from a little-endian two's-complement integer scaled by 10^scale
    /// (googlesql's NUMERIC/BIGNUMERIC proto serialization).
    pub fn fromScaledTwosComplement(
        alloc: std.mem.Allocator,
        bytes: []const u8,
        scale: usize,
    ) ValueError!Rat {
        var num = try mustManaged(alloc);
        if (bytes.len > 0) {
            num.ensureTwosCompCapacity(bytes.len * 8) catch return error.OutOfMemory;
            var m = num.toMutable();
            m.readTwosComplement(bytes, bytes.len * 8, .little, .signed);
            num.setMetadata(m.positive, m.len);
        }
        var r = Rat{ .num = num, .den = try powTen(alloc, scale) };
        try r.normalize(alloc);
        return r;
    }

    pub fn isZero(self: Rat) bool {
        return self.num.eqlZero();
    }

    fn isNegative(self: Rat) bool {
        return !self.num.isPositive() and !self.num.eqlZero();
    }

    /// Reduce to lowest terms with a positive denominator (Go's invariant).
    fn normalize(self: *Rat, alloc: std.mem.Allocator) ValueError!void {
        if (self.den.eqlZero()) return fail("division by zero", error.DivideByZero);
        if (!self.den.isPositive()) {
            self.den.negate();
            if (!self.num.eqlZero()) self.num.negate();
        }
        if (self.num.eqlZero()) {
            self.num.set(0) catch return error.OutOfMemory;
            self.den.set(1) catch return error.OutOfMemory;
            return;
        }
        var g = try mustManaged(alloc);
        g.gcd(&self.num, &self.den) catch return error.OutOfMemory;
        if (g.toConst().orderAgainstScalar(1) == .gt) {
            var q = try mustManaged(alloc);
            var rem = try mustManaged(alloc);
            q.divTrunc(&rem, &self.num, &g) catch return error.OutOfMemory;
            self.num.swap(&q);
            q.divTrunc(&rem, &self.den, &g) catch return error.OutOfMemory;
            self.den.swap(&q);
        }
    }

    pub fn add(a: Rat, alloc: std.mem.Allocator, b: Rat) ValueError!Rat {
        return a.addSub(alloc, b, false);
    }

    pub fn sub(a: Rat, alloc: std.mem.Allocator, b: Rat) ValueError!Rat {
        return a.addSub(alloc, b, true);
    }

    fn addSub(a: Rat, alloc: std.mem.Allocator, b: Rat, subtract: bool) ValueError!Rat {
        var t1 = try mustManaged(alloc);
        t1.mul(&a.num, &b.den) catch return error.OutOfMemory;
        var t2 = try mustManaged(alloc);
        t2.mul(&b.num, &a.den) catch return error.OutOfMemory;
        var n = try mustManaged(alloc);
        if (subtract) {
            n.sub(&t1, &t2) catch return error.OutOfMemory;
        } else {
            n.add(&t1, &t2) catch return error.OutOfMemory;
        }
        var d = try mustManaged(alloc);
        d.mul(&a.den, &b.den) catch return error.OutOfMemory;
        var r = Rat{ .num = n, .den = d };
        try r.normalize(alloc);
        return r;
    }

    pub fn mul(a: Rat, alloc: std.mem.Allocator, b: Rat) ValueError!Rat {
        var n = try mustManaged(alloc);
        n.mul(&a.num, &b.num) catch return error.OutOfMemory;
        var d = try mustManaged(alloc);
        d.mul(&a.den, &b.den) catch return error.OutOfMemory;
        var r = Rat{ .num = n, .den = d };
        try r.normalize(alloc);
        return r;
    }

    /// Go NumericValue.Div reaches big.Rat.Inv, which panics on a zero
    /// divisor with "division by zero"; surface that as DivideByZero.
    pub fn div(a: Rat, alloc: std.mem.Allocator, b: Rat) ValueError!Rat {
        if (b.isZero()) return fail("division by zero", error.DivideByZero);
        var n = try mustManaged(alloc);
        n.mul(&a.num, &b.den) catch return error.OutOfMemory;
        var d = try mustManaged(alloc);
        d.mul(&a.den, &b.num) catch return error.OutOfMemory;
        var r = Rat{ .num = n, .den = d };
        try r.normalize(alloc);
        return r;
    }

    /// Go big.Rat.Cmp: order of a/b vs c/d via a*d <=> c*b (denominators
    /// are positive by invariant).
    pub fn cmp(a: Rat, alloc: std.mem.Allocator, b: Rat) ValueError!std.math.Order {
        var l = try mustManaged(alloc);
        l.mul(&a.num, &b.den) catch return error.OutOfMemory;
        var r = try mustManaged(alloc);
        r.mul(&b.num, &a.den) catch return error.OutOfMemory;
        return l.order(r);
    }

    /// Go big.Rat.Num().Int64(): the *numerator* projected onto int64 (low
    /// word of the magnitude, sign applied) — a Go quirk kept bug-for-bug.
    pub fn numLowInt64(self: Rat) i64 {
        const low: u64 = if (self.num.len() > 0) self.num.limbs[0] else 0;
        const v: i64 = @bitCast(low);
        return if (self.num.isPositive()) v else -%v;
    }

    /// Go big.Rat.Float64 (approximately: correctly-rounded operands, one
    /// f64 division; at most 1 ulp off Go for extreme magnitudes).
    pub fn toFloat64(self: Rat) f64 {
        const n = self.num.toFloat(f64, .nearest_even)[0];
        const d = self.den.toFloat(f64, .nearest_even)[0];
        return n / d;
    }

    /// Go big.Rat.RatString / MarshalText: "n/d" when den != 1, else "n"
    /// (this is the binary-codec payload, so the format must match exactly).
    pub fn ratString(self: Rat, alloc: std.mem.Allocator) ValueError![]u8 {
        const ns = self.num.toString(alloc, 10, .lower) catch return error.OutOfMemory;
        if (self.den.toConst().orderAgainstScalar(1) == .eq) return ns;
        defer alloc.free(ns);
        const ds = self.den.toString(alloc, 10, .lower) catch return error.OutOfMemory;
        defer alloc.free(ds);
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ ns, ds }) catch return error.OutOfMemory;
    }

    /// The value times 10^scale, rounded to an integer half away from zero.
    ///
    /// This is `floatString`'s arithmetic in one step rather than two: that
    /// splits into `trunc(|n|/d)` and `round(rem * 10^scale / d)` and
    /// concatenates them, which is `round(|n| * 10^scale / d)`. Written once,
    /// here, so the engine has exactly one rounding rule — a second
    /// implementation that drifted would round values one way and render them
    /// another.
    pub fn toUnscaled(self: Rat, alloc: std.mem.Allocator, scale: usize) ValueError!big_int.Managed {
        var absn = self.num.cloneWithDifferentAllocator(alloc) catch return error.OutOfMemory;
        absn.abs();
        const p10 = try powTen(alloc, scale);
        var scaled = try mustManaged(alloc);
        scaled.mul(&absn, &p10) catch return error.OutOfMemory;

        var q = try mustManaged(alloc);
        var rem = try mustManaged(alloc);
        q.divTrunc(&rem, &scaled, &self.den) catch return error.OutOfMemory;
        // Half away from zero: the same `2*rem >= den` test floatString uses.
        var twice = try mustManaged(alloc);
        twice.add(&rem, &rem) catch return error.OutOfMemory;
        if (twice.order(self.den) != .lt) q.addScalar(&q, 1) catch return error.OutOfMemory;

        if (self.isNegative() and !q.eqlZero()) q.negate();
        return q;
    }

    /// Rounds in place to `scale` decimal places and returns the unscaled
    /// integer it landed on.
    ///
    /// Establishes the invariant `10^scale % den == 0`, which is what makes a
    /// fixed-width memcomparable encoding possible at all — see
    /// codec_sortable.zig. The i256 conversion doubles as BIGNUMERIC's range
    /// check, since that type's unscaled domain is exactly i256's.
    pub fn roundToScale(self: *Rat, alloc: std.mem.Allocator, scale: usize) ValueError!i256 {
        var unscaled = try self.toUnscaled(alloc, scale);
        const as_int = unscaled.toInt(i256) catch
            return fail("numeric value out of range", error.NumericOutOfRange);
        self.num.swap(&unscaled);
        var p10 = try powTen(alloc, scale);
        self.den.swap(&p10);
        // normalize gcd-reduces, so `den` ends up a divisor of 10^scale rather
        // than 10^scale itself: 1.5 stays 3/2, not 15/10.
        try self.normalize(alloc);
        return as_int;
    }

    /// The unscaled integer for an already-rounded Rat. Exact by the invariant
    /// `roundToScale` establishes, so this does no rounding of its own.
    pub fn unscaledInt(self: Rat, alloc: std.mem.Allocator, scale: usize) ValueError!i256 {
        var m = try self.toUnscaled(alloc, scale);
        return m.toInt(i256) catch
            fail("numeric value out of range", error.NumericOutOfRange);
    }

    /// Go big.Rat.FloatString(prec): decimal form with exactly `prec` digits
    /// after the point; the last digit is rounded to nearest, halves away
    /// from zero. A negative value always renders its '-' (even "-0.000...").
    pub fn floatString(self: Rat, alloc: std.mem.Allocator, prec: usize) ValueError![]u8 {
        var absn = self.num.cloneWithDifferentAllocator(alloc) catch return error.OutOfMemory;
        absn.abs();
        var q = try mustManaged(alloc);
        var rem = try mustManaged(alloc);
        q.divTrunc(&rem, &absn, &self.den) catch return error.OutOfMemory;

        const p10 = try powTen(alloc, prec);
        var scaled = try mustManaged(alloc);
        scaled.mul(&rem, &p10) catch return error.OutOfMemory;
        var fd = try mustManaged(alloc);
        var rem2 = try mustManaged(alloc);
        fd.divTrunc(&rem2, &scaled, &self.den) catch return error.OutOfMemory;
        // Round half away from zero: 2*rem2 >= den -> bump the last digit.
        var twice = try mustManaged(alloc);
        twice.add(&rem2, &rem2) catch return error.OutOfMemory;
        if (twice.order(self.den) != .lt) {
            fd.addScalar(&fd, 1) catch return error.OutOfMemory;
            if (fd.order(p10) != .lt) {
                fd.set(0) catch return error.OutOfMemory;
                q.addScalar(&q, 1) catch return error.OutOfMemory;
            }
        }

        const q_str = q.toString(alloc, 10, .lower) catch return error.OutOfMemory;
        defer alloc.free(q_str);
        const fd_str = fd.toString(alloc, 10, .lower) catch return error.OutOfMemory;
        defer alloc.free(fd_str);

        const sign_len: usize = if (self.isNegative()) 1 else 0;
        const frac_len: usize = if (prec > 0) 1 + prec else 0;
        const out = alloc.alloc(u8, sign_len + q_str.len + frac_len) catch return error.OutOfMemory;
        var w: usize = 0;
        if (sign_len == 1) {
            out[0] = '-';
            w = 1;
        }
        @memcpy(out[w .. w + q_str.len], q_str);
        w += q_str.len;
        if (prec > 0) {
            out[w] = '.';
            w += 1;
            const pad = prec - fd_str.len;
            @memset(out[w .. w + pad], '0');
            w += pad;
            @memcpy(out[w .. w + fd_str.len], fd_str);
        }
        return out;
    }
};

fn mustManaged(alloc: std.mem.Allocator) ValueError!big_int.Managed {
    return big_int.Managed.init(alloc) catch error.OutOfMemory;
}

fn powTen(alloc: std.mem.Allocator, e: usize) ValueError!big_int.Managed {
    if (e == 0) return big_int.Managed.initSet(alloc, 1) catch error.OutOfMemory;
    var ten = big_int.Managed.initSet(alloc, 10) catch return error.OutOfMemory;
    var out = try mustManaged(alloc);
    out.pow(&ten, @intCast(e)) catch return error.OutOfMemory;
    return out;
}

/// Decimal digits (no sign) -> big int; every byte must be a digit.
fn unsignedIntFromDecimal(alloc: std.mem.Allocator, s: []const u8) ValueError!big_int.Managed {
    if (s.len == 0) return error.FailedConversion;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.FailedConversion;
    var m = try mustManaged(alloc);
    m.setString(10, s) catch return error.FailedConversion;
    return m;
}

fn signedIntFromDecimal(alloc: std.mem.Allocator, s_in: []const u8) ValueError!big_int.Managed {
    var s = s_in;
    var negative = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        negative = s[0] == '-';
        s = s[1..];
    }
    var m = try unsignedIntFromDecimal(alloc, s);
    if (negative and !m.eqlZero()) m.negate();
    return m;
}

/// NUMERIC is decimal(38,9) and BIGNUMERIC decimal(76,38), so each value is
/// exactly an integer at its scale. `numericValue` enforces that, which is what
/// lets both be stored memcomparably (codec_sortable.zig).
///
/// Scales, and the unscaled bounds their declared precision allows.
pub const numeric_scale: usize = 9;
pub const bignumeric_scale: usize = 38;
/// 10^38 - 1, i.e. NUMERIC's 38 digits. Comfortably inside i128.
pub const numeric_unscaled_max: i256 = 99999999999999999999999999999999999999;

pub fn scaleFor(is_bignumeric: bool) usize {
    return if (is_bignumeric) bignumeric_scale else numeric_scale;
}

/// Go NumericValue. `is_bignumeric` selects the scale — both the stored
/// precision and the rendered one (FloatString(38) vs FloatString(9)).
pub const Numeric = struct {
    rat: Rat,
    is_bignumeric: bool = false,

    /// Go NumericValue.toString: FloatString(9|38) with trailing zeros then
    /// a trailing '.' trimmed (shared by ToString/ToApiString/ToJSON/Format).
    pub fn toText(self: *const Numeric, alloc: std.mem.Allocator) ValueError![]u8 {
        const prec: usize = if (self.is_bignumeric) 38 else 9;
        const s = try self.rat.floatString(alloc, prec);
        var end = s.len;
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
        return s[0..end];
    }
};

pub const Value = union(enum) {
    @"null",
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,
    /// JSON value (Go JsonValue): a raw JSON string payload. ToString/ToJSON
    /// return it verbatim; ToInt64/ToFloat64/ToBool parse the scalar text.
    json: []const u8,
    /// Civil days since the Unix epoch (Go stores a midnight-UTC time.Time;
    /// observable behavior is identical: ToInt64 => days*86400 (unix
    /// seconds), ToString => "YYYY-MM-DD").
    date: i64,
    /// TIMESTAMP: unix microseconds, UTC (Go stores time.Time; ToInt64 =>
    /// Unix() seconds, codec => fixed64 UnixMicro, ToApiString => "sec.rem").
    timestamp: i64,
    /// DATETIME: civil microseconds since 1970-01-01T00:00:00 treated as UTC
    /// (a wall-clock instant with no zone). ToString "2006-01-02 15:04:05.999999".
    datetime: i64,
    /// TIME: microseconds since midnight, [0, 86_400_000_000). ToString
    /// "15:04:05.999999".
    time: i64,
    /// INTERVAL: bigquery.IntervalValue components (Go wraps it in *IntervalValue).
    interval: Interval,
    /// NUMERIC / BIGNUMERIC (Go *NumericValue); arena-allocated.
    numeric: *Numeric,
    array: *ArrayValue,
    struct_: *StructValue,
    /// SAFE. function-call wrapper: swallows errors, yielding NULL / zero
    /// values instead (mirrors Go *SafeValue).
    safe: *Value,

    // ------------------------------------------------------------------
    // Arithmetic (Go: Add/Sub/Mul/Div)
    // ------------------------------------------------------------------

    pub fn add(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .@"null" => return fail("add on null value", error.NullValue),
            .int => |i| return Value{ .int = i +% try v.toInt64() },
            .float => |f| return Value{ .float = f + try v.toFloat64() },
            .string => |s| {
                const s2 = try v.toString(alloc);
                const out = try alloc.alloc(u8, s.len + s2.len);
                @memcpy(out[0..s.len], s);
                @memcpy(out[s.len..], s2);
                return Value{ .string = out };
            },
            .bytes => |b| {
                const b2 = try v.toBytes(alloc);
                const out = try alloc.alloc(u8, b.len + b2.len);
                @memcpy(out[0..b.len], b);
                @memcpy(out[b.len..], b2);
                return Value{ .bytes = out };
            },
            .bool => return fail("add operation is unsupported for bool", error.UnsupportedOperation),
            .date => |days| switch (v) {
                // Go DateValue.Add: IntValue adds days; *IntervalValue promotes
                // to a DATETIME via calendar arithmetic.
                .int => |n| return Value{ .date = days +% n },
                .interval => |iv| return Value{ .datetime = addCalendar(days *% day_micros, iv, 1) },
                else => return fail("failed to use add operator for date", error.UnsupportedOperation),
            },
            // Go TimestampValue/DatetimeValue.Add: only INTERVAL is accepted
            // (calendar arithmetic); anything else errors.
            .timestamp => |m| switch (v) {
                .interval => |iv| return Value{ .timestamp = addCalendar(m, iv, 1) },
                else => return fail("failed to use add operator for timestamp", error.UnsupportedOperation),
            },
            .datetime => |m| switch (v) {
                .interval => |iv| return Value{ .datetime = addCalendar(m, iv, 1) },
                else => return fail("failed to use add operator for datetime", error.UnsupportedOperation),
            },
            .time => return fail("add operation is unsupported for time", error.UnsupportedOperation),
            .json => return fail("add operation is unsupported for json", error.UnsupportedOperation),
            .interval => return fail("unsupported add operator for interval value", error.UnsupportedOperation),
            // Go NumericValue.Add: rat arithmetic, result keeps isBigNumeric.
            .numeric => |n| return numericValue(
                alloc,
                try n.rat.add(alloc, try v.toRat(alloc)),
                // Widen to the wider operand: BigQuery coerces
                // NUMERIC op BIGNUMERIC to BIGNUMERIC, and rounding
                // the result to scale 9 would discard real digits.
                n.is_bignumeric or isBigNumeric(v),
            ),
            .array => return fail("add operation is unsupported for array", error.UnsupportedOperation),
            .struct_ => return fail("add operation is unsupported for struct", error.UnsupportedOperation),
            .safe => |p| return p.add(alloc, v) catch Value.@"null",
        }
    }

    pub fn sub(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .@"null" => return fail("sub on null value", error.NullValue),
            .int => |i| return Value{ .int = i -% try v.toInt64() },
            .float => |f| return Value{ .float = f - try v.toFloat64() },
            .string => return fail("sub operation is unsupported for string", error.UnsupportedOperation),
            .bytes => return fail("sub operation is unsupported for bytes", error.UnsupportedOperation),
            .bool => return fail("sub operation is unsupported for bool", error.UnsupportedOperation),
            .date => |days| switch (v) {
                .int => |n| return Value{ .date = days -% n },
                // Go DateValue.Sub: *IntervalValue -> DATETIME (calendar sub);
                // any other time-shaped value -> INTERVAL of whole days.
                .interval => |iv| return Value{ .datetime = addCalendar(days *% day_micros, iv, -1) },
                else => {
                    const dst = try timeMicrosForCompare(v);
                    const duration_days = @divTrunc(days *% day_micros -% dst, day_micros);
                    return Value{ .interval = .{ .days = @intCast(duration_days) } };
                },
            },
            // Go TimestampValue/DatetimeValue.Sub: INTERVAL => calendar sub;
            // otherwise => the difference as an INTERVAL (H:M:S.nanos duration).
            .timestamp => |m| switch (v) {
                .interval => |iv| return Value{ .timestamp = addCalendar(m, iv, -1) },
                else => return Value{ .interval = intervalFromDuration((m -% (try timeMicrosForCompare(v))) *% 1000) },
            },
            .datetime => |m| switch (v) {
                .interval => |iv| return Value{ .datetime = addCalendar(m, iv, -1) },
                else => return Value{ .interval = intervalFromDuration((m -% (try timeMicrosForCompare(v))) *% 1000) },
            },
            .time => return fail("sub operation is unsupported for time", error.UnsupportedOperation),
            .json => return fail("sub operation is unsupported for json", error.UnsupportedOperation),
            .interval => return fail("unsupported sub operator for interval value", error.UnsupportedOperation),
            .numeric => |n| return numericValue(
                alloc,
                try n.rat.sub(alloc, try v.toRat(alloc)),
                // Widen to the wider operand: BigQuery coerces
                // NUMERIC op BIGNUMERIC to BIGNUMERIC, and rounding
                // the result to scale 9 would discard real digits.
                n.is_bignumeric or isBigNumeric(v),
            ),
            .array => return fail("sub operation is unsupported for array", error.UnsupportedOperation),
            .struct_ => return fail("sub operation is unsupported for struct", error.UnsupportedOperation),
            .safe => |p| return p.sub(alloc, v) catch Value.@"null",
        }
    }

    pub fn mul(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .@"null" => return fail("mul on null value", error.NullValue),
            .int => |i| return Value{ .int = i *% try v.toInt64() },
            .float => |f| return Value{ .float = f * try v.toFloat64() },
            .numeric => |n| return numericValue(
                alloc,
                try n.rat.mul(alloc, try v.toRat(alloc)),
                // Widen to the wider operand: BigQuery coerces
                // NUMERIC op BIGNUMERIC to BIGNUMERIC, and rounding
                // the result to scale 9 would discard real digits.
                n.is_bignumeric or isBigNumeric(v),
            ),
            .safe => |p| return p.mul(alloc, v) catch Value.@"null",
            else => return fail("mul operation is unsupported for this type", error.UnsupportedOperation),
        }
    }

    pub fn div(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .@"null" => return fail("div on null value", error.NullValue),
            .int => |i| {
                const v2 = try v.toInt64();
                if (v2 == 0) return fail("zero divided error", error.DivideByZero);
                return Value{ .int = @divTrunc(i, v2) };
            },
            .float => |f| {
                const v2 = try v.toFloat64();
                // Go checks v2 == 0 for floats too (no Inf result).
                if (v2 == 0) return fail("zero divided error", error.DivideByZero);
                return Value{ .float = f / v2 };
            },
            .numeric => |n| return numericValue(
                alloc,
                try n.rat.div(alloc, try v.toRat(alloc)),
                // Widen to the wider operand: BigQuery coerces
                // NUMERIC op BIGNUMERIC to BIGNUMERIC, and rounding
                // the result to scale 9 would discard real digits.
                n.is_bignumeric or isBigNumeric(v),
            ),
            .safe => |p| return p.div(alloc, v) catch Value.@"null",
            else => return fail("div operation is unsupported for this type", error.UnsupportedOperation),
        }
    }

    // ------------------------------------------------------------------
    // Comparisons (Go: EQ/GT/GTE/LT/LTE). Allocation-free: scalar-to-string
    // coercions use stack scratch buffers.
    // ------------------------------------------------------------------

    pub fn eq(self: Value, v: Value) ValueError!bool {
        return self.compareOp(.eq, v);
    }
    pub fn gt(self: Value, v: Value) ValueError!bool {
        return self.compareOp(.gt, v);
    }
    pub fn gte(self: Value, v: Value) ValueError!bool {
        return self.compareOp(.gte, v);
    }
    pub fn lt(self: Value, v: Value) ValueError!bool {
        return self.compareOp(.lt, v);
    }
    pub fn lte(self: Value, v: Value) ValueError!bool {
        return self.compareOp(.lte, v);
    }

    const CmpOp = enum { eq, gt, gte, lt, lte };

    fn compareOp(self: Value, op: CmpOp, v: Value) ValueError!bool {
        switch (self) {
            .@"null" => return fail("comparison on null value", error.NullValue),
            .int => |i| {
                const v2 = v.toInt64() catch return fail("failed to convert to int64", error.FailedConversion);
                return applyOrder(op, std.math.order(i, v2));
            },
            .float => |f| {
                const v2 = v.toFloat64() catch return fail("failed to convert to float64", error.FailedConversion);
                // IEEE semantics (NaN compares false), like Go's ==/>/etc.
                return switch (op) {
                    .eq => f == v2,
                    .gt => f > v2,
                    .gte => f >= v2,
                    .lt => f < v2,
                    .lte => f <= v2,
                };
            },
            .string => |s| {
                var buf: [64]u8 = undefined;
                const s2 = coerceToStringForCmp(v, &buf) catch
                    return fail("failed to convert to string", error.FailedConversion);
                return applyOrder(op, std.mem.order(u8, s, s2));
            },
            .bytes => |b| {
                var buf: [64]u8 = undefined;
                const b2 = coerceToStringForCmp(v, &buf) catch
                    return fail("failed to convert to bytes", error.FailedConversion);
                return applyOrder(op, std.mem.order(u8, b, b2));
            },
            .bool => |b| switch (op) {
                .eq => {
                    const v2 = v.toBool() catch return fail("failed to convert to bool", error.FailedConversion);
                    return b == v2;
                },
                // Go: gt/gte/lt/lte are unsupported for bool.
                else => return fail("ordering operation is unsupported for bool", error.UnsupportedOperation),
            },
            .date => |days| {
                const d2 = dateDaysFromValue(v) catch |err| switch (err) {
                    error.Unimplemented => return err,
                    else => return fail("failed to convert to time", error.FailedConversion),
                };
                return applyOrder(op, std.math.order(days, d2));
            },
            // Go compares the underlying time.Time (self) against v.ToTime();
            // for UTC that is exactly a unix-microsecond ordering.
            .timestamp => |m| {
                const o = timeMicrosForCompare(v) catch return fail("failed to convert to time", error.FailedConversion);
                return applyOrder(op, std.math.order(m, o));
            },
            .datetime => |m| {
                const o = timeMicrosForCompare(v) catch return fail("failed to convert to time", error.FailedConversion);
                return applyOrder(op, std.math.order(m, o));
            },
            .time => |m| {
                const o = timeMicrosForCompare(v) catch return fail("failed to convert to time", error.FailedConversion);
                return applyOrder(op, std.math.order(time_base_micros +% m, o));
            },
            // Go: every comparison operator errors for JsonValue.
            .json => return fail("comparison operation is unsupported for json", error.UnsupportedOperation),
            // Go: every comparison operator errors for IntervalValue.
            .interval => return fail("unsupported comparison operator for interval value", error.UnsupportedOperation),
            // Go NumericValue EQ/GT/...: rat comparison against v.ToRat().
            // compareOp has no allocator, so temporaries live in a scratch
            // arena for the duration of the comparison.
            .numeric => |n| {
                var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch.deinit();
                const salloc = scratch.allocator();
                const other = v.toRat(salloc) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return fail("failed to convert to rat", error.FailedConversion),
                };
                const ord = try n.rat.cmp(salloc, other);
                return applyOrder(op, ord);
            },
            .array => |arr| {
                const arr2 = try v.toArray();
                if (arr2.values.len != arr.values.len) return false;
                // Go applies the *same* operator element-wise and requires it
                // to hold for every element, invoking it as rhs_elem.OP(lhs_elem).
                for (arr.values, arr2.values) |lhs_elem, rhs_elem| {
                    if (!try rhs_elem.compareOp(op, lhs_elem)) return false;
                }
                return true;
            },
            .struct_ => |st| {
                const st2 = try v.toStruct();
                if (st2.keys.len != st.keys.len) return false;
                for (st.keys, st.values) |key, lhs_field| {
                    // Go indexes the other struct's map; a missing key yields
                    // a nil Value (which would panic there).
                    const rhs_field = st2.fieldByName(key) orelse
                        return fail("missing struct field in comparison", error.NullValue);
                    if (!try rhs_field.compareOp(op, lhs_field)) return false;
                }
                return true;
            },
            .safe => |p| return p.compareOp(op, v) catch false,
        }
    }

    fn applyOrder(op: CmpOp, ord: std.math.Order) bool {
        return switch (op) {
            .eq => ord == .eq,
            .gt => ord == .gt,
            .gte => ord != .lt,
            .lt => ord == .lt,
            .lte => ord != .gt,
        };
    }

    // ------------------------------------------------------------------
    // Conversions
    // ------------------------------------------------------------------

    pub fn toInt64(self: Value) ValueError!i64 {
        switch (self) {
            .@"null" => return fail("toInt64 on null value", error.NullValue),
            .int => |i| return i,
            // Go: int64(fv). gc's behavior for NaN/out-of-range is
            // arch-specific; we saturate (arm64 semantics), NaN => 0.
            .float => |f| {
                if (std.math.isNan(f)) return 0;
                if (f >= 9223372036854775808.0) return std.math.maxInt(i64);
                if (f <= -9223372036854775808.0) return std.math.minInt(i64);
                return @intFromFloat(f);
            },
            .bool => |b| return @intFromBool(b),
            .string => |s| {
                if (s.len == 0) return 0;
                // Go: base 0 (auto-detect) iff the string contains "0x"/"0X".
                const base: u8 = if (containsHexMarker(s)) 0 else 10;
                return std.fmt.parseInt(i64, s, base) catch
                    fail("failed to convert string to int64", error.FailedConversion);
            },
            .bytes => |b| {
                if (b.len == 0) return 0;
                return std.fmt.parseInt(i64, b, 10) catch
                    fail("failed to convert bytes to int64", error.FailedConversion);
            },
            // Go DateValue.ToInt64 returns time.Time(d).Unix() = days * 86400.
            .date => |days| return days *% 86400,
            // Go: time.Time.Unix() = floor(micros / 1e6) (floor, not trunc).
            .timestamp => |m| return @divFloor(m, second_micros),
            .datetime => |m| return @divFloor(m, second_micros),
            .time => |m| return @divFloor(time_base_micros +% m, second_micros),
            // Go JsonValue.ToInt64: strconv.ParseInt(string, 0, 64) (base 0).
            .json => |s| return std.fmt.parseInt(i64, s, 0) catch
                fail("failed to convert json to int64", error.FailedConversion),
            .interval => return fail("unsupported int64 cast for interval value", error.FailedConversion),
            // Go NumericValue.ToInt64: Rat.Num().Int64() — the numerator.
            .numeric => |n| return n.rat.numLowInt64(),
            .array => return fail("failed to convert int64 from array", error.FailedConversion),
            .struct_ => return fail("failed to convert int64 from struct", error.FailedConversion),
            .safe => |p| return p.toInt64() catch 0,
        }
    }

    pub fn toFloat64(self: Value) ValueError!f64 {
        switch (self) {
            .@"null" => return fail("toFloat64 on null value", error.NullValue),
            .int => |i| return @floatFromInt(i),
            .float => |f| return f,
            .bool => |b| return if (b) 1 else 0,
            .string => |s| {
                if (s.len == 0) return 0;
                return std.fmt.parseFloat(f64, s) catch
                    fail("failed to convert string to float64", error.FailedConversion);
            },
            .bytes => |b| {
                if (b.len == 0) return 0;
                return std.fmt.parseFloat(f64, b) catch
                    fail("failed to convert bytes to float64", error.FailedConversion);
            },
            .date => |days| return @floatFromInt(days *% 86400),
            // Go: float64(time.Time.Unix()).
            .timestamp => |m| return @floatFromInt(@divFloor(m, second_micros)),
            .datetime => |m| return @floatFromInt(@divFloor(m, second_micros)),
            .time => |m| return @floatFromInt(@divFloor(time_base_micros +% m, second_micros)),
            // Go JsonValue.ToFloat64: strconv.ParseFloat(string, 64).
            .json => |s| return std.fmt.parseFloat(f64, s) catch
                fail("failed to convert json to float64", error.FailedConversion),
            .interval => return fail("unsupported float64 cast for interval value", error.FailedConversion),
            .numeric => |n| return n.rat.toFloat64(),
            .array => return fail("failed to convert float64 from array", error.FailedConversion),
            .struct_ => return fail("failed to convert float64 from struct", error.FailedConversion),
            .safe => |p| return p.toFloat64() catch 0,
        }
    }

    pub fn toBool(self: Value) ValueError!bool {
        switch (self) {
            .@"null" => return fail("toBool on null value", error.NullValue),
            .int => |i| switch (i) {
                0 => return false,
                1 => return true,
                else => return fail("failed to convert int to bool type", error.FailedConversion),
            },
            // Go: fmt.Sprint(fv) == "1" / "0" (note: -0.0 prints "-0" and errors).
            .float => |f| {
                if (f == 1) return true;
                if (f == 0 and !std.math.signbit(f)) return false;
                return fail("failed to convert float to bool type", error.FailedConversion);
            },
            .bool => |b| return b,
            .string => |s| {
                if (s.len == 0) return false;
                return parseGoBool(s) orelse
                    fail("failed to parse bool from string", error.FailedConversion);
            },
            .bytes => |b| {
                if (b.len == 0) return false;
                return parseGoBool(b) orelse
                    fail("failed to parse bool from bytes", error.FailedConversion);
            },
            .date => return fail("failed to convert date to bool type", error.FailedConversion),
            .timestamp => return fail("failed to convert timestamp to bool type", error.FailedConversion),
            .datetime => return fail("failed to convert datetime to bool type", error.FailedConversion),
            .time => return fail("failed to convert time to bool type", error.FailedConversion),
            // Go JsonValue.ToBool: strconv.ParseBool(string).
            .json => |s| return parseGoBool(s) orelse
                fail("failed to parse bool from json", error.FailedConversion),
            .interval => return fail("unsupported bool cast for interval value", error.FailedConversion),
            // Go NumericValue.ToBool: numerator 1 -> true, 0 -> false.
            .numeric => |n| switch (n.rat.numLowInt64()) {
                1 => return true,
                0 => return false,
                else => return fail("failed to convert numeric value to bool type", error.FailedConversion),
            },
            .array => return fail("failed to convert bool from array", error.FailedConversion),
            .struct_ => return fail("failed to convert bool from struct", error.FailedConversion),
            .safe => |p| return p.toBool() catch false,
        }
    }

    pub fn toString(self: Value, alloc: std.mem.Allocator) ValueError![]u8 {
        switch (self) {
            .@"null" => return fail("toString on null value", error.NullValue),
            .int => |i| return std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| {
                var buf: [32]u8 = undefined;
                return alloc.dupe(u8, formatFloatGo(&buf, f));
            },
            .bool => |b| return alloc.dupe(u8, if (b) "true" else "false"),
            .string => |s| return alloc.dupe(u8, s),
            .bytes => |b| return alloc.dupe(u8, b),
            // Go JsonValue.ToString: the raw JSON string verbatim.
            .json => |s| return alloc.dupe(u8, s),
            .date => |days| {
                var buf: [32]u8 = undefined;
                return alloc.dupe(u8, formatDateDays(&buf, days));
            },
            // Go ToString formats (timestamp uses the "-07" zone verb => "+00").
            .timestamp => |m| {
                var buf: [40]u8 = undefined;
                return alloc.dupe(u8, formatTimestampString(&buf, m));
            },
            .datetime => |m| {
                var buf: [40]u8 = undefined;
                return alloc.dupe(u8, formatDatetimeString(&buf, m));
            },
            .time => |m| {
                var buf: [24]u8 = undefined;
                return alloc.dupe(u8, formatTimeString(&buf, m));
            },
            .interval => |iv| {
                var buf: [96]u8 = undefined;
                return alloc.dupe(u8, formatInterval(&buf, iv));
            },
            // Go NumericValue.ToString: trimmed FloatString(9|38).
            .numeric => |n| return n.toText(alloc),
            // Go ArrayValue.ToString / StructValue.ToString render each
            // element via ToJSON and are byte-identical to ToJSON itself
            // (ArrayValue.ToJSON/StructValue.ToJSON just call ToString), so
            // delegate to toJson to get the same "[..]" / "{..}" rendering.
            .array, .struct_ => return self.toJson(alloc),
            .safe => |p| return p.toString(alloc) catch alloc.dupe(u8, ""),
        }
    }

    /// Same textual content as toString for all foundation kinds (Go's
    /// ToBytes mirrors ToString byte-for-byte for these types).
    pub fn toBytes(self: Value, alloc: std.mem.Allocator) ValueError![]u8 {
        switch (self) {
            .safe => |p| return p.toBytes(alloc) catch alloc.dupe(u8, ""),
            else => return self.toString(alloc),
        }
    }

    pub fn toArray(self: Value) ValueError!*ArrayValue {
        switch (self) {
            .@"null" => return fail("toArray on null value", error.NullValue),
            .array => |a| return a,
            // Go: StringValue("").ToArray() returns (nil, nil) i.e. a null
            // array; represent that as NullValue here.
            .string => |s| {
                if (s.len == 0) return fail("empty string converts to null array", error.NullValue);
                return fail("failed to convert array from string", error.FailedConversion);
            },
            .safe => |p| return p.toArray() catch &empty_array_storage,
            else => return fail("failed to convert to array type", error.FailedConversion),
        }
    }

    pub fn toStruct(self: Value) ValueError!*StructValue {
        switch (self) {
            .@"null" => return fail("toStruct on null value", error.NullValue),
            .struct_ => |s| return s,
            .string => |s| {
                if (s.len == 0) return fail("empty string converts to null struct", error.NullValue);
                return fail("failed to convert struct from string", error.FailedConversion);
            },
            // Go flattens an array-of-structs into one struct here; that
            // needs allocation, deferred to a later milestone.
            .array => return fail("array-of-struct flattening deferred", error.Unimplemented),
            .safe => |p| return p.toStruct() catch &empty_struct_storage,
            else => return fail("failed to convert to struct type", error.FailedConversion),
        }
    }

    // Deferred interface surface (Go: ToTime/ToJSON/ToRat/ToApiString/Format).
    pub fn toTime(self: Value) ValueError!void {
        _ = self;
        return fail("ToTime is deferred", error.Unimplemented);
    }
    /// Go ToJSON per value kind: the JSON serialization used by TO_JSON /
    /// TO_JSON_STRING and by struct/array element rendering. Scalars stringify;
    /// strings/bytes/date/time kinds are strconv.Quote'd; struct/array recurse
    /// with preserved key order; json passes through verbatim.
    pub fn toJson(self: Value, alloc: std.mem.Allocator) ValueError![]u8 {
        switch (self) {
            .@"null" => return alloc.dupe(u8, "null"),
            .int => |i| return std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| {
                var buf: [32]u8 = undefined;
                return alloc.dupe(u8, formatFloatGo(&buf, f));
            },
            .bool => |b| return alloc.dupe(u8, if (b) "true" else "false"),
            .string => |s| return quoteJsonString(alloc, s),
            .bytes => |b| return quoteJsonString(alloc, b),
            .json => |s| return alloc.dupe(u8, s),
            .date => |days| {
                var buf: [32]u8 = undefined;
                return quoteJsonString(alloc, formatDateDays(&buf, days));
            },
            .datetime => |m| {
                var buf: [40]u8 = undefined;
                return quoteJsonString(alloc, formatDatetimeApi(&buf, m));
            },
            .time => |m| {
                var buf: [24]u8 = undefined;
                return quoteJsonString(alloc, formatTimeString(&buf, m));
            },
            // Go TimestampValue.ToJSON: UTC "2006-01-02T15:04:05.999999Z".
            .timestamp => |m| {
                var buf: [40]u8 = undefined;
                return quoteJsonString(alloc, formatTimestampJson(&buf, m));
            },
            .interval => |iv| {
                var buf: [96]u8 = undefined;
                return quoteJsonString(alloc, formatInterval(&buf, iv));
            },
            // Go NumericValue.ToJSON: the unquoted decimal rendering.
            .numeric => |n| return n.toText(alloc),
            // Go ArrayValue.ToString: "[elem,elem,...]", nil -> "null".
            .array => |arr| {
                var out: std.ArrayList(u8) = .empty;
                try out.append(alloc, '[');
                for (arr.values, 0..) |elem, i| {
                    if (i > 0) try out.append(alloc, ',');
                    const ej = try elem.toJson(alloc);
                    try out.appendSlice(alloc, ej);
                }
                try out.append(alloc, ']');
                return out.items;
            },
            // Go StructValue.ToString: {"key":val,...} in field order.
            .struct_ => |st| {
                var out: std.ArrayList(u8) = .empty;
                try out.append(alloc, '{');
                for (st.values, 0..) |elem, i| {
                    if (i > 0) try out.append(alloc, ',');
                    const key: []const u8 = if (i < st.keys.len) st.keys[i] else "";
                    const kq = try quoteJsonString(alloc, key);
                    try out.appendSlice(alloc, kq);
                    try out.append(alloc, ':');
                    const ej = try elem.toJson(alloc);
                    try out.appendSlice(alloc, ej);
                }
                try out.append(alloc, '}');
                return out.items;
            },
            .safe => |p| return p.toJson(alloc),
        }
    }
    /// Go Value.ToRat per kind. Quirks kept: String/Bytes ignore the
    /// SetString failure and hand back the zero Rat; SafeValue swallows
    /// errors into (nil, nil), mirrored here as the zero Rat.
    pub fn toRat(self: Value, alloc: std.mem.Allocator) ValueError!Rat {
        switch (self) {
            .@"null" => return fail("toRat on null value", error.NullValue),
            .int => |i| return Rat.initInt(alloc, i),
            .float => |f| return Rat.setFloat64(alloc, f),
            .bool => |b| return Rat.initInt(alloc, @intFromBool(b)),
            .string => |s| return Rat.setString(alloc, s) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => Rat.initInt(alloc, 0),
            },
            .bytes => |b| return Rat.setString(alloc, b) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => Rat.initInt(alloc, 0),
            },
            // Go JsonValue.ToRat: strconv.ParseInt(string, 0, 64) then SetInt64.
            .json => |s| {
                const i = std.fmt.parseInt(i64, s, 0) catch
                    return fail("failed to convert json to rat", error.FailedConversion);
                return Rat.initInt(alloc, i);
            },
            .numeric => |n| return n.rat,
            .safe => |p| return p.toRat(alloc) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => Rat.initInt(alloc, 0),
            },
            else => return fail("unsupported rat conversion for this kind", error.FailedConversion),
        }
    }
    /// Go ToApiString: the string form rows.go hands back through
    /// database/sql for each type kind. Implemented for the date/time kinds
    /// (the observable result-cell rendering); other kinds stay deferred.
    pub fn toApiString(self: Value, alloc: std.mem.Allocator) ValueError![]u8 {
        switch (self) {
            .date => |days| {
                var buf: [32]u8 = undefined;
                return alloc.dupe(u8, formatDateDays(&buf, days));
            },
            // TimestampValue.ToApiString: "sec.microrem" (see formatTimestampApi).
            .timestamp => |m| {
                var buf: [40]u8 = undefined;
                return alloc.dupe(u8, formatTimestampApi(&buf, m));
            },
            // DatetimeValue.ToApiString: datetimeDefaultFormat ("...T...").
            .datetime => |m| {
                var buf: [40]u8 = undefined;
                return alloc.dupe(u8, formatDatetimeApi(&buf, m));
            },
            // TimeValue.ToApiString == ToString.
            .time => |m| {
                var buf: [24]u8 = undefined;
                return alloc.dupe(u8, formatTimeString(&buf, m));
            },
            // IntervalValue.ToApiString == ToString.
            .interval => |iv| {
                var buf: [96]u8 = undefined;
                return alloc.dupe(u8, formatInterval(&buf, iv));
            },
            // Go JsonValue.ToApiString == ToString: the raw JSON string.
            .json => |s| return alloc.dupe(u8, s),
            // Go NumericValue.ToApiString == toString().
            .numeric => |n| return n.toText(alloc),
            .safe => |p| return p.toApiString(alloc) catch alloc.dupe(u8, ""),
            else => return fail("ToApiString is deferred for this kind", error.Unimplemented),
        }
    }
    /// Go Value.Format(verb): the %t (printable) / %T (typed) renderings used
    /// by FORMAT. Other verbs fall through to the printable form.
    pub fn format(self: Value, verb: u8, alloc: std.mem.Allocator) ValueError![]u8 {
        switch (self) {
            .@"null" => return alloc.dupe(u8, "NULL"),
            .int => |i| return std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| {
                var buf: [40]u8 = undefined;
                return alloc.dupe(u8, formatFloatGo(&buf, f));
            },
            .bool => |b| return alloc.dupe(u8, if (b) "true" else "false"),
            .string => |s| {
                if (verb == 'T') return goQuote(alloc, s);
                return alloc.dupe(u8, s);
            },
            .bytes => |b| return formatBytes(alloc, b, verb),
            .json => |s| return alloc.dupe(u8, s),
            .date => |days| {
                var buf: [32]u8 = undefined;
                const s = formatDateDays(&buf, days);
                if (verb == 'T') return std.fmt.allocPrint(alloc, "DATE \"{s}\"", .{s});
                return alloc.dupe(u8, s);
            },
            .timestamp => |m| {
                var buf: [40]u8 = undefined;
                const d = decomposeMicros(m);
                const w = writeCivilPrefix(&buf, d, ' ');
                @memcpy(buf[w .. w + 3], "+00");
                const s = buf[0 .. w + 3];
                if (verb == 'T') return std.fmt.allocPrint(alloc, "TIMESTAMP \"{s}\"", .{s});
                return alloc.dupe(u8, s);
            },
            .datetime => |m| {
                var buf: [40]u8 = undefined;
                const s = formatDatetimeString(&buf, m);
                if (verb == 'T') return std.fmt.allocPrint(alloc, "DATETIME \"{s}\"", .{s});
                return alloc.dupe(u8, s);
            },
            .time => |m| {
                var buf: [24]u8 = undefined;
                const s = formatTimeString(&buf, m);
                if (verb == 'T') return std.fmt.allocPrint(alloc, "TIME \"{s}\"", .{s});
                return alloc.dupe(u8, s);
            },
            .interval => |iv| {
                var buf: [96]u8 = undefined;
                return alloc.dupe(u8, formatInterval(&buf, iv));
            },
            // Go NumericValue.Format: toString() for every verb.
            .numeric => |n| return n.toText(alloc),
            .array => |a| {
                var out: std.ArrayList(u8) = .empty;
                try out.append(alloc, '[');
                for (a.values, 0..) |v, i| {
                    if (i > 0) try out.appendSlice(alloc, ", ");
                    if (v == .@"null") {
                        try out.appendSlice(alloc, "NULL");
                    } else {
                        try out.appendSlice(alloc, try v.format(verb, alloc));
                    }
                }
                try out.append(alloc, ']');
                return out.toOwnedSlice(alloc);
            },
            .struct_ => |s| {
                var out: std.ArrayList(u8) = .empty;
                try out.append(alloc, '(');
                for (s.values, 0..) |v, i| {
                    if (i > 0) try out.appendSlice(alloc, ", ");
                    if (v == .@"null") {
                        try out.appendSlice(alloc, "NULL");
                    } else {
                        try out.appendSlice(alloc, try v.format(verb, alloc));
                    }
                }
                try out.append(alloc, ')');
                return out.toOwnedSlice(alloc);
            },
            .safe => |p| return p.format(verb, alloc),
        }
    }
};

/// Go BytesValue.Format: printable bytes verbatim, others as \xNN; %T wraps
/// in b"...".
fn formatBytes(alloc: std.mem.Allocator, b: []const u8, verb: u8) ValueError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (verb == 'T') try out.appendSlice(alloc, "b\"");
    for (b) |byte| {
        if (byte >= 0x20 and byte <= 0x7e) {
            try out.append(alloc, byte);
        } else {
            try out.print(alloc, "\\x{x:0>2}", .{byte});
        }
    }
    if (verb == 'T') try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

/// Go strconv.Quote for the ASCII/common cases the corpus exercises: wraps in
/// double quotes, backslash-escaping ", \, and the standard control escapes;
/// other bytes < 0x20 use \xNN.
fn goQuote(alloc: std.mem.Allocator, s: []const u8) ValueError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.print(alloc, "\\x{x:0>2}", .{c});
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

// ----------------------------------------------------------------------
// Coercion helpers
// ----------------------------------------------------------------------

/// Scalar Value -> string coercion used by string/bytes comparisons; writes
/// scalars into `buf` (needs >= 32 bytes) and aliases string/bytes payloads.
fn coerceToStringForCmp(v: Value, buf: []u8) ValueError![]const u8 {
    switch (v) {
        .@"null" => return error.NullValue,
        .string => |s| return s,
        .bytes => |b| return b,
        .json => |s| return s,
        .int => |i| return std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
        .float => |f| return formatFloatGo(buf, f),
        .bool => |b| return if (b) "true" else "false",
        .date => |days| return formatDateDays(buf, days),
        // ToString forms (buf is >= 32 bytes; interval can exceed it, so it
        // is length-checked into the caller scratch — timestamp/datetime fit).
        .timestamp => |m| return formatTimestampString(buf, m),
        .datetime => |m| return formatDatetimeString(buf, m),
        .time => |m| return formatTimeString(buf, m),
        .interval => return error.Unimplemented,
        // Numeric renders into the caller's scratch buffer (BIGNUMERIC
        // extremes wider than the buffer degrade to FailedConversion).
        .numeric => |n| {
            var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer scratch.deinit();
            const s = n.toText(scratch.allocator()) catch return error.FailedConversion;
            if (s.len > buf.len) return error.FailedConversion;
            @memcpy(buf[0..s.len], s);
            return buf[0..s.len];
        },
        // Array/Struct ToString needs ToJSON (deferred).
        .array, .struct_ => return error.Unimplemented,
        .safe => |p| return coerceToStringForCmp(p.*, buf) catch "",
    }
}

const zero_time_days: i64 = daysFromCivil(1, 1, 1); // Go's time.Time{}

/// rhs.ToTime() as used by date comparisons, projected onto civil days.
fn dateDaysFromValue(v: Value) ValueError!i64 {
    switch (v) {
        .@"null" => return error.NullValue,
        .date => |days| return days,
        .string => |s| return dateDaysFromText(s),
        .bytes => |b| return dateDaysFromText(b),
        // Go IntValue.ToTime() builds a timestamp/date from int64 (deferred).
        .int => return error.Unimplemented,
        // Go SafeValue.ToTime() swallows errors into the zero time.Time.
        .safe => |p| return dateDaysFromValue(p.*) catch zero_time_days,
        else => return error.FailedConversion,
    }
}

fn dateDaysFromText(s: []const u8) ValueError!i64 {
    if (isDateString(s)) return parseDateDays(s);
    // Datetime / time / timestamp shaped strings parse in Go (deferred here).
    if (isDatetimeString(s) or isTimePrefixString(s)) return error.Unimplemented;
    return error.FailedConversion;
}

fn containsHexMarker(s: []const u8) bool {
    if (s.len < 2) return false;
    for (0..s.len - 1) |i| {
        if (s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) return true;
    }
    return false;
}

/// Go strconv.ParseBool accepted forms.
fn parseGoBool(s: []const u8) ?bool {
    const truthy = [_][]const u8{ "1", "t", "T", "TRUE", "true", "True" };
    const falsy = [_][]const u8{ "0", "f", "F", "FALSE", "false", "False" };
    for (truthy) |t| if (std.mem.eql(u8, s, t)) return true;
    for (falsy) |f| if (std.mem.eql(u8, s, f)) return false;
    return null;
}

// ----------------------------------------------------------------------
// Civil date arithmetic (days-from-civil / civil-from-days; no std support)
// ----------------------------------------------------------------------

pub fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mp = @mod(m + 9, 12); // [0, 11]
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

pub const CivilDate = struct { year: i64, month: u8, day: u8 };

pub fn civilFromDays(z_in: i64) CivilDate {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// Formats civil days since epoch as "YYYY-MM-DD" (Go layout "2006-01-02").
/// `buf` must be at least 32 bytes.
pub fn formatDateDays(buf: []u8, days: i64) []const u8 {
    const c = civilFromDays(days);
    // Zig 0.16 prints an explicit '+' when zero-padding signed integers, so
    // format the year as unsigned with a manual sign.
    if (c.year < 0) {
        const y: u64 = @intCast(-c.year);
        return std.fmt.bufPrint(buf, "-{d:0>4}-{d:0>2}-{d:0>2}", .{ y, c.month, c.day }) catch unreachable;
    }
    const y: u64 = @intCast(c.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, c.month, c.day }) catch unreachable;
}

pub fn isDateString(s: []const u8) bool {
    // Go: ^[0-9]{4}-[0-9]{2}-[0-9]{2}$
    if (s.len != 10) return false;
    for (s, 0..) |ch, i| {
        if (i == 4 or i == 7) {
            if (ch != '-') return false;
        } else if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn isDatetimeString(s: []const u8) bool {
    // Go: ^[0-9]{4}-[0-9]{2}-[0-9]{2}[T\s][0-9]{2}:[0-9]{2}:[0-9]{2}$
    if (s.len != 19) return false;
    if (!isDateString(s[0..10])) return false;
    if (s[10] != 'T' and s[10] != ' ') return false;
    return isTimePrefixString(s[11..]);
}

fn isTimePrefixString(s: []const u8) bool {
    // Go: ^[0-9]{2}:[0-9]{2}:[0-9]{2}
    if (s.len < 8) return false;
    for (s[0..8], 0..) |ch, i| {
        if (i == 2 or i == 5) {
            if (ch != ':') return false;
        } else if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// Parses "YYYY-MM-DD" into civil days since epoch (Go time.Parse("2006-01-02")).
pub fn parseDateDays(s: []const u8) ValueError!i64 {
    if (!isDateString(s)) return fail("invalid date literal", error.InvalidDate);
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return error.InvalidDate;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return error.InvalidDate;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return error.InvalidDate;
    if (m < 1 or m > 12) return fail("month out of range", error.InvalidDate);
    if (d < 1 or d > daysInMonth(y, m)) return fail("day out of range", error.InvalidDate);
    return daysFromCivil(y, m, d);
}

fn daysInMonth(y: i64, m: i64) i64 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(y)) @as(i64, 29) else 28,
        else => 0,
    };
}

fn isLeapYear(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

// ----------------------------------------------------------------------
// TIMESTAMP / DATETIME / TIME / INTERVAL helpers (Go value.go time kinds).
// All UTC (the corpus pins TZ=UTC; Zig has no timezone database).
// ----------------------------------------------------------------------

const zero_time_micros: i64 = zero_time_days * 86400 * second_micros; // time.Time{} (0001-01-01)

const Decomposed = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    micro: u32,
};

/// Breaks civil/unix microseconds into calendar + time-of-day components.
fn decomposeMicros(m: i64) Decomposed {
    const days = @divFloor(m, day_micros);
    const day_rem = m - days * day_micros; // [0, day_micros)
    const c = civilFromDays(days);
    const hour = @divTrunc(day_rem, hour_micros);
    var rem = day_rem - hour * hour_micros;
    const minute = @divTrunc(rem, minute_micros);
    rem -= minute * minute_micros;
    const second = @divTrunc(rem, second_micros);
    const micro = rem - second * second_micros;
    return .{
        .year = c.year,
        .month = c.month,
        .day = c.day,
        .hour = @intCast(hour),
        .minute = @intCast(minute),
        .second = @intCast(second),
        .micro = @intCast(micro),
    };
}

/// Writes Go's ".999999" optional fractional-seconds field: nothing when
/// micro == 0, otherwise "." then up to six digits with trailing zeros
/// trimmed. Returns the number of bytes written.
fn writeFracMicros(buf: []u8, micro: u32) usize {
    if (micro == 0) return 0;
    var tmp: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&tmp, "{d:0>6}", .{micro}) catch unreachable;
    var end: usize = 6;
    while (end > 0 and tmp[end - 1] == '0') end -= 1;
    buf[0] = '.';
    @memcpy(buf[1 .. 1 + end], tmp[0..end]);
    return 1 + end;
}

/// Writes "YYYY-MM-DD<sep>HH:MM:SS" (year sign handled like formatDateDays).
fn writeCivilPrefix(buf: []u8, d: Decomposed, sep: u8) usize {
    var w: usize = 0;
    if (d.year < 0) {
        const y: u64 = @intCast(-d.year);
        w = (std.fmt.bufPrint(buf, "-{d:0>4}-{d:0>2}-{d:0>2}", .{ y, d.month, d.day }) catch unreachable).len;
    } else {
        const y: u64 = @intCast(d.year);
        w = (std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, d.month, d.day }) catch unreachable).len;
    }
    buf[w] = sep;
    w += 1;
    w += (std.fmt.bufPrint(buf[w..], "{d:0>2}:{d:0>2}:{d:0>2}", .{ d.hour, d.minute, d.second }) catch unreachable).len;
    return w;
}

/// TimestampValue.ToApiString: fmt.Sprintf("%d.%d", sec, microRemainder)
/// where sec = unixMicro/1e6 (truncated) — a "seconds.remainder" form with
/// the remainder printed unpadded (e.g. 1136239445 micros => "1136239445.0").
pub fn formatTimestampApi(buf: []u8, micros: i64) []const u8 {
    const sec = @divTrunc(micros, second_micros);
    const rem = micros - sec * second_micros;
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ sec, rem }) catch unreachable;
}

/// Inverse of formatTimestampApi ("sec.microRemainder" -> unix micros). Used
/// to round-trip a timestamp result cell back into a bound parameter value.
pub fn parseTimestampApi(s: []const u8) ValueError!i64 {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return error.FailedConversion;
    const sec = std.fmt.parseInt(i64, s[0..dot], 10) catch return error.FailedConversion;
    const rem = std.fmt.parseInt(i64, s[dot + 1 ..], 10) catch return error.FailedConversion;
    return sec *% second_micros +% rem;
}

/// TimestampValue.Interface(): time.RFC3339 = "2006-01-02T15:04:05Z" for UTC
/// (no fractional seconds). Used as the GROUP BY key rendering.
pub fn formatTimestampRfc3339(buf: []u8, micros: i64) []const u8 {
    const d = decomposeMicros(micros);
    const w = writeCivilPrefix(buf, d, 'T');
    buf[w] = 'Z';
    return buf[0 .. w + 1];
}

/// TimestampValue.ToString: "2006-01-02 15:04:05.999999-07"; UTC => "+00".
pub fn formatTimestampString(buf: []u8, micros: i64) []const u8 {
    const d = decomposeMicros(micros);
    var w = writeCivilPrefix(buf, d, ' ');
    w += writeFracMicros(buf[w..], d.micro);
    @memcpy(buf[w .. w + 3], "+00");
    return buf[0 .. w + 3];
}

/// DatetimeValue.ToString: "2006-01-02 15:04:05.999999" (space separator).
pub fn formatDatetimeString(buf: []u8, micros: i64) []const u8 {
    const d = decomposeMicros(micros);
    var w = writeCivilPrefix(buf, d, ' ');
    w += writeFracMicros(buf[w..], d.micro);
    return buf[0..w];
}

/// DatetimeValue.ToApiString: "2006-01-02T15:04:05.999999" (T separator).
pub fn formatDatetimeApi(buf: []u8, micros: i64) []const u8 {
    const d = decomposeMicros(micros);
    var w = writeCivilPrefix(buf, d, 'T');
    w += writeFracMicros(buf[w..], d.micro);
    return buf[0..w];
}

/// TimeValue.ToString / ToApiString: "15:04:05.999999".
pub fn formatTimeString(buf: []u8, micros: i64) []const u8 {
    const d = decomposeMicros(micros);
    var w = (std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ d.hour, d.minute, d.second }) catch unreachable).len;
    w += writeFracMicros(buf[w..], d.micro);
    return buf[0..w];
}

/// TimestampValue.ToJSON: UTC "2006-01-02T15:04:05.999999Z" (T separator,
/// trailing-zero-trimmed fractional seconds, Z suffix). `buf` needs >= 40 bytes.
pub fn formatTimestampJson(buf: []u8, micros: i64) []const u8 {
    const d = decomposeMicros(micros);
    var w = writeCivilPrefix(buf, d, 'T');
    w += writeFracMicros(buf[w..], d.micro);
    buf[w] = 'Z';
    return buf[0 .. w + 1];
}

/// strconv.Quote-equivalent for JSON string literals: wrap in double quotes,
/// escaping `"`, `\`, and the standard C0 control characters. ASCII-printable
/// content (all the corpus exercises) is byte-identical to Go's strconv.Quote
/// and to json.Marshal.
pub fn quoteJsonString(alloc: std.mem.Allocator, s: []const u8) ValueError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0x08 => try out.appendSlice(alloc, "\\b"),
            0x0c => try out.appendSlice(alloc, "\\f"),
            else => {
                if (ch < 0x20) {
                    try out.print(alloc, "\\u{x:0>4}", .{ch});
                } else {
                    try out.append(alloc, ch);
                }
            },
        }
    }
    try out.append(alloc, '"');
    return out.items;
}

fn i32Abs(x: i32) i32 {
    return if (x < 0) -x else x;
}

/// bigquery.IntervalValue.Canonicalize: reduce Y-M and H:M:S.F parts.
fn canonicalizeInterval(iv: Interval) Interval {
    var out = Interval{ .days = iv.days };
    const total_months: i32 = iv.years * 12 + iv.months;
    out.years = @divTrunc(total_months, 12);
    out.months = @rem(total_months, 12);
    var total_nanos: i64 = @as(i64, iv.hours) * 3600 * 1_000_000_000 +
        @as(i64, iv.minutes) * 60 * 1_000_000_000 +
        @as(i64, iv.seconds) * 1_000_000_000 +
        @as(i64, iv.sub_second_nanos);
    out.hours = @intCast(@divTrunc(total_nanos, 3600 * 1_000_000_000));
    total_nanos -= @as(i64, out.hours) * 3600 * 1_000_000_000;
    out.minutes = @intCast(@divTrunc(total_nanos, 60 * 1_000_000_000));
    total_nanos -= @as(i64, out.minutes) * 60 * 1_000_000_000;
    out.seconds = @intCast(@divTrunc(total_nanos, 1_000_000_000));
    total_nanos -= @as(i64, out.seconds) * 1_000_000_000;
    out.sub_second_nanos = @intCast(total_nanos);
    return out;
}

/// IntervalValue.ToString: bigquery canonical "[sign]Y-M [sign]D H:M:S[.F]",
/// plus go-zetasqlite's leading "-" when Years==0 && Months<0. `buf` needs
/// >= 96 bytes.
pub fn formatInterval(buf: []u8, iv_in: Interval) []const u8 {
    const c = canonicalizeInterval(iv_in);
    var w: usize = 0;
    // go-zetasqlite ToString: negative-month intervals get a leading '-'.
    if (c.years == 0 and c.months < 0) {
        buf[0] = '-';
        w = 1;
    }
    w += (std.fmt.bufPrint(buf[w..], "{d}-{d} {d} {d}:{d}:{d}", .{
        c.years,
        i32Abs(c.months),
        c.days,
        c.hours,
        i32Abs(c.minutes),
        i32Abs(c.seconds),
    }) catch unreachable).len;
    if (c.sub_second_nanos != 0) {
        var tmp: [16]u8 = undefined;
        const mant: []const u8 = if (c.sub_second_nanos < 0)
            std.fmt.bufPrint(&tmp, "-{d:0>8}", .{@as(u32, @intCast(-c.sub_second_nanos))}) catch unreachable
        else
            std.fmt.bufPrint(&tmp, "{d:0>9}", .{@as(u32, @intCast(c.sub_second_nanos))}) catch unreachable;
        var end: usize = mant.len;
        while (end > 0 and mant[end - 1] == '0') end -= 1;
        buf[w] = '.';
        w += 1;
        @memcpy(buf[w .. w + end], mant[0..end]);
        w += end;
    }
    return buf[0..w];
}

/// bigquery.IntervalValueFromDuration: only the H/M/S/subsecond parts.
pub fn intervalFromDuration(nanos_in: i64) Interval {
    var nanos = nanos_in;
    var iv = Interval{};
    iv.hours = @intCast(@divTrunc(nanos, 3600 * 1_000_000_000));
    nanos -= @as(i64, iv.hours) * 3600 * 1_000_000_000;
    iv.minutes = @intCast(@divTrunc(nanos, 60 * 1_000_000_000));
    nanos -= @as(i64, iv.minutes) * 60 * 1_000_000_000;
    iv.seconds = @intCast(@divTrunc(nanos, 1_000_000_000));
    nanos -= @as(i64, iv.seconds) * 1_000_000_000;
    iv.sub_second_nanos = @intCast(nanos);
    return iv;
}

const Norm = struct { hi: i64, lo: i64 };

/// Go time.norm: carry lo into hi so lo lands in [0, base).
fn norm(hi: i64, lo: i64, base: i64) Norm {
    var h = hi;
    var l = lo;
    if (l < 0) {
        const n = @divTrunc(-l - 1, base) + 1;
        h -= n;
        l += n * base;
    }
    if (l >= base) {
        const n = @divTrunc(l, base);
        h += n;
        l -= n * base;
    }
    return .{ .hi = h, .lo = l };
}

/// TimestampValue/DatetimeValue + INTERVAL: calendar arithmetic mirroring Go's
/// time.Date(y+Y, m+Mo, d+D, h+H, ...) component add with normalization.
/// `sign` is +1 for Add, -1 for Sub.
fn addCalendar(base_micros: i64, iv: Interval, sign: i64) i64 {
    const d = decomposeMicros(base_micros);
    var year: i64 = d.year + sign * iv.years;
    var month: i64 = @as(i64, d.month) + sign * iv.months;
    var day: i64 = @as(i64, d.day) + sign * iv.days;
    var hour: i64 = @as(i64, d.hour) + sign * iv.hours;
    var minute: i64 = @as(i64, d.minute) + sign * iv.minutes;
    var second: i64 = @as(i64, d.second) + sign * iv.seconds;
    var nsec: i64 = @as(i64, d.micro) * 1000 + sign * iv.sub_second_nanos;

    var r = norm(second, nsec, 1_000_000_000);
    second = r.hi;
    nsec = r.lo;
    r = norm(minute, second, 60);
    minute = r.hi;
    second = r.lo;
    r = norm(hour, minute, 60);
    hour = r.hi;
    minute = r.lo;
    r = norm(day, hour, 24);
    day = r.hi;
    hour = r.lo;
    r = norm(year, month - 1, 12);
    year = r.hi;
    month = r.lo + 1;

    const total_days = daysFromCivil(year, month, 1) + (day - 1);
    return total_days * day_micros +
        hour * hour_micros +
        minute * minute_micros +
        second * second_micros +
        @divTrunc(nsec, 1000);
}

/// Public bridge (Go: Value.ToTime()) projecting any time-shaped value onto
/// unix microseconds; used by the CAST machinery for cross-kind time casts.
pub fn toUnixMicros(v: Value) ValueError!i64 {
    return timeMicrosForCompare(v);
}

/// The rhs of a time-kind comparison as unix microseconds (Go: v.ToTime()).
fn timeMicrosForCompare(v: Value) ValueError!i64 {
    switch (v) {
        .@"null" => return error.NullValue,
        .timestamp => |m| return m,
        .datetime => |m| return m,
        .time => |m| return time_base_micros +% m,
        .date => |days| return days *% 86400 *% second_micros,
        .string => |s| return parseAnyTimeMicros(s),
        .bytes => |b| return parseAnyTimeMicros(b),
        // Go SafeValue.ToTime swallows errors into time.Time{} (0001-01-01).
        .safe => |p| return timeMicrosForCompare(p.*) catch zero_time_micros,
        else => return error.FailedConversion,
    }
}

/// StringValue.ToTime dispatch: date / datetime / time / timestamp shaped
/// strings, projected onto unix microseconds.
fn parseAnyTimeMicros(s: []const u8) ValueError!i64 {
    if (isDateString(s)) return (try parseDateDays(s)) *% 86400 *% second_micros;
    if (isDatetimeString(s)) return parseDatetimeMicros(s);
    if (isTimePrefixString(s)) return time_base_micros +% (try parseTimeMicros(s));
    // Go's isTimestamp() is "parseTimestamp succeeds"; when every shape test
    // fails StringValue.ToTime reports the string itself rather than letting
    // the inner parser's message escape:
    //   fmt.Errorf("failed to convert %s to time.Time type", sv)
    return parseTimestampMicros(s) catch
        failFmt("failed to convert {s} to time.Time type", .{s}, error.FailedConversion);
}

// -- Parsers (Go value.go parse* functions) ---------------------------------

fn parseTwoDigits(s: []const u8, max: i64) ValueError!i64 {
    if (s.len < 2 or !std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1])) return error.InvalidDate;
    const v = @as(i64, s[0] - '0') * 10 + @as(i64, s[1] - '0');
    if (v >= max) return error.InvalidDate;
    return v;
}

/// The hour, and how many bytes it took.
///
/// Every Go layout here spells the hour `15`, which is stdHour and reads
/// through getnum(value, false) — one *or two* digits. Minute (`04`) and
/// second (`05`) are stdZeroMinute/stdZeroSecond, getnum(value, true), which
/// is fixed-width. So "2020-11-30 7:34:44" parses in Go and "2020-11-30
/// 7:4:44" does not, and the flexibility stops at the hour.
///
/// Returns null rather than an error so callers keep their own literal-kind
/// message; nothing here can allocate.
fn parseHour(s: []const u8) ?struct { value: i64, len: usize } {
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    var value: i64 = s[0] - '0';
    var len: usize = 1;
    if (s.len > 1 and std.ascii.isDigit(s[1])) {
        value = value * 10 + @as(i64, s[1] - '0');
        len = 2;
    }
    if (value >= 24) return null;
    return .{ .value = value, .len = len };
}

/// Reads leading decimal digits as sub-second micros (first 6 significant
/// digits, remaining digits truncated). Returns micros and the consumed count.
fn readFracMicros(s: []const u8) struct { micro: u32, len: usize } {
    var micro: u32 = 0;
    var digits: usize = 0;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        if (digits < 6) {
            micro = micro * 10 + (s[i] - '0');
            digits += 1;
        }
    }
    while (digits < 6) : (digits += 1) micro *= 10;
    return .{ .micro = micro, .len = i };
}

/// Go parseTime("15:04:05.999999") -> microseconds since midnight.
pub fn parseTimeMicros(s: []const u8) ValueError!i64 {
    const h = parseHour(s) orelse return fail("invalid time literal", error.InvalidDate);
    var idx = h.len;
    if (s.len < idx + 6 or s[idx] != ':' or s[idx + 3] != ':') {
        return fail("invalid time literal", error.InvalidDate);
    }
    const min = try parseTwoDigits(s[idx + 1 .. idx + 3], 60);
    const sec = try parseTwoDigits(s[idx + 4 .. idx + 6], 60);
    idx += 6;
    var micro: i64 = 0;
    if (s.len > idx) {
        if (s[idx] != '.') return fail("invalid time literal", error.InvalidDate);
        const frac = readFracMicros(s[idx + 1 ..]);
        if (idx + 1 + frac.len != s.len) return fail("invalid time literal", error.InvalidDate);
        micro = frac.micro;
    }
    return (h.value * 3600 + min * 60 + sec) * second_micros + micro;
}

/// Go parseDatetime -> civil microseconds (T or space separator).
pub fn parseDatetimeMicros(s: []const u8) ValueError!i64 {
    // 18, not 19: "YYYY-MM-DD" + separator + the shortest legal time-of-day,
    // "H:MM:SS".
    if (s.len < 18) return fail("invalid datetime literal", error.InvalidDate);
    const days = try parseDateDays(s[0..10]);
    if (s[10] != 'T' and s[10] != ' ') return fail("invalid datetime literal", error.InvalidDate);
    const tod = try parseTimeMicros(s[11..]);
    return days * day_micros + tod;
}

/// Go parseTimestamp -> unix microseconds (UTC). Accepts an optional zone
/// suffix: Z, ±HH[:MM], or a trailing " NAME" (treated as UTC — Zig has no
/// timezone database; the corpus runs TZ=UTC). Non-UTC named zones therefore
/// parse as UTC.
pub fn parseTimestampMicros(s: []const u8) ValueError!i64 {
    if (s.len < 10) return fail("invalid timestamp literal", error.InvalidDate);
    const days = try parseDateDays(s[0..10]);
    if (s.len == 10) return days * 86400 * second_micros;
    if (s[10] != 'T' and s[10] != ' ') return fail("invalid timestamp literal", error.InvalidDate);
    const rest = s[11..];
    const h = parseHour(rest) orelse return fail("invalid timestamp literal", error.InvalidDate);
    var idx = h.len;
    if (rest.len < idx + 6 or rest[idx] != ':' or rest[idx + 3] != ':') {
        return fail("invalid timestamp literal", error.InvalidDate);
    }
    const hour = h.value;
    const min = try parseTwoDigits(rest[idx + 1 .. idx + 3], 60);
    const sec = try parseTwoDigits(rest[idx + 4 .. idx + 6], 60);
    idx += 6;
    var micro: i64 = 0;
    if (idx < rest.len and rest[idx] == '.') {
        const frac = readFracMicros(rest[idx + 1 ..]);
        micro = frac.micro;
        idx += 1 + frac.len;
    }
    var offset_sec: i64 = 0;
    if (idx < rest.len) {
        const c = rest[idx];
        if (c == 'Z') {
            idx += 1;
        } else if (c == '+' or c == '-') {
            const zsign: i64 = if (c == '-') -1 else 1;
            idx += 1;
            const oh = try parseTwoDigits(rest[idx..], 24);
            idx += 2;
            var om: i64 = 0;
            if (idx < rest.len and rest[idx] == ':') {
                idx += 1;
                om = try parseTwoDigits(rest[idx..], 60);
                idx += 2;
            }
            offset_sec = zsign * (oh * 3600 + om * 60);
        } else if (c == ' ') {
            // " NAME" zone: assume UTC (documented limitation).
            idx = rest.len;
        } else {
            return fail("invalid timestamp literal", error.InvalidDate);
        }
    }
    if (idx != rest.len) return fail("invalid timestamp literal", error.InvalidDate);
    return (days * 86400 + hour * 3600 + min * 60 + sec) * second_micros + micro - offset_sec * second_micros;
}

// -- Interval parsing (bigquery.ParseInterval + go-zetasqlite wrapper) -------

const IntervalPart = enum { years, months, days, hours, minutes, seconds, subsecs };

fn intervalTrimByte(part: IntervalPart) u8 {
    return switch (part) {
        .years, .days, .hours => ' ',
        .months => '-',
        .minutes, .seconds => ':',
        .subsecs => '.',
    };
}

/// Go bigquery getPartValue: trim the part prefix then capture its value.
/// Returns the parsed value and the remaining slice.
fn intervalGetPart(part: IntervalPart, s_in: []const u8) ValueError!struct { val: i32, rest: []const u8 } {
    var s = s_in;
    const tb = intervalTrimByte(part);
    while (s.len > 0 and s[0] == tb) s = s[1..];

    const allow_sign = switch (part) {
        .years, .days, .hours => true,
        else => false,
    };
    var negative = false;
    if (s.len > 0 and allow_sign) {
        if (s[0] == '-') {
            negative = true;
            s = s[1..];
        } else if (s[0] == '+') {
            s = s[1..];
        }
    }
    var captured: usize = 0;
    while (captured < s.len and std.ascii.isDigit(s[captured])) captured += 1;
    const digits = s[0..captured];
    s = s[captured..];

    if (digits.len == 0) {
        if (part == .subsecs) return .{ .val = 0, .rest = s };
        return fail("no value parsed for interval part", error.CorruptData);
    }
    if (part == .subsecs) {
        // 0.<digits> * 1e9 nanos, truncated (first 9 significant digits).
        var nanos: i64 = 0;
        var i: usize = 0;
        while (i < 9) : (i += 1) {
            nanos *= 10;
            if (i < digits.len) nanos += digits[i] - '0';
        }
        return .{ .val = @intCast(nanos), .rest = s };
    }
    var v: i64 = 0;
    for (digits) |ch| v = v * 10 + (ch - '0');
    if (negative) v = -v;
    return .{ .val = @intCast(v), .rest = s };
}

/// Go value.go parseInterval -> Interval (bigquery.ParseInterval plus the
/// negative-months fixup).
pub fn parseIntervalValue(s: []const u8) ValueError!Interval {
    if (s.len == 0) return fail("interval value is empty", error.CorruptData);
    const is_negative = s[0] == '-';
    var iv = Interval{};
    var rest = s;
    inline for ([_]IntervalPart{ .years, .months, .days, .hours, .minutes, .seconds, .subsecs }) |part| {
        const r = try intervalGetPart(part, rest);
        rest = r.rest;
        switch (part) {
            .years => iv.years = r.val,
            .months => iv.months = if (iv.years < 0) -r.val else r.val,
            .days => iv.days = r.val,
            .hours => iv.hours = r.val,
            .minutes => iv.minutes = if (iv.hours < 0) -r.val else r.val,
            .seconds => iv.seconds = if (iv.hours < 0) -r.val else r.val,
            .subsecs => iv.sub_second_nanos = if (iv.hours < 0) -r.val else r.val,
        }
    }
    if (is_negative and iv.months > 0) iv.months = -iv.months;
    return iv;
}

// ----------------------------------------------------------------------
// Go-compatible float formatting: strconv.FormatFloat(f, 'g', -1, 64)
// ----------------------------------------------------------------------

/// Renders `f` exactly as Go's strconv.FormatFloat(f, 'g', -1, 64) /
/// fmt.Sprint(float64) does: shortest round-trip digits, %e form when the
/// decimal exponent is < -4 or >= 6, "e+06"-style exponents (sign, >= 2
/// digits). `buf` must be at least 32 bytes.
pub fn formatFloatGo(buf: []u8, f: f64) []const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isInf(f)) return if (f > 0) "+Inf" else "-Inf";

    // Zig's {e} yields shortest round-trip (ryu) digits as [-]d[.ddd]e[-]dd;
    // the digits match Go's shortest digits, so we only re-arrange.
    var sci: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&sci, "{e}", .{f}) catch unreachable;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
    }
    var digits: [24]u8 = undefined;
    var nd: usize = 0;
    while (i < s.len and s[i] != 'e') : (i += 1) {
        if (s[i] == '.') continue;
        digits[nd] = s[i];
        nd += 1;
    }
    const exp = std.fmt.parseInt(i32, s[i + 1 ..], 10) catch unreachable;

    var w: usize = 0;
    if (neg) {
        buf[w] = '-';
        w += 1;
    }
    if (exp < -4 or exp >= 6) {
        // %e form: d[.ddd]e±XX
        buf[w] = digits[0];
        w += 1;
        if (nd > 1) {
            buf[w] = '.';
            w += 1;
            @memcpy(buf[w .. w + nd - 1], digits[1..nd]);
            w += nd - 1;
        }
        buf[w] = 'e';
        w += 1;
        buf[w] = if (exp < 0) '-' else '+';
        w += 1;
        const ae: u32 = @abs(exp);
        const tail = std.fmt.bufPrint(buf[w..], "{d:0>2}", .{ae}) catch unreachable;
        w += tail.len;
    } else {
        // %f form; dp = position of the decimal point in the digit string.
        const dp: i32 = exp + 1;
        if (dp <= 0) {
            buf[w] = '0';
            buf[w + 1] = '.';
            w += 2;
            var k: i32 = dp;
            while (k < 0) : (k += 1) {
                buf[w] = '0';
                w += 1;
            }
            @memcpy(buf[w .. w + nd], digits[0..nd]);
            w += nd;
        } else if (dp >= @as(i32, @intCast(nd))) {
            @memcpy(buf[w .. w + nd], digits[0..nd]);
            w += nd;
            var k: i32 = @intCast(nd);
            while (k < dp) : (k += 1) {
                buf[w] = '0';
                w += 1;
            }
        } else {
            const udp: usize = @intCast(dp);
            @memcpy(buf[w .. w + udp], digits[0..udp]);
            w += udp;
            buf[w] = '.';
            w += 1;
            @memcpy(buf[w .. w + nd - udp], digits[udp..nd]);
            w += nd - udp;
        }
    }
    return buf[0..w];
}

// ----------------------------------------------------------------------
// Value ordering. This backed the zetasqlite_collate collation until the
// encodings became memcomparable and SQLite took the comparison over; it
// remains the oracle the codec_sortable invariant tests assert against.
// (Mirrors Go's function_register.go:
// EQ first, then GT; comparison errors are swallowed as "false").
// ----------------------------------------------------------------------

pub fn compareForCollation(a: Value, b: Value) ValueError!std.math.Order {
    if (a.eq(b) catch false) return .eq;
    if (a.gt(b) catch false) return .gt;
    return .lt;
}

// ----------------------------------------------------------------------
// Construction helpers (tree values; intended for arena allocators)
// ----------------------------------------------------------------------

pub fn arrayValue(alloc: std.mem.Allocator, elems: []const Value) !Value {
    const av = try alloc.create(ArrayValue);
    av.* = .{ .values = try alloc.dupe(Value, elems) };
    return Value{ .array = av };
}

pub fn structValue(alloc: std.mem.Allocator, keys: []const []const u8, values: []const Value) !Value {
    std.debug.assert(keys.len == values.len);
    const sv = try alloc.create(StructValue);
    const owned_keys = try alloc.alloc([]const u8, keys.len);
    for (keys, owned_keys) |k, *ok| ok.* = try alloc.dupe(u8, k);
    sv.* = .{ .keys = owned_keys, .values = try alloc.dupe(Value, values) };
    return Value{ .struct_ = sv };
}

pub fn safeValue(alloc: std.mem.Allocator, inner: Value) !Value {
    const p = try alloc.create(Value);
    p.* = inner;
    return Value{ .safe = p };
}

/// The sole construction point for a numeric Value, and therefore where the
/// fixed-scale invariant is enforced: every path into a `.numeric` — analyzer
/// literal, codec decode, PARSE_*, CAST, parameter and result coercion, and all
/// four arithmetic operators — arrives here.
///
/// Rounding here rather than at encode time means an out-of-scale or
/// out-of-range numeric can never exist, instead of existing in memory and
/// failing later when something tries to store it.
pub fn numericValue(alloc: std.mem.Allocator, rat_in: Rat, is_bignumeric: bool) ValueError!Value {
    var rat = rat_in;
    const unscaled = try rat.roundToScale(alloc, scaleFor(is_bignumeric));
    // BIGNUMERIC's unscaled domain is exactly i256's, so roundToScale's
    // conversion already bounded it. NUMERIC's 38 digits are narrower than the
    // i128 that holds them, so it needs its own check.
    if (!is_bignumeric and (unscaled > numeric_unscaled_max or unscaled < -numeric_unscaled_max)) {
        return fail("numeric value out of range", error.NumericOutOfRange);
    }
    const p = alloc.create(Numeric) catch return error.OutOfMemory;
    p.* = .{ .rat = rat, .is_bignumeric = is_bignumeric };
    return Value{ .numeric = p };
}

/// Builds a numeric from an unscaled integer already at the kind's scale.
///
/// Skips the rounding `numericValue` would redo: a decoder has the invariant by
/// construction, and re-establishing it would cost a powTen, a bigint multiply
/// and a divTrunc per numeric per row to reach the value it already had. The
/// range check stays, because a hand-written blob can carry an unscaled value
/// the width allows but the type does not.
pub fn numericFromUnscaled(
    alloc: std.mem.Allocator,
    unscaled: i256,
    is_bignumeric: bool,
) ValueError!Value {
    if (!is_bignumeric and (unscaled > numeric_unscaled_max or unscaled < -numeric_unscaled_max)) {
        return fail("numeric value out of range", error.NumericOutOfRange);
    }
    var rat = Rat{
        .num = big_int.Managed.initSet(alloc, unscaled) catch return error.OutOfMemory,
        .den = try powTen(alloc, scaleFor(is_bignumeric)),
    };
    try rat.normalize(alloc);
    const p = alloc.create(Numeric) catch return error.OutOfMemory;
    p.* = .{ .rat = rat, .is_bignumeric = is_bignumeric };
    return Value{ .numeric = p };
}

/// Whether `v` is a BIGNUMERIC, following `.safe`. Needed because `toRat`
/// discards the flag, so arithmetic cannot otherwise see the right operand's
/// kind.
fn isBigNumeric(v: Value) bool {
    return switch (v) {
        .numeric => |n| n.is_bignumeric,
        .safe => |p| isBigNumeric(p.*),
        else => false,
    };
}

/// Convenience for tests: NUMERIC/BIGNUMERIC from its decimal literal.
pub fn numericFromString(alloc: std.mem.Allocator, s: []const u8, is_bignumeric: bool) ValueError!Value {
    return numericValue(alloc, try Rat.setString(alloc, s), is_bignumeric);
}

/// Structural equality assertion for tests (floats compared bit-for-bit so
/// NaN payloads and -0.0 round-trip checks are exact).
pub fn expectValueEqual(expected: Value, actual: Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .@"null" => {},
        .int => |i| try std.testing.expectEqual(i, actual.int),
        .float => |f| try std.testing.expectEqual(
            @as(u64, @bitCast(f)),
            @as(u64, @bitCast(actual.float)),
        ),
        .bool => |b| try std.testing.expectEqual(b, actual.bool),
        .string => |s| try std.testing.expectEqualStrings(s, actual.string),
        .bytes => |b| try std.testing.expectEqualSlices(u8, b, actual.bytes),
        .json => |s| try std.testing.expectEqualStrings(s, actual.json),
        .date => |d| try std.testing.expectEqual(d, actual.date),
        .timestamp => |m| try std.testing.expectEqual(m, actual.timestamp),
        .datetime => |m| try std.testing.expectEqual(m, actual.datetime),
        .time => |m| try std.testing.expectEqual(m, actual.time),
        .interval => |iv| try std.testing.expectEqual(iv, actual.interval),
        .numeric => |n| {
            var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer scratch.deinit();
            const salloc = scratch.allocator();
            try std.testing.expectEqual(n.is_bignumeric, actual.numeric.is_bignumeric);
            try std.testing.expectEqualStrings(
                try n.rat.ratString(salloc),
                try actual.numeric.rat.ratString(salloc),
            );
        },
        .array => |a| {
            try std.testing.expectEqual(a.values.len, actual.array.values.len);
            for (a.values, actual.array.values) |ev, av| try expectValueEqual(ev, av);
        },
        .struct_ => |st| {
            try std.testing.expectEqual(st.keys.len, actual.struct_.keys.len);
            for (st.keys, actual.struct_.keys) |ek, ak| try std.testing.expectEqualStrings(ek, ak);
            for (st.values, actual.struct_.values) |ev, av| try expectValueEqual(ev, av);
        },
        .safe => |p| try expectValueEqual(p.*, actual.safe.*),
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

test "civil date conversions" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 1), daysFromCivil(1970, 1, 2));
    try std.testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    try std.testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29)); // leap day
    try std.testing.expectEqual(@as(i64, 13150), daysFromCivil(2006, 1, 2));

    // Round-trip a wide range of days.
    var days: i64 = -1_000_000;
    while (days <= 1_000_000) : (days += 9973) {
        const c = civilFromDays(days);
        try std.testing.expectEqual(days, daysFromCivil(c.year, c.month, c.day));
    }
}

test "date string parse/format round trip" {
    const cases = [_]struct { s: []const u8, days: i64 }{
        .{ .s = "1970-01-01", .days = 0 },
        .{ .s = "2006-01-02", .days = 13150 },
        .{ .s = "1969-12-31", .days = -1 },
        .{ .s = "2000-02-29", .days = 11016 },
        .{ .s = "0001-01-01", .days = zero_time_days },
    };
    var buf: [32]u8 = undefined;
    for (cases) |c| {
        try std.testing.expectEqual(c.days, try parseDateDays(c.s));
        try std.testing.expectEqualStrings(c.s, formatDateDays(&buf, c.days));
    }
    try std.testing.expectError(error.InvalidDate, parseDateDays("2021-02-29"));
    try std.testing.expectError(error.InvalidDate, parseDateDays("2021-13-01"));
    try std.testing.expectError(error.InvalidDate, parseDateDays("garbage"));
}

test "formatFloatGo matches Go strconv 'g' output" {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { f: f64, s: []const u8 }{
        .{ .f = 42.0, .s = "42" },
        .{ .f = 1.5, .s = "1.5" },
        .{ .f = 1e20, .s = "1e+20" },
        .{ .f = 0.0001, .s = "0.0001" },
        .{ .f = 0.00001, .s = "1e-05" },
        .{ .f = 1e6, .s = "1e+06" },
        .{ .f = -1e6, .s = "-1e+06" },
        .{ .f = 100000.0, .s = "100000" },
        .{ .f = 999999.0, .s = "999999" },
        .{ .f = 123456.789, .s = "123456.789" },
        .{ .f = 1234567.8, .s = "1.2345678e+06" },
        .{ .f = 123456789.0, .s = "1.23456789e+08" },
        .{ .f = 2.5e-5, .s = "2.5e-05" },
        .{ .f = 1.7976931348623157e308, .s = "1.7976931348623157e+308" },
        .{ .f = 5e-324, .s = "5e-324" },
        .{ .f = 0.0, .s = "0" },
        .{ .f = -0.0, .s = "-0" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.s, formatFloatGo(&buf, c.f));
    }
    try std.testing.expectEqualStrings("NaN", formatFloatGo(&buf, std.math.nan(f64)));
    try std.testing.expectEqualStrings("+Inf", formatFloatGo(&buf, std.math.inf(f64)));
    try std.testing.expectEqualStrings("-Inf", formatFloatGo(&buf, -std.math.inf(f64)));
}

test "int arithmetic and comparisons coerce like Go" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = Value{ .int = 10 };
    try expectValueEqual(Value{ .int = 13 }, try a.add(alloc, Value{ .int = 3 }));
    try expectValueEqual(Value{ .int = 7 }, try a.sub(alloc, Value{ .int = 3 }));
    try expectValueEqual(Value{ .int = 30 }, try a.mul(alloc, Value{ .int = 3 }));
    try expectValueEqual(Value{ .int = 3 }, try a.div(alloc, Value{ .int = 3 }));
    try std.testing.expectError(error.DivideByZero, a.div(alloc, Value{ .int = 0 }));

    // RHS coerced via ToInt64: strings parse, empty string is 0, bool is 0/1.
    try expectValueEqual(Value{ .int = 52 }, try a.add(alloc, Value{ .string = "42" }));
    try expectValueEqual(Value{ .int = 26 }, try a.add(alloc, Value{ .string = "0x10" }));
    try expectValueEqual(Value{ .int = 10 }, try a.add(alloc, Value{ .string = "" }));
    try expectValueEqual(Value{ .int = 11 }, try a.add(alloc, Value{ .bool = true }));
    try std.testing.expectError(error.FailedConversion, a.add(alloc, Value{ .string = "abc" }));

    try std.testing.expect(try a.eq(Value{ .int = 10 }));
    try std.testing.expect(try a.eq(Value{ .string = "10" }));
    try std.testing.expect(try a.gt(Value{ .int = 9 }));
    try std.testing.expect(try a.gte(Value{ .int = 10 }));
    // Go coerces via ToInt64, truncating: int64(10.5) == 10, so NOT lt.
    try std.testing.expect(!try a.lt(Value{ .float = 10.5 }));
    try std.testing.expect(try a.lte(Value{ .int = 10 }));
}

test "float comparisons and NaN" {
    const f = Value{ .float = 1.5 };
    try std.testing.expect(try f.eq(Value{ .float = 1.5 }));
    try std.testing.expect(try f.gt(Value{ .int = 1 }));
    try std.testing.expect(try f.lt(Value{ .string = "2.5" }));
    const nan = Value{ .float = std.math.nan(f64) };
    try std.testing.expect(!try nan.eq(nan));
    try std.testing.expect(!try nan.lt(Value{ .float = 0 }));
}

test "string semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const s = Value{ .string = "abc" };
    try expectValueEqual(Value{ .string = "abcdef" }, try s.add(alloc, Value{ .string = "def" }));
    try expectValueEqual(Value{ .string = "abc42" }, try s.add(alloc, Value{ .int = 42 }));
    try std.testing.expectError(error.UnsupportedOperation, s.sub(alloc, Value{ .string = "c" }));

    try std.testing.expect(try s.eq(Value{ .string = "abc" }));
    try std.testing.expect(try s.lt(Value{ .string = "abd" }));
    try std.testing.expect(try s.gt(Value{ .string = "ab" }));
    // Comparison against numbers goes through the formatted number.
    try std.testing.expect(try (Value{ .string = "42" }).eq(Value{ .int = 42 }));
    try std.testing.expect(try (Value{ .string = "1.5" }).eq(Value{ .float = 1.5 }));

    try std.testing.expectEqual(@as(i64, 42), try (Value{ .string = "42" }).toInt64());
    try std.testing.expectEqual(@as(i64, 255), try (Value{ .string = "0xff" }).toInt64());
    try std.testing.expectEqual(true, try (Value{ .string = "true" }).toBool());
    try std.testing.expectEqual(false, try (Value{ .string = "" }).toBool());
}

test "bool semantics" {
    const t = Value{ .bool = true };
    try std.testing.expect(try t.eq(Value{ .bool = true }));
    try std.testing.expect(try t.eq(Value{ .int = 1 }));
    try std.testing.expectError(error.UnsupportedOperation, t.gt(Value{ .bool = false }));
    try std.testing.expectEqual(@as(i64, 1), try t.toInt64());
    try std.testing.expectEqual(@as(f64, 0), try (Value{ .bool = false }).toFloat64());
}

test "date semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const days = try parseDateDays("2020-02-28");
    const d = Value{ .date = days };
    try std.testing.expectEqualStrings("2020-02-28", try d.toString(alloc));
    // Go DateValue.ToInt64 = unix seconds (days * 86400).
    try std.testing.expectEqual(days * 86400, try d.toInt64());

    // date + int adds days (leap year).
    const next = try d.add(alloc, Value{ .int = 1 });
    try std.testing.expectEqualStrings("2020-02-29", try next.toString(alloc));
    const prev = try d.sub(alloc, Value{ .int = 28 });
    try std.testing.expectEqualStrings("2020-01-31", try prev.toString(alloc));

    try std.testing.expect(try d.eq(Value{ .string = "2020-02-28" }));
    try std.testing.expect(try d.lt(Value{ .date = try parseDateDays("2020-03-01") }));
    try std.testing.expect(try d.gt(Value{ .string = "2019-12-31" }));
    try std.testing.expectError(error.FailedConversion, d.eq(Value{ .string = "not a date" }));
}

test "array comparisons are element-wise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try arrayValue(alloc, &.{ Value{ .int = 1 }, Value{ .string = "x" } });
    const b = try arrayValue(alloc, &.{ Value{ .int = 1 }, Value{ .string = "x" } });
    const c = try arrayValue(alloc, &.{ Value{ .int = 2 }, Value{ .string = "x" } });
    const short = try arrayValue(alloc, &.{Value{ .int = 1 }});

    try std.testing.expect(try a.eq(b));
    try std.testing.expect(!try a.eq(c));
    try std.testing.expect(!try a.eq(short)); // length mismatch => false
    // Go: GT holds only if it holds for every element; "x" > "x" fails.
    try std.testing.expect(!try c.gt(a));
    try std.testing.expectError(error.UnsupportedOperation, a.add(alloc, b));
}

test "struct comparisons match by key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const s1 = try structValue(alloc, &.{ "a", "b" }, &.{ Value{ .int = 1 }, Value{ .string = "x" } });
    const s2 = try structValue(alloc, &.{ "b", "a" }, &.{ Value{ .string = "x" }, Value{ .int = 1 } });
    const s3 = try structValue(alloc, &.{ "a", "b" }, &.{ Value{ .int = 2 }, Value{ .string = "x" } });
    const s4 = try structValue(alloc, &.{ "a", "c" }, &.{ Value{ .int = 1 }, Value{ .string = "x" } });

    // Key-based comparison: field order does not matter (Go iterates the map).
    try std.testing.expect(try s1.eq(s2));
    try std.testing.expect(!try s1.eq(s3));
    try std.testing.expectError(error.NullValue, s1.eq(s4)); // missing key => Go nil deref
    const field = s1.struct_.fieldByName("a") orelse return error.TestUnexpectedResult;
    try expectValueEqual(Value{ .int = 1 }, field);
    try std.testing.expect(s1.struct_.fieldByName("zzz") == null);
}

test "safe value swallows errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const safe_int = try safeValue(alloc, Value{ .int = 10 });
    // SAFE.DIVIDE(10, 0) => NULL instead of an error.
    try expectValueEqual(Value.@"null", try safe_int.div(alloc, Value{ .int = 0 }));
    // Successful ops pass through unwrapped.
    try expectValueEqual(Value{ .int = 5 }, try safe_int.div(alloc, Value{ .int = 2 }));
    // Failed conversions become zero values.
    const safe_str = try safeValue(alloc, Value{ .string = "abc" });
    try std.testing.expectEqual(@as(i64, 0), try safe_str.toInt64());
    try std.testing.expectEqual(false, try safe_str.toBool());
    // Failed comparisons become false.
    const safe_bool = try safeValue(alloc, Value{ .bool = true });
    try std.testing.expectEqual(false, try safe_bool.gt(Value{ .bool = false }));
}

test "timestamp api/string formatting matches Go" {
    var buf: [48]u8 = undefined;
    // ToApiString: "sec.microRemainder" (unpadded remainder).
    try std.testing.expectEqualStrings("1136239445.0", formatTimestampApi(&buf, 1136239445_000000));
    try std.testing.expectEqualStrings("1705314615.500000", formatTimestampApi(&buf, 1705314615_500000));
    // ToString: "...-07" zone verb => "+00" (fractional trimmed).
    try std.testing.expectEqualStrings("2006-01-02 22:04:05+00", formatTimestampString(&buf, 1136239445_000000));
    try std.testing.expectEqualStrings("2024-01-15 10:30:15.5+00", formatTimestampString(&buf, 1705314615_500000));
    // Interface(): RFC3339 (no fractional, 'Z').
    try std.testing.expectEqualStrings("2006-01-02T22:04:05Z", formatTimestampRfc3339(&buf, 1136239445_000000));
    // Round trip: parse (space + "+00") back to unix micros.
    try std.testing.expectEqual(@as(i64, 1136239445_000000), try parseTimestampMicros("2006-01-02 22:04:05+00"));
    try std.testing.expectEqual(@as(i64, 1136239445_000000), try parseTimestampApi("1136239445.0"));
}

test "timestamp parse accepts every Go layout" {
    // All represent the same instant 2006-01-02 22:04:05 UTC (1136239445s).
    const want: i64 = 1136239445_000000;
    const layouts = [_][]const u8{
        "2006-01-02T22:04:05Z",
        "2006-01-02T22:04:05+00:00",
        "2006-01-02T22:04:05-00",
        "2006-01-02T22:04:05 UTC",
        "2006-01-02T22:04:05",
        "2006-01-02 22:04:05Z",
        "2006-01-02 22:04:05+00:00",
        "2006-01-02 22:04:05-00",
        "2006-01-02 22:04:05",
    };
    for (layouts) |s| try std.testing.expectEqual(want, try parseTimestampMicros(s));
    // Bare date => midnight.
    try std.testing.expectEqual(
        (try parseDateDays("2006-01-02")) * 86400 * second_micros,
        try parseTimestampMicros("2006-01-02"),
    );
    // Non-zero offset shifts the instant: 00:04:05+02 == 22:04:05 UTC the
    // previous day, i.e. the same instant as `want`.
    try std.testing.expectEqual(want, try parseTimestampMicros("2006-01-03 00:04:05+02"));
}

test "the hour may be one digit, as Go's `15` layout element allows" {
    // Raw state data spells midnight "0:00:00" and morning "7:34:44". Go's
    // isDatetime regex wants {2} and rejects those, so ToTime falls through to
    // parseTimestamp, whose `15` accepts one digit — these used to die as
    // "failed to convert %s to time.Time type" on both the insertAll bind path
    // and the runtime CAST.
    try std.testing.expectEqual(
        try parseTimestampMicros("2024-01-05 00:00:00"),
        try parseTimestampMicros("2024-01-05 0:00:00"),
    );
    try std.testing.expectEqual(
        try parseTimestampMicros("2020-11-30 07:34:44"),
        try parseTimestampMicros("2020-11-30 7:34:44"),
    );
    // The flexible width does not disturb what follows it: separator,
    // fractional seconds and zone all still land.
    try std.testing.expectEqual(
        try parseTimestampMicros("2006-01-02T07:04:05.5Z"),
        try parseTimestampMicros("2006-01-02T7:04:05.5Z"),
    );
    try std.testing.expectEqual(
        try parseTimestampMicros("2006-01-02 07:04:05+02:30"),
        try parseTimestampMicros("2006-01-02 7:04:05+02:30"),
    );
    // parseDatetime and parseTime spell the hour `15` too, and both are called
    // directly (driver castParamValue, codec_binary) rather than only through
    // the shape dispatch.
    try std.testing.expectEqual(
        try parseDatetimeMicros("2024-01-05 00:00:00"),
        try parseDatetimeMicros("2024-01-05 0:00:00"),
    );
    try std.testing.expectEqual(
        try parseTimeMicros("07:34:44"),
        try parseTimeMicros("7:34:44"),
    );

    // Minute and second are stdZeroMinute/stdZeroSecond — fixed width. Go
    // rejects these and so do we.
    try std.testing.expectError(error.InvalidDate, parseTimeMicros("7:4:44"));
    try std.testing.expectError(error.InvalidDate, parseTimeMicros("7:04:4"));
    try std.testing.expectError(error.InvalidDate, parseTimestampMicros("2024-01-05 7:4:44"));
    // An hour still has to be a digit, and still has to be an hour.
    try std.testing.expectError(error.InvalidDate, parseTimestampMicros("2024-01-05 :00:00"));
    try std.testing.expectError(error.InvalidDate, parseTimestampMicros("2024-01-05 24:00:00"));
    try std.testing.expectError(error.InvalidDate, parseTimeMicros("9"));
}

test "datetime and time formatting / parsing" {
    var buf: [48]u8 = undefined;
    const dt = try parseDatetimeMicros("2024-01-15 10:30:00");
    try std.testing.expectEqualStrings("2024-01-15 10:30:00", formatDatetimeString(&buf, dt));
    try std.testing.expectEqualStrings("2024-01-15T10:30:00", formatDatetimeApi(&buf, dt));
    // T separator and fractional round-trip.
    const dtf = try parseDatetimeMicros("2024-01-15T10:30:15.123456");
    try std.testing.expectEqualStrings("2024-01-15 10:30:15.123456", formatDatetimeString(&buf, dtf));

    const tv = try parseTimeMicros("10:30:15");
    try std.testing.expectEqual(@as(i64, (10 * 3600 + 30 * 60 + 15) * second_micros), tv);
    try std.testing.expectEqualStrings("10:30:15", formatTimeString(&buf, tv));
    const tvf = try parseTimeMicros("10:30:15.5");
    try std.testing.expectEqualStrings("10:30:15.5", formatTimeString(&buf, tvf));
    try std.testing.expectError(error.InvalidDate, parseTimeMicros("10:30"));
    try std.testing.expectError(error.InvalidDate, parseTimeMicros("25:00:00"));
}

test "interval parse/format round trips (bigquery canonical)" {
    var buf: [96]u8 = undefined;
    const cases = [_][]const u8{
        "1-2 3 4:5:6",
        "0-0 1 0:0:0",
        "1-2 0 0:0:0",
        "0-0 0 1:2:3.123456",
        "0-0 0 1:2:3.5",
        "-1-2 0 0:0:0",
        "0-0 0 -1:2:3",
        "10-0 0 0:0:0",
    };
    for (cases) |s| {
        const iv = try parseIntervalValue(s);
        try std.testing.expectEqualStrings(s, formatInterval(&buf, iv));
    }
    // Canonicalization reduces 13 months to 1-1.
    const c = try parseIntervalValue("0-13 0 0:0:0");
    try std.testing.expectEqualStrings("1-1 0 0:0:0", formatInterval(&buf, c));
}

test "timestamp / datetime arithmetic and comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [48]u8 = undefined;

    const ts = Value{ .timestamp = try parseTimestampMicros("2024-01-31 10:00:00+00") };
    // + INTERVAL 1 month => Go's time.Date normalizes Jan 31 -> Feb 31 -> Mar 2.
    const plus_month = try ts.add(alloc, Value{ .interval = .{ .months = 1 } });
    try std.testing.expectEqualStrings("2024-03-02 10:00:00+00", formatTimestampString(&buf, plus_month.timestamp));
    // + INTERVAL 1 day.
    const plus_day = try ts.add(alloc, Value{ .interval = .{ .days = 1 } });
    try std.testing.expectEqualStrings("2024-02-01 10:00:00+00", formatTimestampString(&buf, plus_day.timestamp));
    // timestamp - timestamp => interval duration (H:M:S).
    const later = Value{ .timestamp = try parseTimestampMicros("2024-01-31 12:30:15+00") };
    const diff = try later.sub(alloc, ts);
    try std.testing.expectEqualStrings("0-0 0 2:30:15", formatInterval(&buf, diff.interval));

    // Comparisons compare the underlying instant.
    try std.testing.expect(try later.gt(ts));
    try std.testing.expect(try ts.lt(later));
    try std.testing.expect(try ts.eq(Value{ .timestamp = ts.timestamp }));
    // Against a string form (parsed via ToTime).
    try std.testing.expect(try ts.eq(Value{ .string = "2024-01-31 10:00:00+00" }));

    // Datetime + interval.
    const dt = Value{ .datetime = try parseDatetimeMicros("2024-02-29 23:59:59") };
    const dt_next = try dt.add(alloc, Value{ .interval = .{ .seconds = 1 } });
    try std.testing.expectEqualStrings("2024-03-01 00:00:00", formatDatetimeString(&buf, dt_next.datetime));

    // Interval comparisons and arithmetic are unsupported (like Go).
    const iv = Value{ .interval = .{ .days = 1 } };
    try std.testing.expectError(error.UnsupportedOperation, iv.eq(iv));
    try std.testing.expectError(error.UnsupportedOperation, iv.add(alloc, iv));
}

test "time-kind conversions (ToInt64 / ToFloat64 / ToString)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ts = Value{ .timestamp = 1136239445_000000 };
    try std.testing.expectEqual(@as(i64, 1136239445), try ts.toInt64());
    try std.testing.expectEqual(@as(f64, 1136239445), try ts.toFloat64());
    try std.testing.expectEqualStrings("2006-01-02 22:04:05+00", try ts.toString(alloc));
    try std.testing.expectEqualStrings("1136239445.0", try ts.toApiString(alloc));
    try std.testing.expectError(error.FailedConversion, ts.toBool());

    // TIME anchored at Go's zero civil date; Unix() is the huge negative base.
    const tv = Value{ .time = (10 * 3600 + 30 * 60) * second_micros };
    try std.testing.expectEqual(@as(i64, -62169946200), try tv.toInt64());
    try std.testing.expectEqualStrings("10:30:00", try tv.toApiString(alloc));
}

test "Rat setString / rendering matches Go big.Rat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { in: []const u8, rat: []const u8, dec9: []const u8 }{
        .{ .in = "123.45", .rat = "2469/20", .dec9 = "123.45" },
        .{ .in = "1.5", .rat = "3/2", .dec9 = "1.5" },
        .{ .in = "-1.5", .rat = "-3/2", .dec9 = "-1.5" },
        .{ .in = "0", .rat = "0", .dec9 = "0" },
        .{ .in = "42", .rat = "42", .dec9 = "42" },
        .{ .in = "12.4E17", .rat = "1240000000000000000", .dec9 = "1240000000000000000" },
        .{ .in = "12.34E27", .rat = "12340000000000000000000000000", .dec9 = "12340000000000000000000000000" },
        .{ .in = "1.0123456789", .rat = "10123456789/10000000000", .dec9 = "1.012345679" }, // rounds half away
        .{ .in = "-0.000000001", .rat = "-1/1000000000", .dec9 = "-0.000000001" },
        .{ .in = "3/2", .rat = "3/2", .dec9 = "1.5" },
        .{ .in = "-3/2", .rat = "-3/2", .dec9 = "-1.5" },
        .{ .in = "4/2", .rat = "2", .dec9 = "2" }, // normalizes
        .{ .in = "1e-10", .rat = "1/10000000000", .dec9 = "0" }, // rounds to 0 at scale 9
    };
    for (cases) |c| {
        const r = try Rat.setString(alloc, c.in);
        try std.testing.expectEqualStrings(c.rat, try r.ratString(alloc));
        const n = Numeric{ .rat = r, .is_bignumeric = false };
        try std.testing.expectEqualStrings(c.dec9, try n.toText(alloc));
    }

    // BIGNUMERIC precision: 39 fractional digits round to 38.
    const bn = try Rat.setString(alloc, "1.123456789012345678901234567890123456789");
    const nb = Numeric{ .rat = bn, .is_bignumeric = true };
    try std.testing.expectEqualStrings(
        "1.12345678901234567890123456789012345679",
        try nb.toText(alloc),
    );
    // NUMERIC rendering of the same value rounds at 9 digits.
    const nn = Numeric{ .rat = bn, .is_bignumeric = false };
    try std.testing.expectEqualStrings("1.123456789", try nn.toText(alloc));

    // Go quirk: -1e-10 renders "-0" (sign survives the round-to-zero).
    const tiny = try Rat.setString(alloc, "-1e-10");
    const nt = Numeric{ .rat = tiny, .is_bignumeric = false };
    try std.testing.expectEqualStrings("-0", try nt.toText(alloc));

    // Invalid literals fail like Go's SetString.
    try std.testing.expectError(error.FailedConversion, Rat.setString(alloc, ""));
    try std.testing.expectError(error.FailedConversion, Rat.setString(alloc, "abc"));
    try std.testing.expectError(error.FailedConversion, Rat.setString(alloc, "1.2.3"));
    try std.testing.expectError(error.FailedConversion, Rat.setString(alloc, "1/0"));
    try std.testing.expectError(error.FailedConversion, Rat.setString(alloc, "1e"));
}

test "numeric value arithmetic / comparisons / conversions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try numericFromString(alloc, "1.5", false);
    const b = try numericFromString(alloc, "2.25", false);

    const sum = try a.add(alloc, b);
    try std.testing.expectEqualStrings("3.75", try sum.toString(alloc));
    const diff = try a.sub(alloc, b);
    try std.testing.expectEqualStrings("-0.75", try diff.toString(alloc));
    const prod = try a.mul(alloc, b);
    try std.testing.expectEqualStrings("3.375", try prod.toString(alloc));
    const quot = try b.div(alloc, a);
    try std.testing.expectEqualStrings("1.5", try quot.toString(alloc));
    // Division by a zero numeric errors (Go panics inside big.Rat.Inv).
    const zero = try numericFromString(alloc, "0", false);
    try std.testing.expectError(error.DivideByZero, a.div(alloc, zero));

    // Mixed-kind rhs coerces through ToRat: int, float, string.
    const plus_int = try a.add(alloc, Value{ .int = 2 });
    try std.testing.expectEqualStrings("3.5", try plus_int.toString(alloc));
    const plus_float = try a.add(alloc, Value{ .float = 0.25 });
    try std.testing.expectEqualStrings("1.75", try plus_float.toString(alloc));
    const plus_str = try a.add(alloc, Value{ .string = "1.5" });
    try std.testing.expectEqualStrings("3", try plus_str.toString(alloc));
    // Go quirk: an unparseable string coerces to the zero Rat.
    const plus_bad = try a.add(alloc, Value{ .string = "abc" });
    try std.testing.expectEqualStrings("1.5", try plus_bad.toString(alloc));

    // Comparisons.
    try std.testing.expect(try b.gt(a));
    try std.testing.expect(try a.lt(b));
    try std.testing.expect(try a.eq(try numericFromString(alloc, "1.50", false)));
    try std.testing.expect(try a.gte(a));
    try std.testing.expect(try a.eq(Value{ .float = 1.5 }));
    try std.testing.expect(try a.lt(Value{ .int = 2 }));

    // Conversions. ToInt64 is the *numerator* (Go bug-for-bug): 1.5 -> 3/2 -> 3.
    try std.testing.expectEqual(@as(i64, 3), try a.toInt64());
    try std.testing.expectEqual(@as(f64, 1.5), try a.toFloat64());
    const one = try numericFromString(alloc, "1", false);
    try std.testing.expectEqual(true, try one.toBool());
    try std.testing.expectEqual(false, try zero.toBool());
    const three = try numericFromString(alloc, "3", false);
    try std.testing.expectError(error.FailedConversion, three.toBool());

    // BIGNUMERIC results keep their flag through arithmetic.
    const big1 = try numericFromString(alloc, "1.5", true);
    const big_sum = try big1.add(alloc, Value{ .int = 1 });
    try std.testing.expect(big_sum.numeric.is_bignumeric);
    try std.testing.expectEqualStrings("2.5", try big_sum.toString(alloc));
}

test "Rat fromScaledTwosComplement (proto byte layout)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // NUMERIC '1.5': 1_500_000_000 LE minimal-length.
    const r1 = try Rat.fromScaledTwosComplement(alloc, &.{ 0x00, 0x2f, 0x68, 0x59 }, 9);
    try std.testing.expectEqualStrings("3/2", try r1.ratString(alloc));
    // NUMERIC '-1.5'.
    const r2 = try Rat.fromScaledTwosComplement(alloc, &.{ 0x00, 0xd1, 0x97, 0xa6 }, 9);
    try std.testing.expectEqualStrings("-3/2", try r2.ratString(alloc));
    // NUMERIC '0' (single zero byte) and empty payload.
    const r3 = try Rat.fromScaledTwosComplement(alloc, &.{0x00}, 9);
    try std.testing.expect(r3.isZero());
    const r4 = try Rat.fromScaledTwosComplement(alloc, &.{}, 9);
    try std.testing.expect(r4.isZero());
    // NUMERIC '-0.000000001' == -1 scaled (0xff sign-extended).
    const r5 = try Rat.fromScaledTwosComplement(alloc, &.{0xff}, 9);
    try std.testing.expectEqualStrings("-1/1000000000", try r5.ratString(alloc));
}

test "numeric rounding breaks ties away from zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Exact halves at the scale boundary. Corpus cases 618/619 only ever round
    // a trailing 9, which half-away-from-zero, half-up and half-even all agree
    // on, so nothing there pins the tie rule. BigQuery documents half away from
    // zero: the magnitude always grows, so the negative twin must go to -2 and
    // not to -1.
    const cases = [_]struct { in: []const u8, out: []const u8, big: bool }{
        .{ .in = "0.0000000005", .out = "0.000000001", .big = false },
        .{ .in = "-0.0000000005", .out = "-0.000000001", .big = false },
        .{ .in = "0.0000000015", .out = "0.000000002", .big = false },
        .{ .in = "-0.0000000015", .out = "-0.000000002", .big = false },
        // Half-even would give 0.000000002 for the first of those.
        .{ .in = "0.000000000000000000000000000000000000005", .out = "0.00000000000000000000000000000000000001", .big = true },
    };
    for (cases) |tc| {
        const v = try numericValue(alloc, try Rat.setString(alloc, tc.in), tc.big);
        try std.testing.expectEqualStrings(tc.out, try v.numeric.toText(alloc));
    }
}

test "compareForCollation orderings" {
    // Strings
    try std.testing.expectEqual(std.math.Order.eq, try compareForCollation(
        Value{ .string = "abc" },
        Value{ .string = "abc" },
    ));
    try std.testing.expectEqual(std.math.Order.lt, try compareForCollation(
        Value{ .string = "abc" },
        Value{ .string = "abd" },
    ));
    try std.testing.expectEqual(std.math.Order.gt, try compareForCollation(
        Value{ .string = "b" },
        Value{ .string = "a" },
    ));
    // Ints
    try std.testing.expectEqual(std.math.Order.lt, try compareForCollation(
        Value{ .int = 1 },
        Value{ .int = 2 },
    ));
    try std.testing.expectEqual(std.math.Order.eq, try compareForCollation(
        Value{ .int = 7 },
        Value{ .int = 7 },
    ));
    try std.testing.expectEqual(std.math.Order.gt, try compareForCollation(
        Value{ .int = 3 },
        Value{ .int = -3 },
    ));
    // Dates
    const d1 = Value{ .date = try parseDateDays("2021-01-01") };
    const d2 = Value{ .date = try parseDateDays("2021-06-15") };
    try std.testing.expectEqual(std.math.Order.lt, try compareForCollation(d1, d2));
    try std.testing.expectEqual(std.math.Order.gt, try compareForCollation(d2, d1));
    try std.testing.expectEqual(std.math.Order.eq, try compareForCollation(d1, d1));
    // Incomparable pair degrades to lt (Go swallows comparison errors).
    try std.testing.expectEqual(std.math.Order.lt, try compareForCollation(
        Value{ .bool = true },
        Value{ .array = &empty_array_storage },
    ));
}
