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

    const Prepared = struct {
        stmt: sqlite.Stmt,
        columns: []const OutputColumn,
    };

    /// The Analyze loop: analyzer -> transform -> prepare per statement.
    /// In .query mode the prepared statement of the LAST statement is
    /// returned (earlier ones are prepared, then finalized unexecuted); in
    /// .exec mode every statement is stepped to completion and null is
    /// returned.
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
            // Re-rendered per statement: later DDL/DML tasks mutate the
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

            // Only QueryStmt is supported this milestone (Go dispatches
            // other statement kinds to dedicated actions).
            const query_stmt = queryStmtOf(analyzed.node) orelse return error.Unimplemented;

            const formatted = try transformStatement(db, arena, analyzed.node, opts);

            var stmt = db.sqlite_db.prepare(formatted) catch {
                db.setLastError(db.sqlite_db.errmsg());
                return error.ExecFailed;
            };
            errdefer stmt.finalize();
            try db.bindParams(arena, &stmt, args);

            if (analyzed.at_end and mode == .query) {
                return .{
                    .stmt = stmt,
                    .columns = try outputColumns(arena, query_stmt),
                };
            }

            switch (mode) {
                // Earlier statements in a query script are never iterated
                // (Go's database/sql laziness); prepare validated them.
                .query => stmt.finalize(),
                .exec => {
                    while (stmt.step() catch {
                        db.setLastError(db.sqlite_db.errmsg());
                        return error.ExecFailed;
                    }) {}
                    stmt.finalize();
                },
            }

            if (analyzed.at_end) return null;
        }
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

/// Transforms one analyzed statement into SQLite SQL text.
fn transformStatement(
    db: ?*Db,
    arena: std.mem.Allocator,
    node: *pb.AnyResolvedNodeProto,
    opts: QueryOptions,
) Error![]const u8 {
    const config = try arena.create(context_mod.TransformConfig);
    config.* = context_mod.defaultTransformConfig();
    const ctx = try context_mod.TransformContext.init(arena, config);
    ctx.query_ctx.current_time_unix_micros = opts.current_time_unix_micros;

    var coordinator = coordinator_mod.QueryCoordinator.init(arena);
    const fragment = coordinator.transformStatementNode(node, ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unimplemented => return error.Unimplemented,
        else => {
            if (db) |d| d.setLastError(@errorName(err));
            return error.TransformFailed;
        },
    };
    return fragment.toString(arena);
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
        const tp = column.@"type" orelse return error.AnalyzeFailed;
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
        .null => return .@"null",
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
    if (v == .@"null") return .null;
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
                .null => .@"null",
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
