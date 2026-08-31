//! Port of go-zetasqlite function_format.go: the BigQuery FORMAT(fmt, args...)
//! printf-style function, over the language at
//! string_functions.md#format_specifiers — the verbs %d %i %o %x %X %f %F %e %E
//! %g %G %s %t %T %%, the flags '-' '+' ' ' '#' '0' and "'", and fixed or
//! *-from-arg width and precision.

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = bind.value_mod;

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

/// Flags may appear in any order, and repeating one is not an error.
/// (string_functions.md#flags)
const Flags = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    sharp: bool = false,
    zero: bool = false,
    quote: bool = false,
};

const Param = struct {
    flags: Flags = .{},
    width: ?i64 = null,
    width_from_arg: bool = false,
    precision: ?i64 = null,
    precision_from_arg: bool = false,
    specifier: u8 = 0,
};

/// Go bindFormat + FORMAT. A NULL format string gives NULL; a NULL argument gives NULL
/// only where the specifier consuming it is neither %t nor %T.
/// (string_functions.md#null_format_specifiers)
pub fn format(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len == 0)
        return bind.fail("FORMAT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (args[0] == .null) return null_v;
    const fmt_str = try args[0].toString(alloc);
    const out = try parseFormat(alloc, fmt_str, args[1..]) orelse return null_v;
    return Value{ .string = out };
}

fn parseFormat(alloc: std.mem.Allocator, fmt: []const u8, args_in: []const Value) Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    var format_args = args_in;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try out.append(alloc, fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        var param = Param{};
        i = readFlags(&param, fmt, i);
        i = try readWidth(&param, fmt, i);
        i = try readPrecision(&param, fmt, i);
        if (i >= fmt.len) return bind.fail("invalid format", .{}, error.UnsupportedOperation);
        param.specifier = fmt[i];
        i += 1;

        if (!isKnownSpecifier(param.specifier))
            return bind.fail("unexpected format type %{c}", .{param.specifier}, error.UnsupportedOperation);

        const num = requiredArgNum(param);
        if (format_args.len < num)
            return bind.fail("not enough arguments for format", .{}, error.UnsupportedOperation);
        const text = try renderSpecifier(alloc, param, format_args[0..num]) orelse return null;
        try out.appendSlice(alloc, text);
        format_args = format_args[num..];
    }
    return try out.toOwnedSlice(alloc);
}

fn readFlags(p: *Param, fmt: []const u8, start: usize) usize {
    var i = start;
    while (i < fmt.len) : (i += 1) {
        switch (fmt[i]) {
            '-' => p.flags.minus = true,
            '+' => p.flags.plus = true,
            ' ' => p.flags.space = true,
            '#' => p.flags.sharp = true,
            '0' => p.flags.zero = true,
            '\'' => p.flags.quote = true,
            else => return i,
        }
    }
    return i;
}

fn readWidth(p: *Param, fmt: []const u8, start: usize) Error!usize {
    if (start < fmt.len and fmt[start] == '*') {
        p.width_from_arg = true;
        return start + 1;
    }
    var i = start;
    while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
    if (i > start) p.width = std.fmt.parseInt(i64, fmt[start..i], 10) catch
        return bind.fail("invalid format width", .{}, error.UnsupportedOperation);
    return i;
}

fn readPrecision(p: *Param, fmt: []const u8, start: usize) Error!usize {
    if (start >= fmt.len or fmt[start] != '.') return start;
    if (start + 1 < fmt.len and fmt[start + 1] == '*') {
        p.precision_from_arg = true;
        return start + 2;
    }
    var i = start + 1;
    while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
    // A bare '.' is precision zero, which is what an empty digit run means here.
    p.precision = if (i > start + 1)
        std.fmt.parseInt(i64, fmt[start + 1 .. i], 10) catch
            return bind.fail("invalid format precision", .{}, error.UnsupportedOperation)
    else
        0;
    return i;
}

