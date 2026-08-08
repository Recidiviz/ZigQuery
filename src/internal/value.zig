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
pub fn failFmt(comptime fmt: []const u8, args: anytype, err: ValueError) ValueError {
    setDiagnostic(fmt, args);
    return err;
}

/// Records a diagnostic without choosing the error, for callers whose error set is not
/// `ValueError` — the coordinator and the transformer raise their own but surface through
/// this same channel (`driver.setLastError` prefers it over the bare error name).
pub fn setDiagnostic(comptime fmt: []const u8, args: anytype) void {
    diagnostic = std.fmt.bufPrint(&diag_buf, fmt, args) catch fmt;
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

/// RANGE<T>: a contiguous span, lower bound inclusive and upper exclusive.
/// googlesql allows exactly three element types (range_type.cc IsSupported-
/// ElementTypeKind), so the element is an enum rather than a nested Type.
///
/// Stored inline like Interval: 24 bytes, trivially copyable, no arena needed.
pub const Range = struct {
    /// Carried explicitly rather than inferred from whichever bound is
    /// present, because `[UNBOUNDED, UNBOUNDED)` has neither.
    elem: ElemKind,
    /// false is UNBOUNDED. A flag beside a plain `i64` rather than the `?i64`
    /// the accessors below hand back: two optionals are 32 bytes on their own
    /// and take Range to 40, past Interval's 28, which is what currently sets
    /// the union payload — Value would grow from 40 bytes to 48 for every
    /// value of every kind. Flags keep Range at 24 and Value where it was.
    has_start: bool = false,
    has_end: bool = false,
    /// Units match the sibling Value variant exactly, so a bound converts to
    /// and from its scalar kind without rescaling: civil days for `.date`,
    /// civil micros for `.datetime`, unix micros UTC for `.timestamp`.
    ///
    /// Zero whenever the matching flag is false. `rangeValue` is the only
    /// constructor and enforces it, so two ranges that differ solely in the
    /// junk under an absent bound cannot exist — which is what lets the
    /// sortable encoding zero-fill that slot and stay canonical.
    start: i64 = 0,
    end: i64 = 0,

    pub const ElemKind = enum(u8) { date = 1, datetime = 2, timestamp = 3 };

    pub fn startBound(self: Range) ?i64 {
        return if (self.has_start) self.start else null;
    }

    pub fn endBound(self: Range) ?i64 {
        return if (self.has_end) self.end else null;
    }

    /// The bound as the scalar Value it denotes; `.null` for UNBOUNDED.
    pub fn startValue(self: Range) Value {
        return boundValue(self.elem, self.startBound());
    }

    pub fn endValue(self: Range) Value {
        return boundValue(self.elem, self.endBound());
    }

    fn boundValue(elem: ElemKind, bound: ?i64) Value {
        const n = bound orelse return Value.null;
        return switch (elem) {
            .date => .{ .date = n },
            .datetime => .{ .datetime = n },
            .timestamp => .{ .timestamp = n },
        };
    }
};

/// The sole construction point for a range Value, so the "zero under an absent
/// bound" invariant holds everywhere — the same doctrine `numericValue` uses
/// for its fixed-scale invariant.
///
/// Deliberately does *not* enforce `start < end`. RANGE_INTERSECT builds
/// `[max(starts), min(ends))` behind an overlap test that already guarantees
/// it, and both decoders have to be able to materialise whatever bytes they
/// were handed. The check belongs to the `RANGE()` constructor alone, which is
/// where googlesql puts it too (value.cc MakeRange).
pub fn rangeValue(elem: Range.ElemKind, start: ?i64, end: ?i64) Value {
    return .{ .range = .{
        .elem = elem,
        .has_start = start != null,
        .has_end = end != null,
        .start = start orelse 0,
        .end = end orelse 0,
    } };
}

/// The raw scalar behind an element Value, in the units `Range` stores.
///
/// Deliberately not `toInt64`, which is a *conversion* and rescales: it hands
/// back unix seconds for a `.date` (days x 86400) and for a `.timestamp`. A
/// bound needs the number as stored — civil days, civil micros, unix micros.
pub fn rangeElementScalar(v: Value) ValueError!i64 {
    return switch (if (v == .safe) v.safe.* else v) {
        .date, .datetime, .timestamp => |n| n,
        else => fail("value is not a valid range element", error.FailedConversion),
    };
}

/// The element kind a scalar bound denotes, or null if it is not one of the
/// three kinds a range can be built over.
pub fn rangeElementOf(v: Value) ?Range.ElemKind {
    return switch (if (v == .safe) v.safe.* else v) {
        .date => .date,
        .datetime => .datetime,
        .timestamp => .timestamp,
        else => null,
    };
}

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

    // There is deliberately no lookup-by-name here. Every field access
    // GoogleSQL resolves is already an index by the time it reaches the
    // runtime (`zetasqlite_get_struct_field(expr, <n>)`), names on a STRUCT
    // need not be unique or even present, and the one thing a by-name helper
    // was used for — comparison and CAST — turned out to be positional.
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

/// Fixed-point decimal arithmetic, mirroring googlesql's NUMERIC/BIGNUMERIC.
///
/// googlesql stores both as a scaled two's-complement integer: NUMERIC as
/// `FixedInt<64, 2>` scaled by 10^9, BIGNUMERIC as `FixedInt<64, 4>` scaled by
/// 10^38 (public/numeric_value.h, "Internally NUMERIC values are stored as
/// scaled 128 bit integers"). There is no numerator and denominator, nothing is
/// reduced, and nothing allocates: an add is an integer add and a multiply is a
/// widening multiply followed by a divide by a constant power of ten.
///
/// This port previously mirrored goccy/go-zetasqlite, which keeps a Go
/// `big.Rat` — an arbitrary-precision *rational*, gcd-reduced on construction,
/// two heap allocations per value. Sampling an ingest view test put that at
/// ~26% of engine CPU in `gcd` and `divTrunc` alone. Nothing about the type
/// needed it: `numericValue` rounds every result onto the scale grid, so the
/// denominator was always a divisor of 10^scale.
///
/// `i256` holds both kinds — BIGNUMERIC's maximum is just under 2^255 — and
/// `Wide` holds the intermediates. The widest is the multiply: two BIGNUMERIC
/// maxima multiply to ~3.3e153, against i512's ~6.7e153.
const Wide = i512;

/// 10^e, for every exponent the two scales can ask for.
fn pow10(comptime T: type, e: usize) T {
    return @intCast(pow_ten_table[e]);
}

/// `n / d` rounded half away from zero — googlesql's rounding for NUMERIC, and
/// the rule the old `toUnscaled` applied via its `2*rem >= den` test. `d` is
/// always a positive power of ten here.
fn divRound(n: Wide, d: Wide) Wide {
    const q = @divTrunc(n, d);
    const rem = n - q * d;
    const twice = if (rem < 0) -rem * 2 else rem * 2;
    if (twice >= d) return if (n < 0) q - 1 else q + 1;
    return q;
}

/// `v`, an unscaled integer at `from`, restated at `to`. Exact when widening,
/// which is the only direction the arithmetic needs: a result takes the wider
/// of its operands' scales, so `to` is never the smaller.
fn rescale(v: Wide, from: usize, to: usize) Wide {
    if (to == from) return v;
    if (to > from) return v * pow10(Wide, to - from);
    return divRound(v, pow10(Wide, from - to));
}

/// The unscaled value is in range for its kind.
///
/// NUMERIC's 38 digits are narrower than the i256 that carries them, so it
/// needs an explicit bound; BIGNUMERIC's domain is exactly i256's, so staying
/// in the type is the whole check.
fn checkRange(unscaled: Wide, is_bignumeric: bool) ValueError!i256 {
    const lo: Wide = if (is_bignumeric) std.math.minInt(i256) else -numeric_unscaled_max;
    const hi: Wide = if (is_bignumeric) std.math.maxInt(i256) else numeric_unscaled_max;
    if (unscaled < lo or unscaled > hi) {
        return fail("numeric value out of range", error.NumericOutOfRange);
    }
    return @intCast(unscaled);
}

/// Go big.Rat.SetString's grammar, read straight to an unscaled integer:
/// "[+-]digits[.digits][eE[+-]digits]", or the fraction form
/// "[+-]digits/digits". The whole string must match.
///
/// Digits past `scale` round rather than being carried, which is what the Rat
/// path did in a second step. Reading them into a Wide as it goes means a
/// literal with more digits than the type can hold is caught here rather than
/// overflowing, so the accumulator saturates once the value is past any range
/// its kind allows.
fn unscaledFromString(s: []const u8, scale: usize) ValueError!Wide {
    if (s.len == 0) return error.FailedConversion;

    if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
        const num = try unscaledFromString(s[0..slash], scale);
        const den = try unscaledFromString(s[slash + 1 ..], 0);
        if (den == 0) return error.FailedConversion; // Go: SetString fails on /0
        if (den < 0) return error.FailedConversion; // denominator is unsigned
        return divRound(num, den);
    }

    var rest = s;
    var negative = false;
    if (rest[0] == '+' or rest[0] == '-') {
        negative = rest[0] == '-';
        rest = rest[1..];
    }

    // The mantissa's digits, and how many of them were after the point.
    var mant: Wide = 0;
    var frac_digits: i64 = 0;
    var seen_dot = false;
    var seen_digit = false;
    var saturated = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c == '.') {
            if (seen_dot) return error.FailedConversion;
            seen_dot = true;
        } else if (std.ascii.isDigit(c)) {
            seen_digit = true;
            if (seen_dot) frac_digits += 1;
            // Past ~76 digits nothing is representable, so stop accumulating
            // rather than overflow; the range check rejects it either way.
            if (!saturated) {
                const next = @mulWithOverflow(mant, 10);
                if (next[1] != 0) {
                    saturated = true;
                } else {
                    const added = @addWithOverflow(next[0], @as(Wide, c - '0'));
                    if (added[1] != 0) saturated = true else mant = added[0];
                }
            }
        } else if (c == 'e' or c == 'E') {
            break;
        } else {
            return error.FailedConversion;
        }
    }
    if (!seen_digit) return error.FailedConversion;

    var exp10: i64 = 0;
    if (i < rest.len) {
        exp10 = std.fmt.parseInt(i64, rest[i + 1 ..], 10) catch
            return error.FailedConversion;
        if (exp10 > 1 << 20 or exp10 < -(1 << 20)) return error.FailedConversion;
    }
    if (saturated) return fail("numeric value out of range", error.NumericOutOfRange);
    if (negative) mant = -mant;
    if (mant == 0) return 0;

    // The value is mant * 10^(exp10 - frac_digits); wanted is that times
    // 10^scale, so the net shift is what decides multiply or round.
    const shift: i64 = exp10 - frac_digits + @as(i64, @intCast(scale));
    if (shift == 0) return mant;
    if (shift > 0) {
        if (shift > 80) return fail("numeric value out of range", error.NumericOutOfRange);
        var out = mant;
        var n: i64 = shift;
        while (n > 0) : (n -= 1) {
            const step = @mulWithOverflow(out, 10);
            if (step[1] != 0) {
                return fail("numeric value out of range", error.NumericOutOfRange);
            }
            out = step[0];
        }
        return out;
    }
    // Rounding away digits below the scale. Past the type's width the result
    // is zero rather than an error: 1e-400 is a representable NUMERIC.
    const down: i64 = -shift;
    if (down > 80) return 0;
    return divRound(mant, pow10Wide(@intCast(down)));
}

