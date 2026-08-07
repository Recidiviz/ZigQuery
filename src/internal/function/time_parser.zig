//! Port of go-zetasqlite internal/function_time_parser.go: the BigQuery
//! date/time format-element engine for FORMAT_* and PARSE_*. Works on the
//! civil-micros BrokenTime from time_util.zig. Error strings mirror Go's
//! exactly (corpus compares PARSE_* error messages byte-for-byte).

const std = @import("std");
const tu = @import("time_util.zig");
const value = @import("../value.zig");

pub const Error = value.ValueError;
const Civil = tu.Civil;

pub const FormatType = enum { date, datetime, time, timestamp };

/// Names the target type in "unavailable format by <type> type". The
/// `.timestamp` arm is unreachable and stays only because the switch must be
/// exhaustive: a TIMESTAMP satisfies every arm of `elementAvailable`, and the
/// one other caller guards on `typ != .timestamp`, so no input produces
/// "unavailable format by timestamp type".
fn typeName(t: FormatType) []const u8 {
    return switch (t) {
        .date => "date",
        .datetime => "datetime",
        .time => "time",
        .timestamp => "timestamp",
    };
}

const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

// ----------------------------------------------------------------------
// Error-message plumbing. time_parser builds dynamic messages in the caller's
// arena; the fn_* wrappers copy `message` into the bind error buffer.
// ----------------------------------------------------------------------

pub threadlocal var message: ?[]const u8 = null;

fn failFmt(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype, err: Error) Error {
    message = std.fmt.allocPrint(alloc, fmt, args) catch fmt;
    return err;
}

// ======================================================================
// FORMAT
// ======================================================================

pub fn formatTime(
    alloc: std.mem.Allocator,
    format: []const u8,
    bt: tu.BrokenTime,
    offset_sec: i64,
    typ: FormatType,
) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const c = bt.parts();
    var i: usize = 0;
    while (i < format.len) {
        const ch = format[i];
        if (ch != '%') {
            try out.append(alloc, ch);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= format.len) return failFmt(alloc, "invalid time format", .{}, error.InvalidDate);
        const spec = format[i];
        if (spec == 'E') {
            i += 1;
            if (i >= format.len) return failFmt(alloc, "invalid time format", .{}, error.InvalidDate);
            const adv = try formatCombination(alloc, &out, format[i..], bt, c, offset_sec);
            i += adv;
            continue;
        }
        try formatElement(alloc, &out, spec, bt, c, offset_sec, typ);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn appendFmt(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    try out.print(alloc, fmt, args);
}

/// %E<...> combination formatters (%Ez, %E<n>S, %E*S, %E4S, %E4Y).
fn formatCombination(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rest: []const u8,
    bt: tu.BrokenTime,
    c: Civil,
    offset_sec: i64,
) Error!usize {
    const f0 = rest[0];
    switch (f0) {
        'z' => {
            // timeZoneRFC3339Formatter: t.Format("-07:00").
            try appendOffset(alloc, out, offset_sec);
            return 1;
        },
        '1', '2', '3', '5', '6' => {
            if (rest.len > 1 and rest[1] == 'S') {
                const prec: usize = @intCast(f0 - '0');
                try appendSecondPrecision(alloc, out, c, prec);
                return 2;
            }
        },
        '4' => {
            if (rest.len > 1) {
                switch (rest[1]) {
                    'S' => {
                        try appendSecondPrecision(alloc, out, c, 4);
                        return 2;
                    },
                    'Y' => {
                        // timeYear4Formatter: t.Format("2006") (zero-padded 4).
                        try appendYear4(alloc, out, c.year);
                        return 2;
                    },
                    else => {},
                }
            }
        },
        '*' => {
            if (rest.len > 1 and rest[1] == 'S') {
                try appendSecondPrecision(alloc, out, c, 6);
                return 2;
            }
        },
        else => {},
    }
    _ = bt;
    return failFmt(alloc, "unexpected format type %{c}", .{f0}, error.InvalidDate);
}

fn appendYear4(alloc: std.mem.Allocator, out: *std.ArrayList(u8), year: i64) Error!void {
    if (year < 0) {
        try appendFmt(alloc, out, "-{d:0>4}", .{@as(u64, @intCast(-year))});
    } else {
        try appendFmt(alloc, out, "{d:0>4}", .{@as(u64, @intCast(year))});
    }
}

fn appendSecondPrecision(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    c: Civil,
    prec: usize,
) Error!void {
    // Go t.Format("05.<prec zeros>"): second, dot, `prec` fractional digits.
    try appendFmt(alloc, out, "{d:0>2}", .{@as(u64, @intCast(c.second))});
    try out.append(alloc, '.');
    // c.micro is microseconds; pad/truncate to `prec` digits (nanos scale).
    var frac: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&frac, "{d:0>6}", .{@as(u64, @intCast(c.micro))}) catch unreachable;
    // Extend to 9 (nanos) with zeros so precisions up to 9 are stable.
    frac[6] = '0';
    frac[7] = '0';
    frac[8] = '0';
    var k: usize = 0;
    while (k < prec) : (k += 1) {
        try out.append(alloc, if (k < 9) frac[k] else '0');
    }
}

