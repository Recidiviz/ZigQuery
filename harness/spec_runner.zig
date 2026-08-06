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
//! ## The `unsupported` bucket is detected, not declared
//!
//! A case that fails with `error.Unimplemented`, with the analyzer's
//! "Function not found", or with SQLite's "no such function: zetasqlite_*"
//! is counted as `unsupported` rather than failed. Nothing in the corpus marks
//! it. Implement `ST_AREA` and its spec flips to PASS with no file edited —
//! which is what makes the suite a live ledger of what we do not have, instead
//! of a document that rots.
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
const driver = zetasqlite.driver;
const spec_expect = zetasqlite.spec_expect;
const analyzer_ffi = zetasqlite.analyzer_ffi;
const ast_dump = zetasqlite.ast_dump;

const Zoir = std.zig.Zoir;

const specs_root = "testdata/specs";
const baseline_path = "testdata/spec_baseline.txt";

/// The clock every case sees, so CURRENT_* is reproducible. Same instant the
/// JSON corpus pinned (2006-01-02 15:04:05 UTC, Go's reference time).
const fixed_now_unix_micros: i64 = 1136239445000000;

const Dialect = enum { googlesql, bigquery, zigquery };

const Outcome = enum { pass, fail, unsupported, skip };

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

const Result = struct {
    spec: []const u8,
    desc: []const u8,
    outcome: Outcome,
    detail: []const u8 = "",
    /// The three pipeline stages, captured under `--verbose` for cases that
    /// did not pass. Empty otherwise, and empty for a stage the case never
    /// reached — a query rejected by the analyzer has no SQL out.
    in_sql: []const u8 = "",
    out_ast: []const u8 = "",
    out_sql: []const u8 = "",
};

// ----------------------------------------------------------------------
// Pipeline trace (--verbose)
// ----------------------------------------------------------------------
//
// `detail` says what went wrong; it does not say where. A case that returns
// the wrong value could have been mis-analyzed, mis-transformed, or answered
// wrongly by a UDF, and the three are told apart by reading the stages: the
// GoogleSQL in, the resolved AST the analyzer returned, the SQLite SQL the
// transformer emitted.
//
// Both sinks are process-global with no context argument, so the buffers they
// append to are file-global. Sound because this runner is single-threaded and
// runs one case at a time.
//
// Capture is scoped to the query itself — `traceBegin` immediately before it,
// `traceEnd` after — so a case's `setup` DDL does not bury the statement under
// test in its own SQL.
//
// ----------------------------------------------------------------------
// SQL snapshot (DUMP_SQL=<path>)
// ----------------------------------------------------------------------
//
// Every engine statement handed to sqlite3_prepare_v2, grouped by case, so a
// change to the SQL builder is reviewed as a diff instead of as a delta in one
// aggregate byte count. Analyse a snapshot (or two) with tools/sql_stats.py.
//
// It shares `sqlSink` with the verbose trace rather than fighting it over the
// one global hook: each destination is gated on its own allocator being set.
// The snapshot's is set for the whole run, so unlike the trace it does include
// a case's `setup` DDL — that SQL comes out of the same builder and is worth
// diffing.

var trace_ast: std.ArrayList(u8) = .empty;
var trace_sql: std.ArrayList(u8) = .empty;
var trace_alloc: ?std.mem.Allocator = null;

var snapshot_buf: std.ArrayList(u8) = .empty;
var snapshot: std.ArrayList(u8) = .empty;
var snapshot_alloc: ?std.mem.Allocator = null;

fn astSink(node: *const zetasqlite.pb.AnyResolvedNodeProto) void {
    const alloc = trace_alloc orelse return;
    var w = std.Io.Writer.Allocating.fromArrayList(alloc, &trace_ast);
    defer trace_ast = w.toArrayList();
    // A spec case may be a script — a CREATE then the SELECT under test. Two
    // trees run together read as one, so the boundary gets a rule.
    if (w.written().len > 0) w.writer.writeAll("--\n") catch return;
    ast_dump.dump(&w.writer, node, .{}) catch {};
}

