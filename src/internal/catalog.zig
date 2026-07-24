//! Port of go-zetasqlite internal/catalog.go (table subset).
//!
//! The persisted side is byte-faithful: the `zetasqlite_catalog` DDL, the
//! upsert/delete SQL and the JSON `spec` column all match Go, so a database
//! written by go-zetasqlite loads here and vice versa.
//!
//! The in-memory side is redesigned per the port plan: where Go builds a
//! live googlesql.SimpleCatalog through the engine API, this port renders a
//! `SimpleCatalogProto` in protobuf-JSON form (catalogJson) that the C++
//! analyzer shim deserializes per statement. Go's dotted-path registration
//! (addTableSpecRecursive: the full dotted name plus every suffix at the
//! root, and sub-catalogs per path segment) is mirrored structurally with
//! nested `catalog` entries; every SimpleTableProto carries
//! `name`=canonical ("_"-joined SQLite table name, what Table.Name()
//! reports back through the resolved AST) and `nameInCatalog`=the name it
//! resolves under.
//!
//! Deferred (vs Go):
//! - FunctionSpec rows (`kind = 'function'`): tolerated during sync but not
//!   registered (CREATE FUNCTION milestone).
//! - Wildcard tables (Gap G): not ported.
//! - MISSING_FUNCTIONS seeding: function milestone.

const std = @import("std");
const sqlite = @import("../sqlite.zig");
const spec = @import("spec.zig");
const pb = @import("../proto/resolved_ast.zig");
const value_mod = @import("value.zig");

pub const Error = error{
    OutOfMemory,
    SQLite,
    /// A catalog row's spec JSON failed to decode.
    InvalidSpec,
    /// DeleteTableSpec on a name that is not in the catalog (Go: "failed to
    /// find table spec from map by %s").
    TableNotFound,
};

// Exact SQL from Go catalog.go (multi-line shape preserved).
pub const create_catalog_table_query =
    \\
    \\CREATE TABLE IF NOT EXISTS zetasqlite_catalog(
    \\  name STRING NOT NULL PRIMARY KEY,
    \\  kind STRING NOT NULL,
    \\  spec STRING NOT NULL,
    \\  updatedAt TIMESTAMP NOT NULL,
    \\  createdAt TIMESTAMP NOT NULL
    \\)
    \\
;
pub const index_catalog_table_query =
    \\
    \\CREATE INDEX IF NOT EXISTS catalog_last_updated_index ON zetasqlite_catalog(updatedAt DESC);
    \\
;
const upsert_catalog_query =
    \\
    \\INSERT INTO zetasqlite_catalog (
    \\  name,
    \\  kind,
    \\  spec,
    \\  updatedAt,
    \\  createdAt
    \\) VALUES (
    \\  @name,
    \\  @kind,
    \\  @spec,
    \\  @updatedAt,
    \\  @createdAt
    \\) ON CONFLICT(name) DO UPDATE SET
    \\  spec = @spec,
    \\  updatedAt = @updatedAt
    \\
;
const delete_catalog_query =
    \\
    \\DELETE FROM zetasqlite_catalog WHERE name = @name
    \\
;
const sync_query =
    "SELECT name, kind, spec FROM zetasqlite_catalog WHERE updatedAt >= @lastUpdatedAt";