fn appendOffset(alloc: std.mem.Allocator, out: *std.ArrayList(u8), offset_sec: i64) Error!void {
    const sign: u8 = if (offset_sec < 0) '-' else '+';
    const a: u64 = @abs(offset_sec);
    const h = @divTrunc(a, 3600);
    const m = @divTrunc(@rem(a, 3600), 60);
    try appendFmt(alloc, out, "{c}{d:0>2}:{d:0>2}", .{ sign, h, m });
}

fn formatElement(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    spec: u8,
    bt: tu.BrokenTime,
    c: Civil,
    offset_sec: i64,
    typ: FormatType,
) Error!void {
    _ = typ;
    switch (spec) {
        'A' => try out.appendSlice(alloc, day_names[@intCast(bt.weekday())]),
        'a' => try out.appendSlice(alloc, day_names[@intCast(bt.weekday())][0..3]),
        'B' => try out.appendSlice(alloc, month_names[@intCast(c.month - 1)]),
        'b', 'h' => try out.appendSlice(alloc, month_names[@intCast(c.month - 1)][0..3]),
        'C' => { // centuryFormatter: fmt.Sprint(t.Year())[:2]
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{c.year}) catch unreachable;
            try out.appendSlice(alloc, s[0..@min(2, s.len)]);
        },
        'c' => try appendAnsic(alloc, out, bt, c), // "Mon Jan 02 15:04:05 2006"
        'D', 'x' => try appendFmt(alloc, out, "{d:0>2}/{d:0>2}/{s}", .{ u(c.month), u(c.day), yearLast2(c.year) }),
        'd' => try appendFmt(alloc, out, "{d:0>2}", .{u(c.day)}),
        'e' => try appendFmt(alloc, out, "{d: >2}", .{u(c.day)}),
        'F' => try appendFmt(
            alloc,
            out,
            "{d:0>4}-{d:0>2}-{d:0>2}",
            .{ @as(u64, @intCast(@max(c.year, 0))), u(c.month), u(c.day) },
        ),
        'G', 'J' => try appendFmt(alloc, out, "{d}", .{bt.isoWeek().year}),
        'g' => try out.appendSlice(alloc, yearLast2(bt.isoWeek().year)),
        'H' => try appendFmt(alloc, out, "{d:0>2}", .{u(c.hour)}),
        // %I and %l are the same 12-hour value and differ only in padding, so
        // they share one expression. go-zetasqlite's hour12Formatter used
        // Hour() as-is for %I and Hour()%12 for %l, which answered 13 and " 0"
        // where format-elements.md documents 01 and "12"; midnight and noon
        // both map to 12, which is what the %12 form gets wrong.
        'I' => try appendFmt(alloc, out, "{d:0>2}", .{u(hour12(c.hour))}),
        'l' => try appendFmt(alloc, out, "{d: >2}", .{u(hour12(c.hour))}),
        'j' => try appendFmt(alloc, out, "{d:0>3}", .{u(bt.yearDay())}),
        'k' => { // space-preceding single digit 24h
            if (c.hour < 10) {
                try appendFmt(alloc, out, " {d}", .{c.hour});
            } else try appendFmt(alloc, out, "{d}", .{c.hour});
        },
        'M' => try appendFmt(alloc, out, "{d:0>2}", .{u(c.minute)}),
        'm' => try appendFmt(alloc, out, "{d:0>2}", .{u(c.month)}),
        'n' => try out.append(alloc, '\n'),
        'P' => try out.appendSlice(alloc, if (c.hour < 12) "am" else "pm"),
        'p' => try out.appendSlice(alloc, if (c.hour < 12) "AM" else "PM"),
        'Q' => try appendFmt(alloc, out, "{d}", .{bt.quarter()}),
        'R' => try appendFmt(alloc, out, "{d:0>2}:{d:0>2}", .{ u(c.hour), u(c.minute) }),
        'S' => try appendFmt(alloc, out, "{d:0>2}", .{u(c.second)}),
        's' => try appendFmt(alloc, out, "{d}", .{bt.unixSeconds()}),
        'T', 'X' => try appendFmt(alloc, out, "{d:0>2}:{d:0>2}:{d:0>2}", .{ u(c.hour), u(c.minute), u(c.second) }),
        't' => try out.append(alloc, '\t'),
        // Three different quantities that used to share one: %U counts weeks
        // from the year's first Sunday, %W from its first Monday, and %V is the
        // ISO week, which belongs to the ISO year and so disagrees with both
        // around New Year. 2023-01-01 is %U=01, %W=00, %V=52.
        'U' => try appendFmt(alloc, out, "{d:0>2}", .{u(bt.weekOfYear(.sunday))}),
        'W' => try appendFmt(alloc, out, "{d:0>2}", .{u(bt.weekOfYear(.monday))}),
        'V' => try appendFmt(alloc, out, "{d:0>2}", .{u(bt.isoWeek().week)}),
        // Weekdays, not week numbers.
        'u' => try appendFmt(alloc, out, "{d}", .{bt.isoWeekday()}),
        'w' => try appendFmt(alloc, out, "{d}", .{bt.weekday()}),
        'Y' => try appendFmt(alloc, out, "{d}", .{c.year}),
        'y' => try out.appendSlice(alloc, yearLast2(c.year)),
        'Z' => {}, // zone name: unavailable (UTC-only)
        'z' => try appendOffsetCompact(alloc, out, offset_sec),
        '%' => try out.append(alloc, '%'),
        else => return failFmt(alloc, "unexpected format type %{c}", .{spec}, error.InvalidDate),
    }
}

