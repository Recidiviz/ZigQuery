//! Port of go-zetasqlite's window UDF framework (function_bind.go
//! WindowAggregator + newSingleItemWindowAggregator /
//! newWindowAggregatorWithoutArguments, and the windowFuncs registration in
//! function_register.go / setupWindowFuncMap).
//!
//! Every window function from fn_window.zig is registered as
//! zigquery_window_<name> using SQLite's real window callbacks
//! (createWindowFunction: xStep/xInverse/xValue/xFinal). SQLite owns the
//! PARTITION BY / ORDER BY / frame machinery; each function only sees the
//! current frame's buffered values through a WindowFuncAggregatedStatus.
//!
//! Per-frame state lives behind sqlite3_aggregate_context exactly like the
//! GROUP BY aggregates: the context slot holds one ?*Group carrying its own
//! arena, the WindowFuncAggregatedStatus buffer and the function impl. What
//! differs from a plain aggregate:
//!   - xValue produces the current row's result (done()) WITHOUT tearing down.
//!   - xFinal ALSO produces done() (real SQLite uses xFinal's return as the
//!     row value for GROUPS/EXCLUDE-TIES frames, e.g. RANK/PERCENT_RANK) and
//!     THEN frees the Group and clears the slot. SQLite re-zeroes the aggregate
//!     context after every xFinal, so the next partition — or the next
//!     per-row recomputation under a GROUPS frame — starts from a fresh Group.
//! This matches Go creating a fresh WindowFuncAggregatedStatus + impl whenever
//! its state must reset across partitions/peer groups.
// ephor:ignore-file ZA103 ZA302

const std = @import("std");
const sqlite = @import("../../sqlite.zig");
const bind = @import("bind.zig");
const encoder = @import("../encoder.zig");
const agg_opt = @import("aggregate_option.zig");
const fns = @import("fn_window.zig");
const register = @import("register.zig");

const c = sqlite.c;
const Value = bind.Value;
const value_mod = bind.value_mod;
const State = register.State;
const WindowFuncAggregatedStatus = fns.WindowFuncAggregatedStatus;

/// Go windowFuncs table (function_register.go). Every entry is registered as
/// zigquery_window_<name>.
const WinEntry = struct {
    name: [:0]const u8,
    Impl: type,
};

const window_table = [_]WinEntry{
    // aggregate functions
    .{ .name = "any_value", .Impl = fns.WINDOW_ANY_VALUE },
    .{ .name = "array_agg", .Impl = fns.WINDOW_ARRAY_AGG },
    .{ .name = "avg", .Impl = fns.WINDOW_AVG },
    .{ .name = "count", .Impl = fns.WINDOW_COUNT },
    .{ .name = "count_star", .Impl = fns.WINDOW_COUNT_STAR },
    .{ .name = "countif", .Impl = fns.WINDOW_COUNTIF },
    .{ .name = "logical_and", .Impl = fns.WINDOW_LOGICAL_AND },
    .{ .name = "logical_or", .Impl = fns.WINDOW_LOGICAL_OR },
    .{ .name = "max", .Impl = fns.WINDOW_MAX },
    .{ .name = "min", .Impl = fns.WINDOW_MIN },
    .{ .name = "string_agg", .Impl = fns.WINDOW_STRING_AGG },
    .{ .name = "sum", .Impl = fns.WINDOW_SUM },

    // statistical aggregate functions (deferred: Done raises unimplemented)
    .{ .name = "corr", .Impl = fns.WINDOW_CORR },
    .{ .name = "covar_pop", .Impl = fns.WINDOW_COVAR_POP },
    .{ .name = "covar_samp", .Impl = fns.WINDOW_COVAR_SAMP },
    .{ .name = "stddev_pop", .Impl = fns.WINDOW_STDDEV_POP },
    .{ .name = "stddev_samp", .Impl = fns.WINDOW_STDDEV_SAMP },
    .{ .name = "stddev", .Impl = fns.WINDOW_STDDEV },
    .{ .name = "var_pop", .Impl = fns.WINDOW_VAR_POP },
    .{ .name = "var_samp", .Impl = fns.WINDOW_VAR_SAMP },
    .{ .name = "variance", .Impl = fns.WINDOW_VARIANCE },

    // navigation functions
    .{ .name = "first_value", .Impl = fns.WINDOW_FIRST_VALUE },
    .{ .name = "last_value", .Impl = fns.WINDOW_LAST_VALUE },
    .{ .name = "nth_value", .Impl = fns.WINDOW_NTH_VALUE },
    .{ .name = "lead", .Impl = fns.WINDOW_LEAD },
    .{ .name = "lag", .Impl = fns.WINDOW_LAG },
    .{ .name = "percentile_cont", .Impl = fns.WINDOW_PERCENTILE_CONT },
    .{ .name = "percentile_disc", .Impl = fns.WINDOW_PERCENTILE_DISC },

    // numbering functions
    .{ .name = "rank", .Impl = fns.WINDOW_RANK },
    .{ .name = "dense_rank", .Impl = fns.WINDOW_DENSE_RANK },
    .{ .name = "percent_rank", .Impl = fns.WINDOW_PERCENT_RANK },
    .{ .name = "cume_dist", .Impl = fns.WINDOW_CUME_DIST },
    .{ .name = "ntile", .Impl = fns.WINDOW_NTILE },
    .{ .name = "row_number", .Impl = fns.WINDOW_ROW_NUMBER },
};

