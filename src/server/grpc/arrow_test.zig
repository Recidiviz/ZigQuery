//! The Arrow encoder against the schema BigQuery actually sends.
//!
//! Kept beside `arrow.zig` for the same reason `avro_test.zig` is kept beside
//! `avro.zig`: the expectations here are transcribed from a recording, and a
//! re-recording should not disturb hand-written code.
//!
//! Avro's tests compare bytes against fastavro, an independent implementation.
//! No such comparison is possible here: two correct Arrow encoders produce
//! different flatbuffers for the same schema, so a byte golden from pyarrow
//! would fail for no reason. So the split is:
//!
//!   - the mapping — every type, name, nullability and annotation — is
//!     asserted below against `testdata/storage/bigquery_arrow_schema.txt`,
//!     read back out of the built `ArrowSchema` rather than out of the encoded
//!     message;
//!   - the encoding is asserted by nanoarrow itself, which validates the
//!     array against the schema before it will encode a batch — a struct whose
//!     children fell out of step with their parent, a list whose offsets do not
//!     reach its items, a value appended to a field of the wrong type, all fail
//!     at `Builder.encode`;
//!   - the semantics — that a real client decodes what this server sends and
//!     gets the values back — are gated by pyarrow against a running emulator,
//!     in `tools/storage_probe.py --endpoint=emulator --format=ARROW`.
//!
//! The mapping is where the recorded contract lives and where a mistake is
//! silent, which is why it gets the detailed tests.

const std = @import("std");
const arrow = @import("arrow.zig");
const zetasqlite = @import("zetasqlite");
const spec = zetasqlite.spec;
const value_mod = zetasqlite.value;
const Value = value_mod.Value;
const c = arrow.c;

const testing = std.testing;

/// A `spec.Type` for a leaf kind.
fn leaf(kind: zetasqlite.pb.TypeKind) spec.Type {
    return .{ .kind = @intFromEnum(kind) };
}

/// nanoarrow's rendering of one column's type, children included.
fn describe(schema: arrow.Schema, buf: []u8, column: usize) ![]const u8 {
    const path = [_]i32{@intCast(column)};
    const n = c.zq_arrow_schema_describe(schema.handle, &path, 1, buf.ptr, @intCast(buf.len));
    if (n < 0 or n >= buf.len) return error.DescribeFailed;
    return buf[0..@intCast(n)];
}

/// The metadata value for `key` on one column, or null when it carries none.
fn metadata(schema: arrow.Schema, buf: []u8, column: usize, key: [:0]const u8) !?[]const u8 {
    const path = [_]i32{@intCast(column)};
    const n = c.zq_arrow_schema_metadata(
        schema.handle,
        &path,
        1,
        key.ptr,
        buf.ptr,
        @intCast(buf.len),
    );
    if (n < 0) return null;
    if (n >= buf.len) return error.MetadataTruncated;
    return buf[0..@intCast(n)];
}

fn isNullable(schema: arrow.Schema, path: []const i32) !bool {
    const n = c.zq_arrow_schema_is_nullable(schema.handle, path.ptr, @intCast(path.len));
    if (n < 0) return error.PathFailed;
    return n != 0;
}

/// Builds a one-column schema and returns nanoarrow's rendering of that column.
fn typeOf(a: std.mem.Allocator, buf: []u8, typ: *const spec.Type) ![]const u8 {
    var schema = try arrow.buildSchema(a, &.{.{ .name = "c", .type = typ }});
    defer schema.deinit();
    return describe(schema, buf, 0);
}

// ---- the mapping, one type at a time ----