/// Go CatalogSpecKind values.
pub const table_spec_kind = "table";
pub const view_spec_kind = "view";
pub const function_spec_kind = "function";
const catalog_name = "zetasqlite";

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    /// Owns every stored TableSpec and all derived strings.
    arena_state: std.heap.ArenaAllocator,
    /// Insertion-ordered specs (Go: c.tables). catalogJson renders from this.
    tables: std.ArrayList(*spec.TableSpec),
    /// Canonical table name -> index into `tables` (Go: c.tableMap).
    table_map: std.StringHashMap(usize),
    /// Timestamp string of the last sync ("" = never; sorts before any
    /// stored timestamp, so the first sync loads everything).
    last_synced_at: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!*Catalog {
        const c = try gpa.create(Catalog);
        c.* = .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .tables = .empty,
            .table_map = std.StringHashMap(usize).init(gpa),
        };
        return c;
    }

    pub fn deinit(c: *Catalog) void {
        c.tables.deinit(c.gpa);
        c.table_map.deinit();
        c.arena_state.deinit();
        c.gpa.destroy(c);
    }

    /// Go createCatalogTablesIfNotExists.
    pub fn createCatalogTablesIfNotExist(c: *Catalog, db: *sqlite.Db) Error!void {
        _ = c;
        try db.exec(create_catalog_table_query);
        try db.exec(index_catalog_table_query);
    }

    /// Go Catalog.Sync: incremental load of every row updated since the
    /// last sync. Function rows are skipped (deferred milestone) rather
    /// than failing the sync.
    pub fn sync(c: *Catalog, db: *sqlite.Db) Error!void {
        try c.createCatalogTablesIfNotExist(db);
        const now = try nowTimestamps(c.arena_state.allocator());

        var stmt = try db.prepare(sync_query);
        defer stmt.finalize();
        try stmt.bindText(1, c.last_synced_at);
        while (try stmt.step()) {
            const kind = stmt.columnText(1);
            if (std.mem.eql(u8, kind, table_spec_kind) or std.mem.eql(u8, kind, view_spec_kind)) {
                // Copy out of sqlite's row buffer before the next step().
                const spec_json = try c.arena_state.allocator().dupe(u8, stmt.columnText(2));
                try c.loadTableSpec(spec_json);
            } else if (std.mem.eql(u8, kind, function_spec_kind)) {
                // Deferred: CREATE FUNCTION milestone.
                continue;
            } else {
                return error.InvalidSpec; // Go: "unknown catalog spec kind %s"
            }
        }
        c.last_synced_at = now.sql;
    }

    fn loadTableSpec(c: *Catalog, spec_json: []const u8) Error!void {
        const table_spec = spec.tableSpecFromJson(c.arena_state.allocator(), spec_json) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSpec,
            };
        try c.addTableSpecToMemory(table_spec);
    }

    /// Go AddNewTableSpec: in-memory registration plus (unless temporary)
    /// the persisted upsert. The spec is deep-copied into the catalog arena
    /// (via its canonical JSON), so callers may pass short-lived memory.
    pub fn addNewTableSpec(c: *Catalog, db: *sqlite.Db, table_spec: *const spec.TableSpec) Error!void {
        const arena = c.arena_state.allocator();
        const encoded = table_spec.toJson(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        const owned = spec.tableSpecFromJson(arena, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        try c.addTableSpecToMemory(owned);
        if (!owned.is_temp) {
            try c.saveTableSpec(db, owned, encoded);
        }
    }

    /// Go saveTableSpec: the upsert. `encoded` is the spec's JSON.
    fn saveTableSpec(c: *Catalog, db: *sqlite.Db, table_spec: *const spec.TableSpec, encoded: []const u8) Error!void {
        const arena = c.arena_state.allocator();
        const now = try nowTimestamps(arena);
        const kind: []const u8 = if (table_spec.is_view) view_spec_kind else table_spec_kind;

        var stmt = try db.prepare(upsert_catalog_query);
        defer stmt.finalize();
        // Named-parameter indices in first-occurrence order: @name, @kind,
        // @spec, @updatedAt, @createdAt (the DO UPDATE reuses 3 and 4).
        try stmt.bindText(1, try table_spec.tableName(arena));
        try stmt.bindText(2, kind);
        try stmt.bindText(3, encoded);
        try stmt.bindText(4, now.sql);
        try stmt.bindText(5, now.sql);
        _ = try stmt.step();
    }

    /// Go DeleteTableSpec: remove from memory and from the persisted table.
    pub fn deleteTableSpec(c: *Catalog, db: *sqlite.Db, name: []const u8) Error!void {
        const entry = c.table_map.fetchRemove(name) orelse return error.TableNotFound;
        _ = c.tables.orderedRemove(entry.value);
        // Reindex the map entries that shifted down.
        var it = c.table_map.valueIterator();
        while (it.next()) |idx| {
            if (idx.* > entry.value) idx.* -= 1;
        }

        var stmt = try db.prepare(delete_catalog_query);
        defer stmt.finalize();
        try stmt.bindText(1, name);
        _ = try stmt.step();
    }

    /// Number of registered (non-deleted) table specs.
    pub fn tableCount(c: *const Catalog) usize {
        return c.tables.items.len;
    }

    pub fn findTableSpec(c: *const Catalog, name: []const u8) ?*spec.TableSpec {
        const idx = c.table_map.get(name) orelse return null;
        return c.tables.items[idx];
    }

    /// Go addTableSpec's in-memory half. On a duplicate canonical name the
    /// stored spec is replaced (Go only swaps the map entry and leaves the
    /// engine catalog with the first registration; since this port
    /// re-renders catalogJson per statement, the replacement becomes
    /// visible immediately — a deliberate, strictly-more-correct deviation).
    fn addTableSpecToMemory(c: *Catalog, table_spec: *spec.TableSpec) Error!void {
        const arena = c.arena_state.allocator();
        const table_name = try table_spec.tableName(arena);
        if (c.table_map.get(table_name)) |idx| {
            c.tables.items[idx] = table_spec;
            return;
        }
        try c.tables.append(c.gpa, table_spec);
        try c.table_map.put(table_name, c.tables.items.len - 1);
    }

    // ------------------------------------------------------------------
    // SimpleCatalogProto JSON rendering (replaces Go's live SimpleCatalog)
    // ------------------------------------------------------------------

    /// Renders the catalog as SimpleCatalogProto protobuf-JSON for the
    /// analyzer shim. Returns "{}" (builtins only) when no tables are
    /// registered. All memory comes from `alloc`.
    pub fn catalogJson(c: *const Catalog, alloc: std.mem.Allocator) error{ OutOfMemory, InvalidSpec }![:0]u8 {
        if (c.tables.items.len == 0) return alloc.dupeZ(u8, "{}");

        var root = Node{ .name = catalog_name };
        for (c.tables.items) |table_spec| {
            const canonical = try table_spec.tableName(alloc);
            try addTableToNode(alloc, &root, table_spec.name_path, table_spec, canonical);
        }

        var out: std.ArrayList(u8) = .empty;
        try appendNodeJson(&out, alloc, &root);
        try out.append(alloc, 0);
        const bytes = try out.toOwnedSlice(alloc);
        return bytes[0 .. bytes.len - 1 :0];
    }
};

/// One registration point: the table resolves under `registered` and
/// reports `canonical` as its Name() (Go createSimpleTable's canonicalName).
const TableEntry = struct {
    registered: []const u8,
    canonical: []const u8,
    table_spec: *const spec.TableSpec,
};

/// In-flight SimpleCatalogProto tree node.
const Node = struct {
    name: []const u8,
    entries: std.ArrayList(TableEntry) = .empty,
    subs: std.ArrayList(*Node) = .empty,

    fn findSub(n: *Node, name: []const u8) ?*Node {
        for (n.subs.items) |sub| {
            if (std.mem.eql(u8, sub.name, name)) return sub;
        }
        return null;
    }

    fn hasEntry(n: *const Node, registered: []const u8) bool {
        for (n.entries.items) |e| {
            if (std.mem.eql(u8, e.registered, registered)) return true;
        }
        return false;
    }
};

/// Go addTableSpecRecursive: for a path [a, b, c] register "a.b.c", "b.c"
/// and "c" at the current level, plus sub-catalogs a -> {"b.c", "c",
/// b -> {"c"}} — with AddOwnedTableIfNotPresent duplicate-name semantics.
fn addTableToNode(
    alloc: std.mem.Allocator,
    node: *Node,
    path: []const []const u8,
    table_spec: *const spec.TableSpec,
    canonical: []const u8,
) error{ OutOfMemory, InvalidSpec }!void {
    if (path.len == 0) return error.InvalidSpec; // Go: "table name is not found"
    if (path.len == 1) {
        if (!node.hasEntry(path[0])) {
            try node.entries.append(alloc, .{
                .registered = path[0],
                .canonical = canonical,
                .table_spec = table_spec,
            });
        }
        return;
    }
    const sub = node.findSub(path[0]) orelse blk: {
        const s = try alloc.create(Node);
        s.* = .{ .name = path[0] };
        try node.subs.append(alloc, s);
        break :blk s;
    };
    const dotted = try std.mem.join(alloc, ".", path);
    if (!node.hasEntry(dotted)) {
        try node.entries.append(alloc, .{
            .registered = dotted,
            .canonical = canonical,
            .table_spec = table_spec,
        });
    }
    try addTableToNode(alloc, node, path[1..], table_spec, canonical);
    try addTableToNode(alloc, sub, path[1..], table_spec, canonical);
}

fn appendNodeJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, node: *const Node) error{ OutOfMemory, InvalidSpec }!void {
    try out.appendSlice(alloc, "{\"name\":");
    try spec.appendJsonString(out, alloc, node.name);
    if (node.entries.items.len > 0) {
        try out.appendSlice(alloc, ",\"table\":[");
        for (node.entries.items, 0..) |entry, i| {
            if (i > 0) try out.append(alloc, ',');
            try appendTableJson(out, alloc, entry);
        }
        try out.append(alloc, ']');
    }
    if (node.subs.items.len > 0) {
        try out.appendSlice(alloc, ",\"catalog\":[");
        for (node.subs.items, 0..) |sub, i| {
            if (i > 0) try out.append(alloc, ',');
            try appendNodeJson(out, alloc, sub);
        }
        try out.append(alloc, ']');
    }
    try out.append(alloc, '}');
}

