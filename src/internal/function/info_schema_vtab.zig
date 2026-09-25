//! `INFORMATION_SCHEMA.{SCHEMATA,TABLES,COLUMNS}` as SQLite virtual tables.
//!
//! Rows are synthesised from the catalog at query time — nothing is
//! materialised into real tables — so after a reopen these views report
//! whatever the catalog now holds rather than a stale snapshot.
//!
//! ## How a query gets here
//!
//! `catalog.zig` registers a synthetic `TableSpec` per (dataset, view) so the
//! analyzer accepts the path, and `transformer/scan_table.zig` recognises the
//! resulting canonical name (`<prefix>_INFORMATION_SCHEMA_<VIEW>`) and emits
//! `FROM zigquery_info_schema_<view>('<dataset>')` instead of a table
//! reference. The dataset rides in on the trailing hidden `schema` column, the
//! same mechanism `unnest_vtab.zig` uses to receive its array argument.
//!
//! ## Two constraints worth stating up front
//!
//! **Values must be encoded, never TEXT.** `driver.Rows.next` rejects a `.text`
//! column outright ("No engine value is TEXT") and turns it into
//! `error.CorruptData`, so every column goes out through `encoder.EncodeValue`
//! exactly as `unnest_vtab.xColumn` does. A bare `sqlite3_result_text` here
//! would fail every query that reads it.
//!
//! **The catalog is read from a snapshot, not under its lock.** `xFilter` runs
//! inside `sqlite3_step`, and `shared_catalog.zig` forbids taking the catalog
//! lock with a transaction open — the reverse order deadlocks a connection
//! pool. The driver publishes `State.info_schema` before preparing; an empty
//! snapshot yields zero rows, which is also what should happen during close.
//!
//! ## Known limitation
//!
//! `catalog.addTableToNode` registers every path suffix including the bare
//! leaf, first-wins, so an unqualified `FROM INFORMATION_SCHEMA.TABLES`
//! resolves to whichever dataset registered first. BigQuery reads that spelling
//! as "the default dataset"; the engine has no such concept.
// ephor:ignore-file ZA102 ZA303 ZA304 ZA701

const std = @import("std");
const sqlite = @import("../../sqlite.zig");
const encoder = @import("../encoder.zig");
const spec = @import("../spec.zig");
const value_mod = @import("../value.zig");

const c = sqlite.c;

const Value = value_mod.Value;

/// The dataset segment of an INFORMATION_SCHEMA path.
pub const info_schema_segment = "INFORMATION_SCHEMA";

/// One synthesised cell. Only the kinds these views actually produce.
pub const Cell = union(enum) {
    null,
    string: []const u8,
    int: i64,
};

pub const Row = []const Cell;

/// The views, in the order their columns are declared. `module` is the SQLite
/// name the transformer emits; `view` is the BigQuery name that appears in the
/// path.
pub const View = struct {
    view: []const u8,
    module: [:0]const u8,
    columns: []const []const u8,
    /// Index of the column naming the table, for constraint pushdown. Null for
    /// SCHEMATA, which has no table dimension.
    name_col: ?u32,
    build: *const fn (
        std.mem.Allocator,
        []const *spec.TableSpec,
        []const *spec.DatasetSpec,
        Filter,
    ) error{OutOfMemory}![]const Row,

    /// Index of the column naming the dataset. First in every view, whether it
    /// is spelled `schema_name` or `table_schema`.
    const dataset_col: u32 = 1;
};

/// What a scan has been narrowed to. `prefix` always comes from the transformer
/// (it is the scanned path); `schema` and `table` are the user's own WHERE
/// terms, handed to us by SQLite's planner when it offers them.
pub const Filter = struct {
    /// `_`-joined path of the dataset being scanned. Empty means every dataset.
    prefix: []const u8 = "",
    schema: ?[]const u8 = null,
    table: ?[]const u8 = null,
};

pub const views = [_]View{
    .{
        .view = "SCHEMATA",
        .module = "zigquery_info_schema_schemata",
        .columns = &.{
            "catalog_name",  "schema_name",        "schema_owner",
            "creation_time", "last_modified_time", "location",
        },
        .name_col = null,
        .build = buildSchemata,
    },
    .{
        .view = "TABLES",
        .module = "zigquery_info_schema_tables",
        .columns = &.{
            "table_catalog", "table_schema", "table_name",
            "table_type",    "is_typed",     "is_insertable_into",
            "creation_time",
        },
        .name_col = 2,
        .build = buildTables,
    },
    .{
        .view = "COLUMNS",
        .module = "zigquery_info_schema_columns",
        .columns = &.{
            "table_catalog",     "table_schema",           "table_name",
            "column_name",       "ordinal_position",       "is_nullable",
            "data_type",         "is_partitioning_column", "is_hidden",
            "is_system_defined",
        },
        .name_col = 2,
        .build = buildColumns,
    },
    .{
        .view = "TABLE_OPTIONS",
        .module = "zigquery_info_schema_table_options",
        .columns = &.{
            "table_catalog", "table_schema", "table_name",
            "option_name",   "option_type",  "option_value",
        },
        .name_col = 2,
        .build = buildTableOptions,
    },
};

