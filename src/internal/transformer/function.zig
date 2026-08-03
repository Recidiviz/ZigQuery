//! Faithful port of go-zetasqlite internal/transformer_function.go.
//!
//! Handles:
//! - recursive argument transformation through the coordinator
//! - current-time literal injection for current_* functions (only when a
//!   deterministic time was provided; Go appends nothing otherwise and the
//!   runtime UDF falls back to time.Now() at eval time)
//! - the special zetasqlite_ifnull / zetasqlite_if / zetasqlite_case_*
//!   rewrites into CASE expression objects
//! - window specification construction (PARTITION BY / ORDER BY / frame)
//! - the fast-path lowering of primitive-typed comparison/logical functions
//!   into native SQL operators (canOptimizeFunction/optimizeFunctionToSQL)
//!
//! The Go funcMap CallSQL branch (user-defined FunctionSpec) is skipped for
//! this milestone: no UDFs are registered yet, so the map is always empty
//! and the default function-call rendering below matches Go's behavior.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const common = @import("common.zig");

const Error = types_data.Error;
const ExpressionData = types_data.ExpressionData;
const SQLExpression = sqlbuilder.SQLExpression;

/// Go FunctionCallTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) Error!*SQLExpression {
    // Go: "expected function call expression data, got type %v"
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
        // Go: CurrentTime(ctx) != nil -> append the encoded UnixNano int64
        // literal; nil (no WithCurrentTime) appends nothing.
        if (ctx.query_ctx.current_time_unix_micros) |micros| {
            const nanos = micros * std.time.ns_per_us;
            try args.append(alloc, try common.newLiteralExpressionFromValue(
                alloc,
                .{ .int = nanos },
            ));
        }
    }

    // Handle special ZetaSQL functions that need transformation.
    if (std.mem.eql(u8, function.name, "zetasqlite_ifnull")) {
        // IFNULL(a, b) => CASE WHEN a IS NULL THEN b ELSE a END
        // Go: "zetasqlite_ifnull requires exactly 2 arguments"
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
    } else if (std.mem.eql(u8, function.name, "zetasqlite_if")) {
        // IF(cond, then, else) => CASE WHEN cond THEN then ELSE else END
        // Go: "zetasqlite_if requires exactly 3 arguments"
        if (args.items.len != 3) return error.InvalidAST;
        const when = try alloc.create(sqlbuilder.WhenClause);
        when.* = .{ .condition = args.items[0], .result = args.items[1] };
        const whens = try alloc.alloc(*sqlbuilder.WhenClause, 1);
        whens[0] = when;
        return sqlbuilder.newCaseExpression(alloc, whens, args.items[2]);
    } else if (std.mem.eql(u8, function.name, "zetasqlite_case_no_value")) {
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
    } else if (std.mem.eql(u8, function.name, "zetasqlite_case_with_value")) {
        // First arg is the value, then condition, result, ..., [else].
        // Go: "zetasqlite_case_with_value requires at least 3 arguments"
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
            // This used to apply COLLATE zetasqlite_collate so SQLite
            // partitioned on the decoded value. Unnecessary since the encodings
            // became memcomparable: SQLite's own byte comparison is now the
            // right one, and the collation no longer exists.
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
            // The sqlbuilder FrameClause requires a start bound (Go leaves a
            // nil pointer that would crash at render time; the extractor
            // always provides one).
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

    // Fast path optimization: bypass function calls for primitive type
    // operations (avoids per-call decode/encode overhead).
    if (canOptimizeFunction(function)) {
        return optimizeFunctionToSQL(alloc, function.name, args.items);
    }

    // Go funcMapFromContext: user-defined FunctionSpec -> CallSQL inlining
    // (the stored SQL body with each @argname replaced by the rendered
    // argument SQL, wrapped in parens). JS-language / templated functions
    // have no stored body and surface error.Unimplemented (goja excluded).
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

/// Go: frameData.Start.Offset != (ExpressionData{}).
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

/// Go functionToOperator.
const function_to_operator = std.StaticStringMap([]const u8).initComptime(.{
    // Comparison operators.
    .{ "zetasqlite_equal", "=" },
    .{ "zetasqlite_not_equal", "!=" },
    .{ "zetasqlite_less", "<" },
    .{ "zetasqlite_greater", ">" },
    .{ "zetasqlite_less_or_equal", "<=" },
    .{ "zetasqlite_greater_or_equal", ">=" },
    .{ "zetasqlite_in", "IN" },
    // Logical operators.
    .{ "zetasqlite_and", "AND" },
    .{ "zetasqlite_or", "OR" },
    .{ "zetasqlite_not", "NOT" },
});

/// Go canOptimizeFunction: name must map to an operator, argument counts
/// must fit the operator shape, and every argument must be a primitive
/// SQLite-compatible type or itself an optimizable expression.
fn canOptimizeFunction(function: *const types_data.FunctionCallData) bool {
    if (function_to_operator.get(function.name) == null) return false;

    // Check argument count requirements.
    if (std.mem.eql(u8, function.name, "zetasqlite_not")) {
        if (function.arguments.len != 1) return false;
    } else if (std.mem.eql(u8, function.name, "zetasqlite_and") or
        std.mem.eql(u8, function.name, "zetasqlite_or"))
    {
        if (function.arguments.len < 2) return false;
    } else {
        // Comparison operators (zetasqlite_in included, exactly like Go).
        if (function.arguments.len != 2) return false;
    }

    for (function.arguments) |arg| {
        if (!isPrimitiveSQLiteType(arg)) return false;
    }
    return true;
}

/// Go optimizeFunctionToSQL: converts functions to direct SQL operators.
fn optimizeFunctionToSQL(
    alloc: std.mem.Allocator,
    function_name: []const u8,
    args: []const *SQLExpression,
) Error!*SQLExpression {
    // Go: "unknown optimizable function: %s"
    const operator = function_to_operator.get(function_name) orelse
        return error.UnsupportedFunction;

    if (std.mem.eql(u8, function_name, "zetasqlite_and") or
        std.mem.eql(u8, function_name, "zetasqlite_or"))
    {
        // Go: "%s expected at least 2 arguments, got %d"
        if (args.len < 2) return error.InvalidAST;
        // Chain multiple arguments with the operator.
        var result = args[0];
        for (args[1..]) |arg| {
            result = try sqlbuilder.newBinaryExpression(alloc, result, operator, arg);
        }
        return result;
    } else if (std.mem.eql(u8, function_name, "zetasqlite_not")) {
        // Go: "%s expected only 1 argument, got %d"
        if (args.len != 1) return error.InvalidAST;
        return sqlbuilder.newNotExpression(alloc, args[0]);
    } else if (std.mem.eql(u8, function_name, "zetasqlite_in")) {
        return sqlbuilder.newBinaryExpression(
            alloc,
            args[0],
            operator,
            try sqlbuilder.newListExpression(alloc, args[1..]),
        );
    } else {
        // Comparison operators. Go: "%s expected 2 arguments, got %d"
        if (args.len != 2) return error.InvalidAST;
        return sqlbuilder.newBinaryExpression(alloc, args[0], operator, args[1]);
    }
}

/// Go isPrimitiveSQLiteType.
fn isPrimitiveSQLiteType(expr: ExpressionData) bool {
    switch (expr.type) {
        .literal => {
            const literal = expr.literal orelse return false;
            // Go: nil Value (SQL NULL) is not primitive.
            return switch (literal.value) {
                .int, .float, .bool, .string => true,
                else => false,
            };
        },
        .column => {
            const column = expr.column orelse return false;
            const t = column.type orelse return false;
            return switch (t.typeKind()) {
                .TYPE_INT32,
                .TYPE_INT64,
                .TYPE_UINT32,
                .TYPE_UINT64,
                .TYPE_BOOL,
                .TYPE_FLOAT,
                .TYPE_DOUBLE,
                .TYPE_STRING,
                => true,
                else => false,
            };
        },
        .function => {
            // Optimizable functions can be treated as primitive for further
            // optimization.
            const function = expr.function orelse return false;
            if (function_to_operator.get(function.name) == null) return false;
            return canOptimizeFunction(function);
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

test "zetasqlite_ifnull rewrites to CASE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const ctx = try testCtx(a);

    const fn_args = try a.alloc(ExpressionData, 2);
    fn_args[0] = try literalExprData(a, .null);
    fn_args[1] = try literalExprData(a, .{ .int = 2 });
    const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_ifnull", fn_args);

    const expr = try transform(&coord, data, ctx);
    try testing.expectEqualStrings(
        "CASE WHEN null IS NULL THEN 2 ELSE null END",
        try expr.toString(a),
    );
}

test "zetasqlite_if and case rewrites" {
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
        const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_if", fn_args);
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
        const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_case_no_value", fn_args);
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
        const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_case_with_value", fn_args);
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
        const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_equal", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("1 = 2", try expr.toString(a));
    }

    // AND chains.
    {
        const fn_args = try a.alloc(ExpressionData, 3);
        fn_args[0] = try literalExprData(a, .{ .bool = true });
        fn_args[1] = try literalExprData(a, .{ .bool = false });
        fn_args[2] = try literalExprData(a, .{ .bool = true });
        const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_and", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("true AND false AND true", try expr.toString(a));
    }

    // NOT.
    {
        const fn_args = try a.alloc(ExpressionData, 1);
        fn_args[0] = try literalExprData(a, .{ .bool = true });
        const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_not", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("NOT (true)", try expr.toString(a));
    }

    // IN (only the two-argument form optimizes, like Go).
    {
        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = try literalExprData(a, .{ .int = 1 });
        fn_args[1] = try literalExprData(a, .{ .int = 2 });
        const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_in", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("1 IN (2)", try expr.toString(a));
    }

    // NULL literal argument defeats the fast path -> plain function call.
    {
        const fn_args = try a.alloc(ExpressionData, 2);
        fn_args[0] = try literalExprData(a, .{ .int = 1 });
        fn_args[1] = try literalExprData(a, .null);
        const data = try types_data.newFunctionCallExpressionData(a, "zetasqlite_equal", fn_args);
        const expr = try transform(&coord, data, ctx);
        try testing.expectEqualStrings("zetasqlite_equal(1, null)", try expr.toString(a));
    }
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
        "zetasqlite_current_date",
        try a.alloc(ExpressionData, 0),
    );
    const expr = try transform(&coord, data, ctx);
    try testing.expectEqualStrings(
        "zetasqlite_current_date(1136239445000000000)",
        try expr.toString(a),
    );

    // Without an injected time no argument is appended (Go appends nothing
    // when WithCurrentTime is unset).
    const ctx2 = try testCtx(a);
    const expr2 = try transform(&coord, data, ctx2);
    try testing.expectEqualStrings("zetasqlite_current_date()", try expr2.toString(a));
}
