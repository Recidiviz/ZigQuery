//! Port of go-zetasqlite internal/function_register.go (foundation scope):
//! registers every FuncInfo from bind.zig as the pair
//!   zetasqlite_<name>      (errors -> SQL error, Go BindFunc path)
//!   zetasqlite_safe_<name> (handler errors -> NULL, Go SafeFunc path;
//!                           argument decode / result encode errors still
//!                           raise, exactly like Go's safe wrapper)
//! plus the specials zetasqlite_decode_array, zetasqlite_group_by and the
//! zetasqlite_collate collation.

const std = @import("std");
const sqlite = @import("../../sqlite.zig");
const bind = @import("bind.zig");
const encoder = @import("../encoder.zig");
const value_mod = bind.value_mod;

const c = sqlite.c;
const Value = bind.Value;

/// Per-connection UDF state: a retained arena reset at the start of every
/// scalar call (Go relies on the GC instead). Lives until the allocator that
/// created it is torn down (Go's registration is process-lifetime too).
pub const State = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(state: *State) void {
        const gpa = state.gpa;
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
    state.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };

    inline for (bind.func_table) |info| {
        const Tramp = struct {
            fn normal(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
                invoke(info, false, ctx, argc, argv);
            }
            fn safe(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
                invoke(info, true, ctx, argc, argv);
            }
        };
        try db.createScalarFunction("zetasqlite_" ++ info.name, -1, state, Tramp.normal);
        try db.createScalarFunction("zetasqlite_safe_" ++ info.name, -1, state, Tramp.safe);
    }

    try db.createScalarFunction("zetasqlite_decode_array", -1, state, decodeArrayTramp);
    try db.createScalarFunction("zetasqlite_group_by", -1, state, groupByTramp);
    try db.createCollation("zetasqlite_collate", state, collateCmp);

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

    const n: usize = @intCast(argc);
    if (n < info.min_args) {
        sqlite.resultError(ctx, "zetasqlite_" ++ info.name ++ ": invalid argument num");
        return;
    }

    const args = decodeArgs(alloc, argv, n) catch {
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
    setResult(ctx, alloc, ret) catch {
        sqlite.resultError(ctx, "zetasqlite_" ++ info.name ++ ": failed to encode value");
    };
}

/// Go convertArgs: driver.Value slice -> DecodeValue'd Values. Native
/// INTEGER/FLOAT pass through; TEXT/BLOB carry base64(binary codec).
fn decodeArgs(
    alloc: std.mem.Allocator,
    argv: [*c]?*c.sqlite3_value,
    n: usize,
) ![]Value {
    const args = try alloc.alloc(Value, n);
    for (0..n) |i| {
        args[i] = switch (sqlite.valueType(argv[i])) {
            .null => Value.@"null",
            .integer => Value{ .int = sqlite.valueInt64(argv[i]) },
            .float => Value{ .float = sqlite.valueDouble(argv[i]) },
            .text, .blob => try encoder.DecodeValue(alloc, .{ .text = sqlite.valueText(argv[i]) }),
        };
    }
    return args;
}

fn setResult(ctx: ?*c.sqlite3_context, alloc: std.mem.Allocator, v: Value) !void {
    switch (try encoder.EncodeValue(alloc, v)) {
        .@"null" => sqlite.resultNull(ctx),
        .int => |i| sqlite.resultInt64(ctx, i),
        .float => |f| sqlite.resultDouble(ctx, f),
        .text => |t| sqlite.resultText(ctx, t),
    }
}

/// Error text priority: the handler's formatted message, then value.zig's
/// static diagnostic, then a generic "zetasqlite_<name>: <ErrorName>".
fn errorText(comptime name: []const u8, err: anyerror, buf: []u8) []const u8 {
    if (bind.message) |m| return m;
    if (value_mod.diagnostic) |m| return m;
    return std.fmt.bufPrint(buf, "zetasqlite_" ++ name ++ ": {s}", .{@errorName(err)}) catch name;
}

// ----------------------------------------------------------------------
// zetasqlite_decode_array: decode arg0, JSON-array of the elements' encoded
// (EncodeValue) representations; NULL decodes to "[]" (feeds json_each for
// UNNEST).
// ----------------------------------------------------------------------

