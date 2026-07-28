//! Thin wrapper over the SQLite C API (Homebrew keg). This layer plus
//! driver.zig replaces go-zetasqlite's database/sql driver surface
//! (driver.go/conn.go/stmt.go/rows.go + modernc sqlite.RegisterFunction) —
//! the one part of the port that is redesigned rather than mirrored.

const std = @import("std");
const phase = @import("internal/phase.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

// SQLITE_TRANSIENT is (sqlite3_destructor_type)-1, which Zig rejects as an
// unaligned function pointer. Redeclare the destructor-taking functions with
// the ABI-identical `isize` parameter and pass -1 directly.
const SQLITE_TRANSIENT: isize = -1;
extern fn sqlite3_bind_text(stmt: ?*c.sqlite3_stmt, idx: c_int, v: [*c]const u8, n: c_int, destructor: isize) c_int;
extern fn sqlite3_bind_blob(stmt: ?*c.sqlite3_stmt, idx: c_int, v: ?*const anyopaque, n: c_int, destructor: isize) c_int;
extern fn sqlite3_result_text(ctx: ?*c.sqlite3_context, v: [*c]const u8, n: c_int, destructor: isize) void;
extern fn sqlite3_result_blob(ctx: ?*c.sqlite3_context, v: ?*const anyopaque, n: c_int, destructor: isize) void;

pub const Error = error{SQLite};

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) Error!Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &handle) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close_v2(h);
            return error.SQLite;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(db: *Db) void {
        _ = c.sqlite3_close_v2(db.handle);
    }

    pub fn errmsg(db: *Db) []const u8 {
        return std.mem.sliceTo(c.sqlite3_errmsg(db.handle), 0);
    }

    /// Most recent primary result code (Go: the `rc` modernc threads into
    /// errstrForDB).
    pub fn errcode(db: *Db) i32 {
        return @intCast(c.sqlite3_errcode(db.handle));
    }

    /// Port of modernc.org/sqlite's errstrForDB — the shape every error from
    /// Go's driver carries, and therefore the shape go-zetasqlite surfaces to
    /// callers (e.g. "SQL logic error: <udf message> (1)").
    ///
    ///   pStr := sqlite3_errstr(rc); msg := sqlite3_errmsg(db)
    ///   msg == pStr -> "%s (%v)%s"   else -> "%s: %s (%v)%s"
    ///   %s tail is " (SQLITE_BUSY)" when rc == SQLITE_BUSY, else empty.
    pub fn errorText(db: *Db, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
        const rc = db.errcode();
        const str = std.mem.sliceTo(c.sqlite3_errstr(rc), 0);
        const msg = db.errmsg();
        const busy: []const u8 = if (rc == c.SQLITE_BUSY) " (SQLITE_BUSY)" else "";
        if (std.mem.eql(u8, msg, str)) {
            return std.fmt.allocPrint(alloc, "{s} ({d}){s}", .{ str, rc, busy });
        }
        return std.fmt.allocPrint(alloc, "{s}: {s} ({d}){s}", .{ str, msg, rc, busy });
    }

    /// Executes SQL that produces no result rows (DDL, DML).
    pub fn exec(db: *Db, sql: [:0]const u8) Error!void {
        var t = phase.Timer.begin(.sqlite_exec);
        defer t.end();
        if (c.sqlite3_exec(db.handle, sql.ptr, null, null, null) != c.SQLITE_OK) {
            return error.SQLite;
        }
    }

    /// sqlite3_busy_timeout. Go's driver never sets one (the emulator
    /// serialized every request instead); a connection pool needs it so a
    /// writer blocking on WAL retries rather than failing immediately.
    /// Note this retries SQLITE_BUSY only — it does not retry SQLITE_LOCKED,
    /// which is what shared-cache mode produces.
    pub fn busyTimeout(db: *Db, ms: i32) void {
        _ = c.sqlite3_busy_timeout(db.handle, ms);
    }

    /// Compiles `sql`, retrying while the schema keeps changing underneath.
    ///
    /// prepare_v2 re-prepares internally when the schema cookie moves, but
    /// gives up and returns SQLITE_SCHEMA after its own retry budget. One
    /// connection never reaches that; several connections doing continuous DDL
    /// against the same database do. It means "the schema moved while
    /// compiling", not "this statement is wrong" — so it is retried rather
    /// than reported.
    pub fn prepare(db: *Db, sql: []const u8) Error!Stmt {
        var t = phase.Timer.begin(.sqlite_prepare);
        defer t.end();
        phase.notePreparedSql(sql);
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(
                db.handle,
                sql.ptr,
                @intCast(sql.len),
                &stmt,
                null,
            );
            if (rc == c.SQLITE_OK) return .{ .handle = stmt.? };
            if (rc == c.SQLITE_SCHEMA and attempt < 8) continue;
            return error.SQLite;
        }
    }

    pub const ScalarFn = fn (
        ctx: ?*c.sqlite3_context,
        argc: c_int,
        argv: [*c]?*c.sqlite3_value,
    ) callconv(.c) void;
    pub const FinalFn = fn (ctx: ?*c.sqlite3_context) callconv(.c) void;
    pub const CompareFn = fn (
        userdata: ?*anyopaque,
        a_len: c_int,
        a: ?*const anyopaque,
        b_len: c_int,
        b: ?*const anyopaque,
    ) callconv(.c) c_int;

    /// Registers a scalar UDF. n_args = -1 for variadic.
    ///
    /// `deterministic` must be false for any function whose value may differ
    /// between calls with identical arguments. SQLITE_DETERMINISTIC lets
    /// SQLite hoist a constant-argument call out of the row loop and evaluate
    /// it once per query, which for e.g. GENERATE_UUID() would yield the same
    /// value for every row instead of one per row.
    pub fn createScalarFunction(
        db: *Db,
        name: [:0]const u8,
        n_args: i32,
        userdata: ?*anyopaque,
        func: *const ScalarFn,
        deterministic: bool,
    ) Error!void {
        const flags: c_int = c.SQLITE_UTF8 |
            @as(c_int, if (deterministic) c.SQLITE_DETERMINISTIC else 0);
        const rc = c.sqlite3_create_function_v2(
            db.handle,
            name.ptr,
            @intCast(n_args),
            flags,
            userdata,
            func,
            null,
            null,
            null,
        );
        if (rc != c.SQLITE_OK) return error.SQLite;
    }

    pub fn createAggregateFunction(
        db: *Db,
        name: [:0]const u8,
        n_args: i32,
        userdata: ?*anyopaque,
        step: *const ScalarFn,
        final: *const FinalFn,
    ) Error!void {
        const rc = c.sqlite3_create_function_v2(
            db.handle,
            name.ptr,
            @intCast(n_args),
            c.SQLITE_UTF8,
            userdata,
            null,
            step,
            final,
            null,
        );
        if (rc != c.SQLITE_OK) return error.SQLite;
    }

    /// Window function: step/final plus value/inverse for frame support.
    pub fn createWindowFunction(
        db: *Db,
        name: [:0]const u8,
        n_args: i32,
        userdata: ?*anyopaque,
        step: *const ScalarFn,
        final: *const FinalFn,
        value: *const FinalFn,
        inverse: *const ScalarFn,
    ) Error!void {
        const rc = c.sqlite3_create_window_function(
            db.handle,
            name.ptr,
            @intCast(n_args),
            c.SQLITE_UTF8,
            userdata,
            step,
            final,
            value,
            inverse,
            null,
        );
        if (rc != c.SQLITE_OK) return error.SQLite;
    }

    pub fn createCollation(
        db: *Db,
        name: [:0]const u8,
        userdata: ?*anyopaque,
        compare: *const CompareFn,
    ) Error!void {
        const rc = c.sqlite3_create_collation_v2(
            db.handle,
            name.ptr,
            c.SQLITE_UTF8,
            userdata,
            compare,
            null,
        );
        if (rc != c.SQLITE_OK) return error.SQLite;
    }

    /// Per-connection allocator counter.
    ///
    /// Read without resetting, so values are cumulative since the connection
    /// opened — a served process wants totals, not an interval.
    pub fn dbStatus(db: *Db, op: DbStatus) Counter {
        var cur: c_int = 0;
        var hi: c_int = 0;
        const rc = c.sqlite3_db_status(db.handle, @intFromEnum(op), &cur, &hi, 0);
        // The only documented failure is an unrecognized op, and every op is a
        // constant lifted from sqlite3.h — so a failure means `DbStatus` has
        // drifted from the header, not that the call was misused.
        std.debug.assert(rc == c.SQLITE_OK);
        std.debug.assert(cur >= 0);
        std.debug.assert(hi >= 0);
        // Assert the field SQLite does *not* maintain for this op, so reading
        // the wrong one is caught here rather than silently reported as zero.
        switch (op.shape()) {
            .gauge_with_peak => std.debug.assert(hi >= cur),
            .total_in_highwater => std.debug.assert(cur == 0),
            .gauge_only => std.debug.assert(hi == 0),
        }
        return .{ .current = cur, .highwater = hi };
    }
};

