//! A query job's results, as a virtual table.
//!
//! The BigQuery REST API gives every query job a destination table holding its result.
//! Copying the rows into a real table to satisfy that is pure waste: the server already holds them.
//! So the destination table is virtual.
//!
//! ## The seam
//!
//! Rows belong to the server (a job store); modules belong to the engine. The
//! engine must not learn what a job is, so this file declares the state it
//! needs and the server fills it in.
//! A `ctx`/`lookup` pair rather than a slice, because the lookup is by
//! job id and the store is somebody else's.
//!
//! ## Lifetime
//!
//! `xColumn` runs inside `sqlite3_step` and dereferences whatever `lookup` returns,
//! so a `RowSet` must stay valid for every step of every statement that reads it.
//!
//! Two consequences for the caller:
//!   - a job's rows may not be freed while its table is registered. Clear the registration first.
//!   - the shared state must be cleared before the store it points at is torn down.
//!    `xDisconnect` runs inside `sqlite3_close_v2`, so a server that frees its jobs before
//!     closing the connection has it backwards.
//!
//! `lookup` returning null is not an error: it yields a table with no rows,
//! which is the right answer for a job that has gone away.
// ephor:ignore-file ZA102 ZA303

const std = @import("std");
const sqlite = @import("../../sqlite.zig");
const encoder = @import("../encoder.zig");

const c = sqlite.c;

/// The SQLite module name, and the `USING` clause a caller writes.
pub const module_name = "zigquery_job_rows";

/// The dataset segment anonymous result tables live under.
pub const anon_segment = "_anon";

/// One job's result: the column names it declares, and its values row-major.
///
/// `SqliteRepr` rather than a richer value type because that is the form the
/// rows are already in — the point of the exercise. It also has no `.text`
/// case, matching the engine's own rule that no stored value is TEXT.
pub const RowSet = struct {
    names: []const []const u8,
    /// `rows * names.len` values, row-major.
    cells: []const encoder.SqliteRepr,

    pub fn rowCount(r: RowSet) usize {
        if (r.names.len == 0) return 0;
        return r.cells.len / r.names.len;
    }

    fn at(r: RowSet, row: usize, col: usize) encoder.SqliteRepr {
        return r.cells[row * r.names.len + col];
    }
};

/// Filled in by whoever owns the rows. Both fields null means every job table
/// is empty, which is what should happen before the server has wired itself up
/// and while it is shutting down.
pub const SharedState = struct {
    ctx: ?*anyopaque = null,
    lookup: ?*const fn (ctx: *anyopaque, job_id: []const u8) ?RowSet = null,

    fn get(s: *const SharedState, job_id: []const u8) ?RowSet {
        const f = s.lookup orelse return null;
        return f(s.ctx orelse return null, job_id);
    }
};

const ModuleCtx = struct {
    gpa: std.mem.Allocator,
    state: *SharedState,
};

// The two handles SQLite owns are `extern`, so neither can hold a slice.
// Everything with a length lives behind a pointer beside them

const Vtab = extern struct {
    base: c.sqlite3_vtab,
    state: *VtabState,
};

const VtabState = struct {
    ctx: *ModuleCtx,
    /// The job id from the `CREATE VIRTUAL TABLE` argument, owned.
    job_id: []const u8,
};

const Cursor = extern struct {
    base: c.sqlite3_vtab_cursor,
    state: *CursorState,
};

const CursorState = struct {
    gpa: std.mem.Allocator,
    row: usize = 0,
    /// The row set as of `xFilter`, so one scan reads stays consistent if the store changes
    rows: RowSet = .{ .names = &.{}, .cells = &.{} },
};

