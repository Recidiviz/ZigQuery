//! A function call: what it takes to turn one resolved call into SQLite text.
//!
//! - arguments transform recursively through the coordinator
//! - a CURRENT_* call takes a literal instant only when one was supplied; otherwise the UDF
//!   reads the clock when it runs
//! - `zigquery_ifnull`, `zigquery_if` and `zigquery_case_*` become CASE expression objects
//! - a windowed call carries its PARTITION BY, ORDER BY and frame
//! - a comparison or logical function lowers to a native SQL operator where it can
//!
//! That last one is the only choice here with a correctness condition: a kind lowers to a native
//! operator when SQLite compares its stored form the way GoogleSQL compares the value.
//! `isPrimitiveKind` carries that argument; `codec_sortable.zig` carries the proof. A windowed
//! call never lowers, because it has to stay a function call to keep its OVER clause.
//!
//! A user-defined function is inlined at its call site: the stored SQL body with each `@argname`
//! replaced by the rendered argument. A JS or templated function has no stored body and reports
//! error.Unimplemented.
// ephor:ignore-file ZA301 ZA302 ZA304

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const common = @import("common.zig");
const pb = @import("../../proto/resolved_ast.zig");
const spec = @import("../spec.zig");

const Error = types_data.Error;
const ExpressionData = types_data.ExpressionData;
const SQLExpression = sqlbuilder.SQLExpression;

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) Error!*SQLExpression {
    if (data.type != .function) return error.UnsupportedNode;
    const function = data.function orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Transform arguments recursively.
    var args: std.ArrayList(*SQLExpression) = .empty;
    try args.ensureTotalCapacity(alloc, function.arguments.len);
    for (function.arguments) |arg_data| {
        try args.append(alloc, try coord.transformExpression(arg_data, ctx));
    }

    if (common.current_time_func_names.has(function.name)) {
        // A supplied instant is appended as a nanosecond literal; without one the call takes
        // no argument and the UDF reads the clock when it runs.
        if (ctx.query_ctx.current_time_unix_micros) |micros| {
            const nanos = micros * std.time.ns_per_us;
            try args.append(alloc, try common.newLiteralExpressionFromValue(
                alloc,
                .{ .int = nanos },
            ));
        }
    }

    // Handle special ZetaSQL functions that need transformation.
    if (std.mem.eql(u8, function.name, "zigquery_ifnull")) {
        // IFNULL(a, b) => CASE WHEN a IS NULL THEN b ELSE a END
        if (args.items.len != 2) return error.InvalidAST;
        const when = try alloc.create(sqlbuilder.WhenClause);
        when.* = .{
            .condition = try sqlbuilder.newBinaryExpression(
                alloc,
                args.items[0],
                "IS",
                try sqlbuilder.newLiteralExpression(alloc, "NULL"),
            ),
            .result = args.items[1],
        };
        const whens = try alloc.alloc(*sqlbuilder.WhenClause, 1);
        whens[0] = when;
        return sqlbuilder.newCaseExpression(alloc, whens, args.items[0]);
    } else if (std.mem.eql(u8, function.name, "zigquery_if")) {
        // IF(cond, then, else) => CASE WHEN cond THEN then ELSE else END
        if (args.items.len != 3) return error.InvalidAST;
        const when = try alloc.create(sqlbuilder.WhenClause);
        when.* = .{ .condition = args.items[0], .result = args.items[1] };
        const whens = try alloc.alloc(*sqlbuilder.WhenClause, 1);
        whens[0] = when;
        return sqlbuilder.newCaseExpression(alloc, whens, args.items[2]);
    } else if (std.mem.eql(u8, function.name, "zigquery_case_no_value")) {
        // Arguments are condition, result, condition, result, ..., [else].
        var whens: std.ArrayList(*sqlbuilder.WhenClause) = .empty;
        var i: usize = 0;
        while (i + 1 < args.items.len) : (i += 2) {
            const when = try alloc.create(sqlbuilder.WhenClause);
            when.* = .{ .condition = args.items[i], .result = args.items[i + 1] };
            try whens.append(alloc, when);
        }
        // If args length is an odd number, an else statement exists.
        var else_expr: ?*SQLExpression = null;
        if (args.items.len % 2 == 1) else_expr = args.items[args.items.len - 1];
        return sqlbuilder.newCaseExpression(alloc, try whens.toOwnedSlice(alloc), else_expr);
    } else if (std.mem.eql(u8, function.name, "zigquery_case_with_value")) {
        // First arg is the value, then condition, result, ..., [else].
        if (args.items.len < 3) return error.InvalidAST;
        const value_expr = args.items[0];
        const remaining = args.items[1..];

        var whens: std.ArrayList(*sqlbuilder.WhenClause) = .empty;
        var i: usize = 0;
        while (i + 1 < remaining.len) : (i += 2) {
            const when = try alloc.create(sqlbuilder.WhenClause);
            when.* = .{ .condition = remaining[i], .result = remaining[i + 1] };
            try whens.append(alloc, when);
        }
        var else_expr: ?*SQLExpression = null;
        if (remaining.len % 2 == 1) else_expr = remaining[remaining.len - 1];
        return sqlbuilder.newSimpleCaseExpression(
            alloc,
            value_expr,
            try whens.toOwnedSlice(alloc),
            else_expr,
        );
    }

    // Default branch.
    var window_spec: ?*sqlbuilder.WindowSpecification = null;
    if (function.window_spec) |ws_data| {
        // Transform PARTITION BY expressions.
        var partition_by: std.ArrayList(*SQLExpression) = .empty;
        try partition_by.ensureTotalCapacity(alloc, ws_data.partition_by.len);
        for (ws_data.partition_by) |part_data| {
            const expr = try coord.transformExpression(part_data.*, ctx);
            try partition_by.append(alloc, expr);
        }

        // Transform ORDER BY expressions.
        var order_by: std.ArrayList(*sqlbuilder.OrderByItem) = .empty;
        for (ws_data.order_by) |order_data| {
            const expr = try coord.transformExpression(order_data.expression, ctx);
            const items = try common.createOrderByItems(alloc, expr, order_data);
            try order_by.appendSlice(alloc, items);
        }

        // Transform frame clause if present.
        var frame_clause: ?*sqlbuilder.FrameClause = null;
        if (ws_data.frame_clause) |frame_data| {
            // A frame always has a start bound, and the renderer needs one, so a frame
            // without it is a malformed AST rather than a default.
            const start_data = frame_data.start orelse return error.InvalidAST;

            var start_offset: ?*SQLExpression = null;
            if (!isZeroExpressionData(start_data.offset)) {
                start_offset = try coord.transformExpression(start_data.offset, ctx);
            }
            const start = try alloc.create(sqlbuilder.FrameBound);
            start.* = .{ .type = start_data.type, .offset = start_offset };

            var end: ?*sqlbuilder.FrameBound = null;
            if (frame_data.end) |end_data| {
                var end_offset: ?*SQLExpression = null;
                if (!isZeroExpressionData(end_data.offset)) {
                    end_offset = try coord.transformExpression(end_data.offset, ctx);
                }
                const bound = try alloc.create(sqlbuilder.FrameBound);
                bound.* = .{ .type = end_data.type, .offset = end_offset };
                end = bound;
            }

            const fc = try alloc.create(sqlbuilder.FrameClause);
            fc.* = .{ .unit = frame_data.unit, .start = start, .end = end };
            frame_clause = fc;
        }

        const ws = try alloc.create(sqlbuilder.WindowSpecification);
        ws.* = .{
            .partition_by = try partition_by.toOwnedSlice(alloc),
            .order_by = try order_by.toOwnedSlice(alloc),
            .frame_clause = frame_clause,
        };
        window_spec = ws;
    }

    // Fast path: bypass the UDF for operations SQLite can do on the stored
    // form, saving a decode per argument and an encode per result, per row. A
    // windowed call keeps its OVER clause by staying a function call.
    if (window_spec == null and canOptimizeFunction(function)) {
        return optimizeFunctionToSQL(alloc, function.name, args.items);
    }

    // A user-defined function is inlined here: the stored SQL body with each `@argname`
    // replaced by the rendered argument, wrapped in parens. A JS or templated function has no
    // stored body and reports error.Unimplemented.
    if (ctx.findFunctionSpec(function.name)) |fn_spec| {
        const arg_sql = try alloc.alloc([]const u8, args.items.len);
        for (args.items, 0..) |arg_expr, i| {
            arg_sql[i] = try arg_expr.toString(alloc);
        }
        const call_sql = try fn_spec.callSQL(alloc, arg_sql);
        return sqlbuilder.newLiteralExpression(alloc, call_sql);
    }

    // Default function call transformation.
    const call = try alloc.create(sqlbuilder.FunctionCall);
    call.* = .{
        .name = function.name,
        .arguments = try args.toOwnedSlice(alloc),
        .window_spec = window_spec,
    };
    const expr = try alloc.create(SQLExpression);
    expr.* = .{ .type = .function, .function_call = call };
    return expr;
}