// --- Allocator instrumentation ----------------------------------------------
//
// These exist to answer one question with a number: is SQLite's allocator
// worth tuning at all? The measured profile puts sqlite3_prepare_v2 at 22% of
// server handle time, and lookaside targets exactly the small allocations
// prepare makes — but only if the pool is actually being exhausted. The
// counters below say whether it is, so the answer is a measurement rather
// than an argument.

pub const Counter = struct {
    current: i64,
    highwater: i64,
};

/// Which of a counter's two fields SQLite actually maintains.
///
/// The status APIs look uniform and are not: some ops are gauges with a peak,
/// some report a running total in `highwater` and leave `current` pinned at
/// zero, and some maintain no peak at all and leave `highwater` at zero. The
/// distinction is documented per-op and nowhere in the signature, so it is
/// recorded here and asserted on every read.
pub const Shape = enum { gauge_with_peak, total_in_highwater, gauge_only };

/// Process-wide allocator counters (sqlite3_status64).
///
/// `malloc_count` is the number of allocations *currently outstanding*, not a
/// lifetime total — SQLite exposes no cumulative allocation count. Cumulative
/// volume comes from the lookaside counters in `DbStatus`, which is the number
/// that matters for prepare/step anyway.
pub const Status = enum(c_int) {
    memory_used = c.SQLITE_STATUS_MEMORY_USED,
    /// Highwater is the largest single allocation ever requested; `current` is
    /// always zero.
    malloc_size = c.SQLITE_STATUS_MALLOC_SIZE,
    malloc_count = c.SQLITE_STATUS_MALLOC_COUNT,
    pagecache_used = c.SQLITE_STATUS_PAGECACHE_USED,
    /// Page-cache bytes that overflowed to the general allocator.
    pagecache_overflow = c.SQLITE_STATUS_PAGECACHE_OVERFLOW,

    pub fn shape(op: Status) Shape {
        return switch (op) {
            .malloc_size => .total_in_highwater,
            .memory_used,
            .malloc_count,
            .pagecache_used,
            .pagecache_overflow,
            => .gauge_with_peak,
        };
    }
};