/// Called from register.registerAll: the 35 window UDFs. Shares the connection
/// State (gpa for per-frame Groups; the scalar arena is unused here).
pub fn registerWindowFunctions(db: *sqlite.Db, state: *State) !void {
    inline for (window_table) |entry| {
        const W = WindowAggregator(entry.name, entry.Impl);
        try db.createWindowFunction(
            "zigquery_window_" ++ entry.name,
            -1,
            state,
            W.xStep,
            W.xFinal,
            W.xValue,
            W.xInverse,
        );
    }
}

// ----------------------------------------------------------------------
// Shared helpers (same shapes as aggregate.zig's private ones)
// ----------------------------------------------------------------------

fn decodeArgs(alloc: std.mem.Allocator, argv: [*c]?*c.sqlite3_value, n: usize) ![]Value {
    const args = try alloc.alloc(Value, n);
    for (0..n) |i| {
        args[i] = switch (sqlite.valueType(argv[i])) {
            .null => Value.null,
            .integer => Value{ .int = sqlite.valueInt64(argv[i]) },
            .float => Value{ .float = sqlite.valueDouble(argv[i]) },
            // TEXT has no engine meaning since storage format 3.
            .text => return error.CorruptData,
            .blob => try encoder.DecodeValue(alloc, .{ .blob = sqlite.valueBlob(argv[i]) }),
        };
    }
    return args;
}

/// register.zig's, which this file's State is (`const State = register.State`),
/// so the connection's one encode scratch buffer serves both. It matters most
/// here: `xValue` produces a result **per row**, and the arena this used to
/// encode into is released only at the end of the partition.
const setResult = register.setResult;

fn errorText(comptime name: []const u8, err: anyerror, buf: []u8) []const u8 {
    if (bind.message) |m| return m;
    if (value_mod.diagnostic) |m| return m;
    return std.fmt.bufPrint(buf, "zigquery_window_" ++ name ++ ": {s}", .{@errorName(err)}) catch name;
}

// ----------------------------------------------------------------------
// The WindowAggregator (Go WindowAggregator + the newXxxWindowAggregator
// constructors, dispatched at comptime on the Impl's shape).
// ----------------------------------------------------------------------

