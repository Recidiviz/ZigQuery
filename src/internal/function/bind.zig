//! Port of go-zetasqlite internal/function_bind.go (foundation scope): the
//! FuncInfo table mapping GoogleSQL function names to bind handlers.
//!
//! Go's setupNormalFuncMap registers each entry twice:
//!   zetasqlite_<name>       -> BindFunc (errors surface as SQL errors)
//!   zetasqlite_safe_<name>  -> SafeFunc orelse BindFunc (errors -> NULL)
//! register.zig mirrors that; this file only owns the table + shared helpers.

const std = @import("std");
const sqlite = @import("../../sqlite.zig");

pub const value_mod = @import("../value.zig");
pub const Value = value_mod.Value;
pub const Error = value_mod.ValueError;

// ----------------------------------------------------------------------
// Per-call-site argument cache.
//
// A handler receives decoded Values, not the sqlite3_context those Values came
// from, so the context is parked here for the duration of the call rather than
// threaded through every one of the ~200 handler signatures. Only functions
// whose arguments include a compile-time constant worth pre-digesting — CAST's
// two type documents — reach for it.
// ----------------------------------------------------------------------

/// Set by the scalar trampoline for the duration of one call; null otherwise,
/// which simply means no caching is available.
pub threadlocal var current_ctx: ?*sqlite.c.sqlite3_context = null;

/// Cached form of argument `arg`, or null when there is none. Callers must
/// always be able to recompute: SQLite may discard the entry at any time.
pub fn auxGet(comptime T: type, arg: i32) ?*T {
    const ctx = current_ctx orelse return null;
    return @ptrCast(@alignCast(sqlite.getAuxdata(ctx, arg)));
}

/// Hands `p` to SQLite as the cached form of argument `arg`. `p` must not be
/// used afterwards — the destructor can run before this returns.
pub fn auxSet(arg: i32, p: *anyopaque, destructor: sqlite.AuxDestructor) void {
    const ctx = current_ctx orelse return;
    sqlite.setAuxdata(ctx, arg, p, destructor);
}

pub const Handler = *const fn (alloc: std.mem.Allocator, args: []const Value) Error!Value;

