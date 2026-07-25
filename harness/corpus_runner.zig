//! Conformance harness: replays testdata/corpus.json (exported from
//! go-zetasqlite's query_test.go) against the Zig driver, mirroring the Go
//! runner's semantics:
//!   - one shared :memory: db, cases run in slice order
//!   - fixed current-time injected into every query
//!   - a query-time error passes the case when expected_err is nonempty
//!     (message compared only on the row-iteration path)
//!   - floats compare with relative tolerance delta/mean < 1e-5
//!
//! Deviation: driver error.Unimplemented always counts as FAIL, so stubbed
//! pipeline stages can't masquerade as expected-error passes.
//!
//! Exit status: nonzero when any baseline case regressed.

const std = @import("std");
const builtin = @import("builtin");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

const corpus_path = "testdata/corpus.json";
const baseline_path = "testdata/baseline.txt";

const Outcome = enum { pass, fail, skip, errmsg_mismatch };

const CaseResult = struct {
    name: []const u8,
    idx: usize,
    outcome: Outcome,
    detail: []const u8 = "",
    ms: f64 = 0,
};

pub fn main(init: std.process.Init) !void {
    // Leak checking in Debug; allocation speed in release (per-case timings
    // would otherwise be dominated by DebugAllocator bookkeeping).
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (builtin.mode == .Debug) gpa_state.allocator() else std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    const corpus_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, corpus_path, arena, .limited(1 << 26));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, corpus_bytes, .{});
    const root = parsed.object;
    const fixed_now_micros = root.get("fixed_now_unix_micros").?.integer;
    const cases = root.get("cases").?.array.items;

    const baseline = loadBaseline(arena, init.io) catch std.StringHashMap(void).init(arena);

    var db = try driver.Db.open(gpa, ":memory:");
    defer db.close();

    var results: std.ArrayList(CaseResult) = .empty;
    var counts = std.enums.EnumArray(Outcome, usize).initFill(0);

    for (cases) |case_val| {
        const case = case_val.object;
        const name = case.get("name").?.string;
        const idx: usize = @intCast(case.get("idx").?.integer);
        const t0 = std.Io.Clock.awake.now(init.io);
        const result = runCase(arena, db, case, fixed_now_micros);
        const elapsed_ns = t0.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        counts.set(result.outcome, counts.get(result.outcome) + 1);
        try results.append(arena, .{
            .name = name,
            .idx = idx,
            .outcome = result.outcome,
            .detail = result.detail,
            .ms = @as(f64, @floatFromInt(@as(i64, @intCast(elapsed_ns)))) / 1_000_000.0,
        });
    }

    // Report.
    try out.print(
        "corpus: {d} PASS / {d} FAIL / {d} SKIP / {d} ERRMSG-MISMATCH (of {d})\n",
        .{
            counts.get(.pass),
            counts.get(.fail),
            counts.get(.skip),
            counts.get(.errmsg_mismatch),
            cases.len,
        },
    );

    // Optional: dump every FAIL detail (invoke with any extra arg).
    if (init.environ_map.get("DUMP_FAILS") != null) {
        for (results.items) |r| {
            if (r.outcome == .fail or r.outcome == .errmsg_mismatch) {
                const q = blk: {
                    for (cases) |cv| {
                        if (@as(usize, @intCast(cv.object.get("idx").?.integer)) == r.idx)
                            break :blk cv.object.get("query").?.string;
                    }
                    break :blk "";
                };
                try out.print("FAIL [{d}] {s} :: {s} :: {s}\n", .{ r.idx, r.name, r.detail, q });
            }
        }
        try out.flush();
    }

    // Baseline diff.
    var regressions: usize = 0;
    var newly_passing: usize = 0;
    for (results.items) |r| {
        // Trim to match loadBaseline's per-line trim (case names in the Go
        // suite can carry trailing whitespace, e.g. corpus case 598).
        const key = std.mem.trim(
            u8,
            try std.fmt.allocPrint(arena, "{d}\t{s}", .{ r.idx, r.name }),
            " \r\t",
        );
        const in_baseline = baseline.contains(key);
        const passed = r.outcome == .pass;
        if (in_baseline and !passed) {
            regressions += 1;
            try out.print("REGRESSION [{d}] {s}: {s}\n", .{ r.idx, r.name, r.detail });
        } else if (!in_baseline and passed) {
            newly_passing += 1;
        }
    }
    if (newly_passing > 0) {
        try out.print("{d} newly passing (append to {s}):\n", .{ newly_passing, baseline_path });
        for (results.items) |r| {
            // Trim to match loadBaseline's per-line trim (case names in the Go
        // suite can carry trailing whitespace, e.g. corpus case 598).
        const key = std.mem.trim(
            u8,
            try std.fmt.allocPrint(arena, "{d}\t{s}", .{ r.idx, r.name }),
            " \r\t",
        );
            if (r.outcome == .pass and !baseline.contains(key)) {
                try out.print("{d}\t{s}\n", .{ r.idx, r.name });
            }
        }
    }
    // Timing report: aggregates plus the slowest 20 cases (or all, if
    // ZETASQLITE_TIMING_ALL is set), sorted slowest-first. Skips are
    // excluded, matching query_test.go (t.Skip fires before its timer).
    var timings: std.ArrayList(CaseResult) = .empty;
    var total_ms: f64 = 0;
    for (results.items) |r| {
        if (r.outcome == .skip) continue;
        total_ms += r.ms;
        try timings.append(arena, r);
    }
    std.mem.sort(CaseResult, timings.items, {}, struct {
        fn slower(_: void, a: CaseResult, b: CaseResult) bool {
            return a.ms > b.ms;
        }
    }.slower);
    const show_all = init.environ_map.get("ZETASQLITE_TIMING_ALL") != null;
    const shown = if (show_all) timings.items.len else @min(timings.items.len, 20);
    const label: []const u8 = if (show_all) "all" else "slowest";
    try out.print("\n--- per-case timing: zetasqlite-zig (shared db) ---\n", .{});
    try out.print("total: {d:.1} ms over {d} cases\n", .{ total_ms, timings.items.len });
    try out.print("{s} {d} cases (set ZETASQLITE_TIMING_ALL=1 for all):\n", .{ label, shown });
    try out.print("  {s:>9}  {s}\n", .{ "query_ms", "case" });
    for (timings.items[0..shown]) |r| {
        try out.print("  {d:>9.3}  {s}\n", .{ r.ms, r.name });
    }

    try out.flush();
    if (regressions > 0) std.process.exit(1);
}