test "the primitive kinds map as BigQuery sends them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [256]u8 = undefined;

    const cases = [_]struct { kind: zetasqlite.pb.TypeKind, want: []const u8 }{
        .{ .kind = .TYPE_BOOL, .want = "bool" },
        .{ .kind = .TYPE_INT64, .want = "int64" },
        // Every integer width collapses to int64: BigQuery has one integer type
        // and the narrower kinds only exist inside the analyzer.
        .{ .kind = .TYPE_INT32, .want = "int64" },
        .{ .kind = .TYPE_UINT32, .want = "int64" },
        .{ .kind = .TYPE_UINT64, .want = "int64" },
        .{ .kind = .TYPE_ENUM, .want = "int64" },
        .{ .kind = .TYPE_DOUBLE, .want = "double" },
        // FLOAT is stored and returned as f64; the narrowness lives only in the
        // declared type, so double is what goes on the wire.
        .{ .kind = .TYPE_FLOAT, .want = "double" },
        .{ .kind = .TYPE_STRING, .want = "string" },
        .{ .kind = .TYPE_BYTES, .want = "binary" },
        .{ .kind = .TYPE_DATE, .want = "date32" },
        .{ .kind = .TYPE_TIME, .want = "time64('us')" },
        // The zone is the whole difference between this and DATETIME below.
        .{ .kind = .TYPE_TIMESTAMP, .want = "timestamp('us', 'UTC')" },
        // `name{storage}` is how nanoarrow renders an extension type. The four
        // annotated kinds are the reason this rendering is worth reading: the
        // storage alone would not tell a DATETIME from a zone-less timestamp.
        .{ .kind = .TYPE_DATETIME, .want = "google:sqlType:datetime{timestamp('us', '')}" },
        .{ .kind = .TYPE_JSON, .want = "google:sqlType:json{string}" },
        .{ .kind = .TYPE_GEOGRAPHY, .want = "google:sqlType:geography{string}" },
        .{
            .kind = .TYPE_INTERVAL,
            .want = "google:sqlType:interval{interval_month_day_nano}",
        },
        .{ .kind = .TYPE_NUMERIC, .want = "decimal128(38, 9)" },
        // 76, where the same column is decimal(77, 38) in Avro.
        .{ .kind = .TYPE_BIGNUMERIC, .want = "decimal256(76, 38)" },
    };
    for (cases) |case| {
        const t = leaf(case.kind);
        try testing.expectEqualStrings(case.want, try typeOf(a, &buf, &t));
    }
}

test "the four annotated kinds carry the extension names BigQuery sends" {
    // These are the only thing separating a DATETIME from a TIMESTAMP without a
    // zone, or a JSON column from a plain string. A client that reads them --
    // and google-cloud-bigquery does -- gets the wrong type without them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [256]u8 = undefined;

    const cases = [_]struct { kind: zetasqlite.pb.TypeKind, want: []const u8 }{
        .{ .kind = .TYPE_DATETIME, .want = "google:sqlType:datetime" },
        .{ .kind = .TYPE_JSON, .want = "google:sqlType:json" },
        .{ .kind = .TYPE_GEOGRAPHY, .want = "google:sqlType:geography" },
        .{ .kind = .TYPE_INTERVAL, .want = "google:sqlType:interval" },
    };
    for (cases) |case| {
        const t = leaf(case.kind);
        var schema = try arrow.buildSchema(a, &.{.{ .name = "c", .type = &t }});
        defer schema.deinit();
        try testing.expectEqualStrings(
            case.want,
            (try metadata(schema, &buf, 0, "ARROW:extension:name")).?,
        );
    }

    // GEOGRAPHY is the only one with parameters, and the encoding is the one
    // thing a reader needs to know about the string.
    const geo = leaf(.TYPE_GEOGRAPHY);
    var schema = try arrow.buildSchema(a, &.{.{ .name = "c", .type = &geo }});
    defer schema.deinit();
    try testing.expectEqualStrings(
        "{\"encoding\": \"WKT\"}",
        (try metadata(schema, &buf, 0, "ARROW:extension:metadata")).?,
    );

    // And a kind that is not annotated carries no annotation, rather than an
    // empty one -- an extension name a reader does not recognise is worse than
    // none at all.
    const str = leaf(.TYPE_STRING);
    var plain = try arrow.buildSchema(a, &.{.{ .name = "c", .type = &str }});
    defer plain.deinit();
    try testing.expectEqual(
        @as(?[]const u8, null),
        try metadata(plain, &buf, 0, "ARROW:extension:name"),
    );
}

