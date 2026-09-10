//! Port of bigquery-emulator server/source.go JSONSource and the project
//! loading in server/loader.go.
//!
//! The input file describes projects, their datasets, and each dataset's
//! tables (schema plus optional rows). Two top-level shapes occur in the
//! wild and both are accepted:
//!
//!   {"projects":[{"id":"proj","datasets":[...]}]}   <- what real tooling emits
//!   [{"id":"proj","datasets":[...]}]                <- a bare project list
//!
//! and a dataset's tables look like:
//!
//!   {"id":"t","columns":[{"name":"a","type":"INTEGER","mode":"NULLABLE"}],
//!    "data":[{"a":1},{"a":2}]}
//!
//! `data` is optional; each entry maps column name to value, exactly as
//! tabledata.insertAll's `json` member does.
//!

const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const schema_mod = @import("internal/types/schema.zig");
const metadata = @import("internal/metadata/repository.zig");
const datasets_handler = @import("handler/datasets.zig");
const tables_handler = @import("handler/tables.zig");
const contentdata = @import("internal/contentdata/repository.zig");

pub const LoadStats = struct {
    projects: usize = 0,
    datasets: usize = 0,
    tables: usize = 0,
    failed_tables: usize = 0,
    rows: usize = 0,
    failed_rows: usize = 0,
};

