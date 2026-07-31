//! Does an in-memory database write to the disk, and does `temp_store` stop it?
//!
//! The emulator runs on memdb, so the main database is memory. This asks what
//! that claim does *not* cover: the ephemeral b-trees SQLite opens for
//! DISTINCT, transient indexes and materializations, and the spill files the
//! sorter opens for a large ORDER BY. Both are opened through the connection's
//! VFS, and memdb passes every non-main-database open down to the OS.
//!
//!   io-probe [rows]            default 500,000
//!   ZQL_TEMP_STORE=memory io-probe
//!
//! Plain SQLite SQL, not GoogleSQL: the question is about the engine's own
//! spill behaviour, and the translator only decides how much data reaches it.
const std = @import("std");
const zetasqlite = @import("zetasqlite");
const sqlite = zetasqlite.sqlite;
const io_stats = zetasqlite.io_stats;

pub fn main(init: std.process.Init) !void {
    var buf: [1 << 15]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next();
    const rows: u32 = if (args_it.next()) |a| try std.fmt.parseInt(u32, a, 10) else 500_000;

    // Wrap memdb exactly as the server does under ZQL_IO_STATS, so what this
    // measures is the connection the server actually opens.
    //
    // ZQL_IO_BASE=unix wraps the OS VFS instead, with an in-memory main
    // database. That is the control: temp files there are certainly real
    // files, so it says what "written to disk" looks like in these counters —
    // without it, a memdb run showing no descriptors could equally mean the
    // probe does not work.
    const base_unix = if (std.c.getenv("ZQL_IO_BASE")) |v|
        std.mem.eql(u8, std.mem.span(v), "unix")
    else
        false;
    var dsn_buf: [64]u8 = undefined;
    const dsn = if (base_unix) blk: {
        try io_stats.install(null);
        break :blk try std.fmt.bufPrintSentinel(
            &dsn_buf,
            "file::memory:?vfs={s}",
            .{io_stats.vfs_name},
            0,
        );
    } else blk: {
        try io_stats.install("memdb");
        break :blk try std.fmt.bufPrintSentinel(
            &dsn_buf,
            "file:/ioprobe-{d}?vfs={s}",
            .{ std.c.getpid(), io_stats.vfs_name },
            0,
        );
    };

    var db = try sqlite.Db.open(dsn);
    defer db.close();
    // The server's pragmas (storage.zig), plus whatever ZQL_TEMP_STORE asks
    // for — the variable under test.
    try db.exec("PRAGMA synchronous = NORMAL");
    try db.exec("PRAGMA foreign_keys = OFF");
    try db.exec("PRAGMA cache_size = -16000");
    const temp_store = io_stats.tempStorePragma();
    if (temp_store) |p| try db.exec(p);
    try o.print("dsn:          {s}\ntemp_store:   {s}\nrows:         {d}\n\n", .{
        dsn,
        temp_store orelse "(sqlite default)",
        rows,
    });

    var sql_buf: [512]u8 = undefined;
    const load = try std.fmt.bufPrintSentinel(&sql_buf,
        \\CREATE TABLE t(x INTEGER, s TEXT);
        \\INSERT INTO t
        \\  WITH RECURSIVE seq(i) AS (
        \\    SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < {d}
        \\  )
        \\  SELECT i, hex(randomblob(24)) FROM seq;
    , .{rows}, 0);

    try stage(o, init.io, &db, "load (INSERT into the memdb main database)", load);
    // A sort larger than the sorter's memory budget. vdbesort.c opens its
    // spill files straight through the VFS and never consults temp_store, so
    // this is the class the pragma cannot move.
    try stage(o, init.io, &db, "ORDER BY (sorter spill)", "SELECT x, s FROM t ORDER BY s");
    // An ephemeral b-tree: its pager spills once it outgrows the cache, and
    // it *does* honour temp_store.
    try stage(o, init.io, &db, "DISTINCT (ephemeral b-tree)", "SELECT COUNT(*) FROM (SELECT DISTINCT s FROM t)");
    // A self-join with no usable index: SQLite builds a transient index.
    try stage(o, init.io, &db, "self-join (transient index)", "SELECT COUNT(*) FROM t a JOIN t b ON a.s = b.s");

    try o.flush();
}

fn stage(
    o: *std.Io.Writer,
    io: std.Io,
    db: *sqlite.Db,
    name: []const u8,
    sql: [:0]const u8,
) !void {
    io_stats.reset();
    const t0 = std.Io.Clock.awake.now(io);
    try db.exec(sql);
    const ms = @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) /
        std.time.ns_per_ms;
    try o.print("=== {s}: {d:.0} ms\n", .{ name, ms });
    try io_stats.writeText(o);
    try o.writeAll("\n");
    try o.flush();
}
