//! Port of the arithmetic/bit/math functions used by the foundation set
//! (Go: function.go ADD/SUB/MUL/OP_DIV/BIT_*, function_math.go ABS/ROUND/
//! SAFE_*). Handler bodies fold in the Go bind* wrappers (null handling,
//! argument-count checks).

const std = @import("std");
const bind = @import("bind.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

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
