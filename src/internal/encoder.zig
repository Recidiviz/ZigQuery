//! Faithful port of go-zetasqlite internal/encoder.go (EncodeValue,
//! LiteralFromValue) and internal/decoder.go (DecodeValue).
//!
//! SQLite representation: Int/Float travel natively, Bool as INTEGER 0/1
//! (Go returns a bool that the driver binds as an integer), NULL as NULL,
//! and everything else as TEXT holding base64(binary codec v1).

const std = @import("std");
const value_mod = @import("value.zig");
const codec = @import("codec_binary.zig");

pub const Value = value_mod.Value;
pub const ValueError = value_mod.ValueError;

/// The value as it crosses the SQLite boundary (Go: driver.Value).
pub const SqliteRepr = union(enum) {
    @"null",
    int: i64,
    float: f64,
    text: []const u8,
};

/// Go EncodeValue: scalar kinds pass through natively; the rest become
/// base64(binary codec).
pub fn EncodeValue(alloc: std.mem.Allocator, v: Value) ValueError!SqliteRepr {
    switch (v) {
        .@"null" => return .@"null",
        .int => |i| return .{ .int = i },
        .float => |f| return .{ .float = f },
        // Go returns ToBool() (a Go bool); the sqlite driver stores it as
        // INTEGER 0/1, so encode it as an int directly.
        .bool => |b| return .{ .int = @intFromBool(b) },
        .safe => |p| return EncodeValue(alloc, p.*),
        else => {
            const bin = try codec.encodeBinaryValue(alloc, v);
            defer alloc.free(bin);
            return .{ .text = try base64Encode(alloc, bin) };
        },
    }
}

/// Go LiteralFromValue: renders a Value as a SQL literal for embedded query
/// text. Non-scalar values become a DOUBLE-quoted base64 string (SQLite
/// treats unknown double-quoted identifiers as string literals).
pub fn LiteralFromValue(alloc: std.mem.Allocator, v: Value) ValueError![]u8 {
    switch (v) {
        .@"null" => return alloc.dupe(u8, "null"),
        .int => |i| return std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| {
            var buf: [32]u8 = undefined;
            const s = value_mod.formatFloatGo(&buf, f);
            // Go: append ".0" to keep float context when the 'g' form has
            // neither '.' nor 'e' (e.g. "42" -> "42.0").
            if (std.mem.indexOfScalar(u8, s, '.') == null and
                std.mem.indexOfScalar(u8, s, 'e') == null)
            {
                return std.fmt.allocPrint(alloc, "{s}.0", .{s});
            }
            return alloc.dupe(u8, s);
        },
        .bool => |b| return alloc.dupe(u8, if (b) "true" else "false"),
        .safe => |p| return LiteralFromValue(alloc, p.*),
        else => {
            const bin = try codec.encodeBinaryValue(alloc, v);
            defer alloc.free(bin);
            const b64 = try base64Encode(alloc, bin);
            defer alloc.free(b64);
            return std.fmt.allocPrint(alloc, "\"{s}\"", .{b64});
        },
    }
}

/// Go DecodeValue: first-byte dispatch after base64-decoding TEXT values.
/// Legacy payloads are base64(JSON{header,body}) and begin with '{'; this
/// engine never produces them, so they surface error.Unimplemented.
pub fn DecodeValue(alloc: std.mem.Allocator, repr: SqliteRepr) ValueError!Value {
    switch (repr) {
        .@"null" => return Value.@"null",
        .int => |i| return Value{ .int = i },
        .float => |f| return Value{ .float = f },
        .text => |s| {
            const decoder = std.base64.standard.Decoder;
            const n = decoder.calcSizeForSlice(s) catch
                return error.CorruptData; // failed to decode value
            const decoded = try alloc.alloc(u8, n);
            defer alloc.free(decoded);
            decoder.decode(decoded, s) catch return error.CorruptData;
            if (decoded.len > 0 and decoded[0] == '{') {
                // Legacy base64(JSON) layout: never produced by this engine.
                return error.Unimplemented;
            }
            return codec.decodeBinaryValue(alloc, decoded);
        },
    }
}

