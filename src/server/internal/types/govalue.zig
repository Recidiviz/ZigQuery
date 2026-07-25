//! Go-compatible scalar rendering for REST responses.
//!
//! bigquery-emulator turns every cell value into a string with `fmt.Sprint`
//! (internal/contentdata/repository.go convertValueToCell), so the emulator's
//! observable output depends on Go's formatting rules — not Zig's. For
//! floats that is `strconv.FormatFloat(v, 'g', -1, 64)`, which differs from
//! Zig's `{d}` in three ways that clients actually see:
//!
//!     1e21   -> "1e+21"    not "1000000000000000000000"
//!     -0.0   -> "-0"       sign preserved
//!     1e-7   -> "1e-07"    exponent zero-padded to two digits
//!
//! Verified against the running Go emulator; see testdata/golden.json
//! ("floats").

const std = @import("std");

/// Go's `%v` for float64 == strconv.FormatFloat(v, 'g', -1, 64).
///
/// Shortest round-trip digits, then Go's 'g' rule: use scientific notation
/// when the decimal exponent is < -4 or >= 6, otherwise positional. (The 6 is
/// Go's `if shortest { eprec = 6 }` in strconv/ftoa.go.)
pub fn formatFloat(arena: std.mem.Allocator, v: f64) std.mem.Allocator.Error![]const u8 {
    if (std.math.isNan(v)) return "NaN";
    if (std.math.isPositiveInf(v)) return "+Inf";
    if (std.math.isNegativeInf(v)) return "-Inf";

    // Zig's scientific mode yields shortest digits as `[-]D[.DDD]eEXP`,
    // which is precisely the (digits, exponent) pair Go's rule needs.
    // 64 bytes is well above the longest shortest-form f64 in scientific
    // notation, and the exponent below is parsed from render()'s own
    // output, so neither can fail here.
    var buf: [64]u8 = undefined;
    const sci = std.fmt.float.render(&buf, v, .{ .mode = .scientific }) catch unreachable;

    const neg = sci[0] == '-';
    const unsigned = if (neg) sci[1..] else sci;
    const e = std.mem.indexOfScalar(u8, unsigned, 'e').?;
    const mantissa = unsigned[0..e];
    const exp = std.fmt.parseInt(i32, unsigned[e + 1 ..], 10) catch unreachable;

    // Digits without the decimal point.
    var digits: [32]u8 = undefined;
    var nd: usize = 0;
    for (mantissa) |ch| {
        if (ch == '.') continue;
        digits[nd] = ch;
        nd += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    if (neg) try out.append(arena, '-');

    if (exp < -4 or exp >= 6) {
        try out.append(arena, digits[0]);
        if (nd > 1) {
            try out.append(arena, '.');
            try out.appendSlice(arena, digits[1..nd]);
        }
        try out.append(arena, 'e');
        try out.append(arena, if (exp < 0) '-' else '+');
        const abs: u32 = @intCast(@abs(exp));
        // Go always emits at least two exponent digits.
        try out.print(arena, "{d:0>2}", .{abs});
    } else {
        // `dp` is the position of the decimal point within `digits`.
        const dp: i32 = exp + 1;
        if (dp <= 0) {
            try out.appendSlice(arena, "0.");
            try out.appendNTimes(arena, '0', @intCast(-dp));
            try out.appendSlice(arena, digits[0..nd]);
        } else if (@as(usize, @intCast(dp)) >= nd) {
            try out.appendSlice(arena, digits[0..nd]);
            try out.appendNTimes(arena, '0', @as(usize, @intCast(dp)) - nd);
        } else {
            const split: usize = @intCast(dp);
            try out.appendSlice(arena, digits[0..split]);
            try out.append(arena, '.');
            try out.appendSlice(arena, digits[split..nd]);
        }
    }

    return out.toOwnedSlice(arena);
}

/// Go's `%v` for bool.
pub fn formatBool(v: bool) []const u8 {
    return if (v) "true" else "false";
}

/// Go's `%v` for int64.
pub fn formatInt(arena: std.mem.Allocator, v: i64) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{v});
}

const testing = std.testing;

fn expectFloat(expected: []const u8, v: f64) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(expected, try formatFloat(arena_state.allocator(), v));
}

test "float formatting matches the Go emulator's captured output" {
    // testdata/golden.json, case "floats":
    //   SELECT 1.5, 1e21, -0.0, 1e-7
    try expectFloat("1.5", 1.5);
    try expectFloat("1e+21", 1e21);
    try expectFloat("-0", -0.0);
    try expectFloat("1e-07", 1e-7);
}

test "the scientific/positional switchover sits exactly where Go puts it" {
    // exp >= 6 -> scientific
    try expectFloat("123456", 123456.0);
    try expectFloat("1.234567e+06", 1234567.0);
    // exp < -4 -> scientific
    try expectFloat("0.0001", 0.0001);
    try expectFloat("1e-05", 0.00001);
}

test "integral and repeating values" {
    try expectFloat("100", 100.0);
    try expectFloat("0", 0.0);
    try expectFloat("2", 2.0);
    try expectFloat("-1.5", -1.5);
    try expectFloat("0.3333333333333333", 1.0 / 3.0);
}

test "non-finite values use Go's spellings" {
    try expectFloat("NaN", std.math.nan(f64));
    try expectFloat("+Inf", std.math.inf(f64));
    try expectFloat("-Inf", -std.math.inf(f64));
}

test "float output round-trips back to the same value" {
    // The formatting is shortest-round-trip; guard that we did not lose
    // precision while re-rendering.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vals = [_]f64{ 1.5, 1e21, 1e-7, 1.0 / 3.0, 123456.789, -2.5e-300, 9007199254740993.0 };
    for (vals) |v| {
        const s = try formatFloat(arena, v);
        try testing.expectEqual(v, try std.fmt.parseFloat(f64, s));
    }
}

test "bool and int match Go's %v" {
    try testing.expectEqualStrings("true", formatBool(true));
    try testing.expectEqualStrings("false", formatBool(false));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("-9223372036854775808", try formatInt(arena_state.allocator(), std.math.minInt(i64)));
}
