//! Replays the ZON spec corpus under `testdata/specs/`.
//!
//! The specs come from goccy/googlesqlite, whose expected values were extracted
//! from the **Examples** sections of the GoogleSQL reference docs — so the
//! numbers on the right-hand side are Google's own published output. See
//! `tools/spec_import.py` for the conversion and `docs/BENCH_GSQL.md`'s sibling
//! `docs/SPEC_COVERAGE.md` for the report this emits.
//!
//! ## Why this exists next to `zig build corpus`
//!
//! `corpus` is deep but narrow: 748 cases inherited from go-zetasqlite's
//! `query_test.go`, all sharing one `:memory:` database in slice order, so DDL
//! from one case is visible to the next. This suite is broad and isolated: one
//! spec per function, cases that declare their own `setup`, and a fresh
//! connection wherever state exists.
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
//! Usage: zig build spec -- [--filter SUBSTR] [--dialect googlesql|bigquery]
//!                          [--verbose] [--markdown] [--update-baseline]

const std = @import("std");
const builtin = @import("builtin");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const spec_expect = zetasqlite.spec_expect;

const Zoir = std.zig.Zoir;

const specs_root = "testdata/specs";
const manifest_path = "testdata/specs/manifest.zon";
const baseline_path = "testdata/spec_baseline.txt";

/// The clock every case sees, so CURRENT_* is reproducible. Same instant the
/// JSON corpus pins (2006-01-02 15:04:05 UTC, Go's reference time).
const fixed_now_unix_micros: i64 = 1136239445000000;

const Dialect = enum { googlesql, bigquery };

/// `manifest.zon` — the one fixed-shape file here, so it gets the typed parser.
const Manifest = struct {
    generated_from: []const u8,
    files: []const Entry,

    const Entry = struct {
        path: []const u8,
        dialect: Dialect,
        cases: u32,
    };
};

const Outcome = enum { pass, fail, unsupported, skip };

const Options = struct {
    filter: ?[]const u8 = null,
    dialect: ?Dialect = null,
    verbose: bool = false,
    markdown: bool = false,
    update_baseline: bool = false,
};

