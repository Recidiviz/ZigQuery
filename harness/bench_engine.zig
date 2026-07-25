//! Per-query cost as a function of catalog size. No Go counterpart — this
//! exists to size the optimizations planned for the server port and to give
//! them a regression gate.
//!
//! The suspected cost centres, all per *statement*:
//!   - Catalog.catalogJson rebuilds the whole SimpleCatalogProto tree, with
//!     linear scans in Node.hasEntry/findSub (O(tables^2) overall).
//!   - analyzer_shim.cc then does JsonStringToMessage + SimpleCatalog::
//!     Deserialize + AddBuiltinFunctions against a fresh TypeFactory.
//!   - defaultTransformConfig calls getenv on every transform.
//!   - Catalog.funcMap rebuilds a StringHashMap of every function spec.
//!
//! So the headline number to watch is not just ms/query but how it *grows*
//! with table count. Go's floor is ~0.175 ms/query.
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
    try out.print("{s:>8}  {s:>12}  {s:>12}  {s:>10}\n", .{ "tables", "ms/query", "queries/s", "vs 1 table" });
    try out.print("{s:>8}  {s:>12}  {s:>12}  {s:>10}\n", .{ "------", "--------", "---------", "----------" });

    var first_ms: f64 = 0;
    for (sizes.items, 0..) |n_tables, i| {
        const ms = try benchOne(gpa, init.io, n_tables, per_size);
        if (i == 0) first_ms = ms;
        try out.print(
            "{d:>8}  {d:>12.4}  {d:>12.0}  {d:>9.2}x\n",
            .{ n_tables, ms, 1000.0 / ms, ms / first_ms },
        );
    }

    try out.print(
        "\nM4 target: <= 0.1750 ms/query at 50 tables (Go parity), sub-linear growth.\n",
        .{},
    );
    try out.flush();
}

/// Builds a catalog of `n_tables` tables, then times a fixed query against one
/// of them. The query itself is trivial: we are measuring per-statement
/// overhead, not execution.
fn benchOne(
    gpa: std.mem.Allocator,
    io: std.Io,
    n_tables: usize,
    queries: usize,
) !f64 {
    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();

    var buf: [256]u8 = undefined;
    var t: usize = 0;
    while (t < n_tables) : (t += 1) {
        const sql = try std.fmt.bufPrint(
            &buf,
            "CREATE TABLE bench_t{d} (id INT64, name STRING, v FLOAT64)",
            .{t},
        );
        try db.exec(sql, &.{}, .{});
    }

    // Warm up: first call pays one-time lazy initialisation in the shim.
    try db.exec("SELECT 1", &.{}, .{});

    const query = try std.fmt.bufPrint(
        &buf,
        "SELECT id, name FROM bench_t{d} WHERE id > 0",
        .{n_tables - 1},
    );

    const t0 = std.Io.Clock.awake.now(io);
    var i: usize = 0;
    while (i < queries) : (i += 1) {
        var rows = try db.query(query, &.{}, .{});
        while (try rows.next()) |_| {}
        rows.deinit();
    }
    const ns = t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(queries)) / std.time.ns_per_ms;
}
