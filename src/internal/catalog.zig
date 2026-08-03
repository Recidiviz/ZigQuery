//! Port of go-zetasqlite internal/catalog.go (table subset).
//!
//! The persisted side is byte-faithful: the `zetasqlite_catalog` DDL, the
//! upsert/delete SQL and the JSON `spec` column all match Go, so a database
//! written by go-zetasqlite loads here and vice versa.
//!
//! The in-memory side is redesigned per the port plan: where Go builds a
//! live googlesql.SimpleCatalog through the engine API, this port renders
//! `SimpleCatalogProto` in protobuf-JSON form for the C++ analyzer shim to
//! deserialize. Go's dotted-path registration (addTableSpecRecursive: the
//! full dotted name plus every suffix at the root, and sub-catalogs per path
//! segment) is mirrored structurally with nested `catalog` entries; every
//! SimpleTableProto carries `name`=canonical ("_"-joined SQLite table name,
//! what Table.Name() reports back through the resolved AST) and
//! `nameInCatalog`=the name it resolves under.
//!
//! That rendering is incremental, not per-statement. The shim holds a
//! persistent catalog handle and this catalog keeps an append-only change
//! log; `renderDelta` hands a consumer's `Cursor` just the entries it has not
//! seen, so a statement analyzed against an unchanged catalog renders nothing
//! at all. `catalogJson` — the whole tree in one proto — is reserved for
//! seeding a fresh handle and for the stateless fallback path.
//!
//! Function specs (`kind = 'function'`) follow the same pattern: persisted
//! rows are Go-compatible JSON, and the in-memory side renders
//! SimpleCatalogProto `customFunction` entries (FunctionProto: namePath /
//! mode / signature with argument kinds+types) instead of Go's live
//! SimpleCatalog registration. Go's MISSING_FUNCTIONS seeding is mirrored
//! for the entries that are NOT already builtins in the shim's newer
//! GoogleSQL (contains_substr, min_by, max_by; array_slice / array_first /
//! array_last are builtins now — Go pre-filters those the same way).
//!
//! Deferred (vs Go):
//! - Wildcard tables (Gap G): not ported.

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
const load_query = "SELECT name, kind, spec FROM zetasqlite_catalog";