/// Whether an ExpressionData carries nothing, which is how an absent frame offset arrives.
fn isZeroExpressionData(e: ExpressionData) bool {
    return e.type == .column and
        e.parameter == null and
        e.literal == null and
        e.function == null and
        e.cast == null and
        e.column == null and
        e.binary == null and
        e.case == null and
        e.subquery == null;
}

/// A function that lowers to a native SQLite operator, and the shape it lowers
/// into. Everything the three consumers need: the gate (`canOptimizeFunction`),
/// the operand predicate (`isPrimitiveSQLiteType`), the renderer
/// (`optimizeFunctionToSQL`).
const Lowering = struct {
    op: []const u8,
    form: Form,
    min_args: u8,
    /// null: variadic.
    max_args: ?u8 = null,
    operands: Operands = .primitive,

    const Form = enum {
        /// `a OP b`, folded left for more than two: `a OP b OP c`.
        infix,
        /// `a OP (b, c, ...)`.
        in_list,
        /// `OP (a)`.
        prefix,
        /// `a IS NULL`.
        is_null,
        /// `a BETWEEN b AND c`.
        between,
    };

    const Operands = enum {
        /// The operator compares stored values: every argument must satisfy
        /// `isPrimitiveSQLiteType`.
        primitive,
        /// The operator inspects only NULL-ness, which every encoding
        /// preserves. Any argument will do.
        any,
    };
};

