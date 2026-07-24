//! Faithful port of go-zetasqlite internal/value.go (foundation scope).
//!
//! Value kinds ported: Null, Int, Float, Bool, String, Bytes, Date, Array,
//! Struct, and the SafeValue wrapper. Numeric/BigNumeric, Json, Datetime,
//! Time, Timestamp and Interval are deferred (error.Unimplemented); their
//! binary codec tags exist in codec_binary.zig so the format is complete.
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
    OutOfMemory,
};

/// Optional diagnostic for the most recent error on this thread. Always a
/// static string (never allocated). Mirrors the Go error messages loosely.
pub threadlocal var diagnostic: ?[]const u8 = null;

fn fail(comptime msg: []const u8, err: ValueError) ValueError {
    diagnostic = msg;
    return err;
}

pub const ArrayValue = struct {
    values: []Value,
};

pub const StructValue = struct {
    keys: [][]const u8,
    values: []Value,

    /// Linear lookup (key counts are small; Go keeps a map, we do not).
    /// Returns the first field with the given name, like Go's map would
    /// return the (deduplicated) entry.
    pub fn fieldByName(self: *const StructValue, name: []const u8) ?Value {
        for (self.keys, self.values) |k, v| {
            if (std.mem.eql(u8, k, name)) return v;
        }
        return null;
    }
};

// Shared zero-value results used by the SafeValue error-swallowing paths
// (Go returns &ArrayValue{} / &StructValue{} there).
var empty_array_storage = ArrayValue{ .values = &[0]Value{} };
var empty_struct_storage = StructValue{ .keys = &[0][]const u8{}, .values = &[0]Value{} };