fn base64Encode(alloc: std.mem.Allocator, data: []const u8) ValueError![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try alloc.alloc(u8, encoder.calcSize(data.len));
    _ = encoder.encode(out, data);
    return out;
}

// ----------------------------------------------------------------------
// castValue: stub only (the real CastValue port arrives with the spec/type
// milestone). Same-kind casts pass through; everything else is deferred.
// ----------------------------------------------------------------------

pub const TypeKind = enum {
    int64,
    bool,
    double,
    string,
    bytes,
    date,
    array,
    struct_,
    // Deferred kinds (present for completeness).
    numeric,
    bignumeric,
    json,
    datetime,
    time,
    timestamp,
    interval,
};

pub fn castValue(alloc: std.mem.Allocator, v: Value, to: TypeKind) ValueError!Value {
    _ = alloc;
    // Go CastValue: nil input stays nil regardless of target type.
    if (v == .@"null") return Value.@"null";
    const inner = if (v == .safe) v.safe.* else v;
    const same = switch (to) {
        .int64 => inner == .int,
        .bool => inner == .bool,
        .double => inner == .float,
        .string => inner == .string,
        .bytes => inner == .bytes,
        .date => inner == .date,
        .array => inner == .array,
        .struct_ => inner == .struct_,
        else => false,
    };
    if (same) return v;
    return error.Unimplemented;
}

// ----------------------------------------------------------------------
// valueFromProto: port of encoder.go ValueFromZetaSQLValue + the
// *FromLiteral helpers, reading the decoded ValueProto/TypeProto instead of
// go-googlesql's Value accessors. Foundation kinds only; timestamp /
// numeric / json / datetime / time / interval / enum are deferred.
// ----------------------------------------------------------------------

const pb = @import("../proto/resolved_ast.zig");