inline fn u(x: i64) u64 {
    return @intCast(x);
}

/// The 12-hour clock reading of a 24-hour hour: 1-12, with both 0 and 12
/// answering 12. `%I` zero-pads it and `%l` space-pads it; nothing else differs.
inline fn hour12(hour: i64) i64 {
    return @mod(hour + 11, 12) + 1;
}

/// `%z`: the UTC offset as `+HHMM` / `-HHMM`. Printing the raw second count is
/// what it used to do, and `+0900` is what format-elements.md documents. The
/// colon-separated `+09:00` form beside it is `%Ez`, which is RFC 3339.
fn appendOffsetCompact(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    offset_sec: i64,
) Error!void {
    const sign: u8 = if (offset_sec < 0) '-' else '+';
    const a: u64 = @abs(offset_sec);
    try appendFmt(alloc, out, "{c}{d:0>2}{d:0>2}", .{
        sign,
        @divTrunc(a, 3600),
        @divTrunc(@rem(a, 3600), 60),
    });
}

threadlocal var year2_buf: [4]u8 = undefined;
fn yearLast2(year: i64) []const u8 {
    const s = std.fmt.bufPrint(
        &year2_buf,
        "{d:0>4}",
        .{@as(u64, @intCast(@max(year, 0)))},
    ) catch unreachable;
    return s[s.len - 2 ..];
}

fn appendAnsic(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bt: tu.BrokenTime,
    c: Civil,
) Error!void {
    try appendFmt(alloc, out, "{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
        day_names[@intCast(bt.weekday())][0..3],
        month_names[@intCast(c.month - 1)][0..3],
        u(c.day),
        u(c.hour),
        u(c.minute),
        u(c.second),
        c.year,
    });
}

// ======================================================================
// PARSE
// ======================================================================

pub const ParseResult = struct {
    civ: i64, // wall-clock civil micros
    offset_sec: i64 = 0, // set by %z / %Ez
};

const State = struct {
    alloc: std.mem.Allocator,
    civ: i64,
    offset_sec: i64 = 0,
    saw_ampm: bool = false,
    ampm_pm: bool = false,
    saw_24h: bool = false,
    saw_12h: bool = false,

    fn parts(self: *State) Civil {
        return tu.decompose(self.civ);
    }
    fn set(self: *State, c: Civil) void {
        self.civ = tu.compose(c.year, c.month, c.day, c.hour, c.minute, c.second, c.micro);
    }
};