fn sqlSink(sql: []const u8) void {
    if (trace_alloc) |alloc| {
        trace_sql.appendSlice(alloc, sql) catch {};
        trace_sql.appendSlice(alloc, ";\n") catch {};
    }
    if (snapshot_alloc) |alloc| {
        snapshot_buf.appendSlice(alloc, sql) catch {};
        snapshot_buf.appendSlice(alloc, ";\n") catch {};
    }
}

fn traceBegin(arena: std.mem.Allocator) void {
    trace_alloc = arena;
    traceClear();
    analyzer_ffi.setAstSink(astSink);
}

fn traceClear() void {
    trace_ast.clearRetainingCapacity();
    trace_sql.clearRetainingCapacity();
}

fn traceEnd() void {
    trace_alloc = null;
    analyzer_ffi.setAstSink(null);
}

/// Closes out one case's snapshot block. Every case gets a header even when it
/// emitted nothing (a SKIP, or a failure before prepare), so a case that stops
/// emitting SQL shows up as a diff rather than as a silent shift of everything
/// below it.
fn snapshotCase(spec_name: []const u8, desc: []const u8) !void {
    const alloc = snapshot_alloc orelse return;
    try snapshot.print(alloc, "### {s}\t{s}\n", .{ spec_name, desc });
    try snapshot.appendSlice(alloc, snapshot_buf.items);
    try snapshot.append(alloc, '\n');
    snapshot_buf.clearRetainingCapacity();
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

    const opts = try parseArgs(init.minimal.args, out);

    const paths = try findSpecs(arena, init.io);
    if (paths.len == 0) {
        try out.print("no .zon specs under {s}\n", .{specs_root});
        try out.flush();
        std.process.exit(1);
    }

    // Installed for the whole run, not per case: the sink is what both the
    // snapshot and the verbose trace read from, and reinstalling it around each
    // query would drop the setup DDL the snapshot wants.
    const snapshot_path = init.environ_map.get("DUMP_SQL");
    if (snapshot_path != null) snapshot_alloc = arena;
    if (snapshot_path != null or opts.verbose) {
        zetasqlite.phase.setPreparedSqlSink(sqlSink);
    }
    defer zetasqlite.phase.setPreparedSqlSink(null);

    var baseline = try loadBaseline(gpa, init.io, arena);
    defer baseline.deinit(gpa);

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(gpa);

    var files_run: usize = 0;
    for (paths) |path| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, path, f) == null) continue;
        }
        // The dialect lives in the file, so unlike `--filter` this one can only
        // be applied once the file is parsed; `runSpecFile` reports whether it
        // kept it.
        if (try runSpecFile(gpa, arena, init.io, path, &results, opts)) files_run += 1;
    }

    if (snapshot_path) |path| {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = snapshot.items });
        try out.print("wrote SQL snapshot: {s} ({d} bytes)\n", .{ path, snapshot.items.len });
    }

    try report(out, gpa, init.io, results.items, files_run, &baseline, opts);
    try out.flush();
}

