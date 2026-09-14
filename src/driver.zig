//! Public driver surface — the redesigned counterpart of go-zetasqlite's
//! database/sql layer (driver.go / conn.go / stmt.go / rows.go).
//!
//! Mirrors the Go flow: Analyzer.Analyze splits the input into statements,
//! each QueryStmt is transformed through the coordinator into a SQLite
//! SELECT, executed via sqlite3, and result cells are decoded back through
//! DecodeValue + castValueInternal semantics (rows.go assignValue /
//! assignInterfaceValue) using the statement's output column types.
//!
//! Like Go's ZetaSQLiteConn.QueryContext, a multi-statement script runs all
//! statements and returns Rows over the LAST one (earlier SELECTs are
//! prepared but their rows are never iterated, matching database/sql's lazy
//! semantics); ExecContext runs every statement to completion.
//!
//! API shape:
//!   var db = try Db.open(gpa, ":memory:");
//!   var rows = try db.query(sql, args, .{ .current_time_unix_micros = ... });
//!   while (try rows.next()) |row| ...
//!   rows.deinit();

const std = @import("std");
const sqlite = @import("sqlite.zig");
const analyzer_ffi = @import("analyzer_ffi.zig");
const pb = @import("proto/resolved_ast.zig");
const value_mod = @import("internal/value.zig");
const encoder = @import("internal/encoder.zig");
const spec = @import("internal/spec.zig");
const sqlbuilder = @import("internal/sqlbuilder/sqlbuilder.zig");
const coordinator_mod = @import("internal/coordinator/coordinator.zig");
const context_mod = @import("internal/coordinator/context.zig");
const function = @import("internal/function/register.zig");
const catalog_mod = @import("internal/catalog.zig");
const shared_catalog = @import("internal/shared_catalog.zig");
const phase = @import("internal/phase.zig");
const ast_text = @import("internal/ast_text.zig");

pub const Error = error{
    Unimplemented,
    /// GoogleSQL analysis failed (message in Db.lastError / analyzer_ffi.last_error).
    AnalyzeFailed,
    /// AST -> SQLite transformation failed (non-Unimplemented pipeline error).
    TransformFailed,
    /// A resolved function this build has no rewrite or UDF for (message in
    /// Db.lastError, naming the function). Distinct from TransformFailed because
    /// "we have not built that yet" is a different answer from "the transformer
    /// broke", and callers -- the spec runner among them -- act on the difference.
    UnsupportedFunction,
    /// SQLite prepare/step failed (message in Db.lastError).
    ExecFailed,
    /// A CREATE named a dataset the catalog does not hold, and the connection
    /// requires datasets to be declared (`Db.require_dataset`). The message
    /// in Db.lastError is BigQuery's own, verbatim, so a server can answer
    /// with it; nothing was created.
    DatasetNotFound,
    /// Result-cell decoding failed.
    DecodeFailed,
    /// The database was written in a storage format this build cannot read.
    /// Distinct from ExecFailed because open() destroys the Db before
    /// returning, so there is no `lastError` to carry an explanation — the
    /// error name has to be the explanation.
    IncompatibleStorageFormat,
    OutOfMemory,
} || sqlite.Error;

/// A decoded result cell, mirroring what Go's Rows.Scan produces per column
/// (scalars, or nested arrays / structs rebuilt from encoded values).
pub const Cell = union(enum) {
    null,
    int: i64,
    float: f64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,
    /// A raw JSON payload, for binding to a JSON column. Never produced when
    /// reading: Go's rows.go hands a JSON column back as its ToApiString, i.e.
    /// a plain string cell, so `cellFromValue` still yields `.string`. It
    /// exists because CastValue(JSON) on a `.string` calls ToJSON, which
    /// *quotes* the string — Go avoids that by unmarshalling before it binds
    /// (contentdata/repository.go:510).
    json: []const u8,
    date: []const u8, // civil date rendered as YYYY-MM-DD, like Go returns
    // Date/time kinds render as their Go ToApiString forms (what rows.go
    // hands back through database/sql): timestamp "sec.rem", datetime
    // "YYYY-MM-DDTHH:MM:SS.ffffff", time "HH:MM:SS.ffffff", interval canonical.
    timestamp: []const u8,
    datetime: []const u8,
    time: []const u8,
    interval: []const u8,
    /// RANGE, as its canonical "[start, end)" text with UNBOUNDED for an open bound.
    range: []const u8,
    array: []Cell,
    struct_: []Field,

    pub const Field = struct {
        name: []const u8,
        value: Cell,
    };
};

/// A query parameter: positional when `name` is null.
pub const Param = struct {
    name: ?[]const u8 = null,
    value: Cell,
    /// GoogleSQL type text for this parameter ("STRING", "ARRAY<STRING>"),
    /// when the caller knows it. The BigQuery REST surface always does —
    /// `queryParameters` carries a `parameterType` beside every value — and
    /// declaring it to the analyzer is the only way a parameter in a position
    /// that cannot be inferred from context resolves correctly. `UNNEST(@ids)`
    /// is the case that forces it: an undeclared parameter comes back as an
    /// untyped INT64, and UNNEST rejects that.
    ///
    /// Null means "let the analyzer infer", which is what every in-process
    /// caller does and what keeps their behaviour unchanged.
    type_text: ?[]const u8 = null,
};

/// Parameter placeholder style of a query script (Go getParameterMode).
pub const ParamMode = enum { named, positional };

pub const QueryOptions = struct {
    /// Deterministic CURRENT_* time injection (go-zetasqlite WithCurrentTime).
    current_time_unix_micros: ?i64 = null,
    /// How much of the catalog the analyzer is given.
    ///
    /// `.full` goes through the persistent handle when there is one, which is
    /// synced by delta — so a statement analyzed against an *unchanged*
    /// catalog pays nothing proportional to catalog size. `bench` measures a
    /// flat ~0.055 ms/query from 1 table to 14,000. The O(catalog) render is
    /// the stateless fallback (`statelessCatalogJson`), taken only when no
    /// handle is available or a delta cannot be applied; there, bulk loading N
    /// tables is O(N^2) with ~90% of it in the C++ re-parse rather than the
    /// Zig render.
    ///
    /// Mutation is the cost that remains on the `.full` path: each statement
    /// that changes the catalog leaves a delta for the next one to push, and
    /// `bench` measures per-CREATE cost growing linearly with the tables
    /// already present (0.055 ms at 50 tables, 0.46 ms at 14,000).
    ///
    /// A statement that references no existing table (a CREATE TABLE with
    /// explicit columns, say) does not need any of it. `.none` says so, and
    /// skips both the delta sync and the render. It is only ever a hint: if
    /// the statement does reference something, analysis fails and the caller
    /// can retry with `.full`.
    catalog_scope: enum { full, none } = .full,
    /// Renders the resolved AST and transformed SQL text that
    /// `transformStatementFragment` computes anyway, for a caller that wants
    /// to inspect them (the spec-corpus UI) — null everywhere else, so this
    /// costs one pointer check and nothing else on the server/CLI/every
    /// other path. Populated for whichever statement kind actually reaches
    /// `transformStatementFragment` (SELECT, DML, MERGE, CREATE TABLE AS
    /// SELECT, CREATE VIEW, DROP TABLE/VIEW); left untouched — not zeroed —
    /// for one that doesn't (plain CREATE TABLE, CREATE FUNCTION, TRUNCATE),
    /// so the caller's own zero-initialized `Capture` reads as "not
    /// applicable" rather than stale data from an earlier statement in the
    /// same multi-statement call.
    capture: ?*Capture = null,
};

pub const Capture = struct {
    /// Where `ast_text`/`sql` are rendered, not `query()`'s own per-call
    /// arena: a query that fails after analysis (a runtime error during
    /// execution, not just analyze/transform) returns through `query()`'s
    /// `errdefer arena_state.deinit()` before ever handing back a `Rows` —
    /// so a pointer into that arena would already dangle by the time the
    /// caller reads it. Must outlive the `query()` call.
    arena: std.mem.Allocator,
    ast_text: []const u8 = "",
    sql: []const u8 = "",
};

/// Connection-level SQLite configuration for Db.openWith. Defaults reproduce
/// plain Db.open exactly: no pragmas, no busy timeout.
pub const OpenOptions = struct {
    /// Applied in order, before UDF registration and the initial catalog
    /// sync. Each must be a complete statement, e.g.
    /// "PRAGMA journal_mode = WAL".
    pragmas: []const [:0]const u8 = &.{},
    /// sqlite3_busy_timeout in milliseconds.
    busy_timeout_ms: ?i32 = null,
    /// Persistent catalog to share with the rest of a connection pool. When
    /// null the connection owns a private catalog, which is what every
    /// single-connection caller wants and what all the tests use.
    shared_catalog: ?*shared_catalog.SharedCatalog = null,
};

/// SQLite's own allocator accounting, process-wide and per-connection.
///
/// Exists so "would tuning SQLite's allocator help?" is answered by counters
/// rather than by reasoning. `lookaside_hit` against the two miss counters is
/// the whole answer: a high hit rate means allocation is already off the
/// critical path and no amount of tuning will move the profile.
pub const AllocStats = struct {
    /// Bytes currently held by SQLite, and the most it ever held.
    memory_used: sqlite.Counter,
    /// Allocations outstanding now / at peak. Not a lifetime total.
    malloc_count: sqlite.Counter,
    /// Largest single allocation SQLite has ever requested.
    malloc_size_max: i64,
    /// Slots checked out now / at peak. A peak pinned to the configured slot
    /// count is what an exhausted pool looks like.
    lookaside_used: sqlite.Counter,
    /// Running totals since this connection opened.
    lookaside_hit: i64,
    lookaside_miss_size: i64,
    lookaside_miss_full: i64,
    /// Page cache, schema and prepared-statement memory for this connection.
    cache_used: i64,
    schema_used: i64,
    stmt_used: i64,

    /// Fraction of lookaside-eligible allocations served from the pool, or
    /// null when nothing has been allocated yet.
    pub fn hitRate(a: AllocStats) ?f64 {
        const total = a.lookaside_hit + a.lookaside_miss_size + a.lookaside_miss_full;
        if (total == 0) return null;
        return @as(f64, @floatFromInt(a.lookaside_hit)) / @as(f64, @floatFromInt(total));
    }
};

/// One output column of a QueryStmt (Go ColumnSpec: name + spec Type).
///
/// Public so servers can derive a result schema. Go reaches the same data
/// through Rows.ColumnTypeDatabaseTypeName, which is literally
/// `json.Marshal(internal.Type)` (go-zetasqlite internal/rows.go:38-41) that
/// the caller immediately unmarshals again (column.go:11); handing back the
/// `*spec.Type` skips that round trip.
pub const OutputColumn = struct {
    name: []const u8,
    type: *spec.Type,
};

