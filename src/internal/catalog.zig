//! The GoogleSQL catalog: the tables, views, functions and datasets the engine knows, persisted
//! in SQLite and rendered for the C++ analyzer shim.
//!
//! Each persisted object is one `zigquery_catalog` row, keyed on `(name, kind)`:
//! - `name` is the "_"-joined path
//! - `kind` is `table`, `view`, `function` or `dataset`
//! - `spec` holds the spec's JSON (see `create_catalog_table_query`).
//!  `loadFromStorage` reads every row once, at open.
//!
//! TEMP objects and synthetic registrations (INFORMATION_SCHEMA, query results) live in-memory only
//!
//! The analyzer sees the catalog as `SimpleCatalogProto` in protobuf-JSON form. A table registers
//! at the root under its full dotted name and every suffix of it, and under one nested `catalog`
//! entry per path segment. Each `SimpleTableProto` carries `name`, the canonical "_"-joined
//! SQLite table name the resolved AST reports back, and `nameInCatalog`, the name it resolves
//! under.
//!
//! Rendering is incremental. The shim holds a persistent catalog handle and this catalog keeps an
//! append-only change log; `renderDelta` hands a consumer's `Cursor` the entries it has not seen,
//! so a statement analyzed against an unchanged catalog renders nothing. `catalogJson`, the whole
//! tree in one proto, seeds a fresh handle and serves the stateless fallback path.
//!
//! Function specs render as `customFunction` entries (FunctionProto: namePath, mode, and a
//! signature with argument kinds and types). The catalog also seeds memory-only, bodyless
//! signatures for `contains_substr`, `min_by` and `max_by`, which the shim's GoogleSQL has no
//! builtins for; the extractor and runtime UDFs lower them.
//!
//! Wildcard tables are unsupported.
// ephor:ignore-file ZA303 ZT105

const std = @import("std");
const sqlite = @import("../sqlite.zig");
const spec = @import("spec.zig");
const pb = @import("../proto/resolved_ast.zig");
const value_mod = @import("value.zig");
const phase = @import("phase.zig");
const info_schema_vtab = @import("function/info_schema_vtab.zig");

pub const Error = error{
    OutOfMemory,
    SQLite,
    /// A catalog row's spec JSON failed to decode.
    InvalidSpec,
    /// Delete/Update on a table name that is not in the catalog.
    TableNotFound,
    /// deleteDatasetSpec on a dataset the catalog does not hold, or only
    /// inferred from a table's path.
    DatasetNotFound,
    /// An update aimed at a spec that is never persisted: a TEMP entry or a synthetic registration.
    NotPersistent,
};

const CatalogSpecKind = enum {
    table,
    view,
    function,
    dataset,
};

// The key is a rowid table's PRIMARY KEY, so `load_query`'s unordered scan walks insertion order.
pub const create_catalog_table_query =
    \\
    \\CREATE TABLE IF NOT EXISTS zigquery_catalog(
    \\  name STRING NOT NULL,
    \\  kind STRING NOT NULL,
    \\  spec STRING NOT NULL,
    \\  updatedAt TIMESTAMP NOT NULL,
    \\  createdAt TIMESTAMP NOT NULL,
    \\  PRIMARY KEY (name, kind)
    \\)
    \\
;
const upsert_catalog_query =
    \\
    \\INSERT INTO zigquery_catalog (
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
    \\) ON CONFLICT(name, kind) DO UPDATE SET
    \\  spec = @spec,
    \\  updatedAt = @updatedAt
    \\
;
const delete_catalog_query =
    \\
    \\DELETE FROM zigquery_catalog WHERE name = @name AND kind = @kind
    \\
;
const load_query = "SELECT name, kind, spec FROM zigquery_catalog";
const select_table_spec_query =
    \\
    \\SELECT spec FROM zigquery_catalog WHERE name = @name AND kind IN ('table', 'view')
    \\
;

const catalog_name = "zigquery";

/// One table change, in the order it happened. Names are canonical
/// ("_"-joined) and arena-owned, so an entry outlives the spec it describes.
pub const Change = union(enum) {
    table_added: []const u8,
    table_removed: []const u8,
};

/// One step in bringing an analyzer catalog handle up to a cursor's position.
pub const DeltaOp = union(enum) {
    /// Merge this proto into the handle.
    add_json: [:0]u8,
    /// Forget this table by canonical name.
    remove: [:0]const u8,
};

/// What a consumer must do to reach a cursor's position.
pub const Delta = struct {
    ops: []const DeltaOp,
    /// The ops describe the whole catalog rather than a change to it, so they
    /// only produce the right result when applied to a fresh handle.
    full: bool,
};

