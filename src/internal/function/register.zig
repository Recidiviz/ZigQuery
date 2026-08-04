//! Port of go-zetasqlite internal/function_register.go (foundation scope):
//! registers every FuncInfo from bind.zig as the pair
//!   zetasqlite_<name>      (errors -> SQL error, Go BindFunc path)
//!   zetasqlite_safe_<name> (handler errors -> NULL, Go SafeFunc path;
//!                           argument decode / result encode errors still
//!                           raise, exactly like Go's safe wrapper)
//! plus the specials zetasqlite_group_by and the zetasqlite_unnest table-valued
//! function.

const std = @import("std");
const sqlite = @import("../../sqlite.zig");
const bind = @import("bind.zig");
const encoder = @import("../encoder.zig");
const codec_binary = @import("../codec_binary.zig");
const phase = @import("../phase.zig");
const value_mod = bind.value_mod;

const c = sqlite.c;
const Value = bind.Value;

/// Per-connection UDF state: a retained arena reset at the start of every
/// scalar call (Go relies on the GC instead). Lives until the allocator that
/// created it is torn down (Go's registration is process-lifetime too).
pub const State = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Buffer every encoded result is built in, reused for the life of the
    /// connection. Shared by the scalar, aggregate and window trampolines —
    /// they alias this State — which is safe because a connection is
    /// single-threaded and each of them hands the bytes to SQLite (which
    /// copies) before the next value is encoded. See `encoder.Scratch`.
    scratch: encoder.Scratch,
    /// Catalog snapshot for the INFORMATION_SCHEMA vtabs, published by the
    /// driver before each statement. Kept here rather than read from the
    /// catalog inside the vtab because those callbacks run inside
    /// sqlite3_step, where taking the catalog lock would invert the ordering
    /// shared_catalog.zig requires.
    info_schema: info_schema_vtab.SharedState = .{},

    pub fn deinit(state: *State) void {
        const gpa = state.gpa;
        state.scratch.deinit();
        state.arena.deinit();
        gpa.destroy(state);
    }
};

/// Registers all foundation scalar functions + specials on `db`. The returned
/// State must outlive the connection; free it with State.deinit after the
/// sqlite db is closed.
pub fn registerAll(db: *sqlite.Db, gpa: std.mem.Allocator) !*State {
    const state = try gpa.create(State);
    errdefer gpa.destroy(state);
    state.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .scratch = encoder.Scratch.init(gpa),
    };

    inline for (bind.func_table) |info| {
        const Tramp = struct {
            fn normal(
                ctx: ?*c.sqlite3_context,
                argc: c_int,
                argv: [*c]?*c.sqlite3_value,
            ) callconv(.c) void {
                invoke(info, false, ctx, argc, argv);
            }
            fn safe(
                ctx: ?*c.sqlite3_context,
                argc: c_int,
                argv: [*c]?*c.sqlite3_value,
            ) callconv(.c) void {
                invoke(info, true, ctx, argc, argv);
            }
        };
        try db.createScalarFunction("zetasqlite_" ++ info.name, -1, state, Tramp.normal, info.deterministic);
        try db.createScalarFunction("zetasqlite_safe_" ++ info.name, -1, state, Tramp.safe, info.deterministic);
    }

    try unnest_vtab.register(db, gpa);
    try info_schema_vtab.register(db, gpa, &state.info_schema);
    try db.createScalarFunction("zetasqlite_group_by", -1, state, groupByTramp, true);

    // Aggregate UDFs + option marker functions (Go: aggregateFuncs plus the
    // distinct/limit/order_by/ignore_nulls/having_* normalFuncs entries).
    try aggregate.registerAggregates(db, state);

    // Window UDFs (Go: windowFuncs / setupWindowFuncMap), registered as
    // zetasqlite_window_<name> with SQLite's real window callbacks.
    try window.registerWindowFunctions(db, state);
    return state;
}

const aggregate = @import("aggregate.zig");
const window = @import("window.zig");
const unnest_vtab = @import("unnest_vtab.zig");
pub const info_schema_vtab = @import("info_schema_vtab.zig");

// ----------------------------------------------------------------------
// Generic scalar trampoline (Go setupNormalFuncMap closure equivalent)
// ----------------------------------------------------------------------

fn invoke(
    comptime info: bind.FuncInfo,
    comptime safe: bool,
    ctx: ?*c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) void {
    const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
    _ = state.arena.reset(.retain_capacity);
    const alloc = state.arena.allocator();
    bind.clearDiagnostics();
    // Lets a handler cache work derived from a constant argument against this
    // call site; see bind.auxGet.
    bind.current_ctx = ctx;
    defer bind.current_ctx = null;

    const n: usize = @intCast(argc);
    if (n < info.min_args) {
        sqlite.resultError(ctx, "zetasqlite_" ++ info.name ++ ": invalid argument num");
        return;
    }

    const args = decodeArgs(
        alloc,
        ctx,
        comptime info.cached_args,
        comptime info.raw_args,
        argv,
        n,
    ) catch {
        sqlite.resultError(ctx, "zetasqlite_" ++ info.name ++ ": failed to decode value");
        return;
    };

    const handler = comptime if (safe) (info.safe_handler orelse info.handler) else info.handler;
    const ret = handler(alloc, args) catch |err| {
        if (safe) {
            // Go safe wrapper: semantic errors from the bind func -> NULL.
            sqlite.resultNull(ctx);
            return;
        }
        var buf: [96]u8 = undefined;
        sqlite.resultError(ctx, errorText(info.name, err, &buf));
        return;
    };
    setResult(ctx, state, ret) catch {
        sqlite.resultError(ctx, "zetasqlite_" ++ info.name ++ ": failed to encode value");
    };
}

/// Go convertArgs: driver.Value slice -> DecodeValue'd Values. Native
/// INTEGER/FLOAT pass through; every other kind arrives as an encoded BLOB.
fn decodeArgs(
    alloc: std.mem.Allocator,
    ctx: ?*c.sqlite3_context,
    comptime cached_args: u8,
    comptime raw_args: u8,
    argv: [*c]?*c.sqlite3_value,
    n: usize,
) ![]Value {
    const args = try alloc.alloc(Value, n);
    for (0..n) |i| {
        // An argument the handler has already digested and cached against this
        // call site is never read, so decoding it is pure waste — and for
        // CAST's type documents that waste is two codec round trips per row.
        if (cached_args != 0 and i < 8 and (cached_args >> @intCast(i)) & 1 == 1) {
            if (sqlite.getAuxdata(ctx, @intCast(i)) != null) {
                args[i] = Value.null;
                continue;
            }
        }
        const wants_raw = raw_args != 0 and i < 8 and (raw_args >> @intCast(i)) & 1 == 1;
        args[i] = switch (sqlite.valueType(argv[i])) {
            .null => Value.null,
            .integer => Value{ .int = sqlite.valueInt64(argv[i]) },
            .float => Value{ .float = sqlite.valueDouble(argv[i]) },
            // TEXT has no engine meaning since storage format 3.
            .text => return error.CorruptData,
            // A handler that asked for this argument raw reads one entry out of
            // it and would throw the rest of the decode away; see
            // `bind.FuncInfo.raw_args`.
            .blob => if (wants_raw)
                Value{ .bytes = sqlite.valueBlob(argv[i]) }
            else
                try encoder.DecodeValueBorrowing(
                    alloc,
                    .{ .blob = sqlite.valueBlob(argv[i]) },
                ),
        };
    }
    return args;
}

/// The one encode-and-return path, shared with aggregate.zig and window.zig
/// (both alias this State). Encodes into the connection's scratch buffer rather
/// than an arena: SQLite copies the bytes here, so nothing needs to own them.
pub fn setResult(ctx: ?*c.sqlite3_context, state: *State, v: Value) !void {
    try encoder.encodeTo(sqlite.ResultSink{ .ctx = ctx }, &state.scratch, v);
}

/// Error text priority: the handler's formatted message, then value.zig's
/// static diagnostic, then a generic "zetasqlite_<name>: <ErrorName>".
fn errorText(comptime name: []const u8, err: anyerror, buf: []u8) []const u8 {
    if (bind.message) |m| return m;
    if (value_mod.diagnostic) |m| return m;
    return std.fmt.bufPrint(buf, "zetasqlite_" ++ name ++ ": {s}", .{@errorName(err)}) catch name;
}

// ----------------------------------------------------------------------
// zetasqlite_group_by: structs/arrays flatten to "elem||elem||..." (their
// elements' ToString); scalars pass through as their native representation
// (Go decoded.Interface()).
// ----------------------------------------------------------------------

fn groupByTramp(
    ctx: ?*c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
    _ = state.arena.reset(.retain_capacity);
    const alloc = state.arena.allocator();
    bind.clearDiagnostics();

    if (argc < 1) {
        sqlite.resultError(ctx, "zetasqlite_group_by: invalid argument num");
        return;
    }
    groupByImpl(ctx, alloc, argv[0]) catch |err| {
        var buf: [96]u8 = undefined;
        sqlite.resultError(ctx, errorText("group_by", err, &buf));
    };
}