/// Loads a `--data-from-json` document: projects and datasets into the
/// metadata store, tables and rows into the engine.
pub fn loadJson(
    arena: std.mem.Allocator,
    db: *driver.Db,
    repo: *metadata.Repository,
    bytes: []const u8,
) !LoadStats {
    var stats = LoadStats{};

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
        return error.InvalidSourceJson;
    };
    const projects: []const std.json.Value = switch (root) {
        .array => |a| a.items,
        .object => blk: {
            // The usual shape is a {"projects":[...]} wrapper; a bare project
            // object is also accepted.
            if (root.object.get("projects")) |ps| {
                if (ps != .array) return error.InvalidSourceJson;
                break :blk ps.array.items;
            }
            const one = try arena.alloc(std.json.Value, 1);
            one[0] = root;
            break :blk one;
        },
        else => return error.InvalidSourceJson,
    };

    for (projects) |proj| {
        if (proj != .object) continue;
        const project_id = stringField(proj, "id") orelse continue;
        try repo.addProjectIfNotExists(project_id);
        stats.projects += 1;

        const datasets = arrayField(proj, "datasets") orelse continue;
        for (datasets) |ds| {
            if (ds != .object) continue;
            const dataset_id = stringField(ds, "id") orelse continue;

            var ds_meta: std.ArrayList(u8) = .empty;
            try datasets_handler.writeDataset(arena, &ds_meta, project_id, dataset_id, true);
            try repo.addDataset(project_id, dataset_id, ds_meta.items);
            try db.ensureDataset(project_id, dataset_id);
            stats.datasets += 1;

            const tables = arrayField(ds, "tables") orelse continue;
            for (tables) |tbl| {
                if (tbl != .object) continue;
                const table_id = stringField(tbl, "id") orelse continue;

                // `columns` is the emulator's own spelling; `schema.fields`
                // is the REST spelling. Accept both.
                const schema_node = normalizeSchema(arena, tbl) catch null;

                // Loading over a database that already holds the table keeps
                // what is there; the fixture's schema is not applied to it.
                if (try db.catalogTable(arena, project_id, dataset_id, table_id)) |_| {
                    std.log.warn(
                        "source table {s}.{s}.{s} already exists; not replaced",
                        .{ project_id, dataset_id, table_id },
                    );
                    stats.failed_tables += 1;
                    continue;
                }

                const ddl = schema_mod.createTableDdl(
                    arena,
                    project_id,
                    dataset_id,
                    table_id,
                    schema_node,
                ) catch {
                    stats.failed_tables += 1;
                    continue;
                };
                // The default path is now O(1) in catalog size thanks to the
                // analyzer's persistent catalog, so no scope hint is needed.
                db.exec(ddl, &.{}, .{}) catch {
                    // Lenient, like Go's JSONSource: log and carry on.
                    std.log.warn(
                        "source table {s}.{s}.{s} failed to create: {s}",
                        .{ project_id, dataset_id, table_id, db.lastError() },
                    );
                    stats.failed_tables += 1;
                    continue;
                };

                // The posted schema rides on the spec, as it does for
                // tables.insert, so nested modes come back from tables.get.
                if (schema_node) |schema| {
                    var posted: std.json.ObjectMap = .empty;
                    try posted.put(arena, "schema", schema);
                    var metadata_json: std.ArrayList(u8) = .empty;
                    try tables_handler.writeMetadata(arena, &metadata_json, .{ .object = posted });
                    db.setTableMetadata(
                        arena,
                        project_id,
                        dataset_id,
                        table_id,
                        metadata_json.items,
                    ) catch |err| {
                        // Lenient like the rest of the loader.
                        std.log.warn(
                            "source table {s}.{s}.{s}: schema not recorded: {t}",
                            .{ project_id, dataset_id, table_id, err },
                        );
                        stats.failed_tables += 1;
                        continue;
                    };
                }
                stats.tables += 1;

                // A table's rows live beside its schema in `data`, keyed by
                // column name — the same object tabledata.insertAll posts in
                // its `json` member, which is why the same writer serves both.
                // Checked against the Go emulator: a missing key and an
                // explicit null both store NULL, REPEATED columns take a JSON
                // array and RECORD columns a JSON object, and values may be
                // native JSON types rather than strings.
                const rows = arrayField(tbl, "data") orelse continue;
                if (rows.len == 0) continue;
                var content = contentdata.Repository{ .arena = arena, .db = db };
                const result = content.addTableData(
                    project_id,
                    dataset_id,
                    table_id,
                    schemaFields(schema_node),
                    rows,
                    false,
                ) catch |err| {
                    // Lenient like the rest of JSONSource: a table whose rows
                    // will not load still exists, and empty beats absent.
                    std.log.warn(
                        "source table {s}.{s}.{s}: {d} rows failed to load: {t} — {s}",
                        .{ project_id, dataset_id, table_id, rows.len, err, content.message },
                    );
                    stats.failed_rows += rows.len;
                    continue;
                };
                if (result.invalid.len > 0) {
                    // The batch is all-or-nothing, one bad value leaves the table empty.
                    const invalid = result.invalid;
                    std.log.warn(
                        "source table {s}.{s}.{s}: {d} rows failed to load: row {d} {s}: {s}",
                        .{
                            project_id,           dataset_id,            table_id,           rows.len,
                            invalid[0].row_index, invalid[0].field_name, invalid[0].message,
                        },
                    );
                    stats.failed_rows += rows.len;
                    continue;
                }
                stats.rows += rows.len;
            }
        }
    }
    // Loading nothing from a non-empty file means the shape was not
    // understood. Silence here previously hid a wrapper object being skipped
    // wholesale, which surfaced much later as "Table not found".
    if (stats.projects == 0) return error.NoProjectsLoaded;
    return stats;
}

/// Returns a `{"fields":[...]}` node from either the emulator's `columns`
/// list or a REST-style `schema`.
fn normalizeSchema(
    arena: std.mem.Allocator,
    table: std.json.Value,
) !?std.json.Value {
    if (table.object.get("schema")) |s| {
        if (s == .object and s.object.get("fields") != null) return s;
    }
    const columns = table.object.get("columns") orelse return null;
    if (columns != .array) return null;

    const obj = try std.json.ObjectMap.init(
        arena,
        &.{"fields"},
        &.{table.object.get("columns").?},
    );
    return .{ .object = obj };
}

/// The `fields` array of a normalized `{"fields":[...]}` schema node.
fn schemaFields(schema_node: ?std.json.Value) []const std.json.Value {
    const node = schema_node orelse return &.{};
    if (node != .object) return &.{};
    const f = node.object.get("fields") orelse return &.{};
    return if (f == .array) f.array.items else &.{};
}

fn stringField(v: std.json.Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(name) orelse return null;
    return if (f == .string) f.string else null;
}

