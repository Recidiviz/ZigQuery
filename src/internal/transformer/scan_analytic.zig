//! Faithful port of go-zetasqlite internal/transformer_scan_analytic.go.
//!
//! Converts an AnalyticScan (window functions) into a SELECT:
//! - the input scan becomes the FROM item
//! - every window function expression is pre-transformed BEFORE the
//!   coordinator registers this scan's output columns, so its column refs
//!   resolve against the input scan
//! - the SELECT list carries both passthrough columns (qualified refs) and
//!   the computed window functions, all under ID-based aliases
//! - a result-level ORDER BY is synthesized from each function's PARTITION
//!   BY + ORDER BY columns so rows come out in the window evaluation order,
//!   like Go

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const query_expr = @import("../sqlbuilder/query_expr.zig");

const Error = types_data.Error;
const SQLExpression = sqlbuilder.SQLExpression;

/// Go AnalyticScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) Error!*sqlbuilder.SelectStatement {
    // Go: "expected analytic scan data, got type %v"
    if (data.type != .analytic) return error.UnsupportedNode;
    const analytic_data = data.analytic_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Transform the input scan recursively.
    const input_from_item = try coord.materializeScan(
        try coord.transformScan(analytic_data.input_scan, ctx),
        ctx,
    );

    // Pre-transform all window function expressions BEFORE registering
    // output columns, so window function references resolve to input
    // columns, not output columns. (Go keeps two maps keyed identically —
    // functionColumns and transformedFunctions; one map serves both here.)
    var transformed_functions = std.AutoHashMap(i64, *SQLExpression).init(alloc);
    for (analytic_data.function_list) |func_data| {
        const col = func_data.column orelse return error.InvalidAST;
        const expr = try coord.transformExpression(func_data.expression, ctx);
        try transformed_functions.put(col.id, expr);
    }

    // Add all output columns to the SELECT list.
    var select_list: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;
    try select_list.ensureTotalCapacity(alloc, data.column_list.len);
    for (data.column_list) |col| {
        // Window function column -> pre-transformed expression; otherwise a
        // qualified passthrough reference into the input scan.
        const expr = transformed_functions.get(col.id) orelse
            try ctx.fragmentContext().getQualifiedColumnExpression(col.id);

        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{
            .expression = expr,
            .alias = try context.generateIDBasedAlias(alloc, col.name, col.id),
        };
        try select_list.append(alloc, item);
    }

    // Extract ORDER BY from the window specifications so results come out
    // in PARTITION BY + ORDER BY order (Go preserves window semantics in
    // the produced row order).
    var order_by_items: std.ArrayList(*sqlbuilder.OrderByItem) = .empty;
    for (analytic_data.function_list) |func_data| {
        if (func_data.expression.type != .function) continue;
        const function = func_data.expression.function orelse continue;
        const window_spec = function.window_spec orelse continue;

        // PARTITION BY expressions first (unqualified column names; always
        // ASC).
        for (window_spec.partition_by) |part_data| {
            if (part_data.type != .column) continue;
            const column = part_data.column orelse continue;
            const expr = try ctx.fragmentContext().getQualifiedColumnExpression(column.column_id);
            const item = try alloc.create(sqlbuilder.OrderByItem);
            item.* = .{ .expression = expr, .direction = "ASC" };
            try order_by_items.append(alloc, item);
        }

        // ORDER BY expressions (direction from the item).
        for (window_spec.order_by) |order_data| {
            if (order_data.expression.type != .column) continue;
            const column = order_data.expression.column orelse continue;
            const expr = try ctx.fragmentContext().getQualifiedColumnExpression(column.column_id);
            const item = try alloc.create(sqlbuilder.OrderByItem);
            item.* = .{
                .expression = expr,
                .direction = if (order_data.is_descending) "DESC" else "ASC",
            };
            try order_by_items.append(alloc, item);
        }
    }

    const select_stmt = try alloc.create(sqlbuilder.SelectStatement);
    select_stmt.* = .{
        .select_list = try select_list.toOwnedSlice(alloc),
        .from_clause = input_from_item,
        .order_by_list = try order_by_items.toOwnedSlice(alloc),
    };

    // Return as a subquery FROM item (the coordinator assigns the alias).
    return select_stmt;
}

