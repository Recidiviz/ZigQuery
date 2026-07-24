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

pub const Error = error{
    Unimplemented,
    /// GoogleSQL analysis failed (message in Db.lastError / analyzer_ffi.last_error).
    AnalyzeFailed,
    /// AST -> SQLite transformation failed (non-Unimplemented pipeline error).
    TransformFailed,
    /// SQLite prepare/step failed (message in Db.lastError).
    ExecFailed,
    /// Result-cell decoding failed.
    DecodeFailed,
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
    date: []const u8, // civil date rendered as YYYY-MM-DD, like Go returns
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
};

pub const QueryOptions = struct {
    /// Deterministic CURRENT_* time injection (go-zetasqlite WithCurrentTime).
    current_time_unix_micros: ?i64 = null,
};

/// One output column of a QueryStmt (Go ColumnSpec: name + spec Type).
const OutputColumn = struct {
    name: []const u8,
    type: *spec.Type,
};

pub const Db = struct {
    gpa: std.mem.Allocator,
    sqlite_db: sqlite.Db,
    udf_state: *function.State,
    catalog: *catalog_mod.Catalog,
    last_error: ?[]u8 = null,

    pub fn open(gpa: std.mem.Allocator, path: [:0]const u8) Error!*Db {
        const db = try gpa.create(Db);
        errdefer gpa.destroy(db);
        db.* = .{
            .gpa = gpa,
            .sqlite_db = try sqlite.Db.open(path),
            .udf_state = undefined,
            .catalog = undefined,
        };
        errdefer db.sqlite_db.close();
        // zetasqlite_* UDFs + collation (Go: RegisterFunctions in driver init).
        db.udf_state = function.registerAll(&db.sqlite_db, gpa) catch
            return error.ExecFailed;
        errdefer db.udf_state.deinit();
        // zetasqlite_catalog tables + initial sync (Go: Catalog.Sync at the
        // top of Analyzer.Analyze; done eagerly here and re-checked per
        // query via syncCatalog).
        db.catalog = try catalog_mod.Catalog.init(gpa);
        errdefer db.catalog.deinit();
        db.catalog.sync(&db.sqlite_db) catch return error.ExecFailed;
        return db;
    }

    pub fn close(db: *Db) void {
        db.clearLastError();
        db.catalog.deinit();
        db.sqlite_db.close();
        db.udf_state.deinit();
        db.gpa.destroy(db);
    }

    /// Diagnostic message for the last failed query/exec call.
    pub fn lastError(db: *Db) []const u8 {
        return db.last_error orelse "";
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

        return .{
            .arena = arena_state,
            .db = db,
            .stmt = prepared.stmt,
            .cols = prepared.columns,
            .names = names,
        };
    }

    /// Mirrors Go ExecContext: run every statement to completion.
    pub fn exec(db: *Db, sql: []const u8, args: []const Param, opts: QueryOptions) Error!void {
        var arena_state = std.heap.ArenaAllocator.init(db.gpa);
        defer arena_state.deinit();
        _ = try db.runStatements(arena_state.allocator(), sql, args, opts, .exec);
    }

    const Mode = enum { query, exec };

    /// Result of running a statement script. A null `stmt` mirrors Go's
    /// empty &Rows{conn} returned when the last statement is not a query
    /// (DML/DDL executed to completion; Rows yields no rows).
    const Prepared = struct {
        stmt: ?sqlite.Stmt = null,
        columns: []const OutputColumn = &.{},
    };

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
        const sqlz = try arena.dupeZ(u8, sql);
        var offset: usize = 0;

        // Go Analyzer.Analyze: catalog sync before analysis.
        db.catalog.sync(&db.sqlite_db) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                db.setLastError(db.sqlite_db.errmsg());
                return error.ExecFailed;
            },
        };

        while (true) {
            // Re-rendered per statement: DDL/DML actions mutate the
            // catalog between statements of one script.
            const catalog_json = db.catalog.catalogJson(arena) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    db.setLastError(@errorName(err));
                    return error.AnalyzeFailed;
                },
            };
            const analyzed = analyzer_ffi.analyzeNextStatement(arena, sqlz, offset, catalog_json) catch |err| {
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        db.setLastError(analyzer_ffi.last_error);
                        return error.AnalyzeFailed;
                    },
                }
            };
            offset = analyzed.resume_offset;
            const last = analyzed.at_end;

            const stmt_node = statementNodeOf(analyzed.node) orelse return error.Unimplemented;
            switch (stmt_node) {
                .resolved_query_stmt_node => |query_stmt| {
                    const formatted = try transformStatement(db, arena, analyzed.node, opts);

                    var stmt = db.sqlite_db.prepare(formatted) catch {
                        db.setLastError(db.sqlite_db.errmsg());
                        return error.ExecFailed;
                    };
                    errdefer stmt.finalize();
                    try db.bindParams(arena, &stmt, args);

                    if (last and mode == .query) {
                        return .{
                            .stmt = stmt,
                            .columns = try outputColumns(arena, query_stmt),
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
                    try db.execCreateStatement(arena, analyzed.node, create_any, args, opts);
                },
                // Go newDMLStmtAction: exec the formatted DML SQL.
                .resolved_insert_stmt_node,
                .resolved_update_stmt_node,
                .resolved_delete_stmt_node,
                => {
                    const formatted = try transformStatement(db, arena, analyzed.node, opts);
                    try db.execSql(arena, formatted, args);
                },
                .resolved_drop_stmt_node => |drop_stmt| {
                    try db.execDropStatement(arena, analyzed.node, drop_stmt, args, opts);
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

            if (last) return if (mode == .query) Prepared{} else null;
        }
    }

    /// Prepares `sql_text`, binds `args`, and steps it to completion
    /// (Go conn.ExecContext used by every non-query action).
    fn execSql(db: *Db, arena: std.mem.Allocator, sql_text: []const u8, args: []const Param) Error!void {
        var stmt = db.sqlite_db.prepare(sql_text) catch {
            db.setLastError(db.sqlite_db.errmsg());
            return error.ExecFailed;
        };
        defer stmt.finalize();
        try db.bindParams(arena, &stmt, args);
        while (stmt.step() catch {
            db.setLastError(db.sqlite_db.errmsg());
            return error.ExecFailed;
        }) {}
    }

    fn failCatalog(db: *Db, err: catalog_mod.Error) Error {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        db.setLastError(@errorName(err));
        return error.ExecFailed;
    }

    /// Go newStmtAction's CREATE dispatch: table / table-as-select / view;
    /// CREATE FUNCTION belongs to the UDF milestone.
    fn execCreateStatement(
        db: *Db,
        arena: std.mem.Allocator,
        node: *pb.AnyResolvedNodeProto,
        create_any: *const pb.AnyResolvedCreateStatementProto,
        args: []const Param,
        opts: QueryOptions,
    ) Error!void {
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
                        return db.execCreateView(arena, node, cv, opts);
                    },
                    else => return error.Unimplemented,
                }
            },
            // CREATE FUNCTION: JS/SQL UDF milestone.
            else => return error.Unimplemented,
        }
    }

    /// Go CreateTableStmtAction for a plain CREATE TABLE (spec built by
    /// newTableSpec; exec runs spec.SQLiteSchema).
    fn execCreateTable(
        db: *Db,
        arena: std.mem.Allocator,
        ct: *const pb.ResolvedCreateTableStmtProto,
        args: []const Param,
    ) Error!void {
        const base = ct.parent orelse return error.TransformFailed;
        const create = base.parent orelse return error.TransformFailed;
        const table_spec = try newTableSpecFromCreate(arena, create, base, "");
        try db.execCreateTableAction(arena, table_spec, args);
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
    ) Error!void {
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
        try db.execCreateTableAction(arena, table_spec, args);
    }

    /// Shared CreateTableStmtAction.exec body: OR REPLACE drops first,
    /// exec the schema DDL, register the spec (persisted unless temp).
    fn execCreateTableAction(
        db: *Db,
        arena: std.mem.Allocator,
        table_spec: *spec.TableSpec,
        args: []const Param,
    ) Error!void {
        const table_name = try table_spec.tableName(arena);
        if (table_spec.create_mode == spec.create_mode_create_or_replace) {
            const drop_sql = try std.fmt.allocPrint(arena, "DROP TABLE IF EXISTS `{s}`", .{table_name});
            try db.execSql(arena, drop_sql, &.{});
        }
        const schema = table_spec.sqliteSchema(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransformFailed,
        };
        try db.execSql(arena, schema, args);
        // IF NOT EXISTS on an already-registered table keeps the existing
        // spec. Go's exec unconditionally upserts the JSON spec, but its
        // live engine catalog keeps the first registration
        // (AddOwnedTableIfNotPresent), so the old schema stays visible;
        // this port re-renders the analyzer catalog from the spec map per
        // statement, so skipping the upsert reproduces Go's observable
        // (and BigQuery's actual) no-op semantics.
        if (table_spec.create_mode == spec.create_mode_create_if_not_exists and
            db.catalog.findTableSpec(table_name) != null)
        {
            return;
        }
        db.catalog.addNewTableSpec(&db.sqlite_db, table_spec) catch |err|
            return db.failCatalog(err);
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
        const table_spec = try arena.create(spec.TableSpec);
        table_spec.* = .{
            .is_temp = (create.create_scope orelse .CREATE_DEFAULT_SCOPE) == .CREATE_TEMP,
            .is_view = true,
            .name_path = try normalizePath(arena, create.name_path),
            .columns = columns,
            .create_mode = goCreateMode(create.create_mode),
            .query = query_str,
            .updated_at = now.rfc3339,
            .created_at = now.rfc3339,
        };

        if (table_spec.create_mode == spec.create_mode_create_or_replace) {
            const drop_sql = try std.fmt.allocPrint(
                arena,
                "DROP VIEW IF EXISTS `{s}`",
                .{try table_spec.tableName(arena)},
            );
            try db.execSql(arena, drop_sql, &.{});
        }
        const create_sql = fragment.toString(arena) catch return error.OutOfMemory;
        try db.execSql(arena, create_sql, &.{});
        db.catalog.addNewTableSpec(&db.sqlite_db, table_spec) catch |err|
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
    ) Error!void {
        const object_type = drop_stmt.object_type orelse "";
        if (!std.mem.eql(u8, object_type, "TABLE") and !std.mem.eql(u8, object_type, "VIEW")) {
            // Go: "currently unsupported DROP %s statement" (FUNCTION is a
            // separate node kind handled by the UDF milestone).
            return error.Unimplemented;
        }
        const formatted = try transformStatement(db, arena, node, opts);
        try db.execSql(arena, formatted, args);

        const name = try formatNamePath(arena, drop_stmt.name_path);
        db.catalog.deleteTableSpec(&db.sqlite_db, name) catch |err|
            return db.failCatalog(err);
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
        try db.execSql(arena, sql_text, &.{});
    }

    fn bindParams(
        db: *Db,
        arena: std.mem.Allocator,
        stmt: *sqlite.Stmt,
        args: []const Param,
    ) Error!void {
        if (args.len == 0) return;
        const count: i32 = @intCast(sqlite.c.sqlite3_bind_parameter_count(stmt.handle));
        var idx: i32 = 1;
        for (args) |param| {
            if (idx > count) break;
            // Named parameters arrive with the parameter-transformer task.
            if (param.name != null) return error.Unimplemented;
            const v = valueFromCell(arena, param.value) catch |err| return db.failDecode(err);
            const repr = encoder.EncodeValue(arena, v) catch |err| return db.failDecode(err);
            switch (repr) {
                .null => try stmt.bindNull(idx),
                .int => |i| try stmt.bindInt64(idx, i),
                .float => |f| try stmt.bindDouble(idx, f),
                .text => |t| try stmt.bindText(idx, t),
            }
            idx += 1;
        }
    }

    fn failDecode(db: *Db, err: anyerror) Error {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        db.setLastError(@errorName(err));
        return error.DecodeFailed;
    }
};

