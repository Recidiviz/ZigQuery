//! Port of go-zetasqlite's aggregate UDF framework (function_bind.go
//! Aggregator + newAggregator + setupAggregateFuncMap):
//!
//! - Every foundation aggregate from fn_aggregate.zig is registered as
//!   zigquery_<name> (Go setupAggregateFuncMap; aggregates have no safe_
//!   variants and window variants are a later milestone).
//! - The generic Aggregator step logic is shared: reject the rows DISTINCT has already
//!   taken, reading the arguments as SQLite stored them, then decode args, strip the option
//!   markers (aggregate_option.parseAggregateOptions), apply IGNORE NULLS filtering, and
//!   hand off to the impl.
//! - Per-group state lives behind sqlite3_aggregate_context: the context
//!   slot holds one pointer to a gpa-allocated Group carrying its own arena
//!   (decoded values must survive until xFinal). xFinal may run without any
//!   prior xStep (empty group): the result is then done() on a fresh impl.
//!
//! Also registers the six option marker producers (zigquery_distinct /
//! _limit / _order_by / _ignore_nulls / _having_max / _having_min) that Go
//! keeps in normalFuncs, including their safe_ twins.

const std = @import("std");
const sqlite = @import("../../sqlite.zig");
const bind = @import("bind.zig");
const encoder = @import("../encoder.zig");
const agg_opt = @import("aggregate_option.zig");
const fns = @import("fn_aggregate.zig");
const fhll = @import("fn_hll.zig");
const register = @import("register.zig");

const c = sqlite.c;
const Value = bind.Value;
const value_mod = bind.value_mod;
const State = register.State;

/// Go aggregateFuncs (foundation subset) — the "array" entry backs ARRAY
/// subqueries, the rest are the ordinary aggregate functions.
const AggEntry = struct {
    name: [:0]const u8,
    Impl: type,
};

const agg_table = [_]AggEntry{
    .{ .name = "array", .Impl = fns.ARRAY },
    .{ .name = "any_value", .Impl = fns.ANY_VALUE },
    .{ .name = "array_agg", .Impl = fns.ARRAY_AGG },
    .{ .name = "array_concat_agg", .Impl = fns.ARRAY_CONCAT_AGG },
    .{ .name = "avg", .Impl = fns.AVG },
    .{ .name = "count", .Impl = fns.COUNT },
    .{ .name = "count_star", .Impl = fns.COUNT_STAR },
    .{ .name = "bit_and", .Impl = fns.BIT_AND_AGG },
    .{ .name = "bit_or", .Impl = fns.BIT_OR_AGG },
    .{ .name = "bit_xor", .Impl = fns.BIT_XOR_AGG },
    .{ .name = "countif", .Impl = fns.COUNTIF },
    .{ .name = "logical_and", .Impl = fns.LOGICAL_AND },
    .{ .name = "logical_or", .Impl = fns.LOGICAL_OR },
    .{ .name = "max", .Impl = fns.MAX },
    .{ .name = "min", .Impl = fns.MIN },
    .{ .name = "string_agg", .Impl = fns.STRING_AGG },
    .{ .name = "sum", .Impl = fns.SUM },

    // statistical aggregate functions (Go aggregateFuncs)
    .{ .name = "corr", .Impl = fns.CORR },
    .{ .name = "covar_pop", .Impl = fns.COVAR_POP },
    .{ .name = "covar_samp", .Impl = fns.COVAR_SAMP },
    .{ .name = "stddev_pop", .Impl = fns.STDDEV_POP },
    .{ .name = "stddev_samp", .Impl = fns.STDDEV_SAMP },
    .{ .name = "stddev", .Impl = fns.STDDEV },
    .{ .name = "var_pop", .Impl = fns.VAR_POP },
    .{ .name = "var_samp", .Impl = fns.VAR_SAMP },
    .{ .name = "variance", .Impl = fns.VARIANCE },

    // approximate aggregate functions (Go aggregateFuncs)
    .{ .name = "approx_count_distinct", .Impl = fns.APPROX_COUNT_DISTINCT },
    .{ .name = "approx_quantiles", .Impl = fns.APPROX_QUANTILES },
    .{ .name = "approx_top_count", .Impl = fns.APPROX_TOP_COUNT },
    .{ .name = "approx_top_sum", .Impl = fns.APPROX_TOP_SUM },

    // HLL_COUNT.* (Go aggregateFuncs; the EXTRACT half is a scalar and
    // lives in bind.zig).
    .{ .name = "hll_count_init", .Impl = fhll.HLL_COUNT_INIT },
    .{ .name = "hll_count_merge", .Impl = fhll.HLL_COUNT_MERGE },
    .{ .name = "hll_count_merge_partial", .Impl = fhll.HLL_COUNT_MERGE_PARTIAL },
};

