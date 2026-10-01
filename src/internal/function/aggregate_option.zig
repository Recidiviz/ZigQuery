//! Port of go-zetasqlite internal/function_aggregate_option.go.
//!
//! Aggregate modifiers (DISTINCT / IGNORE NULLS / LIMIT / ORDER BY /
//! HAVING MAX|MIN) travel from the transformer to the aggregate UDFs as
//! ordinary string arguments produced by the scalar functions
//! zigquery_distinct() / zigquery_limit(n) / zigquery_order_by(v, asc) /
//! zigquery_ignore_nulls() / zigquery_having_max|min(v). Each produces a
//! JSON marker string ({"type":"aggregate_*","value":...}) that the
//! Aggregator's Step recognizes and strips from the argument list
//! (parseAggregateOptions), exactly like Go.
//!
//! Deviation from Go, both sides owned by this file: Go builds a JSON marker
//! string and embeds the payload Value with encoding/json marshaling, which is
//! lossy for e.g. dates. This uses a BYTES marker carrying the self-delimiting
//! codec directly — magic, a kind byte, then the payload.
//!
//! The JSON was worth dropping because it forced base64 on the payload: JSON
//! strings cannot hold arbitrary bytes, so every marker paid an encode and a
//! decode purely to survive the envelope. That cost is per row, not per query —
//! zigquery_order_by takes the sort key, so it runs once per row of every
//! ordered aggregate. Nothing observable depended on the JSON: a marker is
//! produced and consumed inside one statement, never stored (generated SQL
//! holds the *call*, not the marker), so no golden, corpus case or database
//! could ever see one.
// ephor:ignore-file ZT105

const std = @import("std");
const bind = @import("bind.zig");
const codec = @import("../codec_binary.zig");
const sortable = @import("../codec_sortable.zig");

pub const Value = bind.Value;
pub const Error = bind.Error;

/// Marks an argument as an option rather than data. A marker rides in the
/// argument list beside real values, so it has to be self-identifying, and any
/// in-band scheme has some collision surface: this one needs a BYTES value
/// whose first 12 bytes are exactly the magic.
const magic = "\x00\xffzqAGGOPT\xff\x00";

/// Go's AggregatorFuncOptionType, as a byte.
pub const Kind = enum(u8) {
    distinct = 1,
    ignore_nulls = 2,
    limit = 3,
    order_by = 4,
    having_max = 5,
    having_min = 6,
};

/// Go AggregateOrderBy: one per zigquery_order_by argument, carrying the
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
// Each returns a BytesValue holding the marker.
// ----------------------------------------------------------------------

/// `magic ++ kind ++ extra ++ codec(value)`, where a kind that carries no
/// value stops after `extra`.
fn marker(alloc: std.mem.Allocator, kind: Kind, extra: []const u8, value: ?Value) Error![]u8 {
    const encoded: []const u8 = if (value) |v| try codec.encodeBinaryValue(alloc, v) else "";
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(alloc, magic.len + 1 + extra.len + encoded.len);
    out.appendSliceAssumeCapacity(magic);
    out.appendAssumeCapacity(@backingInt(kind));
    out.appendSliceAssumeCapacity(extra);
    out.appendSliceAssumeCapacity(encoded);
    return out.toOwnedSlice(alloc);
}

pub fn DISTINCT(alloc: std.mem.Allocator) Error!Value {
    return .{ .bytes = try marker(alloc, .distinct, "", null) };
}

pub fn IGNORE_NULLS(alloc: std.mem.Allocator) Error!Value {
    return .{ .bytes = try marker(alloc, .ignore_nulls, "", null) };
}

pub fn LIMIT(alloc: std.mem.Allocator, limit: i64) Error!Value {
    var le: [8]u8 = undefined;
    std.mem.writeInt(i64, &le, limit, .little);
    return .{ .bytes = try marker(alloc, .limit, &le, null) };
}

pub fn ORDER_BY(alloc: std.mem.Allocator, value: Value, is_asc: bool) Error!Value {
    return .{ .bytes = try marker(alloc, .order_by, &.{@intFromBool(is_asc)}, value) };
}