fn loadBaseline(arena: std.mem.Allocator, io: std.Io) !std.StringHashMap(void) {
    var map = std.StringHashMap(void).init(arena);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, baseline_path, arena, .limited(1 << 22));
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try map.put(trimmed, {});
    }
    return map;
}

const RunOutcome = struct {
    outcome: Outcome,
    detail: []const u8 = "",
};

fn runCase(
    arena: std.mem.Allocator,
    db: *driver.Db,
    case: std.json.ObjectMap,
    fixed_now_micros: i64,
) RunOutcome {
    if (case.get("skip")) |s| {
        if (s == .string and s.string.len > 0) return .{ .outcome = .skip };
    }
    const query = case.get("query").?.string;
    const expected_err: []const u8 = if (case.get("expected_err")) |e| e.string else "";
    const expected_rows = case.get("expected_rows").?.array.items;

    var args: std.ArrayList(driver.Param) = .empty;
    if (case.get("args")) |a| {
        for (a.array.items) |arg_val| {
            const param = paramFromTagged(arena, arg_val) catch |err| {
                return .{ .outcome = .fail, .detail = errName(arena, err) };
            };
            args.append(arena, param) catch return .{ .outcome = .fail, .detail = "oom" };
        }
    }

    var rows = db.query(query, args.items, .{
        .current_time_unix_micros = fixed_now_micros,
    }) catch |err| {
        if (err == error.Unimplemented) {
            return .{ .outcome = .fail, .detail = "unimplemented" };
        }
        // Analyze/prepare-time failure: passes any expected-error case
        // (query_test.go compares no message on this path).
        if (expected_err.len > 0) return .{ .outcome = .pass };
        const msg = std.fmt.allocPrint(arena, "{s}: {s}", .{
            errName(arena, err),
            db.lastError(),
        }) catch "error";
        return .{ .outcome = .fail, .detail = msg };
    };
    defer rows.deinit();

    var row_idx: usize = 0;
    while (true) {
        const maybe_row = rows.next() catch |err| {
            // Row-iteration failure: message must match exactly.
            if (expected_err.len > 0) {
                if (std.mem.eql(u8, expected_err, db.lastError())) {
                    return .{ .outcome = .pass };
                }
                const msg = std.fmt.allocPrint(arena, "expected [{s}] got [{s}]", .{
                    expected_err,
                    db.lastError(),
                }) catch "errmsg mismatch";
                return .{ .outcome = .errmsg_mismatch, .detail = msg };
            }
            return .{ .outcome = .fail, .detail = errName(arena, err) };
        };
        const row = maybe_row orelse break;
        if (row_idx >= expected_rows.len) {
            return .{ .outcome = .fail, .detail = "more rows than expected" };
        }
        const expected_row = expected_rows[row_idx].array.items;
        if (row.len != expected_row.len) {
            const msg = std.fmt.allocPrint(arena, "row {d}: expected {d} cols got {d}", .{
                row_idx, expected_row.len, row.len,
            }) catch "column count";
            return .{ .outcome = .fail, .detail = msg };
        }
        for (expected_row, row, 0..) |want, got, col| {
            if (!cellMatches(want, got)) {
                const msg = std.fmt.allocPrint(arena, "row {d} col {d} mismatch", .{
                    row_idx, col,
                }) catch "cell mismatch";
                return .{ .outcome = .fail, .detail = msg };
            }
        }
        row_idx += 1;
    }
    if (expected_err.len > 0) {
        return .{ .outcome = .fail, .detail = "expected error but query succeeded" };
    }
    if (row_idx != expected_rows.len) {
        const msg = std.fmt.allocPrint(arena, "expected {d} rows got {d}", .{
            expected_rows.len, row_idx,
        }) catch "row count";
        return .{ .outcome = .fail, .detail = msg };
    }
    return .{ .outcome = .pass };
}