fn groupByImpl(ctx: ?*c.sqlite3_context, alloc: std.mem.Allocator, arg: ?*c.sqlite3_value) !void {
    const args = try decodeArgs(
        alloc,
        ctx,
        0,
        0,
        @ptrCast(@constCast(&[_]?*c.sqlite3_value{arg})),
        1,
    );
    const decoded = if (args[0] == .safe) args[0].safe.* else args[0];
    switch (decoded) {
        .null => sqlite.resultNull(ctx),
        .array => |a| sqlite.resultText(ctx, try joinToString(alloc, a.values)),
        .struct_ => |s| sqlite.resultText(ctx, try joinToString(alloc, s.values)),
        // Scalars: Go decoded.Interface().
        .int => |i| sqlite.resultInt64(ctx, i),
        .bool => |b| sqlite.resultInt64(ctx, @intFromBool(b)),
        .float => |f| sqlite.resultDouble(ctx, f),
        .string => |s| sqlite.resultText(ctx, s),
        .bytes => |b| sqlite.resultBlob(ctx, b),
        // JSON group key: the raw JSON text (distinct raw strings group together).
        .json => |s| sqlite.resultText(ctx, s),
        .date => |days| {
            var buf: [32]u8 = undefined;
            sqlite.resultText(ctx, value_mod.formatDateDays(&buf, days));
        },
        // Go decoded.Interface(): timestamp => time.RFC3339, the others =>
        // their ToApiString form.
        .timestamp => |m| {
            var buf: [40]u8 = undefined;
            sqlite.resultText(ctx, value_mod.formatTimestampRfc3339(&buf, m));
        },
        .datetime => |m| {
            var buf: [40]u8 = undefined;
            sqlite.resultText(ctx, value_mod.formatDatetimeApi(&buf, m));
        },
        .time => |m| {
            var buf: [24]u8 = undefined;
            sqlite.resultText(ctx, value_mod.formatTimeString(&buf, m));
        },
        .interval => |iv| {
            var buf: [96]u8 = undefined;
            sqlite.resultText(ctx, value_mod.formatInterval(&buf, iv));
        },
        // RANGE group key: the canonical "[start, end)" text. RangeType
        // overrides SupportsGroupingImpl to true, so GROUP BY over a range
        // column is legal, and distinct ranges of one element kind render to
        // distinct text. Two kinds could collide on "[UNBOUNDED, UNBOUNDED)",
        // which cannot arise: a column carries one static element type.
        .range => |r| {
            var buf: [96]u8 = undefined;
            sqlite.resultText(ctx, value_mod.formatRange(&buf, r));
        },
        // NUMERIC/BIGNUMERIC group key: the decimal rendering (distinct
        // numeric values render to distinct text, so grouping is exact).
        .numeric => |n| sqlite.resultText(ctx, try n.toText(alloc)),
        .safe => unreachable,
    }
}

fn joinToString(alloc: std.mem.Allocator, values: []const Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (values, 0..) |v, i| {
        if (i > 0) try out.appendSlice(alloc, "||");
        try out.appendSlice(alloc, try v.toString(alloc));
    }
    return out.toOwnedSlice(alloc);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@import("bind.zig"));
    testing.refAllDecls(@import("fn_math.zig"));
    testing.refAllDecls(@import("fn_compare.zig"));
    testing.refAllDecls(@import("fn_string.zig"));
    testing.refAllDecls(@import("fn_regexp.zig"));
    testing.refAllDecls(@import("fn_format.zig"));
    testing.refAllDecls(@import("fn_net.zig"));
    testing.refAllDecls(@import("fn_array.zig"));
    testing.refAllDecls(@import("fn_misc.zig"));
    testing.refAllDecls(@import("fn_date.zig"));
    testing.refAllDecls(@import("fn_datetime.zig"));
    testing.refAllDecls(@import("fn_time.zig"));
    testing.refAllDecls(@import("fn_timestamp.zig"));
    testing.refAllDecls(@import("fn_interval.zig"));
    testing.refAllDecls(@import("time_util.zig"));
    testing.refAllDecls(@import("time_parser.zig"));
    testing.refAllDecls(@import("date_ops.zig"));
    testing.refAllDecls(@import("aggregate.zig"));
}

const TestEnv = struct {
    // Heap-allocated so the Allocator vtable pointer stays stable when the
    // TestEnv struct is returned by value.
    arena: *std.heap.ArenaAllocator,
    db: sqlite.Db,

    fn init() !TestEnv {
        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        var db = try sqlite.Db.open(":memory:");
        errdefer db.close();
        // State chunks come from the test arena, so nothing leaks.
        _ = try registerAll(&db, arena.allocator());
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

    /// One-row/one-column query; TEXT/BLOB results are DecodeValue'd.
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

    /// One-row/one-column query returning the raw TEXT (no decode).
    fn queryText(env: *TestEnv, sql: []const u8) ![]u8 {
        var stmt = try env.db.prepare(sql);
        defer stmt.finalize();
        if (!try stmt.step()) return error.NoRow;
        return env.alloc().dupe(u8, stmt.columnText(0));
    }

    fn expectInt(env: *TestEnv, expected: i64, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try value_mod.expectValueEqual(Value{ .int = expected }, v);
    }

    fn expectFloat(env: *TestEnv, expected: f64, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try testing.expect(v == .float);
        try testing.expectApproxEqAbs(expected, v.float, 1e-12);
    }

    fn expectValue(env: *TestEnv, expected: Value, sql: []const u8) !void {
        try value_mod.expectValueEqual(expected, try env.queryValue(sql));
    }

    fn expectNullResult(env: *TestEnv, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try testing.expect(v == .null);
    }

    fn expectStringResult(env: *TestEnv, expected: []const u8, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try testing.expect(v == .string);
        try testing.expectEqualStrings(expected, v.string);
    }

    fn expectBytesResult(env: *TestEnv, expected: []const u8, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try testing.expect(v == .bytes);
        try testing.expectEqualStrings(expected, v.bytes);
    }

    fn expectErrorMsg(env: *TestEnv, expected_substr: []const u8, sql: []const u8) !void {
        var stmt = try env.db.prepare(sql);
        defer stmt.finalize();
        try testing.expectError(error.SQLite, stmt.step());
        const msg = env.db.errmsg();
        if (std.mem.indexOf(u8, msg, expected_substr) == null) {
            std.debug.print("expected error containing \"{s}\", got \"{s}\"\n", .{ expected_substr, msg });
            return error.TestUnexpectedResult;
        }
    }

    /// Renders a Value as a single-quoted encoded SQL literal (the base64
    /// codec text never contains quotes).
    fn enc(env: *TestEnv, v: Value) ![]u8 {
        // LiteralFromValue rather than quoting EncodeValue's output: it is the
        // one place that knows how each kind renders as SQL.
        return encoder.LiteralFromValue(env.alloc(), v);
    }

    fn encStr(env: *TestEnv, s: []const u8) ![]u8 {
        return env.enc(Value{ .string = s });
    }

    fn encBytes(env: *TestEnv, b: []const u8) ![]u8 {
        return env.enc(Value{ .bytes = b });
    }

    fn fmt(env: *TestEnv, comptime f: []const u8, args: anytype) ![]u8 {
        return std.fmt.allocPrint(env.alloc(), f, args);
    }
};

test "arithmetic and bit functions" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectInt(3, "SELECT zetasqlite_add(1, 2)");
    try env.expectInt(-1, "SELECT zetasqlite_subtract(2, 3)");
    try env.expectInt(42, "SELECT zetasqlite_multiply(6, 7)");
    try env.expectInt(3, "SELECT zetasqlite_divide(7, 2)");
    try env.expectFloat(3.5, "SELECT zetasqlite_divide(7.0, 2)");
    try env.expectFloat(4.0, "SELECT zetasqlite_add(1.5, 2.5)");
    try env.expectNullResult("SELECT zetasqlite_add(1, NULL)");
    // This Go fork wraps on int64 overflow (no overflow check in IntValue.Add).
    try env.expectInt(std.math.minInt(i64), "SELECT zetasqlite_add(9223372036854775807, 1)");
    try env.expectErrorMsg("zero divided error ( 1 / 0 )", "SELECT zetasqlite_divide(1, 0)");

    // SAFE variants: divide-by-zero -> NULL; others go through float64.
    try env.expectNullResult("SELECT zetasqlite_safe_divide(1, 0)");
    try env.expectFloat(0.5, "SELECT zetasqlite_safe_divide(1, 2)");
    try env.expectFloat(3.0, "SELECT zetasqlite_safe_add(1, 2)");
    try env.expectFloat(-1.0, "SELECT zetasqlite_safe_subtract(1, 2)");
    try env.expectFloat(6.0, "SELECT zetasqlite_safe_multiply(2, 3)");
    try env.expectFloat(-5.0, "SELECT zetasqlite_safe_negate(5)");
    // safe_negate also gets the automatic safe_ wrapper (Go registers
    // zetasqlite_safe_safe_negate too).
    try env.expectFloat(-5.0, "SELECT zetasqlite_safe_safe_negate(5)");

    try env.expectInt(-1, "SELECT zetasqlite_bitwise_not(0)");
    try env.expectInt(8, "SELECT zetasqlite_bitwise_left_shift(1, 3)");
    try env.expectInt(-4, "SELECT zetasqlite_bitwise_right_shift(-8, 1)");
    try env.expectInt(4, "SELECT zetasqlite_bitwise_and(6, 5)");
    try env.expectInt(7, "SELECT zetasqlite_bitwise_or(6, 5)");
    try env.expectInt(3, "SELECT zetasqlite_bitwise_xor(6, 5)");
    try env.expectNullResult("SELECT zetasqlite_bitwise_and(NULL, 5)");

    try env.expectFloat(2.5, "SELECT zetasqlite_abs(-2.5)");
    try env.expectFloat(2.0, "SELECT zetasqlite_round(1.5)");
    try env.expectFloat(-2.0, "SELECT zetasqlite_round(-1.5)");
    try env.expectFloat(1.23, "SELECT zetasqlite_round(1.2345, 2)");
    try env.expectNullResult("SELECT zetasqlite_round(NULL)");
}

