//! Replays the ZON spec corpus under `testdata/specs/`.
//!
//! Three trees live there, and they answer to different authorities:
//!
//!   - `googlesql/`, `bigquery/` — imported by `tools/spec_import.py` from
//!     goccy/googlesqlite, whose expected values were extracted from the
//!     **Examples** sections of the GoogleSQL reference docs. The numbers on the
//!     right-hand side are Google's own published output, scraped out of ASCII
//!     tables, so they arrive untyped and are compared leniently.
//!   - `zigquery/` — this engine's own regression suite, migrated out of
//!     `testdata/corpus.json` (go-zetasqlite's `query_test.go`). Every expected
//!     value there was machine-exported *with its type*, so those files declare
//!     `.typed = true` and get the exact, kind-checked comparison the retired
//!     `corpus_runner.zig` performed. See `src/internal/spec_expect.zig`.
//!
//! Spec files are discovered by walking the tree, sorted by path. There is no
//! index to keep in step: a `.zon` file under `testdata/specs` is a spec.
//!
//! ## Two axes, one display bucket
//!
//! `NOT_IMPLEMENTED` is detected, not declared: a case that fails with
//! `error.Unimplemented`, with the analyzer's "Function not found", or with
//! SQLite's "no such function: zetasqlite_*" is counted `not_implemented`
//! rather than `fail`. Nothing in the corpus marks it — implement `ST_AREA`
//! and its spec flips to PASS with no file edited, which is what makes the
//! suite a live ledger of what we do not have, instead of a document that
//! rots.
//!
//! `UNSUPPORTED` is declared, not detected: a case or file carrying
//! `.unsupported_in_bigquery = "..."` asserts that real BigQuery rejects the
//! construct too, so a `not_implemented`/`fail` result there is not backlog.
//! The case still runs — `spec_run.bucket()` overrides the display bucket to
//! `.unsupported` regardless of the raw `Outcome`, but a declared case that
//! genuinely passes on real rows (not an `.expect_error` match) is flagged
//! `[STALE]`: this engine now accepts something it claims BigQuery doesn't.
//!
//! ## This file vs. `src/internal/spec_run.zig`
//!
//! The actual case-running/classification logic lives in `spec_run.zig`,
//! part of the `zetasqlite` module — this file is the CLI shell around it:
//! argument parsing, the pass/fail baseline gate, `--markdown`, and the
//! `--strict` exit code. `harness/spec_ui.zig` (a browsable results UI) is
//! the other caller of `spec_run.run`, so both share one source of truth for
//! what a case's outcome means rather than drifting apart.
//!
//! Usage: zig build spec -- [--filter SUBSTR] [--case SUBSTR]
//!                          [--dialect googlesql|bigquery|zigquery]
//!                          [--verbose] [--markdown] [--update-baseline]
//!                          [--strict]
//!
//! `--filter` selects spec files by path, `--case` selects cases within them
//! by description. Together they narrow the run to a single query, which is
//! what makes `zig-out/bin/spec-runner` usable as a debug target: point a
//! breakpoint at the transformer and step through one case instead of 1760.
//! See `.run/Debug spec case.run.xml`.
//!
//! `DUMP_SQL=<path>` additionally writes the SQL snapshot (see below).

const std = @import("std");
const builtin = @import("builtin");
const zetasqlite = @import("zetasqlite");
const spec_run = zetasqlite.spec_run;

const Dialect = spec_run.Dialect;
const Manifest = spec_run.Manifest;
const Outcome = spec_run.Outcome;
const Record = spec_run.Record;

const baseline_path = "testdata/spec_baseline.txt";
const specs_root = "testdata/specs";