fn errName(arena: std.mem.Allocator, err: anyerror) []const u8 {
    return std.fmt.allocPrint(arena, "{s}", .{@errorName(err)}) catch "error";
}

/// Converts a corpus tagged value (see corpus_export_test.go) into a Param.
fn paramFromTagged(arena: std.mem.Allocator, v: std.json.Value) !driver.Param {
    const obj = v.object;
    const tag = obj.get("t").?.string;
    if (std.mem.eql(u8, tag, "named")) {
        const name = obj.get("name").?.string;
        const inner = try cellFromTagged(arena, obj.get("v").?);
        return .{ .name = if (name.len > 0) name else null, .value = inner };
    }
    return .{ .value = try cellFromTagged(arena, v) };
}

fn cellFromTagged(arena: std.mem.Allocator, v: std.json.Value) !driver.Cell {
    const obj = v.object;
    const tag = obj.get("t").?.string;
    if (std.mem.eql(u8, tag, "null")) return .null;
    if (std.mem.eql(u8, tag, "bool")) return .{ .bool = obj.get("v").?.bool };
    if (std.mem.eql(u8, tag, "int")) {
        return .{ .int = try std.fmt.parseInt(i64, obj.get("v").?.string, 10) };
    }
    if (std.mem.eql(u8, tag, "float")) {
        if (obj.get("s")) |special| {
            if (std.mem.eql(u8, special.string, "NaN")) return .{ .float = std.math.nan(f64) };
            if (std.mem.eql(u8, special.string, "+Inf")) return .{ .float = std.math.inf(f64) };
            return .{ .float = -std.math.inf(f64) };
        }
        return .{ .float = switch (obj.get("v").?) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return error.BadCorpus,
        } };
    }
    if (std.mem.eql(u8, tag, "string")) return .{ .string = obj.get("v").?.string };
    if (std.mem.eql(u8, tag, "bytes")) {
        const b64 = obj.get("v").?.string;
        const decoder = std.base64.standard.Decoder;
        const n = try decoder.calcSizeForSlice(b64);
        const buf = try arena.alloc(u8, n);
        try decoder.decode(buf, b64);
        return .{ .bytes = buf };
    }
    if (std.mem.eql(u8, tag, "array")) {
        const items = obj.get("v").?.array.items;
        const cells = try arena.alloc(driver.Cell, items.len);
        for (items, cells) |item, *cell| cell.* = try cellFromTagged(arena, item);
        return .{ .array = cells };
    }
    if (std.mem.eql(u8, tag, "struct")) {
        const fields_obj = obj.get("v").?.object;
        const fields = try arena.alloc(driver.Cell.Field, fields_obj.count());
        var it = fields_obj.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            fields[i] = .{
                .name = entry.key_ptr.*,
                .value = try cellFromTagged(arena, entry.value_ptr.*),
            };
        }
        return .{ .struct_ = fields };
    }
    return error.BadCorpus;
}