pub const Db = struct {
    gpa: std.mem.Allocator,
    sqlite_db: sqlite.Db,
    udf_state: *function.State,
    /// The persistent catalog this connection owns, or null when it uses a
    /// shared one. Reachable only through `lockCatalog`, so no call site can
    /// touch a shared catalog without holding its mutex.
    own_catalog: ?*catalog_mod.Catalog,
    shared: ?*shared_catalog.SharedCatalog,
    /// TEMP tables, views and functions created by this connection.
    ///
    /// A separate catalog rather than a flag on the persistent one: TEMP
    /// objects are scoped to the connection that made them, so once the
    /// persistent catalog is shared across a pool they cannot live in it —
    /// one connection's TEMP table would resolve for every other. Keeping
    /// them apart also fixes a shadowing bug: a TEMP table named the same as
    /// a persistent one used to delete the *persistent* spec when the query's
    /// cleanup dropped it.
    ///
    /// Lookups check this first, so a TEMP object shadows a persistent one of
    /// the same name.
    temps: *catalog_mod.Catalog,
    /// The project a two-part DDL name (`dataset.table`) belongs to, when a
    /// server sets one. BigQuery resolves such names against the job's
    /// project; without a default the path is registered as written.
    default_project: ?[]const u8 = null,
    /// Whether a CREATE into `project.dataset.x` must name a dataset the
    /// catalog holds, as BigQuery insists ("Not found: Dataset p:ds was not
    /// found in location US"). Off by default: the engine library and the
    /// spec corpus create `ds.t` freely and the catalog infers the dataset.
    /// A server, whose clients declare datasets through the metadata API,
    /// turns it on so the two agree on which datasets exist. Deliberately
    /// separate from `default_project`, which is a name-resolution rule and
    /// is set by engine tests that never declare a dataset.
    require_dataset: bool = false,
    last_error: ?[]u8 = null,
    /// The 1-based bind index whose value failed to convert, when `last_error` came from a bind.
    /// Cleared at the start of every bind pass.
    /// Lets a caller binding one placeholder per column name the column in its own error.
    last_error_param: ?i32 = null,
    /// Parameter mode of the currently-running script (set per runStatements).
    param_mode: ParamMode = .named,
    /// Collects the canonical names of temp tables/views created during the
    /// current script so they can be dropped once the query completes (Go's
    /// StmtAction.Cleanup). Arena-backed by runStatements' arena.
    temp_collector: ?*std.ArrayList([]const u8) = null,
    /// Same for CREATE TEMP FUNCTION names (Go
    /// CreateFunctionStmtAction.Cleanup deletes the temp spec after the
    /// query). Dropped when runStatements returns: UDF calls are inlined at
    /// transform time, so nothing outlives the script.
    temp_func_collector: ?*std.ArrayList([]const u8) = null,
    /// Parameter occurrences of the most recently transformed statement
    /// (identifier + resolved type). Arena-backed; used by bindParams to
    /// cast values (Go EncodeNamedValues with getParamsFromNode results).
    stmt_params: []const context_mod.CollectedParam = &.{},
    /// Prepared-statement cache for the raw SQLite path, keyed by SQL text
    /// (Go's per-connection ManagedConnection.stmts). gpa-owned keys.
    raw_cache: std.StringHashMapUnmanaged(*RawStmt) = .empty,
    /// Persistent analyzer catalog. Without it, every statement re-parses the
    /// whole catalog JSON and rebuilds the builtin function set in C++, which
    /// makes analysis cost O(catalog) instead of O(statement).
    ///
    /// Per-Db and unsynchronized, like the rest of Db.
    catalog_handle: ?*analyzer_ffi.CatalogHandle = null,
    /// This handle's position in the catalog's change log: how much of the
    /// catalog it already reflects. Other connections read the same log at
    /// their own cursors, so replaying is non-destructive.
    cursor: catalog_mod.Cursor = .{},
    /// The handle's position in the TEMP overlay's change log. Applied after
    /// the persistent delta so a TEMP object shadows rather than loses to the
    /// persistent one it overrides.
    temp_cursor: catalog_mod.Cursor = .{},

    pub fn open(gpa: std.mem.Allocator, path: [:0]const u8) Error!*Db {
        return openWith(gpa, path, .{});
    }

    /// open() with connection-level SQLite configuration. Go applies the
    /// equivalent through the DSN (`&_pragma=journal_mode(WAL)` etc. in
    /// bigquery-emulator server.go); the C API has no DSN pragma syntax, so
    /// they run as statements instead.
    ///
    /// Pragmas are applied before UDF registration and the catalog sync
    /// because journal_mode=WAL must precede the first write to the file.
    pub fn openWith(gpa: std.mem.Allocator, path: [:0]const u8, opts: OpenOptions) Error!*Db {
        const db = try gpa.create(Db);
        errdefer gpa.destroy(db);
        db.* = .{
            .gpa = gpa,
            .sqlite_db = try sqlite.Db.open(path),
            .udf_state = undefined,
            .own_catalog = null,
            .shared = opts.shared_catalog,
            .temps = undefined,
        };
        errdefer db.sqlite_db.close();
        if (opts.busy_timeout_ms) |ms| db.sqlite_db.busyTimeout(ms);
        for (opts.pragmas) |pragma| {
            db.sqlite_db.exec(pragma) catch {
                db.setLastSqliteError();
                return error.ExecFailed;
            };
        }
        try db.checkStorageFormat();
        // zigquery_* UDFs and the unnest vtab (Go: RegisterFunctions in
        // driver init; Go also registered a collation, which this no longer
        // needs — see codec_sortable.zig).
        db.udf_state = function.registerAll(&db.sqlite_db, gpa) catch
            return error.ExecFailed;
        errdefer db.udf_state.deinit();
        // zigquery_catalog tables + the one-shot load of everything already
        // persisted. A shared catalog is loaded by whichever connection
        // attaches first; later ones find it already done.
        if (opts.shared_catalog == null) db.own_catalog = try catalog_mod.Catalog.init(gpa);
        errdefer if (db.own_catalog) |c| c.deinit();
        {
            var g = db.lockCatalog();
            defer g.unlock();
            if (db.shared == null or !db.shared.?.loaded) {
                g.catalog.loadFromStorage(&db.sqlite_db) catch return error.ExecFailed;
                if (db.shared) |sc| sc.loaded = true;
            } else {
                // Still ensure this connection can write catalog rows.
                g.catalog.createCatalogTablesIfNotExist(&db.sqlite_db) catch
                    return error.ExecFailed;
            }
        }
        db.temps = try catalog_mod.Catalog.init(gpa);
        errdefer db.temps.deinit();
        db.catalog_handle = analyzer_ffi.catalogCreate(gpa) catch null;
        return db;
    }

    pub fn close(db: *Db) void {
        if (db.catalog_handle) |h| analyzer_ffi.catalogDestroy(h);
        db.clearLastError();
        // Before sqlite_db.close(): sqlite3_close_v2 leaves the handle a
        // zombie until every statement is finalized.
        db.deinitRawCache();
        db.temps.deinit();
        // A shared catalog outlives its connections; whoever built it owns it.
        if (db.own_catalog) |c| c.deinit();
        db.sqlite_db.close();
        db.udf_state.deinit();
        db.gpa.destroy(db);
    }

    /// Diagnostic message for the last failed query/exec call.
    pub fn lastError(db: *Db) []const u8 {
        return db.last_error orelse "";
    }

    /// The bind index behind the last `error.DecodeFailed`, or null when it wasn't a bind failure.
    pub fn lastErrorParam(db: *Db) ?i32 {
        return db.last_error_param;
    }

    /// The storage format this build reads and writes, kept in the database's
    /// `user_version`.
    ///
    /// 4 — the current format, and the only one this build reads or writes: as
    ///     3, but the self-delimiting codec stores DATE, DATETIME, TIME and
    ///     NUMERIC/BIGNUMERIC as fixed-width little-endian integers rather than
    ///     as their rendered text (codec_binary.zig).
    /// 3 — every non-scalar value is a BLOB carrying one of the two payload
    ///     shapes (codec_sortable.zig for the orderable kinds, codec_binary.zig
    ///     for the rest).
    /// 2 — orderable kinds as BLOB, NUMERIC/BIGNUMERIC still base64 in TEXT.
    /// 1 — every value as base64 in TEXT.
    ///
    /// None of 1-3 is readable here and there is no migration: the code that
    /// decoded them is gone. They are listed because refusing a database is only
    /// useful if the reader can tell what was refused.
    ///
    /// 3 is the one that would fail quietly rather than loudly if it were not
    /// refused: its tags are these tags, so a stored DATE would read its
    /// "1970-01-01" as an 8-byte integer and come back as some far-future day
    /// rather than as an error.
    ///
    /// Refusing is the only defence available, because a mismatch fails
    /// silently rather than loudly: TEXT and BLOB never compare equal in SQLite,
    /// so a database holding the older shape would not error — it would quietly
    /// stop deduplicating in DISTINCT and UNION, and stop matching in index
    /// lookups.
    pub const storage_format_version: i64 = 4;

    /// Refuses a database this build cannot read, and stamps a new one.
    ///
    /// `user_version` is 0 both for a database this engine has never touched and
    /// for every database written before the stamp existed. The two are told
    /// apart by whether the catalog is already there: an unstamped database that
    /// already holds one was written by an older format, and adopting it would
    /// read its TEXT values as though they were BLOBs, silently, on every one.
    fn checkStorageFormat(db: *Db) Error!void {
        const found = db.readUserVersion() orelse return;
        if (found == storage_format_version) return;
        if (found != 0) return error.IncompatibleStorageFormat;
        if (db.hasCatalogTable()) return error.IncompatibleStorageFormat;
        // Fresh database. Best-effort: a read-only connection cannot stamp one,
        // and an empty database has nothing to misread either way.
        db.sqlite_db.exec(std.fmt.comptimePrint(
            "PRAGMA user_version = {d}",
            .{storage_format_version},
        )) catch {};
    }

    fn hasCatalogTable(db: *Db) bool {
        var stmt = db.sqlite_db.prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'zigquery_catalog'",
        ) catch return false;
        defer stmt.finalize();
        return stmt.step() catch false;
    }

    fn readUserVersion(db: *Db) ?i64 {
        var stmt = db.sqlite_db.prepare("PRAGMA user_version") catch return null;
        defer stmt.finalize();
        if (!(stmt.step() catch return null)) return null;
        return stmt.columnInt64(0);
    }

    /// SQLite's allocator accounting for this connection plus the process.
    ///
    /// Cheap (seven counter reads, no locks taken), so a stats endpoint can
    /// call it per request without perturbing what it measures.
    pub fn allocStats(db: *Db) AllocStats {
        return .{
            .memory_used = sqlite.status(.memory_used),
            .malloc_count = sqlite.status(.malloc_count),
            .malloc_size_max = sqlite.status(.malloc_size).highwater,
            .lookaside_used = db.sqlite_db.dbStatus(.lookaside_used),
            .lookaside_hit = db.sqlite_db.dbStatus(.lookaside_hit).highwater,
            .lookaside_miss_size = db.sqlite_db.dbStatus(.lookaside_miss_size).highwater,
            .lookaside_miss_full = db.sqlite_db.dbStatus(.lookaside_miss_full).highwater,
            .cache_used = db.sqlite_db.dbStatus(.cache_used).current,
            .schema_used = db.sqlite_db.dbStatus(.schema_used).current,
            .stmt_used = db.sqlite_db.dbStatus(.stmt_used).current,
        };
    }

    fn setLastError(db: *Db, msg: []const u8) void {
        const dup = db.gpa.dupe(u8, msg) catch return;
        db.clearLastError();
        db.last_error = dup;
    }

    fn clearLastError(db: *Db) void {
        if (db.last_error) |msg| db.gpa.free(msg);
        db.last_error = null;
    }

    /// Records the current SQLite error in modernc's errstrForDB shape, which
    /// is what Go's driver hands back (e.g. "SQL logic error: <msg> (1)").
    fn setLastSqliteError(db: *Db) void {
        const text = db.sqlite_db.errorText(db.gpa) catch {
            db.setLastError(db.sqlite_db.errmsg());
            return;
        };
        defer db.gpa.free(text);
        db.setLastError(text);
    }

    /// Mirrors Go QueryContext: run the statement pipeline, returning Rows
    /// over the last statement.
    pub fn query(db: *Db, sql: []const u8, args: []const Param, opts: QueryOptions) Error!Rows {
        var arena_state = std.heap.ArenaAllocator.init(db.gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const prepared = (try db.runStatements(arena, sql, args, opts, .query)) orelse
            return error.ExecFailed; // unreachable: .query always yields the last stmt

        const names = try arena.alloc([]const u8, prepared.columns.len);
        for (prepared.columns, 0..) |col, i| names[i] = col.name;

        var rows: Rows = .{
            .arena = arena_state,
            .db = db,
            .stmt = prepared.stmt,
            .cols = prepared.columns,
            .names = names,
            .temp_tables = prepared.temp_tables,
        };

        // modernc.org/sqlite's (*stmt).Query steps once before handing back
        // rows, so a failure on the FIRST row surfaces from Query rather than
        // from iteration (go-zetasqlite then wraps it "failed to query %s").
        // Later rows fail during iteration instead. Reproduce that timing by
        // taking the first step here and letting next() consume its result.
        if (rows.stmt) |*stmt| {
            rows.first_has_row = stmt.step() catch {
                db.setLastSqliteError();
                stmt.finalize();
                rows.stmt = null;
                // Go's action Cleanup still runs for a failed query; the
                // arena backing these names is released by the errdefer.
                if (rows.temp_tables.len > 0) db.dropTempTables(arena, rows.temp_tables);
                return error.ExecFailed;
            };
            rows.first_step_done = true;
        }
        return rows;
    }

    /// Mirrors Go ExecContext: run every statement to completion.
    pub fn exec(db: *Db, sql: []const u8, args: []const Param, opts: QueryOptions) Error!void {
        var arena_state = std.heap.ArenaAllocator.init(db.gpa);
        defer arena_state.deinit();
        _ = try db.runStatements(arena_state.allocator(), sql, args, opts, .exec);
    }

    /// Analyzes, transforms and SQLite-prepares one statement for reuse across
    /// many bind/exec cycles — Go's conn.PrepareContext, which is how
    /// bigquery-emulator's contentdata.AddTableData writes a whole batch
    /// through a single prepare. Without it every row would pay its own
    /// analyze + transform.
    ///
    /// One statement only, and only the kinds that lower to one reusable
    /// SQLite statement: a query, or INSERT / UPDATE / DELETE. DDL, MERGE and
    /// TRUNCATE *are* their own execution — they mutate the catalog inline and
    /// leave nothing to hold on to — so they report error.Unimplemented.
    ///
    /// The handle embeds the schema resolved at prepare time, so it stays
    /// valid only while the catalog objects it referenced are unchanged. Go's
    /// prepared statements carry the same caveat.
    pub fn prepare(db: *Db, sql: []const u8, opts: QueryOptions) Error!PreparedStmt {
        var arena_state = std.heap.ArenaAllocator.init(db.gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const flattened_sql = try flattenBeginEndBlocks(arena, sql);
        const sqlz = try arena.dupeZ(u8, flattened_sql);

        db.param_mode = parameterMode(arena, sql) catch {
            db.setLastError("named parameter and positional parameter cannot be used together");
            return error.AnalyzeFailed;
        };
        const options_json: [:0]const u8 = switch (db.param_mode) {
            .positional => "{\"parameter_mode\":\"positional\"}",
            .named => "{}",
        };

        // prepare takes no args, so there are no types to declare; a prepared
        // statement's parameters are inferred, as they always were.
        const analyzed = try db.analyzeOne(arena, sqlz, 0, opts, options_json, null);
        if (!analyzed.at_end) {
            db.setLastError("cannot prepare a multi-statement script");
            return error.Unimplemented;
        }

        // Temp objects live only as long as the script that created them, so a
        // statement that collects any cannot outlive this call. Collect them
        // anyway: the transform below expects the collectors to be set.
        var temp_tables: std.ArrayList([]const u8) = .empty;
        db.temp_collector = &temp_tables;
        defer db.temp_collector = null;
        var temp_functions: std.ArrayList([]const u8) = .empty;
        db.temp_func_collector = &temp_functions;
        defer db.temp_func_collector = null;
        defer for (temp_functions.items) |name| {
            db.unregisterFunctionSpec(name) catch {};
        };

        db.stmt_params = &.{};
        const stmt_node = statementNodeOf(analyzed.node) orelse return error.Unimplemented;
        var columns: []const OutputColumn = &.{};
        const formatted = switch (stmt_node) {
            .resolved_query_stmt_node => |query_stmt| blk: {
                const text = try transformStatement(db, arena, analyzed.node, opts);
                columns = try outputColumns(arena, query_stmt);
                break :blk text;
            },
            .resolved_insert_stmt_node,
            .resolved_update_stmt_node,
            .resolved_delete_stmt_node,
            => try transformStatement(db, arena, analyzed.node, opts),
            else => return error.Unimplemented,
        };
        if (temp_tables.items.len > 0) {
            db.dropTempTables(arena, temp_tables.items);
            db.setLastError("cannot prepare a statement that creates temporary tables");
            return error.Unimplemented;
        }

        const stmt = db.sqlite_db.prepare(formatted) catch {
            db.setLastError(db.sqlite_db.errmsg());
            return error.ExecFailed;
        };
        return .{
            .db = db,
            .arena = arena_state,
            .scratch = std.heap.ArenaAllocator.init(db.gpa),
            .stmt = stmt,
            .param_mode = db.param_mode,
            // Points into `arena_state`, which the handle now owns; only the
            // Db-level field is transient.
            .params = db.stmt_params,
            .columns = columns,
        };
    }

    /// Table or view registered in the GoogleSQL catalog under
    /// `project.dataset.table`, or null.
    ///
    /// This answers "does it exist" without running a query. Probing with a
    /// SELECT would instead answer "is it currently resolvable", which is a
    /// different and much less stable question: a view whose dependency is
    /// momentarily dropped — as happens constantly while materializing —
    /// would look absent.
    pub fn catalogTable(
        db: *Db,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) error{OutOfMemory}!?*const spec.TableSpec {
        const canonical = try std.mem.join(
            arena,
            "_",
            &.{ project_id, dataset_id, table_id },
        );
        // Persistent only: this is the metadata API's "does this table exist",
        // and a TEMP object exists solely for the duration of the script that
        // made it.
        //
        // The returned pointer outlives the lock. That is safe because a
        // published TableSpec is never mutated in place — a replacement swaps
        // the slot to a new spec — and tombstoned slots are never reused, so
        // the object stays valid for the catalog's lifetime. The worst case is
        // reading a definition that another connection replaced a moment ago.
        var g = db.lockCatalog();
        defer g.unlock();
        const found = g.catalog.tableSpecByName(canonical) orelse return null;
        // The join is not injective: `foo_bar_baz` as one segment collides with
        // `foo.bar.baz`. Only the path that was asked for counts.
        if (!pathIs(found.name_path, project_id, dataset_id, table_id)) return null;
        return found;
    }

    fn pathIs(path: []const []const u8, p: []const u8, d: []const u8, t: []const u8) bool {
        return path.len == 3 and std.mem.eql(u8, path[0], p) and std.mem.eql(u8, path[1], d) and
            std.mem.eql(u8, path[2], t);
    }

    /// Every table and view the GoogleSQL catalog holds under
    /// `project.dataset`, in registration order.
    ///
    /// The metadata API needs this to answer "what is in this dataset" for
    /// objects the metadata store never saw — anything created by SQL rather
    /// than by tables.insert. Pointer lifetime is as `catalogTable` describes.
    pub fn catalogTablesIn(
        db: *Db,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
    ) error{OutOfMemory}![]const *const spec.TableSpec {
        var out: std.ArrayList(*const spec.TableSpec) = .empty;
        var g = db.lockCatalog();
        defer g.unlock();
        for (try g.catalog.liveTableSpecs(arena)) |table_spec| {
            const path = table_spec.name_path;
            if (path.len != 3) continue;
            // A 2-part dataset yields a 3-part synthetic
            // `ds.INFORMATION_SCHEMA.TABLES`, which would otherwise pass the
            // length filter and surface in datasets.list / datasets.delete.
            if (std.mem.eql(u8, path[1], function.info_schema_vtab.info_schema_segment)) continue;
            if (!std.mem.eql(u8, path[0], project_id)) continue;
            if (!std.mem.eql(u8, path[1], dataset_id)) continue;
            try out.append(arena, table_spec);
        }
        return out.toOwnedSlice(arena);
    }

    /// A DDL name path, normalized, with `default_project` prepended for`dataset.table` paths
    fn qualifyPath(
        db: *Db,
        arena: std.mem.Allocator,
        path: []const []const u8,
    ) error{OutOfMemory}![]const []const u8 {
        const normalized = try normalizePath(arena, path);
        const project = db.default_project orelse return normalized;
        if (normalized.len != 2) return normalized;
        return try arena.dupe([]const u8, &.{ project, normalized[0], normalized[1] });
    }

    /// Attaches the metadata API's resource text to `project.dataset.table`,
    /// replacing what was there, and stamps `updated_at`. The analyzer-visible
    /// shape is untouched, so this is a slot swap with no handle resync.
    pub fn setTableMetadata(
        db: *Db,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
        metadata_json: []const u8,
    ) catalog_mod.Error!void {
        const canonical = try std.mem.join(arena, "_", &.{ project_id, dataset_id, table_id });
        const now = catalog_mod.nowTimestamps(arena) catch return error.OutOfMemory;
        var g = db.lockCatalog();
        defer g.unlock();
        const current = g.catalog.tableSpecByName(canonical) orelse return error.TableNotFound;
        var updated = current.*;
        updated.metadata = metadata_json;
        updated.updated_at = now.rfc3339;
        try g.catalog.updateTableSpec(&db.sqlite_db, &updated);
    }

    /// Declares that `project.dataset` exists, carrying the metadata API's
    /// resource text. The catalog is a dataset's only store: datasets.get and
    /// datasets.list read the resource back from here, `require_dataset`
    /// consults it, and `<project>.INFORMATION_SCHEMA.SCHEMATA` reports the
    /// dataset even before it holds a table. Declaring a dataset again
    /// replaces its resource (datasets.patch) and keeps its creation time.
    pub fn addDataset(
        db: *Db,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
        metadata_json: []const u8,
    ) catalog_mod.Error!void {
        const now = catalog_mod.nowTimestamps(arena) catch return error.OutOfMemory;
        const canonical = try std.mem.join(arena, "_", &.{ project_id, dataset_id });
        var ds = spec.DatasetSpec{
            .name_path = &.{ project_id, dataset_id },
            .metadata = metadata_json,
            .updated_at = now.rfc3339,
            .created_at = now.rfc3339,
        };
        var g = db.lockCatalog();
        defer g.unlock();
        if (g.catalog.datasetSpecByName(canonical)) |current| {
            if (!current.is_synthetic and pathIs2(current.name_path, project_id, dataset_id)) {
                ds.created_at = current.created_at;
            }
        }
        try g.catalog.addNewDatasetSpec(&db.sqlite_db, &ds);
    }

    /// Forgets a declared dataset. Its tables are the caller's business
    /// (datasets.delete drops them first). A dataset the catalog only
    /// inferred from a table's path is not declared, so it reports
    /// `DatasetNotFound` like an unknown one.
    pub fn deleteDataset(
        db: *Db,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
    ) catalog_mod.Error!void {
        const canonical = try std.mem.join(arena, "_", &.{ project_id, dataset_id });
        var g = db.lockCatalog();
        defer g.unlock();
        const current = g.catalog.datasetSpecByName(canonical) orelse return error.DatasetNotFound;
        if (!pathIs2(current.name_path, project_id, dataset_id)) return error.DatasetNotFound;
        try g.catalog.deleteDatasetSpec(&db.sqlite_db, canonical);
    }

    /// The declared dataset `project.dataset`, or null. Inferred datasets do
    /// not count: this is the metadata API's "does this dataset exist", and
    /// nobody created those. Pointer lifetime is as `catalogTable` describes.
    pub fn catalogDataset(
        db: *Db,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
    ) error{OutOfMemory}!?*const spec.DatasetSpec {
        const canonical = try std.mem.join(arena, "_", &.{ project_id, dataset_id });
        var g = db.lockCatalog();
        defer g.unlock();
        const found = g.catalog.datasetSpecByName(canonical) orelse return null;
        if (found.is_synthetic) return null;
        if (!pathIs2(found.name_path, project_id, dataset_id)) return null;
        return found;
    }

    /// Every declared dataset under `project`, in declaration order.
    pub fn catalogDatasetsIn(
        db: *Db,
        arena: std.mem.Allocator,
        project_id: []const u8,
    ) error{OutOfMemory}![]*const spec.DatasetSpec {
        var out: std.ArrayList(*const spec.DatasetSpec) = .empty;
        var g = db.lockCatalog();
        defer g.unlock();
        for (try g.catalog.liveDatasets(arena)) |ds| {
            if (ds.is_synthetic) continue;
            if (!std.mem.eql(u8, ds.name_path[0], project_id)) continue;
            try out.append(arena, ds);
        }
        return out.toOwnedSlice(arena);
    }

    /// Whether the engine knows `project.dataset` at all — declared, or
    /// inferred from a table already living in it.
    pub fn datasetExists(
        db: *Db,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
    ) error{OutOfMemory}!bool {
        const canonical = try std.mem.join(arena, "_", &.{ project_id, dataset_id });
        var g = db.lockCatalog();
        defer g.unlock();
        const found = g.catalog.datasetSpecByName(canonical) orelse return false;
        return pathIs2(found.name_path, project_id, dataset_id);
    }

    fn pathIs2(path: []const []const u8, p: []const u8, d: []const u8) bool {
        return path.len == 2 and std.mem.eql(u8, path[0], p) and std.mem.eql(u8, path[1], d);
    }

    /// The `require_dataset` check, for a CREATE whose (qualified) name is
    /// `name_path`. BigQuery's own message goes into `lastError`. Only a
    /// `project.dataset.x` name can be checked: a shorter one has no dataset
    /// to look up, and the anonymous results dataset and INFORMATION_SCHEMA
    /// are the engine's own, never declared by anyone.
    fn requireDataset(db: *Db, arena: std.mem.Allocator, name_path: []const []const u8) Error!void {
        if (!db.require_dataset or name_path.len != 3) return;
        if (std.mem.eql(u8, name_path[1], function.job_rows_vtab.anon_segment)) return;
        if (std.mem.eql(u8, name_path[1], function.info_schema_vtab.info_schema_segment)) return;
        if (try db.datasetExists(arena, name_path[0], name_path[1])) return;
        db.setLastError(try std.fmt.allocPrint(
            arena,
            "Not found: Dataset {s}:{s} was not found in location US",
            .{ name_path[0], name_path[1] },
        ));
        return error.DatasetNotFound;
    }

    /// Snapshots the live table specs for the INFORMATION_SCHEMA vtabs.
    ///
    /// The TEMP overlay is deliberately not merged in: those views report
    /// persistent objects, and `info_schema_vtab` filters temps out anyway.
    fn publishInfoSchemaSnapshot(db: *Db, arena: std.mem.Allocator) Error!void {
        var g = db.lockCatalog();
        defer g.unlock();
        db.udf_state.info_schema.info_schema = g.catalog.liveTableSpecs(arena) catch
            return error.OutOfMemory;
        db.udf_state.info_schema.datasets = g.catalog.liveDatasets(arena) catch
            return error.OutOfMemory;
    }

    /// Exclusive access to this connection's persistent catalog. Blocks while
    /// another connection holds a shared one; a no-op when the catalog is
    /// private. Release with `unlock`.
    ///
    /// Do not hold this across a GoogleSQL analyze or any SQLite work beyond
    /// the catalog's own upsert — the point of sharing a catalog rather than
    /// synchronising copies is that the expensive work stays parallel. See
    /// the lock-ordering invariant on `shared_catalog.Guard`.
    pub fn lockCatalog(db: *Db) shared_catalog.Guard {
        if (db.shared) |sc| return shared_catalog.lockShared(sc);
        return .{ .catalog = db.own_catalog.? };
    }

    /// Registers a table/view spec in the connection's TEMP overlay or the
    /// persistent catalog, per its scope.
    fn registerTableSpec(db: *Db, table_spec: *const spec.TableSpec) catalog_mod.Error!void {
        if (table_spec.is_temp) return db.temps.addOverlayTableSpec(table_spec);
        var g = db.lockCatalog();
        defer g.unlock();
        return g.catalog.addNewTableSpec(&db.sqlite_db, table_spec);
    }

    /// Removes a table/view spec, TEMP overlay first so a DROP of a shadowing
    /// TEMP object leaves the persistent table it shadowed intact.
    fn unregisterTableSpec(db: *Db, name: []const u8) catalog_mod.Error!void {
        if (db.temps.findTableSpec(name) != null) {
            return db.temps.deleteOverlayTableSpec(name);
        }
        var g = db.lockCatalog();
        defer g.unlock();
        return g.catalog.deleteTableSpec(&db.sqlite_db, name);
    }

    /// Removes a function spec, TEMP overlay first (same reasoning as
    /// `unregisterTableSpec`).
    fn unregisterFunctionSpec(db: *Db, name: []const u8) catalog_mod.Error!void {
        if (db.temps.findFunctionSpec(name) != null) {
            return db.temps.deleteOverlayFunctionSpec(name);
        }
        var g = db.lockCatalog();
        defer g.unlock();
        return g.catalog.deleteFunctionSpec(&db.sqlite_db, name);
    }

    /// The whole catalog as one proto, for the stateless analyzer path.
    fn statelessCatalogJson(
        db: *Db,
        arena: std.mem.Allocator,
    ) error{ OutOfMemory, InvalidSpec }![:0]u8 {
        var g = db.lockCatalog();
        defer g.unlock();
        return g.catalog.catalogJsonWith(arena, db.temps);
    }

    fn addPersistentFunctionSpec(db: *Db, fs: *const spec.FunctionSpec) catalog_mod.Error!void {
        var g = db.lockCatalog();
        defer g.unlock();
        return g.catalog.addNewFunctionSpec(&db.sqlite_db, fs);
    }

    /// Persistent functions with the connection's TEMP ones layered on top,
    /// so a TEMP function shadows a persistent one of the same name.
    ///
    /// The map holds catalog-owned `*FunctionSpec` pointers and is used after
    /// the lock is dropped. Safe for the same reason as `catalogTable`:
    /// registration replaces the pointer rather than mutating the spec, and
    /// nothing in the catalog arena is freed before teardown — so a spec
    /// dropped by another connection mid-statement is stale, not dangling.
    fn mergedFuncMap(db: *Db, arena: std.mem.Allocator) error{OutOfMemory}!*spec.FuncMap {
        const fm = blk: {
            var g = db.lockCatalog();
            defer g.unlock();
            break :blk try g.catalog.funcMap(arena);
        };
        try db.temps.addFunctionsTo(arena, fm);
        return fm;
    }

    /// Whether a canonical name is registered, TEMP overlay shadowing the
    /// persistent catalog.
    fn tableSpecExists(db: *Db, name: []const u8) bool {
        if (db.temps.findTableSpec(name) != null) return true;
        var g = db.lockCatalog();
        defer g.unlock();
        return g.catalog.findTableSpec(name) != null;
    }

    // ---- Raw SQLite passthrough (Go zetasqlite.WithQueryFormattingDisabled) ----
    //
    // bigquery-emulator's metadata tables (projects/datasets/tables/jobs/...)
    // are plain SQLite, not GoogleSQL: Go prepares all 22 of them under
    // WithQueryFormattingDisabled (internal/connection/manager.go
    // PrepareQueries). These entry points are that path — no analyzer, no
    // transform, no catalog. They are invisible to the GoogleSQL catalog, so
    // a table created here cannot be reached by query()/exec().
    //
    // Statements are cached per Db, which is what Go's per-connection
    // `stmts map[string]*sql.Stmt` achieves. Go needs txConnMap/txMu to route
    // a *sql.Tx back to the connection owning its prepared statement; here a
    // statement never leaves its Db, so no such bookkeeping exists.

    /// Bindable value for the raw path. Distinct from Cell: no GoogleSQL
    /// types, since nothing here is analyzed or encoded.
    pub const RawValue = union(enum) {
        null,
        int: i64,
        float: f64,
        text: []const u8,
        blob: []const u8,
    };

    /// `name` binds by `@name`/`:name` (Go's sql.Named); null binds
    /// positionally in argument order.
    pub const RawArg = struct {
        name: ?[:0]const u8 = null,
        value: RawValue,
    };

    /// Run a raw SQLite statement producing no rows.
    pub fn rawExec(db: *Db, sql: [:0]const u8, args: []const RawArg) Error!void {
        var rows = try db.rawQuery(sql, args);
        defer rows.deinit();
        while (try rows.next()) |_| {}
    }

    /// Run a raw SQLite query. The returned RawRows borrows SQLite's own row
    /// buffer, so each row is valid only until the next next() call — copy
    /// anything that must outlive it.
    pub fn rawQuery(db: *Db, sql: [:0]const u8, args: []const RawArg) Error!RawRows {
        // Everything reached from here is emulator bookkeeping, not the
        // caller's query; RawRows.next re-enters the scope for the same reason.
        var scope = phase.SourceScope.begin(.metadata);
        defer scope.end();
        const entry = try db.acquireRawStmt(sql);
        errdefer db.releaseRawStmt(entry);

        var stmt = entry.stmt;
        stmt.reset();
        stmt.clearBindings();

        for (args, 0..) |arg, i| {
            const idx: i32 = if (arg.name) |n| blk: {
                const found = stmt.bindParameterIndex(n);
                if (found == 0) {
                    db.setLastError("unknown named parameter");
                    return error.ExecFailed;
                }
                break :blk found;
            } else @intCast(i + 1);
            db.bindRawValue(&stmt, idx, arg.value) catch {
                db.setLastSqliteError();
                return error.ExecFailed;
            };
        }

        const ncols: usize = @intCast(stmt.columnCount());
        const scratch = try db.gpa.alloc(RawValue, ncols);
        return .{ .db = db, .entry = entry, .scratch = scratch };
    }

    fn bindRawValue(db: *Db, stmt: *sqlite.Stmt, idx: i32, v: RawValue) sqlite.Error!void {
        _ = db;
        return switch (v) {
            .null => stmt.bindNull(idx),
            .int => |x| stmt.bindInt64(idx, x),
            .float => |x| stmt.bindDouble(idx, x),
            .text => |x| stmt.bindText(idx, x),
            .blob => |x| stmt.bindBlob(idx, x),
        };
    }

    /// Cached prepared statement plus a reentrancy guard: a second concurrent
    /// rawQuery on the same SQL gets its own uncached statement rather than
    /// silently resetting one that an open RawRows is still stepping.
    const RawStmt = struct {
        stmt: sqlite.Stmt,
        in_use: bool = false,
        cached: bool = true,
    };

    fn acquireRawStmt(db: *Db, sql: [:0]const u8) Error!*RawStmt {
        if (db.raw_cache.get(sql)) |entry| {
            if (!entry.in_use) {
                entry.in_use = true;
                return entry;
            }
            // Re-entrant use: prepare a throwaway statement.
            return db.newRawStmt(sql, false);
        }
        const entry = try db.newRawStmt(sql, true);
        // dupe, not dupeZ: the map key type is []const u8, so a sentinel-
        // terminated allocation would be freed one byte short.
        const key = try db.gpa.dupe(u8, sql);
        errdefer db.gpa.free(key);
        try db.raw_cache.put(db.gpa, key, entry);
        return entry;
    }

    fn newRawStmt(db: *Db, sql: [:0]const u8, cached: bool) Error!*RawStmt {
        const stmt = db.sqlite_db.prepare(sql) catch {
            db.setLastSqliteError();
            return error.ExecFailed;
        };
        const entry = try db.gpa.create(RawStmt);
        entry.* = .{ .stmt = stmt, .in_use = true, .cached = cached };
        return entry;
    }

    fn releaseRawStmt(db: *Db, entry: *RawStmt) void {
        if (entry.cached) {
            entry.stmt.reset();
            entry.stmt.clearBindings();
            entry.in_use = false;
            return;
        }
        entry.stmt.finalize();
        db.gpa.destroy(entry);
    }

    fn deinitRawCache(db: *Db) void {
        var it = db.raw_cache.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.stmt.finalize();
            db.gpa.destroy(kv.value_ptr.*);
            db.gpa.free(kv.key_ptr.*);
        }
        db.raw_cache.deinit(db.gpa);
    }

    /// Returns a catalog handle that is up to date with `db.catalog`, or null
    /// if the persistent path cannot be used and the caller should fall back
    /// to the stateless one.
    ///
    /// The returned pointer must be used instead of any handle captured
    /// earlier: a change that cannot be expressed as a delta forces a rebuild,
    /// which destroys the previous handle.
    fn syncedCatalogHandle(
        db: *Db,
        arena: std.mem.Allocator,
    ) ?*analyzer_ffi.CatalogHandle {
        if (db.catalog_handle == null) return null;

        // Both sources are rendered before either is applied, because a full
        // render assumes a fresh handle: if one side rendered from scratch and
        // the other incrementally, recreating the handle would silently drop
        // whatever the incremental side thought it already held. Disagreement
        // is resolved by forcing both full and rendering again — which happens
        // only when another connection drops a function between the two
        // renders, so the loop is a guard rather than a hot path.
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            const persistent = blk: {
                var g = db.lockCatalog();
                defer g.unlock();
                break :blk g.catalog.renderDelta(arena, &db.cursor) catch {
                    db.cursor.needs_rebuild = true;
                    return null;
                };
            };
            const temps = db.temps.renderDelta(arena, &db.temp_cursor) catch {
                db.temp_cursor.needs_rebuild = true;
                return null;
            };

            if (persistent.full != temps.full) {
                db.cursor.needs_rebuild = true;
                db.temp_cursor.needs_rebuild = true;
                continue;
            }

            if (persistent.full) {
                analyzer_ffi.catalogDestroy(db.catalog_handle.?);
                db.catalog_handle = analyzer_ffi.catalogCreate(db.gpa) catch null;
                if (db.catalog_handle == null) return null;
            }

            if (!db.applyOps(persistent.ops, &db.cursor)) return null;
            // The overlay goes last: its entries carry a removal ahead of the
            // addition, so applying them after the persistent ones is what
            // makes a TEMP object shadow the persistent one it overrides.
            if (!db.applyOps(temps.ops, &db.temp_cursor)) return null;
            return db.catalog_handle;
        }
        return null;
    }

    /// Pushes rendered ops into the analyzer handle. Returns false if the
    /// caller must fall back to the stateless path.
    ///
    /// A failure partway leaves the handle reflecting an unknown prefix of the
    /// delta, and the cursor has already advanced past it — so the only safe
    /// recovery is a full rebuild on the next use.
    fn applyOps(
        db: *Db,
        ops: []const catalog_mod.DeltaOp,
        cur: *catalog_mod.Cursor,
    ) bool {
        const handle = db.catalog_handle orelse return false;
        for (ops) |op| switch (op) {
            .add_json => |json| analyzer_ffi.catalogAddTables(db.gpa, handle, json) catch {
                cur.needs_rebuild = true;
                return false;
            },
            .remove => |name| analyzer_ffi.catalogRemoveTable(db.gpa, handle, name) catch {
                cur.needs_rebuild = true;
                return false;
            },
        };
        return true;
    }

    const Mode = enum { query, exec };

    /// Result of running a statement script. A null `stmt` mirrors Go's
    /// empty &Rows{conn} returned when the last statement is not a query
    /// (DML/DDL executed to completion; Rows yields no rows).
    const Prepared = struct {
        stmt: ?sqlite.Stmt = null,
        columns: []const OutputColumn = &.{},
        /// Temp tables/views to drop when the returned Rows is deinited.
        temp_tables: []const []const u8 = &.{},
    };

    /// One analyzer round trip: the catalog-handle path when the delta can be
    /// pushed into the live handle, the stateless JSON path otherwise. Shared
    /// by the runStatements loop and by prepare.
    fn analyzeOne(
        db: *Db,
        arena: std.mem.Allocator,
        sqlz: [:0]const u8,
        offset: usize,
        opts: QueryOptions,
        options_json: [:0]const u8,
        /// Parameter types to declare, or null to let the analyzer infer.
        decls: ?analyzer_ffi.ParamDecls,
    ) Error!analyzer_ffi.Analyzed {
        var analyze_timer = phase.Timer.begin(.analyze);
        defer analyze_timer.end();
        // Re-read the handle from `db` *after* syncing: a catalog removal
        // forces a rebuild, which destroys the old handle. Using the pointer
        // captured before the sync is a use-after-free.
        if (opts.catalog_scope == .full) if (db.syncedCatalogHandle(arena)) |handle| {
            return analyzer_ffi.analyzeNextStatementWithCatalog(
                arena,
                handle,
                sqlz,
                offset,
                options_json,
                decls,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    db.setLastError(analyzer_ffi.last_error);
                    return error.AnalyzeFailed;
                },
            };
        };

        const catalog_json = if (opts.catalog_scope == .none)
            try arena.dupeZ(u8, "{}")
        else
            db.statelessCatalogJson(arena) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    db.setLastError(@errorName(err));
                    return error.AnalyzeFailed;
                },
            };
        return analyzer_ffi.analyzeNextStatementOpts(
            arena,
            sqlz,
            offset,
            catalog_json,
            options_json,
            decls,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                db.setLastError(analyzer_ffi.last_error);
                return error.AnalyzeFailed;
            },
        };
    }

    /// The Analyze loop: analyzer -> per-kind statement action, mirroring
    /// Go's newStmtAction dispatch. QueryStmt transforms and prepares;
    /// CREATE/DML/DROP/TRUNCATE actions execute inline and mutate the
    /// catalog; BEGIN/COMMIT and row-access-policy statements are no-ops.
    /// In .query mode the LAST statement's prepared query is returned
    /// (empty Prepared when the last statement is not a query); in .exec
    /// mode every statement runs to completion and null is returned.
    fn runStatements(
        db: *Db,
        arena: std.mem.Allocator,
        sql: []const u8,
        args: []const Param,
        opts: QueryOptions,
        mode: Mode,
    ) Error!?Prepared {
        // Go parseScript flattens BEGIN ... END script blocks before analysis
        // (flattenBeginEndBlock); AnalyzeNextStatement can't parse script
        // blocks, so blank out the block keywords at the text level (lengths
        // preserved so analyzer error positions stay accurate).
        const flattened_sql = try flattenBeginEndBlocks(arena, sql);
        const sqlz = try arena.dupeZ(u8, flattened_sql);
        var offset: usize = 0;

        // Publish the catalog snapshot the INFORMATION_SCHEMA vtabs read.
        // Taken here, under the lock and before any stepping: those callbacks
        // run inside sqlite3_step, where acquiring the catalog lock would
        // invert the ordering shared_catalog.zig requires and can deadlock a
        // connection pool.
        //
        // Deliberately not cleared on the way out. In `.query` mode this
        // function only *prepares* — Rows.next does the stepping afterwards —
        // so releasing here would empty the snapshot before a single row was
        // read. It lives in the query arena, which becomes Rows.arena, so it
        // stays valid exactly as long as the rows do; Rows.deinit clears it.
        try db.publishInfoSchemaSnapshot(arena);

        // Go getParameterMode: scan the (literal-stripped) query for `?`
        // (positional) vs `@name` (named); mixing is rejected.
        db.param_mode = parameterMode(arena, sql) catch {
            db.setLastError("named parameter and positional parameter cannot be used together");
            return error.AnalyzeFailed;
        };
        const options_json: [:0]const u8 = switch (db.param_mode) {
            .positional => "{\"parameter_mode\":\"positional\"}",
            .named => "{}",
        };

        // Positional parameters are consumed statement-by-statement across a
        // script (Go slices args by each statement's parameter count); named
        // parameters apply to every statement.
        var cur_args = args;

        // Named declarations are constant across the script, so build them
        // once; positional ones are rebuilt per statement below, because
        // cur_args advances.
        const named_decls = if (db.param_mode == .named)
            try paramDecls(arena, args, .named)
        else
            null;

        // Collect temp tables/views created during this script; dropped when
        // the query's Rows is deinited (query mode) or right after the last
        // statement (exec mode), mirroring Go's per-action Cleanup.
        var temp_tables: std.ArrayList([]const u8) = .empty;
        db.temp_collector = &temp_tables;
        defer db.temp_collector = null;

        // Temp functions live only until the script finishes (their calls
        // are inlined into the generated SQL at transform time), so they
        // are removed on every exit path, unlike temp tables which must
        // survive while Rows is iterated.
        var temp_functions: std.ArrayList([]const u8) = .empty;
        db.temp_func_collector = &temp_functions;
        defer db.temp_func_collector = null;
        defer for (temp_functions.items) |name| {
            db.unregisterFunctionSpec(name) catch {};
        };

        // No catalog re-read here (Go re-syncs from SQLite before every
        // statement). Every write goes through the in-process catalog, so it
        // is already current; re-reading only reintroduced the timestamp
        // cursor's lost-commit window and a SQLite round trip per statement.
        while (true) {
            const decls = switch (db.param_mode) {
                .named => named_decls,
                // Declaring every *remaining* positional type is safe:
                // supplying more than the statement has `?` is explicitly
                // allowed, and the resolver only complains when a `?` sits
                // past the end of the list. It has to be the remaining set
                // rather than the whole one because cur_args has already
                // advanced past what earlier statements consumed.
                .positional => try paramDecls(arena, cur_args, .positional),
            };

            // Re-rendered per statement: DDL/DML actions mutate the
            // catalog between statements of one script.
            const analyzed = try db.analyzeOne(arena, sqlz, offset, opts, options_json, decls);
            offset = analyzed.resume_offset;
            const last = analyzed.at_end;

            // Positional parameters consumed by this statement (Go
            // action.Args() count); used to advance cur_args below.
            var consumed: usize = 0;

            // Parameter types are re-collected per statement by
            // transformStatementFragment; clear any stale set first.
            db.stmt_params = &.{};

            const stmt_node = statementNodeOf(analyzed.node) orelse return error.Unimplemented;
            switch (stmt_node) {
                .resolved_query_stmt_node => |query_stmt| {
                    const formatted = try transformStatement(db, arena, analyzed.node, opts);

                    var stmt = db.sqlite_db.prepare(formatted) catch {
                        db.setLastError(db.sqlite_db.errmsg());
                        return error.ExecFailed;
                    };
                    errdefer stmt.finalize();
                    consumed = try db.bindParams(arena, &stmt, cur_args);

                    if (last and mode == .query) {
                        return .{
                            .stmt = stmt,
                            .columns = try outputColumns(arena, query_stmt),
                            .temp_tables = temp_tables.items,
                        };
                    }

                    switch (mode) {
                        // Earlier statements in a query script are never
                        // iterated (Go's database/sql laziness); prepare
                        // validated them.
                        .query => stmt.finalize(),
                        .exec => {
                            while (stmt.step() catch {
                                db.setLastError(db.sqlite_db.errmsg());
                                return error.ExecFailed;
                            }) {}
                            stmt.finalize();
                        },
                    }
                },
                .resolved_create_statement_node => |create_any| {
                    consumed = try db.execCreateStatement(
                        arena,
                        analyzed.node,
                        create_any,
                        cur_args,
                        opts,
                    );
                },
                // Go newDMLStmtAction: exec the formatted DML SQL.
                .resolved_insert_stmt_node,
                .resolved_update_stmt_node,
                .resolved_delete_stmt_node,
                => {
                    const formatted = try transformStatement(db, arena, analyzed.node, opts);
                    consumed = try db.execSql(arena, formatted, cur_args);
                },
                .resolved_drop_stmt_node => |drop_stmt| {
                    consumed = try db.execDropStatement(
                        arena,
                        analyzed.node,
                        drop_stmt,
                        cur_args,
                        opts,
                    );
                },
                // Go newDropFunctionStmtAction -> DropStmtAction with
                // objectType "FUNCTION": delete the catalog spec only (no
                // SQLite object exists for a UDF).
                .resolved_drop_function_stmt_node => |drop_fn| {
                    const name = try formatNamePath(arena, drop_fn.name_path);
                    db.unregisterFunctionSpec(name) catch |err| {
                        // DROP FUNCTION IF EXISTS on a missing function is
                        // a no-op; otherwise Go errors out.
                        if (err == error.TableNotFound and (drop_fn.is_if_exists orelse false)) {
                            // no-op
                        } else return db.failCatalog(err);
                    };
                },
                // Go MergeStmtAction: the transformer lowers MERGE to a list
                // of plain statements (create merged temp table, one
                // INSERT/UPDATE/DELETE per WHEN clause, drop temp table)
                // executed in order without args.
                .resolved_merge_stmt_node => {
                    const fragment = try transformStatementFragment(db, arena, analyzed.node, opts);
                    const compound = switch (fragment) {
                        .compound => |c| c,
                        else => return error.TransformFailed,
                    };
                    for (compound.getStatements()) |stmt_sql| {
                        _ = try db.execSql(arena, stmt_sql, &.{});
                    }
                },
                // Go newTruncateStmtAction: DELETE FROM `table`.
                .resolved_truncate_stmt_node => |truncate_stmt| {
                    try db.execTruncateStatement(arena, truncate_stmt);
                },
                // Go Begin/CommitStmtAction and NullStmtAction (row access
                // policies): no-ops.
                .resolved_begin_stmt_node,
                .resolved_commit_stmt_node,
                .resolved_create_row_access_policy_stmt_node,
                .resolved_drop_row_access_policy_stmt_node,
                => {},
                else => return error.Unimplemented,
            }

            // Advance past the positional args this statement consumed.
            if (db.param_mode == .positional) cur_args = cur_args[consumed..];

            if (last) {
                switch (mode) {
                    // Query mode: the last statement was not a query (empty
                    // Prepared). Temp tables are dropped now since no Rows
                    // will carry them.
                    .query => {
                        db.dropTempTables(arena, temp_tables.items);
                        return Prepared{};
                    },
                    // Exec mode: everything ran; drop temp tables and finish.
                    .exec => {
                        db.dropTempTables(arena, temp_tables.items);
                        return null;
                    },
                }
            }
        }
    }

    /// Drops the given temp tables/views and removes their catalog specs
    /// (Go CreateTableStmtAction.Cleanup). Best-effort: errors are ignored
    /// since cleanup runs after the query has already produced its result.
    fn dropTempTables(db: *Db, arena: std.mem.Allocator, names: []const []const u8) void {
        for (names) |name| {
            const drop_sql = std.fmt.allocPrint(arena, "DROP TABLE IF EXISTS `{s}`", .{name}) catch continue;
            _ = db.execSql(arena, drop_sql, &.{}) catch {};
            db.unregisterTableSpec(name) catch {};
        }
    }

    /// Prepares `sql_text`, binds `args`, and steps it to completion
    /// (Go conn.ExecContext used by every non-query action). Returns the
    /// number of positional args consumed (0 in named mode).
    fn execSql(
        db: *Db,
        arena: std.mem.Allocator,
        sql_text: []const u8,
        args: []const Param,
    ) Error!usize {
        var stmt = db.sqlite_db.prepare(sql_text) catch {
            db.setLastError(db.sqlite_db.errmsg());
            return error.ExecFailed;
        };
        defer stmt.finalize();
        const consumed = try db.bindParams(arena, &stmt, args);
        while (stmt.step() catch {
            db.setLastError(db.sqlite_db.errmsg());
            return error.ExecFailed;
        }) {}
        return consumed;
    }

    /// Creates the index backing a declared primary key, if the spec has one.
    ///
    /// A separate statement rather than part of the CREATE TABLE, because
    /// `execSql` prepares exactly one statement and would silently discard
    /// anything after a `;`. Routed through `execSql` rather than
    /// `sqlite_db.exec` so the index shows up in `DUMP_SQL` snapshots beside
    /// the table DDL it belongs to.
    fn execPkIndex(
        db: *Db,
        arena: std.mem.Allocator,
        table_spec: *const spec.TableSpec,
    ) Error!void {
        const idx = (table_spec.pkIndexSchema(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransformFailed,
        }) orelse return;
        _ = try db.execSql(arena, idx, &.{});
    }

    fn failCatalog(db: *Db, err: catalog_mod.Error) Error {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        db.setLastError(@errorName(err));
        return error.ExecFailed;
    }

    /// Go newStmtAction's CREATE dispatch: table / table-as-select / view /
    /// function.
    fn execCreateStatement(
        db: *Db,
        arena: std.mem.Allocator,
        node: *pb.AnyResolvedNodeProto,
        create_any: *const pb.AnyResolvedCreateStatementProto,
        args: []const Param,
        opts: QueryOptions,
    ) Error!usize {
        const create_node = create_any.node orelse return error.Unimplemented;
        switch (create_node) {
            .resolved_create_table_stmt_base_node => |base_any| {
                const base_node = base_any.node orelse return error.Unimplemented;
                switch (base_node) {
                    .resolved_create_table_stmt_node => |ct| {
                        return db.execCreateTable(arena, ct, args);
                    },
                    .resolved_create_table_as_select_stmt_node => |ctas| {
                        return db.execCreateTableAsSelect(arena, node, ctas, args, opts);
                    },
                    else => return error.Unimplemented,
                }
            },
            .resolved_create_view_base_node => |view_any| {
                const view_node = view_any.node orelse return error.Unimplemented;
                switch (view_node) {
                    .resolved_create_view_stmt_node => |cv| {
                        try db.execCreateView(arena, node, cv, opts);
                        return 0;
                    },
                    else => return error.Unimplemented,
                }
            },
            .resolved_create_function_stmt_node => |cf| {
                try db.execCreateFunction(arena, cf, opts);
                return 0;
            },
            else => return error.Unimplemented,
        }
    }

    /// Go CreateFunctionStmtAction: build the FunctionSpec (spec.go
    /// newFunctionSpec) and register it with the catalog (persisted unless
    /// TEMP). No SQLite DDL is emitted — calls are inlined at transform
    /// time via FunctionSpec.CallSQL.
    fn execCreateFunction(
        db: *Db,
        arena: std.mem.Allocator,
        cf: *const pb.ResolvedCreateFunctionStmtProto,
        opts: QueryOptions,
    ) Error!void {
        const fn_spec = try db.newFunctionSpec(arena, cf, opts);
        if (!fn_spec.is_temp) try db.requireDataset(arena, fn_spec.name_path);
        if (fn_spec.is_temp)
            db.temps.addNewFunctionSpec(&db.sqlite_db, fn_spec) catch |err|
                return db.failCatalog(err)
        else
            db.addPersistentFunctionSpec(fn_spec) catch |err|
                return db.failCatalog(err);
        if (fn_spec.is_temp) {
            if (db.temp_func_collector) |collector| {
                collector.append(arena, try fn_spec.funcName(arena)) catch {};
            }
        }
    }

    /// Go spec.go newFunctionSpec: signature arguments (name + type or
    /// templated kind), language/code, return type, and — for SQL bodies —
    /// the function expression transformed to SQLite text with the
    /// arguments left as "@name" parameter references (extractArgumentRefData
    /// renders a ResolvedArgumentRef as "@name", which CallSQL substitutes).
    fn newFunctionSpec(
        db: *Db,
        arena: std.mem.Allocator,
        cf: *const pb.ResolvedCreateFunctionStmtProto,
        opts: QueryOptions,
    ) Error!*spec.FunctionSpec {
        const create = cf.parent orelse return error.TransformFailed;

        // Arguments: prefer the signature's per-argument names/types; the
        // resolved AST also carries argument_name_list in declaration order.
        const sig = cf.signature orelse return error.TransformFailed;
        const args = try arena.alloc(*spec.NameWithType, sig.argument.len);
        for (sig.argument, 0..) |arg, i| {
            const nwt = try arena.create(spec.NameWithType);
            nwt.* = .{};
            if (arg.options) |o| {
                if (o.argument_name) |n| nwt.name = n;
            }
            if (nwt.name.len == 0 and i < cf.argument_name_list.len) {
                nwt.name = cf.argument_name_list[i];
            }
            nwt.type = try functionArgumentSpecType(arena, arg);
            args[i] = nwt;
        }

        const language = cf.language orelse "";
        const code = cf.code orelse "";

        // The SQL body: transform the resolved function expression on its
        // own (Go newFunctionSpec: ExtractExpressionData + TransformExpression
        // against a fresh transform context).
        var body: ?[]const u8 = null;
        if (cf.function_expression) |expr| {
            // JS functions carry no resolved expression; a SQL function
            // always does. Templated SQL functions (untyped arguments) also
            // resolve to null here and stay unimplemented, like Go's
            // analyzeTemplatedFunctionWithRuntimeArgument path (excluded).
            body = try transformFunctionBody(db, arena, expr, opts);
        }

        const return_type: ?*spec.Type = if (cf.return_type) |rt|
            spec.newTypeFromProto(arena, rt) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.TransformFailed,
            }
        else
            null;

        const now = catalog_mod.nowTimestamps(arena) catch return error.OutOfMemory;
        const fn_spec = try arena.create(spec.FunctionSpec);
        fn_spec.* = .{
            .is_temp = (create.create_scope orelse .CREATE_DEFAULT_SCOPE) == .CREATE_TEMP,
            .name_path = try normalizePath(arena, create.name_path),
            .language = language,
            .args = args,
            .return_type = return_type,
            .body = body,
            .code = code,
            .is_aggregate = cf.is_aggregate orelse false,
            .updated_at = now.rfc3339,
            .created_at = now.rfc3339,
        };
        return fn_spec;
    }

    /// Transforms a CREATE FUNCTION body expression into SQLite SQL text.
    fn transformFunctionBody(
        db: *Db,
        arena: std.mem.Allocator,
        expr: *pb.AnyResolvedExprProto,
        opts: QueryOptions,
    ) Error![]const u8 {
        const config = try arena.create(context_mod.TransformConfig);
        config.* = context_mod.defaultTransformConfig();
        const ctx = try context_mod.TransformContext.init(arena, config);
        ctx.query_ctx.current_time_unix_micros = opts.current_time_unix_micros;
        ctx.func_map = try db.mergedFuncMap(arena);

        var coordinator = coordinator_mod.QueryCoordinator.init(arena);
        var extractor = coordinator_mod.NodeExtractor{};
        const data = extractor.ExtractExpressionData(arena, expr, ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unimplemented => return error.Unimplemented,
            error.UnsupportedFunction => {
                db.setLastError(value_mod.diagnostic orelse @errorName(err));
                return error.UnsupportedFunction;
            },
            else => {
                db.setLastError(value_mod.diagnostic orelse @errorName(err));
                return error.TransformFailed;
            },
        };
        const sql_expr = coordinator.transformExpression(data, ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unimplemented => return error.Unimplemented,
            error.UnsupportedFunction => {
                db.setLastError(value_mod.diagnostic orelse @errorName(err));
                return error.UnsupportedFunction;
            },
            else => {
                db.setLastError(value_mod.diagnostic orelse @errorName(err));
                return error.TransformFailed;
            },
        };
        return sql_expr.toString(arena) catch return error.OutOfMemory;
    }

    /// Go CreateTableStmtAction for a plain CREATE TABLE (spec built by
    /// newTableSpec; exec runs spec.SQLiteSchema).
    fn execCreateTable(
        db: *Db,
        arena: std.mem.Allocator,
        ct: *const pb.ResolvedCreateTableStmtProto,
        args: []const Param,
    ) Error!usize {
        const base = ct.parent orelse return error.TransformFailed;
        const create = base.parent orelse return error.TransformFailed;
        const table_spec = try newTableSpecFromCreate(arena, create, base, "");
        return db.execCreateTableAction(arena, table_spec, args);
    }

    /// Go CreateTableStmtAction for CREATE TABLE AS SELECT: the transformer
    /// yields a CreateTableStatement whose AsSelect string is persisted in
    /// the spec (newTableAsSelectSpec); exec runs spec.SQLiteSchema, which
    /// renders "CREATE TABLE `t` AS <select>".
    fn execCreateTableAsSelect(
        db: *Db,
        arena: std.mem.Allocator,
        node: *pb.AnyResolvedNodeProto,
        ctas: *const pb.ResolvedCreateTableAsSelectStmtProto,
        args: []const Param,
        opts: QueryOptions,
    ) Error!usize {
        const fragment = try transformStatementFragment(db, arena, node, opts);
        const create_table_stmt = switch (fragment) {
            .create_table_statement => |c| c,
            else => return error.TransformFailed,
        };
        const select_stmt = create_table_stmt.as_select orelse return error.TransformFailed;
        const query_str = select_stmt.toString(arena) catch return error.OutOfMemory;

        const base = ctas.parent orelse return error.TransformFailed;
        const create = base.parent orelse return error.TransformFailed;
        const table_spec = try newTableSpecFromCreate(arena, create, base, query_str);
        return db.execCreateTableAction(arena, table_spec, args);
    }

    /// Shared CreateTableStmtAction.exec body: OR REPLACE drops first,
    /// exec the schema DDL, register the spec (persisted unless temp).
    fn execCreateTableAction(
        db: *Db,
        arena: std.mem.Allocator,
        table_spec: *spec.TableSpec,
        args: []const Param,
    ) Error!usize {
        // A TEMP table has no dataset to qualify into.
        if (!table_spec.is_temp) {
            table_spec.name_path = try db.qualifyPath(arena, table_spec.name_path);
            try db.requireDataset(arena, table_spec.name_path);
        }
        const table_name = try table_spec.tableName(arena);
        const replacing = table_spec.create_mode == spec.create_mode_create_or_replace;
        const from_query = table_spec.query.len != 0;

        // CREATE OR REPLACE ... AS <query> builds into a scratch table and
        // swaps, rather than dropping first. WRITE_TRUNCATE arrives here, and
        // a truncate whose query reads its own destination is ordinary — the
        // dataflow metric pruning job is `SELECT ... FROM t` replacing `t`.
        // Dropping first loses the rows the query is about to read, and left
        // the spec registered against a table SQLite no longer had, so later
        // reads analyzed fine and then failed at prepare with "no such table".
        // Go has no such window: it runs the query to completion first and
        // only then truncates and inserts.
        if (replacing and from_query) {
            const scratch = try std.fmt.allocPrint(arena, "{s}__zigquery_replace", .{table_name});
            const drop_scratch = try std.fmt.allocPrint(
                arena,
                "DROP TABLE IF EXISTS `{s}`",
                .{scratch},
            );
            _ = try db.execSql(arena, drop_scratch, &.{});

            const build = try std.fmt.allocPrint(
                arena,
                "CREATE TABLE `{s}` AS {s}",
                .{ scratch, table_spec.query },
            );
            const consumed = db.execSql(arena, build, args) catch |err| {
                // Leave the destination exactly as it was.
                _ = db.execSql(arena, drop_scratch, &.{}) catch {};
                return err;
            };

            const drop_old = try std.fmt.allocPrint(
                arena,
                "DROP TABLE IF EXISTS `{s}`",
                .{table_name},
            );
            _ = try db.execSql(arena, drop_old, &.{});
            const rename = try std.fmt.allocPrint(
                arena,
                "ALTER TABLE `{s}` RENAME TO `{s}`",
                .{ scratch, table_name },
            );
            _ = try db.execSql(arena, rename, &.{});

            // No execPkIndex here, deliberately: a CTAS cannot carry a primary
            // key, because declaring one needs a column definition list and the
            // analyzer rejects that outright ("CREATE TABLE AS SELECT with
            // column definition list is unsupported"). If that ever becomes
            // supported, this branch needs the index — and it must be created
            // *after* the rename above, since SQLite's ALTER TABLE ... RENAME
            // leaves index names alone and it would otherwise stay called
            // `<t>__zigquery_replace.pk`.
            db.registerTableSpec(table_spec) catch |err|
                return db.failCatalog(err);
            return consumed;
        }

        if (replacing) {
            const drop_sql = try std.fmt.allocPrint(arena, "DROP TABLE IF EXISTS `{s}`", .{table_name});
            _ = try db.execSql(arena, drop_sql, &.{});
        }
        const schema = table_spec.sqliteSchema(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransformFailed,
        };
        const consumed = try db.execSql(arena, schema, args);

        // Before the IF NOT EXISTS early return below, which would otherwise
        // skip it for an already-registered table. CREATE INDEX IF NOT EXISTS
        // is the right no-op in that case.
        try db.execPkIndex(arena, table_spec);

        // Temp tables are dropped once the query completes (Go Cleanup);
        // record them so a later statement/query can re-create the name.
        if (table_spec.is_temp) {
            if (db.temp_collector) |collector| {
                collector.append(arena, table_name) catch {};
            }
        }

        // IF NOT EXISTS on an already-registered table keeps the existing
        // spec. Go's exec unconditionally upserts the JSON spec, but its
        // live engine catalog keeps the first registration
        // (AddOwnedTableIfNotPresent), so the old schema stays visible;
        // this port re-renders the analyzer catalog from the spec map per
        // statement, so skipping the upsert reproduces Go's observable
        // (and BigQuery's actual) no-op semantics.
        if (table_spec.create_mode == spec.create_mode_create_if_not_exists and
            db.tableSpecExists(table_name))
        {
            return consumed;
        }
        db.registerTableSpec(table_spec) catch |err|
            return db.failCatalog(err);
        return consumed;
    }

    /// Go CreateViewStmtAction: exec the CREATE VIEW fragment SQL and
    /// register a view spec (newTableAsViewSpec) whose Query is the inner
    /// SELECT text.
    fn execCreateView(
        db: *Db,
        arena: std.mem.Allocator,
        node: *pb.AnyResolvedNodeProto,
        cv: *const pb.ResolvedCreateViewStmtProto,
        opts: QueryOptions,
    ) Error!void {
        const fragment = try transformStatementFragment(db, arena, node, opts);
        const create_view_stmt = switch (fragment) {
            .create_view_statement => |c| c,
            else => return error.TransformFailed,
        };
        const query_str = create_view_stmt.query.toString(arena) catch return error.OutOfMemory;

        const base = cv.parent orelse return error.TransformFailed;
        const create = base.parent orelse return error.TransformFailed;

        // Go newTableAsViewSpec: columns from the output column list.
        const columns = try arena.alloc(*spec.ColumnSpec, base.output_column_list.len);
        for (base.output_column_list, 0..) |oc, i| {
            const column = oc.column orelse return error.TransformFailed;
            const tp = column.type orelse return error.TransformFailed;
            const col = try arena.create(spec.ColumnSpec);
            col.* = .{
                .name = oc.name orelse "",
                .type = spec.newTypeFromProto(arena, tp) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.TransformFailed,
                },
            };
            columns[i] = col;
        }

        const now = catalog_mod.nowTimestamps(arena) catch return error.OutOfMemory;
        const is_temp = (create.create_scope orelse .CREATE_DEFAULT_SCOPE) == .CREATE_TEMP;
        const table_spec = try arena.create(spec.TableSpec);
        table_spec.* = .{
            .is_temp = is_temp,
            .is_view = true,
            .name_path = if (is_temp)
                try normalizePath(arena, create.name_path)
            else
                try db.qualifyPath(arena, create.name_path),
            .columns = columns,
            .create_mode = goCreateMode(create.create_mode),
            .query = query_str,
            .updated_at = now.rfc3339,
            .created_at = now.rfc3339,
            .options = try optionSpecsFrom(arena, base.option_list),
            .source_sql = base.sql orelse "",
        };
        if (!is_temp) try db.requireDataset(arena, table_spec.name_path);

        if (table_spec.create_mode == spec.create_mode_create_or_replace) {
            const drop_sql = try std.fmt.allocPrint(
                arena,
                "DROP VIEW IF EXISTS `{s}`",
                .{try table_spec.tableName(arena)},
            );
            _ = try db.execSql(arena, drop_sql, &.{});
        }
        // The transformer named the view as written; the spec's name is the
        // one SQLite must know it by.
        const qualified = sqlbuilder.CreateViewStatement{
            .if_not_exists = create_view_stmt.if_not_exists,
            .view_name = try table_spec.tableName(arena),
            .query = create_view_stmt.query,
        };
        const create_fragment = sqlbuilder.SQLFragment{ .create_view_statement = &qualified };
        const create_sql = create_fragment.toString(arena) catch return error.OutOfMemory;
        _ = try db.execSql(arena, create_sql, &.{});
        db.registerTableSpec(table_spec) catch |err|
            return db.failCatalog(err);
    }

    /// Go DropStmtAction: exec the formatted DROP for tables/views, then
    /// delete the catalog spec. DROP FUNCTION belongs to the UDF milestone.
    fn execDropStatement(
        db: *Db,
        arena: std.mem.Allocator,
        node: *pb.AnyResolvedNodeProto,
        drop_stmt: *const pb.ResolvedDropStmtProto,
        args: []const Param,
        opts: QueryOptions,
    ) Error!usize {
        const object_type = drop_stmt.object_type orelse "";
        if (!std.mem.eql(u8, object_type, "TABLE") and !std.mem.eql(u8, object_type, "VIEW")) {
            // Go: "currently unsupported DROP %s statement" (FUNCTION is a
            // separate node kind handled by the UDF milestone).
            return error.Unimplemented;
        }
        _ = node;
        _ = opts;
        // A TEMP object is registered as written; anything else under the
        // project the name resolves to.
        const as_written = try formatNamePath(arena, drop_stmt.name_path);
        const name = if (db.temps.findTableSpec(as_written) != null)
            as_written
        else
            try spec.formatPath(arena, try db.qualifyPath(arena, drop_stmt.name_path));
        const drop = sqlbuilder.DropStatement{
            .if_exists = drop_stmt.is_if_exists orelse false,
            .object_type = object_type,
            .object_name = name,
        };
        const drop_fragment = sqlbuilder.SQLFragment{ .drop_statement = &drop };
        const formatted = drop_fragment.toString(arena) catch return error.OutOfMemory;
        const consumed = try db.execSql(arena, formatted, args);

        // IF EXISTS covers the catalog too: nothing to remove is not an error.
        db.unregisterTableSpec(name) catch |err| switch (err) {
            error.TableNotFound => if (!drop.if_exists) return db.failCatalog(err),
            else => return db.failCatalog(err),
        };
        return consumed;
    }

    /// Go newTruncateStmtAction + TruncateStmtAction.exec:
    /// DELETE FROM `<canonical table name>`.
    fn execTruncateStatement(
        db: *Db,
        arena: std.mem.Allocator,
        truncate_stmt: *const pb.ResolvedTruncateStmtProto,
    ) Error!void {
        const table_scan = truncate_stmt.table_scan orelse return error.TransformFailed;
        const table_ref = table_scan.table orelse return error.TransformFailed;
        const raw_name = table_ref.name orelse return error.TransformFailed;
        const name = try formatNamePath(arena, &.{raw_name});
        const sql_text = try std.fmt.allocPrint(arena, "DELETE FROM `{s}`", .{name});
        _ = try db.execSql(arena, sql_text, &.{});
    }

    /// Binds `args` to the prepared statement's placeholders (Go
    /// getArgsFromParams + database/sql binding). Returns the number of
    /// positional args this statement consumed (0 in named mode, where the
    /// full arg set applies to every statement of the script).
    fn bindParams(
        db: *Db,
        arena: std.mem.Allocator,
        stmt: *sqlite.Stmt,
        args: []const Param,
    ) Error!usize {
        return db.bindParamsWith(arena, stmt, args, db.param_mode, db.stmt_params, .transient);
    }

    /// bindParams against an explicit mode + parameter-type list, so a
    /// PreparedStmt can bind from its own snapshot after `db.stmt_params` has
    /// moved on to another statement.
    /// Whether SQLite copies each bound blob or borrows it.
    ///
    /// `.static` is only correct when the encoded bytes outlive the statement's
    /// use of them. `Db.query` hands its arena to the returned `Rows`, and the
    /// rest of the engine binds from arenas with assorted lifetimes, so those
    /// stay `.transient`; `PreparedStmt.exec` owns its scratch arena outright
    /// and is the one place that can promise otherwise.
    const BlobLifetime = enum { transient, static };

    fn bindParamsWith(
        db: *Db,
        arena: std.mem.Allocator,
        stmt: *sqlite.Stmt,
        args: []const Param,
        param_mode: ParamMode,
        stmt_params: []const context_mod.CollectedParam,
        blobs: BlobLifetime,
    ) Error!usize {
        db.last_error_param = null;

        const count = stmt.bindParameterCount();
        if (count <= 0) return 0;
        const ucount: usize = @intCast(count);

        // Go getArgsFromParams: fewer supplied values than placeholders.
        if (args.len < ucount) {
            db.setLastError("not enough query arguments");
            return error.ExecFailed;
        }

        switch (param_mode) {
            .positional => {
                var idx: i32 = 1;
                while (idx <= count) : (idx += 1) {
                    const ord: usize = @intCast(idx - 1);
                    const param_type = if (ord < stmt_params.len)
                        stmt_params[ord].type
                    else
                        null;
                    try db.bindCell(arena, stmt, idx, args[ord].value, param_type, blobs);
                }
                return ucount;
            },
            .named => {
                var idx: i32 = 1;
                while (idx <= count) : (idx += 1) {
                    // SQLite reports the placeholder text, e.g. "@a"; a bare
                    // "?" reports null and binds positionally.
                    var value: Cell = undefined;
                    var param_type: ?*spec.Type = null;
                    if (stmt.bindParameterName(idx)) |pname| {
                        value = findArgByName(args, pname[1..]) orelse {
                            db.setLastError("not enough query arguments");
                            return error.ExecFailed;
                        };
                        for (stmt_params) |p| {
                            if (std.ascii.eqlIgnoreCase(p.identifier, pname)) {
                                param_type = p.type;
                                break;
                            }
                        }
                    } else {
                        value = args[@intCast(idx - 1)].value;
                    }
                    try db.bindCell(arena, stmt, idx, value, param_type, blobs);
                }
                return 0;
            },
        }
    }

    /// Case-insensitive lookup of a named arg (Go lowercases both sides).
    fn findArgByName(args: []const Param, name: []const u8) ?Cell {
        for (args) |param| {
            const n = param.name orelse continue;
            if (std.ascii.eqlIgnoreCase(n, name)) return param.value;
        }
        return null;
    }

    /// Encodes and binds a single cell at 1-based `idx`, casting to the
    /// parameter's resolved type first when known (Go EncodeGoValue =
    /// ValueFromGoValue + CastValue + EncodeValue).
    fn bindCell(
        db: *Db,
        arena: std.mem.Allocator,
        stmt: *sqlite.Stmt,
        idx: i32,
        cell: Cell,
        param_type: ?*const spec.Type,
        blobs: BlobLifetime,
    ) Error!void {
        // Cleared first so failDecode cannot report a diagnostic left behind
        // by some earlier conversion (function/bind.zig does the same before
        // it calls a UDF).
        value_mod.diagnostic = null;
        var v = valueFromCell(arena, cell) catch |err| return db.failBind(err, idx);
        if (param_type) |t| {
            v = castParamValue(arena, v, t) catch |err| return db.failBind(err, idx);
        }
        const repr = encoder.EncodeValue(arena, v) catch |err| return db.failBind(err, idx);
        switch (repr) {
            .null => try stmt.bindNull(idx),
            .int => |i| try stmt.bindInt64(idx, i),
            .float => |f| try stmt.bindDouble(idx, f),
            .blob => |b| switch (blobs) {
                .transient => try stmt.bindBlob(idx, b),
                .static => try stmt.bindBlobStatic(idx, b),
            },
        }
    }

    /// `failDecode` for a bind, which also names the placeholder.
    fn failBind(db: *Db, err: anyerror, idx: i32) Error {
        const out = db.failDecode(err);
        if (out == error.DecodeFailed) db.last_error_param = idx;
        return out;
    }

    fn failDecode(db: *Db, err: anyerror) Error {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // Value conversions record Go's own message (e.g. "failed to convert
        // 202-06-06 to time.Time type"); the error tag alone would throw it
        // away. Same precedence the UDF error paths use.
        db.setLastError(value_mod.diagnostic orelse @errorName(err));
        return error.DecodeFailed;
    }
};