/// The view a canonical catalog name refers to, or null.
///
/// The canonical name is the `_`-joined path, so
/// `proj_ds_INFORMATION_SCHEMA_TABLES` ends in `_INFORMATION_SCHEMA_TABLES`.
/// Matching on that suffix is enough: the extractor hands the transformer this
/// exact string (`extractor.zig` reads the resolved table's catalog name), so
/// no side-table of metadata is needed.
pub fn viewForCanonicalName(canonical: []const u8) ?*const View {
    for (&views) |*v| {
        var buf: [64]u8 = undefined;
        const suffix = std.fmt.bufPrint(&buf, "_{s}_{s}", .{ info_schema_segment, v.view }) catch
            continue;
        if (std.mem.endsWith(u8, canonical, suffix)) return v;
    }
    return null;
}

/// The dataset a synthetic INFORMATION_SCHEMA path belongs to: the segment
/// immediately before `INFORMATION_SCHEMA`.
pub fn datasetOfPath(name_path: []const []const u8) ?[]const u8 {
    if (name_path.len < 3) return null;
    const seg = name_path[name_path.len - 2];
    if (!std.mem.eql(u8, seg, info_schema_segment)) return null;
    return name_path[name_path.len - 3];
}

// ---- row synthesis (pure; no SQLite involvement) ----

/// Project and dataset for a user table, or null when the path is too short to
/// name a dataset. A 2-part `ds.tbl` has no project, which is how the spec
/// corpus writes it; a 3-part `proj.ds.tbl` is what the emulator registers.
fn splitPath(name_path: []const []const u8) ?struct { catalog: []const u8, schema: []const u8 } {
    if (name_path.len < 2) return null;
    return .{
        .catalog = if (name_path.len >= 3) name_path[name_path.len - 3] else "",
        .schema = name_path[name_path.len - 2],
    };
}

/// Is this one of our own synthetic views, or a connection-scoped temp? Neither
/// belongs in the output.
fn hidden(table_spec: *const spec.TableSpec) bool {
    if (table_spec.is_temp) return true;
    for (table_spec.name_path) |seg| {
        if (std.mem.eql(u8, seg, info_schema_segment)) return true;
    }
    return false;
}

/// Tables under the dataset whose `_`-joined path is `prefix`, skipping temps
/// and our own synthetic views. An empty `prefix` matches everything (an
/// unconstrained scan).
///
/// Matching whole prefixes rather than the bare dataset name is deliberate:
/// canonical names are `_`-joined and dataset names may contain underscores,
/// so `demo_ds_...` is not decomposable. A table and its dataset's views always
/// share a prefix, which makes this exact.
fn matches(arena: std.mem.Allocator, table_spec: *const spec.TableSpec, filter: Filter) bool {
    if (hidden(table_spec)) return false;
    const path = table_spec.name_path;
    if (path.len < 2) return false;

    // The user's own WHERE terms, pushed down by SQLite's planner. Pruning here
    // is what keeps COLUMNS from building a row per column of every table in
    // the dataset when the query only wanted one table's.
    if (filter.table) |want| {
        if (!std.mem.eql(u8, path[path.len - 1], want)) return false;
    }
    if (filter.schema) |want| {
        if (!std.mem.eql(u8, path[path.len - 2], want)) return false;
    }

    if (filter.prefix.len == 0) return true;
    const own = spec.formatPath(arena, path[0 .. path.len - 1]) catch return false;
    return std.mem.eql(u8, own, filter.prefix);
}

/// SCHEMATA's own matching, looser than `matches()`: a scan can be narrowed
/// to exactly one dataset (`filter.prefix` is that dataset's own `_`-joined
/// path, same as `matches()`) or to every dataset in one project
/// (`filter.prefix` is just the bare project — `<project>.INFORMATION_SCHEMA.
/// SCHEMATA` has no dataset segment to narrow by). The two cannot collide: a
/// project only ever equals a bare, project-less dataset's own name, which is
/// itself the narrower, correct match either way.
fn schemataMatches(arena: std.mem.Allocator, table_spec: *const spec.TableSpec, filter: Filter) bool {
    if (hidden(table_spec)) return false;
    const path = table_spec.name_path;
    if (path.len < 2) return false;
    if (filter.schema) |want| {
        if (!std.mem.eql(u8, path[path.len - 2], want)) return false;
    }
    if (filter.prefix.len == 0) return true;
    const own = spec.formatPath(arena, path[0 .. path.len - 1]) catch return false;
    if (std.mem.eql(u8, own, filter.prefix)) return true;
    return path.len >= 3 and std.mem.eql(u8, path[0], filter.prefix);
}