/// One consumer's position in a catalog's change log.
///
/// The log is append-only and shared, so each consumer (one per analyzer
/// catalog handle) tracks its own position rather than draining. `log_pos`
/// and `functions_seen` are indices into `changes` and `functions`;
/// `function_generation` mirrors the catalog's, and `needs_rebuild` forces a
/// full re-push after a failed apply.
pub const Cursor = struct {
    log_pos: usize = 0,
    functions_seen: usize = 0,
    function_generation: u64 = 0,
    needs_rebuild: bool = true,
};

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    /// Owns every stored TableSpec and all derived strings.
    arena_state: std.heap.ArenaAllocator,
    /// Insertion-ordered specs. catalogJson renders from this.
    ///
    /// A deleted table leaves a null tombstone rather than compacting the
    /// list: removing an element would shift every later index and force a
    /// full rescan of `table_map` to repair it, which is O(catalog) per drop
    /// on a path the emulator takes for every view materialization. Slots are
    /// never reused, so a `*spec.TableSpec` handed to a caller stays valid for
    /// the catalog's lifetime.
    tables: std.ArrayList(?*spec.TableSpec),
    /// Canonical table name -> index into `tables`. Only live (non-tombstoned) slots are
    /// referenced.
    table_map: std.StringHashMap(usize),
    /// Insertion-ordered function specs.
    functions: std.ArrayList(*spec.FunctionSpec),
    /// Canonical function name -> index into `functions`.
    func_map: std.StringHashMap(usize),
    /// Insertion-ordered datasets: every dataset the catalog has been told exists or has inferred
    /// from a table's path. A deleted dataset leaves a null tombstone, for the same reason
    /// `tables` does, and slots are never reused, so a `*spec.DatasetSpec` handed out stays valid
    /// for the catalog's lifetime. See `addNewDatasetSpec` and `ensureDataset`.
    datasets: std.ArrayList(?*spec.DatasetSpec),
    /// `project_dataset` -> index into `datasets`.
    dataset_map: std.StringHashMap(usize),
    /// Append-only, ordered log of table changes.
    ///
    /// A persistent analyzer catalog can be updated incrementally, but only
    /// if it is told what changed: additions are pushed as a delta, removals
    /// are removed by name. Recording the changes here is what keeps a DROP
    /// from costing O(catalog) — the emulator drops and recreates a table on
    /// every view materialization, so that cost dominates otherwise.
    ///
    /// Never truncated. Entries are read at a `Cursor` rather than drained so
    /// that several consumers — one per analyzer catalog handle, i.e. one per
    /// pooled connection — can each replay from their own position.
    changes: std.ArrayList(Change),
    /// Canonical table name -> `shapeFingerprint` of the spec registered under it. Kept for every
    /// name registered through `addTableSpecToMemory`, so checking whether a view is due for a
    /// refresh is a lookup per dependency rather than a render.
    fingerprints: std.StringHashMap(u64),
    /// Canonical names of every table and view whose `zigquery_catalog` row was written or
    /// deleted, in order. Append-only, like `changes`. A connection that rolls back a transaction
    /// reads back the rows of the names written since it began; see `resyncTableSpecs`.
    written_table_names: std.ArrayList([]const u8),

    /// Bumped by any change that cannot be expressed as a table delta.
    ///
    /// Function removals have no incremental path: the analyzer catalog has
    /// no "forget this function" operation, and a merge that skips entries
    /// already present would silently keep the stale definition. A consumer
    /// compares this against the generation its `Cursor` last saw and
    /// rebuilds from scratch when it differs.
    function_generation: u64 = 0,

    /// Whether this cursor's consumer can be brought up to date incrementally,
    /// or needs a fresh handle re-pushed from scratch. A function removal has
    /// no incremental path, and a previous apply may have failed partway.
    pub fn needsRebuild(c: *const Catalog, cur: Cursor) bool {
        return cur.needs_rebuild or cur.function_generation != c.function_generation;
    }

    /// The changes this cursor has not seen, without advancing it.
    pub fn changesSince(c: *const Catalog, cur: Cursor) []const Change {
        if (cur.log_pos >= c.changes.items.len) return &.{};
        return c.changes.items[cur.log_pos..];
    }

    /// Renders everything `cur` has not seen as operations to apply to an
    /// analyzer catalog handle, and advances `cur` past them.
    ///
    /// Every byte the caller needs is copied into `alloc` here, so the
    /// returned ops stay valid after the catalog is released. That is what
    /// lets the expensive half — pushing into C++ and then analyzing — happen
    /// without holding the catalog.
    ///
    /// Order is preserved: a table created and then dropped must end up
    /// absent. Runs of consecutive additions coalesce into one push, so a bulk
    /// load stays a single merge rather than one merge per table.
    ///
    /// A `full` delta describes the whole catalog and assumes a *fresh*
    /// handle — the caller must recreate it before applying. Two sources push
    /// into one handle (persistent plus TEMP overlay), so when either renders
    /// full the other must too, or the fresh handle loses whatever the
    /// incremental side thought it already held.
    pub fn renderDelta(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        cur: *Cursor,
    ) error{ OutOfMemory, InvalidSpec }!Delta {
        var ops: std.ArrayList(DeltaOp) = .empty;

        if (c.needsRebuild(cur.*)) {
            try ops.append(alloc, .{ .add_json = try c.catalogJson(alloc) });
            c.advance(cur);
            return .{ .ops = ops.items, .full = true };
        }

        var pending: std.ArrayList(*spec.TableSpec) = .empty;
        for (c.changesSince(cur.*)) |ch| switch (ch) {
            .table_added => |name| {
                // A name added and later replaced resolves to the current
                // spec, which is the definition the consumer should end up
                // with either way.
                if (c.tableSpecByName(name)) |s| try pending.append(alloc, s);
            },
            .table_removed => |name| {
                try flushAdditions(c, alloc, &ops, &pending);
                try ops.append(alloc, .{ .remove = try alloc.dupeSentinel(u8, name, 0) });
            },
        };
        try flushAdditions(c, alloc, &ops, &pending);

        if (cur.functions_seen != c.functions.items.len) {
            try ops.append(alloc, .{
                .add_json = try c.functionJsonFrom(alloc, cur.functions_seen),
            });
        }

        c.advance(cur);
        return .{ .ops = ops.items, .full = false };
    }

    fn flushAdditions(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        ops: *std.ArrayList(DeltaOp),
        pending: *std.ArrayList(*spec.TableSpec),
    ) error{ OutOfMemory, InvalidSpec }!void {
        if (pending.items.len == 0) return;
        try ops.append(alloc, .{
            .add_json = try c.catalogJsonForSpecs(alloc, pending.items),
        });
        pending.* = .empty;
    }

    /// Moves `cur` past everything currently logged. Non-destructive: other
    /// consumers keep their own positions.
    pub fn advance(c: *const Catalog, cur: *Cursor) void {
        cur.log_pos = c.changes.items.len;
        cur.functions_seen = c.functions.items.len;
        cur.function_generation = c.function_generation;
        cur.needs_rebuild = false;
    }

    /// Spec currently registered under a canonical name, if any.
    pub fn tableSpecByName(c: *const Catalog, name: []const u8) ?*spec.TableSpec {
        const idx = c.table_map.get(name) orelse return null;
        return c.tables.items[idx];
    }

    /// Every live spec, tombstones skipped, in registration order.
    pub fn liveTableSpecs(
        c: *const Catalog,
        alloc: std.mem.Allocator,
    ) error{OutOfMemory}![]*spec.TableSpec {
        var out = try std.ArrayList(*spec.TableSpec).initCapacity(alloc, c.table_map.count());
        for (c.tables.items) |maybe| {
            if (maybe) |table_spec| out.appendAssumeCapacity(table_spec);
        }
        return out.items;
    }

    /// Renders a SimpleCatalogProto containing exactly `specs`.
    pub fn catalogJsonForSpecs(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        specs: []const *spec.TableSpec,
    ) error{ OutOfMemory, InvalidSpec }![:0]u8 {
        _ = c;
        if (specs.len == 0) return alloc.dupeSentinel(u8, "{}", 0);
        var root = Node{ .name = catalog_name };
        for (specs) |table_spec| {
            const canonical = try table_spec.tableName(alloc);
            try addTableToNode(alloc, &root, table_spec.name_path, table_spec, canonical);
        }
        return renderNode(alloc, &root);
    }

    pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!*Catalog {
        const c = try gpa.create(Catalog);
        c.* = .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .tables = .empty,
            .table_map = std.StringHashMap(usize).init(gpa),
            .functions = .empty,
            .func_map = std.StringHashMap(usize).init(gpa),
            .datasets = .empty,
            .dataset_map = std.StringHashMap(usize).init(gpa),
            .changes = .empty,
            .fingerprints = std.StringHashMap(u64).init(gpa),
            .written_table_names = .empty,
        };
        errdefer c.deinit();
        // Signatures the shim's GoogleSQL has no builtin for: memory only, never persisted.
        for (try missingFunctions(c.arena_state.allocator())) |fs| {
            c.addFunctionSpecToMemory(fs) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable, // in-memory registration only OOMs
            };
        }
        return c;
    }

    pub fn deinit(c: *Catalog) void {
        c.tables.deinit(c.gpa);
        c.table_map.deinit();
        c.functions.deinit(c.gpa);
        c.func_map.deinit();
        c.datasets.deinit(c.gpa);
        c.dataset_map.deinit();
        c.changes.deinit(c.gpa);
        c.fingerprints.deinit();
        c.written_table_names.deinit(c.gpa);
        c.arena_state.deinit();
        c.gpa.destroy(c);
    }

    /// Creates `zigquery_catalog` when the database lacks it.
    pub fn createCatalogTablesIfNotExist(c: *Catalog, db: *sqlite.Db) Error!void {
        _ = c;
        try db.exec(create_catalog_table_query);
    }

    /// Loads every persisted spec into memory, once, at open. Coherence between connections is
    /// the shared catalog's job, so nothing re-reads storage afterwards.
    pub fn loadFromStorage(c: *Catalog, db: *sqlite.Db) Error!void {
        try c.createCatalogTablesIfNotExist(db);

        var stmt = try db.prepare(load_query);
        defer stmt.finalize();
        while (try stmt.step()) {
            const kind = std.meta.stringToEnum(CatalogSpecKind, stmt.columnText(1)) orelse
                return error.InvalidSpec;

            // Copy out of sqlite's row buffer before the next step().
            switch (kind) {
                .table, .view => {
                    const spec_json = try c.arena_state.allocator().dupe(u8, stmt.columnText(2));
                    try c.loadTableSpec(spec_json);
                },
                .function => {
                    const spec_json = try c.arena_state.allocator().dupe(u8, stmt.columnText(2));
                    try c.loadFunctionSpec(spec_json);
                },
                .dataset => {
                    const spec_json = try c.arena_state.allocator().dupe(u8, stmt.columnText(2));
                    try c.loadDatasetSpec(spec_json);
                },
            }
        }
    }

    fn loadTableSpec(c: *Catalog, spec_json: []const u8) Error!void {
        const table_spec = spec.tableSpecFromJson(c.arena_state.allocator(), spec_json) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSpec,
            };

        try c.addTableSpecToMemory(table_spec);
    }

    /// In-memory registration plus (unless temporary) the persisted upsert. The spec is
    /// deep-copied into the catalog arena (via its canonical JSON), so callers may pass
    /// short-lived memory.
    pub fn addNewTableSpec(
        c: *Catalog,
        db: *sqlite.Db,
        table_spec: *const spec.TableSpec,
    ) Error!void {
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

    /// Replaces a persistent spec, memory and row, for a change the analyzer does not see:
    /// `appendTableJson` renders the name and columns only, so
    /// `metadata` and `source_sql` edits need no entry in the change log and
    /// no handle resync. The caller keeps name and columns as they were.
    pub fn updateTableSpec(
        c: *Catalog,
        db: *sqlite.Db,
        table_spec: *const spec.TableSpec,
    ) Error!void {
        if (table_spec.is_temp or table_spec.is_synthetic) return error.NotPersistent;
        const arena = c.arena_state.allocator();
        const encoded = table_spec.toJson(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        const owned = spec.tableSpecFromJson(arena, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        const idx = c.table_map.get(try owned.tableName(arena)) orelse return error.TableNotFound;
        c.tables.items[idx] = owned;
        try c.saveTableSpec(db, owned, encoded);
    }

    /// Registers a spec into a per-connection TEMP overlay, never persisting
    /// it.
    ///
    /// A removal is logged before the addition because the overlay's consumer
    /// may already hold a persistent table of the same name, and the analyzer
    /// catalog's merge keeps whatever is already registered — without the
    /// removal a TEMP table would silently resolve to the table it shadows.
    /// Removing a name the consumer does not have is a no-op, so this is
    /// unconditional rather than conditional on the persistent catalog.
    pub fn addOverlayTableSpec(c: *Catalog, table_spec: *const spec.TableSpec) Error!void {
        const arena = c.arena_state.allocator();
        const encoded = table_spec.toJson(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        const owned = spec.tableSpecFromJson(arena, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        try c.changes.append(c.gpa, .{ .table_removed = try owned.tableName(arena) });
        try c.addTableSpecToMemory(owned);
    }

    /// The persisted upsert. `encoded` is the spec's JSON.
    fn saveTableSpec(
        c: *Catalog,
        db: *sqlite.Db,
        table_spec: *const spec.TableSpec,
        encoded: []const u8,
    ) Error!void {
        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        const arena = c.arena_state.allocator();
        const now = try nowTimestamps(arena);

        var stmt = try db.prepare(upsert_catalog_query);
        defer stmt.finalize();
        // Named-parameter indices in first-occurrence order: @name, @kind,
        // @spec, @updatedAt, @createdAt (the DO UPDATE reuses 3 and 4).
        const name = try table_spec.tableName(arena);
        try stmt.bindText(1, name);
        try stmt.bindText(2, @tagName(tableSpecKind(table_spec)));
        try stmt.bindText(3, encoded);
        try stmt.bindText(4, now.sql);
        try stmt.bindText(5, now.sql);
        _ = try stmt.step();
        try c.written_table_names.append(c.gpa, name);
    }

    /// The `kind` a table spec's row is stored under, and so half its key.
    ///
    /// Fixed for a name's lifetime, which the `(name, kind)` key relies on: a spec replacing one
    /// of the other kind would add a second row. CREATE OR REPLACE drops with its own kind's
    /// `DROP TABLE` or `DROP VIEW`, which SQLite refuses on the other; CREATE TABLE IF NOT EXISTS
    /// of a held name registers nothing; any other CREATE of a held name fails in SQLite.
    fn tableSpecKind(table_spec: *const spec.TableSpec) CatalogSpecKind {
        return if (table_spec.is_view) .view else .table;
    }

    /// Overlay counterpart of `deleteTableSpec`: an overlay spec was never
    /// persisted, so there is no row to delete.
    pub fn deleteOverlayTableSpec(c: *Catalog, name: []const u8) Error!void {
        _ = try c.forgetTableSpec(name);
    }

    /// Unregisters `name` and returns the spec it held.
    fn forgetTableSpec(c: *Catalog, name: []const u8) Error!*spec.TableSpec {
        const entry = c.table_map.fetchRemove(name) orelse return error.TableNotFound;
        // A mapped slot is never a tombstone.
        const removed = c.tables.items[entry.value].?;
        try c.changes.append(c.gpa, .{ .table_removed = entry.key });
        _ = c.fingerprints.remove(entry.key);
        // Tombstone rather than compact: no index shifts, so no reindex.
        c.tables.items[entry.value] = null;
        return removed;
    }

    /// Removes a table spec from memory and from storage.
    pub fn deleteTableSpec(c: *Catalog, db: *sqlite.Db, name: []const u8) Error!void {
        const removed = try c.forgetTableSpec(name);

        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        var stmt = try db.prepare(delete_catalog_query);
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, @tagName(tableSpecKind(removed)));
        _ = try stmt.step();
        try c.written_table_names.append(c.gpa, try c.arena_state.allocator().dupe(u8, name));
    }

    /// Makes the entries for `names` match their `zigquery_catalog` rows again, for a transaction
    /// that wrote those rows and then rolled back. The rollback restored the rows but not memory:
    /// a name with a row gets that row's spec back, and one without is forgotten.
    pub fn resyncTableSpecs(c: *Catalog, db: *sqlite.Db, names: []const []const u8) Error!void {
        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        var resynced = std.StringHashMap(void).init(c.gpa);
        defer resynced.deinit();
        var stmt = try db.prepare(select_table_spec_query);
        defer stmt.finalize();
        for (names) |name| {
            if ((try resynced.getOrPut(name)).found_existing) continue;
            stmt.reset();
            try stmt.bindText(1, name);
            if (try stmt.step()) {
                // Copy out of SQLite's row buffer before the next step.
                try c.loadTableSpec(try c.arena_state.allocator().dupe(u8, stmt.columnText(0)));
                continue;
            }
            if (c.table_map.contains(name)) _ = try c.forgetTableSpec(name);
        }
    }

    /// Number of registered (non-deleted) table specs. Counts live slots, so
    /// tombstones do not inflate it.
    pub fn tableCount(c: *const Catalog) usize {
        return c.table_map.count();
    }

    pub fn findTableSpec(c: *const Catalog, name: []const u8) ?*spec.TableSpec {
        const idx = c.table_map.get(name) orelse return null;
        return c.tables.items[idx];
    }

    /// `shapeFingerprint` of the spec registered under `name`, or `spec.missing_fingerprint`.
    pub fn fingerprint(c: *const Catalog, name: []const u8) u64 {
        return c.fingerprints.get(name) orelse spec.missing_fingerprint;
    }

    /// Each dependency as it stands now, for a view whose query reads `names`.
    pub fn currentDependencies(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        names: []const []const u8,
    ) error{OutOfMemory}![]spec.ViewDependency {
        var out: std.ArrayList(spec.ViewDependency) = .empty;
        for (names) |name| {
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen.name, name)) break;
            } else try out.append(alloc, .{ .name = name, .fingerprint = c.fingerprint(name) });
        }
        return out.items;
    }

    /// Whether a refreshable view reads something whose shape is not what it was when the view
    /// was last analyzed.
    pub fn dependenciesChanged(c: *const Catalog, view: *const spec.TableSpec) bool {
        for (view.dependencies) |dependency| {
            if (c.fingerprint(dependency.name) != dependency.fingerprint) return true;
        }
        return false;
    }

    /// The canonical names of every refreshable view that is stale: it reads something whose
    /// shape changed since it was last analyzed, or it reads a view that is stale. A view over a
    /// stale view is listed too, because refreshing the view beneath changes the shape it reads.
    pub fn staleViewNames(
        c: *const Catalog,
        alloc: std.mem.Allocator,
    ) error{OutOfMemory}![]const []const u8 {
        var is_stale_by_name: std.StringHashMapUnmanaged(bool) = .empty;
        defer is_stale_by_name.deinit(alloc);
        var names: std.ArrayList([]const u8) = .empty;
        for (c.tables.items) |maybe| {
            const table_spec = maybe orelse continue;
            if (!isRefreshableView(table_spec)) continue;
            const name = try table_spec.tableName(alloc);
            const is_stale = try c.isStale(
                alloc,
                &is_stale_by_name,
                name,
                table_spec,
            );

            if (is_stale) {
                try names.append(alloc, name);
            }
        }
        return names.items;
    }

    /// Whether the refreshable view `view`, registered as `name`, is stale through any chain of
    /// views it reads. Each answer is kept in `is_stale_by_name`, so a view read by many is
    /// worked out once.
    fn isStale(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        is_stale_by_name: *std.StringHashMapUnmanaged(bool),
        name: []const u8,
        view: *const spec.TableSpec,
    ) error{OutOfMemory}!bool {
        const entry = try is_stale_by_name.getOrPut(alloc, name);
        if (entry.found_existing) return entry.value_ptr.*;
        // Recorded before recursing, so a cycle of views ends here; querying the cycle fails.
        entry.value_ptr.* = false;
        const is_stale = c.dependenciesChanged(view) or for (view.dependencies) |dependency| {
            const read = c.findTableSpec(dependency.name) orelse continue;
            if (!isRefreshableView(read)) continue;
            if (try c.isStale(alloc, is_stale_by_name, dependency.name, read)) break true;
        } else false;
        // Not through `entry`: the recursion may have grown the map.
        try is_stale_by_name.put(alloc, name, is_stale);
        return is_stale;
    }

    /// Whether a query that reads `name` can run as the catalog stands, following views that
    /// read other views.
    pub fn viewStatus(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        name: []const u8,
    ) error{OutOfMemory}!ViewStatus {
        var visited = std.StringHashMap(void).init(alloc);
        return c.viewStatusVisiting(&visited, name);
    }

    fn viewStatusVisiting(
        c: *const Catalog,
        visited: *std.StringHashMap(void),
        name: []const u8,
    ) error{OutOfMemory}!ViewStatus {
        const view = c.findTableSpec(name) orelse return .fresh;
        if (!isRefreshableView(view)) return .fresh;
        if ((try visited.getOrPut(name)).found_existing) return .fresh;
        if (c.dependenciesChanged(view)) return .stale;

        var dependency_invalid_reason: ?[]const u8 = null;
        for (view.dependencies) |dependency| {
            switch (try c.viewStatusVisiting(visited, dependency.name)) {
                .fresh => {},
                .stale => return .stale,
                .invalid => |reason| {
                    if (dependency_invalid_reason == null) dependency_invalid_reason = reason;
                },
            }
        }
        if (view.invalid_reason.len > 0) return .{ .invalid = view.invalid_reason };
        if (dependency_invalid_reason) |reason| return .{ .invalid = reason };
        return .fresh;
    }

    // ------------------------------------------------------------------
    // Function specs
    // ------------------------------------------------------------------

    fn loadFunctionSpec(c: *Catalog, spec_json: []const u8) Error!void {
        const fs = spec.functionSpecFromJson(c.arena_state.allocator(), spec_json) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSpec,
            };
        try c.addFunctionSpecToMemory(fs);
    }

    /// In-memory registration plus (unless temporary) the persisted upsert. Deep-copies via
    /// canonical JSON so callers may pass short-lived memory.
    pub fn addNewFunctionSpec(
        c: *Catalog,
        db: *sqlite.Db,
        fs: *const spec.FunctionSpec,
    ) Error!void {
        const arena = c.arena_state.allocator();
        const encoded = fs.toJson(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        const owned = spec.functionSpecFromJson(arena, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        try c.addFunctionSpecToMemory(owned);
        if (!owned.is_temp) {
            try c.saveFunctionSpec(db, owned, encoded);
        }
    }

    /// The shared catalog upsert with kind='function'.
    fn saveFunctionSpec(
        c: *Catalog,
        db: *sqlite.Db,
        fs: *const spec.FunctionSpec,
        encoded: []const u8,
    ) Error!void {
        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        const arena = c.arena_state.allocator();
        const now = try nowTimestamps(arena);
        var stmt = try db.prepare(upsert_catalog_query);
        defer stmt.finalize();
        try stmt.bindText(1, try fs.funcName(arena));
        try stmt.bindText(2, @tagName(CatalogSpecKind.function));
        try stmt.bindText(3, encoded);
        try stmt.bindText(4, now.sql);
        try stmt.bindText(5, now.sql);
        _ = try stmt.step();
    }

    /// Overlay counterpart of `deleteFunctionSpec`: nothing was persisted.
    pub fn deleteOverlayFunctionSpec(c: *Catalog, name: []const u8) Error!void {
        return c.forgetFunctionSpec(name);
    }

    fn forgetFunctionSpec(c: *Catalog, name: []const u8) Error!void {
        c.function_generation +%= 1;
        const entry = c.func_map.fetchRemove(name) orelse return error.TableNotFound;
        _ = c.functions.orderedRemove(entry.value);
        var it = c.func_map.valueIterator();
        while (it.next()) |idx| {
            if (idx.* > entry.value) idx.* -= 1;
        }
    }

    /// Removes a function spec from memory and from storage.
    pub fn deleteFunctionSpec(c: *Catalog, db: *sqlite.Db, name: []const u8) Error!void {
        try c.forgetFunctionSpec(name);

        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        var stmt = try db.prepare(delete_catalog_query);
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, @tagName(CatalogSpecKind.function));
        _ = try stmt.step();
    }

    pub fn findFunctionSpec(c: *const Catalog, name: []const u8) ?*spec.FunctionSpec {
        const idx = c.func_map.get(name) orelse return null;
        return c.functions.items[idx];
    }

    /// The per-statement function map, keyed by FuncName. The seeded signatures (contains_substr,
    /// min_by, max_by) are excluded: they carry no body and are lowered by the extractor /
    /// runtime UDFs instead, so routing them through CallSQL would shadow those paths. Every
    /// user-created spec is included — including "js" ones, whose bodyless CallSQL raises a clear
    /// Unimplemented rather than emitting a call to a function SQLite never defined. Allocated
    /// from `alloc` (per-statement arena).
    pub fn funcMap(c: *const Catalog, alloc: std.mem.Allocator) error{OutOfMemory}!*spec.FuncMap {
        const map = try alloc.create(spec.FuncMap);
        map.* = spec.FuncMap.init(alloc);
        try c.addFunctionsTo(alloc, map);
        return map;
    }

    /// Merges this catalog's functions into an existing map. Later callers
    /// win, which is how a connection's TEMP overlay shadows a persistent
    /// function of the same name.
    pub fn addFunctionsTo(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        map: *spec.FuncMap,
    ) error{OutOfMemory}!void {
        for (c.functions.items) |fs| {
            if (fs.body == null and std.mem.eql(u8, fs.language, "SQL")) continue;
            const full = try fs.funcName(alloc);
            try map.put(full, fs);

            // A dataset-qualified function also answers to its bare leaf name,
            // because that is how addFunctionToNode registers it — at the
            // analyzer's root catalog as well as inside the dataset's. The
            // resolved AST then names it by the leaf and nothing else:
            // `fn_ds.add_one(41)` comes back as a FunctionRef called
            // "add_one", with the dataset gone. Keyed only by the joined path,
            // that call matched no spec and fell through to an undefined
            // SQLite function.
            if (fs.name_path.len < 2) continue;
            const leaf = fs.name_path[fs.name_path.len - 1];
            if (leaf.len == 0 or std.mem.eql(u8, leaf, full)) continue;
            // First registration keeps the leaf, which is what the analyzer
            // resolved against (addFunctionToNode skips a name already
            // present), so the two agree on which body an unqualified call
            // means. The full-path key above is unambiguous and still lets a
            // TEMP function shadow a persistent one of the same path.
            if (!map.contains(leaf)) try map.put(leaf, fs);
        }
    }

    /// Number of registered function specs (seeded builtins included).
    pub fn functionCount(c: *const Catalog) usize {
        return c.functions.items.len;
    }

    /// In-memory registration. A duplicate name replaces the stored spec.
    fn addFunctionSpecToMemory(c: *Catalog, fs: *spec.FunctionSpec) Error!void {
        const arena = c.arena_state.allocator();
        const name = try fs.funcName(arena);
        if (c.func_map.get(name)) |idx| {
            c.functions.items[idx] = fs;
            return;
        }
        try c.functions.append(c.gpa, fs);
        try c.func_map.put(name, c.functions.items.len - 1);
    }

    /// Registers a spec the analyzer should resolve but nothing should persist.
    ///
    /// `addNewTableSpec` writes a `zigquery_catalog` row, which is right for a
    /// table SQLite is holding and wrong for one whose rows live somewhere else
    /// for the length of a process: a persisted spec would come back on reopen
    /// naming a table with nothing behind it. The INFORMATION_SCHEMA views take
    /// this same memory-only path, for the same reason.
    ///
    /// The caller owns `table_spec` and everything it points at, and must keep
    /// them alive until `deleteTableSpec` removes it.
    pub fn addSyntheticTableSpec(c: *Catalog, table_spec: *spec.TableSpec) Error!void {
        table_spec.is_synthetic = true;
        return c.addTableSpecToMemory(table_spec);
    }

    /// In-memory registration. A duplicate canonical name replaces the stored spec, and the change
    /// log carries the replacement as a remove followed by an add, so it is visible at once.
    fn addTableSpecToMemory(c: *Catalog, table_spec: *spec.TableSpec) Error!void {
        const arena = c.arena_state.allocator();
        const table_name = try table_spec.tableName(arena);
        try c.fingerprints.put(table_name, try shapeFingerprint(arena, table_spec));
        if (c.table_map.get(table_name)) |idx| {
            // Replacement in place. The entry count does not change, so this
            // is invisible to an append-only delta: record it as a remove
            // followed by an add so a consumer redefines rather than keeps
            // the stale entry.
            c.tables.items[idx] = table_spec;
            try c.changes.append(c.gpa, .{ .table_removed = table_name });
            try c.changes.append(c.gpa, .{ .table_added = table_name });
            return;
        }
        try c.tables.append(c.gpa, table_spec);
        try c.table_map.put(table_name, c.tables.items.len - 1);
        try c.changes.append(c.gpa, .{ .table_added = table_name });
        try c.ensureInfoSchema(table_spec.name_path);
    }

    /// Registers the INFORMATION_SCHEMA views for a table's dataset, once, and
    /// (via `ensureDataset`) the dataset itself and its project's SCHEMATA.
    ///
    /// Hooked here rather than in the JSON renderers because this is the single
    /// funnel all three registration paths pass through — including
    /// `loadTableSpec`, so the views come back on a reopened database — and
    /// because both the full render and the delta render then pick them up
    /// without inventing synthetic change entries.
    ///
    /// The views are ordinary `TableSpec`s with no backing SQLite object; the
    /// transformer rewrites a scan of one into a virtual-table call (see
    /// `function/info_schema_vtab.zig`).
    fn ensureInfoSchema(c: *Catalog, name_path: []const []const u8) Error!void {
        // A dataset needs at least <dataset>.<table>.
        if (name_path.len < 2) return;
        // Recursion guard: the synthetic specs below re-enter this function.
        //
        // The anonymous-results dataset is excluded for a different reason. Its
        // tables are a query job's results, one per job, and giving each of them
        // a dataset's worth of views would be four more specs per job in a
        // catalog that `publishInfoSchemaSnapshot` walks on every statement --
        // the growth docs/MATERIALIZE_COST.md §3 measures. The dataset itself
        // still gets one set, from whichever job registers first.
        for (name_path) |seg| {
            if (std.mem.eql(u8, seg, info_schema_vtab.info_schema_segment)) return;
        }
        const arena = c.arena_state.allocator();
        const prefix = name_path[0 .. name_path.len - 1];

        for (&info_schema_vtab.views) |*view| {
            const path = try arena.alloc([]const u8, prefix.len + 2);
            for (prefix, 0..) |seg, i| path[i] = try arena.dupe(u8, seg);
            path[prefix.len] = info_schema_vtab.info_schema_segment;
            path[prefix.len + 1] = view.view;
            try c.registerSyntheticView(arena, path, view);
        }
        try c.ensureDataset(prefix);
    }

    /// Builds and registers one INFORMATION_SCHEMA view's `TableSpec` at
    /// `path`, if a spec is not already registered there. Shared by a table's
    /// per-dataset views (`ensureInfoSchema`) and a dataset's project-scoped
    /// SCHEMATA (`ensureDataset`) — both are ordinary synthetic `TableSpec`s
    /// with no backing SQLite object, differing only in path shape.
    fn registerSyntheticView(
        c: *Catalog,
        arena: std.mem.Allocator,
        path: []const []const u8,
        view: *const info_schema_vtab.View,
    ) error{OutOfMemory}!void {
        const table_spec = try arena.create(spec.TableSpec);
        const columns = try arena.alloc(*spec.ColumnSpec, view.columns.len);
        for (view.columns, 0..) |col_name, i| {
            const col = try arena.create(spec.ColumnSpec);
            col.* = .{
                .name = col_name,
                // ordinal_position is the only non-STRING column.
                .type = try spec.newSimpleType(arena, .TYPE_INT64),
            };
            if (!std.mem.eql(u8, col_name, "ordinal_position")) {
                col.type = try spec.newSimpleType(arena, .TYPE_STRING);
            }
            columns[i] = col;
        }
        table_spec.* = .{ .name_path = path, .columns = columns };

        const canonical = try table_spec.tableName(arena);
        if (c.table_map.contains(canonical)) return;
        try c.tables.append(c.gpa, table_spec);
        try c.table_map.put(canonical, c.tables.items.len - 1);
        try c.changes.append(c.gpa, .{ .table_added = canonical });
    }

    /// Records that a table's `[project, dataset]` exists, when nothing has
    /// said so yet. Idempotent: a dataset already known — declared or
    /// inferred — is left alone.
    ///
    /// INFORMATION_SCHEMA is served from the catalog, so it has to know about every dataset a
    /// table lands in even when nobody declared it (the engine library and the spec corpus create
    /// `ds.t` freely). The entry is synthetic: memory-only, and invisible to the metadata API,
    /// which only reports datasets someone declared through `addNewDatasetSpec`.
    ///
    /// Reached via `ensureInfoSchema`, so `loadTableSpec` takes it too. A
    /// project-less dataset (`name_path.len != 2`, e.g. a bare `CREATE TABLE
    /// ds.t`) has no project segment to register a project-scoped SCHEMATA
    /// under, so it is left to the existing dataset-scoped
    /// `ds.INFORMATION_SCHEMA.SCHEMATA` form instead.
    fn ensureDataset(c: *Catalog, name_path: []const []const u8) error{OutOfMemory}!void {
        if (name_path.len != 2) return;
        const arena = c.arena_state.allocator();
        const canonical = try spec.formatPath(arena, name_path);
        if (c.dataset_map.contains(canonical)) return;

        const dataset_path = try arena.alloc([]const u8, 2);
        dataset_path[0] = try arena.dupe(u8, name_path[0]);
        dataset_path[1] = try arena.dupe(u8, name_path[1]);
        const entry = try arena.create(spec.DatasetSpec);
        entry.* = .{ .name_path = dataset_path, .is_synthetic = true };
        try c.addDatasetToMemory(entry, canonical);
    }

    /// Registers `ds` under `canonical`, replacing whatever slot held that
    /// name — this is how a declared dataset supersedes the synthetic entry a
    /// table's registration inferred, and why load order does not matter
    /// (`loadFromStorage` has no ORDER BY, so a table row can precede its
    /// dataset row). Also registers the project's SCHEMATA view
    /// (`<project>.INFORMATION_SCHEMA.SCHEMATA`), once per project.
    ///
    /// Datasets are not logged in `changes`: the analyzer catalog has no
    /// dataset concept, and SCHEMATA reads the live registry.
    fn addDatasetToMemory(
        c: *Catalog,
        ds: *spec.DatasetSpec,
        canonical: []const u8,
    ) error{OutOfMemory}!void {
        if (c.dataset_map.get(canonical)) |idx| {
            c.datasets.items[idx] = ds;
        } else {
            try c.datasets.append(c.gpa, ds);
            try c.dataset_map.put(canonical, c.datasets.items.len - 1);
        }

        const arena = c.arena_state.allocator();
        const schemata_view = for (&info_schema_vtab.views) |*v| {
            if (std.mem.eql(u8, v.view, "SCHEMATA")) break v;
        } else unreachable; // SCHEMATA is always in info_schema_vtab.views.
        const project_path = try arena.alloc([]const u8, 3);
        project_path[0] = try arena.dupe(u8, ds.name_path[0]);
        project_path[1] = info_schema_vtab.info_schema_segment;
        project_path[2] = schemata_view.view;
        try c.registerSyntheticView(arena, project_path, schemata_view);
    }

    fn loadDatasetSpec(c: *Catalog, spec_json: []const u8) Error!void {
        const arena = c.arena_state.allocator();
        const ds = spec.datasetSpecFromJson(arena, spec_json) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        if (ds.name_path.len != 2) return error.InvalidSpec;
        try c.addDatasetToMemory(ds, try ds.datasetName(arena));
    }

    /// Declares a dataset: in-memory registration plus the persisted upsert, the dataset
    /// counterpart of `addNewTableSpec`. Both a fresh dataset and a patched one come through here.
    /// The spec is deep-copied into the catalog arena via its JSON, so callers may pass
    /// short-lived memory. A synthetic spec is refused: inferred datasets are `ensureDataset`'s
    /// business and never persist.
    pub fn addNewDatasetSpec(
        c: *Catalog,
        db: *sqlite.Db,
        ds: *const spec.DatasetSpec,
    ) Error!void {
        if (ds.is_synthetic) return error.NotPersistent;
        if (ds.name_path.len != 2) return error.InvalidSpec;
        const arena = c.arena_state.allocator();
        const encoded = ds.toJson(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        const owned = spec.datasetSpecFromJson(arena, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSpec,
        };
        const canonical = try owned.datasetName(arena);
        try c.addDatasetToMemory(owned, canonical);

        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        const now = try nowTimestamps(arena);
        var stmt = try db.prepare(upsert_catalog_query);
        defer stmt.finalize();
        try stmt.bindText(1, canonical);
        try stmt.bindText(2, @tagName(CatalogSpecKind.dataset));
        try stmt.bindText(3, encoded);
        try stmt.bindText(4, now.sql);
        try stmt.bindText(5, now.sql);
        _ = try stmt.step();
    }

    /// Removes a declared dataset from memory and from storage. A dataset the
    /// catalog only inferred is not deletable through the metadata API, so it
    /// reports `DatasetNotFound` like an unknown one.
    ///
    /// Tombstones rather than compacts, as `deleteTableSpec` does. The
    /// dataset's INFORMATION_SCHEMA views stay registered: they are hidden
    /// from listings by the vtab and would be recreated by the next table
    /// anyway.
    pub fn deleteDatasetSpec(c: *Catalog, db: *sqlite.Db, name: []const u8) Error!void {
        const idx = c.dataset_map.get(name) orelse return error.DatasetNotFound;
        const current = c.datasets.items[idx] orelse return error.DatasetNotFound;
        if (current.is_synthetic) return error.DatasetNotFound;
        _ = c.dataset_map.remove(name);
        c.datasets.items[idx] = null;

        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        var stmt = try db.prepare(delete_catalog_query);
        defer stmt.finalize();
        try stmt.bindText(1, name);
        try stmt.bindText(2, @tagName(CatalogSpecKind.dataset));
        _ = try stmt.step();
    }

    /// Spec currently registered under a canonical dataset name, declared or
    /// inferred, if any.
    pub fn datasetSpecByName(c: *const Catalog, name: []const u8) ?*spec.DatasetSpec {
        const idx = c.dataset_map.get(name) orelse return null;
        return c.datasets.items[idx];
    }

    /// Every live dataset, declared or inferred, in registration order.
    ///
    /// Copies into `alloc` rather than returning `c.datasets.items` directly,
    /// same as `liveTableSpecs`: the slice must stay valid for a reader who
    /// releases the catalog lock before consuming it, and a concurrent append
    /// on another connection can reallocate the backing array underneath it.
    pub fn liveDatasets(
        c: *const Catalog,
        alloc: std.mem.Allocator,
    ) error{OutOfMemory}![]const *spec.DatasetSpec {
        var out = try std.ArrayList(*spec.DatasetSpec).initCapacity(alloc, c.dataset_map.count());
        for (c.datasets.items) |maybe| {
            if (maybe) |ds| out.appendAssumeCapacity(ds);
        }
        return out.items;
    }

    // ------------------------------------------------------------------
    // SimpleCatalogProto JSON rendering
    // ------------------------------------------------------------------

    /// Renders the catalog as SimpleCatalogProto protobuf-JSON for the
    /// analyzer shim. Returns "{}" (builtins only) when neither tables nor
    /// functions are registered. All memory comes from `alloc`.
    pub fn catalogJson(
        c: *const Catalog,
        alloc: std.mem.Allocator,
    ) error{ OutOfMemory, InvalidSpec }![:0]u8 {
        return c.catalogJsonWith(alloc, null);
    }

    /// Renders this catalog unioned with a per-connection TEMP overlay, the
    /// overlay winning on name collisions. Used by the stateless analyzer
    /// path, which rebuilds the whole proto per statement instead of pushing
    /// deltas into a persistent handle.
    pub fn catalogJsonWith(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        overlay: ?*const Catalog,
    ) error{ OutOfMemory, InvalidSpec }![:0]u8 {
        const ov_tables = if (overlay) |o| o.table_map.count() else 0;
        const ov_funcs = if (overlay) |o| o.functions.items.len else 0;
        if (c.table_map.count() == 0 and c.functions.items.len == 0 and
            ov_tables == 0 and ov_funcs == 0)
            return alloc.dupeSentinel(u8, "{}", 0);

        var root = Node{ .name = catalog_name };
        for (c.tables.items) |maybe| {
            const table_spec = maybe orelse continue;
            const canonical = try table_spec.tableName(alloc);
            // Shadowed by the overlay: emit the overlay's definition only.
            if (overlay) |o| if (o.table_map.contains(canonical)) continue;
            try addTableToNode(alloc, &root, table_spec.name_path, table_spec, canonical);
        }
        // Functions register under their leaf name at the root and inside every sub-catalog along
        // the path.
        for (c.functions.items) |fs| {
            if (overlay) |o| if (o.func_map.contains(try fs.funcName(alloc))) continue;
            try addFunctionToNode(alloc, &root, fs.name_path, fs);
        }
        if (overlay) |o| {
            for (o.tables.items) |maybe| {
                const table_spec = maybe orelse continue;
                const canonical = try table_spec.tableName(alloc);
                try addTableToNode(alloc, &root, table_spec.name_path, table_spec, canonical);
            }
            for (o.functions.items) |fs| {
                try addFunctionToNode(alloc, &root, fs.name_path, fs);
            }
        }
        return renderNode(alloc, &root);
    }

    /// Renders a SimpleCatalogProto containing only the functions registered
    /// at or after `fn_start`, so a consumer that already holds the earlier
    /// ones can merge rather than re-receive everything. Functions only ever
    /// append, so an index is a sufficient cursor.
    pub fn functionJsonFrom(
        c: *const Catalog,
        alloc: std.mem.Allocator,
        fn_start: usize,
    ) error{ OutOfMemory, InvalidSpec }![:0]u8 {
        if (fn_start >= c.functions.items.len) return alloc.dupeSentinel(u8, "{}", 0);
        var root = Node{ .name = catalog_name };
        for (c.functions.items[fn_start..]) |fs| {
            try addFunctionToNode(alloc, &root, fs.name_path, fs);
        }
        return renderNode(alloc, &root);
    }
};

/// Serializes a built proto tree to NUL-terminated protobuf-JSON.
fn renderNode(alloc: std.mem.Allocator, root: *Node) error{ OutOfMemory, InvalidSpec }![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendNodeJson(&out, alloc, root);
    try out.append(alloc, 0);
    const bytes = try out.toOwnedSlice(alloc);
    return bytes[0 .. bytes.len - 1 :0];
}

/// One registration point: the table resolves under `registered` and reports `canonical` as its
/// Name().
const TableEntry = struct {
    registered: []const u8,
    canonical: []const u8,
    table_spec: *const spec.TableSpec,
};

/// One function registration point: FunctionProto rendered with
/// namePath=[registered] (the leaf name at this catalog level).
const FunctionEntry = struct {
    registered: []const u8,
    fn_spec: *const spec.FunctionSpec,
};

/// In-flight SimpleCatalogProto tree node.
const Node = struct {
    name: []const u8,
    entries: std.ArrayList(TableEntry) = .empty,
    fn_entries: std.ArrayList(FunctionEntry) = .empty,
    subs: std.ArrayList(*Node) = .empty,

    // Lookup sidecars mirroring the three lists above. The lists stay
    // authoritative because emission order is part of the output; these only
    // answer "is it already here?".
    //
    // Without them, registering N tables costs O(N^2) string comparisons per
    // render. Back when every statement re-rendered the whole catalog, that
    // made bulk loading a few thousand source tables minutes of pure lookup.
    // Full renders are rare now — seeding a fresh handle, or the stateless
    // fallback — but they are still the ones that touch every table, so the
    // sidecars are what keeps that O(N). All of this is arena-allocated and
    // discarded with the render.
    entry_set: std.StringHashMapUnmanaged(void) = .empty,
    fn_entry_set: std.StringHashMapUnmanaged(void) = .empty,
    sub_map: std.StringHashMapUnmanaged(*Node) = .empty,

    fn findSub(n: *Node, name: []const u8) ?*Node {
        return n.sub_map.get(name);
    }

    fn addSub(n: *Node, alloc: std.mem.Allocator, sub: *Node) error{OutOfMemory}!void {
        try n.subs.append(alloc, sub);
        try n.sub_map.put(alloc, sub.name, sub);
    }

    fn hasEntry(n: *const Node, registered: []const u8) bool {
        return n.entry_set.contains(registered);
    }

    fn addEntry(
        n: *Node,
        alloc: std.mem.Allocator,
        e: TableEntry,
    ) error{OutOfMemory}!void {
        try n.entries.append(alloc, e);
        try n.entry_set.put(alloc, e.registered, {});
    }

    fn hasFnEntry(n: *const Node, registered: []const u8) bool {
        return n.fn_entry_set.contains(registered);
    }

    fn addFnEntry(
        n: *Node,
        alloc: std.mem.Allocator,
        e: FunctionEntry,
    ) error{OutOfMemory}!void {
        try n.fn_entries.append(alloc, e);
        try n.fn_entry_set.put(alloc, e.registered, {});
    }
};

/// For a path [a, b, c], registers "a.b.c", "b.c" and "c" at the current level, plus
/// sub-catalogs a -> {"b.c", "c", b -> {"c"}}. The first registration of a name wins.
fn addTableToNode(
    alloc: std.mem.Allocator,
    node: *Node,
    path: []const []const u8,
    table_spec: *const spec.TableSpec,
    canonical: []const u8,
) error{ OutOfMemory, InvalidSpec }!void {
    if (path.len == 0) return error.InvalidSpec;
    if (path.len == 1) {
        if (!node.hasEntry(path[0])) {
            try node.addEntry(alloc, .{
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
        try node.addSub(alloc, s);
        break :blk s;
    };
    const dotted = try std.mem.join(alloc, ".", path);
    if (!node.hasEntry(dotted)) {
        try node.addEntry(alloc, .{
            .registered = dotted,
            .canonical = canonical,
            .table_spec = table_spec,
        });
    }
    try addTableToNode(alloc, node, path[1..], table_spec, canonical);
    try addTableToNode(alloc, sub, path[1..], table_spec, canonical);
}

/// For a path [a, b, c], registers the function under its leaf name "c" at the current level and
/// inside the sub-catalog chain a -> b; each level also re-registers at the root.
fn addFunctionToNode(
    alloc: std.mem.Allocator,
    node: *Node,
    path: []const []const u8,
    fn_spec: *const spec.FunctionSpec,
) error{ OutOfMemory, InvalidSpec }!void {
    if (path.len == 0) return error.InvalidSpec;
    if (path.len == 1) {
        if (!node.hasFnEntry(path[0])) {
            try node.addFnEntry(alloc, .{ .registered = path[0], .fn_spec = fn_spec });
        }
        return;
    }
    const sub = node.findSub(path[0]) orelse blk: {
        const s = try alloc.create(Node);
        s.* = .{ .name = path[0] };
        try node.addSub(alloc, s);
        break :blk s;
    };
    try addFunctionToNode(alloc, node, path[1..], fn_spec);
    try addFunctionToNode(alloc, sub, path[1..], fn_spec);
}

fn appendNodeJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    node: *const Node,
) error{ OutOfMemory, InvalidSpec }!void {
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
    if (node.fn_entries.items.len > 0) {
        try out.appendSlice(alloc, ",\"customFunction\":[");
        for (node.fn_entries.items, 0..) |entry, i| {
            if (i > 0) try out.append(alloc, ',');
            try appendFunctionJson(out, alloc, entry);
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

/// FunctionProto protobuf-JSON (googlesql/proto/function.proto): namePath, group "", mode
/// SCALAR/AGGREGATE, one FunctionSignatureProto whose argument/returnType are
/// FunctionArgumentTypeProto entries — templated arguments carry `kind` (SignatureArgumentKind
/// name), fixed arguments carry `type` (TypeProto).
fn appendFunctionJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    entry: FunctionEntry,
) error{ OutOfMemory, InvalidSpec }!void {
    const fs = entry.fn_spec;
    try out.appendSlice(alloc, "{\"namePath\":[");
    try spec.appendJsonString(out, alloc, entry.registered);
    try out.appendSlice(alloc, "],\"group\":\"\",\"mode\":");
    try out.appendSlice(alloc, if (fs.is_aggregate) "\"AGGREGATE\"" else "\"SCALAR\"");
    try out.appendSlice(alloc, ",\"signature\":[{\"argument\":[");
    for (fs.args, 0..) |arg, i| {
        if (i > 0) try out.append(alloc, ',');
        const t = arg.type orelse return error.InvalidSpec;
        try appendFunctionArgumentTypeJson(out, alloc, t);
    }
    try out.appendSlice(alloc, "],\"returnType\":");
    const ret = fs.return_type orelse return error.InvalidSpec;
    try appendFunctionArgumentTypeJson(out, alloc, ret);
    try out.appendSlice(alloc, ",\"contextId\":\"-1\"}]}");
}

/// FunctionArgumentTypeProto JSON: `kind` for a templated argument, `ARG_TYPE_FIXED` and `type`
/// for a fixed one, numOccurrences 1 in both.
fn appendFunctionArgumentTypeJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    t: *const spec.Type,
) error{ OutOfMemory, InvalidSpec }!void {
    if (spec.isTemplatedSignatureKind(t.signature_kind)) {
        const kind: pb.SignatureArgumentKind = @fromBackingInt(@intCast(t.signature_kind));
        const kind_name = std.enums.tagName(pb.SignatureArgumentKind, kind) orelse
            return error.InvalidSpec;
        try out.appendSlice(alloc, "{\"kind\":\"");
        try out.appendSlice(alloc, kind_name);
        try out.appendSlice(alloc, "\",\"numOccurrences\":1}");
        return;
    }
    try out.appendSlice(alloc, "{\"kind\":\"ARG_TYPE_FIXED\",\"type\":");
    try appendTypeProtoJson(out, alloc, t);
    try out.appendSlice(alloc, ",\"numOccurrences\":1}");
}

/// Signatures for the functions the shim's GoogleSQL has no builtin for.
fn missingFunctions(alloc: std.mem.Allocator) error{OutOfMemory}![]*spec.FunctionSpec {
    const arg_arbitrary: i32 = @backingInt(pb.SignatureArgumentKind.ARG_KIND_EXPR_ARBITRARY);
    const arg_any_1: i32 = @backingInt(pb.SignatureArgumentKind.ARG_KIND_EXPR_ANY_1);
    const arg_any_2: i32 = @backingInt(pb.SignatureArgumentKind.ARG_KIND_EXPR_ANY_2);

    const out = try alloc.alloc(*spec.FunctionSpec, 3);

    // contains_substr(expression ARBITRARY, search_value_literal STRING) -> BOOL
    {
        const expr_t = try alloc.create(spec.Type);
        expr_t.* = .{
            .name = "expression",
            .kind = @backingInt(pb.TypeKind.TYPE_STRING),
            .signature_kind = arg_arbitrary,
        };
        const search_t = try alloc.create(spec.Type);
        search_t.* = .{
            .name = "search_value_literal",
            .kind = @backingInt(pb.TypeKind.TYPE_STRING),
        };
        const ret_t = try alloc.create(spec.Type);
        ret_t.* = .{ .name = "BOOL", .kind = @backingInt(pb.TypeKind.TYPE_BOOL) };
        const args = try alloc.alloc(*spec.NameWithType, 2);
        const a0 = try alloc.create(spec.NameWithType);
        a0.* = .{ .name = "expression", .type = expr_t };
        const a1 = try alloc.create(spec.NameWithType);
        a1.* = .{ .name = "search_value_literal", .type = search_t };
        args[0] = a0;
        args[1] = a1;
        const fs = try alloc.create(spec.FunctionSpec);
        fs.* = .{
            .name_path = &.{"contains_substr"},
            .language = "SQL",
            .args = args,
            .return_type = ret_t,
        };
        out[0] = fs;
    }

    // min_by / max_by (x ANY_1, y ANY_2) -> ANY_1, aggregate.
    for ([_][]const u8{ "min_by", "max_by" }, 1..) |name, i| {
        const x_t = try alloc.create(spec.Type);
        x_t.* = .{ .name = "x", .signature_kind = arg_any_1 };
        const y_t = try alloc.create(spec.Type);
        y_t.* = .{ .name = "y", .signature_kind = arg_any_2 };
        const ret_t = try alloc.create(spec.Type);
        ret_t.* = .{ .signature_kind = arg_any_1 };
        const args = try alloc.alloc(*spec.NameWithType, 2);
        const a0 = try alloc.create(spec.NameWithType);
        a0.* = .{ .name = "x", .type = x_t };
        const a1 = try alloc.create(spec.NameWithType);
        a1.* = .{ .name = "y", .type = y_t };
        args[0] = a0;
        args[1] = a1;
        const fs = try alloc.create(spec.FunctionSpec);
        fs.* = .{
            .name_path = try alloc.dupe([]const u8, &.{name}),
            .language = "SQL",
            .is_aggregate = true,
            .args = args,
            .return_type = ret_t,
        };
        out[i] = fs;
    }

    return out;
}

/// Whether a query through the view `name` can run as the catalog stands.
pub const ViewStatus = union(enum) {
    /// Its query and everything it reads analyzed against what they read now.
    fresh,
    /// It, or a view it reads, reads something whose shape changed since it was last analyzed.
    stale,
    /// It, or a view it reads, no longer analyzes; the reason is BigQuery's wording.
    invalid: []const u8,
};

/// Whether `table_spec` is a view whose query can be analyzed again: a persistent view that kept
/// the GoogleSQL it was created from.
pub fn isRefreshableView(table_spec: *const spec.TableSpec) bool {
    return table_spec.is_view and table_spec.source_sql.len > 0;
}

/// A hash of a spec's analyzed column names and types:
/// what a view's query sees when it reads the
/// spec. Two specs with the same columns fingerprint alike, so dropping a table and recreating it
/// with the same columns, which is how a view is materialized, leaves the views over it fresh.
/// Never `spec.missing_fingerprint`.
pub fn shapeFingerprint(
    alloc: std.mem.Allocator,
    table_spec: *const spec.TableSpec,
) error{ OutOfMemory, InvalidSpec }!u64 {
    return columnsFingerprint(alloc, table_spec.analyzedColumns());
}

/// `shapeFingerprint` of a spec whose analyzed columns are `columns`.
pub fn columnsFingerprint(
    alloc: std.mem.Allocator,
    columns: []const *spec.ColumnSpec,
) error{ OutOfMemory, InvalidSpec }!u64 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (columns) |col| {
        try spec.appendJsonString(&out, alloc, col.name);
        try appendTypeProtoJson(&out, alloc, col.type);
    }
    const hash = std.hash.Wyhash.hash(0, out.items);
    return if (hash == spec.missing_fingerprint) 1 else hash;
}

fn appendTableJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    entry: TableEntry,
) error{ OutOfMemory, InvalidSpec }!void {
    try out.appendSlice(alloc, "{\"name\":");
    try spec.appendJsonString(out, alloc, entry.canonical);
    if (!std.mem.eql(u8, entry.registered, entry.canonical)) {
        try out.appendSlice(alloc, ",\"nameInCatalog\":");
        try spec.appendJsonString(out, alloc, entry.registered);
    }
    try out.appendSlice(alloc, ",\"column\":[");
    for (entry.table_spec.analyzedColumns(), 0..) |col, i| {
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
fn appendTypeProtoJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    t: *const spec.Type,
) error{ OutOfMemory, InvalidSpec }!void {
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
        // googlesql's ValidateTypeProto (type_deserializer.cc) accepts a
        // TYPE_RANGE only when the proto also carries `range_type` — the same
        // iff it enforces for ARRAY and STRUCT. Emitting the bare kind is what
        // made a `RANGE<DATE>` column fail with "Invalid TypeProto provided
        // for deserialization", and it failed on the *next* statement rather
        // than the DDL, because the whole catalog is re-parsed per analyze.
        .TYPE_RANGE => {
            const elem = t.element_type orelse return error.InvalidSpec;
            try out.appendSlice(alloc, ",\"rangeType\":{\"elementType\":");
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
    /// SQL column form, comparable lexicographically with the catalog's other rows:
    /// "YYYY-MM-DD HH:MM:SS.micros+00:00", in UTC.
    sql: []const u8,
    /// RFC3339 for spec JSON updatedAt/createdAt.
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

/// Unix microseconds for an RFC3339 timestamp, `YYYY-MM-DDTHH:MM:SS[.frac]Z` or with a
/// `+HH:MM` / `-HH:MM` offset. Null for anything else.
pub fn epochMicrosFromRfc3339(text: []const u8) ?i64 {
    if (text.len < 20) return null;
    const secs = civilSecondsOf(text[0..19]) orelse return null;
    const frac = fractionOf(text[19..]);
    const offset_secs = zoneOffsetOf(text[19 + frac.len ..]) orelse return null;
    return (secs - offset_secs) * std.time.us_per_s + frac.micros;
}

/// Seconds since the epoch for `YYYY-MM-DDTHH:MM:SS`, as if UTC.
fn civilSecondsOf(text: *const [19]u8) ?i64 {
    if (text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':') {
        return null;
    }
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    const days = value_mod.daysFromCivil(year, month, day);
    return days * std.time.s_per_day + hh * 3600 + mm * 60 + ss;
}

/// An optional `.digits` fraction of a second: its microseconds and how many
/// bytes it took, both zero when there is none.
fn fractionOf(text: []const u8) struct { micros: i64, len: usize } {
    if (text.len == 0 or text[0] != '.') return .{ .micros = 0, .len = 0 };
    var micros: i64 = 0;
    var scale: i64 = 100_000;
    var i: usize = 1;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        micros += @as(i64, text[i] - '0') * scale;
        scale = @divTrunc(scale, 10);
    }
    return .{ .micros = micros, .len = i };
}

/// The zone suffix's offset in seconds: `Z`, or `+HH:MM` / `-HH:MM`.
fn zoneOffsetOf(text: []const u8) ?i64 {
    if (std.mem.eql(u8, text, "Z")) return 0;
    if (text.len != 6 or text[3] != ':') return null;
    const sign: i64 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const oh = std.fmt.parseInt(i64, text[1..3], 10) catch return null;
    const om = std.fmt.parseInt(i64, text[4..6], 10) catch return null;
    return sign * (oh * 3600 + om * 60);
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
        .create_mode = .CREATE_DEFAULT,
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    return ts;
}

test "staleViewNames lists the views over a stale view, through every chain and either dependency" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c = try Catalog.init(testing.allocator);
    defer c.deinit();
    try c.createCatalogTablesIfNotExist(&db);

    const Read = struct {
        fn view(
            catalog: *Catalog,
            arena: std.mem.Allocator,
            name: []const u8,
            reads: []const []const u8,
        ) !*spec.TableSpec {
            const view_spec = try testTableSpec(arena, try arena.dupe([]const u8, &.{name}));
            view_spec.is_view = true;
            view_spec.source_sql = "SELECT a, b FROM t";
            const dependencies = try arena.alloc(spec.ViewDependency, reads.len);
            for (reads, 0..) |read, i| dependencies[i] = .{
                .name = read,
                .fingerprint = catalog.fingerprint(read),
            };
            view_spec.dependencies = dependencies;
            return view_spec;
        }
    };
    // t <- v1 <- v2 <- v3; `other` <- fresh; (other, v2) <- second, stale only through v2.
    try c.addNewTableSpec(&db, try testTableSpec(alloc, &.{"t"}));
    try c.addNewTableSpec(&db, try testTableSpec(alloc, &.{"other"}));
    try c.addNewTableSpec(&db, try Read.view(c, alloc, "v1", &.{"t"}));
    try c.addNewTableSpec(&db, try Read.view(c, alloc, "v2", &.{"v1"}));
    try c.addNewTableSpec(&db, try Read.view(c, alloc, "v3", &.{"v2"}));
    try c.addNewTableSpec(&db, try Read.view(c, alloc, "fresh", &.{"other"}));
    try c.addNewTableSpec(&db, try Read.view(c, alloc, "second", &.{ "other", "v2" }));
    try testing.expectEqual(@as(usize, 0), (try c.staleViewNames(alloc)).len);

    const reshaped = try testTableSpec(alloc, &.{"t"});
    reshaped.columns = reshaped.columns[0..1];
    try c.addNewTableSpec(&db, reshaped);

    const names = try alloc.dupe([]const u8, try c.staleViewNames(alloc));
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    try testing.expectEqual(@as(usize, 4), names.len);
    for ([_][]const u8{ "second", "v1", "v2", "v3" }, names) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }
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

test "RFC3339 timestamps parse back to the micros they were formatted from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const micros: i64 = (value_mod.daysFromCivil(2024, 1, 2) * std.time.s_per_day +
        3 * 3600 + 4 * 60 + 5) * std.time.us_per_s + 123456;
    const t = try timestampsFromMicros(arena_state.allocator(), micros);
    try testing.expectEqual(micros, epochMicrosFromRfc3339(t.rfc3339).?);
    // A whole second with no fraction, and a zone given as an offset.
    try testing.expectEqual(micros - 123456, epochMicrosFromRfc3339("2024-01-02T03:04:05Z").?);
    try testing.expectEqual(
        micros - 123456,
        epochMicrosFromRfc3339("2024-01-02T05:04:05+02:00").?,
    );
    try testing.expectEqual(@as(?i64, null), epochMicrosFromRfc3339(""));
    try testing.expectEqual(@as(?i64, null), epochMicrosFromRfc3339("2024-01-02 03:04:05"));
}

test "updateTableSpec swaps the spec, persists it, and leaves the change log alone" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c1 = try Catalog.init(testing.allocator);
    defer c1.deinit();
    try c1.createCatalogTablesIfNotExist(&db);
    try c1.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "p", "d", "t1" }));
    const logged = c1.changes.items.len;

    var updated = (c1.findTableSpec("p_d_t1") orelse return error.TestUnexpectedResult).*;
    updated.metadata = "{\"description\":\"posted\"}";
    try c1.updateTableSpec(&db, &updated);
    try testing.expectEqual(logged, c1.changes.items.len);
    try testing.expectEqualStrings(
        "{\"description\":\"posted\"}",
        (c1.findTableSpec("p_d_t1") orelse return error.TestUnexpectedResult).metadata,
    );

    // The row carries it, so a fresh catalog reads it back.
    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.loadFromStorage(&db);
    const found = c2.findTableSpec("p_d_t1") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("{\"description\":\"posted\"}", found.metadata);
    try testing.expectEqual(@as(usize, 2), found.columns.len);

    var missing = updated;
    missing.name_path = &.{ "p", "d", "nope" };
    try testing.expectError(error.TableNotFound, c1.updateTableSpec(&db, &missing));

    // A synthetic spec is registered for the analyzer and never written; an
    // update must not smuggle it into a row.
    const synthetic = try testTableSpec(alloc, &.{ "p", "_anon", "job1" });
    try c1.addSyntheticTableSpec(synthetic);
    var patched = synthetic.*;
    patched.metadata = "{\"description\":\"phantom\"}";
    try testing.expectError(error.NotPersistent, c1.updateTableSpec(&db, &patched));
    {
        var stmt = try db.prepare(
            "SELECT COUNT(*) FROM zigquery_catalog WHERE name = 'p__anon_job1'",
        );
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
    }
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

    // The persisted row exists with its kind and a decodable spec.
    {
        var stmt = try db.prepare("SELECT name, kind, spec FROM zigquery_catalog");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqualStrings("t1", stmt.columnText(0));
        try testing.expectEqualStrings("table", stmt.columnText(1));
        const decoded = try spec.tableSpecFromJson(alloc, stmt.columnText(2));
        try testing.expectEqual(@as(usize, 2), decoded.columns.len);
        try testing.expectEqualStrings("a", decoded.columns[0].name);
        try testing.expect(!(try stmt.step()));
    }

    // A brand-new Catalog over the same connection picks it up at load.
    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.loadFromStorage(&db);
    try testing.expectEqual(@as(usize, 1), c2.tableCount());
    const found = c2.findTableSpec("t1") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("b", found.columns[1].name);

    // Idempotent: reloading the same rows replaces rather than duplicates.
    try c2.loadFromStorage(&db);
    try testing.expectEqual(@as(usize, 1), c2.tableCount());

    // Delete removes both memory and the persisted row.
    try c1.deleteTableSpec(&db, "t1");
    try testing.expectEqual(@as(usize, 0), c1.tableCount());
    try testing.expectEqual(@as(?*spec.TableSpec, null), c1.findTableSpec("t1"));
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM zigquery_catalog");
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

    var stmt = try db.prepare("SELECT COUNT(*) FROM zigquery_catalog");
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
    // A path suffix resolves too.
    {
        const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, "SELECT a FROM ds.t2", 0, catalog_json);
        try testing.expectEqualStrings("proj_ds_t2", try resolvedTableName(analyzed.node));
    }
    // Unknown tables still fail.
    try testing.expectError(
        error.AnalyzeFailed,
        analyzer_ffi.analyzeNextStatement(alloc, "SELECT 1 FROM missing_table", 0, catalog_json),
    );
    // BigQuery's INT64 aliases resolve on the catalog that
    // GoogleSQL_AnalyzeNextStatementParams rebuilds from JSON per call, the
    // fallback when a connection's handle is unusable. data-types.md#integer_types
    _ = try analyzer_ffi.analyzeNextStatement(alloc, "SELECT CAST(1 AS INT) FROM t1", 0, catalog_json);

    // A fresh catalog carries only the seeded MISSING_FUNCTIONS (no "{}"
    // sentinel anymore: contains_substr/min_by/max_by are always present).
    var fresh = try Catalog.init(testing.allocator);
    defer fresh.deinit();
    const fresh_json = try fresh.catalogJson(alloc);
    try testing.expect(std.mem.indexOf(u8, fresh_json, "\"customFunction\"") != null);
    try testing.expect(std.mem.indexOf(u8, fresh_json, "contains_substr") != null);
}