/// Per-connection counters (sqlite3_db_status).
///
/// For the three lookaside outcome counters, SQLite documents `current` as
/// always zero and only `highwater` as meaningful — they are running totals,
/// not gauges. `lookaside_used` is a genuine gauge, and its highwater pinned
/// at the configured slot count is what "the pool is too small" looks like.
pub const DbStatus = enum(c_int) {
    /// Slots checked out now, and at peak. A peak pinned to the configured
    /// slot count is what an exhausted pool looks like.
    lookaside_used = c.SQLITE_DBSTATUS_LOOKASIDE_USED,
    /// Allocations served from lookaside: the fast path.
    lookaside_hit = c.SQLITE_DBSTATUS_LOOKASIDE_HIT,
    /// Missed because the request was larger than a slot -> raise slot_bytes.
    lookaside_miss_size = c.SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE,
    /// Missed because every slot was checked out -> raise slot_count.
    lookaside_miss_full = c.SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL,
    cache_used = c.SQLITE_DBSTATUS_CACHE_USED,
    schema_used = c.SQLITE_DBSTATUS_SCHEMA_USED,
    stmt_used = c.SQLITE_DBSTATUS_STMT_USED,

    pub fn shape(op: DbStatus) Shape {
        return switch (op) {
            .lookaside_used => .gauge_with_peak,
            .lookaside_hit,
            .lookaside_miss_size,
            .lookaside_miss_full,
            => .total_in_highwater,
            // SQLite documents the highwater for these three as always zero.
            .cache_used, .schema_used, .stmt_used => .gauge_only,
        };
    }
};