/// Go ValueFromZetaSQLValue. A ValueProto with no oneof member set is the
/// NULL literal (Go: v.IsNull() -> nil Value).
pub fn valueFromProto(
    alloc: std.mem.Allocator,
    value_proto: *const pb.ValueProto,
    type_proto: *const pb.TypeProto,
) ValueError!Value {
    const v = value_proto.value orelse return Value.@"null";
    const kind = type_proto.type_kind orelse return error.Unimplemented;
    switch (kind) {
        // Go: intValueFromLiteral over the SQL literal; here the proto
        // carries the native value. Uint64 beyond int64 range would have
        // failed Go's ParseInt too.
        .TYPE_INT32 => return .{ .int = switch (v) {
            .int32_value => |x| @as(i64, x),
            else => return error.CorruptData,
        } },
        .TYPE_INT64 => return .{ .int = switch (v) {
            .int64_value => |x| x,
            else => return error.CorruptData,
        } },
        .TYPE_UINT32 => return .{ .int = switch (v) {
            .uint32_value => |x| @as(i64, x),
            else => return error.CorruptData,
        } },
        .TYPE_UINT64 => return .{ .int = switch (v) {
            .uint64_value => |x| std.math.cast(i64, x) orelse return error.FailedConversion,
            else => return error.CorruptData,
        } },
        .TYPE_BOOL => return .{ .bool = switch (v) {
            .bool_value => |x| x,
            else => return error.CorruptData,
        } },
        .TYPE_FLOAT => return .{ .float = switch (v) {
            .float_value => |x| @as(f64, x),
            else => return error.CorruptData,
        } },
        .TYPE_DOUBLE => return .{ .float = switch (v) {
            .double_value => |x| x,
            else => return error.CorruptData,
        } },
        .TYPE_STRING => return .{ .string = switch (v) {
            .string_value => |x| x,
            else => return error.CorruptData,
        } },
        .TYPE_BYTES => return .{ .bytes = switch (v) {
            .bytes_value => |x| x,
            else => return error.CorruptData,
        } },
        // Go dateValueFromLiteral: civil days since the Unix epoch.
        .TYPE_DATE => return .{ .date = switch (v) {
            .date_value => |days| @as(i64, days),
            else => return error.CorruptData,
        } },
        .TYPE_ARRAY => {
            // Go arrayValueFromLiteral. NULL arrays were handled by the
            // oneof-not-set case above; this is a present (possibly empty)
            // array.
            const arr = switch (v) {
                .array_value => |x| x,
                else => return error.CorruptData,
            };
            const arr_type = type_proto.array_type orelse return error.CorruptData;
            const elem_type = arr_type.element_type orelse return error.CorruptData;
            const values = try alloc.alloc(Value, arr.element.len);
            for (arr.element, 0..) |elem, i| {
                values[i] = try valueFromProto(alloc, elem, elem_type);
            }
            return value_mod.arrayValue(alloc, values);
        },
        .TYPE_STRUCT => {
            // Go structValueFromLiteral: field names from the struct type.
            const st = switch (v) {
                .struct_value => |x| x,
                else => return error.CorruptData,
            };
            const struct_type = type_proto.struct_type orelse return error.CorruptData;
            if (struct_type.field.len != st.field.len) return error.CorruptData;
            const keys = try alloc.alloc([]const u8, st.field.len);
            const values = try alloc.alloc(Value, st.field.len);
            for (st.field, 0..) |field, i| {
                const sf = struct_type.field[i];
                keys[i] = sf.field_name orelse "";
                const field_type = sf.field_type orelse return error.CorruptData;
                values[i] = try valueFromProto(alloc, field, field_type);
            }
            return value_mod.structValue(alloc, keys, values);
        },
        // Deferred kinds (timestamp, numeric, bignumeric, json, datetime,
        // time, interval, enum, ...): Go supports them; this port defers
        // them with their Value kinds.
        else => return error.Unimplemented,
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "EncodeValue keeps scalars native" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(SqliteRepr.@"null", try EncodeValue(alloc, Value.@"null"));
    try testing.expectEqual(SqliteRepr{ .int = -7 }, try EncodeValue(alloc, Value{ .int = -7 }));
    try testing.expectEqual(SqliteRepr{ .float = 1.5 }, try EncodeValue(alloc, Value{ .float = 1.5 }));
    // Bool travels as INTEGER 0/1 (Go bool bound by the sqlite driver).
    try testing.expectEqual(SqliteRepr{ .int = 1 }, try EncodeValue(alloc, Value{ .bool = true }));
    try testing.expectEqual(SqliteRepr{ .int = 0 }, try EncodeValue(alloc, Value{ .bool = false }));
    // SafeValue encodes as its inner value.
    const safe = try value_mod.safeValue(alloc, Value{ .int = 3 });
    try testing.expectEqual(SqliteRepr{ .int = 3 }, try EncodeValue(alloc, safe));
}

test "EncodeValue base64-wraps non-scalar kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const repr = try EncodeValue(alloc, Value{ .string = "hello" });
    try testing.expect(repr == .text);
    // The text is valid base64 of the binary codec payload.
    const decoder = std.base64.standard.Decoder;
    const n = try decoder.calcSizeForSlice(repr.text);
    const decoded = try alloc.alloc(u8, n);
    try decoder.decode(decoded, repr.text);
    try testing.expectEqualSlices(u8, "\x04\x05hello", decoded);

    const arr = try value_mod.arrayValue(alloc, &.{ Value{ .int = 1 }, Value.@"null" });
    const arr_repr = try EncodeValue(alloc, arr);
    try testing.expect(arr_repr == .text);
}