/// 10^e for exponents past the table, which only the string parser reaches.
fn pow10Wide(e: usize) Wide {
    if (e < pow_ten_table.len) return pow10(Wide, e);
    var out: Wide = pow10(Wide, pow_ten_table.len - 1);
    var n = e - (pow_ten_table.len - 1);
    while (n > 0) : (n -= 1) out *= 10;
    return out;
}

/// A finite f64's exact binary value, rounded once onto the scale grid.
///
/// Go's big.Rat.SetFloat64 is exact and the rounding happened afterwards, so
/// going through the f64's decimal spelling would round twice and lose the
/// tail that BIGNUMERIC's 38 digits can actually hold. `m * 2^e` is carried
/// exactly instead: 53 bits of mantissa times 10^38 needs ~180 bits, well
/// inside Wide, and only the shift can leave the range.
fn unscaledFromFloat(f: f64, scale: usize) ValueError!Wide {
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
    if (mant == 0) return 0;

    var v: Wide = @as(Wide, mant) * pow10(Wide, scale);
    if (exp2 >= 0) {
        // 2^exp2 past the width is unrepresentable for either kind.
        if (exp2 > 300) return fail("numeric value out of range", error.NumericOutOfRange);
        var n: i32 = exp2;
        while (n > 0) : (n -= 1) {
            const step = @mulWithOverflow(v, 2);
            if (step[1] != 0) {
                return fail("numeric value out of range", error.NumericOutOfRange);
            }
            v = step[0];
        }
    } else {
        const k: u32 = @intCast(-exp2);
        // Shifting further than the value has bits leaves zero, and the
        // rounding bit with it.
        if (k >= @bitSizeOf(Wide) - 8) return 0;
        const d: Wide = @as(Wide, 1) << @intCast(k);
        v = divRound(v, d);
    }
    return if (negative) -v else v;
}

/// Little-endian two's-complement scaled integer (googlesql's NUMERIC and
/// BIGNUMERIC proto encoding), restated at `to_scale`.
fn unscaledFromTwosComplement(
    bytes: []const u8,
    from_scale: usize,
    to_scale: usize,
) ValueError!Wide {
    if (bytes.len == 0) return 0;
    if (bytes.len > 64) return error.FailedConversion;
    var mag: std.meta.Int(.unsigned, @bitSizeOf(Wide)) = 0;
    var i: usize = bytes.len;
    while (i > 0) {
        i -= 1;
        mag = (mag << 8) | bytes[i];
    }
    // Sign-extend from the top bit of the highest byte.
    const width: u32 = @intCast(bytes.len * 8);
    var v: Wide = @bitCast(mag);
    if (width < @bitSizeOf(Wide) and (mag >> @intCast(width - 1)) & 1 == 1) {
        v -= @as(Wide, 1) << @intCast(width);
    }
    return rescale(v, from_scale, to_scale);
}

