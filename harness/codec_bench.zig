//! What does the Value codec cost when there is actually data?
//!
//! The view-graph test moves no rows, so its phase numbers say nothing about
//! per-row work. This builds a table with real values and scans it, so encode
//! and decode run once per value per row.
//!
//! Reading the output. `codec adj` is encode+decode+literal with each span
//! charged the measured cost of its own timer, taken from the INT64 control
//! stage — without that subtraction the numbers are substantially a measurement
//! of clock_gettime.
//!
//! `alloc/row` counts allocations made through the allocator handed to the
//! driver, which is where the codec's own churn lands.
const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const phase = zetasqlite.phase;

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn pct(part_ms: f64, total_ms: f64) f64 {
    return if (total_ms == 0) 0 else 100 * part_ms / total_ms;
}

/// Counts every allocation reaching the backing allocator. The codec allocates
/// per value (encodeBinaryValue's ArrayList, decode's alloc.dupe) and
/// collateCmp builds a whole arena per comparison, so this is the counter that
/// shows allocation churn the phase timers cannot.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocs: u64 = 0,
    frees: u64 = 0,
    bytes: u64 = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = rawAlloc,
            .resize = rawResize,
            .remap = rawRemap,
            .free = rawFree,
        } };
    }

    fn reset(self: *CountingAllocator) void {
        self.allocs = 0;
        self.frees = 0;
        self.bytes = 0;
    }

    fn rawAlloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, a, ra);
        if (p != null) {
            self.allocs += 1;
            self.bytes += len;
        }
        return p;
    }

    fn rawResize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(mem, a, new_len, ra);
    }

    fn rawRemap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(mem, a, new_len, ra);
    }

    fn rawFree(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.backing.rawFree(mem, a, ra);
    }
};

