//! CLI: zetasqlite-zig [--sql] [--file <path>] [--explain] ["SELECT ..."]
//!
//! Executes GoogleSQL against an in-memory database and prints the result rows
//! (tab-separated, header first).
//!
//!   --sql      print the generated SQLite SQL instead of executing
//!   --file P   run every statement in P first, against one database, so a
//!              whole view graph can be recreated before the query runs
//!   --explain  print SQLite's query plan for the final statement instead of
//!              its rows
//!
//! The --file/--explain pair is what makes a dumped view ancestry useful:
//!
//!   uv run recidiviz/tools/emulator/dump_view_ancestry.py \
//!       --view sessions.compartment_sessions --output /tmp/a.sql
//!   zetasqlite-zig --file /tmp/a.sql --explain
//!
//! The plan comes from EXPLAIN QUERY PLAN over the *translated* SQL, run on the
//! raw SQLite handle — the GoogleSQL analyzer has no EXPLAIN of its own, and
//! the plan is a property of what we emit, not of what the user wrote.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    var print_sql = false;
    var explain = false;
    var show_stats = false;
    var script_path: ?[]const u8 = null;
    var sql: ?[]const u8 = null;
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next(); // program name
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sql")) {
            print_sql = true;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            explain = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            show_stats = true;
        } else if (std.mem.eql(u8, arg, "--file")) {
            script_path = args_it.next() orelse {
                try out.writeAll("error: --file needs a path\n");
                try out.flush();
                std.process.exit(2);
            };
        } else {
            sql = arg;
        }
    }

    if (sql == null and script_path == null) {
        try out.writeAll(
            "usage: zetasqlite-zig [--sql] [--file <path>] [--stats] [--explain] [\"SELECT ...\"]\n",
        );
        try out.flush();
        std.process.exit(2);
    }

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (print_sql) {
        const stmts = driver.translate(arena, sql.?, .{}) catch |err| {
            try out.print("error: {s}: {s}\n", .{
                @errorName(err),
                zetasqlite.analyzer_ffi.last_error,
            });
            try out.flush();
            std.process.exit(1);
        };
        for (stmts) |stmt| try out.print("{s};\n", .{stmt});
        try out.flush();
        return;
    }

    var db = try driver.Db.open(init.gpa, ":memory:");
    defer db.close();

    // The script runs first and its results are discarded: it exists to put
    // tables and views in place. A statement that fails is reported and the
    // run stops, because everything after it is building on missing ground.
    var last_from_script: ?[]const u8 = null;
    if (script_path) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(1 << 28)) catch |err| {
            try out.print("error: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            try out.flush();
            std.process.exit(1);
        };
        const stmts = try driver.splitStatements(arena, bytes);
        var n: usize = 0;
        for (stmts) |stmt| {
            last_from_script = stmt;
            n += 1;
            db.exec(stmt, &.{}, .{}) catch |err| {
                try out.print(
                    "error: statement {d} failed: {s}: {s}\n  {s}\n",
                    .{ n, @errorName(err), db.lastError(), stmt[0..@min(stmt.len, 300)] },
                );
                try out.flush();
                std.process.exit(1);
            };
        }
        try out.print("-- ran {d} statements from {s}\n", .{ n, path });
        // The script is setup, not the thing being measured.
        if (show_stats) zetasqlite.phase.reset();
    }

    // With no query of its own, --file means "run the script, then explain (or
    // run) its last statement" — which for a dumped ancestry is the SELECT the
    // whole graph was built for.
    const query = sql orelse last_from_script orelse return;

    // Wall clock for the query alone — the script above is setup. The phase
    // totals partition only the work that is instrumented, so the gap between
    // them and this is the answer to "what isn't being measured?"
    const query_start = zetasqlite.phase.nowNs();

    if (explain) {
        try explainQuery(arena, out, db, query);
        if (show_stats) try printPhases(out, zetasqlite.phase.nowNs() -| query_start);
        try out.flush();
        return;
    }

    var rows = db.query(query, &.{}, .{}) catch |err| {
        try out.print("error: {s}: {s}\n", .{ @errorName(err), db.lastError() });
        try out.flush();
        std.process.exit(1);
    };
    defer rows.deinit();

    for (rows.columns(), 0..) |name, i| {
        if (i > 0) try out.writeAll("\t");
        try out.print("{s}", .{name});
    }
    try out.writeAll("\n");

    while (rows.next() catch |err| {
        try out.print("error: {s}: {s}\n", .{ @errorName(err), db.lastError() });
        try out.flush();
        std.process.exit(1);
    }) |row| {
        for (row, 0..) |cell, i| {
            if (i > 0) try out.writeAll("\t");
            try printCell(out, cell);
        }
        try out.writeAll("\n");
    }
    if (show_stats) try printPhases(out, zetasqlite.phase.nowNs() -| query_start);
    try out.flush();
}