fn decodeArrayTramp(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(sqlite.userData(ctx).?));
    _ = state.arena.reset(.retain_capacity);
    const alloc = state.arena.allocator();
    bind.clearDiagnostics();

    if (argc < 1) {
        sqlite.resultError(ctx, "zetasqlite_decode_array: invalid argument num");
        return;
    }
    decodeArrayImpl(ctx, alloc, argv[0]) catch |err| {
        var buf: [96]u8 = undefined;
        sqlite.resultError(ctx, errorText("decode_array", err, &buf));
    };
}

fn decodeArrayImpl(ctx: ?*c.sqlite3_context, alloc: std.mem.Allocator, arg: ?*c.sqlite3_value) !void {
    const args = try decodeArgs(alloc, @ptrCast(@constCast(&[_]?*c.sqlite3_value{arg})), 1);
    if (args[0] == .@"null") {
        sqlite.resultText(ctx, "[]");
        return;
    }
    const arr = try args[0].toArray();
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '[');
    for (arr.values, 0..) |elem, i| {
        if (i > 0) try out.append(alloc, ',');
        switch (try encoder.EncodeValue(alloc, elem)) {
            .@"null" => try out.appendSlice(alloc, "null"),
            .int => |v| try out.print(alloc, "{d}", .{v}),
            .float => |f| {
                var fbuf: [32]u8 = undefined;
                try out.appendSlice(alloc, value_mod.formatFloatGo(&fbuf, f));
            },
            // Encoded text is base64: JSON-safe without escaping.
            .text => |t| try out.print(alloc, "\"{s}\"", .{t}),
        }
    }
    try out.append(alloc, ']');
    sqlite.resultText(ctx, out.items);
}

// ----------------------------------------------------------------------
// zetasqlite_group_by: structs/arrays flatten to "elem||elem||..." (their
// elements' ToString); scalars pass through as their native representation
// (Go decoded.Interface()).
// ----------------------------------------------------------------------

