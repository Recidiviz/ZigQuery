//! Two bulk patterns the view graph exercises: creating N distinct objects,
//! and repeatedly replacing the same one. The second is the case an
//! append-only catalog delta cannot express, so it forces a handle rebuild.
const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;
    const gpa = std.heap.smp_allocator;

    try o.print("{s:>7} {s:>12} {s:>12} {s:>12}\n", .{ "n", "create ms", "replace ms", "repl ms/op" });
    for ([_]usize{ 100, 200, 400, 800 }) |n| {
        var db = try driver.Db.open(gpa, ":memory:");
        defer db.close();
        var sql: [256]u8 = undefined;

        const t0 = std.Io.Clock.awake.now(init.io);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const s = try std.fmt.bufPrint(&sql, "CREATE TABLE `p.d.t{d}` (a INT64, b STRING)", .{i});
            try db.exec(s, &.{}, .{});
        }
        const create_ms = ms(t0, init.io);

        // CREATE OR REPLACE VIEW over and over: the view graph's dominant op.
        const t1 = std.Io.Clock.awake.now(init.io);
        i = 0;
        while (i < n) : (i += 1) {
            const s = try std.fmt.bufPrint(
                &sql,
                "CREATE OR REPLACE VIEW `p.d.v{d}` AS SELECT a FROM `p.d.t0`",
                .{i},
            );
            try db.exec(s, &.{}, .{});
        }
        const replace_ms = ms(t1, init.io);

        try o.print("{d:>7} {d:>12.1} {d:>12.1} {d:>12.3}\n", .{
            n, create_ms, replace_ms, replace_ms / @as(f64, @floatFromInt(n)),
        });
    }
    try o.flush();
}

fn ms(t0: std.Io.Timestamp, io: std.Io) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_ms;
}
