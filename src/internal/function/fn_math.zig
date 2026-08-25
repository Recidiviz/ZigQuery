//! Port of the arithmetic/bit/math functions used by the foundation set
//! (Go: function.go ADD/SUB/MUL/OP_DIV/BIT_*, function_math.go ABS/ROUND/
//! SAFE_*). Handler bodies fold in the Go bind* wrappers (null handling,
//! argument-count checks).

const std = @import("std");
const bind = @import("bind.zig");

const value_mod = bind.value_mod;

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

// ---------------------------------------------------------------------
// add / subtract / multiply / divide (Go bindAdd/bindSub/bindMul/bindOpDiv)
// ---------------------------------------------------------------------

pub fn add(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    return args[0].add(alloc, args[1]);
}

pub fn sub(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    return args[0].sub(alloc, args[1]);
}

pub fn mul(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    return args[0].mul(alloc, args[1]);
}

/// Go IntValue.Div / FloatValue.Div carry the dividend in the error message;
/// value.zig's generic div does not, so the int/float paths are inlined here
/// to reproduce "zero divided error ( %d / 0 )" exactly.
pub fn opDiv(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .int => |i| {
            const v2 = try args[1].toInt64();
            if (v2 == 0) return bind.fail("zero divided error ( {d} / 0 )", .{i}, error.DivideByZero);
            return Value{ .int = @divTrunc(i, v2) };
        },
        .float => |f| {
            const v2 = try args[1].toFloat64();
            if (v2 == 0) return bind.fail("zero divided error ( {d:.6} / 0 )", .{f}, error.DivideByZero);
            return Value{ .float = f / v2 };
        },
        else => return args[0].div(alloc, args[1]),
    }
}

// ---------------------------------------------------------------------
// SAFE_* (function_math.go): all coerce through float64, div-by-zero -> NULL
// ---------------------------------------------------------------------

pub fn safeAdd(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = (try args[0].toFloat64()) + (try args[1].toFloat64()) };
}

pub fn safeSubtract(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = (try args[0].toFloat64()) - (try args[1].toFloat64()) };
}

pub fn safeMultiply(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = (try args[0].toFloat64()) * (try args[1].toFloat64()) };
}

pub fn safeDivide(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toFloat64();
    const y = try args[1].toFloat64();
    if (y == 0) return null_v;
    return Value{ .float = x / y };
}

pub fn safeNegate(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = -(try args[0].toFloat64()) };
}

// ---------------------------------------------------------------------
// Bit operations (function.go BIT_*). Go's << / >> semantics: shift counts
// >= 64 yield 0 / sign-fill; std.math.shl/shr match for non-negative counts.
// ---------------------------------------------------------------------

pub fn bitNot(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = ~(try args[0].toInt64()) };
}

pub fn bitLeftShift(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = std.math.shl(i64, try args[0].toInt64(), try args[1].toInt64()) };
}

pub fn bitRightShift(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = std.math.shr(i64, try args[0].toInt64(), try args[1].toInt64()) };
}

pub fn bitAnd(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = (try args[0].toInt64()) & (try args[1].toInt64()) };
}

pub fn bitOr(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = (try args[0].toInt64()) | (try args[1].toInt64()) };
}

pub fn bitXor(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = (try args[0].toInt64()) ^ (try args[1].toInt64()) };
}

// ---------------------------------------------------------------------
// abs / round (function_math.go ABS/ROUND; both return FLOAT64 like Go)
// ---------------------------------------------------------------------

pub fn abs(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = @abs(try args[0].toFloat64()) };
}

/// Go bindRound reads the precision *before* the null check, so
/// ROUND(x, NULL) errors rather than returning NULL — mirrored here.
pub fn round(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1 and args.len != 2)
        return bind.fail("ROUND: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    var precision: i32 = 0;
    if (args.len == 2) precision = @intCast(try args[1].toInt64());
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = gonumRound(try args[0].toFloat64(), precision) };
}

/// Go MOD: math.Mod over float64 operands (returns FLOAT64). Zero divisor errors.
pub fn mod(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toFloat64();
    const y = try args[1].toFloat64();
    if (y == 0) return bind.fail("MOD: zero divided", .{}, error.DivideByZero);
    return Value{ .float = @rem(x, y) };
}