test "comparison and logical functions" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectInt(1, "SELECT zetasqlite_equal(1, 1)");
    try env.expectInt(0, "SELECT zetasqlite_equal(1, 2)");
    try env.expectInt(1, "SELECT zetasqlite_not_equal(1, 2)");
    try env.expectInt(1, "SELECT zetasqlite_greater(2, 1)");
    try env.expectInt(1, "SELECT zetasqlite_greater_or_equal(2, 2)");
    try env.expectInt(1, "SELECT zetasqlite_less(1, 2)");
    try env.expectInt(1, "SELECT zetasqlite_less_or_equal(2, 2)");
    try env.expectNullResult("SELECT zetasqlite_equal(NULL, 1)");

    try env.expectInt(0, "SELECT zetasqlite_is_distinct_from(NULL, NULL)");
    try env.expectInt(1, "SELECT zetasqlite_is_distinct_from(1, NULL)");
    try env.expectInt(0, "SELECT zetasqlite_is_distinct_from(1, 1)");
    try env.expectInt(1, "SELECT zetasqlite_is_not_distinct_from(NULL, NULL)");
    try env.expectInt(0, "SELECT zetasqlite_is_not_distinct_from(1, NULL)");

    try env.expectInt(1, "SELECT zetasqlite_between(2, 1, 3)");
    try env.expectInt(0, "SELECT zetasqlite_between(4, 1, 3)");
    try env.expectInt(1, "SELECT zetasqlite_in(2, 1, 2, 3)");
    try env.expectInt(0, "SELECT zetasqlite_in(9, 1, 2, 3)");

    try env.expectInt(1, "SELECT zetasqlite_is_null(NULL)");
    try env.expectInt(0, "SELECT zetasqlite_is_null(1)");
    try env.expectInt(1, "SELECT zetasqlite_is_true(1)");
    try env.expectInt(1, "SELECT zetasqlite_is_false(0)");
    try env.expectInt(1, "SELECT zetasqlite_not(0)");
    try env.expectInt(0, "SELECT zetasqlite_not(1)");

    try env.expectInt(1, "SELECT zetasqlite_and(1, 1, 1)");
    try env.expectInt(0, "SELECT zetasqlite_and(1, 0, NULL)"); // false beats NULL
    try env.expectNullResult("SELECT zetasqlite_and(1, NULL)");
    try env.expectInt(1, "SELECT zetasqlite_or(0, NULL, 1)"); // true beats NULL
    try env.expectNullResult("SELECT zetasqlite_or(0, NULL)");
    try env.expectInt(0, "SELECT zetasqlite_or(0, 0)");
}

test "LIKE matching (only % is a wildcard, _ is literal)" {
    var env = try TestEnv.init();
    defer env.deinit();

    const cases = [_]struct { s: []const u8, p: []const u8, expect: i64 }{
        .{ .s = "abc", .p = "abc", .expect = 1 },
        .{ .s = "abc", .p = "a%", .expect = 1 },
        .{ .s = "abc", .p = "%c", .expect = 1 },
        .{ .s = "abc", .p = "%b%", .expect = 1 },
        .{ .s = "abc", .p = "%", .expect = 1 },
        .{ .s = "", .p = "%", .expect = 1 },
        .{ .s = "abc", .p = "a%d", .expect = 0 },
        .{ .s = "abc", .p = "a_c", .expect = 0 }, // Go treats _ literally
        .{ .s = "a_c", .p = "a_c", .expect = 1 },
        .{ .s = "ab", .p = "a%b%c", .expect = 0 },
        .{ .s = "axbyc", .p = "a%b%c", .expect = 1 },
        .{ .s = "ab", .p = "a%ab", .expect = 0 }, // suffix may not overlap prefix
    };
    for (cases) |cse| {
        const sql = try env.fmt("SELECT zetasqlite_like({s}, {s})", .{
            try env.encStr(cse.s), try env.encStr(cse.p),
        });
        try env.expectInt(cse.expect, sql);
    }
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_like(NULL, {s})", .{try env.encStr("%")}));
}

test "conditional functions" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectInt(5, "SELECT zetasqlite_coalesce(NULL, 5, 7)");
    try env.expectNullResult("SELECT zetasqlite_coalesce(NULL, NULL)");
    try env.expectErrorMsg("COALESCE: invalid argument num 0", "SELECT zetasqlite_coalesce()");

    try env.expectInt(1, "SELECT zetasqlite_if(1, 1, 2)");
    try env.expectInt(2, "SELECT zetasqlite_if(0, 1, 2)");
    try env.expectInt(2, "SELECT zetasqlite_if(NULL, 1, 2)"); // NULL cond -> false branch
    try env.expectStringResult("yes", try env.fmt(
        "SELECT zetasqlite_if(1, {s}, {s})",
        .{ try env.encStr("yes"), try env.encStr("no") },
    ));
    try env.expectErrorMsg("IF: invalid argument num 2", "SELECT zetasqlite_if(1, 2)");

    try env.expectInt(9, "SELECT zetasqlite_ifnull(NULL, 9)");
    try env.expectInt(4, "SELECT zetasqlite_ifnull(4, 9)");
    try env.expectNullResult("SELECT zetasqlite_nullif(3, 3)");
    try env.expectInt(3, "SELECT zetasqlite_nullif(3, 4)");
    try env.expectNullResult("SELECT zetasqlite_nullif(NULL, 4)");
}

test "string functions" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectStringResult("abcd", try env.fmt(
        "SELECT zetasqlite_concat({s}, {s})",
        .{ try env.encStr("ab"), try env.encStr("cd") },
    ));
    try env.expectNullResult(try env.fmt(
        "SELECT zetasqlite_concat({s}, NULL)",
        .{try env.encStr("ab")},
    ));
    try env.expectErrorMsg("CONCAT: argument type must be STRING or BYTES", "SELECT zetasqlite_concat(1, 2)");

    // length counts runes for strings, bytes for BYTES.
    try env.expectInt(5, try env.fmt("SELECT zetasqlite_length({s})", .{try env.encStr("héllo")}));
    try env.expectInt(6, try env.fmt("SELECT zetasqlite_length({s})", .{try env.enc(Value{ .bytes = "héllo" })}));
    try env.expectNullResult("SELECT zetasqlite_length(NULL)");

    try env.expectStringResult("hé", try env.fmt("SELECT zetasqlite_left({s}, 2)", .{try env.encStr("héllo")}));
    try env.expectStringResult("llo", try env.fmt("SELECT zetasqlite_right({s}, 3)", .{try env.encStr("héllo")}));
    try env.expectStringResult("abc", try env.fmt("SELECT zetasqlite_left({s}, 99)", .{try env.encStr("abc")}));
    try env.expectErrorMsg(
        "LEFT: unexpected length value. length must be positive number",
        try env.fmt("SELECT zetasqlite_left({s}, -1)", .{try env.encStr("abc")}),
    );

    try env.expectStringResult("abc", try env.fmt("SELECT zetasqlite_lower({s})", .{try env.encStr("AbC")}));
    try env.expectStringResult("ABC", try env.fmt("SELECT zetasqlite_upper({s})", .{try env.encStr("aBc")}));

    // SUBSTR: 1-based, negative pos counts from the end.
    try env.expectStringResult("bcd", try env.fmt("SELECT zetasqlite_substr({s}, 2)", .{try env.encStr("abcd")}));
    try env.expectStringResult("bc", try env.fmt("SELECT zetasqlite_substr({s}, 2, 2)", .{try env.encStr("abcd")}));
    try env.expectStringResult("cd", try env.fmt("SELECT zetasqlite_substr({s}, -2)", .{try env.encStr("abcd")}));
    try env.expectErrorMsg(
        "SUBSTR: length must be positive number",
        try env.fmt("SELECT zetasqlite_substr({s}, 1, -1)", .{try env.encStr("abcd")}),
    );
}

test "array and struct functions" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectInt(3, "SELECT zetasqlite_array_length(zetasqlite_make_array(7, 8, 9))");
    try env.expectInt(8, "SELECT zetasqlite_array_at_offset(zetasqlite_make_array(7, 8, 9), 1)");
    try env.expectInt(7, "SELECT zetasqlite_array_at_ordinal(zetasqlite_make_array(7, 8, 9), 1)");
    try env.expectErrorMsg("OFFSET(5) is out of range", "SELECT zetasqlite_array_at_offset(zetasqlite_make_array(7), 5)");
    try env.expectErrorMsg("ORDINAL(0) is out of range", "SELECT zetasqlite_array_at_ordinal(zetasqlite_make_array(7), 0)");
    try env.expectNullResult("SELECT zetasqlite_safe_array_at_offset(zetasqlite_make_array(7), 5)");
    try env.expectNullResult("SELECT zetasqlite_safe_array_at_ordinal(zetasqlite_make_array(7), 0)");

    try env.expectInt(4, "SELECT zetasqlite_array_length(zetasqlite_array_concat(zetasqlite_make_array(1, 2), zetasqlite_make_array(3, 4)))");
    try env.expectNullResult("SELECT zetasqlite_array_concat(zetasqlite_make_array(1), NULL)");

    try env.expectInt(1, "SELECT zetasqlite_in_array(2, zetasqlite_make_array(1, 2, 3))");
    try env.expectInt(0, "SELECT zetasqlite_in_array(9, zetasqlite_make_array(1, 2, 3))");

    const mk_struct = try env.fmt("zetasqlite_make_struct({s}, 1, {s}, {s})", .{
        try env.encStr("a"), try env.encStr("b"), try env.encStr("x"),
    });
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_get_struct_field({s}, 0)", .{mk_struct}));
    try env.expectStringResult("x", try env.fmt("SELECT zetasqlite_get_struct_field({s}, 1)", .{mk_struct}));
    try env.expectErrorMsg(
        "struct field index 7 out of range (struct has 2 fields)",
        try env.fmt("SELECT zetasqlite_get_struct_field({s}, 7)", .{mk_struct}),
    );
    // A nested composite field is walked over, not decoded, on the way to a
    // later one — the case where a wrong skip width would desynchronise the
    // walk rather than error.
    const nested = try env.fmt(
        "zetasqlite_make_struct({s}, zetasqlite_make_array(1, 2), {s}, 9)",
        .{ try env.encStr("a"), try env.encStr("b") },
    );
    try env.expectInt(9, try env.fmt("SELECT zetasqlite_get_struct_field({s}, 1)", .{nested}));

    // These three take their composite argument encoded (bind.FuncInfo
    // raw_args), so an argument that is not one has to fall back to a full
    // decode to report what it is — in the words toStruct/toArray always used.
    // Note the message is the string-specific one: the fallback reproduces what
    // toStruct says about the value it actually got, not a generic complaint.
    try env.expectErrorMsg(
        "failed to convert struct from string",
        try env.fmt("SELECT zetasqlite_get_struct_field({s}, 0)", .{try env.encStr("nope")}),
    );
    try env.expectErrorMsg(
        "failed to convert array from string",
        try env.fmt("SELECT zetasqlite_array_at_offset({s}, 0)", .{try env.encStr("nope")}),
    );
    // An INTEGER argument never arrives raw at all, so it takes the same path
    // it always did.
    try env.expectErrorMsg(
        "failed to convert to array type",
        "SELECT zetasqlite_array_at_ordinal(1, 1)",
    );
}