test "catalogJson: seeded MISSING_FUNCTIONS resolve through the analyzer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c = try Catalog.init(testing.allocator);
    defer c.deinit();
    const catalog_json = try c.catalogJson(alloc);

    // contains_substr: scalar, ARBITRARY expression + STRING literal.
    _ = try analyzer_ffi.analyzeNextStatement(
        alloc,
        "SELECT CONTAINS_SUBSTR('the blue house', 'Blue')",
        0,
        catalog_json,
    );
    // Struct-typed first argument also resolves (ARG_TYPE_ARBITRARY).
    _ = try analyzer_ffi.analyzeNextStatement(
        alloc,
        "SELECT CONTAINS_SUBSTR((23, 35, 41), '35')",
        0,
        catalog_json,
    );
    // min_by/max_by: aggregate mode with templated ANY_1/ANY_2 args.
    _ = try analyzer_ffi.analyzeNextStatement(
        alloc,
        "SELECT MIN_BY(x, y) FROM (SELECT 1 AS x, 2 AS y)",
        0,
        catalog_json,
    );
    _ = try analyzer_ffi.analyzeNextStatement(
        alloc,
        "SELECT MAX_BY(x, y) FROM (SELECT 1 AS x, 2 AS y)",
        0,
        catalog_json,
    );
}