const Result = struct {
    spec: []const u8,
    desc: []const u8,
    outcome: Outcome,
    detail: []const u8 = "",
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

    const man_src = try std.Io.Dir.cwd().readFileAllocOptions(
        init.io,
        manifest_path,
        arena,
        .limited(1 << 22),
        .of(u8),
        0,
    );
    // No `defer man_diag.deinit(...)`: the parse allocates through `arena`, so
    // the Ast and Zoir it stashes are arena memory. Deinit-ing with `gpa` is an
    // invalid free, and deinit-ing with the arena allocator is pointless.
    var man_diag: std.zon.parse.Diagnostics = .{};
    const manifest = std.zon.parse.fromSliceAlloc(
        Manifest,
        arena,
        man_src,
        &man_diag,
        .{},
    ) catch {
        try out.print("{s}: {f}\n", .{ manifest_path, &man_diag });
        try out.flush();
        std.process.exit(1);
    };

    var baseline = try loadBaseline(gpa, init.io, arena);
    defer baseline.deinit(gpa);

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(gpa);

    for (manifest.files) |entry| {
        if (opts.dialect) |d| {
            if (d != entry.dialect) continue;
        }
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, entry.path, f) == null) continue;
        }
        try runSpecFile(gpa, arena, init.io, entry, &results);
    }

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
        } else {
            try out.print(
                "usage: zig build spec -- [--filter SUBSTR] [--dialect D] " ++
                    "[--verbose] [--markdown] [--update-baseline]\n",
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

/// Elements of an array literal; `.{}` reads as empty rather than absent.
fn elements(zoir: Zoir, node: Zoir.Node.Index) Zoir.Node.Index.Range {
    return switch (node.get(zoir)) {
        .array_literal => |r| r,
        else => .{ .start = @enumFromInt(0), .len = 0 },
    };
}

/// A ZON scalar as a bind parameter.
fn cellFromNode(zoir: Zoir, node: Zoir.Node.Index) ?driver.Cell {
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
        else => null,
    };
}

// ---- execution ----

fn runSpecFile(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    entry: Manifest.Entry,
    results: *std.ArrayList(Result),
) !void {
    const path = try std.fs.path.join(arena, &.{ specs_root, entry.path });
    const src = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(1 << 22),
        .of(u8),
        0,
    ) catch |err| {
        // The manifest is generated; a missing file means it is stale, which is
        // a hard error rather than a silently shorter run.
        try results.append(gpa, .{
            .spec = entry.path,
            .desc = "(load)",
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "cannot read: {s}", .{@errorName(err)}),
        });
        return;
    };

    var ast = try std.zig.Ast.parse(gpa, src, .zon);
    defer ast.deinit(gpa);
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);
    if (zoir.compile_errors.len > 0) {
        try results.append(gpa, .{
            .spec = entry.path,
            .desc = "(parse)",
            .outcome = .fail,
            .detail = "malformed ZON",
        });
        return;
    }

    // Duped: string literals point into `zoir.string_bytes`, which dies with
    // the `defer zoir.deinit` above, while `results` outlives this function.
    const spec_name = try arena.dupe(u8, stringField(zoir, .root, "spec") orelse entry.path);
    const cases = field(zoir, .root, "cases") orelse return;

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
    // setup-free case; only 9% of the corpus carries `setup`, and those get
    // their own. See docs: this is the ordering coupling `corpus` has and this
    // suite does not.
    var shared: ?*driver.Db = null;
    defer if (shared) |db| db.close();

    const range = elements(zoir, cases);
    var i: u32 = 0;
    while (i < range.len) : (i += 1) {
        const c = range.at(i);
        const desc = try arena.dupe(u8, stringField(zoir, c, "desc") orelse "(no desc)");
        const sql = stringField(zoir, c, "sql") orelse continue;

        if (stringField(zoir, c, "skip") orelse spec_skip) |reason| {
            try results.append(gpa, .{
                .spec = spec_name,
                .desc = desc,
                .outcome = .skip,
                .detail = try arena.dupe(u8, reason),
            });
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

        const res = runCase(gpa, arena, zoir, c, db, sql, setup) catch |err| {
            try results.append(gpa, .{
                .spec = spec_name,
                .desc = desc,
                .outcome = .fail,
                .detail = try std.fmt.allocPrint(arena, "harness: {s}", .{@errorName(err)}),
            });
            continue;
        };
        try results.append(gpa, .{
            .spec = spec_name,
            .desc = desc,
            .outcome = res.outcome,
            .detail = res.detail,
        });
    }
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
) !CaseResult {
    const qopts: driver.QueryOptions = .{ .current_time_unix_micros = fixed_now_unix_micros };

    if (setup) |s| {
        const stmts = elements(zoir, s);
        var i: u32 = 0;
        while (i < stmts.len) : (i += 1) {
            const stmt_node = stmts.at(i);
            const n = stmt_node.get(zoir);
            if (n != .string_literal) continue;
            db.exec(n.string_literal, &.{}, qopts) catch |err| {
                if (classify(err, db.lastError())) |u| return u;
                return .{
                    .outcome = .fail,
                    .detail = try std.fmt.allocPrint(arena, "setup: {s}: {s}", .{
                        @errorName(err), db.lastError(),
                    }),
                };
            };
        }
    }

    var args: std.ArrayList(driver.Param) = .empty;
    defer args.deinit(arena);
    if (field(zoir, c, "named_args")) |na| {
        const n = na.get(zoir);
        if (n == .struct_literal) {
            for (n.struct_literal.names, 0..) |name, i| {
                const v = cellFromNode(zoir, n.struct_literal.vals.at(@intCast(i))) orelse continue;
                try args.append(arena, .{ .name = name.get(zoir), .value = v });
            }
        }
    }
    if (field(zoir, c, "args")) |a| {
        const r = elements(zoir, a);
        var i: u32 = 0;
        while (i < r.len) : (i += 1) {
            const v = cellFromNode(zoir, r.at(i)) orelse continue;
            try args.append(arena, .{ .value = v });
        }
    }

    const want_err = stringField(zoir, c, "expect_error");

    var rows = db.query(sql, args.items, qopts) catch |err| {
        const msg = db.lastError();
        if (want_err) |w| {
            // Doc-derived expectations are prose fragments, so substring —
            // not the corpus runner's exact match.
            if (std.mem.indexOf(u8, msg, w) != null) return .{ .outcome = .pass };
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
    return compareRows(gpa, arena, zoir, want_rows, got.items, boolField(zoir, c, "unordered"));
}

fn compareRows(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    zoir: Zoir,
    want_rows: Zoir.Node.Index,
    got: []const []const driver.Cell,
    unordered: bool,
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
            if (!try rowMatches(gpa, zoir, want.at(i), got[i])) {
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
            if (try rowMatches(gpa, zoir, want.at(i), row)) {
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
) !bool {
    const cells = elements(zoir, want_row);
    if (cells.len != got_row.len) return false;
    var i: u32 = 0;
    while (i < cells.len) : (i += 1) {
        if (!try spec_expect.matches(gpa, zoir, cells.at(i), got_row[i], .{})) return false;
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
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try map.put(gpa, trimmed, {});
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
    manifest: Manifest,
    baseline: *Baseline,
    opts: Options,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var counts = std.EnumArray(Outcome, usize).initFill(0);
    for (results) |r| counts.getPtr(r.outcome).* += 1;

    if (opts.markdown) {
        try markdownReport(out, arena, results, manifest);
        return;
    }

    if (builtin.mode == .Debug) {
        try out.print("WARNING: Debug build.\n\n", .{});
    }
    try out.print("spec corpus ({s})\n", .{manifest.generated_from});
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

    if (regressions > 0) {
        try out.print("\n{d} regressions\n", .{regressions});
        try out.flush();
        std.process.exit(1);
    }
}

/// Per-category coverage, which is the number worth tracking: a single
/// "N% of cases pass" is dominated by the categories we have not built at all.
fn markdownReport(
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    results: []const Result,
    manifest: Manifest,
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
        \\Generated by `zig build spec -- --markdown`. Corpus imported from
        \\{s} by `tools/spec_import.py`; expected values are the GoogleSQL
        \\reference docs' own published output.
        \\
        \\`unsupported` is detected at run time — `error.Unimplemented`, the
        \\analyzer's "Function not found", or a registered name with no UDF —
        \\not declared in the corpus. Implementing a function moves it to
        \\`pass` with no file edited.
        \\
        \\| Category | pass | fail | unsupported | skip |
        \\|---|---:|---:|---:|---:|
        \\
    , .{manifest.generated_from});

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