fn groupByTramp(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
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
    const args = try decodeArgs(alloc, @ptrCast(@constCast(&[_]?*c.sqlite3_value{arg})), 1);
    const decoded = if (args[0] == .safe) args[0].safe.* else args[0];
    switch (decoded) {
        .@"null" => sqlite.resultNull(ctx),
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
// zetasqlite_collate: base64-decode both operands and compare as Values
// (Go swallows decode/compare errors, degrading toward "less").
// ----------------------------------------------------------------------

fn collateCmp(
    userdata: ?*anyopaque,
    a_len: c_int,
    a_ptr: ?*const anyopaque,
    b_len: c_int,
    b_ptr: ?*const anyopaque,
) callconv(.c) c_int {
    const state: *State = @ptrCast(@alignCast(userdata.?));
    // The scalar arena may be mid-sort-key computation; use a private one.
    var arena = std.heap.ArenaAllocator.init(state.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = rawBytes(a_ptr, a_len);
    const b = rawBytes(b_ptr, b_len);
    const va = encoder.DecodeValue(alloc, .{ .text = a }) catch Value.@"null";
    const vb = encoder.DecodeValue(alloc, .{ .text = b }) catch Value.@"null";
    const ord = value_mod.compareForCollation(va, vb) catch .lt;
    return switch (ord) {
        .eq => 0,
        .gt => 1,
        .lt => -1,
    };
}

fn rawBytes(ptr: ?*const anyopaque, len: c_int) []const u8 {
    const p = ptr orelse return "";
    if (len <= 0) return "";
    return @as([*]const u8, @ptrCast(p))[0..@intCast(len)];
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
            .text, .blob => blk: {
                const txt = try env.alloc().dupe(u8, stmt.columnText(0));
                break :blk try encoder.DecodeValue(env.alloc(), .{ .text = txt });
            },
            .null => Value.@"null",
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

    fn expectNullResult(env: *TestEnv, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try testing.expect(v == .@"null");
    }

    fn expectStringResult(env: *TestEnv, expected: []const u8, sql: []const u8) !void {
        const v = try env.queryValue(sql);
        try testing.expect(v == .string);
        try testing.expectEqualStrings(expected, v.string);
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
        const repr = try encoder.EncodeValue(env.alloc(), v);
        return std.fmt.allocPrint(env.alloc(), "'{s}'", .{repr.text});
    }

    fn encStr(env: *TestEnv, s: []const u8) ![]u8 {
        return env.enc(Value{ .string = s });
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

    // Still-deferred target kinds raise (NUMERIC, kind 23).
    const t_numeric = try env.encStr("{\"kind\":23}");
    try env.expectErrorMsg(
        "CAST: unimplemented cast",
        try env.fmt("SELECT zetasqlite_cast({s}, {s}, {s}, 0)", .{ try env.encStr("1.5"), t_string, t_numeric }),
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

test "error() raises with its message; safe variant yields NULL" {
    var env = try TestEnv.init();
    defer env.deinit();

    try env.expectErrorMsg("boom", try env.fmt("SELECT zetasqlite_error({s})", .{try env.encStr("boom")}));
    try env.expectNullResult("SELECT zetasqlite_error(NULL)");
    try env.expectNullResult(try env.fmt("SELECT zetasqlite_safe_error({s})", .{try env.encStr("boom")}));
}

test "decode_array emits JSON of encoded elements" {
    var env = try TestEnv.init();
    defer env.deinit();

    try testing.expectEqualStrings(
        "[1,2,3]",
        try env.queryText("SELECT zetasqlite_decode_array(zetasqlite_make_array(1, 2, 3))"),
    );
    try testing.expectEqualStrings(
        "[]",
        try env.queryText("SELECT zetasqlite_decode_array(NULL)"),
    );
    // NULL elements and encoded (text) elements round-trip through the JSON.
    const json = try env.queryText(try env.fmt(
        "SELECT zetasqlite_decode_array(zetasqlite_make_array(1, NULL, {s}))",
        .{try env.encStr("hi")},
    ));
    try testing.expect(std.mem.startsWith(u8, json, "[1,null,\""));
    // The quoted element decodes back to "hi".
    const start = std.mem.indexOfScalar(u8, json, '"').? + 1;
    const end = std.mem.lastIndexOfScalar(u8, json, '"').?;
    const decoded = try encoder.DecodeValue(env.alloc(), .{ .text = json[start..end] });
    try value_mod.expectValueEqual(Value{ .string = "hi" }, decoded);
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

test "zetasqlite_collate orders by decoded value" {
    var env = try TestEnv.init();
    defer env.deinit();

    // Binary order of the encoded text puts "b" (shorter payload) before
    // "aa"; decoded string order must put "aa" first.
    const enc_b = try env.encStr("b");
    const enc_aa = try env.encStr("aa");
    const sql = try env.fmt(
        "SELECT v FROM (SELECT {s} AS v UNION ALL SELECT {s}) ORDER BY v COLLATE zetasqlite_collate",
        .{ enc_b, enc_aa },
    );
    var stmt = try env.db.prepare(sql);
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    const first = try encoder.DecodeValue(env.alloc(), .{ .text = try env.alloc().dupe(u8, stmt.columnText(0)) });
    try value_mod.expectValueEqual(Value{ .string = "aa" }, first);
    try testing.expect(try stmt.step());
    const second = try encoder.DecodeValue(env.alloc(), .{ .text = try env.alloc().dupe(u8, stmt.columnText(0)) });
    try value_mod.expectValueEqual(Value{ .string = "b" }, second);

    // Dates compare chronologically.
    const d1 = try env.enc(Value{ .date = try value_mod.parseDateDays("2021-06-15") });
    const d2 = try env.enc(Value{ .date = try value_mod.parseDateDays("2021-01-01") });
    const date_sql = try env.fmt(
        "SELECT v FROM (SELECT {s} AS v UNION ALL SELECT {s}) ORDER BY v COLLATE zetasqlite_collate",
        .{ d1, d2 },
    );
    var dstmt = try env.db.prepare(date_sql);
    defer dstmt.finalize();
    try testing.expect(try dstmt.step());
    const first_date = try encoder.DecodeValue(env.alloc(), .{ .text = try env.alloc().dupe(u8, dstmt.columnText(0)) });
    try value_mod.expectValueEqual(Value{ .date = try value_mod.parseDateDays("2021-01-01") }, first_date);
}

test "min_args guard rejects too few arguments instead of UB" {
    var env = try TestEnv.init();
    defer env.deinit();
    try env.expectErrorMsg("zetasqlite_add: invalid argument num", "SELECT zetasqlite_add(1)");
}