/// Transforms one analyzed statement into its SQL fragment.
fn transformStatementFragment(
    db: ?*Db,
    arena: std.mem.Allocator,
    node: *pb.AnyResolvedNodeProto,
    opts: QueryOptions,
) Error!sqlbuilder.SQLFragment {
    const config = try arena.create(context_mod.TransformConfig);
    config.* = context_mod.defaultTransformConfig();
    const ctx = try context_mod.TransformContext.init(arena, config);
    ctx.query_ctx.current_time_unix_micros = opts.current_time_unix_micros;

    var coordinator = coordinator_mod.QueryCoordinator.init(arena);
    return coordinator.transformStatementNode(node, ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unimplemented => return error.Unimplemented,
        else => {
            if (db) |d| d.setLastError(@errorName(err));
            return error.TransformFailed;
        },
    };
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
        columns[i] = col;
    }
    return columns;
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
    };
    return table_spec;
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

/// Cell -> Value for parameter binding (inverse of cellFromValue).
fn valueFromCell(alloc: std.mem.Allocator, cell: Cell) !value_mod.Value {
    switch (cell) {
        .null => return .null,
        .int => |i| return .{ .int = i },
        .float => |f| return .{ .float = f },
        .bool => |b| return .{ .bool = b },
        .string => |s| return .{ .string = s },
        .bytes => |b| return .{ .bytes = b },
        .date => |s| return .{ .date = try value_mod.parseDateDays(s) },
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
        .TYPE_BYTES => return .{ .bytes = try v.toBytes(alloc) },
        .TYPE_DATE => switch (v) {
            .date => |days| {
                var buf: [16]u8 = undefined;
                const s = value_mod.formatDateDays(&buf, days);
                return .{ .date = try alloc.dupe(u8, s) };
            },
            .string => |s| return .{ .date = try alloc.dupe(u8, s) },
            else => return error.FailedConversion,
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
                    .name = key,
                    .value = try cellFromValue(alloc, st.values[i], field_type),
                };
            }
            return .{ .struct_ = fields };
        },
        // Timestamp / numeric / json / datetime / time / interval defer with
        // their Value kinds.
        else => return error.Unimplemented,
    }
}

pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    db: *Db,
    stmt: ?sqlite.Stmt = null,
    cols: []const OutputColumn = &.{},
    names: []const []const u8 = &.{},

    pub fn columns(r: *Rows) []const []const u8 {
        return r.names;
    }

    /// Next row of decoded cells, or null when exhausted. Cells are valid
    /// until deinit() (per-query arena).
    pub fn next(r: *Rows) Error!?[]const Cell {
        var stmt = r.stmt orelse return null;
        const has_row = stmt.step() catch {
            r.db.setLastError(r.db.sqlite_db.errmsg());
            return error.ExecFailed;
        };
        if (!has_row) return null;

        const alloc = r.arena.allocator();
        const cells = try alloc.alloc(Cell, r.cols.len);
        for (r.cols, 0..) |col, i| {
            const ci: i32 = @intCast(i);
            const repr: encoder.SqliteRepr = switch (stmt.columnType(ci)) {
                .integer => .{ .int = stmt.columnInt64(ci) },
                .float => .{ .float = stmt.columnDouble(ci) },
                .text => .{ .text = stmt.columnText(ci) },
                .blob => .{ .text = stmt.columnBlob(ci) },
                .null => .null,
            };
            const value = encoder.DecodeValue(alloc, repr) catch |err|
                return r.db.failDecode(err);
            cells[i] = cellFromValue(alloc, value, col.type) catch |err|
                return r.db.failDecode(err);
        }
        return cells;
    }

    pub fn deinit(r: *Rows) void {
        if (r.stmt) |*stmt| stmt.finalize();
        r.stmt = null;
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
        "SELECT\n`x__1` AS `x`\nFROM (\nSELECT  \n1 AS `x__1`\n) AS `project_scan_3`",
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
    try testing.expectEqualStrings("xy", row[4].bytes);
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

        try db.catalog.addNewTableSpec(&db.sqlite_db, table_spec);
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
    try db.catalog.addNewTableSpec(&db.sqlite_db, table_spec);

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

    try db.exec(
        "CREATE TEMP TABLE tmp1 (a INT64); INSERT INTO tmp1 (a) VALUES (9)",
        &.{},
        .{},
    );
    var rows = try db.query("SELECT a FROM tmp1", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(Cell{ .int = 9 }, (try rows.next()).?[0]);

    // No zetasqlite_catalog row (Go AddNewTableSpec skips persist for temp).
    var stmt = try db.sqlite_db.prepare("SELECT COUNT(*) FROM zetasqlite_catalog");
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

    try db.exec(
        "CREATE TEMP TABLE tmp_ctas AS SELECT 'Kylie' AS FirstName UNION ALL SELECT 'Nick'",
        &.{},
        .{},
    );
    var rows = try db.query("SELECT FirstName FROM tmp_ctas ORDER BY FirstName", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqualStrings("Kylie", (try rows.next()).?[0].string);
    try testing.expectEqualStrings("Nick", (try rows.next()).?[0].string);
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