const lowerings = std.StaticStringMap(Lowering).initComptime(.{
    // Comparison operators.
    .{ "zigquery_equal", Lowering{ .op = "=", .form = .infix, .min_args = 2, .max_args = 2 } },
    .{ "zigquery_not_equal", Lowering{ .op = "!=", .form = .infix, .min_args = 2, .max_args = 2 } },
    .{ "zigquery_less", Lowering{ .op = "<", .form = .infix, .min_args = 2, .max_args = 2 } },
    .{ "zigquery_greater", Lowering{ .op = ">", .form = .infix, .min_args = 2, .max_args = 2 } },
    .{ "zigquery_less_or_equal", Lowering{ .op = "<=", .form = .infix, .min_args = 2, .max_args = 2 } },
    .{ "zigquery_greater_or_equal", Lowering{ .op = ">=", .form = .infix, .min_args = 2, .max_args = 2 } },
    // NULL-safe equality: `a IS b` is TRUE when both are NULL and `a = b`
    // otherwise. operators.md#is_operators
    .{ "zigquery_is_not_distinct_from", Lowering{ .op = "IS", .form = .infix, .min_args = 2, .max_args = 2 } },
    .{ "zigquery_is_distinct_from", Lowering{ .op = "IS NOT", .form = .infix, .min_args = 2, .max_args = 2 } },
    .{ "zigquery_between", Lowering{ .op = "BETWEEN", .form = .between, .min_args = 3, .max_args = 3 } },
    .{ "zigquery_in", Lowering{ .op = "IN", .form = .in_list, .min_args = 2 } },
    // Logical operators.
    .{ "zigquery_and", Lowering{ .op = "AND", .form = .infix, .min_args = 2 } },
    .{ "zigquery_or", Lowering{ .op = "OR", .form = .infix, .min_args = 2 } },
    .{ "zigquery_not", Lowering{ .op = "NOT", .form = .prefix, .min_args = 1, .max_args = 1 } },
    // Lowers over ARRAY and STRUCT too, by the .any operand rule.
    .{ "zigquery_is_null", Lowering{ .op = "IS NULL", .form = .is_null, .min_args = 1, .max_args = 1, .operands = .any } },
});