test "cast function (foundation kinds)" {
    var env = try TestEnv.init();
    defer env.deinit();

    const t_int = try env.encStr("{\"kind\":2}");
    const t_bool = try env.encStr("{\"kind\":5}");
    const t_double = try env.encStr("{\"kind\":7}");
    const t_string = try env.encStr("{\"kind\":8}");
    const t_date = try env.encStr("{\"kind\":10}");
    const t_ts = try env.encStr("{\"kind\":19}");

    // int -> string / float / bool
    try env.expectStringResult("1", try env.fmt("SELECT zetasqlite_cast(1, {s}, {s}, 0)", .{ t_int, t_string }));
    const as_float = try env.queryValue(try env.fmt("SELECT zetasqlite_cast(3, {s}, {s}, 0)", .{ t_int, t_double }));
    try value_mod.expectValueEqual(Value{ .float = 3.0 }, as_float);
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_cast(1, {s}, {s}, 0)", .{ t_int, t_bool }));

    // string -> int; float -> int truncates
    try env.expectInt(42, try env.fmt("SELECT zetasqlite_cast({s}, {s}, {s}, 0)", .{ try env.encStr("42"), t_string, t_int }));
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_cast(1.5, {s}, {s}, 0)", .{ t_double, t_int }));

    // date <-> string
    const days = try value_mod.parseDateDays("2021-01-02");
    const date_lit = try env.enc(Value{ .date = days });
    try env.expectStringResult("2021-01-02", try env.fmt("SELECT zetasqlite_cast({s}, {s}, {s}, 0)", .{ date_lit, t_date, t_string }));
    const as_date = try env.queryValue(try env.fmt(
        "SELECT zetasqlite_cast({s}, {s}, {s}, 0)",
        .{ try env.encStr("2021-01-02"), t_string, t_date },
    ));
    try value_mod.expectValueEqual(Value{ .date = days }, as_date);

    // NULL passes through; safe cast turns failures into NULL, unsafe raises.
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_cast(NULL, {s}, {s}, 0)", .{ t_string, t_int }));
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_cast({s}, {s}, {s}, 1)", .{ try env.encStr("abc"), t_string, t_int }));
    try env.expectErrorMsg(
        "failed to convert string to int64",
        try env.fmt("SELECT zetasqlite_cast({s}, {s}, {s}, 0)", .{ try env.encStr("abc"), t_string, t_int }),
    );
    // string -> timestamp parses the date/datetime/timestamp form (a bare
    // date lands at midnight UTC).
    const ts_days = try value_mod.parseDateDays("2021-01-02");
    const as_ts = try env.queryValue(try env.fmt(
        "SELECT zetasqlite_cast({s}, {s}, {s}, 0)",
        .{ try env.encStr("2021-01-02"), t_string, t_ts },
    ));
    try value_mod.expectValueEqual(Value{ .timestamp = ts_days * 86400 * 1_000_000 }, as_ts);

    // NUMERIC (kind 23) / BIGNUMERIC (kind 24) casts: string exponents parse
    // via Rat.SetString; rendering trims trailing zeros (corpus case 617).
    const t_numeric = try env.encStr("{\"kind\":23}");
    const t_bignumeric = try env.encStr("{\"kind\":24}");
    const as_numeric = try env.queryValue(
        try env.fmt("SELECT zetasqlite_cast({s}, {s}, {s}, 0)", .{ try env.encStr("12.4E17"), t_string, t_numeric }),
    );
    try testing.expect(as_numeric == .numeric);
    try testing.expect(!as_numeric.numeric.is_bignumeric);
    try testing.expectEqualStrings("1240000000000000000", try as_numeric.toString(env.alloc()));
    const as_bignumeric = try env.queryValue(
        try env.fmt("SELECT zetasqlite_cast({s}, {s}, {s}, 0)", .{ try env.encStr("12.4E37"), t_string, t_bignumeric }),
    );
    try testing.expect(as_bignumeric == .numeric);
    try testing.expect(as_bignumeric.numeric.is_bignumeric);
    try testing.expectEqualStrings("124000000000000000000000000000000000000", try as_bignumeric.toString(env.alloc()));
    // numeric -> string (corpus case 620).
    const numeric_lit = try env.enc(try value_mod.numericFromString(env.alloc(), "123.456", false));
    try env.expectStringResult(
        "123.456",
        try env.fmt("SELECT zetasqlite_cast({s}, {s}, {s}, 0)", .{ numeric_lit, t_numeric, t_string }),
    );

    // array cast: elements go through elementType.
    const t_arr_str = try env.encStr("{\"kind\":16,\"elementType\":{\"kind\":8}}");
    const t_arr_int = try env.encStr("{\"kind\":16,\"elementType\":{\"kind\":2}}");
    const arr_in = try env.fmt("zetasqlite_make_array({s}, {s})", .{ try env.encStr("1"), try env.encStr("2") });
    try env.expectInt(2, try env.fmt(
        "SELECT zetasqlite_array_at_offset(zetasqlite_cast({s}, {s}, {s}, 0), 1)",
        .{ arr_in, t_arr_str, t_arr_int },
    ));
}

test "parse_numeric / parse_bignumeric" {
    var env = try TestEnv.init();
    defer env.deinit();

    // Corpus cases 618/619: plain, exponent, and precision-rounding forms.
    const cases = [_]struct { func: []const u8, in: []const u8, out: []const u8, big: bool }{
        .{ .func = "zetasqlite_parse_numeric", .in = "123.45", .out = "123.45", .big = false },
        .{ .func = "zetasqlite_parse_numeric", .in = "12.34E27", .out = "12340000000000000000000000000", .big = false },
        .{ .func = "zetasqlite_parse_numeric", .in = "1.0123456789", .out = "1.012345679", .big = false },
        .{ .func = "zetasqlite_parse_bignumeric", .in = "123.45", .out = "123.45", .big = true },

        .{
            .func = "zetasqlite_parse_bignumeric",
            .in = "1.123456789012345678901234567890123456789",
            .out = "1.12345678901234567890123456789012345679",
            .big = true,
        },
    };
    for (cases) |tc| {
        const v = try env.queryValue(try env.fmt("SELECT {s}({s})", .{ tc.func, try env.encStr(tc.in) }));
        try testing.expect(v == .numeric);
        try testing.expectEqual(tc.big, v.numeric.is_bignumeric);
        try testing.expectEqualStrings(tc.out, try v.toString(env.alloc()));
    }

    // Unparseable literals raise like Go's PARSE_NUMERIC.
    try env.expectErrorMsg(
        "unexpected numeric literal: abc",
        try env.fmt("SELECT zetasqlite_parse_numeric({s})", .{try env.encStr("abc")}),
    );

    // A well-formed literal past the type's range is a *range* error, and is
    // rejected rather than stored. Corpus case 619 used to expect
    // "123.456E37" (1.23456e39) to parse, which is 2.13x BIGNUMERIC's max of
    // 5.7896e38 and needs 1.23e77 unscaled, past 2^255. BigQuery rejects it
    // too; go-zetasqlite accepted it only because it has no bounds check.
    try env.expectErrorMsg(
        "BIGNUMERIC value out of range: 123.456E37",
        try env.fmt("SELECT zetasqlite_parse_bignumeric({s})", .{try env.encStr("123.456E37")}),
    );
    // NUMERIC's own bound is 10^38 - 1 unscaled, i.e. just under 1e29.
    try env.expectErrorMsg(
        "NUMERIC value out of range: 1e29",
        try env.fmt("SELECT zetasqlite_parse_numeric({s})", .{try env.encStr("1e29")}),
    );
}

test "SUM / AVG / MIN / MAX over numeric values" {
    var env = try TestEnv.init();
    defer env.deinit();

    const n1 = try env.enc(try value_mod.numericFromString(env.alloc(), "1.5", false));
    const n2 = try env.enc(try value_mod.numericFromString(env.alloc(), "2.25", false));
    const n3 = try env.enc(try value_mod.numericFromString(env.alloc(), "-0.75", false));
    const table = try env.fmt(
        "WITH t(v) AS (SELECT {s} UNION ALL SELECT {s} UNION ALL SELECT {s})",
        .{ n1, n2, n3 },
    );

    // SUM keeps the NUMERIC kind (Go: sum.Add returns the NumericValue).
    const sum = try env.queryValue(try env.fmt("{s} SELECT zetasqlite_sum(v) FROM t", .{table}));
    try testing.expect(sum == .numeric);
    try testing.expectEqualStrings("3", try sum.toString(env.alloc()));

    // AVG converts through ToFloat64 (Go returns FloatValue).
    const avg = try env.queryValue(try env.fmt("{s} SELECT zetasqlite_avg(v) FROM t", .{table}));
    try testing.expect(avg == .float);
    try testing.expectApproxEqAbs(@as(f64, 1.0), avg.float, 1e-12);

    // MIN/MAX order via the rat comparison.
    const max = try env.queryValue(try env.fmt("{s} SELECT zetasqlite_max(v) FROM t", .{table}));
    try testing.expectEqualStrings("2.25", try max.toString(env.alloc()));
    const min = try env.queryValue(try env.fmt("{s} SELECT zetasqlite_min(v) FROM t", .{table}));
    try testing.expectEqualStrings("-0.75", try min.toString(env.alloc()));
}