/// gonum floats/scalar.Round: half away from zero at `prec` decimals.
fn gonumRound(x: f64, prec: i32) f64 {
    if (x == 0) return 0; // return +0 even for -0 input
    if (prec >= 0 and x == @trunc(x)) return x;
    const scale = std.math.pow(f64, 10, @floatFromInt(prec));
    const intermed = x * scale;
    if (std.math.isInf(intermed)) return x;
    const rounded = @round(intermed); // half away from zero, like Go math.Round
    if (rounded == 0) return 0;
    return rounded / scale;
}

// ---------------------------------------------------------------------
// sign / bit_count (Go function_math.go SIGN, function_bit.go BIT_COUNT)
// ---------------------------------------------------------------------

pub fn sign(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    const f = try args[0].toFloat64();
    if (std.math.signbit(f)) return Value{ .int = -1 };
    if (f == 0) return Value{ .int = 0 };
    return Value{ .int = 1 };
}

pub fn bitCount(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (bind.existsNull(args)) return null_v;
    switch (args[0]) {
        .bytes => |b| {
            var sum: i64 = 0;
            for (b) |byte| sum += @popCount(byte);
            return Value{ .int = sum };
        },
        else => {
            const v: u64 = @bitCast(try args[0].toInt64());
            return Value{ .int = @popCount(v) };
        },
    }
}

// ---------------------------------------------------------------------
// BIT_CAST_TO_{INT,UINT}{32,64} (bit_functions.md): reinterpret the bit
// pattern instead of the value it denotes.
//
// The 32-bit forms truncate to the low 32 bits and re-widen — signed for
// INT32, so 0xFFFFFFFF reads back as -1; zero-extended for UINT32, so it
// reads as 4294967295, which i64 holds comfortably.
//
// The 64-bit forms are the identity on the bits, and for both directions,
// because Value carries a single signed `int`. BIT_CAST_TO_UINT64 therefore
// returns a value whose bits are right but whose *rendering* is the signed
// reading: BIT_CAST_TO_UINT64(-1) shows as -1 rather than
// 18446744073709551615. That is the engine's standing UINT64 limit — there is
// no unsigned Value kind, and encoder.valueFromProto already refuses a UINT64
// literal past i64's max — not something bit-casting introduces. It is also
// invisible to a round trip, which is what the docs' own examples do:
// BIT_CAST_TO_INT64(BIT_CAST_TO_UINT64(x)) is x for every x.
// ---------------------------------------------------------------------

pub fn bitCastToInt32(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("BIT_CAST_TO_INT32", args);
    if (bind.existsNull(args)) return null_v;
    const bits: u64 = @bitCast(try args[0].toInt64());
    return Value{ .int = @as(i32, @bitCast(@as(u32, @truncate(bits)))) };
}

pub fn bitCastToUint32(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("BIT_CAST_TO_UINT32", args);
    if (bind.existsNull(args)) return null_v;
    const bits: u64 = @bitCast(try args[0].toInt64());
    return Value{ .int = @as(u32, @truncate(bits)) };
}

pub fn bitCastToInt64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("BIT_CAST_TO_INT64", args);
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = try args[0].toInt64() };
}

pub fn bitCastToUint64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("BIT_CAST_TO_UINT64", args);
    if (bind.existsNull(args)) return null_v;
    return Value{ .int = try args[0].toInt64() };
}

/// Go FLOOR: largest integral value not greater than x.
pub fn floor(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1)
        return bind.fail("FLOOR: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = @floor(try args[0].toFloat64()) };
}

/// Go CEIL / CEILING: smallest integral value not less than x.
pub fn ceil(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1)
        return bind.fail("CEIL: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = @ceil(try args[0].toFloat64()) };
}

/// Go TRUNC: truncate toward zero, optionally to `digits` decimal places.
///
/// Note this rounds toward zero rather than down, so it differs from FLOOR
/// for negatives: TRUNC(-1.5) is -1, FLOOR(-1.5) is -2.
pub fn trunc(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1 and args.len != 2)
        return bind.fail("TRUNC: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toFloat64();
    if (args.len == 1) return Value{ .float = @trunc(x) };

    const digits: i32 = @intCast(try args[1].toInt64());
    const scale = std.math.pow(f64, 10, @floatFromInt(digits));
    if (!std.math.isFinite(scale) or scale == 0) return Value{ .float = @trunc(x) };
    return Value{ .float = @trunc(x * scale) / scale };
}

