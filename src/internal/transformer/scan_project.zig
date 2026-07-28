//! Faithful port of go-zetasqlite internal/transformer_scan_project.go.
//!
//! Recursively transforms the input scan, resolves each output column either
//! through its computed expression or as a qualified column reference, gives
//! every SELECT item an ID-based alias, and wraps the result in a subquery
//! FROM item (the coordinator assigns the scan alias).

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const query_expr = @import("../sqlbuilder/query_expr.zig");

/// Go ProjectScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SelectStatement {
    // Go: "expected project scan data, got type %v"
    if (data.type != .project) return error.UnsupportedNode;
    const project_data = data.project_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const input = try coord.transformScan(project_data.input_scan, ctx);

    // Claim the input's select slot when it is free — this is the whole point
    // of the slot model, and the reason project scans stop being 60% of the
    // emitted subquery levels. A projection over something that already
    // projects (an aggregate, a set operation) still costs a level.
    const q = if (query_expr.canSetSelect(input.query))
        input.query
    else
        try coord.wrapScan(input, ctx);

    // Build a map of computed expressions by column ID for efficient lookup.
    var computed_expr_map = std.AutoHashMap(i64, types_data.ExpressionData).init(alloc);
    for (project_data.expr_list) |computed_col| {
        const id = if (computed_col.column) |col| col.id else 0;
        try computed_expr_map.put(id, computed_col.expression);
    }

    // Now build the projection - expressions can resolve column references.
    var all_cheap = true;
    const select_list = try alloc.alloc(*sqlbuilder.SelectListItem, data.column_list.len);
    for (data.column_list, 0..) |col, i| {
        // ID-based alias for disambiguation.
        const alias = try context.generateIDBasedAlias(alloc, col.name, col.id);

        var expr: *sqlbuilder.SQLExpression = undefined;
        if (computed_expr_map.get(col.id)) |computed_expr_data| {
            // Transform the computed expression.
            expr = try coord.transformExpression(computed_expr_data, ctx);
        } else {
            // No computed expression - create a column reference resolved by
            // the ColumnRef transformer through the FragmentContext.
            const ref = try alloc.create(types_data.ColumnRefData);
            ref.* = .{
                .column_name = col.name,
                .column_id = col.id,
                .table_name = col.table_name,
            };
            expr = try coord.transformExpression(
                .{ .type = .column, .column = ref },
                ctx,
            );
        }

        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{ .expression = expr, .alias = alias };
        select_list[i] = item;
        if (!query_expr.isCheapToDuplicate(expr)) all_cheap = false;
    }

    // If nothing here is worth naming, don't: leave every output column
    // pending and let whoever consumes them write them in place. That is what
    // collapses a chain of projections into one SELECT, and it is why project
    // scans stop dominating the emitted levels.
    //
    // All-or-nothing per scan, not per column: a select list holding only
    // *some* of the scan's outputs would break the one-item-per-output-column
    // contract that materializeScan and validateColumnData rely on.
    if (all_cheap) {
        for (data.column_list, 0..) |col, i| {
            try ctx.fragmentContext().setPending(col.id, select_list[i].expression);
        }
        return q;
    }

    q.select_list = select_list;

    // Otherwise every output column now exists under its id-based alias in
    // this select list. If this statement is never materialized (a LIMIT above
    // it, say), that alias is still how an enclosing scope names it — so record
    // it, rather than leaving the column resolvable by neither route. The entry
    // is retired by materializeScan if and when a level is spent.
    for (data.column_list) |col| {
        try ctx.fragmentContext().setPending(
            col.id,
            try sqlbuilder.newColumnExpression(
                alloc,
                try context.generateIDBasedAlias(alloc, col.name, col.id),
                null,
            ),
        );
    }

    return q;
}