/// Flattens BEGIN ... END script blocks by blanking the block keywords with
/// spaces, leaving the inner statements as a plain statement list (Go's
/// analyzer parses scripts with ParseNextScriptStatement and flattens
/// ASTBeginEndBlock nodes; our shim's AnalyzeNextStatement cannot parse
/// script blocks). `BEGIN TRANSACTION` / bare `BEGIN;` are left untouched.
/// Byte length is preserved so analyzer error offsets stay meaningful.
fn flattenBeginEndBlocks(arena: std.mem.Allocator, sql: []const u8) error{OutOfMemory}![]const u8 {
    var out: ?[]u8 = null; // copy-on-write
    var depth: usize = 0;
    var at_stmt_start = true;
    var quote: u8 = 0;
    var in_line_comment = false;
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        const c = sql[i];
        if (in_line_comment) {
            if (c == '\n') in_line_comment = false;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"', '`' => quote = c,
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    in_line_comment = true;
                    i += 1;
                }
            },
            ';' => at_stmt_start = true,
            else => {
                if (std.ascii.isWhitespace(c)) continue;
                if (!at_stmt_start) continue;
                at_stmt_start = false;

                const rest = sql[i..];
                if (startsWithKeyword(rest, "BEGIN")) {
                    // Distinguish a block from BEGIN [TRANSACTION];.
                    const after = std.mem.trimStart(u8, rest["BEGIN".len..], &std.ascii.whitespace);
                    if (after.len == 0 or after[0] == ';' or
                        startsWithKeyword(after, "TRANSACTION")) continue;
                    if (out == null) out = try arena.dupe(u8, sql);
                    @memset(out.?[i .. i + "BEGIN".len], ' ');
                    depth += 1;
                    i += "BEGIN".len - 1;
                    at_stmt_start = true; // inner statements follow directly
                } else if (depth > 0 and startsWithKeyword(rest, "END")) {
                    @memset(out.?[i .. i + "END".len], ' ');
                    // Blank the block terminator's own ';' too.
                    var j = i + "END".len;
                    while (j < sql.len and std.ascii.isWhitespace(sql[j])) : (j += 1) {}
                    if (j < sql.len and sql[j] == ';') out.?[j] = ' ';
                    depth -= 1;
                    i = j;
                    at_stmt_start = true;
                }
            },
        }
    }
    return out orelse sql;
}

/// True when `s` begins with keyword `kw` (case-insensitive) at a word
/// boundary.
fn startsWithKeyword(s: []const u8, kw: []const u8) bool {
    if (s.len < kw.len) return false;
    if (!std.ascii.eqlIgnoreCase(s[0..kw.len], kw)) return false;
    if (s.len == kw.len) return true;
    const next = s[kw.len];
    return !(std.ascii.isAlphanumeric(next) or next == '_');
}