/// The decimal text of `unscaled` at `scale`, with exactly `prec` digits after
/// the point — Go big.Rat.FloatString's shape, which `Numeric.toText` then
/// trims. Rounds half away from zero when `prec` is the narrower.
fn renderDecimal(
    alloc: std.mem.Allocator,
    unscaled: i256,
    scale: usize,
    prec: usize,
) ValueError![]u8 {
    const at_prec: Wide = rescale(unscaled, scale, prec);
    const negative = at_prec < 0;
    const Mag = std.meta.Int(.unsigned, @bitSizeOf(Wide));
    const mag: Mag = @intCast(if (negative) -at_prec else at_prec);

    var digits_buf: [160]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{mag}) catch
        return error.OutOfMemory;

    // Split into integer and fractional halves, left-padding the fraction so a
    // value below 1 still renders its leading zeros.
    const int_len = if (digits.len > prec) digits.len - prec else 0;
    const int_part = digits[0..int_len];
    const frac_part = digits[int_len..];
    const frac_pad = prec - frac_part.len;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    // Go renders the sign even for a value that rounded to zero ("-0.000").
    if (negative) try out.append(alloc, '-');
    if (int_part.len == 0) try out.append(alloc, '0') else try out.appendSlice(alloc, int_part);
    if (prec > 0) {
        try out.append(alloc, '.');
        try out.appendNTimes(alloc, '0', frac_pad);
        try out.appendSlice(alloc, frac_part);
    }
    return out.toOwnedSlice(alloc);
}

/// The value as an f64.
///
/// Go big.Rat.Float64 divided the reduced numerator by the reduced
/// denominator; dividing the unscaled value by its scaling factor is the same
/// quotient. The halves are converted separately because LLVM has no
/// integer-to-double libcall wider than 128 bits — `sitofp i256 to double` is
/// an "unsupported library call operation" at codegen — and because 2^128 is
/// exact in f64, the split costs no accuracy the 53-bit mantissa would keep.
fn unscaledToFloat(unscaled: i256, scale: usize) f64 {
    const negative = unscaled < 0;
    const mag: u256 = @intCast(if (negative) -unscaled else unscaled);
    const hi: u128 = @truncate(mag >> 128);
    const lo: u128 = @truncate(mag);
    const two_128: f64 = 340282366920938463463374607431768211456.0; // 2^128
    const n_f: f64 = @as(f64, @floatFromInt(hi)) * two_128 + @as(f64, @floatFromInt(lo));
    const d_f: f64 = @floatFromInt(pow_ten_table[scale]);
    const q = n_f / d_f;
    return if (negative) -q else q;
}

/// 10^e for every exponent NUMERIC and BIGNUMERIC can ask for. BIGNUMERIC's
/// scale of 38 is the largest, and 10^38 < 2^128, so the whole table is a
/// native integer each entry can be set from directly.
const pow_ten_table: [39]u128 = blk: {
    var t: [39]u128 = undefined;
    t[0] = 1;
    for (1..39) |i| t[i] = t[i - 1] * 10;
    break :blk t;
};

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
    /// The value scaled by 10^9 (NUMERIC) or 10^38 (BIGNUMERIC) — googlesql's
    /// `FixedInt<64, 2>` and `FixedInt<64, 4>`, as one native integer.
    unscaled: i256,
    is_bignumeric: bool = false,

    pub fn scale(self: *const Numeric) usize {
        return scaleFor(self.is_bignumeric);
    }

    pub fn isZero(self: *const Numeric) bool {
        return self.unscaled == 0;
    }

    /// googlesql NumericValue::ToString: the decimal form with trailing zeros
    /// and a trailing '.' trimmed (shared by ToString/ToApiString/ToJSON).
    pub fn toText(self: *const Numeric, alloc: std.mem.Allocator) ValueError![]u8 {
        const s = try renderDecimal(alloc, self.unscaled, self.scale(), self.scale());
        var end = s.len;
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
        return s[0..end];
    }

    /// The decimal form with exactly `prec` digits after the point.
    pub fn toTextPrec(self: *const Numeric, alloc: std.mem.Allocator, prec: usize) ValueError![]u8 {
        return renderDecimal(alloc, self.unscaled, self.scale(), prec);
    }

    pub fn toFloat(self: *const Numeric) f64 {
        return unscaledToFloat(self.unscaled, self.scale());
    }

    /// googlesql NumericValue::To<int64_t>: rounded to a whole integer half
    /// away from zero, OUT_OF_RANGE past i64 (public/numeric_value.h:223).
    pub fn toInt64(self: *const Numeric) ValueError!i64 {
        const whole = divRound(self.unscaled, pow10(Wide, self.scale()));
        if (whole > std.math.maxInt(i64) or whole < std.math.minInt(i64)) {
            return fail("numeric value out of range for int64", error.NumericOutOfRange);
        }
        return @intCast(whole);
    }
};

