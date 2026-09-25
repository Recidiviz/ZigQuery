//! Where does a load job's time and memory actually go?
//!
//! The route timer says a load took N ms. It cannot say whether that was reading the CSV,
//! inferring the column types, or binding the rows into SQLite, and the three have different
//! fixes. This runs the same calls the upload handler makes, on a generated body, and reports
//! each one.
//!
//! Memory is reported three ways because they answer different questions. The request arena is
//! what one upload costs to hold; SQLite's own high-water is what the rows cost once stored;
//! max RSS is what the process asked the kernel for, which includes both and the analyzer.
//!
//! Usage:
//!   zig build load-job-bench -Drelease=true -- [rows] [columns]

const std = @import("std");
const zigquery = @import("zigquery");
const bqserver = @import("bqserver");
const driver = zigquery.driver;
const csv = bqserver.csv;
const autodetect = bqserver.autodetect;
const load_rows = bqserver.load_rows;
const load_handler = bqserver.load_handler;
const contentdata = bqserver.contentdata_repository;
const schema_mod = bqserver.schema;

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const rows = try parseArg(args.next(), 100_000);
    const columns = try parseArg(args.next(), 8);

    const gpa = std.heap.smp_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const media = try generateCsv(arena, rows, columns);
    try o.print(
        "{d} rows x {d} columns, {d:.1} MB of CSV\n\n",
        .{ rows, columns, mb(media.len) },
    );

    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    };

    // The two halves of the read, timed on their own before the whole, so the whole can be
    // attributed rather than only measured.
    const t_csv = std.Io.Clock.awake.now(init.io);
    const parsed = try csv.parse(arena, media, .{});
    const csv_ms = ms(t_csv, init.io);

    const texts = try arena.alloc([]const []const u8, parsed.len);
    for (parsed, texts) |row, *dst| {
        const cells = try arena.alloc([]const u8, row.len);
        for (row, cells) |field, *cell| cell.* = field.text;
        dst.* = cells;
    }

    const t_detect = std.Io.Clock.awake.now(init.io);
    const detection = try autodetect.detect(arena, texts, null);
    const detect_ms = ms(t_detect, init.io);

    const arena_after_parse = arena_state.queryCapacity();

    const t_read = std.Io.Clock.awake.now(init.io);
    const reading = try load_rows.read(arena, media, spec, null);
    const read_ms = ms(t_read, init.io);
    const arena_after_read = arena_state.queryCapacity();

    const t_ddl = std.Io.Clock.awake.now(init.io);
    try db.exec(
        try schema_mod.createTableDdl(arena, "p", "d", "t", reading.schema_node),
        &.{},
        .{},
    );
    const ddl_ms = ms(t_ddl, init.io);

    const before = db.allocStats();
    const t_write = std.Io.Clock.awake.now(init.io);
    var repo = contentdata.Repository{ .arena = arena, .db = db };
    const result = try repo.addTableData(
        "p",
        "d",
        "t",
        reading.schema_fields,
        reading.rows,
        .{ .skip_invalid_rows = true },
    );
    const write_ms = ms(t_write, init.io);
    const after = db.allocStats();

    const total = read_ms + ddl_ms + write_ms;
    try o.print(
        \\detected {d} columns, wrote {d} rows, {d} rejected
        \\
        \\{s:<26}{d:>10.1} ms  {d:>5.1}%
        \\{s:<26}{d:>10.1} ms  {d:>5.1}%
        \\{s:<26}{d:>10.1} ms  {d:>5.1}%
        \\{s:<26}{d:>10.1} ms
        \\
        \\  of the read half:
        \\{s:<26}{d:>10.1} ms
        \\{s:<26}{d:>10.1} ms
        \\
    , .{
        detection.columns.len,
        reading.rows.len,
        result.invalid.len,
        "read (csv + detect + rows)",
        read_ms,
        pct(read_ms, total),
        "create table",
        ddl_ms,
        pct(ddl_ms, total),
        "addTableData",
        write_ms,
        pct(write_ms, total),
        "total",
        total,
        "  csv.parse",
        csv_ms,
        "  autodetect.detect",
        detect_ms,
    });

    // Arena capacity is what was reserved, not what was asked for: the arena grows in
    // doubling chunks, so this is an upper bound. Max RSS below is the corroborating figure.
    try o.print(
        \\
        \\{s:<26}{d:>10.1} MB   ({d:.1}x the CSV, reserved)
        \\{s:<26}{d:>10.1} MB
        \\
        \\{d:.2} us/row read, {d:.2} us/row written
        \\
    , .{
        "arena after read",
        mb(arena_after_read),
        @as(f64, @floatFromInt(arena_after_read)) / @as(f64, @floatFromInt(media.len)),
        "  of which csv + detect",
        mb(arena_after_parse),
        usPerRow(read_ms, reading.rows.len),
        usPerRow(write_ms, reading.rows.len),
    });

    if (zigquery.sqlite.memStatsEnabled()) {
        try o.print(
            \\{s:<26}{d:>10.1} MB   peak {d:.1} MB
            \\{s:<26}{d:>10.1} MB
            \\
        , .{
            "sqlite held",
            mb(@intCast(after.memory_used.current)),
            mb(@intCast(after.memory_used.highwater)),
            "sqlite gained by the write",
            mb(@intCast(after.memory_used.current - before.memory_used.current)),
        });
    } else {
        try o.print(
            "{s:<26}{s:>10}   (set ZQL_MEM_STATS=1)\n",
            .{ "sqlite held", "not measured" },
        );
    }

    if (maxRssBytes()) |peak| {
        try o.print("{s:<26}{d:>10.1} MB\n", .{ "process max RSS", mb(peak) });
    }
    try o.flush();
}

/// A CSV whose columns exercise each inferred type, so detection does the work it would on a
/// real body rather than short-circuiting on one kind.
fn generateCsv(arena: std.mem.Allocator, rows: usize, columns: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..columns) |c| {
        if (c > 0) try out.append(arena, ',');
        try out.print(arena, "col_{d}", .{c});
    }
    try out.append(arena, '\n');

    for (0..rows) |r| {
        for (0..columns) |c| {
            if (c > 0) try out.append(arena, ',');
            switch (c % 4) {
                0 => try out.print(arena, "{d}", .{r}),
                1 => try out.print(arena, "name_{d}", .{r % 1000}),
                2 => try out.print(arena, "{d}.{d}", .{ r % 100, r % 10 }),
                else => try out.print(arena, "2024-{d:0>2}-{d:0>2}", .{ r % 12 + 1, r % 28 + 1 }),
            }
        }
        try out.append(arena, '\n');
    }
    return out.items;
}

fn parseArg(text: ?[]const u8, default: usize) !usize {
    const t = text orelse return default;
    return std.fmt.parseInt(usize, t, 10) catch default;
}

fn ms(t0: std.Io.Timestamp, io: std.Io) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) /
        std.time.ns_per_ms;
}

fn pct(part: f64, whole: f64) f64 {
    return if (whole == 0) 0 else part * 100 / whole;
}

fn mb(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1e6;
}

fn usPerRow(millis: f64, rows: usize) f64 {
    return if (rows == 0) 0 else millis * 1000 / @as(f64, @floatFromInt(rows));
}

/// What the kernel says the process asked for. Darwin reports bytes where Linux reports
/// kilobytes.
fn maxRssBytes() ?usize {
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(0, &usage) != 0) return null;
    const raw: usize = @intCast(usage.maxrss);
    return if (@import("builtin").os.tag == .macos) raw else raw * 1024;
}