pub fn parseTimeFormat(
    alloc: std.mem.Allocator,
    format: []const u8,
    target: []const u8,
    typ: FormatType,
) Error!ParseResult {
    var st = State{ .alloc = alloc, .civ = 0 }; // seed 1970-01-01 UTC
    var ti: usize = 0; // target index
    var fi: usize = 0; // format index
    while (fi < format.len) {
        const c = format[fi];
        if (c == '%') {
            fi += 1;
            if (fi >= format.len) return failFmt(alloc, "invalid time format", .{}, error.InvalidDate);
            const spec = format[fi];
            if (spec == 'E') {
                fi += 1;
                if (fi >= format.len) return failFmt(alloc, "invalid time format", .{}, error.InvalidDate);
                const r = try parseCombination(&st, format[fi..], target[ti..], typ);
                ti += r.progress;
                fi += r.format_adv;
                continue;
            }
            if (!elementAvailable(spec, typ)) {
                return failFmt(alloc, "unavailable format by {s} type", .{typeName(typ)}, error.InvalidDate);
            }
            if (ti > target.len) return failFmt(alloc, "invalid target text", .{}, error.InvalidDate);
            const progress = parseElement(&st, spec, target[ti..]) catch |e| {
                // Non-E path wraps the element error with the outer context.
                return failFmt(alloc, "error parsing [{s}] with format [{s}]: {s}", .{
                    target, format, message orelse "parse error",
                }, e);
            };
            ti += progress;
            fi += 1;
        } else if (c == ' ') {
            fi += 1;
            while (ti < target.len and target[ti] == ' ') ti += 1;
        } else {
            fi += 1;
            ti += 1;
        }
    }
    if (ti != target.len) {
        return failFmt(alloc, "error parsing [{s}] with format [{s}]: found unparsed text [{s}]", .{
            target, format, target[ti..],
        }, error.InvalidDate);
    }
    // Post-process am/pm (unless a 24-hour token was present).
    if (st.saw_ampm and st.saw_12h and !st.saw_24h) {
        var cv = st.parts();
        var hour = cv.hour;
        if (!st.ampm_pm) {
            hour = @mod(hour, 12);
        } else if (hour < 12) {
            hour += 12;
        }
        cv.hour = hour;
        st.set(cv);
    }
    return .{ .civ = st.civ, .offset_sec = st.offset_sec };
}

fn elementAvailable(spec: u8, typ: FormatType) bool {
    // Availability mirrors formatPatternMap; only the common cases matter for
    // corpus, but the timestamp-only zone tokens must be rejected elsewhere.
    return switch (spec) {
        'H', 'I', 'M', 'S', 's', 'k', 'l', 'P', 'p', 'R', 'T', 'X' => typ != .date,
        'A', 'a', 'B', 'b', 'h', 'C', 'D', 'd', 'e', 'F' => typ != .time,
        'G', 'g', 'J', 'j', 'm', 'Q', 'U', 'W', 'V' => typ != .time,
        'u', 'w', 'x', 'Y', 'y' => typ != .time,
        'c' => typ == .datetime or typ == .timestamp,
        'Z', 'z' => typ == .timestamp,
        'n', 't', '%' => true,
        else => true,
    };
}

const StepResult = struct { progress: usize, format_adv: usize };

fn parseCombination(
    st: *State,
    rest: []const u8,
    target: []const u8,
    typ: FormatType,
) Error!StepResult {
    const f0 = rest[0];
    switch (f0) {
        'z' => {
            if (typ != .timestamp) return failFmt(
                st.alloc,
                "unavailable format by {s} type",
                .{typeName(typ)},
                error.InvalidDate,
            );
            const p = try parseRFC3339Zone(st, target);
            return .{ .progress = p, .format_adv = 1 };
        },
        '1', '2', '3', '5', '6' => {
            if (rest.len > 1 and rest[1] == 'S') {
                const prec: usize = @intCast(f0 - '0');
                const p = try parseSecondPrecision(st, prec, target);
                return .{ .progress = p, .format_adv = 2 };
            }
        },
        '4' => {
            if (rest.len > 1) switch (rest[1]) {
                'S' => {
                    const p = try parseSecondPrecision(st, 4, target);
                    return .{ .progress = p, .format_adv = 2 };
                },
                'Y' => {
                    const p = try parseYear(st, target);
                    return .{ .progress = p, .format_adv = 2 };
                },
                else => {},
            };
        },
        '*' => {
            if (rest.len > 1 and rest[1] == 'S') {
                const p = try parseSecondPrecision(st, 6, target);
                return .{ .progress = p, .format_adv = 2 };
            }
        },
        else => {},
    }
    return failFmt(st.alloc, "unexpected format type %{c}", .{f0}, error.InvalidDate);
}

