//! Port of go-zetasqlite internal/function_bind.go (foundation scope): the
//! FuncInfo table mapping GoogleSQL function names to bind handlers.
//!
//! Go's setupNormalFuncMap registers each entry twice:
//!   zetasqlite_<name>       -> BindFunc (errors surface as SQL errors)
//!   zetasqlite_safe_<name>  -> SafeFunc orelse BindFunc (errors -> NULL)
//! register.zig mirrors that; this file only owns the table + shared helpers.

const std = @import("std");

pub const value_mod = @import("../value.zig");
pub const Value = value_mod.Value;
pub const Error = value_mod.ValueError;

pub const Handler = *const fn (alloc: std.mem.Allocator, args: []const Value) Error!Value;

pub const FuncInfo = struct {
    name: [:0]const u8,
    /// Arguments the handler indexes without checking (Go would panic below
    /// this count; we surface an error instead of UB).
    min_args: u8 = 0,
    handler: Handler,
    /// Go FuncInfo.SafeFunc: replaces handler for the safe_ variant.
    safe_handler: ?Handler = null,
};

// ----------------------------------------------------------------------
// Error message plumbing. Go returns fmt.Errorf strings through the sqlite
// driver; we format into a threadlocal buffer that register.zig hands to
// sqlite3_result_error. value.zig keeps its own (static-string) diagnostic.
// ----------------------------------------------------------------------

threadlocal var msg_buf: [512]u8 = undefined;
pub threadlocal var message: ?[]const u8 = null;

pub fn clearDiagnostics() void {
    message = null;
    value_mod.diagnostic = null;
}

/// Formats a Go-style error message and returns `err`.
pub fn fail(comptime fmt: []const u8, args: anytype, err: Error) Error {
    message = std.fmt.bufPrint(&msg_buf, fmt, args) catch fmt;
    return err;
}

/// Copies a runtime message (e.g. the argument of ERROR()) and returns `err`.
pub fn failMsg(msg: []const u8, err: Error) Error {
    const n = @min(msg.len, msg_buf.len);
    @memcpy(msg_buf[0..n], msg[0..n]);
    message = msg_buf[0..n];
    return err;
}

/// Go function.go existsNull: any SQL NULL among the arguments.
pub fn existsNull(args: []const Value) bool {
    for (args) |v| {
        if (v == .@"null") return true;
    }
    return false;
}

// ----------------------------------------------------------------------
// The table (Go: normalFuncs, foundation subset). Names are exactly the Go
// map keys; the extractor normalizes $add/$subtract/... to these.
// ----------------------------------------------------------------------

const math = @import("fn_math.zig");
const cmp = @import("fn_compare.zig");
const str = @import("fn_string.zig");
const arr = @import("fn_array.zig");
const misc = @import("fn_misc.zig");
const fdate = @import("fn_date.zig");
const fdatetime = @import("fn_datetime.zig");
const ftime = @import("fn_time.zig");
const ftimestamp = @import("fn_timestamp.zig");
const fintv = @import("fn_interval.zig");