/// Process-wide allocator counter (sqlite3_status64).
pub fn status(op: Status) Counter {
    var cur: c.sqlite3_int64 = 0;
    var hi: c.sqlite3_int64 = 0;
    const rc = c.sqlite3_status64(@intFromEnum(op), &cur, &hi, 0);
    std.debug.assert(rc == c.SQLITE_OK);
    std.debug.assert(cur >= 0);
    std.debug.assert(hi >= 0);
    switch (op.shape()) {
        .gauge_with_peak => std.debug.assert(hi >= cur),
        .total_in_highwater => std.debug.assert(cur == 0),
        .gauge_only => std.debug.assert(hi == 0),
    }
    return .{ .current = cur, .highwater = hi };
}

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn finalize(s: *Stmt) void {
        _ = c.sqlite3_finalize(s.handle);
    }

    pub fn reset(s: *Stmt) void {
        _ = c.sqlite3_reset(s.handle);
    }

    /// Drops previously bound values so a cached statement cannot inherit a
    /// stale binding when the next caller supplies fewer arguments.
    pub fn clearBindings(s: *Stmt) void {
        _ = c.sqlite3_clear_bindings(s.handle);
    }

    /// Returns true while a row is available; false when done.
    pub fn step(s: *Stmt) Error!bool {
        var t = phase.Timer.begin(.sqlite_step);
        defer t.end();
        return switch (c.sqlite3_step(s.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.SQLite,
        };
    }

    pub fn bindNull(s: *Stmt, index: i32) Error!void {
        if (c.sqlite3_bind_null(s.handle, @intCast(index)) != c.SQLITE_OK)
            return error.SQLite;
    }

    pub fn bindInt64(s: *Stmt, index: i32, v: i64) Error!void {
        if (c.sqlite3_bind_int64(s.handle, @intCast(index), v) != c.SQLITE_OK)
            return error.SQLite;
    }

    pub fn bindDouble(s: *Stmt, index: i32, v: f64) Error!void {
        if (c.sqlite3_bind_double(s.handle, @intCast(index), v) != c.SQLITE_OK)
            return error.SQLite;
    }

    pub fn bindText(s: *Stmt, index: i32, v: []const u8) Error!void {
        const rc = sqlite3_bind_text(
            s.handle,
            @intCast(index),
            v.ptr,
            @intCast(v.len),
            SQLITE_TRANSIENT,
        );
        if (rc != c.SQLITE_OK) return error.SQLite;
    }

    pub fn bindBlob(s: *Stmt, index: i32, v: []const u8) Error!void {
        const rc = sqlite3_bind_blob(
            s.handle,
            @intCast(index),
            v.ptr,
            @intCast(v.len),
            SQLITE_TRANSIENT,
        );
        if (rc != c.SQLITE_OK) return error.SQLite;
    }

    /// Number of SQL parameter placeholders in the prepared statement.
    pub fn bindParameterCount(s: *Stmt) i32 {
        return @intCast(c.sqlite3_bind_parameter_count(s.handle));
    }

    /// 1-based index of the named parameter `name` (e.g. "@a"), or 0 if none.
    pub fn bindParameterIndex(s: *Stmt, name: [:0]const u8) i32 {
        return @intCast(c.sqlite3_bind_parameter_index(s.handle, name.ptr));
    }

    /// Placeholder text of the 1-based parameter `index` (e.g. "@a"), or null
    /// for a nameless "?" placeholder.
    pub fn bindParameterName(s: *Stmt, index: i32) ?[]const u8 {
        const p = c.sqlite3_bind_parameter_name(s.handle, @intCast(index));
        if (p == null) return null;
        return std.mem.sliceTo(p, 0);
    }

    pub fn columnCount(s: *Stmt) i32 {
        return @intCast(c.sqlite3_column_count(s.handle));
    }

    pub fn columnName(s: *Stmt, col: i32) []const u8 {
        return std.mem.sliceTo(c.sqlite3_column_name(s.handle, @intCast(col)), 0);
    }

    pub const ColumnType = enum { integer, float, text, blob, null };

    pub fn columnType(s: *Stmt, col: i32) ColumnType {
        return switch (c.sqlite3_column_type(s.handle, @intCast(col))) {
            c.SQLITE_INTEGER => .integer,
            c.SQLITE_FLOAT => .float,
            c.SQLITE_TEXT => .text,
            c.SQLITE_BLOB => .blob,
            else => .null,
        };
    }

    pub fn columnInt64(s: *Stmt, col: i32) i64 {
        return c.sqlite3_column_int64(s.handle, @intCast(col));
    }

    pub fn columnDouble(s: *Stmt, col: i32) f64 {
        return c.sqlite3_column_double(s.handle, @intCast(col));
    }

    pub fn columnText(s: *Stmt, col: i32) []const u8 {
        const n: usize = @intCast(c.sqlite3_column_bytes(s.handle, @intCast(col)));
        if (n == 0) return "";
        const p: [*]const u8 = @ptrCast(c.sqlite3_column_text(s.handle, @intCast(col)));
        return p[0..n];
    }

    pub fn columnBlob(s: *Stmt, col: i32) []const u8 {
        const n: usize = @intCast(c.sqlite3_column_bytes(s.handle, @intCast(col)));
        if (n == 0) return "";
        const p: [*]const u8 = @ptrCast(c.sqlite3_column_blob(s.handle, @intCast(col)).?);
        return p[0..n];
    }
};