test "DecodeValue(EncodeValue(v)) round trips foundation kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const identity_cases = [_]Value{
        Value.@"null",
        Value{ .int = 42 },
        Value{ .int = std.math.minInt(i64) },
        Value{ .float = -1.5 },
        Value{ .float = std.math.nan(f64) },
        Value{ .string = "héllo" },
        Value{ .string = "" },
        Value{ .bytes = "\x00\xff" },
        Value{ .date = try value_mod.parseDateDays("2021-03-04") },
        try value_mod.arrayValue(alloc, &.{
            Value{ .int = 1 },
            Value.@"null",
            try value_mod.structValue(alloc, &.{"k"}, &.{Value{ .string = "v" }}),
        }),
        try value_mod.structValue(
            alloc,
            &.{ "a", "b" },
            &.{ Value{ .float = 2.5 }, Value{ .bytes = "zz" } },
        ),
    };
    for (identity_cases) |v| {
        const decoded = try DecodeValue(alloc, try EncodeValue(alloc, v));
        try value_mod.expectValueEqual(v, decoded);
    }

    // Bool round-trips as INTEGER (exactly like the Go driver stack).
    const bool_decoded = try DecodeValue(alloc, try EncodeValue(alloc, Value{ .bool = true }));
    try value_mod.expectValueEqual(Value{ .int = 1 }, bool_decoded);
}

test "DecodeValue rejects legacy JSON payloads and bad base64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // base64("{...}") => legacy layout => Unimplemented.
    const legacy = try base64Encode(alloc, "{\"header\":\"StringValue\"}");
    try testing.expectError(error.Unimplemented, DecodeValue(alloc, .{ .text = legacy }));
    try testing.expectError(error.CorruptData, DecodeValue(alloc, .{ .text = "!!!not base64!!!" }));
}

test "LiteralFromValue formatting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("null", try LiteralFromValue(alloc, Value.@"null"));
    try testing.expectEqualStrings("42", try LiteralFromValue(alloc, Value{ .int = 42 }));
    try testing.expectEqualStrings("-9223372036854775808", try LiteralFromValue(alloc, Value{ .int = std.math.minInt(i64) }));
    try testing.expectEqualStrings("true", try LiteralFromValue(alloc, Value{ .bool = true }));
    try testing.expectEqualStrings("false", try LiteralFromValue(alloc, Value{ .bool = false }));

    // Float cases: Go strconv 'g' plus the ".0" float-context suffix.
    try testing.expectEqualStrings("42.0", try LiteralFromValue(alloc, Value{ .float = 42.0 }));
    try testing.expectEqualStrings("1.5", try LiteralFromValue(alloc, Value{ .float = 1.5 }));
    try testing.expectEqualStrings("1e+20", try LiteralFromValue(alloc, Value{ .float = 1e20 }));
    try testing.expectEqualStrings("0.0001", try LiteralFromValue(alloc, Value{ .float = 0.0001 }));
    try testing.expectEqualStrings("1e-05", try LiteralFromValue(alloc, Value{ .float = 0.00001 }));
    try testing.expectEqualStrings("100000.0", try LiteralFromValue(alloc, Value{ .float = 100000.0 }));
    try testing.expectEqualStrings("1e+06", try LiteralFromValue(alloc, Value{ .float = 1e6 }));
    try testing.expectEqualStrings("-0.0", try LiteralFromValue(alloc, Value{ .float = -0.0 }));

    // Non-scalar kinds become a DOUBLE-quoted base64 literal that decodes
    // back to the original value.
    const lit = try LiteralFromValue(alloc, Value{ .string = "hi" });
    try testing.expect(lit.len >= 2 and lit[0] == '"' and lit[lit.len - 1] == '"');
    const decoded = try DecodeValue(alloc, .{ .text = lit[1 .. lit.len - 1] });
    try value_mod.expectValueEqual(Value{ .string = "hi" }, decoded);

    // Dates use their "YYYY-MM-DD" binary form under the quotes.
    const date_lit = try LiteralFromValue(alloc, Value{ .date = 0 });
    const date_decoded = try DecodeValue(alloc, .{ .text = date_lit[1 .. date_lit.len - 1] });
    try value_mod.expectValueEqual(Value{ .date = 0 }, date_decoded);
}