fn isKnownSpecifier(c: u8) bool {
    return switch (c) {
        'd', 'i', 'o', 'x', 'X', 'f', 'F', 'e', 'E', 'g', 'G', 's', 't', 'T', '%' => true,
        else => false,
    };
}

fn requiredArgNum(p: Param) usize {
    if (p.specifier == '%') return 0;
    var n: usize = 1;
    if (p.width_from_arg) n += 1;
    if (p.precision_from_arg) n += 1;
    return n;
}

/// Null when a NULL argument makes the whole result NULL.
fn renderSpecifier(alloc: std.mem.Allocator, p: Param, args: []const Value) Error!?[]u8 {
    if (p.specifier == '%') return try alloc.dupe(u8, "%");
    // %t and %T spell a NULL value out; the width and precision arguments never do.
    const spells_null = p.specifier == 't' or p.specifier == 'T';
    const checked = args.len - @intFromBool(spells_null);
    for (args[0..checked]) |a| if (a == .null) return null;
    return switch (p.specifier) {
        'd', 'i', 'o', 'x', 'X' => try parseInteger(alloc, p, args),
        'f', 'F', 'e', 'E', 'g', 'G' => try parseFloat(alloc, p, args),
        else => try parseText(alloc, p, args),
    };
}

/// FormatWidth.format: resolves the width, consuming a leading arg for '*'.
fn resolveWidth(p: Param, args: []const Value) Error!struct { w: i64, rest: []const Value } {
    if (p.width_from_arg) {
        if (args[0] != .int)
            return bind.fail("width type required int64 value", .{}, error.UnsupportedOperation);
        const w = try args[0].toInt64();
        return .{ .w = if (w <= 0) 0 else w, .rest = args[1..] };
    }
    const w = p.width orelse 0;
    return .{ .w = if (w <= 0) 0 else w, .rest = args };
}

/// A resolved precision and the arguments left after any '*' consumed one.
const Precision = struct { prec: ?i64, rest: []const Value };

/// FormatPrecision.format: null when the format gives none, since the default differs by
/// verb — 6 for the float verbs, absent for the integer and string ones.
fn resolvePrecision(p: Param, args: []const Value) Error!Precision {
    if (p.precision_from_arg) {
        if (args[0] != .int)
            return bind.fail("precision type required int64 value", .{}, error.UnsupportedOperation);
        return .{ .prec = try args[0].toInt64(), .rest = args[1..] };
    }
    return .{ .prec = p.precision, .rest = args };
}

// ----------------------------------------------------------------------
// Integer verbs
// ----------------------------------------------------------------------

