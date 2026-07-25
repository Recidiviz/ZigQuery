//! Concurrency gating experiment. No Go counterpart — go-zetasqlite never
//! ran the analyzer concurrently, because bigquery-emulator serialized every
//! request behind one process-wide mutex (server/middleware.go
//! sequentialAccessMiddleware).
//!
//! The question this answers: can N threads each drive their own driver.Db
//! safely? The C++ shim itself is stateless per call (analyzer_shim.cc builds
//! LanguageOptions/AnalyzerOptions/TypeFactory/SimpleCatalog fresh every
//! invocation), but GoogleSQL, protobuf, ICU, RE2 and absl have not been
//! audited here for process-wide lazy initialization. A negative result means
//! the server must funnel engine work through a single analyzer thread.
//!
//! Three tiers:
//!   A  translate-only: analyzer + extractor + transformer, no SQLite.
//!   B  full stack: per-thread Db on its own memdb, exercising UDFs
//!      (RE2 via REGEXP_*, ICU via NORMALIZE/UPPER/collation), STRUCT/ARRAY
//!      catalogs, and analysis-error paths (absl status formatting).
//!   C  positive control: GENERATE_UUID uniqueness. `uuid_seed` in
//!      internal/function/fn_net.zig is a plain non-threadlocal global, so
//!      this tier MUST fail before that is fixed. If tier C passes on an
//!      unfixed tree the harness is not actually detecting races and tiers
//!      A/B prove nothing.
//!
//! Exit status: nonzero if any tier reports a mismatch.
//!
//! Usage: zig build analyzer-threads -- [iterations] [threads]

const std = @import("std");
const builtin = @import("builtin");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

/// Statements chosen to reach the libraries most likely to carry
/// process-wide state, not for SQL coverage.
const translate_cases = [_][]const u8{
    // Plain analysis.
    "SELECT 1 AS a, 'x' AS b",
    "SELECT a FROM UNNEST([1, 2, 3]) AS a WHERE a > 1",
    // STRUCT/ARRAY: drives TypeFactory and the protobuf descriptor pool
    // through SimpleCatalog::Deserialize.
    "SELECT STRUCT(1 AS x, [2, 3] AS y) AS s",
    "SELECT ARRAY(SELECT AS STRUCT 1 AS a, 'b' AS b)",
    // RE2.
    "SELECT REGEXP_CONTAINS('abc', r'^a.c$')",
    "SELECT REGEXP_REPLACE('a-b-c', r'-', '_')",
    "SELECT REGEXP_EXTRACT('foo123', r'[0-9]+')",
    // ICU.
    "SELECT NORMALIZE('\u{00C5}', NFD)",
    "SELECT UPPER('\u{00E9}\u{00DF}stra\u{00DF}e')",
    // Analytic + aggregate: heavier resolver paths.
    "SELECT SUM(x) OVER (ORDER BY x) FROM UNNEST([1, 2, 3]) AS x",
    // Analysis errors: absl Status formatting + the shim's error path.
    "SELECT * FROM no_such_table_xyz",
    "SELECT 1 +",
    "SELECT nonexistent_function_xyz(1)",
};

/// Run against a per-thread Db. Each returns a single scalar so results
/// compare cheaply.
const query_cases = [_][]const u8{
    "SELECT REGEXP_CONTAINS('abc', r'^a.c$')",
    "SELECT REGEXP_REPLACE('a-b-c', r'-', '_')",
    "SELECT NORMALIZE('\u{00C5}', NFD)",
    "SELECT UPPER('stra\u{00DF}e')",
    "SELECT FORMAT('%t', STRUCT(1 AS x, 'y' AS y))",
    "SELECT TO_JSON_STRING(STRUCT([1, 2] AS a))",
    "SELECT CAST('2024-01-02 03:04:05' AS TIMESTAMP)",
    "SELECT ARRAY_TO_STRING(['a', 'b'], ',')",
    "SELECT SUM(x) FROM UNNEST([1, 2, 3]) AS x",
};

const Failure = struct {
    tier: []const u8,
    detail: []const u8,
};

