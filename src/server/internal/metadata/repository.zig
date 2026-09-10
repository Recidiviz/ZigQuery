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
//! - models and routines arrive with their handlers,
//!   and a table's resource rides on its engine catalog spec
//!   (`TableSpec.metadata`), where DDL and the metadata API cannot disagree.
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