/// Every `.zon` under `specs_root`, relative to it, sorted. Sorted because the
/// run order decides what a file's shared connection sees and what the report
/// and the snapshot look like — none of which may depend on readdir order.
fn findSpecs(arena: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, specs_root, .{ .iterate = true });
    defer dir.close(io);

    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.path, ".zon")) continue;
        try paths.append(arena, try arena.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return paths.items;
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

// ---- Zoir helpers ----

/// The value of struct field `name`, or null. ZON struct field order is source
/// order, so a linear scan is both correct and cheap at these sizes.
fn field(zoir: Zoir, node: Zoir.Node.Index, name: []const u8) ?Zoir.Node.Index {
    const n = node.get(zoir);
    if (n != .struct_literal) return null;
    for (n.struct_literal.names, 0..) |field_name, i| {
        if (std.mem.eql(u8, field_name.get(zoir), name)) {
            return n.struct_literal.vals.at(@intCast(i));
        }
    }
    return null;
}

fn stringField(zoir: Zoir, node: Zoir.Node.Index, name: []const u8) ?[]const u8 {
    const f = field(zoir, node, name) orelse return null;
    const n = f.get(zoir);
    return if (n == .string_literal) n.string_literal else null;
}

fn boolField(zoir: Zoir, node: Zoir.Node.Index, name: []const u8) bool {
    const f = field(zoir, node, name) orelse return false;
    return f.get(zoir) == .true;
}

/// The tag of an enum-literal field (`.dialect = .bigquery` -> "bigquery").
fn enumField(zoir: Zoir, node: Zoir.Node.Index, name: []const u8) ?[]const u8 {
    const f = field(zoir, node, name) orelse return null;
    const n = f.get(zoir);
    return if (n == .enum_literal) n.enum_literal.get(zoir) else null;
}

/// Elements of an array literal; `.{}` reads as empty rather than absent.
fn elements(zoir: Zoir, node: Zoir.Node.Index) Zoir.Node.Index.Range {
    return switch (node.get(zoir)) {
        .array_literal => |r| r,
        else => .{ .start = @enumFromInt(0), .len = 0 },
    };
}

/// A ZON value as a bind parameter. Containers are included: `zigquery` binds a
/// STRUCT (`types/struct`, "struct field integration"), and a dropped argument
/// would silently shift every positional one after it.
///
/// `type_text` is the case's declared GoogleSQL type for this argument, when it
/// has one. It settles the single thing ZON cannot say: `.{}` is both the empty
/// array literal and the empty struct literal, and Zig itself only tells them
/// apart by the destination type. So does this.
fn cellFromNode(
    arena: std.mem.Allocator,
    zoir: Zoir,
    node: Zoir.Node.Index,
    type_text: ?[]const u8,
) !?driver.Cell {
    return switch (node.get(zoir)) {
        .null => .null,
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .int_literal => |i| switch (i) {
            .small => |v| .{ .int = v },
            .big => |v| .{ .int = v.toInt(i64) catch return null },
        },
        .float_literal => |f| .{ .float = @floatCast(f) },
        .string_literal => |s| .{ .string = s },
        // Empty array unless the declared type says otherwise; `.{}` in value
        // position reads as an empty array everywhere else too (spec_expect).
        .empty_literal => if (type_text != null and
            std.ascii.startsWithIgnoreCase(type_text.?, "STRUCT"))
            .{ .struct_ = &.{} }
        else
            .{ .array = &.{} },
        .array_literal => |range| {
            const cells = try arena.alloc(driver.Cell, range.len);
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                cells[i] = try cellFromNode(arena, zoir, range.at(i), null) orelse return null;
            }
            return .{ .array = cells };
        },
        .struct_literal => |lit| {
            const fields = try arena.alloc(driver.Cell.Field, lit.names.len);
            for (lit.names, 0..) |name, i| {
                const v = try cellFromNode(arena, zoir, lit.vals.at(@intCast(i)), null);
                fields[i] = .{ .name = name.get(zoir), .value = v orelse return null };
            }
            return .{ .struct_ = fields };
        },
        else => null,
    };
}

/// The `.arg_types` entry at `i` — the GoogleSQL type text a case declares for
/// its `i`th positional argument, as `queryParameters.parameterType` would.
fn argType(zoir: Zoir, c: Zoir.Node.Index, i: u32) ?[]const u8 {
    const f = field(zoir, c, "arg_types") orelse return null;
    const r = elements(zoir, f);
    if (i >= r.len) return null;
    const n = r.at(i).get(zoir);
    return if (n == .string_literal) n.string_literal else null;
}

// ---- execution ----