fn WindowAggregator(comptime name: [:0]const u8, comptime Impl: type) type {
    const mode: fns.WindowMode = if (@hasDecl(Impl, "window_mode")) Impl.window_mode else .single;
    const has_step = @hasDecl(Impl, "step");
    const has_inverse = @hasDecl(Impl, "inverse");
    const has_parse_args = @hasDecl(Impl, "parseArguments");

    return struct {
        /// Per-frame state. The aggregate context slot holds ?*Group
        /// (zero-initialized by sqlite3_aggregate_context on first use, and
        /// re-zeroed by SQLite after each xFinal).
        const Group = struct {
            /// Lives as long as the partition: the stepped values, and the aggregator's
            /// relevant-set cache over them.
            arena: std.heap.ArenaAllocator,
            /// Lives for one `xValue`. `done()` produces a value per row, and `setResult`
            /// encodes it into the connection's scratch buffer before returning, so nothing it
            /// allocates outlives the call.
            row_arena: std.heap.ArenaAllocator,
            agg: WindowFuncAggregatedStatus = .{},
            impl: Impl = .{},
            once: bool = false,
            failed: bool = false,
        };

        /// Creates the Group on first use (used by xStep/xInverse/xValue).
        fn getGroup(ctx: ?*c.sqlite3_context) ?*Group {
            const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
            const raw = sqlite.aggregateContext(ctx, @sizeOf(?*Group)) orelse return null;
            const slot: *?*Group = @ptrCast(@alignCast(raw));
            if (slot.* == null) {
                const group = state.gpa.create(Group) catch return null;
                group.* = .{
                    .arena = std.heap.ArenaAllocator.init(state.gpa),
                    .row_arena = std.heap.ArenaAllocator.init(state.gpa),
                };
                group.agg.cache_alloc = group.arena.allocator();
                slot.* = group;
            }
            return slot.*;
        }

        fn xStep(
            ctx: ?*c.sqlite3_context,
            argc: c_int,
            argv: [*c]?*c.sqlite3_value,
        ) callconv(.c) void {
            const group = getGroup(ctx) orelse {
                sqlite.resultError(ctx, "zigquery_window_" ++ name ++ ": out of memory");
                return;
            };
            if (group.failed) return;
            bind.clearDiagnostics();
            step(group, argv, @intCast(argc)) catch |err| {
                group.failed = true;
                var buf: [96]u8 = undefined;
                sqlite.resultError(ctx, errorText(name, err, &buf));
            };
        }

        fn step(group: *Group, argv: [*c]?*c.sqlite3_value, n: usize) !void {
            const alloc = group.arena.allocator();
            const args = try decodeArgs(alloc, argv, n);
            switch (mode) {
                .no_args => {
                    if (has_step) {
                        try group.impl.step(alloc, args, &group.agg);
                    } else {
                        try group.agg.step(alloc, .{ .int = 1 });
                    }
                },
                .single => {
                    const parsed = try agg_opt.parseAggregateOptions(alloc, args);
                    group.agg.setOption(parsed.opt.*);
                    if (!group.once) {
                        group.once = true;
                        if (has_parse_args) try group.impl.parseArguments(alloc, parsed.values);
                    }
                    if (has_step) {
                        try group.impl.step(alloc, parsed.values, &group.agg);
                    } else {
                        if (parsed.values.len < 1) {
                            return bind.fail("zigquery_window_" ++ name ++ ": invalid argument num", .{}, error.UnsupportedOperation);
                        }
                        try group.agg.step(alloc, parsed.values[0]);
                    }
                },
                // Go newTupleItemWindowAggregator: pack [x, y] (skip if either NULL).
                .tuple => {
                    const parsed = try agg_opt.parseAggregateOptions(alloc, args);
                    group.agg.setOption(parsed.opt.*);
                    if (parsed.values.len < 2) {
                        return bind.fail("must provide both x and y values", .{}, error.UnsupportedOperation);
                    }
                    const x = parsed.values[0];
                    const y = parsed.values[1];
                    if (x == .null or y == .null) return;
                    try group.agg.step(alloc, try value_mod.arrayValue(alloc, &.{ x, y }));
                },
            }
        }

        fn xInverse(
            ctx: ?*c.sqlite3_context,
            argc: c_int,
            argv: [*c]?*c.sqlite3_value,
        ) callconv(.c) void {
            const group = getGroup(ctx) orelse return;
            if (group.failed) return;
            bind.clearDiagnostics();
            inverse(group, argv, @intCast(argc)) catch |err| {
                group.failed = true;
                var buf: [96]u8 = undefined;
                sqlite.resultError(ctx, errorText(name, err, &buf));
            };
        }

        fn inverse(group: *Group, argv: [*c]?*c.sqlite3_value, n: usize) !void {
            const alloc = group.arena.allocator();
            const args = try decodeArgs(alloc, argv, n);
            if (has_inverse) {
                try group.impl.inverse(alloc, args, &group.agg);
                return;
            }
            switch (mode) {
                .no_args => try group.agg.inverse(.{ .int = 1 }),
                .single => {
                    if (args.len >= 1) try group.agg.inverse(args[0]);
                },
                // Go newTupleItemWindowAggregator inverse removes the oldest NULL
                // (never matches a buffered [x, y] array): a no-op in practice.
                .tuple => try group.agg.inverse(.null),
            }
        }

        /// Per-row value: done() over the current frame, no teardown.
        fn xValue(ctx: ?*c.sqlite3_context) callconv(.c) void {
            const group = getGroup(ctx) orelse {
                sqlite.resultError(ctx, "zigquery_window_" ++ name ++ ": out of memory");
                return;
            };
            if (group.failed) {
                sqlite.resultNull(ctx);
                return;
            }
            produce(ctx, group);
        }

        /// End of a partition (or a per-row recomputation under GROUPS/RANGE
        /// framing): produce done() — real SQLite uses this return value —
        /// then free the Group and clear the slot so the next frame starts
        /// fresh. SQLite re-zeroes the context after xFinal regardless.
        fn xFinal(ctx: ?*c.sqlite3_context) callconv(.c) void {
            // N==0: never allocates; NULL means xStep never ran for this frame.
            var slot: ?*?*Group = null;
            if (sqlite.aggregateContext(ctx, 0)) |raw| {
                slot = @ptrCast(@alignCast(raw));
            }
            const group: ?*Group = if (slot) |s| s.* else null;

            if (group) |g| {
                const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
                defer {
                    g.arena.deinit();
                    g.row_arena.deinit();
                    state.gpa.destroy(g);
                    if (slot) |s| s.* = null;
                }
                if (g.failed) {
                    sqlite.resultNull(ctx);
                    return;
                }
                produce(ctx, g);
            } else {
                // Empty frame that never stepped: done() on a fresh impl.
                const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
                var arena = std.heap.ArenaAllocator.init(state.gpa);
                defer arena.deinit();
                var fresh = Group{ .arena = undefined, .row_arena = undefined };
                fresh.agg.cache_alloc = arena.allocator();
                produceImpl(ctx, state, arena.allocator(), &fresh);
            }
        }

        fn produce(ctx: ?*c.sqlite3_context, group: *Group) void {
            const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
            _ = group.row_arena.reset(.retain_capacity);
            produceImpl(ctx, state, group.row_arena.allocator(), group);
        }

        fn produceImpl(
            ctx: ?*c.sqlite3_context,
            state: *State,
            alloc: std.mem.Allocator,
            group: *Group,
        ) void {
            bind.clearDiagnostics();
            const ret = group.impl.done(alloc, &group.agg) catch |err| {
                var buf: [96]u8 = undefined;
                sqlite.resultError(ctx, errorText(name, err, &buf));
                return;
            };
            setResult(ctx, state, ret) catch {
                sqlite.resultError(ctx, "zigquery_window_" ++ name ++ ": failed to encode value");
            };
        }
    };
}