/// Go DIV: integer division truncating toward zero. Errors on a zero divisor,
/// unlike IEEE_DIVIDE.
pub fn div(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("DIV: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toInt64();
    const y = try args[1].toInt64();
    if (y == 0) return bind.fail("DIV: zero divided", .{}, error.DivideByZero);
    // Guard the one case two's complement cannot represent.
    if (x == std.math.minInt(i64) and y == -1) {
        return bind.fail("DIV: overflow", .{}, error.UnsupportedOperation);
    }
    return Value{ .int = @divTrunc(x, y) };
}

/// Go IEEE_DIVIDE: float division that yields ±Inf or NaN instead of an
/// error, which is exactly how it differs from the `/` operator.
pub fn ieeeDivide(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("IEEE_DIVIDE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toFloat64();
    const y = try args[1].toFloat64();
    return Value{ .float = x / y };
}

// ---- remaining GoogleSQL math builtins ----
//
// BigQuery errors on a domain violation (SQRT of a negative, LN of zero)
// rather than returning NaN, so each of these checks its domain. The SAFE_
// variants registered alongside turn those errors into NULL.

fn oneArg(name: []const u8, args: []const Value) Error!void {
    if (args.len != 1)
        return bind.fail("{s}: invalid argument num {d}", .{ name, args.len }, error.UnsupportedOperation);
}

pub fn sqrt(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("SQRT", args);
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toFloat64();
    if (x < 0) return bind.fail("SQRT: argument must not be negative", .{}, error.UnsupportedOperation);
    return Value{ .float = @sqrt(x) };
}

pub fn cbrt(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("CBRT", args);
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = std.math.cbrt(try args[0].toFloat64()) };
}

pub fn pow(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("POW: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = std.math.pow(f64, try args[0].toFloat64(), try args[1].toFloat64()) };
}

pub fn exp(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("EXP", args);
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = @exp(try args[0].toFloat64()) };
}

pub fn ln(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("LN", args);
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toFloat64();
    if (x <= 0) return bind.fail("LN: argument must be positive", .{}, error.UnsupportedOperation);
    return Value{ .float = @log(x) };
}

pub fn log10(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("LOG10", args);
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toFloat64();
    if (x <= 0) return bind.fail("LOG10: argument must be positive", .{}, error.UnsupportedOperation);
    return Value{ .float = @log10(x) };
}

/// LOG(x) is the natural log; LOG(x, base) changes the base.
pub fn log(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len == 1) return ln(alloc, args);
    if (args.len != 2)
        return bind.fail("LOG: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const x = try args[0].toFloat64();
    const base = try args[1].toFloat64();
    if (x <= 0) return bind.fail("LOG: argument must be positive", .{}, error.UnsupportedOperation);
    if (base <= 0 or base == 1)
        return bind.fail("LOG: base must be positive and not 1", .{}, error.UnsupportedOperation);
    return Value{ .float = @log(x) / @log(base) };
}

pub fn isInf(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("IS_INF", args);
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = std.math.isInf(try args[0].toFloat64()) };
}

pub fn isNan(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    try oneArg("IS_NAN", args);
    if (bind.existsNull(args)) return null_v;
    return Value{ .bool = std.math.isNan(try args[0].toFloat64()) };
}

fn unaryTrig(comptime f: fn (f64) f64, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = f(try args[0].toFloat64()) };
}

pub fn cos(a: std.mem.Allocator, args: []const Value) Error!Value {
    _ = a;
    try oneArg("COS", args);
    return unaryTrig(struct {
        fn g(x: f64) f64 {
            return @cos(x);
        }
    }.g, args);
}
pub fn sin(a: std.mem.Allocator, args: []const Value) Error!Value {
    _ = a;
    try oneArg("SIN", args);
    return unaryTrig(struct {
        fn g(x: f64) f64 {
            return @sin(x);
        }
    }.g, args);
}
pub fn tan(a: std.mem.Allocator, args: []const Value) Error!Value {
    _ = a;
    try oneArg("TAN", args);
    return unaryTrig(struct {
        fn g(x: f64) f64 {
            return @tan(x);
        }
    }.g, args);
}
pub fn atan(a: std.mem.Allocator, args: []const Value) Error!Value {
    _ = a;
    try oneArg("ATAN", args);
    return unaryTrig(struct {
        fn g(x: f64) f64 {
            return std.math.atan(x);
        }
    }.g, args);
}