fn appendTableJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, entry: TableEntry) error{ OutOfMemory, InvalidSpec }!void {
    try out.appendSlice(alloc, "{\"name\":");
    try spec.appendJsonString(out, alloc, entry.canonical);
    if (!std.mem.eql(u8, entry.registered, entry.canonical)) {
        try out.appendSlice(alloc, ",\"nameInCatalog\":");
        try spec.appendJsonString(out, alloc, entry.registered);
    }
    try out.appendSlice(alloc, ",\"column\":[");
    for (entry.table_spec.columns, 0..) |col, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"name\":");
        try spec.appendJsonString(out, alloc, col.name);
        try out.appendSlice(alloc, ",\"type\":");
        try appendTypeProtoJson(out, alloc, col.type);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]}");
}

/// TypeProto protobuf-JSON: {"typeKind":"TYPE_*"} with nested
/// arrayType.elementType / structType.field[].fieldName+fieldType
/// (lowerCamelCase per protobuf JSON; verified against
/// googlesql/public/type.proto).
fn appendTypeProtoJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, t: *const spec.Type) error{ OutOfMemory, InvalidSpec }!void {
    const kind_name = std.enums.tagName(pb.TypeKind, t.typeKind()) orelse return error.InvalidSpec;
    try out.appendSlice(alloc, "{\"typeKind\":\"");
    try out.appendSlice(alloc, kind_name);
    try out.append(alloc, '"');
    switch (t.typeKind()) {
        .TYPE_ARRAY => {
            const elem = t.element_type orelse return error.InvalidSpec;
            try out.appendSlice(alloc, ",\"arrayType\":{\"elementType\":");
            try appendTypeProtoJson(out, alloc, elem);
            try out.appendSlice(alloc, "}");
        },
        .TYPE_STRUCT => {
            try out.appendSlice(alloc, ",\"structType\":{\"field\":[");
            for (t.field_types, 0..) |field, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, "{\"fieldName\":");
                try spec.appendJsonString(out, alloc, field.name);
                try out.appendSlice(alloc, ",\"fieldType\":");
                const ft = field.type orelse return error.InvalidSpec;
                try appendTypeProtoJson(out, alloc, ft);
                try out.append(alloc, '}');
            }
            try out.appendSlice(alloc, "]}");
        },
        else => {},
    }
    try out.append(alloc, '}');
}