test "error() raises with its message; safe variant yields NULL" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectErrorMsg("boom", try env.fmt("SELECT zetasqlite_error({s})", .{try env.encStr("boom")}));
    try env.expectNullResult("SELECT zetasqlite_error(NULL)");
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_safe_error({s})", .{try env.encStr("boom")}));
}

test "group_by flattens containers and passes scalars through" {
    var env = try TestEnv.init();
    defer env.deinit();

    // Scalars: native passthrough (raw string, not re-encoded).
    try testing.expectEqualStrings("x", try env.queryText(try env.fmt(
        "SELECT zetasqlite_group_by({s})",
        .{try env.encStr("x")},
    )));
    {
        var stmt = try env.db.prepare("SELECT zetasqlite_group_by(5)");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqual(sqlite.Stmt.ColumnType.integer, stmt.columnType(0));
        try testing.expectEqual(@as(i64, 5), stmt.columnInt64(0));
    }
    {
        var stmt = try env.db.prepare("SELECT zetasqlite_group_by(NULL)");
        defer stmt.finalize();
        try testing.expect(try stmt.step());
        try testing.expectEqual(sqlite.Stmt.ColumnType.null, stmt.columnType(0));
    }

    // Arrays/structs join their elements' ToString with "||".
    try testing.expectEqualStrings("a||b", try env.queryText(try env.fmt(
        "SELECT zetasqlite_group_by(zetasqlite_make_array({s}, {s}))",
        .{ try env.encStr("a"), try env.encStr("b") },
    )));
    try testing.expectEqualStrings("1||x", try env.queryText(try env.fmt(
        "SELECT zetasqlite_group_by(zetasqlite_make_struct({s}, 1, {s}, {s}))",
        .{ try env.encStr("k1"), try env.encStr("k2"), try env.encStr("x") },
    )));
}

test "encoded values order by memcmp, with no collation involved" {
    var env = try TestEnv.init();
    defer env.deinit();

    // This test used to rest on the opposite premise: that the binary order of
    // the *encoded* text put "b" before "aa", so a collation had to decode to
    // get it right. The encoding is memcomparable now, which is what lets these
    // values be BLOBs at all — SQLite never consults a collation for a BLOB, so
    // if the bytes were not ordered this ORDER BY would be silently wrong with
    // nothing to catch it.
    const sql = try env.fmt(
        "SELECT v FROM (SELECT {s} AS v UNION ALL SELECT {s}) ORDER BY v",
        .{ try env.encStr("b"), try env.encStr("aa") },
    );
    var stmt = try env.db.prepare(sql);
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(sqlite.Stmt.ColumnType.blob, stmt.columnType(0));
    var v = try encoder.DecodeValue(
        env.alloc(),
        .{ .blob = try env.alloc().dupe(u8, stmt.columnBlob(0)) },
    );
    try value_mod.expectValueEqual(Value{ .string = "aa" }, v);
    try testing.expect(try stmt.step());
    v = try encoder.DecodeValue(
        env.alloc(),
        .{ .blob = try env.alloc().dupe(u8, stmt.columnBlob(0)) },
    );
    try value_mod.expectValueEqual(Value{ .string = "b" }, v);

    // Dates compare chronologically, including across the epoch, which a naive
    // big-endian encoding would get wrong (the sign bit sorts negatives high).
    const d1 = try env.enc(Value{ .date = try value_mod.parseDateDays("2021-06-15") });
    const d2 = try env.enc(Value{ .date = try value_mod.parseDateDays("1930-01-01") });
    var dstmt = try env.db.prepare(try env.fmt(
        "SELECT v FROM (SELECT {s} AS v UNION ALL SELECT {s}) ORDER BY v",
        .{ d1, d2 },
    ));
    defer dstmt.finalize();
    try testing.expect(try dstmt.step());
    const first = try encoder.DecodeValue(
        env.alloc(),
        .{ .blob = try env.alloc().dupe(u8, dstmt.columnBlob(0)) },
    );
    try value_mod.expectValueEqual(Value{ .date = try value_mod.parseDateDays("1930-01-01") }, first);
}

test "min_args guard rejects too few arguments instead of UB" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.expectErrorMsg("zetasqlite_add: invalid argument num", "SELECT zetasqlite_add(1)");
}

test "extended string functions (ascii/length/case/pad/split/soundex)" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectInt(97, try env.fmt("SELECT zetasqlite_ascii({s})", .{try env.encStr("abcd")}));
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_ascii({s})", .{try env.encStr("")}));
    // rune vs byte length.
    try env.expectInt(5, try env.fmt("SELECT zetasqlite_char_length({s})", .{try env.encStr("абвгд")}));
    try env.expectInt(10, try env.fmt("SELECT zetasqlite_byte_length({s})", .{try env.encStr("абвгд")}));
    // full-unicode case mapping.
    try env.expectStringResult("ΚΑΘΊΣΜΑΤΑ", try env.fmt("SELECT zetasqlite_upper({s})", .{try env.encStr("καθίσματα")}));
    // rune-aware reverse.
    try env.expectStringResult("дгвба", try env.fmt("SELECT zetasqlite_reverse({s})", .{try env.encStr("абвгд")}));
    // lpad on runes, with repeated pattern.
    try env.expectStringResult("中文中例子", try env.fmt(
        "SELECT zetasqlite_lpad({s}, 5, {s})",
        .{ try env.encStr("例子"), try env.encStr("中文") },
    ));
    try env.expectStringResult("  例子", try env.fmt("SELECT zetasqlite_lpad({s}, 4)", .{try env.encStr("例子")}));
    // initcap default delimiters (Greek).
    try env.expectStringResult("Καθίσματα Ταινιών", try env.fmt("SELECT zetasqlite_initcap({s})", .{try env.encStr("καθίσματα ταινιών")}));
    // soundex.
    try env.expectStringResult("A261", try env.fmt("SELECT zetasqlite_soundex({s})", .{try env.encStr("Ashcraft")}));
    try env.expectStringResult("", try env.fmt("SELECT zetasqlite_soundex({s})", .{try env.encStr("#1")}));
    // strpos / instr / starts_with / ends_with.
    try env.expectInt(4, try env.fmt("SELECT zetasqlite_strpos({s}, {s})", .{ try env.encStr("foo@bar"), try env.encStr("@") }));
    try env.expectInt(4, try env.fmt("SELECT zetasqlite_instr({s}, {s}, 1, 2)", .{ try env.encStr("banana"), try env.encStr("an") }));
    try env.expectInt(4, try env.fmt("SELECT zetasqlite_instr({s}, {s}, -1, 1)", .{ try env.encStr("banana"), try env.encStr("an") }));
    // INSTR's optional arguments and its backward search. Every expectation
    // below is BigQuery's (recidiviz-bigquery-sandbox); the docs carry the
    // -3 and helloooo ones too (string_functions.md#instr).
    //
    // Two arguments: position defaults to the start, occurrence to the first.
    try env.expectInt(2, try env.fmt("SELECT zetasqlite_instr({s}, {s})", .{ try env.encStr("banana"), try env.encStr("a") }));
    // A negative position searches backward from the end, -1 being the last
    // unit, and the occurrence counts backward with it.
    try env.expectInt(6, try env.fmt("SELECT zetasqlite_instr({s}, {s}, -1)", .{ try env.encStr("banana"), try env.encStr("a") }));
    try env.expectInt(4, try env.fmt("SELECT zetasqlite_instr({s}, {s}, -1, 2)", .{ try env.encStr("banana"), try env.encStr("a") }));
    // It bounds where a match *starts*, so this one runs past unit 4.
    try env.expectInt(4, try env.fmt("SELECT zetasqlite_instr({s}, {s}, -3)", .{ try env.encStr("banana"), try env.encStr("an") }));
    // A position past either end returns 0 rather than erroring.
    try env.expectInt(6, try env.fmt("SELECT zetasqlite_instr({s}, {s}, 6)", .{ try env.encStr("banana"), try env.encStr("a") }));
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_instr({s}, {s}, 7)", .{ try env.encStr("banana"), try env.encStr("a") }));
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_instr({s}, {s}, -10)", .{ try env.encStr("banana"), try env.encStr("an") }));
    // Occurrences may overlap: the second "oo" of "helloooo" starts at 6.
    try env.expectInt(6, try env.fmt("SELECT zetasqlite_instr({s}, {s}, 1, 2)", .{ try env.encStr("helloooo"), try env.encStr("oo") }));
    // More occurrences asked for than exist, and an empty needle.
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_instr({s}, {s}, 1, 9)", .{ try env.encStr("banana"), try env.encStr("a") }));
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_instr({s}, {s})", .{ try env.encStr("banana"), try env.encStr("") }));
    // STRING counts characters, BYTES counts bytes: "héllo" puts the first
    // "l" at 3, and the identical value as BYTES puts it at 4.
    try env.expectInt(3, try env.fmt("SELECT zetasqlite_instr({s}, {s})", .{ try env.encStr("héllo"), try env.encStr("l") }));
    try env.expectInt(4, try env.fmt("SELECT zetasqlite_instr({s}, {s}, -1)", .{ try env.encStr("héllo"), try env.encStr("l") }));
    try env.expectInt(4, try env.fmt("SELECT zetasqlite_instr({s}, {s})", .{ try env.encBytes("héllo"), try env.encBytes("l") }));
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_starts_with({s}, {s})", .{ try env.encStr("bar"), try env.encStr("b") }));
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_ends_with({s}, {s})", .{ try env.encStr("apple"), try env.encStr("e") }));
    // translate.
    try env.expectStringResult("Thiz iz a kuukie", try env.fmt(
        "SELECT zetasqlite_translate({s}, {s}, {s})",
        .{ try env.encStr("This is a cookie"), try env.encStr("sco"), try env.encStr("zku") },
    ));
    try env.expectInt(226, try env.fmt("SELECT zetasqlite_unicode({s})", .{try env.encStr("âbc")}));
}