pub const FuncInfo = struct {
    name: [:0]const u8,
    /// Arguments the handler indexes without checking (Go would panic below
    /// this count; we surface an error instead of UB).
    min_args: u8 = 0,
    handler: Handler,
    /// Go FuncInfo.SafeFunc: replaces handler for the safe_ variant.
    safe_handler: ?Handler = null,
    /// False for functions whose result may vary between calls with the same
    /// arguments. Such functions must not carry SQLITE_DETERMINISTIC, or
    /// SQLite evaluates them once per query rather than once per row.
    deterministic: bool = true,
    /// Bit i marks argument i as a compile-time constant the handler digests
    /// once and caches with auxGet/auxSet. The trampoline then skips decoding
    /// it on rows where the cache is warm, since the handler will not look at
    /// it. Handlers must still cope with the argument being absent, which is
    /// what a cache hit means.
    cached_args: u8 = 0,
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
        if (v == .null) return true;
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
const reg = @import("fn_regexp.zig");
const fmtfn = @import("fn_format.zig");
const net = @import("fn_net.zig");
const misc = @import("fn_misc.zig");
const fdate = @import("fn_date.zig");
const fdatetime = @import("fn_datetime.zig");
const ftime = @import("fn_time.zig");
const ftimestamp = @import("fn_timestamp.zig");
const fintv = @import("fn_interval.zig");
const fjson = @import("fn_json.zig");
const hash = @import("fn_hash.zig");
const fhll = @import("fn_hll.zig");

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
    .{
        .name = "array_at_offset",
        .min_args = 2,
        .handler = arr.arrayAtOffset,
        .safe_handler = arr.safeArrayAtOffset,
    },
    .{
        .name = "array_at_ordinal",
        .min_args = 2,
        .handler = arr.arrayAtOrdinal,
        .safe_handler = arr.safeArrayAtOrdinal,
    },
    .{ .name = "safe_negate", .min_args = 1, .handler = math.safeNegate },
    .{ .name = "is_distinct_from", .min_args = 2, .handler = cmp.isDistinctFrom },
    .{ .name = "is_not_distinct_from", .min_args = 2, .handler = cmp.isNotDistinctFrom },

    // hash functions (Go function_hash.go) + SESSION_USER (function_security.go)
    .{ .name = "md5", .min_args = 1, .handler = hash.md5 },
    .{ .name = "sha1", .min_args = 1, .handler = hash.sha1 },
    .{ .name = "sha256", .min_args = 1, .handler = hash.sha256 },
    .{ .name = "sha512", .min_args = 1, .handler = hash.sha512 },
    .{ .name = "farm_fingerprint", .min_args = 1, .handler = hash.farmFingerprint },
    .{ .name = "session_user", .handler = hash.sessionUser },

    // HLL_COUNT.EXTRACT (Go bindHllCountExtract; the aggregate HLL_COUNT.*
    // functions are registered in aggregate.zig).
    .{ .name = "hll_count_extract", .min_args = 1, .handler = fhll.hllCountExtract },

    // debugging
    .{ .name = "error", .min_args = 1, .handler = misc.errorFn },

    // numeric (Go function_numeric.go: bindParseNumeric / bindParseBigNumeric)
    .{ .name = "parse_numeric", .min_args = 1, .handler = misc.parseNumeric },
    .{ .name = "parse_bignumeric", .min_args = 1, .handler = misc.parseBignumeric },

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
    // Args 1 and 2 are the from/to type documents, SQL literals that cast()
    // parses once per call site rather than once per row.
    .{ .name = "cast", .handler = misc.cast, .cached_args = 0b110 },

    // string functions
    .{ .name = "concat", .handler = str.concat },
    .{ .name = "left", .handler = str.left },
    .{ .name = "lower", .handler = str.lower },
    .{ .name = "right", .min_args = 2, .handler = str.right },
    .{ .name = "substr", .handler = str.substr },
    .{ .name = "upper", .handler = str.upper },
    .{ .name = "ascii", .min_args = 1, .handler = str.ascii },
    .{ .name = "byte_length", .min_args = 1, .handler = str.byteLength },
    .{ .name = "char_length", .min_args = 1, .handler = str.charLength },
    .{ .name = "chr", .min_args = 1, .handler = str.chr },
    .{ .name = "code_points_to_bytes", .min_args = 1, .handler = str.codePointsToBytes },
    .{ .name = "code_points_to_string", .min_args = 1, .handler = str.codePointsToString },
    .{ .name = "to_code_points", .min_args = 1, .handler = str.toCodePoints },
    .{ .name = "ends_with", .min_args = 2, .handler = str.endsWith },
    .{ .name = "starts_with", .min_args = 2, .handler = str.startsWith },
    .{ .name = "strpos", .min_args = 2, .handler = str.strpos },
    .{ .name = "instr", .min_args = 2, .handler = str.instr },
    .{ .name = "replace", .min_args = 3, .handler = str.replace },
    .{ .name = "repeat", .min_args = 2, .handler = str.repeat },
    .{ .name = "reverse", .min_args = 1, .handler = str.reverse },
    .{ .name = "trim", .min_args = 1, .handler = str.trim },
    .{ .name = "ltrim", .min_args = 1, .handler = str.ltrim },
    .{ .name = "rtrim", .min_args = 1, .handler = str.rtrim },
    .{ .name = "lpad", .min_args = 2, .handler = str.lpad },
    .{ .name = "rpad", .min_args = 2, .handler = str.rpad },
    .{ .name = "split", .min_args = 1, .handler = str.split },
    .{ .name = "initcap", .min_args = 1, .handler = str.initcap },
    .{ .name = "translate", .min_args = 3, .handler = str.translate },
    .{ .name = "unicode", .min_args = 1, .handler = str.unicode },
    .{ .name = "soundex", .min_args = 1, .handler = str.soundex },
    .{ .name = "safe_convert_bytes_to_string", .min_args = 1, .handler = str.safeConvertBytesToString },
    .{ .name = "normalize", .min_args = 1, .handler = str.normalize },
    .{ .name = "normalize_and_casefold", .min_args = 1, .handler = str.normalizeAndCasefold },
    .{ .name = "contains_substr", .min_args = 2, .handler = str.containsSubstr },
    .{ .name = "to_base32", .min_args = 1, .handler = str.toBase32 },
    .{ .name = "from_base32", .min_args = 1, .handler = str.fromBase32 },
    .{ .name = "to_base64", .min_args = 1, .handler = str.toBase64 },
    .{ .name = "from_base64", .min_args = 1, .handler = str.fromBase64 },
    .{ .name = "to_hex", .min_args = 1, .handler = str.toHex },
    .{ .name = "from_hex", .min_args = 1, .handler = str.fromHex },

    // regexp functions (RE2 via the shim)
    .{ .name = "regexp_contains", .min_args = 2, .handler = reg.regexpContains },
    .{ .name = "regexp_extract", .min_args = 2, .handler = reg.regexpExtract },
    .{ .name = "regexp_extract_all", .min_args = 2, .handler = reg.regexpExtractAll },
    .{ .name = "regexp_instr", .min_args = 2, .handler = reg.regexpInstr },
    .{ .name = "regexp_replace", .min_args = 3, .handler = reg.regexpReplace },

    // FORMAT
    .{ .name = "format", .min_args = 1, .handler = fmtfn.format },

    // net.* functions
    // Volatile: BigQuery returns a distinct UUID per row.
    .{ .name = "generate_uuid", .handler = net.generateUuid, .deterministic = false },
    .{ .name = "net_host", .min_args = 1, .handler = net.netHost },
    .{ .name = "net_ip_from_string", .min_args = 1, .handler = net.netIpFromString },
    .{ .name = "net_ip_net_mask", .min_args = 2, .handler = net.netIpNetMask },
    .{ .name = "net_ip_to_string", .min_args = 1, .handler = net.netIpToString },
    .{ .name = "net_ip_trunc", .min_args = 2, .handler = net.netIpTrunc },
    .{ .name = "net_ipv4_from_int64", .min_args = 1, .handler = net.netIpv4FromInt64 },
    .{ .name = "net_ipv4_to_int64", .min_args = 1, .handler = net.netIpv4ToInt64 },
    .{ .name = "net_safe_ip_from_string", .min_args = 1, .handler = net.netSafeIpFromString },
    .{ .name = "net_public_suffix", .min_args = 1, .handler = net.netPublicSuffix },
    .{ .name = "net_reg_domain", .min_args = 1, .handler = net.netRegDomain },

    // math functions
    .{ .name = "abs", .min_args = 1, .handler = math.abs },
    .{ .name = "round", .handler = math.round },
    .{ .name = "floor", .min_args = 1, .handler = math.floor },
    .{ .name = "ceil", .min_args = 1, .handler = math.ceil },
    .{ .name = "ceiling", .min_args = 1, .handler = math.ceil },
    .{ .name = "trunc", .min_args = 1, .handler = math.trunc },
    .{ .name = "div", .min_args = 2, .handler = math.div },
    .{ .name = "ieee_divide", .min_args = 2, .handler = math.ieeeDivide },
    .{ .name = "sqrt", .min_args = 1, .handler = math.sqrt },
    .{ .name = "cbrt", .min_args = 1, .handler = math.cbrt },
    .{ .name = "pow", .min_args = 2, .handler = math.pow },
    .{ .name = "power", .min_args = 2, .handler = math.pow },
    .{ .name = "exp", .min_args = 1, .handler = math.exp },
    .{ .name = "ln", .min_args = 1, .handler = math.ln },
    .{ .name = "log", .min_args = 1, .handler = math.log },
    .{ .name = "log10", .min_args = 1, .handler = math.log10 },
    .{ .name = "is_inf", .min_args = 1, .handler = math.isInf },
    .{ .name = "is_nan", .min_args = 1, .handler = math.isNan },
    .{ .name = "cos", .min_args = 1, .handler = math.cos },
    .{ .name = "sin", .min_args = 1, .handler = math.sin },
    .{ .name = "tan", .min_args = 1, .handler = math.tan },
    .{ .name = "atan", .min_args = 1, .handler = math.atan },
    .{ .name = "atan2", .min_args = 2, .handler = math.atan2 },
    .{ .name = "acos", .min_args = 1, .handler = math.acos },
    .{ .name = "acosh", .min_args = 1, .handler = math.acosh },
    .{ .name = "asin", .min_args = 1, .handler = math.asin },
    .{ .name = "asinh", .min_args = 1, .handler = math.asinh },
    .{ .name = "atanh", .min_args = 1, .handler = math.atanh },
    .{ .name = "cosh", .min_args = 1, .handler = math.cosh },
    .{ .name = "sinh", .min_args = 1, .handler = math.sinh },
    .{ .name = "tanh", .min_args = 1, .handler = math.tanh },
    .{ .name = "cot", .min_args = 1, .handler = math.cot },
    .{ .name = "coth", .min_args = 1, .handler = math.coth },
    .{ .name = "csc", .min_args = 1, .handler = math.csc },
    .{ .name = "csch", .min_args = 1, .handler = math.csch },
    .{ .name = "sec", .min_args = 1, .handler = math.sec },
    .{ .name = "sech", .min_args = 1, .handler = math.sech },
    // Not deterministic: see fn_math.rand on why SQLITE_DETERMINISTIC would
    // collapse every RAND() in a query to one value.
    .{ .name = "rand", .handler = math.rand, .deterministic = false },
    .{ .name = "range_bucket", .min_args = 2, .handler = math.rangeBucket },
    .{ .name = "cosine_distance", .min_args = 2, .handler = math.cosineDistance },
    .{ .name = "euclidean_distance", .min_args = 2, .handler = math.euclideanDistance },

    .{ .name = "mod", .min_args = 2, .handler = math.mod },
    .{ .name = "least", .min_args = 1, .handler = cmp.least },
    .{ .name = "greatest", .min_args = 1, .handler = cmp.greatest },

    // math functions (cont.)
    .{ .name = "sign", .min_args = 1, .handler = math.sign },
    .{ .name = "bit_count", .min_args = 1, .handler = math.bitCount },

    // array functions
    .{ .name = "array_concat", .handler = arr.arrayConcat },
    .{ .name = "array_length", .handler = arr.arrayLength },
    .{ .name = "make_array", .handler = arr.makeArray },
    .{ .name = "make_struct", .handler = arr.makeStruct },
    .{ .name = "array_to_string", .min_args = 2, .handler = arr.arrayToString },
    .{ .name = "array_reverse", .min_args = 1, .handler = arr.arrayReverse },
    .{ .name = "generate_array", .min_args = 2, .handler = arr.generateArray },

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

    // json family (Go function_json.go / function_bind.go)
    .{ .name = "get_json_field", .min_args = 2, .handler = fjson.getJsonField },
    .{ .name = "subscript", .min_args = 2, .handler = fjson.subscript },
    .{ .name = "json_extract", .min_args = 2, .handler = fjson.jsonExtract },
    .{ .name = "json_extract_scalar", .min_args = 2, .handler = fjson.jsonExtractScalar },
    .{ .name = "json_extract_array", .min_args = 2, .handler = fjson.jsonExtractArray },
    .{ .name = "json_extract_string_array", .min_args = 2, .handler = fjson.jsonExtractStringArray },
    .{ .name = "json_query", .min_args = 2, .handler = fjson.jsonQuery },
    .{ .name = "json_value", .min_args = 2, .handler = fjson.jsonValue },
    .{ .name = "json_query_array", .min_args = 2, .handler = fjson.jsonQueryArray },
    .{ .name = "json_value_array", .min_args = 2, .handler = fjson.jsonValueArray },
    .{ .name = "parse_json", .min_args = 1, .handler = fjson.parseJsonFn },
    .{ .name = "to_json", .min_args = 1, .handler = fjson.toJson },
    .{ .name = "to_json_string", .min_args = 1, .handler = fjson.toJsonString },
    .{ .name = "json_type", .min_args = 1, .handler = fjson.jsonType },
    .{ .name = "bool", .min_args = 1, .handler = fjson.jsonBool },
    .{ .name = "int64", .min_args = 1, .handler = fjson.jsonInt64 },
    .{ .name = "float64", .min_args = 1, .handler = fjson.jsonFloat64 },
    .{ .name = "double", .min_args = 2, .handler = fjson.jsonDouble },

    // interval family (Go function_interval.go)
    .{ .name = "interval", .min_args = 2, .handler = fintv.interval },
    .{ .name = "make_interval", .min_args = 6, .handler = fintv.makeInterval },
    .{ .name = "justify_days", .min_args = 1, .handler = fintv.justifyDaysFn },
    .{ .name = "justify_hours", .min_args = 1, .handler = fintv.justifyHoursFn },
    .{ .name = "justify_interval", .min_args = 1, .handler = fintv.justifyIntervalFn },
};