/// The dataset-registry analogue of `schemataMatches`, for a dataset that
/// holds no table of its own yet to carry a path `matches()`/`schemataMatches`
/// could scan.
fn datasetMatches(ds: *const spec.DatasetSpec, filter: Filter) bool {
    if (filter.schema) |want| {
        if (!std.mem.eql(u8, ds.name_path[1], want)) return false;
    }
    if (filter.prefix.len == 0) return true;
    if (std.mem.eql(u8, ds.name_path[1], filter.prefix)) return true;
    return std.mem.eql(u8, ds.name_path[0], filter.prefix);
}

fn buildSchemata(
    arena: std.mem.Allocator,
    specs: []const *spec.TableSpec,
    datasets: []const *spec.DatasetSpec,
    filter: Filter,
) error{OutOfMemory}![]const Row {
    var out: std.ArrayList(Row) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    for (specs) |table_spec| {
        if (!schemataMatches(arena, table_spec, filter)) continue;
        const parts = splitPath(table_spec.name_path).?;
        if (seen.contains(parts.schema)) continue;
        try seen.put(arena, parts.schema, {});
        const row = try arena.alloc(Cell, 6);
        row[0] = .{ .string = parts.catalog };
        row[1] = .{ .string = parts.schema };
        row[2] = .null; // schema_owner: no ownership model
        row[3] = if (table_spec.created_at.len > 0)
            .{ .string = table_spec.created_at }
        else
            .null;
        row[4] = .null; // last_modified_time
        row[5] = .null; // location: no regions
        try out.append(arena, row);
    }
    // A dataset with no table of its own contributes nothing above; report it
    // from the registry instead. Checked after `specs` so a dataset that does
    // have tables keeps reporting whatever `created_at` its own path carried.
    for (datasets) |ds| {
        if (!datasetMatches(ds, filter)) continue;
        if (seen.contains(ds.name_path[1])) continue;
        try seen.put(arena, ds.name_path[1], {});
        const row = try arena.alloc(Cell, 6);
        row[0] = .{ .string = ds.name_path[0] };
        row[1] = .{ .string = ds.name_path[1] };
        row[2] = .null; // schema_owner: no ownership model
        row[3] = if (ds.created_at.len > 0) .{ .string = ds.created_at } else .null;
        row[4] = .null; // last_modified_time
        row[5] = .null; // location: no regions
        try out.append(arena, row);
    }
    return out.toOwnedSlice(arena);
}

fn buildTables(
    arena: std.mem.Allocator,
    specs: []const *spec.TableSpec,
    datasets: []const *spec.DatasetSpec,
    filter: Filter,
) error{OutOfMemory}![]const Row {
    _ = datasets; // A dataset with no tables has no rows to report here.
    var out: std.ArrayList(Row) = .empty;
    for (specs) |table_spec| {
        if (!matches(arena, table_spec, filter)) continue;
        const parts = splitPath(table_spec.name_path).?;
        const row = try arena.alloc(Cell, 7);
        row[0] = .{ .string = parts.catalog };
        row[1] = .{ .string = parts.schema };
        row[2] = .{ .string = table_spec.name_path[table_spec.name_path.len - 1] };
        row[3] = .{ .string = if (table_spec.is_view) "VIEW" else "BASE TABLE" };
        row[4] = .{ .string = "NO" };
        row[5] = .{ .string = if (table_spec.is_view) "NO" else "YES" };
        row[6] = if (table_spec.created_at.len > 0)
            .{ .string = table_spec.created_at }
        else
            .null;
        try out.append(arena, row);
    }
    return out.toOwnedSlice(arena);
}

fn buildColumns(
    arena: std.mem.Allocator,
    specs: []const *spec.TableSpec,
    datasets: []const *spec.DatasetSpec,
    filter: Filter,
) error{OutOfMemory}![]const Row {
    _ = datasets; // A dataset with no tables has no columns to report here.
    var out: std.ArrayList(Row) = .empty;
    for (specs) |table_spec| {
        if (!matches(arena, table_spec, filter)) continue;
        const parts = splitPath(table_spec.name_path).?;
        const table_name = table_spec.name_path[table_spec.name_path.len - 1];
        for (table_spec.columns, 0..) |col, i| {
            const row = try arena.alloc(Cell, 10);
            row[0] = .{ .string = parts.catalog };
            row[1] = .{ .string = parts.schema };
            row[2] = .{ .string = table_name };
            row[3] = .{ .string = col.name };
            row[4] = .{ .int = @intCast(i + 1) };
            row[5] = .{ .string = if (col.is_not_null) "NO" else "YES" };
            row[6] = .{ .string = col.type.formatType(arena) catch "" };
            // No partitioning, hidden or system columns exist in this engine.
            row[7] = .{ .string = "NO" };
            row[8] = .{ .string = "NO" };
            row[9] = .{ .string = "NO" };
            try out.append(arena, row);
        }
    }
    return out.toOwnedSlice(arena);
}

