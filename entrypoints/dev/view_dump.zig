//! Dump the SQLite schema a GoogleSQL view graph actually produces.
//!
//! Replays a dumped ancestry script into one database, then writes every
//! CREATE TABLE/VIEW SQLite ended up holding, followed by the translated SQL
//! of the script's last statement. That pair is what another engine needs in
//! order to be compared against SQLite on the same graph: the view bodies as
//! emitted, not the GoogleSQL they came from.
//!
//!   view-dump <script.sql> > schema.sql
//!
//! Schema goes to stdout; timings and progress go to stderr, so the two can be
//! separated by redirection alone.
const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const phase = zigquery.phase;

pub fn main(init: std.process.Init) !void {
    var out_buf: [1 << 16]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const o = &w.interface;
    var err_buf: [4096]u8 = undefined;
    var ew = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
    const e = &ew.interface;

    const gpa = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next();
    const path = args_it.next() orelse {
        try e.writeAll("usage: view-dump <script.sql> > schema.sql\n");
        try e.flush();
        std.process.exit(2);
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(1 << 29));
    const stmts = try driver.splitStatements(arena, bytes);
    try e.print("-- {d} statements, {d} bytes\n", .{ stmts.len, bytes.len });
    try e.flush();

    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();

    const t_replay = std.Io.Clock.awake.now(init.io);
    var last: []const u8 = "";
    for (stmts, 0..) |stmt, i| {
        last = stmt;
        db.exec(stmt, &.{}, .{}) catch |err| {
            try e.print("statement {d} failed: {s}: {s}\n  {s}\n", .{
                i + 1, @errorName(err), db.lastError(), stmt[0..@min(stmt.len, 240)],
            });
            try e.flush();
            std.process.exit(1);
        };
        if ((i + 1) % 250 == 0) {
            try e.print("   {d}/{d}  {d:.1}s\n", .{ i + 1, stmts.len, ms(t_replay, init.io) / 1000 });
            try e.flush();
        }
    }
    const replay_ms = ms(t_replay, init.io);

    // The last statement again, in isolation: replay already paid these costs,
    // but mixed in with 2000 others.
    phase.reset();
    const t_tr = std.Io.Clock.awake.now(init.io);
    const translated = driver.translateOn(db, arena, last, .{}) catch |err| {
        try e.print("translate failed: {s}: {s}\n", .{ @errorName(err), db.lastError() });
        try e.flush();
        std.process.exit(1);
    };
    const translate_ms = ms(t_tr, init.io);

    var final_bytes: usize = 0;
    for (translated) |s| final_bytes += s.len;

    // Prepare only: rawQuery compiles and hands back rows without stepping.
    const zsql = try arena.dupeZ(u8, translated[translated.len - 1]);
    const t_prep = std.Io.Clock.awake.now(init.io);
    var pr = db.rawQuery(zsql, &.{}) catch |err| {
        try e.print("prepare failed: {s}: {s}\n", .{ @errorName(err), db.lastError() });
        try e.flush();
        std.process.exit(1);
    };
    const prepare_ms = ms(t_prep, init.io);
    pr.deinit();

    // Schema as SQLite holds it, in creation order so it replays as-is.
    var n_view: usize = 0;
    var n_table: usize = 0;
    var n_index: usize = 0;
    var ddl_bytes: usize = 0;
    {
        var rows = try db.rawQuery(
            "SELECT type, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY rowid",
            &.{},
        );
        defer rows.deinit();
        while (try rows.next()) |row| {
            const kind = switch (row[0]) {
                .text => |t| t,
                else => continue,
            };
            const sql = switch (row[1]) {
                .text => |t| t,
                else => continue,
            };
            if (std.mem.eql(u8, kind, "view")) {
                n_view += 1;
            } else if (std.mem.eql(u8, kind, "table")) {
                n_table += 1;
            } else {
                n_index += 1;
            }
            ddl_bytes += sql.len;
            try o.print("{s};\n", .{sql});
        }
    }
    try o.print("\n-- FINAL STATEMENT (translated)\n{s};\n", .{translated[translated.len - 1]});
    try o.flush();

    try e.print(
        \\
        \\-- replay        {d:.1} ms   ({d} statements)
        \\-- schema        {d} tables, {d} views, {d} indexes, {d} bytes of DDL
        \\-- final stmt    translate {d:.1} ms   prepare {d:.1} ms   {d} bytes of SQL
        \\--   analyze {d:.1} ms   transform {d:.1} ms
        \\
    , .{
        replay_ms,                       stmts.len,
        n_table,                         n_view,
        n_index,                         ddl_bytes,
        translate_ms,                    prepare_ms,
        final_bytes,                     msNs(phase.totalNs(.analyze)),
        msNs(phase.totalNs(.transform)),
    });
    try e.flush();
}

fn ms(t0: std.Io.Timestamp, io: std.Io) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) /
        std.time.ns_per_ms;
}

fn msNs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