pub const Value = union(enum) {
    null,
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
    /// RANGE<DATE|DATETIME|TIMESTAMP>. No go-zetasqlite counterpart — this
    /// kind is new here, so nothing about it is constrained by Go's shapes.
    range: Range,
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
            .null => return fail("add on null value", error.NullValue),
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
                .interval => |iv| return Value{
                    .datetime = addCalendar(days *% day_micros, iv, 1),
                },
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
            // "The range type doesn't support arithmetic operators." (data-types.md)
            .range => return fail("unsupported add operator for range value", error.UnsupportedOperation),
            // Result takes the wider operand's kind; see numericArith.
            .numeric => |n| return numericArith(
                alloc,
                n,
                v,
                .add,
            ),
            .array => return fail("add operation is unsupported for array", error.UnsupportedOperation),
            .struct_ => return fail("add operation is unsupported for struct", error.UnsupportedOperation),
            .safe => |p| return p.add(alloc, v) catch Value.null,
        }
    }

    pub fn sub(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .null => return fail("sub on null value", error.NullValue),
            .int => |i| return Value{ .int = i -% try v.toInt64() },
            .float => |f| return Value{ .float = f - try v.toFloat64() },
            .string => return fail("sub operation is unsupported for string", error.UnsupportedOperation),
            .bytes => return fail("sub operation is unsupported for bytes", error.UnsupportedOperation),
            .bool => return fail("sub operation is unsupported for bool", error.UnsupportedOperation),
            .date => |days| switch (v) {
                .int => |n| return Value{ .date = days -% n },
                // Go DateValue.Sub: *IntervalValue -> DATETIME (calendar sub);
                // any other time-shaped value -> INTERVAL of whole days.
                .interval => |iv| return Value{
                    .datetime = addCalendar(days *% day_micros, iv, -1),
                },
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
                else => return Value{
                    .interval = intervalFromDuration((m -% (try timeMicrosForCompare(v))) *% 1000),
                },
            },
            .datetime => |m| switch (v) {
                .interval => |iv| return Value{ .datetime = addCalendar(m, iv, -1) },
                else => return Value{
                    .interval = intervalFromDuration((m -% (try timeMicrosForCompare(v))) *% 1000),
                },
            },
            .time => return fail("sub operation is unsupported for time", error.UnsupportedOperation),
            .json => return fail("sub operation is unsupported for json", error.UnsupportedOperation),
            .interval => return fail("unsupported sub operator for interval value", error.UnsupportedOperation),
            .range => return fail("unsupported sub operator for range value", error.UnsupportedOperation),
            .numeric => |n| return numericArith(
                alloc,
                n,
                v,
                .sub,
            ),
            .array => return fail("sub operation is unsupported for array", error.UnsupportedOperation),
            .struct_ => return fail("sub operation is unsupported for struct", error.UnsupportedOperation),
            .safe => |p| return p.sub(alloc, v) catch Value.null,
        }
    }

    pub fn mul(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .null => return fail("mul on null value", error.NullValue),
            .int => |i| return Value{ .int = i *% try v.toInt64() },
            .float => |f| return Value{ .float = f * try v.toFloat64() },
            .numeric => |n| return numericArith(
                alloc,
                n,
                v,
                .mul,
            ),
            .safe => |p| return p.mul(alloc, v) catch Value.null,
            else => return fail("mul operation is unsupported for this type", error.UnsupportedOperation),
        }
    }

    pub fn div(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .null => return fail("div on null value", error.NullValue),
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
            .numeric => |n| return numericArith(
                alloc,
                n,
                v,
                .div,
            ),
            .safe => |p| return p.div(alloc, v) catch Value.null,
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
            .null => return fail("comparison on null value", error.NullValue),
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
            // RANGE *is* ordered — Type::SupportsOrdering excludes only
            // GEOGRAPHY and TOKENLIST — which is why it gets a real order here
            // and a memcomparable encoding in codec_sortable.zig, where JSON
            // and INTERVAL above get neither. The two must agree exactly; the
            // invariant test in that file is what holds them together.
            .range => |r| {
                const other = if (v == .safe) v.safe.* else v;
                if (other != .range)
                    return fail("failed to convert to range", error.FailedConversion);
                return applyOrder(op, rangeOrder(r, other.range));
            },
            // googlesql compares the scaled integers. Both sides are restated
            // at BIGNUMERIC's scale first, which is exact for either kind and
            // keeps the comparison kind-agnostic the way Rat.cmp was — and
            // needs no allocator at all, where the rational form spun up a
            // scratch arena per comparison just to hold temporaries.
            .numeric => |n| {
                const a: Wide = rescale(n.unscaled, n.scale(), bignumeric_scale);
                const b: Wide = v.toUnscaled(bignumeric_scale) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Magnitudes past what any numeric can hold still order
                    // against one: fall back to the float value, which is the
                    // only thing both sides can be stated in.
                    error.NumericOutOfRange => {
                        const af = n.toFloat();
                        const bf = try v.toFloat64();
                        return applyOrder(op, std.math.order(af, bf));
                    },
                    else => return fail("failed to convert to numeric", error.FailedConversion),
                };
                return applyOrder(op, std.math.order(a, b));
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
                if (st2.values.len != st.values.len) return false;
                // Field-by-position, like the array arm above. Names belong to
                // the type, not the value: BigQuery says
                // `STRUCT(1 AS a, 2 AS b) = STRUCT(1 AS b, 2 AS a)` is TRUE,
                // which by-name matching would call false. Go indexes the other
                // struct's map because its StructValue *is* a map; ours is an
                // ordered pair of slices and does not have to. By name, two
                // anonymous fields both key on "" and collide, which made
                // `STRUCT(3, 5) = STRUCT(3, 5)` false.
                for (st.values, st2.values) |lhs_field, rhs_field| {
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
            .null => return fail("toInt64 on null value", error.NullValue),
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
                // BigQuery names the offending input rather than the conversion:
                // CAST('apple' AS INT64) is "Bad int64 value: apple".
                return std.fmt.parseInt(i64, s, base) catch
                    failFmt("Bad int64 value: {s}", .{s}, error.FailedConversion);
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
            .range => return fail("unsupported int64 cast for range value", error.FailedConversion),
            // googlesql NumericValue::To<int64_t>: the value rounded to a
            // whole integer, half away from zero (public/numeric_value.h:223).
            // goccy returned the reduced fraction's numerator instead, so
            // NUMERIC '1.5' cast to 2 here where it used to give 3.
            .numeric => |n| return n.toInt64(),
            .array => return fail("failed to convert int64 from array", error.FailedConversion),
            .struct_ => return fail("failed to convert int64 from struct", error.FailedConversion),
            .safe => |p| return p.toInt64() catch 0,
        }
    }

    pub fn toFloat64(self: Value) ValueError!f64 {
        switch (self) {
            .null => return fail("toFloat64 on null value", error.NullValue),
            .int => |i| return @floatFromInt(i),
            .float => |f| return f,
            .bool => |b| return if (b) 1 else 0,
            .string => |s| {
                if (s.len == 0) return 0;
                // BigQuery says "double", not the FLOAT64 spelling of the target type.
                return std.fmt.parseFloat(f64, s) catch
                    failFmt("Bad double value: {s}", .{s}, error.FailedConversion);
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
            .range => return fail("unsupported float64 cast for range value", error.FailedConversion),
            .numeric => |n| return n.toFloat(),
            .array => return fail("failed to convert float64 from array", error.FailedConversion),
            .struct_ => return fail("failed to convert float64 from struct", error.FailedConversion),
            .safe => |p| return p.toFloat64() catch 0,
        }
    }

    pub fn toBool(self: Value) ValueError!bool {
        switch (self) {
            .null => return fail("toBool on null value", error.NullValue),
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
            .range => return fail("unsupported bool cast for range value", error.FailedConversion),
            // googlesql has no NUMERIC -> BOOL cast at all: cast.cc carries no
            // FCT(TYPE_NUMERIC, TYPE_BOOL), so the legal targets are the
            // integer and float widths, BIGNUMERIC, STRING and JSON. goccy
            // read the reduced numerator, which made NUMERIC '0.5' true.
            .numeric => return fail("failed to convert numeric value to bool type", error.FailedConversion),
            .array => return fail("failed to convert bool from array", error.FailedConversion),
            .struct_ => return fail("failed to convert bool from struct", error.FailedConversion),
            .safe => |p| return p.toBool() catch false,
        }
    }

    pub fn toString(self: Value, alloc: std.mem.Allocator) ValueError![]u8 {
        switch (self) {
            .null => return fail("toString on null value", error.NullValue),
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
            .range => |r| {
                var buf: [96]u8 = undefined;
                return alloc.dupe(u8, formatRange(&buf, r));
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
            .null => return fail("toArray on null value", error.NullValue),
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
            .null => return fail("toStruct on null value", error.NullValue),
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
            .null => return alloc.dupe(u8, "null"),
            .int => |i| return std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| {
                var buf: [32]u8 = undefined;
                return alloc.dupe(u8, formatFloatGo(&buf, f));
            },
            .bool => |b| return alloc.dupe(u8, if (b) "true" else "false"),
            .string => |s| return quoteJsonString(alloc, s),
            // BYTES is base64 in JSON, as it is everywhere else the value
            // crosses into text (driver.zig's TYPE_BYTES cell, Go's
            // BytesValue.ToApiString). BigQuery: TO_JSON_STRING(b"He") is
            // "SGU=". Emitting the raw bytes also produced invalid JSON for
            // anything that was not already UTF-8. Arrays and structs recurse
            // through here, so they follow.
            .bytes => |b| {
                const enc = std.base64.standard.Encoder;
                const buf = try alloc.alloc(u8, enc.calcSize(b.len));
                defer alloc.free(buf);
                return quoteJsonString(alloc, enc.encode(buf, b));
            },
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
            .range => |r| {
                var buf: [96]u8 = undefined;
                return quoteJsonString(alloc, formatRange(&buf, r));
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
    /// This value as an unscaled integer at `scale` — what googlesql stores,
    /// and the replacement for the old `toRat`. Non-representable text still
    /// yields zero rather than an error, which is Go's SetString behaviour the
    /// arithmetic paths depend on.
    pub fn toUnscaled(self: Value, scale: usize) ValueError!Wide {
        switch (self) {
            .null => return fail("toUnscaled on null value", error.NullValue),
            .int => |i| return @as(Wide, i) * pow10(Wide, scale),
            .float => |f| return unscaledFromFloat(f, scale),
            .bool => |b| return @as(Wide, @intFromBool(b)) * pow10(Wide, scale),
            .string => |str| return unscaledFromString(str, scale) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => @as(Wide, 0),
            },
            .bytes => |b| return unscaledFromString(b, scale) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => @as(Wide, 0),
            },
            // Go JsonValue.ToRat: strconv.ParseInt(string, 0, 64) then SetInt64.
            .json => |str| {
                const i = std.fmt.parseInt(i64, str, 0) catch
                    return fail("failed to convert json to numeric", error.FailedConversion);
                return @as(Wide, i) * pow10(Wide, scale);
            },
            .numeric => |n| return rescale(n.unscaled, n.scale(), scale),
            .safe => |ptr| return ptr.toUnscaled(scale) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => @as(Wide, 0),
            },
            else => return fail("unsupported numeric conversion for this kind", error.FailedConversion),
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
            .range => |r| {
                var buf: [96]u8 = undefined;
                return alloc.dupe(u8, formatRange(&buf, r));
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
            .null => return alloc.dupe(u8, "NULL"),
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
            .range => |r| {
                var buf: [96]u8 = undefined;
                return alloc.dupe(u8, formatRange(&buf, r));
            },
            // Go NumericValue.Format: toString() for every verb.
            .numeric => |n| return n.toText(alloc),
            .array => |a| {
                var out: std.ArrayList(u8) = .empty;
                try out.append(alloc, '[');
                for (a.values, 0..) |v, i| {
                    if (i > 0) try out.appendSlice(alloc, ", ");
                    if (v == .null) {
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
                    if (v == .null) {
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
        .null => return error.NullValue,
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
        // A range never coerces to a string for comparison: comparing it
        // against a non-range is an error in compareOp, so nothing gets
        // here needing the fallback this function exists to provide.
        .range => return error.Unimplemented,
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
        .null => return error.NullValue,
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
    // [0, 399]
    const yoe = @divTrunc(
        doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096),
        365,
    );
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

/// One bound of a range, in the form the reference docs print *inside* a
/// range — which is not the form the same kind uses on its own:
///
///   DATE       2022-12-01                     (same as formatDateDays)
///   DATETIME   2022-10-01 14:53:27            (space separator)
///   TIMESTAMP  2022-10-01 21:53:27.000000+00  (always six digits, UTC)
///
/// The TIMESTAMP row is the one that diverges from every existing renderer:
/// formatTimestampString drops the fraction entirely on a whole second
/// (writeFracMicros returns 0), and toApiString gives "sec.remainder". A
/// range prints all six digits regardless, so it needs its own writer.
fn writeRangeBound(buf: []u8, elem: Range.ElemKind, bound: ?i64) usize {
    const n = bound orelse {
        @memcpy(buf[0..9], "UNBOUNDED");
        return 9;
    };
    return switch (elem) {
        .date => formatDateDays(buf, n).len,
        .datetime => formatDatetimeString(buf, n).len,
        .timestamp => blk: {
            const d = decomposeMicros(n);
            var w = writeCivilPrefix(buf, d, ' ');
            w += (std.fmt.bufPrint(buf[w..], ".{d:0>6}+00", .{d.micro}) catch unreachable).len;
            break :blk w;
        },
    };
}

/// Total order over ranges: element kind, then lower bound, then upper.
///
/// UNBOUNDED is not a missing value here, it is an infinity, and which
/// infinity depends on the end it sits at — an absent lower bound is below
/// every date, an absent upper bound is above every date. That asymmetry is
/// the whole of the ordering, and `codec_sortable.zig` reproduces it in bytes
/// by giving the two ends different presence flags.
///
/// Element kind leads so two kinds never interleave. Comparing across kinds is
/// not something GoogleSQL permits, so the arm this feeds rejects it; the
/// tie-break exists for the byte encoding's benefit, which has no such gate.
pub fn rangeOrder(a: Range, b: Range) std.math.Order {
    const ka = @intFromEnum(a.elem);
    const kb = @intFromEnum(b.elem);
    if (ka != kb) return std.math.order(ka, kb);
    const s = orderBound(a.startBound(), b.startBound(), .low);
    if (s != .eq) return s;
    return orderBound(a.endBound(), b.endBound(), .high);
}

/// Which infinity an absent bound stands for.
const Unbounded = enum { low, high };

fn orderBound(a: ?i64, b: ?i64, absent: Unbounded) std.math.Order {
    if (a) |x| {
        const y = b orelse return if (absent == .low) .gt else .lt;
        return std.math.order(x, y);
    }
    if (b == null) return .eq;
    return if (absent == .low) .lt else .gt;
}

/// RangeValue.ToString: "[lower, upper)", either bound possibly UNBOUNDED.
/// The single source of truth for range text — every text-producing arm below
/// routes here, the way the date/time kinds route through their formatters.
/// `buf` needs >= 96 bytes.
pub fn formatRange(buf: []u8, r: Range) []const u8 {
    buf[0] = '[';
    var w: usize = 1;
    w += writeRangeBound(buf[w..], r.elem, r.startBound());
    @memcpy(buf[w .. w + 2], ", ");
    w += 2;
    w += writeRangeBound(buf[w..], r.elem, r.endBound());
    buf[w] = ')';
    return buf[0 .. w + 1];
}

/// Inverse of `formatRange`, for a range that has been through a result cell
/// and is on its way back in as a bound parameter.
///
/// The element kind is inferred from the shape of the first bounded end, since
/// the text does not name it: no space is a DATE, a trailing UTC offset is a
/// TIMESTAMP, and anything else is a DATETIME. `[UNBOUNDED, UNBOUNDED)` has no
/// shape to read and falls back to DATE — harmless, because it renders and
/// orders identically whichever kind it claims, and because `castParamValue`
/// re-stamps the kind from the declared column type immediately afterwards.
pub fn parseRangeValue(s: []const u8) ValueError!Range {
    if (s.len < 4 or s[0] != '[' or s[s.len - 1] != ')')
        return fail("failed to convert range from string", error.FailedConversion);
    const body = s[1 .. s.len - 1];
    // A single ", " separates the bounds; neither bound can contain one.
    const comma = std.mem.indexOf(u8, body, ", ") orelse
        return fail("failed to convert range from string", error.FailedConversion);
    const lo = body[0..comma];
    const hi = body[comma + 2 ..];

    const elem: Range.ElemKind = blk: {
        const shaped = if (!std.mem.eql(u8, lo, "UNBOUNDED"))
            lo
        else if (!std.mem.eql(u8, hi, "UNBOUNDED"))
            hi
        else
            break :blk .date;
        if (std.mem.indexOfScalar(u8, shaped, ' ') == null) break :blk .date;
        break :blk if (std.mem.indexOfAny(u8, shaped[11..], "+-Z") != null)
            .timestamp
        else
            .datetime;
    };

    return .{
        .elem = elem,
        .has_start = !std.mem.eql(u8, lo, "UNBOUNDED"),
        .has_end = !std.mem.eql(u8, hi, "UNBOUNDED"),
        .start = if (std.mem.eql(u8, lo, "UNBOUNDED")) 0 else try parseRangeBound(elem, lo),
        .end = if (std.mem.eql(u8, hi, "UNBOUNDED")) 0 else try parseRangeBound(elem, hi),
    };
}

fn parseRangeBound(elem: Range.ElemKind, s: []const u8) ValueError!i64 {
    return switch (elem) {
        .date => parseDateDays(s),
        .datetime => parseDatetimeMicros(s),
        .timestamp => parseTimestampMicros(s),
    };
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

/// googlesql's bounds on an interval's canonical fields. They constrain the
/// *result*, not the count written down: `INTERVAL 3000000000 SECOND` is legal
/// and canonicalizes to 833333:20:0, while `INTERVAL 10001 YEAR` is not, because
/// 120012 months is past the month bound. Verified against BigQuery, which
/// reports each by name — "Interval field days '3660001' is out of range
/// -3660000 to 3660000".
pub const interval_max_months: i64 = 120_000;
pub const interval_max_days: i64 = 3_660_000;
pub const interval_max_micros: i64 = 316_224_000_000_000_000;

/// As `intervalFromDuration`, but from a *microsecond* total.
///
/// Deliberately not a wrapper over it: the legal microsecond range above times
/// 1000 is ~3.2e20, well past i64, so a nanosecond total cannot carry every
/// interval a microsecond one can. Microseconds reach the whole range with room
/// to spare — the widest legal value is ~87.8M hours, comfortably an i32.
///
/// `micros` must already be within `interval_max_micros`; the caller checks it,
/// because it is the caller that knows how to report the failure.
pub fn intervalFromMicros(micros_in: i64) Interval {
    var micros = micros_in;
    var iv = Interval{};
    iv.hours = @intCast(@divTrunc(micros, 3600 * 1_000_000));
    micros -= @as(i64, iv.hours) * 3600 * 1_000_000;
    iv.minutes = @intCast(@divTrunc(micros, 60 * 1_000_000));
    micros -= @as(i64, iv.minutes) * 60 * 1_000_000;
    iv.seconds = @intCast(@divTrunc(micros, 1_000_000));
    micros -= @as(i64, iv.seconds) * 1_000_000;
    iv.sub_second_nanos = @intCast(micros * 1000);
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
        .null => return error.NullValue,
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
    const secs = days * 86400 + hour * 3600 + min * 60 + sec;
    return secs * second_micros + micro - offset_sec * second_micros;
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
fn intervalGetPart(
    part: IntervalPart,
    s_in: []const u8,
) ValueError!struct { val: i32, rest: []const u8 } {
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
    inline for ([_]IntervalPart{
        .years, .months, .days, .hours, .minutes, .seconds, .subsecs,
    }) |part| {
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

pub fn structValue(
    alloc: std.mem.Allocator,
    keys: []const []const u8,
    values: []const Value,
) !Value {
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
/// A Value cast to NUMERIC or BIGNUMERIC, rounded onto the kind's scale.
///
/// Replaces the old `numericValue(alloc, Rat, kind)`: with the value stored
/// scaled there is no rational to hand in, and the one rounding happens while
/// converting the operand rather than afterwards.
pub fn numericValue(alloc: std.mem.Allocator, v: Value, is_bignumeric: bool) ValueError!Value {
    return numericFromWide(alloc, try v.toUnscaled(scaleFor(is_bignumeric)), is_bignumeric);
}

fn numericFromWide(alloc: std.mem.Allocator, unscaled: Wide, is_bignumeric: bool) ValueError!Value {
    const checked = try checkRange(unscaled, is_bignumeric);
    const p = alloc.create(Numeric) catch return error.OutOfMemory;
    p.* = .{ .unscaled = checked, .is_bignumeric = is_bignumeric };
    return Value{ .numeric = p };
}

/// A numeric from an unscaled integer already at the kind's scale.
pub fn numericFromUnscaled(
    alloc: std.mem.Allocator,
    unscaled: i256,
    is_bignumeric: bool,
) ValueError!Value {
    return numericFromWide(alloc, unscaled, is_bignumeric);
}

/// A numeric from a little-endian two's-complement scaled integer.
pub fn numericFromTwosComplement(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    from_scale: usize,
    is_bignumeric: bool,
) ValueError!Value {
    const u = try unscaledFromTwosComplement(bytes, from_scale, scaleFor(is_bignumeric));
    return numericFromWide(alloc, u, is_bignumeric);
}

/// NUMERIC/BIGNUMERIC arithmetic, on the scaled integers googlesql stores.
///
/// Both operands are first restated at the result's scale, which is exact
/// because the result takes the wider of the two — BigQuery coerces
/// NUMERIC op BIGNUMERIC to BIGNUMERIC, and rounding to scale 9 would discard
/// real digits. From there add and subtract are integer add and subtract, and
/// only multiply and divide round, once, half away from zero.
///
/// This is where the rational representation used to earn its cost: a gcd on
/// every result, to reduce a fraction whose denominator was always a divisor
/// of 10^scale.
const NumericOp = enum { add, sub, mul, div };

fn numericArith(
    alloc: std.mem.Allocator,
    n: *const Numeric,
    v: Value,
    op: NumericOp,
) ValueError!Value {
    const is_big = n.is_bignumeric or isBigNumeric(v);
    const scale = scaleFor(is_big);
    const a: Wide = rescale(n.unscaled, n.scale(), scale);
    const b: Wide = try v.toUnscaled(scale);
    const factor = pow10(Wide, scale);

    const out: Wide = switch (op) {
        .add => a + b,
        .sub => a - b,
        // a*b carries scale twice over, so one factor comes back out. Two
        // BIGNUMERIC maxima reach ~3.3e153 against Wide's ~6.7e153.
        .mul => divRound(a * b, factor),
        .div => blk: {
            if (b == 0) return fail("division by zero", error.DivideByZero);
            break :blk divRound(a * factor, b);
        },
    };
    return numericFromWide(alloc, out, is_big);
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
pub fn numericFromString(
    alloc: std.mem.Allocator,
    s: []const u8,
    is_bignumeric: bool,
) ValueError!Value {
    return numericFromWide(
        alloc,
        try unscaledFromString(s, scaleFor(is_bignumeric)),
        is_bignumeric,
    );
}

/// Structural equality assertion for tests (floats compared bit-for-bit so
/// NaN payloads and -0.0 round-trip checks are exact).
pub fn expectValueEqual(expected: Value, actual: Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .null => {},
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
        .range => |r| try std.testing.expectEqual(r, actual.range),
        .numeric => |n| {
            var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer scratch.deinit();
            try std.testing.expectEqual(n.is_bignumeric, actual.numeric.is_bignumeric);
            try std.testing.expectEqual(n.unscaled, actual.numeric.unscaled);
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

test "struct comparisons match by position, not by field name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const s1 = try structValue(alloc, &.{ "a", "b" }, &.{ Value{ .int = 1 }, Value{ .string = "x" } });
    // Same values in the same order under different names. BigQuery calls this
    // equal; Go's map lookup would pair a-with-a and call it false.
    const renamed = try structValue(
        alloc,
        &.{ "b", "a" },
        &.{ Value{ .int = 1 }, Value{ .string = "x" } },
    );
    try std.testing.expect(try s1.eq(renamed));

    // Two anonymous fields share the key "", so a by-name lookup answered both
    // with the first field and reported STRUCT(3, 5) != STRUCT(3, 5).
    const anon1 = try structValue(alloc, &.{ "", "" }, &.{ Value{ .int = 3 }, Value{ .int = 5 } });
    const anon2 = try structValue(alloc, &.{ "", "" }, &.{ Value{ .int = 3 }, Value{ .int = 5 } });
    const anon3 = try structValue(alloc, &.{ "", "" }, &.{ Value{ .int = 5 }, Value{ .int = 3 } });
    try std.testing.expect(try anon1.eq(anon2));
    try std.testing.expect(!try anon1.eq(anon3)); // position carries the meaning

    const differing = try structValue(
        alloc,
        &.{ "a", "b" },
        &.{ Value{ .int = 2 }, Value{ .string = "x" } },
    );
    try std.testing.expect(!try s1.eq(differing));

    const shorter = try structValue(alloc, &.{"a"}, &.{Value{ .int = 1 }});
    try std.testing.expect(!try s1.eq(shorter)); // length mismatch => false
}

test "safe value swallows errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const safe_int = try safeValue(alloc, Value{ .int = 10 });
    // SAFE.DIVIDE(10, 0) => NULL instead of an error.
    try expectValueEqual(Value.null, try safe_int.div(alloc, Value{ .int = 0 }));
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

    // `unscaled` is the scaled integer googlesql stores, so it pins the
    // representation and not just how the value renders.
    const cases = [_]struct { in: []const u8, unscaled: i256, dec9: []const u8 }{
        .{ .in = "123.45", .unscaled = 123450000000, .dec9 = "123.45" },
        .{ .in = "1.5", .unscaled = 1500000000, .dec9 = "1.5" },
        .{ .in = "-1.5", .unscaled = -1500000000, .dec9 = "-1.5" },
        .{ .in = "0", .unscaled = 0, .dec9 = "0" },
        .{ .in = "42", .unscaled = 42000000000, .dec9 = "42" },
        .{ .in = "12.4E17", .unscaled = 1240000000000000000000000000, .dec9 = "1240000000000000000" },
        .{ .in = "1.0123456789", .unscaled = 1012345679, .dec9 = "1.012345679" }, // rounds half away
        .{ .in = "-0.000000001", .unscaled = -1, .dec9 = "-0.000000001" },
        .{ .in = "3/2", .unscaled = 1500000000, .dec9 = "1.5" },
        .{ .in = "-3/2", .unscaled = -1500000000, .dec9 = "-1.5" },
        .{ .in = "4/2", .unscaled = 2000000000, .dec9 = "2" },
        .{ .in = "1e-10", .unscaled = 0, .dec9 = "0" }, // rounds to 0 at scale 9
    };
    for (cases) |c| {
        const v = try numericFromString(alloc, c.in, false);
        try std.testing.expectEqual(c.unscaled, v.numeric.unscaled);
        try std.testing.expectEqualStrings(c.dec9, try v.numeric.toText(alloc));
    }

    // BIGNUMERIC precision: 39 fractional digits round to 38.
    const nbv = try numericFromString(alloc, "1.123456789012345678901234567890123456789", true);
    const nb = nbv.numeric;
    try std.testing.expectEqualStrings(
        "1.12345678901234567890123456789012345679",
        try nb.toText(alloc),
    );
    // NUMERIC rendering of the same value rounds at 9 digits.
    const nn = Numeric{
        .unscaled = @intCast(rescale(nb.unscaled, bignumeric_scale, numeric_scale)),
        .is_bignumeric = false,
    };
    try std.testing.expectEqualStrings("1.123456789", try nn.toText(alloc));

    // -1e-10 is below NUMERIC's scale, so it *is* zero once stored and
    // renders "0". goccy kept the value exact until it rendered, so the sign
    // survived a round-to-zero there and it printed "-0"; googlesql has no
    // unrounded value to carry a sign on.
    const tinyv = try numericFromString(alloc, "-1e-10", false);
    try std.testing.expectEqual(@as(i256, 0), tinyv.numeric.unscaled);
    try std.testing.expectEqualStrings("0", try tinyv.numeric.toText(alloc));

    // Invalid literals fail like Go's SetString.
    try std.testing.expectError(error.FailedConversion, unscaledFromString("", 9));
    try std.testing.expectError(error.FailedConversion, unscaledFromString("abc", 9));
    try std.testing.expectError(error.FailedConversion, unscaledFromString("1.2.3", 9));
    try std.testing.expectError(error.FailedConversion, unscaledFromString("1/0", 9));
    try std.testing.expectError(error.FailedConversion, unscaledFromString("1e", 9));
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

    // googlesql NumericValue::To<int64_t> rounds the value half away from
    // zero, so 1.5 is 2. goccy returned the reduced numerator and gave 3.
    try std.testing.expectEqual(@as(i64, 2), try a.toInt64());
    try std.testing.expectEqual(
        @as(i64, -2),
        try (try numericFromString(alloc, "-1.5", false)).toInt64(),
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        try (try numericFromString(alloc, "1.4", false)).toInt64(),
    );
    try std.testing.expectEqual(@as(f64, 1.5), try a.toFloat64());
    // googlesql has no NUMERIC -> BOOL cast; goccy read the numerator, which
    // made 1 true, 0 false and 0.5 true.
    const one = try numericFromString(alloc, "1", false);
    try std.testing.expectError(error.FailedConversion, one.toBool());
    try std.testing.expectError(error.FailedConversion, zero.toBool());

    // BIGNUMERIC results keep their flag through arithmetic.
    const big1 = try numericFromString(alloc, "1.5", true);
    const big_sum = try big1.add(alloc, Value{ .int = 1 });
    try std.testing.expect(big_sum.numeric.is_bignumeric);
    try std.testing.expectEqualStrings("2.5", try big_sum.toString(alloc));
}

test "numericFromTwosComplement (proto byte layout)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The payload is the scaled integer, which is now also how it is stored —
    // so these assert the unscaled value straight through, where the rational
    // form had to be checked as a reduced fraction ("3/2" for 1.5).
    // NUMERIC '1.5': 1_500_000_000 LE minimal-length.
    const r1 = try numericFromTwosComplement(alloc, &.{ 0x00, 0x2f, 0x68, 0x59 }, 9, false);
    try std.testing.expectEqual(@as(i256, 1_500_000_000), r1.numeric.unscaled);
    try std.testing.expectEqualStrings("1.5", try r1.numeric.toText(alloc));
    // NUMERIC '-1.5'.
    const r2 = try numericFromTwosComplement(alloc, &.{ 0x00, 0xd1, 0x97, 0xa6 }, 9, false);
    try std.testing.expectEqual(@as(i256, -1_500_000_000), r2.numeric.unscaled);
    try std.testing.expectEqualStrings("-1.5", try r2.numeric.toText(alloc));
    // NUMERIC '0' (single zero byte) and empty payload.
    const r3 = try numericFromTwosComplement(alloc, &.{0x00}, 9, false);
    try std.testing.expect(r3.numeric.isZero());
    const r4 = try numericFromTwosComplement(alloc, &.{}, 9, false);
    try std.testing.expect(r4.numeric.isZero());
    // NUMERIC '-0.000000001' == -1 scaled (0xff sign-extended).
    const r5 = try numericFromTwosComplement(alloc, &.{0xff}, 9, false);
    try std.testing.expectEqual(@as(i256, -1), r5.numeric.unscaled);
    try std.testing.expectEqualStrings("-0.000000001", try r5.numeric.toText(alloc));
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
        const v = try numericFromString(alloc, tc.in, tc.big);
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

test "BYTES is base64 in JSON, at every nesting depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // BigQuery: TO_JSON_STRING(b"He") is "SGU=". Emitting the raw bytes made
    // TO_JSON_STRING(CODE_POINTS_TO_BYTES([72, 101])) read "He", and produced
    // invalid JSON outright for anything not already UTF-8.
    const he = Value{ .bytes = "He" };
    try std.testing.expectEqualStrings("\"SGU=\"", try he.toJson(alloc));

    // Arrays and structs recurse through the same arm.
    const arr = try arrayValue(alloc, &.{ he, Value{ .bytes = "Hi" } });
    try std.testing.expectEqualStrings("[\"SGU=\",\"SGk=\"]", try arr.toJson(alloc));
    const st = try structValue(alloc, &.{"x"}, &.{he});
    try std.testing.expectEqualStrings("{\"x\":\"SGU=\"}", try st.toJson(alloc));

    // Bytes that are not valid UTF-8 survive, where quoting them did not.
    const raw = Value{ .bytes = &[_]u8{ 0xff, 0x00, 0x80 } };
    try std.testing.expectEqualStrings("\"/wCA\"", try raw.toJson(alloc));
}

test "range renders each element kind the way the reference docs print it" {
    var buf: [96]u8 = undefined;

    // DATE: the plain civil date.
    const d = rangeValue(.date, daysFromCivil(2022, 12, 1), daysFromCivil(2022, 12, 31));
    try std.testing.expectEqualStrings("[2022-12-01, 2022-12-31)", formatRange(&buf, d.range));

    // DATETIME: space-separated, fraction trimmed when it is zero.
    const oct1 = daysFromCivil(2022, 10, 1) * day_micros;
    const hms = struct {
        fn f(h: i64, m: i64, s: i64) i64 {
            return h * hour_micros + m * minute_micros + s * second_micros;
        }
    }.f;
    const dt = rangeValue(.datetime, oct1 + hms(14, 53, 27), oct1 + hms(16, 0, 0));
    try std.testing.expectEqualStrings(
        "[2022-10-01 14:53:27, 2022-10-01 16:00:00)",
        formatRange(&buf, dt.range),
    );

    // TIMESTAMP: six fractional digits *always*, plus the UTC offset. This is
    // the one that diverges from every other renderer — formatTimestampString
    // drops ".000000" entirely, and toApiString gives "sec.remainder".
    const ts = rangeValue(.timestamp, oct1 + hms(21, 53, 27), oct1 + hms(23, 0, 0));
    try std.testing.expectEqualStrings(
        "[2022-10-01 21:53:27.000000+00, 2022-10-01 23:00:00.000000+00)",
        formatRange(&buf, ts.range),
    );

    // UNBOUNDED on either side, and on both.
    try std.testing.expectEqualStrings(
        "[UNBOUNDED, 2022-12-31)",
        formatRange(&buf, rangeValue(.date, null, daysFromCivil(2022, 12, 31)).range),
    );
    try std.testing.expectEqualStrings(
        "[2022-10-01, UNBOUNDED)",
        formatRange(&buf, rangeValue(.date, daysFromCivil(2022, 10, 1), null).range),
    );
    try std.testing.expectEqualStrings(
        "[UNBOUNDED, UNBOUNDED)",
        formatRange(&buf, rangeValue(.date, null, null).range),
    );
}

test "range text round trips, inferring the element kind from the bound shape" {
    var buf: [96]u8 = undefined;
    const cases = [_]Value{
        rangeValue(.date, daysFromCivil(2022, 1, 1), daysFromCivil(2023, 1, 1)),
        rangeValue(.date, null, daysFromCivil(2023, 1, 1)),
        rangeValue(.date, daysFromCivil(2022, 1, 1), null),
        rangeValue(.datetime, 5 * day_micros + 3 * hour_micros, 6 * day_micros),
        rangeValue(.timestamp, 5 * day_micros + 3 * hour_micros, 6 * day_micros),
    };
    for (cases) |v| {
        const text = formatRange(&buf, v.range);
        try std.testing.expectEqual(v.range, try parseRangeValue(text));
    }

    // `[UNBOUNDED, UNBOUNDED)` is the one shape with nothing to infer from, so
    // it reads back as DATE whatever it was written as. Harmless: it renders
    // and orders identically for every element kind, and castParamValue
    // re-stamps the kind from the declared column type.
    const both = rangeValue(.timestamp, null, null);
    const parsed = try parseRangeValue(formatRange(&buf, both.range));
    try std.testing.expectEqual(Range.ElemKind.date, parsed.elem);
    try std.testing.expect(parsed.startBound() == null and parsed.endBound() == null);
}

test "range ordering puts an unbounded start first and an unbounded end last" {
    // Ascending. Note where `[UNBOUNDED, UNBOUNDED)` lands: its start is -inf
    // so it precedes every bounded start, but among the unbounded-start ranges
    // its +inf end puts it *last*. Reading both bounds as "missing sorts
    // first" is the natural mistake and gets this pair backwards.
    const ascending = [_]Value{
        rangeValue(.date, null, 100),
        rangeValue(.date, null, 200),
        rangeValue(.date, null, null),
        rangeValue(.date, 100, 150),
        rangeValue(.date, 100, null),
        rangeValue(.date, 200, 250),
    };
    for (ascending, 0..) |a, i| {
        for (ascending, 0..) |b, j| {
            const want: std.math.Order = if (i < j) .lt else if (i > j) .gt else .eq;
            try std.testing.expectEqual(want, rangeOrder(a.range, b.range));
        }
    }
    // Ranges compare only against ranges; anything else is a conversion error.
    try std.testing.expectError(
        error.FailedConversion,
        ascending[0].eq(Value{ .date = 100 }),
    );
}