const Stage = struct {
    label: []const u8,
    total_ns: u64,
    rows: usize,
    allocs: u64,
    frees: u64,
    // Phase counters snapshotted at stage end, since the next stage resets them.
    codec_ns: u64 = 0,
    codec_calls: u64 = 0,
    encode_ns: u64 = 0,
    encode_calls: u64 = 0,
    decode_ns: u64 = 0,
    decode_calls: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const o = &w.interface;

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next();
    const rows: usize = if (args_it.next()) |a| try std.fmt.parseInt(usize, a, 10) else 200_000;

    // Without the timers every codec column reads zero, which looks like a
    // result rather than a missing instrument. Refuse rather than mislead.
    if (!phase.codec_timers_enabled) {
        try o.print(
            "codec-bench needs the codec phase timers, which are off by default because\n" ++
                "they cost ~18ns per span and there are millions of spans.\n\n" ++
                "    zig build codec-bench -Drelease=true -Dcodec-timers=true -- [rows]\n\n" ++
                "Note the timers inflate what they measure; the harness subtracts a per-span\n" ++
                "estimate taken from the INT64 control stage.\n",
            .{},
        );
        try o.flush();
        return;
    }

    var counting: CountingAllocator = .{ .backing = std.heap.smp_allocator };
    const gpa = counting.allocator();

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

    var stages: [9]Stage = undefined;
    var ns: usize = 0;

    var stage = try begin(&counting);
    try db.exec(sql.items, &.{}, .{});
    stages[ns] = end(stage, "INSERT (encode-heavy)", rows, &counting);
    ns += 1;

    // Full scan: every stored value decodes on the way out.
    stage = try begin(&counting);
    var n: usize = 0;
    {
        var r = try db.query("SELECT n, s, d, ts FROM t", &.{}, .{});
        defer r.deinit();
        while (try r.next()) |_| n += 1;
    }
    stages[ns] = end(stage, "SELECT * (decode-heavy)", n, &counting);
    ns += 1;

    // String work inside UDFs: each call decodes its args and encodes a result.
    stage = try begin(&counting);
    {
        var r = try db.query(
            "SELECT COUNT(*), MAX(CONCAT(UPPER(s), '-', CAST(d AS STRING))) FROM t",
            &.{},
            .{},
        );
        defer r.deinit();
        while (try r.next()) |_| {}
    }
    stages[ns] = end(stage, "nested UDFs over strings", rows, &counting);
    ns += 1;

    // The declared pain: sheer scalar-UDF call volume. Every function here is a
    // zetasqlite_* UDF, so each one decodes its arguments and encodes a result,
    // and the nesting multiplies that per row. Aggregated to one row so the
    // client boundary contributes nothing.
    stage = try begin(&counting);
    {
        var r = try db.query(
            \\SELECT COUNT(*), MAX(LENGTH(CONCAT(
            \\  SUBSTR(UPPER(s), 1, 6), '|',
            \\  REPLACE(LOWER(s), 'row', 'r'), '|',
            \\  CAST(CAST(d AS STRING) AS STRING), '|',
            \\  TRIM(CONCAT(s, '  ')), '|',
            \\  CAST(n + LENGTH(s) AS STRING)
            \\))) FROM t
        , &.{}, .{});
        defer r.deinit();
        while (try r.next()) |_| {}
    }
    stages[ns] = end(stage, "scalar UDF volume", rows, &counting);
    ns += 1;

    // Control: the same shape of work over INT64 only, which never touches the
    // codec. If this stage shows codec time, the instrumentation is wrong.
    stage = try begin(&counting);
    {
        var r = try db.query(
            \\SELECT COUNT(*), MAX(((n * 3) + (n / 2) - MOD(n, 7)) * 2 + MOD(n * 5, 13)) FROM t
        , &.{}, .{});
        defer r.deinit();
        while (try r.next()) |_| {}
    }
    stages[ns] = end(stage, "INT64 control (no codec)", rows, &counting);
    ns += 1;

    // Sort over an encoded column. This used to enter zetasqlite_collate for
    // every comparison; since the encoding became memcomparable SQLite compares
    // the bytes directly and no callback is involved.
    stage = try begin(&counting);
    n = 0;
    {
        var r = try db.query("SELECT s FROM t ORDER BY s", &.{}, .{});
        defer r.deinit();
        while (try r.next()) |_| n += 1;
    }
    stages[ns] = end(stage, "ORDER BY string", n, &counting);
    ns += 1;

    // The same sort over the native INT64 column. The gap between the two is
    // now just payload width, not a callback.
    stage = try begin(&counting);
    n = 0;
    {
        var r = try db.query("SELECT n FROM t ORDER BY n", &.{}, .{});
        defer r.deinit();
        while (try r.next()) |_| n += 1;
    }
    stages[ns] = end(stage, "ORDER BY int", n, &counting);
    ns += 1;

    // A scan dominated by UNNEST itself: one large array, every element read.
    // This is the path zetasqlite_unnest replaced, and the one a BLOB format
    // would next take work out of.
    stage = try begin(&counting);
    {
        var sql2: std.ArrayList(u8) = .empty;
        defer sql2.deinit(gpa);
        try sql2.print(gpa, "SELECT COUNT(*), MAX(x) FROM UNNEST(GENERATE_ARRAY(1, {d})) AS x", .{rows});
        var r = try db.query(sql2.items, &.{}, .{});
        defer r.deinit();
        while (try r.next()) |_| {}
    }
    stages[ns] = end(stage, "UNNEST scan", rows, &counting);
    ns += 1;

    // Ordered aggregation. zetasqlite_order_by takes the per-row sort key, so
    // SQLite cannot hoist it: the option marker is built once per row, and the
    // aggregate parses it again on every step. The other modifiers take
    // constant arguments and are hoisted, so this is where marker cost lives.
    stage = try begin(&counting);
    {
        var r = try db.query(
            "SELECT COUNT(*) FROM (SELECT ARRAY_AGG(s ORDER BY n) AS a FROM t)",
            &.{},
            .{},
        );
        defer r.deinit();
        while (try r.next()) |_| {}
    }
    stages[ns] = end(stage, "ARRAY_AGG(... ORDER BY)", rows, &counting);
    ns += 1;

    // The control stage does no real codec work — every value in it is a native
    // INT64, so EncodeValue is a switch and a return. Whatever time it recorded
    // is therefore the instrumentation measuring itself, and dividing by its
    // call count gives the per-span cost of the timer. Subtracting that from
    // every stage is what turns these numbers into an honest gate rather than a
    // measurement of clock_gettime.
    const control = stages[4];
    const overhead_ns: f64 = if (control.codec_calls == 0) 0 else @as(f64, @floatFromInt(control.codec_ns)) /
        @as(f64, @floatFromInt(control.codec_calls));
    try o.print(
        "timer overhead: {d:.1} ns per codec span, from the INT64 control stage " ++
            "({d} spans, {d:.1}ms of pure instrumentation)\n\n",
        .{ overhead_ns, control.codec_calls, ms(control.codec_ns) },
    );

    try header(o);
    for (stages[0..ns]) |s| try report(o, s, overhead_ns);

    try o.print(
        "\ncodec adj = codec time minus (spans x timer overhead); " ++
            "encode/decode/literal partition it.\n",
        .{},
    );

    try o.flush();
}