const Shared = struct {
    gpa: std.mem.Allocator,
    iterations: usize,
    /// Oracle digests, indexed like the case arrays.
    translate_oracle: []const u64,
    query_oracle: []const u64,
    mismatches: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (builtin.mode == .Debug) gpa_state.allocator() else std.heap.smp_allocator;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    const iterations: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 2000;
    const threads: usize = if (args.next()) |a|
        try std.fmt.parseInt(usize, a, 10)
    else
        @max(2, std.Thread.getCpuCount() catch 4);

    try out.print(
        "analyzer-threads: {d} threads x {d} iterations ({s})\n",
        .{ threads, iterations, @tagName(builtin.mode) },
    );

    // ---- Oracles, computed single-threaded ----
    const translate_oracle = try buildTranslateOracle(gpa);
    defer gpa.free(translate_oracle);
    const query_oracle = try buildQueryOracle(gpa);
    defer gpa.free(query_oracle);
    try out.print(
        "oracle: {d} translate cases, {d} query cases\n",
        .{ translate_oracle.len, query_oracle.len },
    );

    var shared = Shared{
        .gpa = gpa,
        .iterations = iterations,
        .translate_oracle = translate_oracle,
        .query_oracle = query_oracle,
    };

    // ---- Tiers A + B ----
    const workers = try gpa.alloc(std.Thread, threads);
    defer gpa.free(workers);
    const t0 = std.Io.Clock.awake.now(init.io);
    for (workers, 0..) |*w, i| {
        w.* = try std.Thread.spawn(.{}, worker, .{ &shared, i });
    }
    for (workers) |w| w.join();
    const elapsed_ms = @as(f64, @floatFromInt(
        t0.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds,
    )) / std.time.ns_per_ms;

    const mismatches = shared.mismatches.load(.acquire);
    const errors = shared.errors.load(.acquire);
    try out.print(
        "tiers A+B: {d} mismatches, {d} errors in {d:.1} ms\n",
        .{ mismatches, errors, elapsed_ms },
    );

    // ---- Tier C: uuid positive control ----
    const uuid = try uuidControl(gpa, threads);
    try out.print(
        "tier C (uuid positive control): {d}/{d} duplicates, {d} not produced -- {s}\n",
        .{
            uuid.duplicates,
            uuid.total,
            uuid.empty,
            if (uuid.duplicates > 0)
                "RACE DETECTED (expected pre-fix; harness is sensitive)"
            else
                "NO RACE OBSERVED -- harness cannot detect races, tiers A/B are inconclusive",
        },
    );

    const failed = mismatches > 0 or errors > 0;
    try out.print("RESULT: {s}\n", .{if (failed) "FAIL" else "PASS"});
    try out.flush();
    if (failed) std.process.exit(1);
}

fn buildTranslateOracle(gpa: std.mem.Allocator) ![]u64 {
    const digests = try gpa.alloc(u64, translate_cases.len);
    for (translate_cases, 0..) |sql, i| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        digests[i] = translateDigest(arena_state.allocator(), sql);
    }
    return digests;
}

fn buildQueryOracle(gpa: std.mem.Allocator) ![]u64 {
    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();
    const digests = try gpa.alloc(u64, query_cases.len);
    for (query_cases, 0..) |sql, i| {
        digests[i] = queryDigest(db, sql);
    }
    return digests;
}

/// Digest of the generated SQL, or of the error message when analysis fails.
/// Both are deterministic, so either is a usable oracle.
fn translateDigest(arena: std.mem.Allocator, sql: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    if (driver.translate(arena, sql, .{})) |stmts| {
        for (stmts) |s| h.update(s);
    } else |err| {
        h.update(@errorName(err));
    }
    return h.final();
}

fn queryDigest(db: *driver.Db, sql: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    var rows = db.query(sql, &.{}, .{}) catch {
        h.update(db.lastError());
        return h.final();
    };
    defer rows.deinit();
    while (rows.next() catch null) |row| {
        for (row) |cell| hashCell(&h, cell);
    }
    return h.final();
}

