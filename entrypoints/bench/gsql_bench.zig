//! The goccy/googlesqlite benchmark corpus, run against this engine.
//!
//! Upstream (github.com/goccy/googlesqlite/tree/main/bench) is a Go
//! `testing.B` suite over 22 GoogleSQL queries in five categories, published
//! as bench/RESULTS.md. The corpus files are vendored verbatim under
//! testdata/bench_corpus so the two suites measure the same SQL; this file is
//! the runner, and it reports the same shape of table.
//!
//! ## What is timed, and why there are two numbers
//!
//! Upstream prepares each query once and re-runs it (`prep: true`), scanning
//! every row per iteration. Neither of this driver's entry points is exactly
//! that, so the run reports both and the comparable figure sits between them:
//!
//!   full  Db.query() per iteration, rows decoded — analyze + transform +
//!         sqlite3_prepare + step + decode. Strictly MORE work than upstream's
//!         number, and the path the emulator actually takes per request.
//!   prep  Db.prepare() once, PreparedStmt.exec() per iteration. Skips analysis
//!         and transform, but exec discards rows, so it also skips the decode
//!         upstream pays. Strictly LESS work than upstream's number.
//!
//! So `prep <= upstream <= full` for the same query, and the gap between the
//! two columns is what statement caching is worth. `--phases` splits `full`
//! into the phase counters (src/internal/phase.zig) to show where it went.
//!
//! ## Allocation columns
//!
//! `allocs/op` and `B/op` count calls into and bytes requested from the
//! allocator handed to the driver. They are NOT upstream's Go numbers: this
//! driver serves a query from an arena, so one op is a handful of large chunk
//! requests where Go's allocator sees every object. Compare them against a
//! previous run of THIS harness, not against RESULTS.md.
//!
//! Usage: zig build gsql-bench -- [--time MS] [--iters N] [--filter SUBSTR]
//!                                [--phases] [--markdown] [--json] [--corpus DIR]

const std = @import("std");
const builtin = @import("builtin");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const phase = zetasqlite.phase;

const default_corpus_root = "testdata/bench_corpus";

/// The corpus, in upstream's report order: window first because it is the
/// heaviest, then alphabetical within each category (render_results.go's
/// `preferred`). Listed rather than walked so a missing file is a hard error
/// instead of a silently shorter run.
const corpus = [_][]const u8{
    "window/array_agg_window",
    "window/lag_lead",
    "window/rank_dense_rank",
    "window/row_number_partition",
    "window/sum_running_total",
    "aggregate/group_by_partition",
    "aggregate/sum_1k",
    "scalar/concat_strings",
    "scalar/select_constant",
    "scalar/upper_string",
    "mixed/cte_session_funnel",
    "mixed/filtered_lookup",
    "mixed/information_schema_columns",
    "mixed/json_extract_pipeline",
    "mixed/priced_orders_report",
    "mixed/struct_array_unnest",
    "mixed/wildcard_table_scan",
    "tpch_like/q1_lineitem_pricing_summary",
    "tpch_like/q14_promo_revenue",
    "tpch_like/q3_shipping_priority",
    "tpch_like/q5_local_supplier",
    "tpch_like/q6_forecast_revenue",
};

/// Separator between a corpus file's setup block and its timed query. Upstream
/// splits on exactly this.
const query_marker = "\n-- @query\n";

const Options = struct {
    /// Wall-clock budget per query per mode. Iterations run until it is spent.
    budget_ms: u64 = 1000,
    /// Fixed iteration count, overriding the budget.
    iters: ?u64 = null,
    /// Never spin past this many iterations, however cheap the query.
    max_iters: u64 = 200_000,
    filter: ?[]const u8 = null,
    phases: bool = false,
    markdown: bool = false,
    json: bool = false,
    corpus_root: []const u8 = default_corpus_root,
};

/// Every allocation the driver makes, so a query's churn is visible per op.
/// The driver serves a query from an arena, so these are chunk requests.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocs: u64 = 0,
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
        self.backing.rawFree(mem, a, ra);
    }
};