/// Called from register.registerAll: aggregate UDFs + the option marker
/// scalar functions. Shares the connection State (gpa + scalar arena).
pub fn registerAggregates(db: *sqlite.Db, state: *State) !void {
    inline for (agg_table) |entry| {
        const A = Aggregator(entry.name, entry.Impl);
        try db.createAggregateFunction(
            "zigquery_" ++ entry.name,
            -1,
            state,
            A.xStep,
            A.xFinal,
        );
    }

    // Option markers are plain scalar functions in Go's normalFuncs table,
    // so they get both zigquery_ and zigquery_safe_ names.
    inline for (agg_opt.option_func_table) |info| {
        const Tramp = struct {
            fn scalar(
                ctx: ?*c.sqlite3_context,
                argc: c_int,
                argv: [*c]?*c.sqlite3_value,
            ) callconv(.c) void {
                invokeOption(info, ctx, argc, argv);
            }
        };
        try db.createScalarFunction("zigquery_" ++ info.name, -1, state, Tramp.scalar, true);
        try db.createScalarFunction("zigquery_safe_" ++ info.name, -1, state, Tramp.scalar, true);
    }
}

// ----------------------------------------------------------------------
// Option marker scalar trampoline (mirror of register.zig's invoke; the
// markers never produce semantic errors that the safe_ path would mask).
// ----------------------------------------------------------------------

fn invokeOption(
    comptime info: bind.FuncInfo,
    ctx: ?*c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) void {
    const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
    _ = state.arena.reset(.retain_capacity);
    const alloc = state.arena.allocator();
    bind.clearDiagnostics();

    const args = decodeArgs(alloc, argv, @intCast(argc)) catch {
        sqlite.resultError(ctx, "zigquery_" ++ info.name ++ ": failed to decode value");
        return;
    };
    const ret = info.handler(alloc, args) catch |err| {
        var buf: [96]u8 = undefined;
        sqlite.resultError(ctx, errorText(info.name, err, &buf));
        return;
    };
    setResult(ctx, state, ret) catch {
        sqlite.resultError(ctx, "zigquery_" ++ info.name ++ ": failed to encode value");
    };
}

// ----------------------------------------------------------------------
// Shared helpers (same shapes as register.zig's private ones)
// ----------------------------------------------------------------------

/// Go convertArgs / DecodeValue over the raw sqlite3_value argv.
fn decodeArgs(
    alloc: std.mem.Allocator,
    argv: [*c]?*c.sqlite3_value,
    n: usize,
) ![]Value {
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

/// The option kind an argument carries, or null for an ordinary value.
fn markerKind(v: ?*c.sqlite3_value) ?agg_opt.Kind {
    if (sqlite.valueType(v) != .blob) return null;
    return agg_opt.rawMarkerKind(sqlite.valueBlob(v));
}

/// Appends a key equal for exactly the values DISTINCT puts in one group, taken from the
/// argument as SQLite stored it.
///
/// The storage encoding is canonical — one value has one byte string, per kind — so two
/// arguments can be compared without decoding either. The leading discriminator separates the
/// storage classes on their own terms rather than resting on an argument having one static
/// type.
///
/// Signed zero is the one value the stored bytes cannot answer for: 0.0 and -0.0 are one group
/// (data-types.md#grouping-with-floating-point-types) and two bit patterns. NaN needs no arm,
/// arriving as NULL.
fn appendDistinctKey(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    v: ?*c.sqlite3_value,
) !void {
    switch (sqlite.valueType(v)) {
        .null => try buf.append(alloc, 0),
        .integer => {
            try buf.append(alloc, 1);
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, sqlite.valueInt64(v), .little);
            try buf.appendSlice(alloc, &b);
        },
        .float => {
            try buf.append(alloc, 2);
            const f = sqlite.valueDouble(v);
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @bitCast(if (f == 0) @as(f64, 0) else f), .little);
            try buf.appendSlice(alloc, &b);
        },
        .blob => {
            try buf.append(alloc, 3);
            try buf.appendSlice(alloc, sqlite.valueBlob(v));
        },
        // TEXT has no engine meaning since storage format 3.
        .text => return error.CorruptData,
    }
}