pub fn atan2(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("ATAN2: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .float = std.math.atan2(try args[0].toFloat64(), try args[1].toFloat64()) };
}

// ---------------------------------------------------------------------
// Inverse, hyperbolic and reciprocal trigonometry
// (googlesql/public/functions/math.h Acos/Acosh/Asin/Asinh/Atanh/Cosh/Sinh/
// Tanh/Csc/Sec/Cot/Csch/Sech/Coth).
//
// Upstream computes each with the plain libm call and then applies a single
// predicate, `internal::CheckFloatingPointError`: a non-finite result is an
// error only when the argument was finite. That one rule reproduces every row
// of the reference docs' per-function tables — ACOS(2) errors while
// ACOS(+inf) is NaN, COT(0) errors while COT(+inf) is NaN — so `checked`
// below is the whole domain contract rather than a dozen hand-written range
// tests, and it is the reason none of these need the `x < 0` style guard
// SQRT and LN carry above.
// ---------------------------------------------------------------------

/// What upstream does with a non-finite result: nothing, or one of its two
/// message forms (SetFloatingPointError / SetFloatingPointOverflow). COSH and
/// SINH report overflow; TANH, SEC and SECH cannot turn a finite argument
/// non-finite, so upstream skips the check for them entirely.
const Guard = enum { none, err, overflow };

fn checked(comptime name: []const u8, comptime guard: Guard, in: f64, out: f64) Error!Value {
    if (guard == .none or std.math.isFinite(out) or !std.math.isFinite(in))
        return Value{ .float = out };
    return bind.fail(
        "Floating point " ++ (if (guard == .overflow) "overflow" else "error") ++
            " in function: " ++ name ++ "({d})",
        .{in},
        error.UnsupportedOperation,
    );
}

/// A one-argument DOUBLE -> DOUBLE handler. `f` is left `anytype` because the
/// std.math entries are generic over the float width.
fn unary(comptime name: []const u8, comptime f: anytype, comptime guard: Guard) bind.Handler {
    return struct {
        fn h(alloc: std.mem.Allocator, args: []const Value) Error!Value {
            _ = alloc;
            try oneArg(name, args);
            if (bind.existsNull(args)) return null_v;
            const x = try args[0].toFloat64();
            return checked(name, guard, x, f(x));
        }
    }.h;
}

// The reciprocals are spelled the way math.h spells them — `1.0 / primitive`,
// letting the division produce the infinity that `checked` then rejects —
// rather than as a guard on the argument. COT(1e-300) has to overflow the same
// way COT(0) does, and only the result knows that.
fn cotOf(x: f64) f64 {
    return 1.0 / @tan(x);
}
fn cothOf(x: f64) f64 {
    return 1.0 / std.math.tanh(x);
}
fn cscOf(x: f64) f64 {
    return 1.0 / @sin(x);
}
fn cschOf(x: f64) f64 {
    return 1.0 / std.math.sinh(x);
}
fn secOf(x: f64) f64 {
    return 1.0 / @cos(x);
}
fn sechOf(x: f64) f64 {
    return 1.0 / std.math.cosh(x);
}

pub const acos = unary("ACOS", std.math.acos, .err);
pub const acosh = unary("ACOSH", std.math.acosh, .err);
pub const asin = unary("ASIN", std.math.asin, .err);
pub const asinh = unary("ASINH", std.math.asinh, .err);
pub const atanh = unary("ATANH", std.math.atanh, .err);
pub const cosh = unary("COSH", std.math.cosh, .overflow);
pub const sinh = unary("SINH", std.math.sinh, .overflow);
pub const tanh = unary("TANH", std.math.tanh, .none);
pub const cot = unary("COT", cotOf, .err);
pub const coth = unary("COTH", cothOf, .err);
pub const csc = unary("CSC", cscOf, .err);
pub const csch = unary("CSCH", cschOf, .err);
pub const sec = unary("SEC", secOf, .none);
pub const sech = unary("SECH", sechOf, .none);

/// RAND()'s generator, one per thread so concurrent connections neither share
/// a stream nor need a lock. Seeded on first use from the same wall clock
/// fn_date.nowCiv falls back to, mixed with the state's own address: two
/// threads that start within the same nanosecond still diverge.
threadlocal var rand_state: ?std.Random.DefaultPrng = null;

fn randomGenerator() std.Random {
    if (rand_state == null) {
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.REALTIME, &ts);
        const seed = (@as(u64, @bitCast(@as(i64, ts.sec))) *% 1_000_000_000 +%
            @as(u64, @bitCast(@as(i64, ts.nsec)))) ^ @intFromPtr(&rand_state);
        rand_state = std.Random.DefaultPrng.init(seed);
    }
    return rand_state.?.random();
}

