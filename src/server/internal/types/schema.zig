//! Port of bigquery-emulator types/types.go
//! TableFieldSchemaFromZetaSQLType (types.go:383) and BigQueryTypeName.
//!
//! Differences from Go, by design:
//! - No JSON round trip. Go reaches the column type via
//!   `Rows.ColumnTypeDatabaseTypeName`, which is literally
//!   `json.Marshal(internal.Type)` (go-zetasqlite internal/rows.go:38-41),
//!   immediately unmarshalled again by `UnmarshalDatabaseTypeName`
//!   (column.go:11). The Zig driver hands back the `*spec.Type` directly.
//!
//! The REST API uses BigQuery's **legacy** type names — INTEGER, FLOAT,
//! BOOLEAN, RECORD — not the standard-SQL spellings (INT64, FLOAT64, BOOL,
//! STRUCT) that `spec.bigQueryTypeName` produces for CREATE FUNCTION text.
//! Confirmed against the Go emulator; see testdata/golden.json.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const spec = zetasqlite.spec;
const pb = zetasqlite.pb;
const errors = @import("../../error.zig");

/// Legacy BigQuery type name for a leaf kind. STRUCT/ARRAY are handled by the
/// caller, which unwraps them into `fields` / `mode`.
pub fn legacyTypeName(k: pb.TypeKind) []const u8 {
    return switch (k) {
        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64 => "INTEGER",
        .TYPE_BOOL => "BOOLEAN",
        .TYPE_FLOAT, .TYPE_DOUBLE => "FLOAT",
        .TYPE_STRING => "STRING",
        .TYPE_BYTES => "BYTES",
        .TYPE_DATE => "DATE",
        .TYPE_DATETIME => "DATETIME",
        .TYPE_TIME => "TIME",
        .TYPE_TIMESTAMP => "TIMESTAMP",
        .TYPE_NUMERIC => "NUMERIC",
        .TYPE_BIGNUMERIC => "BIGNUMERIC",
        .TYPE_JSON => "JSON",
        .TYPE_INTERVAL => "INTERVAL",
        .TYPE_GEOGRAPHY => "GEOGRAPHY",
        .TYPE_STRUCT => "RECORD",
        else => "STRING",
    };
}

/// Emits one TableFieldSchema object.
///
/// Keys are written in the order Go's encoding/json produces for
/// bigqueryv2.TableFieldSchema — `fields, mode, name, type` — so responses
/// compare byte-for-byte with the Go emulator.
pub fn writeField(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    t: *const spec.Type,
) std.mem.Allocator.Error!void {
    // ARRAY<T> is not a type of its own on the wire: the element type is
    // hoisted and the field is marked REPEATED.
    const repeated = t.isArray();
    const elem: *const spec.Type = if (repeated) (t.element_type orelse t) else t;

    try out.append(arena, '{');
    var need_comma = false;

    if (elem.isStruct()) {
        try out.appendSlice(arena, "\"fields\":[");
        for (elem.field_types, 0..) |f, i| {
            if (i > 0) try out.append(arena, ',');
            try writeField(arena, out, f.name, f.type orelse elem);
        }
        try out.append(arena, ']');
        need_comma = true;
    }

    if (repeated) {
        if (need_comma) try out.append(arena, ',');
        try out.appendSlice(arena, "\"mode\":\"REPEATED\"");
        need_comma = true;
    }

    if (need_comma) try out.append(arena, ',');
    try out.appendSlice(arena, "\"name\":");
    try errors.writeJsonString(arena, out, name);

    try out.appendSlice(arena, ",\"type\":");
    try errors.writeJsonString(arena, out, legacyTypeName(elem.typeKind()));

    try out.append(arena, '}');
}

/// Emits the `schema` object: {"fields":[...]}.
pub fn writeSchema(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cols: []const zetasqlite.driver.OutputColumn,
) !void {
    try out.appendSlice(arena, "{\"fields\":[");
    for (cols, 0..) |col, i| {
        if (i > 0) try out.append(arena, ',');
        try writeField(arena, out, col.name, col.type);
    }
    try out.appendSlice(arena, "]}");
}

const testing = std.testing;

/// Runs `sql` through the engine and returns its serialized schema, so tests
/// assert against real analyzer output rather than hand-built types.
fn schemaOf(arena: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var db = try zetasqlite.driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    var rows = try db.query(sql, &.{}, .{});
    defer rows.deinit();

    var out: std.ArrayList(u8) = .empty;
    try writeSchema(arena, &out, rows.columnTypes());
    return out.toOwnedSlice(arena);
}

test "scalar schema uses legacy type names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // testdata/golden.json: scalar_int, scalar_bool, floats
    try testing.expectEqualStrings(
        \\{"fields":[{"name":"i","type":"INTEGER"}]}
    , try schemaOf(arena, "SELECT 1 AS i"));
    try testing.expectEqualStrings(
        \\{"fields":[{"name":"b","type":"BOOLEAN"},{"name":"b2","type":"BOOLEAN"}]}
    , try schemaOf(arena, "SELECT TRUE AS b, FALSE AS b2"));
    try testing.expectEqualStrings(
        \\{"fields":[{"name":"f","type":"FLOAT"}]}
    , try schemaOf(arena, "SELECT 1.5 AS f"));
}

test "ARRAY hoists its element type and marks the field REPEATED" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // testdata/golden.json: array_simple
    try testing.expectEqualStrings(
        \\{"fields":[{"mode":"REPEATED","name":"arr","type":"INTEGER"}]}
    , try schemaOf(arena, "SELECT [1,2,3] AS arr"));
}

test "STRUCT becomes RECORD with nested fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // testdata/golden.json: struct_simple
    try testing.expectEqualStrings(
        \\{"fields":[{"fields":[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING"}],"name":"s","type":"RECORD"}]}
    , try schemaOf(arena, "SELECT STRUCT(1 AS a, 'x' AS b) AS s"));
}

test "ARRAY<STRUCT> is REPEATED RECORD with the element's fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // testdata/golden.json: struct_nested
    try testing.expectEqualStrings(
        \\{"fields":[{"fields":[{"name":"a","type":"INTEGER"},{"fields":[{"name":"c","type":"INTEGER"}],"mode":"REPEATED","name":"b","type":"RECORD"}],"name":"s","type":"RECORD"}]}
    , try schemaOf(arena, "SELECT STRUCT(1 AS a, [STRUCT(2 AS c)] AS b) AS s"));
}

test "date, timestamp and bytes keep their own names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // testdata/golden.json: types_mix
    try testing.expectEqualStrings(
        \\{"fields":[{"name":"d","type":"DATE"},{"name":"ts","type":"TIMESTAMP"},{"name":"raw","type":"BYTES"}]}
    , try schemaOf(arena, "SELECT DATE '2024-01-02' AS d, TIMESTAMP '2024-01-02 03:04:05' AS ts, b'ab' AS raw"));
}
