//! The core of the ZON spec-corpus runner: load the manifest, run each spec
//! file's cases, classify pass/fail/not_implemented/skip. Split out of
//! `harness/spec_runner.zig` so both that CLI (baseline gating, `--markdown`,
//! `--strict` exit codes — CLI-only concerns, still owned by that file) and
//! `harness/spec_ui.zig` (a browsable results UI) share one source of truth
//! for what a case's outcome means, rather than two copies drifting apart.
//!
//! `RunOptions.capture_detail` is the one behavioral knob between the two
//! callers: false (what `spec_runner.zig` always passes) reproduces today's
//! cost and output exactly; true (what `spec_ui.zig` passes) additionally
//! captures each case's input/setup SQL, analyzed AST, transformed SQL, and
//! rendered expected/received values into `Record.full`, at the cost of one
//! extra `driver.QueryOptions.capture` render per case (see `src/driver.zig`'s
//! `Capture` — the AST node and transformed SQL are computed on every query
//! regardless; capturing them costs nothing beyond rendering into this
//! call's own arena, paid only when requested).

const std = @import("std");
const driver = @import("../driver.zig");
const spec_expect = @import("spec_expect.zig");

const Zoir = std.zig.Zoir;

pub const specs_root = "testdata/specs";
pub const manifest_path = "testdata/specs/manifest.zon";

/// The clock every case sees, so CURRENT_* is reproducible. Same instant the
/// JSON corpus pins (2006-01-02 15:04:05 UTC, Go's reference time).
const fixed_now_unix_micros: i64 = 1136239445000000;

pub const Dialect = enum { googlesql, bigquery };

/// `manifest.zon` — the one fixed-shape file here, so it gets the typed parser.
pub const Manifest = struct {
    generated_from: []const u8,
    files: []const Entry,

    pub const Entry = struct {
        path: []const u8,
        dialect: Dialect,
        cases: u32,
    };
};