/// RAND(): a DOUBLE in [0, 1). `std.Random.float` is already half-open, so the
/// range is the generator's rather than something this rounds into place.
///
/// The bind table marks this `deterministic = false`; without that SQLite
/// carries SQLITE_DETERMINISTIC and folds the call to one value for the whole
/// query, which is exactly what the spec case (`RAND() >= 0 AND RAND() < 1`)
/// would still pass under while being wrong.
pub fn rand(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 0)
        return bind.fail("RAND: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    return Value{ .float = randomGenerator().float(f64) };
}

/// Not reachable from GoogleSQL surface syntax — a constant-folded NaN Value needs a SQL token to
/// embed in generated text. SQLite has none: 1e400/-1e400 parse straight to +-Inf, but every
/// arithmetic operator and math function nulls out a non-finite result.
pub fn nanLiteral(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 0)
        return bind.fail("NAN_LITERAL: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    return Value{ .float = std.math.nan(f64) };
}

fn isNanValue(v: Value) bool {
    return v == .float and std.math.isNan(v.float);
}

/// RANGE_BUCKET(point, boundaries_array): the 0-based position of the point's
/// upper bound — equivalently, how many boundaries are <= point. Counting
/// rather than binary-searching is deliberate: the sortedness and
/// NULL/NaN-freeness of the array are themselves execution errors upstream,
/// so a full pass is owed regardless and doing both in one is the cheaper
/// version of the same work.
pub fn rangeBucket(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 2)
        return bind.fail("RANGE_BUCKET: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const point = args[0];
    // A NaN point is NULL, not an error — the opposite of a NaN inside the
    // array. In practice `existsNull` above has already caught it: SQLite
    // turns a NaN result into SQL NULL, so no NaN reaches a scalar argument.
    // The array is a different matter, since it crosses as one encoded blob
    // and the codec does carry NaN.
    if (isNanValue(point)) return null_v;

    const arr = try args[1].toArray();
    var count: i64 = 0;
    for (arr.values, 0..) |elem, i| {
        if (elem == .null or isNanValue(elem)) return bind.fail(
            "RANGE_BUCKET: boundaries_array must not contain NULL or NaN",
            .{},
            error.UnsupportedOperation,
        );
        if (i > 0 and try elem.lt(arr.values[i - 1])) return bind.fail(
            "RANGE_BUCKET: boundaries_array must be sorted in ascending order",
            .{},
            error.UnsupportedOperation,
        );
        if (try elem.lte(point)) count += 1;
    }
    return Value{ .int = count };
}

// ---------------------------------------------------------------------
// Vector distances (COSINE_DISTANCE / EUCLIDEAN_DISTANCE).
//
// Both accept either a dense ARRAY<DOUBLE>, where the array index is the
// dimension, or a sparse ARRAY<STRUCT<dimension, magnitude>>, where an absent
// dimension means a magnitude of zero. Both are computed from the same three
// sums, so the traversal that aligns the two representations is written once.
// ---------------------------------------------------------------------

const Sums = struct {
    dot: f64 = 0,
    /// Squared norms, kept separately because COSINE_DISTANCE has to tell a
    /// zero vector (an error) from a zero distance.
    a2: f64 = 0,
    b2: f64 = 0,
    /// Sum of squared differences. Accumulated directly rather than derived as
    /// `a2 + b2 - 2*dot`, which loses every significant digit when the two
    /// vectors are close — the case a distance function is most often asked
    /// about.
    diff2: f64 = 0,
};

