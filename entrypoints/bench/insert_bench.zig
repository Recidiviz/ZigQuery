//! Where does tabledata.insertAll's time actually go?
//!
//! The Go emulator streams the 18k-row us_az LOOKUPS fixture in ~700 ms; this
//! port took ~5.9 s for the same body. The route timer cannot say which of
//! decode / validate / bind / step owns that, so this replays a captured
//! request body through the same three calls the handler makes and times each.
//!
//! Usage:
//!   zig build insert-bench -Drelease=true -- <body.json> <schema.json>
//!
//! `body.json` is a tabledata.insertAll request body; `schema.json` is the
//! table's `{"fields":[...]}`. tools/../scratchpad/bench_insert.py writes both.

const std = @import("std");
const zigquery = @import("zigquery");
const bqserver = @import("bqserver");
const driver = zigquery.driver;
const tabledata = bqserver.tabledata_handler;
const contentdata = bqserver.contentdata_repository;
const schema_mod = bqserver.schema;

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const body_path = args.next() orelse "scratchpad/body.json";
    const schema_path = args.next() orelse "scratchpad/schema.json";
    // Third arg picks the backing allocator: the server's main.zig runs on
    // DebugAllocator even in a release build, which is worth being able to
    // reproduce here.
    const want_debug = if (args.next()) |a| std.mem.eql(u8, a, "debug") else false;

    var debug_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (want_debug) {
        _ = debug_state.deinit();
    };
    const gpa = if (want_debug) debug_state.allocator() else std.heap.smp_allocator;
    try o.print("allocator: {s}\n", .{if (want_debug) "DebugAllocator" else "smp_allocator"});

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try std.Io.Dir.cwd().readFileAlloc(init.io, body_path, arena, .limited(1 << 30));
    const schema_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, schema_path, arena, .limited(1 << 20));
    try o.print("body {d:.1} MB\n", .{@as(f64, @floatFromInt(body.len)) / 1e6});

    // The file is the bare `{"fields":[...]}` node, not a table resource.
    const schema_json = try std.json.parseFromSliceLeaky(std.json.Value, arena, schema_bytes, .{});
    const fields = schema_json.object.get("fields").?.array.items;

    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();
    try db.exec(
        try schema_mod.createTableDdl(arena, "p", "d", "t", schema_json),
        &.{},
        .{},
    );

    // 1. Decode. The handler parses the whole body into a Value tree before it
    //    looks at a single row.
    const t_parse = std.Io.Clock.awake.now(init.io);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const parse_ms = ms(t_parse, init.io);

    // 2. Unwrap + validate.
    const t_rows = std.Io.Clock.awake.now(init.io);
    const rows = try tabledata.rowsFromBody(arena, parsed);
    const rows_ms = ms(t_rows, init.io);

    const t_val = std.Io.Clock.awake.now(init.io);
    const errs = try tabledata.validateAgainstSchema(arena, fields, rows);
    const val_ms = ms(t_val, init.io);

    // 3. Bind and insert.
    const t_ins = std.Io.Clock.awake.now(init.io);
    var repo = contentdata.Repository{ .arena = arena, .db = db };
    repo.addTableData("p", "d", "t", fields, rows) catch |err| {
        try o.print("addTableData failed: {t} — {s}\n", .{ err, repo.message });
        try o.flush();
        return err;
    };
    const insert_ms = ms(t_ins, init.io);

    const total = parse_ms + rows_ms + val_ms + insert_ms;
    const per_row = insert_ms * 1000 / @as(f64, @floatFromInt(rows.len));
    try o.print(
        \\{d} rows x {d} columns, {d} validation error(s)
        \\{s:<22}{d:>10.1} ms  {d:>5.1}%
        \\{s:<22}{d:>10.1} ms  {d:>5.1}%
        \\{s:<22}{d:>10.1} ms  {d:>5.1}%
        \\{s:<22}{d:>10.1} ms  {d:>5.1}%   ({d:.1} us/row)
        \\{s:<22}{d:>10.1} ms
        \\
    , .{
        rows.len,              fields.len,
        errs.len,              "std.json parse",
        parse_ms,              pct(parse_ms, total),
        "rowsFromBody",        rows_ms,
        pct(rows_ms, total),   "validate",
        val_ms,                pct(val_ms, total),
        "addTableData",        insert_ms,
        pct(insert_ms, total), per_row,
        "total",               total,
    });
    try o.flush();
}

fn ms(t0: std.Io.Timestamp, io: std.Io) f64 {
    return @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) /
        std.time.ns_per_ms;
}

fn pct(part: f64, whole: f64) f64 {
    return if (whole == 0) 0 else part * 100 / whole;
}