// ----------------------------------------------------------------------
// Tests: hand-written SQL exactly as the transformer emits it (the
// zigquery_window_<name> calls plus the fixed frames from
// windowFuncFixedRanges / the user's frame). Values travel through the
// encoded representation just like the real pipeline.
// ----------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@import("fn_window.zig"));
}

const TestEnv = struct {
    arena: *std.heap.ArenaAllocator,
    db: sqlite.Db,

    fn init() !TestEnv {
        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        var db = try sqlite.Db.open(":memory:");
        errdefer db.close();
        _ = try register.registerAll(&db, arena.allocator());
        return .{ .arena = arena, .db = db };
    }

    fn deinit(env: *TestEnv) void {
        env.db.close();
        env.arena.deinit();
        testing.allocator.destroy(env.arena);
    }

    fn alloc(env: *TestEnv) std.mem.Allocator {
        return env.arena.allocator();
    }

    fn exec(env: *TestEnv, sql: [:0]const u8) !void {
        try env.db.exec(sql);
    }

    fn encStr(env: *TestEnv, s: []const u8) ![]u8 {
        // LiteralFromValue rather than quoting EncodeValue's output: it is the
        // one place that knows how each kind renders as SQL.
        return encoder.LiteralFromValue(env.alloc(), .{ .string = s });
    }

    /// Integer literal as the transformer emits it: EncodeValue maps INT64 to
    /// a native SQLite integer, so it is passed bare (not base64 text).
    fn encInt(env: *TestEnv, v: i64) ![]u8 {
        return std.fmt.allocPrint(env.alloc(), "{d}", .{v});
    }

    fn fmt(env: *TestEnv, comptime f: []const u8, args: anytype) ![:0]u8 {
        return std.fmt.allocPrintSentinel(env.alloc(), f, args, 0);
    }

    /// Collects the single result column of every row, decoding the encoded
    /// text back to a Value (native INTEGER/FLOAT pass straight through).
    fn column(env: *TestEnv, sql: []const u8) ![]Value {
        var stmt = try env.db.prepare(sql);
        defer stmt.finalize();
        var out: std.ArrayList(Value) = .empty;
        while (try stmt.step()) {
            const v: Value = switch (stmt.columnType(0)) {
                .integer => .{ .int = stmt.columnInt64(0) },
                .float => .{ .float = stmt.columnDouble(0) },
                .text => return error.NoRow,
                .blob => try encoder.DecodeValue(
                    env.alloc(),
                    .{ .blob = try env.alloc().dupe(u8, stmt.columnBlob(0)) },
                ),
                .null => .null,
            };
            try out.append(env.alloc(), v);
        }
        return out.toOwnedSlice(env.alloc());
    }

    fn expectInts(env: *TestEnv, expected: []const i64, sql: []const u8) !void {
        const got = try env.column(sql);
        try testing.expectEqual(expected.len, got.len);
        for (expected, got) |e, g| {
            try testing.expect(g == .int);
            try testing.expectEqual(e, g.int);
        }
    }

    fn expectFloats(env: *TestEnv, expected: []const f64, sql: []const u8) !void {
        const got = try env.column(sql);
        try testing.expectEqual(expected.len, got.len);
        for (expected, got) |e, g| {
            try testing.expect(g == .float);
            try testing.expectApproxEqAbs(e, g.float, 1e-9);
        }
    }
};

