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
// ephor:ignore-file ZA302 ZA303 ZA304 ZT105

const std = @import("std");
const zigquery = @import("zigquery");
const spec = zigquery.spec;
const pb = zigquery.pb;
const errors = @import("../../error.zig");
const bqpb = @import("../../proto/bigquery.zig");

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
/// Keys are written in alphabetical order: `fields, mode, name, type`.
pub fn writeField(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    t: *const spec.Type,
) std.mem.Allocator.Error!void {
    return writeFieldMode(arena, out, .{ .name = name, .type = t });
}

/// A field, with the mode a caller that knows it can supply.
///
/// A GoogleSQL type carries no nullability, so a schema derived from a query's
/// output columns cannot say REQUIRED and never should. A schema derived from
/// the catalog can: `ColumnSpec.is_not_null` is what `CREATE TABLE ... NOT
/// NULL` left behind, and a DDL-created table's REQUIRED columns need it
/// carried through to both the REST and the Storage APIs.
pub const Field = struct {
    name: []const u8,
    type: *const spec.Type,
    /// True only for a column the catalog declared NOT NULL. REPEATED wins over
    /// it — an ARRAY is its own mode — which is why it is consulted after.
    required: bool = false,
    /// The catalog's OPTIONS(description); "" writes none.
    description: []const u8 = "",
};

pub fn writeFieldMode(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    field: Field,
) std.mem.Allocator.Error!void {
    const name = field.name;
    const t = field.type;
    // ARRAY<T> is not a type of its own on the wire: the element type is
    // hoisted and the field is marked REPEATED.
    const repeated = t.isArray();
    const elem: *const spec.Type = if (repeated) (t.element_type orelse t) else t;

    try out.append(arena, '{');
    var need_comma = false;

    if (field.description.len > 0) {
        try out.appendSlice(arena, "\"description\":");
        try errors.writeJsonString(arena, out, field.description);
        need_comma = true;
    }

    if (elem.isStruct()) {
        if (need_comma) try out.append(arena, ',');
        try writeSubFields(arena, out, elem);
        need_comma = true;
    }

    if (repeated) {
        if (need_comma) try out.append(arena, ',');
        try out.appendSlice(arena, "\"mode\":\"REPEATED\"");
        need_comma = true;
    } else if (field.required) {
        if (need_comma) try out.append(arena, ',');
        try out.appendSlice(arena, "\"mode\":\"REQUIRED\"");
        need_comma = true;
    }

    if (need_comma) try out.append(arena, ',');
    try out.appendSlice(arena, "\"name\":");
    try errors.writeJsonString(arena, out, name);

    try out.appendSlice(arena, ",\"type\":");
    try errors.writeJsonString(arena, out, legacyTypeName(elem.typeKind()));

    try out.append(arena, '}');
}

/// `"fields":[...]`: a STRUCT's members, each with its own mode and description.
fn writeSubFields(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    elem: *const spec.Type,
) std.mem.Allocator.Error!void {
    try out.appendSlice(arena, "\"fields\":[");
    for (elem.field_types, 0..) |f, i| {
        if (i > 0) try out.append(arena, ',');
        try writeFieldMode(arena, out, .{
            .name = f.name,
            .type = f.type orelse elem,
            .required = f.is_not_null,
            .description = f.description,
        });
    }
    try out.append(arena, ']');
}

/// The same field as a generated TableFieldSchema.
///
/// `mode` is absent rather than "NULLABLE": a GoogleSQL type carries no
/// nullability, and REPEATED is what an ARRAY becomes once its element type is
/// hoisted.
pub fn pbField(
    arena: std.mem.Allocator,
    field: Field,
) std.mem.Allocator.Error!*bqpb.TableFieldSchema {
    const t = field.type;
    const repeated = t.isArray();
    const elem: *const spec.Type = if (repeated) (t.element_type orelse t) else t;

    const out = try arena.create(bqpb.TableFieldSchema);
    out.* = .{
        .name = field.name,
        .type = legacyTypeName(elem.typeKind()),
        .mode = if (repeated) "REPEATED" else if (field.required) "REQUIRED" else null,
    };
    if (field.description.len > 0) {
        const description = try arena.create(bqpb.StringValue);
        description.* = .{ .value = field.description };
        out.description = description;
    }
    if (elem.isStruct()) out.fields = try pbFields(arena, elem);
    return out;
}

