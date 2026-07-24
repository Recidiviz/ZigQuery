//! Port of go-zetasqlite internal/function_aggregate_option.go.
//!
//! Aggregate modifiers (DISTINCT / IGNORE NULLS / LIMIT / ORDER BY /
//! HAVING MAX|MIN) travel from the transformer to the aggregate UDFs as
//! ordinary string arguments produced by the scalar functions
//! zetasqlite_distinct() / zetasqlite_limit(n) / zetasqlite_order_by(v, asc) /
//! zetasqlite_ignore_nulls() / zetasqlite_having_max|min(v). Each produces a
//! JSON marker string ({"type":"aggregate_*","value":...}) that the
//! Aggregator's Step recognizes and strips from the argument list
//! (parseAggregateOptions), exactly like Go.
//!
//! Deviation from Go (both sides owned by this file, so lossless): where Go
//! embeds the payload Value with encoding/json marshaling (lossy for e.g.
//! dates), we embed base64(binary codec v1) so every foundation Value kind
//! round-trips exactly. The surrounding JSON structure matches Go
//! byte-for-byte otherwise, and parsing accepts only what the producers
//! below emit.

const std = @import("std");
const bind = @import("bind.zig");
const codec = @import("../codec_binary.zig");

pub const Value = bind.Value;
pub const Error = bind.Error;

// Go AggregatorFuncOptionType constants.
pub const type_distinct = "aggregate_distinct";
pub const type_limit = "aggregate_limit";
pub const type_order_by = "aggregate_order_by";
pub const type_ignore_nulls = "aggregate_ignore_nulls";
pub const type_having_max = "aggregate_having_max";
pub const type_having_min = "aggregate_having_min";

const marker_prefix = "{\"type\":\"aggregate_";

/// Go AggregateOrderBy: one per zetasqlite_order_by argument, carrying the
/// (per-row) sort key value.
pub const AggregateOrderBy = struct {
    value: Value,
    is_asc: bool,
};

pub const HavingKind = enum { max, min };

/// Go AggregateHavingModifier.
pub const AggregateHavingModifier = struct {
    kind: HavingKind,
    value: Value,
};

/// Go AggregatorOption.
pub const AggregatorOption = struct {
    distinct: bool = false,
    ignore_nulls: bool = false,
    limit: ?i64 = null,
    order_by: []const *AggregateOrderBy = &.{},
    having_modifier: ?*AggregateHavingModifier = null,
};

// ----------------------------------------------------------------------
// Producers (Go DISTINCT()/LIMIT()/IGNORE_NULLS()/ORDER_BY()/HAVING_*()).
// Each returns a StringValue holding the JSON marker.
// ----------------------------------------------------------------------

pub fn DISTINCT(alloc: std.mem.Allocator) Error!Value {
    return .{ .string = try alloc.dupe(
        u8,
        "{\"type\":\"aggregate_distinct\",\"value\":null}",
    ) };
}

pub fn IGNORE_NULLS(alloc: std.mem.Allocator) Error!Value {
    return .{ .string = try alloc.dupe(
        u8,
        "{\"type\":\"aggregate_ignore_nulls\",\"value\":null}",
    ) };
}

pub fn LIMIT(alloc: std.mem.Allocator, limit: i64) Error!Value {
    return .{ .string = try std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"aggregate_limit\",\"value\":{d}}}",
        .{limit},
    ) };
}

pub fn ORDER_BY(alloc: std.mem.Allocator, value: Value, is_asc: bool) Error!Value {
    const embedded = try embedValue(alloc, value);
    return .{ .string = try std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"aggregate_order_by\",\"value\":{{\"value\":\"{s}\",\"isAsc\":{s}}}}}",
        .{ embedded, if (is_asc) "true" else "false" },
    ) };
}

pub fn HAVING_MAX(alloc: std.mem.Allocator, value: Value) Error!Value {
    return havingMarker(alloc, type_having_max, value);
}

pub fn HAVING_MIN(alloc: std.mem.Allocator, value: Value) Error!Value {
    return havingMarker(alloc, type_having_min, value);
}

fn havingMarker(alloc: std.mem.Allocator, comptime type_name: []const u8, value: Value) Error!Value {
    const embedded = try embedValue(alloc, value);
    return .{ .string = try std.fmt.allocPrint(
        alloc,
        "{{\"type\":\"" ++ type_name ++ "\",\"value\":\"{s}\"}}",
        .{embedded},
    ) };
}

/// base64(binary codec v1) of any foundation Value (NULL included).
fn embedValue(alloc: std.mem.Allocator, v: Value) Error![]u8 {
    const bin = try codec.encodeBinaryValue(alloc, v);
    defer alloc.free(bin);
    const encoder = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, encoder.calcSize(bin.len));
    _ = encoder.encode(out, bin);
    return out;
}