test "nullability rides in the field flags, not in the type" {
    // Arrow's answer to what Avro spells `["null", T]`. The mode comes from the
    // table's metadata, and `read_service.outputColumns` is the single place it
    // is decided -- both encoders are handed the same `Column`.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [256]u8 = undefined;

    const t = leaf(.TYPE_INT64);
    var schema = try arrow.buildSchema(a, &.{
        .{ .name = "req", .type = &t, .nullable = false },
        .{ .name = "opt", .type = &t, .nullable = true },
    });
    defer schema.deinit();

    try testing.expect(!try isNullable(schema, &.{0}));
    try testing.expect(try isNullable(schema, &.{1}));
    // The type itself is identical either way -- which is the difference from
    // Avro, where the mode changes the schema text.
    try testing.expectEqualStrings("int64", try describe(schema, &buf, 0));
    try testing.expectEqualStrings("int64", try describe(schema, &buf, 1));
}

test "an ARRAY is a not-null list of a nullable item" {
    // Recorded: `c_array: list<item: int64> not null`, with the item nullable.
    // The NOT NULL is the same rule `avro.zig` spells as "no union here" -- a
    // REPEATED column that holds nothing is an empty array, not an absent one,
    // so there is no null to spell.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [256]u8 = undefined;

    var elem = leaf(.TYPE_INT64);
    var arr: spec.Type = .{
        .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_ARRAY),
        .element_type = &elem,
    };

    // Not null even when the column's own mode says nullable.
    var schema = try arrow.buildSchema(a, &.{.{ .name = "c", .type = &arr, .nullable = true }});
    defer schema.deinit();
    try testing.expectEqualStrings("list<item: int64>", try describe(schema, &buf, 0));
    try testing.expect(!try isNullable(schema, &.{0}));
    try testing.expect(try isNullable(schema, &.{ 0, 0 }));
}

test "a STRUCT keeps its field names and order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [256]u8 = undefined;

    var ta = leaf(.TYPE_INT64);
    var tb = leaf(.TYPE_STRING);
    var fa: spec.NameWithType = .{ .name = "a", .type = &ta };
    var fb: spec.NameWithType = .{ .name = "b", .type = &tb };
    var fields = [_]*spec.NameWithType{ &fa, &fb };
    var st: spec.Type = .{
        .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_STRUCT),
        .field_types = &fields,
    };

    var schema = try arrow.buildSchema(a, &.{.{ .name = "c", .type = &st }});
    defer schema.deinit();
    try testing.expectEqualStrings("struct<a: int64, b: string>", try describe(schema, &buf, 0));
    // Every struct field is nullable in BigQuery's schema, whatever the
    // column's own mode.
    try testing.expect(try isNullable(schema, &.{ 0, 0 }));
    try testing.expect(try isNullable(schema, &.{ 0, 1 }));
}

test "a RANGE is a struct of two bounds under a plain google:sqlType key" {
    // The one annotated type that uses a plain google:sqlType key rather than
    // ARROW:extension:name, and the value is lowercase where Avro's sqlType is
    // "RANGE". Both recorded.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [256]u8 = undefined;

    var elem = leaf(.TYPE_DATE);
    var rng: spec.Type = .{
        .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_RANGE),
        .element_type = &elem,
    };

    var schema = try arrow.buildSchema(a, &.{.{ .name = "c", .type = &rng }});
    defer schema.deinit();
    try testing.expectEqualStrings(
        "struct<start: date32, end: date32>",
        try describe(schema, &buf, 0),
    );
    try testing.expectEqualStrings("range", (try metadata(schema, &buf, 0, "google:sqlType")).?);
    // Not the key the other four use: a client looking for an extension name
    // here finds nothing, which is what BigQuery does too.
    try testing.expectEqual(
        @as(?[]const u8, null),
        try metadata(schema, &buf, 0, "ARROW:extension:name"),
    );
    // Both bounds nullable however the column was declared: null is how
    // UNBOUNDED is spelled.
    try testing.expect(try isNullable(schema, &.{ 0, 0 }));
    try testing.expect(try isNullable(schema, &.{ 0, 1 }));
}