/// Whether the call can be lowered: the name maps to an operator, the argument
/// count fits its shape, and — unless the operator only looks at NULL-ness —
/// every argument is stored in a form SQLite compares the way GoogleSQL does.
fn canOptimizeFunction(function: *const types_data.FunctionCallData) bool {
    const l = lowerings.get(function.name) orelse return false;

    if (function.arguments.len < l.min_args) return false;
    if (l.max_args) |max| {
        if (function.arguments.len > max) return false;
    }

    if (l.operands == .primitive) {
        for (function.arguments) |arg| {
            if (!isPrimitiveSQLiteType(arg)) return false;
        }
    }
    return true;
}

/// Parenthesises a binary operand, whose precedence against its parent
/// `BinaryExpression` is otherwise whatever SQLite's grammar assigns: the
/// builder renders `left OP right` bare, so nesting an OR under an AND reads
/// back as `a OR (b AND c)`. Every other expression kind self-delimits.
///
/// A one-element `ListExpression` renders as `(expr)`.
fn grouped(alloc: std.mem.Allocator, e: *SQLExpression) Error!*SQLExpression {
    if (e.type != .binary) return e;
    const one = try alloc.alloc(*SQLExpression, 1);
    one[0] = e;
    return sqlbuilder.newListExpression(alloc, one);
}

/// `args`, each grouped, as one parenthesised list: the right side of an IN.
fn groupedList(alloc: std.mem.Allocator, args: []const *SQLExpression) Error!*SQLExpression {
    const list = try alloc.alloc(*SQLExpression, args.len);
    errdefer alloc.free(list);
    for (args, list) |arg, *slot| slot.* = try grouped(alloc, arg);
    return sqlbuilder.newListExpression(alloc, list);
}

/// Renders the lowered form, one arm per `Lowering.Form`.
fn optimizeFunctionToSQL(
    alloc: std.mem.Allocator,
    function_name: []const u8,
    args: []const *SQLExpression,
) Error!*SQLExpression {
    // canOptimizeFunction, the only caller, has looked this up and
    // range-checked args.len against it.
    const l = lowerings.get(function_name) orelse return error.InvalidAST;

    switch (l.form) {
        .infix => {
            if (args.len < 2) return error.InvalidAST;
            var result = try grouped(alloc, args[0]);
            for (args[1..]) |arg| {
                result = try sqlbuilder.newBinaryExpression(
                    alloc,
                    result,
                    l.op,
                    try grouped(alloc, arg),
                );
            }
            return result;
        },
        .in_list => {
            if (args.len < 2) return error.InvalidAST;
            return sqlbuilder.newBinaryExpression(
                alloc,
                try grouped(alloc, args[0]),
                l.op,
                try groupedList(alloc, args[1..]),
            );
        },
        .prefix => {
            if (args.len != 1) return error.InvalidAST;
            // newNotExpression renders `NOT (x)`, parentheses included.
            return sqlbuilder.newNotExpression(alloc, args[0]);
        },
        .is_null => {
            if (args.len != 1) return error.InvalidAST;
            return sqlbuilder.newBinaryExpression(
                alloc,
                try grouped(alloc, args[0]),
                "IS",
                try sqlbuilder.newLiteralExpression(alloc, "NULL"),
            );
        },
        .between => {
            if (args.len != 3) return error.InvalidAST;
            // BETWEEN's AND is part of its syntax: the bounds group, the
            // joiner does not.
            const bounds = try sqlbuilder.newBinaryExpression(
                alloc,
                try grouped(alloc, args[1]),
                "AND",
                try grouped(alloc, args[2]),
            );
            return sqlbuilder.newBinaryExpression(
                alloc,
                try grouped(alloc, args[0]),
                l.op,
                bounds,
            );
        },
    }
}