fn parseEmbedded(alloc: std.mem.Allocator, b64: []const u8) Error!Value {
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(b64) catch return error.CorruptData;
    const bin = try alloc.alloc(u8, n);
    defer alloc.free(bin);
    decoder.decode(bin, b64) catch return error.CorruptData;
    return codec.decodeBinaryValue(alloc, bin);
}

// ----------------------------------------------------------------------
// parseAggregateOptions (Go parseAggregateOptions): splits marker strings
// out of the raw argument list.
// ----------------------------------------------------------------------

pub const ParsedArgs = struct {
    values: []Value,
    opt: *AggregatorOption,
};

pub fn parseAggregateOptions(alloc: std.mem.Allocator, args: []const Value) Error!ParsedArgs {
    const opt = try alloc.create(AggregatorOption);
    opt.* = .{};

    var filtered: std.ArrayList(Value) = .empty;
    var order_by: std.ArrayList(*AggregateOrderBy) = .empty;

    for (args) |arg| {
        // Go tries arg.ToString() + json.Unmarshal on every arg and keeps
        // args that fail either step; only marker-shaped strings qualify.
        if (arg != .string or !std.mem.startsWith(u8, arg.string, marker_prefix)) {
            try filtered.append(alloc, arg);
            continue;
        }
        if (try applyOption(alloc, arg.string, opt, &order_by)) continue;
        try filtered.append(alloc, arg);
    }

    opt.order_by = try order_by.toOwnedSlice(alloc);
    return .{ .values = try filtered.toOwnedSlice(alloc), .opt = opt };
}

/// Parses one marker string; returns false when it is not a recognized
/// option (the arg then stays in the filtered list, like Go's default case).
fn applyOption(
    alloc: std.mem.Allocator,
    s: []const u8,
    opt: *AggregatorOption,
    order_by: *std.ArrayList(*AggregateOrderBy),
) Error!bool {
    // s = {"type":"aggregate_<kind>","value":<payload>}  (fixed field order:
    // this parser only needs to read what the producers above emit).
    var rest = s["{\"type\":\"".len..];
    const type_end = std.mem.indexOfScalar(u8, rest, '"') orelse return false;
    const type_name = rest[0..type_end];
    rest = rest[type_end..];

    if (std.mem.eql(u8, type_name, type_distinct)) {
        opt.distinct = true;
        return true;
    }
    if (std.mem.eql(u8, type_name, type_ignore_nulls)) {
        opt.ignore_nulls = true;
        return true;
    }

    if (!std.mem.startsWith(u8, rest, "\",\"value\":")) return false;
    var payload = rest["\",\"value\":".len..];
    if (payload.len < 1 or payload[payload.len - 1] != '}') return false;
    payload = payload[0 .. payload.len - 1];

    if (std.mem.eql(u8, type_name, type_limit)) {
        opt.limit = std.fmt.parseInt(i64, payload, 10) catch return false;
        return true;
    }
    if (std.mem.eql(u8, type_name, type_order_by)) {
        // payload = {"value":"B64","isAsc":true|false}
        if (!std.mem.startsWith(u8, payload, "{\"value\":\"")) return false;
        const b64_and_tail = payload["{\"value\":\"".len..];
        const b64_end = std.mem.indexOfScalar(u8, b64_and_tail, '"') orelse return false;
        const tail = b64_and_tail[b64_end..];
        const is_asc = if (std.mem.eql(u8, tail, "\",\"isAsc\":true}"))
            true
        else if (std.mem.eql(u8, tail, "\",\"isAsc\":false}"))
            false
        else
            return false;
        const item = try alloc.create(AggregateOrderBy);
        item.* = .{
            .value = try parseEmbedded(alloc, b64_and_tail[0..b64_end]),
            .is_asc = is_asc,
        };
        try order_by.append(alloc, item);
        return true;
    }
    if (std.mem.eql(u8, type_name, type_having_max) or
        std.mem.eql(u8, type_name, type_having_min))
    {
        if (payload.len < 2 or payload[0] != '"' or payload[payload.len - 1] != '"') return false;
        const modifier = try alloc.create(AggregateHavingModifier);
        modifier.* = .{
            .kind = if (std.mem.eql(u8, type_name, type_having_max)) .max else .min,
            .value = try parseEmbedded(alloc, payload[1 .. payload.len - 1]),
        };
        opt.having_modifier = modifier;
        return true;
    }
    return false;
}

// ----------------------------------------------------------------------
// Scalar bind handlers (Go bindDistinct/bindLimit/bindOrderBy/
// bindIgnoreNulls/bindHavingMax/bindHavingMin). Registered by
// aggregate.zig as zetasqlite_distinct etc.
// ----------------------------------------------------------------------

