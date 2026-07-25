//! Where does bulk CREATE TABLE time actually go?
//!
//! The catalog is re-rendered and re-parsed on every statement, so loading N
//! tables is inherently O(N^2). This splits that cost into the Zig-side
//! render and everything else (the FFI analyze, which re-parses the rendered
//! JSON and rebuilds a SimpleCatalog in C++).
const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;
    const gpa = std.heap.smp_allocator;

    try o.print("{s:>6} {s:>11} {s:>11} {s:>11} {s:>9}\n", .{ "tables", "total ms", "ms/table", "render ms", "json KB" });
    for ([_]usize{ 250, 500, 1000, 2000 }) |n| {
        var db = try driver.Db.open(gpa, ":memory:");
        defer db.close();
        const t0 = std.Io.Clock.awake.now(init.io);
        var i: usize = 0;
        var sql: [256]u8 = undefined;
        while (i < n) : (i += 1) {
            const s = try std.fmt.bufPrint(&sql, "CREATE TABLE `p.d.t{d}` (a INT64, b STRING, c FLOAT64)", .{i});
            try db.exec(s, &.{}, .{ .catalog_scope = .none });
        }
        const total_ms = ms(t0, init.io);

        // One render at the final catalog size.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const t1 = std.Io.Clock.awake.now(init.io);
        const json = try db.catalog.catalogJson(arena_state.allocator());
        const render_ms = ms(t1, init.io);

        try o.print("{d:>6} {d:>11.1} {d:>11.3} {d:>11.3} {d:>9.1}\n", .{
            n, total_ms, total_ms / @as(f64, @floatFromInt(n)), render_ms,
            @as(f64, @floatFromInt(json.len)) / 1024.0,
        });
    }
    try o.flush();
}

fn ms(t0: std.Io.Timestamp, io: std.Io) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_ms;
}