test "trim / normalize functions" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.expectStringResult("apple   ", try env.fmt("SELECT zetasqlite_ltrim({s})", .{try env.encStr("   apple   ")}));
    try env.expectStringResult("apple", try env.fmt("SELECT zetasqlite_trim({s})", .{try env.encStr("   apple   ")}));
    try env.expectStringResult("apple", try env.fmt("SELECT zetasqlite_trim({s}, {s})", .{ try env.encStr("***apple***"), try env.encStr("*") }));
    // NFC composes e + combining circumflex into ê.
    try env.expectStringResult("\u{00ea}", try env.fmt("SELECT zetasqlite_normalize({s})", .{try env.encStr("e\u{0302}")}));
}

test "base32 / base64 / hex encodings" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.expectStringResult("MFRGGZDF74======", try env.fmt("SELECT zetasqlite_to_base32({s})", .{try env.enc(Value{ .bytes = "abcde\xFF" })}));
    try env.expectBytesResult("abcde\xFF", try env.fmt("SELECT zetasqlite_from_base32({s})", .{try env.encStr("MFRGGZDF74======")}));
    try env.expectStringResult("00010203aaeeefff", try env.fmt("SELECT zetasqlite_to_hex({s})", .{try env.enc(Value{ .bytes = "\x00\x01\x02\x03\xAA\xEE\xEF\xFF" })}));
    try env.expectBytesResult("\x00\xAF", try env.fmt("SELECT zetasqlite_from_hex({s})", .{try env.encStr("0AF")}));
}

test "regexp functions (RE2 shim)" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_regexp_contains({s}, {s})", .{ try env.encStr("a@foo.com"), try env.encStr("@foo\\.com$") }));
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_regexp_contains({s}, {s})", .{ try env.encStr("www.net"), try env.encStr("@") }));
    // capture group -> last submatch.
    try env.expectStringResult("com", try env.fmt(
        "SELECT zetasqlite_regexp_extract({s}, {s})",
        .{ try env.encStr("foo@example.com"), try env.encStr(".*@.*\\.([a-z]+)$") },
    ));
    // no groups -> whole match.
    try env.expectStringResult("foo", try env.fmt(
        "SELECT zetasqlite_regexp_extract({s}, {s})",
        .{ try env.encStr("foo@example.com"), try env.encStr("^[a-z]+") },
    ));
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_regexp_extract({s}, {s})", .{ try env.encStr("###"), try env.encStr("[a-z]+") }));
    // replace with \1 rewrite.
    try env.expectStringResult("<h1>Heading</h1>", try env.fmt(
        "SELECT zetasqlite_regexp_replace({s}, {s}, {s})",
        .{ try env.encStr("# Heading"), try env.encStr("^# (.+)$"), try env.encStr("<h1>\\1</h1>") },
    ));
    // instr: 1-based byte position of the match.
    try env.expectInt(3, try env.fmt("SELECT zetasqlite_regexp_instr({s}, {s})", .{ try env.encStr("ab@gmail.com"), try env.encStr("@[^.]*") }));
}

test "FORMAT verbs" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.expectStringResult("10 11 12 ff FF", try env.fmt("SELECT zetasqlite_format({s}, 10, 11, 10, 255, 255)", .{try env.encStr("%d %i %o %x %X")}));
    try env.expectStringResult("|        11|", try env.fmt("SELECT zetasqlite_format({s}, 11)", .{try env.encStr("|%10d|")}));
    try env.expectStringResult("+0000000012+", try env.fmt("SELECT zetasqlite_format({s}, 12)", .{try env.encStr("+%010d+")}));
    try env.expectStringResult("123,456,789", try env.fmt("SELECT zetasqlite_format({s}, 123456789)", .{try env.encStr("%'d")}));
    try env.expectStringResult("1.100000 2.200000E+00", try env.fmt("SELECT zetasqlite_format({s}, 1.1, 2.2)", .{try env.encStr("%f %E")}));
    try env.expectStringResult("-abcd-", try env.fmt("SELECT zetasqlite_format({s}, {s})", .{ try env.encStr("-%s-"), try env.encStr("abcd") }));
    // %T typed rendering of BYTES.
    try env.expectStringResult("b\"abc\"", try env.fmt(
        "SELECT zetasqlite_format({s}, {s})",
        .{ try env.encStr("%T"), try env.enc(Value{ .bytes = "abc" }) },
    ));
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_format({s}, NULL)", .{try env.encStr("%s")}));
}

test "array functions (generate_array/array_to_string/array_reverse)" {
    var env = try TestEnv.init();
    defer env.deinit();
    // GENERATE_ARRAY(10, 0, -3) -> [10,7,4,1].
    try env.expectInt(4, "SELECT zetasqlite_array_length(zetasqlite_generate_array(10, 0, -3))");
    try env.expectInt(1, "SELECT zetasqlite_array_at_offset(zetasqlite_generate_array(10, 0, -3), 3)");
    // step wrong sign -> empty.
    try env.expectInt(0, "SELECT zetasqlite_array_length(zetasqlite_generate_array(10, 0, 3))");
    // NULL bound -> empty array.
    try env.expectInt(0, "SELECT zetasqlite_array_length(zetasqlite_generate_array(5, NULL, 1))");
    try env.expectInt(3, "SELECT zetasqlite_array_at_offset(zetasqlite_array_reverse(zetasqlite_make_array(1, 2, 3)), 0)");
    try env.expectStringResult("a--b", try env.fmt(
        "SELECT zetasqlite_array_to_string(zetasqlite_make_array({s}, {s}), {s})",
        .{ try env.encStr("a"), try env.encStr("b"), try env.encStr("--") },
    ));
}

test "math sign / bit_count" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.expectInt(1, "SELECT zetasqlite_sign(25)");
    try env.expectInt(0, "SELECT zetasqlite_sign(0)");
    try env.expectInt(-1, "SELECT zetasqlite_sign(-25)");
    try env.expectInt(2, "SELECT zetasqlite_bit_count(5)");
    try env.expectInt(64, "SELECT zetasqlite_bit_count(-1)");
    try env.expectInt(16, try env.fmt("SELECT zetasqlite_bit_count({s})", .{try env.enc(Value{ .bytes = "\xFF\xFF" })}));
}

test "inverse / hyperbolic / reciprocal trigonometry" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectFloat(0.0, "SELECT zetasqlite_acos(1.0)");
    try env.expectFloat(std.math.pi, "SELECT zetasqlite_acos(-1.0)");
    try env.expectFloat(0.0, "SELECT zetasqlite_acosh(1.0)");
    try env.expectFloat(0.0, "SELECT zetasqlite_asin(0.0)");
    try env.expectFloat(0.0, "SELECT zetasqlite_asinh(0.0)");
    try env.expectFloat(0.0, "SELECT zetasqlite_atanh(0.0)");
    try env.expectFloat(1.0, "SELECT zetasqlite_cosh(0.0)");
    try env.expectFloat(0.0, "SELECT zetasqlite_sinh(0.0)");
    try env.expectFloat(0.0, "SELECT zetasqlite_tanh(0.0)");
    try env.expectFloat(1.0, "SELECT zetasqlite_sec(0.0)");
    try env.expectFloat(1.0, "SELECT zetasqlite_sech(0.0)");
    try env.expectFloat(3.0, "SELECT zetasqlite_cbrt(27.0)");

    // A finite argument that leaves the domain is an execution error, and the
    // message is the one googlesql prints (math.h SetFloatingPointError).
    try env.expectErrorMsg("Floating point error in function: ACOS(2)", "SELECT zetasqlite_acos(2.0)");
    try env.expectErrorMsg("Floating point error in function: ASIN(2)", "SELECT zetasqlite_asin(2.0)");
    try env.expectErrorMsg("Floating point error in function: ACOSH(0.5)", "SELECT zetasqlite_acosh(0.5)");
    try env.expectErrorMsg("Floating point error in function: ATANH(2)", "SELECT zetasqlite_atanh(2.0)");
    // The reciprocals go singular at 0 rather than out of range.
    try env.expectErrorMsg("Floating point error in function: COT(0)", "SELECT zetasqlite_cot(0.0)");
    try env.expectErrorMsg("Floating point error in function: COTH(0)", "SELECT zetasqlite_coth(0.0)");
    try env.expectErrorMsg("Floating point error in function: CSC(0)", "SELECT zetasqlite_csc(0.0)");
    try env.expectErrorMsg("Floating point error in function: CSCH(0)", "SELECT zetasqlite_csch(0.0)");
    // COSH/SINH overflow instead, which upstream words differently.
    try env.expectErrorMsg("Floating point overflow in function: COSH(1000)", "SELECT zetasqlite_cosh(1000.0)");
    try env.expectErrorMsg("Floating point overflow in function: SINH(1000)", "SELECT zetasqlite_sinh(1000.0)");

    // A non-finite argument is never an error, whatever comes out — the docs'
    // per-function tables reduce to that one distinction.
    //
    // The NaN rows read as NULL rather than NaN, and that is SQLite rather
    // than this code: sqlite3_result_double() turns a NaN into SQL NULL, so no
    // NaN survives a function boundary here. What these two assert is that
    // ACOS(+inf) and SEC(+inf) *do not raise*, which is the part `checked`
    // decides.
    const inf = "zetasqlite_ieee_divide(1.0, 0.0)";
    try env.expectNullResult("SELECT zetasqlite_acos(" ++ inf ++ ")");
    try env.expectNullResult("SELECT zetasqlite_sec(" ++ inf ++ ")");
    try env.expectInt(1, "SELECT zetasqlite_is_inf(zetasqlite_acosh(" ++ inf ++ "))");
    try env.expectFloat(1.0, "SELECT zetasqlite_tanh(" ++ inf ++ ")");
    try env.expectFloat(0.0, "SELECT zetasqlite_sech(" ++ inf ++ ")");

    try env.expectNullResult("SELECT zetasqlite_acos(NULL)");
    try env.expectNullResult("SELECT zetasqlite_cot(NULL)");
    // SAFE. turns the domain error into NULL, via the automatic safe_ wrapper.
    try env.expectNullResult("SELECT zetasqlite_safe_acos(2.0)");
}

