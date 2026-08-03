//! Port of go-zetasqlite function_format.go: the BigQuery FORMAT(fmt, args...)
//! printf-style function. Supports the verb set the corpus exercises —
//! %d %i %o %x %X %f %F %e %E %g %G %s %t %T %% — with the '0', '+', ' ' and
//! "'" flags, fixed and *-from-arg width, and fixed/*-from-arg precision.

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = bind.value_mod;

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

const Flag = enum { none, minus, plus, space, sharp, zero, quote };

const Param = struct {
    flag: Flag = .none,
    width: ?i64 = null,
    width_from_arg: bool = false,
    precision: ?i64 = null,
    precision_from_arg: bool = false,
    specifier: u8 = 0,
};

/// Go bindFormat + FORMAT: NULL arg -> NULL; otherwise printf-parse.
pub fn format(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len == 0)
        return bind.fail("FORMAT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const fmt_str = try args[0].toString(alloc);
    const out = try parseFormat(alloc, fmt_str, args[1..]);
    return Value{ .string = out };
}

fn parseFormat(alloc: std.mem.Allocator, fmt: []const u8, args_in: []const Value) Error![]u8 {
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
        if (i >= fmt.len) return bind.fail("invalid format", .{}, error.UnsupportedOperation);
        var param = Param{};
        // flag
        switch (fmt[i]) {
            '-' => {
                param.flag = .minus;
                i += 1;
            },
            '+' => {
                param.flag = .plus;
                i += 1;
            },
            ' ' => {
                param.flag = .space;
                i += 1;
            },
            '#' => {
                param.flag = .sharp;
                i += 1;
            },
            '0' => {
                param.flag = .zero;
                i += 1;
            },
            '\'' => {
                param.flag = .quote;
                i += 1;
            },
            else => {},
        }
        // width
        if (i < fmt.len and fmt[i] == '*') {
            param.width_from_arg = true;
            i += 1;
        } else {
            const start = i;
            while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
            if (i > start) param.width = std.fmt.parseInt(i64, fmt[start..i], 10) catch
                return bind.fail("invalid format width", .{}, error.UnsupportedOperation);
        }
        // precision
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                param.precision_from_arg = true;
                i += 1;
            } else {
                const start = i;
                while (i < fmt.len and fmt[i] >= '0' and fmt[i] <= '9') i += 1;
                if (i > start) param.precision = std.fmt.parseInt(i64, fmt[start..i], 10) catch
                    return bind.fail("invalid format precision", .{}, error.UnsupportedOperation);
            }
        }
        if (i >= fmt.len) return bind.fail("invalid format", .{}, error.UnsupportedOperation);
        param.specifier = fmt[i];
        i += 1;

        if (!isKnownSpecifier(param.specifier))
            return bind.fail("unexpected format type %{c}", .{param.specifier}, error.UnsupportedOperation);

        const num = requiredArgNum(param);
        if (format_args.len < num)
            return bind.fail("not enough arguments for format", .{}, error.UnsupportedOperation);
        const call_args = format_args[0..num];
        const text = try renderSpecifier(alloc, param, call_args);
        try out.appendSlice(alloc, text);
        if (format_args.len > num) {
            format_args = format_args[num..];
        } else if (num != 0) {
            format_args = &.{};
        }
    }
    return out.toOwnedSlice(alloc);
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

fn renderSpecifier(alloc: std.mem.Allocator, p: Param, args: []const Value) Error![]u8 {
    switch (p.specifier) {
        '%' => return alloc.dupe(u8, "%"),
        'd', 'i', 'o', 'x', 'X' => return parseInteger(alloc, p, args),
        'f', 'F', 'e', 'E', 'g', 'G' => return parseFloat(alloc, p, args),
        's' => {
            try validateString(args[args.len - 1]);
            return alloc.dupe(u8, try args[args.len - 1].toString(alloc));
        },
        't', 'T' => return args[args.len - 1].format(p.specifier, alloc),
        else => unreachable,
    }
}

