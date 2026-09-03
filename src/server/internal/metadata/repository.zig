//! Port of bigquery-emulator internal/metadata/repository.go — the catalog of
//! projects, datasets and tables.
//!
//! Go stores these in six SQLite tables whose `metadata` column is a JSON blob
//! of the corresponding bigqueryv2 struct, deliberately kept as a raw map so
//! unknown fields survive a round trip. The same shape is used here, through
//! the driver's raw (non-GoogleSQL) path — Go likewise prepares all of these
//! under WithQueryFormattingDisabled, because they are plain SQLite, not
//! GoogleSQL.
//!
//! Differences from Go, by design:
//! - Four tables, not six: models and routines arrive with their handlers.
//! - No prepared-statement pre-warming. Go prepares 22 statements on each of
//!   5 pooled connections at boot to work around database/sql binding
//!   statements to connections; the driver's raw path caches per Db on first
//!   use instead.

const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;

/// One statement per entry: the raw path prepares a single statement at a
/// time (sqlite3_prepare_v2 stops at the first), so a multi-statement string
/// would silently create only the first table.
pub const schema_statements = [_][:0]const u8{
    "CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY)",
    \\CREATE TABLE IF NOT EXISTS datasets (
    \\  id TEXT, projectID TEXT, metadata TEXT,
    \\  PRIMARY KEY (projectID, id)
    \\)
    ,
    \\CREATE TABLE IF NOT EXISTS tables (
    \\  id TEXT, projectID TEXT, datasetID TEXT, metadata TEXT,
    \\  PRIMARY KEY (projectID, datasetID, id)
    \\)
    ,
    \\CREATE TABLE IF NOT EXISTS jobs (
    \\  id TEXT, projectID TEXT, metadata TEXT, result TEXT, error TEXT,
    \\  PRIMARY KEY (projectID, id)
    \\)
    ,
};