/// Whether a value of this kind is stored in a form SQLite's own operators
/// compare the way GoogleSQL does.
///
/// Two groups qualify. The scalars travel natively: INT/UINT as INTEGER, FLOAT
/// and DOUBLE as REAL, BOOL as INTEGER 0/1. The rest are BLOBs carrying the
/// memcomparable encoding, where `memcmp` equals `value.compareForCollation`
/// (pinned by `test "memcmp over encodings matches compareForCollation"` in
/// `codec_sortable.zig`), and `compareForCollation` is built from `Value.eq`
/// and `Value.gt` — what the comparison UDFs themselves call.
///
/// Two supporting facts, neither local to this file:
///
/// - Every value crossing the SQLite boundary is encoded top-level through
///   `encoder.encodeTo`, `unnest_vtab.xColumn` and `zigquery_get_struct_field`
///   results included. An operator sees RANGE in its ordered form, never the
///   self-delimiting one an ARRAY or STRUCT nests.
/// - `spec.sqliteTypeName` declares these columns TEXT (BYTES: BLOB), and
///   neither affinity coerces a BLOB value, so the stored bytes reach the
///   comparison intact.
///
/// The exclusions and their reasons. ARRAY, STRUCT, JSON and INTERVAL take the
/// self-delimiting codec, whose uvarint length prefixes sort by length before
/// content; byte equality on a STRUCT also answers FALSE where GoogleSQL
/// answers NULL for a NULL field. An ENUM literal decodes to a `.string` Value
/// while `sqliteTypeName` declares the column INT; enums reach the engine only
/// as date-part and NORMALIZE-mode markers passed to functions.
fn isPrimitiveKind(k: pb.TypeKind) bool {
    return switch (k) {
        // Native storage classes.
        .TYPE_INT32,
        .TYPE_INT64,
        .TYPE_UINT32,
        .TYPE_UINT64,
        .TYPE_BOOL,
        .TYPE_FLOAT,
        .TYPE_DOUBLE,
        // Memcomparable BLOBs.
        .TYPE_STRING,
        .TYPE_BYTES,
        .TYPE_DATE,
        .TYPE_TIME,
        .TYPE_DATETIME,
        .TYPE_TIMESTAMP,
        .TYPE_NUMERIC,
        .TYPE_BIGNUMERIC,
        .TYPE_RANGE,
        => true,
        else => false,
    };
}