fn pbFields(
    arena: std.mem.Allocator,
    elem: *const spec.Type,
) std.mem.Allocator.Error![]*bqpb.TableFieldSchema {
    const subs = try arena.alloc(*bqpb.TableFieldSchema, elem.field_types.len);
    for (elem.field_types, 0..) |f, i| {
        subs[i] = try pbField(arena, .{
            .name = f.name,
            .type = f.type orelse elem,
            .required = f.is_not_null,
            .description = f.description,
        });
    }
    return subs;
}

/// A query's output columns as a TableSchema.
pub fn pbSchema(
    arena: std.mem.Allocator,
    cols: []const zigquery.driver.OutputColumn,
) std.mem.Allocator.Error!*bqpb.TableSchema {
    const fields = try arena.alloc(*bqpb.TableFieldSchema, cols.len);
    for (cols, 0..) |col, i| {
        fields[i] = try pbField(arena, .{ .name = col.name, .type = col.type });
    }
    const out = try arena.create(bqpb.TableSchema);
    out.* = .{ .fields = fields };
    return out;
}

/// Emits the `schema` object: {"fields":[...]}.
pub fn writeSchema(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cols: []const zigquery.driver.OutputColumn,
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
    var db = try zigquery.driver.Db.open(testing.allocator, ":memory:");
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

    try testing.expectEqualStrings(
        \\{"fields":[{"mode":"REPEATED","name":"arr","type":"INTEGER"}]}
    , try schemaOf(arena, "SELECT [1,2,3] AS arr"));
}

test "STRUCT becomes RECORD with nested fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        \\{"fields":[{"fields":[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING"}],"name":"s","type":"RECORD"}]}
    , try schemaOf(arena, "SELECT STRUCT(1 AS a, 'x' AS b) AS s"));
}

test "ARRAY<STRUCT> is REPEATED RECORD with the element's fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        \\{"fields":[{"fields":[{"name":"a","type":"INTEGER"},{"fields":[{"name":"c","type":"INTEGER"}],"mode":"REPEATED","name":"b","type":"RECORD"}],"name":"s","type":"RECORD"}]}
    , try schemaOf(arena, "SELECT STRUCT(1 AS a, [STRUCT(2 AS c)] AS b) AS s"));
}

test "date, timestamp and bytes keep their own names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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

/// A posted schema names a type this emulator cannot translate. Go reaches the
/// same place by writing an empty type into the DDL and letting the CREATE
/// fail; both surface to the client as a 400.
pub const TypeError = error{UnknownFieldType};

/// Legacy REST type name -> GoogleSQL type name, the inverse of
/// legacyTypeName. Null when the name is not one BigQuery defines.
///
/// The alias set is Go's `Type.ZetaSQLTypeKind` (types/types.go): BigQuery
/// spells INT64 six ways and NUMERIC/BIGNUMERIC two each, and a client that
/// picks the wrong spelling should still get the right column. Returning
/// "STRING" for anything unrecognised is what let `SchemaField("person_id",
/// "INT")` silently create a STRING column, so unknown names now fail loudly.
pub fn googleSqlTypeName(legacy: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "INT64", "INT64" },
        .{ "INT", "INT64" },
        .{ "SMALLINT", "INT64" },
        .{ "INTEGER", "INT64" },
        .{ "BIGINT", "INT64" },
        .{ "TINYINT", "INT64" },
        .{ "BYTEINT", "INT64" },
        // Go sends FLOAT to types.FLOAT (32-bit) and only FLOAT64/DOUBLE to
        // types.DOUBLE; BigQuery's REST "FLOAT" means FLOAT64, and that is
        // what this port has always emitted.
        .{ "FLOAT", "FLOAT64" },
        .{ "FLOAT64", "FLOAT64" },
        .{ "DOUBLE", "FLOAT64" },
        .{ "BOOLEAN", "BOOL" },
        .{ "BOOL", "BOOL" },
        .{ "STRING", "STRING" },
        .{ "BYTES", "BYTES" },
        .{ "DATE", "DATE" },
        .{ "DATETIME", "DATETIME" },
        .{ "TIME", "TIME" },
        .{ "TIMESTAMP", "TIMESTAMP" },
        .{ "NUMERIC", "NUMERIC" },
        .{ "DECIMAL", "NUMERIC" },
        .{ "BIGNUMERIC", "BIGNUMERIC" },
        .{ "BIGDECIMAL", "BIGNUMERIC" },
        .{ "JSON", "JSON" },
        .{ "INTERVAL", "INTERVAL" },
        .{ "GEOGRAPHY", "GEOGRAPHY" },
    });
    return map.get(legacy);
}

