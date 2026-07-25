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

// ---- reverse direction: BigQuery schema -> GoogleSQL DDL ----
//
// Go's contentdata repository emits `CREATE TABLE `p.ds.t` (col TYPE, ...)`
// from the schema a client posts to tables.insert, which is what makes the
// table visible to queries. These helpers rebuild the GoogleSQL type text
// from a TableFieldSchema JSON node.

/// Legacy REST type name -> GoogleSQL type name. The inverse of
/// legacyTypeName, for the subset that round-trips.
pub fn googleSqlTypeName(legacy: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "INTEGER", "INT64" },
        .{ "INT64", "INT64" },
        .{ "FLOAT", "FLOAT64" },
        .{ "FLOAT64", "FLOAT64" },
        .{ "BOOLEAN", "BOOL" },
        .{ "BOOL", "BOOL" },
        .{ "STRING", "STRING" },
        .{ "BYTES", "BYTES" },
        .{ "DATE", "DATE" },
        .{ "DATETIME", "DATETIME" },
        .{ "TIME", "TIME" },
        .{ "TIMESTAMP", "TIMESTAMP" },
        .{ "NUMERIC", "NUMERIC" },
        .{ "BIGNUMERIC", "BIGNUMERIC" },
        .{ "JSON", "JSON" },
        .{ "INTERVAL", "INTERVAL" },
        .{ "GEOGRAPHY", "GEOGRAPHY" },
    });
    return map.get(legacy) orelse "STRING";
}

/// GoogleSQL type text for one field node, honouring mode REPEATED and
/// nested RECORD fields.
pub fn fieldTypeText(
    arena: std.mem.Allocator,
    field: std.json.Value,
) std.mem.Allocator.Error![]const u8 {
    if (field != .object) return "STRING";
    const obj = field.object;

    const type_name = blk: {
        const t = obj.get("type") orelse break :blk "STRING";
        break :blk if (t == .string) t.string else "STRING";
    };

    var base: []const u8 = undefined;
    if (std.mem.eql(u8, type_name, "RECORD") or std.mem.eql(u8, type_name, "STRUCT")) {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "STRUCT<");
        if (obj.get("fields")) |fields| {
            if (fields == .array) {
                for (fields.array.items, 0..) |sub, i| {
                    if (i > 0) try out.appendSlice(arena, ", ");
                    const sub_name = if (sub == .object) blk2: {
                        const n = sub.object.get("name") orelse break :blk2 "f";
                        break :blk2 if (n == .string) n.string else "f";
                    } else "f";
                    try out.append(arena, '`');
                    try out.appendSlice(arena, sub_name);
                    try out.appendSlice(arena, "` ");
                    try out.appendSlice(arena, try fieldTypeText(arena, sub));
                }
            }
        }
        try out.append(arena, '>');
        base = try out.toOwnedSlice(arena);
    } else {
        base = googleSqlTypeName(type_name);
    }

    const mode = blk: {
        const m = obj.get("mode") orelse break :blk "";
        break :blk if (m == .string) m.string else "";
    };
    if (std.mem.eql(u8, mode, "REPEATED")) {
        return std.fmt.allocPrint(arena, "ARRAY<{s}>", .{base});
    }
    return base;
}

/// `CREATE TABLE `project.dataset.table` (`col` TYPE, ...)`.
///
/// A schema with no fields produces a table with a single placeholder column,
/// because GoogleSQL rejects a column-less CREATE TABLE.
pub fn createTableDdl(
    arena: std.mem.Allocator,
    project_id: []const u8,
    dataset_id: []const u8,
    table_id: []const u8,
    schema_json: ?std.json.Value,
) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "CREATE TABLE IF NOT EXISTS `{s}.{s}.{s}` (", .{
        project_id, dataset_id, table_id,
    });

    var wrote_any = false;
    if (schema_json) |s| {
        if (s == .object) {
            if (s.object.get("fields")) |fields| {
                if (fields == .array) {
                    for (fields.array.items) |field| {
                        if (field != .object) continue;
                        const name_v = field.object.get("name") orelse continue;
                        if (name_v != .string) continue;
                        if (wrote_any) try out.appendSlice(arena, ", ");
                        try out.print(arena, "`{s}` {s}", .{
                            name_v.string,
                            try fieldTypeText(arena, field),
                        });
                        wrote_any = true;
                    }
                }
            }
        }
    }
    if (!wrote_any) try out.appendSlice(arena, "`_placeholder` INT64");
    try out.append(arena, ')');
    return out.toOwnedSlice(arena);
}

test "legacy type names map back to GoogleSQL" {
    try testing.expectEqualStrings("INT64", googleSqlTypeName("INTEGER"));
    try testing.expectEqualStrings("BOOL", googleSqlTypeName("BOOLEAN"));
    try testing.expectEqualStrings("FLOAT64", googleSqlTypeName("FLOAT"));
    // Unknown types degrade to STRING rather than failing the CREATE.
    try testing.expectEqualStrings("STRING", googleSqlTypeName("SOMETHING_NEW"));
}

test "CREATE TABLE DDL covers scalars, REPEATED and nested RECORD" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"fields":[
        \\  {"name":"a","type":"INTEGER"},
        \\  {"name":"b","type":"STRING","mode":"REPEATED"},
        \\  {"name":"c","type":"RECORD","fields":[{"name":"x","type":"BOOLEAN"}]},
        \\  {"name":"d","type":"RECORD","mode":"REPEATED","fields":[{"name":"y","type":"FLOAT"}]}
        \\]}
    , .{});

    try testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `p.ds.t` (`a` INT64, `b` ARRAY<STRING>, " ++
            "`c` STRUCT<`x` BOOL>, `d` ARRAY<STRUCT<`y` FLOAT64>>)",
        try createTableDdl(arena, "p", "ds", "t", schema),
    );
}

test "a schema-less table still creates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // GoogleSQL rejects a column-less CREATE TABLE, so a placeholder stands in.
    try testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `p.ds.t` (`_placeholder` INT64)",
        try createTableDdl(arena, "p", "ds", "t", null),
    );
}

test "DDL from a posted schema actually creates a queryable table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"fields":[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING","mode":"REPEATED"}]}
    , .{});
    const ddl = try createTableDdl(arena, "p", "ds", "round_trip", schema);

    var db = try zetasqlite.driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec(ddl, &.{}, .{});

    // And the schema we get back matches what went in.
    var rows = try db.query("SELECT a, b FROM `p.ds.round_trip`", &.{}, .{});
    defer rows.deinit();
    var out: std.ArrayList(u8) = .empty;
    try writeSchema(arena, &out, rows.columnTypes());
    try testing.expectEqualStrings(
        \\{"fields":[{"name":"a","type":"INTEGER"},{"mode":"REPEATED","name":"b","type":"STRING"}]}
    , out.items);
}