fn hashCell(h: *std.hash.Wyhash, cell: driver.Cell) void {
    h.update(@tagName(cell));
    switch (cell) {
        .null => {},
        .int => |v| h.update(std.mem.asBytes(&v)),
        .float => |v| h.update(std.mem.asBytes(&v)),
        .bool => |v| h.update(std.mem.asBytes(&v)),
        .string, .bytes, .date, .timestamp, .datetime, .time, .interval => |v| h.update(v),
        .array => |items| for (items) |it| hashCell(h, it),
        .struct_ => |fields| for (fields) |f| {
            h.update(f.name);
            hashCell(h, f.value);
        },
    }
}

fn worker(shared: *Shared, thread_index: usize) void {
    // Tier A: translate only, no SQLite involved.
    var i: usize = 0;
    while (i < shared.iterations) : (i += 1) {
        const idx = (i + thread_index) % translate_cases.len;
        var arena_state = std.heap.ArenaAllocator.init(shared.gpa);
        defer arena_state.deinit();
        const got = translateDigest(arena_state.allocator(), translate_cases[idx]);
        if (got != shared.translate_oracle[idx]) {
            _ = shared.mismatches.fetchAdd(1, .release);
        }
    }

    // Tier B: full stack on a private in-memory database. Each thread owns
    // its Db exclusively, which is exactly the server's pool discipline.
    var db = driver.Db.open(shared.gpa, ":memory:") catch {
        _ = shared.errors.fetchAdd(1, .release);
        return;
    };
    defer db.close();

    i = 0;
    while (i < shared.iterations) : (i += 1) {
        const idx = (i + thread_index) % query_cases.len;
        const got = queryDigest(db, query_cases[idx]);
        if (got != shared.query_oracle[idx]) {
            _ = shared.mismatches.fetchAdd(1, .release);
        }
    }
}

/// Tier C. Collects GENERATE_UUID() output from every thread and counts
/// duplicates. `uuid_seed` (internal/function/fn_net.zig) is a shared
/// non-threadlocal global, so duplicates are expected until it moves into the
/// per-connection function.State.
fn uuidControl(gpa: std.mem.Allocator, threads: usize) !UuidResult {
    const per_thread = 5000;

    const Ctx = struct {
        gpa: std.mem.Allocator,
        failed: bool = false,

        fn run(ctx: *@This(), slot: []([]u8)) void {
            var db = driver.Db.open(ctx.gpa, ":memory:") catch {
                ctx.failed = true;
                return;
            };
            defer db.close();
            // One statement yielding `per_thread` rows: the UDF is then
            // called in a tight sqlite3_step loop, so threads actually
            // overlap inside generateUuid. Driving it one row per query
            // instead hides the race behind the ~0.5 ms analyzer round trip.
            var buf: [128]u8 = undefined;
            const sql = std.fmt.bufPrint(
                &buf,
                "SELECT GENERATE_UUID() FROM UNNEST(GENERATE_ARRAY(1, {d}))",
                .{slot.len},
            ) catch return;
            var rows = db.query(sql, &.{}, .{}) catch {
                ctx.failed = true;
                return;
            };
            defer rows.deinit();
            var i: usize = 0;
            while (rows.next() catch null) |row| : (i += 1) {
                if (i >= slot.len) break;
                slot[i] = ctx.gpa.dupe(u8, row[0].string) catch &.{};
            }
        }
    };

    const all = try gpa.alloc([]u8, threads * per_thread);
    defer {
        for (all) |s| if (s.len > 0) gpa.free(s);
        gpa.free(all);
    }
    @memset(all, &.{});

    var ctx = Ctx{ .gpa = gpa };
    const workers = try gpa.alloc(std.Thread, threads);
    defer gpa.free(workers);
    for (workers, 0..) |*w, t| {
        w.* = try std.Thread.spawn(.{}, Ctx.run, .{ &ctx, all[t * per_thread ..][0..per_thread] });
    }
    for (workers) |w| w.join();

    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    var dup: usize = 0;
    var empty: usize = 0;
    for (all) |s| {
        if (s.len == 0) {
            // Not a race signal — a slot that was never produced. Counted
            // separately so a failed query cannot masquerade as a detected
            // race.
            empty += 1;
            continue;
        }
        const gop = try seen.getOrPut(s);
        if (gop.found_existing) dup += 1;
    }
    return .{ .duplicates = dup, .empty = empty, .total = all.len };
}

const UuidResult = struct { duplicates: usize, empty: usize, total: usize };