test "a type with no Arrow mapping is an error, not a plausible wrong schema" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = leaf(.TYPE_PROTO);
    try testing.expectError(
        error.UnsupportedType,
        arrow.buildSchema(a, &.{.{ .name = "c", .type = &t }}),
    );

    // A RANGE over something that is not a date-like kind likewise: BigQuery has
    // no such type, so guessing a struct for it would be inventing one.
    var elem = leaf(.TYPE_INT64);
    var rng: spec.Type = .{
        .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_RANGE),
        .element_type = &elem,
    };
    try testing.expectError(
        error.UnsupportedType,
        arrow.buildSchema(a, &.{.{ .name = "c", .type = &rng }}),
    );
}

// ---- a whole row, schema and batch together ----

/// The 19 columns of `testdata/storage/bigquery_arrow_schema.txt`, built once so
/// the schema test and the row test cannot drift apart.
///
/// The same shape as `avro_test.zig`'s `FullRow`, with the two columns that
/// recording has and Avro's does not: a GEOGRAPHY, and an ARRAY of STRUCT.
const FullRow = struct {
    int: spec.Type = leaf(.TYPE_INT64),
    dbl: spec.Type = leaf(.TYPE_DOUBLE),
    boolean: spec.Type = leaf(.TYPE_BOOL),
    str: spec.Type = leaf(.TYPE_STRING),
    byt: spec.Type = leaf(.TYPE_BYTES),
    num: spec.Type = leaf(.TYPE_NUMERIC),
    bnum: spec.Type = leaf(.TYPE_BIGNUMERIC),
    date: spec.Type = leaf(.TYPE_DATE),
    dtm: spec.Type = leaf(.TYPE_DATETIME),
    time: spec.Type = leaf(.TYPE_TIME),
    ts: spec.Type = leaf(.TYPE_TIMESTAMP),
    js: spec.Type = leaf(.TYPE_JSON),
    geo: spec.Type = leaf(.TYPE_GEOGRAPHY),
    iv: spec.Type = leaf(.TYPE_INTERVAL),
    elem_date: spec.Type = leaf(.TYPE_DATE),
    elem_int: spec.Type = leaf(.TYPE_INT64),
    fa: spec.NameWithType = undefined,
    fb: spec.NameWithType = undefined,
    sfields: [2]*spec.NameWithType = undefined,
    fx: spec.NameWithType = undefined,
    fy: spec.NameWithType = undefined,
    xyfields: [2]*spec.NameWithType = undefined,
    rng: spec.Type = undefined,
    arr: spec.Type = undefined,
    st: spec.Type = undefined,
    xy: spec.Type = undefined,
    arr_st: spec.Type = undefined,
    cols: [19]arrow.Column = undefined,

    fn init(f: *FullRow) void {
        f.* = .{};
        f.fa = .{ .name = "a", .type = &f.int };
        f.fb = .{ .name = "b", .type = &f.str };
        f.sfields = .{ &f.fa, &f.fb };
        f.fx = .{ .name = "x", .type = &f.int };
        f.fy = .{ .name = "y", .type = &f.str };
        f.xyfields = .{ &f.fx, &f.fy };
        f.rng = .{
            .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_RANGE),
            .element_type = &f.elem_date,
        };
        f.arr = .{
            .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_ARRAY),
            .element_type = &f.elem_int,
        };
        f.st = .{
            .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_STRUCT),
            .field_types = &f.sfields,
        };
        f.xy = .{
            .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_STRUCT),
            .field_types = &f.xyfields,
        };
        f.arr_st = .{
            .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_ARRAY),
            .element_type = &f.xy,
        };
        f.cols = .{
            .{ .name = "c_req_int64", .type = &f.int, .nullable = false },
            .{ .name = "c_int64", .type = &f.int },
            .{ .name = "c_float64", .type = &f.dbl },
            .{ .name = "c_numeric", .type = &f.num },
            .{ .name = "c_bignumeric", .type = &f.bnum },
            .{ .name = "c_bool", .type = &f.boolean },
            .{ .name = "c_string", .type = &f.str },
            .{ .name = "c_bytes", .type = &f.byt },
            .{ .name = "c_date", .type = &f.date },
            .{ .name = "c_datetime", .type = &f.dtm },
            .{ .name = "c_time", .type = &f.time },
            .{ .name = "c_timestamp", .type = &f.ts },
            .{ .name = "c_json", .type = &f.js },
            .{ .name = "c_geography", .type = &f.geo },
            .{ .name = "c_interval", .type = &f.iv },
            .{ .name = "c_range_date", .type = &f.rng },
            .{ .name = "c_array", .type = &f.arr },
            .{ .name = "c_struct", .type = &f.st },
            .{ .name = "c_array_struct", .type = &f.arr_st },
        };
    }

    /// The row `testdata/storage/bigquery_arrow_batch.hex` carries, as the
    /// engine's own values.
    fn values(f: *const FullRow, a: std.mem.Allocator) ![19]Value {
        _ = f;
        return .{
            .{ .int = 7 },
            .{ .int = -2 },
            .{ .float = 1.5 },
            try value_mod.numericFromString(a, "1.2345", false),
            try value_mod.numericFromString(a, "-1.5", true),
            // A top-level BOOL arrives as .int; the declared type is what makes
            // it an Arrow bool.
            .{ .int = 1 },
            .{ .string = "hello" },
            .{ .bytes = "\x00\xff" },
            .{ .date = 20454 },
            .{ .datetime = try value_mod.parseDatetimeMicros("2026-01-01 12:00:00.123456") },
            .{ .time = try value_mod.parseTimeMicros("12:00:00.123456") },
            .{ .timestamp = 1767225600000123 },
            .{ .json = "{\"a\":1}" },
            .{ .string = "POINT(1 2)" },
            .{ .interval = try value_mod.parseIntervalValue("1-2 3 4:5:6") },
            value_mod.rangeValue(.date, 20454, 20485),
            try value_mod.arrayValue(a, &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } }),
            try value_mod.structValue(a, &.{ "a", "b" }, &.{ .{ .int = 1 }, .{ .string = "x" } }),
            try value_mod.arrayValue(a, &.{
                try value_mod.structValue(a, &.{ "x", "y" }, &.{ .{ .int = 1 }, .{ .string = "y" } }),
            }),
        };
    }
};

