//! Public driver surface — the redesigned counterpart of go-zetasqlite's
//! database/sql layer (driver.go / conn.go / stmt.go / rows.go).
//!
//! API shape (fills in as pipeline tasks land):
//!   var db = try Db.open(gpa, ":memory:");
//!   var rows = try db.query(sql, args, .{ .current_time_unix_micros = ... });
//!   while (try rows.next()) |row| ...
//!   rows.deinit();

const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const Error = error{
    Unimplemented,
    AnalyzeFailed,
    ExecFailed,
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

pub const Db = struct {
    gpa: std.mem.Allocator,
    sqlite_db: sqlite.Db,

    pub fn open(gpa: std.mem.Allocator, path: [:0]const u8) Error!*Db {
        const db = try gpa.create(Db);
        errdefer gpa.destroy(db);
        db.* = .{
            .gpa = gpa,
            .sqlite_db = try sqlite.Db.open(path),
        };
        // UDF/collation registration and zetasqlite_catalog setup land with
        // the function-runtime task.
        return db;
    }

    pub fn close(db: *Db) void {
        db.sqlite_db.close();
        db.gpa.destroy(db);
    }

    /// Diagnostic message for the last AnalyzeFailed/ExecFailed error.
    pub fn lastError(db: *Db) []const u8 {
        _ = db;
        return "";
    }

    pub fn query(db: *Db, sql: []const u8, args: []const Param, opts: QueryOptions) Error!Rows {
        _ = db;
        _ = sql;
        _ = args;
        _ = opts;
        return error.Unimplemented;
    }

    pub fn exec(db: *Db, sql: []const u8, args: []const Param, opts: QueryOptions) Error!void {
        _ = db;
        _ = sql;
        _ = args;
        _ = opts;
        return error.Unimplemented;
    }
};

pub const Rows = struct {
    arena: std.heap.ArenaAllocator,

    pub fn columns(r: *Rows) []const []const u8 {
        _ = r;
        return &.{};
    }

    /// Next row of decoded cells, or null when exhausted. Cells are valid
    /// until the following next()/deinit() call.
    pub fn next(r: *Rows) Error!?[]const Cell {
        _ = r;
        return null;
    }

    pub fn deinit(r: *Rows) void {
        r.arena.deinit();
    }
};