/// Where this statement's time went. Answers "is the plan the problem?" — for
/// a query over empty tables it usually is not.
///
/// `total_ns` is measured wall time for the query, row printing included; the
/// phases below are subsets of it, not a partition of it.
fn printPhases(out: *std.Io.Writer, total_ns: u64) !void {
    const phase = zetasqlite.phase;
    const ms = struct {
        fn of(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.of;
    try out.print(
        "\n-- total {d:.2}ms  analyze {d:.2}ms ({d})  transform {d:.2}ms ({d})  prepare {d:.2}ms ({d})  " ++
            "step {d:.2}ms ({d})  exec {d:.2}ms ({d})  sql {d} bytes\n",
        .{
            ms(total_ns),
            ms(phase.totalNs(.analyze)),        phase.count(.analyze),
            ms(phase.totalNs(.transform)),      phase.count(.transform),
            ms(phase.totalNs(.sqlite_prepare)), phase.count(.sqlite_prepare),
            ms(phase.totalNs(.sqlite_step)),    phase.count(.sqlite_step),
            ms(phase.totalNs(.sqlite_exec)),    phase.count(.sqlite_exec),
            phase.preparedBytes(),
        },
    );
    // Separate line because encode/decode/literal partition `codec`, so the
    // total is not the sum of the whole line.
    try out.print(
        "-- codec {d:.2}ms ({d})  encode {d:.2}ms ({d})  decode {d:.2}ms ({d})  " ++
            "literal {d:.2}ms ({d})\n",
        .{
            ms(phase.codecTotalNs()),          phase.codecCount(),
            ms(phase.totalNs(.codec_encode)),  phase.count(.codec_encode),
            ms(phase.totalNs(.codec_decode)),  phase.count(.codec_decode),
            ms(phase.totalNs(.codec_literal)), phase.count(.codec_literal),
        },
    );
}

/// EXPLAIN QUERY PLAN over the translated SQL, on the raw handle.
fn explainQuery(
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    db: *driver.Db,
    query: []const u8,
) !void {
    const stmts = driver.translateOn(db, arena, query, .{}) catch |err| {
        try out.print("error: translate: {s}: {s}\n", .{ @errorName(err), db.lastError() });
        return;
    };
    for (stmts) |stmt| {
        const z = try std.fmt.allocPrintSentinel(arena, "EXPLAIN QUERY PLAN {s}", .{stmt}, 0);
        var rows = db.rawQuery(z, &.{}) catch |err| {
            try out.print("error: explain: {s}: {s}\n", .{ @errorName(err), db.lastError() });
            return;
        };
        defer rows.deinit();
        try out.print("QUERY PLAN  ({d} bytes of SQL)\n", .{stmt.len});
        while (try rows.next()) |row| {
            // EXPLAIN QUERY PLAN yields (id, parent, notused, detail); only the
            // detail is worth printing, indented by nesting depth.
            const detail = if (row.len >= 4) row[3] else continue;
            const parent: i64 = switch (row[1]) {
                .int => |v| v,
                else => 0,
            };
            try out.splatByteAll(' ', if (parent == 0) 2 else 4);
            switch (detail) {
                .text => |t| try out.print("{s}\n", .{t}),
                else => try out.writeAll("?\n"),
            }
        }
    }
}

fn printCell(out: *std.Io.Writer, cell: driver.Cell) std.Io.Writer.Error!void {
    switch (cell) {
        .null => try out.writeAll("NULL"),
        .int => |i| try out.print("{d}", .{i}),
        .float => |f| try out.print("{d}", .{f}),
        .bool => |b| try out.writeAll(if (b) "true" else "false"),
        .string, .json => |s| try out.print("{s}", .{s}),
        .date => |s| try out.print("{s}", .{s}),
        .timestamp, .datetime, .time, .interval => |s| try out.print("{s}", .{s}),
        .bytes => |b| {
            for (b) |c| try out.print("{x:0>2}", .{c});
        },
        .array => |cells| {
            try out.writeAll("[");
            for (cells, 0..) |c, i| {
                if (i > 0) try out.writeAll(", ");
                try printCell(out, c);
            }
            try out.writeAll("]");
        },
        .struct_ => |fields| {
            try out.writeAll("{");
            for (fields, 0..) |field, i| {
                if (i > 0) try out.writeAll(", ");
                try out.print("{s}: ", .{field.name});
                try printCell(out, field.value);
            }
            try out.writeAll("}");
        },
    }
}

const testing = std.testing;

test "replay splitting comes from the driver and survives prose" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const stmts = try driver.splitStatements(arena.allocator(),
        \\-- a comment; with a semicolon
        \\CREATE TABLE `a` (x STRING);
        \\CREATE VIEW `b` OPTIONS(description='''has; a semicolon''') AS SELECT 'x;y';
        \\# hash comment; also semicolons
        \\CREATE VIEW `c` AS /* block; comment */ SELECT 1;
        \\SELECT 2
    );
    try testing.expectEqual(@as(usize, 5), stmts.len);
    try testing.expectEqualStrings("SELECT 2", stmts[4]);
}