const Options = struct {
    /// Substring of a spec file's path.
    filter: ?[]const u8 = null,
    /// Substring of a case's `desc`, applied within the files `filter` kept.
    case: ?[]const u8 = null,
    dialect: ?Dialect = null,
    verbose: bool = false,
    markdown: bool = false,
    update_baseline: bool = false,
    strict: bool = false,
};

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

    const opts = try parseArgs(init.minimal.args, out);
    const manifest = try spec_run.loadManifest(arena, init.io, out);

    var baseline = try loadBaseline(gpa, init.io, arena);
    defer baseline.deinit(gpa);

    var results: std.ArrayList(Record) = .empty;
    defer results.deinit(gpa);

    // capture_detail stays false here: this CLI's cost/output must stay
    // exactly what it was before spec_ui.zig existed. See spec_run.zig's
    // module doc comment.
    try spec_run.run(gpa, arena, init.io, manifest, .{
        .dialect = opts.dialect,
        .filter = opts.filter,
    }, &results);

    try report(out, gpa, init.io, results.items, manifest, &baseline, opts);
    try out.flush();
}

fn parseArgs(argv: anytype, out: *std.Io.Writer) !Options {
    var opts: Options = .{};
    var it = std.process.Args.Iterator.init(argv);
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--filter")) {
            opts.filter = it.next();
        } else if (std.mem.eql(u8, arg, "--case")) {
            opts.case = it.next();
        } else if (std.mem.eql(u8, arg, "--dialect")) {
            const d = it.next() orelse "";
            opts.dialect = std.meta.stringToEnum(Dialect, d) orelse {
                try out.print("error: unknown dialect {s}\n", .{d});
                try out.flush();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--markdown")) {
            opts.markdown = true;
        } else if (std.mem.eql(u8, arg, "--update-baseline")) {
            opts.update_baseline = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            opts.strict = true;
        } else {
            try out.print(
                "usage: zig build spec -- [--filter SUBSTR] [--case SUBSTR] " ++
                    "[--dialect D] [--verbose] [--markdown] [--update-baseline] " ++
                    "[--strict]\n",
                .{},
            );
            try out.flush();
            std.process.exit(2);
        }
    }
    return opts;
}

// ---- baseline & reporting ----

const Baseline = std.StringHashMapUnmanaged(void);

fn loadBaseline(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) !Baseline {
    var map: Baseline = .empty;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, baseline_path, arena, .limited(1 << 22)) catch {
        return map; // absent on the first run
    };
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        // Only `\r` comes off: a `desc` may legitimately end in a space
        // ("parse timestamp with extra whitespace "), and trimming the key
        // would leave that case permanently unable to match its own baseline
        // entry — reported as newly passing on every run.
        const entry = std.mem.trimEnd(u8, line, "\r");
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try map.put(gpa, entry, {});
    }
    return map;
}

fn key(arena: std.mem.Allocator, r: Record) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\t{s}", .{ r.spec, r.desc });
}