// The transformer emits each numbering/navigation function with the fixed
// frame from windowFuncFixedRanges; reproduce those frames verbatim here.
const F_ROW_NUMBER = "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW";
const F_RANK = "GROUPS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW EXCLUDE TIES";
const F_DENSE_RANK = "RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW";
const F_PERCENT_RANK = "GROUPS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING";
const F_CUME_DIST = "GROUPS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING";
const F_NTILE = "ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING";
const F_LAG = "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW";
const F_LEAD = "ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING";

test "row_number / rank / dense_rank with ties" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(v)");
    try env.exec("INSERT INTO t VALUES (10),(10),(20),(30),(40)");

    try env.expectInts(&.{ 1, 2, 3, 4, 5 }, "SELECT zigquery_window_row_number() OVER (ORDER BY v " ++ F_ROW_NUMBER ++ ") FROM t");
    try env.expectInts(&.{ 1, 1, 3, 4, 5 }, "SELECT zigquery_window_rank() OVER (ORDER BY v " ++ F_RANK ++ ") FROM t");
    try env.expectInts(&.{ 1, 1, 2, 3, 4 }, "SELECT zigquery_window_dense_rank() OVER (ORDER BY v " ++ F_DENSE_RANK ++ ") FROM t");
}

test "row_number / rank / dense_rank reset per PARTITION" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(p, v)");
    try env.exec("INSERT INTO t VALUES (1,10),(1,10),(1,20),(2,5),(2,6)");

    try env.expectInts(&.{ 1, 2, 3, 1, 2 }, "SELECT zigquery_window_row_number() OVER (PARTITION BY p ORDER BY v " ++ F_ROW_NUMBER ++ ") FROM t");
    try env.expectInts(&.{ 1, 1, 3, 1, 2 }, "SELECT zigquery_window_rank() OVER (PARTITION BY p ORDER BY v " ++ F_RANK ++ ") FROM t");
    try env.expectInts(&.{ 1, 1, 2, 1, 2 }, "SELECT zigquery_window_dense_rank() OVER (PARTITION BY p ORDER BY v " ++ F_DENSE_RANK ++ ") FROM t");
}