test "a whole schema matches the one BigQuery sent for the same columns" {
    // The gate for the mapping: every line here is transcribed from
    // testdata/storage/bigquery_arrow_schema.txt, which is what real BigQuery
    // returned for a table with one column of every type.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [512]u8 = undefined;

    var f: FullRow = undefined;
    f.init();

    var schema = try arrow.buildSchema(a, &f.cols);
    defer schema.deinit();

    const want = [_][]const u8{
        "int64",
        "int64",
        "double",
        "decimal128(38, 9)",
        "decimal256(76, 38)",
        "bool",
        "string",
        "binary",
        "date32",
        "google:sqlType:datetime{timestamp('us', '')}",
        "time64('us')",
        "timestamp('us', 'UTC')",
        "google:sqlType:json{string}",
        "google:sqlType:geography{string}",
        "google:sqlType:interval{interval_month_day_nano}",
        "struct<start: date32, end: date32>",
        "list<item: int64>",
        "struct<a: int64, b: string>",
        "list<item: struct<x: int64, y: string>>",
    };
    for (want, 0..) |w, i| {
        try testing.expectEqualStrings(w, try describe(schema, &buf, i));
    }

    // Only the first column is REQUIRED, and only the two lists are NOT NULL
    // for a reason of their own.
    for (f.cols, 0..) |col, i| {
        const is_list = col.type.typeKind() == .TYPE_ARRAY;
        const want_nullable = col.nullable and !is_list;
        try testing.expectEqual(want_nullable, try isNullable(schema, &.{@intCast(i)}));
    }
}

test "a whole row builds a batch nanoarrow will encode" {
    // nanoarrow validates the array against the schema before encoding: a
    // struct whose children fell out of step with their parent, a list whose
    // offsets do not reach its items, a value appended to the wrong field --
    // each fails here rather than inside somebody's client library.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: FullRow = undefined;
    f.init();

    var schema = try arrow.buildSchema(a, &f.cols);
    defer schema.deinit();
    var b = try arrow.Builder.init(schema, &f.cols);
    defer b.deinit();

    const vals = try f.values(a);
    try b.appendRow(&vals);
    try b.appendRow(&vals);
    try testing.expectEqual(@as(i64, 2), b.rowCount());

    const bytes = try b.encode();
    // An encapsulated message leads with the 0xFFFFFFFF continuation marker and
    // is padded to 8 bytes. Anything else is not a message a reader accepts.
    try testing.expect(bytes.len > 8);
    try testing.expectEqual(@as(usize, 0), bytes.len % 8);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, bytes[0..4]);
}