// ----------------------------------------------------------------------
// Timestamps
// ----------------------------------------------------------------------

const Timestamps = struct {
    /// SQL column form, comparable lexicographically with other rows this
    /// port writes: "YYYY-MM-DD HH:MM:SS.micros+00:00" (UTC rendering of
    /// go-sqlite3's timestamp layout).
    sql: []const u8,
    /// RFC3339 for spec JSON updatedAt/createdAt (Go time.Time layout).
    rfc3339: []const u8,
};

pub fn nowTimestamps(alloc: std.mem.Allocator) error{OutOfMemory}!Timestamps {
    // Zig 0.16 moved wall-clock reads behind std.Io; libc is already linked,
    // so read the realtime clock directly.
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const micros = @as(i64, @intCast(tv.sec)) * std.time.us_per_s + @as(i64, @intCast(tv.usec));
    return timestampsFromMicros(alloc, micros);
}

fn timestampsFromMicros(alloc: std.mem.Allocator, micros: i64) error{OutOfMemory}!Timestamps {
    const secs = @divFloor(micros, std.time.us_per_s);
    const us: u64 = @intCast(@mod(micros, std.time.us_per_s));
    const days = @divFloor(secs, std.time.s_per_day);
    const day_secs: u64 = @intCast(@mod(secs, std.time.s_per_day));
    const civil = value_mod.civilFromDays(days);
    const yr: u64 = @intCast(civil.year); // post-1970 in practice
    const hh = day_secs / 3600;
    const mm = (day_secs % 3600) / 60;
    const ss = day_secs % 60;
    return .{
        .sql = try std.fmt.allocPrint(
            alloc,
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}+00:00",
            .{ yr, civil.month, civil.day, hh, mm, ss, us },
        ),
        .rfc3339 = try std.fmt.allocPrint(
            alloc,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z",
            .{ yr, civil.month, civil.day, hh, mm, ss, us },
        ),
    };
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const analyzer_ffi = @import("../analyzer_ffi.zig");

