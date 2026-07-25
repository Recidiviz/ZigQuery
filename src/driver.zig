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
    // Date/time kinds render as their Go ToApiString forms (what rows.go
    // hands back through database/sql): timestamp "sec.rem", datetime
    // "YYYY-MM-DDTHH:MM:SS.ffffff", time "HH:MM:SS.ffffff", interval canonical.
    timestamp: []const u8,
    datetime: []const u8,
    time: []const u8,
    interval: []const u8,
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

/// Parameter placeholder style of a query script (Go getParameterMode).
pub const ParamMode = enum { named, positional };

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
            db.catalog.deleteFunctionSpec(&db.sqlite_db, name) catch {};
        };

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
            const analyzed = analyzer_ffi.analyzeNextStatementOpts(arena, sqlz, offset, catalog_json, options_json) catch |err| {
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
                    consumed = try db.execCreateStatement(arena, analyzed.node, create_any, cur_args, opts);
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
                    consumed = try db.execDropStatement(arena, analyzed.node, drop_stmt, cur_args, opts);
                },
                // Go newDropFunctionStmtAction -> DropStmtAction with
                // objectType "FUNCTION": delete the catalog spec only (no
                // SQLite object exists for a UDF).
                .resolved_drop_function_stmt_node => |drop_fn| {
                    const name = try formatNamePath(arena, drop_fn.name_path);
                    db.catalog.deleteFunctionSpec(&db.sqlite_db, name) catch |err| {
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
            db.catalog.deleteTableSpec(&db.sqlite_db, name) catch {};
        }
    }

    /// Prepares `sql_text`, binds `args`, and steps it to completion
    /// (Go conn.ExecContext used by every non-query action). Returns the
    /// number of positional args consumed (0 in named mode).
    fn execSql(db: *Db, arena: std.mem.Allocator, sql_text: []const u8, args: []const Param) Error!usize {
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
        db.catalog.addNewFunctionSpec(&db.sqlite_db, fn_spec) catch |err|
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
        ctx.func_map = try db.catalog.funcMap(arena);

        var coordinator = coordinator_mod.QueryCoordinator.init(arena);
        var extractor = coordinator_mod.NodeExtractor{};
        const data = extractor.ExtractExpressionData(arena, expr, ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unimplemented => return error.Unimplemented,
            else => {
                db.setLastError(@errorName(err));
                return error.TransformFailed;
            },
        };
        const sql_expr = coordinator.transformExpression(data, ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unimplemented => return error.Unimplemented,
            else => {
                db.setLastError(@errorName(err));
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
        const table_name = try table_spec.tableName(arena);
        if (table_spec.create_mode == spec.create_mode_create_or_replace) {
            const drop_sql = try std.fmt.allocPrint(arena, "DROP TABLE IF EXISTS `{s}`", .{table_name});
            _ = try db.execSql(arena, drop_sql, &.{});
        }
        const schema = table_spec.sqliteSchema(arena) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransformFailed,
        };
        const consumed = try db.execSql(arena, schema, args);

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
            db.catalog.findTableSpec(table_name) != null)
        {
            return consumed;
        }
        db.catalog.addNewTableSpec(&db.sqlite_db, table_spec) catch |err|
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
            _ = try db.execSql(arena, drop_sql, &.{});
        }
        const create_sql = fragment.toString(arena) catch return error.OutOfMemory;
        _ = try db.execSql(arena, create_sql, &.{});
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
    ) Error!usize {
        const object_type = drop_stmt.object_type orelse "";
        if (!std.mem.eql(u8, object_type, "TABLE") and !std.mem.eql(u8, object_type, "VIEW")) {
            // Go: "currently unsupported DROP %s statement" (FUNCTION is a
            // separate node kind handled by the UDF milestone).
            return error.Unimplemented;
        }
        const formatted = try transformStatement(db, arena, node, opts);
        const consumed = try db.execSql(arena, formatted, args);

        const name = try formatNamePath(arena, drop_stmt.name_path);
        db.catalog.deleteTableSpec(&db.sqlite_db, name) catch |err|
            return db.failCatalog(err);
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
        const count = stmt.bindParameterCount();
        if (count <= 0) return 0;
        const ucount: usize = @intCast(count);

        // Go getArgsFromParams: fewer supplied values than placeholders.
        if (args.len < ucount) {
            db.setLastError("not enough query arguments");
            return error.ExecFailed;
        }

        switch (db.param_mode) {
            .positional => {
                var idx: i32 = 1;
                while (idx <= count) : (idx += 1) {
                    const ord: usize = @intCast(idx - 1);
                    const param_type = if (ord < db.stmt_params.len)
                        db.stmt_params[ord].type
                    else
                        null;
                    try db.bindCell(arena, stmt, idx, args[ord].value, param_type);
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
                        for (db.stmt_params) |p| {
                            if (std.ascii.eqlIgnoreCase(p.identifier, pname)) {
                                param_type = p.type;
                                break;
                            }
                        }
                    } else {
                        value = args[@intCast(idx - 1)].value;
                    }
                    try db.bindCell(arena, stmt, idx, value, param_type);
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
    ) Error!void {
        var v = valueFromCell(arena, cell) catch |err| return db.failDecode(err);
        if (param_type) |t| {
            v = castParamValue(arena, v, t) catch |err| return db.failDecode(err);
        }
        const repr = encoder.EncodeValue(arena, v) catch |err| return db.failDecode(err);
        switch (repr) {
            .null => try stmt.bindNull(idx),
            .int => |i| try stmt.bindInt64(idx, i),
            .float => |f| try stmt.bindDouble(idx, f),
            .text => |t| try stmt.bindText(idx, t),
        }
    }

    fn failDecode(db: *Db, err: anyerror) Error {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        db.setLastError(@errorName(err));
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
fn parameterMode(arena: std.mem.Allocator, sql: []const u8) error{ OutOfMemory, MixedParameters }!ParamMode {
    const stripped = try stripSQLLiterals(arena, sql);
    const has_positional = std.mem.indexOfScalar(u8, stripped, '?') != null;
    const has_named = hasNamedParam(stripped);
    if (has_named and has_positional) return error.MixedParameters;
    if (has_positional) return .positional;
    return .named;
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

/// Go stripSQLLiterals: blanks out single/double/backtick-quoted spans and
/// `--` line comments so parameter detection ignores `?`/`@` inside them.
fn stripSQLLiterals(arena: std.mem.Allocator, q: []const u8) error{OutOfMemory}![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.ensureTotalCapacity(arena, q.len);
    var quote: u8 = 0;
    var in_line_comment = false;
    var i: usize = 0;
    while (i < q.len) : (i += 1) {
        const c = q[i];
        if (in_line_comment) {
            if (c == '\n') {
                in_line_comment = false;
                try b.append(arena, c);
            }
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"' or c == '`') {
            quote = c;
        } else if (c == '-' and i + 1 < q.len and q[i + 1] == '-') {
            in_line_comment = true;
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
    const config = try arena.create(context_mod.TransformConfig);
    config.* = context_mod.defaultTransformConfig();
    const ctx = try context_mod.TransformContext.init(arena, config);
    ctx.query_ctx.current_time_unix_micros = opts.current_time_unix_micros;
    // Go analyzer.go: withFuncMap(ctx, catalog.getFunctions(namePath)) before
    // transforming, so the function transformer can inline UDF bodies
    // (transformer_function.go funcMapFromContext -> spec.CallSQL).
    if (db) |d| ctx.func_map = try d.catalog.funcMap(arena);

    var coordinator = coordinator_mod.QueryCoordinator.init(arena);
    const fragment = coordinator.transformStatementNode(node, ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unimplemented => return error.Unimplemented,
        else => {
            if (db) |d| d.setLastError(@errorName(err));
            return error.TransformFailed;
        },
    };
    // Surface the parameter occurrences (with resolved types) to the driver
    // so bindParams can cast bound values (Go getParamsFromNode +
    // EncodeNamedValues).
    if (db) |d| d.stmt_params = ctx.collected_params.items;
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
    const s = try fragment.toString(arena);
    if (std.c.getenv("DUMP_SQL") != null) std.debug.print("SQL>>> {s}\n", .{s});
    return s;
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
/// Casts a bound parameter value to its resolved parameter type, mirroring
/// the parts of Go CastValue that change the value shape: STRUCT types
/// re-project the fields in declared order (missing fields become NULL) and
/// ARRAY types cast every element. Scalar kinds pass through (the driver's
/// cells already carry matching scalar types).
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
            for (t.field_types, 0..) |field, i| {
                var key = field.name;
                if (key.len == 0) {
                    key = try std.fmt.allocPrint(alloc, "_field_{d}", .{i + 1});
                }
                keys[i] = key;
                if (sv.fieldByName(key)) |fv| {
                    values[i] = if (field.type) |ft| try castParamValue(alloc, fv, ft) else fv;
                } else {
                    values[i] = .null;
                }
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
        .date => |s| return .{ .date = try value_mod.parseDateDays(s) },
        // Inverse of cellFromValue: parse the rendered api strings back.
        .timestamp => |s| return .{ .timestamp = try value_mod.parseTimestampApi(s) },
        .datetime => |s| return .{ .datetime = try value_mod.parseDatetimeMicros(s) },
        .time => |s| return .{ .time = try value_mod.parseTimeMicros(s) },
        .interval => |s| return .{ .interval = try value_mod.parseIntervalValue(s) },
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
        // Go rows.go: castValueInternal wraps v.ToRat() in a NumericValue for
        // the column kind, then assignInterfaceValue renders ToApiString — a
        // plain decimal-string cell through database/sql.
        .TYPE_NUMERIC, .TYPE_BIGNUMERIC => {
            const n = value_mod.Numeric{
                .rat = try v.toRat(alloc),
                .is_bignumeric = typ.typeKind() == .TYPE_BIGNUMERIC,
            };
            return .{ .string = try n.toText(alloc) };
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
        // Remaining kinds (geography, proto, ...) defer with their Value kinds.
        else => return error.Unimplemented,
    }
}

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

    /// Next row of decoded cells, or null when exhausted. Cells are valid
    /// until deinit() (per-query arena).
    pub fn next(r: *Rows) Error!?[]const Cell {
        var stmt = r.stmt orelse return null;
        const has_row = if (r.first_step_done) blk: {
            r.first_step_done = false;
            break :blk r.first_has_row;
        } else stmt.step() catch {
            // Mid-iteration failures carry modernc's wrapped text verbatim
            // (go-zetasqlite does not re-wrap the iteration path).
            r.db.setLastSqliteError();
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

    // Temp tables live only within one query script (Go Cleanup), so create,
    // populate and read within a single script.
    var rows = try db.query(
        "CREATE TEMP TABLE tmp1 (a INT64); INSERT INTO tmp1 (a) VALUES (9); SELECT a FROM tmp1",
        &.{},
        .{},
    );
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
            "SELECT COUNT(*) FROM zetasqlite_catalog WHERE kind = 'function'",
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
        "SELECT COUNT(*) FROM zetasqlite_catalog WHERE kind = 'function'",
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
    const fs = db.catalog.findFunctionSpec("jsf") orelse return error.TestUnexpectedResult;
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