const Result = struct {
    category: []const u8,
    name: []const u8,
    /// Set when setup or the query itself would not run at all; the other
    /// fields are then meaningless. Held rather than printed inline so an
    /// unsupported query does not interrupt the table.
    failure: ?[]const u8 = null,
    /// Set when the query runs but cannot be prepared for reuse.
    prep_failure: ?[]const u8 = null,

    full_ns: u64 = 0,
    full_iters: u64 = 0,
    prep_ns: u64 = 0,
    prep_iters: u64 = 0,
    rows: usize = 0,
    allocs: u64 = 0,
    bytes: u64 = 0,

    analyze_ns: u64 = 0,
    transform_ns: u64 = 0,
    sqlite_prepare_ns: u64 = 0,
    step_ns: u64 = 0,

    fn fullNsPerOp(r: Result) f64 {
        return perOp(r.full_ns, r.full_iters);
    }

    fn prepNsPerOp(r: Result) f64 {
        return perOp(r.prep_ns, r.prep_iters);
    }
};

fn perOp(ns: u64, iters: u64) f64 {
    if (iters == 0) return 0;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters));
}

fn ms(ns: f64) f64 {
    return ns / 1e6;
}

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (builtin.mode == .Debug) gpa_state.allocator() else std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opts = parseArgs(init.minimal.args, out) catch |err| switch (err) {
        error.Usage => {
            try out.flush();
            std.process.exit(2);
        },
        else => return err,
    };

    // Upstream warms the wasm runtime before the corpus so its one-time cost
    // lands on the warm-up rather than on whichever query ran first. The
    // analyzer shim has the same shape of lazy init, so pay it the same way and
    // report it the same way.
    const init_ns = try warmAnalyzer(gpa);

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(gpa);

    for (corpus) |rel| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, rel, f) == null) continue;
        }
        try results.append(gpa, try runCase(gpa, arena, init.io, rel, opts));
    }

    if (opts.json) {
        try renderJson(out, results.items, init_ns);
    } else if (opts.markdown) {
        try renderMarkdown(out, results.items, init_ns, opts);
    } else {
        try renderTable(out, results.items, init_ns, opts);
    }
    try out.flush();
}

fn parseArgs(argv: anytype, out: *std.Io.Writer) !Options {
    var opts: Options = .{};
    var it = std.process.Args.Iterator.init(argv);
    _ = it.next(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--time")) {
            opts.budget_ms = try std.fmt.parseInt(u64, it.next() orelse return usage(out), 10);
        } else if (std.mem.eql(u8, arg, "--iters")) {
            opts.iters = try std.fmt.parseInt(u64, it.next() orelse return usage(out), 10);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            opts.filter = it.next() orelse return usage(out);
        } else if (std.mem.eql(u8, arg, "--corpus")) {
            opts.corpus_root = it.next() orelse return usage(out);
        } else if (std.mem.eql(u8, arg, "--phases")) {
            opts.phases = true;
        } else if (std.mem.eql(u8, arg, "--markdown")) {
            opts.markdown = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else {
            try out.print("error: unknown argument {s}\n", .{arg});
            return usage(out);
        }
    }
    return opts;
}

fn usage(out: *std.Io.Writer) error{Usage} {
    out.print(
        "usage: zig build gsql-bench -- [--time MS] [--iters N] [--filter SUBSTR]\n" ++
            "                              [--phases] [--markdown] [--json] [--corpus DIR]\n",
        .{},
    ) catch {};
    return error.Usage;
}

/// Opens a connection and runs one trivial query, returning what that cost.
/// The first statement in a process pays the shim's lazy initialisation.
fn warmAnalyzer(gpa: std.mem.Allocator) !u64 {
    const t0 = phase.nowNs();
    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();
    var rows = try db.query("SELECT 1", &.{}, .{});
    defer rows.deinit();
    while (try rows.next()) |_| {}
    return phase.nowNs() -| t0;
}