/// register.zig's, which this file's State is (`const State = register.State`),
/// so the connection's one encode scratch buffer serves both.
const setResult = register.setResult;

fn errorText(comptime name: []const u8, err: anyerror, buf: []u8) []const u8 {
    if (bind.message) |m| return m;
    if (value_mod.diagnostic) |m| return m;
    return std.fmt.bufPrint(buf, "zigquery_" ++ name ++ ": {s}", .{@errorName(err)}) catch name;
}

// ----------------------------------------------------------------------
// The Aggregator (Go Aggregator struct + newAggregator)
// ----------------------------------------------------------------------

fn Aggregator(comptime name: [:0]const u8, comptime Impl: type) type {
    return struct {
        /// Per-group state. The aggregate context slot holds ?*Group
        /// (zero-initialized by sqlite3_aggregate_context on first use).
        const Group = struct {
            arena: std.heap.ArenaAllocator,
            /// Keyed by `appendDistinctKey`, which spells NULL as a key like any other value.
            distinct_map: std.StringHashMapUnmanaged(void) = .empty,
            /// Built per row and handed to the map as a borrowed slice; the map takes its own
            /// copy only for a value it has not seen.
            distinct_key: std.ArrayList(u8) = .empty,
            failed: bool = false,
            impl: Impl = .{},
        };

        fn xStep(
            ctx: ?*c.sqlite3_context,
            argc: c_int,
            argv: [*c]?*c.sqlite3_value,
        ) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
            const raw = sqlite.aggregateContext(ctx, @sizeOf(?*Group)) orelse {
                sqlite.resultError(ctx, "zigquery_" ++ name ++ ": out of memory");
                return;
            };
            const slot: *?*Group = @ptrCast(@alignCast(raw));
            if (slot.* == null) {
                const group = state.gpa.create(Group) catch {
                    sqlite.resultError(ctx, "zigquery_" ++ name ++ ": out of memory");
                    return;
                };
                group.* = .{ .arena = std.heap.ArenaAllocator.init(state.gpa) };
                slot.* = group;
            }
            const group = slot.*.?;
            if (group.failed) return;

            bind.clearDiagnostics();
            step(group, argv, @intCast(argc)) catch |err| {
                group.failed = true;
                var buf: [96]u8 = undefined;
                sqlite.resultError(ctx, errorText(name, err, &buf));
            };
        }

        /// Go Aggregator.Step.
        fn step(group: *Group, argv: [*c]?*c.sqlite3_value, n: usize) !void {
            const alloc = group.arena.allocator();
            // A row DISTINCT has seen before contributes nothing, and deciding that from the
            // stored bytes means it never has to be decoded.
            if (try seenBefore(group, argv, n)) return;
            const args = try decodeArgs(alloc, argv, n);
            const parsed = try agg_opt.parseAggregateOptions(alloc, args);
            var values = parsed.values;
            const opt = parsed.opt;

            if (opt.ignore_nulls) {
                var kept: usize = 0;
                for (values) |v| {
                    if (v == .null) continue;
                    values[kept] = v;
                    kept += 1;
                }
                values = values[0..kept];
                if (values.len == 0) return;
            }

            if (opt.distinct and values.len < 1) {
                return bind.fail(
                    "DISTINCT option required at least one argument",
                    .{},
                    error.UnsupportedOperation,
                );
            }

            try group.impl.step(alloc, values, opt);
        }

        /// Whether DISTINCT has already taken a row with this value, decided from the arguments
        /// as SQLite stored them. Records the value when it has not.
        ///
        /// The value slot is picked the way the decoded path picks `values[0]`: the first
        /// argument that is not an option marker, skipping NULLs under IGNORE NULLS. An
        /// argument list with no value slot falls through to the decoded path, which owns the
        /// diagnostics for it.
        fn seenBefore(group: *Group, argv: [*c]?*c.sqlite3_value, n: usize) !bool {
            var distinct = false;
            var ignore_nulls = false;
            var first: ?usize = null;
            var first_non_null: ?usize = null;
            for (0..n) |i| {
                if (markerKind(argv[i])) |kind| {
                    switch (kind) {
                        .distinct => distinct = true,
                        .ignore_nulls => ignore_nulls = true,
                        else => {},
                    }
                    continue;
                }
                if (first == null) first = i;
                if (first_non_null == null and sqlite.valueType(argv[i]) != .null) {
                    first_non_null = i;
                }
            }
            if (!distinct) return false;
            const slot = (if (ignore_nulls) first_non_null else first) orelse return false;

            const alloc = group.arena.allocator();
            group.distinct_key.clearRetainingCapacity();
            try appendDistinctKey(&group.distinct_key, alloc, argv[slot]);
            const gop = try group.distinct_map.getOrPut(alloc, group.distinct_key.items);
            if (gop.found_existing) return true;
            gop.key_ptr.* = try alloc.dupe(u8, group.distinct_key.items);
            return false;
        }

        fn xFinal(ctx: ?*c.sqlite3_context) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
            // N == 0: never allocates; NULL means xStep never ran (empty
            // group) and done() must still produce the zero-row result.
            var group: ?*Group = null;
            if (sqlite.aggregateContext(ctx, 0)) |raw| {
                group = @as(*?*Group, @ptrCast(@alignCast(raw))).*;
            }

            if (group) |g| {
                defer {
                    g.arena.deinit();
                    state.gpa.destroy(g);
                }
                if (g.failed) {
                    // xStep already reported through sqlite3_result_error.
                    sqlite.resultNull(ctx);
                    return;
                }
                finish(ctx, state, g.arena.allocator(), &g.impl);
            } else {
                var arena = std.heap.ArenaAllocator.init(state.gpa);
                defer arena.deinit();
                var impl: Impl = .{};
                finish(ctx, state, arena.allocator(), &impl);
            }
        }

        fn finish(
            ctx: ?*c.sqlite3_context,
            state: *State,
            alloc: std.mem.Allocator,
            impl: *Impl,
        ) void {
            bind.clearDiagnostics();
            const ret = impl.done(alloc) catch |err| {
                var buf: [96]u8 = undefined;
                sqlite.resultError(ctx, errorText(name, err, &buf));
                return;
            };
            setResult(ctx, state, ret) catch {
                sqlite.resultError(ctx, "zigquery_" ++ name ++ ": failed to encode value");
            };
        }
    };
}