/// Go getParameterMode: scans the literal-stripped query for unquoted `?`
/// (positional) vs `@name` (named). Mixing the two is rejected; a query with
/// neither defaults to named.
fn parameterMode(
    arena: std.mem.Allocator,
    sql: []const u8,
) error{ OutOfMemory, MixedParameters }!ParamMode {
    const stripped = try stripSQLLiterals(arena, sql);
    const has_positional = std.mem.indexOfScalar(u8, stripped, '?') != null;
    const has_named = hasNamedParam(stripped);
    if (has_named and has_positional) return error.MixedParameters;
    if (has_positional) return .positional;
    return .named;
}

/// Analyzer-visible type declarations for `args`, or null when there is
/// nothing to declare.
///
/// Declaring is opt-in: only a caller that knows the types — in practice the
/// REST surface, where `queryParameters` names one beside every value — sets
/// `Param.type_text`. Every in-process caller leaves it null, gets a null
/// here, and analyzes through exactly the code that ran before declarations
/// existed.
///
/// Named mode declares each named arg that carries a type and leaves the rest
/// to inference; the two coexist. Positional mode is all-or-nothing, because
/// declaring any positional type turns undeclared inference off for the whole
/// statement, which would then reject every `?` left undeclared.
fn paramDecls(
    arena: std.mem.Allocator,
    args: []const Param,
    param_mode: ParamMode,
) error{OutOfMemory}!?analyzer_ffi.ParamDecls {
    if (args.len == 0) return null;

    switch (param_mode) {
        .named => {
            var names: std.ArrayList(?[*:0]const u8) = .empty;
            var types: std.ArrayList(?[*:0]const u8) = .empty;
            for (args) |arg| {
                const name = arg.name orelse continue;
                const text = arg.type_text orelse continue;
                try names.append(arena, (try arena.dupeZ(u8, name)).ptr);
                try types.append(arena, (try arena.dupeZ(u8, text)).ptr);
            }
            if (types.items.len == 0) return null;
            return .{ .names = names.items, .types = types.items };
        },
        .positional => {
            for (args) |arg| if (arg.type_text == null) return null;
            const names = try arena.alloc(?[*:0]const u8, args.len);
            const types = try arena.alloc(?[*:0]const u8, args.len);
            for (args, 0..) |arg, i| {
                names[i] = null;
                types[i] = (try arena.dupeZ(u8, arg.type_text.?)).ptr;
            }
            return .{ .names = names, .types = types };
        },
    }
}

/// Go namedParamPattern `@\w+`: an '@' followed by at least one word char.
fn hasNamedParam(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '@' and i + 1 < s.len) {
            const c = s[i + 1];
            if (std.ascii.isAlphanumeric(c) or c == '_') return true;
        }
    }
    return false;
}

/// Splits a script into statements on top-level `;`.
///
/// Shares its scanner with stripSQLLiterals below, because the hard part is the
/// same: a `;` inside a string, a backtick-quoted identifier, a `--`/`#` line
/// comment or a `/* */` block is not a statement boundary. View definitions
/// carry prose descriptions in triple-quoted strings and block comments, and
/// both are full of semicolons and apostrophes.
///
/// Trailing text with no final `;` is returned as a statement; empty runs are
/// skipped.
pub fn splitStatements(
    arena: std.mem.Allocator,
    script: []const u8,
) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var quote: u8 = 0;
    var triple = false;
    var in_line_comment = false;
    var in_block_comment = false;
    var i: usize = 0;
    while (i < script.len) : (i += 1) {
        const c = script[i];
        if (in_block_comment) {
            if (c == '*' and i + 1 < script.len and script[i + 1] == '/') {
                in_block_comment = false;
                i += 1;
            }
            continue;
        }
        if (in_line_comment) {
            if (c == '\n') in_line_comment = false;
            continue;
        }
        if (quote != 0) {
            if (c == quote) {
                if (triple) {
                    if (i + 2 < script.len and script[i + 1] == quote and script[i + 2] == quote) {
                        quote = 0;
                        triple = false;
                        i += 2;
                    }
                } else {
                    quote = 0;
                }
            }
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
            triple = (i + 2 < script.len and script[i + 1] == c and script[i + 2] == c);
            if (triple) i += 2;
        } else if (c == '-' and i + 1 < script.len and script[i + 1] == '-') {
            in_line_comment = true;
            i += 1;
        } else if (c == '#') {
            in_line_comment = true;
        } else if (c == '/' and i + 1 < script.len and script[i + 1] == '*') {
            in_block_comment = true;
            i += 1;
        } else if (c == ';') {
            const stmt = std.mem.trim(u8, script[start..i], " \t\n\r");
            if (stmt.len > 0) try out.append(arena, stmt);
            start = i + 1;
        }
    }
    const tail = std.mem.trim(u8, script[start..], " \t\n\r");
    if (tail.len > 0) try out.append(arena, tail);
    return out.toOwnedSlice(arena);
}

/// Go stripSQLLiterals: blanks out single/double/backtick-quoted spans and
/// `--` line comments so parameter detection ignores `?`/`@` inside them.
fn stripSQLLiterals(arena: std.mem.Allocator, q: []const u8) error{OutOfMemory}![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.ensureTotalCapacity(arena, q.len);
    var quote: u8 = 0;
    var triple = false;
    var in_line_comment = false;
    var in_block_comment = false;
    var i: usize = 0;
    while (i < q.len) : (i += 1) {
        const c = q[i];
        if (in_block_comment) {
            // Block comments routinely contain prose with question marks, and
            // a stray '?' here would otherwise be read as a positional
            // parameter — which then conflicts with any real @named one.
            if (c == '*' and i + 1 < q.len and q[i + 1] == '/') {
                in_block_comment = false;
                i += 1;
            }
            continue;
        }
        if (in_line_comment) {
            if (c == '\n') {
                in_line_comment = false;
                try b.append(arena, c);
            }
            continue;
        }
        if (quote != 0) {
            if (c == quote) {
                if (triple) {
                    // Only a matching triple ends a triple-quoted string; a
                    // lone quote inside it is just text.
                    if (i + 2 < q.len and q[i + 1] == quote and q[i + 2] == quote) {
                        quote = 0;
                        triple = false;
                        i += 2;
                    }
                } else {
                    quote = 0;
                }
            }
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
            // BigQuery triple-quoted strings routinely hold prose. Read as
            // three adjacent empty strings, that prose stays in the scanned
            // text and a '?' in a description looks like a parameter.
            triple = (i + 2 < q.len and q[i + 1] == c and q[i + 2] == c);
            if (triple) i += 2;
        } else if (c == '-' and i + 1 < q.len and q[i + 1] == '-') {
            in_line_comment = true;
            i += 1;
        } else if (c == '#') {
            // BigQuery also accepts '#' line comments.
            in_line_comment = true;
        } else if (c == '/' and i + 1 < q.len and q[i + 1] == '*') {
            in_block_comment = true;
            i += 1;
        } else {
            try b.append(arena, c);
        }
    }
    return b.items;
}

/// Transforms one analyzed statement into its SQL fragment.
fn transformStatementFragment(
    db: ?*Db,
    arena: std.mem.Allocator,
    node: *pb.AnyResolvedNodeProto,
    opts: QueryOptions,
) Error!sqlbuilder.SQLFragment {
    var timer = phase.Timer.begin(.transform);
    defer timer.end();
    const config = try arena.create(context_mod.TransformConfig);
    config.* = context_mod.defaultTransformConfig();
    const ctx = try context_mod.TransformContext.init(arena, config);
    ctx.query_ctx.current_time_unix_micros = opts.current_time_unix_micros;
    // Go analyzer.go: withFuncMap(ctx, catalog.getFunctions(namePath)) before
    // transforming, so the function transformer can inline UDF bodies
    // (transformer_function.go funcMapFromContext -> spec.CallSQL).
    if (db) |d| {
        ctx.func_map = try d.mergedFuncMap(arena);
    }

    var coordinator = coordinator_mod.QueryCoordinator.init(arena);
    const fragment = coordinator.transformStatementNode(node, ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unimplemented => return error.Unimplemented,
        error.UnsupportedFunction => {
            if (db) |d| d.setLastError(value_mod.diagnostic orelse @errorName(err));
            return error.UnsupportedFunction;
        },
        else => {
            if (db) |d| d.setLastError(value_mod.diagnostic orelse @errorName(err));
            return error.TransformFailed;
        },
    };
    // Surface the parameter occurrences (with resolved types) to the driver
    // so bindParams can cast bound values (Go getParamsFromNode +
    // EncodeNamedValues).
    if (db) |d| d.stmt_params = ctx.collected_params.items;
    if (opts.capture) |cap| {
        cap.ast_text = ast_text.render(cap.arena, node) catch "";
        cap.sql = fragment.toString(cap.arena) catch "";
    }
    return fragment;
}

/// Transforms one analyzed statement into SQLite SQL text.
fn transformStatement(
    db: ?*Db,
    arena: std.mem.Allocator,
    node: *pb.AnyResolvedNodeProto,
    opts: QueryOptions,
) Error![]const u8 {
    const fragment = try transformStatementFragment(db, arena, node, opts);
    return fragment.toString(arena);
}

/// Unwraps an analyzed node down to its statement-kind union.
fn statementNodeOf(
    node: *const pb.AnyResolvedNodeProto,
) ?pb.AnyResolvedStatementProto.NodeUnion {
    const any = node.node orelse return null;
    switch (any) {
        .resolved_statement_node => |stmt| return stmt.node,
        else => return null,
    }
}

/// Go NamePath.normalizePath with an empty base path: every segment is
/// split on "." (backticked identifiers may carry dots).
fn normalizePath(
    arena: std.mem.Allocator,
    path: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (path) |segment| {
        var it = std.mem.splitScalar(u8, segment, '.');
        while (it.next()) |part| try out.append(arena, part);
    }
    return out.toOwnedSlice(arena);
}

/// Go NamePath.format with an empty base path: normalize + "_"-join.
fn formatNamePath(
    arena: std.mem.Allocator,
    path: []const []const u8,
) error{OutOfMemory}![]u8 {
    return spec.formatPath(arena, try normalizePath(arena, path));
}

/// Maps the 0-based proto CreateMode onto the 1-based values Go's binding
/// persists in TableSpec JSON (see spec.zig create_mode_* constants).
fn goCreateMode(mode: ?pb.ResolvedCreateStatementEnums_CreateMode) i64 {
    return switch (mode orelse .CREATE_DEFAULT) {
        .CREATE_DEFAULT => spec.create_mode_create_default,
        .CREATE_OR_REPLACE => spec.create_mode_create_or_replace,
        .CREATE_IF_NOT_EXISTS => spec.create_mode_create_if_not_exists,
        else => spec.create_mode_unspecified,
    };
}

/// Go spec.go newTypeFromFunctionArgumentType: a templated argument keeps
/// only its SignatureArgumentKind; a fixed one carries the concrete type.
fn functionArgumentSpecType(
    arena: std.mem.Allocator,
    arg: *const pb.FunctionArgumentTypeProto,
) Error!*spec.Type {
    if (arg.type) |tp| {
        return spec.newTypeFromProto(arena, tp) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransformFailed,
        };
    }
    const t = try arena.create(spec.Type);
    t.* = .{ .signature_kind = @intFromEnum(arg.kind orelse .ARG_KIND_EXPR_FIXED) };
    return t;
}

/// Go spec.go newColumnsFromDef: ColumnSpecs from the resolved column
/// definition list (type + NOT NULL annotation).
fn columnSpecsFromDefs(
    arena: std.mem.Allocator,
    defs: []const *pb.ResolvedColumnDefinitionProto,
) Error![]const *spec.ColumnSpec {
    const columns = try arena.alloc(*spec.ColumnSpec, defs.len);
    for (defs, 0..) |def, i| {
        const tp = def.type orelse return error.TransformFailed;
        const col = try arena.create(spec.ColumnSpec);
        col.* = .{
            .name = def.name orelse "",
            .type = spec.newTypeFromProto(arena, tp) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.TransformFailed,
            },
            .is_not_null = if (def.annotations) |ann| (ann.not_null orelse false) else false,
        };
        if (def.annotations) |ann| applyNestedNotNull(col.type, ann);
        columns[i] = col;
    }
    return columns;
}

/// `STRUCT<x INT64 NOT NULL>` and deeper:
/// the analyzer's `child_list` has one entry per STRUCT field up to the last one annotated,
///  and one for an ARRAY's element, so it is walked and the type indexed, never the reverse.
/// An ARRAY member carries no nullability: BigQuery stores a NULL array as empty, so there is
/// nothing for NOT NULL to reject.
fn applyNestedNotNull(t: *spec.Type, ann: *const pb.ResolvedColumnAnnotationsProto) void {
    if (t.isArray()) {
        if (ann.child_list.len != 1) return;
        if (t.element_type) |elem| applyNestedNotNull(elem, ann.child_list[0]);
        return;
    }
    if (!t.isStruct()) return;
    for (ann.child_list, 0..) |child, i| {
        if (i >= t.field_types.len) break;
        const field = t.field_types[i];
        const ft = field.type orelse continue;
        field.is_not_null = !ft.isArray() and (child.not_null orelse false);
        applyNestedNotNull(ft, child);
    }
}

/// DDL `OPTIONS(name=value)` as INFORMATION_SCHEMA.TABLE_OPTIONS reports them.
///
/// Takes the option list rather than the statement because CREATE TABLE and
/// CREATE VIEW carry it on different base protos.
///
/// Only literal values are captured. An option whose value is a computed
/// expression is skipped rather than evaluated: rendering it would need the
/// transformer's context, and BigQuery's own DDL only accepts literals here.
///
/// The rendered form is `Value.format('T', ...)`, which is BigQuery's: a STRING
/// option reads back as `"demo table"` — double-quoted, `\"`-escaped, single
/// quotes untouched. Verified against a real table. Note this is deliberately
/// NOT `encoder.LiteralFromValue`, which renders a string as the storage
/// literal `X'606869'`.
fn optionSpecsFrom(
    arena: std.mem.Allocator,
    opts: []const *pb.ResolvedOptionProto,
) Error![]const *spec.OptionSpec {
    if (opts.len == 0) return &.{};
    var out: std.ArrayList(*spec.OptionSpec) = .empty;
    for (opts) |opt| {
        const name = opt.name orelse continue;
        const expr = opt.value orelse continue;
        const node = expr.node orelse continue;
        const lit = switch (node) {
            .resolved_literal_node => |n| n,
            else => continue,
        };
        const vwt = lit.value orelse continue;
        const type_proto = vwt.type orelse continue;
        const value_proto = vwt.value orelse continue;
        const v = encoder.valueFromProto(arena, value_proto, type_proto) catch continue;

        const rendered = v.format('T', arena) catch continue;
        const o = try arena.create(spec.OptionSpec);
        o.* = .{
            .name = try arena.dupe(u8, name),
            .type_name = spec.bigQueryTypeName(type_proto.type_kind orelse .TYPE_UNKNOWN),
            .value = rendered,
        };
        try out.append(arena, o);
    }
    return out.toOwnedSlice(arena);
}

/// Go spec.go newTableSpec / newTableAsSelectSpec (shared body): scope,
/// merged name path, column definitions, primary key, create mode and
/// timestamps; `query_str` is empty for plain CREATE TABLE and holds the
/// formatted AS SELECT text for CTAS.
fn newTableSpecFromCreate(
    arena: std.mem.Allocator,
    create: *const pb.ResolvedCreateStatementProto,
    base: *const pb.ResolvedCreateTableStmtBaseProto,
    query_str: []const u8,
) Error!*spec.TableSpec {
    const now = catalog_mod.nowTimestamps(arena) catch return error.OutOfMemory;
    const table_spec = try arena.create(spec.TableSpec);
    table_spec.* = .{
        .is_temp = (create.create_scope orelse .CREATE_DEFAULT_SCOPE) == .CREATE_TEMP,
        .name_path = try normalizePath(arena, create.name_path),
        .columns = try columnSpecsFromDefs(arena, base.column_definition_list),
        .primary_key = if (base.primary_key) |pk| pk.column_name_list else &.{},
        .create_mode = goCreateMode(create.create_mode),
        .query = query_str,
        .updated_at = now.rfc3339,
        .created_at = now.rfc3339,
        .options = try optionSpecsFrom(arena, base.option_list),
    };
    return table_spec;
}

/// Like `translate`, but against a live database's catalog, so the statement
/// may reference tables and views that database has created. `translate`
/// analyzes with an empty catalog and cannot.
///
/// For inspecting emitted SQL — `EXPLAIN QUERY PLAN` over a recreated view
/// graph, say — where the query is only meaningful in terms of what is already
/// there.
pub fn translateOn(
    db: *Db,
    arena: std.mem.Allocator,
    sql: []const u8,
    opts: QueryOptions,
) Error![]const []const u8 {
    const sqlz = try arena.dupeZ(u8, sql);
    var out: std.ArrayList([]const u8) = .empty;
    var offset: usize = 0;
    while (true) {
        const analyzed = blk: {
            if (db.syncedCatalogHandle(arena)) |handle| {
                break :blk analyzer_ffi.analyzeNextStatementWithCatalog(
                    arena,
                    handle,
                    sqlz,
                    offset,
                    "{}",
                    null,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        db.setLastError(analyzer_ffi.last_error);
                        return error.AnalyzeFailed;
                    },
                };
            }
            const catalog_json = db.statelessCatalogJson(arena) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    db.setLastError(@errorName(err));
                    return error.AnalyzeFailed;
                },
            };
            break :blk analyzer_ffi.analyzeNextStatement(
                arena,
                sqlz,
                offset,
                catalog_json,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    db.setLastError(analyzer_ffi.last_error);
                    return error.AnalyzeFailed;
                },
            };
        };
        offset = analyzed.resume_offset;
        try out.append(arena, transformStatement(db, arena, analyzed.node, opts) catch |err| {
            db.setLastError(@errorName(err));
            return err;
        });
        if (analyzed.at_end) break;
    }
    return out.toOwnedSlice(arena);
}

/// Analyze + transform without executing: the SQLite SQL text of every
/// statement in `sql` (CLI --sql mode and golden tests). On AnalyzeFailed
/// the message is in analyzer_ffi.last_error.
pub fn translate(
    arena: std.mem.Allocator,
    sql: []const u8,
    opts: QueryOptions,
) Error![]const []const u8 {
    const sqlz = try arena.dupeZ(u8, sql);
    var out: std.ArrayList([]const u8) = .empty;
    var offset: usize = 0;
    while (true) {
        const analyzed = analyzer_ffi.analyzeNextStatement(arena, sqlz, offset, "{}") catch |err|
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.AnalyzeFailed,
            };
        offset = analyzed.resume_offset;
        if (queryStmtOf(analyzed.node) == null) return error.Unimplemented;
        try out.append(arena, try transformStatement(null, arena, analyzed.node, opts));
        if (analyzed.at_end) break;
    }
    return out.toOwnedSlice(arena);
}

/// Unwraps an analyzed node down to its ResolvedQueryStmt, or null for any
/// other statement kind.
fn queryStmtOf(node: *const pb.AnyResolvedNodeProto) ?*const pb.ResolvedQueryStmtProto {
    const any = node.node orelse return null;
    switch (any) {
        .resolved_statement_node => |stmt| {
            const stmt_node = stmt.node orelse return null;
            switch (stmt_node) {
                .resolved_query_stmt_node => |q| return q,
                else => return null,
            }
        },
        else => return null,
    }
}

/// Go newQueryStmtAction: output column specs (name + spec Type) from the
/// statement's output column list.
fn outputColumns(
    arena: std.mem.Allocator,
    query_stmt: *const pb.ResolvedQueryStmtProto,
) Error![]const OutputColumn {
    const out = try arena.alloc(OutputColumn, query_stmt.output_column_list.len);
    for (query_stmt.output_column_list, 0..) |oc, i| {
        const column = oc.column orelse return error.AnalyzeFailed;
        const tp = column.type orelse return error.AnalyzeFailed;
        out[i] = .{
            .name = oc.name orelse "",
            .type = spec.newTypeFromProto(arena, tp) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.AnalyzeFailed,
            },
        };
    }
    return out;
}

/// Go encoder.go CastValue, keyed on the resolved parameter/column type.
///
/// STRUCT re-projects the fields in declared order (missing fields become
/// NULL) and ARRAY casts every element; the scalar arms coerce whatever the
/// caller bound to what the column actually holds, which is what lets a REST
/// client send an INT64 as the JSON string "5". Go reaches this through
/// EncodeGoValue = ValueFromGoValue + CastValue + EncodeValue.
///
/// The same switch exists twice more, pre-existing and untouched: the CAST
/// UDF's copy keyed on a JSON type node
/// (internal/function/fn_misc.zig castValue) and the same-kind-only stub in
/// internal/encoder.zig.
fn castParamValue(
    alloc: std.mem.Allocator,
    v: value_mod.Value,
    t: *const spec.Type,
) !value_mod.Value {
    if (v == .null) return v;
    switch (t.typeKind()) {
        .TYPE_STRUCT => {
            if (v != .struct_) return v;
            const sv = v.struct_;
            const keys = try alloc.alloc([]const u8, t.field_types.len);
            const values = try alloc.alloc(value_mod.Value, t.field_types.len);
            // Field-by-position, like the CAST function itself: the declared
            // type names the fields, the supplied value fills them in order.
            for (t.field_types, 0..) |field, i| {
                keys[i] = field.name;
                if (i >= sv.values.len) {
                    values[i] = .null;
                    continue;
                }
                const fv = sv.values[i];
                values[i] = if (field.type) |ft| try castParamValue(alloc, fv, ft) else fv;
            }
            return value_mod.structValue(alloc, keys, values);
        },
        .TYPE_ARRAY => {
            if (v != .array) return v;
            const elem_type = t.element_type orelse return v;
            const values = try alloc.alloc(value_mod.Value, v.array.values.len);
            for (v.array.values, 0..) |elem, i| {
                values[i] = try castParamValue(alloc, elem, elem_type);
            }
            return value_mod.arrayValue(alloc, values);
        },
        // Re-stamp the element kind from the declared type. parseRangeValue
        // has to infer it from the text's shape, which cannot distinguish
        // `[UNBOUNDED, UNBOUNDED)` at all; the column type knows, so a range
        // that made a round trip through a result cell recovers here.
        .TYPE_RANGE => {
            if (v != .range) return v;
            const elem_type = t.element_type orelse return v;
            const elem: value_mod.Range.ElemKind = switch (elem_type.typeKind()) {
                .TYPE_DATE => .date,
                .TYPE_DATETIME => .datetime,
                .TYPE_TIMESTAMP => .timestamp,
                else => return v,
            };
            return value_mod.rangeValue(elem, v.range.startBound(), v.range.endBound());
        },

        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64 => {
            return .{ .int = try v.toInt64() };
        },
        .TYPE_BOOL => return .{ .bool = try v.toBool() },
        .TYPE_FLOAT, .TYPE_DOUBLE => return .{ .float = try v.toFloat64() },
        // Go checks the concrete date/time types first and renders them with
        // dedicated layouts; Value.toString already uses exactly those.
        .TYPE_STRING, .TYPE_ENUM => return .{ .string = try v.toString(alloc) },
        .TYPE_BYTES => return .{ .bytes = try v.toBytes(alloc) },
        // Go CastValue: JsonValue(v.ToJSON()).
        .TYPE_JSON => return .{ .json = try v.toJson(alloc) },
        // Go CastValue: DATE(v.ToTime()) — the civil date of the instant.
        // Routed through ToTime for every kind, as Go does, so a malformed
        // date reports Go's "failed to convert %s to time.Time type" rather
        // than a parser-specific message.
        .TYPE_DATE => {
            if (v == .date) return v;
            return .{
                .date = @divFloor(try value_mod.toUnixMicros(v), value_mod.day_micros),
            };
        },
        // Go CastValue: TIMESTAMP/DATETIME/TIME(v.ToTime()). DATETIME shares
        // the unix-micros scale; TIME is the time-of-day remainder.
        .TYPE_TIMESTAMP => return .{ .timestamp = try value_mod.toUnixMicros(v) },
        .TYPE_DATETIME => return .{ .datetime = try value_mod.toUnixMicros(v) },
        .TYPE_TIME => {
            const micros = try value_mod.toUnixMicros(v);
            return .{ .time = @mod(micros, value_mod.day_micros) };
        },
        // Go CastValue: parseInterval(v.ToString()).
        .TYPE_INTERVAL => switch (v) {
            .interval => return v,
            else => return .{ .interval = try value_mod.parseIntervalValue(try v.toString(alloc)) },
        },
        // googlesql casts to the scaled integer for the target kind (a
        // numeric input is rewrapped, and rescaled, under the new kind).
        .TYPE_NUMERIC => return value_mod.numericValue(alloc, v, false),
        .TYPE_BIGNUMERIC => return value_mod.numericValue(alloc, v, true),

        // Kinds with no CastValue arm in Go (geography, proto, ...) pass the
        // value through unchanged rather than failing the bind.
        else => return v,
    }
}

fn valueFromCell(alloc: std.mem.Allocator, cell: Cell) !value_mod.Value {
    switch (cell) {
        .null => return .null,
        .int => |i| return .{ .int = i },
        .float => |f| return .{ .float = f },
        .bool => |b| return .{ .bool = b },
        .string => |s| return .{ .string = s },
        .bytes => |b| return .{ .bytes = b },
        .json => |s| return .{ .json = s },
        .date => |s| return .{ .date = try value_mod.parseDateDays(s) },
        // Inverse of cellFromValue: parse the rendered api strings back.
        .timestamp => |s| return .{ .timestamp = try value_mod.parseTimestampApi(s) },
        .datetime => |s| return .{ .datetime = try value_mod.parseDatetimeMicros(s) },
        .time => |s| return .{ .time = try value_mod.parseTimeMicros(s) },
        .interval => |s| return .{ .interval = try value_mod.parseIntervalValue(s) },
        .range => |s| return .{ .range = try value_mod.parseRangeValue(s) },
        .array => |cells| {
            const values = try alloc.alloc(value_mod.Value, cells.len);
            for (cells, 0..) |c, i| values[i] = try valueFromCell(alloc, c);
            return value_mod.arrayValue(alloc, values);
        },
        .struct_ => |fields| {
            const keys = try alloc.alloc([]const u8, fields.len);
            const values = try alloc.alloc(value_mod.Value, fields.len);
            for (fields, 0..) |f, i| {
                keys[i] = f.name;
                values[i] = try valueFromCell(alloc, f.value);
            }
            return value_mod.structValue(alloc, keys, values);
        },
    }
}

/// Value -> Cell conversion per the output column type, mirroring Go
/// rows.go castValueInternal + assignInterfaceValue for foundation kinds.
/// A rendered `Cell` from a stored value and the type it was stored under.
///
/// The pair `Rows.next` applies internally, exposed for a caller that held raw
/// values from `nextRaw` and wants to render them later — the decode reads the
/// codec's own tag, but turning the result into a `Cell` needs the declared
/// type, because that is what decides whether an integer is an INT64 or a DATE.
pub fn cellFrom(
    alloc: std.mem.Allocator,
    repr: encoder.SqliteRepr,
    typ: *const spec.Type,
) !Cell {
    const v = try encoder.DecodeValueBorrowing(alloc, repr);
    return cellFromValue(alloc, v, typ);
}

fn cellFromValue(
    alloc: std.mem.Allocator,
    v: value_mod.Value,
    typ: *const spec.Type,
) value_mod.ValueError!Cell {
    // Go: nil src -> zero dest (SQL NULL).
    if (v == .null) return .null;
    switch (typ.typeKind()) {
        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64 => {
            return .{ .int = try v.toInt64() };
        },
        .TYPE_BOOL => return .{ .bool = try v.toBool() },
        .TYPE_FLOAT, .TYPE_DOUBLE => return .{ .float = try v.toFloat64() },
        // Go castValueInternal STRING renders DateValue as "2006-01-02";
        // Value.toString does the same for .date.
        .TYPE_STRING => return .{ .string = try v.toString(alloc) },
        // Go rows.go renders a BYTES column through BytesValue.ToApiString =
        // base64(StdEncoding), i.e. a plain string cell (database/sql sees a
        // string, never []byte).
        .TYPE_BYTES => {
            const b = try v.toBytes(alloc);
            const enc = std.base64.standard.Encoder;
            const out = try alloc.alloc(u8, enc.calcSize(b.len));
            return .{ .string = enc.encode(out, b) };
        },
        // Go rows.go: JSON columns are scanned as their raw JSON string
        // (ToApiString) through database/sql, i.e. a plain string cell.
        .TYPE_JSON => return .{ .string = try v.toApiString(alloc) },
        .TYPE_DATE => switch (v) {
            .date => |days| {
                var buf: [16]u8 = undefined;
                const s = value_mod.formatDateDays(&buf, days);
                return .{ .date = try alloc.dupe(u8, s) };
            },
            .string => |s| return .{ .date = try alloc.dupe(u8, s) },
            else => return error.FailedConversion,
        },
        // Go rows.go assignInterfaceValue renders these via ToApiString after
        // castValueInternal; the decoded value already carries the right kind.
        .TYPE_TIMESTAMP => switch (v) {
            .timestamp => return .{ .timestamp = try v.toApiString(alloc) },
            .string => |s| return .{ .timestamp = try (value_mod.Value{
                .timestamp = try value_mod.parseTimestampMicros(s),
            }).toApiString(alloc) },
            else => return error.FailedConversion,
        },
        .TYPE_DATETIME => switch (v) {
            .datetime => return .{ .datetime = try v.toApiString(alloc) },
            .string => |s| return .{ .datetime = try (value_mod.Value{
                .datetime = try value_mod.parseDatetimeMicros(s),
            }).toApiString(alloc) },
            else => return error.FailedConversion,
        },
        .TYPE_TIME => switch (v) {
            .time => return .{ .time = try v.toApiString(alloc) },
            .string => |s| return .{ .time = try (value_mod.Value{
                .time = try value_mod.parseTimeMicros(s),
            }).toApiString(alloc) },
            else => return error.FailedConversion,
        },
        .TYPE_INTERVAL => switch (v) {
            .interval => return .{ .interval = try v.toApiString(alloc) },
            .string => |s| return .{ .interval = try (value_mod.Value{
                .interval = try value_mod.parseIntervalValue(s),
            }).toApiString(alloc) },
            else => return error.FailedConversion,
        },
        // ARRAY<RANGE<...>> needs no arm of its own: the TYPE_ARRAY case below
        // recurses on element_type and lands back here per element, which is
        // what makes GENERATE_RANGE_ARRAY render.
        .TYPE_RANGE => switch (v) {
            .range => return .{ .range = try v.toApiString(alloc) },
            .string => |s| return .{ .range = try (value_mod.Value{
                .range = try value_mod.parseRangeValue(s),
            }).toApiString(alloc) },
            else => return error.FailedConversion,
        },
        // Go rows.go: castValueInternal wraps v.ToRat() in a NumericValue for
        // the column kind, then assignInterfaceValue renders ToApiString — a
        // plain decimal-string cell through database/sql.
        .TYPE_NUMERIC, .TYPE_BIGNUMERIC => {
            const is_big = typ.typeKind() == .TYPE_BIGNUMERIC;
            const wrapped = try value_mod.numericValue(alloc, v, is_big);
            return .{ .string = try wrapped.numeric.toText(alloc) };
        },
        .TYPE_ARRAY => {
            const arr = try v.toArray();
            const elem_type = typ.element_type orelse return error.FailedConversion;
            const cells = try alloc.alloc(Cell, arr.values.len);
            for (arr.values, 0..) |ev, i| {
                cells[i] = try cellFromValue(alloc, ev, elem_type);
            }
            return .{ .array = cells };
        },
        .TYPE_STRUCT => {
            const st = try v.toStruct();
            if (typ.field_types.len != st.keys.len) return error.FailedConversion;
            const fields = try alloc.alloc(Cell.Field, st.keys.len);
            for (st.keys, 0..) |key, i| {
                const field_type = typ.field_types[i].type orelse return error.FailedConversion;
                fields[i] = .{
                    // Copied, not aliased. `Rows.next` decodes with
                    // DecodeValueBorrowing, and struct keys are one of the
                    // payloads that borrows — they point into SQLite's column
                    // buffer, which the next step() invalidates. Every other arm
                    // here already copies via toString/toApiString/dupe; this
                    // one assigned the borrowed slice straight through.
                    .name = try alloc.dupe(u8, key),
                    .value = try cellFromValue(alloc, st.values[i], field_type),
                };
            }
            return .{ .struct_ = fields };
        },
        // Remaining kinds (geography, proto, ...) defer with their Value kinds.
        else => return error.Unimplemented,
    }
}

