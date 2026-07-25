//! Port of bigquery-emulator server/source.go JSONSource and the project
//! loading in server/loader.go.
//!
//! The input file describes projects, their datasets, and each dataset's
//! tables (schema plus optional rows):
//!
//!   [{"id":"proj","datasets":[{"id":"ds","tables":[
//!      {"id":"t","columns":[{"name":"a","type":"INTEGER"}],"data":[...]}]}]}]
//!
//! Go's JSONSource does no validation at all — unlike YAMLSource, which is
//! strict — so a malformed entry is skipped rather than fatal. That leniency
//! is reproduced: a table that fails to create must not stop the server from
//! booting, or a single bad source table would take down every test.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const schema_mod = @import("internal/types/schema.zig");
const metadata = @import("internal/metadata/repository.zig");
const datasets_handler = @import("handler/datasets.zig");
const tables_handler = @import("handler/tables.zig");

pub const LoadStats = struct {
    projects: usize = 0,
    datasets: usize = 0,
    tables: usize = 0,
    failed_tables: usize = 0,
};

/// Loads a `--data-from-json` document into the content database and the
/// metadata store.
pub fn loadJson(
    arena: std.mem.Allocator,
    db: *driver.Db,
    repo: *metadata.Repository,
    endpoint: []const u8,
    now_millis: i64,
    bytes: []const u8,
) !LoadStats {
    var stats = LoadStats{};

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch {
        return error.InvalidSourceJson;
    };
    // The file is normally a list of projects, but a single project object is
    // accepted too.
    const projects: []const std.json.Value = switch (root) {
        .array => |a| a.items,
        .object => blk: {
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
            stats.datasets += 1;

            const tables = arrayField(ds, "tables") orelse continue;
            for (tables) |tbl| {
                if (tbl != .object) continue;
                const table_id = stringField(tbl, "id") orelse continue;

                // `columns` is the emulator's own spelling; `schema.fields`
                // is the REST spelling. Accept both.
                const schema_node = normalizeSchema(arena, tbl) catch null;

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
                db.exec(ddl, &.{}, .{}) catch {
                    // Lenient, like Go's JSONSource: log and carry on.
                    std.log.warn(
                        "source table {s}.{s}.{s} failed to create: {s}",
                        .{ project_id, dataset_id, table_id, db.lastError() },
                    );
                    stats.failed_tables += 1;
                    continue;
                };

                var meta: std.ArrayList(u8) = .empty;
                try tables_handler.writeTable(arena, &meta, .{
                    .project_id = project_id,
                    .dataset_id = dataset_id,
                    .table_id = table_id,
                    .endpoint = endpoint,
                    .created_millis = now_millis,
                    .schema = schema_node,
                });
                try repo.addTable(project_id, dataset_id, table_id, meta.items);
                stats.tables += 1;
            }
        }
    }
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
    return loadJson(arena, db, &repo, "h:1", 0, json);
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