fn parseInteger(alloc: std.mem.Allocator, p: Param, args_in: []const Value) Error![]u8 {
    const wr = try resolveWidth(p, args_in);
    const pr = try resolvePrecision(p, wr.rest);
    const args = pr.rest;
    if (args[0] != .int)
        return bind.fail("invalid argument type: decimal integer format (%d or %i) required int64 type", .{}, error.UnsupportedOperation);
    const v = try args[0].toInt64();

    const neg = v < 0;
    const mag: u64 = if (neg) @as(u64, @intCast(-(v + 1))) + 1 else @as(u64, @intCast(v));
    const base: u8 = switch (p.specifier) {
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    var digits_buf: [24]u8 = undefined;
    var digits = formatUint(&digits_buf, mag, base, p.specifier == 'X');
    var prec_buf: [64]u8 = undefined;
    if (pr.prec) |prec| digits = applyIntPrecision(&prec_buf, digits, prec, mag == 0);

    const sign = signPrefix(p.flags, neg);
    const intro = basePrefix(p.specifier, p.flags.sharp, mag == 0);
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(alloc, sign);
    try body.appendSlice(alloc, intro);
    if (p.flags.quote) {
        try appendGrouped(alloc, &body, digits, Grouping.of(base));
    } else {
        try body.appendSlice(alloc, digits);
    }

    // A precision already says how many digits to write, and outranks the zero flag.
    var flags = p.flags;
    if (pr.prec != null) flags.zero = false;
    return padTo(alloc, try body.toOwnedSlice(alloc), .{
        .width = wr.w,
        .flags = flags,
        .prefix = sign.len + intro.len,
    });
}

/// Precision on an integer is a minimum digit count, zero-filled on the left. A precision
/// of zero writes nothing at all for a zero value. (string_functions.md#precision)
fn applyIntPrecision(buf: []u8, digits: []const u8, prec: i64, is_zero: bool) []const u8 {
    if (prec <= 0) return if (is_zero) buf[0..0] else digits;
    const want: usize = @intCast(prec);
    if (want <= digits.len or want > buf.len) return digits;
    const pad = want - digits.len;
    @memset(buf[0..pad], '0');
    @memcpy(buf[pad..want], digits);
    return buf[0..want];
}

/// '+' outranks the space flag, and neither reaches a value that already carries a '-'.
fn signPrefix(flags: Flags, neg: bool) []const u8 {
    if (neg) return "-";
    if (flags.plus) return "+";
    if (flags.space) return " ";
    return "";
}

/// '#' introduces the base for %o %x %X, and leaves a zero value alone.
fn basePrefix(specifier: u8, sharp: bool, is_zero: bool) []const u8 {
    if (!sharp or is_zero) return "";
    return switch (specifier) {
        'o' => "0",
        'x' => "0x",
        'X' => "0X",
        else => "",
    };
}

/// How the "'" flag breaks digits up: threes for decimal, fours for octal and hex, and a
/// colon for hex where the others take a comma.
const Grouping = struct {
    size: usize,
    sep: u8,

    fn of(base: u8) Grouping {
        return .{ .size = if (base == 10) 3 else 4, .sep = if (base == 16) ':' else ',' };
    }
};

fn appendGrouped(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    digits: []const u8,
    g: Grouping,
) Error!void {
    for (digits, 0..) |c, idx| {
        if (idx > 0 and (digits.len - idx) % g.size == 0) try out.append(alloc, g.sep);
        try out.append(alloc, c);
    }
}

fn formatUint(buf: []u8, v_in: u64, base: u8, upper: bool) []const u8 {
    const alphabet = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    if (v_in == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = v_in;
    var i: usize = buf.len;
    while (v > 0) {
        i -= 1;
        buf[i] = alphabet[@intCast(v % base)];
        v /= base;
    }
    return buf[i..];
}

// ----------------------------------------------------------------------
// Float verbs
// ----------------------------------------------------------------------

fn parseFloat(alloc: std.mem.Allocator, p: Param, args_in: []const Value) Error![]u8 {
    const wr = try resolveWidth(p, args_in);
    const pr = try resolvePrecision(p, wr.rest);
    const args = pr.rest;
    if (args[0] != .float and args[0] != .int)
        return bind.fail("invalid argument type: decimal notation format (%f or %F) required float64 or numeric type", .{}, error.UnsupportedOperation);
    const v = try args[0].toFloat64();
    const upper = p.specifier == 'F' or p.specifier == 'E' or p.specifier == 'G';
    // A NaN takes no sign at all, not even from the '+' flag.
    const sign = if (std.math.isNan(v)) "" else signPrefix(p.flags, std.math.signbit(v));

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(alloc, sign);
    var flags = p.flags;
    if (std.math.isNan(v) or std.math.isInf(v)) {
        // Neither zero padding nor grouping means anything for a non-finite value.
        try body.appendSlice(alloc, nonFinite(v, upper));
        flags.zero = false;
    } else {
        const prec = floatPrecision(p.specifier, pr.prec);
        var num = try formatFloatVerb(alloc, @abs(v), p, prec);
        if (p.flags.quote) num = try groupIntegerPart(alloc, num);
        try body.appendSlice(alloc, num);
    }
    return padTo(alloc, try body.toOwnedSlice(alloc), .{
        .width = wr.w,
        .flags = flags,
        .prefix = sign.len,
    });
}

/// `inf`, `-inf` and `nan`, cased to match the verb.
/// (string_functions.md#rules_format_specifiers)
fn nonFinite(v: f64, upper: bool) []const u8 {
    if (std.math.isNan(v)) return if (upper) "NAN" else "nan";
    return if (upper) "INF" else "inf";
}

/// Every float verb defaults to 6; %g and %G additionally read anything under 1 as 1.
/// (string_functions.md#precision)
fn floatPrecision(specifier: u8, given: ?i64) i64 {
    const pr = given orelse 6;
    if (specifier == 'g' or specifier == 'G') return @max(pr, 1);
    return @max(pr, 0);
}

/// strconv.FormatFloat(v, verb, precision, 64) for f/F/e/E/g/G, over a non-negative `v`.
fn formatFloatVerb(alloc: std.mem.Allocator, v: f64, p: Param, precision: i64) Error![]u8 {
    const specifier = p.specifier;
    const sharp = p.flags.sharp;
    var buf: [512]u8 = undefined;
    const prec: usize = @intCast(precision);
    const rendered = switch (specifier) {
        'f', 'F' => blk: {
            const s = std.fmt.float.render(&buf, v, .{ .mode = .decimal, .precision = prec }) catch
                return error.OutOfMemory;
            break :blk try alloc.dupe(u8, s);
        },
        'e', 'E' => blk: {
            const s = std.fmt.float.render(&buf, v, .{
                .mode = .scientific,
                .precision = prec,
            }) catch return error.OutOfMemory;
            break :blk try goScientific(alloc, s, specifier == 'E');
        },
        else => try formatG(alloc, v, .{
            .upper = specifier == 'G',
            .precision = precision,
            .keep_zeros = sharp,
        }),
    };
    if (!sharp) return rendered;
    return forceDecimalPoint(alloc, rendered);
}

/// '#' keeps the decimal point even with no digit after it. In scientific notation the
/// point belongs to the mantissa, so it goes in front of the exponent marker.
fn forceDecimalPoint(alloc: std.mem.Allocator, s: []u8) Error![]u8 {
    if (std.mem.indexOfScalar(u8, s, '.') != null) return s;
    const at = std.mem.indexOfAny(u8, s, "eE") orelse s.len;
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ s[0..at], s[at..] });
}