pub fn loadManifest(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !Manifest {
    const man_src = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        manifest_path,
        arena,
        .limited(1 << 22),
        .of(u8),
        0,
    );
    var man_diag: std.zon.parse.Diagnostics = .{};
    return std.zon.parse.fromSliceAlloc(
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
}

/// What actually happened when this engine ran the case. Says nothing about
/// whether BigQuery would accept the construct at all — see `unsupported_in_bigquery`.
pub const Outcome = enum { pass, fail, not_implemented, skip };

/// Per-case detail beyond pass/fail, populated only when `RunOptions.capture_detail`.
pub const Detail = struct {
    input_sql: []const u8 = "",
    setup_sql: []const []const u8 = &.{},
    /// Empty when the case's statement never reached
    /// `driver.transformStatementFragment` (analysis/transform failed first,
    /// or the statement kind — plain CREATE TABLE, CREATE FUNCTION,
    /// TRUNCATE — never builds an SQLFragment at all) — not an error.
    ast_text: []const u8 = "",
    transformed_sql: []const u8 = "",
    expected_text: []const u8 = "",
    received_text: []const u8 = "",
};

pub const Record = struct {
    spec: []const u8,
    desc: []const u8,
    outcome: Outcome,
    detail: []const u8 = "",
    full: Detail = .{},
    /// Set from a case's or file's declared `.unsupported_in_bigquery` field:
    /// evidence (a quoted rejection string, or a short reasoned claim) that
    /// real BigQuery does not support the construct under test, independent
    /// of whether this engine could run it at all. `bucket()` reports any
    /// such case as `.unsupported` regardless of `outcome`.
    unsupported_in_bigquery: ?[]const u8 = null,
    /// True when a declared-`unsupported_in_bigquery` case ran to a genuine
    /// `pass` — real matching rows, not an `.expect_error`/`.expect_error_any`
    /// match — meaning this engine now accepts something it claims BigQuery
    /// doesn't. A stale annotation, not a happy accident; see `runCase`.
    unsupported_stale: bool = false,
};

/// The two-axis view `--verbose`/`--markdown`/`spec_ui` report: `Outcome` answers
/// "did this engine run it correctly," `unsupported_in_bigquery` answers "does
/// BigQuery accept the construct at all" — orthogonal facts folded into one
/// display bucket. A declared-unsupported case is never short-circuited before
/// running (`.skip` still owns that); it runs and is checked like any other
/// case, and only the reported bucket is overridden.
pub const Bucket = enum { pass, fail, not_implemented, unsupported, skip };

pub fn bucket(r: Record) Bucket {
    if (r.unsupported_in_bigquery != null) return .unsupported;
    return switch (r.outcome) {
        .pass => .pass,
        .fail => .fail,
        .not_implemented => .not_implemented,
        .skip => .skip,
    };
}

pub const RunOptions = struct {
    dialect: ?Dialect = null,
    filter: ?[]const u8 = null,
    capture_detail: bool = false,
};

/// Runs every case in `manifest.files` that passes `opts.dialect`/`opts.filter`,
/// appending one `Record` per case to `results`.
pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    manifest: Manifest,
    opts: RunOptions,
    results: *std.ArrayList(Record),
) !void {
    for (manifest.files) |entry| {
        if (opts.dialect) |d| {
            if (d != entry.dialect) continue;
        }
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, entry.path, f) == null) continue;
        }
        try runSpecFile(gpa, arena, io, entry, opts.capture_detail, results);
    }
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
    capture_detail: bool,
    results: *std.ArrayList(Record),
) !void {
    // Comparison rules diverge for testdata/specs/googlesql/compliance/**;
    // see spec_expect.zig's module doc comment.
    const corpus: spec_expect.Corpus = if (std.mem.startsWith(u8, entry.path, "googlesql/compliance/"))
        .compliance
    else
        .doc;

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

    // A file-level `.skip` applies to every case in it. It says this harness
    // cannot meaningfully run or compare the case at all (no proto registration,
    // a false-pass risk) — distinct from `.unsupported_in_bigquery` below, which
    // says BigQuery itself rejects the construct. Without either, a case that
    // this engine can't handle reports as NOT_IMPLEMENTED, which reads as a
    // to-do list; that is the correct default when no BigQuery verdict is on
    // record.
    const spec_skip: ?[]const u8 = if (stringField(zoir, .root, "skip")) |r|
        try arena.dupe(u8, r)
    else
        null;

    // A file-level `.unsupported_in_bigquery` applies to every case in it,
    // same override rule as `.skip`. Unlike `.skip`, it does not stop the case
    // from running — see `bucket()` and `runCase`'s staleness check.
    const spec_unsupported_bq: ?[]const u8 = if (stringField(zoir, .root, "unsupported_in_bigquery")) |r|
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
        // Duped for the same reason `desc` is: this outlives `zoir`, which
        // dies with this function, while `results` (and thus this string)
        // does not.
        const unsupported_bq: ?[]const u8 = if (stringField(zoir, c, "unsupported_in_bigquery") orelse spec_unsupported_bq) |r|
            try arena.dupe(u8, r)
        else
            null;

        if (stringField(zoir, c, "skip") orelse spec_skip) |reason| {
            try results.append(gpa, .{
                .spec = spec_name,
                .desc = desc,
                .outcome = .skip,
                .detail = try arena.dupe(u8, reason),
                .unsupported_in_bigquery = unsupported_bq,
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

        var full: Detail = .{};
        const full_ptr: ?*Detail = if (capture_detail) &full else null;
        const res = runCase(gpa, arena, zoir, c, db, sql, setup, full_ptr, unsupported_bq, corpus) catch |err| {
            try results.append(gpa, .{
                .spec = spec_name,
                .desc = desc,
                .outcome = .fail,
                .detail = try std.fmt.allocPrint(arena, "harness: {s}", .{@errorName(err)}),
                .full = full,
                .unsupported_in_bigquery = unsupported_bq,
            });
            continue;
        };
        try results.append(gpa, .{
            .spec = spec_name,
            .desc = desc,
            .outcome = res.outcome,
            .detail = res.detail,
            .full = full,
            .unsupported_in_bigquery = unsupported_bq,
            .unsupported_stale = res.unsupported_stale,
        });
    }
}

const CaseResult = struct { outcome: Outcome, detail: []const u8 = "", unsupported_stale: bool = false };

/// Copies `capture`'s AST/transformed-SQL into `f`, if the statement reached
/// `transformStatementFragment` at all (see `Detail.ast_text`'s doc comment
/// for when it doesn't). Called from every point `runCase` can return once
/// the query attempt has happened, success or failure, so a failing case's
/// debug view still shows what this engine actually analyzed/generated.
/// `capture` was constructed with the same `arena` as this call already
/// rendering into — see `driver.Capture`'s doc comment for why that has to
/// happen at capture time rather than here: `query()`'s own arena, which a
/// failing query frees via `errdefer` before this ever runs, cannot be the
/// one holding the rendered text.
fn fillCapture(f: *Detail, capture: driver.Capture) void {
    f.ast_text = capture.ast_text;
    f.transformed_sql = capture.sql;
}

fn renderRowsText(arena: std.mem.Allocator, rows: []const []const driver.Cell) ![]const u8 {
    if (rows.len == 0) return "(0 rows)";
    var buf: std.ArrayList(u8) = .empty;
    for (rows, 0..) |row, i| {
        if (i > 0) try buf.append(arena, '\n');
        try buf.appendSlice(arena, try renderRow(arena, row));
    }
    return buf.toOwnedSlice(arena);
}

fn renderWantRowsText(arena: std.mem.Allocator, zoir: Zoir, want_rows: Zoir.Node.Index) ![]const u8 {
    const range = elements(zoir, want_rows);
    if (range.len == 0) return "(0 rows)";
    var buf: std.ArrayList(u8) = .empty;
    var i: u32 = 0;
    while (i < range.len) : (i += 1) {
        if (i > 0) try buf.append(arena, '\n');
        try buf.append(arena, '(');
        const cells = elements(zoir, range.at(i));
        var j: u32 = 0;
        while (j < cells.len) : (j += 1) {
            if (j > 0) try buf.appendSlice(arena, ", ");
            try buf.appendSlice(arena, try spec_expect.renderWant(arena, zoir, cells.at(j)));
        }
        try buf.append(arena, ')');
    }
    return buf.toOwnedSlice(arena);
}

fn runCase(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    zoir: Zoir,
    c: Zoir.Node.Index,
    db: *driver.Db,
    sql: []const u8,
    setup: ?Zoir.Node.Index,
    full: ?*Detail,
    unsupported_in_bigquery: ?[]const u8,
    corpus: spec_expect.Corpus,
) !CaseResult {
    if (full) |f| f.input_sql = try arena.dupe(u8, sql);

    const qopts: driver.QueryOptions = .{ .current_time_unix_micros = fixed_now_unix_micros };

    if (setup) |s| {
        const stmts = elements(zoir, s);
        var setup_list: std.ArrayList([]const u8) = .empty;
        var i: u32 = 0;
        while (i < stmts.len) : (i += 1) {
            const stmt_node = stmts.at(i);
            const n = stmt_node.get(zoir);
            if (n != .string_literal) continue;
            if (full != null) try setup_list.append(arena, try arena.dupe(u8, n.string_literal));
            db.exec(n.string_literal, &.{}, qopts) catch |err| {
                if (full) |f| f.setup_sql = setup_list.items;
                if (classify(err, db.lastError())) |u| return u;
                return .{
                    .outcome = .fail,
                    .detail = try std.fmt.allocPrint(arena, "setup: {s}: {s}", .{
                        @errorName(err), db.lastError(),
                    }),
                };
            };
        }
        if (full) |f| f.setup_sql = setup_list.items;
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
    // Upstream ERROR text from a reference implementation this engine does
    // not share a word of (ZetaSQL's own C++ error space and wording, e.g.
    // `generic::out_of_range: ...`) is unfalsifiable as a substring, but
    // omitting `.expect_error` entirely would assert success, which is the
    // wrong claim — a case that should error but silently returns a
    // plausible wrong value deserves to be caught, not skipped. Checked
    // after `classify()`: a case whose upstream error actually manifests
    // here as "we don't support this" still correctly reports unsupported,
    // not a hollow pass.
    const want_err_any = boolField(zoir, c, "expect_error_any");

    var capture: driver.Capture = .{ .arena = arena };
    const query_qopts: driver.QueryOptions = .{
        .current_time_unix_micros = fixed_now_unix_micros,
        .capture = if (full != null) &capture else null,
    };

    var rows = db.query(sql, args.items, query_qopts) catch |err| {
        if (full) |f| fillCapture(f, capture);
        const msg = db.lastError();
        if (want_err) |w| {
            // Doc-derived expectations are prose fragments, so substring —
            // not the corpus runner's exact match.
            if (std.mem.indexOf(u8, msg, w) != null) return .{ .outcome = .pass };
        }
        if (classify(err, msg)) |u| return u;
        if (want_err_any) return .{ .outcome = .pass };
        return .{
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(err), msg }),
        };
    };
    defer rows.deinit();
    if (full) |f| fillCapture(f, capture);

    var got: std.ArrayList([]const driver.Cell) = .empty;
    defer got.deinit(arena);
    while (rows.next() catch |err| {
        const msg = db.lastError();
        if (want_err) |w| {
            if (std.mem.indexOf(u8, msg, w) != null) return .{ .outcome = .pass };
        }
        if (classify(err, msg)) |u| return u;
        if (want_err_any) return .{ .outcome = .pass };
        return .{
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(err), msg }),
        };
    }) |row| {
        try got.append(arena, row);
    }

    if (full) |f| {
        f.received_text = try renderRowsText(arena, got.items);
        if (field(zoir, c, "rows")) |want_rows| {
            f.expected_text = try renderWantRowsText(arena, zoir, want_rows);
        } else {
            f.expected_text = "(not checked)";
        }
    }

    if (want_err) |w| {
        return .{
            .outcome = .fail,
            .detail = try std.fmt.allocPrint(arena, "expected error containing \"{s}\"", .{w}),
        };
    }
    if (want_err_any) {
        return .{ .outcome = .fail, .detail = "expected an error, none occurred" };
    }

    // `nondeterministic` cases (random noise, wall clock) must run cleanly;
    // their values are not the engine's to reproduce. Not a staleness signal
    // either way: "ran without error" is too weak a claim to call a declared
    // BigQuery rejection stale.
    if (boolField(zoir, c, "nondeterministic")) return .{ .outcome = .pass };

    // No `.rows` to check (most commonly a `prepare_database` case, which is
    // scaffolding, not an assertion) is likewise not a staleness signal — the
    // engine reaching this point proves nothing about the disputed construct.
    const want_rows = field(zoir, c, "rows") orelse return .{ .outcome = .pass };
    const result = try compareRows(gpa, arena, zoir, want_rows, got.items, boolField(zoir, c, "unordered"), corpus);
    // A declared-BigQuery-invalid case that genuinely matched real rows here
    // (not an `.expect_error`/`.expect_error_any` match — those already
    // returned above) means this engine now accepts something it claims
    // BigQuery doesn't. Flag it rather than let it read as an ordinary pass.
    if (result.outcome == .pass and unsupported_in_bigquery != null) {
        return .{ .outcome = .pass, .unsupported_stale = true };
    }
    return result;
}