/// Comparison semantics of query_test.go's cmp.Diff + floatCmpOpt.
fn cellMatches(want_tagged: std.json.Value, got: driver.Cell) bool {
    const obj = want_tagged.object;
    const tag = obj.get("t").?.string;

    if (std.mem.eql(u8, tag, "null")) return got == .null;
    if (std.mem.eql(u8, tag, "bool")) {
        return got == .bool and got.bool == obj.get("v").?.bool;
    }
    if (std.mem.eql(u8, tag, "int")) {
        const want = std.fmt.parseInt(i64, obj.get("v").?.string, 10) catch return false;
        return got == .int and got.int == want;
    }
    if (std.mem.eql(u8, tag, "float")) {
        if (got != .float) return false;
        if (obj.get("s")) |special| {
            if (std.mem.eql(u8, special.string, "NaN")) return std.math.isNan(got.float);
            if (std.mem.eql(u8, special.string, "+Inf"))
                return std.math.isPositiveInf(got.float);
            return std.math.isNegativeInf(got.float);
        }
        const want: f64 = switch (obj.get("v").?) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return false,
        };
        if (want == got.float) return true;
        const delta = @abs(want - got.float);
        const mean = @abs(want + got.float) / 2.0;
        if (mean == 0) return false;
        return delta / mean < 0.00001;
    }
    if (std.mem.eql(u8, tag, "string")) {
        const want = obj.get("v").?.string;
        // Go returns date/time kinds as strings (ToApiString) through
        // database/sql, so each renders to a distinct string-valued Cell.
        return switch (got) {
            .string => |s| std.mem.eql(u8, want, s),
            .date => |s| std.mem.eql(u8, want, s),
            .timestamp => |s| std.mem.eql(u8, want, s),
            .datetime => |s| std.mem.eql(u8, want, s),
            .time => |s| std.mem.eql(u8, want, s),
            .interval => |s| std.mem.eql(u8, want, s),
            else => false,
        };
    }
    if (std.mem.eql(u8, tag, "bytes")) {
        if (got != .bytes) return false;
        const b64 = obj.get("v").?.string;
        var buf: [4096]u8 = undefined;
        const decoder = std.base64.standard.Decoder;
        const n = decoder.calcSizeForSlice(b64) catch return false;
        if (n > buf.len) return false;
        decoder.decode(buf[0..n], b64) catch return false;
        return std.mem.eql(u8, buf[0..n], got.bytes);
    }
    if (std.mem.eql(u8, tag, "array")) {
        if (got != .array) return false;
        const items = obj.get("v").?.array.items;
        if (items.len != got.array.len) return false;
        for (items, got.array) |want_item, got_item| {
            if (!cellMatches(want_item, got_item)) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, tag, "struct")) {
        if (got != .struct_) return false;
        const want_fields = obj.get("v").?.object;
        if (want_fields.count() != got.struct_.len) return false;
        for (got.struct_) |field| {
            const want_val = want_fields.get(field.name) orelse return false;
            if (!cellMatches(want_val, field.value)) return false;
        }
        return true;
    }
    return false;
}