// ----------------------------------------------------------------------
// Tests: raw SQLite SQL against the registered UDFs (values travel through
// the encoded representation exactly as the transformer would emit them).
// ----------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@import("aggregate_option.zig"));
    testing.refAllDecls(@import("fn_aggregate.zig"));
    testing.refAllDecls(@import("fn_hll.zig"));
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

    fn queryValue(env: *TestEnv, sql: []const u8) !Value {
        var stmt = try env.db.prepare(sql);
        defer stmt.finalize();
        if (!try stmt.step()) return error.NoRow;
        return switch (stmt.columnType(0)) {
            .integer => Value{ .int = stmt.columnInt64(0) },
            .float => Value{ .float = stmt.columnDouble(0) },
            .text => return error.NoRow,
            .blob => blk: {
                const b = try env.alloc().dupe(u8, stmt.columnBlob(0));
                break :blk try encoder.DecodeValue(env.alloc(), .{ .blob = b });
            },
            .null => Value.null,
        };
    }

    fn expectInt(env: *TestEnv, expected: i64, sql: []const u8) !void {
        try value_mod.expectValueEqual(.{ .int = expected }, try env.queryValue(sql));
    }

    fn expectFloat(env: *TestEnv, expected: f64, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try testing.expect(v == .float);
        try testing.expectApproxEqAbs(expected, v.float, 1e-12);
    }

    fn expectNullResult(env: *TestEnv, sql: []const u8) !void {
        try testing.expect(try env.queryValue(sql) == .null);
    }

    fn expectStringResult(env: *TestEnv, expected: []const u8, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try testing.expect(v == .string);
        try testing.expectEqualStrings(expected, v.string);
    }

    fn expectErrorMsg(env: *TestEnv, expected_substr: []const u8, sql: []const u8) !void {
        var stmt = try env.db.prepare(sql);
        defer stmt.finalize();
        var failed = false;
        while (true) {
            const has_row = stmt.step() catch {
                failed = true;
                break;
            };
            if (!has_row) break;
        }
        if (!failed) return error.TestUnexpectedResult;
        const msg = env.db.errmsg();
        if (std.mem.indexOf(u8, msg, expected_substr) == null) {
            std.debug.print("expected error containing \"{s}\", got \"{s}\"\n", .{ expected_substr, msg });
            return error.TestUnexpectedResult;
        }
    }

    fn enc(env: *TestEnv, v: Value) ![]u8 {
        // LiteralFromValue rather than quoting EncodeValue's output: it is the
        // one place that knows how each kind renders as SQL.
        return encoder.LiteralFromValue(env.alloc(), v);
    }

    fn encStr(env: *TestEnv, s: []const u8) ![]u8 {
        return env.enc(.{ .string = s });
    }

    fn fmt(env: *TestEnv, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(env.alloc(), f, args);
    }
};