/// Go parseDigitRespectingOptionalPlaces: parse up to len(maxNumber) digits,
/// stopping at the first non-digit; validate the [min,max] range.
fn parseDigits(
    st: *State,
    text: []const u8,
    min: i64,
    max: i64,
) Error!struct { progress: usize, value: i64 } {
    if (text.len == 0) return failFmt(st.alloc, "empty text", .{}, error.InvalidDate);
    var places: usize = 0;
    {
        var mm = max;
        while (mm != 0) : (mm = @divTrunc(mm, 10)) places += 1;
        if (places == 0) places = 1;
    }
    const steps = @min(places, text.len);
    var count: usize = 0;
    while (count < steps) : (count += 1) {
        if (!std.ascii.isDigit(text[count])) {
            if (count == 0) return failFmt(st.alloc, "leading character is not a digit", .{}, error.InvalidDate);
            break;
        }
    }
    var result: i64 = 0;
    for (text[0..count]) |ch| result = result * 10 + (ch - '0');
    if (result > max) return failFmt(st.alloc, "part [{d}] is greater than maximum value [{d}]", .{ result, max }, error.InvalidDate);
    if (result < min) return failFmt(st.alloc, "part [{d}] is less than minimum value [{d}]", .{ result, min }, error.InvalidDate);
    return .{ .progress = count, .value = result };
}

fn parseElement(st: *State, spec: u8, target: []const u8) Error!usize {
    return switch (spec) {
        'A' => parseWeekdayName(st, target, false),
        'a' => parseWeekdayName(st, target, true),
        'B' => parseMonthName(st, target, false),
        'b', 'h' => parseMonthName(st, target, true),
        'C' => parseCentury(st, target),
        'c' => parseAnsic(st, target),
        'D', 'x' => parseMonthDayYear(st, target),
        'd' => parseDay(st, target),
        'e' => parseLeadingSpaceThen(st, target, parseDay),
        'F' => parseYearMonthDay(st, target),
        'H' => parseHour(st, target),
        'I' => parseHour12(st, target),
        'j' => parseDayOfYear(st, target),
        'k' => blk: {
            st.saw_24h = true;
            break :blk parseLeadingSpaceThen(st, target, parseHour);
        },
        'l' => blk: {
            st.saw_12h = true;
            break :blk parseLeadingSpaceThen(st, target, parseHour12);
        },
        'M' => parseMinute(st, target),
        'm' => parseMonthNumber(st, target),
        'p', 'P' => parseAMPM(st, target),
        'R' => parseHourMinute(st, target),
        'S' => parseSecond(st, target),
        's' => parseUnixSeconds(st, target),
        'T', 'X' => parseHourMinuteSecond(st, target),
        'Y' => parseYear(st, target),
        'y' => parseYearNoCentury(st, target),
        '%' => parseLiteral(st, target, '%'),
        else => failFmt(st.alloc, "unexpected format type %{c}", .{spec}, error.InvalidDate),
    };
}

// -- field parsers ------------------------------------------------------