/// Runs one spec file. Returns false when `--dialect` excluded it, which is
/// only knowable after the parse — the dialect is a field in the file.
fn runSpecFile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    rel_path: []const u8,
    results: *std.ArrayList(Result),
    opts: Options,
) !bool {
    const path = try std.fs.path.join(arena, &.{ specs_root, rel_path });
    const src = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(1 << 22),
        .of(u8),
        0,
    ) catch |err| {
        // The walk just told us this file exists, so failing to read it is a
        // hard error rather than a silently shorter run.
        try results.append(gpa, .{
            .spec = rel_path,
            .desc = "(load)",
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "cannot read: {s}", .{@errorName(err)}),
        });
        return true;
    };

    var ast = try std.zig.Ast.parse(gpa, src, .zon);
    defer ast.deinit(gpa);
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);
    if (zoir.compile_errors.len > 0) {
        try results.append(gpa, .{
            .spec = rel_path,
            .desc = "(parse)",
            .outcome = .fail,
            .detail = "malformed ZON",
        });
        return true;
    }

    // A file with no `.dialect`, or one naming a dialect this build does not
    // know, is a malformed spec rather than a file to quietly run anyway.
    const dialect = std.meta.stringToEnum(
        Dialect,
        enumField(zoir, .root, "dialect") orelse "",
    ) orelse {
        try results.append(gpa, .{
            .spec = rel_path,
            .desc = "(parse)",
            .outcome = .fail,
            .detail = "missing or unknown .dialect",
        });
        return true;
    };
    if (opts.dialect) |d| {
        if (d != dialect) return false;
    }

    // `.typed` is how a file says its expectations carry their own types, which
    // is true of `zigquery/` and of nothing else. See src/internal/spec_expect.zig.
    const expect: spec_expect.Options =
        if (boolField(zoir, .root, "typed")) spec_expect.typed_options else .{};

    // Duped: string literals point into `zoir.string_bytes`, which dies with
    // the `defer zoir.deinit` above, while `results` outlives this function.
    const spec_name = try arena.dupe(u8, stringField(zoir, .root, "spec") orelse rel_path);
    const cases = field(zoir, .root, "cases") orelse return true;

    // A file-level `.skip` applies to every case in it. That is a different
    // claim from the per-case one below: it says the whole spec does not
    // describe this engine's surface — a GoogleSQL feature BigQuery does not
    // expose — rather than that some case is unimplemented. Without it such a
    // file reports as UNSUPPORTED, which reads as a to-do list.
    const spec_skip: ?[]const u8 = if (stringField(zoir, .root, "skip")) |r|
        try arena.dupe(u8, r)
    else
        null;

    // One connection for the whole file, opened lazily and reused by every
    // setup-free case; the ~9% that carry `setup` get their own. So a file is
    // the unit of shared state: DDL in one case is visible to the next case in
    // the same file, and to nothing beyond it. `zigquery/` depends on that —
    // it inherited a suite that shared one database across all 748 cases.
    var shared: ?*driver.Db = null;
    defer if (shared) |db| db.close();

    const range = elements(zoir, cases);
    var i: u32 = 0;
    while (i < range.len) : (i += 1) {
        const c = range.at(i);
        const desc = try arena.dupe(u8, stringField(zoir, c, "desc") orelse "(no desc)");
        const sql = stringField(zoir, c, "sql") orelse continue;

        // Dropped before it reaches `results`, so the totals describe the run
        // you asked for rather than a filtered view of a larger one.
        if (opts.case) |want| {
            if (std.mem.indexOf(u8, desc, want) == null) continue;
        }

        if (stringField(zoir, c, "skip") orelse spec_skip) |reason| {
            try results.append(gpa, .{
                .spec = spec_name,
                .desc = desc,
                .outcome = .skip,
                .detail = try arena.dupe(u8, reason),
                // Nothing ran, so there is no AST or emitted SQL — but the
                // input is still worth showing beside the reason.
                .in_sql = if (opts.verbose) try arena.dupe(u8, sql) else "",
            });
            try snapshotCase(spec_name, desc);
            continue;
        }

        const setup = field(zoir, c, "setup");
        var owned: ?*driver.Db = null;
        defer if (owned) |db| db.close();

        const db = blk: {
            if (setup != null) {
                owned = try driver.Db.open(gpa, ":memory:");
                break :blk owned.?;
            }
            if (shared == null) shared = try driver.Db.open(gpa, ":memory:");
            break :blk shared.?;
        };

        const res = runCase(gpa, arena, zoir, c, db, sql, setup, opts.verbose, expect) catch |err| {
            try results.append(gpa, .{
                .spec = spec_name,
                .desc = desc,
                .outcome = .fail,
                .detail = try std.fmt.allocPrint(arena, "harness: {s}", .{@errorName(err)}),
                .in_sql = if (opts.verbose) try arena.dupe(u8, sql) else "",
            });
            try snapshotCase(spec_name, desc);
            continue;
        };
        // The trace buffers are reused by the next case, so a result that
        // wants them has to take a copy now. Only non-passing cases do:
        // verbose never prints a pass, and holding every AST in the arena
        // costs tens of megabytes across the corpus.
        const keep = opts.verbose and res.outcome != .pass;
        try results.append(gpa, .{
            .spec = spec_name,
            .desc = desc,
            .outcome = res.outcome,
            .detail = res.detail,
            .in_sql = if (keep) try arena.dupe(u8, sql) else "",
            .out_ast = if (keep) try arena.dupe(u8, trace_ast.items) else "",
            .out_sql = if (keep) try arena.dupe(u8, trace_sql.items) else "",
        });
        try snapshotCase(spec_name, desc);
    }
    return true;
}