test "sum/avg/count/countif over a table" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(x)");
    try env.exec("INSERT INTO t VALUES (1),(2),(NULL),(3)");

    try env.expectInt(6, "SELECT zigquery_sum(x) FROM t");
    try env.expectFloat(2.0, "SELECT zigquery_avg(x) FROM t");
    try env.expectInt(3, "SELECT zigquery_count(x) FROM t");
    try env.expectInt(4, "SELECT zigquery_count_star() FROM t");
    try env.expectInt(2, "SELECT zigquery_countif(zigquery_greater_or_equal(x, 2)) FROM t");

    // Float inputs keep float results; int-only SUM stays INTEGER.
    try env.exec("CREATE TABLE tf(x)");
    try env.exec("INSERT INTO tf VALUES (1.5),(2.0)");
    try env.expectFloat(3.5, "SELECT zigquery_sum(x) FROM tf");
}

test "empty and all-NULL groups are NULL" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE empty_t(x)");
    // Empty input: xFinal runs without xStep.
    try env.expectNullResult("SELECT zigquery_sum(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_avg(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_max(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_min(x) FROM empty_t");
    try env.expectInt(0, "SELECT zigquery_count(x) FROM empty_t");
    try env.expectInt(0, "SELECT zigquery_count_star() FROM empty_t");
    try env.expectNullResult("SELECT zigquery_string_agg(x) FROM empty_t");
    // These returned Go's in-band sentinels (true/false/-1/-1/1/[]) until the
    // "unset" marker moved out of band. BigQuery returns NULL for all of them;
    // see the header of fn_aggregate.zig.
    try env.expectNullResult("SELECT zigquery_logical_and(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_logical_or(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_bit_and(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_bit_or(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_bit_xor(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_array_agg(x) FROM empty_t");
    try env.expectNullResult("SELECT zigquery_array_concat_agg(x) FROM empty_t");

    // All-NULL input behaves the same for the NULL-skipping aggregates.
    try env.exec("CREATE TABLE null_t(x)");
    try env.exec("INSERT INTO null_t VALUES (NULL),(NULL)");
    try env.expectNullResult("SELECT zigquery_sum(x) FROM null_t");
    try env.expectInt(0, "SELECT zigquery_count(x) FROM null_t");
    try env.expectInt(2, "SELECT zigquery_count_star() FROM null_t");
    try env.expectNullResult("SELECT zigquery_any_value(x) FROM null_t");
    // All-NULL reaches done() by a different route than the empty group above
    // — step runs but returns early — so assert it separately. BigQuery gives
    // NULL for both.
    try env.expectNullResult("SELECT zigquery_bit_and(x) FROM null_t");
    try env.expectNullResult("SELECT zigquery_bit_or(x) FROM null_t");
    try env.expectNullResult("SELECT zigquery_bit_xor(x) FROM null_t");
    try env.expectNullResult("SELECT zigquery_logical_and(x) FROM null_t");
    try env.expectNullResult("SELECT zigquery_logical_or(x) FROM null_t");
}