/// One corpus file: setup on a fresh in-memory database, then the query timed
/// both ways. `arena` holds strings that must outlive the connection.
fn runCase(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    rel: []const u8,
    opts: Options,
) !Result {
    const slash = std.mem.indexOfScalar(u8, rel, '/').?;
    var result: Result = .{
        .category = rel[0..slash],
        .name = rel[slash + 1 ..],
    };

    const path = try std.fmt.allocPrint(arena, "{s}/{s}.sql", .{ opts.corpus_root, rel });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 22)) catch |err| {
        result.failure = try std.fmt.allocPrint(arena, "cannot read {s}: {s}", .{ path, @errorName(err) });
        return result;
    };

    var setup: []const u8 = "";
    var query: []const u8 = undefined;
    if (std.mem.indexOf(u8, text, query_marker)) |i| {
        setup = std.mem.trim(u8, text[0..i], " \t\r\n");
        query = std.mem.trim(u8, text[i + query_marker.len ..], " \t\r\n");
    } else {
        query = std.mem.trim(u8, text, " \t\r\n");
    }

    var counting: CountingAllocator = .{ .backing = gpa };
    var db = try driver.Db.open(counting.allocator(), ":memory:");
    defer db.close();

    if (setup.len > 0) {
        db.exec(setup, &.{}, .{}) catch |err| {
            result.failure = try std.fmt.allocPrint(
                arena,
                "setup: {s}: {s}",
                .{ @errorName(err), db.lastError() },
            );
            return result;
        };
    }

    // Untimed: establishes the row count and leaves any per-statement caches in
    // the state the timed iterations will see.
    result.rows = drainQuery(db, query) catch |err| {
        result.failure = try std.fmt.allocPrint(
            arena,
            "{s}: {s}",
            .{ @errorName(err), db.lastError() },
        );
        return result;
    };

    // --- full: analyze + transform + prepare + step + decode, per iteration.
    counting.reset();
    phase.reset();
    const full_start = phase.nowNs();
    var iters: u64 = 0;
    while (!done(iters, full_start, opts)) : (iters += 1) {
        _ = try drainQuery(db, query);
    }
    result.full_ns = phase.nowNs() -| full_start;
    result.full_iters = iters;
    result.allocs = counting.allocs / @max(iters, 1);
    result.bytes = counting.bytes / @max(iters, 1);
    result.analyze_ns = phase.totalNs(.analyze);
    result.transform_ns = phase.totalNs(.transform);
    result.sqlite_prepare_ns = phase.totalNs(.sqlite_prepare);
    result.step_ns = phase.totalNs(.sqlite_step);

    // --- prep: bind + step only, the statement compiled once up front.
    var stmt = db.prepare(query, .{}) catch |err| {
        result.prep_failure = try std.fmt.allocPrint(
            arena,
            "{s}: {s}",
            .{ @errorName(err), db.lastError() },
        );
        return result;
    };
    defer stmt.deinit();
    try stmt.exec(&.{}); // warm, untimed
    const prep_start = phase.nowNs();
    iters = 0;
    while (!done(iters, prep_start, opts)) : (iters += 1) {
        try stmt.exec(&.{});
    }
    result.prep_ns = phase.nowNs() -| prep_start;
    result.prep_iters = iters;

    return result;
}

/// Whether the timed loop has run enough: a fixed count when `--iters` was
/// given, otherwise at least one iteration and then until the budget is spent.
fn done(iters: u64, start_ns: u64, opts: Options) bool {
    if (opts.iters) |n| return iters >= n;
    if (iters == 0) return false;
    if (iters >= opts.max_iters) return true;
    return (phase.nowNs() -| start_ns) >= opts.budget_ms * std.time.ns_per_ms;
}

fn drainQuery(db: *driver.Db, query: []const u8) !usize {
    var rows = try db.query(query, &.{}, .{});
    defer rows.deinit();
    var n: usize = 0;
    while (try rows.next()) |_| n += 1;
    return n;
}

// ---- reporting ----

fn renderTable(out: *std.Io.Writer, results: []const Result, init_ns: u64, opts: Options) !void {
    if (builtin.mode == .Debug) {
        try out.print("WARNING: Debug build; numbers are not comparable to release.\n\n", .{});
    }
    try out.print(
        "goccy/googlesqlite bench corpus on zetasqlite-zig ({s})\n" ++
            "analyzer init: {d:.2}ms (paid once, before the corpus; not in the numbers below)\n\n",
        .{ @tagName(builtin.mode), ms(@floatFromInt(init_ns)) },
    );

    try out.print(
        "{s:<38} {s:>11} {s:>11} {s:>8} {s:>10} {s:>12}\n",
        .{ "query", "full ms/op", "prep ms/op", "rows", "allocs/op", "B/op" },
    );
    try out.print("{s}\n", .{"-" ** 94});

    var current: []const u8 = "";
    var unsupported: usize = 0;
    for (results) |r| {
        if (!std.mem.eql(u8, current, r.category)) {
            current = r.category;
            try out.print("{s}/\n", .{r.category});
        }
        if (r.failure) |why| {
            unsupported += 1;
            try out.print("  {s:<36} {s:>11}  {s}\n", .{ r.name, "-", why });
            continue;
        }
        try out.print(
            "  {s:<36} {d:>11.4} {d:>11.4} {d:>8} {d:>10} {d:>12}\n",
            .{
                r.name,
                ms(r.fullNsPerOp()),
                ms(r.prepNsPerOp()),
                r.rows,
                r.allocs,
                r.bytes,
            },
        );
        if (r.prep_failure) |why| {
            try out.print("  {s:<36} prepare unavailable: {s}\n", .{ "", why });
        }
        if (opts.phases) try printPhases(out, r);
    }

    try out.print(
        "\nprep <= (upstream's prepared+scan number) <= full: prep skips analysis and\n" ++
            "transform but discards rows, full pays both and decodes every row.\n" ++
            "allocs/op and B/op are this driver's arena traffic, not Go object counts.\n",
        .{},
    );
    if (unsupported > 0) {
        try out.print(
            "{d} of {d} queries did not run; they need catalog features the engine does not\n" ++
                "provide on its own (see the message beside each).\n",
            .{ unsupported, results.len },
        );
    }
}