fn compareRows(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    zoir: Zoir,
    want_rows: Zoir.Node.Index,
    got: []const []const driver.Cell,
    unordered: bool,
    corpus: spec_expect.Corpus,
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
            if (!try rowMatches(gpa, zoir, want.at(i), got[i], corpus)) {
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
            if (try rowMatches(gpa, zoir, want.at(i), row, corpus)) {
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
    corpus: spec_expect.Corpus,
) !bool {
    const cells = elements(zoir, want_row);
    if (cells.len != got_row.len) return false;
    var i: u32 = 0;
    while (i < cells.len) : (i += 1) {
        if (!try spec_expect.matches(gpa, zoir, cells.at(i), got_row[i], .{ .corpus = corpus })) return false;
    }
    return true;
}

/// Is this failure "we have not built that yet" rather than "we built it wrong"?
///
/// The line: **rejected at analyze or transform time as a missing capability**
/// is `not_implemented`; anything that runs and returns the wrong values is
/// `fail`. That keeps the two questions this suite answers separate — what is
/// missing, and what is broken. Neither arm asks whether BigQuery itself would
/// accept the construct — that is `unsupported_in_bigquery`'s job, a declared
/// fact this function has no way to know from an error string alone.
///
/// Each arm carries its own detail string, so `--verbose` always shows which
/// signal fired. That matters: a converter that mangled SQL would surface here
/// as "syntax" rather than vanishing into a generic bucket.
fn classify(err: anyerror, msg: []const u8) ?CaseResult {
    if (err == error.Unimplemented) {
        return .{ .outcome = .not_implemented, .detail = "Unimplemented" };
    }
    // extractor.zig:241 — a resolved name with no entry in the dispatch maps.
    if (std.mem.indexOf(u8, msg, "UnsupportedFunction") != null) {
        return .{ .outcome = .not_implemented, .detail = "no such function in the transformer" };
    }
    // A resolved AST node kind the extractor has no case for (TABLESAMPLE, TVF
    // scans — see extractor.zig:957-979).
    if (std.mem.indexOf(u8, msg, "UnsupportedNode") != null) {
        return .{ .outcome = .not_implemented, .detail = "no such AST node in the extractor" };
    }
    if (std.mem.indexOf(u8, msg, "Function not found") != null) {
        return .{ .outcome = .not_implemented, .detail = "analyzer: function not found" };
    }
    if (std.mem.indexOf(u8, msg, "Type not found") != null) {
        return .{ .outcome = .not_implemented, .detail = "analyzer: type not found (proto)" };
    }
    // The name resolves but its UDF was never registered — the ACOS/SINH family
    // named in extractor.zig:106-110 with no handler in fn_math.zig.
    if (std.mem.indexOf(u8, msg, "no such function: zetasqlite_") != null) {
        return .{ .outcome = .not_implemented, .detail = "registered name, no UDF" };
    }
    // "RANGE type is not supported", "Table-valued functions are not supported",
    // "Statement not supported: GrantStatement", "Subscript access ... is not
    // supported on values of type ...".
    if (std.mem.indexOf(u8, msg, "not supported") != null) {
        return .{ .outcome = .not_implemented, .detail = "analyzer: feature not supported" };
    }
    // Syntax the analyzer will not parse because the feature is off in
    // shim/analyzer_shim.cc — pipe syntax (`|>`) and the scripting keywords
    // (LOOP/WHILE/REPEAT/RETURN). Verified against the corpus: the SQL arrives
    // intact and it is the grammar, not the text, that is rejected.
    if (std.mem.indexOf(u8, msg, "Syntax error: Unexpected") != null or
        std.mem.indexOf(u8, msg, "Unexpected keyword") != null)
    {
        return .{ .outcome = .not_implemented, .detail = "analyzer: syntax/feature disabled" };
    }
    return null;
}

