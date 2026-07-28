//! What does the Value codec cost when there is actually data?
//!
//! The view-graph test moves no rows, so its phase numbers say nothing about
//! per-row work. This builds a table with real values and scans it, so encode
//! and decode run once per value per row.
const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const phase = zetasqlite.phase;

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;
    const gpa = std.heap.smp_allocator;

    const rows: usize = 200_000;

    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();

    // A row shape with one of each interesting kind: an int that travels
    // natively, and a string/date/timestamp that all go through the codec.
    try db.exec(
        \\CREATE TABLE t (n INT64, s STRING, d DATE, ts TIMESTAMP)
    , &.{}, .{});

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa, "INSERT INTO t (n, s, d, ts) SELECT x, CONCAT('row-', CAST(x AS STRING)), " ++
        "DATE_ADD(DATE '2020-01-01', INTERVAL MOD(x, 1000) DAY), " ++
        "TIMESTAMP_ADD(TIMESTAMP '2020-01-01 00:00:00', INTERVAL x SECOND) " ++
        "FROM UNNEST(GENERATE_ARRAY(1, ");
    try sql.print(gpa, "{d}", .{rows});
    try sql.appendSlice(gpa, ")) AS x");

    phase.reset();
    const t_ins = phase.nowNs();
    try db.exec(sql.items, &.{}, .{});
    const ins_ns = phase.nowNs() - t_ins;
    try report(o, "INSERT (encode-heavy)", ins_ns, rows);

    // Full scan: every stored value decodes on the way out.
    phase.reset();
    const t_scan = phase.nowNs();
    var n: usize = 0;
    {
        var r = try db.query("SELECT n, s, d, ts FROM t", &.{}, .{});
        defer r.deinit();
        while (try r.next()) |_| n += 1;
    }
    const scan_ns = phase.nowNs() - t_scan;
    try report(o, "SELECT * (decode-heavy)", scan_ns, n);

    // String work inside UDFs: each call decodes its args and encodes a result.
    phase.reset();
    const t_agg = phase.nowNs();
    {
        var r = try db.query(
            "SELECT COUNT(*), MAX(CONCAT(UPPER(s), '-', CAST(d AS STRING))) FROM t",
            &.{},
            .{},
        );
        defer r.deinit();
        while (try r.next()) |_| {}
    }
    const agg_ns = phase.nowNs() - t_agg;
    try report(o, "nested UDFs over strings", agg_ns, rows);

    try o.flush();
}

fn report(o: anytype, label: []const u8, total_ns: u64, n: usize) !void {
    const codec_ms = ms(phase.totalNs(.codec));
    const total_ms = ms(total_ns);
    try o.print(
        "{s:<26} {d:>8.1} ms total   codec {d:>7.1} ms ({d:>4.1}%)  {d} calls over {d} rows\n",
        .{ label, total_ms, codec_ms, if (total_ms == 0) 0 else 100 * codec_ms / total_ms, phase.count(.codec), n },
    );
}