fn testTableSpec(alloc: std.mem.Allocator, name_path: []const []const u8) !*spec.TableSpec {
    const col_a = try alloc.create(spec.ColumnSpec);
    col_a.* = .{ .name = "a", .type = try spec.newSimpleType(alloc, .TYPE_INT64) };
    const col_b = try alloc.create(spec.ColumnSpec);
    col_b.* = .{ .name = "b", .type = try spec.newSimpleType(alloc, .TYPE_STRING) };
    const ts = try alloc.create(spec.TableSpec);
    ts.* = .{
        .name_path = name_path,
        .columns = try alloc.dupe(*spec.ColumnSpec, &.{ col_a, col_b }),
        .create_mode = spec.create_mode_create_default,
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    return ts;
}

test "timestamp formatting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // 2024-01-02T03:04:05.123456Z
    const micros: i64 = (value_mod.daysFromCivil(2024, 1, 2) * std.time.s_per_day +
        3 * 3600 + 4 * 60 + 5) * std.time.us_per_s + 123456;
    const t = try timestampsFromMicros(arena_state.allocator(), micros);
    try testing.expectEqualStrings("2024-01-02 03:04:05.123456+00:00", t.sql);
    try testing.expectEqualStrings("2024-01-02T03:04:05.123456Z", t.rfc3339);
}