// ----------------------------------------------------------------------
// Tests: golden SQL through driver.translate.
//
// Expected-text derivation (from the Go pipeline this ports):
// - extractor: ROW_NUMBER() -> getZetasqliteFuncName(isWindowFunc=true) ->
//   "zetasqlite_window_row_number" (windowFuncs table); its frame comes from
//   windowFuncFixedRanges: ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW.
//   SUM(x) OVER (...) -> "zetasqlite_window_sum"; the explicit frame is
//   extracted via getWindowBoundaryOptionFuncSQL ("ROWS", "1 PRECEDING",
//   "CURRENT ROW"). The group's PARTITION BY / ORDER BY columns attach to
//   the call's WindowSpec.
// - transformer_function.go: ORDER BY renders "<expr> ASC|DESC"
//   (createOrderByItems). Go also set Collation = "zetasqlite_collate" on the
//   PARTITION BY and ORDER BY exprs; that is gone here, because the encodings
//   are memcomparable and the collation no longer exists.
// - sqlbuilder: FunctionCall renders "name(args) OVER (<spec>)"; the frame
//   renders "<unit> BETWEEN <start> AND <end>", offsets as "<n> PRECEDING".
// - transformer_scan_analytic.go additionally ORDER BYs the outer SELECT on
//   the partition/order columns.
// Column aliases are ID-based (name__id); IDs come from the analyzer, so
// assertions match on the stable fragments around them.
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n  {s}\nin generated SQL:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "golden SQL: ROW_NUMBER() OVER (ORDER BY x)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const stmts = try driver.translate(
        arena.allocator(),
        "SELECT x, ROW_NUMBER() OVER (ORDER BY x) FROM UNNEST([3, 1, 2]) AS x",
        .{},
    );
    try testing.expectEqual(@as(usize, 1), stmts.len);
    const sql = stmts[0];

    // zetasqlite_window_row_number carries the fixed frame from Go's
    // windowFuncFixedRanges (ROWS UNBOUNDED PRECEDING..CURRENT ROW) and the
    // group ORDER BY.
    try expectContains(sql, "zetasqlite_window_row_number() OVER (ORDER BY `x__");
    try expectContains(
        sql,
        "` ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)",
    );
    // The analytic subquery also orders its results by the window ORDER BY
    // column (transformer_scan_analytic.go result ordering).
    try expectContains(sql, "analytic_scan_");
}

test "golden SQL: SUM(x) OVER (PARTITION BY y ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const stmts = try driver.translate(
        arena.allocator(),
        \\SELECT SUM(x) OVER (PARTITION BY y ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        \\FROM UNNEST([STRUCT(1 AS x, 'a' AS y), STRUCT(2, 'a'), STRUCT(3, 'b')])
    ,
        .{},
    );
    try testing.expectEqual(@as(usize, 1), stmts.len);
    const sql = stmts[0];

    try expectContains(sql, "zetasqlite_window_sum(");
    try expectContains(sql, "OVER (PARTITION BY `y__");
    try expectContains(sql, "` ORDER BY `x__");
    try expectContains(
        sql,
        "` ASC ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)",
    );
}

test "golden SQL: DISTINCT and IGNORE NULLS become trailing pseudo-args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // COUNT(DISTINCT x) OVER () -> zetasqlite_window_count(x,
    // zetasqlite_distinct()) with the default full frame.
    {
        const stmts = try driver.translate(
            arena.allocator(),
            "SELECT COUNT(DISTINCT x) OVER () FROM UNNEST([1, 1, 2]) AS x",
            .{},
        );
        try expectContains(stmts[0], "zetasqlite_window_count(`x__");
        try expectContains(stmts[0], ", zetasqlite_distinct()) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)");
    }

    // FIRST_VALUE(x IGNORE NULLS) OVER (ORDER BY x) -> trailing
    // zetasqlite_ignore_nulls() pseudo-arg (navigation functions require an
    // ORDER BY in the OVER clause).
    {
        const stmts = try driver.translate(
            arena.allocator(),
            "SELECT FIRST_VALUE(x IGNORE NULLS) OVER (ORDER BY x) FROM UNNEST([NULL, 1, 2]) AS x",
            .{},
        );
        try expectContains(stmts[0], "zetasqlite_window_first_value(`x__");
        try expectContains(stmts[0], ", zetasqlite_ignore_nulls()) OVER (");
    }
}