fn parseDay(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 1, 31) catch |e| return wrap(st, "could not parse day number", e);
    var c = st.parts();
    c.day = r.value;
    st.set(c);
    return r.progress;
}
fn parseMonthNumber(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 1, 12) catch |e| return wrap(st, "could not parse month", e);
    var c = st.parts();
    c.month = r.value;
    st.set(c);
    return r.progress;
}
fn parseHour(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 0, 23) catch |e| return wrap(st, "could not parse hour number", e);
    var c = st.parts();
    c.hour = r.value;
    st.set(c);
    return r.progress;
}
fn parseHour12(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 1, 12) catch |e| return wrap(st, "could not parse hour number", e);
    var c = st.parts();
    c.hour = r.value;
    st.set(c);
    st.saw_12h = true;
    return r.progress;
}
fn parseMinute(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 0, 59) catch |e| return wrap(st, "unexpected minute number", e);
    var c = st.parts();
    c.minute = r.value;
    st.set(c);
    return r.progress;
}
fn parseSecond(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 0, 59) catch |e| return wrap(st, "unexpected second number", e);
    var c = st.parts();
    c.second = r.value;
    st.set(c);
    return r.progress;
}
fn parseYear(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 1, 9999) catch |e| return wrap(st, "could not parse year", e);
    var c = st.parts();
    c.year = r.value;
    st.set(c);
    return r.progress;
}
fn parseYearNoCentury(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 0, 99) catch |e| return wrap(st, "could not parse year without century", e);
    var year = r.value;
    if (year >= 69) year += 1900 else year += 2000;
    var c = st.parts();
    c.year = year;
    st.set(c);
    return r.progress;
}
fn parseCentury(st: *State, target: []const u8) Error!usize {
    if (target.len < 2 or !std.ascii.isDigit(target[0]) or !std.ascii.isDigit(target[1]))
        return failFmt(st.alloc, "unexpected century number", .{}, error.InvalidDate);
    const cc = @as(i64, target[0] - '0') * 10 + (target[1] - '0');
    var c = st.parts();
    c.year = cc * 100 - 99;
    st.set(c);
    return 2;
}
fn parseDayOfYear(st: *State, target: []const u8) Error!usize {
    const r = parseDigits(st, target, 1, 366) catch |e| return wrap(st, "could not parse day of year number", e);
    const c = st.parts();
    // Go: Jan 1 of year + (d-1) days.
    const base = tu.compose(c.year, 1, 1, c.hour, c.minute, c.second, c.micro);
    st.civ = base + (r.value - 1) * tu.day_micros;
    return r.progress;
}
fn parseUnixSeconds(st: *State, target: []const u8) Error!usize {
    if (target.len < 10) return failFmt(st.alloc, "unexpected unixtime length", .{}, error.InvalidDate);
    var uv: i64 = 0;
    for (target[0..10]) |ch| {
        if (!std.ascii.isDigit(ch)) return failFmt(st.alloc, "unexpected unixtime number", .{}, error.InvalidDate);
        uv = uv * 10 + (ch - '0');
    }
    st.civ = uv * tu.second_micros;
    return 10;
}

fn wrap(st: *State, comptime name: []const u8, e: Error) Error {
    return failFmt(st.alloc, name ++ ": {s}", .{message orelse "error"}, e);
}

fn parseLiteral(st: *State, target: []const u8, ch: u8) Error!usize {
    if (target.len < 1 or target[0] != ch)
        return failFmt(st.alloc, "[{c}] not found", .{ch}, error.InvalidDate);
    return 1;
}

fn parseLeadingSpaceThen(
    st: *State,
    target: []const u8,
    inner: *const fn (*State, []const u8) Error!usize,
) Error!usize {
    // Go leadingSpaceAllowedParser requires >= 2 chars, consumes 1 leading space.
    if (target.len < 2) return failFmt(st.alloc, "text must be at least 2 characters long", .{}, error.InvalidDate);
    var progress: usize = 0;
    if (target[0] == ' ') progress += 1;
    progress += try inner(st, target[progress..]);
    return progress;
}

fn parseWeekdayName(st: *State, target: []const u8, short: bool) Error!usize {
    if (short) {
        if (target.len < 3) return failFmt(st.alloc, "unexpected short day of week", .{}, error.InvalidDate);
        for (day_names) |name| {
            if (eqIgnoreCase(name[0..3], target[0..3])) return 3;
        }
        return failFmt(st.alloc, "unexpected short day of week", .{}, error.InvalidDate);
    }
    for (day_names) |name| {
        if (target.len < name.len) continue;
        if (eqIgnoreCase(name, target[0..name.len])) return name.len;
    }
    return failFmt(st.alloc, "unexpected day of week", .{}, error.InvalidDate);
}

fn parseMonthName(st: *State, target: []const u8, short: bool) Error!usize {
    if (short) {
        if (target.len < 3) return failFmt(st.alloc, "unexpected short month", .{}, error.InvalidDate);
        for (month_names, 0..) |name, idx| {
            if (eqIgnoreCase(name[0..3], target[0..3])) {
                // Go shortMonthParser: AddDate(0, (idx+1)-month, 0).
                const c = st.parts();
                const bt = tu.BrokenTime{ .civ = st.civ };
                st.civ = bt.addDate(0, @as(i64, @intCast(idx + 1)) - c.month, 0).civ;
                return 3;
            }
        }
        return failFmt(st.alloc, "unexpected short month", .{}, error.InvalidDate);
    }
    for (month_names, 0..) |name, idx| {
        if (target.len < name.len) continue;
        if (eqIgnoreCase(name, target[0..name.len])) {
            var c = st.parts();
            c.month = @intCast(idx + 1);
            st.set(c);
            return name.len;
        }
    }
    return failFmt(st.alloc, "unexpected month", .{}, error.InvalidDate);
}