// --- UDF callback helpers -------------------------------------------------

pub fn valueType(v: ?*c.sqlite3_value) Stmt.ColumnType {
    return switch (c.sqlite3_value_type(v)) {
        c.SQLITE_INTEGER => .integer,
        c.SQLITE_FLOAT => .float,
        c.SQLITE_TEXT => .text,
        c.SQLITE_BLOB => .blob,
        else => .null,
    };
}

pub fn valueInt64(v: ?*c.sqlite3_value) i64 {
    return c.sqlite3_value_int64(v);
}

pub fn valueDouble(v: ?*c.sqlite3_value) f64 {
    return c.sqlite3_value_double(v);
}

pub fn valueText(v: ?*c.sqlite3_value) []const u8 {
    const n: usize = @intCast(c.sqlite3_value_bytes(v));
    if (n == 0) return "";
    const p: [*]const u8 = @ptrCast(c.sqlite3_value_text(v));
    return p[0..n];
}

pub fn resultNull(ctx: ?*c.sqlite3_context) void {
    c.sqlite3_result_null(ctx);
}

pub fn resultInt64(ctx: ?*c.sqlite3_context, v: i64) void {
    c.sqlite3_result_int64(ctx, v);
}

pub fn resultDouble(ctx: ?*c.sqlite3_context, v: f64) void {
    c.sqlite3_result_double(ctx, v);
}

pub fn resultText(ctx: ?*c.sqlite3_context, v: []const u8) void {
    sqlite3_result_text(ctx, v.ptr, @intCast(v.len), SQLITE_TRANSIENT);
}

pub fn resultBlob(ctx: ?*c.sqlite3_context, v: []const u8) void {
    sqlite3_result_blob(ctx, v.ptr, @intCast(v.len), SQLITE_TRANSIENT);
}

pub fn resultError(ctx: ?*c.sqlite3_context, msg: []const u8) void {
    c.sqlite3_result_error(ctx, msg.ptr, @intCast(msg.len));
}

pub fn userData(ctx: ?*c.sqlite3_context) ?*anyopaque {
    return c.sqlite3_user_data(ctx);
}