test "catalogJson: user-defined SQL function resolves through the analyzer" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c = try Catalog.init(testing.allocator);
    defer c.deinit();
    try c.createCatalogTablesIfNotExist(&db);

    // CREATE FUNCTION Add(x INT64, y INT64) AS (x + y) equivalent spec.
    const x_t = try spec.newSimpleType(alloc, .TYPE_INT64);
    const y_t = try spec.newSimpleType(alloc, .TYPE_INT64);
    const args = try alloc.alloc(*spec.NameWithType, 2);
    const a0 = try alloc.create(spec.NameWithType);
    a0.* = .{ .name = "x", .type = x_t };
    const a1 = try alloc.create(spec.NameWithType);
    a1.* = .{ .name = "y", .type = y_t };
    args[0] = a0;
    args[1] = a1;
    const fs = try alloc.create(spec.FunctionSpec);
    fs.* = .{
        .name_path = &.{"myadd"},
        .language = "SQL",
        .args = args,
        .return_type = try spec.newSimpleType(alloc, .TYPE_INT64),
        .body = "zigquery_add(@x, @y)",
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    try c.addNewFunctionSpec(&db, fs);

    const catalog_json = try c.catalogJson(alloc);
    _ = try analyzer_ffi.analyzeNextStatement(alloc, "SELECT myadd(1, 2)", 0, catalog_json);

    // Persisted row round-trips through a fresh catalog's load.
    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.loadFromStorage(&db);
    const found = c2.findFunctionSpec("myadd") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zigquery_add(@x, @y)", found.body.?);
    try testing.expectEqual(@as(usize, 2), found.args.len);

    // CallSQL substitution: @x/@y replaced, wrapped in "( ... )".
    const call = try found.callSQL(alloc, &.{ "1", "2" });
    try testing.expectEqualStrings("( zigquery_add(1, 2) )", call);

    // Delete removes memory + persisted row; analysis then fails.
    try c2.deleteFunctionSpec(&db, "myadd");
    try testing.expectEqual(@as(?*spec.FunctionSpec, null), c2.findFunctionSpec("myadd"));
    const catalog_json2 = try c2.catalogJson(alloc);
    try testing.expectError(
        error.AnalyzeFailed,
        analyzer_ffi.analyzeNextStatement(alloc, "SELECT myadd(1, 2)", 0, catalog_json2),
    );
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

test "registering a table injects its dataset's INFORMATION_SCHEMA views" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c = try Catalog.init(testing.allocator);
    defer c.deinit();
    try c.createCatalogTablesIfNotExist(&db);

    const views = info_schema_vtab.views.len;

    // One table -> the table plus one view per INFORMATION_SCHEMA view.
    try c.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "ds", "t1" }));
    try testing.expectEqual(@as(usize, 1 + views), c.tableCount());

    // A second table in the same dataset reuses them.
    try c.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "ds", "t2" }));
    try testing.expectEqual(@as(usize, 2 + views), c.tableCount());

    // A different dataset gets its own set.
    try c.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "ds2", "t3" }));
    try testing.expectEqual(@as(usize, 3 + views * 2), c.tableCount());

    // Registered under the canonical `_`-joined name.
    try testing.expect(c.findTableSpec("ds_INFORMATION_SCHEMA_TABLES") != null);
    try testing.expect(c.findTableSpec("ds2_INFORMATION_SCHEMA_COLUMNS") != null);
}