const CaseResult = struct { outcome: Outcome, detail: []const u8 = "" };

fn runCase(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    zoir: Zoir,
    c: Zoir.Node.Index,
    db: *driver.Db,
    sql: []const u8,
    setup: ?Zoir.Node.Index,
    trace: bool,
    expect: spec_expect.Options,
) !CaseResult {
    const qopts: driver.QueryOptions = .{ .current_time_unix_micros = fixed_now_unix_micros };

    // Opened before `setup`, not before the query: a case whose setup fails
    // never reaches the query, and would otherwise be reported against
    // whatever the *previous* case left in the buffers.
    if (trace) traceBegin(arena);
    defer if (trace) traceEnd();

    if (setup) |s| {
        const stmts = elements(zoir, s);
        var i: u32 = 0;
        while (i < stmts.len) : (i += 1) {
            const stmt_node = stmts.at(i);
            const n = stmt_node.get(zoir);
            if (n != .string_literal) continue;
            db.exec(n.string_literal, &.{}, qopts) catch |err| {
                // Say so: the trace the reader is about to see is this setup
                // statement's, not the `sql` printed above it.
                if (classify(err, db.lastError())) |u| return .{
                    .outcome = u.outcome,
                    .detail = try std.fmt.allocPrint(arena, "setup: {s}", .{u.detail}),
                };
                return .{
                    .outcome = .fail,
                    .detail = try std.fmt.allocPrint(arena, "setup: {s}: {s}", .{
                        @errorName(err), db.lastError(),
                    }),
                };
            };
        }
        // Setup got through, so its DDL is not what anyone is here to read.
        if (trace) traceClear();
    }

    var args: std.ArrayList(driver.Param) = .empty;
    defer args.deinit(arena);
    if (field(zoir, c, "named_args")) |na| {
        const n = na.get(zoir);
        if (n == .struct_literal) {
            for (n.struct_literal.names, 0..) |name, i| {
                const node = n.struct_literal.vals.at(@intCast(i));
                const v = try cellFromNode(arena, zoir, node, null) orelse continue;
                try args.append(arena, .{ .name = name.get(zoir), .value = v });
            }
        }
    }
    if (field(zoir, c, "args")) |a| {
        const r = elements(zoir, a);
        var i: u32 = 0;
        while (i < r.len) : (i += 1) {
            const t = argType(zoir, c, i);
            const v = try cellFromNode(arena, zoir, r.at(i), t) orelse continue;
            try args.append(arena, .{ .value = v, .type_text = t });
        }
    }

    const want_err = stringField(zoir, c, "expect_error");

    // Where a case's error is expected to surface decides how hard we look at
    // the message, and `typed` decides which rule applies:
    //
    //   - Analyze/prepare time. A doc-derived expectation is a prose fragment,
    //     so substring. A `typed` one passes on any message, because
    //     `query_test.go` compared none on this path and the exported string is
    //     whatever go-zetasqlite happened to say.
    //   - Row-iteration time. Substring again for the doc suite; `typed`
    //     demands equality, since that message is this engine's own wording,
    //     exported verbatim, and a change to it is worth seeing.
    //
    // `error.Unimplemented` is excluded from the `typed` prepare-time pass.
    // That was the corpus runner's one deliberate deviation from Go and it is
    // still the right one: a stubbed pipeline stage must not be able to
    // masquerade as a satisfied error expectation.
    var rows = db.query(sql, args.items, qopts) catch |err| {
        const msg = db.lastError();
        if (want_err) |w| {
            if (expect.typed) {
                if (err != error.Unimplemented) return .{ .outcome = .pass };
            } else if (std.mem.indexOf(u8, msg, w) != null) {
                return .{ .outcome = .pass };
            }
        }
        if (classify(err, msg)) |u| return u;
        return .{
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(err), msg }),
        };
    };
    defer rows.deinit();

    var got: std.ArrayList([]const driver.Cell) = .empty;
    defer got.deinit(arena);
    while (rows.next() catch |err| {
        const msg = db.lastError();
        if (want_err) |w| {
            if (expect.typed) {
                if (std.mem.eql(u8, w, msg)) return .{ .outcome = .pass };
                return .{
                    .outcome = .fail,
                    .detail = try std.fmt.allocPrint(arena, "expected [{s}] got [{s}]", .{ w, msg }),
                };
            }
            if (std.mem.indexOf(u8, msg, w) != null) return .{ .outcome = .pass };
        }
        if (classify(err, msg)) |u| return u;
        return .{
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(err), msg }),
        };
    }) |row| {
        try got.append(arena, row);
    }

    if (want_err) |w| {
        return .{
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "expected error containing \"{s}\"", .{w}),
        };
    }

    // `nondeterministic` cases (random noise, wall clock) must run cleanly;
    // their values are not the engine's to reproduce.
    if (boolField(zoir, c, "nondeterministic")) return .{ .outcome = .pass };

    const want_rows = field(zoir, c, "rows") orelse return .{ .outcome = .pass };
    return compareRows(
        gpa,
        arena,
        zoir,
        want_rows,
        got.items,
        boolField(zoir, c, "unordered"),
        expect,
    );
}

