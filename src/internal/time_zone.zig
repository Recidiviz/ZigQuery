//! Time zone strings to offsets from UTC, shared by:
//! - the time zone argument of the date/time functions (function/time_util.zig)
//! - the zone written at the end of a timestamp string (value.zig)
//!
//! Fixed offsets parse here; named zones resolve through ICU (shim_ffi.zig)

const std = @import("std");
const shim_ffi = @import("../shim_ffi.zig");

pub const Error = error{InvalidTimeZone};

/// Offset (seconds east of UTC) for `zone` at the given civil micros.
/// The civil value is used as if it were the UTC instant
pub fn offsetSeconds(zone: []const u8, civ: i64) Error!i64 {
    if (zone.len == 0) return 0;
    if (std.mem.eql(u8, zone, "UTC") or std.mem.eql(u8, zone, "Z")) return 0;

    // GoogleSQL's MakeTimeZone takes a numeric offset bare or after "UTC". ICU knows
    // GMT+hh:mm but not UTC+hh:mm, so neither spelling may fall through to it.
    const offset = if (std.mem.startsWith(u8, zone, "UTC")) zone[3..] else zone;
    if (offset[0] == '+' or offset[0] == '-')
        return fixedOffsetSeconds(offset) orelse error.InvalidTimeZone;

    const millis = @divFloor(civ, 1000);
    return shim_ffi.timeZoneOffsetSeconds(zone, millis) catch return error.InvalidTimeZone;
}

/// Seconds east of UTC for the numeric offset form `(+|-)H[H][:M[M]]` (or `HHMM`)
/// Null if `offset` is not one, minutes reach 60, or the offset passes the +/-14:00 bound.
/// (timestamp_functions.md#timezone_definitions)
fn fixedOffsetSeconds(offset: []const u8) ?i64 {
    const rest = offset[1..];
    var h_text = rest;
    var m_text: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        h_text = rest[0..i];
        m_text = rest[i + 1 ..];
    } else if (rest.len > 2) {
        h_text = rest[0..2];
        m_text = rest[2..];
    }
    const h = offsetField(h_text) orelse return null;
    // A colon promises minutes: GoogleSQL rejects "+12:".
    const m = if (m_text) |text| offsetField(text) orelse return null else 0;
    if (m > 59) return null;
    const secs = h * 3600 + m * 60;
    if (secs > 14 * 3600) return null;
    return if (offset[0] == '-') -secs else secs;
}

/// One or two decimal digits as a number; null for anything else.
fn offsetField(text: []const u8) ?i64 {
    if (text.len == 0 or text.len > 2) return null;
    var n: i64 = 0;
    for (text) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        n = n * 10 + (ch - '0');
    }
    return n;
}

test "numeric offsets, bare or after UTC" {
    const cases = [_]struct { zone: []const u8, secs: i64 }{
        .{ .zone = "+09:00", .secs = 9 * 3600 },
        .{ .zone = "+0930", .secs = 9 * 3600 + 1800 },
        .{ .zone = "-7", .secs = -7 * 3600 },
        // The spelling timezones.test seeds its table with.
        .{ .zone = "UTC+1234", .secs = 12 * 3600 + 34 * 60 },
        .{ .zone = "UTC+12:34", .secs = 12 * 3600 + 34 * 60 },
        .{ .zone = "UTC-8", .secs = -8 * 3600 },
        .{ .zone = "UTC-08:00", .secs = -8 * 3600 },
        .{ .zone = "UTC+14", .secs = 14 * 3600 },
    };
    for (cases) |c| try std.testing.expectEqual(c.secs, try offsetSeconds(c.zone, 0));

    const invalid = [_][]const u8{
        "UTC+15", "UTC+09:60", "UTC+", "+12:", "UTC+12:", "+:30", "UTC+12345", "UTCX",
    };
    for (invalid) |zone| try std.testing.expectError(error.InvalidTimeZone, offsetSeconds(zone, 0));
}
