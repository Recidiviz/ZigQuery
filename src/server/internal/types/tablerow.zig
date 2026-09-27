//! The `{"f":[{"v":…}]}` shape a result row travels in.
//!
//! Two shapes are load-bearing for clients and are reproduced exactly: `"v": null` is emitted
//! rather than omitted, and every scalar is a string. FLOAT64 takes BigQuery's spelling
//! (formatFloat); TIMESTAMP is decimal Unix seconds (value.formatTimestampApi).

const std = @import("std");
const builtin = @import("builtin");
const zigquery = @import("zigquery");
const driver = zigquery.driver;

/// Named rather than inferred: writeValue and jsonStringify are mutually
/// recursive through `jw.write`, and these hooks only ever run under Stringify.
const Error = std.json.Stringify.Error;

pub const TableCell = struct {
    cell: driver.Cell,

    pub fn jsonStringify(self: TableCell, jw: anytype) Error!void {
        try jw.beginObject();
        try jw.objectField("v");
        try writeValue(self.cell, jw);
        try jw.endObject();
    }
};

pub const TableRow = struct {
    cells: []const driver.Cell,

    pub fn jsonStringify(self: TableRow, jw: anytype) Error!void {
        try jw.beginObject();
        try jw.objectField("f");
        try jw.beginArray();
        for (self.cells) |cell| try jw.write(TableCell{ .cell = cell });
        try jw.endArray();
        try jw.endObject();
    }
};

fn writeValue(cell: driver.Cell, jw: anytype) Error!void {
    switch (cell) {
        .null => try jw.write(null),
        .int => |v| {
            var buf: [int_buf_len]u8 = undefined;
            try jw.write(formatInt(&buf, v));
        },
        .float => |v| {
            var buf: [float_buf_len]u8 = undefined;
            try jw.write(formatFloat(&buf, v));
        },
        .bool => |v| try jw.write(formatBool(v)),
        // BYTES arrive already base64-encoded and NUMERIC as decimal text, both
        // as text from the driver — see driver.zig's Cell docs.
        .string,
        .bytes,
        .json,
        .date,
        .timestamp,
        .datetime,
        .time,
        .interval,
        .range,
        => |v| try jw.write(v),
        .array => |items| {
            try jw.beginArray();
            for (items) |item| try jw.write(TableCell{ .cell = item });
            try jw.endArray();
        },
        .struct_ => |fields| {
            try jw.beginObject();
            try jw.objectField("f");
            try jw.beginArray();
            for (fields) |f| try jw.write(TableCell{ .cell = f.value });
            try jw.endArray();
            try jw.endObject();
        },
    }
}

/// Room for any i64 in base ten, sign included.
pub const int_buf_len = 24;

pub fn formatInt(buf: *[int_buf_len]u8, v: i64) []const u8 {
    return buf[0..std.fmt.printInt(buf, v, 10, .lower, .{})];
}

pub fn formatBool(v: bool) []const u8 {
    return if (v) "true" else "false";
}

/// Room for seventeen significant digits, a sign, a decimal point and "E-324".
pub const float_buf_len = 32;

/// A FLOAT64 cell as BigQuery prints, which is Java's Double.toString: positional for
/// 1e-3 <= |v| < 1e7 and `d.dddE[-]n` otherwise, always with a digit after the point, using
/// the shortest digits that round-trip.
pub fn formatFloat(buf: *[float_buf_len]u8, v: f64) []const u8 {
    if (std.math.isNan(v)) return "NaN";
    if (std.math.isInf(v)) return if (v > 0) "Infinity" else "-Infinity";

    const d = Digits.of(v);
    var out: Out = .{ .buf = buf };
    if (d.negative) out.byte('-');
    if (d.exp < -3 or d.exp >= 7) writeScientific(&out, &d) else writePositional(&out, &d);
    return out.written();
}