test "castValue stub passes same-kind values through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try value_mod.expectValueEqual(Value{ .int = 5 }, try castValue(alloc, Value{ .int = 5 }, .int64));
    try value_mod.expectValueEqual(Value.@"null", try castValue(alloc, Value.@"null", .string));
    try testing.expectError(error.Unimplemented, castValue(alloc, Value{ .int = 5 }, .string));
    try testing.expectError(error.Unimplemented, castValue(alloc, Value{ .string = "1" }, .timestamp));
}

// ----------------------------------------------------------------------
// valueFromProto tests: real analyzer round-trips.
// ----------------------------------------------------------------------

const analyzer_ffi = @import("../analyzer_ffi.zig");

/// Analyzes `SELECT <literal>` and converts the first projected literal.
fn literalValueOf(alloc: std.mem.Allocator, sql: [:0]const u8) !Value {
    const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, sql, 0, "{}");
    const query = analyzed.node.node.?.resolved_statement_node.node.?.resolved_query_stmt_node;
    const scan = query.query.?.node.?.resolved_project_scan_node;
    const literal = scan.expr_list[0].expr.?.node.?.resolved_literal_node;
    const vwt = literal.value.?;
    return valueFromProto(alloc, vwt.value.?, vwt.@"type".?);
}

test "valueFromProto scalar literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try value_mod.expectValueEqual(Value{ .int = 42 }, try literalValueOf(alloc, "SELECT 42"));
    try value_mod.expectValueEqual(Value{ .bool = true }, try literalValueOf(alloc, "SELECT true"));
    try value_mod.expectValueEqual(Value{ .float = 1.5 }, try literalValueOf(alloc, "SELECT 1.5"));
    try value_mod.expectValueEqual(Value{ .string = "héllo" }, try literalValueOf(alloc, "SELECT 'héllo'"));
    try value_mod.expectValueEqual(Value{ .bytes = "ab\x00" }, try literalValueOf(alloc, "SELECT b'ab\\x00'"));
    // NULL literal: ValueProto with no oneof member set.
    try value_mod.expectValueEqual(Value.@"null", try literalValueOf(alloc, "SELECT NULL"));
}

test "valueFromProto date literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const expected_days = try value_mod.parseDateDays("2023-01-15");
    try value_mod.expectValueEqual(
        Value{ .date = expected_days },
        try literalValueOf(alloc, "SELECT DATE '2023-01-15'"),
    );
}

test "valueFromProto array literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try literalValueOf(alloc, "SELECT [1, 2, 3]");
    const expected = try value_mod.arrayValue(alloc, &.{
        Value{ .int = 1 }, Value{ .int = 2 }, Value{ .int = 3 },
    });
    try value_mod.expectValueEqual(expected, v);

    // Empty array is a present array with no elements, not NULL.
    const empty = try literalValueOf(alloc, "SELECT ARRAY<INT64>[]");
    try testing.expect(empty == .array);
    try testing.expectEqual(@as(usize, 0), empty.array.values.len);

    // NULL array is NULL.
    const null_array = try literalValueOf(alloc, "SELECT CAST(NULL AS ARRAY<INT64>)");
    try value_mod.expectValueEqual(Value.@"null", null_array);
}

test "valueFromProto struct literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try literalValueOf(alloc, "SELECT STRUCT(1 AS a, 'x' AS b)");
    const expected = try value_mod.structValue(
        alloc,
        &.{ "a", "b" },
        &.{ Value{ .int = 1 }, Value{ .string = "x" } },
    );
    try value_mod.expectValueEqual(expected, v);
}

test "valueFromProto defers non-foundation kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectError(
        error.Unimplemented,
        literalValueOf(alloc, "SELECT TIMESTAMP '2023-01-15 00:00:00+00'"),
    );
}