var module: c.sqlite3_module = blk: {
    var m = std.mem.zeroes(c.sqlite3_module);
    m.iVersion = 0;
    // xCreate and xDestroy as well as xConnect: this module is not eponymous.
    // The declared columns differ per job, and an eponymous module declares one
    // fixed schema for every use of its name -- so each job's table is created
    // by name instead, which also means a plain table reference to it resolves
    // with no transformer rewrite at all.
    // The same function in both slots: there is nothing to do differently when
    // the table is first created versus reconnected, because the rows live
    // outside SQLite either way.
    m.xCreate = xConnect;
    m.xConnect = xConnect;
    m.xDestroy = xDisconnect;
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

/// Registers the module. `gpa` and `state` must outlive the connection.
pub fn register(db: *sqlite.Db, gpa: std.mem.Allocator, state: *SharedState) !void {
    const ctx = try gpa.create(ModuleCtx);
    ctx.* = .{ .gpa = gpa, .state = state };
    // No errdefer on `ctx`: create_module_v2 invokes the destructor itself on failure,
    // so freeing here would be a double free.
    const rc = c.sqlite3_create_module_v2(
        db.handle,
        module_name,
        &module,
        ctx,
        destroyModuleCtx,
    );
    if (rc != c.SQLITE_OK) return error.SQLite;
}

fn destroyModuleCtx(p: ?*anyopaque) callconv(.c) void {
    const ctx: *ModuleCtx = @ptrCast(@alignCast(p.?));
    ctx.gpa.destroy(ctx);
}

/// `argv[3]` is the job id and `argv[4..]` the column names, as written in the `USING` clause.
///
/// The columns come from the `CREATE`, not from the lookup, and that is the
/// point: a job's rows can go away, and when they do the table must still
/// declare the same columns and simply return no rows. Declaring from the
/// lookup instead made `SELECT a FROM <gone job>` fail to prepare — SQLite
/// rejects the column, rather than the read coming back empty.
fn xConnect(
    db: ?*c.sqlite3,
    aux: ?*anyopaque,
    argc: c_int,
    argv: [*c]const [*c]const u8,
    vtab_out: [*c][*c]c.sqlite3_vtab,
    err: [*c][*c]u8,
) callconv(.c) c_int {
    _ = err;
    const ctx: *ModuleCtx = @ptrCast(@alignCast(aux.?));
    if (argc < 4) return c.SQLITE_ERROR;
    const job_id = unquote(ctx.gpa, std.mem.span(argv[3])) catch return c.SQLITE_NOMEM;
    defer ctx.gpa.free(job_id);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| ctx.gpa.free(n);
        names.deinit(ctx.gpa);
    }
    var i: usize = 4;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const name = unquote(ctx.gpa, std.mem.span(argv[i])) catch return c.SQLITE_NOMEM;
        names.append(ctx.gpa, name) catch {
            ctx.gpa.free(name);
            return c.SQLITE_NOMEM;
        };
    }

    const decl = declaredSchema(ctx.gpa, names.items) catch return c.SQLITE_NOMEM;
    defer ctx.gpa.free(decl);
    if (c.sqlite3_declare_vtab(db, decl.ptr) != c.SQLITE_OK) return c.SQLITE_ERROR;

    const owned = ctx.gpa.dupe(u8, job_id) catch return c.SQLITE_NOMEM;
    const state = ctx.gpa.create(VtabState) catch {
        ctx.gpa.free(owned);
        return c.SQLITE_NOMEM;
    };
    state.* = .{ .ctx = ctx, .job_id = owned };
    const v = ctx.gpa.create(Vtab) catch {
        ctx.gpa.free(owned);
        ctx.gpa.destroy(state);
        return c.SQLITE_NOMEM;
    };
    v.* = .{ .base = std.mem.zeroes(c.sqlite3_vtab), .state = state };
    vtab_out.* = @ptrCast(v);
    return c.SQLITE_OK;
}

/// SQLite hands module arguments over exactly as written between the
/// parentheses — quotes included, escapes not undone — so both are this file's
/// job.
fn unquote(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len < 2 or raw[0] != '\'' or raw[raw.len - 1] != '\'') return gpa.dupe(u8, raw);
    const inner = raw[1 .. raw.len - 1];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        try out.append(gpa, inner[i]);
        if (inner[i] == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn declaredSchema(gpa: std.mem.Allocator, names: []const []const u8) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "CREATE TABLE x(");
    if (names.len == 0) {
        try buf.appendSlice(gpa, "`_placeholder`");
    }
    for (names, 0..) |name, i| {
        if (i != 0) try buf.append(gpa, ',');
        try backticked(gpa, &buf, name);
    }
    try buf.append(gpa, ')');
    return buf.toOwnedSliceSentinel(gpa, 0);
}

fn xDisconnect(vtab_ptr: [*c]c.sqlite3_vtab) callconv(.c) c_int {
    const v: *Vtab = @ptrCast(@alignCast(vtab_ptr));
    const gpa = v.state.ctx.gpa;
    gpa.free(v.state.job_id);
    gpa.destroy(v.state);
    gpa.destroy(v);
    return c.SQLITE_OK;
}

/// A full scan is the only access path, which is what reading a result is.
fn xBestIndex(vtab: [*c]c.sqlite3_vtab, info: [*c]c.sqlite3_index_info) callconv(.c) c_int {
    const v: *Vtab = @ptrCast(@alignCast(vtab));
    const rows = v.state.ctx.state.get(v.state.job_id);
    const n: f64 = @floatFromInt(if (rows) |r| r.rowCount() else 0);
    info.*.estimatedCost = n;
    info.*.estimatedRows = @intFromFloat(n);
    return c.SQLITE_OK;
}