fn report(
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    io: std.Io,
    results: []const Record,
    manifest: Manifest,
    baseline: *Baseline,
    opts: Options,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var counts = std.EnumArray(spec_run.Bucket, usize).initFill(0);
    var stale_count: usize = 0;
    for (results) |r| {
        counts.getPtr(spec_run.bucket(r)).* += 1;
        if (r.unsupported_stale) stale_count += 1;
    }

    if (opts.markdown) {
        try markdownReport(out, arena, results);
        return;
    }

    if (builtin.mode == .Debug) {
        try out.print("WARNING: Debug build.\n\n", .{});
    }
    try out.print("spec corpus ({d} files)\n", .{manifest.files.len});
    if (stale_count > 0) {
        try out.print(
            "{d} PASS / {d} FAIL / {d} NOT_IMPLEMENTED / {d} UNSUPPORTED ({d} stale) / {d} SKIP  (of {d})\n\n",
            .{
                counts.get(.pass),           counts.get(.fail),
                counts.get(.not_implemented), counts.get(.unsupported),
                stale_count,                 counts.get(.skip),
                results.len,
            },
        );
    } else {
        try out.print(
            "{d} PASS / {d} FAIL / {d} NOT_IMPLEMENTED / {d} UNSUPPORTED / {d} SKIP  (of {d})\n\n",
            .{
                counts.get(.pass),           counts.get(.fail),
                counts.get(.not_implemented), counts.get(.unsupported),
                counts.get(.skip),
                results.len,
            },
        );
    }

    if (opts.verbose) {
        for (results) |r| {
            const b = spec_run.bucket(r);
            if (b == .pass) continue;
            try out.print("  {s:<15} {s} :: {s}", .{
                @tagName(b), r.spec, r.desc,
            });
            if (r.detail.len > 0) try out.print(" :: {s}", .{r.detail});
            if (b == .unsupported) {
                if (r.unsupported_in_bigquery) |reason| try out.print(" (bigquery: {s})", .{reason});
                if (r.unsupported_stale) try out.writeAll(" [STALE]");
            }
            try out.writeAll("\n");
        }
        try out.writeAll("\n");
    }

    // Gate: anything the baseline says passed must still pass.
    var regressions: usize = 0;
    var newly: std.ArrayList([]const u8) = .empty;
    defer newly.deinit(arena);
    for (results) |r| {
        const k = try key(arena, r);
        const known = baseline.contains(k);
        if (known and r.outcome != .pass) {
            regressions += 1;
            try out.print("REGRESSION {s} :: {s} :: {s} {s}\n", .{
                r.spec, r.desc, @tagName(r.outcome), r.detail,
            });
        } else if (!known and r.outcome == .pass) {
            try newly.append(arena, k);
        }
    }

    if (opts.update_baseline) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(arena);
        try buf.appendSlice(arena, "# Cases that must keep passing. Regenerate: zig build spec -- --update-baseline\n");
        // Keyed on raw `outcome`, same as the regression gate above — a
        // declared-`unsupported_in_bigquery` case that passed via
        // `.expect_error` still belongs here, so a future regression on it
        // (BigQuery text drifting, or the analyzer stopping matching it) is
        // still caught. `counts.get(.pass)` (bucket-based) undercounts this
        // set, so track the raw-pass write count separately.
        var written: usize = 0;
        for (results) |r| {
            if (r.outcome != .pass) continue;
            try buf.print(arena, "{s}\t{s}\n", .{ r.spec, r.desc });
            written += 1;
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = baseline_path, .data = buf.items });
        try out.print("wrote {s} ({d} entries)\n", .{ baseline_path, written });
        return;
    }

    if (newly.items.len > 0) {
        try out.print(
            "\n{d} newly passing (run with --update-baseline to record):\n",
            .{newly.items.len},
        );
        for (newly.items[0..@min(newly.items.len, 15)]) |k| try out.print("  {s}\n", .{k});
        if (newly.items.len > 15) try out.print("  ... and {d} more\n", .{newly.items.len - 15});
    }

    // Two gates. The baseline one is always on: whatever passed must still
    // pass. `--strict` adds two more — a wrong answer fails the run even when
    // the case was never in the baseline (without it, a case that flips
    // `not_implemented` -> `fail` is silently green, because it never passed
    // to begin with and so cannot regress), and a stale `unsupported_in_bigquery`
    // annotation fails the run too (this engine now accepts something it
    // claims BigQuery doesn't — a drifted fact, not a wrong answer, but just
    // as actionable). `not_implemented` and `skip` stay non-fatal; they are
    // the known-missing surface, not wrong answers.
    const strict_failures = if (opts.strict) counts.get(.fail) else 0;
    const strict_stale = if (opts.strict) stale_count else 0;
    if (strict_failures > 0 and !opts.verbose) {
        try out.print("\nfailing cases:\n", .{});
        for (results) |r| {
            if (r.outcome != .fail) continue;
            try out.print("  FAIL {s} :: {s} :: {s}\n", .{ r.spec, r.desc, r.detail });
        }
    }
    if (strict_stale > 0 and !opts.verbose) {
        try out.print("\nstale unsupported_in_bigquery cases:\n", .{});
        for (results) |r| {
            if (!r.unsupported_stale) continue;
            try out.print("  STALE {s} :: {s} :: {s}\n", .{ r.spec, r.desc, r.unsupported_in_bigquery orelse "" });
        }
    }

    if (regressions > 0 or strict_failures > 0 or strict_stale > 0) {
        if (regressions > 0) try out.print("\n{d} regressions\n", .{regressions});
        if (strict_failures > 0) {
            try out.print("{d} failing cases (--strict)\n", .{strict_failures});
        }
        if (strict_stale > 0) {
            try out.print("{d} stale unsupported_in_bigquery cases (--strict)\n", .{strict_stale});
        }
        try out.flush();
        std.process.exit(1);
    }
}