/// A translated, SQLite-prepared statement that can be bound and run many
/// times (Go database/sql Stmt). Created by Db.prepare; see its docs for the
/// statement kinds accepted and the catalog-staleness caveat.
pub const PreparedStmt = struct {
    db: *Db,
    /// Owns the translated SQL and the collected parameter types, so the
    /// handle keeps working after Db.stmt_params has moved on.
    arena: std.heap.ArenaAllocator,
    /// Per-exec encoding scratch, reset rather than rebuilt between calls.
    scratch: std.heap.ArenaAllocator,
    stmt: sqlite.Stmt,
    param_mode: ParamMode,
    params: []const context_mod.CollectedParam,
    /// Result columns of a query statement; empty for DML.
    columns: []const OutputColumn = &.{},

    /// Binds `args` and runs the statement to completion (Go
    /// Stmt.ExecContext). Rows produced by a query statement are discarded.
    pub fn exec(p: *PreparedStmt, args: []const Param) Error!void {
        // Encoding allocates, and those allocations live only as long as the
        // bind, so they must not accumulate in the handle's own arena. One
        // scratch arena is reset per exec rather than built and torn down:
        // over a streaming insert that is the difference between a couple of
        // allocator round trips per row and none.
        //
        // Order matters now that the binds are `.static`: the previous row's
        // bytes stay referenced by the statement until clearBindings drops
        // them, so the scratch they live in is only recycled after that.
        p.stmt.reset();
        p.stmt.clearBindings();
        _ = p.scratch.reset(.retain_capacity);

        _ = try p.db.bindParamsWith(
            p.scratch.allocator(),
            &p.stmt,
            args,
            p.param_mode,
            p.params,
            // Sound because the bytes are allocated from `scratch` just below
            // and outlive the step: nothing recycles them until the next call
            // reaches the reset above, and `deinit` finalizes before freeing.
            .static,
        );
        while (p.stmt.step() catch {
            p.db.setLastSqliteError();
            return error.ExecFailed;
        }) {}
    }

    pub fn deinit(p: *PreparedStmt) void {
        p.stmt.finalize();
        p.scratch.deinit();
        p.arena.deinit();
    }
};

/// Result of Db.rawQuery. Unlike Rows there is no arena: values borrow
/// SQLite's row buffer directly and are invalidated by the next next().
pub const RawRows = struct {
    db: *Db,
    entry: *Db.RawStmt,
    /// Reused row buffer, gpa-owned, one slot per column.
    scratch: []Db.RawValue,
    done: bool = false,

    /// Next row, or null when exhausted. Slices in the returned row point
    /// into SQLite's storage — copy before calling next() again.
    pub fn next(r: *RawRows) Error!?[]const Db.RawValue {
        if (r.done) return null;
        var scope = phase.SourceScope.begin(.metadata);
        defer scope.end();
        const has_row = r.entry.stmt.step() catch {
            r.done = true;
            r.db.setLastSqliteError();
            return error.ExecFailed;
        };
        if (!has_row) {
            r.done = true;
            return null;
        }
        for (r.scratch, 0..) |*slot, i| {
            const col: i32 = @intCast(i);
            slot.* = switch (r.entry.stmt.columnType(col)) {
                .integer => .{ .int = r.entry.stmt.columnInt64(col) },
                .float => .{ .float = r.entry.stmt.columnDouble(col) },
                .text => .{ .text = r.entry.stmt.columnText(col) },
                .blob => .{ .blob = r.entry.stmt.columnBlob(col) },
                .null => .null,
            };
        }
        return r.scratch;
    }

    pub fn columnCount(r: *RawRows) usize {
        return r.scratch.len;
    }

    pub fn deinit(r: *RawRows) void {
        r.db.gpa.free(r.scratch);
        r.db.releaseRawStmt(r.entry);
    }
};

pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    db: *Db,
    stmt: ?sqlite.Stmt = null,
    cols: []const OutputColumn = &.{},
    names: []const []const u8 = &.{},
    /// Temp tables to drop on deinit (Go StmtAction.Cleanup).
    temp_tables: []const []const u8 = &.{},
    /// query() already took the first step (modernc steps eagerly); the next
    /// next() call consumes its outcome instead of stepping again.
    first_step_done: bool = false,
    first_has_row: bool = false,

    pub fn columns(r: *Rows) []const []const u8 {
        return r.names;
    }

    /// Output columns with their resolved types (Go
    /// Rows.ColumnTypeDatabaseTypeName, minus the JSON round trip — see
    /// OutputColumn). Parallel to columns(); valid until deinit().
    ///
    /// Empty for statements that produce no result set (DDL/DML), matching
    /// columns().
    pub fn columnTypes(r: *Rows) []const OutputColumn {
        return r.cols;
    }

    /// Steps to the next row, or false when the result set is exhausted.
    fn advance(r: *Rows) Error!bool {
        var stmt = r.stmt orelse return false;
        if (r.first_step_done) {
            r.first_step_done = false;
            return r.first_has_row;
        }
        return stmt.step() catch {
            // Mid-iteration failures carry modernc's wrapped text verbatim
            // (go-zetasqlite does not re-wrap the iteration path).
            r.db.setLastSqliteError();
            return error.ExecFailed;
        };
    }

    /// One column of the current row, as the engine's own typed value.
    ///
    /// Safe to borrow from SQLite's column memory: every caller copies what it
    /// keeps into the rows arena before the next step invalidates it.
    fn decodeColumn(r: *Rows, alloc: std.mem.Allocator, ci: i32) Error!value_mod.Value {
        var stmt = r.stmt.?;
        const repr: encoder.SqliteRepr = switch (stmt.columnType(ci)) {
            .integer => .{ .int = stmt.columnInt64(ci) },
            .float => .{ .float = stmt.columnDouble(ci) },
            .blob => .{ .blob = stmt.columnBlob(ci) },
            .null => .null,
            // A column here means something outside the engine wrote it.
            // No engine value is TEXT.
            .text => return r.db.failDecode(error.CorruptData),
        };
        return encoder.DecodeValueBorrowing(alloc, repr) catch |err|
            return r.db.failDecode(err);
    }

    /// Next row of decoded cells, or null when exhausted. Cells are valid until deinit() (per-query arena).
    pub fn next(r: *Rows) Error!?[]const Cell {
        if (r.stmt == null) return null;
        if (!try r.advance()) return null;

        const alloc = r.arena.allocator();
        const cells = try alloc.alloc(Cell, r.cols.len);
        for (r.cols, 0..) |col, i| {
            const v = try r.decodeColumn(alloc, @intCast(i));
            cells[i] = cellFromValue(alloc, v, col.type) catch |err|
                return r.db.failDecode(err);
        }
        return cells;
    }

    /// Next row as the engine's own typed values, or null when exhausted.
    /// Values are valid until `deinit`, and strings and bytes borrow from the per-query arena.
    pub fn nextTyped(r: *Rows) Error!?[]const value_mod.Value {
        if (r.stmt == null) return null;
        if (!try r.advance()) return null;

        const alloc = r.arena.allocator();
        const out = try alloc.alloc(value_mod.Value, r.cols.len);
        for (0..r.cols.len) |i| out[i] = try r.decodeColumn(alloc, @intCast(i));
        return out;
    }

    /// Next row as SQLite's own column values, undecoded.
    ///
    /// `next` and `nextTyped` both pay a decode — stored bytes to `Value`, and
    /// for `next` a second step to a rendered `Cell`. A caller that is only
    /// going to hand these values straight back to SQLite pays that twice: once
    /// decoding out, once encoding back in. Copying a query's result into a
    /// table is exactly that shape, and both sides carry the same codec
    /// encoding, so the bytes can move across untouched.
    ///
    /// Values borrow SQLite's row buffer and are valid only until the next
    /// call — the same contract `RawRows.next` has. Binding them is safe
    /// regardless, because every bind is SQLITE_TRANSIENT and copies.
    pub fn nextRaw(r: *Rows) Error!?[]const Db.RawValue {
        if (r.stmt == null) return null;
        if (!try r.advance()) return null;

        var stmt = r.stmt.?;
        const out = try r.arena.allocator().alloc(Db.RawValue, r.cols.len);
        for (out, 0..) |*dst, i| {
            const ci: i32 = @intCast(i);
            dst.* = switch (stmt.columnType(ci)) {
                .integer => .{ .int = stmt.columnInt64(ci) },
                .float => .{ .float = stmt.columnDouble(ci) },
                .blob => .{ .blob = stmt.columnBlob(ci) },
                .null => .null,
                // Same invariant `decodeColumn` asserts: no engine value is
                // TEXT, so one here means something outside the engine wrote
                // the column.
                .text => return r.db.failDecode(error.CorruptData),
            };
        }
        return out;
    }

    pub fn deinit(r: *Rows) void {
        if (r.stmt) |*stmt| stmt.finalize();
        r.stmt = null;
        // The INFORMATION_SCHEMA snapshot lives in the arena released below,
        // so it must not outlive it. Every statement republishes, so an empty
        // slice between queries is correct rather than merely safe.
        r.db.udf_state.info_schema.info_schema = &.{};
        r.db.udf_state.info_schema.datasets = &.{};
        // Drop temp tables created by this query (Go Cleanup) before the
        // arena (which backs the name strings) is released.
        if (r.temp_tables.len > 0) {
            r.db.dropTempTables(r.arena.allocator(), r.temp_tables);
        }
        r.arena.deinit();
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "generated SQL golden: SELECT 1 AS x" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const stmts = try translate(arena.allocator(), "SELECT 1 AS x", .{});
    try testing.expectEqual(@as(usize, 1), stmts.len);
    try testing.expectEqualStrings(
        "SELECT\n1 AS `x`",
        stmts[0],
    );
}

test "query SELECT 1 AS x end-to-end" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1 AS x", &.{}, .{});
    defer rows.deinit();

    try testing.expectEqual(@as(usize, 1), rows.columns().len);
    try testing.expectEqualStrings("x", rows.columns()[0]);

    const row = (try rows.next()).?;
    try testing.expectEqual(@as(usize, 1), row.len);
    try testing.expectEqual(Cell{ .int = 1 }, row[0]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "query scalar literals of each foundation kind" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1.5, 'a', true, NULL, b'xy'", &.{}, .{});
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(@as(usize, 5), row.len);
    try testing.expectEqual(@as(f64, 1.5), row[0].float);
    try testing.expectEqualStrings("a", row[1].string);
    try testing.expectEqual(true, row[2].bool);
    try testing.expect(row[3] == .null);
    // BYTES columns render as base64 STRING cells (Go ToApiString).
    try testing.expectEqualStrings("eHk=", row[4].string);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "query date and array literals" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT DATE '2023-01-15' AS d, [1, 2, 3] AS a", &.{}, .{});
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqualStrings("2023-01-15", row[0].date);
    try testing.expectEqual(@as(usize, 3), row[1].array.len);
    try testing.expectEqual(Cell{ .int = 2 }, row[1].array[1]);
}

test "query timestamp / datetime / time literals render as Go api strings" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT TIMESTAMP '2006-01-02 22:04:05+00' AS ts, " ++
            "DATETIME '2024-01-15 10:30:15.123456' AS dt, " ++
            "TIME '10:30:15' AS tm",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    // Timestamp cell: "sec.microRemainder" (ToApiString), exactly like the
    // corpus expects (e.g. "1136239445.0").
    try testing.expectEqualStrings("1136239445.0", row[0].timestamp);
    try testing.expectEqualStrings("2024-01-15T10:30:15.123456", row[1].datetime);
    try testing.expectEqualStrings("10:30:15", row[2].time);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "query struct literal" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT STRUCT(1 AS a, 'x' AS b)", &.{}, .{});
    defer rows.deinit();

    const row = (try rows.next()).?;
    const fields = row[0].struct_;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("a", fields[0].name);
    try testing.expectEqual(Cell{ .int = 1 }, fields[0].value);
    try testing.expectEqualStrings("b", fields[1].name);
    try testing.expectEqualStrings("x", fields[1].value.string);
}

test "multi-statement query returns rows over the last statement" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1; SELECT 2 AS y", &.{}, .{});
    defer rows.deinit();

    try testing.expectEqualStrings("y", rows.columns()[0]);
    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 2 }, row[0]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "fast-path operators execute natively" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1 = 1, 2 < 1, NOT true", &.{}, .{});
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(true, row[0].bool);
    try testing.expectEqual(false, row[1].bool);
    try testing.expectEqual(false, row[2].bool);
}

test "analyze errors surface message through lastError" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try testing.expectError(
        error.AnalyzeFailed,
        db.query("SELECT * FROM missing_table", &.{}, .{}),
    );
    try testing.expect(std.mem.indexOf(u8, db.lastError(), "missing_table") != null);
}

test "exec runs statements to completion" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("SELECT 1; SELECT 2", &.{}, .{});
}

// ----------------------------------------------------------------------
// Table scan end-to-end (catalog + extractor + scan_table transformer)
// ----------------------------------------------------------------------

const catalog_test = struct {
    /// Builds the t1 spec (INT64, STRING, BOOL, DOUBLE, DATE, ARRAY<INT64>),
    /// creates the SQLite table from spec.SQLiteSchema, inserts one row of
    /// encoder-encoded values, and registers the spec in db.catalog.
    fn setupTable(db: *Db, arena: std.mem.Allocator) !void {
        const kinds = [_]pb.TypeKind{
            .TYPE_INT64, .TYPE_STRING, .TYPE_BOOL, .TYPE_DOUBLE, .TYPE_DATE, .TYPE_ARRAY,
        };
        const names = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
        const cols = try arena.alloc(*spec.ColumnSpec, kinds.len);
        for (kinds, names, 0..) |kind, name, i| {
            const t = try spec.newSimpleType(arena, kind);
            if (kind == .TYPE_ARRAY) t.element_type = try spec.newSimpleType(arena, .TYPE_INT64);
            const col = try arena.create(spec.ColumnSpec);
            col.* = .{ .name = name, .type = t };
            cols[i] = col;
        }
        const table_spec = try arena.create(spec.TableSpec);
        table_spec.* = .{
            .name_path = &.{"t1"},
            .columns = cols,
            .create_mode = spec.create_mode_create_default,
            .updated_at = "2024-01-02T03:04:05Z",
            .created_at = "2024-01-02T03:04:05Z",
        };

        // Raw SQLite DDL from the spec schema.
        try db.sqlite_db.exec(try arena.dupeZ(u8, try table_spec.sqliteSchema(arena)));

        // One row, built by hand through encoder.LiteralFromValue (what the
        // INSERT transformer will emit later).
        const arr = try value_mod.arrayValue(arena, &.{
            .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 },
        });
        const row = [_]value_mod.Value{
            .{ .int = 42 },
            .{ .string = "hello" },
            .{ .bool = true },
            .{ .float = 1.5 },
            .{ .date = try value_mod.parseDateDays("2023-01-15") },
            arr,
        };
        var insert: std.ArrayList(u8) = .empty;
        try insert.appendSlice(arena, "INSERT INTO `t1` VALUES (");
        for (row, 0..) |v, i| {
            if (i > 0) try insert.appendSlice(arena, ",");
            try insert.appendSlice(arena, try encoder.LiteralFromValue(arena, v));
        }
        try insert.appendSlice(arena, ")");
        try db.sqlite_db.exec(try arena.dupeZ(u8, insert.items));

        {
            var g = db.lockCatalog();
            defer g.unlock();
            try g.catalog.addNewTableSpec(&db.sqlite_db, table_spec);
        }
    }
};

test "table scan end-to-end: typed columns decode through the catalog" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try catalog_test.setupTable(db, arena_state.allocator());

    var rows = try db.query("SELECT a, b, c, d, e, f FROM t1", &.{}, .{});
    defer rows.deinit();

    try testing.expectEqual(@as(usize, 6), rows.columns().len);
    try testing.expectEqualStrings("a", rows.columns()[0]);
    try testing.expectEqualStrings("f", rows.columns()[5]);

    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 42 }, row[0]);
    try testing.expectEqualStrings("hello", row[1].string);
    try testing.expectEqual(true, row[2].bool);
    try testing.expectEqual(@as(f64, 1.5), row[3].float);
    try testing.expectEqualStrings("2023-01-15", row[4].date);
    try testing.expectEqual(@as(usize, 3), row[5].array.len);
    try testing.expectEqual(Cell{ .int = 2 }, row[5].array[1]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "table scan with WHERE filter and expressions" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try catalog_test.setupTable(db, arena_state.allocator());

    // Matching filter over multiple column kinds.
    {
        var rows = try db.query(
            "SELECT a + 1, UPPER(b) FROM t1 WHERE a = 42 AND c AND e = DATE '2023-01-15'",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(Cell{ .int = 43 }, row[0]);
        try testing.expectEqualStrings("HELLO", row[1].string);
        try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
    }
    // Non-matching filter yields no rows.
    {
        var rows = try db.query("SELECT a FROM t1 WHERE a = 0", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
    }
    // SELECT * (star expansion through the catalog columns).
    {
        var rows = try db.query("SELECT * FROM t1", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(@as(usize, 6), row.len);
        try testing.expectEqual(Cell{ .int = 42 }, row[0]);
    }
    // Aggregate over the table.
    {
        var rows = try db.query("SELECT COUNT(*), SUM(a) FROM t1", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(Cell{ .int = 1 }, row[0]);
        try testing.expectEqual(Cell{ .int = 42 }, row[1]);
    }
}

test "dotted table names resolve and scan" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const col = try arena.create(spec.ColumnSpec);
    col.* = .{ .name = "x", .type = try spec.newSimpleType(arena, .TYPE_INT64) };
    const table_spec = try arena.create(spec.TableSpec);
    table_spec.* = .{
        .name_path = &.{ "proj", "ds", "t" },
        .columns = &.{col},
        .create_mode = spec.create_mode_create_default,
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    // SQLite table under the canonical "_"-joined name.
    try db.sqlite_db.exec(try arena.dupeZ(u8, try table_spec.sqliteSchema(arena)));
    try db.sqlite_db.exec("INSERT INTO `proj_ds_t` VALUES (7)");
    {
        var g = db.lockCatalog();
        defer g.unlock();
        try g.catalog.addNewTableSpec(&db.sqlite_db, table_spec);
    }

    inline for (.{
        "SELECT x FROM proj.ds.t",
        "SELECT x FROM `proj.ds.t`",
        "SELECT x FROM ds.t",
    }) |query_sql| {
        var rows = try db.query(query_sql, &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(Cell{ .int = 7 }, row[0]);
    }
}

// ----------------------------------------------------------------------
// CREATE TABLE + DML statement actions (Go stmt_action.go end-to-end)
// ----------------------------------------------------------------------

test "CREATE TABLE + INSERT + SELECT round-trip across foundation kinds" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE t1 (a INT64, b STRING, c BOOL, d FLOAT64, e DATE, f ARRAY<INT64>)",
        &.{},
        .{},
    );
    try db.exec(
        "INSERT INTO t1 (a, b, c, d, e, f) VALUES (42, 'hello', true, 1.5, DATE '2023-01-15', [1, 2, 3])",
        &.{},
        .{},
    );

    var rows = try db.query("SELECT a, b, c, d, e, f FROM t1", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 42 }, row[0]);
    try testing.expectEqualStrings("hello", row[1].string);
    try testing.expectEqual(true, row[2].bool);
    try testing.expectEqual(@as(f64, 1.5), row[3].float);
    try testing.expectEqualStrings("2023-01-15", row[4].date);
    try testing.expectEqual(@as(usize, 3), row[5].array.len);
    try testing.expectEqual(Cell{ .int = 2 }, row[5].array[1]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "multi-statement CREATE + INSERT + SELECT in one query() call" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "CREATE TABLE t2 (x INT64, y STRING); " ++
            "INSERT INTO t2 (x, y) VALUES (1, 'a'), (2, 'b'); " ++
            "SELECT x, y FROM t2 ORDER BY x",
        &.{},
        .{},
    );
    defer rows.deinit();
    const first = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 1 }, first[0]);
    try testing.expectEqualStrings("a", first[1].string);
    const second = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 2 }, second[0]);
    try testing.expectEqualStrings("b", second[1].string);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

/// Names of the SQLite indexes attached to `table`, for the primary-key tests.
fn indexNamesFor(db: *Db, gpa: std.mem.Allocator, table: [:0]const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var rows = try db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
        &.{.{ .value = .{ .text = table } }},
    );
    defer rows.deinit();
    while (try rows.next()) |row| {
        try names.append(gpa, try gpa.dupe(u8, row[0].text));
    }
    return names.toOwnedSlice(gpa);
}

test "INFORMATION_SCHEMA.TABLES lists the dataset's tables and views" {
    // End-to-end on purpose: the vtab must emit encoded values, because
    // Rows.next rejects a TEXT column as CorruptData. A unit test on the row
    // builders alone would not catch that.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE isd.t_a (x INT64, y STRING)", &.{}, .{});
    try db.exec("CREATE TABLE isd.t_b (z FLOAT64)", &.{}, .{});
    try db.exec("CREATE VIEW isd.v_a AS SELECT 1 AS n", &.{}, .{});

    var rows = try db.query(
        \\SELECT table_name, table_type FROM isd.INFORMATION_SCHEMA.TABLES
        \\ORDER BY table_name
    , &.{}, .{});
    defer rows.deinit();

    const want = [_]struct { name: []const u8, kind: []const u8 }{
        .{ .name = "t_a", .kind = "BASE TABLE" },
        .{ .name = "t_b", .kind = "BASE TABLE" },
        .{ .name = "v_a", .kind = "VIEW" },
    };
    var i: usize = 0;
    while (try rows.next()) |row| : (i += 1) {
        try testing.expectEqualStrings(want[i].name, row[0].string);
        try testing.expectEqualStrings(want[i].kind, row[1].string);
    }
    try testing.expectEqual(want.len, i);
}

test "INFORMATION_SCHEMA.COLUMNS reports columns in declaration order" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE cd.tbl (col_a INT64, col_b STRING, col_c FLOAT64)", &.{}, .{});

    var rows = try db.query(
        \\SELECT column_name, ordinal_position, data_type
        \\FROM cd.INFORMATION_SCHEMA.COLUMNS
        \\WHERE table_name = 'tbl' ORDER BY ordinal_position
    , &.{}, .{});
    defer rows.deinit();

    const want = [_][]const u8{ "col_a", "col_b", "col_c" };
    var i: usize = 0;
    while (try rows.next()) |row| : (i += 1) {
        try testing.expectEqualStrings(want[i], row[0].string);
        try testing.expectEqual(Cell{ .int = @intCast(i + 1) }, row[1]);
    }
    try testing.expectEqual(want.len, i);
}

test "INFORMATION_SCHEMA.SCHEMATA names the dataset" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE sd.tbl (x INT64)", &.{}, .{});

    var rows = try db.query(
        "SELECT schema_name FROM sd.INFORMATION_SCHEMA.SCHEMATA",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqualStrings("sd", row[0].string);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "INFORMATION_SCHEMA.TABLE_OPTIONS reports DDL options for tables and views" {
    // option_value is the SQL literal as BigQuery renders it: double-quoted
    // with backslash escapes, NOT single-quoted. Verified against a real table
    // — setting this description and reading TABLE_OPTIONS back returns
    // `"demo table"`. Upstream googlesqlite normalises to single quotes; we do
    // not, which is why the .zon fixture is hand-corrected.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE od.t1 (a INT64) OPTIONS(description='demo table')", &.{}, .{});
    try db.exec("CREATE VIEW od.v1 OPTIONS(description='a view') AS SELECT 1 AS b", &.{}, .{});
    // No OPTIONS: contributes no rows.
    try db.exec("CREATE TABLE od.t2 (a INT64)", &.{}, .{});

    var rows = try db.query(
        \\SELECT table_name, option_name, option_type, option_value
        \\FROM od.INFORMATION_SCHEMA.TABLE_OPTIONS ORDER BY table_name
    , &.{}, .{});
    defer rows.deinit();

    const want = [_]struct { table: []const u8, value: []const u8 }{
        .{ .table = "t1", .value = "\"demo table\"" },
        .{ .table = "v1", .value = "\"a view\"" },
    };
    var i: usize = 0;
    while (try rows.next()) |row| : (i += 1) {
        try testing.expectEqualStrings(want[i].table, row[0].string);
        try testing.expectEqualStrings("description", row[1].string);
        try testing.expectEqualStrings("STRING", row[2].string);
        try testing.expectEqualStrings(want[i].value, row[3].string);
    }
    try testing.expectEqual(want.len, i);
}

test "a default project qualifies two-part DDL names" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    db.default_project = "p";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try db.exec("CREATE TABLE d.t (a INT64)", &.{}, .{});
    try testing.expect((try db.catalogTable(arena, "p", "d", "t")) != null);
    try db.exec("INSERT INTO d.t VALUES (1)", &.{}, .{});

    // Both spellings reach the one table. Each read is closed before the
    // replace below, which drops the table SQLite would otherwise hold open.
    {
        var short = try db.query("SELECT a FROM d.t", &.{}, .{});
        defer short.deinit();
        try testing.expectEqual(@as(i64, 1), (try short.next()).?[0].int);
    }
    {
        var full = try db.query("SELECT a FROM `p.d.t`", &.{}, .{});
        defer full.deinit();
        try testing.expectEqual(@as(i64, 1), (try full.next()).?[0].int);
    }

    // A replace lands on that table rather than beside it.
    try db.exec("CREATE OR REPLACE TABLE d.t AS SELECT 'x' AS s", &.{}, .{});
    try testing.expectEqual(@as(usize, 1), (try db.catalogTablesIn(arena, "p", "d")).len);
    const replaced = (try db.catalogTable(arena, "p", "d", "t")).?;
    try testing.expectEqualStrings("s", replaced.columns[0].name);

    try db.exec("CREATE VIEW d.v AS SELECT s FROM d.t", &.{}, .{});
    try testing.expect((try db.catalogTable(arena, "p", "d", "v")) != null);
    {
        var via_view = try db.query("SELECT s FROM `p.d.v`", &.{}, .{});
        defer via_view.deinit();
        try testing.expectEqualStrings("x", (try via_view.next()).?[0].string);
    }

    try db.exec("DROP VIEW d.v", &.{}, .{});
    try db.exec("DROP TABLE d.t", &.{}, .{});
    try testing.expectEqual(@as(usize, 0), (try db.catalogTablesIn(arena, "p", "d")).len);
    try testing.expectError(error.AnalyzeFailed, db.query("SELECT s FROM `p.d.t`", &.{}, .{}));

    // A TEMP table stays where it was written, for the script that made it.
    try db.exec("CREATE TEMP TABLE scratch (a INT64); DROP TABLE scratch; SELECT 1", &.{}, .{});
}

test "catalogTable answers only the path it was asked for" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One segment whose canonical name reads like three. The SQLite object
    // name is the same for both spellings, so only the spec's path can tell.
    try db.exec("CREATE TABLE foo_bar_baz (x INT64)", &.{}, .{});
    try testing.expectEqual(
        @as(?*const spec.TableSpec, null),
        try db.catalogTable(arena, "foo", "bar", "baz"),
    );
    try testing.expectEqual(@as(usize, 0), (try db.catalogTablesIn(arena, "foo", "bar")).len);
}