/// GoogleSQL type text for one field node, honouring mode REPEATED and
/// nested RECORD fields.
pub fn fieldTypeText(
    arena: std.mem.Allocator,
    field: std.json.Value,
) (std.mem.Allocator.Error || TypeError)![]const u8 {
    if (field != .object) return error.UnknownFieldType;
    const obj = field.object;

    const type_name = blk: {
        const t = obj.get("type") orelse return error.UnknownFieldType;
        break :blk if (t == .string) t.string else return error.UnknownFieldType;
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
                    // REQUIRED on a member is NOT NULL on the field.
                    if (sub == .object and isRequired(sub)) try out.appendSlice(arena, " NOT NULL");
                }
            }
        }
        try out.append(arena, '>');
        base = try out.toOwnedSlice(arena);
    } else {
        base = googleSqlTypeName(type_name) orelse return error.UnknownFieldType;
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

fn isRequired(field: std.json.Value) bool {
    const m = field.object.get("mode") orelse return false;
    return m == .string and std.mem.eql(u8, m.string, "REQUIRED");
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
) (std.mem.Allocator.Error || TypeError)![]const u8 {
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
                        // REQUIRED is NOT NULL on the column
                        if (isRequired(field)) try out.appendSlice(arena, " NOT NULL");
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
    // Every alias Go's Type.ZetaSQLTypeKind accepts. `SchemaField("person_id",
    // "INT")` used to fall through to STRING, which made person_id come back
    // from a query as '123' instead of 123.
    const cases = [_]struct { legacy: []const u8, googlesql: []const u8 }{
        .{ .legacy = "INT64", .googlesql = "INT64" },
        .{ .legacy = "INT", .googlesql = "INT64" },
        .{ .legacy = "SMALLINT", .googlesql = "INT64" },
        .{ .legacy = "INTEGER", .googlesql = "INT64" },
        .{ .legacy = "BIGINT", .googlesql = "INT64" },
        .{ .legacy = "TINYINT", .googlesql = "INT64" },
        .{ .legacy = "BYTEINT", .googlesql = "INT64" },
        .{ .legacy = "FLOAT", .googlesql = "FLOAT64" },
        .{ .legacy = "FLOAT64", .googlesql = "FLOAT64" },
        .{ .legacy = "DOUBLE", .googlesql = "FLOAT64" },
        .{ .legacy = "BOOLEAN", .googlesql = "BOOL" },
        .{ .legacy = "BOOL", .googlesql = "BOOL" },
        .{ .legacy = "NUMERIC", .googlesql = "NUMERIC" },
        .{ .legacy = "DECIMAL", .googlesql = "NUMERIC" },
        .{ .legacy = "BIGNUMERIC", .googlesql = "BIGNUMERIC" },
        .{ .legacy = "BIGDECIMAL", .googlesql = "BIGNUMERIC" },
        .{ .legacy = "STRING", .googlesql = "STRING" },
        .{ .legacy = "GEOGRAPHY", .googlesql = "GEOGRAPHY" },
    };
    for (cases) |c| try testing.expectEqualStrings(c.googlesql, googleSqlTypeName(c.legacy).?);

    // Unknown names no longer degrade to STRING — a silent wrong column type
    // is worse than a rejected CREATE, and Go rejects it too.
    try testing.expectEqual(@as(?[]const u8, null), googleSqlTypeName("SOMETHING_NEW"));
    // The map is case-sensitive, as BigQuery's REST schema is.
    try testing.expectEqual(@as(?[]const u8, null), googleSqlTypeName("int64"));
}

test "an unusable field type fails the DDL instead of becoming STRING" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"fields":[{"name":"a","type":"WIDGET"}]}
    , .{});
    try testing.expectError(
        error.UnknownFieldType,
        createTableDdl(arena, "p", "ds", "t", schema),
    );

    // A field with no type at all is the same kind of failure.
    const untyped = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"fields":[{"name":"a"}]}
    , .{});
    try testing.expectError(
        error.UnknownFieldType,
        createTableDdl(arena, "p", "ds", "t", untyped),
    );

    // The aliases really do reach the DDL.
    const ints = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"fields":[{"name":"person_id","type":"INT"},{"name":"n","type":"DECIMAL"}]}
    , .{});
    try testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `p.ds.t` (`person_id` INT64, `n` NUMERIC)",
        try createTableDdl(arena, "p", "ds", "t", ints),
    );
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