pub fn aggregateContext(ctx: ?*c.sqlite3_context, n_bytes: i32) ?*anyopaque {
    return c.sqlite3_aggregate_context(ctx, @intCast(n_bytes));
}

/// Destructor SQLite calls when it discards auxiliary data.
pub const AuxDestructor = ?*const fn (?*anyopaque) callconv(.c) void;

/// Per-call-site cache for a function argument, keyed by argument index
/// (0-based). SQLite preserves it across rows "for function parameters that
/// are compile-time constants, including literal values", and discards it when
/// the statement is reset or finalized — the mechanism the docs illustrate
/// with a compiled regular expression.
///
/// Returns null when nothing is cached, which is always a legal answer: the
/// caller must be able to recompute.
pub fn getAuxdata(ctx: ?*c.sqlite3_context, arg: i32) ?*anyopaque {
    return c.sqlite3_get_auxdata(ctx, @intCast(arg));
}

/// Hands `p` to SQLite as the cached form of argument `arg`.
///
/// The destructor may run before this returns — during query planning, or on
/// an allocation failure — so `p` must not be touched afterwards. Call it once
/// the value is no longer needed for the current row.
pub fn setAuxdata(
    ctx: ?*c.sqlite3_context,
    arg: i32,
    p: ?*anyopaque,
    destructor: AuxDestructor,
) void {
    c.sqlite3_set_auxdata(ctx, @intCast(arg), p, destructor);
}

// --- Tests ------------------------------------------------------------------

fn testEcho(
    ctx: ?*c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) void {
    std.debug.assert(argc == 1);
    resultText(ctx, valueText(argv[0]));
}

const TestSumState = struct { total: i64 };

fn testSumStep(
    ctx: ?*c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) void {
    std.debug.assert(argc == 1);
    const raw = aggregateContext(ctx, @sizeOf(TestSumState)) orelse return;
    const state: *TestSumState = @ptrCast(@alignCast(raw));
    state.total += valueInt64(argv[0]);
}

fn testSumFinal(ctx: ?*c.sqlite3_context) callconv(.c) void {
    const raw = aggregateContext(ctx, @sizeOf(TestSumState)) orelse {
        resultInt64(ctx, 0);
        return;
    };
    const state: *TestSumState = @ptrCast(@alignCast(raw));
    resultInt64(ctx, state.total);
}

/// Orders by string length only (recognizably different from binary order).
fn testLenCollation(
    _: ?*anyopaque,
    a_len: c_int,
    _: ?*const anyopaque,
    b_len: c_int,
    _: ?*const anyopaque,
) callconv(.c) c_int {
    if (a_len < b_len) return -1;
    if (a_len > b_len) return 1;
    return 0;
}

test "open, query, scalar UDF, aggregate, collation" {
    var db = try Db.open(":memory:");
    defer db.close();

    // Plain query.
    {
        var stmt = try db.prepare("SELECT 1 + 1");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqual(@as(i64, 2), stmt.columnInt64(0));
    }

    // Scalar UDF.
    try db.createScalarFunction("test_echo", 1, null, testEcho, true);
    {
        var stmt = try db.prepare("SELECT test_echo('hello')");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("hello", stmt.columnText(0));
    }

    // Aggregate over a small table.
    try db.createAggregateFunction("test_sum2", 1, null, testSumStep, testSumFinal);
    try db.exec("CREATE TABLE t(x INTEGER)");
    try db.exec("INSERT INTO t VALUES (1),(2),(3)");
    {
        var stmt = try db.prepare("SELECT test_sum2(x) FROM t");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqual(@as(i64, 6), stmt.columnInt64(0));
    }

    // Collation: length-ordering puts 'ccc' last regardless of binary order.
    try db.createCollation("test_len", null, testLenCollation);
    {
        var stmt = try db.prepare(
            "SELECT s FROM (SELECT 'ccc' AS s UNION ALL SELECT 'a' UNION ALL SELECT 'bb') ORDER BY s COLLATE test_len",
        );
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("a", stmt.columnText(0));
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("bb", stmt.columnText(0));
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("ccc", stmt.columnText(0));
    }
}