/// Significant digits without trailing zeros, and the power of ten of the first.
const Digits = struct {
    buf: [20]u8,
    len: usize,
    exp: i32,
    negative: bool,

    fn of(v: f64) Digits {
        const float = std.fmt.float;
        const tables = if (builtin.mode == .small)
            &float.Backend64_TablesSmall
        else
            &float.Backend64_TablesFull;
        const bits: u64 = @bitCast(v);
        const d = float.binaryToDecimal(u64, bits, 52, 11, false, tables);
        var r: Digits = .{ .buf = undefined, .len = 0, .exp = 0, .negative = d.sign };
        r.len = std.fmt.printInt(&r.buf, d.mantissa, 10, .lower, .{});
        r.exp = d.exponent + @as(i32, @intCast(r.len)) - 1;
        while (r.len > 1 and r.buf[r.len - 1] == '0') r.len -= 1;

        // Java never settles for one digit: it takes the nearest two-digit decimal, which
        // differs from `d.0` only where the rounding interval is wide, among the subnormals.
        const fraction = bits & ((@as(u64, 1) << 52) - 1);
        if (r.len == 1 and (bits >> 52) & 0x7ff == 0 and fraction != 0) {
            const two = nearestTwoDigits(fraction, r.exp);
            r.buf[0] = '0' + two.digits / 10;
            r.buf[1] = '0' + two.digits % 10;
            r.len = if (two.digits % 10 == 0) 1 else 2;
            r.exp = two.exp;
        }
        return r;
    }

    fn slice(self: *const Digits) []const u8 {
        return self.buf[0..self.len];
    }
};

fn writeScientific(out: *Out, d: *const Digits) void {
    const digits = d.slice();
    out.byte(digits[0]);
    out.byte('.');
    if (digits.len > 1) out.str(digits[1..]) else out.byte('0');
    out.byte('E');
    if (d.exp < 0) out.byte('-');
    var exp_buf: [int_buf_len]u8 = undefined;
    out.str(formatInt(&exp_buf, @abs(d.exp)));
}

fn writePositional(out: *Out, d: *const Digits) void {
    const digits = d.slice();
    // The position of the decimal point within `digits`.
    const dp: i32 = d.exp + 1;
    if (dp <= 0) {
        out.str("0.");
        out.zeros(@intCast(-dp));
        out.str(digits);
    } else if (dp >= digits.len) {
        out.str(digits);
        out.zeros(@intCast(dp - @as(i32, @intCast(digits.len))));
        out.str(".0");
    } else {
        const split: usize = @intCast(dp);
        out.str(digits[0..split]);
        out.byte('.');
        out.str(digits[split..]);
    }
}

/// Wide enough for a subnormal's fraction times 10^325.
const Wide = u1280;

/// The two-digit decimal nearest the subnormal `fraction * 2^-1074`, as digits 10..99 and the
/// power of ten of the first. `exp` is that power for its one-digit shortest form, which can sit a
/// decade above the value itself.
fn nearestTwoDigits(fraction: u64, exp: i32) struct { digits: u8, exp: i32 } {
    const one: Wide = @as(Wide, 1) << 1074;
    const e = if (scaled(fraction, @intCast(-exp)) < one) exp - 1 else exp;
    // Round half up at the second digit.
    const n = (scaled(fraction, @intCast(1 - e)) + (one >> 1)) >> 1074;
    if (n == 100) return .{ .digits = 10, .exp = e + 1 };
    return .{ .digits = @intCast(n), .exp = e };
}

fn scaled(fraction: u64, power_of_ten: u32) Wide {
    var n: Wide = fraction;
    for (0..power_of_ten) |_| n *= 10;
    return n;
}