test "nulls reach every kind, including the nested ones" {
    // A null STRUCT has to append an empty element to each child, or the
    // children fall a row behind their parent and the batch will not encode.
    // The same for a null RANGE, whose children are two more fields.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: FullRow = undefined;
    f.init();

    var schema = try arrow.buildSchema(a, &f.cols);
    defer schema.deinit();
    var b = try arrow.Builder.init(schema, &f.cols);
    defer b.deinit();

    var nulls: [19]Value = undefined;
    // Column 0 is REQUIRED, so it is the one that cannot be null.
    nulls[0] = .{ .int = 0 };
    for (nulls[1..]) |*v| v.* = .null;
    try b.appendRow(&nulls);

    // Mixed with a full row, because a validity bitmap that only ever sees one
    // answer is not being tested.
    try b.appendRow(&try f.values(a));
    try testing.expectEqual(@as(i64, 2), b.rowCount());
    _ = try b.encode();
}

test "a null in a REQUIRED column has nowhere to go" {
    // The Arrow spelling of `avro.zig`'s "a NOT NULL column with a null in it
    // has no encoding": the validity bit the schema says is not there.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = leaf(.TYPE_INT64);
    const cols = [_]arrow.Column{.{ .name = "req", .type = &t, .nullable = false }};
    var schema = try arrow.buildSchema(a, &cols);
    defer schema.deinit();
    var b = try arrow.Builder.init(schema, &cols);
    defer b.deinit();

    try testing.expectError(error.TypeMismatch, b.appendRow(&.{.null}));
    // And a row of the wrong width, which would otherwise leave the columns at
    // different lengths and fail much later.
    try testing.expectError(error.TypeMismatch, b.appendRow(&.{ .{ .int = 1 }, .{ .int = 2 } }));
}

test "a null ARRAY is an empty list, not a null" {
    // The regression `avro.zig` carries in the other spelling: the field is NOT
    // NULL, so a null appended here would be a validity bit the schema has no
    // room for. An empty list is the same answer BigQuery gives.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var elem = leaf(.TYPE_INT64);
    var arr: spec.Type = .{
        .kind = @intFromEnum(zetasqlite.pb.TypeKind.TYPE_ARRAY),
        .element_type = &elem,
    };
    // Nullable at the column level, which is what makes this the interesting
    // case: the schema ignores that for an array.
    const cols = [_]arrow.Column{.{ .name = "c", .type = &arr, .nullable = true }};

    var schema = try arrow.buildSchema(a, &cols);
    defer schema.deinit();
    var b = try arrow.Builder.init(schema, &cols);
    defer b.deinit();

    try b.appendRow(&.{.null});
    try b.appendRow(&.{try value_mod.arrayValue(a, &.{ .{ .int = 1 }, .{ .int = 2 } })});
    try b.appendRow(&.{try value_mod.arrayValue(a, &.{})});
    try testing.expectEqual(@as(i64, 3), b.rowCount());
    _ = try b.encode();
}

test "a value that is not what its column declared is refused" {
    // Everything dispatches on the declared type, so a mismatch is a real
    // possibility rather than a theoretical one -- and appending a string to an
    // int64 builder would corrupt the buffer rather than fail.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = leaf(.TYPE_INT64);
    const cols = [_]arrow.Column{.{ .name = "c", .type = &t }};
    var schema = try arrow.buildSchema(a, &cols);
    defer schema.deinit();
    var b = try arrow.Builder.init(schema, &cols);
    defer b.deinit();

    try testing.expectError(error.TypeMismatch, b.appendRow(&.{.{ .string = "x" }}));

    // A DATE where a TIMESTAMP was declared: both are integers underneath, and
    // both are plausible, which is exactly why the units are checked.
    const ts = leaf(.TYPE_TIMESTAMP);
    const tcols = [_]arrow.Column{.{ .name = "c", .type = &ts }};
    var tschema = try arrow.buildSchema(a, &tcols);
    defer tschema.deinit();
    var tb = try arrow.Builder.init(tschema, &tcols);
    defer tb.deinit();
    try testing.expectError(error.TypeMismatch, tb.appendRow(&.{.{ .date = 20454 }}));
}

