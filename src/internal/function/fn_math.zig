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
    const pow = std.math.pow(f64, 10, @floatFromInt(prec));
    const intermed = x * pow;
    if (std.math.isInf(intermed)) return x;
    const rounded = @round(intermed); // half away from zero, like Go math.Round
    if (rounded == 0) return 0;
    return rounded / pow;
}