/// A magnitude cell. NULL inside a vector is an error, distinct from a NULL
/// vector, which the callers turn into NULL before getting here.
fn magnitudeOf(v: Value, name: []const u8) Error!f64 {
    if (v == .null)
        return bind.fail("{s}: a magnitude in a vector must not be NULL", .{name}, error.UnsupportedOperation);
    return v.toFloat64();
}

/// True when the array carries dimension-magnitude pairs rather than bare
/// magnitudes. An empty array is dense: it is the zero vector, and nothing
/// about it needs the sparse path.
fn isSparse(arr: *const value_mod.ArrayValue) bool {
    return arr.values.len > 0 and arr.values[0] == .struct_;
}

fn sums(
    a: *const value_mod.ArrayValue,
    b: *const value_mod.ArrayValue,
    name: []const u8,
) Error!Sums {
    var s: Sums = .{};
    if (isSparse(a) != isSparse(b))
        return bind.fail("{s}: both vectors must use the same representation", .{name}, error.UnsupportedOperation);

    if (!isSparse(a)) {
        if (a.values.len != b.values.len) return bind.fail(
            "{s}: both vectors must share the same dimensions",
            .{name},
            error.UnsupportedOperation,
        );
        for (a.values, b.values) |av, bv| {
            const x = try magnitudeOf(av, name);
            const y = try magnitudeOf(bv, name);
            s.dot += x * y;
            s.a2 += x * x;
            s.b2 += y * y;
            s.diff2 += (x - y) * (x - y);
        }
        return s;
    }

    // Sparse: pair by dimension key. The lookup is a linear scan of the other
    // vector, so this is O(n*m) — sparse vectors are sparse by construction
    // (that is the point of the representation), and a map would cost an
    // allocation per call to save nothing at these sizes.
    for (a.values) |el| {
        const pair = try el.toStruct();
        if (pair.values.len != 2)
            return bind.fail("{s}: a sparse vector element must be (dimension, magnitude)", .{name}, error.UnsupportedOperation);
        const x = try magnitudeOf(pair.values[1], name);
        s.a2 += x * x;
        var y: f64 = 0;
        for (b.values) |other| {
            const op = try other.toStruct();
            if (op.values.len != 2) continue;
            if (try op.values[0].eq(pair.values[0])) {
                y = try magnitudeOf(op.values[1], name);
                break;
            }
        }
        s.dot += x * y;
        s.diff2 += (x - y) * (x - y);
    }
    // Dimensions present only in `b` contribute their whole magnitude to both
    // b's norm and the difference; they contribute nothing to the dot product.
    for (b.values) |el| {
        const pair = try el.toStruct();
        if (pair.values.len != 2)
            return bind.fail("{s}: a sparse vector element must be (dimension, magnitude)", .{name}, error.UnsupportedOperation);
        const y = try magnitudeOf(pair.values[1], name);
        s.b2 += y * y;
        var seen = false;
        for (a.values) |other| {
            const op = try other.toStruct();
            if (op.values.len != 2) continue;
            if (try op.values[0].eq(pair.values[0])) {
                seen = true;
                break;
            }
        }
        if (!seen) s.diff2 += y * y;
    }
    return s;
}

fn twoVectors(name: []const u8, args: []const Value) Error!?Sums {
    if (args.len != 2)
        return bind.fail("{s}: invalid argument num {d}", .{ name, args.len }, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null;
    return try sums(try args[0].toArray(), try args[1].toArray(), name);
}

/// COSINE_DISTANCE: 1 - cos(theta). A zero vector has no direction, so unlike
/// EUCLIDEAN_DISTANCE this one rejects it rather than answering.
pub fn cosineDistance(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    const s = try twoVectors("COSINE_DISTANCE", args) orelse return null_v;
    if (s.a2 == 0 or s.b2 == 0) return bind.fail(
        "COSINE_DISTANCE: a vector must not be a zero vector",
        .{},
        error.UnsupportedOperation,
    );
    return Value{ .float = 1.0 - s.dot / @sqrt(s.a2 * s.b2) };
}

pub fn euclideanDistance(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    const s = try twoVectors("EUCLIDEAN_DISTANCE", args) orelse return null_v;
    return Value{ .float = @sqrt(s.diff2) };
}