test "addNewTableSpec persists a row and a fresh catalog syncs it" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c1 = try Catalog.init(testing.allocator);
    defer c1.deinit();
    try c1.createCatalogTablesIfNotExist(&db);
    try c1.addNewTableSpec(&db, try testTableSpec(alloc, &.{"t1"}));
    try testing.expectEqual(@as(usize, 1), c1.tableCount());

    // The persisted row exists with the Go schema/kind and decodable spec.
    {
        var stmt = try db.prepare("SELECT name, kind, spec FROM zetasqlite_catalog");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqualStrings("t1", stmt.columnText(0));
        try testing.expectEqualStrings("table", stmt.columnText(1));
        const decoded = try spec.tableSpecFromJson(alloc, stmt.columnText(2));
        try testing.expectEqual(@as(usize, 2), decoded.columns.len);
        try testing.expectEqualStrings("a", decoded.columns[0].name);
        try testing.expect(!(try stmt.step()));
    }

    // A brand-new Catalog over the same connection picks it up via sync.
    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.sync(&db);
    try testing.expectEqual(@as(usize, 1), c2.tableCount());
    const found = c2.findTableSpec("t1") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("b", found.columns[1].name);

    // Incremental: a second sync with nothing new loads nothing extra.
    try c2.sync(&db);
    try testing.expectEqual(@as(usize, 1), c2.tableCount());

    // Delete removes both memory and the persisted row.
    try c1.deleteTableSpec(&db, "t1");
    try testing.expectEqual(@as(usize, 0), c1.tableCount());
    try testing.expectEqual(@as(?*spec.TableSpec, null), c1.findTableSpec("t1"));
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM zetasqlite_catalog");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
    }
    try testing.expectError(error.TableNotFound, c1.deleteTableSpec(&db, "t1"));
}

test "temp table spec is registered in memory but not persisted" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c = try Catalog.init(testing.allocator);
    defer c.deinit();
    try c.createCatalogTablesIfNotExist(&db);
    const ts = try testTableSpec(alloc, &.{"tmp1"});
    ts.is_temp = true;
    try c.addNewTableSpec(&db, ts);
    try testing.expectEqual(@as(usize, 1), c.tableCount());

    var stmt = try db.prepare("SELECT COUNT(*) FROM zetasqlite_catalog");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
}

test "catalogJson: analyzer resolves bare and dotted table names" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c = try Catalog.init(testing.allocator);
    defer c.deinit();
    try c.createCatalogTablesIfNotExist(&db);
    try c.addNewTableSpec(&db, try testTableSpec(alloc, &.{"t1"}));
    try c.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "proj", "ds", "t2" }));

    const catalog_json = try c.catalogJson(alloc);

    // Bare name.
    {
        const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, "SELECT a, b FROM t1", 0, catalog_json);
        try testing.expectEqualStrings("t1", try resolvedTableName(analyzed.node));
    }
    // Dotted path: resolves through sub-catalogs; Table.Name() reports the
    // canonical "_"-joined SQLite name.
    {
        const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, "SELECT a FROM proj.ds.t2", 0, catalog_json);
        try testing.expectEqualStrings("proj_ds_t2", try resolvedTableName(analyzed.node));
    }
    // Backticked full path (single identifier containing dots).
    {
        const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, "SELECT a FROM `proj.ds.t2`", 0, catalog_json);
        try testing.expectEqualStrings("proj_ds_t2", try resolvedTableName(analyzed.node));
    }
    // Path suffix, like Go's recursive registration allows.
    {
        const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, "SELECT a FROM ds.t2", 0, catalog_json);
        try testing.expectEqualStrings("proj_ds_t2", try resolvedTableName(analyzed.node));
    }
    // Unknown tables still fail.
    try testing.expectError(
        error.AnalyzeFailed,
        analyzer_ffi.analyzeNextStatement(alloc, "SELECT 1 FROM missing_table", 0, catalog_json),
    );

    // Empty catalog renders the shim's builtins-only sentinel.
    var empty = try Catalog.init(testing.allocator);
    defer empty.deinit();
    try testing.expectEqualStrings("{}", try empty.catalogJson(alloc));
}

/// Walks stmt -> query -> (project scan ->) table scan and returns the
/// resolved TableRefProto name.
fn resolvedTableName(node: *const pb.AnyResolvedNodeProto) ![]const u8 {
    const stmt = node.node.?.resolved_statement_node;
    const query = stmt.node.?.resolved_query_stmt_node;
    var scan = query.query.?;
    while (true) {
        switch (scan.node.?) {
            .resolved_project_scan_node => |p| scan = p.input_scan.?,
            .resolved_table_scan_node => |t| return t.table.?.name.?,
            else => return error.TestUnexpectedResult,
        }
    }
}