/// Whether this operand may meet a native SQLite operator. See
/// `isPrimitiveKind` for why a kind qualifies.
fn isPrimitiveSQLiteType(expr: ExpressionData) bool {
    switch (expr.type) {
        .literal => {
            const literal = expr.literal orelse return false;
            // A SQL NULL is not primitive. Every operator in the table agrees
            // with its UDF on NULL, so the cost is a constant-folding
            // opportunity and the gain is lowered SQL free of `null IS NULL`.
            return switch (literal.value) {
                .int,
                .float,
                .bool,
                .string,
                .bytes,
                .date,
                .time,
                .datetime,
                .timestamp,
                .numeric,
                .range,
                => true,
                else => false,
            };
        },
        .column => {
            const column = expr.column orelse return false;
            const t = column.type orelse return false;
            return isPrimitiveKind(t.typeKind());
        },
        .function => {
            const function = expr.function orelse return false;
            // A lowered operator yields SQLite's own 0/1, which is how BOOL is
            // stored.
            if (canOptimizeFunction(function)) return true;
            // A UDF call yields the engine's encoding for its result type, an
            // operand like any other when that type qualifies. Covers both the
            // functions with no operator mapping and the mapped ones that fail
            // the gate: `zigquery_in` over a STRUCT returns an encoded BOOL.
            return isPrimitiveKind(function.result_kind);
        },
        else => return false,
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn testCtx(alloc: std.mem.Allocator) !*context.TransformContext {
    const config = try alloc.create(context.TransformConfig);
    config.* = .{};
    return context.TransformContext.init(alloc, config);
}

fn literalExprData(alloc: std.mem.Allocator, v: types_data.Value) !ExpressionData {
    const lit = try alloc.create(types_data.LiteralData);
    lit.* = .{ .value = v };
    return .{ .type = .literal, .literal = lit };
}

test "zigquery_ifnull rewrites to CASE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const ctx = try testCtx(a);

    const fn_args = try a.alloc(ExpressionData, 2);
    fn_args[0] = try literalExprData(a, .null);
    fn_args[1] = try literalExprData(a, .{ .int = 2 });
    const data = try types_data.newFunctionCallExpressionData(a, "zigquery_ifnull", fn_args);

    const expr = try transform(&coord, data, ctx);
    try testing.expectEqualStrings(
        "CASE WHEN null IS NULL THEN 2 ELSE null END",
        try expr.toString(a),
    );
}

test "zigquery_if and case rewrites" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const ctx = try testCtx(a);

    {
        const fn_args = try a.alloc(ExpressionData, 3);
        fn_args[0] = try literalExprData(a, .{ .bool = true });
        fn_args[1] = try literalExprData(a, .{ .int = 1 });
        fn_args[2] = try literalExprData(a, .{ .int = 2 });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_if", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings(
            "CASE WHEN true THEN 1 ELSE 2 END",
            try expr.toString(a),
        );
    }

    // case_no_value with odd arg count -> trailing ELSE.
    {
        const fn_args = try a.alloc(ExpressionData, 3);
        fn_args[0] = try literalExprData(a, .{ .bool = false });
        fn_args[1] = try literalExprData(a, .{ .int = 1 });
        fn_args[2] = try literalExprData(a, .{ .int = 9 });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_case_no_value", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings(
            "CASE WHEN false THEN 1 ELSE 9 END",
            try expr.toString(a),
        );
    }

    // case_with_value: CASE v WHEN c THEN r ELSE e END.
    {
        const fn_args = try a.alloc(ExpressionData, 4);
        fn_args[0] = try literalExprData(a, .{ .int = 3 });
        fn_args[1] = try literalExprData(a, .{ .int = 3 });
        fn_args[2] = try literalExprData(a, .{ .string = "x" });
        fn_args[3] = try literalExprData(a, .{ .string = "y" });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_case_with_value", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expect(expr.type == .case);
        try testing.expect(expr.case_expression.?.case_expr != null);
        try testing.expectEqual(@as(usize, 1), expr.case_expression.?.when_clauses.len);
        try testing.expect(expr.case_expression.?.else_expr != null);
    }
}

test "fast-path lowering of primitive comparisons and logic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const ctx = try testCtx(a);

    // 1 = 2 -> native binary expression.
    {
        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = try literalExprData(a, .{ .int = 1 });
        fn_args[1] = try literalExprData(a, .{ .int = 2 });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_equal", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("1 = 2", try expr.toString(a));
    }

    // AND chains.
    {
        const fn_args = try a.alloc(ExpressionData, 3);
        fn_args[0] = try literalExprData(a, .{ .bool = true });
        fn_args[1] = try literalExprData(a, .{ .bool = false });
        fn_args[2] = try literalExprData(a, .{ .bool = true });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_and", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("true AND false AND true", try expr.toString(a));
    }

    // NOT.
    {
        const fn_args = try a.alloc(ExpressionData, 1);
        fn_args[0] = try literalExprData(a, .{ .bool = true });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_not", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("NOT (true)", try expr.toString(a));
    }

    // IN, at every list length.
    {
        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = try literalExprData(a, .{ .int = 1 });
        fn_args[1] = try literalExprData(a, .{ .int = 2 });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_in", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("1 IN (2)", try expr.toString(a));
    }
    {
        const fn_args = try a.alloc(ExpressionData, 4);
        fn_args[0] = try literalExprData(a, .{ .int = 5 });
        fn_args[1] = try literalExprData(a, .{ .int = 1 });
        fn_args[2] = try literalExprData(a, .{ .int = 5 });
        fn_args[3] = try literalExprData(a, .{ .int = 10 });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_in", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("5 IN (1,5,10)", try expr.toString(a));
    }

    // BETWEEN's AND is syntax: the bounds group, the joiner does not.
    {
        const fn_args = try a.alloc(ExpressionData, 3);
        fn_args[0] = try literalExprData(a, .{ .int = 5 });
        fn_args[1] = try literalExprData(a, .{ .int = 1 });
        fn_args[2] = try literalExprData(a, .{ .int = 10 });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_between", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("5 BETWEEN 1 AND 10", try expr.toString(a));
    }

    // NULL-safe equality maps onto SQLite's IS.
    {
        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = try literalExprData(a, .{ .int = 1 });
        fn_args[1] = try literalExprData(a, .{ .int = 1 });
        const data = try types_data.newFunctionCallExpressionData(
            a,
            "zigquery_is_not_distinct_from",
            fn_args,
        );
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("1 IS 1", try expr.toString(a));
    }

    // NULL literal argument defeats the fast path -> plain function call.
    {
        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = try literalExprData(a, .{ .int = 1 });
        fn_args[1] = try literalExprData(a, .null);
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_equal", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("zigquery_equal(1, null)", try expr.toString(a));
    }
}