pub fn bindDistinct(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 0) {
        return bind.fail("DISTINCT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    }
    return DISTINCT(alloc);
}

pub fn bindLimit(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1) {
        return bind.fail("LIMIT: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    }
    return LIMIT(alloc, try args[0].toInt64());
}

pub fn bindIgnoreNulls(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 0) {
        return bind.fail("IGNORE_NULLS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    }
    return IGNORE_NULLS(alloc);
}

pub fn bindOrderBy(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2) {
        return bind.fail("ORDER_BY: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    }
    return ORDER_BY(alloc, args[0], try args[1].toBool());
}

pub fn bindHavingMax(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1) {
        return bind.fail("HAVING_MAX: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    }
    return HAVING_MAX(alloc, args[0]);
}

pub fn bindHavingMin(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1) {
        return bind.fail("HAVING_MIN: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    }
    return HAVING_MIN(alloc, args[0]);
}

/// The scalar-function table registered alongside the aggregates. Names get
/// the zetasqlite_ / zetasqlite_safe_ prefixes exactly like Go's normalFuncs
/// entries for these six functions.
pub const option_func_table = [_]bind.FuncInfo{
    .{ .name = "distinct", .handler = bindDistinct },
    .{ .name = "limit", .handler = bindLimit },
    .{ .name = "order_by", .handler = bindOrderBy },
    .{ .name = "ignore_nulls", .handler = bindIgnoreNulls },
    .{ .name = "having_max", .handler = bindHavingMax },
    .{ .name = "having_min", .handler = bindHavingMin },
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const value_mod = bind.value_mod;

test "producers emit Go-shaped markers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const d = try DISTINCT(alloc);
    try testing.expectEqualStrings("{\"type\":\"aggregate_distinct\",\"value\":null}", d.string);
    const l = try LIMIT(alloc, 42);
    try testing.expectEqualStrings("{\"type\":\"aggregate_limit\",\"value\":42}", l.string);
    const inl = try IGNORE_NULLS(alloc);
    try testing.expectEqualStrings("{\"type\":\"aggregate_ignore_nulls\",\"value\":null}", inl.string);
}

test "parseAggregateOptions round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = [_]Value{
        .{ .int = 7 },
        try DISTINCT(alloc),
        try ORDER_BY(alloc, .{ .string = "key" }, false),
        try LIMIT(alloc, 3),
        try IGNORE_NULLS(alloc),
        try HAVING_MAX(alloc, .{ .date = try value_mod.parseDateDays("2021-05-06") }),
        .{ .string = "plain arg" },
        .@"null",
    };
    const parsed = try parseAggregateOptions(alloc, &args);

    try testing.expectEqual(@as(usize, 3), parsed.values.len);
    try value_mod.expectValueEqual(.{ .int = 7 }, parsed.values[0]);
    try value_mod.expectValueEqual(.{ .string = "plain arg" }, parsed.values[1]);
    try value_mod.expectValueEqual(.@"null", parsed.values[2]);

    try testing.expect(parsed.opt.distinct);
    try testing.expect(parsed.opt.ignore_nulls);
    try testing.expectEqual(@as(?i64, 3), parsed.opt.limit);
    try testing.expectEqual(@as(usize, 1), parsed.opt.order_by.len);
    try testing.expect(!parsed.opt.order_by[0].is_asc);
    try value_mod.expectValueEqual(.{ .string = "key" }, parsed.opt.order_by[0].value);
    const having = parsed.opt.having_modifier.?;
    try testing.expectEqual(HavingKind.max, having.kind);
    try value_mod.expectValueEqual(
        .{ .date = try value_mod.parseDateDays("2021-05-06") },
        having.value,
    );
}

test "order_by markers preserve per-row NULL sort keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = [_]Value{
        .{ .int = 1 },
        try ORDER_BY(alloc, .@"null", true),
    };
    const parsed = try parseAggregateOptions(alloc, &args);
    try testing.expectEqual(@as(usize, 1), parsed.opt.order_by.len);
    try testing.expect(parsed.opt.order_by[0].is_asc);
    try value_mod.expectValueEqual(.@"null", parsed.opt.order_by[0].value);
}

test "non-marker strings stay in the argument list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = [_]Value{
        .{ .string = "{\"type\":\"aggregate_bogus\",\"value\":null}" },
        .{ .string = "{not json" },
    };
    const parsed = try parseAggregateOptions(alloc, &args);
    try testing.expectEqual(@as(usize, 2), parsed.values.len);
    try testing.expect(!parsed.opt.distinct);
}