test "sum / count / avg over UNBOUNDED PRECEDING and sliding frames" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(v)");
    try env.exec("INSERT INTO t VALUES (1),(2),(3),(4)");

    // Running total.
    try env.expectInts(&.{ 1, 3, 6, 10 }, "SELECT zigquery_window_sum(v) OVER (ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t");
    // Running count.
    try env.expectInts(&.{ 1, 2, 3, 4 }, "SELECT zigquery_window_count(v) OVER (ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t");
    // Sliding sum over [1 PRECEDING, CURRENT ROW]: exercises xInverse.
    try env.expectInts(&.{ 1, 3, 5, 7 }, "SELECT zigquery_window_sum(v) OVER (ORDER BY v ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t");
    // Sliding avg over the same frame.
    try env.expectFloats(&.{ 1.0, 1.5, 2.5, 3.5 }, "SELECT zigquery_window_avg(v) OVER (ORDER BY v ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t");
}

test "max / min over sliding frame" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(v)");
    try env.exec("INSERT INTO t VALUES (3),(1),(4),(1),(5)");

    try env.expectInts(&.{ 3, 3, 4, 4, 5 }, "SELECT zigquery_window_max(v) OVER (ORDER BY (SELECT 0) ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t");
    try env.expectInts(&.{ 3, 1, 1, 1, 1 }, "SELECT zigquery_window_min(v) OVER (ORDER BY (SELECT 0) ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t");
}

test "lag / lead with defaults" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(v)");
    try env.exec("INSERT INTO t VALUES (10),(20),(30)");

    // LAG(v): previous row, NULL default at the first row.
    {
        const got = try env.column("SELECT zigquery_window_lag(v) OVER (ORDER BY v " ++ F_LAG ++ ") FROM t");
        try testing.expectEqual(@as(usize, 3), got.len);
        try testing.expect(got[0] == .null);
        try testing.expectEqual(@as(i64, 10), got[1].int);
        try testing.expectEqual(@as(i64, 20), got[2].int);
    }
    // LAG(v, 1, -1): explicit default.
    try env.expectInts(&.{ -1, 10, 20 }, try env.fmt(
        "SELECT zigquery_window_lag(v, {s}, {s}) OVER (ORDER BY v " ++ F_LAG ++ ") FROM t",
        .{ try env.encInt(1), try env.encInt(-1) },
    ));
    // LEAD(v): next row, NULL default at the last row.
    {
        const got = try env.column("SELECT zigquery_window_lead(v) OVER (ORDER BY v " ++ F_LEAD ++ ") FROM t");
        try testing.expectEqual(@as(usize, 3), got.len);
        try testing.expectEqual(@as(i64, 20), got[0].int);
        try testing.expectEqual(@as(i64, 30), got[1].int);
        try testing.expect(got[2] == .null);
    }
}