fn xOpen(vtab_ptr: [*c]c.sqlite3_vtab, cur_out: [*c][*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const v: *Vtab = @ptrCast(@alignCast(vtab_ptr));
    const gpa = v.state.ctx.gpa;
    const state = gpa.create(CursorState) catch return c.SQLITE_NOMEM;
    state.* = .{ .gpa = gpa };
    const cur = gpa.create(Cursor) catch {
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
    gpa.destroy(cur.state);
    gpa.destroy(cur);
    return c.SQLITE_OK;
}

/// Resolves the row set once per scan rather than per row, so a scan reads one
/// consistent result even if the store changes between statements.
fn xFilter(
    cur_ptr: [*c]c.sqlite3_vtab_cursor,
    idx_num: c_int,
    idx_str: [*c]const u8,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) c_int {
    _ = idx_num;
    _ = idx_str;
    _ = argc;
    _ = argv;
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    const v: *Vtab = @ptrCast(@alignCast(cur.base.pVtab));
    cur.state.row = 0;
    cur.state.rows = v.state.ctx.state.get(v.state.job_id) orelse
        .{ .names = &.{}, .cells = &.{} };
    return c.SQLITE_OK;
}

fn xNext(cur_ptr: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    cur.state.row += 1;
    return c.SQLITE_OK;
}

fn xEof(cur_ptr: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    return @intFromBool(cur.state.row >= cur.state.rows.rowCount());
}

fn xRowid(cur_ptr: [*c]c.sqlite3_vtab_cursor, rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    rowid.* = @intCast(cur.state.row);
    return c.SQLITE_OK;
}

/// Handed over unchanged. The values are already in the storage encoding, so
/// there is nothing to encode and nothing to copy.
fn xColumn(
    cur_ptr: [*c]c.sqlite3_vtab_cursor,
    ctx: ?*c.sqlite3_context,
    col: c_int,
) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    const st = cur.state;
    const idx: usize = @intCast(col);
    if (st.row >= st.rows.rowCount() or idx >= st.rows.names.len) {
        sqlite.resultNull(ctx);
        return c.SQLITE_OK;
    }
    switch (st.rows.at(st.row, idx)) {
        .null => sqlite.resultNull(ctx),
        .int => |v| sqlite.resultInt64(ctx, v),
        .float => |v| sqlite.resultDouble(ctx, v),
        .blob => |v| sqlite.resultBlob(ctx, v),
    }
    return c.SQLITE_OK;
}

/// The `CREATE VIRTUAL TABLE` that registers one job's result.
///
/// Runs through the raw SQLite path (`Db.rawExec`), not `Db.exec`: this is
/// SQLite's own DDL and means nothing to the GoogleSQL analyzer, which answers
/// `AnalyzeFailed` for it.
///
/// In the **temp** schema deliberately: a virtual table in `main` is written to
/// `sqlite_master` and would survive a reopen of a file-backed database, naming
/// a job whose rows died with the process. Temp objects are per-connection and never persisted.
///
/// SQLite resolves unqualified names against temp first, so a plain reference resolves
pub fn createSql(
    gpa: std.mem.Allocator,
    sqlite_name: []const u8,
    job_id: []const u8,
    names: []const []const u8,
) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.print(gpa, "CREATE VIRTUAL TABLE main.`{s}` USING {s}(", .{
        sqlite_name, module_name,
    });
    try quoted(gpa, &buf, job_id);
    for (names) |name| {
        try buf.appendSlice(gpa, ", ");
        try quoted(gpa, &buf, name);
    }
    try buf.append(gpa, ')');
    return buf.toOwnedSliceSentinel(gpa, 0);
}

/// Finds job-results tables left in a database by a previous process.
///
/// Their rows lived in that process's job store, so every one of them is stale
/// by definition — there is no case where a persisted one should be kept.
/// Built from `module_name` rather than spelling it again: a literal here
/// silently matched nothing when the module was renamed, and a stale-table
/// sweep that finds none looks exactly like one with nothing to do.
pub const find_stale_sql = "SELECT name FROM sqlite_master WHERE type = 'table'" ++
    " AND sql LIKE 'CREATE VIRTUAL TABLE%" ++ module_name ++ "%'";

/// A quoted identifier. Column names reach here from a client's SELECT list, so
/// a backtick in one would otherwise close the quoting early.
fn backticked(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: []const u8) !void {
    try buf.append(gpa, '`');
    for (v) |ch| {
        if (ch == '`') try buf.append(gpa, '`');
        try buf.append(gpa, ch);
    }
    try buf.append(gpa, '`');
}

/// A SQL string literal, for the same reason.
fn quoted(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: []const u8) !void {
    try buf.append(gpa, '\'');
    for (v) |ch| {
        if (ch == '\'') try buf.append(gpa, '\'');
        try buf.append(gpa, ch);
    }
    try buf.append(gpa, '\'');
}