fn begin(counting: *CountingAllocator) !Stage {
    phase.reset();
    counting.reset();
    return .{ .label = "", .total_ns = phase.nowNs(), .rows = 0, .allocs = 0, .frees = 0 };
}

fn end(s: Stage, label: []const u8, rows: usize, counting: *CountingAllocator) Stage {
    return .{
        .label = label,
        .total_ns = phase.nowNs() - s.total_ns,
        .rows = rows,
        .allocs = counting.allocs,
        .frees = counting.frees,
        .codec_ns = phase.codecTotalNs(),
        .codec_calls = phase.codecCount(),
        .encode_ns = phase.totalNs(.codec_encode),
        .encode_calls = phase.count(.codec_encode),
        .decode_ns = phase.totalNs(.codec_decode),
        .decode_calls = phase.count(.codec_decode),
    };
}

fn header(o: anytype) !void {
    try o.print(
        "{s:<26} {s:>8} {s:>10} {s:>7} {s:>11} {s:>9}\n",
        .{ "stage", "total", "codec adj", "%", "codec spans", "alloc/row" },
    );
    try o.print("{s}\n", .{"-" ** 74});
}

fn report(o: anytype, s: Stage, overhead_ns: f64) !void {
    const total_ms = ms(s.total_ns);

    // Charge every codec span the measured cost of its own timer and hand back
    // the remainder. Clamped at zero: a stage whose real codec work is below
    // the noise floor should read as 0, not as a negative.
    const overhead_total = overhead_ns * @as(f64, @floatFromInt(s.codec_calls));
    const codec_adj_ms = @max(0, (@as(f64, @floatFromInt(s.codec_ns)) - overhead_total) / 1e6);

    const per_row = if (s.rows == 0) 0 else @as(f64, @floatFromInt(s.allocs)) / @as(f64, @floatFromInt(s.rows));

    try o.print(
        "{s:<26} {d:>6.1}ms {d:>8.1}ms {d:>6.1}% {d:>11} {d:>9.2}\n",
        .{ s.label, total_ms, codec_adj_ms, pct(codec_adj_ms, total_ms), s.codec_calls, per_row },
    );
    // Encode vs decode, so it is visible which direction a change should
    // target. Raw, not overhead-adjusted; subtract spans x overhead to compare
    // against the adjusted column above.
    try o.print(
        "{s:<26} encode {d:>6.1}ms /{d:>9}   decode {d:>6.1}ms /{d:>9}   literal {d:>5.1}ms /{d:>6}\n",
        .{
            "",
            ms(s.encode_ns),  s.encode_calls,
            ms(s.decode_ns),  s.decode_calls,
            ms(phase_literal_ns(s)), s.codec_calls - s.encode_calls - s.decode_calls,
        },
    );
}

fn phase_literal_ns(s: Stage) u64 {
    return s.codec_ns -| s.encode_ns -| s.decode_ns;
}