/// One row per declared option. A table with no OPTIONS contributes nothing,
/// which is what BigQuery does — it reports options that were set, not every
/// option with a default.
fn buildTableOptions(
    arena: std.mem.Allocator,
    specs: []const *spec.TableSpec,
    datasets: []const *spec.DatasetSpec,
    filter: Filter,
) error{OutOfMemory}![]const Row {
    _ = datasets; // A dataset with no tables has no options to report here.
    var out: std.ArrayList(Row) = .empty;
    for (specs) |table_spec| {
        if (!matches(arena, table_spec, filter)) continue;
        const parts = splitPath(table_spec.name_path).?;
        const table_name = table_spec.name_path[table_spec.name_path.len - 1];
        for (table_spec.options) |opt| {
            if (opt.name.len == 0) continue;
            const row = try arena.alloc(Cell, 6);
            row[0] = .{ .string = parts.catalog };
            row[1] = .{ .string = parts.schema };
            row[2] = .{ .string = table_name };
            row[3] = .{ .string = opt.name };
            row[4] = .{ .string = opt.type_name };
            row[5] = .{ .string = opt.value };
            try out.append(arena, row);
        }
    }
    return out.toOwnedSlice(arena);
}

// ---- the virtual tables ----

/// Reachable from every callback: the module aux pointer, hung off the vtab.
/// `state` is the connection's shared UDF state, which carries the catalog
/// snapshot the driver publishes before each statement.
const ModuleCtx = struct {
    gpa: std.mem.Allocator,
    state: *SharedState,
    view: *const View,
};

/// The slice of `function.State` this module needs. Declared here rather than
/// imported to keep `register.zig` free of a back-dependency.
pub const SharedState = struct {
    /// Live table specs, published by the driver under the catalog lock before
    /// the statement runs. Points into the per-query arena; empty between
    /// statements, which correctly yields zero rows.
    info_schema: []const *spec.TableSpec = &.{},
    /// Live dataset specs, published alongside `info_schema`. Only SCHEMATA
    /// reads this — TABLES/COLUMNS/TABLE_OPTIONS have no rows for a dataset
    /// that holds no tables, so they need no dataset-level source at all.
    datasets: []const *spec.DatasetSpec = &.{},
};

const Vtab = extern struct {
    base: c.sqlite3_vtab,
    ctx: *ModuleCtx,
};

const Cursor = extern struct {
    base: c.sqlite3_vtab_cursor,
    state: *CursorState,
};

const CursorState = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Buffer each column value is encoded in, reused for every row of the
    /// scan. The arena beside it lives for the whole cursor, so encoding there
    /// retained one copy of every cell until the scan ended.
    scratch: encoder.Scratch,
    ctx: *ModuleCtx,
    rows: []const Row = &.{},
    row: usize = 0,
};

var module: c.sqlite3_module = blk: {
    var m = std.mem.zeroes(c.sqlite3_module);
    m.iVersion = 0;
    m.xConnect = xConnect;
    m.xDisconnect = xDisconnect;
    m.xBestIndex = xBestIndex;
    m.xOpen = xOpen;
    m.xClose = xClose;
    m.xFilter = xFilter;
    m.xNext = xNext;
    m.xEof = xEof;
    m.xColumn = xColumn;
    m.xRowid = xRowid;
    break :blk m;
};

/// Registers one eponymous-only module per view. `gpa` and `state` must outlive
/// the connection.
pub fn register(db: *sqlite.Db, gpa: std.mem.Allocator, state: *SharedState) !void {
    for (&views) |*v| {
        const ctx = try gpa.create(ModuleCtx);
        ctx.* = .{ .gpa = gpa, .state = state, .view = v };
        const decl = try declaredSchema(gpa, v);
        defer gpa.free(decl);
        // No errdefer on `ctx`: when create_module_v2 fails it has already
        // invoked the destructor, so freeing here would be a double free.
        // (unnest_vtab.register has exactly that bug; do not copy it.)
        const rc = c.sqlite3_create_module_v2(
            db.handle,
            v.module.ptr,
            &module,
            ctx,
            destroyModuleCtx,
        );
        if (rc != c.SQLITE_OK) return error.SQLite;
    }
}

/// `CREATE TABLE x(col, col, ..., schema HIDDEN)`. The trailing hidden column
/// is how the dataset arrives; see the file header.
fn declaredSchema(gpa: std.mem.Allocator, v: *const View) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "CREATE TABLE x(");
    for (v.columns) |col| {
        try buf.print(gpa, "`{s}`,", .{col});
    }
    try buf.appendSlice(gpa, "`schema` HIDDEN)");
    return buf.toOwnedSliceSentinel(gpa, 0);
}

fn destroyModuleCtx(p: ?*anyopaque) callconv(.c) void {
    const ctx: *ModuleCtx = @ptrCast(@alignCast(p.?));
    ctx.gpa.destroy(ctx);
}

