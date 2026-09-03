//! Per-row cost of named-timezone resolution (zoneOffsetSeconds), isolated
//! from surrounding per-row overhead by holding the query shape fixed and
//! varying only the zone expression passed to FORMAT_TIMESTAMP.
//!
//! This is the A/B harness for the ICU-tzdata integration: run it once
//! against a binary built with the ICU-backed zoneOffsetSeconds, once against
//! the four-zone hand-rolled DST rules it replaced (git stash the
//! implementation files, rebuild, rerun), and diff the ns/row column. A stage
//! whose zone the old code did not support (anything but UTC, a fixed
//! offset, or the four hardcoded names) is expected to error there — it is
//! reported as failed rather than crashing the run, so the same binary and
//! harness work unmodified against either implementation.
//!
//! Usage: zig build tz-bench -- [rows]
const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const phase = zigquery.phase;

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

const Stage = struct {
    label: []const u8,
    /// SQL expression for FORMAT_TIMESTAMP's 3rd (zone) argument, or "" for
    /// the 2-arg form (no zone at all — the zero-cost fast path).
    zone_expr: []const u8,
};

const stages = [_]Stage{
    .{ .label = "no zone (2-arg)", .zone_expr = "" },
    .{ .label = "fixed offset -08:00", .zone_expr = "'-08:00'" },
    .{ .label = "Asia/Tokyo", .zone_expr = "'Asia/Tokyo'" },
    .{ .label = "America/Los_Angeles", .zone_expr = "'America/Los_Angeles'" },
    .{ .label = "America/New_York", .zone_expr = "'America/New_York'" },
    .{ .label = "Pacific/Auckland", .zone_expr = "'Pacific/Auckland'" },
    .{
        .label = "alternating LA/NY/Tokyo/Auckland",
        .zone_expr =
        \\CASE MOD(x, 4)
        \\  WHEN 0 THEN 'America/Los_Angeles'
        \\  WHEN 1 THEN 'America/New_York'
        \\  WHEN 2 THEN 'Asia/Tokyo'
        \\  ELSE 'Pacific/Auckland'
        \\END
        ,
    },
    // Outside the old hardcoded four: only the ICU-backed implementation
    // resolves this. Expected to fail (whole query, not per-row) when run
    // against the fixed hand-rolled implementation.
    .{ .label = "America/Chicago (new coverage)", .zone_expr = "'America/Chicago'" },
};

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next();
    const rows: usize = if (args_it.next()) |a| try std.fmt.parseInt(usize, a, 10) else 200_000;

    const gpa = std.heap.smp_allocator;

    const db = try driver.Db.open(gpa, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t (x INT64, ts TIMESTAMP)", &.{}, .{});

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(gpa);
    try sql.appendSlice(gpa, "INSERT INTO t (x, ts) SELECT x, " ++
        "TIMESTAMP_ADD(TIMESTAMP '2020-01-01 00:00:00', INTERVAL x SECOND) " ++
        "FROM UNNEST(GENERATE_ARRAY(1, ");
    try sql.print(gpa, "{d}", .{rows});
    try sql.appendSlice(gpa, ")) AS x");
    try db.exec(sql.items, &.{}, .{});

    try o.print("{s:<34} {s:>9} {s:>10}\n", .{ "stage", "total", "ns/row" });
    try o.print("{s}\n", .{"-" ** 58});

    for (stages) |s| {
        var q: std.ArrayList(u8) = .empty;
        defer q.deinit(gpa);
        if (s.zone_expr.len == 0) {
            try q.appendSlice(gpa, "SELECT COUNT(*), MAX(FORMAT_TIMESTAMP('%F %T', ts)) FROM t");
        } else {
            try q.print(gpa, "SELECT COUNT(*), MAX(FORMAT_TIMESTAMP('%F %T', ts, {s})) FROM t", .{s.zone_expr});
        }

        if (runStage(db, q.items)) |ns| {
            try report(o, s.label, ns, rows, null);
        } else |_| {
            try report(o, s.label, 0, 0, db.lastError());
        }
    }

    try o.flush();
}

fn runStage(db: *driver.Db, sql: []const u8) !u64 {
    const start = phase.nowNs();
    var r = try db.query(sql, &.{}, .{});
    defer r.deinit();
    while (try r.next()) |_| {}
    return phase.nowNs() - start;
}

fn report(o: anytype, label: []const u8, ns: u64, rows: usize, failed: ?[]const u8) !void {
    if (failed) |e| {
        try o.print("{s:<34} {s:>9} FAILED: {s}\n", .{ label, "-", e });
        return;
    }
    const per_row = if (rows == 0) 0 else @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(rows));
    try o.print("{s:<34} {d:>7.1}ms {d:>8.1}ns\n", .{ label, ms(ns), per_row });
}