fn parseAMPM(st: *State, target: []const u8) Error!usize {
    if (target.len < 2) return failFmt(st.alloc, "cannot parse am/pm format: remaining text [{s}]", .{target}, error.InvalidDate);
    const tod = target[0..2];
    if (eqIgnoreCase(tod, "am")) {
        st.saw_ampm = true;
        st.ampm_pm = false;
        return 2;
    }
    if (eqIgnoreCase(tod, "pm")) {
        st.saw_ampm = true;
        st.ampm_pm = true;
        return 2;
    }
    return failFmt(st.alloc, "cannot parse am/pm format: [{s}] is not am/pm", .{target}, error.InvalidDate);
}

// -- composed parsers ---------------------------------------------------

fn parseYearMonthDay(st: *State, target: []const u8) Error!usize {
    return composed(st, target, "year-month-day format", &.{ pfYear, pfHyphen, pfMonthNumber, pfHyphen, pfDay });
}
fn parseMonthDayYear(st: *State, target: []const u8) Error!usize {
    return composed(st, target, "month/day/year format", &.{ pfMonthNumber, pfSlash, pfDay, pfSlash, pfYearNoCentury });
}
fn parseHourMinute(st: *State, target: []const u8) Error!usize {
    st.saw_24h = true;
    return composed(st, target, "hour:minute format", &.{ pfHour, pfColon, pfMinute });
}
fn parseHourMinuteSecond(st: *State, target: []const u8) Error!usize {
    st.saw_24h = true;
    return composed(st, target, "hour:minute:second format", &.{ pfHour, pfColon, pfMinute, pfColon, pfSecond });
}

const PF = *const fn (*State, []const u8) Error!usize;
fn pfYear(s: *State, t: []const u8) Error!usize {
    return parseYear(s, t);
}
fn pfYearNoCentury(s: *State, t: []const u8) Error!usize {
    return parseYearNoCentury(s, t);
}
fn pfMonthNumber(s: *State, t: []const u8) Error!usize {
    return parseMonthNumber(s, t);
}
fn pfDay(s: *State, t: []const u8) Error!usize {
    return parseDay(s, t);
}
fn pfHour(s: *State, t: []const u8) Error!usize {
    return parseHour(s, t);
}
fn pfMinute(s: *State, t: []const u8) Error!usize {
    return parseMinute(s, t);
}
fn pfSecond(s: *State, t: []const u8) Error!usize {
    return parseSecond(s, t);
}
fn pfHyphen(s: *State, t: []const u8) Error!usize {
    return parseLiteral(s, t, '-');
}
fn pfColon(s: *State, t: []const u8) Error!usize {
    return parseLiteral(s, t, ':');
}
fn pfSlash(s: *State, t: []const u8) Error!usize {
    return parseLiteral(s, t, '/');
}

fn composed(
    st: *State,
    target: []const u8,
    comptime name: []const u8,
    parsers: []const PF,
) Error!usize {
    var progress: usize = 0;
    for (parsers) |p| {
        const step = p(st, target[progress..]) catch {
            return failFmt(st.alloc, "could not parse " ++ name ++ ": {s} after [{s}]", .{
                message orelse "error", target[0..progress],
            }, error.InvalidDate);
        };
        progress += step;
    }
    return progress;
}

/// Go ansicParser: time.Parse("Mon Jan 02 15:04:05 2006", text) over all text.
fn parseAnsic(st: *State, target: []const u8) Error!usize {
    // "Thu Dec 25 07:30:00 2008": wday(3) sp mon(3) sp day(2) sp hh:mm:ss sp year
    if (target.len < 24) return failFmt(st.alloc, "parsing time \"{s}\" as ansic", .{target}, error.InvalidDate);
    _ = try parseWeekdayName(st, target[0..], true);
    if (target[3] != ' ') return failFmt(st.alloc, "ansic parse error", .{}, error.InvalidDate);
    _ = try parseMonthName(st, target[4..], true);
    if (target[7] != ' ') return failFmt(st.alloc, "ansic parse error", .{}, error.InvalidDate);
    var c = st.parts();
    c.day = try twoDigit(st, target[8..10]);
    st.set(c);
    if (target[10] != ' ') return failFmt(st.alloc, "ansic parse error", .{}, error.InvalidDate);
    _ = try parseHourMinuteSecond(st, target[11..19]);
    if (target[19] != ' ') return failFmt(st.alloc, "ansic parse error", .{}, error.InvalidDate);
    c = st.parts();
    var year: i64 = 0;
    for (target[20..24]) |ch| {
        if (!std.ascii.isDigit(ch)) return failFmt(st.alloc, "ansic parse error", .{}, error.InvalidDate);
        year = year * 10 + (ch - '0');
    }
    c.year = year;
    st.set(c);
    return 24;
}