fn compareRows(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    zoir: Zoir,
    want_rows: Zoir.Node.Index,
    got: []const []const driver.Cell,
    unordered: bool,
    expect: spec_expect.Options,
) !CaseResult {
    const want = elements(zoir, want_rows);
    if (want.len != got.len) {
        return .{
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "want {d} rows, got {d}", .{ want.len, got.len }),
        };
    }

    if (!unordered) {
        var i: u32 = 0;
        while (i < want.len) : (i += 1) {
            if (!try rowMatches(gpa, zoir, want.at(i), got[i], expect)) {
                return .{
                    .outcome = .fail,
                    .detail = try std.fmt.allocPrint(arena, "row {d}: got {s}", .{
                        i, try renderRow(arena, got[i]),
                    }),
                };
            }
        }
        return .{ .outcome = .pass };
    }

    // Unordered: greedy pairing. Row counts here are tiny (the largest expected
    // set in the corpus is a few dozen), so O(n^2) is the right trade against
    // devising a total order over heterogeneous cells.
    const used = try arena.alloc(bool, got.len);
    @memset(used, false);
    var i: u32 = 0;
    while (i < want.len) : (i += 1) {
        var found = false;
        for (got, 0..) |row, j| {
            if (used[j]) continue;
            if (try rowMatches(gpa, zoir, want.at(i), row, expect)) {
                used[j] = true;
                found = true;
                break;
            }
        }
        if (!found) return .{
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "no row matches want[{d}]", .{i}),
        };
    }
    return .{ .outcome = .pass };
}