test "BIGNUMERIC's extremes are written raw, out of the declared precision" {
    // The field says decimal256(76, 38) because Arrow has no 77 to say -- 76 is
    // the format's maximum for 256 bits, and BIGNUMERIC's extremes are 77
    // unscaled digits. Real BigQuery declares the same 76 and writes the value
    // anyway; so does this. A precision check added here later would look like
    // a fix and would make the largest BIGNUMERIC unserveable, which is what
    // this test is here to stop. See docs/NUMERIC_FIDELITY.md.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = leaf(.TYPE_BIGNUMERIC);
    const cols = [_]arrow.Column{.{ .name = "bn", .type = &t }};
    var schema = try arrow.buildSchema(a, &cols);
    defer schema.deinit();
    var b = try arrow.Builder.init(schema, &cols);
    defer b.deinit();

    // +2^255-1 and -2^255, which is the whole of what i256 holds.
    const max = try value_mod.numericFromString(
        a,
        "578960446186580977117854925043439539266.34992332820282019728792003956564819967",
        true,
    );
    const min = try value_mod.numericFromString(
        a,
        "-578960446186580977117854925043439539266.34992332820282019728792003956564819968",
        true,
    );
    try testing.expectEqual(@as(i256, std.math.maxInt(i256)), max.numeric.unscaled);
    try testing.expectEqual(@as(i256, std.math.minInt(i256)), min.numeric.unscaled);

    try b.appendRow(&.{max});
    try b.appendRow(&.{min});
    try testing.expectEqual(@as(i64, 2), b.rowCount());
    _ = try b.encode();
}

test "a NUMERIC too large for decimal128 is refused rather than truncated" {
    // The 128-bit sibling of the case above, and the reason it is not the same
    // answer: an out-of-range value here is silently cut by the 16-byte write,
    // where a 256-bit one only exceeds a declared precision.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = leaf(.TYPE_NUMERIC);
    const cols = [_]arrow.Column{.{ .name = "n", .type = &t }};
    var schema = try arrow.buildSchema(a, &cols);
    defer schema.deinit();
    var b = try arrow.Builder.init(schema, &cols);
    defer b.deinit();

    // Reached by hand: `numericValue` rejects an out-of-range NUMERIC at
    // construction, so the only way to a decimal128 column holding one is a
    // value built as BIGNUMERIC and declared NUMERIC -- which is exactly the
    // mismatch the check is for.
    const big = try value_mod.numericFromString(
        a,
        "578960446186580977117854925043439539266.34992332820282019728792003956564819967",
        true,
    );
    try testing.expectError(error.TypeMismatch, b.appendRow(&.{big}));

    // And an in-range NUMERIC at its own extreme still goes through.
    const ok = try value_mod.numericFromString(
        a,
        "99999999999999999999999999999.999999999",
        false,
    );
    try b.appendRow(&.{ok});
    try testing.expectEqual(@as(i64, 1), b.rowCount());
}

test "byteCount grows with the rows, so a batch can be flushed by size" {
    // `read_service` flushes on it, and a counter that never moved would put a
    // whole table in one message.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = leaf(.TYPE_STRING);
    const cols = [_]arrow.Column{.{ .name = "c", .type = &t }};
    var schema = try arrow.buildSchema(a, &cols);
    defer schema.deinit();
    var b = try arrow.Builder.init(schema, &cols);
    defer b.deinit();

    const empty = b.byteCount();
    for (0..64) |_| try b.appendRow(&.{.{ .string = "0123456789abcdef" }});
    // The strings alone are 1 KiB, and the offsets another 256 bytes.
    try testing.expect(b.byteCount() >= empty + 64 * 16);
}