pub const Repository = struct {
    db: *driver.Db,

    pub fn init(db: *driver.Db) !Repository {
        var r = Repository{ .db = db };
        for (schema_statements) |stmt| try r.db.rawExec(stmt, &.{});
        return r;
    }

    // ---- projects ----

    pub fn addProjectIfNotExists(r: *Repository, project_id: []const u8) !void {
        try r.db.rawExec(
            "INSERT OR IGNORE INTO projects (id) VALUES (?)",
            &.{.{ .value = .{ .text = project_id } }},
        );
    }

    // ---- datasets ----

    pub fn addDataset(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
        metadata_json: []const u8,
    ) !void {
        try r.db.rawExec(
            "INSERT OR REPLACE INTO datasets (id, projectID, metadata) VALUES (?, ?, ?)",
            &.{
                .{ .value = .{ .text = dataset_id } },
                .{ .value = .{ .text = project_id } },
                .{ .value = .{ .text = metadata_json } },
            },
        );
    }

    pub fn datasetExists(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !bool {
        var rows = try r.db.rawQuery(
            "SELECT 1 FROM datasets WHERE projectID = ? AND id = ?",
            &.{
                .{ .value = .{ .text = project_id } },
                .{ .value = .{ .text = dataset_id } },
            },
        );
        defer rows.deinit();
        return (try rows.next()) != null;
    }

    /// Dataset ids in insertion-stable (id) order. Caller owns the slice and
    /// its contents, allocated from `arena`.
    pub fn listDatasets(
        r: *Repository,
        arena: std.mem.Allocator,
        project_id: []const u8,
    ) ![]const []const u8 {
        var rows = try r.db.rawQuery(
            "SELECT id FROM datasets WHERE projectID = ? ORDER BY id",
            &.{.{ .value = .{ .text = project_id } }},
        );
        defer rows.deinit();

        var out: std.ArrayList([]const u8) = .empty;
        while (try rows.next()) |row| {
            try out.append(arena, try arena.dupe(u8, row[0].text));
        }
        return out.toOwnedSlice(arena);
    }

    pub fn deleteDataset(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !void {
        try r.db.rawExec(
            "DELETE FROM datasets WHERE projectID = ? AND id = ?",
            &.{
                .{ .value = .{ .text = project_id } },
                .{ .value = .{ .text = dataset_id } },
            },
        );
    }

    // ---- tables ----

    pub fn addTable(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
        metadata_json: []const u8,
    ) !void {
        try r.db.rawExec(
            "INSERT OR REPLACE INTO tables (id, projectID, datasetID, metadata) VALUES (?, ?, ?, ?)",
            &.{
                .{ .value = .{ .text = table_id } },
                .{ .value = .{ .text = project_id } },
                .{ .value = .{ .text = dataset_id } },
                .{ .value = .{ .text = metadata_json } },
            },
        );
    }

    /// Stored table metadata JSON, or null. Allocated from `arena`.
    pub fn findTable(
        r: *Repository,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !?[]const u8 {
        var rows = try r.db.rawQuery(
            "SELECT metadata FROM tables WHERE projectID = ? AND datasetID = ? AND id = ?",
            &.{
                .{ .value = .{ .text = project_id } },
                .{ .value = .{ .text = dataset_id } },
                .{ .value = .{ .text = table_id } },
            },
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return null;
        return try arena.dupe(u8, row[0].text);
    }

    pub fn listTables(
        r: *Repository,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
    ) ![]const []const u8 {
        var rows = try r.db.rawQuery(
            "SELECT metadata FROM tables WHERE projectID = ? AND datasetID = ? ORDER BY id",
            &.{
                .{ .value = .{ .text = project_id } },
                .{ .value = .{ .text = dataset_id } },
            },
        );
        defer rows.deinit();

        var out: std.ArrayList([]const u8) = .empty;
        while (try rows.next()) |row| {
            try out.append(arena, try arena.dupe(u8, row[0].text));
        }
        return out.toOwnedSlice(arena);
    }

    pub fn deleteTable(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !void {
        try r.db.rawExec(
            "DELETE FROM tables WHERE projectID = ? AND datasetID = ? AND id = ?",
            &.{
                .{ .value = .{ .text = project_id } },
                .{ .value = .{ .text = dataset_id } },
                .{ .value = .{ .text = table_id } },
            },
        );
    }

    pub fn deleteTablesInDataset(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !void {
        try r.db.rawExec(
            "DELETE FROM tables WHERE projectID = ? AND datasetID = ?",
            &.{
                .{ .value = .{ .text = project_id } },
                .{ .value = .{ .text = dataset_id } },
            },
        );
    }
};

const testing = std.testing;

test "datasets round-trip and list in id order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    var repo = try Repository.init(db);

    try repo.addProjectIfNotExists("p");
    try repo.addDataset("p", "b_ds", "{\"id\":\"b_ds\"}");
    try repo.addDataset("p", "a_ds", "{\"id\":\"a_ds\"}");

    try testing.expect(try repo.datasetExists("p", "a_ds"));
    try testing.expect(!try repo.datasetExists("p", "missing"));

    const ids = try repo.listDatasets(arena, "p");
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("a_ds", ids[0]);
    try testing.expectEqualStrings("b_ds", ids[1]);

    try repo.deleteDataset("p", "a_ds");
    try testing.expect(!try repo.datasetExists("p", "a_ds"));
}

test "tables round-trip, and metadata JSON survives verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    var repo = try Repository.init(db);

    // Unknown fields must survive: Go stores the raw map for this reason.
    const meta =
        \\{"tableReference":{"tableId":"t1"},"someFutureField":{"a":[1,2]}}
    ;
    try repo.addTable("p", "ds", "t1", meta);
    try testing.expectEqualStrings(meta, (try repo.findTable(arena, "p", "ds", "t1")).?);
    try testing.expectEqual(
        @as(?[]const u8, null),
        try repo.findTable(arena, "p", "ds", "missing"),
    );

    try repo.addTable("p", "ds", "t2", "{}");
    try testing.expectEqual(@as(usize, 2), (try repo.listTables(arena, "p", "ds")).len);

    // Same id in a different dataset is a distinct row.
    try repo.addTable("p", "other", "t1", "{}");
    try testing.expectEqual(@as(usize, 1), (try repo.listTables(arena, "p", "other")).len);

    try repo.deleteTable("p", "ds", "t1");
    try testing.expectEqual(@as(usize, 1), (try repo.listTables(arena, "p", "ds")).len);

    try repo.deleteTablesInDataset("p", "ds");
    try testing.expectEqual(@as(usize, 0), (try repo.listTables(arena, "p", "ds")).len);
    // Other datasets are untouched.
    try testing.expectEqual(@as(usize, 1), (try repo.listTables(arena, "p", "other")).len);
}

test "re-adding a table replaces its metadata" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    var repo = try Repository.init(db);

    try repo.addTable("p", "ds", "t", "{\"v\":1}");
    try repo.addTable("p", "ds", "t", "{\"v\":2}");
    try testing.expectEqualStrings("{\"v\":2}", (try repo.findTable(arena, "p", "ds", "t")).?);
    try testing.expectEqual(@as(usize, 1), (try repo.listTables(arena, "p", "ds")).len);
}

test "metadata tables stay invisible to the GoogleSQL catalog" {
    // They are plain SQLite, reached only through the raw path — Go achieves
    // the same with WithQueryFormattingDisabled.
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    var repo = try Repository.init(db);
    try repo.addDataset("p", "ds", "{}");

    try testing.expectError(
        error.AnalyzeFailed,
        db.query("SELECT * FROM datasets", &.{}, .{}),
    );
}