/// A result row as `(a, b, c)`, for failure messages. Without the actual value
/// beside the expectation a failure is not actionable.
fn renderRow(arena: std.mem.Allocator, row: []const driver.Cell) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(arena, '(');
    for (row, 0..) |cell, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        const s = try spec_expect.renderCell(arena, cell);
        try buf.appendSlice(arena, s);
    }
    try buf.append(arena, ')');
    return buf.items;
}

fn rowMatches(
    gpa: std.mem.Allocator,
    zoir: Zoir,
    want_row: Zoir.Node.Index,
    got_row: []const driver.Cell,
    expect: spec_expect.Options,
) !bool {
    const cells = elements(zoir, want_row);
    if (cells.len != got_row.len) return false;
    var i: u32 = 0;
    while (i < cells.len) : (i += 1) {
        if (!try spec_expect.matches(gpa, zoir, cells.at(i), got_row[i], expect)) return false;
    }
    return true;
}

/// Is this failure "we have not built that yet" rather than "we built it wrong"?
///
/// The line: **rejected at analyze or transform time as a missing capability**
/// is `unsupported`; anything that runs and returns the wrong values is `fail`.
/// That keeps the two questions this suite answers separate — what is missing,
/// and what is broken.
///
/// Each arm carries its own detail string, so `--verbose` always shows which
/// signal fired. That matters: a converter that mangled SQL would surface here
/// as "syntax" rather than vanishing into a generic bucket.
fn classify(err: anyerror, msg: []const u8) ?CaseResult {
    if (err == error.Unimplemented) {
        return .{ .outcome = .unsupported, .detail = "Unimplemented" };
    }
    // extractor.zig:241 — a resolved name with no entry in the dispatch maps.
    if (std.mem.indexOf(u8, msg, "UnsupportedFunction") != null) {
        return .{ .outcome = .unsupported, .detail = "no such function in the transformer" };
    }
    // A resolved AST node kind the extractor has no case for (TABLESAMPLE, TVF
    // scans — see extractor.zig:957-979).
    if (std.mem.indexOf(u8, msg, "UnsupportedNode") != null) {
        return .{ .outcome = .unsupported, .detail = "no such AST node in the extractor" };
    }
    if (std.mem.indexOf(u8, msg, "Function not found") != null) {
        return .{ .outcome = .unsupported, .detail = "analyzer: function not found" };
    }
    if (std.mem.indexOf(u8, msg, "Type not found") != null) {
        return .{ .outcome = .unsupported, .detail = "analyzer: type not found (proto)" };
    }
    // The name resolves but its UDF was never registered — the ACOS/SINH family
    // named in extractor.zig:106-110 with no handler in fn_math.zig.
    if (std.mem.indexOf(u8, msg, "no such function: zetasqlite_") != null) {
        return .{ .outcome = .unsupported, .detail = "registered name, no UDF" };
    }
    // "RANGE type is not supported", "Table-valued functions are not supported",
    // "Statement not supported: GrantStatement", "Subscript access ... is not
    // supported on values of type ...".
    if (std.mem.indexOf(u8, msg, "not supported") != null) {
        return .{ .outcome = .unsupported, .detail = "analyzer: feature not supported" };
    }
    // Syntax the analyzer will not parse because the feature is off in
    // shim/analyzer_shim.cc — pipe syntax (`|>`) and the scripting keywords
    // (LOOP/WHILE/REPEAT/RETURN). Verified against the corpus: the SQL arrives
    // intact and it is the grammar, not the text, that is rejected.
    if (std.mem.indexOf(u8, msg, "Syntax error: Unexpected") != null or
        std.mem.indexOf(u8, msg, "Unexpected keyword") != null)
    {
        return .{ .outcome = .unsupported, .detail = "analyzer: syntax/feature disabled" };
    }
    return null;
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

fn key(arena: std.mem.Allocator, r: Result) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\t{s}", .{ r.spec, r.desc });
}