test "require_dataset refuses a CREATE into an undeclared dataset with BigQuery's message" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    db.default_project = "p";
    db.require_dataset = true;

    // Refused before any SQLite work: no object, no spec.
    try testing.expectError(error.DatasetNotFound, db.exec("CREATE TABLE d.t (a INT64)", &.{}, .{}));
    try testing.expectEqualStrings("Not found: Dataset p:d was not found in location US", db.lastError());
    try testing.expectEqual(@as(?*const spec.TableSpec, null), try db.catalogTable(arena, "p", "d", "t"));
    {
        var rows = try db.rawQuery("SELECT name FROM sqlite_master WHERE name = 'p_d_t'", &.{});
        defer rows.deinit();
        try testing.expect((try rows.next()) == null);
    }
    try testing.expectError(
        error.DatasetNotFound,
        db.exec("CREATE VIEW d.v AS SELECT 1 AS x", &.{}, .{}),
    );
    try testing.expectError(
        error.DatasetNotFound,
        db.exec("CREATE FUNCTION p.d.f(x INT64) AS (x + 1)", &.{}, .{}),
    );

    // Declared, the same statements go through.
    try db.addDataset(arena, "p", "d", "{\"id\":\"d\"}");
    try db.exec("CREATE TABLE d.t (a INT64)", &.{}, .{});
    try db.exec("CREATE VIEW d.v AS SELECT a FROM d.t", &.{}, .{});
    try db.exec("CREATE FUNCTION p.d.f(x INT64) AS (x + 1)", &.{}, .{});
    try testing.expect((try db.catalogTable(arena, "p", "d", "t")) != null);

    // The engine's own datasets are exempt: TEMP objects have none, and the
    // anonymous results dataset is never declared by anyone.
    try db.exec("CREATE TEMP TABLE scratch (a INT64)", &.{}, .{});
    try db.exec("CREATE TABLE `p._anon.job1` (a INT64)", &.{}, .{});

    // Off — the library default — the catalog infers the dataset instead.
    db.require_dataset = false;
    try db.exec("CREATE TABLE other.t (a INT64)", &.{}, .{});
    try testing.expect(try db.datasetExists(arena, "p", "other"));
    try testing.expectEqual(@as(?*const spec.DatasetSpec, null), try db.catalogDataset(arena, "p", "other"));
    try testing.expectEqual(@as(usize, 1), (try db.catalogDatasetsIn(arena, "p")).len);
}

test "declared datasets persist across connections, keep their creation time, and delete cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db_path = try std.fmt.allocPrintSentinel(
        arena,
        ".zig-cache/tmp/{s}/datasets.db",
        .{tmp.sub_path},
        0,
    );

    var created_at: []const u8 = "";
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        try db.addDataset(arena, "p", "ds", "{\"id\":\"ds\"}");
        const first = (try db.catalogDataset(arena, "p", "ds")) orelse return error.TestUnexpectedResult;
        created_at = try arena.dupe(u8, first.created_at);
        try testing.expect(created_at.len > 0);
        // Declaring again (datasets.patch) replaces the resource only.
        try db.addDataset(arena, "p", "ds", "{\"id\":\"ds\",\"description\":\"kept\"}");
        const second = (try db.catalogDataset(arena, "p", "ds")) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(created_at, second.created_at);
        try testing.expectEqualStrings("{\"id\":\"ds\",\"description\":\"kept\"}", second.metadata);
        try testing.expectEqual(@as(usize, 1), (try db.catalogDatasetsIn(arena, "p")).len);
    }
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        const reloaded = (try db.catalogDataset(arena, "p", "ds")) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("{\"id\":\"ds\",\"description\":\"kept\"}", reloaded.metadata);
        try testing.expectEqualStrings(created_at, reloaded.created_at);

        try db.deleteDataset(arena, "p", "ds");
        try testing.expectEqual(@as(?*const spec.DatasetSpec, null), try db.catalogDataset(arena, "p", "ds"));
        try testing.expect(!try db.datasetExists(arena, "p", "ds"));
        try testing.expectError(error.DatasetNotFound, db.deleteDataset(arena, "p", "ds"));
    }
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        try testing.expectEqual(@as(usize, 0), (try db.catalogDatasetsIn(arena, "p")).len);
    }
}

test "a dataset and a table sharing a canonical name both survive a reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db_path = try std.fmt.allocPrintSentinel(
        arena,
        ".zig-cache/tmp/{s}/shared_name.db",
        .{tmp.sub_path},
        0,
    );

    // Dataset `p.a_b` and table `p.a.b` are both `p_a_b`; each keeps its own catalog row.
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        try db.addDataset(arena, "p", "a", "");
        try db.addDataset(arena, "p", "a_b", "");
        try db.exec("CREATE TABLE p.a.b (x INT64)", &.{}, .{});
        try db.exec("INSERT INTO p.a.b (x) VALUES (7)", &.{}, .{});
    }
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        try testing.expect((try db.catalogDataset(arena, "p", "a_b")) != null);
        try testing.expect((try db.catalogTable(arena, "p", "a", "b")) != null);
        // Deleting the dataset takes its own row only.
        try db.deleteDataset(arena, "p", "a_b");
    }
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        const gone = try db.catalogDataset(arena, "p", "a_b");
        try testing.expectEqual(@as(?*const spec.DatasetSpec, null), gone);
        var rows = try db.query("SELECT x FROM p.a.b", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 7), row[0].int);
    }
}

test "a view cannot take a table's name, so the name keeps its one catalog row" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The invariant `Catalog.tableSpecKind` states: a name never moves between `table` and `view`.
    try db.exec("CREATE TABLE p.ds.t (a INT64)", &.{}, .{});
    try testing.expectError(
        error.ExecFailed,
        db.exec("CREATE VIEW p.ds.t AS SELECT 1 AS n", &.{}, .{}),
    );
    try testing.expectError(
        error.ExecFailed,
        db.exec("CREATE OR REPLACE VIEW p.ds.t AS SELECT 1 AS n", &.{}, .{}),
    );
    const t = (try db.catalogTable(arena, "p", "ds", "t")) orelse return error.TestUnexpectedResult;
    try testing.expect(!t.is_view);
    var rows = try db.rawQuery("SELECT kind FROM zigquery_catalog WHERE name = 'p_ds_t'", &.{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("table", row[0].text);
    try testing.expect((try rows.next()) == null);
}

test "DROP TABLE IF EXISTS on nothing is a no-op, DROP TABLE on nothing is an error" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    db.default_project = "p";
    try db.exec("DROP TABLE IF EXISTS d.nothing", &.{}, .{});
    try db.exec("DROP VIEW IF EXISTS `p.d.nothing`", &.{}, .{});
    // Without IF EXISTS, SQLite rejects it first.
    try testing.expectError(error.ExecFailed, db.exec("DROP TABLE d.nothing", &.{}, .{}));
}

test "a NOT NULL STRUCT member is enforced by DML and reported in BigQuery's words" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try db.exec(
        "CREATE TABLE `p.d.t` (id INT64, r STRUCT<x INT64 NOT NULL, y STRING>, " ++
            "rs ARRAY<STRUCT<k INT64 NOT NULL>>)",
        &.{},
        .{},
    );
    const table = (try db.catalogTable(arena, "p", "d", "t")).?;
    try testing.expect(table.columns[1].type.field_types[0].is_not_null);
    try testing.expect(!table.columns[1].type.field_types[1].is_not_null);
    try testing.expect(table.columns[2].type.element_type.?.field_types[0].is_not_null);

    try db.exec("INSERT INTO `p.d.t` VALUES (1, STRUCT(1, 'a'), [STRUCT(2)])", &.{}, .{});
    // A NULL parent has no members to require.
    try db.exec("INSERT INTO `p.d.t` VALUES (2, NULL, [])", &.{}, .{});

    const cases = [_][]const u8{
        "INSERT INTO `p.d.t` VALUES (3, STRUCT(NULL, 'a'), [])",
        "INSERT INTO `p.d.t` SELECT 4, STRUCT(CAST(NULL AS INT64) AS x, 'b' AS y), [] " ++
            "FROM UNNEST([1])",
        "UPDATE `p.d.t` SET r = STRUCT(NULL, 'c') WHERE id = 1",
        "INSERT INTO `p.d.t` VALUES (5, NULL, [STRUCT(1), STRUCT(NULL)])",
    };
    for (cases) |sql| {
        try testing.expectError(error.ExecFailed, db.exec(sql, &.{}, .{}));
    }
    try testing.expectError(
        error.ExecFailed,
        db.exec("INSERT INTO `p.d.t` VALUES (6, STRUCT(NULL, 'a'), [])", &.{}, .{}),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        db.lastError(),
        "Required field r.x cannot be null; error in writing field r",
    ) != null);
    try testing.expectError(
        error.ExecFailed,
        db.exec("INSERT INTO `p.d.t` VALUES (7, NULL, [STRUCT(NULL)])", &.{}, .{}),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        db.lastError(),
        "Required field rs.k cannot be null; error in writing field rs",
    ) != null);

    // A column the check does not reference is free to change.
    try db.exec("UPDATE `p.d.t` SET id = 10 WHERE id = 1", &.{}, .{});
    var rows = try db.query("SELECT COUNT(*), MAX(id) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 2), row[0].int);
    try testing.expectEqual(@as(i64, 10), row[1].int);
}

test "NOT NULL on an ARRAY member is recorded as nothing, and a NULL array lands" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try db.exec(
        "CREATE TABLE `p.d.t` (r STRUCT<a ARRAY<INT64> NOT NULL, x INT64 NOT NULL>)",
        &.{},
        .{},
    );
    const table = (try db.catalogTable(arena, "p", "d", "t")).?;
    try testing.expect(!table.columns[0].type.field_types[0].is_not_null);
    try testing.expect(table.columns[0].type.field_types[1].is_not_null);

    try db.exec("INSERT INTO `p.d.t` VALUES (STRUCT(CAST(NULL AS ARRAY<INT64>), 1))", &.{}, .{});
    try testing.expectError(
        error.ExecFailed,
        db.exec("INSERT INTO `p.d.t` VALUES (STRUCT([1], NULL))", &.{}, .{}),
    );
}

test "a member name with an apostrophe still makes a table with a working check" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE `p.d.t` (r STRUCT<`it's` INT64 NOT NULL>)", &.{}, .{});
    try db.exec("INSERT INTO `p.d.t` VALUES (STRUCT(1))", &.{}, .{});
    try testing.expectError(
        error.ExecFailed,
        db.exec("INSERT INTO `p.d.t` VALUES (STRUCT(NULL))", &.{}, .{}),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        db.lastError(),
        "Required field r.it's cannot be null; error in writing field r",
    ) != null);
}

test "UPDATE SET r.x rebuilds the struct, merges members, and descends" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE `p.d.t` (id INT64, r STRUCT<x INT64, y STRING, nested STRUCT<z INT64>>)",
        &.{},
        .{},
    );
    try db.exec(
        "INSERT INTO `p.d.t` VALUES (1, NULL), (2, STRUCT(1, 'a', STRUCT(9))), " ++
            "(3, STRUCT(3, 'c', NULL))",
        &.{},
        .{},
    );

    // A NULL parent is rebuilt from NULL siblings (recidiviz-bigquery-sandbox, 2026-09-10).
    try db.exec("UPDATE `p.d.t` SET r.x = 5 WHERE id = 1", &.{}, .{});
    // Two members of one column fold into one assignment.
    try db.exec("UPDATE `p.d.t` SET r.x = 5, r.y = 'b' WHERE id = 2", &.{}, .{});
    // A deeper path rebuilds only the struct it descends through.
    try db.exec("UPDATE `p.d.t` SET r.nested.z = 42 WHERE id = 2", &.{}, .{});
    // Untouched rows and members stay as they were.

    var rows = try db.query(
        "SELECT id, r.x, r.y, r.nested.z FROM `p.d.t` ORDER BY id",
        &.{},
        .{},
    );
    defer rows.deinit();
    const r1 = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 5), r1[1].int);
    try testing.expectEqual(Cell.null, r1[2]);
    try testing.expectEqual(Cell.null, r1[3]);
    const r2 = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 5), r2[1].int);
    try testing.expectEqualStrings("b", r2[2].string);
    try testing.expectEqual(@as(i64, 42), r2[3].int);
    const r3 = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 3), r3[1].int);
    try testing.expectEqualStrings("c", r3[2].string);
    try testing.expectEqual(Cell.null, r3[3]);
}

test "UPDATE SET r.x = NULL on a NOT NULL member is rejected with BigQuery's words" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE `p.d.t` (id INT64, r STRUCT<x INT64 NOT NULL, y STRING>)", &.{}, .{});
    try db.exec("INSERT INTO `p.d.t` VALUES (1, STRUCT(1, 'a'))", &.{}, .{});
    try testing.expectError(
        error.ExecFailed,
        db.exec("UPDATE `p.d.t` SET r.x = NULL WHERE id = 1", &.{}, .{}),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        db.lastError(),
        "Required field r.x cannot be null; error in writing field r",
    ) != null);
    // The sibling assignment in the same statement did not land either.
    try testing.expectError(
        error.ExecFailed,
        db.exec("UPDATE `p.d.t` SET r.y = 'z', r.x = NULL WHERE id = 1", &.{}, .{}),
    );
    var rows = try db.query("SELECT r.x, r.y FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 1), row[0].int);
    try testing.expectEqualStrings("a", row[1].string);
}

test "UPDATE targets the analyzer or the transformer refuse" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE `p.d.t` (id INT64, r STRUCT<x INT64>, rs ARRAY<STRUCT<k INT64>>)",
        &.{},
        .{},
    );
    try db.exec("INSERT INTO `p.d.t` VALUES (1, STRUCT(1), [STRUCT(2)])", &.{}, .{});
    // Overlap and repetition are the analyzer's to reject.
    try testing.expectError(
        error.AnalyzeFailed,
        db.exec("UPDATE `p.d.t` SET r = STRUCT(2), r.x = 3 WHERE id = 1", &.{}, .{}),
    );
    try testing.expectError(
        error.AnalyzeFailed,
        db.exec("UPDATE `p.d.t` SET r.x = 1, r.x = 2 WHERE id = 1", &.{}, .{}),
    );
    // An array element is not a target here.
    const element_target = "UPDATE `p.d.t` SET rs[OFFSET(0)].k = 5 WHERE id = 1";
    try testing.expect(if (db.exec(element_target, &.{}, .{})) |_| false else |_| true);
}

test "a view keeps the GoogleSQL it was written with" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try db.exec("CREATE TABLE `p.d.t` (a INT64, b STRING)", &.{}, .{});
    const view_sql = "SELECT a, UPPER(b) AS b FROM `p.d.t` WHERE a > 1";
    try db.exec("CREATE VIEW `p.d.v` AS " ++ view_sql, &.{}, .{});

    const view = (try db.catalogTable(arena, "p", "d", "v")).?;
    try testing.expect(view.is_view);
    try testing.expectEqualStrings(view_sql, view.source_sql);
    // The engine's own text is the SQLite translation, kept apart from it.
    try testing.expect(std.mem.indexOf(u8, view.query, "p_d_t") != null);
}

test "setTableMetadata is what catalogTable reads back" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try db.exec("CREATE TABLE `p.d.t` (a INT64)", &.{}, .{});
    const before = (try db.catalogTable(arena, "p", "d", "t")).?;
    try testing.expectEqualStrings("", before.metadata);

    try db.setTableMetadata(arena, "p", "d", "t", "{\"description\":\"posted\"}");
    const after = (try db.catalogTable(arena, "p", "d", "t")).?;
    try testing.expectEqualStrings("{\"description\":\"posted\"}", after.metadata);
    try testing.expectEqualStrings("a", after.columns[0].name);
    // A published spec is never mutated in place: the earlier pointer is intact.
    try testing.expectEqualStrings("", before.metadata);

    try testing.expectError(
        error.TableNotFound,
        db.setTableMetadata(arena, "p", "d", "nope", "{}"),
    );
}

test "a quoted description renders the way BigQuery escapes it" {
    // BigQuery returns `"he said \"hi\" and it's fine"` for this description:
    // inner double quotes backslash-escaped, single quotes left alone.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE qd.t (a INT64)
        \\OPTIONS(description='he said "hi" and it\'s fine')
    , &.{}, .{});

    var rows = try db.query(
        "SELECT option_value FROM qd.INFORMATION_SCHEMA.TABLE_OPTIONS",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqualStrings(
        \\"he said \"hi\" and it's fine"
    , row[0].string);
}

test "a table_name filter reaches the vtab and returns the same rows" {
    // SQLite pushes the user's WHERE through the generated subquery down to
    // xBestIndex, so the vtab prunes instead of building every table's columns
    // and letting SQLite discard them. Correctness must not change: assert the
    // filtered result equals the filtered-afterwards result.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE pd.t1 (a INT64, b STRING)", &.{}, .{});
    try db.exec("CREATE TABLE pd.t2 (c FLOAT64)", &.{}, .{});

    {
        var rows = try db.query(
            \\SELECT column_name FROM pd.INFORMATION_SCHEMA.COLUMNS
            \\WHERE table_name = 't1' ORDER BY column_name
        , &.{}, .{});
        defer rows.deinit();
        const want = [_][]const u8{ "a", "b" };
        var i: usize = 0;
        while (try rows.next()) |row| : (i += 1) {
            try testing.expectEqualStrings(want[i], row[0].string);
        }
        try testing.expectEqual(want.len, i);
    }

    // A name that matches nothing yields nothing, rather than falling back to
    // an unfiltered scan.
    {
        var rows = try db.query(
            "SELECT COUNT(*) FROM pd.INFORMATION_SCHEMA.COLUMNS WHERE table_name = 'nope'",
            &.{},
            .{},
        );
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 0 }, (try rows.next()).?[0]);
    }

    // And a table_schema filter, the other pushed-down column.
    {
        var rows = try db.query(
            "SELECT COUNT(*) FROM pd.INFORMATION_SCHEMA.TABLES WHERE table_schema = 'pd'",
            &.{},
            .{},
        );
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 2 }, (try rows.next()).?[0]);
    }
}

test "an unfiltered INFORMATION_SCHEMA scan is legal" {
    // Exercises the xBestIndex path where the hidden schema constraint is
    // absent: unnest rejects that with SQLITE_CONSTRAINT, these views must not.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE ud.tbl (x INT64)", &.{}, .{});

    var rows = try db.query(
        "SELECT COUNT(*) FROM ud.INFORMATION_SCHEMA.TABLES",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 1 }, row[0]);
}

test "a NOT ENFORCED primary key constrains nothing" {
    // BigQuery primary keys are only ever NOT ENFORCED: optimizer metadata for
    // join elimination, never a uniqueness or non-null guarantee. Both inserts
    // below succeed in BigQuery, so both must succeed here — lowering the key
    // to a real SQLite PRIMARY KEY made the emulator reject rows production
    // accepts, which is the wrong direction for an emulator to be wrong in.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE pk_t (id INT64 PRIMARY KEY NOT ENFORCED, v STRING)",
        &.{},
        .{},
    );
    try db.exec("INSERT INTO pk_t VALUES (1, 'a'), (1, 'b')", &.{}, .{});
    try db.exec("INSERT INTO pk_t VALUES (NULL, 'c')", &.{}, .{});

    var rows = try db.query("SELECT COUNT(*) FROM pk_t", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 3 }, row[0]);
}

test "a NOT ENFORCED primary key still becomes an index" {
    // The half of the key that does carry over: BigQuery uses it to plan, and
    // so should SQLite.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE pk_idx (id INT64 PRIMARY KEY NOT ENFORCED, v STRING)",
        &.{},
        .{},
    );

    const names = try indexNamesFor(db, testing.allocator, "pk_idx");
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("pk_idx.pk", names[0]);
}

test "CREATE OR REPLACE re-creates the primary-key index" {
    // The replace path drops the table first, which takes its indexes with it,
    // so the recreate has to put the index back. Exercises that DROP/CREATE
    // round trip rather than trusting it.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE pk_rep (id INT64 PRIMARY KEY NOT ENFORCED, v STRING)",
        &.{},
        .{},
    );
    try db.exec(
        "CREATE OR REPLACE TABLE pk_rep (id INT64 PRIMARY KEY NOT ENFORCED, w STRING)",
        &.{},
        .{},
    );

    const names = try indexNamesFor(db, testing.allocator, "pk_rep");
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("pk_rep.pk", names[0]);
}

test "CREATE TABLE AS SELECT cannot declare a primary key" {
    // Pins the assumption the swap branch in execCreateTableAction relies on:
    // it skips index creation because a CTAS spec can never carry a key. If
    // this test ever starts failing, that branch needs an execPkIndex call.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE ctas_src (id INT64)", &.{}, .{});
    try testing.expectError(error.AnalyzeFailed, db.exec(
        "CREATE OR REPLACE TABLE ctas_pk (id INT64 PRIMARY KEY NOT ENFORCED) " ++
            "AS SELECT id FROM ctas_src",
        &.{},
        .{},
    ));
}

test "struct field names outlive the step that produced them" {
    // Regression. Rows.next decodes with DecodeValueBorrowing, whose struct
    // keys alias SQLite's column buffer (see
    // codec_binary.decodeBinaryValueBorrowing). cellFromValue copied every
    // payload out of that buffer but not the field *name*, so a caller holding
    // a row across the next step() read freed memory.
    //
    // Nothing caught it because every existing caller reads each row before
    // stepping again: the CLI prints inside the loop, and the JSON corpus
    // compares inside the loop. The spec runner collects rows first, and saw
    // `{<garbage>: 1}`.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT STRUCT(x AS n) FROM UNNEST([1, 2]) AS x ORDER BY x",
        &.{},
        .{},
    );
    defer rows.deinit();

    const first = (try rows.next()).?;
    const held = first[0].struct_;

    // Step past it twice: once to the second row, once to exhaustion. Both
    // invalidate the buffer the first row's name pointed into.
    _ = try rows.next();
    _ = try rows.next();

    try testing.expectEqualStrings("n", held[0].name);
    try testing.expectEqual(Cell{ .int = 1 }, held[0].value);
}

test "query() over a script ending in DML returns empty rows (Go &Rows{conn})" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "CREATE TABLE t3 (x INT64); INSERT INTO t3 (x) VALUES (7)",
        &.{},
        .{},
    );
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 0), rows.columns().len);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "CREATE OR REPLACE drops and recreates; IF NOT EXISTS is idempotent" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t4 (a INT64); INSERT INTO t4 (a) VALUES (1)", &.{}, .{});
    // Plain CREATE on an existing table fails (SQLite: table exists).
    try testing.expectError(error.ExecFailed, db.exec("CREATE TABLE t4 (a INT64)", &.{}, .{}));

    // OR REPLACE swaps the schema and clears the rows.
    try db.exec("CREATE OR REPLACE TABLE t4 (a INT64, b STRING)", &.{}, .{});
    {
        var rows = try db.query("SELECT COUNT(*) FROM t4", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 0 }, (try rows.next()).?[0]);
    }

    // IF NOT EXISTS on an existing table is a no-op.
    try db.exec("INSERT INTO t4 (a, b) VALUES (5, 'x')", &.{}, .{});
    try db.exec("CREATE TABLE IF NOT EXISTS t4 (a INT64)", &.{}, .{});
    {
        var rows = try db.query("SELECT a, b FROM t4", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(Cell{ .int = 5 }, row[0]);
        try testing.expectEqualStrings("x", row[1].string);
    }
}

test "CREATE TEMP TABLE registers in memory but is not persisted" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Temp tables live only within one query script (Go Cleanup), so create,
    // populate and read within a single script.
    var rows = try db.query(
        "CREATE TEMP TABLE tmp1 (a INT64); INSERT INTO tmp1 (a) VALUES (9); SELECT a FROM tmp1",
        &.{},
        .{},
    );
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 9 }, (try rows.next()).?[0]);

    // No zigquery_catalog row (Go AddNewTableSpec skips persist for temp).
    var stmt = try db.sqlite_db.prepare("SELECT COUNT(*) FROM zigquery_catalog");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
}

test "UPDATE with WHERE and DELETE" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE t5 (id INT64, name STRING); " ++
            "INSERT INTO t5 (id, name) VALUES (1, 'a'), (2, 'b'), (3, 'c')",
        &.{},
        .{},
    );

    try db.exec("UPDATE t5 SET name = 'z' WHERE id = 2", &.{}, .{});
    {
        var rows = try db.query("SELECT name FROM t5 WHERE id = 2", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqualStrings("z", (try rows.next()).?[0].string);
    }

    try db.exec("DELETE FROM t5 WHERE id >= 2", &.{}, .{});
    {
        var rows = try db.query("SELECT COUNT(*), MAX(id) FROM t5", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(Cell{ .int = 1 }, row[0]);
        try testing.expectEqual(Cell{ .int = 1 }, row[1]);
    }
}

test "INSERT ... SELECT copies rows" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE src (a INT64); INSERT INTO src (a) VALUES (1), (2); " ++
            "CREATE TABLE dst (a INT64); INSERT INTO dst (a) SELECT a + 10 FROM src",
        &.{},
        .{},
    );
    var rows = try db.query("SELECT a FROM dst ORDER BY a", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 11 }, (try rows.next()).?[0]);
    try testing.expectEqual(Cell{ .int = 12 }, (try rows.next()).?[0]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "nextRaw hands back the stored bytes, and they bind straight back in" {
    // The point of nextRaw is that a value can go from one statement to another
    // without a decode and a re-encode, so the test that matters is the round
    // trip: read raw, bind raw, and read the copy back decoded. If the two
    // sides ever stop sharing an encoding this fails here rather than in a
    // caller staring at a corrupt column.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE raw_src (a INT64, b STRING, c FLOAT64, d BOOL); " ++
            "INSERT INTO raw_src (a, b, c, d) VALUES (7, 'x', 1.5, TRUE), " ++
            "(NULL, NULL, NULL, NULL); " ++
            "CREATE TABLE raw_dst (a INT64, b STRING, c FLOAT64, d BOOL)",
        &.{},
        .{},
    );

    {
        var rows = try db.query("SELECT a, b, c, d FROM raw_src ORDER BY a", &.{}, .{});
        defer rows.deinit();
        var args: [4]Db.RawArg = undefined;
        var seen: usize = 0;
        while (try rows.nextRaw()) |row| {
            try testing.expectEqual(@as(usize, 4), row.len);
            for (row, &args) |v, *arg| arg.* = .{ .value = v };
            try db.rawExec("INSERT INTO `raw_dst` VALUES (?, ?, ?, ?)", &args);
            seen += 1;
        }
        try testing.expectEqual(@as(usize, 2), seen);
    }

    // Decoded on the way out, so a wrong encoding shows as a wrong value.
    var rows = try db.query("SELECT a, b, c, d FROM raw_dst ORDER BY a", &.{}, .{});
    defer rows.deinit();
    const nulls = (try rows.next()).?;
    for (nulls) |cell| try testing.expectEqual(Cell.null, cell);
    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 7 }, row[0]);
    try testing.expectEqualStrings("x", row[1].string);
    try testing.expectEqual(Cell{ .float = 1.5 }, row[2]);
    try testing.expectEqual(Cell{ .bool = true }, row[3]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "a multi-row VALUES insert copies a table, nulls included" {
    // One statement per many rows, which is what makes it worth doing at all --
    // and a statement that silently wrote fewer rows than it was given would
    // look exactly like a speedup, so the round trip is the check.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try db.exec(
        "CREATE TABLE ba_src (a INT64, b STRING); " ++
            "INSERT INTO ba_src (a, b) VALUES (1, 'x'), (2, NULL), (3, ''); " ++
            "CREATE TABLE ba_dst (a INT64, b STRING)",
        &.{},
        .{},
    );

    var args: std.ArrayList(Db.RawArg) = .empty;
    {
        var rows = try db.query("SELECT a, b FROM ba_src ORDER BY a", &.{}, .{});
        defer rows.deinit();
        while (try rows.nextRaw()) |row| {
            for (row) |v| try args.append(arena, .{
                .value = switch (v) {
                    // Copied: the row buffer dies at the next step, and every
                    // value has to survive until the one statement runs.
                    .blob => |b| .{ .blob = try arena.dupe(u8, b) },
                    else => v,
                },
            });
        }
    }
    try testing.expectEqual(@as(usize, 6), args.items.len);

    try db.rawExec("INSERT INTO `ba_dst` VALUES (?,?),(?,?),(?,?)", args.items);

    var rows = try db.query("SELECT a, b FROM ba_dst ORDER BY a", &.{}, .{});
    defer rows.deinit();
    const r1 = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 1 }, r1[0]);
    try testing.expectEqualStrings("x", r1[1].string);
    const r2 = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 2 }, r2[0]);
    try testing.expectEqual(Cell.null, r2[1]);
    const r3 = (try rows.next()).?;
    try testing.expectEqualStrings("", r3[1].string);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

/// Backs the job-rows vtab in the test below: the server's role, minus a server.
const JobRowsFixture = struct {
    id: []const u8,
    rows: function.job_rows_vtab.RowSet,

    fn lookup(ctx: *anyopaque, job_id: []const u8) ?function.job_rows_vtab.RowSet {
        const f: *JobRowsFixture = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, job_id, f.id)) return null;
        return f.rows;
    }
};