fn twoDigit(st: *State, s: []const u8) Error!i64 {
    if (s.len < 2 or !std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1]))
        return failFmt(st.alloc, "expected two digits", .{}, error.InvalidDate);
    return @as(i64, s[0] - '0') * 10 + (s[1] - '0');
}

fn parseRFC3339Zone(st: *State, target: []const u8) Error!usize {
    if (target.len == 0) return failFmt(st.alloc, "unexpected offset format", .{}, error.InvalidDate);
    if (target[0] == 'Z') {
        st.offset_sec = 0;
        return 1;
    }
    if (target[0] == '+' or target[0] == '-') {
        const sign: i64 = if (target[0] == '-') -1 else 1;
        // Expect exactly "HH:MM".
        if (target.len < 6 or target[3] != ':') return failFmt(
            st.alloc,
            "unexpected offset format",
            .{},
            error.InvalidDate,
        );
        const h = try twoDigit(st, target[1..3]);
        const m = try twoDigit(st, target[4..6]);
        st.offset_sec = sign * (h * 3600 + m * 60);
        return 6;
    }
    return failFmt(st.alloc, "unexpected offset format: %{c}", .{target[0]}, error.InvalidDate);
}

/// Go timePrecisionParser: regex `[0-9]{2}\.?[0-9]*` — seconds and optional
/// fractional, truncated to `precision` digits.
fn parseSecondPrecision(st: *State, precision: usize, target: []const u8) Error!usize {
    _ = precision;
    if (target.len < 2 or !std.ascii.isDigit(target[0]) or !std.ascii.isDigit(target[1]))
        return failFmt(st.alloc, "failed to parse seconds.nanoseconds for {s}", .{target}, error.InvalidDate);
    var idx: usize = 2;
    const sec = @as(i64, target[0] - '0') * 10 + (target[1] - '0');
    var micro: i64 = 0;
    if (idx < target.len and target[idx] == '.') {
        idx += 1;
        var digits: usize = 0;
        while (idx < target.len and std.ascii.isDigit(target[idx])) : (idx += 1) {
            if (digits < 6) {
                micro = micro * 10 + (target[idx] - '0');
                digits += 1;
            }
        }
        while (digits < 6) : (digits += 1) micro *= 10;
    }
    var c = st.parts();
    c.second = sec;
    c.micro = micro;
    st.set(c);
    return idx;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn testFmt(comptime expect: []const u8, format: []const u8, civ: i64, typ: FormatType) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try formatTime(arena.allocator(), format, .{ .civ = civ }, 0, typ);
    try testing.expectEqualStrings(expect, out);
}

test "format elements" {
    const civ = tu.compose(2008, 12, 25, 15, 30, 0, 0);
    try testFmt("12/25/08", "%x", civ, .date);
    try testFmt("08", "%y", civ, .date);
    try testFmt("Dec-25-2008", "%b-%d-%Y", civ, .date);
    try testFmt("2008", "%E4Y", civ, .date);
    try testFmt("Thu Dec 25 15:30:00 2008", "%c", civ, .datetime);
    try testFmt("15:30", "%R", civ, .time);
    try testFmt("15", "%k", civ, .time);
    try testFmt(" 3", "%l", civ, .time);
    const civf = tu.compose(2008, 12, 25, 15, 30, 12, 345678);
    try testFmt("12.345", "%E3S", civf, .datetime);
    try testFmt("12.345678", "%E*S", civf, .datetime);
}

test "parse round trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const r = try parseTimeFormat(a, "%Y-%m-%d", "2008-12-25", .date);
        const c = tu.decompose(r.civ);
        try testing.expectEqual(@as(i64, 2008), c.year);
        try testing.expectEqual(@as(i64, 12), c.month);
        try testing.expectEqual(@as(i64, 25), c.day);
    }
    {
        const r = try parseTimeFormat(a, "%m", "03", .date);
        const c = tu.decompose(r.civ);
        try testing.expectEqual(@as(i64, 3), c.month);
        try testing.expectEqual(@as(i64, 1970), c.year);
    }
    {
        const r = try parseTimeFormat(a, "%I%p", "9am", .timestamp);
        try testing.expectEqual(@as(i64, 9 * 3600 * tu.second_micros), r.civ);
    }
}