fn xConnect(
    db: ?*c.sqlite3,
    aux: ?*anyopaque,
    argc: c_int,
    argv: [*c]const [*c]const u8,
    vtab_out: [*c][*c]c.sqlite3_vtab,
    err: [*c][*c]u8,
) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    _ = err;
    const ctx: *ModuleCtx = @ptrCast(@alignCast(aux.?));
    const decl = declaredSchema(ctx.gpa, ctx.view) catch return c.SQLITE_NOMEM;
    defer ctx.gpa.free(decl);
    if (c.sqlite3_declare_vtab(db, decl.ptr) != c.SQLITE_OK) return c.SQLITE_ERROR;
    const v = ctx.gpa.create(Vtab) catch return c.SQLITE_NOMEM;
    v.* = .{ .base = std.mem.zeroes(c.sqlite3_vtab), .ctx = ctx };
    vtab_out.* = @ptrCast(v);
    return c.SQLITE_OK;
}

fn xDisconnect(vtab_ptr: [*c]c.sqlite3_vtab) callconv(.c) c_int {
    const v: *Vtab = @ptrCast(@alignCast(vtab_ptr));
    v.ctx.gpa.destroy(v);
    return c.SQLITE_OK;
}

/// Which filters `xFilter` was handed, and in which `argv` slot.
///
/// A bitmask rather than fixed positions because argv is packed in assignment
/// order: with only a table constraint the table lands in argv[0], with both a
/// prefix and a table it lands in argv[1].
const has_prefix: c_int = 1;
const has_schema: c_int = 2;
const has_table: c_int = 4;

/// Offers three EQ pushdowns: the hidden `schema` column (the scanned dataset,
/// always supplied by the transformer) plus the user's own `table_schema` and
/// `table_name` terms, which SQLite hands us when the query has them.
///
/// Unlike unnest, an absent constraint is legal — `SELECT * FROM
/// ds.INFORMATION_SCHEMA.TABLES` with no WHERE is a real query — so the
/// unconstrained plan is offered at a high cost rather than rejected.
///
/// `omit` is set only for the hidden column, whose value SQLite cannot check
/// for itself (xColumn returns NULL for it). The visible ones are left for
/// SQLite to re-check: our pruning is an optimisation, and correctness should
/// not depend on our comparison agreeing with SQLite's byte-for-byte.
fn xBestIndex(vtab: [*c]c.sqlite3_vtab, info: [*c]c.sqlite3_index_info) callconv(.c) c_int {
    const v: *Vtab = @ptrCast(@alignCast(vtab));
    const view = v.ctx.view;
    const schema_col: c_int = @intCast(view.columns.len);
    const dataset_col: c_int = @intCast(View.dataset_col);
    const name_col: c_int = if (view.name_col) |nc| @intCast(nc) else -1;

    info.*.estimatedCost = 1e6;
    info.*.estimatedRows = 1000;
    info.*.idxNum = 0;

    const n: usize = @intCast(info.*.nConstraint);
    const cons = info.*.aConstraint[0..n];
    const usage = info.*.aConstraintUsage[0..n];
    var argv_index: c_int = 0;
    var idx: c_int = 0;

    // Assign slots in a FIXED order — prefix, schema, table — rather than in
    // the order SQLite happens to list the constraints. argv is packed by
    // argvIndex, and SQLite does not list them in column order (it offers
    // `table_name` before the hidden column for a `WHERE table_name = ...`
    // query), so iterating the constraint array directly would hand xFilter
    // the values transposed.
    const wanted = [_]struct { bit: c_int, col: c_int }{
        .{ .bit = has_prefix, .col = schema_col },
        .{ .bit = has_schema, .col = dataset_col },
        .{ .bit = has_table, .col = name_col },
    };
    for (wanted) |w| {
        if (w.col < 0) continue;
        for (cons, usage) |con, *use| {
            if (con.usable == 0 or con.op != c.SQLITE_INDEX_CONSTRAINT_EQ) continue;
            if (con.iColumn != w.col) continue;
            argv_index += 1;
            use.argvIndex = argv_index;
            if (w.bit == has_prefix) use.omit = 1;
            idx |= w.bit;
            break; // one slot per column; a repeat adds nothing
        }
    }

    info.*.idxNum = idx;
    if (idx != 0) {
        info.*.estimatedCost = if (idx & has_table != 0) 1.0 else 10.0;
        info.*.estimatedRows = if (idx & has_table != 0) 8 else 100;
    }
    return c.SQLITE_OK;
}

fn xOpen(vtab_ptr: [*c]c.sqlite3_vtab, cur_out: [*c][*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const v: *Vtab = @ptrCast(@alignCast(vtab_ptr));
    const gpa = v.ctx.gpa;
    const state = gpa.create(CursorState) catch return c.SQLITE_NOMEM;
    state.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .scratch = encoder.Scratch.init(gpa),
        .ctx = v.ctx,
    };
    const cur = gpa.create(Cursor) catch {
        state.scratch.deinit();
        state.arena.deinit();
        gpa.destroy(state);
        return c.SQLITE_NOMEM;
    };
    cur.* = .{ .base = std.mem.zeroes(c.sqlite3_vtab_cursor), .state = state };
    cur_out.* = @ptrCast(cur);
    return c.SQLITE_OK;
}