/// One captured pipeline stage under the case that produced it. Indented as a
/// block and labelled on its first line only, so a multi-line AST still reads
/// as one thing and the case header above it stays findable by eye.
fn writeStage(out: *std.Io.Writer, name: []const u8, body: []const u8) !void {
    const text = std.mem.trim(u8, body, " \t\r\n");
    if (text.len == 0) return;

    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (first) {
            try out.print("    {s} | {s}\n", .{ name, line });
            first = false;
        } else {
            try out.print("            | {s}\n", .{line});
        }
    }
}

/// Per-category coverage, which is the number worth tracking: a single
/// "N% of cases pass" is dominated by the categories we have not built at all.
fn markdownReport(
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    results: []const Record,
) !void {
    const Row = struct {
        name: []const u8,
        pass: usize = 0,
        fail: usize = 0,
        not_implemented: usize = 0,
        unsupported: usize = 0,
        skip: usize = 0,
    };
    var cats: std.ArrayList(Row) = .empty;
    defer cats.deinit(arena);

    for (results) |r| {
        // "googlesql/functions/string/concat" -> "googlesql/functions/string"
        const cat = if (std.mem.lastIndexOfScalar(u8, r.spec, '/')) |i| r.spec[0..i] else r.spec;
        var found: ?*Row = null;
        for (cats.items) |*row| {
            if (std.mem.eql(u8, row.name, cat)) {
                found = row;
                break;
            }
        }
        if (found == null) {
            try cats.append(arena, .{ .name = cat });
            found = &cats.items[cats.items.len - 1];
        }
        switch (spec_run.bucket(r)) {
            .pass => found.?.pass += 1,
            .fail => found.?.fail += 1,
            .not_implemented => found.?.not_implemented += 1,
            .unsupported => found.?.unsupported += 1,
            .skip => found.?.skip += 1,
        }
    }

    try out.print(
        \\# Spec coverage
        \\
        \\Generated by `zig build spec -- --markdown` from `testdata/specs`.
        \\`googlesql/` and `bigquery/` are imported by `tools/spec_import.py`
        \\from goccy/googlesqlite, and their expected values are the GoogleSQL
        \\reference docs' own published output; `zigquery/` is this engine's own
        \\regression suite, inherited from go-zetasqlite's `query_test.go`. See
        \\the `NOTICE` beside each.
        \\
        \\`not_implemented` is detected at run time — `error.Unimplemented`, the
        \\analyzer's "Function not found", or a registered name with no UDF —
        \\not declared in the corpus. Implementing a function moves it to
        \\`pass` with no file edited. `unsupported` is declared: a case or file
        \\carrying `.unsupported_in_bigquery` asserts real BigQuery rejects the
        \\construct too, so it is not backlog.
        \\
        \\| Category | pass | fail | not_implemented | unsupported | skip |
        \\|---|---:|---:|---:|---:|---:|
        \\
    , .{});

    var tp: usize = 0;
    var tf: usize = 0;
    var tn: usize = 0;
    var tu: usize = 0;
    var ts: usize = 0;
    for (cats.items) |row| {
        try out.print("| `{s}` | {d} | {d} | {d} | {d} | {d} |\n", .{
            row.name, row.pass, row.fail, row.not_implemented, row.unsupported, row.skip,
        });
        tp += row.pass;
        tf += row.fail;
        tn += row.not_implemented;
        tu += row.unsupported;
        ts += row.skip;
    }
    try out.print("| **total** | **{d}** | **{d}** | **{d}** | **{d}** | **{d}** |\n", .{ tp, tf, tn, tu, ts });
}