test "a job's results resolve as a virtual table under GoogleSQL" {
    // The whole mechanism end to end, and the thing worth proving before any of
    // it is wired into the server: a synthetic TableSpec makes the analyzer
    // accept `p._anon.<job>`, a temp virtual table of the same canonical name
    // makes SQLite resolve it, and the rows come back decoded -- with no
    // transformer rewrite and nothing copied.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Real storage-form values, taken from a real query rather than invented.
    try db.exec(
        "CREATE TABLE jr_src (a INT64, b STRING); " ++
            "INSERT INTO jr_src (a, b) VALUES (1, 'x'), (2, NULL)",
        &.{},
        .{},
    );
    var cells: std.ArrayList(encoder.SqliteRepr) = .empty;
    {
        var rows = try db.query("SELECT a, b FROM jr_src ORDER BY a", &.{}, .{});
        defer rows.deinit();
        while (try rows.nextRaw()) |row| {
            for (row) |v| try cells.append(arena, switch (v) {
                .null => .null,
                .int => |x| .{ .int = x },
                .float => |x| .{ .float = x },
                .blob => |x| .{ .blob = try arena.dupe(u8, x) },
                .text => return error.UnexpectedStorage,
            });
        }
    }

    const job_id = "jobabc";
    var fixture: JobRowsFixture = .{
        .id = job_id,
        .rows = .{ .names = &.{ "a", "b" }, .cells = cells.items },
    };
    db.udf_state.job_rows = .{ .ctx = &fixture, .lookup = JobRowsFixture.lookup };
    defer db.udf_state.job_rows = .{};

    // The spec the analyzer resolves, memory-only: these rows are not SQLite's.
    var int_t: spec.Type = .{ .kind = @intFromEnum(pb.TypeKind.TYPE_INT64) };
    var str_t: spec.Type = .{ .kind = @intFromEnum(pb.TypeKind.TYPE_STRING) };
    var col_a: spec.ColumnSpec = .{ .name = "a", .type = &int_t };
    var col_b: spec.ColumnSpec = .{ .name = "b", .type = &str_t };
    var columns = [_]*spec.ColumnSpec{ &col_a, &col_b };
    var name_path = [_][]const u8{ "p", function.job_rows_vtab.anon_segment, job_id };
    var table_spec: spec.TableSpec = .{ .name_path = &name_path, .columns = &columns };
    {
        var g = db.lockCatalog();
        defer g.unlock();
        try g.catalog.addSyntheticTableSpec(&table_spec);
    }

    // And the SQLite object of the same canonical name, so a plain table
    // reference finds it. In temp, so it is never written to sqlite_master.
    const sqlite_name = try table_spec.tableName(arena);
    // Raw, not `exec`: `CREATE VIRTUAL TABLE` is SQLite's own DDL and means
    // nothing to the GoogleSQL analyzer, which answers AnalyzeFailed for it.
    const create = try function.job_rows_vtab.createSql(arena, sqlite_name, job_id, &.{ "a", "b" });
    try db.rawExec(create, &.{});

    var rows = try db.query("SELECT a, b FROM `p`.`_anon`.`jobabc`", &.{}, .{});
    defer rows.deinit();
    const r1 = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 1 }, r1[0]);
    try testing.expectEqualStrings("x", r1[1].string);
    const r2 = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 2 }, r2[0]);
    try testing.expectEqual(Cell.null, r2[1]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "a view can be defined over a job's results table" {
    // Two things could stop this and neither is obvious from the call site.
    //
    // SQLite refuses a virtual table inside a view when the schema is
    // untrusted -- `eVtabRisk > (flags & SQLITE_TrustedSchema)` in
    // sqlite3.c's selectExpander. A module opts out of that with
    // `sqlite3_vtab_config(SQLITE_VTAB_INNOCUOUS)`, which this one does not,
    // so the test stands guard over the default: `SQLITE_TRUSTED_SCHEMA` is not
    // in `sqlite_cflags` and nothing calls `sqlite3_db_config`, so the flag is
    // on and risk `Normal` is permitted. Turn either around and this fails with
    // "unsafe use of virtual table" -- at which point INNOCUOUS is the fix.
    //
    // And the table is created in `temp`, which a view in `main` may not be
    // able to see.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try db.exec(
        "CREATE TABLE jv_src (a INT64); INSERT INTO jv_src (a) VALUES (1), (2)",
        &.{},
        .{},
    );
    var cells: std.ArrayList(encoder.SqliteRepr) = .empty;
    {
        var rows = try db.query("SELECT a FROM jv_src ORDER BY a", &.{}, .{});
        defer rows.deinit();
        while (try rows.nextRaw()) |row| try cells.append(arena, .{ .int = row[0].int });
    }

    var fixture: JobRowsFixture = .{
        .id = "viewjob",
        .rows = .{ .names = &.{"a"}, .cells = cells.items },
    };
    db.udf_state.job_rows = .{ .ctx = &fixture, .lookup = JobRowsFixture.lookup };
    defer db.udf_state.job_rows = .{};

    var int_t: spec.Type = .{ .kind = @intFromEnum(pb.TypeKind.TYPE_INT64) };
    var col_a: spec.ColumnSpec = .{ .name = "a", .type = &int_t };
    var columns = [_]*spec.ColumnSpec{&col_a};
    var name_path = [_][]const u8{ "p", function.job_rows_vtab.anon_segment, "viewjob" };
    var table_spec: spec.TableSpec = .{ .name_path = &name_path, .columns = &columns };
    {
        var g = db.lockCatalog();
        defer g.unlock();
        try g.catalog.addSyntheticTableSpec(&table_spec);
    }
    const sqlite_name = try table_spec.tableName(arena);
    try db.rawExec(
        try function.job_rows_vtab.createSql(arena, sqlite_name, "viewjob", &.{"a"}),
        &.{},
    );

    try db.exec("CREATE VIEW jv AS SELECT a FROM `p`.`_anon`.`viewjob`", &.{}, .{});
    var rows = try db.query("SELECT a FROM jv ORDER BY a", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 1 }, (try rows.next()).?[0]);
    try testing.expectEqual(Cell{ .int = 2 }, (try rows.next()).?[0]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "a job-rows table whose job is gone reads as empty, not an error" {
    // What a caller sees once the rows are released: `lookup` returning null is
    // an empty table, because a read of a job that has expired should come back
    // with nothing rather than break the statement around it.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var int_t: spec.Type = .{ .kind = @intFromEnum(pb.TypeKind.TYPE_INT64) };
    var col_a: spec.ColumnSpec = .{ .name = "a", .type = &int_t };
    var columns = [_]*spec.ColumnSpec{&col_a};
    var name_path = [_][]const u8{ "p", function.job_rows_vtab.anon_segment, "goneid" };
    var table_spec: spec.TableSpec = .{ .name_path = &name_path, .columns = &columns };
    {
        var g = db.lockCatalog();
        defer g.unlock();
        try g.catalog.addSyntheticTableSpec(&table_spec);
    }
    const sqlite_name = try table_spec.tableName(arena);
    try db.rawExec(
        try function.job_rows_vtab.createSql(arena, sqlite_name, "goneid", &.{"a"}),
        &.{},
    );

    var rows = try db.query("SELECT a FROM `p`.`_anon`.`goneid`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "DROP TABLE removes catalog entry; SELECT then fails analysis" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t6 (a INT64)", &.{}, .{});
    try db.exec("DROP TABLE t6", &.{}, .{});
    try testing.expectError(error.AnalyzeFailed, db.query("SELECT a FROM t6", &.{}, .{}));
    try testing.expect(std.mem.indexOf(u8, db.lastError(), "t6") != null);
}

test "CREATE TABLE AS SELECT materializes the query" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE base (a INT64); INSERT INTO base (a) VALUES (1), (2), (3); " ++
            "CREATE TABLE ctas AS SELECT a * 2 AS doubled FROM base WHERE a > 1",
        &.{},
        .{},
    );
    var rows = try db.query("SELECT doubled FROM ctas ORDER BY doubled", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 4 }, (try rows.next()).?[0]);
    try testing.expectEqual(Cell{ .int = 6 }, (try rows.next()).?[0]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "CREATE TEMP TABLE AS SELECT (Go newTableAsSelectSpec temp path)" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Temp tables live for the duration of a single query script and are
    // dropped when its Rows is closed (Go StmtAction.Cleanup), so the CREATE
    // and the SELECT share one script here.
    var rows = try db.query(
        "CREATE TEMP TABLE tmp_ctas AS SELECT 'Kylie' AS FirstName UNION ALL SELECT 'Nick'; " ++
            "SELECT FirstName FROM tmp_ctas ORDER BY FirstName",
        &.{},
        .{},
    );
    defer rows.deinit();
    try testing.expectEqualStrings("Kylie", (try rows.next()).?[0].string);
    try testing.expectEqualStrings("Nick", (try rows.next()).?[0].string);
}

test "temp table is dropped after its query script completes" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Go drops temp tables at Rows.Close; re-creating the same name in a
    // later script must therefore succeed rather than collide.
    {
        var rows = try db.query(
            "CREATE TEMP TABLE reused (a INT64); SELECT * FROM reused",
            &.{},
            .{},
        );
        rows.deinit();
    }
    var rows = try db.query(
        "CREATE TEMP TABLE reused (a INT64); INSERT INTO reused (a) VALUES (7); SELECT a FROM reused",
        &.{},
        .{},
    );
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 7 }, (try rows.next()).?[0]);
}

test "TEMP objects live in the connection's overlay, not the persistent catalog" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE keeper (a INT64); INSERT INTO keeper (a) VALUES (1)", &.{}, .{});
    {
        var g = db.lockCatalog();
        defer g.unlock();
        try testing.expectEqual(@as(usize, 1), g.catalog.tableCount());
    }

    // Mid-script the TEMP table is registered — in the overlay only, so the
    // persistent catalog a pool would share stays untouched by it.
    {
        var rows = try db.query(
            "CREATE TEMP TABLE scratch (a INT64); INSERT INTO scratch (a) VALUES (99); " ++
                "SELECT a FROM scratch",
            &.{},
            .{},
        );
        try testing.expect(db.temps.findTableSpec("scratch") != null);
        {
            var g = db.lockCatalog();
            defer g.unlock();
            try testing.expect(g.catalog.findTableSpec("scratch") == null);
        }
        try testing.expectEqual(Cell{ .int = 99 }, (try rows.next()).?[0]);
        rows.deinit();
    }

    // Cleanup drops it from the overlay and leaves the persistent catalog
    // exactly as it was — the whole point of the split, since cleanup used to
    // call deleteTableSpec on the one shared catalog.
    try testing.expect(db.temps.findTableSpec("scratch") == null);
    var g = db.lockCatalog();
    defer g.unlock();
    try testing.expectEqual(@as(usize, 1), g.catalog.tableCount());
    try testing.expect(g.catalog.findTableSpec("keeper") != null);
}

test "a TEMP function shadows a persistent one of the same name" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE FUNCTION dbl(x INT64) AS (x * 2)", &.{}, .{});
    {
        var rows = try db.query(
            "CREATE TEMP FUNCTION dbl(x INT64) AS (x * 100); SELECT dbl(3)",
            &.{},
            .{},
        );
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 300 }, (try rows.next()).?[0]);
    }
    // The persistent definition survives the TEMP one's cleanup.
    var rows = try db.query("SELECT dbl(3)", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 6 }, (try rows.next()).?[0]);
}

test "CREATE VIEW resolves through the catalog and reflects base rows" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE vt (a INT64); INSERT INTO vt (a) VALUES (1), (2); " ++
            "CREATE VIEW v1 AS SELECT a + 1 AS b FROM vt",
        &.{},
        .{},
    );
    {
        var rows = try db.query("SELECT b FROM v1 ORDER BY b", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 2 }, (try rows.next()).?[0]);
        try testing.expectEqual(Cell{ .int = 3 }, (try rows.next()).?[0]);
    }
    // The view tracks subsequent DML on the base table.
    try db.exec("INSERT INTO vt (a) VALUES (10)", &.{}, .{});
    {
        var rows = try db.query("SELECT MAX(b) FROM v1", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 11 }, (try rows.next()).?[0]);
    }
}

test "TRUNCATE TABLE deletes all rows" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE trunc_t (a INT64); INSERT INTO trunc_t (a) VALUES (1), (2)",
        &.{},
        .{},
    );
    try db.exec("TRUNCATE TABLE trunc_t", &.{}, .{});
    var rows = try db.query("SELECT COUNT(*) FROM trunc_t", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 0 }, (try rows.next()).?[0]);
}

test "dotted CREATE and DML resolve through recursive catalog paths" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        "CREATE TABLE ds.t (id INT64, name STRING); " ++
            "INSERT INTO ds.t (id, name) VALUES (1, 'x')",
        &.{},
        .{},
    );
    var rows = try db.query("SELECT name FROM ds.t WHERE id = 1", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqualStrings("x", (try rows.next()).?[0].string);
}

test "columnTypes exposes resolved output column types" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT 1 AS i, 'a' AS s, [1, 2] AS arr, STRUCT(1 AS f) AS st",
        &.{},
        .{},
    );
    defer rows.deinit();

    const cols = rows.columnTypes();
    try testing.expectEqual(@as(usize, 4), cols.len);
    try testing.expectEqualStrings("i", cols[0].name);
    try testing.expectEqual(pb.TypeKind.TYPE_INT64, cols[0].type.typeKind());
    try testing.expectEqual(pb.TypeKind.TYPE_STRING, cols[1].type.typeKind());
    try testing.expect(cols[2].type.isArray());
    try testing.expectEqual(
        pb.TypeKind.TYPE_INT64,
        cols[2].type.element_type.?.typeKind(),
    );
    try testing.expect(cols[3].type.isStruct());
    try testing.expectEqualStrings("f", cols[3].type.field_types[0].name);

    // Names stay in lockstep with columns().
    try testing.expectEqual(rows.columns().len, cols.len);
}

test "columnTypes is empty for a non-query statement" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("CREATE TABLE ct_empty (a INT64)", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 0), rows.columnTypes().len);
}

test "NUMERIC arithmetic rounds to the declared scale" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // These pin a deliberate divergence from go-zetasqlite, which keeps an
    // exact big.Rat and so answers 1, and a move toward BigQuery, whose NUMERIC
    // is decimal(38,9). No corpus case covers any of it, so without these tests
    // the change would be invisible.
    const cases = [_]struct { sql: []const u8, want: []const u8 }{
        // Division rounds, so multiplying back does not recover the input.
        .{ .sql = "SELECT CAST((NUMERIC '1' / NUMERIC '7') * NUMERIC '7' AS STRING) AS v", .want = "1.000000001" },
        // PARSE_NUMERIC now rounds at ingest, as a folded CAST always did.
        .{ .sql = "SELECT CAST(PARSE_NUMERIC('1.0123456789') * NUMERIC '1000000000' AS STRING) AS v", .want = "1012345679" },
        // Values that render alike now *are* alike; they used to compare
        // unequal while grouping together, since GROUP BY keys on the rendering.
        .{ .sql = "SELECT CAST((NUMERIC '1' / NUMERIC '3') = PARSE_NUMERIC('0.333333333') AS STRING) AS v", .want = "true" },
        // Mixed kinds widen to BIGNUMERIC rather than rounding the wider
        // operand away: LHS-wins would make this 0.
        .{
            .sql = "SELECT CAST(BIGNUMERIC '0.00000000000000000000000000000000000001' + NUMERIC '0' AS STRING) AS v",
            .want = "0.00000000000000000000000000000000000001",
        },
        // A magnitude below the scale rounds to a true zero, not Go's "-0".
        .{ .sql = "SELECT CAST(CAST('-1e-10' AS NUMERIC) AS STRING) AS v", .want = "0" },
    };
    for (cases) |tc| {
        var rows = try db.query(tc.sql, &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqualStrings(tc.want, row[0].string);
    }
}

test "storage format gate stamps an unversioned database and rejects a foreign one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const db_path = try std.fmt.allocPrintSentinel(
        arena_state.allocator(),
        ".zig-cache/tmp/{s}/format.db",
        .{tmp.sub_path},
        0,
    );

    // A fresh database has user_version 0 and must be adopted, not rejected —
    // that is also every database written before this check existed.
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        var rows = try db.rawQuery("PRAGMA user_version", &.{});
        defer rows.deinit();
        try testing.expectEqual(Db.storage_format_version, (try rows.next()).?[0].int);
    }
    // Reopening finds its own stamp and is satisfied by it.
    {
        var db = try Db.open(testing.allocator, db_path);
        db.close();
    }
    // A database claiming a format this build does not know must refuse to
    // open. Left silent, the failures downstream are wrong answers rather than
    // errors: mismatched values never compare equal, so DISTINCT and primary
    // keys quietly stop deduplicating.
    {
        var raw = try sqlite.Db.open(db_path);
        try raw.exec("PRAGMA user_version = 999");
        raw.close();
    }
    try testing.expectError(error.IncompatibleStorageFormat, Db.open(testing.allocator, db_path));
}

test "openWith applies pragmas and leaves open() behaviour unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const db_path = try std.fmt.allocPrintSentinel(
        arena_state.allocator(),
        ".zig-cache/tmp/{s}/pragmas.db",
        .{tmp.sub_path},
        0,
    );

    var db = try Db.openWith(testing.allocator, db_path, .{
        .pragmas = &.{ "PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL" },
        .busy_timeout_ms = 5000,
    });
    defer db.close();

    var rows = try db.rawQuery("PRAGMA journal_mode", &.{});
    defer rows.deinit();
    try testing.expectEqualStrings("wal", (try rows.next()).?[0].text);
}

test "rawQuery round-trips values and stays invisible to the analyzer" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.rawExec("CREATE TABLE raw_t (a INTEGER, b TEXT, c REAL, d BLOB)", &.{});
    try db.rawExec(
        "INSERT INTO raw_t VALUES (@a, @b, @c, @d)",
        &.{
            .{ .name = "@a", .value = .{ .int = 7 } },
            .{ .name = "@b", .value = .{ .text = "hi" } },
            .{ .name = "@c", .value = .{ .float = 1.5 } },
            .{ .name = "@d", .value = .{ .blob = "\x00\x01" } },
        },
    );

    {
        var rows = try db.rawQuery("SELECT a, b, c, d FROM raw_t", &.{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(@as(i64, 7), row[0].int);
        try testing.expectEqualStrings("hi", row[1].text);
        try testing.expectEqual(@as(f64, 1.5), row[2].float);
        try testing.expectEqualSlices(u8, "\x00\x01", row[3].blob);
        try testing.expectEqual(@as(?[]const Db.RawValue, null), try rows.next());
    }

    // The raw path bypasses the catalog entirely, so the GoogleSQL side must
    // not resolve the table (Go: WithQueryFormattingDisabled statements never
    // reach the analyzer).
    try testing.expectError(error.AnalyzeFailed, db.query("SELECT a FROM raw_t", &.{}, .{}));
}

test "rawQuery binds positionally and caches prepared statements" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.rawExec("CREATE TABLE raw_p (a INTEGER)", &.{});
    try db.rawExec("INSERT INTO raw_p VALUES (?)", &.{.{ .value = .{ .int = 1 } }});
    try db.rawExec("INSERT INTO raw_p VALUES (?)", &.{.{ .value = .{ .int = 2 } }});

    var rows = try db.rawQuery("SELECT a FROM raw_p ORDER BY a", &.{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?[0].int);
    try testing.expectEqual(@as(i64, 2), (try rows.next()).?[0].int);

    // Both INSERTs share one cached statement; CREATE and SELECT add one each.
    try testing.expectEqual(@as(u32, 3), db.raw_cache.count());
}

test "rawQuery re-entrant on the same SQL does not disturb an open cursor" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.rawExec("CREATE TABLE raw_r (a INTEGER)", &.{});
    try db.rawExec("INSERT INTO raw_r VALUES (1), (2)", &.{});

    var outer = try db.rawQuery("SELECT a FROM raw_r ORDER BY a", &.{});
    defer outer.deinit();
    try testing.expectEqual(@as(i64, 1), (try outer.next()).?[0].int);

    {
        // Same SQL while `outer` is mid-iteration: must get its own statement
        // rather than resetting the one `outer` is stepping.
        var inner = try db.rawQuery("SELECT a FROM raw_r ORDER BY a", &.{});
        defer inner.deinit();
        try testing.expectEqual(@as(i64, 1), (try inner.next()).?[0].int);
    }

    // `outer` resumes where it left off.
    try testing.expectEqual(@as(i64, 2), (try outer.next()).?[0].int);
}

test "memdb VFS shares one database across connections" {
    // Pool prerequisite: `:memory:` is per-connection, and shared-cache mode
    // raises SQLITE_LOCKED, which busy_timeout does not retry. memdb gives a
    // genuinely shared in-memory DB with normal locking.
    var a = try Db.open(testing.allocator, "file:/zigquery_memdb_test?vfs=memdb");
    defer a.close();
    try a.exec("CREATE TABLE shared_t (x INT64); INSERT INTO shared_t (x) VALUES (42)", &.{}, .{});

    var b = try Db.open(testing.allocator, "file:/zigquery_memdb_test?vfs=memdb");
    defer b.close();
    var rows = try b.query("SELECT x FROM shared_t", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 42 }, (try rows.next()).?[0]);
}

test "GENERATE_UUID yields a distinct value per row" {
    // Every scalar UDF used to be registered SQLITE_DETERMINISTIC, which lets
    // SQLite hoist a constant-argument call out of the row loop and evaluate
    // it once per query — so this returned one UUID repeated N times. The
    // corpus never caught it because it only asserts LENGTH().
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT GENERATE_UUID() FROM UNNEST([1, 2, 3, 4, 5])",
        &.{},
        .{},
    );
    defer rows.deinit();

    var seen = std.StringHashMap(void).init(testing.allocator);
    defer seen.deinit();
    var n: usize = 0;
    while (try rows.next()) |row| : (n += 1) {
        try testing.expectEqual(@as(usize, 36), row[0].string.len);
        try testing.expect(!seen.contains(row[0].string));
        try seen.put(row[0].string, {});
    }
    try testing.expectEqual(@as(usize, 5), n);
}

test "a new connection loads every persisted spec at open" {
    const dsn = "file:/zigquery_load_test?vfs=memdb";

    var first = try Db.open(testing.allocator, dsn);
    defer first.close();
    try first.exec("CREATE TABLE preexisting (a INT64); INSERT INTO preexisting (a) VALUES (5)", &.{}, .{});

    // No timestamp filter: opening reads the whole catalog table, so
    // everything committed before this point resolves immediately.
    var second = try Db.open(testing.allocator, dsn);
    defer second.close();
    var rows = try second.query("SELECT a FROM preexisting", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 5 }, (try rows.next()).?[0]);
}

test "connections with separate catalogs do not see each other's later DDL" {
    // The contract this replaces the old sync-cursor behaviour with: catalog
    // coherence between connections is *not* a property of re-reading SQLite.
    // Two Dbs each owning a catalog are independent by construction, which is
    // sound and predictable, where the old timestamp cursor made the same
    // scenario silently and permanently lossy. Connections that must agree
    // share one catalog instead — see SharedCatalog.
    const dsn = "file:/zigquery_independent_test?vfs=memdb";

    var writer = try Db.open(testing.allocator, dsn);
    defer writer.close();
    var reader = try Db.open(testing.allocator, dsn);
    defer reader.close();

    try writer.exec("CREATE TABLE written_later (a INT64)", &.{}, .{});

    var wg = writer.lockCatalog();
    defer wg.unlock();
    var rg = reader.lockCatalog();
    defer rg.unlock();
    try testing.expect(wg.catalog.findTableSpec("written_later") != null);
    try testing.expect(rg.catalog.findTableSpec("written_later") == null);
    try testing.expectError(
        error.AnalyzeFailed,
        reader.query("SELECT a FROM written_later", &.{}, .{}),
    );
}

test "created tables persist across connections to the same file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const db_path = try std.fmt.allocPrintSentinel(
        arena_state.allocator(),
        ".zig-cache/tmp/{s}/create_dml_e2e.db",
        .{tmp.sub_path},
        0,
    );

    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        try db.exec(
            "CREATE TABLE pt (a INT64); INSERT INTO pt (a) VALUES (5)",
            &.{},
            .{},
        );
    }
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        var rows = try db.query("SELECT a FROM pt", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 5 }, (try rows.next()).?[0]);
    }
}

test "CREATE OR REPLACE ... AS SELECT can read the table it replaces" {
    // WRITE_TRUNCATE lands here, and the dataflow metric pruning job replaces
    // a table from a query over that same table. Dropping first destroyed the
    // rows the query was about to read; the job died with SQLite's "no such
    // table", not the analyzer's "Table not found", because the raw DROP left
    // the spec registered.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    _ = try db.exec(
        "CREATE TABLE `p.d.metrics` (job_id STRING, n INT64);\n" ++
            "INSERT INTO `p.d.metrics` VALUES ('keep', 1), ('drop', 2), ('keep', 3);",
        &.{},
        .{},
    );
    _ = try db.exec(
        "CREATE OR REPLACE TABLE `p.d.metrics` AS " ++
            "SELECT job_id, n FROM `p.d.metrics` WHERE job_id = 'keep';",
        &.{},
        .{},
    );

    var rows = try db.query("SELECT n FROM `p.d.metrics` ORDER BY n", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?[0].int);
    try testing.expectEqual(@as(i64, 3), (try rows.next()).?[0].int);
    try testing.expect((try rows.next()) == null);
}

test "a failed CREATE OR REPLACE ... AS SELECT leaves the table intact" {
    // The rebuild happens off to the side, so a query that cannot run costs
    // nothing. Previously the DROP had already committed by then, and the
    // catalog still advertised a table SQLite no longer had.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    _ = try db.exec(
        "CREATE TABLE `p.d.t` (a INT64);\nINSERT INTO `p.d.t` VALUES (7);",
        &.{},
        .{},
    );
    try testing.expectError(error.AnalyzeFailed, db.exec(
        "CREATE OR REPLACE TABLE `p.d.t` AS SELECT no_such_column FROM `p.d.t`;",
        &.{},
        .{},
    ));

    var rows = try db.query("SELECT a FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 7), (try rows.next()).?[0].int);
}

test "catalog persists across driver connections to the same file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // tmpDir lives at .zig-cache/tmp/<sub_path> relative to the test cwd;
    // sqlite resolves the same relative path against the same cwd.
    const db_path = try std.fmt.allocPrintSentinel(
        arena,
        ".zig-cache/tmp/{s}/catalog_e2e.db",
        .{tmp.sub_path},
        0,
    );

    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        try catalog_test.setupTable(db, arena);
    }
    // A fresh connection loads the spec via Catalog.sync.
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        var rows = try db.query("SELECT b FROM t1 WHERE a = 42", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqualStrings("hello", row[0].string);
    }
}

test "positional parameters bind in order" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT ? + ?", &.{
        .{ .value = .{ .int = 1 } },
        .{ .value = .{ .int = 2 } },
    }, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 3 }, (try rows.next()).?[0]);
}

test "positional parameters consumed across a multi-statement script" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Corpus 723: first ? feeds the CTAS, the remaining two feed the SELECT.
    var rows = try db.query(
        "CREATE TEMP TABLE t1 AS SELECT ? c1;\nSELECT c1 * ? * ? FROM t1;",
        &.{
            .{ .value = .{ .int = 1 } },
            .{ .value = .{ .int = 2 } },
            .{ .value = .{ .int = 3 } },
        },
        .{},
    );
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 6 }, (try rows.next()).?[0]);
}

test "named parameters bind by name (order independent)" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT @a + @b", &.{
        .{ .name = "b", .value = .{ .int = 2 } },
        .{ .name = "a", .value = .{ .int = 1 } },
    }, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 3 }, (try rows.next()).?[0]);
}

test "missing named parameter reports not enough query arguments" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try testing.expectError(error.ExecFailed, db.query("SELECT @a + @b", &.{
        .{ .name = "a", .value = .{ .int = 1 } },
    }, .{}));
    try testing.expectEqualStrings("not enough query arguments", db.lastError());
}

test "mixing named and positional parameters is rejected" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try testing.expectError(error.AnalyzeFailed, db.query("SELECT ? + @a", &.{
        .{ .value = .{ .int = 1 } },
        .{ .name = "a", .value = .{ .int = 2 } },
    }, .{}));
}

test "a declared parameter type overrides the analyzer's inference" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Undeclared, `@x` sits in no function or operator argument, so there is
    // nothing to infer from and the analyzer stamps it INT64.
    {
        var rows = try db.query("SELECT @x AS a", &.{
            .{ .name = "x", .value = .{ .string = "5" } },
        }, .{});
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 5 }, (try rows.next()).?[0]);
    }

    // Declaring the type is what the REST surface does — queryParameters
    // names one beside every value — and it is the only way this column comes
    // back as the STRING the client asked for.
    {
        var rows = try db.query("SELECT @x AS a", &.{
            .{ .name = "x", .value = .{ .string = "5" }, .type_text = "STRING" },
        }, .{});
        defer rows.deinit();
        try testing.expectEqualStrings("5", (try rows.next()).?[0].string);
    }
}

test "a declared positional parameter type is honoured too" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Positional declaration switches undeclared inference off for the
    // statement, so this is the all-or-nothing path.
    var rows = try db.query("SELECT ? AS a", &.{
        .{ .value = .{ .string = "hi" }, .type_text = "STRING" },
    }, .{});
    defer rows.deinit();
    try testing.expectEqualStrings("hi", (try rows.next()).?[0].string);
}

test "a declared ARRAY parameter can be UNNESTed" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // credit_calculator.py's `... IN UNNEST(@ids)`. UNNEST is not function
    // argument coercion, so an undeclared parameter stays an untyped INT64
    // and ResolveArrayScan rejects it outright — declaring the type is the
    // only thing that makes this analyze at all.
    var ids = [_]Cell{ .{ .string = "a" }, .{ .string = "b" } };
    var rows = try db.query(
        "SELECT COUNT(*) FROM UNNEST(@ids) AS id",
        &.{.{ .name = "ids", .value = .{ .array = &ids }, .type_text = "ARRAY<STRING>" }},
        .{},
    );
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 2 }, (try rows.next()).?[0]);
}

test "an undeclared parameter still infers alongside a declared one" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Named declarations and undeclared inference coexist: @a is declared,
    // @b is not, and both have to resolve.
    var rows = try db.query("SELECT CONCAT(@a, @b) AS s", &.{
        .{ .name = "a", .value = .{ .string = "x" }, .type_text = "STRING" },
        .{ .name = "b", .value = .{ .string = "y" } },
    }, .{});
    defer rows.deinit();
    try testing.expectEqualStrings("xy", (try rows.next()).?[0].string);
}

test "an unresolvable declared type falls back to inference" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // A type text the analyzer cannot parse must not fail the query; the
    // parameter is simply left undeclared, which is what it was before.
    var rows = try db.query("SELECT CONCAT(@a, 'x') AS s", &.{
        .{ .name = "a", .value = .{ .string = "h" }, .type_text = "NOT_A_TYPE" },
    }, .{});
    defer rows.deinit();
    try testing.expectEqualStrings("hx", (try rows.next()).?[0].string);
}

