//! Does a delete force work proportional to catalog size?
//!
//! A removal cannot be expressed as an append-only catalog delta, so the
//! driver rebuilds the analyzer handle and re-pushes everything. If that is
//! what happens, the cost of a create+delete cycle grows with the number of
//! tables already present — which is exactly the shape the view graph hits,
//! since materializing a view deletes and recreates its table.
const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;
    const gpa = std.heap.smp_allocator;

    try o.print("{s:>9} {s:>12} {s:>14} {s:>16}\n", .{ "base", "load ms", "20 cycles ms", "ms per cycle" });
    for ([_]usize{ 100, 250, 500, 1000, 2000 }) |base| {
        var db = try driver.Db.open(gpa, ":memory:");
        defer db.close();
        var sql: [256]u8 = undefined;

        const t_load = std.Io.Clock.awake.now(init.io);
        var i: usize = 0;
        while (i < base) : (i += 1) {
            const s = try std.fmt.bufPrint(&sql, "CREATE TABLE `p.d.t{d}` (a INT64)", .{i});
            try db.exec(s, &.{}, .{});
        }
        const load_ms = ms(t_load, init.io);

        // create + drop, the materialization pattern
        const cycles = 20;
        const t0 = std.Io.Clock.awake.now(init.io);
        i = 0;
        while (i < cycles) : (i += 1) {
            try db.exec("CREATE OR REPLACE TABLE `p.d.mat` AS SELECT 1 AS a", &.{}, .{});
            try db.exec("DROP TABLE IF EXISTS `p.d.mat`", &.{}, .{});
        }
        const ms_total = ms(t0, init.io);
        try o.print("{d:>9} {d:>12.1} {d:>14.1} {d:>16.2}\n", .{ base, load_ms, ms_total, ms_total / cycles });
    }
    try o.flush();
}

fn ms(t0: std.Io.Timestamp, io: std.Io) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_ms;
}