fn report(
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    io: std.Io,
    results: []const Result,
    files_run: usize,
    baseline: *Baseline,
    opts: Options,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var counts = std.EnumArray(Outcome, usize).initFill(0);
    for (results) |r| counts.getPtr(r.outcome).* += 1;

    if (opts.markdown) {
        try markdownReport(out, arena, results);
        return;
    }

    if (builtin.mode == .Debug) {
        try out.print("WARNING: Debug build.\n\n", .{});
    }
    try out.print("spec corpus ({d} files under {s})\n", .{ files_run, specs_root });
    try out.print(
        "{d} PASS / {d} FAIL / {d} UNSUPPORTED / {d} SKIP  (of {d})\n\n",
        .{
            counts.get(.pass),        counts.get(.fail),
            counts.get(.unsupported), counts.get(.skip),
            results.len,
        },
    );

    if (opts.verbose) {
        for (results) |r| {
            if (r.outcome == .pass) continue;
            try out.print("  {s:<11} {s} :: {s}", .{
                @tagName(r.outcome), r.spec, r.desc,
            });
            if (r.detail.len > 0) try out.print(" :: {s}", .{r.detail});
            try out.writeAll("\n");
            try writeStage(out, "in  sql", r.in_sql);
            try writeStage(out, "out ast", r.out_ast);
            try writeStage(out, "out sql", r.out_sql);
            if (r.in_sql.len > 0) try out.writeAll("\n");
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
        for (results) |r| {
            if (r.outcome != .pass) continue;
            try buf.print(arena, "{s}\t{s}\n", .{ r.spec, r.desc });
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = baseline_path, .data = buf.items });
        try out.print("wrote {s} ({d} entries)\n", .{ baseline_path, counts.get(.pass) });
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
    // pass. `--strict` adds the other half — a wrong answer fails the run even
    // when the case was never in the baseline. Without it a case that flips
    // `unsupported` -> `fail` is silently green, because it never passed to
    // begin with and so cannot regress. `unsupported` and `skip` stay
    // non-fatal; they are the known-missing surface, not wrong answers.
    const strict_failures = if (opts.strict) counts.get(.fail) else 0;
    if (strict_failures > 0 and !opts.verbose) {
        try out.print("\nfailing cases:\n", .{});
        for (results) |r| {
            if (r.outcome != .fail) continue;
            try out.print("  FAIL {s} :: {s} :: {s}\n", .{ r.spec, r.desc, r.detail });
        }
    }

    if (regressions > 0 or strict_failures > 0) {
        if (regressions > 0) try out.print("\n{d} regressions\n", .{regressions});
        if (strict_failures > 0) {
            try out.print("{d} failing cases (--strict)\n", .{strict_failures});
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
    results: []const Result,
) !void {
    const Row = struct {
        name: []const u8,
        pass: usize = 0,
        fail: usize = 0,
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
        switch (r.outcome) {
            .pass => found.?.pass += 1,
            .fail => found.?.fail += 1,
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
        \\`unsupported` is detected at run time — `error.Unimplemented`, the
        \\analyzer's "Function not found", or a registered name with no UDF —
        \\not declared in the corpus. Implementing a function moves it to
        \\`pass` with no file edited.
        \\
        \\| Category | pass | fail | unsupported | skip |
        \\|---|---:|---:|---:|---:|
        \\
    , .{});

    var tp: usize = 0;
    var tf: usize = 0;
    var tu: usize = 0;
    var ts: usize = 0;
    for (cats.items) |row| {
        try out.print("| `{s}` | {d} | {d} | {d} | {d} |\n", .{
            row.name, row.pass, row.fail, row.unsupported, row.skip,
        });
        tp += row.pass;
        tf += row.fail;
        tu += row.unsupported;
        ts += row.skip;
    }
    try out.print("| **total** | **{d}** | **{d}** | **{d}** | **{d}** |\n", .{ tp, tf, tu, ts });
}