/// Where a `full` iteration went. The phases do not sum to the total: decoding
/// rows and the driver's own bookkeeping are outside all of them.
fn printPhases(out: *std.Io.Writer, r: Result) !void {
    const n = @max(r.full_iters, 1);
    const per = struct {
        fn of(ns: u64, iters: u64) f64 {
            return ms(@as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)));
        }
    }.of;
    const total = ms(r.fullNsPerOp());
    const other = @max(0, total - per(r.analyze_ns, n) - per(r.transform_ns, n) -
        per(r.sqlite_prepare_ns, n) - per(r.step_ns, n));
    try out.print(
        "  {s:<36} analyze {d:.4}  transform {d:.4}  sqlite-prepare {d:.4}  " ++
            "step {d:.4}  other {d:.4}\n",
        .{
            "",
            per(r.analyze_ns, n),
            per(r.transform_ns, n),
            per(r.sqlite_prepare_ns, n),
            per(r.step_ns, n),
            other,
        },
    );
}

/// Upstream's RESULTS.md shape, so the two files can be read side by side.
/// github-action-benchmark's `customSmallerIsBetter` shape: a flat array of
/// `{name, unit, value}`. That tool treats every entry as lower-is-better and
/// alerts when one grows past its threshold, so `rows` is deliberately absent
/// — it describes the workload, not its cost, and a change in it is a corpus
/// edit rather than a regression.
///
/// Both timing modes are emitted because they bracket the truth from opposite
/// sides (see the header): a `full` regression with `prep` flat points at
/// analyze/transform, the reverse points at sqlite or the decoder.
///
/// Nothing else may go to stdout in this mode — the workflow pipes it straight
/// into a file that the action parses.
fn renderJson(out: *std.Io.Writer, results: []const Result, init_ns: u64) !void {
    var first = true;
    try out.writeAll("[\n");

    try emitJson(out, &first, "", "", "analyzer init", "ms", @as(f64, @floatFromInt(init_ns)) / 1e6);

    for (results) |r| {
        // A query that would not run has no numbers to compare; emitting a
        // zero would read as an enormous improvement.
        if (r.failure != null) continue;

        try emitJson(out, &first, r.category, r.name, " full", "ns/op", r.fullNsPerOp());
        if (r.prep_failure == null) {
            try emitJson(out, &first, r.category, r.name, " prep", "ns/op", r.prepNsPerOp());
        }
        try emitJson(out, &first, r.category, r.name, " B/op", "B", @floatFromInt(r.bytes));
        try emitJson(out, &first, r.category, r.name, " allocs/op", "allocs", @floatFromInt(r.allocs));
    }

    try out.writeAll("\n]\n");
}

fn emitJson(
    out: *std.Io.Writer,
    first: *bool,
    category: []const u8,
    name: []const u8,
    suffix: []const u8,
    unit: []const u8,
    value: f64,
) !void {
    if (!first.*) try out.writeAll(",\n");
    first.* = false;
    // Names come from the hardcoded `corpus` list above, so they are known
    // ASCII path fragments with nothing to escape. The lone entry with neither
    // category nor name (analyzer init) renders without the separator.
    const sep: []const u8 = if (category.len > 0) "/" else "";
    try out.print(
        "  {{\"name\": \"{s}{s}{s}{s}\", \"unit\": \"{s}\", \"value\": {d:.3}}}",
        .{ category, sep, name, suffix, unit, value },
    );
}

