//! Per-query cost as a function of catalog size. No Go counterpart — this
//! exists to size the optimizations planned for the server port and to give
//! them a regression gate.
//!
//! A fresh table is created between every timed query, and that is the whole
//! point. Against a *static* catalog the analyzer handle is persistent and
//! Catalog.renderDelta returns zero ops, so a repeated query never touches the
//! table set at all — 1 table and 14,000 tables both land at ~0.047 ms/query
//! and the size axis measures nothing but CPU warm-up. Interleaving a CREATE
//! forces a non-empty delta into each iteration, which is where the remaining
//! per-statement costs actually live:
//!   - Catalog.renderDelta -> catalogJsonForSpecs, then catalogAddTables into
//!     the live handle. Both the lookup and the insert are hash operations now
//!     (`SimpleCatalog::tables_` is an absl::flat_hash_map, and Node.hasEntry /
//!     findSub gained hash sidecars), so this is O(delta) rather than the
//!     linear scans an earlier version of this comment described.
//!   - the CREATE's own analyze + catalog registration, and the per-table
//!     fan-out that comes with a multi-part name: addTableToNode registers a
//!     3-part path at 7 points and a 4-part one at 15, each carrying the full
//!     column list.
//!   - publishInfoSchemaSnapshot, which walks the *whole* catalog on every
//!     statement whatever the delta
//!   - defaultTransformConfig calls getenv on every transform.
//!   - Catalog.funcMap rebuilds a StringHashMap of every function spec.
//!
//! So the headline number to watch is not just ms/query but how it *grows*
//! with table count. Go's floor is ~0.175 ms/query.
//!
//! Note that `vs 1 table` is normalised against the first row, which is also
//! the row that absorbs process warm-up. Put a throwaway size first (e.g.
//! `-- 200 1 1 50 500`) when comparing sizes.
//!
//! Usage: zig build bench -- [queries_per_size] [sizes...]

const std = @import("std");
const builtin = @import("builtin");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

const default_sizes = [_]usize{ 1, 50, 500 };

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (builtin.mode == .Debug) gpa_state.allocator() else std.heap.smp_allocator;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const per_size: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 2000;

    var sizes: std.ArrayList(usize) = .empty;
    defer sizes.deinit(gpa);
    while (args.next()) |a| try sizes.append(gpa, try std.fmt.parseInt(usize, a, 10));
    if (sizes.items.len == 0) try sizes.appendSlice(gpa, &default_sizes);

    if (builtin.mode == .Debug) {
        try out.print("WARNING: Debug build; numbers are not comparable to release.\n", .{});
    }
    try out.print(
        "bench: {d} queries per catalog size ({s})\n\n",
        .{ per_size, @tagName(builtin.mode) },
    );
    try out.print("{s:>8}  {s:>12}  {s:>12}  {s:>12}  {s:>10}\n", .{ "tables", "ms/create", "ms/query", "queries/s", "vs 1 table" });
    try out.print("{s:>8}  {s:>12}  {s:>12}  {s:>12}  {s:>10}\n", .{ "------", "---------", "--------", "---------", "----------" });

    var first_ms: f64 = 0;
    for (sizes.items, 0..) |n_tables, i| {
        const r = try benchOne(gpa, init.io, n_tables, per_size);
        if (i == 0) first_ms = r.query_ms;
        try out.print(
            "{d:>8}  {d:>12.4}  {d:>12.4}  {d:>12.0}  {d:>9.2}x\n",
            .{ n_tables, r.create_ms, r.query_ms, 1000.0 / r.query_ms, r.query_ms / first_ms },
        );
    }

    try out.print(
        "\nM4 target: <= 0.1750 ms/query at 50 tables (Go parity), sub-linear growth.\n",
        .{},
    );
    try out.flush();
}

/// Mean cost of one CREATE and one query, both measured over the same loop.
const Result = struct {
    create_ms: f64,
    query_ms: f64,
};

/// Builds a catalog of `n_tables` tables, then alternates a fresh CREATE with
/// a fixed query against one of the originals. The two are timed separately so
/// `ms/query` keeps meaning the query alone; the CREATE is what leaves a
/// pending catalog delta for that query to pay off.
///
/// The query stays pinned to `bench_t{n_tables - 1}` rather than following the
/// new tables: reusing one SQL string keeps the measurement on catalog growth
/// instead of mixing in first-sight costs for novel query text. Both statements
/// are trivial — we are measuring per-statement overhead, not execution.
fn benchOne(
    gpa: std.mem.Allocator,
    io: std.Io,
    n_tables: usize,
    queries: usize,
) !Result {
    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();

    // Separate buffers: the loop below rewrites the DDL one every iteration,
    // and `query` has to survive that.
    var ddl_buf: [256]u8 = undefined;
    var query_buf: [256]u8 = undefined;

    var t: usize = 0;
    while (t < n_tables) : (t += 1) {
        const sql = try std.fmt.bufPrint(
            &ddl_buf,
            "CREATE TABLE bench_t{d} (id INT64, name STRING, v FLOAT64)",
            .{t},
        );
        try db.exec(sql, &.{}, .{});
    }

    // Warm up: first call pays one-time lazy initialisation in the shim.
    try db.exec("SELECT 1", &.{}, .{});

    const query = try std.fmt.bufPrint(
        &query_buf,
        "SELECT id, name FROM bench_t{d} WHERE id > 0",
        .{n_tables - 1},
    );

    var create_ns: f64 = 0;
    var query_ns: f64 = 0;
    var i: usize = 0;
    while (i < queries) : (i += 1) {
        const ddl = try std.fmt.bufPrint(
            &ddl_buf,
            "CREATE TABLE bench_x{d} (id INT64, name STRING, v FLOAT64)",
            .{i},
        );

        const t0 = std.Io.Clock.awake.now(io);
        try db.exec(ddl, &.{}, .{});

        const t1 = std.Io.Clock.awake.now(io);
        var rows = try db.query(query, &.{}, .{});
        while (try rows.next()) |_| {}
        rows.deinit();
        const t2 = std.Io.Clock.awake.now(io);

        create_ns += @floatFromInt(t0.durationTo(t1).nanoseconds);
        query_ns += @floatFromInt(t1.durationTo(t2).nanoseconds);
    }

    const n: f64 = @floatFromInt(queries);
    return .{
        .create_ms = create_ns / n / std.time.ns_per_ms,
        .query_ms = query_ns / n / std.time.ns_per_ms,
    };
}