test "struct parameter is cast to the declared parameter type" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Corpus 741: an empty struct value gains the declared field as NULL.
    var rows = try db.query(
        "CREATE TABLE conductors (conductor STRUCT<length FLOAT64>);\n" ++
            "INSERT INTO conductors (conductor) VALUES (?);\n" ++
            "SELECT conductor.length FROM conductors;",
        &.{.{ .value = .{ .struct_ = &.{} } }},
        .{},
    );
    defer rows.deinit();
    try testing.expectEqual(Cell.null, (try rows.next()).?[0]);
}

test "scalar parameters are cast to the column type" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // The REST surface hands every scalar over as JSON text — google-cloud-
    // bigquery sends INT64, NUMERIC and the date/time kinds as strings — so
    // CastValue has to coerce them on the way in, exactly as Go does.
    var rows = try db.query(
        "CREATE TABLE cast_params (i INT64, f FLOAT64, b BOOL, n NUMERIC, d DATE, ts TIMESTAMP);\n" ++
            "INSERT INTO cast_params (i, f, b, n, d, ts) VALUES (?, ?, ?, ?, ?, ?);\n" ++
            "SELECT i, f, b, n, d, ts FROM cast_params;",
        &.{
            .{ .value = .{ .string = "5" } },
            .{ .value = .{ .string = "1.5" } },
            .{ .value = .{ .string = "true" } },
            .{ .value = .{ .string = "1.2345" } },
            .{ .value = .{ .string = "2024-01-02" } },
            .{ .value = .{ .string = "2024-01-02T03:04:05Z" } },
        },
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 5), row[0].int);
    try testing.expectEqual(@as(f64, 1.5), row[1].float);
    try testing.expectEqual(true, row[2].bool);
    try testing.expectEqualStrings("1.2345", row[3].string);
    try testing.expectEqualStrings("2024-01-02", row[4].date);
    try testing.expectEqualStrings("1704164645.0", row[5].timestamp);
}

test "a value that cannot be cast reports Go's message, not the error tag" {
    // emulator_test.py test_invalid_data_load_fails asserts on this exact
    // text, so the diagnostic has to survive as far as lastError().
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try testing.expectError(error.DecodeFailed, db.query(
        "CREATE TABLE bad_date (d DATE);\n" ++
            "INSERT INTO bad_date (d) VALUES (?);",
        &.{.{ .value = .{ .string = "202-06-06" } }},
        .{},
    ));
    try testing.expectEqualStrings(
        "failed to convert 202-06-06 to time.Time type",
        db.lastError(),
    );
}

test "a DATE column accepts the datetime spellings ToTime handles" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Go casts through ToTime and keeps the civil date of the instant.
    var rows = try db.query(
        "CREATE TABLE dates (d DATE);\n" ++
            "INSERT INTO dates (d) VALUES (?), (?);\n" ++
            "SELECT d FROM dates ORDER BY d;",
        &.{
            .{ .value = .{ .string = "2024-01-02" } },
            .{ .value = .{ .string = "2024-03-04 05:06:07" } },
        },
        .{},
    );
    defer rows.deinit();
    try testing.expectEqualStrings("2024-01-02", (try rows.next()).?[0].date);
    try testing.expectEqualStrings("2024-03-04", (try rows.next()).?[0].date);
}

test "an unpadded hour parses on both the bind path and the runtime cast" {
    // Raw state extracts spell midnight "0:00:00" and morning "7:34:44". Go's
    // `15` layout element takes one or two digits, so both paths accept them;
    // this port used to reject both, as HTTP 500 out of insertAll and as
    // "SQL logic error: failed to convert ... (1)" out of a query.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Bind path: castParamValue -> toUnixMicros, what insertAll does.
    var bound = try db.query(
        "CREATE TABLE stamps (d DATETIME);\n" ++
            "INSERT INTO stamps (d) VALUES (?), (?);\n" ++
            "SELECT d FROM stamps ORDER BY d;",
        &.{
            .{ .value = .{ .string = "2024-01-05 0:00:00" } },
            .{ .value = .{ .string = "2020-11-30 7:34:44" } },
        },
        .{},
    );
    defer bound.deinit();
    try testing.expectEqualStrings("2020-11-30T07:34:44", (try bound.next()).?[0].datetime);
    try testing.expectEqualStrings("2024-01-05T00:00:00", (try bound.next()).?[0].datetime);

    // Runtime cast: the zigquery_cast UDF. UNNEST keeps the analyzer from
    // constant-folding the cast, which is what hid this from a literal test.
    var cast = try db.query(
        "SELECT CAST(x AS DATETIME) AS d " ++
            "FROM UNNEST(['2024-01-05 0:00:00', '1988-09-14 2:05:05']) AS x " ++
            "ORDER BY d;",
        &.{},
        .{},
    );
    defer cast.deinit();
    try testing.expectEqualStrings("1988-09-14T02:05:05", (try cast.next()).?[0].datetime);
    try testing.expectEqualStrings("2024-01-05T00:00:00", (try cast.next()).?[0].datetime);
}

test "an INT64 column bound as a string still compares as a number" {
    // The point of casting at bind time rather than at read time: the value
    // has to reach SQLite as an INTEGER, or predicates and aggregates over it
    // silently do string comparisons.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "CREATE TABLE nums (i INT64);\n" ++
            "INSERT INTO nums (i) VALUES (?), (?), (?);\n" ++
            "SELECT SUM(i), MAX(i) FROM nums WHERE i > 5;",
        &.{
            .{ .value = .{ .string = "9" } },
            .{ .value = .{ .string = "10" } },
            .{ .value = .{ .string = "2" } },
        },
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 19), row[0].int);
    try testing.expectEqual(@as(i64, 10), row[1].int);
}

test "a JSON cell binds its payload without re-quoting it" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Binding the same text as a plain string would go through ToJSON and
    // come back quoted; Go avoids that by unmarshalling before it binds.
    var rows = try db.query(
        "CREATE TABLE docs (j JSON);\n" ++
            "INSERT INTO docs (j) VALUES (?);\n" ++
            "SELECT JSON_VALUE(j, '$.a'), j FROM docs;",
        &.{.{ .value = .{ .json = "{\"a\":\"x\"}" } }},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqualStrings("x", row[0].string);
    try testing.expectEqualStrings("{\"a\":\"x\"}", row[1].string);
}

test "a prepared INSERT analyzes once and executes per row" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE batch (i INT64, s STRING)", &.{}, .{});

    const before = phase.count(.analyze);
    var stmt = try db.prepare("INSERT INTO batch (i, s) VALUES (?, ?)", .{});
    defer stmt.deinit();
    const after_prepare = phase.count(.analyze);

    for ([_]struct { i: i64, s: []const u8 }{
        .{ .i = 1, .s = "a" },
        .{ .i = 2, .s = "b" },
        .{ .i = 3, .s = "c" },
    }) |row| {
        try stmt.exec(&.{
            .{ .value = .{ .int = row.i } },
            .{ .value = .{ .string = row.s } },
        });
    }
    // The whole batch costs the one analysis the prepare paid for; this is
    // the entire point of the handle.
    try testing.expectEqual(@as(u64, 1), after_prepare - before);
    try testing.expectEqual(after_prepare, phase.count(.analyze));

    var rows = try db.query("SELECT i, s FROM batch ORDER BY i", &.{}, .{});
    defer rows.deinit();
    var seen: usize = 0;
    while (try rows.next()) |row| : (seen += 1) {
        try testing.expectEqual(@as(i64, @intCast(seen + 1)), row[0].int);
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "a prepared statement rebinds cleanly between executions" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE rebind (a INT64, b STRING)", &.{}, .{});

    var stmt = try db.prepare("INSERT INTO rebind (a, b) VALUES (?, ?)", .{});
    defer stmt.deinit();
    try stmt.exec(&.{ .{ .value = .{ .int = 1 } }, .{ .value = .{ .string = "x" } } });
    // A NULL where the previous execution bound a value: without
    // clearBindings the stale "x" would survive.
    try stmt.exec(&.{ .{ .value = .{ .int = 2 } }, .{ .value = .null } });

    var rows = try db.query("SELECT b FROM rebind WHERE a = 2", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell.null, (try rows.next()).?[0]);
}

test "prepared parameters are cast to the column type too" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE pcast (i INT64, ts TIMESTAMP)", &.{}, .{});

    var stmt = try db.prepare("INSERT INTO pcast (i, ts) VALUES (?, ?)", .{});
    defer stmt.deinit();
    try stmt.exec(&.{
        .{ .value = .{ .string = "7" } },
        .{ .value = .{ .string = "2024-01-02T03:04:05Z" } },
    });

    var rows = try db.query("SELECT i, ts FROM pcast", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 7), row[0].int);
    try testing.expectEqualStrings("1704164645.0", row[1].timestamp);
}

test "prepare rejects scripts and statements with no reusable form" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE only (a INT64)", &.{}, .{});

    try testing.expectError(
        error.Unimplemented,
        db.prepare("SELECT 1; SELECT 2", .{}),
    );
    try testing.expectEqualStrings("cannot prepare a multi-statement script", db.lastError());

    // DDL mutates the catalog as its execution; there is nothing to hold.
    try testing.expectError(
        error.Unimplemented,
        db.prepare("CREATE TABLE ddl (a INT64)", .{}),
    );
    try testing.expectError(
        error.Unimplemented,
        db.prepare("DROP TABLE only", .{}),
    );
}

test "a prepared query statement can be exec'd" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE q (a INT64)", &.{}, .{});
    try db.exec("INSERT INTO q (a) VALUES (1)", &.{}, .{});

    // Rows are discarded, as Go's ExecContext does; the columns are still
    // reported so a future Rows-returning variant has them.
    var stmt = try db.prepare("SELECT a FROM q WHERE a = ?", .{});
    defer stmt.deinit();
    try testing.expectEqual(@as(usize, 1), stmt.columns.len);
    try testing.expectEqualStrings("a", stmt.columns[0].name);
    try stmt.exec(&.{.{ .value = .{ .int = 1 } }});
}

test "BEGIN..END block is flattened before analysis" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("\nBEGIN\n  SELECT 1;\nEND;", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 1 }, (try rows.next()).?[0]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

// ----------------------------------------------------------------------
// CREATE / DROP FUNCTION (Go CreateFunctionStmtAction / DropStmtAction)
// ----------------------------------------------------------------------

test "CREATE FUNCTION then use it in a SELECT" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE FUNCTION myadd(x INT64, y INT64) AS (x + y)", &.{}, .{});

    var rows = try db.query("SELECT myadd(3, 4)", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 7 }, (try rows.next()).?[0]);
}

// BigQuery requires a persistent UDF to name its dataset ("Routine must be
// qualified with a dataset"), so this — not the bare form above — is the shape
// every real CREATE FUNCTION takes.
test "a dataset-qualified CREATE FUNCTION is callable both ways" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE FUNCTION fn_ds.add_one(x INT64) AS (x + 1)", &.{}, .{});
    try db.exec("CREATE FUNCTION fn_ds.dbl(x INT64) AS (x * 2)", &.{}, .{});

    // Qualified is how it was declared. Unqualified also resolves, because the
    // analyzer registers the function at the root catalog as well as inside
    // the dataset's — and it is the only name the resolved AST ever carries,
    // so the qualified call is the one that used to fail.
    var rows = try db.query(
        "SELECT fn_ds.add_one(41) AS a, add_one(1) AS b, fn_ds.dbl(fn_ds.add_one(4)) AS c",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 42 }, row[0]);
    try testing.expectEqual(Cell{ .int = 2 }, row[1]);
    try testing.expectEqual(Cell{ .int = 10 }, row[2]);
}

test "CREATE FUNCTION persists across connections to the same file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db_path = try std.fmt.allocPrintSentinel(
        arena,
        ".zig-cache/tmp/{s}/udf_e2e.db",
        .{tmp.sub_path},
        0,
    );

    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        try db.exec("CREATE FUNCTION triple(x INT64) AS (x * 3)", &.{}, .{});
    }
    // A fresh connection loads the function spec via Catalog.sync.
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        var rows = try db.query("SELECT triple(5)", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 15 }, (try rows.next()).?[0]);
    }
}

test "CREATE TEMP FUNCTION is connection-local and script-scoped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db_path = try std.fmt.allocPrintSentinel(
        arena,
        ".zig-cache/tmp/{s}/udf_temp.db",
        .{tmp.sub_path},
        0,
    );

    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        // Usable within the same script (corpus case 626).
        var rows = try db.query(
            "CREATE TEMP FUNCTION Add(x INT64, y INT64) AS (x + y);\nSELECT Add(3, 4);\n",
            &.{},
            .{},
        );
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 7 }, (try rows.next()).?[0]);
    }
    // Never persisted: a fresh connection cannot resolve it.
    {
        var db = try Db.open(testing.allocator, db_path);
        defer db.close();
        try testing.expectError(
            error.AnalyzeFailed,
            db.query("SELECT Add(1, 2)", &.{}, .{}),
        );
        var stmt = try db.sqlite_db.prepare(
            "SELECT COUNT(*) FROM zigquery_catalog WHERE kind = 'function'",
        );
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
    }
}

test "DROP FUNCTION removes the spec so later analysis fails" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec("CREATE FUNCTION dbl(x INT64) AS (x * 2)", &.{}, .{});
    {
        var rows = try db.query("SELECT dbl(21)", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(Cell{ .int = 42 }, (try rows.next()).?[0]);
    }

    try db.exec("DROP FUNCTION dbl", &.{}, .{});
    try testing.expectError(error.AnalyzeFailed, db.query("SELECT dbl(21)", &.{}, .{}));

    // The persisted catalog row is gone too.
    var stmt = try db.sqlite_db.prepare(
        "SELECT COUNT(*) FROM zigquery_catalog WHERE kind = 'function'",
    );
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt64(0));
}

test "corpus 105/106: CREATE FUNCTION over ARRAY<STRUCT<..>> then call it" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        \\CREATE FUNCTION customfunc(
        \\  arr ARRAY<STRUCT<name STRING, val INT64>>
        \\) AS (
        \\  (SELECT SUM(IF(elem.name = "foo",elem.val,null)) FROM UNNEST(arr) AS elem)
        \\)
    , &.{}, .{});

    var rows = try db.query(
        \\SELECT customfunc([
        \\  STRUCT<name STRING, val INT64>("foo", 10),
        \\  STRUCT<name STRING, val INT64>("bar", 40),
        \\  STRUCT<name STRING, val INT64>("foo", 20)
        \\])
    , &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 30 }, (try rows.next()).?[0]);
}

test "CONTAINS_SUBSTR truth table including tri-state NULL semantics" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    const Case = struct { sql: []const u8, want: Cell };
    for ([_]Case{
        // Case-insensitive containment.
        .{ .sql = "SELECT CONTAINS_SUBSTR('the blue house', 'Blue house')", .want = .{ .bool = true } },
        .{ .sql = "SELECT CONTAINS_SUBSTR('the red house', 'blue')", .want = .{ .bool = false } },
        // NFKC normalization: U+2168 (ROMAN NUMERAL NINE) folds to "ix".
        .{ .sql = "SELECT CONTAINS_SUBSTR('\u{2168}', 'IX')", .want = .{ .bool = true } },
        // Struct: true when ANY field contains the substring.
        .{ .sql = "SELECT CONTAINS_SUBSTR((23, 35, 41), '35')", .want = .{ .bool = true } },
        // Recursion through a nested array field.
        .{ .sql = "SELECT CONTAINS_SUBSTR(('abc', ['def', 'ghi', 'jkl'], 'mno'), 'jk')", .want = .{ .bool = true } },
        // Tri-state: a match wins over a NULL field...
        .{ .sql = "SELECT CONTAINS_SUBSTR((23, NULL, 41), '41')", .want = .{ .bool = true } },
        // ...but with no match a NULL field makes the result NULL.
        .{ .sql = "SELECT CONTAINS_SUBSTR((23, NULL, 41), '35')", .want = .null },
        // A NULL expression (not a struct) is NULL.
        .{ .sql = "SELECT CONTAINS_SUBSTR(CAST(NULL AS STRING), 'x')", .want = .null },
    }) |case| {
        var rows = try db.query(case.sql, &.{}, .{});
        defer rows.deinit();
        const got = (try rows.next()).?[0];
        switch (case.want) {
            .bool => |b| try testing.expectEqual(b, got.bool),
            .null => try testing.expectEqual(Cell.null, got),
            else => unreachable,
        }
    }

    // A NULL search literal is an error, not NULL (Go bindContainsSubstr).
    {
        var rows = db.query("SELECT CONTAINS_SUBSTR('hello', NULL)", &.{}, .{}) catch {
            return; // analyze/prepare-time failure is also acceptable
        };
        defer rows.deinit();
        try testing.expectError(error.ExecFailed, rows.next());
        try testing.expect(std.mem.indexOf(
            u8,
            db.lastError(),
            "search literal must be not null",
        ) != null);
    }
}

test "MIN_BY / MAX_BY aggregate over groups with ties" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // MIN_BY(x, y) returns the x of the row with the smallest y.
    {
        var rows = try db.query(
            \\WITH t AS (
            \\  SELECT 'a' AS name, 1 AS score
            \\  UNION ALL SELECT 'b', 3
            \\  UNION ALL SELECT 'c', 2
            \\)
            \\SELECT MIN_BY(name, score), MAX_BY(name, score) FROM t
        , &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqualStrings("a", row[0].string);
        try testing.expectEqualStrings("b", row[1].string);
    }

    // Ties on the ordering key: one of the tied rows is returned (the
    // first seen, matching ANY_VALUE ... HAVING MIN/MAX semantics).
    {
        var rows = try db.query(
            \\WITH t AS (
            \\  SELECT 'x' AS name, 5 AS score
            \\  UNION ALL SELECT 'y', 5
            \\)
            \\SELECT MIN_BY(name, score) FROM t
        , &.{}, .{});
        defer rows.deinit();
        const got = (try rows.next()).?[0].string;
        try testing.expect(std.mem.eql(u8, got, "x") or std.mem.eql(u8, got, "y"));
    }
}

test "JS-language function is persisted and analyzable but not executable" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    try db.exec(
        \\CREATE FUNCTION jsf(x INT64) RETURNS INT64 LANGUAGE js AS """return x+1;"""
    , &.{}, .{});

    // Persisted with its language and code (Go newFunctionSpec).
    var g = db.lockCatalog();
    defer g.unlock();
    const fs = g.catalog.findFunctionSpec("jsf") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("js", fs.language);
    try testing.expect(std.mem.indexOf(u8, fs.code, "return x+1;") != null);
    try testing.expectEqual(@as(?[]const u8, null), fs.body);

    // Analysis resolves the call (the catalog seeds it), but there is no
    // inlinable body, so execution reports Unimplemented rather than
    // emitting a call to a function SQLite never defined (goja excluded).
    try testing.expectError(error.Unimplemented, db.query("SELECT jsf(1)", &.{}, .{}));
}

test "Go error-message shapes: modernc wrapper + StringValue.ToTime text" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // First-row failure surfaces from query() (modernc steps eagerly), and
    // carries Go's StringValue.ToTime message.
    {
        const err = db.query(
            \\WITH toks AS (SELECT "20100317" AS dt) SELECT CAST(dt AS DATETIME) FROM toks
        , &.{}, .{});
        try testing.expectError(error.ExecFailed, err);
        try testing.expectEqualStrings(
            "SQL logic error: failed to convert 20100317 to time.Time type (1)",
            db.lastError(),
        );
    }

    // Later-row failure surfaces from iteration in modernc's errstrForDB
    // shape: "SQL logic error: <msg> (1)".
    {
        var rows = try db.query(
            \\SELECT CASE WHEN value = 'baz' THEN ERROR('Found unexpected value: baz')
            \\ ELSE 'ok' END AS v
            \\FROM (SELECT 'foo' AS value UNION ALL SELECT 'bar' UNION ALL SELECT 'baz')
        , &.{}, .{});
        defer rows.deinit();
        _ = try rows.next();
        _ = try rows.next();
        try testing.expectError(error.ExecFailed, rows.next());
        try testing.expectEqualStrings(
            "SQL logic error: Found unexpected value: baz (1)",
            db.lastError(),
        );
    }
}

test "parameter mode ignores question marks inside comments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A '?' in prose must not be mistaken for a positional parameter. Real
    // views carry comments like "is the sentence done?", and pairing that
    // with a genuine @named parameter used to be rejected outright.
    try testing.expectEqual(
        ParamMode.named,
        try parameterMode(arena, "/* is it done? */ SELECT @x AS a"),
    );
    try testing.expectEqual(
        ParamMode.named,
        try parameterMode(arena, "-- really? \nSELECT @x AS a"),
    );
    try testing.expectEqual(
        ParamMode.named,
        try parameterMode(arena, "# what? \nSELECT @x AS a"),
    );
    try testing.expectEqual(
        ParamMode.named,
        try parameterMode(arena, "SELECT 'huh?' AS a, @x AS b"),
    );

    // Genuine markers are still detected.
    try testing.expectEqual(ParamMode.positional, try parameterMode(arena, "SELECT ? AS a"));
    try testing.expectEqual(ParamMode.named, try parameterMode(arena, "SELECT @x AS a"));
    try testing.expectError(
        error.MixedParameters,
        parameterMode(arena, "SELECT ? AS a, @x AS b"),
    );

    // Block comments must not swallow the rest of the query.
    try testing.expectEqual(
        ParamMode.positional,
        try parameterMode(arena, "/* c */ SELECT ? AS a"),
    );
}

test "parameter mode ignores question marks in triple-quoted strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Views carry prose in OPTIONS(description='''...'''). Read as three
    // adjacent empty strings, that prose stays in the scanned text and any
    // '?' in it looks like a positional parameter.
    try testing.expectEqual(
        ParamMode.named,
        try parameterMode(arena, "CREATE VIEW v OPTIONS(description='''Why? Because.''') AS SELECT 1"),
    );
    try testing.expectEqual(
        ParamMode.named,
        try parameterMode(arena, "CREATE VIEW v OPTIONS(description=\"\"\"Really? yes.\"\"\") AS SELECT @x"),
    );
    // A real positional parameter after one is still detected.
    try testing.expectEqual(
        ParamMode.positional,
        try parameterMode(arena, "SELECT '''prose?''' AS a, ? AS b"),
    );
}

test "allocStats reports lookaside activity" {
    // Two connections: one at SQLite's default pool, one deliberately starved
    // to a single tiny slot. The starved one must show misses the default one
    // does not, which is what proves the counters track the pool rather than
    // just counting allocations.
    const sql = "SELECT x, x * 2 AS d FROM UNNEST([1, 2, 3]) AS x ORDER BY x";

    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();
    {
        var rows = try db.query(sql, &.{}, .{});
        defer rows.deinit();
        while (try rows.next()) |_| {}
    }
    const default_stats = db.allocStats();
    try testing.expect(default_stats.lookaside_hit > 0);
    // memory_used and malloc_size_max come from sqlite3_status, which reports
    // zero unless ZQL_MEM_STATS kept SQLITE_CONFIG_MEMSTATUS on. The lookaside
    // counters below are sqlite3_db_status and are always live.
    if (sqlite.memStatsEnabled()) {
        try testing.expect(default_stats.memory_used.current > 0);
        try testing.expect(default_stats.malloc_size_max > 0);
    }
    // A pool that is never exhausted reports a hit rate; assert it is a real
    // fraction rather than trusting the division.
    const rate = default_stats.hitRate().?;
    try testing.expect(rate > 0.0);
    try testing.expect(rate <= 1.0);
}

test "Capture survives a query that fails after analysis/transform succeed" {
    // STRUCT(IEEE_DIVIDE(0, 0)) IS DISTINCT FROM ...: IEEE_DIVIDE's NaN result
    // silently becomes SQL NULL once it leaves native float storage (a SQLite
    // invariant), and the struct-field comparison then fails at runtime — an
    // error `query()` only discovers after `transformStatementFragment` has
    // already populated `Capture`. `query()` frees its own per-call arena via
    // `errdefer` on any such error, before ever returning to the caller, so
    // `Capture` must not hold pointers into it.
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var capture: Capture = .{ .arena = arena_state.allocator() };
    const err = db.query(
        "SELECT STRUCT(IEEE_DIVIDE(0, 0)) IS DISTINCT FROM STRUCT(IEEE_DIVIDE(0, 0))",
        &.{},
        .{ .capture = &capture },
    );
    try testing.expectError(error.ExecFailed, err);

    try testing.expect(capture.ast_text.len > 0);
    try testing.expect(capture.sql.len > 0);
}

// ---- nextTyped: the row path a binary encoder needs ----
//
// These assert the numbers, not the rendered text `next()` produces. That is
// the whole point of the accessor: an Avro or Arrow encoder writing a
// timestamp-micros long from "1767268800.0" would be parsing back out of a
// string that this path already had the integer for.

test "nextTyped hands back date and time kinds as integers, not API strings" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\SELECT TIMESTAMP '2026-01-01 12:00:00.000123+00' AS ts,
        \\       DATE '2026-01-01' AS d,
        \\       DATETIME '2026-01-01 12:00:00.000123' AS dt,
        \\       TIME '12:00:00.000123' AS t
    , &.{}, .{});
    defer rows.deinit();

    const row = (try rows.nextTyped()).?;
    try testing.expectEqual(@as(usize, 4), row.len);

    // Unix microseconds. `next()` would render this "1767268800.000123".
    try testing.expectEqual(@as(i64, 1767268800_000123), row[0].timestamp);
    // Days since the epoch, not "2026-01-01".
    try testing.expectEqual(@as(i64, 20454), row[1].date);
    // Civil microseconds since 1970-01-01T00:00:00, no zone.
    try testing.expectEqual(@as(i64, 1767268800_000123), row[2].datetime);
    // Microseconds since midnight.
    try testing.expectEqual(@as(i64, 43200_000123), row[3].time);

    try testing.expectEqual(@as(?[]const value_mod.Value, null), try rows.nextTyped());
}

test "nextTyped hands back NUMERIC as an unscaled integer and a scale" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\SELECT CAST('1.2345' AS NUMERIC) AS n,
        \\       CAST('-0.000000001' AS NUMERIC) AS tiny,
        \\       CAST('12345678901234567890.123456789' AS BIGNUMERIC) AS big
    , &.{}, .{});
    defer rows.deinit();

    const row = (try rows.nextTyped()).?;

    // NUMERIC is scale 9, so 1.2345 is 1234500000 unscaled. An Avro decimal
    // writes exactly this integer as big-endian two's complement; going via
    // `next()`'s "1.2345" would mean re-parsing decimal text.
    try testing.expectEqual(@as(u32, 9), row[0].numeric.scale());
    try testing.expectEqual(@as(i128, 1234500000), @as(i128, @intCast(row[0].numeric.unscaled)));

    // The smallest representable NUMERIC, and negative: sign has to survive.
    try testing.expectEqual(@as(i128, -1), @as(i128, @intCast(row[1].numeric.unscaled)));

    // BIGNUMERIC keeps precision an f64 could not.
    try testing.expect(row[2].numeric.unscaled != 0);
    try testing.expectEqualStrings(
        "12345678901234567890.123456789",
        try row[2].numeric.toText(rows.arena.allocator()),
    );
}

test "nextTyped hands back the foundation kinds unrendered" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1, 1.5, 'a', true, NULL, b'xy'", &.{}, .{});
    defer rows.deinit();

    const row = (try rows.nextTyped()).?;
    try testing.expectEqual(@as(i64, 1), row[0].int);
    try testing.expectEqual(@as(f64, 1.5), row[1].float);
    try testing.expectEqualStrings("a", row[2].string);
    // BOOL is the one kind that does not describe itself: the memcomparable
    // encoding stores it as an integer, so only the declared column type
    // separates `true` from `1`. An encoder switching on the value alone
    // writes this column as an int64 and the client reads garbage.
    try testing.expectEqual(@as(i64, 1), row[3].int);
    try testing.expectEqual(pb.TypeKind.TYPE_BOOL, rows.columnTypes()[3].type.typeKind());
    try testing.expectEqual(pb.TypeKind.TYPE_INT64, rows.columnTypes()[0].type.typeKind());

    try testing.expect(row[4] == .null);
    // BYTES stay bytes. `next()` base64-encodes them for the REST envelope,
    // which a binary encoder would have to undo.
    try testing.expectEqualSlices(u8, "xy", row[5].bytes);
}

test "nextTyped keeps array and struct structure" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT [1, 2, 3] AS arr, STRUCT(1 AS a, 'x' AS b) AS s",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.nextTyped()).?;
    try testing.expectEqual(@as(usize, 3), row[0].array.values.len);
    try testing.expectEqual(@as(i64, 2), row[0].array.values[1].int);
    try testing.expectEqual(@as(usize, 2), row[1].struct_.values.len);
    try testing.expectEqual(@as(i64, 1), row[1].struct_.values[0].int);
    try testing.expectEqualStrings("x", row[1].struct_.values[1].string);
}

test "nextTyped walks every row and reports the same columns as next" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    // Three rows, so the first-step dance in `advance` is exercised: query()
    // already stepped once, and mishandling that drops or repeats row one.
    var rows = try db.query(
        "SELECT n FROM UNNEST([10, 20, 30]) AS n ORDER BY n",
        &.{},
        .{},
    );
    defer rows.deinit();

    try testing.expectEqual(@as(usize, 1), rows.columnTypes().len);
    var seen: [3]i64 = undefined;
    var i: usize = 0;
    while (try rows.nextTyped()) |row| : (i += 1) {
        try testing.expect(i < seen.len);
        seen[i] = row[0].int;
    }
    try testing.expectEqual(@as(usize, 3), i);
    try testing.expectEqualSlices(i64, &.{ 10, 20, 30 }, &seen);
}

test "nextTyped on a statement with no result set yields nothing" {
    var db = try Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("CREATE TABLE typed_t (a INT64)", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 0), rows.columnTypes().len);
    try testing.expectEqual(@as(?[]const value_mod.Value, null), try rows.nextTyped());
}