fn validateString(v: Value) Error!void {
    if (v != .string)
        return bind.fail("invalid argument type: string of characters format (%s) required string type", .{}, error.UnsupportedOperation);
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

/// FormatPrecision.format: default 6, '*' consumes an arg, <=0 -> -1.
fn resolvePrecision(p: Param, args: []const Value) Error!struct { prec: i64, rest: []const Value } {
    if (p.precision_from_arg) {
        if (args[0] != .int)
            return bind.fail("precision type required int64 value", .{}, error.UnsupportedOperation);
        const pr = try args[0].toInt64();
        return .{ .prec = if (pr <= 0) -1 else pr, .rest = args[1..] };
    }
    const pr = p.precision orelse return .{ .prec = 6, .rest = args };
    return .{ .prec = if (pr <= 0) -1 else pr, .rest = args };
}

fn parseInteger(alloc: std.mem.Allocator, p: Param, args_in: []const Value) Error![]u8 {
    const wr = try resolveWidth(p, args_in);
    const args = wr.rest;
    if (args[0] != .int)
        return bind.fail("invalid argument type: decimal integer format (%d or %i) required int64 type", .{}, error.UnsupportedOperation);
    const v = try args[0].toInt64();
    switch (p.specifier) {
        'o' => if (v < 0) return bind.fail("invalid argument type: octal format (%o) required positive value", .{}, error.UnsupportedOperation),
        'x', 'X' => if (v < 0) return bind.fail("invalid argument type: hexadecimal integer format (%x or %X) required positive value", .{}, error.UnsupportedOperation),
        else => {},
    }
    if (p.flag == .quote) {
        if (p.specifier != 'd' and p.specifier != 'i')
            return bind.fail("currently doesn't support ' flag for {c} specifier", .{p.specifier}, error.UnsupportedOperation);
        return withCommas(alloc, v);
    }
    if (p.flag == .minus)
        return bind.fail("currently doesn't support - flag for integer value", .{}, error.UnsupportedOperation);
    if (p.flag == .sharp)
        return bind.fail("currently doesn't support # flag for integer value", .{}, error.UnsupportedOperation);

    const base: u8 = switch (p.specifier) {
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    const upper = p.specifier == 'X';
    const width: usize = @intCast(wr.w);
    const body = try fmtIntBody(alloc, v, base, upper, width, p.flag == .zero);
    // '+'/' ' become a literal prefix (Go prepends to the format string).
    switch (p.flag) {
        .plus => if (v > 0) return std.fmt.allocPrint(alloc, "+{s}", .{body}),
        .space => return std.fmt.allocPrint(alloc, " {s}", .{body}),
        else => {},
    }
    return body;
}

fn fmtIntBody(
    alloc: std.mem.Allocator,
    v: i64,
    base: u8,
    upper: bool,
    width: usize,
    zero: bool,
) Error![]u8 {
    const neg = v < 0;
    const av: u64 = if (neg) @as(u64, @intCast(-(v + 1))) + 1 else @as(u64, @intCast(v));
    var digits_buf: [24]u8 = undefined;
    const digits = formatUint(&digits_buf, av, base, upper);
    const sign_len: usize = if (neg) 1 else 0;
    const total = sign_len + digits.len;
    var out: std.ArrayList(u8) = .empty;
    if (width > total) {
        const pad = width - total;
        if (zero) {
            if (neg) try out.append(alloc, '-');
            try out.appendNTimes(alloc, '0', pad);
            try out.appendSlice(alloc, digits);
        } else {
            try out.appendNTimes(alloc, ' ', pad);
            if (neg) try out.append(alloc, '-');
            try out.appendSlice(alloc, digits);
        }
    } else {
        if (neg) try out.append(alloc, '-');
        try out.appendSlice(alloc, digits);
    }
    return out.toOwnedSlice(alloc);
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

fn withCommas(alloc: std.mem.Allocator, v: i64) Error![]u8 {
    const neg = v < 0;
    const av: u64 = if (neg) @as(u64, @intCast(-(v + 1))) + 1 else @as(u64, @intCast(v));
    var digits_buf: [24]u8 = undefined;
    const digits = formatUint(&digits_buf, av, 10, false);
    var out: std.ArrayList(u8) = .empty;
    if (neg) try out.append(alloc, '-');
    const n = digits.len;
    for (digits, 0..) |c, idx| {
        if (idx > 0 and (n - idx) % 3 == 0) try out.append(alloc, ',');
        try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

fn parseFloat(alloc: std.mem.Allocator, p: Param, args_in: []const Value) Error![]u8 {
    const wr = try resolveWidth(p, args_in);
    const pr = try resolvePrecision(p, wr.rest);
    const args = pr.rest;
    if (args[0] != .float and args[0] != .int)
        return bind.fail("invalid argument type: decimal notation format (%f or %F) required float64 or numeric type", .{}, error.UnsupportedOperation);
    const v = try args[0].toFloat64();
    var body = try formatFloatVerb(alloc, v, p.specifier, pr.prec);
    const width: usize = @intCast(wr.w);
    if (width > body.len) {
        const pad = width - body.len;
        var out: std.ArrayList(u8) = .empty;
        try out.appendNTimes(alloc, if (p.flag == .zero) @as(u8, '0') else ' ', pad);
        try out.appendSlice(alloc, body);
        body = try out.toOwnedSlice(alloc);
    }
    switch (p.flag) {
        .plus => if (v > 0) return std.fmt.allocPrint(alloc, "+{s}", .{body}),
        .space => return std.fmt.allocPrint(alloc, " {s}", .{body}),
        .minus => return bind.fail("currently doesn't support - flag for float value", .{}, error.UnsupportedOperation),
        .sharp => return bind.fail("currently doesn't support # flag for float value", .{}, error.UnsupportedOperation),
        .quote => return bind.fail("currently doesn't support ' flag for float value", .{}, error.UnsupportedOperation),
        else => {},
    }
    return body;
}

/// strconv.FormatFloat(v, verb, precision, 64) for f/F/e/E/g/G.
fn formatFloatVerb(alloc: std.mem.Allocator, v: f64, specifier: u8, precision: i64) Error![]u8 {
    if (std.math.isNan(v)) return alloc.dupe(u8, "NaN");
    if (std.math.isInf(v)) return alloc.dupe(u8, if (v > 0) "+Inf" else "-Inf");
    var buf: [512]u8 = undefined;
    const prec: ?usize = if (precision < 0) null else @intCast(precision);
    switch (specifier) {
        'f', 'F' => {
            const s = std.fmt.float.render(&buf, v, .{ .mode = .decimal, .precision = prec }) catch
                return error.OutOfMemory;
            return alloc.dupe(u8, s);
        },
        'e', 'E' => {
            const s = std.fmt.float.render(
                &buf,
                v,
                .{ .mode = .scientific, .precision = prec },
            ) catch return error.OutOfMemory;
            return goScientific(alloc, s, specifier == 'E');
        },
        'g', 'G' => return formatG(alloc, v, specifier == 'G', precision),
        else => unreachable,
    }
}

/// strconv.FormatFloat(v, 'g'|'G', prec, 64): `prec` significant digits with
/// trailing zeros trimmed, rendered as %e when the decimal exponent falls
/// outside [-4, eprec) and as %f otherwise. `precision < 0` is Go's shortest
/// mode, which uses eprec = 6 for that decision.
fn formatG(alloc: std.mem.Allocator, v: f64, upper: bool, precision: i64) Error![]u8 {
    const neg = std.math.signbit(v);
    const av = @abs(v);

    // Significant digits and the decimal point position: av == 0.<digits> * 10^dp.
    var digits_buf: [512]u8 = undefined;
    var digits: []const u8 = "0";
    var dp: i64 = 1;
    if (av != 0) {
        var buf: [512]u8 = undefined;
        // Rounding to N significant digits is scientific notation with N-1
        // fractional digits; shortest mode asks for the round-trip form.
        const sci_prec: ?usize = if (precision < 0)
            null
        else
            @intCast(@max(precision, 1) - 1);
        const s = std.fmt.float.render(
            &buf,
            av,
            .{ .mode = .scientific, .precision = sci_prec },
        ) catch return error.OutOfMemory;
        const e_idx = std.mem.indexOfScalar(u8, s, 'e') orelse s.len;
        var n: usize = 0;
        for (s[0..e_idx]) |c| {
            if (c == '.') continue;
            digits_buf[n] = c;
            n += 1;
        }
        const exp: i64 = if (e_idx < s.len)
            std.fmt.parseInt(i64, s[e_idx + 1 ..], 10) catch 0
        else
            0;
        // decimal.Round trims trailing zeros before formatDigits sees them.
        while (n > 1 and digits_buf[n - 1] == '0') n -= 1;
        digits = digits_buf[0..n];
        dp = exp + 1;
    }

    const nd: i64 = @intCast(digits.len);
    var prec: i64 = undefined;
    var eprec: i64 = undefined;
    if (precision < 0) {
        prec = nd;
        eprec = 6;
    } else {
        prec = @max(precision, 1);
        eprec = prec;
        if (eprec > nd and nd >= dp) eprec = nd;
    }

    const exp = dp - 1;
    var out: std.ArrayList(u8) = .empty;
    if (neg) try out.append(alloc, '-');
    if (exp < -4 or exp >= eprec) {
        try fmtE(alloc, &out, digits, dp, @min(prec, nd) - 1, upper);
    } else {
        if (prec > dp) prec = nd;
        try fmtF(alloc, &out, digits, dp, @max(prec - dp, 0));
    }
    return out.toOwnedSlice(alloc);
}

/// strconv fmtE: d[.ddd]e±NN with `prec` fractional mantissa digits.
fn fmtE(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    digits: []const u8,
    dp: i64,
    prec: i64,
    upper: bool,
) Error!void {
    try out.append(alloc, digits[0]);
    if (prec > 0) {
        try out.append(alloc, '.');
        var i: i64 = 1;
        while (i <= prec) : (i += 1) {
            const idx: usize = @intCast(i);
            try out.append(alloc, if (idx < digits.len) digits[idx] else '0');
        }
    }
    try out.append(alloc, if (upper) 'E' else 'e');
    const exp: i64 = if (digits.len == 1 and digits[0] == '0') 0 else dp - 1;
    try out.append(alloc, if (exp < 0) @as(u8, '-') else @as(u8, '+'));
    try out.print(alloc, "{d:0>2}", .{@abs(exp)});
}

/// strconv fmtF: fixed notation with `prec` fractional digits.
fn fmtF(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    digits: []const u8,
    dp: i64,
    prec: i64,
) Error!void {
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

/// Reformats Zig scientific "d.ddde<exp>" into Go's "d.dddE±NN" (min 2 exp
/// digits, explicit sign, upper/lower E).
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