fn xClose(cur_ptr: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    const gpa = cur.state.gpa;
    cur.state.scratch.deinit();
    cur.state.arena.deinit();
    gpa.destroy(cur.state);
    gpa.destroy(cur);
    return c.SQLITE_OK;
}

/// Materialises the whole result once, so `xColumn` allocates nothing per row.
fn xFilter(
    cur_ptr: [*c]c.sqlite3_vtab_cursor,
    idx_num: c_int,
    idx_str: [*c]const u8,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) c_int {
    _ = idx_str;
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    const st = cur.state;
    _ = st.arena.reset(.retain_capacity);
    st.rows = &.{};
    st.row = 0;
    const alloc = st.arena.allocator();

    // argv is packed in the order xBestIndex assigned, so walk the bits in the
    // same order rather than assuming fixed positions.
    var filter: Filter = .{};
    var next: usize = 0;
    const take = struct {
        fn f(
            a: std.mem.Allocator,
            args: [*c]?*c.sqlite3_value,
            n: usize,
            count: c_int,
        ) ?[]const u8 {
            if (n >= @as(usize, @intCast(count))) return null;
            return argText(a, args[n]);
        }
    }.f;

    if (idx_num & has_prefix != 0) {
        filter.prefix = take(alloc, argv, next, argc) orelse return c.SQLITE_ERROR;
        next += 1;
    }
    if (idx_num & has_schema != 0) {
        filter.schema = take(alloc, argv, next, argc);
        next += 1;
    }
    if (idx_num & has_table != 0) {
        filter.table = take(alloc, argv, next, argc);
        next += 1;
    }

    st.rows = st.ctx.view.build(alloc, st.ctx.state.info_schema, st.ctx.state.datasets, filter) catch
        return c.SQLITE_NOMEM;
    return c.SQLITE_OK;
}

/// A constraint value as text. The transformer emits the dataset as a plain SQL
/// literal, but a user's `WHERE table_name = 'x'` is compared against encoded
/// column values, so that arrives as an encoded BLOB — accept both. A NULL
/// constraint matches nothing, which `null` here expresses by leaving the
/// filter unset and letting SQLite's own re-check discard the rows.
fn argText(alloc: std.mem.Allocator, v: ?*c.sqlite3_value) ?[]const u8 {
    return switch (sqlite.valueType(v)) {
        .text => sqlite.valueText(v),
        .blob => blk: {
            const decoded = encoder.DecodeValueBorrowing(
                alloc,
                .{ .blob = sqlite.valueBlob(v) },
            ) catch break :blk null;
            break :blk decoded.toString(alloc) catch null;
        },
        else => null,
    };
}

fn xNext(cur_ptr: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    cur.state.row += 1;
    return c.SQLITE_OK;
}

fn xEof(cur_ptr: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    return @intFromBool(cur.state.row >= cur.state.rows.len);
}

fn xRowid(cur_ptr: [*c]c.sqlite3_vtab_cursor, rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    rowid.* = @intCast(cur.state.row);
    return c.SQLITE_OK;
}

/// Encoded, never `resultText`: `driver.Rows.next` treats a TEXT column as
/// `error.CorruptData` because no engine value is TEXT.
fn xColumn(
    cur_ptr: [*c]c.sqlite3_vtab_cursor,
    ctx: ?*c.sqlite3_context,
    col: c_int,
) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    const st = cur.state;
    if (st.row >= st.rows.len) return c.SQLITE_OK;
    const idx: usize = @intCast(col);
    const row = st.rows[st.row];
    // The hidden `schema` column sits past the declared ones and is never read
    // (xBestIndex omits it).
    if (idx >= row.len) {
        sqlite.resultNull(ctx);
        return c.SQLITE_OK;
    }
    const v: Value = switch (row[idx]) {
        .null => Value.null,
        .string => |s| Value{ .string = s },
        .int => |i| Value{ .int = i },
    };
    encoder.encodeTo(sqlite.ResultSink{ .ctx = ctx }, &st.scratch, v) catch
        return c.SQLITE_ERROR;
    return c.SQLITE_OK;
}

// ---- tests ----
//
// The row builders are pure, so they are tested without SQLite in the loop.
// End-to-end coverage (which is what catches the encoding trap above) lives in
// src/driver.zig.

const testing = std.testing;

fn testSpec(
    alloc: std.mem.Allocator,
    path: []const []const u8,
    cols: []const []const u8,
    is_view: bool,
) !*spec.TableSpec {
    const columns = try alloc.alloc(*spec.ColumnSpec, cols.len);
    for (cols, 0..) |name, i| {
        const col = try alloc.create(spec.ColumnSpec);
        col.* = .{ .name = name, .type = try spec.newSimpleType(alloc, .TYPE_INT64) };
        columns[i] = col;
    }
    const s = try alloc.create(spec.TableSpec);
    s.* = .{ .name_path = path, .columns = columns, .is_view = is_view };
    return s;
}