test "max/min/any_value over ints, strings and dates" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(x)");
    try env.exec("INSERT INTO t VALUES (3),(NULL),(1),(2)");
    try env.expectInt(3, "SELECT zigquery_max(x) FROM t");
    try env.expectInt(1, "SELECT zigquery_min(x) FROM t");
    try env.expectInt(3, "SELECT zigquery_any_value(x) FROM t");

    try env.exec("CREATE TABLE ts(s)");
    try env.exec(try env.alloc().dupeZ(u8, try env.fmt(
        "INSERT INTO ts VALUES ({s}),({s}),({s})",
        .{ try env.encStr("pear"), try env.encStr("apple"), try env.encStr("fig") },
    )));
    try env.expectStringResult("pear", "SELECT zigquery_max(s) FROM ts");
    try env.expectStringResult("apple", "SELECT zigquery_min(s) FROM ts");

    try env.exec("CREATE TABLE td(d)");
    const d1 = try env.enc(.{ .date = try value_mod.parseDateDays("2021-06-15") });
    const d2 = try env.enc(.{ .date = try value_mod.parseDateDays("2020-01-01") });
    try env.exec(try env.alloc().dupeZ(u8, try env.fmt(
        "INSERT INTO td VALUES ({s}),({s})",
        .{ d1, d2 },
    )));
    try value_mod.expectValueEqual(
        .{ .date = try value_mod.parseDateDays("2020-01-01") },
        try env.queryValue("SELECT zigquery_min(d) FROM td"),
    );
}

test "logical_and/logical_or and bit aggregates" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(b)");
    try env.exec("INSERT INTO t VALUES (1),(1),(NULL)");
    try value_mod.expectValueEqual(.{ .int = 1 }, try env.queryValue("SELECT zigquery_logical_and(b) FROM t"));
    try value_mod.expectValueEqual(.{ .int = 1 }, try env.queryValue("SELECT zigquery_logical_or(b) FROM t"));
    try env.exec("INSERT INTO t VALUES (0)");
    try value_mod.expectValueEqual(.{ .int = 0 }, try env.queryValue("SELECT zigquery_logical_and(b) FROM t"));
    try value_mod.expectValueEqual(.{ .int = 1 }, try env.queryValue("SELECT zigquery_logical_or(b) FROM t"));

    try env.exec("CREATE TABLE bits(x)");
    try env.exec("INSERT INTO bits VALUES (12),(10),(NULL)");
    try env.expectInt(8, "SELECT zigquery_bit_and(x) FROM bits");
    try env.expectInt(14, "SELECT zigquery_bit_or(x) FROM bits");
    try env.expectInt(6, "SELECT zigquery_bit_xor(x) FROM bits");
}

test "distinct dedup including NULL handling" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(x)");
    try env.exec("INSERT INTO t VALUES (1),(1),(2),(2),(3),(NULL),(NULL)");
    try env.expectInt(6, "SELECT zigquery_sum(x, zigquery_distinct()) FROM t");
    try env.expectInt(3, "SELECT zigquery_count(x, zigquery_distinct()) FROM t");
    // Plain (non-distinct) for contrast.
    try env.expectInt(9, "SELECT zigquery_sum(x) FROM t");

    // DISTINCT over strings dedups on decoded content.
    try env.exec("CREATE TABLE ts(s)");
    try env.exec(try env.alloc().dupeZ(u8, try env.fmt(
        "INSERT INTO ts VALUES ({s}),({s}),({s})",
        .{ try env.encStr("a"), try env.encStr("a"), try env.encStr("b") },
    )));
    try env.expectInt(2, "SELECT zigquery_count(s, zigquery_distinct()) FROM ts");
}

test "array_agg with order_by/limit/ignore_nulls markers" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(x)");
    try env.exec("INSERT INTO t VALUES (2),(3),(1)");

    // ORDER BY x ASC.
    {
        const v = try env.queryValue(
            "SELECT zigquery_array_agg(x, zigquery_order_by(x, 1)) FROM t",
        );
        try testing.expectEqual(@as(usize, 3), v.array.values.len);
        try value_mod.expectValueEqual(.{ .int = 1 }, v.array.values[0]);
        try value_mod.expectValueEqual(.{ .int = 2 }, v.array.values[1]);
        try value_mod.expectValueEqual(.{ .int = 3 }, v.array.values[2]);
    }
    // ORDER BY x DESC LIMIT 2.
    {
        const v = try env.queryValue(
            "SELECT zigquery_array_agg(x, zigquery_order_by(x, 0), zigquery_limit(2)) FROM t",
        );
        try testing.expectEqual(@as(usize, 2), v.array.values.len);
        try value_mod.expectValueEqual(.{ .int = 3 }, v.array.values[0]);
        try value_mod.expectValueEqual(.{ .int = 2 }, v.array.values[1]);
    }

    // NULL input errors without IGNORE NULLS, passes with it.
    try env.exec("INSERT INTO t VALUES (NULL)");
    try env.expectErrorMsg(
        "ARRAY_AGG: input value must be not null",
        "SELECT zigquery_array_agg(x) FROM t",
    );
    {
        const v = try env.queryValue(
            "SELECT zigquery_array_agg(x, zigquery_ignore_nulls()) FROM t",
        );
        try testing.expectEqual(@as(usize, 3), v.array.values.len);
    }
}