pub const Value = union(enum) {
    @"null",
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,
    /// Civil days since the Unix epoch (Go stores a midnight-UTC time.Time;
    /// observable behavior is identical: ToInt64 => days*86400 (unix
    /// seconds), ToString => "YYYY-MM-DD").
    date: i64,
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
            .@"null" => return fail("add on null value", error.NullValue),
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
                // Go type-switches on IntValue (add days) and *IntervalValue
                // (deferred); anything else is an error.
                .int => |n| return Value{ .date = days +% n },
                else => return fail("failed to use add operator for date", error.UnsupportedOperation),
            },
            .array => return fail("add operation is unsupported for array", error.UnsupportedOperation),
            .struct_ => return fail("add operation is unsupported for struct", error.UnsupportedOperation),
            .safe => |p| return p.add(alloc, v) catch Value.@"null",
        }
    }

    pub fn sub(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .@"null" => return fail("sub on null value", error.NullValue),
            .int => |i| return Value{ .int = i -% try v.toInt64() },
            .float => |f| return Value{ .float = f - try v.toFloat64() },
            .string => return fail("sub operation is unsupported for string", error.UnsupportedOperation),
            .bytes => return fail("sub operation is unsupported for bytes", error.UnsupportedOperation),
            .bool => return fail("sub operation is unsupported for bool", error.UnsupportedOperation),
            .date => |days| switch (v) {
                .int => |n| return Value{ .date = days -% n },
                // date - date / date - interval produce IntervalValue in Go: deferred.
                else => return fail("date sub produces interval (deferred)", error.Unimplemented),
            },
            .array => return fail("sub operation is unsupported for array", error.UnsupportedOperation),
            .struct_ => return fail("sub operation is unsupported for struct", error.UnsupportedOperation),
            .safe => |p| return p.sub(alloc, v) catch Value.@"null",
        }
    }

    pub fn mul(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .@"null" => return fail("mul on null value", error.NullValue),
            .int => |i| return Value{ .int = i *% try v.toInt64() },
            .float => |f| return Value{ .float = f * try v.toFloat64() },
            .safe => |p| return p.mul(alloc, v) catch Value.@"null",
            else => return fail("mul operation is unsupported for this type", error.UnsupportedOperation),
        }
    }

    pub fn div(self: Value, alloc: std.mem.Allocator, v: Value) ValueError!Value {
        switch (self) {
            .@"null" => return fail("div on null value", error.NullValue),
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
            .safe => |p| return p.div(alloc, v) catch Value.@"null",
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
            .@"null" => return fail("comparison on null value", error.NullValue),
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
                if (st2.keys.len != st.keys.len) return false;
                for (st.keys, st.values) |key, lhs_field| {
                    // Go indexes the other struct's map; a missing key yields
                    // a nil Value (which would panic there).
                    const rhs_field = st2.fieldByName(key) orelse
                        return fail("missing struct field in comparison", error.NullValue);
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
            .@"null" => return fail("toInt64 on null value", error.NullValue),
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
                return std.fmt.parseInt(i64, s, base) catch
                    fail("failed to convert string to int64", error.FailedConversion);
            },
            .bytes => |b| {
                if (b.len == 0) return 0;
                return std.fmt.parseInt(i64, b, 10) catch
                    fail("failed to convert bytes to int64", error.FailedConversion);
            },
            // Go DateValue.ToInt64 returns time.Time(d).Unix() = days * 86400.
            .date => |days| return days *% 86400,
            .array => return fail("failed to convert int64 from array", error.FailedConversion),
            .struct_ => return fail("failed to convert int64 from struct", error.FailedConversion),
            .safe => |p| return p.toInt64() catch 0,
        }
    }

    pub fn toFloat64(self: Value) ValueError!f64 {
        switch (self) {
            .@"null" => return fail("toFloat64 on null value", error.NullValue),
            .int => |i| return @floatFromInt(i),
            .float => |f| return f,
            .bool => |b| return if (b) 1 else 0,
            .string => |s| {
                if (s.len == 0) return 0;
                return std.fmt.parseFloat(f64, s) catch
                    fail("failed to convert string to float64", error.FailedConversion);
            },
            .bytes => |b| {
                if (b.len == 0) return 0;
                return std.fmt.parseFloat(f64, b) catch
                    fail("failed to convert bytes to float64", error.FailedConversion);
            },
            .date => |days| return @floatFromInt(days *% 86400),
            .array => return fail("failed to convert float64 from array", error.FailedConversion),
            .struct_ => return fail("failed to convert float64 from struct", error.FailedConversion),
            .safe => |p| return p.toFloat64() catch 0,
        }
    }

    pub fn toBool(self: Value) ValueError!bool {
        switch (self) {
            .@"null" => return fail("toBool on null value", error.NullValue),
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
            .array => return fail("failed to convert bool from array", error.FailedConversion),
            .struct_ => return fail("failed to convert bool from struct", error.FailedConversion),
            .safe => |p| return p.toBool() catch false,
        }
    }

    pub fn toString(self: Value, alloc: std.mem.Allocator) ValueError![]u8 {
        switch (self) {
            .@"null" => return fail("toString on null value", error.NullValue),
            .int => |i| return std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| {
                var buf: [32]u8 = undefined;
                return alloc.dupe(u8, formatFloatGo(&buf, f));
            },
            .bool => |b| return alloc.dupe(u8, if (b) "true" else "false"),
            .string => |s| return alloc.dupe(u8, s),
            .bytes => |b| return alloc.dupe(u8, b),
            .date => |days| {
                var buf: [32]u8 = undefined;
                return alloc.dupe(u8, formatDateDays(&buf, days));
            },
            // Array/Struct ToString renders elements via ToJSON (deferred).
            .array => return fail("array ToString requires ToJSON (deferred)", error.Unimplemented),
            .struct_ => return fail("struct ToString requires ToJSON (deferred)", error.Unimplemented),
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
            .@"null" => return fail("toArray on null value", error.NullValue),
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
            .@"null" => return fail("toStruct on null value", error.NullValue),
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
    pub fn toJson(self: Value, alloc: std.mem.Allocator) ValueError![]u8 {
        _ = self;
        _ = alloc;
        return fail("ToJSON is deferred", error.Unimplemented);
    }
    pub fn toRat(self: Value) ValueError!void {
        _ = self;
        return fail("ToRat is deferred", error.Unimplemented);
    }
    pub fn toApiString(self: Value, alloc: std.mem.Allocator) ValueError![]u8 {
        _ = self;
        _ = alloc;
        return fail("ToApiString is deferred", error.Unimplemented);
    }
    pub fn format(self: Value, verb: u8, alloc: std.mem.Allocator) ValueError![]u8 {
        _ = self;
        _ = verb;
        _ = alloc;
        return fail("Format is deferred", error.Unimplemented);
    }
};

// ----------------------------------------------------------------------
// Coercion helpers
// ----------------------------------------------------------------------

/// Scalar Value -> string coercion used by string/bytes comparisons; writes
/// scalars into `buf` (needs >= 32 bytes) and aliases string/bytes payloads.
fn coerceToStringForCmp(v: Value, buf: []u8) ValueError![]const u8 {
    switch (v) {
        .@"null" => return error.NullValue,
        .string => |s| return s,
        .bytes => |b| return b,
        .int => |i| return std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable,
        .float => |f| return formatFloatGo(buf, f),
        .bool => |b| return if (b) "true" else "false",
        .date => |days| return formatDateDays(buf, days),
        // Array/Struct ToString needs ToJSON (deferred).
        .array, .struct_ => return error.Unimplemented,
        .safe => |p| return coerceToStringForCmp(p.*, buf) catch "",
    }
}

const zero_time_days: i64 = daysFromCivil(1, 1, 1); // Go's time.Time{}

/// rhs.ToTime() as used by date comparisons, projected onto civil days.
fn dateDaysFromValue(v: Value) ValueError!i64 {
    switch (v) {
        .@"null" => return error.NullValue,
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
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
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
// Collation comparison (mirrors zetasqlite_collate in function_register.go:
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

pub fn structValue(alloc: std.mem.Allocator, keys: []const []const u8, values: []const Value) !Value {
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

/// Structural equality assertion for tests (floats compared bit-for-bit so
/// NaN payloads and -0.0 round-trip checks are exact).
pub fn expectValueEqual(expected: Value, actual: Value) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .@"null" => {},
        .int => |i| try std.testing.expectEqual(i, actual.int),
        .float => |f| try std.testing.expectEqual(
            @as(u64, @bitCast(f)),
            @as(u64, @bitCast(actual.float)),
        ),
        .bool => |b| try std.testing.expectEqual(b, actual.bool),
        .string => |s| try std.testing.expectEqualStrings(s, actual.string),
        .bytes => |b| try std.testing.expectEqualSlices(u8, b, actual.bytes),
        .date => |d| try std.testing.expectEqual(d, actual.date),
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

test "struct comparisons match by key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const s1 = try structValue(alloc, &.{ "a", "b" }, &.{ Value{ .int = 1 }, Value{ .string = "x" } });
    const s2 = try structValue(alloc, &.{ "b", "a" }, &.{ Value{ .string = "x" }, Value{ .int = 1 } });
    const s3 = try structValue(alloc, &.{ "a", "b" }, &.{ Value{ .int = 2 }, Value{ .string = "x" } });
    const s4 = try structValue(alloc, &.{ "a", "c" }, &.{ Value{ .int = 1 }, Value{ .string = "x" } });

    // Key-based comparison: field order does not matter (Go iterates the map).
    try std.testing.expect(try s1.eq(s2));
    try std.testing.expect(!try s1.eq(s3));
    try std.testing.expectError(error.NullValue, s1.eq(s4)); // missing key => Go nil deref
    const field = s1.struct_.fieldByName("a") orelse return error.TestUnexpectedResult;
    try expectValueEqual(Value{ .int = 1 }, field);
    try std.testing.expect(s1.struct_.fieldByName("zzz") == null);
}

test "safe value swallows errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const safe_int = try safeValue(alloc, Value{ .int = 10 });
    // SAFE.DIVIDE(10, 0) => NULL instead of an error.
    try expectValueEqual(Value.@"null", try safe_int.div(alloc, Value{ .int = 0 }));
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