fn arrayField(v: std.json.Value, name: []const u8) ?[]const std.json.Value {
    if (v != .object) return null;
    const f = v.object.get(name) orelse return null;
    return if (f == .array) f.array.items else null;
}

const testing = std.testing;

fn loadInto(arena: std.mem.Allocator, db: *driver.Db, json: []const u8) !LoadStats {
    var repo = try metadata.Repository.init(db);
    return loadJson(arena, db, &repo, json);
}

test "a table's `data` rows load and are queryable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Shapes checked against the Go emulator: a missing key and an explicit
    // null are both NULL, values may be native JSON types, and REPEATED and
    // RECORD columns take an array and an object.
    const stats = try loadInto(arena, db,
        \\[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"t","columns":[
        \\     {"name":"i","type":"INTEGER"},
        \\     {"name":"s","type":"STRING"},
        \\     {"name":"b","type":"BOOLEAN"},
        \\     {"name":"arr","type":"INTEGER","mode":"REPEATED"},
        \\     {"name":"st","type":"RECORD","fields":[{"name":"x","type":"INTEGER"}]}],
        \\   "data":[
        \\     {"i":1,"s":"alice","b":true,"arr":[1,2,3],"st":{"x":7}},
        \\     {"i":2,"s":null}]}
        \\]}]}]
    );
    try testing.expectEqual(@as(usize, 1), stats.tables);
    try testing.expectEqual(@as(usize, 2), stats.rows);
    try testing.expectEqual(@as(usize, 0), stats.failed_rows);

    var rows = try db.query(
        "SELECT i, s, b, ARRAY_LENGTH(arr), st.x FROM `p.d.t` ORDER BY i",
        &.{},
        .{},
    );
    defer rows.deinit();
    const r1 = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 1), r1[0].int);
    try testing.expectEqualStrings("alice", r1[1].string);
    try testing.expectEqual(true, r1[2].bool);
    try testing.expectEqual(@as(i64, 3), r1[3].int);
    try testing.expectEqual(@as(i64, 7), r1[4].int);
    const r2 = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 2), r2[0].int);
    // An explicit null and a key that is simply absent are both NULL.
    try testing.expectEqual(driver.Cell.null, r2[1]);
    try testing.expectEqual(driver.Cell.null, r2[2]);
}

test "a table with no `data` member still loads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const stats = try loadInto(arena, db,
        \\[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"t","columns":[{"name":"a","type":"INTEGER"}]},
        \\  {"id":"u","columns":[{"name":"a","type":"INTEGER"}],"data":[]}
        \\]}]}]
    );
    try testing.expectEqual(@as(usize, 2), stats.tables);
    try testing.expectEqual(@as(usize, 0), stats.rows);

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "rows that cannot be shaped leave the table present but empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // The warning this load logs is the expected outcome here.
    const saved_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log_level;

    // "not a number" cannot cast to INT64, so the batch rolls back — but
    // JSONSource is lenient and the table still exists.
    const stats = try loadInto(arena, db,
        \\[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"t","columns":[{"name":"a","type":"INTEGER"}],
        \\   "data":[{"a":1},{"a":"not a number"}]}
        \\]}]}]
    );
    try testing.expectEqual(@as(usize, 1), stats.tables);
    try testing.expectEqual(@as(usize, 0), stats.rows);
    try testing.expectEqual(@as(usize, 2), stats.failed_rows);

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "loads projects, datasets and tables, and the tables are queryable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const stats = try loadInto(arena, db,
        \\[{"id":"proj","datasets":[{"id":"ds","tables":[
        \\  {"id":"t1","columns":[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING"}]},
        \\  {"id":"t2","columns":[{"name":"c","type":"BOOLEAN","mode":"REPEATED"}]}
        \\]}]}]
    );
    try testing.expectEqual(@as(usize, 1), stats.projects);
    try testing.expectEqual(@as(usize, 1), stats.datasets);
    try testing.expectEqual(@as(usize, 2), stats.tables);
    try testing.expectEqual(@as(usize, 0), stats.failed_tables);

    var rows = try db.query("SELECT a, b FROM `proj.ds.t1`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());

    var rows2 = try db.query("SELECT c FROM `proj.ds.t2`", &.{}, .{});
    defer rows2.deinit();
    try testing.expect(rows2.columnTypes()[0].type.isArray());
}

test "accepts a REST-style schema node as well as columns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const stats = try loadInto(arena, db,
        \\[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"t","schema":{"fields":[{"name":"x","type":"INTEGER"}]}}
        \\]}]}]
    );
    try testing.expectEqual(@as(usize, 1), stats.tables);
    var rows = try db.query("SELECT x FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
}