/// The "'" flag groups the integer part of a decimal rendering in threes; scientific
/// notation has no integer part to group.
fn groupIntegerPart(alloc: std.mem.Allocator, s: []u8) Error![]u8 {
    if (std.mem.indexOfAny(u8, s, "eE") != null) return s;
    const end = std.mem.indexOfScalar(u8, s, '.') orelse s.len;
    var out: std.ArrayList(u8) = .empty;
    try appendGrouped(alloc, &out, s[0..end], .{ .size = 3, .sep = ',' });
    try out.appendSlice(alloc, s[end..]);
    return out.toOwnedSlice(alloc);
}

/// What the %g renderer needs beyond the value itself.
const GOpts = struct { upper: bool, precision: i64, keep_zeros: bool };

/// A rounded value as significant digits plus the decimal point position.
const Decimal = struct { digits: []const u8, dp: i64 };

/// strconv.FormatFloat(v, 'g'|'G', prec, 64) over a non-negative `v`: `precision`
/// significant digits rendered as %e when the decimal exponent falls outside
/// [-4, eprec) and as %f otherwise. Trailing zeros are trimmed unless `keep_zeros`.
fn formatG(alloc: std.mem.Allocator, av: f64, o: GOpts) Error![]u8 {
    var digits_buf: [512]u8 = undefined;
    const d = try significand(&digits_buf, av, o);

    const nd: i64 = @intCast(d.digits.len);
    var prec: i64 = o.precision;
    var eprec: i64 = o.precision;
    if (eprec > nd and nd >= d.dp) eprec = nd;

    const exp = d.dp - 1;
    var out: std.ArrayList(u8) = .empty;
    if (exp < -4 or exp >= eprec) {
        try fmtE(alloc, &out, d, .{ .prec = @min(prec, nd) - 1, .upper = o.upper });
    } else {
        if (prec > d.dp) prec = nd;
        try fmtF(alloc, &out, d, @max(prec - d.dp, 0));
    }
    return out.toOwnedSlice(alloc);
}