/// A column reference of the given kind, registered in the fragment context so
/// the ColumnRef transformer resolves it.
fn columnExprData(
    ctx: *context.TransformContext,
    id: i64,
    name: []const u8,
    kind: pb.TypeKind,
) !ExpressionData {
    const a = ctx.alloc;
    const info = try a.create(context.ColumnInfo);
    info.* = .{ .name = name, .id = id };
    try ctx.fragmentContext().addAvailableColumn(id, info);
    try ctx.fragmentContext().registerColumnScope(id, "t");

    const t = try a.create(spec.Type);
    t.* = .{ .kind = @backingInt(kind) };
    const ref = try a.create(types_data.ColumnRefData);
    ref.* = .{ .column_name = name, .column_id = id, .table_name = "t", .type = t };
    return .{ .type = .column, .column = ref };
}

test "every memcomparable kind lowers; the self-delimiting ones do not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const ctx = try testCtx(a);

    // The kinds codec_sortable.zig owns, plus the natively stored scalars.
    for ([_]pb.TypeKind{
        .TYPE_STRING,   .TYPE_BYTES,
        .TYPE_DATE,     .TYPE_TIME,
        .TYPE_DATETIME, .TYPE_TIMESTAMP,
        .TYPE_NUMERIC,  .TYPE_BIGNUMERIC,
        .TYPE_RANGE,    .TYPE_INT64,
        .TYPE_DOUBLE,   .TYPE_BOOL,
    }, 0..) |kind, i| {
        const id: i64 = @intCast(i * 2);
        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = try columnExprData(ctx, id, "x", kind);
        fn_args[1] = try columnExprData(ctx, id + 1, "y", kind);
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_less", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("`x` < `y`", try expr.toString(a));
    }

    // The self-delimiting codec sorts by length before content, so these stay
    // on the UDF.
    for ([_]pb.TypeKind{ .TYPE_ARRAY, .TYPE_STRUCT, .TYPE_JSON, .TYPE_INTERVAL }, 0..) |kind, i| {
        const id: i64 = @intCast(100 + i * 2);
        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = try columnExprData(ctx, id, "x", kind);
        fn_args[1] = try columnExprData(ctx, id + 1, "y", kind);
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_equal", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("zigquery_equal(`x`, `y`)", try expr.toString(a));
    }
}