test "CREATE TABLE DDL makes a REQUIRED column NOT NULL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"fields":[
        \\  {"name":"a","type":"STRING","mode":"REQUIRED"},
        \\  {"name":"b","type":"STRING","mode":"NULLABLE"},
        \\  {"name":"c","type":"STRING","mode":"REPEATED"},
        \\  {"name":"r","type":"RECORD","mode":"REQUIRED","fields":[{"name":"x","type":"INTEGER","mode":"REQUIRED"}]}
        \\]}
    , .{});

    try testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `p.ds.t` (`a` STRING NOT NULL, `b` STRING, " ++
            "`c` ARRAY<STRING>, `r` STRUCT<`x` INT64 NOT NULL> NOT NULL)",
        try createTableDdl(arena, "p", "ds", "t", schema),
    );
}

test "a REQUIRED column rejects NULL from DML and the statement rolls back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"fields":[{"name":"a","type":"STRING","mode":"REQUIRED"},{"name":"b","type":"STRING"}]}
    , .{});
    var db = try zigquery.driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec(try createTableDdl(arena, "p", "ds", "req", schema), &.{}, .{});

    try db.exec("INSERT INTO `p.ds.req` (a, b) VALUES ('ok', NULL)", &.{}, .{});
    try testing.expectError(
        error.ExecFailed,
        db.exec("INSERT INTO `p.ds.req` (a, b) VALUES ('also ok', 'x'), (NULL, 'y')", &.{}, .{}),
    );
    try testing.expectError(
        error.ExecFailed,
        db.exec("UPDATE `p.ds.req` SET a = NULL WHERE TRUE", &.{}, .{}),
    );

    var rows = try db.query("SELECT COUNT(*) FROM `p.ds.req`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?[0].int);
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

    var db = try zigquery.driver.Db.open(testing.allocator, ":memory:");
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

/// Emits a schema from a catalog TableSpec's columns.
///
/// Used when answering tables.get for something the engine knows about but
/// the metadata store does not; reading the spec avoids running a query just
/// to learn the shape.
pub fn writeSchemaFromSpec(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    table_spec: *const spec.TableSpec,
) std.mem.Allocator.Error!void {
    try out.appendSlice(arena, "{\"fields\":[");
    for (table_spec.columns, 0..) |col, i| {
        if (i > 0) try out.append(arena, ',');
        // The catalog is the only place NOT NULL survives -- a query's output
        // columns cannot say it -- so this is where REQUIRED comes from for a
        // table nobody created through tables.insert.
        try writeFieldMode(arena, out, .{
            .name = col.name,
            .type = col.type,
            .required = col.is_not_null,
            .description = col.description,
        });
    }
    try out.appendSlice(arena, "]}");
}

test "schema from a catalog spec matches the query-derived one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try zigquery.driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec(
        "CREATE TABLE `p.d.spec_t` (a INT64, b STRING, c ARRAY<INT64>)",
        &.{},
        .{},
    );

    const table_spec = (try db.catalogTable(arena, "p", "d", "spec_t")).?;
    var from_spec: std.ArrayList(u8) = .empty;
    try writeSchemaFromSpec(arena, &from_spec, table_spec);

    var rows = try db.query("SELECT a, b, c FROM `p.d.spec_t`", &.{}, .{});
    defer rows.deinit();
    var from_query: std.ArrayList(u8) = .empty;
    try writeSchema(arena, &from_query, rows.columnTypes());

    try testing.expectEqualStrings(from_query.items, from_spec.items);
}

test "catalogTable finds views and misses absent tables" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try zigquery.driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.base` (a INT64)", &.{}, .{});
    try db.exec("CREATE OR REPLACE VIEW `p.d.v` AS SELECT a FROM `p.d.base`", &.{}, .{});

    try testing.expect((try db.catalogTable(arena, "p", "d", "v")) != null);
    try testing.expect((try db.catalogTable(arena, "p", "d", "base")) != null);
    try testing.expectEqual(
        @as(?*const spec.TableSpec, null),
        try db.catalogTable(arena, "p", "d", "nope"),
    );
}