test "a table with no dataset gets no INFORMATION_SCHEMA views" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c = try Catalog.init(testing.allocator);
    defer c.deinit();
    try c.createCatalogTablesIfNotExist(&db);

    // A bare `t1` names no dataset, so there is nothing to describe.
    try c.addNewTableSpec(&db, try testTableSpec(alloc, &.{"t1"}));
    try testing.expectEqual(@as(usize, 1), c.tableCount());
}

test "INFORMATION_SCHEMA views come back after a reload" {
    // They are synthesised, never persisted, so a fresh catalog must rebuild
    // them from the stored user tables rather than find them in storage.
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c1 = try Catalog.init(testing.allocator);
    defer c1.deinit();
    try c1.createCatalogTablesIfNotExist(&db);
    try c1.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "ds", "t1" }));

    // Only the user table is persisted.
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM zigquery_catalog");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
    }

    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.loadFromStorage(&db);
    try testing.expectEqual(@as(usize, 1 + info_schema_vtab.views.len), c2.tableCount());
    try testing.expect(c2.findTableSpec("ds_INFORMATION_SCHEMA_TABLES") != null);
}

test "a declared dataset persists as a dataset row, reloads with its resource, and deletes" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c1 = try Catalog.init(testing.allocator);
    defer c1.deinit();
    try c1.createCatalogTablesIfNotExist(&db);
    const resource = "{\"datasetReference\":{\"datasetId\":\"ds\",\"projectId\":\"p\"},\"id\":\"ds\"}";
    try c1.addNewDatasetSpec(&db, &.{
        .name_path = &.{ "p", "ds" },
        .metadata = resource,
        .created_at = "2024-01-02T03:04:05Z",
    });

    const declared = c1.datasetSpecByName("p_ds") orelse return error.TestUnexpectedResult;
    try testing.expect(!declared.is_synthetic);
    try testing.expectEqualStrings(resource, declared.metadata);
    try testing.expectEqual(@as(usize, 1), (try c1.liveDatasets(alloc)).len);
    // The project's SCHEMATA view comes with it, so `p.INFORMATION_SCHEMA.
    // SCHEMATA` resolves before the dataset holds a table.
    try testing.expect(c1.findTableSpec("p_INFORMATION_SCHEMA_SCHEMATA") != null);

    // Persisted under its own kind, beside tables and functions.
    {
        var stmt = try db.prepare("SELECT name, kind FROM zigquery_catalog");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqualStrings("p_ds", stmt.columnText(0));
        try testing.expectEqualStrings(@tagName(CatalogSpecKind.dataset), stmt.columnText(1));
        try testing.expect(!(try stmt.step()));
    }

    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.loadFromStorage(&db);
    const reloaded = c2.datasetSpecByName("p_ds") orelse return error.TestUnexpectedResult;
    try testing.expect(!reloaded.is_synthetic);
    try testing.expectEqualStrings(resource, reloaded.metadata);
    try testing.expectEqualStrings("2024-01-02T03:04:05Z", reloaded.created_at);

    // Delete tombstones the slot and removes the row; a second delete, or a
    // delete of something never declared, is DatasetNotFound.
    try c1.deleteDatasetSpec(&db, "p_ds");
    try testing.expectEqual(@as(?*spec.DatasetSpec, null), c1.datasetSpecByName("p_ds"));
    try testing.expectEqual(@as(usize, 0), (try c1.liveDatasets(alloc)).len);
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM zigquery_catalog");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
    }
    try testing.expectError(error.DatasetNotFound, c1.deleteDatasetSpec(&db, "p_ds"));
    try testing.expectError(error.DatasetNotFound, c1.deleteDatasetSpec(&db, "p_never"));

    // Declaring it again takes a fresh slot.
    try c1.addNewDatasetSpec(&db, &.{ .name_path = &.{ "p", "ds" } });
    try testing.expectEqual(@as(usize, 1), (try c1.liveDatasets(alloc)).len);

    // A synthetic spec is never persisted through this path.
    try testing.expectError(error.NotPersistent, c1.addNewDatasetSpec(&db, &.{
        .name_path = &.{ "p", "inferred" },
        .is_synthetic = true,
    }));
}

