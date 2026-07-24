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