/// Appends into a buffer sized by formatFloat's type.
const Out = struct {
    buf: *[float_buf_len]u8,
    len: usize = 0,

    fn byte(self: *Out, b: u8) void {
        self.buf[self.len] = b;
        self.len += 1;
    }

    fn str(self: *Out, s: []const u8) void {
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn zeros(self: *Out, count: u32) void {
        for (0..count) |_| self.byte('0');
    }

    fn written(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};

const testing = std.testing;

fn expectRow(expected: []const u8, cells: []const driver.Cell) !void {
    const got = try std.json.Stringify.valueAlloc(
        testing.allocator,
        TableRow{ .cells = cells },
        .{},
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "a null cell emits v:null rather than omitting the key" {
    try expectRow(
        \\{"f":[{"v":null}]}
    , &.{.null});
}

test "every scalar is a string, in BigQuery's spelling" {
    try expectRow(
        \\{"f":[{"v":"1"},{"v":"1.0E21"},{"v":"-0.0"},{"v":"true"},{"v":"2024-01-02"}]}
    , &.{
        .{ .int = 1 },
        .{ .float = 1e21 },
        .{ .float = -0.0 },
        .{ .bool = true },
        .{ .date = "2024-01-02" },
    });
}

test "an array wraps each element in its own v" {
    var items = [_]driver.Cell{ .{ .int = 1 }, .{ .int = 2 } };
    try expectRow(
        \\{"f":[{"v":[{"v":"1"},{"v":"2"}]}]}
    , &.{.{ .array = &items }});
}

test "a struct nests another f array" {
    var fields = [_]driver.Cell.Field{
        .{ .name = "a", .value = .{ .int = 1 } },
        .{ .name = "b", .value = .{ .string = "x" } },
    };
    try expectRow(
        \\{"f":[{"v":{"f":[{"v":"1"},{"v":"x"}]}}]}
    , &.{.{ .struct_ = &fields }});
}

test "strings are escaped by the serializer" {
    try expectRow(
        \\{"f":[{"v":"a\"b"},{"v":"tab\there"}]}
    , &.{ .{ .string = "a\"b" }, .{ .string = "tab\there" } });
}

fn expectFloat(expected: []const u8, v: f64) !void {
    var buf: [float_buf_len]u8 = undefined;
    try testing.expectEqualStrings(expected, formatFloat(&buf, v));
}

test "floats match BigQuery's REST cells" {
    // jobs.query, recidiviz-bigquery-sandbox, 2026-09-26.
    try expectFloat("1.5", 1.5);
    try expectFloat("1.0", 1.0);
    try expectFloat("100.0", 100.0);
    try expectFloat("0.5", 0.5);
    try expectFloat("123.456", 123.456);
    try expectFloat("0.30000000000000004", 0.30000000000000004);
    try expectFloat("-0.0", -0.0);
    try expectFloat("1.0E21", 1e21);
    try expectFloat("1.0E-7", 1e-7);
    try expectFloat("-1.5E-10", -1.5e-10);
    try expectFloat("3.0E-5", 3e-5);
    try expectFloat("1.0E15", 1e15);
    try expectFloat("1.0E300", 1e300);
    try expectFloat("1.234567890125E11", 123456789012.5);
    try expectFloat("1.7976931348623157E308", 1.7976931348623157e308);
    try expectFloat("2.2250738585072014E-308", 2.2250738585072014e-308);
    try expectFloat("Infinity", std.math.inf(f64));
    try expectFloat("-Infinity", -std.math.inf(f64));
    try expectFloat("NaN", std.math.nan(f64));
}

test "positional between 1e-3 and 1e7, scientific outside" {
    // jobs.query, recidiviz-bigquery-sandbox, 2026-09-26.
    try expectFloat("0.001", 0.001);
    try expectFloat("9.9E-4", 0.00099);
    try expectFloat("1.0E-4", 0.0001);
    try expectFloat("123456.0", 123456.0);
    try expectFloat("1234567.0", 1234567.0);
    try expectFloat("9999999.0", 9999999.0);
    try expectFloat("9999999.5", 9999999.5);
    try expectFloat("1.0E7", 1e7);
    try expectFloat("1.2345678E7", 12345678.0);
}

test "subnormals with a one-digit shortest form take the nearest two digits" {
    // jobs.query, recidiviz-bigquery-sandbox, 2026-09-26.
    try expectFloat("4.9E-324", 5e-324);
    try expectFloat("9.9E-324", 1e-323);
    try expectFloat("1.5E-323", 1.5e-323);
    try expectFloat("2.0E-323", 2e-323);
    try expectFloat("2.5E-323", 2.5e-323);
    try expectFloat("4.4E-323", 4.4e-323);
    try expectFloat("9.9E-323", 1e-322);
    try expectFloat("9.6E-322", 9.6e-322);
    try expectFloat("1.0E-321", 1e-321);
    try expectFloat("1.0E-320", 1e-320);
    try expectFloat("1.0E-310", 1e-310);
}

test "zero is positional" {
    try expectFloat("0.0", 0.0);
}

test "bools are lowercase" {
    try testing.expectEqualStrings("true", formatBool(true));
    try testing.expectEqualStrings("false", formatBool(false));
}