test "TABLES reports one row per table with its type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const specs = [_]*spec.TableSpec{
        try testSpec(a, &.{ "ds", "t1" }, &.{"x"}, false),
        try testSpec(a, &.{ "ds", "v1" }, &.{"y"}, true),
        try testSpec(a, &.{ "other", "t2" }, &.{"z"}, false),
    };

    const rows = try buildTables(a, &specs, &.{}, .{ .prefix = "ds" });
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("t1", rows[0][2].string);
    try testing.expectEqualStrings("BASE TABLE", rows[0][3].string);
    try testing.expectEqualStrings("YES", rows[0][5].string);
    try testing.expectEqualStrings("v1", rows[1][2].string);
    try testing.expectEqualStrings("VIEW", rows[1][3].string);
    try testing.expectEqualStrings("NO", rows[1][5].string);

    // No dataset constraint scans everything.
    try testing.expectEqual(@as(usize, 3), (try buildTables(a, &specs, &.{}, .{ .prefix = "" })).len);
}

test "COLUMNS numbers columns from one, in declaration order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const specs = [_]*spec.TableSpec{
        try testSpec(a, &.{ "ds", "t1" }, &.{ "col_a", "col_b", "col_c" }, false),
    };
    const rows = try buildColumns(a, &specs, &.{}, .{ .prefix = "ds" });
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("col_a", rows[0][3].string);
    try testing.expectEqual(@as(i64, 1), rows[0][4].int);
    try testing.expectEqualStrings("col_c", rows[2][3].string);
    try testing.expectEqual(@as(i64, 3), rows[2][4].int);
    try testing.expectEqualStrings("INT64", rows[0][6].string);
    try testing.expectEqualStrings("YES", rows[0][5].string); // nullable
}

test "SCHEMATA lists each dataset once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const specs = [_]*spec.TableSpec{
        try testSpec(a, &.{ "ds", "t1" }, &.{"x"}, false),
        try testSpec(a, &.{ "ds", "t2" }, &.{"x"}, false),
        try testSpec(a, &.{ "other", "t3" }, &.{"x"}, false),
    };
    const all = try buildSchemata(a, &specs, &.{}, .{ .prefix = "" });
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("ds", all[0][1].string);
    try testing.expectEqualStrings("other", all[1][1].string);

    const one = try buildSchemata(a, &specs, &.{}, .{ .prefix = "ds" });
    try testing.expectEqual(@as(usize, 1), one.len);
}

test "temps and the synthetic views are never listed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const temp = try testSpec(a, &.{ "ds", "scratch" }, &.{"x"}, false);
    temp.is_temp = true;
    const specs = [_]*spec.TableSpec{
        try testSpec(a, &.{ "ds", "real" }, &.{"x"}, false),
        temp,
        // Our own injected view must not report itself.
        try testSpec(a, &.{ "ds", "INFORMATION_SCHEMA", "TABLES" }, &.{"table_name"}, false),
    };
    const rows = try buildTables(a, &specs, &.{}, .{ .prefix = "ds" });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("real", rows[0][2].string);
}

test "a three-part path reports its project as the catalog" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const specs = [_]*spec.TableSpec{
        try testSpec(a, &.{ "proj", "ds", "t1" }, &.{"x"}, false),
    };
    // The filter is the `_`-joined prefix, so a 3-part path wants "proj_ds".
    const rows = try buildTables(a, &specs, &.{}, .{ .prefix = "proj_ds" });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("proj", rows[0][0].string);
    try testing.expectEqualStrings("ds", rows[0][1].string);
    // The bare dataset name is NOT the prefix here and must not match.
    try testing.expectEqual(@as(usize, 0), (try buildTables(a, &specs, &.{}, .{ .prefix = "ds" })).len);

    // A two-part path has no project to report.
    const short = [_]*spec.TableSpec{try testSpec(a, &.{ "ds", "t1" }, &.{"x"}, false)};
    const short_rows = try buildTables(a, &short, &.{}, .{ .prefix = "ds" });
    try testing.expectEqualStrings("", short_rows[0][0].string);
}

test "a dataset name containing an underscore is not mis-split" {
    // The reason the filter is a joined prefix rather than a dataset name:
    // `demo_ds_INFORMATION_SCHEMA_TABLES` cannot be decomposed back into
    // (dataset `demo_ds`) versus (project `demo`, dataset `ds`).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const specs = [_]*spec.TableSpec{
        try testSpec(a, &.{ "demo_ds", "tbl_a" }, &.{"x"}, false),
    };
    try testing.expectEqual(@as(usize, 1), (try buildTables(a, &specs, &.{}, .{ .prefix = "demo_ds" })).len);
    try testing.expectEqual(@as(usize, 0), (try buildTables(a, &specs, &.{}, .{ .prefix = "ds" })).len);
}