pub const func_table = [_]FuncInfo{
    // arithmetic (Go: bindAdd/bindSub/bindMul/bindOpDiv + SAFE_* funcs)
    .{ .name = "add", .min_args = 2, .handler = math.add, .safe_handler = math.safeAdd },
    .{ .name = "subtract", .min_args = 2, .handler = math.sub, .safe_handler = math.safeSubtract },
    .{ .name = "multiply", .min_args = 2, .handler = math.mul, .safe_handler = math.safeMultiply },
    .{ .name = "divide", .min_args = 2, .handler = math.opDiv, .safe_handler = math.safeDivide },

    // comparisons
    .{ .name = "equal", .min_args = 2, .handler = cmp.equal },
    .{ .name = "not_equal", .min_args = 2, .handler = cmp.notEqual },
    .{ .name = "greater", .min_args = 2, .handler = cmp.greater },
    .{ .name = "greater_or_equal", .min_args = 2, .handler = cmp.greaterOrEqual },
    .{ .name = "less", .min_args = 2, .handler = cmp.less },
    .{ .name = "less_or_equal", .min_args = 2, .handler = cmp.lessOrEqual },

    // bit operations
    .{ .name = "bitwise_not", .min_args = 1, .handler = math.bitNot },
    .{ .name = "bitwise_left_shift", .min_args = 2, .handler = math.bitLeftShift },
    .{ .name = "bitwise_right_shift", .min_args = 2, .handler = math.bitRightShift },
    .{ .name = "bitwise_and", .min_args = 2, .handler = math.bitAnd },
    .{ .name = "bitwise_or", .min_args = 2, .handler = math.bitOr },
    .{ .name = "bitwise_xor", .min_args = 2, .handler = math.bitXor },

    // array / struct access
    .{ .name = "in_array", .min_args = 2, .handler = arr.inArray },
    .{ .name = "get_struct_field", .min_args = 2, .handler = arr.structField },
    .{ .name = "array_at_offset", .min_args = 2, .handler = arr.arrayAtOffset, .safe_handler = arr.safeArrayAtOffset },
    .{ .name = "array_at_ordinal", .min_args = 2, .handler = arr.arrayAtOrdinal, .safe_handler = arr.safeArrayAtOrdinal },
    .{ .name = "safe_negate", .min_args = 1, .handler = math.safeNegate },
    .{ .name = "is_distinct_from", .min_args = 2, .handler = cmp.isDistinctFrom },
    .{ .name = "is_not_distinct_from", .min_args = 2, .handler = cmp.isNotDistinctFrom },

    // debugging
    .{ .name = "error", .min_args = 1, .handler = misc.errorFn },

    // predicates / conditionals
    .{ .name = "like", .min_args = 2, .handler = cmp.like },
    .{ .name = "between", .min_args = 3, .handler = cmp.between },
    .{ .name = "in", .min_args = 1, .handler = cmp.in },
    .{ .name = "is_null", .min_args = 1, .handler = cmp.isNull },
    .{ .name = "is_true", .min_args = 1, .handler = cmp.isTrue },
    .{ .name = "is_false", .min_args = 1, .handler = cmp.isFalse },
    .{ .name = "not", .min_args = 1, .handler = cmp.not },
    .{ .name = "and", .handler = cmp.@"and" },
    .{ .name = "or", .handler = cmp.@"or" },
    .{ .name = "coalesce", .handler = cmp.coalesce },
    .{ .name = "if", .handler = cmp.@"if" },
    .{ .name = "ifnull", .handler = cmp.ifnull },
    .{ .name = "nullif", .handler = cmp.nullif },
    .{ .name = "length", .handler = str.length },
    .{ .name = "cast", .handler = misc.cast },

    // string functions
    .{ .name = "concat", .handler = str.concat },
    .{ .name = "left", .handler = str.left },
    .{ .name = "lower", .handler = str.lower },
    .{ .name = "right", .min_args = 2, .handler = str.right },
    .{ .name = "substr", .handler = str.substr },
    .{ .name = "upper", .handler = str.upper },

    // math functions
    .{ .name = "abs", .min_args = 1, .handler = math.abs },
    .{ .name = "round", .handler = math.round },

    .{ .name = "mod", .min_args = 2, .handler = math.mod },
    .{ .name = "least", .min_args = 1, .handler = cmp.least },
    .{ .name = "greatest", .min_args = 1, .handler = cmp.greatest },

    // array functions
    .{ .name = "array_concat", .handler = arr.arrayConcat },
    .{ .name = "array_length", .handler = arr.arrayLength },
    .{ .name = "make_array", .handler = arr.makeArray },
    .{ .name = "make_struct", .handler = arr.makeStruct },

    // date family (Go function_date.go)
    .{ .name = "current_date", .handler = fdate.currentDate },
    .{ .name = "date", .min_args = 1, .handler = fdate.date },
    .{ .name = "date_add", .min_args = 3, .handler = fdate.dateAdd },
    .{ .name = "date_sub", .min_args = 3, .handler = fdate.dateSub },
    .{ .name = "date_diff", .min_args = 3, .handler = fdate.dateDiff },
    .{ .name = "date_trunc", .min_args = 2, .handler = fdate.dateTrunc },
    .{ .name = "date_from_unix_date", .min_args = 1, .handler = fdate.dateFromUnixDate },
    .{ .name = "format_date", .min_args = 2, .handler = fdate.formatDate },
    .{ .name = "last_day", .min_args = 1, .handler = fdate.lastDay },
    .{ .name = "parse_date", .min_args = 2, .handler = fdate.parseDate },
    .{ .name = "unix_date", .min_args = 1, .handler = fdate.unixDate },
    .{ .name = "extract", .min_args = 2, .handler = fdate.extract },
    .{ .name = "extract_date", .min_args = 1, .handler = fdate.extractDate },
    .{ .name = "generate_date_array", .min_args = 2, .handler = fdate.generateDateArray },

    // datetime family (Go function_datetime.go)
    .{ .name = "current_datetime", .handler = fdatetime.currentDatetime },
    .{ .name = "datetime", .min_args = 1, .handler = fdatetime.datetime },
    .{ .name = "datetime_add", .min_args = 3, .handler = fdatetime.datetimeAdd },
    .{ .name = "datetime_sub", .min_args = 3, .handler = fdatetime.datetimeSub },
    .{ .name = "datetime_diff", .min_args = 3, .handler = fdatetime.datetimeDiff },
    .{ .name = "datetime_trunc", .min_args = 2, .handler = fdatetime.datetimeTrunc },
    .{ .name = "format_datetime", .min_args = 2, .handler = fdatetime.formatDatetime },
    .{ .name = "parse_datetime", .min_args = 2, .handler = fdatetime.parseDatetime },

    // time family (Go function_time.go)
    .{ .name = "current_time", .handler = ftime.currentTime },
    .{ .name = "time", .min_args = 1, .handler = ftime.time },
    .{ .name = "time_add", .min_args = 3, .handler = ftime.timeAdd },
    .{ .name = "time_sub", .min_args = 3, .handler = ftime.timeSub },
    .{ .name = "time_diff", .min_args = 3, .handler = ftime.timeDiff },
    .{ .name = "time_trunc", .min_args = 2, .handler = ftime.timeTrunc },
    .{ .name = "format_time", .min_args = 2, .handler = ftime.formatTimeFn },
    .{ .name = "parse_time", .min_args = 2, .handler = ftime.parseTime },

    // timestamp family (Go function_timestamp.go)
    .{ .name = "current_timestamp", .handler = ftimestamp.currentTimestamp },
    .{ .name = "string", .min_args = 1, .handler = ftimestamp.string },
    .{ .name = "timestamp", .min_args = 1, .handler = ftimestamp.timestamp },
    .{ .name = "timestamp_add", .min_args = 3, .handler = ftimestamp.timestampAdd },
    .{ .name = "timestamp_sub", .min_args = 3, .handler = ftimestamp.timestampSub },
    .{ .name = "timestamp_diff", .min_args = 3, .handler = ftimestamp.timestampDiff },
    .{ .name = "timestamp_trunc", .min_args = 2, .handler = ftimestamp.timestampTrunc },
    .{ .name = "format_timestamp", .min_args = 2, .handler = ftimestamp.formatTimestamp },
    .{ .name = "parse_timestamp", .min_args = 2, .handler = ftimestamp.parseTimestamp },
    .{ .name = "timestamp_seconds", .min_args = 1, .handler = ftimestamp.timestampSeconds },
    .{ .name = "timestamp_millis", .min_args = 1, .handler = ftimestamp.timestampMillis },
    .{ .name = "timestamp_micros", .min_args = 1, .handler = ftimestamp.timestampMicros },
    .{ .name = "unix_seconds", .min_args = 1, .handler = ftimestamp.unixSeconds },
    .{ .name = "unix_millis", .min_args = 1, .handler = ftimestamp.unixMillis },
    .{ .name = "unix_micros", .min_args = 1, .handler = ftimestamp.unixMicros },
    .{ .name = "generate_timestamp_array", .min_args = 4, .handler = ftimestamp.generateTimestampArray },

    // interval family (Go function_interval.go)
    .{ .name = "interval", .min_args = 2, .handler = fintv.interval },
    .{ .name = "make_interval", .min_args = 6, .handler = fintv.makeInterval },
    .{ .name = "justify_days", .min_args = 1, .handler = fintv.justifyDaysFn },
    .{ .name = "justify_hours", .min_args = 1, .handler = fintv.justifyHoursFn },
    .{ .name = "justify_interval", .min_args = 1, .handler = fintv.justifyIntervalFn },
};