test "array_concat_agg flattens element arrays" {
    var env = try TestEnv.init();
    defer env.deinit();

    const a1 = try env.enc(try value_mod.arrayValue(env.alloc(), &.{
        Value{ .int = 1 }, Value{ .int = 2 },
    }));
    const a2 = try env.enc(try value_mod.arrayValue(env.alloc(), &.{
        Value{ .int = 3 },
    }));
    try env.exec("CREATE TABLE t(a)");
    try env.exec(try env.alloc().dupeZ(u8, try env.fmt(
        "INSERT INTO t VALUES ({s}),(NULL),({s})",
        .{ a1, a2 },
    )));

    const v = try env.queryValue("SELECT zigquery_array_concat_agg(a) FROM t");
    try testing.expectEqual(@as(usize, 3), v.array.values.len);
    try value_mod.expectValueEqual(.{ .int = 1 }, v.array.values[0]);
    try value_mod.expectValueEqual(.{ .int = 3 }, v.array.values[2]);
}

test "string_agg default and custom delimiters, order and limit" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(s)");
    try env.exec(try env.alloc().dupeZ(u8, try env.fmt(
        "INSERT INTO t VALUES ({s}),({s}),(NULL),({s})",
        .{ try env.encStr("b"), try env.encStr("a"), try env.encStr("c") },
    )));

    try env.expectStringResult("b,a,c", "SELECT zigquery_string_agg(s) FROM t");
    try env.expectStringResult("b-a-c", try env.fmt(
        "SELECT zigquery_string_agg(s, {s}) FROM t",
        .{try env.encStr("-")},
    ));
    try env.expectStringResult("a,b,c", "SELECT zigquery_string_agg(s, zigquery_order_by(s, 1)) FROM t");
    try env.expectStringResult("c,b", "SELECT zigquery_string_agg(s, zigquery_order_by(s, 0), zigquery_limit(2)) FROM t");
}

test "any_value having max/min markers" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(name, score)");
    try env.exec(try env.alloc().dupeZ(u8, try env.fmt(
        "INSERT INTO t VALUES ({s}, 10),({s}, 30),({s}, 20)",
        .{ try env.encStr("low"), try env.encStr("high"), try env.encStr("mid") },
    )));

    try env.expectStringResult(
        "high",
        "SELECT zigquery_any_value(name, zigquery_having_max(score)) FROM t",
    );
    try env.expectStringResult(
        "low",
        "SELECT zigquery_any_value(name, zigquery_having_min(score)) FROM t",
    );
}

test "aggregates work per group with GROUP BY" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(g, x)");
    try env.exec("INSERT INTO t VALUES (1, 10),(1, 20),(2, 5),(2, NULL)");

    var stmt = try env.db.prepare(
        "SELECT zigquery_group_by(g), zigquery_sum(x), zigquery_count(x) FROM t GROUP BY zigquery_group_by(g) ORDER BY 1",
    );
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 1), stmt.columnInt64(0));
    try testing.expectEqual(@as(i64, 30), stmt.columnInt64(1));
    try testing.expectEqual(@as(i64, 2), stmt.columnInt64(2));
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 2), stmt.columnInt64(0));
    try testing.expectEqual(@as(i64, 5), stmt.columnInt64(1));
    try testing.expectEqual(@as(i64, 1), stmt.columnInt64(2));
    try testing.expect(!try stmt.step());
}

test "distinct combined with order_by and limit" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.exec("CREATE TABLE t(x)");
    try env.exec("INSERT INTO t VALUES (2),(2),(1),(3),(1)");

    const v = try env.queryValue(
        "SELECT zigquery_array_agg(x, zigquery_distinct(), zigquery_order_by(x, 1), zigquery_limit(2)) FROM t",
    );
    try testing.expectEqual(@as(usize, 2), v.array.values.len);
    try value_mod.expectValueEqual(.{ .int = 1 }, v.array.values[0]);
    try value_mod.expectValueEqual(.{ .int = 2 }, v.array.values[1]);
}