/// Go CatalogSpecKind values.
pub const table_spec_kind = "table";
pub const view_spec_kind = "view";
pub const function_spec_kind = "function";
const catalog_name = "zetasqlite";

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
    /// Insertion-ordered specs (Go: c.tables). catalogJson renders from this.
    ///
    /// A deleted table leaves a null tombstone rather than compacting the
    /// list: removing an element would shift every later index and force a
    /// full rescan of `table_map` to repair it, which is O(catalog) per drop
    /// on a path the emulator takes for every view materialization. Slots are
    /// never reused, so a `*spec.TableSpec` handed to a caller stays valid for
    /// the catalog's lifetime.
    tables: std.ArrayList(?*spec.TableSpec),
    /// Canonical table name -> index into `tables` (Go: c.tableMap). Only
    /// live (non-tombstoned) slots are referenced.
    table_map: std.StringHashMap(usize),
    /// Insertion-ordered function specs (Go: c.functions).
    functions: std.ArrayList(*spec.FunctionSpec),
    /// Canonical function name -> index into `functions` (Go: c.funcMap).
    func_map: std.StringHashMap(usize),
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
                try ops.append(alloc, .{ .remove = try alloc.dupeZ(u8, name) });
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
        if (specs.len == 0) return alloc.dupeZ(u8, "{}");
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
            .changes = .empty,
        };
        errdefer c.deinit();
        // Go NewCatalog: seed MISSING_FUNCTIONS (memory only, never
        // persisted; Go's addFunctionSpec skips saveFunctionSpec here).
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
        c.changes.deinit(c.gpa);
        c.arena_state.deinit();
        c.gpa.destroy(c);
    }

    /// Go createCatalogTablesIfNotExists.
    pub fn createCatalogTablesIfNotExist(c: *Catalog, db: *sqlite.Db) Error!void {
        _ = c;
        try db.exec(create_catalog_table_query);
        try db.exec(index_catalog_table_query);
    }

    /// Loads every persisted spec into memory. Go's Catalog.Sync equivalent,
    /// but a one-shot load rather than a per-statement incremental re-read.
    ///
    /// Go re-syncs before every statement, filtered by `updatedAt >= cursor`,
    /// where the cursor is wall-clock time stamped *before* the read. That
    /// permanently skips a commit stamped before the cursor but made visible
    /// after it — narrow with one connection, the common case with several,
    /// and it cost a connection-pool experiment 530 of 594 view creations.
    /// Coherence between connections is the shared catalog's job now, not a
    /// timestamp's, so this runs once at open and never again.
    pub fn loadFromStorage(c: *Catalog, db: *sqlite.Db) Error!void {
        try c.createCatalogTablesIfNotExist(db);

        var stmt = try db.prepare(load_query);
        defer stmt.finalize();
        while (try stmt.step()) {
            const kind = stmt.columnText(1);
            if (std.mem.eql(u8, kind, table_spec_kind) or std.mem.eql(u8, kind, view_spec_kind)) {
                // Copy out of sqlite's row buffer before the next step().
                const spec_json = try c.arena_state.allocator().dupe(u8, stmt.columnText(2));
                try c.loadTableSpec(spec_json);
            } else if (std.mem.eql(u8, kind, function_spec_kind)) {
                const spec_json = try c.arena_state.allocator().dupe(u8, stmt.columnText(2));
                try c.loadFunctionSpec(spec_json);
            } else {
                return error.InvalidSpec; // Go: "unknown catalog spec kind %s"
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

    /// Go AddNewTableSpec: in-memory registration plus (unless temporary)
    /// the persisted upsert. The spec is deep-copied into the catalog arena
    /// (via its canonical JSON), so callers may pass short-lived memory.
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

    /// Go saveTableSpec: the upsert. `encoded` is the spec's JSON.
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

    /// Overlay counterpart of `deleteTableSpec`: an overlay spec was never
    /// persisted, so there is no row to delete.
    pub fn deleteOverlayTableSpec(c: *Catalog, name: []const u8) Error!void {
        return c.forgetTableSpec(name);
    }

    fn forgetTableSpec(c: *Catalog, name: []const u8) Error!void {
        const entry = c.table_map.fetchRemove(name) orelse return error.TableNotFound;
        try c.changes.append(c.gpa, .{ .table_removed = entry.key });
        // Tombstone rather than compact: no index shifts, so no reindex.
        c.tables.items[entry.value] = null;
    }

    /// Go DeleteTableSpec: remove from memory and from the persisted table.
    pub fn deleteTableSpec(c: *Catalog, db: *sqlite.Db, name: []const u8) Error!void {
        try c.forgetTableSpec(name);

        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        var stmt = try db.prepare(delete_catalog_query);
        defer stmt.finalize();
        try stmt.bindText(1, name);
        _ = try stmt.step();
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

    // ------------------------------------------------------------------
    // Function specs (Go loadFunctionSpec / AddNewFunctionSpec /
    // DeleteFunctionSpec / saveFunctionSpec)
    // ------------------------------------------------------------------

    fn loadFunctionSpec(c: *Catalog, spec_json: []const u8) Error!void {
        const fs = spec.functionSpecFromJson(c.arena_state.allocator(), spec_json) catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSpec,
            };
        try c.addFunctionSpecToMemory(fs);
    }

    /// Go AddNewFunctionSpec: in-memory registration plus (unless
    /// temporary) the persisted upsert. Deep-copies via canonical JSON so
    /// callers may pass short-lived memory.
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

    /// Go saveFunctionSpec: the shared catalog upsert with kind='function'.
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
        try stmt.bindText(2, function_spec_kind);
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

    /// Go DeleteFunctionSpec: remove from memory and the persisted table.
    /// (Go: "failed to find function spec from map by %s".)
    pub fn deleteFunctionSpec(c: *Catalog, db: *sqlite.Db, name: []const u8) Error!void {
        try c.forgetFunctionSpec(name);

        var scope = phase.SourceScope.begin(.catalog);
        defer scope.end();
        var stmt = try db.prepare(delete_catalog_query);
        defer stmt.finalize();
        try stmt.bindText(1, name);
        _ = try stmt.step();
    }

    pub fn findFunctionSpec(c: *const Catalog, name: []const u8) ?*spec.FunctionSpec {
        const idx = c.func_map.get(name) orelse return null;
        return c.functions.items[idx];
    }

    /// Go analyzer.go's per-statement funcMap build (catalog.getFunctions
    /// keyed by FuncName). The seeded MISSING_FUNCTIONS (contains_substr,
    /// min_by, max_by) are excluded: they carry no body and are lowered by
    /// the extractor / runtime UDFs instead, so routing them through
    /// CallSQL would shadow those paths. Every user-created spec is
    /// included — including "js" ones, whose bodyless CallSQL raises a
    /// clear Unimplemented rather than emitting a call to a function
    /// SQLite never defined. Allocated from `alloc` (per-statement arena).
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

    /// Go addFunctionSpec's in-memory half (duplicate name replaces the
    /// stored spec, same deliberate deviation as addTableSpecToMemory).
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

    /// Go addTableSpec's in-memory half. On a duplicate canonical name the
    /// stored spec is replaced (Go only swaps the map entry and leaves the
    /// engine catalog with the first registration; here the change log carries
    /// the replacement through as a remove followed by an add, so it becomes
    /// visible immediately — a deliberate, strictly-more-correct deviation).
    fn addTableSpecToMemory(c: *Catalog, table_spec: *spec.TableSpec) Error!void {
        const arena = c.arena_state.allocator();
        const table_name = try table_spec.tableName(arena);
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

    /// Registers the INFORMATION_SCHEMA views for a table's dataset, once.
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
            if (c.table_map.contains(canonical)) continue;
            try c.tables.append(c.gpa, table_spec);
            try c.table_map.put(canonical, c.tables.items.len - 1);
            try c.changes.append(c.gpa, .{ .table_added = canonical });
        }
    }

    // ------------------------------------------------------------------
    // SimpleCatalogProto JSON rendering (replaces Go's live SimpleCatalog)
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
            return alloc.dupeZ(u8, "{}");

        var root = Node{ .name = catalog_name };
        for (c.tables.items) |maybe| {
            const table_spec = maybe orelse continue;
            const canonical = try table_spec.tableName(alloc);
            // Shadowed by the overlay: emit the overlay's definition only.
            if (overlay) |o| if (o.table_map.contains(canonical)) continue;
            try addTableToNode(alloc, &root, table_spec.name_path, table_spec, canonical);
        }
        // Go addFunctionSpecRecursive: functions register under their LEAF
        // name at the root and inside every sub-catalog along the path.
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
        if (fn_start >= c.functions.items.len) return alloc.dupeZ(u8, "{}");
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

/// One registration point: the table resolves under `registered` and
/// reports `canonical` as its Name() (Go createSimpleTable's canonicalName).
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

/// Go addFunctionSpecRecursive: for a path [a, b, c] the function is
/// registered under its leaf name "c" at the current level AND inside the
/// sub-catalog chain a -> b (each level also re-registers at the root,
/// exactly like Go's double recursion).
fn addFunctionToNode(
    alloc: std.mem.Allocator,
    node: *Node,
    path: []const []const u8,
    fn_spec: *const spec.FunctionSpec,
) error{ OutOfMemory, InvalidSpec }!void {
    if (path.len == 0) return error.InvalidSpec; // Go: "function name is not found"
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

/// FunctionProto protobuf-JSON (googlesql/proto/function.proto): namePath,
/// group "", mode SCALAR/AGGREGATE, one FunctionSignatureProto whose
/// argument/returnType are FunctionArgumentTypeProto entries — templated
/// arguments carry `kind` (SignatureArgumentKind name), fixed arguments
/// carry `type` (TypeProto). Mirrors Go createFunction's
/// NewFunctionArgumentType3/4 + NewFunctionSignature3 + NewFunction.
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

/// FunctionArgumentTypeProto JSON: Go NewFunctionArgumentType4(kind, 1) for
/// templated kinds, NewFunctionArgumentType3(type, 1) for fixed types
/// (numOccurrences 1 in both).
fn appendFunctionArgumentTypeJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    t: *const spec.Type,
) error{ OutOfMemory, InvalidSpec }!void {
    if (spec.isTemplatedSignatureKind(t.signature_kind)) {
        const kind: pb.SignatureArgumentKind = @enumFromInt(t.signature_kind);
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

/// Go catalog.go MISSING_FUNCTIONS, minus the entries that are engine
/// builtins in the shim's GoogleSQL revision (array_slice, array_first,
/// array_last) — Go pre-filters those against `builtins` at registration.
fn missingFunctions(alloc: std.mem.Allocator) error{OutOfMemory}![]*spec.FunctionSpec {
    const arg_arbitrary: i32 = @intFromEnum(pb.SignatureArgumentKind.ARG_KIND_EXPR_ARBITRARY);
    const arg_any_1: i32 = @intFromEnum(pb.SignatureArgumentKind.ARG_KIND_EXPR_ANY_1);
    const arg_any_2: i32 = @intFromEnum(pb.SignatureArgumentKind.ARG_KIND_EXPR_ANY_2);

    const out = try alloc.alloc(*spec.FunctionSpec, 3);

    // contains_substr(expression ARBITRARY, search_value_literal STRING) -> BOOL
    {
        const expr_t = try alloc.create(spec.Type);
        expr_t.* = .{
            .name = "expression",
            .kind = @intFromEnum(pb.TypeKind.TYPE_STRING),
            .signature_kind = arg_arbitrary,
        };
        const search_t = try alloc.create(spec.Type);
        search_t.* = .{ .name = "search_value_literal", .kind = @intFromEnum(pb.TypeKind.TYPE_STRING) };
        const ret_t = try alloc.create(spec.Type);
        ret_t.* = .{ .name = "BOOL", .kind = @intFromEnum(pb.TypeKind.TYPE_BOOL) };
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
        .body = "zetasqlite_add(@x, @y)",
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
    try testing.expectEqualStrings("zetasqlite_add(@x, @y)", found.body.?);
    try testing.expectEqual(@as(usize, 2), found.args.len);

    // CallSQL substitution: @x/@y replaced, wrapped in "( ... )".
    const call = try found.callSQL(alloc, &.{ "1", "2" });
    try testing.expectEqualStrings("( zetasqlite_add(1, 2) )", call);

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
        var stmt = try db.prepare("SELECT COUNT(*) FROM zetasqlite_catalog");
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