/// The rounded significant digits and where the decimal point sits among them:
/// `av == 0.<digits> * 10^dp`. Rounding to N significant digits is scientific notation
/// with N-1 fractional digits.
fn significand(buf: []u8, av: f64, o: GOpts) Error!Decimal {
    if (av == 0) return .{ .digits = "0", .dp = 1 };
    var raw: [512]u8 = undefined;
    const s = std.fmt.float.render(&raw, av, .{
        .mode = .scientific,
        .precision = @intCast(o.precision - 1),
    }) catch return error.OutOfMemory;
    const e_idx = std.mem.indexOfScalar(u8, s, 'e') orelse s.len;
    var n: usize = 0;
    for (s[0..e_idx]) |c| {
        if (c == '.') continue;
        buf[n] = c;
        n += 1;
    }
    const exp: i64 = if (e_idx < s.len)
        std.fmt.parseInt(i64, s[e_idx + 1 ..], 10) catch 0
    else
        0;
    // decimal.Round trims trailing zeros before formatDigits sees them.
    if (!o.keep_zeros) {
        while (n > 1 and buf[n - 1] == '0') n -= 1;
    }
    return .{ .digits = buf[0..n], .dp = exp + 1 };
}

/// The mantissa width and letter case %e renders with.
const EOpts = struct { prec: i64, upper: bool };

/// strconv fmtE: d[.ddd]e±NN with `prec` fractional mantissa digits.
fn fmtE(alloc: std.mem.Allocator, out: *std.ArrayList(u8), d: Decimal, e: EOpts) Error!void {
    const digits = d.digits;
    try out.append(alloc, digits[0]);
    if (e.prec > 0) {
        try out.append(alloc, '.');
        var i: i64 = 1;
        while (i <= e.prec) : (i += 1) {
            const idx: usize = @intCast(i);
            try out.append(alloc, if (idx < digits.len) digits[idx] else '0');
        }
    }
    try out.append(alloc, if (e.upper) 'E' else 'e');
    const exp: i64 = if (digits.len == 1 and digits[0] == '0') 0 else d.dp - 1;
    try out.append(alloc, if (exp < 0) @as(u8, '-') else @as(u8, '+'));
    try out.print(alloc, "{d:0>2}", .{@abs(exp)});
}

/// strconv fmtF: fixed notation with `prec` fractional digits.
fn fmtF(alloc: std.mem.Allocator, out: *std.ArrayList(u8), d: Decimal, prec: i64) Error!void {
    const digits = d.digits;
    const dp = d.dp;
    if (dp > 0) {
        var i: i64 = 0;
        while (i < dp) : (i += 1) {
            const idx: usize = @intCast(i);
            try out.append(alloc, if (idx < digits.len) digits[idx] else '0');
        }
    } else {
        try out.append(alloc, '0');
    }
    if (prec > 0) {
        try out.append(alloc, '.');
        var i: i64 = 0;
        while (i < prec) : (i += 1) {
            const at = dp + i;
            const in_range = at >= 0 and at < @as(i64, @intCast(digits.len));
            try out.append(alloc, if (in_range) digits[@intCast(at)] else '0');
        }
    }
}

/// Reformats Zig scientific "d.ddde<exp>" into Go's "d.dddE±NN" (min 2 exp digits,
/// explicit sign, upper/lower E).
fn goScientific(alloc: std.mem.Allocator, s: []const u8, upper: bool) Error![]u8 {
    const e_idx = std.mem.indexOfScalar(u8, s, 'e') orelse std.mem.indexOfScalar(u8, s, 'E') orelse
        return alloc.dupe(u8, s);
    const mantissa = s[0..e_idx];
    const exp = std.fmt.parseInt(i32, s[e_idx + 1 ..], 10) catch 0;
    const e_char: u8 = if (upper) 'E' else 'e';
    const sign: u8 = if (exp < 0) '-' else '+';
    const ae: u32 = @abs(exp);
    return std.fmt.allocPrint(alloc, "{s}{c}{c}{d:0>2}", .{ mantissa, e_char, sign, ae });
}