test "rand stays inside [0, 1) and is not folded across rows" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.expectInt(1, "SELECT zetasqlite_rand() >= 0.0 AND zetasqlite_rand() < 1.0");
    // The point of `deterministic = false` in the bind table: with
    // SQLITE_DETERMINISTIC set, SQLite hoists this zero-argument call out of
    // the loop and every row sees one value.
    try env.expectInt(20, "SELECT COUNT(DISTINCT zetasqlite_rand()) FROM " ++
        "(WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r WHERE i < 20) SELECT i FROM r)");
}

test "range_bucket counts boundaries at or below the point" {
    var env = try TestEnv.init();
    defer env.deinit();
    const b = "zetasqlite_make_array(0, 10, 20, 30, 40)";
    // A point that is in the array lands past its own last copy.
    try env.expectInt(3, "SELECT zetasqlite_range_bucket(20, " ++ b ++ ")");
    try env.expectInt(4, "SELECT zetasqlite_range_bucket(20, zetasqlite_make_array(0, 10, 20, 20, 40, 40))");
    try env.expectInt(3, "SELECT zetasqlite_range_bucket(25, " ++ b ++ ")");
    try env.expectInt(0, "SELECT zetasqlite_range_bucket(-10, " ++ b ++ ")");
    try env.expectInt(5, "SELECT zetasqlite_range_bucket(80, " ++ b ++ ")");
    try env.expectInt(0, "SELECT zetasqlite_range_bucket(80, zetasqlite_make_array())");
    try env.expectInt(1, try env.fmt(
        "SELECT zetasqlite_range_bucket({s}, zetasqlite_make_array({s}, {s}, {s}))",
        .{ try env.encStr("a"), try env.encStr("a"), try env.encStr("b"), try env.encStr("c") },
    ));

    // A NULL or NaN *point* is NULL; the same inside the array is an error.
    // (The NaN case arrives already collapsed to NULL — see the trigonometry
    // test — so this only pins the observable half of the rule.)
    try env.expectNullResult("SELECT zetasqlite_range_bucket(NULL, " ++ b ++ ")");
    try env.expectNullResult("SELECT zetasqlite_range_bucket(" ++
        "zetasqlite_ieee_divide(0.0, 0.0), zetasqlite_make_array(1.0, 2.0))");
    try env.expectErrorMsg(
        "boundaries_array must not contain NULL or NaN",
        "SELECT zetasqlite_range_bucket(80, zetasqlite_make_array(NULL, 10, 20))",
    );
    try env.expectErrorMsg(
        "boundaries_array must be sorted in ascending order",
        "SELECT zetasqlite_range_bucket(30, zetasqlite_make_array(10, 30, 20, 40))",
    );
}

test "vector distances over dense and sparse vectors" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectFloat(5.0, "SELECT zetasqlite_euclidean_distance(" ++
        "zetasqlite_make_array(1.0, 2.0), zetasqlite_make_array(4.0, 6.0))");
    try env.expectFloat(0.0, "SELECT zetasqlite_euclidean_distance(" ++
        "zetasqlite_make_array(1.0, 2.0, 3.0), zetasqlite_make_array(1.0, 2.0, 3.0))");
    try env.expectFloat(1.0, "SELECT zetasqlite_cosine_distance(" ++
        "zetasqlite_make_array(1.0, 0.0), zetasqlite_make_array(0.0, 1.0))");
    try env.expectFloat(0.0, "SELECT zetasqlite_cosine_distance(" ++
        "zetasqlite_make_array(1.0, 2.0, 3.0), zetasqlite_make_array(1.0, 2.0, 3.0))");
    // Opposite directions are the far end of the range.
    try env.expectFloat(2.0, "SELECT zetasqlite_cosine_distance(" ++
        "zetasqlite_make_array(1.0, 0.0), zetasqlite_make_array(-1.0, 0.0))");

    // A zero vector has a Euclidean distance but no direction.
    try env.expectFloat(5.0, "SELECT zetasqlite_euclidean_distance(" ++
        "zetasqlite_make_array(3.0, 4.0), zetasqlite_make_array(0.0, 0.0))");
    try env.expectErrorMsg("must not be a zero vector", "SELECT zetasqlite_cosine_distance(" ++
        "zetasqlite_make_array(3.0, 4.0), zetasqlite_make_array(0.0, 0.0))");

    try env.expectErrorMsg("must share the same dimensions", "SELECT zetasqlite_euclidean_distance(" ++
        "zetasqlite_make_array(1.0, 2.0), zetasqlite_make_array(1.0, 2.0, 3.0))");
    try env.expectErrorMsg("must not be NULL", "SELECT zetasqlite_euclidean_distance(" ++
        "zetasqlite_make_array(1.0, NULL), zetasqlite_make_array(1.0, 2.0))");
    try env.expectNullResult("SELECT zetasqlite_euclidean_distance(NULL, zetasqlite_make_array(1.0))");

    // Sparse form: dimensions are named, absent ones are zero. 'x' and 'y' do
    // not overlap, so the vectors are orthogonal and 3-4-5 applies.
    const sparse_a = try env.fmt("zetasqlite_make_array(zetasqlite_make_struct({s}, {s}, {s}, 3.0))", .{
        try env.encStr("dimension"), try env.encStr("x"), try env.encStr("magnitude"),
    });
    const sparse_b = try env.fmt("zetasqlite_make_array(zetasqlite_make_struct({s}, {s}, {s}, 4.0))", .{
        try env.encStr("dimension"), try env.encStr("y"), try env.encStr("magnitude"),
    });
    try env.expectFloat(5.0, try env.fmt(
        "SELECT zetasqlite_euclidean_distance({s}, {s})",
        .{ sparse_a, sparse_b },
    ));
    try env.expectFloat(1.0, try env.fmt(
        "SELECT zetasqlite_cosine_distance({s}, {s})",
        .{ sparse_a, sparse_b },
    ));
    // A shared dimension pairs up rather than adding a second axis.
    const sparse_c = try env.fmt("zetasqlite_make_array(zetasqlite_make_struct({s}, {s}, {s}, 7.0))", .{
        try env.encStr("dimension"), try env.encStr("x"), try env.encStr("magnitude"),
    });
    try env.expectFloat(4.0, try env.fmt(
        "SELECT zetasqlite_euclidean_distance({s}, {s})",
        .{ sparse_a, sparse_c },
    ));
    try env.expectErrorMsg("same representation", try env.fmt(
        "SELECT zetasqlite_euclidean_distance({s}, zetasqlite_make_array(3.0))",
        .{sparse_a},
    ));
}