pub fn HAVING_MAX(alloc: std.mem.Allocator, value: Value) Error!Value {
    return .{ .bytes = try marker(alloc, .having_max, "", value) };
}

pub fn HAVING_MIN(alloc: std.mem.Allocator, value: Value) Error!Value {
    return .{ .bytes = try marker(alloc, .having_min, "", value) };
}

// ----------------------------------------------------------------------
// parseAggregateOptions (Go parseAggregateOptions): splits markers out of the
// raw argument list.
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
        // Go tries arg.ToString() + json.Unmarshal on every arg and keeps args
        // that fail either step; only marker-shaped BYTES qualify here.
        if (arg != .bytes or !std.mem.startsWith(u8, arg.bytes, magic)) {
            try filtered.append(alloc, arg);
            continue;
        }
        if (try applyOption(alloc, arg.bytes[magic.len..], opt, &order_by)) continue;
        try filtered.append(alloc, arg);
    }

    opt.order_by = try order_by.toOwnedSlice(alloc);
    return .{ .values = try filtered.toOwnedSlice(alloc), .opt = opt };
}

/// Parses one marker body (everything after the magic); returns false when it
/// is not a recognized option, and the arg then stays in the filtered list like
/// Go's default case.
fn applyOption(
    alloc: std.mem.Allocator,
    body: []const u8,
    opt: *AggregatorOption,
    order_by: *std.ArrayList(*AggregateOrderBy),
) Error!bool {
    if (body.len < 1) return false;
    // An unknown byte means this is not our marker (or is from a build that
    // knows a kind this one does not), so it stays in the argument list.
    const kind = std.enums.fromInt(Kind, body[0]) orelse return false;
    const rest = body[1..];
    switch (kind) {
        .distinct => {
            opt.distinct = true;
            return true;
        },
        .ignore_nulls => {
            opt.ignore_nulls = true;
            return true;
        },
        .limit => {
            if (rest.len != 8) return false;
            opt.limit = std.mem.readInt(i64, rest[0..8], .little);
            return true;
        },
        .order_by => {
            if (rest.len < 1) return false;
            const item = try alloc.create(AggregateOrderBy);
            item.* = .{
                .value = try codec.decodeBinaryValue(alloc, rest[1..]),
                .is_asc = rest[0] != 0,
            };
            try order_by.append(alloc, item);
            return true;
        },
        .having_max, .having_min => {
            const modifier = try alloc.create(AggregateHavingModifier);
            modifier.* = .{
                .kind = if (kind == .having_max) .max else .min,
                .value = try codec.decodeBinaryValue(alloc, rest),
            };
            opt.having_modifier = modifier;
            return true;
        },
    }
}

// ----------------------------------------------------------------------
// Scalar bind handlers (Go bindDistinct/bindLimit/bindOrderBy/
// bindIgnoreNulls/bindHavingMax/bindHavingMin). Registered by
// aggregate.zig as zigquery_distinct etc.
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
/// the zigquery_ / zigquery_safe_ prefixes exactly like Go's normalFuncs
/// entries for these six functions.
pub const option_func_table = [_]bind.FuncInfo{
    .{ .name = "distinct", .handler = bindDistinct },
    .{ .name = "limit", .handler = bindLimit },
    .{ .name = "order_by", .handler = bindOrderBy },
    .{ .name = "ignore_nulls", .handler = bindIgnoreNulls },
    .{ .name = "having_max", .handler = bindHavingMax },
    .{ .name = "having_min", .handler = bindHavingMin },
};

/// The option kind a stored argument carries, or null when it is an ordinary value. Reads the
/// encoded bytes, so nothing has to be decoded to tell the two apart.
///
/// A marker is a BYTES value opening with `magic`, which the sortable codec stores as its tag
/// followed by the payload. The payload checks mirror `applyOption`: a body it would reject is
/// not a marker here either, and stays an argument.
pub fn rawMarkerKind(blob: []const u8) ?Kind {
    if (blob.len < 1 + magic.len + 1) return null;
    if (blob[0] != sortable.tag_bytes) return null;
    if (!std.mem.startsWith(u8, blob[1..], magic)) return null;
    const body = blob[1 + magic.len ..];
    const kind = std.enums.fromInt(Kind, body[0]) orelse return null;
    switch (kind) {
        .limit => if (body.len - 1 != 8) return null,
        .order_by => if (body.len - 1 < 1) return null,
        else => {},
    }
    return kind;
}