test "a table's dataset is inferred as synthetic and a declaration replaces it in place" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var c1 = try Catalog.init(testing.allocator);
    defer c1.deinit();
    try c1.createCatalogTablesIfNotExist(&db);
    try c1.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "p", "ds", "t" }));

    const inferred = c1.datasetSpecByName("p_ds") orelse return error.TestUnexpectedResult;
    try testing.expect(inferred.is_synthetic);
    // Not declared, so not deletable — and not persisted: the table is the
    // only row.
    try testing.expectError(error.DatasetNotFound, c1.deleteDatasetSpec(&db, "p_ds"));
    {
        var stmt = try db.prepare("SELECT COUNT(*) FROM zigquery_catalog");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
    }

    // Declaring it upgrades the same slot rather than adding a second entry.
    try c1.addNewDatasetSpec(&db, &.{ .name_path = &.{ "p", "ds" }, .metadata = "{\"id\":\"ds\"}" });
    const live = try c1.liveDatasets(alloc);
    try testing.expectEqual(@as(usize, 1), live.len);
    try testing.expect(!live[0].is_synthetic);
    try testing.expectEqualStrings("{\"id\":\"ds\"}", live[0].metadata);

    // On reload the table row comes first (rowid order), so its inferred
    // dataset is registered before the dataset row arrives; the declaration
    // must still win.
    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.loadFromStorage(&db);
    const reloaded = c2.datasetSpecByName("p_ds") orelse return error.TestUnexpectedResult;
    try testing.expect(!reloaded.is_synthetic);
    try testing.expectEqualStrings("{\"id\":\"ds\"}", reloaded.metadata);
    try testing.expectEqual(@as(usize, 1), (try c2.liveDatasets(alloc)).len);
}