test "range constructor, accessors and predicates" {
    var env = try TestEnv.init();
    defer env.deinit();

    const day = value_mod.daysFromCivil;
    const rng = value_mod.rangeValue;
    // A range as an X'..' literal, which is how one reaches a UDF from SQL.
    const lit = struct {
        fn f(e: *TestEnv, v: Value) ![]u8 {
            return e.enc(v);
        }
    }.f;

    const jan22 = day(2022, 1, 1);
    const jan23 = day(2023, 1, 1);
    const outer = try lit(&env, rng(.date, jan22, jan23));

    // Constructor: bounds in order, either one NULL for UNBOUNDED.
    try env.expectValue(rng(.date, day(2022, 12, 1), day(2022, 12, 31)), try env.fmt(
        "SELECT zetasqlite_range({s}, {s})",
        .{
            try lit(&env, .{ .date = day(2022, 12, 1) }),
            try lit(&env, .{ .date = day(2022, 12, 31) }),
        },
    ));
    try env.expectValue(rng(.date, null, day(2022, 12, 31)), try env.fmt(
        "SELECT zetasqlite_range(NULL, {s})",
        .{try lit(&env, .{ .date = day(2022, 12, 31) })},
    ));

    // start >= end is googlesql's error, verbatim; SAFE. turns it into NULL.
    const backwards = try env.fmt("zetasqlite_range({s}, {s})", .{
        try lit(&env, .{ .date = jan23 }), try lit(&env, .{ .date = jan22 }),
    });
    try env.expectErrorMsg(
        "Range start element must be smaller than range end element",
        try env.fmt("SELECT {s}", .{backwards}),
    );
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_safe_range({s}, {s})", .{
        try lit(&env, .{ .date = jan23 }), try lit(&env, .{ .date = jan22 }),
    }));
    // Equal bounds are empty, not valid: the upper bound is exclusive.
    try env.expectErrorMsg("must be smaller", try env.fmt("SELECT zetasqlite_range({s}, {s})", .{
        try lit(&env, .{ .date = jan22 }), try lit(&env, .{ .date = jan22 }),
    }));

    // Accessors, including UNBOUNDED reading back as NULL.
    try env.expectValue(.{ .date = jan22 }, try env.fmt("SELECT zetasqlite_range_start({s})", .{outer}));
    try env.expectValue(.{ .date = jan23 }, try env.fmt("SELECT zetasqlite_range_end({s})", .{outer}));
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_range_start({s})", .{
        try lit(&env, rng(.date, null, jan23)),
    }));
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_range_end({s})", .{
        try lit(&env, rng(.date, jan22, null)),
    }));
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_range_is_start_unbounded({s})", .{
        try lit(&env, rng(.date, null, jan23)),
    }));

    // RANGE_CONTAINS, range overload.
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_range_contains({s}, {s})", .{
        outer, try lit(&env, rng(.date, day(2022, 4, 1), day(2022, 7, 1))),
    }));
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_range_contains({s}, {s})", .{
        outer, try lit(&env, rng(.date, jan23, day(2023, 4, 1))),
    }));
    // RANGE_CONTAINS, element overload — dispatched purely on arg[1]'s tag.
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_range_contains({s}, {s})", .{
        outer, try lit(&env, .{ .date = day(2022, 4, 1) }),
    }));
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_range_contains({s}, {s})", .{
        outer, try lit(&env, .{ .date = day(2023, 4, 1) }),
    }));
    // The half-open edges: the lower bound is in, the upper is not.
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_range_contains({s}, {s})", .{
        outer, try lit(&env, .{ .date = jan22 }),
    }));
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_range_contains({s}, {s})", .{
        outer, try lit(&env, .{ .date = jan23 }),
    }));

    // RANGE_OVERLAPS is strict: abutting ranges do not overlap, which is the
    // whole difference between the MEETS and OVERLAPS sessionize modes.
    try env.expectInt(0, try env.fmt("SELECT zetasqlite_range_overlaps({s}, {s})", .{
        outer, try lit(&env, rng(.date, jan23, day(2023, 6, 1))),
    }));
    try env.expectInt(1, try env.fmt("SELECT zetasqlite_range_overlaps({s}, {s})", .{
        try lit(&env, rng(.date, day(2022, 2, 1), null)),
        try lit(&env, rng(.date, day(2021, 6, 15), null)),
    }));

    // RANGE_INTERSECT, including UNBOUNDED surviving into the result.
    try env.expectValue(rng(.date, day(2022, 2, 1), day(2022, 4, 15)), try env.fmt(
        "SELECT zetasqlite_range_intersect({s}, {s})",
        .{
            try lit(&env, rng(.date, day(2022, 2, 1), null)),
            try lit(&env, rng(.date, day(2021, 6, 15), day(2022, 4, 15))),
        },
    ));
    try env.expectValue(rng(.date, day(2022, 2, 1), null), try env.fmt(
        "SELECT zetasqlite_range_intersect({s}, {s})",
        .{
            try lit(&env, rng(.date, day(2022, 2, 1), null)),
            try lit(&env, rng(.date, day(2021, 6, 15), null)),
        },
    ));
    const disjoint = try env.fmt("zetasqlite_range_intersect({s}, {s})", .{
        try lit(&env, rng(.date, day(2020, 2, 1), day(2020, 9, 1))),
        try lit(&env, rng(.date, day(2021, 6, 15), day(2022, 4, 15))),
    });
    try env.expectErrorMsg("do not overlap", try env.fmt("SELECT {s}", .{disjoint}));
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_safe_range_intersect({s}, {s})", .{
        try lit(&env, rng(.date, day(2020, 2, 1), day(2020, 9, 1))),
        try lit(&env, rng(.date, day(2021, 6, 15), day(2022, 4, 15))),
    }));

    // NULL in, NULL out for every predicate.
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_range_contains({s}, NULL)", .{outer}));
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_range_overlaps({s}, NULL)", .{outer}));
}

test "generate_range_array splits a range and validates its step" {
    var env = try TestEnv.init();
    defer env.deinit();

    const day = value_mod.daysFromCivil;
    const rng = value_mod.rangeValue;
    const jan1 = day(2020, 1, 1);
    const jan6 = day(2020, 1, 6);
    const src = try env.enc(rng(.date, jan1, jan6));
    const one_day = try env.enc(.{ .interval = .{ .days = 1 } });
    const two_days = try env.enc(.{ .interval = .{ .days = 2 } });

    // Exact fit: five one-day subranges, no partial.
    try env.expectInt(5, try env.fmt(
        "SELECT zetasqlite_array_length(zetasqlite_generate_range_array({s}, {s}))",
        .{ src, one_day },
    ));
    try env.expectValue(rng(.date, jan1, day(2020, 1, 2)), try env.fmt(
        "SELECT zetasqlite_array_at_offset(zetasqlite_generate_range_array({s}, {s}), 0)",
        .{ src, one_day },
    ));

    // Two-day steps leave a one-day remainder: kept by default, kept when the
    // third argument is TRUE, dropped when it is FALSE.
    try env.expectInt(3, try env.fmt(
        "SELECT zetasqlite_array_length(zetasqlite_generate_range_array({s}, {s}))",
        .{ src, two_days },
    ));
    try env.expectInt(3, try env.fmt(
        "SELECT zetasqlite_array_length(zetasqlite_generate_range_array({s}, {s}, true))",
        .{ src, two_days },
    ));
    try env.expectInt(2, try env.fmt(
        "SELECT zetasqlite_array_length(zetasqlite_generate_range_array({s}, {s}, false))",
        .{ src, two_days },
    ));
    // The trailing subrange is clipped to the range's own end, not to a full step.
    try env.expectValue(rng(.date, day(2020, 1, 5), jan6), try env.fmt(
        "SELECT zetasqlite_array_at_offset(zetasqlite_generate_range_array({s}, {s}), 2)",
        .{ src, two_days },
    ));

    // A month step is measured from the original start every iteration, so it
    // clamps at short months rather than drifting. Jan 31 + 1 month is Feb 29
    // in 2020, and + 2 months is Mar 31 — not Mar 2 and May 1, which is what
    // stepping from the previous end (or normalising instead of clamping)
    // would give. No spec case covers this; the corpus only steps by days.
    const month_src = try env.enc(rng(.date, day(2020, 1, 31), day(2020, 5, 1)));
    const one_month = try env.enc(.{ .interval = .{ .months = 1 } });
    try env.expectValue(rng(.date, day(2020, 1, 31), day(2020, 2, 29)), try env.fmt(
        "SELECT zetasqlite_array_at_offset(zetasqlite_generate_range_array({s}, {s}), 0)",
        .{ month_src, one_month },
    ));
    try env.expectValue(rng(.date, day(2020, 2, 29), day(2020, 3, 31)), try env.fmt(
        "SELECT zetasqlite_array_at_offset(zetasqlite_generate_range_array({s}, {s}), 1)",
        .{ month_src, one_month },
    ));

    // Step validation, messages as googlesql words them.
    try env.expectErrorMsg("step cannot be 0", try env.fmt(
        "SELECT zetasqlite_generate_range_array({s}, {s})",
        .{ src, try env.enc(.{ .interval = .{} }) },
    ));
    try env.expectErrorMsg("step cannot be negative", try env.fmt(
        "SELECT zetasqlite_generate_range_array({s}, {s})",
        .{ src, try env.enc(.{ .interval = .{ .days = -1 } }) },
    ));
    try env.expectErrorMsg("step should either have the Y-M part or the DAY part", try env.fmt(
        "SELECT zetasqlite_generate_range_array({s}, {s})",
        .{ src, try env.enc(.{ .interval = .{ .months = 1, .days = 1 } }) },
    ));
    try env.expectErrorMsg("step with non-zero (H:M:S[.F]) part is not supported", try env.fmt(
        "SELECT zetasqlite_generate_range_array({s}, {s})",
        .{ src, try env.enc(.{ .interval = .{ .hours = 1 } }) },
    ));
    try env.expectErrorMsg("input RANGE cannot have UNBOUNDED endpoints", try env.fmt(
        "SELECT zetasqlite_generate_range_array({s}, {s})",
        .{ try env.enc(rng(.date, jan1, null)), one_day },
    ));
}

test "net functions" {
    var env = try TestEnv.init();
    defer env.deinit();
    // IPV4_FROM_INT64(0xABCDEF) -> bytes 00 ab cd ef.
    try env.expectBytesResult("\x00\xAB\xCD\xEF", "SELECT zetasqlite_net_ipv4_from_int64(11259375)");
    try env.expectInt(0xABCDEF, try env.fmt("SELECT zetasqlite_net_ipv4_to_int64({s})", .{try env.enc(Value{ .bytes = "\x00\xAB\xCD\xEF" })}));
    // IP_TO_STRING for v4 and v6.
    try env.expectStringResult("48.49.50.51", try env.fmt("SELECT zetasqlite_net_ip_to_string({s})", .{try env.enc(Value{ .bytes = "0123" })}));
    try env.expectStringResult("::1", try env.fmt("SELECT zetasqlite_net_ip_to_string({s})", .{try env.enc(Value{ .bytes = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01" })}));
    // IP_FROM_STRING round-trips.
    try env.expectBytesResult("0123", try env.fmt("SELECT zetasqlite_net_ip_from_string({s})", .{try env.encStr("48.49.50.51")}));
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_net_safe_ip_from_string({s})", .{try env.encStr("::wxyz")}));
    // HOST / PUBLIC_SUFFIX / REG_DOMAIN.
    try env.expectStringResult("abc.xyz", try env.fmt("SELECT zetasqlite_net_host({s})", .{try env.encStr("http://abc.xyz")}));
    try env.expectStringResult("xyz", try env.fmt("SELECT zetasqlite_net_public_suffix({s})", .{try env.encStr("http://abc.xyz")}));
    try env.expectStringResult("amazon.co.uk", try env.fmt("SELECT zetasqlite_net_reg_domain({s})", .{try env.encStr("amazon.co.uk")}));
    // GENERATE_UUID shape.
    try env.expectInt(36, "SELECT zetasqlite_length(zetasqlite_generate_uuid())");
}