// ----------------------------------------------------------------------
// String verbs, and the padding every verb ends with
// ----------------------------------------------------------------------

fn parseText(alloc: std.mem.Allocator, p: Param, args_in: []const Value) Error![]u8 {
    const wr = try resolveWidth(p, args_in);
    const pr = try resolvePrecision(p, wr.rest);
    const v = pr.rest[0];
    var body = if (p.specifier == 's') blk: {
        if (v != .string)
            return bind.fail("invalid argument type: string of characters format (%s) required string type", .{}, error.UnsupportedOperation);
        break :blk try alloc.dupe(u8, v.string);
    } else try v.format(p.specifier, alloc);
    // Precision truncates a string rather than padding it.
    if (pr.prec) |prec| {
        const keep: usize = if (prec <= 0) 0 else @intCast(prec);
        if (keep < body.len) body = body[0..keep];
    }
    // Zero padding is a numeric idea; a short string takes spaces either way.
    var flags = p.flags;
    flags.zero = false;
    return padTo(alloc, body, .{ .width = wr.w, .flags = flags });
}

/// Where padding goes: the target width, the flags that pick the fill character, and how
/// many leading bytes of the body must stay in front of it.
const Pad = struct { width: i64, flags: Flags, prefix: usize = 0 };

/// Pads `body` out to the width. '-' left-justifies and outranks '0'; zero padding lands
/// after the prefix, keeping a sign or a base introducer in front of the zeros.
fn padTo(alloc: std.mem.Allocator, body: []u8, pad: Pad) Error![]u8 {
    const flags = pad.flags;
    const prefix_len = pad.prefix;
    if (pad.width <= 0) return body;
    const w: usize = @intCast(pad.width);
    if (w <= body.len) return body;
    const n = w - body.len;
    var out: std.ArrayList(u8) = .empty;
    if (flags.minus) {
        try out.appendSlice(alloc, body);
        try out.appendNTimes(alloc, ' ', n);
    } else if (flags.zero) {
        try out.appendSlice(alloc, body[0..prefix_len]);
        try out.appendNTimes(alloc, '0', n);
        try out.appendSlice(alloc, body[prefix_len..]);
    } else {
        try out.appendNTimes(alloc, ' ', n);
        try out.appendSlice(alloc, body);
    }
    return out.toOwnedSlice(alloc);
}

// ---- tests ----
//
// Everything a query can reach is asserted against BigQuery in
// testdata/specs/zigquery/functions/string/format.zon. What is left here is what no query
// can execute: SQLite has no NaN, so a NaN argument arrives at the UDF as NULL and the
// `nan` spelling is unreachable from SQL.

const testing = std.testing;

test "FORMAT with no arguments at all is refused" {
    // The analyzer requires the format string, so only a direct call reaches this guard.
    bind.clearDiagnostics();
    try testing.expectError(error.UnsupportedOperation, format(testing.allocator, &.{}));
    try testing.expect(std.mem.indexOf(u8, bind.message.?, "invalid argument num 0") != null);
}

test "a NaN spells lowercase or uppercase to match the verb, and takes no sign" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nan = Value{ .float = std.math.nan(f64) };

    for ([_]struct { f: []const u8, want: []const u8 }{
        .{ .f = "%f", .want = "nan" },
        .{ .f = "%F", .want = "NAN" },
        .{ .f = "%e", .want = "nan" },
        .{ .f = "%E", .want = "NAN" },
        .{ .f = "%g", .want = "nan" },
        .{ .f = "%G", .want = "NAN" },
        .{ .f = "%+f", .want = "nan" },
        .{ .f = "[%8f]", .want = "[     nan]" },
        .{ .f = "[%-8f]", .want = "[nan     ]" },
    }) |c| {
        const got = try format(alloc, &.{ .{ .string = c.f }, nan });
        try testing.expectEqualStrings(c.want, got.string);
    }
}