/// Every `zigquery_catalog` row as "name:kind", comma-separated, in key order.
fn catalogRows(alloc: std.mem.Allocator, db: *sqlite.Db) ![]const u8 {
    var stmt = try db.prepare("SELECT name, kind FROM zigquery_catalog ORDER BY name, kind");
    defer stmt.finalize();
    var out: std.ArrayList(u8) = .empty;
    while (try stmt.step()) {
        if (out.items.len > 0) try out.append(alloc, ',');
        try out.print(alloc, "{s}:{s}", .{ stmt.columnText(0), stmt.columnText(1) });
    }
    return out.items;
}

test "a dataset and a table sharing a canonical name keep separate rows" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Dataset `p.a_b` and table `p.a.b` are both `p_a_b`, as are dataset `p.x_y` and table
    // `p.x.y`. One pair is declared dataset-first and the other table-first, so neither upsert
    // may land on the other's row.
    var c1 = try Catalog.init(testing.allocator);
    defer c1.deinit();
    try c1.createCatalogTablesIfNotExist(&db);
    try c1.addNewDatasetSpec(&db, &.{ .name_path = &.{ "p", "a_b" } });
    try c1.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "p", "a", "b" }));
    try c1.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "p", "x", "y" }));
    try c1.addNewDatasetSpec(&db, &.{ .name_path = &.{ "p", "x_y" } });
    try testing.expectEqualStrings(
        "p_a_b:dataset,p_a_b:table,p_x_y:dataset,p_x_y:table",
        try catalogRows(alloc, &db),
    );

    // Each comes back as itself.
    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.loadFromStorage(&db);
    for ([_][]const u8{ "p_a_b", "p_x_y" }, [_][]const u8{ "a_b", "x_y" }) |name, dataset_id| {
        const ds = c2.datasetSpecByName(name) orelse return error.TestUnexpectedResult;
        try testing.expect(!ds.is_synthetic);
        try testing.expectEqualStrings(dataset_id, ds.name_path[1]);
        const table = c2.findTableSpec(name) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 3), table.name_path.len);
    }

    // A delete takes its own kind's row and leaves the other.
    try c1.deleteDatasetSpec(&db, "p_a_b");
    try c1.deleteTableSpec(&db, "p_x_y");
    try testing.expectEqualStrings("p_a_b:table,p_x_y:dataset", try catalogRows(alloc, &db));
}

test "a function and a table sharing a canonical name keep separate rows" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // BigQuery keeps routines and tables apart, so `p.ds.f` can name both.
    var c1 = try Catalog.init(testing.allocator);
    defer c1.deinit();
    try c1.createCatalogTablesIfNotExist(&db);
    try c1.addNewTableSpec(&db, try testTableSpec(alloc, &.{ "p", "ds", "f" }));
    const fs = try alloc.create(spec.FunctionSpec);
    fs.* = .{
        .name_path = &.{ "p", "ds", "f" },
        .language = "SQL",
        .return_type = try spec.newSimpleType(alloc, .TYPE_INT64),
        .body = "1",
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    try c1.addNewFunctionSpec(&db, fs);
    try testing.expectEqualStrings("p_ds_f:function,p_ds_f:table", try catalogRows(alloc, &db));

    var c2 = try Catalog.init(testing.allocator);
    defer c2.deinit();
    try c2.loadFromStorage(&db);
    try testing.expect(c2.findTableSpec("p_ds_f") != null);
    try testing.expect(c2.findFunctionSpec("p_ds_f") != null);

    try c1.deleteFunctionSpec(&db, "p_ds_f");
    try testing.expectEqualStrings("p_ds_f:table", try catalogRows(alloc, &db));
}