fn renderMarkdown(out: *std.Io.Writer, results: []const Result, init_ns: u64, opts: Options) !void {
    try out.print(
        \\# Benchmark — zetasqlite-zig on the googlesqlite corpus
        \\
        \\Auto-generated by `zig build gsql-bench -- --markdown`. The corpus is
        \\vendored verbatim from github.com/goccy/googlesqlite/tree/main/bench,
        \\so the SQL matches that project's `bench/RESULTS.md`.
        \\
        \\`full` runs the whole pipeline per iteration (analyze, transform,
        \\sqlite prepare, step, decode). `prep` compiles once and re-executes,
        \\discarding rows. Upstream's single prepared-and-scanned number sits
        \\between the two. `allocs/op` and `B/op` are requests reaching the
        \\driver's backing allocator — arena chunks, not Go object counts, and
        \\comparable only against another run of this harness.
        \\
        \\
    , .{});
    try out.print(
        "## Runtime initialisation\n\n" ++
            "One-time analyzer/shim initialisation, measured as open + first query:\n" ++
            "**{d} ns** ({d:.2} s).\n\n" ++
            "Paid once per process, before the corpus runs, so it is NOT included\n" ++
            "in the per-query numbers below.\n\n",
        .{ init_ns, @as(f64, @floatFromInt(init_ns)) / 1e9 },
    );

    var current: []const u8 = "";
    var unsupported: usize = 0;
    for (results, 0..) |r, i| {
        if (!std.mem.eql(u8, current, r.category)) {
            if (i > 0) try out.writeAll("\n");
            current = r.category;
            // Upstream titles headings with Go's strings.Title, which here just
            // uppercases the first letter ("tpch_like" -> "Tpch_like").
            try out.print("## {c}{s}\n\n", .{ std.ascii.toUpper(r.category[0]), r.category[1..] });
            try out.writeAll("| Query | full ns/op | prep ns/op | rows | B/op | allocs/op |\n");
            try out.writeAll("|-------|-----------|-----------|------|------|-----------|\n");
        }
        if (r.failure != null) {
            unsupported += 1;
            try out.print("| {s} | — | — | — | — | — |\n", .{r.name});
            continue;
        }
        try out.print(
            "| {s} | {d:.0} | {d:.0} | {d} | {d} | {d} |\n",
            .{ r.name, r.fullNsPerOp(), r.prepNsPerOp(), r.rows, r.bytes, r.allocs },
        );
    }
    try out.writeAll("\n");

    if (unsupported > 0) {
        try out.writeAll("## Not run\n\n");
        for (results) |r| {
            if (r.failure) |why| {
                try out.print("- `{s}/{s}` — {s}\n", .{ r.category, r.name, why });
            }
        }
        try out.writeAll("\n");
    }

    if (opts.phases) try markdownPhases(out, results);
}

/// The `full` column split by phase, from the same run as the tables above.
fn markdownPhases(out: *std.Io.Writer, results: []const Result) !void {
    try out.writeAll(
        \\## Where `full` goes
        \\
        \\Milliseconds per op, from the counters in `src/internal/phase.zig`.
        \\They do not sum to `full`: decoding rows and the driver's own
        \\bookkeeping sit outside every phase, in `other`.
        \\
        \\| Query | analyze | transform | sqlite-prepare | step | other | full |
        \\|-------|--------:|----------:|---------------:|-----:|------:|-----:|
        \\
    );
    for (results) |r| {
        if (r.failure != null) continue;
        const n = @max(r.full_iters, 1);
        const p = struct {
            fn of(ns: u64, iters: u64) f64 {
                return ms(@as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)));
            }
        }.of;
        const total = ms(r.fullNsPerOp());
        const other = @max(0, total - p(r.analyze_ns, n) - p(r.transform_ns, n) -
            p(r.sqlite_prepare_ns, n) - p(r.step_ns, n));
        try out.print(
            "| {s}/{s} | {d:.4} | {d:.4} | {d:.4} | {d:.4} | {d:.4} | {d:.4} |\n",
            .{
                r.category,
                r.name,
                p(r.analyze_ns, n),
                p(r.transform_ns, n),
                p(r.sqlite_prepare_ns, n),
                p(r.step_ns, n),
                other,
                total,
            },
        );
    }
    try out.writeAll("\n");
}