test "pushed-down table and schema filters agree with filtering afterwards" {
    // The whole point of the pushdown is to prune early. It is only valid if it
    // selects exactly what SQLite's own re-check would have kept, so assert
    // that rather than just asserting a smaller number.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const specs = [_]*spec.TableSpec{
        try testSpec(a, &.{ "ds", "t1" }, &.{ "x", "y" }, false),
        try testSpec(a, &.{ "ds", "t2" }, &.{"z"}, false),
        try testSpec(a, &.{ "other", "t1" }, &.{"w"}, false),
    };

    // COLUMNS across the dataset is 3 rows; narrowed to t1 it is the 2 that
    // belong to t1, and they are the same rows.
    const all = try buildColumns(a, &specs, &.{}, .{ .prefix = "ds" });
    try testing.expectEqual(@as(usize, 3), all.len);

    const narrowed = try buildColumns(a, &specs, &.{}, .{ .prefix = "ds", .table = "t1" });
    try testing.expectEqual(@as(usize, 2), narrowed.len);
    for (narrowed) |row| try testing.expectEqualStrings("t1", row[2].string);
    try testing.expectEqualStrings("x", narrowed[0][3].string);
    try testing.expectEqualStrings("y", narrowed[1][3].string);

    // A schema filter is redundant with a matching prefix and contradictory
    // with a different one.
    try testing.expectEqual(
        @as(usize, 3),
        (try buildColumns(a, &specs, &.{}, .{ .prefix = "ds", .schema = "ds" })).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try buildColumns(a, &specs, &.{}, .{ .prefix = "ds", .schema = "other" })).len,
    );

    // A table name that exists in a different dataset must not leak in.
    try testing.expectEqual(
        @as(usize, 2),
        (try buildTables(a, &specs, &.{}, .{ .table = "t1" })).len, // ds.t1 and other.t1
    );
    try testing.expectEqual(
        @as(usize, 1),
        (try buildTables(a, &specs, &.{}, .{ .prefix = "ds", .table = "t1" })).len,
    );

    // An unmatched table prunes to nothing rather than falling back to all.
    try testing.expectEqual(
        @as(usize, 0),
        (try buildTables(a, &specs, &.{}, .{ .prefix = "ds", .table = "nope" })).len,
    );
}

test "TABLE_OPTIONS reports one row per declared option and none otherwise" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const with_opts = try testSpec(a, &.{ "ds", "t1" }, &.{"x"}, false);
    const desc = try a.create(spec.OptionSpec);
    desc.* = .{ .name = "description", .type_name = "STRING", .value = "\"demo table\"" };
    const friendly = try a.create(spec.OptionSpec);
    friendly.* = .{ .name = "friendly_name", .type_name = "STRING", .value = "\"T One\"" };
    with_opts.options = try a.dupe(*spec.OptionSpec, &.{ desc, friendly });

    const specs = [_]*spec.TableSpec{
        with_opts,
        // No OPTIONS at all: contributes nothing, as BigQuery does. It reports
        // options that were set, not every option with a default.
        try testSpec(a, &.{ "ds", "t2" }, &.{"y"}, false),
    };

    const rows = try buildTableOptions(a, &specs, &.{}, .{ .prefix = "ds" });
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("t1", rows[0][2].string);
    try testing.expectEqualStrings("description", rows[0][3].string);
    try testing.expectEqualStrings("STRING", rows[0][4].string);
    try testing.expectEqualStrings("\"demo table\"", rows[0][5].string);
    try testing.expectEqualStrings("friendly_name", rows[1][3].string);

    // The table pushdown applies here too.
    try testing.expectEqual(
        @as(usize, 0),
        (try buildTableOptions(a, &specs, &.{}, .{ .prefix = "ds", .table = "t2" })).len,
    );
    try testing.expectEqual(
        @as(usize, 2),
        (try buildTableOptions(a, &specs, &.{}, .{ .prefix = "ds", .table = "t1" })).len,
    );
}

test "canonical names map back to their view" {
    try testing.expectEqualStrings(
        "TABLES",
        viewForCanonicalName("proj_ds_INFORMATION_SCHEMA_TABLES").?.view,
    );
    try testing.expectEqualStrings(
        "COLUMNS",
        viewForCanonicalName("ds_INFORMATION_SCHEMA_COLUMNS").?.view,
    );
    try testing.expect(viewForCanonicalName("ds_ordinary_table") == null);
    // A user table merely *named* like one must not be hijacked.
    try testing.expect(viewForCanonicalName("ds_TABLES") == null);
}

test "datasetOfPath finds the segment before INFORMATION_SCHEMA" {
    try testing.expectEqualStrings(
        "ds",
        datasetOfPath(&.{ "proj", "ds", "INFORMATION_SCHEMA", "TABLES" }).?,
    );
    try testing.expectEqualStrings(
        "ds",
        datasetOfPath(&.{ "ds", "INFORMATION_SCHEMA", "TABLES" }).?,
    );
    try testing.expect(datasetOfPath(&.{ "ds", "t1" }) == null);
}