test "IS NULL lowers over any kind; a primitive result type makes any call an operand" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const ctx = try testCtx(a);

    // IS NULL inspects only NULL-ness, so an ARRAY column lowers here while
    // `=` on one does not.
    {
        const fn_args = try a.alloc(ExpressionData, 1);
        fn_args[0] = try columnExprData(ctx, 1, "arr", .TYPE_ARRAY);
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_is_null", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("`arr` IS NULL", try expr.toString(a));
    }

    // A call with no operator mapping is an operand when its result type
    // qualifies: zigquery_array_length returns INT64, a native INTEGER.
    {
        const inner_args = try a.alloc(ExpressionData, 1);
        inner_args[0] = try columnExprData(ctx, 2, "arr", .TYPE_ARRAY);
        var inner = try types_data.newFunctionCallExpressionData(
            a,
            "zigquery_array_length",
            inner_args,
        );
        inner.function.?.result_kind = .TYPE_INT64;

        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = inner;
        fn_args[1] = try literalExprData(a, .{ .int = 0 });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_equal", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings(
            "zigquery_array_length(`arr`) = 0",
            try expr.toString(a),
        );
    }

    // TYPE_UNKNOWN, the default every transformer-synthesized node carries,
    // is not an operand.
    {
        const inner_args = try a.alloc(ExpressionData, 1);
        inner_args[0] = try columnExprData(ctx, 3, "arr", .TYPE_ARRAY);
        const inner = try types_data.newFunctionCallExpressionData(
            a,
            "zigquery_array_length",
            inner_args,
        );

        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = inner;
        fn_args[1] = try literalExprData(a, .{ .int = 0 });
        const data = try types_data.newFunctionCallExpressionData(a, "zigquery_equal", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings(
            "zigquery_equal(zigquery_array_length(`arr`), 0)",
            try expr.toString(a),
        );
    }
}

test "a lowered operand keeps its parentheses when the parent binds tighter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const ctx = try testCtx(a);

    // AND binds tighter than OR, so the OR operand carries the grouping:
    // bare, `a OR b AND c` reads back as `a OR (b AND c)`.
    const or_args = try a.alloc(ExpressionData, 2);
    or_args[0] = try columnExprData(ctx, 1, "a", .TYPE_BOOL);
    or_args[1] = try columnExprData(ctx, 2, "b", .TYPE_BOOL);
    const or_data = try types_data.newFunctionCallExpressionData(a, "zigquery_or", or_args);

    const and_args = try a.alloc(ExpressionData, 2);
    and_args[0] = or_data;
    and_args[1] = try columnExprData(ctx, 3, "c", .TYPE_BOOL);
    const and_data = try types_data.newFunctionCallExpressionData(a, "zigquery_and", and_args);

    const expr = try transform(&coord, and_data, ctx);
    try testing.expectEqualStrings(
        "(`a` OR `b`) AND `c`",
        try expr.toString(a),
    );

    // The reverse nesting groups correctly bare, and must stay bare.
    const and2_args = try a.alloc(ExpressionData, 2);
    and2_args[0] = try columnExprData(ctx, 1, "a", .TYPE_BOOL);
    and2_args[1] = try columnExprData(ctx, 2, "b", .TYPE_BOOL);
    const and2 = try types_data.newFunctionCallExpressionData(a, "zigquery_and", and2_args);

    const or2_args = try a.alloc(ExpressionData, 2);
    or2_args[0] = and2;
    or2_args[1] = try columnExprData(ctx, 3, "c", .TYPE_BOOL);
    const or2 = try types_data.newFunctionCallExpressionData(a, "zigquery_or", or2_args);

    const expr2 = try transform(&coord, or2, ctx);
    try testing.expectEqualStrings(
        "(`a` AND `b`) OR `c`",
        try expr2.toString(a),
    );
}

test "current-time literal injection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const ctx = try testCtx(a);
    ctx.query_ctx.current_time_unix_micros = 1136239445000000;

    const data = try types_data.newFunctionCallExpressionData(
        a,
        "zigquery_current_date",
        try a.alloc(ExpressionData, 0),
    );
    const expr = try transform(&coord, data, ctx);
    try testing.expectEqualStrings(
        "zigquery_current_date(1136239445000000000)",
        try expr.toString(a),
    );

    // Without an injected time the call takes no argument.
    const ctx2 = try testCtx(a);
    const expr2 = try transform(&coord, data, ctx2);
    try testing.expectEqualStrings("zigquery_current_date()", try expr2.toString(a));
}