test "a single bad table does not abort the load" {
    // Go's JSONSource does no validation; one broken source table must not
    // stop the server from booting.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const stats = try loadInto(arena, db,
        \\[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"good","columns":[{"name":"a","type":"INTEGER"}]},
        \\  {"no_id":true},
        \\  {"id":"also_good","columns":[{"name":"b","type":"STRING"}]}
        \\]}]}]
    );
    try testing.expectEqual(@as(usize, 2), stats.tables);
    var rows = try db.query("SELECT b FROM `p.d.also_good`", &.{}, .{});
    defer rows.deinit();
}

test "a table whose schema cannot be recorded is counted, and the load goes on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // A dotted id is split by the DDL path, so the spec lands under a name the
    // loader's own lookup cannot see; the next table still loads.
    const stats = try loadInto(arena, db,
        \\[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"a.b","columns":[{"name":"x","type":"INTEGER"}]},
        \\  {"id":"fine","columns":[{"name":"x","type":"INTEGER"}],"data":[{"x":1}]}
        \\]}]}]
    );
    try testing.expectEqual(@as(usize, 1), stats.failed_tables);
    try testing.expectEqual(@as(usize, 1), stats.tables);
    try testing.expectEqual(@as(usize, 1), stats.rows);
}

test "loading over a table that already exists leaves it alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const first = try loadInto(arena, db,
        \\[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"t","columns":[{"name":"a","type":"STRING"}],"data":[{"a":"kept"}]}]}]}]
    );
    try testing.expectEqual(@as(usize, 1), first.tables);
    const second = try loadInto(arena, db,
        \\[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"t","columns":[{"name":"b","type":"INTEGER"}],"data":[{"b":2}]}]}]}]
    );
    try testing.expectEqual(@as(usize, 0), second.tables);
    try testing.expectEqual(@as(usize, 1), second.failed_tables);

    const table_spec = (try db.catalogTable(arena, "p", "d", "t")).?;
    try testing.expectEqualStrings("a", table_spec.columns[0].name);
    var rows = try db.query("SELECT a FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqualStrings("kept", (try rows.next()).?[0].string);
}

test "a single project object is accepted, not just a list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const stats = try loadInto(arena, db,
        \\{"id":"p","datasets":[{"id":"d","tables":[{"id":"t","columns":[{"name":"a","type":"INTEGER"}]}]}]}
    );
    try testing.expectEqual(@as(usize, 1), stats.projects);
    try testing.expectEqual(@as(usize, 1), stats.tables);
}

test "malformed json is an error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    try testing.expectError(error.InvalidSourceJson, loadInto(arena, db, "{not json"));
    try testing.expectError(error.InvalidSourceJson, loadInto(arena, db, "42"));
}

test "accepts the {\"projects\":[...]} wrapper that real tooling emits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const stats = try loadInto(arena, db,
        \\{"projects":[{"id":"p","datasets":[{"id":"d","tables":[
        \\  {"id":"t","columns":[{"name":"a","type":"STRING","mode":"NULLABLE","fields":[]}]}
        \\]}]}]}
    );
    try testing.expectEqual(@as(usize, 1), stats.projects);
    try testing.expectEqual(@as(usize, 1), stats.tables);

    var rows = try db.query("SELECT a FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
}

test "a file that yields no projects is an error, not a silent no-op" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // An unrecognised wrapper must not quietly load nothing.
    try testing.expectError(
        error.NoProjectsLoaded,
        loadInto(arena, db, "{\"somethingElse\":[]}"),
    );
}