// ----------------------------------------------------------------------
// DISTINCT keying
// ----------------------------------------------------------------------

/// A byte string equal for exactly the values DISTINCT puts in one group.
///
/// The self-delimiting codec is canonical and carries a kind tag, so byte equality is value
/// equality across every kind, NULL (`bin_tag_null`) and nested ARRAY/STRUCT included — which
/// is the element-wise rule data-types.md#group_with_arrays and #group_with_structs describe.
///
/// Signed zero is the one value the codec cannot answer for: -0.0 and 0.0 are one group
/// (data-types.md#grouping-with-floating-point-types) and two f64 bit patterns. It is
/// normalised here. A float nested inside an ARRAY or STRUCT keeps its own bits, since reaching
/// it means rebuilding the value tree.
///
/// NaN needs no arm: SQLite stores it as NULL, so it never arrives as a float.
pub fn groupingKey(alloc: std.mem.Allocator, v: Value) Error![]const u8 {
    const normalised = switch (v) {
        .float => |f| Value{ .float = if (f == 0) 0 else f },
        else => v,
    };
    var buf: std.ArrayList(u8) = .empty;
    try codec.appendBinaryValue(&buf, alloc, normalised);
    return buf.toOwnedSlice(alloc);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const value_mod = bind.value_mod;

test "producers emit magic-prefixed BYTES markers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // BYTES, not STRING: the payload is raw codec bytes, which is the whole
    // point — a JSON envelope would force base64 back on, per row.
    const d = try DISTINCT(alloc);
    try testing.expect(d == .bytes);
    try testing.expectEqualSlices(u8, magic ++ "\x01", d.bytes);
    try testing.expectEqualSlices(u8, magic ++ "\x02", (try IGNORE_NULLS(alloc)).bytes);
    try testing.expectEqualSlices(
        u8,
        magic ++ "\x03" ++ "\x2a\x00\x00\x00\x00\x00\x00\x00",
        (try LIMIT(alloc, 42)).bytes,
    );

    // A payload with a NUL and a 0xff byte survives, which is exactly what the
    // JSON envelope could not carry without escaping or base64.
    const hostile = Value{ .bytes = "\x00\xff\x00" };
    const rt = try parseAggregateOptions(alloc, &.{try HAVING_MAX(alloc, hostile)});
    try value_mod.expectValueEqual(hostile, rt.opt.having_modifier.?.value);
}

test "a BYTES value that is not a marker stays an argument" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Detection is in-band, so the near misses matter: ordinary BYTES, a
    // prefix of the magic, and the magic followed by a kind byte nothing
    // claims. None may be swallowed as an option.
    const near = [_]Value{
        .{ .bytes = "plain" },
        .{ .bytes = magic[0 .. magic.len - 1] },
        .{ .bytes = magic ++ "\x7f" },
        .{ .string = magic },
    };
    const parsed = try parseAggregateOptions(alloc, &near);
    try testing.expectEqual(near.len, parsed.values.len);
    try testing.expect(!parsed.opt.distinct);
    try testing.expect(parsed.opt.limit == null);
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
        .null,
    };
    const parsed = try parseAggregateOptions(alloc, &args);

    try testing.expectEqual(@as(usize, 3), parsed.values.len);
    try value_mod.expectValueEqual(.{ .int = 7 }, parsed.values[0]);
    try value_mod.expectValueEqual(.{ .string = "plain arg" }, parsed.values[1]);
    try value_mod.expectValueEqual(.null, parsed.values[2]);

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
        try ORDER_BY(alloc, .null, true),
    };
    const parsed = try parseAggregateOptions(alloc, &args);
    try testing.expectEqual(@as(usize, 1), parsed.opt.order_by.len);
    try testing.expect(parsed.opt.order_by[0].is_asc);
    try value_mod.expectValueEqual(.null, parsed.opt.order_by[0].value);
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