test "first_value / last_value / nth_value" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(v)");
    try env.exec("INSERT INTO t VALUES (10),(20),(30)");

    // FIRST_VALUE over the running frame stays 10.
    try env.expectInts(&.{ 10, 10, 10 }, "SELECT zigquery_window_first_value(v) OVER (ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t");
    // LAST_VALUE over the running frame tracks the current row.
    try env.expectInts(&.{ 10, 20, 30 }, "SELECT zigquery_window_last_value(v) OVER (ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t");
    // NTH_VALUE(v, 2) over the whole partition frame -> 20 everywhere.
    try env.expectInts(&.{ 20, 20, 20 }, try env.fmt(
        "SELECT zigquery_window_nth_value(v, {s}) OVER (ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM t",
        .{try env.encInt(2)},
    ));
}

test "ntile / percent_rank / cume_dist" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(v)");
    try env.exec("INSERT INTO t VALUES (10),(20),(30),(40)");

    // NTILE(2): two buckets over 4 rows -> 1,1,2,2.
    try env.expectInts(&.{ 1, 1, 2, 2 }, try env.fmt(
        "SELECT zigquery_window_ntile({s}) OVER (ORDER BY v " ++ F_NTILE ++ ") FROM t",
        .{try env.encInt(2)},
    ));
    // PERCENT_RANK over distinct values: (rank-1)/(n-1).
    try env.expectFloats(&.{ 0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0 }, "SELECT zigquery_window_percent_rank() OVER (ORDER BY v " ++ F_PERCENT_RANK ++ ") FROM t");
    // CUME_DIST over distinct values: k/n.
    try env.expectFloats(&.{ 0.25, 0.5, 0.75, 1.0 }, "SELECT zigquery_window_cume_dist() OVER (ORDER BY v " ++ F_CUME_DIST ++ ") FROM t");
}

test "partition boundary resets buffered aggregates" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(p, v)");
    try env.exec("INSERT INTO t VALUES (1,1),(1,2),(2,10),(2,20),(2,30)");

    // Running sum restarts at each partition.
    try env.expectInts(&.{ 1, 3, 10, 30, 60 }, "SELECT zigquery_window_sum(v) OVER (PARTITION BY p ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t");
    // Running count restarts too.
    try env.expectInts(&.{ 1, 2, 1, 2, 3 }, "SELECT zigquery_window_count(v) OVER (PARTITION BY p ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t");
}

test "statistical window functions (stddev / var / corr)" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(v)");
    try env.exec("INSERT INTO t VALUES (10),(14),(18)");

    // STDDEV_POP over the whole partition -> sqrt(32/3) = 3.2659863...
    try env.expectFloats(&.{ 3.265986323710904, 3.265986323710904, 3.265986323710904 }, "SELECT zigquery_window_stddev_pop(v) OVER () FROM t");
    // STDDEV_SAMP (== STDDEV) -> sqrt(32/2) = 4.
    try env.expectFloats(&.{ 4, 4, 4 }, "SELECT zigquery_window_stddev(v) OVER () FROM t");
    // VAR_POP -> 32/3, VAR_SAMP -> 16.
    try env.expectFloats(&.{ 10.666666666666666, 10.666666666666666, 10.666666666666666 }, "SELECT zigquery_window_var_pop(v) OVER () FROM t");
    try env.expectFloats(&.{ 16, 16, 16 }, "SELECT zigquery_window_var_samp(v) OVER () FROM t");

    // A single value yields NULL (Go: len(values) < 2).
    try env.exec("CREATE TABLE one(v)");
    try env.exec("INSERT INTO one VALUES (5)");
    const got = try env.column("SELECT zigquery_window_stddev(v) OVER () FROM one");
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(got[0] == .null);
}

test "corr window over packed [x, y] pairs" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.exec("CREATE TABLE t(y, x)");
    try env.exec("INSERT INTO t VALUES (1.0,5.0),(3.0,9.0),(4.0,7.0)");

    // The tuple aggregator packs (y, x) into a 2-element array per row; CORR is
    // symmetric so the result is Pearson's r ~= 0.6546536707079772.
    try env.expectFloats(
        &.{ 0.6546536707079772, 0.6546536707079772, 0.6546536707079772 },
        "SELECT zigquery_window_corr(y, x) OVER () FROM t",
    );
}
